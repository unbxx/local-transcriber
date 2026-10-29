import Foundation
@testable import MusicCore

// Fixtures/test_song.wav and test_truth.json come from AudioLens's
// make_test_song.py: a 22 s song at 100 BPM in A minor (Am F C G twice) with
// 21 known vocal notes. reference-*.json are the Python reference's results
// for that song. See Fixtures/README.md.
nonisolated enum Fixtures {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil)!
    }

    static func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url(name)))
    }

    static func referenceAnalysis() throws -> MusicAnalysis { try decode(MusicAnalysis.self, from: "reference-analysis.json") }
    static func truth() throws -> Truth { try decode(Truth.self, from: "test_truth.json") }

    // Computed once and shared by the tests.
    static let song = Task { try await AudioLoader.load(url("test_song.wav")) }
    static let separation = Task { Separation(try await song.value) }
    // The whole pipeline from the file, off the main actor.
    static let analysis = Task.detached { try await MusicAnalyzer.analyse(contentsOf: url("test_song.wav")) }
}

// test_truth.json, and the scores of AudioLens's eval_truth.py.
nonisolated struct Truth: Decodable {
    struct Note: Decodable {
        let start, end: Double
        let midi: Int
    }

    struct Chord: Decodable {
        let start, end: Double
        let chord: String
    }

    let bpm: Double
    let key: String
    let chords: [Chord]
    let notes: [Note]

    // A true note is found when an unused detected note starts within 80 ms
    // of it with the same pitch.
    func noteF1(_ detected: [VocalNote]) -> Double {
        var used = Set<Int>()
        for note in notes {
            let match = detected.indices.first {
                !used.contains($0) && abs(detected[$0].start - note.start) <= 0.08 && detected[$0].midi == note.midi
            }
            if let match { used.insert(match) }
        }
        let precision = Double(used.count) / Double(max(1, detected.count))
        let recall = Double(used.count) / Double(max(1, notes.count))
        return precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
    }

    // Share of a 50 ms grid over the true chords where the detected chord
    // has the same name.
    func chordAccuracy(_ detected: [ChordSegment]) -> Double {
        func label(_ time: Double, _ segments: [(start: Double, end: Double, chord: String)]) -> String {
            segments.first { $0.start <= time && time < $0.end }?.chord ?? "N"
        }
        let truth = chords.map { ($0.start, $0.end, $0.chord) }, found = detected.map { ($0.start, $0.end, $0.chord) }
        let first = chords.first!.start, last = chords.last!.end
        // np.arange(first, last, 0.05), which steps by (first + 0.05) − first.
        let step = (first + 0.05) - first
        let grid = (0..<Int(((last - first) / 0.05).rounded(.up))).map { first + Double($0) * step }
        return Double(grid.filter { label($0, found) == label($0, truth) }.count) / Double(grid.count)
    }
}

// reference-frames.json: per-frame results of the reference's steps.
nonisolated struct ReferenceFrames: Decodable {
    struct Melody: Decodable {
        let f0: [Double]
        let voiced: [Int]
    }

    struct Vocals: Decodable {
        let sumOfSquares: Double
        // [sample index, value]
        let samples: [[Double]]

        enum CodingKeys: String, CodingKey { case sumOfSquares = "sum_of_squares", samples }
    }

    struct Chroma: Decodable {
        let frames: Int
        // Sum over frames per pitch class, C first.
        let profile: [Double]
        // Frame index → 12 values.
        let columns: [String: [Double]]
    }

    let melody: Melody
    let vocals: Vocals
    let onsetEnvelope: [Double]
    let chroma: Chroma

    enum CodingKeys: String, CodingKey { case melody, vocals, onsetEnvelope = "onset_envelope", chroma }

    static func load() throws -> ReferenceFrames { try Fixtures.decode(Self.self, from: "reference-frames.json") }
}
