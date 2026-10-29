import Foundation

// Vocal notes from the melody track, from the reference's `segment_notes`:
// the song's tuning offset (circular mean of the deviation from the semitone
// grid), a 7-frame median that ignores unvoiced frames, runs of the same
// rounded pitch with gaps up to 50 ms bridged, at least 90 ms long. Short
// notes more than an octave from the median note (bass or kick leaking into
// the melody) are dropped.
nonisolated enum NoteSegmentation {
    static let minimumDuration = 0.09
    static let maximumGap = 0.05
    static let smoothingFrames = 7
    static let outlierSemitones = 12.0
    static let outlierDuration = 0.2

    // `level` sets the velocities; the reference passes the melody salience.
    static func notes(
        times: [Double], f0: [Double], voiced: [Bool], level: [Double]
    ) -> (notes: [VocalNote], tuningCents: Double) {
        let n = times.count
        let hop = n > 1 ? times[1] - times[0] : 0.01
        let midi = (0..<n).map { voiced[$0] ? Pitch.midi(hz: max(f0[$0], 1)) : .nan }

        let pitched = midi.filter { !$0.isNaN }
        var tuning = 0.0
        if !pitched.isEmpty {
            let deviations = pitched.map { 2 * Double.pi * ($0 - $0.roundedHalfEven) }
            let count = Double(pitched.count)
            let x = deviations.reduce(0) { $0 + cos($1) } / count, y = deviations.reduce(0) { $0 + sin($1) } / count
            tuning = atan2(y, x) / (2 * Double.pi)
        }

        let radius = smoothingFrames / 2
        let smoothed = (0..<n).map { i -> Double in
            guard !midi[i].isNaN else { return .nan }
            let window = midi[max(0, i - radius)...min(n - 1, i + radius)].filter { !$0.isNaN }.map { $0 - tuning }
            return Numerics.median(window)
        }
        let rounded = smoothed.map(\.roundedHalfEven)

        var notes: [(note: VocalNote, level: Double)] = []
        let gapFrames = Int((maximumGap / hop).roundedHalfEven)
        var i = 0
        while i < n {
            guard !rounded[i].isNaN else {
                i += 1
                continue
            }
            let pitch = rounded[i]
            var j = i, last = i
            while j + 1 < n {
                if rounded[j + 1] == pitch {
                    j += 1
                    last = j
                } else if rounded[j + 1].isNaN && j + 1 - last <= gapFrames {
                    j += 1
                } else {
                    break
                }
            }
            let start = times[i], end = times[last] + hop
            if end - start >= minimumDuration {
                let median = Numerics.median(smoothed[i...last].filter { !$0.isNaN })
                let note = VocalNote(
                    start: start.rounded(digits: 3), end: end.rounded(digits: 3), midi: Int(pitch),
                    name: Pitch.name(midi: pitch), centsOff: Int(((median - pitch) * 100).roundedHalfEven), velocity: 0)
                notes.append((note, Numerics.mean(Array(level[i...last]))))
            }
            i = last + 1
        }

        if notes.count > 4 {
            let median = Numerics.median(notes.map { Double($0.note.midi) })
            notes.removeAll {
                abs(Double($0.note.midi) - median) > outlierSemitones && $0.note.end - $0.note.start < outlierDuration
            }
        }
        let loudest = notes.map(\.level).max() ?? 0
        let reference = loudest == 0 ? 1 : loudest
        let result = notes.map { entry in
            var note = entry.note
            note.velocity = Int(min(127, max(1, 40 + 87 * entry.level / reference)))
            return note
        }
        return (result, tuning * 100)
    }
}
