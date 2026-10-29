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
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(contentsOf: url(name)))
    }

    // Computed once and shared by the tests.
    static let song = Task { try await AudioLoader.load(url("test_song.wav")) }
    static let separation = Task { Separation(try await song.value) }
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

    static func load() throws -> ReferenceFrames { try Fixtures.decode(Self.self, from: "reference-frames.json") }
}
