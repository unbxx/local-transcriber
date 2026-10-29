import Foundation
import Testing
@testable import MusicCore

struct ExportTests {
    @Test func analysisJSONIsByteIdenticalToTheReference() async throws {
        let analysis = try await Fixtures.analysis.value.analysis
        #expect(analysis.jsonData() == (try Data(contentsOf: Fixtures.url("reference-analysis.json"))))
    }

    @Test func analysisJSONDecodesBack() async throws {
        let analysis = try await Fixtures.analysis.value.analysis
        #expect(try JSONDecoder().decode(MusicAnalysis.self, from: analysis.jsonData()) == analysis)
    }

    @Test func jsonWritesLikePython() {
        var text = ""
        JSONValue.object([
            ("float", .number(1)), ("small", .number(0.0007)), ("tiny", .number(1e-05)), ("int", .integer(-1)),
            ("text", .string("é \"q\" \\ \n")), ("empty", .array([])), ("none", .null), ("nan", .number(.nan)),
            ("list", .array([.number(0.58), .object([])])),
        ]).write(to: &text, level: 0)
        // json.dumps({...}, indent=1)
        #expect(text == """
            {
             "float": 1.0,
             "small": 0.0007,
             "tiny": 1e-05,
             "int": -1,
             "text": "\\u00e9 \\"q\\" \\\\ \\n",
             "empty": [],
             "none": null,
             "nan": NaN,
             "list": [
              0.58,
              {}
             ]
            }
            """)
    }

    @Test func midiIsByteIdenticalToTheReference() async throws {
        let analysis = try await Fixtures.analysis.value.analysis
        #expect(MIDIFile.transcription(analysis) == (try Data(contentsOf: Fixtures.url("reference-transcription.mid"))))
    }

    @Test func midiHasATempoTrackAndThreeParts() throws {
        let analysis = try Fixtures.referenceAnalysis()
        let midi = [UInt8](MIDIFile.transcription(analysis))
        #expect(Array(midi[0..<4]) == Array("MThd".utf8))
        #expect(Array(midi[8..<14]) == [0, 1, 0, 4, 0x01, 0xE0])
        // Tempo 99.4 BPM: 603 621 µs per quarter note.
        #expect(Array(midi[22..<29]) == [0x00, 0xFF, 0x51, 0x03, 0x09, 0x35, 0xE5])
        let noteOns = zip(midi, midi.dropFirst()).filter { $0.0 & 0xF0 == 0x90 && $0.1 < 128 }.count
        let chords = analysis.harmony.chords.filter { $0.chord != "N" }.count
        #expect(noteOns >= analysis.vocals.notes.count + 5 * chords)
    }

    @Test func variableLengthQuantities() {
        #expect(MIDIFile.variableLength(0) == [0x00])
        #expect(MIDIFile.variableLength(0x7F) == [0x7F])
        #expect(MIDIFile.variableLength(0x80) == [0x81, 0x00])
        #expect(MIDIFile.variableLength(0x3FFF) == [0xFF, 0x7F])
        #expect(MIDIFile.variableLength(0x0FFF_FFFF) == [0xFF, 0xFF, 0xFF, 0x7F])
    }

    @Test func markdownMatchesTheGolden() async throws {
        let analysis = try await Fixtures.analysis.value.analysis
        let golden = try String(contentsOf: Fixtures.url("test_song.md"), encoding: .utf8)
        #expect(MusicMarkdownRenderer.render(analysis, sourceURL: Fixtures.url("test_song.wav")) == golden)
    }

    // Beats every 0.5 s from 0.5 s; chords change on beats 1, 5 and 7, so bars
    // start on beat 1 and the first beat is a pickup.
    private var small: MusicAnalysis {
        let chords = [
            ChordSegment(start: 0, end: 1, chord: "N", root: -1, quality: ""),
            ChordSegment(start: 1, end: 3, chord: "C", root: 0, quality: ""),
            ChordSegment(start: 3, end: 4, chord: "Am", root: 9, quality: "m"),
            ChordSegment(start: 4, end: 6.2, chord: "G", root: 7, quality: ""),
        ]
        let notes = [
            VocalNote(start: 0.6, end: 0.9, midi: 67, name: "G4", centsOff: 0, velocity: 100),
            VocalNote(start: 1.05, end: 2, midi: 72, name: "C5", centsOff: 0, velocity: 100),
            VocalNote(start: 2.95, end: 3.4, midi: 69, name: "A4", centsOff: 0, velocity: 100),
            VocalNote(start: 4.5, end: 5, midi: 71, name: "B4", centsOff: 0, velocity: 100),
        ]
        return MusicAnalysis(
            meta: .init(durationSeconds: 6.2, sampleRate: 44_100, separation: Separation.method),
            vocals: .init(voicedRatio: 0.5, range: ["G4", "C5"], medianNote: "A4", tuningOffsetCents: 0, notes: notes),
            rhythm: .init(bpm: 120, beats: stride(from: 0.5, through: 5.5, by: 0.5).map { $0 }),
            harmony: .init(
                key: "C majeur", relativeKey: "A mineur", keyConfidence: 0.8, keyAlternatives: [],
                pitchClassProfile: Array(repeating: 1.0 / 12, count: 12), chords: chords),
            loudness: .init(),
            timbre: .init(mix: timbre, vocals: timbre, instrumental: timbre))
    }

    private let timbre = MusicAnalysis.Timbre(
        spectralCentroidHz: 0, energyDistributionPct: [0, 0, 0, 0, 0], spectralFlatness: 0, stereoWidth: 0,
        stereoCorrelation: 1)

    @Test func barsStartOnTheBeatChordsChangeOn() {
        let bars = MusicMarkdownRenderer.bars(small)
        #expect(bars.map(\.label) == ["Pickup", "Bar 1", "Bar 2", "Bar 3"])
        #expect(bars.map(\.start) == [0, 1, 3, 5])
        #expect(bars.last?.end == 6.2)
        // A note up to 80 ms before a bar line belongs to the new bar.
        #expect(bars.map { $0.notes.map(\.name) } == [["G4"], ["C5"], ["A4", "B4"], []])
        #expect(bars[2].chords.map(\.name) == ["Am", "G"])
        #expect(bars[2].chords.map(\.time) == [3, 4])
        #expect(bars[3].chords.map(\.name) == ["G"])
    }

    @Test func rendersInTheAppStyle() {
        let markdown = MusicMarkdownRenderer.render(small, sourceURL: URL(fileURLWithPath: "/tmp/Demo Song.m4a"))
        // Lines ending in two spaces are Markdown line breaks, as in the app.
        let expected = [
            "# Demo Song", "",
            "**Source:** `Demo Song.m4a`  ", "**Duration:** 00:00:06  ", "**Tempo:** 120.0 BPM  ", "**Key:** C major", "",
            "## Transcript", "",
            "### Pickup · 00:00:00.00", "",
            "Chords: N.C. 00:00:00.00  ", "Vocals: G4 00:00:00.60", "",
            "### Bar 1 · 00:00:01.00", "",
            "Chords: C 00:00:01.00  ", "Vocals: C5 00:00:01.05", "",
            "### Bar 2 · 00:00:03.00", "",
            "Chords: Am 00:00:03.00 · G 00:00:04.00  ", "Vocals: A4 00:00:02.95 · B4 00:00:04.50", "",
            "### Bar 3 · 00:00:05.00", "",
            "Chords: G 00:00:05.00", "",
        ]
        #expect(markdown == expected.joined(separator: "\n"))
    }

    @Test func aLeadInWithoutNotesOrChordsIsLeftOut() {
        var analysis = small
        analysis.vocals.notes.removeFirst()
        #expect(MusicMarkdownRenderer.bars(analysis).first?.label == "Bar 1")
    }
}
