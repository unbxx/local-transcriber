import Accelerate
import Foundation

// Key and chords from the reference's `chromagram`, `detect_key`,
// `detect_chords` and `refine_key`, on the instrumental at 22.05 kHz.
nonisolated enum TonalAnalysis {
    static let sampleRate = 22_050.0
    static let fftSize = 8192
    static let hop = 512
    static let lowestFrequency = 65.0
    static let highestFrequency = 2100.0
    static let switchPenalty = 0.06
    static let noChordScore = 0.72
    // The reference's mode names, which end up in analysis.json.
    static let major = "majeur", minor = "mineur"
    // Krumhansl–Kessler key profiles, tonic first.
    static let majorProfile = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    struct Chromagram: Sendable {
        var times: [Double]
        // Frame-major, 12 pitch classes per frame (C first), each frame
        // divided by its maximum.
        var values: [Double]
        var frameCount: Int { times.count }

        func frame(_ t: Int) -> ArraySlice<Double> { values[t * 12 ..< (t + 1) * 12] }
    }

    struct KeyCandidate: Equatable, Sendable {
        var correlation: Double
        var tonic: String
        var mode: String
    }

    static func analyse(
        _ signal: [Double], tuningCents: Double, beats: [Double], duration: Double
    ) -> (harmony: MusicAnalysis.Harmony, chroma: Chromagram) {
        let chroma = chromagram(signal, tuningSemitones: tuningCents / 100)
        let keys = keyCandidates(chroma)
        let chords = chords(chroma, beats: beats, duration: duration)
        let (key, relative) = refineKey(keys, chords: chords)
        let profile = (0..<12).map { pc in (0..<chroma.frameCount).reduce(0.0) { $0 + chroma.values[$1 * 12 + pc] } }
        let total = profile.reduce(0, +)
        let harmony = MusicAnalysis.Harmony(
            key: "\(key.tonic) \(key.mode)", relativeKey: "\(relative.tonic) \(relative.mode)",
            keyConfidence: keys[0].correlation.rounded(digits: 3),
            keyAlternatives: keys.filter { $0.tonic != key.tonic || $0.mode != key.mode }.prefix(3).map {
                "\($0.tonic) \($0.mode) (\(String(format: "%.2f", $0.correlation)))"
            },
            pitchClassProfile: profile.map { ($0 / total).rounded(digits: 3) },
            chords: chords)
        return (harmony, chroma)
    }

    // Each bin from 65 to 2100 Hz goes to its nearest pitch class (after the
    // tuning offset), weighted down to zero at 0.4 semitone off, from the
    // magnitude log-compressed against its 99.9th percentile.
    static func chromagram(_ signal: [Double], tuningSemitones: Double) -> Chromagram {
        let spectrogram = Spectrogram(signal, sampleRate: sampleRate, size: fftSize, hop: hop)
        let bins = spectrogram.binCount, frames = spectrogram.frameCount
        let selected = (0..<bins).filter {
            let f = spectrogram.frequency(ofBin: $0)
            return f >= lowestFrequency && f <= highestFrequency
        }
        let pitchClasses = selected.map { bin -> (pitchClass: Int, weight: Double) in
            let midi = Pitch.midi(hz: spectrogram.frequency(ofBin: bin)) - tuningSemitones
            let nearest = midi.roundedHalfEven
            return ((Int(nearest) % 12 + 12) % 12, min(1, max(0, 1 - 2.5 * abs(midi - nearest))))
        }

        let magnitude = spectrogram.magnitudes()
        let first = selected.first ?? 0
        let selectedMagnitudes = (0..<frames).flatMap { t in magnitude[t * bins + first ..< t * bins + first + selected.count] }
        let scale = 1 / (Numerics.percentile(selectedMagnitudes, 99.9) + 1e-12)

        var values = [Double](repeating: 0, count: frames * 12)
        for t in 0..<frames {
            for (j, bin) in pitchClasses.enumerated() {
                values[t * 12 + bin.pitchClass] += bin.weight * log1p(selectedMagnitudes[t * selected.count + j] * scale)
            }
            let maximum = values[t * 12 ..< (t + 1) * 12].max()! + 1e-9
            for pc in 0..<12 { values[t * 12 + pc] /= maximum }
        }
        return Chromagram(times: (0..<frames).map(spectrogram.time(ofFrame:)), values: values)
    }

    // All 24 keys by the correlation of the summed chroma with the rotated
    // profile, best first.
    static func keyCandidates(_ chroma: Chromagram) -> [KeyCandidate] {
        let profile = (0..<12).map { pc in (0..<chroma.frameCount).reduce(0.0) { $0 + chroma.values[$1 * 12 + pc] } }
        var candidates: [KeyCandidate] = []
        for (mode, template) in [(major, majorProfile), (minor, minorProfile)] {
            for tonic in 0..<12 {
                let rotated = (0..<12).map { template[($0 - tonic + 12) % 12] }
                candidates.append(KeyCandidate(
                    correlation: Numerics.correlation(profile, rotated), tonic: Pitch.names[tonic], mode: mode))
            }
        }
        // Python's descending tuple sort: correlation, then tonic, then mode.
        return candidates.sorted {
            ($0.correlation, $0.tonic, $0.mode) > ($1.correlation, $1.tonic, $1.mode)
        }
    }

    // Major and minor triads (root weighted 1.3) as unit vectors: C, Cm, C#, …
    static let templates: [(name: String, root: Int, quality: String, vector: [Double])] = (0..<12).flatMap { root in
        [("", [0, 4, 7]), ("m", [0, 3, 7])].map { quality, intervals in
            var vector = [Double](repeating: 0, count: 12)
            for interval in intervals { vector[(root + interval) % 12] = 1 }
            vector[root] += 0.3
            let norm = vDSP.dot(vector, vector).squareRoot()
            return (Pitch.names[root] + quality, root, quality, vector.map { $0 / norm })
        }
    }

    // One chord per beat: the cosine of the beat's mean chroma with each
    // template, or "N" (no chord) at a fixed 0.72; a Viterbi path where
    // changing chords costs 0.06. Consecutive beats with the same chord are
    // merged. Without beats the grid is every 0.5 s.
    static func chords(_ chroma: Chromagram, beats: [Double], duration: Double) -> [ChordSegment] {
        var edges = beats.isEmpty
            ? (0..<Int(((duration + 0.5) / 0.5).rounded(.up))).map { Double($0) * 0.5 }
            : [0] + beats + [duration]
        edges = Array(Set(edges.map { min(duration, max(0, $0)) })).sorted()

        var segments: [(start: Double, end: Double)] = [], scores: [[Double]] = []
        for (start, end) in zip(edges, edges.dropFirst()) {
            let frames = chroma.times.indices.filter { chroma.times[$0] >= start && chroma.times[$0] < end }
            guard !frames.isEmpty && end - start >= 0.05 else { continue }
            let mean = (0..<12).map { pc in frames.reduce(0.0) { $0 + chroma.values[$1 * 12 + pc] } / Double(frames.count) }
            let norm = vDSP.dot(mean, mean).squareRoot()
            var row = norm > 1e-6
                ? templates.map { template in vDSP.dot(template.vector, mean.map { $0 / norm }) }
                : [Double](repeating: 0, count: templates.count)
            row.append(noChordScore)
            segments.append((start, end))
            scores.append(row)
        }
        guard !segments.isEmpty else { return [] }

        let states = templates.count + 1
        var score = scores[0]
        var back = [[Int]](repeating: [Int](repeating: 0, count: states), count: segments.count)
        for i in 1..<segments.count {
            let best = Numerics.argmax(score)
            let change = score[best] - switchPenalty
            back[i] = (0..<states).map { score[$0] >= change ? $0 : best }
            score = (0..<states).map { max(score[$0], change) + scores[i][$0] }
        }
        var path = [Numerics.argmax(score)]
        for i in stride(from: segments.count - 1, to: 0, by: -1) { path.append(back[i][path.last!]) }
        path.reverse()

        var chords: [ChordSegment] = []
        for (segment, state) in zip(segments, path) {
            let (name, root, quality) = state < templates.count
                ? (templates[state].name, templates[state].root, templates[state].quality)
                : ("N", -1, "")
            if chords.last?.chord == name {
                chords[chords.count - 1].end = segment.end.rounded(digits: 3)
            } else {
                chords.append(ChordSegment(
                    start: segment.start.rounded(digits: 3), end: segment.end.rounded(digits: 3), chord: name,
                    root: root, quality: quality))
            }
        }
        return chords
    }

    // Chooses between the best key and its relative (C major ↔ A minor) by
    // which tonic chord sounds longest, with a bonus for opening (0.15) and
    // closing (0.1) the song.
    typealias Key = (tonic: String, mode: String)

    static func refineKey(_ keys: [KeyCandidate], chords: [ChordSegment]) -> (key: Key, relative: Key) {
        let best: Key = (keys[0].tonic, keys[0].mode)
        let index = Pitch.names.firstIndex(of: best.tonic)!
        let relative: Key = best.mode == major
            ? (Pitch.names[(index + 9) % 12], minor)
            : (Pitch.names[(index + 3) % 12], major)
        let real = chords.filter { $0.chord != "N" }
        guard let opening = real.first, let closing = real.last else { return (best, relative) }

        func tonicScore(_ key: Key) -> Double {
            let name = key.tonic + (key.mode == minor ? "m" : "")
            let duration = real.filter { $0.chord == name }.reduce(0.0) { $0 + ($1.end - $1.start) }
            let total = real.reduce(0.0) { $0 + ($1.end - $1.start) }
            return duration / total + (opening.chord == name ? 0.15 : 0) + (closing.chord == name ? 0.1 : 0)
        }
        if tonicScore(relative) > tonicScore(best) { return (relative, best) }
        return (best, relative)
    }
}
