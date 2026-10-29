import Foundation
import Testing
@testable import MusicCore

struct BeatTrackerTests {
    private func rhythm() async throws -> BeatTracker.Result {
        BeatTracker.analyse(Numerics.halveSampleRate(try await Fixtures.song.value.mid))
    }

    @Test func onsetEnvelopeMatchesTheReference() async throws {
        let result = try await rhythm()
        let reference = try ReferenceFrames.load().onsetEnvelope
        #expect(result.framesPerSecond == 22_050.0 / 256)
        #expect(result.envelope.count == reference.count)
        #expect(zip(result.envelope, reference).allSatisfy { abs($0 - $1) < 1e-9 })
    }

    @Test func tempoAndBeatsMatchTheReference() async throws {
        let result = try await rhythm()
        let reference = try Fixtures.referenceAnalysis().rhythm
        #expect(result.bpm.rounded(digits: 1) == reference.bpm)
        #expect(result.beats.map { $0.rounded(digits: 3) } == reference.beats)
    }

    // The acceptance criterion: within 1 BPM of the true 100 BPM.
    @Test func tempoMatchesTheTruth() async throws {
        #expect(abs(try await rhythm().bpm - (try Fixtures.truth().bpm)) <= 1)
    }

    @Test func followsAClickTrack() {
        // Short noise-like clicks every 0.5 s (120 BPM) from 0.25 s, 10 s long.
        var signal = [Double](repeating: 0, count: 220_500)
        for beat in 0..<20 {
            let start = Int((0.25 + 0.5 * Double(beat)) * BeatTracker.sampleRate)
            for i in 0..<200 { signal[start + i] = sin(Double(i * i) * 0.37) * exp(-Double(i) / 40) }
        }
        let result = BeatTracker.analyse(signal)
        #expect(abs(result.bpm - 120) < 1)
        #expect(result.beats.count >= 18)
        let intervals = zip(result.beats.dropFirst(), result.beats).map { $0 - $1 }
        #expect(intervals.allSatisfy { abs($0 - 0.5) < 0.03 })
        let offsets = result.beats.map { ($0 - 0.25).truncatingRemainder(dividingBy: 0.5) }
        #expect(offsets.allSatisfy { $0 < 0.03 || $0 > 0.47 })
    }

    @Test func convolveSameMatchesNumpy() {
        // np.convolve(a, v, 'same') for even and odd kernels and swapped arguments.
        #expect(BeatTracker.convolveSame([1, 2, 3, 4, 5], [1, 0, -1, 2]) == [2, 2, 4, 6, 2])
        #expect(BeatTracker.convolveSame([1, 0, -1, 2], [1, 2, 3, 4, 5]) == [2, 2, 4, 6, 2])
        #expect(BeatTracker.convolveSame([1, 2, 3, 4, 5], [1, 0, -1]) == [2, 2, 2, 2, -4])
    }
}
