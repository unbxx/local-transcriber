import Foundation

// A music transcript in the app's Markdown style: the title and metadata
// lines of TranscriptMarkdownRenderer (Source, Duration, then Tempo and Key),
// then one section per bar with its chords and vocal notes, each with the
// time it starts. Bars assume 4/4: every fourth beat, from the beat most
// chord changes fall on.
nonisolated enum MusicMarkdownRenderer {
    struct Bar: Equatable {
        // "Bar 3", or "Pickup" before the first bar.
        var label: String
        var start: Double
        var end: Double
        // Chords sounding in the bar, from when they sound in it.
        var chords: [(name: String, time: Double)]
        var notes: [VocalNote]

        static func == (lhs: Bar, rhs: Bar) -> Bool {
            lhs.label == rhs.label && lhs.start == rhs.start && lhs.end == rhs.end && lhs.notes == rhs.notes
                && lhs.chords.map(\.name) == rhs.chords.map(\.name) && lhs.chords.map(\.time) == rhs.chords.map(\.time)
        }
    }

    // A vocal note starting this much before a bar line belongs to that bar.
    static let anticipation = 0.08
    // A chord has to sound this long in a bar to be listed there.
    static let minimumChordOverlap = 0.05

    static func render(_ analysis: MusicAnalysis, sourceURL: URL) -> String {
        let metadata = [
            "**Source:** `\(sourceURL.lastPathComponent)`",
            "**Duration:** \(timestamp(analysis.meta.durationSeconds.rounded()))",
            "**Tempo:** \(String(format: "%.1f", analysis.rhythm.bpm)) BPM",
            "**Key:** \(keyName(analysis.harmony.key))",
        ]
        var markdown = "# \(sourceURL.deletingPathExtension().lastPathComponent)\n\n"
        markdown += metadata.joined(separator: "  \n")
        markdown += "\n\n## Transcript"

        for bar in bars(analysis) {
            var lines: [String] = []
            if !bar.chords.isEmpty {
                lines.append("Chords: " + bar.chords.map { "\(chordName($0.name)) \(time($0.time))" }.joined(separator: " · "))
            }
            if !bar.notes.isEmpty {
                lines.append("Vocals: " + bar.notes.map { "\($0.name) \(time($0.start))" }.joined(separator: " · "))
            }
            markdown += "\n\n### \(bar.label) · \(time(bar.start))"
            if !lines.isEmpty { markdown += "\n\n" + lines.joined(separator: "  \n") }
        }
        return markdown + "\n"
    }

    static func bars(_ analysis: MusicAnalysis) -> [Bar] {
        let duration = analysis.meta.durationSeconds
        var beats = analysis.rhythm.beats
        if beats.count < 2 {
            let bpm = analysis.rhythm.bpm > 0 ? analysis.rhythm.bpm : 120
            beats = Array(stride(from: 0, to: duration, by: 60 / bpm))
        }
        let phase = downbeatPhase(beats: beats, chords: analysis.harmony.chords)
        let downbeats = stride(from: phase, to: beats.count, by: 4).map { beats[$0] }
        guard let first = downbeats.first else { return [] }

        var bars: [Bar] = []
        if first > 0 { bars.append(Bar(label: "Pickup", start: 0, end: first, chords: [], notes: [])) }
        for (index, start) in downbeats.enumerated() {
            let end = index + 1 < downbeats.count ? downbeats[index + 1] : max(duration, start)
            bars.append(Bar(label: "Bar \(index + 1)", start: start, end: end, chords: [], notes: []))
        }
        for note in analysis.vocals.notes {
            let index = bars.lastIndex { $0.start <= note.start + anticipation } ?? 0
            bars[index].notes.append(note)
        }
        for index in bars.indices {
            bars[index].chords = analysis.harmony.chords.compactMap { chord in
                let from = max(chord.start, bars[index].start), to = min(chord.end, bars[index].end)
                return to - from > minimumChordOverlap ? (chord.chord, from) : nil
            }
        }
        // A lead-in with no notes and no chords says nothing.
        if bars.first?.label == "Pickup" && bars[0].notes.isEmpty && bars[0].chords.allSatisfy({ $0.name == "N" }) {
            bars.removeFirst()
        }
        return bars
    }

    // The beat (0–3) that starts the bars: the one most chord changes fall on
    // (within 50 ms), the earliest on a tie.
    static func downbeatPhase(beats: [Double], chords: [ChordSegment]) -> Int {
        var votes = [0, 0, 0, 0]
        for chord in chords.dropFirst() {
            guard let nearest = beats.indices.min(by: { abs(beats[$0] - chord.start) < abs(beats[$1] - chord.start) }),
                  abs(beats[nearest] - chord.start) < 0.05 else { continue }
            votes[nearest % 4] += 1
        }
        return votes.indices.max { votes[$0] < votes[$1] }!
    }

    // "A mineur" → "A minor".
    static func keyName(_ key: String) -> String {
        key.replacingOccurrences(of: " majeur", with: " major").replacingOccurrences(of: " mineur", with: " minor")
    }

    static func chordName(_ chord: String) -> String { chord == "N" ? "N.C." : chord }

    // 00:01:02.35
    static func time(_ seconds: Double) -> String {
        let centiseconds = max(0, Int((seconds * 100).rounded()))
        return String(
            format: "%02d:%02d:%02d.%02d", centiseconds / 360_000, centiseconds / 6000 % 60, centiseconds / 100 % 60,
            centiseconds % 100)
    }

    // As in TranscriptMarkdownRenderer.
    private static func timestamp(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds % 3600) / 60, totalSeconds % 60)
    }
}
