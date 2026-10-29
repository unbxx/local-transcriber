import Accelerate
import Foundation

// Loudness and timbre from the reference's `loudness` and `timbre`.
nonisolated enum LoudnessMeter {
    // BS.1770-style integrated loudness: K-weighting (a +4 dB shelf at
    // 1.5 kHz and a 38 Hz high-pass, as the reference designs them), 400 ms
    // blocks every 100 ms summed over both channels, an absolute gate at
    // −70 LUFS and a relative gate 10 LU below. The loudness range is the
    // spread (10th to 95th percentile) of 3 s blocks every second.
    static func loudness(_ audio: StereoAudio) -> MusicAnalysis.Loudness {
        let rate = StereoAudio.sampleRate
        let block = Int(0.4 * rate), step = Int(0.1 * rate)
        guard audio.frameCount >= block else { return MusicAnalysis.Loudness() }

        // Running sums of the squared K-weighted signal, starting at 0.
        func runningEnergy(_ channel: [Double]) -> [Double] {
            var sum = 0.0
            var sums: [Double] = [0]
            sums.reserveCapacity(channel.count + 1)
            for sample in kWeighted(channel, sampleRate: rate) {
                sum += sample * sample
                sums.append(sum)
            }
            return sums
        }
        let channels = [runningEnergy(audio.left), runningEnergy(audio.right)]
        func meanSquares(length: Int, every hop: Int) -> [Double] {
            stride(from: 0, through: audio.frameCount - length, by: hop).map { start in
                channels.reduce(0.0) { $0 + ($1[start + length] - $1[start]) / Double(length) }
            }
        }
        func lufs(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(meanSquare + 1e-12) }
        func ungatedLUFS(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(meanSquare) }

        let blocks = meanSquares(length: block, every: step)
        let levels = blocks.map(lufs)
        var integrated: Double?
        let audible = zip(blocks, levels).filter { $1 > -70 }.map(\.0)
        if !audible.isEmpty {
            let relativeGate = ungatedLUFS(Numerics.mean(audible)) - 10
            let gated = zip(blocks, levels).filter { $1 > -70 && $1 > relativeGate }.map(\.0)
            integrated = ungatedLUFS(Numerics.mean(gated))
        }

        var shortTerm: [Double] = []
        let shortBlock = Int(3 * rate)
        if audio.frameCount >= shortBlock {
            shortTerm = meanSquares(length: shortBlock, every: Int(rate)).map(lufs).filter { $0 > -70 }
        }

        let peak = max(vDSP.maximumMagnitude(audio.left), vDSP.maximumMagnitude(audio.right))
        let rms = ((vDSP.sumOfSquares(audio.left) + vDSP.sumOfSquares(audio.right)) / Double(2 * audio.frameCount))
            .squareRoot()
        return MusicAnalysis.Loudness(
            lufsIntegrated: integrated?.rounded(digits: 1),
            loudnessRangeLU: shortTerm.count > 2
                ? (Numerics.percentile(shortTerm, 95) - Numerics.percentile(shortTerm, 10)).rounded(digits: 1) : nil,
            peakDBFS: (20 * log10(peak + 1e-12)).rounded(digits: 1),
            rmsDBFS: (20 * log10(rms + 1e-12)).rounded(digits: 1),
            crestFactorDB: (20 * log10((peak + 1e-12) / (rms + 1e-12))).rounded(digits: 1))
    }

    static func kWeighted(_ x: [Double], sampleRate: Double) -> [Double] {
        // RBJ high shelf: +4 dB at 1500 Hz, Q = 1/√2.
        let gain = pow(10, 4.0 / 40), q = 1 / 2.0.squareRoot()
        var w0 = 2 * Double.pi * 1500 / sampleRate
        var alpha = sin(w0) / (2 * q), c = cos(w0)
        let rootGain = gain.squareRoot()
        let shelf = biquad(
            x,
            b: [
                gain * ((gain + 1) + (gain - 1) * c + 2 * rootGain * alpha),
                -2 * gain * ((gain - 1) + (gain + 1) * c),
                gain * ((gain + 1) + (gain - 1) * c - 2 * rootGain * alpha),
            ],
            a: [
                (gain + 1) - (gain - 1) * c + 2 * rootGain * alpha,
                2 * ((gain - 1) - (gain + 1) * c),
                (gain + 1) - (gain - 1) * c - 2 * rootGain * alpha,
            ])
        // RBJ high-pass at 38 Hz, Q = 0.5.
        w0 = 2 * Double.pi * 38 / sampleRate
        alpha = sin(w0) / (2 * 0.5)
        c = cos(w0)
        return biquad(shelf, b: [(1 + c) / 2, -(1 + c), (1 + c) / 2], a: [1 + alpha, -2 * c, 1 - alpha])
    }

    // scipy.signal.lfilter for a biquad (transposed direct form II,
    // coefficients divided by a[0], zero initial state).
    static func biquad(_ x: [Double], b: [Double], a: [Double]) -> [Double] {
        let b0 = b[0] / a[0], b1 = b[1] / a[0], b2 = b[2] / a[0]
        let a1 = a[1] / a[0], a2 = a[2] / a[0]
        var output = [Double](repeating: 0, count: x.count)
        var z0 = 0.0, z1 = 0.0
        x.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                let x = input.baseAddress!, y = output.baseAddress!
                var n = 0
                while n < input.count {
                    let value = z0 + b0 * x[n]
                    z0 = z1 + x[n] * b1 - value * a1
                    z1 = x[n] * b2 - value * a2
                    y[n] = value
                    n += 1
                }
            }
        }
        return output
    }
}

