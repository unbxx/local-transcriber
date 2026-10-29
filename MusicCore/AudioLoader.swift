import Accelerate
import AVFoundation

// Two channels at 44.1 kHz, the input every analysis step works on (the
// reference's `load_audio`: ffmpeg to stereo f32le, widened to float64).
nonisolated struct StereoAudio: Sendable, Equatable {
    static let sampleRate = 44_100.0

    var left: [Double]
    var right: [Double]

    var frameCount: Int { left.count }
    var duration: Double { Double(frameCount) / Self.sampleRate }

    // (L + R) / 2, the reference's `x.mean(0)`.
    var mid: [Double] { vDSP.divide(vDSP.add(left, right), 2) }
}

nonisolated enum AudioLoader {
    enum LoadError: LocalizedError {
        case noAudioTrack
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: "The file has no audio track."
            case .readFailed(let reason): "The audio couldn’t be read: \(reason)"
            }
        }
    }

    // Decodes the first audio track of anything AVFoundation opens (WAV, M4A,
    // MP3, MP4, MOV, …). AVFoundation resamples to 44.1 kHz and maps mono or
    // multichannel audio to stereo.
    static func load(_ url: URL) async throws -> StereoAudio {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw LoadError.noAudioTrack
        }

        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: StereoAudio.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false

        let reader = try AVAssetReader(asset: asset)
        reader.add(output)
        guard reader.startReading() else {
            throw LoadError.readFailed(reader.error?.localizedDescription ?? "the reader didn’t start")
        }

        var interleaved: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let start = interleaved.count
            interleaved.append(contentsOf: repeatElement(0, count: length / MemoryLayout<Float>.size))
            let status = interleaved.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: length,
                    destination: $0.baseAddress! + start * MemoryLayout<Float>.size)
            }
            guard status == kCMBlockBufferNoErr else { throw LoadError.readFailed("OSStatus \(status)") }
        }
        if reader.status == .failed {
            throw LoadError.readFailed(reader.error?.localizedDescription ?? "unknown error")
        }

        let frames = interleaved.count / 2
        var left = [Double](repeating: 0, count: frames)
        var right = [Double](repeating: 0, count: frames)
        interleaved.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress, frames > 0 else { return }
            vDSP_vspdp(base, 2, &left, 1, vDSP_Length(frames))
            vDSP_vspdp(base + 1, 2, &right, 1, vDSP_Length(frames))
        }
        return StereoAudio(left: left, right: right)
    }
}
