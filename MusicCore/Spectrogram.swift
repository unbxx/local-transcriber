import Accelerate
import Foundation

// Real FFT of a power-of-two size with numpy's `rfft`/`irfft` scaling. vDSP's
// packed real FFT returns twice the DFT and keeps the Nyquist bin in imag[0].
nonisolated final class RealFFT {
    let size: Int
    private let half: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetupD
    private var packedReal: [Double]
    private var packedImag: [Double]

    init(size: Int) {
        precondition(size >= 4 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        half = size / 2
        log2n = vDSP_Length(size.trailingZeroBitCount)
        setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!
        packedReal = [Double](repeating: 0, count: half)
        packedImag = [Double](repeating: 0, count: half)
    }

    deinit { vDSP_destroy_fftsetupD(setup) }

    // rfft: `size` samples in, bins 0...size/2 out.
    func forward(_ input: UnsafePointer<Double>, real: UnsafeMutablePointer<Double>, imag: UnsafeMutablePointer<Double>) {
        packedReal.withUnsafeMutableBufferPointer { packedReal in
            packedImag.withUnsafeMutableBufferPointer { packedImag in
                var split = DSPDoubleSplitComplex(realp: packedReal.baseAddress!, imagp: packedImag.baseAddress!)
                input.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) {
                    vDSP_ctozD($0, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                var scale = 0.5
                vDSP_vsmulD(split.realp, 1, &scale, real, 1, vDSP_Length(half))
                vDSP_vsmulD(split.imagp, 1, &scale, imag, 1, vDSP_Length(half))
            }
        }
        real[half] = imag[0]
        imag[0] = 0
        imag[half] = 0
    }

    // irfft: bins 0...size/2 in (the imaginary parts of DC and Nyquist are
    // ignored), `size` samples out.
    func inverse(real: UnsafePointer<Double>, imag: UnsafePointer<Double>, output: UnsafeMutablePointer<Double>) {
        packedReal.withUnsafeMutableBufferPointer { packedReal in
            packedImag.withUnsafeMutableBufferPointer { packedImag in
                packedReal.baseAddress!.update(from: real, count: half)
                packedImag.baseAddress!.update(from: imag, count: half)
                packedImag[0] = real[half]
                var split = DSPDoubleSplitComplex(realp: packedReal.baseAddress!, imagp: packedImag.baseAddress!)
                vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                output.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) {
                    vDSP_ztocD(&split, 1, $0, 2, vDSP_Length(half))
                }
            }
        }
        var scale = 1 / Double(size)
        vDSP_vsmulD(output, 1, &scale, output, 1, vDSP_Length(size))
    }
}

// scipy.signal.stft as the reference calls it: periodic Hann window, size/2
// zeros on both sides (boundary='zeros'), zeros at the end up to a whole
// number of hops (padded=True) and 'spectrum' scaling (divided by the window
// sum). Frame t is centred on input sample t·hop. Storage is frame-major: bin
// k of frame t is at t * binCount + k.
nonisolated struct Spectrogram: Sendable {
    let size: Int
    let hop: Int
    let sampleRate: Double
    let frameCount: Int
    var real: [Double]
    var imag: [Double]

    var binCount: Int { size / 2 + 1 }
    // numpy's rfftfreq spacing, 1 / (n · (1 / fs)).
    var binWidth: Double { 1 / (Double(size) * (1 / sampleRate)) }

    init(_ signal: [Double], sampleRate: Double, size: Int, hop: Int) {
        self.size = size
        self.hop = hop
        self.sampleRate = sampleRate
        let n = signal.count
        let extra = (hop - n % hop) % hop % size
        let frameCount = (n + extra) / hop + 1
        self.frameCount = frameCount

        var padded = [Double](repeating: 0, count: n + size + extra)
        padded.replaceSubrange(size / 2 ..< size / 2 + n, with: signal)
        let window = Self.hannWindow(size)
        let windowSum = vDSP.sum(window)
        var scale = (1 / (windowSum * windowSum)).squareRoot()
        let binCount = size / 2 + 1

        let fft = RealFFT(size: size)
        var real = [Double](repeating: 0, count: frameCount * binCount)
        var imag = [Double](repeating: 0, count: frameCount * binCount)
        var segment = [Double](repeating: 0, count: size)
        padded.withUnsafeBufferPointer { padded in
            real.withUnsafeMutableBufferPointer { real in
                imag.withUnsafeMutableBufferPointer { imag in
                    for t in 0..<frameCount {
                        vDSP_vmulD(padded.baseAddress! + t * hop, 1, window, 1, &segment, 1, vDSP_Length(size))
                        fft.forward(segment, real: real.baseAddress! + t * binCount, imag: imag.baseAddress! + t * binCount)
                    }
                    vDSP_vsmulD(real.baseAddress!, 1, &scale, real.baseAddress!, 1, vDSP_Length(real.count))
                    vDSP_vsmulD(imag.baseAddress!, 1, &scale, imag.baseAddress!, 1, vDSP_Length(imag.count))
                }
            }
        }
        self.real = real
        self.imag = imag
    }

    func frequency(ofBin bin: Int) -> Double { Double(bin) * binWidth }

    // scipy's segment times: (size/2 + t·hop) / fs − (size/2) / fs.
    func time(ofFrame frame: Int) -> Double {
        let half = Double(size / 2)
        return (half + Double(frame * hop)) / sampleRate - half / sampleRate
    }

    // |Z|, frame-major like the spectrogram.
    func magnitudes() -> [Double] {
        var magnitudes = [Double](repeating: 0, count: real.count)
        real.withUnsafeBufferPointer { real in
            imag.withUnsafeBufferPointer { imag in
                // vDSP only reads the split complex input.
                var split = DSPDoubleSplitComplex(
                    realp: UnsafeMutablePointer(mutating: real.baseAddress!),
                    imagp: UnsafeMutablePointer(mutating: imag.baseAddress!))
                vDSP_zvabsD(&split, 1, &magnitudes, 1, vDSP_Length(magnitudes.count))
            }
        }
        return magnitudes
    }

    // scipy.signal.istft: irfft of every frame times the window sum, windowed
    // overlap-add divided by the summed squared window where that is above
    // 1e-10, boundary padding removed.
    func inverse() -> [Double] {
        let window = Self.hannWindow(size)
        let windowSum = vDSP.sum(window)
        let squaredWindow = vDSP.square(window)
        let length = size + (frameCount - 1) * hop
        var output = [Double](repeating: 0, count: length)
        var norm = [Double](repeating: 0, count: length)
        let frame = UnsafeMutablePointer<Double>.allocate(capacity: size)
        defer { frame.deallocate() }
        var scale = windowSum
        let fft = RealFFT(size: size)
        real.withUnsafeBufferPointer { real in
            imag.withUnsafeBufferPointer { imag in
                output.withUnsafeMutableBufferPointer { output in
                    norm.withUnsafeMutableBufferPointer { norm in
                        for t in 0..<frameCount {
                            fft.inverse(
                                real: real.baseAddress! + t * binCount, imag: imag.baseAddress! + t * binCount,
                                output: frame)
                            vDSP_vsmulD(frame, 1, &scale, frame, 1, vDSP_Length(size))
                            let start = output.baseAddress! + t * hop
                            vDSP_vmaD(frame, 1, window, 1, start, 1, start, 1, vDSP_Length(size))
                            let normStart = norm.baseAddress! + t * hop
                            vDSP_vaddD(normStart, 1, squaredWindow, 1, normStart, 1, vDSP_Length(size))
                        }
                    }
                }
            }
        }
        let trimmed = size / 2 ..< length - size / 2
        return zip(output[trimmed], norm[trimmed]).map { $1 > 1e-10 ? $0 / $1 : $0 }
    }

    // scipy's periodic Hann: 0.5 + 0.5·cos(linspace(−π, π, N + 1)[n]).
    static func hannWindow(_ size: Int) -> [Double] {
        let step = (Double.pi - -Double.pi) / Double(size)
        return (0..<size).map { 0.5 + 0.5 * cos(Double($0) * step + -Double.pi) }
    }
}
