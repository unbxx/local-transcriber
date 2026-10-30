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

## Settings

`MusicAnalyzer.analyse(_:settings:)` takes `AnalysisSettings`:

- `.standard`, the default, is tuned on real recordings (see Results).
- `.reference` reproduces `audiolens.py` exactly. The tests check that its
  `analysis.json` and MIDI file are byte-identical to the reference's.

They differ only in the tempo and chord steps; separation, melody, notes, key,
loudness and timbre are the reference's in both.

| | `.reference` | `.standard` |
| --- | --- | --- |
| Tempo score of a beat period | autocorrelation at the period | also at ½, 2 and 4 periods (eighth notes, half bar, bar) |
| Chord score per beat | cosine with the triad | correlation (chroma and triad minus their mean) |
| Score of "no chord" | 0.72 | 0.3 |
| Cost of changing chords | 0.06 | 0.3 |

Why: in real mixes the reference locked trap at 150 BPM on 100 (2/3 of the
tempo; the subdivision term rules that out), and drums and noise raise every
pitch class, which pushed the cosine of most beats below 0.72: no chord most of
the time. Correlation ignores that flat floor; the higher switch cost keeps the
chords from flickering.

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

On the AudioLens test song (`Tests/MusicCoreTests/Fixtures`) the `.reference`
settings write the same `analysis.json` as the reference, byte for byte, and the
same MIDI file. The reference's `eval_truth.py` scores it like the reference:
note F1 1.00, 99.4 BPM (true: 100), A minor, the right chord 96.6 % of the
time. The brief's thresholds were F1 ≥ 0.90, ±1 BPM, A minor and ≥ 90 %. The
`.standard` settings give the same notes, tempo and key, and the right chord
96.4 % of the time.

On real recordings (measured by hand, not in the tests): 63 beats and loops
from sample packs whose file names give the tempo, 30 of them also the key —
mostly trap at 140–167 BPM, some at 93–104 and 170–180 — and five released
songs. There is no chord truth for these, so the chord rows are stand-ins: how
much of the music gets a chord, how much of that fits the labelled key, and how
often the chord changes.

| 63 labelled files | `.reference` | `.standard` |
| --- | --- | --- |
| Tempo within 2 % | 22 | 32 |
| Tempo at half or double | 11 | 25 |
| Tempo at 2/3 or 3/2 | 23 | 4 |
| Tempo otherwise wrong | 7 | 2 |
| Time with a chord | 38 % | 99 % |
| Chord time that fits the key | 67 % | 75 % |
| Chord changes per minute (median) | 6.5 | 22 |
| Key exact (with the relative key) | 11 of 30 (18) | 11 of 30 (18) |

On the five songs the tempo stays the same and the time with a chord goes from
24 % to 99 %.

Also checked by hand, outside the tests: a 48 kHz AAC version of the song
scores the same; a 3-minute file (the song eight times) and a version made mono
give byte-identical `analysis.json` files from both implementations.

On an M1 Pro (release build) the 22 s song takes 0.6 s and the 3-minute file
6 s with a peak memory footprint of 2.0 GB. The reference takes 20 s and 3.7 GB
for the same file. Memory grows with the length of the audio, because whole
spectrograms are kept in Double precision; that is worth reducing before the
app uses this.

## Limits

These are the reference's, kept in both settings:

- Separation without a model: a harmonic mask around the melody in the centre
  of the stereo image (AudioLens can use Demucs instead; MusicCore does not).
  It works for a clear lead vocal and less well for choirs, rap, or mono
  recordings where another instrument is louder than the voice. The mono
  version of the test song finds 15 of 21 notes (F1 0.64), the same as the
  reference. In real mixes the melody often follows the bass, which is in the
  centre too: in four of the five songs half or more of the notes are below C3.
- The melody tracker always finds a melody, so instrumentals get "vocal"
  notes from their lead instrument.
- Chords are major and minor triads only.
- Key detection is right for about a third of the labelled files, and for
  about 60 % if the relative major or minor counts.

And of the `.standard` tempo: trap often comes out at half its labelled tempo
(75 instead of 150). That keeps the bars aligned, two to a section.
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
(gap bridging, a click track, a trap bar that the reference hears at 2/3 of its
tempo, chords above a drum floor, loudness of a sine). Tests that compare with
the reference use the `.reference` settings.
`Tests/MusicCoreTests/Fixtures/README.md` says where each fixture comes from.
