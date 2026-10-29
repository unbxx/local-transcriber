import Accelerate
import Foundation

// One value per spectrogram frame (hop 512 at 44.1 kHz, 11.6 ms).
nonisolated struct MelodyTrack: Sendable {
    var times: [Double]
    var f0: [Double]
    var voiced: [Bool]
    var salience: [Double]
}

// The predominant melody, from the reference's `melody_f0`: the harmonic
// salience of candidate pitches 75–1050 Hz in 10-cent steps, a Viterbi path
// through them (small steps are cheap, jumps cost a fixed price) and voicing
// where the path's salience is above 35 % of its 90th percentile.
nonisolated enum Melody {
    static let lowestFrequency = 75.0
    static let highestFrequency = 1050.0
    static let candidateStepCents = 10.0
    static let harmonicCount = 12
    static let harmonicWeight = 0.82
    static let analysedFrequency = 5500.0
    static let maxStep = 30
    static let stepPenalty = 0.004
    static let jumpPenalty = 0.12

    static let candidates: [Double] = {
        let stop = 1200 * log2(highestFrequency / lowestFrequency)
        let count = Int((stop / candidateStepCents).rounded(.up))
        return (0..<count).map { lowestFrequency * pow(2, Double($0) * candidateStepCents / 1200) }
    }()

    // `magnitude` is frame-major like `Spectrogram`.
    static func track(
        magnitude: [Double], frameCount: Int, binCount: Int, binWidth: Double, hopSeconds: Double
    ) -> MelodyTrack {
        let salience = harmonicSalience(magnitude: magnitude, frameCount: frameCount, binCount: binCount, binWidth: binWidth)
        let candidateCount = candidates.count
        let path = viterbi(salience, frameCount: frameCount, candidateCount: candidateCount)

        var pathSalience = [Double](repeating: 0, count: frameCount)
        var f0 = [Double](repeating: 0, count: frameCount)
        for t in 0..<frameCount {
            let row = t * candidateCount, c = path[t]
            pathSalience[t] = salience[row + c]
            // Parabolic sub-step refinement around the path.
            var position = Double(c)
            if c > 0 && c < candidateCount - 1 {
                let a = salience[row + c - 1], b = pathSalience[t], d = salience[row + c + 1]
                let denominator = a - 2 * b + d
                if abs(denominator) > 1e-12 { position += min(0.5, max(-0.5, 0.5 * (a - d) / denominator)) }
            }
            f0[t] = lowestFrequency * pow(2, position * candidateStepCents / 1200)
        }

        let threshold = 0.35 * Numerics.percentile(pathSalience, 90)
        let voiced = Numerics.medianFilter(pathSalience.map { $0 > threshold ? 1 : 0 }, kernel: 5).map { $0 > 0.5 }
        return MelodyTrack(
            times: (0..<frameCount).map { Double($0) * hopSeconds }, f0: f0, voiced: voiced, salience: pathSalience)
    }

    // Frame-major salience (frame × candidate): the sum of 12 harmonics with
    // weight 0.82^(h−1), read between bins by linear interpolation, from the
    // log-compressed magnitude up to 5.5 kHz with the bass damped below 250 Hz.
    // Normalised by the 98th percentile of the per-frame maximum.
    static func harmonicSalience(magnitude: [Double], frameCount: Int, binCount: Int, binWidth: Double) -> [Double] {
        let bins = (0..<binCount).prefix { Double($0) * binWidth <= analysedFrequency }.count
        var weighted = [Double](repeating: 0, count: frameCount * bins)
        for t in 0..<frameCount {
            for k in 0..<bins {
                weighted[t * bins + k] = magnitude[t * binCount + k] * min(1, max(0.25, Double(k) * binWidth / 250))
            }
        }
        let scale = 1000 / (Numerics.percentile(weighted, 99.5) + 1e-12)
        let compressed = weighted.map { log1p($0 * scale) }

        // Bin × candidate weights (the reference's A, transposed).
        let candidateCount = candidates.count
        var weights = [Double](repeating: 0, count: bins * candidateCount)
        for h in 1...harmonicCount {
            let weight = pow(harmonicWeight, Double(h - 1))
            for (c, candidate) in candidates.enumerated() {
                let k = Double(h) * candidate / binWidth
                guard k < Double(bins - 1) else { continue }
                let k0 = Int(k.rounded(.down)), fraction = k - Double(k0)
                weights[k0 * candidateCount + c] += weight * (1 - fraction)
                weights[(k0 + 1) * candidateCount + c] += weight * fraction
            }
        }

        var salience = [Double](repeating: 0, count: frameCount * candidateCount)
        vDSP_mmulD(
            compressed, 1, weights, 1, &salience, 1,
            vDSP_Length(frameCount), vDSP_Length(candidateCount), vDSP_Length(bins))

        let frameMaxima = (0..<frameCount).map { t in
            salience[t * candidateCount ..< (t + 1) * candidateCount].max() ?? 0
        }
        let norm = Numerics.percentile(frameMaxima, 98) + 1e-12
        return vDSP.divide(salience, norm)
    }

    // Best candidate per frame. Moving s candidates costs 0.004·s within ±30
    // (vibrato, glides); any larger jump costs 0.12 from the best previous
    // candidate. Ties go to the first candidate, as with np.argmax.
    static func viterbi(_ salience: [Double], frameCount: Int, candidateCount: Int) -> [Int] {
        guard frameCount > 0 else { return [] }
        let count = candidateCount, maxStep = maxStep, jumpPenalty = jumpPenalty
        var back = [Int16](repeating: 0, count: frameCount * count)
        let penalties = (-maxStep...maxStep).map { stepPenalty * Double(abs($0)) }
        var score = UnsafeMutablePointer<Double>.allocate(capacity: count)
        var next = UnsafeMutablePointer<Double>.allocate(capacity: count)
        defer { score.deallocate(); next.deallocate() }

        // Raw pointers and while loops: this runs ~50 million times per
        // minute of audio, and `swift test` builds without optimisation.
        salience.withUnsafeBufferPointer { salienceBuffer in
            penalties.withUnsafeBufferPointer { penaltyBuffer in
                back.withUnsafeMutableBufferPointer { backBuffer in
                    let salience = salienceBuffer.baseAddress!, penalties = penaltyBuffer.baseAddress!
                    let back = backBuffer.baseAddress!
                    score.update(from: salience, count: count)
                    var t = 1
                    while t < frameCount {
                        var best = 0, i = 1
                        while i < count {
                            if score[i] > score[best] { best = i }
                            i += 1
                        }
                        let jump = score[best] - jumpPenalty
                        let row = t * count
                        var c = 0
                        while c < count {
                            var j = c > maxStep ? c - maxStep : 0
                            let last = c + maxStep < count ? c + maxStep : count - 1
                            var local = -Double.infinity, from = c
                            while j <= last {
                                let value = score[j] - penalties[j - c + maxStep]
                                if value > local {
                                    local = value
                                    from = j
                                }
                                j += 1
                            }
                            back[row + c] = Int16(truncatingIfNeeded: jump > local ? best : from)
                            next[c] = (jump > local ? jump : local) + salience[row + c]
                            c += 1
                        }
                        swap(&score, &next)
                        t += 1
                    }
                }
            }
        }

        var path = [Int](repeating: 0, count: frameCount)
        path[frameCount - 1] = Numerics.argmax(UnsafeBufferPointer(start: score, count: count))
        for t in stride(from: frameCount - 1, to: 0, by: -1) {
            path[t - 1] = Int(back[t * count + path[t]])
        }
        return path
    }
}
