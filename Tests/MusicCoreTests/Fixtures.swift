import Foundation
@testable import MusicCore

// Fixtures/test_song.wav and test_truth.json come from AudioLens's
// make_test_song.py: a 22 s song at 100 BPM in A minor (Am F C G twice) with
// 21 known vocal notes. See Fixtures/README.md.
nonisolated enum Fixtures {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil)!
    }

    static let song = Task { try await AudioLoader.load(url("test_song.wav")) }
}
