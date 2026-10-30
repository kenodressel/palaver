# WebRTC AEC for Speaker-Bleed — Design Spec

**Date:** 2026-04-23
**Status:** Approved for implementation planning
**Supersedes:** An earlier VPIO-based design explored in this session and reverted (`c88598c`). See **Alternatives considered** below for why.

## Goal

Eliminate speaker-bleed in the recorded mic track so that, when the user records a Teams meeting without headphones, participants' voices coming out of the laptop speakers are no longer re-captured by the mic and falsely attributed to the user. Works across all audio output configurations (built-in speakers, headphones, AirPods, external USB/monitor speakers) — the user must be free to plug and unplug audio hardware without having to think about the tool.

## Non-Goals

- Real-time AEC. Cancellation runs as a post-capture step inside `meeting-transcribe process`.
- Replacing the V1 pipeline (transcribe / diarize / merge / Notion). Only the capture layer and one new `process` step change.
- Cross-platform. macOS Tahoe (26.x) + Apple Silicon only, same as V1.
- Tuning WebRTC's other sub-features (noise suppression, AGC, HPF) beyond the defaults project-raven ships with. Revisit only if transcript quality regresses.

## Constraints

- Python-only source code in this repo. The one non-Python dependency is a **vendored pre-built static library** from WebRTC (BSD-3-Clause) via `Laxcorp-Research/project-raven` (MIT); we do not write or compile C++ ourselves.
- macOS 26 + Apple Silicon, Python 3.10+.
- `_WavRecorder` Protocol surface in `recorder.py` stays intact.
- One SCStream delivers both microphone and system audio on a shared CoreAudio host-time clock. This is the architectural reason the whole rewrite is small.

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│ meeting-transcribe record                                   │
│                                                             │
│   Recorder (unchanged)                                      │
│     │                                                       │
│     ▼                                                       │
│   CaptureRecorder (was SystemRecorder — renamed/extended)   │
│     │    one SCStream, two SCStreamOutputTypes:             │
│     │      - SCStreamOutputType.microphone → mic_raw.wav    │
│     │      - SCStreamOutputType.audio      → system.wav     │
│     ▼                                                       │
│   writes: mic_raw.wav, system.wav, meta.json                │
└────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────┐
│ meeting-transcribe process                                  │
│                                                             │
│   NEW step: AEC                                             │
│     mic_raw.wav + system.wav  →  aec.py  →  mic.wav         │
│     (ctypes over vendored libwebrtc_audio_processing.a)     │
│                                                             │
│   existing steps continue unchanged:                        │
│     transcribe(mic.wav) + transcribe(system.wav)            │
│     diarize(system.wav) + merge + render                    │
└────────────────────────────────────────────────────────────┘
```

**Key component deltas:**

- **`system_recorder.py` → `capture_recorder.py`** (renamed because it no longer only captures system audio). Adds `configuration.captureMicrophone = True` + a second `addStreamOutput_type_sampleHandlerQueue_error_` call with `SCStreamOutputTypeMicrophone`. The delegate method switches on sample-buffer type and writes to one of two WAV files. The class implements the `_WavRecorder` Protocol; `Recorder` in `recorder.py` now holds ONE recorder that produces both tracks.
- **`mic_recorder.py`** deleted. The `sounddevice` dependency disappears.
- **`meeting_transcribe/_vendored/webrtc_aec/`** — copy of `src/native/webrtc-aec/` from project-raven: 88 LOC public C header, 198 LOC C++ wrapper over `webrtc::AudioProcessing`, plus pre-built universal (`arm64+x86_64`) static libs (~3.4 MB total). A `THIRD_PARTY.md` notes WebRTC BSD-3-Clause and project-raven MIT.
- **`aec.py`** (new) — Python ctypes wrapper around the C API. ~150 LOC. Exposes `aec_process(mic_raw_path, system_path, out_path)` that streams 10ms frames through the WebRTC APM and writes `mic.wav`.
- **`cli.py` _cmd_process** — adds one call to `aec_process(...)` before the transcription step. If `mic.wav` already exists on disk (e.g. from a re-run), skip. Resumable like every other stage.

## Invariants (additions to V1)

1. **Three capture tracks on disk per recording.** `mic_raw.wav` (raw mic, never transcribed directly), `system.wav` (loopback), and after `process` runs: `mic.wav` (AEC-processed mic, fed into transcription).
2. **Shared clock.** `mic_raw.wav` and `system.wav` come from the same SCStream and share a CoreAudio host-time clock. No drift over long sessions. This is the load-bearing assumption that lets AEC be a simple offline step instead of a drift-aware pipeline.
3. **AEC is non-optional.** If the AEC step fails (library load error, corrupt frame), `process` exits non-zero and keeps the partial folder. No silent fallback to transcribing `mic_raw.wav` directly — the speaker-bleed symptom is exactly what V2 is fixing, a fallback to raw would defeat the purpose.
4. **`mic_raw.wav` is never deleted by the pipeline.** Retained for forensics and re-runs exactly like the V1 WAVs.

## Verification Strategy

Apple has not published a one-line "SCStream delivers raw mic" statement. Project-raven uses CoreAudio (not SCStream) for its mic path, which is a yellow flag suggesting SCStream's mic might be pre-processed by macOS. **The plan MUST include a smoke test early that answers this empirically** before the AEC wrapper work starts:

- Record 30 seconds of known test audio played through the laptop speakers while silent.
- Run WebRTC AEC3 on the two tracks.
- Listen for double-processing artifacts in `mic.wav` (warbly, pumped, metallic speech) OR a clean silent result.
- **Decision gate:** clean → continue. Artifacts → fall back to AVCaptureSession + AUHAL for mic only (pyobjc wraps both; V1 had one working path via `sounddevice`/CoreAudio that we'd revive, separate clock, and add a one-time GCC-PHAT alignment at the start of AEC).

## Failure Modes

| Scenario | Behavior |
|----------|----------|
| SCStream fails to add the microphone output | `record` exits 2 with the SCStreamError reason. No partial files left behind. |
| Mic permission denied (TCC) | macOS prompt on first run. If denied, pyobjc raises; surface it with a pointer to System Settings. |
| AEC C library fails to load | `process` exits 2. Points at vendored `.a` path + install instructions. |
| Corrupt or too-short input WAV | `process` exits 2 with an explicit message (e.g., "mic_raw.wav shorter than 1s — recording broken"). |
| AEC-double-processing detected during verification | Fall back to AVCaptureSession mic path, documented in Alternatives. |

## Testing

- **Unit tests (`tests/test_aec.py`).** With synthetic short WAVs (1s silence, 1s tone) assert that `aec_process` produces a valid 16kHz mono PCM_16 WAV of the expected length, and that the output RMS of a silent-mic + audio-system pair is <50 (AEC cancels), and the output RMS of a speech-mic + silent-system pair is unchanged (near-end preserved).
- **Integration test (`tests/test_integration_capture.py`, `-m integration`).** Records 2 seconds via the extended `CaptureRecorder` against real hardware, asserts both WAVs exist and are 16 kHz mono. Skipped in CI / without mic permission.
- **Hardware verification.** One real Teams meeting without headphones, documented as `docs/superpowers/specs/2026-04-XX-webrtc-aec-verification.md`. Metrics: RMS of `mic_raw.wav` vs `mic.wav` during windows where the remote participant is talking and the user is silent. Expected ratio > 3× (raw louder because it still has speaker bleed; mic.wav clean). Transcript check: count utterances attributed to the user that are substring-duplicates of nearby SPEAKER_XX lines. Expected: 0.

## Rollout

- No data migration. New recordings produce three WAVs (`mic_raw.wav`, `mic.wav` after process, `system.wav`). Old recordings (V1) only have `mic.wav` + `system.wav`; they still re-process correctly because `process` sees `mic.wav` already on disk and skips the new AEC step.
- README gets a V2 section: "Speaker-bleed is now removed automatically during `process`. No headphones required." Also documents the SCStream single-stream architecture change and the vendored WebRTC library.

## Alternatives Considered

1. **VPIO via `setVoiceProcessingEnabled(true)` on AVAudioEngine.** First direction explored this session. `channelMap = [0]` got audio flowing, but VPIO's reference signal is tied to the `BuiltInSpeakerDevice` pseudo-device — external audio played by coreaudiod (like Teams participants hitting the speakers) was NOT cancelled in an empirical test (`say -v Alex` stayed loud in the processed mic track). On top of that, VPIO silently degrades AEC when the default output is not the built-in speaker (AirPods, external speakers). The user uses headphones sometimes but not always, so this approach is incompatible with their workflow. Reverted in `c88598c`.
2. **Two separate capture paths (SCStream for system, sounddevice/AVCaptureSession for mic).** Adds clock-drift between paths over long sessions (tens of ms over a 50-min meeting). Solvable via GCC-PHAT alignment but adds a whole error class the SCStream-single-stream path avoids. Kept on the shelf as a fallback if the verification smoke test reveals SCStream mic is pre-processed.
3. **All-Swift helper binary with a native WebRTC bridge.** Swift+Python+C split produced the multi-language sprawl the user rejected. The Python-only path uses the same vendored C library via ctypes; there is no Swift code in V2.
