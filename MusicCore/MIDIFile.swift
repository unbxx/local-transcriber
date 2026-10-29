import Foundation

// Standard MIDI files, from the reference's `write_midi`: format 1, 480 ticks
// per quarter note, a first track with the tempo and 4/4, then one track per
// part. Times in seconds become ticks at the song's tempo.
nonisolated enum MIDIFile {
    struct Note: Equatable, Sendable {
        var start: Double
        var end: Double
        var pitch: Int
        var velocity: Int
    }

    struct Track: Sendable {
        var name: String
        // General MIDI program, 0-based.
        var program: Int
        var channel: Int
        var notes: [Note]
    }

    static let ticksPerQuarter = 480

    // The reference's transcription.mid: the vocal notes (choir aahs), each
    // chord as a root-position triad plus octave from C3 (warm pad) and its
    // root from C2 (fingered bass). No-chord segments are left out.
    static func transcription(_ analysis: MusicAnalysis) -> Data {
        let chords = analysis.harmony.chords.filter { $0.chord != "N" }
        return data(bpm: analysis.rhythm.bpm > 0 ? analysis.rhythm.bpm : 120, tracks: [
            Track(name: "Vocals", program: 52, channel: 0, notes: analysis.vocals.notes.map {
                Note(start: $0.start, end: $0.end, pitch: $0.midi, velocity: $0.velocity)
            }),
            Track(name: "Chords", program: 89, channel: 1, notes: chords.flatMap { chord in
                chordPitches(chord).map { Note(start: chord.start, end: chord.end, pitch: $0, velocity: 70) }
            }),
            Track(name: "Bass", program: 33, channel: 2, notes: chords.map {
                Note(start: $0.start, end: $0.end, pitch: 36 + $0.root, velocity: 90)
            }),
        ])
    }

    static func chordPitches(_ chord: ChordSegment) -> [Int] {
        let root = 48 + chord.root, third = chord.quality == "m" ? 3 : 4
        return [root, root + third, root + 7, root + 12]
    }

    static func data(bpm: Double, tracks: [Track]) -> Data {
        func tick(_ seconds: Double) -> Int { Int((seconds * bpm / 60 * Double(ticksPerQuarter)).roundedHalfEven) }
        let microsecondsPerQuarter = Int(60_000_000 / bpm)
        var chunks = [chunk([
            [0x00, 0xFF, 0x51, 0x03] + bigEndian(UInt32(microsecondsPerQuarter)).suffix(3),
            [0x00, 0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08],
        ])]

        for track in tracks {
            let channel = UInt8(track.channel & 0x0F)
            // Note-offs before note-ons at the same tick; otherwise in order.
            var events: [(tick: Int, isOn: Bool, order: Int, message: [UInt8])] = []
            for note in track.notes {
                let start = tick(note.start), pitch = UInt8(clamping: note.pitch)
                events.append((start, true, events.count, [0x90 | channel, pitch, UInt8(clamping: note.velocity)]))
                events.append((max(tick(note.end), start + 1), false, events.count, [0x80 | channel, pitch, 0]))
            }
            events.sort { ($0.tick, $0.isOn ? 1 : 0, $0.order) < ($1.tick, $1.isOn ? 1 : 0, $1.order) }

            let name = Array(track.name.utf8)
            var messages: [[UInt8]] = [
                [0x00, 0xFF, 0x03] + variableLength(name.count) + name,
                [0x00, 0xC0 | channel, UInt8(clamping: track.program)],
            ]
            var last = 0
            for event in events {
                messages.append(variableLength(event.tick - last) + event.message)
                last = event.tick
            }
            chunks.append(chunk(messages))
        }

        let header = Array("MThd".utf8) + bigEndian(UInt32(6)) + bigEndian(UInt16(1))
            + bigEndian(UInt16(chunks.count)) + bigEndian(UInt16(ticksPerQuarter))
        return Data(header + chunks.joined())
    }

    private static func chunk(_ events: [[UInt8]]) -> [UInt8] {
        let body = Array(events.joined()) + [0x00, 0xFF, 0x2F, 0x00]
        return Array("MTrk".utf8) + bigEndian(UInt32(body.count)) + body
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    // MIDI variable-length quantity: 7 bits per byte, high bit on all but the last.
    static func variableLength(_ value: Int) -> [UInt8] {
        var value = value
        var bytes = [UInt8(value & 0x7F)]
        value >>= 7
        while value > 0 {
            bytes.insert(UInt8(value & 0x7F) | 0x80, at: 0)
            value >>= 7
        }
        return bytes
    }
}
