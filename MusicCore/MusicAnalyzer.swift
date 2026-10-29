import Foundation

// The whole analysis, from the reference's `analyze`: separate and track the
// melody, segment the notes, then rhythm on the mix and harmony on the
// instrumental (both at 22.05 kHz), loudness and timbre. Runs off the main
// actor; a 3-minute song takes a few seconds.
nonisolated enum MusicAnalyzer {
    struct Result: Sendable {
        var analysis: MusicAnalysis
        // The stems: the vocals have the same signal in both channels.
        var vocals: StereoAudio
        var instrumental: StereoAudio
        // Per-frame data behind the analysis.
        var melody: MelodyTrack
        var rhythm: BeatTracker.Result
        var chroma: TonalAnalysis.Chromagram
    }

    static func analyse(contentsOf url: URL) async throws -> Result {
        analyse(try await AudioLoader.load(url))
    }

    static func analyse(_ audio: StereoAudio) -> Result {
        let separation = Separation(audio)
        let melody = separation.melody
        let (notes, tuningCents) = NoteSegmentation.notes(
            times: melody.times, f0: melody.f0, voiced: melody.voiced, level: melody.salience)
        let rhythm = BeatTracker.analyse(Numerics.halveSampleRate(audio.mid))
        let tonal = TonalAnalysis.analyse(
            Numerics.halveSampleRate(separation.instrumental.mid), tuningCents: tuningCents, beats: rhythm.beats,
            duration: audio.duration)
        let vocals = StereoAudio(left: separation.vocals, right: separation.vocals)

        let pitches = notes.map(\.midi)
        let analysis = MusicAnalysis(
            meta: MusicAnalysis.Meta(
                durationSeconds: audio.duration.rounded(digits: 2), sampleRate: Int(StereoAudio.sampleRate),
                separation: Separation.method),
            vocals: MusicAnalysis.Vocals(
                voicedRatio: (Double(melody.voiced.filter { $0 }.count) / Double(max(1, melody.voiced.count)))
                    .rounded(digits: 3),
                range: notes.isEmpty ? nil : [Pitch.name(midi: Double(pitches.min()!)), Pitch.name(midi: Double(pitches.max()!))],
                medianNote: notes.isEmpty ? nil : Pitch.name(midi: Numerics.median(pitches.map(Double.init))),
                tuningOffsetCents: tuningCents.rounded(digits: 1),
                notes: notes),
            rhythm: MusicAnalysis.Rhythm(bpm: rhythm.bpm.rounded(digits: 1), beats: rhythm.beats.map { $0.rounded(digits: 3) }),
            harmony: tonal.harmony,
            loudness: LoudnessMeter.loudness(audio),
            timbre: MusicAnalysis.TimbreSet(
                mix: TimbreAnalysis.timbre(audio), vocals: TimbreAnalysis.timbre(vocals),
                instrumental: TimbreAnalysis.timbre(separation.instrumental)))
        return Result(
            analysis: analysis, vocals: vocals, instrumental: separation.instrumental, melody: melody, rhythm: rhythm,
            chroma: tonal.chroma)
    }
}
