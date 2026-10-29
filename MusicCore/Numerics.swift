import Accelerate
import Foundation

// numpy and scipy behaviour the reference depends on, reproduced exactly so
// the port can be compared with it step by step.
nonisolated enum Numerics {
    // numpy.percentile with the default 'linear' method.
    static func percentile(_ values: [Double], _ q: Double) -> Double {
        precondition(!values.isEmpty, "percentile of an empty array")
        var sorted = values
        vDSP.sort(&sorted, sortOrder: .ascending)
        let position = Double(sorted.count - 1) * (q / 100)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let gamma = position - Double(lower)
        let difference = sorted[upper] - sorted[lower]
        // numpy's _lerp: interpolate from the nearer end.
        return gamma >= 0.5 ? sorted[upper] - difference * (1 - gamma) : sorted[lower] + difference * gamma
    }

    static func median(_ values: [Double]) -> Double {
        precondition(!values.isEmpty, "median of an empty array")
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    static func mean(_ values: [Double]) -> Double { vDSP.mean(values) }

    // Population standard deviation (numpy's default ddof = 0).
    static func standardDeviation(_ values: [Double]) -> Double {
        let deviations = vDSP.add(-mean(values), values)
        return (vDSP.sumOfSquares(deviations) / Double(values.count)).squareRoot()
    }

    // np.corrcoef(x, y)[0, 1], clipped to [-1, 1].
    static func correlation(_ x: [Double], _ y: [Double]) -> Double {
        let dx = vDSP.add(-mean(x), x), dy = vDSP.add(-mean(y), y)
        let n = Double(x.count - 1)
        let covariance = vDSP.dot(dx, dy) / n
        let sx = (vDSP.sumOfSquares(dx) / n).squareRoot(), sy = (vDSP.sumOfSquares(dy) / n).squareRoot()
        return min(1, max(-1, covariance / sx / sy))
    }

    // scipy.signal.medfilt: median of `kernel` neighbours, zeros outside.
    static func medianFilter(_ x: [Double], kernel: Int) -> [Double] {
        precondition(kernel % 2 == 1, "medfilt needs an odd kernel")
        let radius = kernel / 2
        var window = [Double](repeating: 0, count: kernel)
        return x.indices.map { i in
            for j in 0..<kernel {
                let k = i - radius + j
                window[j] = k >= 0 && k < x.count ? x[k] : 0
            }
            window.sort()
            return window[radius]
        }
    }

    // First index of the maximum (np.argmax).
    static func argmax(_ values: UnsafeBufferPointer<Double>) -> Int {
        var best = 0
        for i in values.indices where values[i] > values[best] { best = i }
        return best
    }

    static func argmax(_ values: [Double]) -> Int { values.withUnsafeBufferPointer(argmax) }

    // scipy.signal.resample_poly(x, 1, 2): the 41-tap firwin low-pass at half
    // the input band (Kaiser window, β = 5), zeros outside the signal, output
    // sample m centred on input sample 2m.
    static func halveSampleRate(_ x: [Double]) -> [Double] {
        let taps = halfBandFilter
        let radius = taps.count / 2
        let outputCount = (x.count + 1) / 2
        guard outputCount > 0 else { return [] }
        var padded = [Double](repeating: 0, count: x.count + 2 * radius)
        padded.replaceSubrange(radius ..< radius + x.count, with: x)
        var output = [Double](repeating: 0, count: outputCount)
        // The filter is symmetric, so vDSP's correlation is the convolution.
        vDSP_desampD(padded, 2, taps, &output, vDSP_Length(outputCount), vDSP_Length(taps.count))
        return output
    }

    static let halfBandFilter: [Double] = {
        let count = 41, beta = 5.0, cutoff = 0.5
        let alpha = 0.5 * Double(count - 1)
        let taps = (0..<count).map { n -> Double in
            let m = Double(n) - alpha
            let y = Double.pi * (cutoff * m)
            let sinc = m == 0 ? 1 : sin(y) / y
            let kaiser = besselI0(beta * (1 - pow(m / alpha, 2)).squareRoot()) / besselI0(beta)
            return cutoff * sinc * kaiser
        }
        let sum = taps.reduce(0, +)
        return taps.map { $0 / sum }
    }()

    // Modified Bessel function of the first kind, order 0 (power series).
    static func besselI0(_ x: Double) -> Double {
        let quarterSquare = x * x / 4
        var sum = 1.0, term = 1.0
        for k in 1...200 {
            term *= quarterSquare / Double(k * k)
            sum += term
            if term < sum * 1e-17 { break }
        }
        return sum
    }
}

nonisolated extension Double {
    // Python's round(x, digits): the correctly rounded decimal, ties to even.
    func rounded(digits: Int) -> Double {
        Double(String(format: "%.*f", Int32(digits), self)) ?? self
    }

    // Python's round(x) and numpy's round: ties to even.
    var roundedHalfEven: Double { rounded(.toNearestOrEven) }
}
