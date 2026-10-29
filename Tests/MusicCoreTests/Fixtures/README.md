# MusicCore fixtures

- `test_song.wav`, `test_truth.json`: made by AudioLens's `make_test_song.py`
  (sha256 `e29fa83a…`). A 21.9 s stereo song at 100 BPM in A minor: two lead-in
  drum beats, then Am F C G twice (one bar each) with 21 known vocal notes.
  The truth file lists the notes, chords, tempo and key.
- `reference-analysis.json`, `reference-frames.json`: the Python reference's
  results for `test_song.wav` (AudioLens `reference/audiolens.py`, sha256
  `15832463…`, without Demucs or the replica step, numpy 2.0.2, scipy 1.13.1).
  `reference-analysis.json` is its `analysis.json` unchanged;
  `reference-frames.json` holds the per-frame melody (f0, voicing), samples of
  the vocal stem, the onset envelope and chroma sums, so each step of the port
  can be compared with the reference on its own.
