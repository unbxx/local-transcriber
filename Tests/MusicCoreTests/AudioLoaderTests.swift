import AVFoundation
import Testing
@testable import MusicCore

struct AudioLoaderTests {
    // The reference reads the same 16-bit WAV as s / 32768 (ffmpeg's f32le).
    @Test func loadsTheFixtureLikeTheReference() async throws {
        let song = try await Fixtures.song.value
        #expect(song.frameCount == 965_789)
        #expect(song.left[500_000] == 0.046661376953125)
        #expect(abs(song.left.reduce(0) { $0 + $1 * $1 } - 24556.831404806115) < 1e-6)
        #expect(abs(song.right.reduce(0) { $0 + $1 * $1 } - 24370.61899588909) < 1e-6)
    }

    @Test func resamplesMonoToStereoAt44100() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "tone.wav")

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for i in 0..<48_000 { buffer.floatChannelData![0][i] = Float(0.5 * sin(2 * Double.pi * 440 * Double(i) / 48_000)) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ])
            try file.write(from: buffer)
        }

        let audio = try await AudioLoader.load(url)
        #expect(abs(audio.frameCount - 44_100) <= 64)
        #expect(audio.left == audio.right)
        let peak = audio.left.map(abs).max() ?? 0
        #expect(peak > 0.45 && peak < 0.55)
    }

    @Test func rejectsAFileWithoutAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: (any Error).self) { try await AudioLoader.load(url) }
    }
}
