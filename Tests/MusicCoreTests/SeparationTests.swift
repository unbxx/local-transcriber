import Foundation
import Testing
@testable import MusicCore

struct SeparationTests {
    @Test func melodyMatchesTheReferenceFrameByFrame() async throws {
        let melody = try await Fixtures.separation.value.melody
        let reference = try ReferenceFrames.load().melody
        #expect(melody.f0.count == 1888)
        #expect(melody.f0.count == reference.f0.count)
        let worstCents = zip(melody.f0, reference.f0).map { 1200 * abs(log2($0 / $1)) }.max() ?? .infinity
        #expect(worstCents < 1e-6)
        #expect(melody.voiced == reference.voiced.map { $0 == 1 })
        #expect(abs(melody.times[100] - 100 * 512 / 44_100) < 1e-15)
    }

    @Test func vocalsAndInstrumentalMatchTheReference() async throws {
        let separation = try await Fixtures.separation.value
        let song = try await Fixtures.song.value
        let reference = try ReferenceFrames.load().vocals
        let energy = separation.vocals.reduce(0) { $0 + $1 * $1 }
        #expect(abs(energy / reference.sumOfSquares - 1) < 1e-9)
        for sample in reference.samples {
            #expect(abs(separation.vocals[Int(sample[0])] - sample[1]) < 1e-12)
        }
        #expect(separation.vocals.count == song.frameCount)
        #expect(separation.instrumental.left[500_000] == song.left[500_000] - separation.vocals[500_000])
        #expect(separation.instrumental.right[500_000] == song.right[500_000] - separation.vocals[500_000])
    }

    // Unvoiced frames get no vocals: a sample is silent when no frame whose
    // window reaches it (4 hops either way) is voiced.
    @Test func vocalsAreSilentWhereNoFrameIsVoiced() async throws {
        let separation = try await Fixtures.separation.value
        let voiced = separation.melody.voiced, hop = Separation.hop
        let reach = Separation.fftSize / 2 / hop
        var silentSamples = 0
        for t in reach ..< voiced.count - reach where !voiced[(t - reach)...(t + reach)].contains(true) {
            #expect(separation.vocals[t * hop ..< (t + 1) * hop].allSatisfy { $0 == 0 })
            silentSamples += hop
        }
        #expect(silentSamples > 44_100 / 4)
    }
}
