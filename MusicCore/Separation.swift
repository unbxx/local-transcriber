import Accelerate
import Foundation

// Vocals and instrumental without a separation model, from the reference's
// `separate_and_track`: the melody is tracked in the centre-weighted mid
// spectrogram, and the vocals are the mid signal under a harmonic mask around
// that melody (times the square root of the centre weight). The instrumental
// is the mix minus the vocals.
nonisolated struct Separation: Sendable {
    static let fftSize = 4096
    static let hop = 512
    static let maskFrequency = 11_000.0
    // The reference's description of this method (it also offers Demucs).
    static let method = "harmonisch masker + stereo-midden (geen Demucs beschikbaar)"

    var melody: MelodyTrack
    // Mono; the vocal stem has it in both channels.
    var vocals: [Double]
    var instrumental: StereoAudio

    init(_ audio: StereoAudio) {
        let rate = StereoAudio.sampleRate
        let side = vDSP.divide(vDSP.subtract(audio.left, audio.right), 2)
        var mid = Spectrogram(audio.mid, sampleRate: rate, size: Self.fftSize, hop: Self.hop)
        let sideMagnitude = Spectrogram(side, sampleRate: rate, size: Self.fftSize, hop: Self.hop).magnitudes()
        let midMagnitude = mid.magnitudes()

        // 1 in the centre of the stereo image, 0 at or past half side.
        let centre = zip(midMagnitude, sideMagnitude).map { m, s in
            min(1, max(0, (1 - s / (m + s + 1e-12) - 0.5) * 2))
        }
        melody = Melody.track(
            magnitude: vDSP.multiply(midMagnitude, centre), frameCount: mid.frameCount, binCount: mid.binCount,
            binWidth: mid.binWidth, hopSeconds: Double(Self.hop) / rate)

        let mask = vDSP.multiply(
            Self.harmonicMask(
                f0: melody.f0, voiced: melody.voiced, binCount: mid.binCount, binWidth: mid.binWidth,
                maxFrequency: Self.maskFrequency),
            vForce.sqrt(centre))
        mid.real = vDSP.multiply(mid.real, mask)
        mid.imag = vDSP.multiply(mid.imag, mask)
        var vocals = mid.inverse()
        vocals = vocals.count >= audio.frameCount
            ? Array(vocals.prefix(audio.frameCount))
            : vocals + [Double](repeating: 0, count: audio.frameCount - vocals.count)
        self.vocals = vocals
        instrumental = StereoAudio(left: vDSP.subtract(audio.left, vocals), right: vDSP.subtract(audio.right, vocals))
    }

    // Frame-major mask: around every harmonic h·f0 a Gaussian of width
    // max(Δf, 2.5 % of h·f0), the maximum over harmonics, zero in unvoiced
    // frames and above `maxFrequency`. Like the reference, every chunk of 2000
    // frames takes harmonics until all its frames are past `maxFrequency`, so
    // the tails of a frame's higher harmonics still reach below it.
    static func harmonicMask(
        f0: [Double], voiced: [Bool], binCount: Int, binWidth: Double, maxFrequency: Double
    ) -> [Double] {
        let frames = f0.count
        let bins = (0..<binCount).prefix { Double($0) * binWidth <= maxFrequency }.count
        let harmonicLimit = Int(maxFrequency / Melody.lowestFrequency)
        var mask = [Double](repeating: 0, count: frames * binCount)
        mask.withUnsafeMutableBufferPointer { mask in
            for chunkStart in stride(from: 0, to: frames, by: 2000) {
                let chunk = chunkStart ..< min(frames, chunkStart + 2000)
                let lowest = f0[chunk].min()!
                let harmonics = (1...harmonicLimit).prefix { Double($0) * lowest <= maxFrequency }.count
                for t in chunk where voiced[t] {
                    let row = mask.baseAddress! + t * binCount
                    for h in stride(from: 1, through: harmonics, by: 1) {
                        let centre = Double(h) * f0[t]
                        let width = max(binWidth, 0.025 * centre)
                        // Further than 10 widths the Gaussian is below 1e-21.
                        let low = max(0, Int(((centre - 10 * width) / binWidth).rounded(.up)))
                        let high = min(bins - 1, Int(((centre + 10 * width) / binWidth).rounded(.down)))
                        var k = low
                        while k <= high {
                            let z = (Double(k) * binWidth - centre) / width
                            let value = exp(-0.5 * (z * z))
                            if value > row[k] { row[k] = value }
                            k += 1
                        }
                    }
                }
            }
        }
        return mask
    }
}
