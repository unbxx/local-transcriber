import Foundation
import Testing
@testable import MusicCore

struct BeatTrackerTests {
    private func rhythm() async throws -> BeatTracker.Result {
        BeatTracker.analyse(Numerics.halveSampleRate(try await Fixtures.song.value.mid), settings: .reference)
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
    @Test(arguments: [AnalysisSettings.reference, .standard])
    func tempoMatchesTheTruth(settings: AnalysisSettings) async throws {
        let signal = Numerics.halveSampleRate(try await Fixtures.song.value.mid)
        #expect(abs(BeatTracker.analyse(signal, settings: settings).bpm - (try Fixtures.truth().bpm)) <= 1)
    }

    // A noise-like hit at `time`, decaying over `decay` samples.
    private func hit(_ signal: inout [Double], at time: Double, amplitude: Double, decay: Double, phase: Double) {
        let start = Int(time * BeatTracker.sampleRate)
        for i in 0 ..< min(signal.count - start, Int(0.12 * BeatTracker.sampleRate)) {
            signal[start + i] += amplitude * sin(Double(i * i) * 0.37 + phase) * exp(-Double(i) / decay)
        }
    }

    // A trap bar at 150 BPM: kicks on 1, the and of 2 and the and of 3, the
    // snare on 3, hi-hats on every eighth note. The reference hears 2/3 of the
    // tempo (100 BPM); the standard settings hear the pulse or its half.
    @Test func standardSettingsAvoidTheTripletTempo() {
        let beat = 60.0 / 150
        var signal = [Double](repeating: 0, count: Int((48 * beat + 1) * BeatTracker.sampleRate))
        for bar in 0..<12 {
            let start = Double(bar * 4) * beat
            for kick in [0, 1.5, 2.5] { hit(&signal, at: start + kick * beat, amplitude: 1, decay: 300, phase: 0) }
            hit(&signal, at: start + 2 * beat, amplitude: 0.8, decay: 150, phase: 1)
            for eighth in 0..<8 { hit(&signal, at: start + Double(eighth) * beat / 2, amplitude: 0.25, decay: 30, phase: 2) }
        }
        let reference = BeatTracker.analyse(signal, settings: .reference).bpm
        let standard = BeatTracker.analyse(signal, settings: .standard).bpm
        #expect(abs(reference - 100) < 3)
        #expect(abs(standard - 150) < 3 || abs(standard - 75) < 2)
    }

    @Test(arguments: [AnalysisSettings.reference, .standard])
    func followsAClickTrack(settings: AnalysisSettings) {
        // Short noise-like clicks every 0.5 s (120 BPM) from 0.25 s, 10 s long.
        var signal = [Double](repeating: 0, count: 220_500)
        for beat in 0..<20 {
            let start = Int((0.25 + 0.5 * Double(beat)) * BeatTracker.sampleRate)
            for i in 0..<200 { signal[start + i] = sin(Double(i * i) * 0.37) * exp(-Double(i) / 40) }
        }
        let result = BeatTracker.analyse(signal, settings: settings)
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