nonisolated enum TimbreAnalysis {
    // From the power spectrum of the mid signal (4096-point frames, hop
    // 1024): the median spectral centroid, the share of energy per band, the
    // median spectral flatness (DC excluded), and the stereo width (side RMS
    // over mid RMS) and L/R correlation.
    static func timbre(_ audio: StereoAudio) -> MusicAnalysis.Timbre {
        let spectrogram = Spectrogram(audio.mid, sampleRate: StereoAudio.sampleRate, size: 4096, hop: 1024)
        let bins = spectrogram.binCount, frames = spectrogram.frameCount
        let power = spectrogram.magnitudes().map { $0 * $0 }
        let total = vDSP.sum(power) + 1e-12

        let distribution = MusicAnalysis.Timbre.bands.map { band in
            var sum = 0.0
            for k in 0..<bins where band.range.contains(spectrogram.frequency(ofBin: k)) {
                for t in 0..<frames { sum += power[t * bins + k] }
            }
            return (100 * sum / total).rounded(digits: 1)
        }

        var centroids = [Double](repeating: 0, count: frames)
        var flatness = [Double](repeating: 0, count: frames)
        for t in 0..<frames {
            let frame = power[t * bins ..< (t + 1) * bins]
            var weighted = 0.0, logSum = 0.0, sum = 0.0
            for (k, p) in zip(0..., frame) {
                weighted += spectrogram.frequency(ofBin: k) * p
                guard k > 0 else { continue }
                logSum += log(p + 1e-12)
                sum += p
            }
            centroids[t] = weighted / (frame.reduce(0, +) + 1e-12)
            let count = Double(bins - 1)
            flatness[t] = exp(logSum / count) / (sum / count + 1e-12)
        }

        let side = vDSP.subtract(audio.left, audio.right), sum = vDSP.add(audio.left, audio.right)
        let n = Double(audio.frameCount)
        let width = (vDSP.sumOfSquares(side) / n).squareRoot() / ((vDSP.sumOfSquares(sum) / n).squareRoot() + 1e-12)
        let correlated = Numerics.standardDeviation(audio.left) > 0 && Numerics.standardDeviation(audio.right) > 0
        return MusicAnalysis.Timbre(
            spectralCentroidHz: Int(Numerics.median(centroids).roundedHalfEven),
            energyDistributionPct: distribution,
            spectralFlatness: Numerics.median(flatness).rounded(digits: 4),
            stereoWidth: width.rounded(digits: 3),
            stereoCorrelation: correlated ? Numerics.correlation(audio.left, audio.right).rounded(digits: 3) : 1)
    }
}
