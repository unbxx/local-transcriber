import Foundation
import Testing
@testable import MusicCore

struct NoteTests {
    private func segment(_ melody: MelodyTrack) -> (notes: [VocalNote], tuningCents: Double) {
        NoteSegmentation.notes(times: melody.times, f0: melody.f0, voiced: melody.voiced, level: melody.salience)
    }

    @Test func notesMatchTheReference() async throws {
        let (notes, tuning) = segment(try await Fixtures.separation.value.melody)
        let reference = try Fixtures.referenceAnalysis().vocals
        #expect(notes == reference.notes)
        #expect(tuning.rounded(digits: 1) == reference.tuningOffsetCents)
    }

    // The acceptance criterion: F1 ≥ 0.90 against the song's true notes.
    @Test func notesMatchTheTruth() async throws {
        let (notes, _) = segment(try await Fixtures.separation.value.melody)
        #expect(try Fixtures.truth().noteF1(notes) >= 0.9)
    }

    // A synthetic track at 10 ms per frame.
    private func track(_ runs: [(midi: Double?, frames: Int)]) -> MelodyTrack {
        let pitches = runs.flatMap { Array(repeating: $0.midi, count: $0.frames) }
        return MelodyTrack(
            times: pitches.indices.map { Double($0) * 0.01 },
            f0: pitches.map { $0.map { 440 * pow(2, ($0 - 69) / 12) } ?? 440 },
            voiced: pitches.map { $0 != nil },
            salience: pitches.map { $0 == nil ? 0 : 1 })
    }

    @Test func bridgesGapsUpTo50Milliseconds() {
        let bridged = segment(track([(69, 30), (nil, 5), (69, 30)])).notes
        #expect(bridged.map(\.midi) == [69])
        #expect(bridged.first?.start == 0)
        #expect(bridged.first?.end == 0.65)
        let split = segment(track([(69, 30), (nil, 6), (69, 30)])).notes
        #expect(split.map(\.midi) == [69, 69])
    }

    @Test func dropsNotesShorterThan90Milliseconds() {
        let notes = segment(track([(69, 30), (nil, 20), (72, 8), (nil, 20), (74, 30)])).notes
        #expect(notes.map(\.midi) == [69, 74])
    }

    @Test func dropsShortNotesAnOctaveAwayFromTheMelody() {
        let melody: [(midi: Double?, frames: Int)] = [(69, 30), (nil, 10), (71, 30), (nil, 10), (72, 30), (nil, 10)]
        let notes = segment(track(melody + [(45, 15), (nil, 10), (74, 30), (nil, 10), (45, 30)])).notes
        #expect(notes.map(\.midi) == [69, 71, 72, 74, 45])
        #expect(notes.allSatisfy { $0.velocity == 127 && $0.centsOff == 0 })
        #expect(notes.map(\.name) == ["A4", "B4", "C5", "D5", "A2"])
    }

    @Test func measuresTheTuningOffset() {
        let sharp = track([(69.2, 30), (nil, 10), (72.2, 30)])
        let (notes, tuning) = segment(sharp)
        #expect(abs(tuning - 20) < 1e-9)
        #expect(notes.map(\.midi) == [69, 72])
        #expect(notes.allSatisfy { $0.centsOff == 0 })
    }
}
