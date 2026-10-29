import Foundation

// The reference's analysis.json, field for field: its key names, units,
// rounding and nulls, so results of either implementation can be compared
// (and its eval_truth.py reads ours). Text values (mode names, separation
// method, band names) stay as the reference writes them. Decoding reads either
// file; `jsonData()` (AnalysisJSON.swift) writes it.
nonisolated struct MusicAnalysis: Decodable, Equatable, Sendable {
    var meta: Meta
    var vocals: Vocals
    var rhythm: Rhythm
    var harmony: Harmony
    var loudness: Loudness
    var timbre: TimbreSet

    struct Meta: Decodable, Equatable, Sendable {
        var durationSeconds: Double
        var sampleRate: Int
        var separation: String

        enum CodingKeys: String, CodingKey {
            case durationSeconds = "duration_s", sampleRate = "samplerate", separation
        }
    }

    struct Vocals: Decodable, Equatable, Sendable {
        var voicedRatio: Double
        // Lowest and highest note name; nil without notes.
        var range: [String]?
        var medianNote: String?
        var tuningOffsetCents: Double
        var notes: [VocalNote]

        enum CodingKeys: String, CodingKey {
            case voicedRatio = "voiced_ratio", range, medianNote = "median_note"
            case tuningOffsetCents = "tuning_offset_cents", notes
        }
    }

    struct Rhythm: Decodable, Equatable, Sendable {
        var bpm: Double
        var beats: [Double]
    }

    struct Harmony: Decodable, Equatable, Sendable {
        // "A mineur", "C majeur": the reference's Dutch mode names.
        var key: String
        var relativeKey: String
        var keyConfidence: Double
        // Up to three, "C majeur (0.84)".
        var keyAlternatives: [String]
        // Share of each pitch class, C first; an object keyed by note name.
        var pitchClassProfile: [Double]
        var chords: [ChordSegment]

        enum CodingKeys: String, CodingKey {
            case key, relativeKey = "relative_key", keyConfidence = "key_confidence"
            case keyAlternatives = "key_alternatives", pitchClassProfile = "pitch_class_profile", chords
        }

        init(
            key: String, relativeKey: String, keyConfidence: Double, keyAlternatives: [String],
            pitchClassProfile: [Double], chords: [ChordSegment]
        ) {
            self.key = key
            self.relativeKey = relativeKey
            self.keyConfidence = keyConfidence
            self.keyAlternatives = keyAlternatives
            self.pitchClassProfile = pitchClassProfile
            self.chords = chords
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            relativeKey = try container.decode(String.self, forKey: .relativeKey)
            keyConfidence = try container.decode(Double.self, forKey: .keyConfidence)
            keyAlternatives = try container.decode([String].self, forKey: .keyAlternatives)
            pitchClassProfile = try container.decodeValues(named: Pitch.names, forKey: .pitchClassProfile)
            chords = try container.decode([ChordSegment].self, forKey: .chords)
        }
    }

    // Like the reference, audio shorter than one 400 ms block has only a null
    // integrated loudness.
    struct Loudness: Decodable, Equatable, Sendable {
        var lufsIntegrated: Double?
        var loudnessRangeLU: Double?
        var peakDBFS: Double?
        var rmsDBFS: Double?
        var crestFactorDB: Double?

        enum CodingKeys: String, CodingKey {
            case lufsIntegrated = "lufs_integrated", loudnessRangeLU = "loudness_range_lu", peakDBFS = "peak_dbfs"
            case rmsDBFS = "rms_dbfs", crestFactorDB = "crest_factor_db"
        }
    }

    struct Timbre: Decodable, Equatable, Sendable {
        static let bands: [(name: String, range: Range<Double>)] = [
            ("sub (<60 Hz)", 0 ..< 60), ("laag (60-250)", 60 ..< 250), ("laag-mid (250-2k)", 250 ..< 2000),
            ("hoog-mid (2k-6k)", 2000 ..< 6000), ("lucht (>6k)", 6000 ..< 30_000),
        ]

        var spectralCentroidHz: Int
        // Percentage of the energy in each of `bands`; an object keyed by band name.
        var energyDistributionPct: [Double]
        var spectralFlatness: Double
        var stereoWidth: Double
        var stereoCorrelation: Double

        enum CodingKeys: String, CodingKey {
            case spectralCentroidHz = "spectral_centroid_hz", energyDistributionPct = "energy_distribution_pct"
            case spectralFlatness = "spectral_flatness", stereoWidth = "stereo_width"
            case stereoCorrelation = "stereo_correlation"
        }

        init(
            spectralCentroidHz: Int, energyDistributionPct: [Double], spectralFlatness: Double, stereoWidth: Double,
            stereoCorrelation: Double
        ) {
            self.spectralCentroidHz = spectralCentroidHz
            self.energyDistributionPct = energyDistributionPct
            self.spectralFlatness = spectralFlatness
            self.stereoWidth = stereoWidth
            self.stereoCorrelation = stereoCorrelation
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            spectralCentroidHz = try container.decode(Int.self, forKey: .spectralCentroidHz)
            energyDistributionPct = try container.decodeValues(named: Self.bands.map(\.name), forKey: .energyDistributionPct)
            spectralFlatness = try container.decode(Double.self, forKey: .spectralFlatness)
            stereoWidth = try container.decode(Double.self, forKey: .stereoWidth)
            stereoCorrelation = try container.decode(Double.self, forKey: .stereoCorrelation)
        }
    }

    struct TimbreSet: Decodable, Equatable, Sendable {
        var mix: Timbre
        var vocals: Timbre
        var instrumental: Timbre
    }
}

nonisolated struct VocalNote: Decodable, Equatable, Sendable {
    var start: Double
    var end: Double
    var midi: Int
    var name: String
    // Median deviation from `midi`, relative to the song's tuning.
    var centsOff: Int
    var velocity: Int

    enum CodingKeys: String, CodingKey {
        case start, end, midi, name, centsOff = "cents_off", velocity
    }
}

nonisolated struct ChordSegment: Decodable, Equatable, Sendable {
    var start: Double
    var end: Double
    // "Am", "F#", or "N" for no chord.
    var chord: String
    // Pitch class of the root, −1 for "N".
    var root: Int
    // "m" for minor, "" for major and "N".
    var quality: String
}

nonisolated enum Pitch {
    static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    static func midi(hz: Double) -> Double { 69 + 12 * log2(hz / 440) }

    // "A4" for 69; rounds half to even like the reference.
    static func name(midi: Double) -> String {
        let m = Int(midi.roundedHalfEven)
        let pitchClass = (m % 12 + 12) % 12
        return names[pitchClass] + String((m - pitchClass) / 12 - 1)
    }
}

// JSON objects with fixed keys (Python dicts) decoded as arrays.
private struct NameKey: CodingKey {
    let stringValue: String
    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

nonisolated private extension KeyedDecodingContainer {
    func decodeValues(named names: [String], forKey key: Key) throws -> [Double] {
        let object = try nestedContainer(keyedBy: NameKey.self, forKey: key)
        return try names.map { try object.decode(Double.self, forKey: NameKey($0)) }
    }
}
