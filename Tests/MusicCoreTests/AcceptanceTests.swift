import Foundation
import Testing
@testable import MusicCore

// The brief's acceptance criteria, end to end from the WAV file: note F1 ≥ 0.90
// (onset within 80 ms, same pitch), tempo within 1 BPM, A minor, and the right
// chord at least 90 % of the time. The reference scores 1.00, 99.4 BPM,
// A minor and 96.6 %.
struct AcceptanceTests {
    @Test func meetsTheAcceptanceCriteria() async throws {
        let analysis = try await Fixtures.analysis.value.analysis
        let truth = try Fixtures.truth()
        #expect(truth.noteF1(analysis.vocals.notes) >= 0.9)
        #expect(abs(analysis.rhythm.bpm - truth.bpm) <= 1)
        #expect(analysis.harmony.key == truth.key)
        #expect(truth.chordAccuracy(analysis.harmony.chords) >= 0.9)
    }

    @Test func referenceSettingsScoreLikeTheReference() async throws {
        let analysis = try await Fixtures.referenceResult.value.analysis
        let truth = try Fixtures.truth()
        #expect(truth.noteF1(analysis.vocals.notes) == 1)
        #expect(analysis.rhythm.bpm == 99.4)
        #expect((truth.chordAccuracy(analysis.harmony.chords) * 1000).rounded() == 966)
    }

    @Test func referenceSettingsGiveTheReferencesAnalysis() async throws {
        #expect(try await Fixtures.referenceResult.value.analysis == Fixtures.referenceAnalysis())
    }

    // The standard settings change only tempo and chords; on the test song
    // the notes stay the same and the scores barely move.
    @Test func standardSettingsKeepTheTestSongsResults() async throws {
        let analysis = try await Fixtures.analysis.value.analysis
        let reference = try Fixtures.referenceAnalysis()
        let truth = try Fixtures.truth()
        #expect(analysis.vocals == reference.vocals)
        #expect(analysis.rhythm.bpm == reference.rhythm.bpm)
        #expect(analysis.harmony.key == reference.harmony.key)
        #expect(truth.chordAccuracy(analysis.harmony.chords) >= 0.95)
        #expect(analysis.harmony.chords.first?.chord == "N")
    }

    @Test func stemsAddUpToTheMix() async throws {
        let result = try await Fixtures.analysis.value
        let song = try await Fixtures.song.value
        #expect(result.vocals.left == result.vocals.right)
        for i in stride(from: 0, to: song.frameCount, by: 10_007) {
            #expect(abs(result.vocals.left[i] + result.instrumental.left[i] - song.left[i]) < 1e-15)
            #expect(abs(result.vocals.right[i] + result.instrumental.right[i] - song.right[i]) < 1e-15)
        }
    }
}
