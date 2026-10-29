import Accelerate
import Foundation

// Tempo and beats from the reference's `onset_envelope`, `estimate_tempo` and
// `track_beats`, on the mix at 22.05 kHz.
nonisolated enum BeatTracker {
    static let sampleRate = 22_050.0
    static let fftSize = 2048
    static let hop = 256

    struct Result: Sendable {
        var envelope: [Double]
        var framesPerSecond: Double
        var bpm: Double
        // Seconds.
        var beats: [Double]
    }

    // `signal` is mono at 22.05 kHz. With more than three beats the tempo is
    // the median beat interval, otherwise the autocorrelation estimate.
    static func analyse(_ signal: [Double]) -> Result {
        let (envelope, fps) = onsetEnvelope(signal)
        var bpm = tempo(envelope, framesPerSecond: fps)
        let beats = beats(envelope, framesPerSecond: fps, bpm: bpm)
        if beats.count > 3 {
            bpm = 60 / Numerics.median(zip(beats.dropFirst(), beats).map { $0 - $1 })
        }
        return Result(envelope: envelope, framesPerSecond: fps, bpm: bpm, beats: beats)
    }

    // Spectral flux: the mean positive change of log(1 + 1000·|Z|) per frame,
    // minus its 31-frame median, clipped at zero and divided by its standard
    // deviation. One value per hop (86 per second).
    static func onsetEnvelope(_ signal: [Double]) -> (envelope: [Double], framesPerSecond: Double) {
        let spectrogram = Spectrogram(signal, sampleRate: sampleRate, size: fftSize, hop: hop)
        let bins = spectrogram.binCount, frames = spectrogram.frameCount
        let compressed = spectrogram.magnitudes().map { log1p(1000 * $0) }
        var flux = [Double](repeating: 0, count: frames)
        compressed.withUnsafeBufferPointer { compressed in
            let s = compressed.baseAddress!
            for t in 1..<max(1, frames) {
                var sum = 0.0, k = 0
                while k < bins {
                    let rise = s[t * bins + k] - s[(t - 1) * bins + k]
                    if rise > 0 { sum += rise }
                    k += 1
                }
                flux[t] = sum / Double(bins)
            }
        }
        if flux.count >= 31 {
            flux = vDSP.subtract(flux, Numerics.medianFilter(flux, kernel: 31))
        } else {
            flux = vDSP.add(-Numerics.mean(flux), flux)
        }
        flux = flux.map { max($0, 0) }
        let deviation = Numerics.standardDeviation(flux) + 1e-9
        return (flux.map { $0 / deviation }, sampleRate / Double(hop))
    }

    // The autocorrelation lag between 60 and 200 BPM with the highest score,
    // weighted by a log-Gaussian (one octave wide) around 120 BPM and refined
    // parabolically.
    static func tempo(_ envelope: [Double], framesPerSecond fps: Double, lowest: Double = 60, highest: Double = 200) -> Double {
        let centred = vDSP.add(-Numerics.mean(envelope), envelope)
        let lags = Array(Int(60 * fps / highest)...Int(60 * fps / lowest)).filter { $0 < centred.count - 1 }
        guard !lags.isEmpty else { return 120 }
        let scores = lags.map { lag -> Double in
            let correlation = vDSP.dot(Array(centred[lag...]), Array(centred[..<(centred.count - lag)]))
            let octaves = log2(60 * fps / Double(lag) / 120) / 1.0
            return correlation * exp(-0.5 * (octaves * octaves))
        }
        let k = Numerics.argmax(scores)
        var lag = Double(lags[k])
        if k >= 1 && k < lags.count - 1 {
            let a = scores[k - 1], b = scores[k], c = scores[k + 1]
            let denominator = a - 2 * b + c
            if abs(denominator) > 1e-12 { lag += 0.5 * (a - c) / denominator }
        }
        return 60 * fps / lag
    }

    // Dynamic-programming beat tracking (Ellis 2007): onset strength smoothed
    // around each frame, plus the best earlier beat 0.5–2 periods back,
    // penalised by tightness · log(interval / period)². The weak beats at
    // either end are trimmed. Times in seconds.
    static func beats(_ envelope: [Double], framesPerSecond fps: Double, bpm: Double, tightness: Double = 100) -> [Double] {
        let period = 60 * fps / bpm
        // np.arange(-period, period + 1), which steps by (start + 1) − start.
        let step = (-period + 1) - -period
        let windowCount = Int(((period + 1 - -period) / 1).rounded(.up))
        let window = (0..<windowCount).map { i -> Double in
            let x = (-period + Double(i) * step) * 32 / period
            return exp(-0.5 * (x * x))
        }
        let local = convolveSame(envelope, window)
        let n = local.count
        guard n > 0 else { return [] }

        var cumulative = [Double](repeating: 0, count: n)
        var previous = [Int](repeating: -1, count: n)
        let farthest = Int((2 * period).roundedHalfEven), nearest = Int((period / 2).roundedHalfEven)
        for i in 0..<n {
            let low = i - farthest, high = i - nearest
            guard high >= 0 else {
                cumulative[i] = local[i]
                continue
            }
            var best = -Double.infinity, from = max(0, low)
            for p in max(0, low)...high {
                let interval = log(Double(i - p) / period)
                let score = cumulative[p] - tightness * (interval * interval)
                if score > best {
                    best = score
                    from = p
                }
            }
            cumulative[i] = local[i] + best
            previous[i] = from
        }

        let tail = max(0, n - Int(period))
        var i = tail + Numerics.argmax(Array(cumulative[tail...]))
        var beats: [Int] = []
        while i >= 0 {
            beats.append(i)
            i = previous[i]
        }
        beats.reverse()

        let threshold = 0.5 * Numerics.median(beats.map { local[$0] })
        if let first = beats.firstIndex(where: { local[$0] > threshold }),
           let last = beats.lastIndex(where: { local[$0] > threshold }) {
            beats = Array(beats[first...last])
        }
        return beats.map { Double($0) / fps }
    }

    // np.convolve(signal, kernel, 'same') for a kernel no longer than the
    // signal: the full convolution from (kernel.count − 1) / 2 on.
    static func convolveSame(_ signal: [Double], _ kernel: [Double]) -> [Double] {
        guard kernel.count <= signal.count else { return convolveSame(kernel, signal) }
        let offset = (kernel.count - 1) / 2
        return signal.indices.map { i in
            let p = i + offset
            var sum = 0.0
            for j in max(0, p - signal.count + 1)...min(kernel.count - 1, p) {
                sum += signal[p - j] * kernel[j]
            }
            return sum
        }
    }
}
