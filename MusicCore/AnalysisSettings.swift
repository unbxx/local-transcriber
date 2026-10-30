// How the tempo and chord steps are tuned. `.reference` reproduces AudioLens's
// audiolens.py exactly (its analysis.json byte for byte); `.standard`, the
// default, is tuned on real recordings. MusicCore/README.md has the
// measurements.
nonisolated struct AnalysisSettings: Equatable, Sendable {
    // A multiple of a candidate beat period whose autocorrelation counts
    // towards that period's tempo score, with its weight.
    struct PeriodMultiple: Equatable, Sendable {
        var multiple: Double
        var weight: Double
    }

    enum ChordScoring: Equatable, Sendable {
        // Cosine of a beat's chroma with each triad template.
        case cosine
        // Correlation: chroma and templates with their mean removed, so the
        // flat floor that drums and noise add does not count against a chord.
        case correlation
    }

    var tempoPeriodMultiples: [PeriodMultiple]
    var chordScoring: ChordScoring
    // The score of "no chord" against the 24 triads, per beat.
    var noChordScore: Double
    // What changing chords costs in the Viterbi path.
    var chordSwitchPenalty: Double

    static let reference = AnalysisSettings(
        tempoPeriodMultiples: [PeriodMultiple(multiple: 1, weight: 1)],
        chordScoring: .cosine, noChordScore: 0.72, chordSwitchPenalty: 0.06)

    // The beat period also scores by its half (eighth notes), double and
    // quadruple (half bar, bar), so music with a duple pulse no longer locks
    // on 2/3 of its tempo, as trap at 150 BPM did at 100. Chords by
    // correlation with a low no-chord score: real mixes had no chord 60 % of
    // the time. The higher switch penalty keeps that from flickering.
    static let standard = AnalysisSettings(
        tempoPeriodMultiples: [
            PeriodMultiple(multiple: 1, weight: 1), PeriodMultiple(multiple: 2, weight: 1),
            PeriodMultiple(multiple: 4, weight: 1), PeriodMultiple(multiple: 0.5, weight: 1),
        ],
        chordScoring: .correlation, noChordScore: 0.3, chordSwitchPenalty: 0.3)
}
