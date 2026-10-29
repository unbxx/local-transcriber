# MusicCore

Music analysis for Local Transcriber, ported to Swift from AudioLens
(`audiolens.py`): vocals and instrumental, the sung notes, tempo and beats, key
and chords, loudness and timbre, exported as `analysis.json`, a Markdown music
transcript and a MIDI file.

This is phase 1: a SwiftPM target with tests. The app does not use it, and the
Xcode project, app target, signing and UI are unchanged. The folder sits outside
`LocalTranscriber/`, so the project's synchronized group does not pick it up.

## Use

```swift
let result = try await MusicAnalyzer.analyse(contentsOf: url)   // any file AVFoundation reads
try result.analysis.jsonData().write(to: folder.appending(path: "analysis.json"))
let markdown = MusicMarkdownRenderer.render(result.analysis, sourceURL: url)
let midi = MIDIFile.transcription(result.analysis)
```

`MusicAnalyzer.Result` also holds the stems (`vocals`, `instrumental`, stereo at
44.1 kHz) and the per-frame data (melody f0 and voicing, onset envelope, beats,
chroma). Everything runs locally with AVFoundation and Accelerate; there is no
network access, Python or third-party package.

The target has the app's default isolation (`MainActor`); the analysis types
are `nonisolated` and `Sendable`, so the analysis runs on any task. It takes no
UI or app types.

## Steps

| Step | Reference | Swift |
| --- | --- | --- |
| Load: stereo, 44.1 kHz | `load_audio` (ffmpeg) | `AudioLoader` (AVAssetReader) |
| Melody f0: harmonic salience, Viterbi, voicing | `melody_f0` | `Melody` |
| Vocal separation: harmonic mask, inverse STFT | `harmonic_mask`, `separate_and_track` | `Separation` |
| Notes | `segment_notes` | `NoteSegmentation` |
| Onsets, tempo, beats | `onset_envelope`, `estimate_tempo`, `track_beats` | `BeatTracker` |
| Chroma, key, chords | `chromagram`, `detect_key`, `detect_chords`, `refine_key` | `TonalAnalysis` |
| Loudness, timbre | `loudness`, `timbre` | `LoudnessMeter`, `TimbreAnalysis` |
| Whole analysis | `analyze` | `MusicAnalyzer` |
| analysis.json | `json.dump` | `MusicAnalysis.jsonData()` |
| MIDI | `write_midi` | `MIDIFile` |
| Markdown transcript | (new) | `MusicMarkdownRenderer` |

The scipy and numpy behaviour the reference depends on is reproduced exactly
(`Spectrogram`, `Numerics`): `stft`/`istft` with their padding and scaling (the
FFT is vDSP's), `resample_poly(x, 1, 2)`, numpy percentiles, `medfilt`, and
Python's rounding. That keeps every step comparable with the reference on its
own.

## Results

On the AudioLens test song (`Tests/MusicCoreTests/Fixtures`) the port writes
the same `analysis.json` as the reference, byte for byte, and the same MIDI
file. The reference's `eval_truth.py` scores it like the reference: note F1
1.00, 99.4 BPM (true: 100), A minor, the right chord 96.6 % of the time. The
brief's thresholds were F1 ≥ 0.90, ±1 BPM, A minor and ≥ 90 %.

Also checked by hand, outside the tests: a 48 kHz AAC version of the song
scores the same; a 3-minute file (the song eight times) and a version made mono
give byte-identical `analysis.json` files from both implementations.

On an M1 Pro (release build) the 22 s song takes 0.6 s and the 3-minute file
6 s with a peak memory footprint of 2.0 GB. The reference takes 20 s and 3.7 GB
for the same file. Memory grows with the length of the audio, because whole
spectrograms are kept in Double precision; that is worth reducing before the
app uses this.

## Limits

These are the reference's, kept on purpose:

- Separation without a model: a harmonic mask around the melody in the centre
  of the stereo image (AudioLens can use Demucs instead; MusicCore does not).
  It works for a clear lead vocal and less well for choirs, rap, or mono
  recordings where another instrument is louder than the voice. The mono
  version of the test song finds 15 of 21 notes (F1 0.64), the same as the
  reference.
- Chords are major and minor triads only.
- Text values in `analysis.json` stay as the reference writes them: Dutch mode
  names ("A mineur"), band names and the separation method. The Markdown and
  MIDI use English.

New in the Markdown transcript: bars assume 4/4 and start on the beat that most
chord changes fall on (the reference has no downbeats). A vocal note starting
up to 80 ms before a bar line belongs to the new bar.

Not ported: the replica synthesis and comparison, the overview plot and writing
the stems as WAV files.

## Tests

`swift test` at the repository root runs `MusicCoreTests` (Swift Testing) next
to `TranscriptCoreTests`; a debug run of the music tests takes about 10 s. They
compare each step with the reference's results for the test song
(`reference-*.json`), check the acceptance criteria end to end, the exports
(byte-identical JSON and MIDI, a golden Markdown transcript) and synthetic cases
(gap bridging, a click track, chord changes, loudness of a sine).
`Tests/MusicCoreTests/Fixtures/README.md` says where each fixture comes from.
