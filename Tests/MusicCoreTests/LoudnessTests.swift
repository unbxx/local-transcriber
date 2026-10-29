import Foundation
import Testing
@testable import MusicCore

struct LoudnessTests {
    @Test func loudnessAndTimbreMatchTheReference() async throws {
        let song = try await Fixtures.song.value
        let separation = try await Fixtures.separation.value
        let reference = try Fixtures.referenceAnalysis()
        #expect(LoudnessMeter.loudness(song) == reference.loudness)
        #expect(TimbreAnalysis.timbre(song) == reference.timbre.mix)
        #expect(TimbreAnalysis.timbre(StereoAudio(left: separation.vocals, right: separation.vocals)) == reference.timbre.vocals)
        #expect(TimbreAnalysis.timbre(separation.instrumental) == reference.timbre.instrumental)
    }

    private func sine(_ frequency: Double, amplitude: Double, seconds: Double) -> StereoAudio {
        let samples = (0..<Int(seconds * StereoAudio.sampleRate)).map {
            amplitude * sin(2 * Double.pi * frequency * Double($0) / StereoAudio.sampleRate)
        }
        return StereoAudio(left: samples, right: samples)
    }

    @Test func halvingTheLevelLowersLoudnessBySixDecibels() throws {
        let full = LoudnessMeter.loudness(sine(1000, amplitude: 0.5, seconds: 5))
        let half = LoudnessMeter.loudness(sine(1000, amplitude: 0.25, seconds: 5))
        let fullLUFS = try #require(full.lufsIntegrated), halfLUFS = try #require(half.lufsIntegrated)
        #expect(abs(fullLUFS - halfLUFS - 6) <= 0.1)
        #expect(full.peakDBFS == -6)
        #expect(full.crestFactorDB == 3)
        #expect(full.loudnessRangeLU == 0)
    }

    @Test func shortAudioHasOnlyANullIntegratedLoudness() throws {
        let loudness = LoudnessMeter.loudness(sine(1000, amplitude: 0.5, seconds: 0.3))
        #expect(loudness == MusicAnalysis.Loudness())
        var json = ""
        loudness.json.write(to: &json, level: 0)
        #expect(json == "{\n \"lufs_integrated\": null\n}")
    }

    @Test func timbreOfASineInTheCentre() {
        let timbre = TimbreAnalysis.timbre(sine(1000, amplitude: 0.5, seconds: 2))
        #expect(abs(timbre.spectralCentroidHz - 1000) < 30)
        #expect(timbre.energyDistributionPct[2] > 99)
        #expect(timbre.stereoWidth == 0)
        #expect(timbre.stereoCorrelation == 1)
    }
}
