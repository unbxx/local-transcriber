import Foundation
import Testing
@testable import MusicCore

// Expected values were computed with numpy 2.0.2 and scipy 1.13.1, the
// libraries the reference implementation runs on.
struct NumericsTests {
    private let ramp = (0..<1000).map { sin(0.1 * Double($0)) + 0.01 * Double($0) }

    @Test func realFFTMatchesTheDFTAndInvertsIt() {
        let n = 16
        let x = (0..<n).map { cos(0.7 * Double($0)) + 0.3 * Double($0 % 5) }
        let fft = RealFFT(size: n)
        var real = [Double](repeating: 0, count: n / 2 + 1), imag = real
        fft.forward(x, real: &real, imag: &imag)
        for k in 0...(n / 2) {
            let angle = { (j: Int) in -2 * Double.pi * Double(k * j) / Double(n) }
            let expectedReal = (0..<n).reduce(0.0) { $0 + x[$1] * cos(angle($1)) }
            let expectedImag = (0..<n).reduce(0.0) { $0 + x[$1] * sin(angle($1)) }
            #expect(abs(real[k] - expectedReal) < 1e-12)
            #expect(abs(imag[k] - expectedImag) < 1e-12)
        }
        var back = [Double](repeating: 0, count: n)
        fft.inverse(real: real, imag: imag, output: &back)
        #expect(zip(back, x).allSatisfy { abs($0 - $1) < 1e-12 })
    }

    @Test func spectrogramMatchesScipySTFT() {
        let spectrogram = Spectrogram(ramp, sampleRate: 8000, size: 256, hop: 64)
        #expect(spectrogram.frameCount == 17)
        #expect(spectrogram.binCount == 129)
        #expect(spectrogram.binWidth == 31.25)
        #expect(abs(spectrogram.time(ofFrame: 5) - 0.04) < 1e-15)
        func bin(_ k: Int, _ t: Int) -> (Double, Double) {
            (spectrogram.real[t * 129 + k], spectrogram.imag[t * 129 + k])
        }
        #expect(abs(bin(7, 10).0 - 0.0015076390841405564) < 1e-15)
        #expect(abs(bin(7, 10).1 - -0.0018761736263304294) < 1e-15)
        #expect(abs(bin(0, 0).0 - 0.27330209623436735) < 1e-15)
        #expect(abs(bin(128, 3).0 - 2.3458707198997786e-09) < 1e-15)
    }

    @Test func inverseSpectrogramReconstructsTheSignal() {
        let restored = Spectrogram(ramp, sampleRate: 8000, size: 256, hop: 64).inverse()
        #expect(restored.count == 1024)
        #expect(zip(restored, ramp).allSatisfy { abs($0 - $1) < 1e-12 })
    }

    @Test func halvingTheSampleRateMatchesResamplePoly() {
        let halved = Numerics.halveSampleRate(ramp)
        #expect(halved.count == 500)
        #expect(abs(halved[0] - 0.017360750628269472) < 1e-13)
        #expect(abs(halved[1] - 0.21593634506261788) < 1e-13)
        #expect(abs(halved[250] - 4.737423788676336) < 1e-13)
        #expect(abs(halved[499] - 9.948943544224855) < 1e-13)
        let odd = Numerics.halveSampleRate(Array(ramp.prefix(999)))
        #expect(odd.count == 500)
        #expect(abs(odd[499] - 6.971936276693034) < 1e-13)
    }

    @Test func percentilesAndMediansMatchNumpy() {
        let values = (0..<101).map { cos(Double($0) * 1.7) * 10 }
        #expect(abs(Numerics.percentile(values, 99.5) - 9.99956030051586) < 1e-13)
        #expect(abs(Numerics.percentile(values, 90) - 9.555985806128394) < 1e-13)
        #expect(abs(Numerics.percentile(values, 10) - -9.471532884219778) < 1e-13)
        #expect(abs(Numerics.median(values) - 0.2035084333168298) < 1e-13)
        #expect(abs(Numerics.median(Array(values.prefix(100))) - 0.13720483565125385) < 1e-13)
    }

    @Test func medianFilterPadsWithZerosLikeMedfilt() {
        #expect(Numerics.medianFilter([5, 1, 4, 2, 8, 3, 9, 7], kernel: 5) == [1, 2, 4, 3, 4, 7, 7, 3])
    }

    @Test func roundingFollowsPython() {
        #expect(0.25.rounded(digits: 1) == 0.2)
        #expect(0.35.rounded(digits: 1) == 0.3)
        #expect(2.675.rounded(digits: 2) == 2.67)
        #expect(-1.25.rounded(digits: 1) == -1.2)
        #expect(13.05.rounded(digits: 1) == 13.1)
        #expect(2.5.roundedHalfEven == 2)
    }
}
