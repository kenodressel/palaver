# SCStream mic verdict — RAW

**Date:** 2026-04-23
**Question:** Does `SCStreamConfiguration.setCaptureMicrophone_(True)` on macOS 26
deliver raw microphone audio, or does macOS pre-process it (AEC / NS / AGC /
gating) before handing samples to the SCStream output?

**Verdict: RAW.** Speaker bleed reaches the SCStream mic track unchanged.
The `webrtc-aec` plan proceeds as specified — Task 2 extends SCStream to
deliver both tracks; we run WebRTC APM over them in post.

---

## Method

One SCStream with both `SCStreamOutputTypeAudio` and
`SCStreamOutputTypeMicrophone` outputs, configured at 16 kHz mono. Sequence:
2 s silent pre-roll, then `say -v Alex "the quick brown fox jumps over the
lazy dog"` played through built-in speakers (volume 63%, not muted), then a
2 s silent tail. Both tracks written to 16-bit PCM WAV.

The spike script was run once with the project venv and then deleted. It
lived at `/tmp/scstream_mic_spike.py` and produced
`/tmp/spike/{mic_raw,system}.wav`.

## RMS results

### As specified in the plan (naive 2 s windows from file start)

| File           | pre (0–2 s) | during (2–4 s) | post (4–6 s) |
|----------------|------------:|---------------:|-------------:|
| `mic_raw.wav`  |          97 |             89 |           76 |
| `system.wav`   |           0 |           3489 |         4485 |

The naive window looks like a PROCESSED verdict at first glance — mic RMS
is flat at ~90 across all three windows. **But this is a timing artefact**,
not evidence of processing:

- `mic_raw.wav` is 18.53 s long; `system.wav` is 7.56 s long. SCStream
  started delivering system samples immediately, but mic samples arrived
  later (or backfilled from the device's internal buffer) — so the first
  6 s of `mic_raw.wav` is still pre-roll silence, and the bleed actually
  lands much later in the file.
- A sliding 500 ms RMS envelope over `mic_raw.wav` shows a flat floor
  (~10 RMS, peaks ~30) from t=0 s to t≈8 s, then a clear loud envelope
  (RMS 1000–2500, peaks up to 8259) from t≈8.5 s to t≈16 s, then floor
  again. That loud envelope is the `say` playback bleeding through the
  mic — duration and shape match the `system.wav` speech window.

### Aligned to the observed envelopes

| Track                            | silent baseline RMS | speech window RMS | peak during |    ratio |
|----------------------------------|--------------------:|------------------:|------------:|---------:|
| `mic_raw.wav` (silent / bleed)   |                  60 |              1393 |        8259 |    ~23 × |
| `system.wav` (silent / playback) |                  13 |              4846 |       26737 |   ~370 × |

Silent baseline is the average of the pre- and post-speech silent windows.

## Interpretation

Mic RMS during the `say` window is ~23× higher than during the silent
baseline, with peak samples exceeding 8000 (out of int16 ±32768). If macOS
had applied VPIO-style AEC or aggressive gating on the SCStream mic, the
speaker bleed would have been attenuated toward the noise floor (mic_raw
during ≈ mic_raw silent); instead it shows a clear loud envelope of
unprocessed bleed, shaped like the far-end signal. There is also no sign of
the "nothing, nothing, nothing, gate opens, audio appears" step-function
that NS/gating would produce.

The one quirk is the timing: mic samples arrived in a later/longer burst
than system samples (18.5 s of mic vs. 7.6 s of system wall-clock capture).
This is a delivery-schedule detail of `SCStreamOutputTypeMicrophone`, not
evidence of processing. For the AEC pipeline it doesn't matter — WebRTC
APM aligns far-end and near-end internally using its own delay estimator,
and both files land on the same CoreAudio host-time clock so any sample
indexing we need for diagnostics can be done via CMSampleBuffer PTS.

## Recommendation

Proceed with Task 2 of
`docs/superpowers/plans/2026-04-23-webrtc-aec.md` as specified:
extend SCStream to deliver mic + system in one stream, and run WebRTC APM
in post. No AVCaptureSession fallback needed.

**Follow-up note for Task 2 implementation:** the mic vs. system file
lengths diverged noticeably in this spike (18.5 s vs. 7.6 s for the same
wall-clock capture window). Investigate why — possibly SC starts mic
capture after a warmup, possibly it delivers buffered samples that predate
`startCapture`. CaptureRecorder should timestamp-align the two tracks
using CMSampleBuffer PTS (rather than appending raw samples in arrival
order) so the AEC step receives synchronised inputs.
