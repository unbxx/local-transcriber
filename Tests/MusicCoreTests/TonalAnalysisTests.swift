import Foundation
import Testing
@testable import MusicCore

struct TonalAnalysisTests {
    // The reference's harmony step: the instrumental at 22.05 kHz, the
    // vocals' tuning offset and the beats.
    private func harmony() async throws -> (harmony: MusicAnalysis.Harmony, chroma: TonalAnalysis.Chromagram) {
        let song = try await Fixtures.song.value
        let separation = try await Fixtures.separation.value
        let melody = separation.melody
        let tuning = NoteSegmentation.notes(
            times: melody.times, f0: melody.f0, voiced: melody.voiced, level: melody.salience
        ).tuningCents
        let beats = BeatTracker.analyse(Numerics.halveSampleRate(song.mid), settings: .reference).beats
        return TonalAnalysis.analyse(
            Numerics.halveSampleRate(separation.instrumental.mid), tuningCents: tuning, beats: beats,
            duration: song.duration, settings: .reference)
    }

    @Test func chromaMatchesTheReference() async throws {
        let chroma = try await harmony().chroma
        let reference = try ReferenceFrames.load().chroma
        #expect(chroma.frameCount == reference.frames)
        let profile = (0..<12).map { pc in (0..<chroma.frameCount).reduce(0.0) { $0 + chroma.values[$1 * 12 + pc] } }
        #expect(zip(profile, reference.profile).allSatisfy { abs($0 - $1) < 1e-9 })
        for (frame, values) in reference.columns {
            #expect(zip(chroma.frame(Int(frame)!), values).allSatisfy { abs($0 - $1) < 1e-12 })
        }
    }

    @Test func keyAndChordsMatchTheReference() async throws {
        #expect(try await harmony().harmony == Fixtures.referenceAnalysis().harmony)
    }

    // The acceptance criteria: A minor, and the right chord ≥ 90 % of the time.
    @Test func keyAndChordsMatchTheTruth() async throws {
        let harmony = try await harmony().harmony
        let truth = try Fixtures.truth()
        #expect(harmony.key == truth.key)
        #expect(truth.chordAccuracy(harmony.chords) >= 0.9)
    }

    @Test func templatesAreTheTwentyFourTriads() {
        #expect(TonalAnalysis.templates.count == 24)
        #expect(TonalAnalysis.templates.prefix(4).map(\.name) == ["C", "Cm", "C#", "C#m"])
        let am = TonalAnalysis.templates.first { $0.name == "Am" }!
        #expect(am.root == 9 && am.quality == "m")
        #expect(am.vector.enumerated().filter { $0.element > 0 }.map(\.offset) == [0, 4, 9])
    }

    @Test func chordsFollowTheBeatsAndMerge() {
        // Two beats of C major, two of G major, then two of silence (no
        // chord). With the standard settings' switch penalty a change has to
        // hold for more than one beat.
        let c: [Double] = [1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0], g: [Double] = [0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1]
        let frames = [c, c, c, c, g, g, g, g] + Array(repeating: [Double](repeating: 0, count: 12), count: 4)
        let chroma = TonalAnalysis.Chromagram(times: frames.indices.map { Double($0) * 0.25 }, values: frames.flatMap { $0 })
        for settings in [AnalysisSettings.reference, .standard] {
            let chords = TonalAnalysis.chords(chroma, beats: [0.5, 1, 1.5, 2, 2.5], duration: 3, settings: settings)
            #expect(chords.map(\.chord) == ["C", "G", "N"])
            #expect(chords.map(\.start) == [0, 1, 2])
            #expect(chords.last?.end == 3)
            #expect(chords.map(\.root) == [0, 7, -1])
        }
    }

    // A C major triad over the flat floor drums and noise leave in a real mix
    // (every other pitch class at 0.55): the reference's cosine falls just
    // below its no-chord score, the standard settings' correlation does not.
    @Test func correlationFindsAChordAboveADrumFloor() {
        var frame = [Double](repeating: 0.55, count: 12)
        for pitchClass in [0, 4, 7] { frame[pitchClass] = 1 }
        let chroma = TonalAnalysis.Chromagram(times: (0..<8).map { Double($0) * 0.25 }, values: Array((0..<8).map { _ in frame }.joined()))
        let beats = [0.5, 1, 1.5]
        #expect(TonalAnalysis.chords(chroma, beats: beats, duration: 2, settings: .reference).map(\.chord) == ["N"])
        #expect(TonalAnalysis.chords(chroma, beats: beats, duration: 2, settings: .standard).map(\.chord) == ["C"])
    }

    @Test func prefersTheRelativeKeyWhoseTonicChordDominates() {
        let keys = [TonalAnalysis.KeyCandidate(correlation: 0.8, tonic: "C", mode: "majeur")]
        let chords = [("Am", 9, 4.0), ("F", 5, 2.0), ("C", 0, 2.0), ("Am", 9, 2.0)].reduce(into: [ChordSegment]()) {
            let start = $0.last?.end ?? 0
            $0.append(ChordSegment(start: start, end: start + $1.2, chord: $1.0, root: $1.1, quality: $1.0.hasSuffix("m") ? "m" : ""))
        }
        let refined = TonalAnalysis.refineKey(keys, chords: chords)
        #expect(refined.key == ("A", "mineur"))
        #expect(refined.relative == ("C", "majeur"))
        let unchanged = TonalAnalysis.refineKey(keys, chords: [])
        #expect(unchanged.key == ("C", "majeur"))
    }
}
