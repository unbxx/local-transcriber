import Foundation

// analysis.json exactly as the reference writes it (Python's
// `json.dump(analysis, fh, indent=1)`): its key order, one-space indent,
// float repr and ASCII escapes, so the two files can be compared byte for
// byte. JSONEncoder orders keys its own way and writes 1.0 as 1.
extension MusicAnalysis {
    nonisolated func jsonData() -> Data {
        var text = ""
        json.write(to: &text, level: 0)
        return Data(text.utf8)
    }

    nonisolated var json: JSONValue {
        .object([
            ("meta", .object([
                ("duration_s", .number(meta.durationSeconds)), ("samplerate", .integer(meta.sampleRate)),
                ("separation", .string(meta.separation)),
            ])),
            ("vocals", .object([
                ("voiced_ratio", .number(vocals.voicedRatio)),
                ("range", vocals.range.map { .array($0.map(JSONValue.string)) } ?? .null),
                ("median_note", vocals.medianNote.map(JSONValue.string) ?? .null),
                ("tuning_offset_cents", .number(vocals.tuningOffsetCents)),
                ("notes", .array(vocals.notes.map(\.json))),
            ])),
            ("rhythm", .object([("bpm", .number(rhythm.bpm)), ("beats", .array(rhythm.beats.map(JSONValue.number)))])),
            ("harmony", .object([
                ("key", .string(harmony.key)), ("relative_key", .string(harmony.relativeKey)),
                ("key_confidence", .number(harmony.keyConfidence)),
                ("key_alternatives", .array(harmony.keyAlternatives.map(JSONValue.string))),
                ("pitch_class_profile", .object(zip(Pitch.names, harmony.pitchClassProfile.map(JSONValue.number)).map { ($0, $1) })),
                ("chords", .array(harmony.chords.map(\.json))),
            ])),
            ("loudness", loudness.json),
            ("timbre", .object([
                ("mix", timbre.mix.json), ("vocals", timbre.vocals.json), ("instrumental", timbre.instrumental.json),
            ])),
        ])
    }
}

extension VocalNote {
    nonisolated var json: JSONValue {
        .object([
            ("start", .number(start)), ("end", .number(end)), ("midi", .integer(midi)), ("name", .string(name)),
            ("cents_off", .integer(centsOff)), ("velocity", .integer(velocity)),
        ])
    }
}

extension ChordSegment {
    nonisolated var json: JSONValue {
        .object([
            ("start", .number(start)), ("end", .number(end)), ("chord", .string(chord)), ("root", .integer(root)),
            ("quality", .string(quality)),
        ])
    }
}

extension MusicAnalysis.Loudness {
    nonisolated var json: JSONValue {
        var members: [(String, JSONValue)] = [("lufs_integrated", lufsIntegrated.map(JSONValue.number) ?? .null)]
        if let peakDBFS, let rmsDBFS, let crestFactorDB {
            members += [
                ("loudness_range_lu", loudnessRangeLU.map(JSONValue.number) ?? .null), ("peak_dbfs", .number(peakDBFS)),
                ("rms_dbfs", .number(rmsDBFS)), ("crest_factor_db", .number(crestFactorDB)),
            ]
        }
        return .object(members)
    }
}

extension MusicAnalysis.Timbre {
    nonisolated var json: JSONValue {
        .object([
            ("spectral_centroid_hz", .integer(spectralCentroidHz)),
            ("energy_distribution_pct", .object(zip(Self.bands, energyDistributionPct).map { ($0.name, .number($1)) })),
            ("spectral_flatness", .number(spectralFlatness)), ("stereo_width", .number(stereoWidth)),
            ("stereo_correlation", .number(stereoCorrelation)),
        ])
    }
}

nonisolated indirect enum JSONValue: Equatable, Sendable {
    // Members in order.
    case object([(String, JSONValue)])
    case array([JSONValue])
    case number(Double)
    case integer(Int)
    case string(String)
    case null

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.object(let a), .object(let b)): a.map(\.0) == b.map(\.0) && a.map(\.1) == b.map(\.1)
        case (.array(let a), .array(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.integer(let a), .integer(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.null, .null): true
        default: false
        }
    }

    // Python's json encoder with indent=1.
    func write(to text: inout String, level: Int) {
        func container<T>(_ open: String, _ close: String, _ items: [T], _ body: (T, inout String) -> Void) {
            guard !items.isEmpty else { return text += open + close }
            let indent = "\n" + String(repeating: " ", count: level + 1)
            text += open
            for (index, item) in items.enumerated() {
                text += (index == 0 ? "" : ",") + indent
                body(item, &text)
            }
            text += "\n" + String(repeating: " ", count: level) + close
        }
        switch self {
        case .object(let members):
            container("{", "}", members) { member, text in
                text += Self.quoted(member.0) + ": "
                member.1.write(to: &text, level: level + 1)
            }
        case .array(let items):
            container("[", "]", items) { item, text in item.write(to: &text, level: level + 1) }
        case .number(let value):
            // Swift's description is the same shortest round-trip repr as Python's.
            text += value.isNaN ? "NaN" : value.isInfinite ? (value > 0 ? "Infinity" : "-Infinity") : value.description
        case .integer(let value):
            text += String(value)
        case .string(let value):
            text += Self.quoted(value)
        case .null:
            text += "null"
        }
    }

    // ensure_ascii: everything outside printable ASCII as \uXXXX (UTF-16).
    private static func quoted(_ string: String) -> String {
        var result = "\""
        for unit in string.utf16 {
            switch unit {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            case 0x08: result += "\\b"
            case 0x0C: result += "\\f"
            case 0x20..<0x7F: result.unicodeScalars.append(Unicode.Scalar(unit)!)
            default: result += String(format: "\\u%04x", unit)
            }
        }
        return result + "\""
    }
}
