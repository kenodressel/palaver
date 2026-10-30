# V1 Journey

This doc captures the research, decisions, and hardware-verification that
produced V1. The authoritative architecture lives in `superpowers/specs/`
and the task breakdown in `superpowers/plans/`.

## Problem

Notion AI's built-in meeting transcription has no speaker detection, which
made transcripts hard to read for multi-person meetings. V1 replaces it with a
local, privacy-preserving alternative that also does speaker diarization.

## Constraints

- macOS Tahoe (26.x) on Apple Silicon (M1+)
- Python 3.10+
- No paid dependencies
- Output lands in a Notion page
- 1-hour meeting processed in <30 min wall-clock
- German + English (often code-switched)

## Technology decisions

Researched three ASR + diarization stacks for Apple Silicon in April 2026.

### Ruled out

- **WhisperX** — MPS backend broken in PyTorch (sparse-tensor limitations,
  issue #109 open 3+ years); CTranslate2 has no Metal backend (#1562). Falls
  back to CPU at 4-6× realtime → a 1h meeting takes 25-40min. Misses the time
  budget.
- **faster-whisper** — same CTranslate2 / no-Metal problem. CPU-only on Mac.
- **WhisperKit + SpeakerKit** — SpeakerKit is a commercial Argmax product;
  not open source.
- **whisper.cpp + tinydiarize** — tinydiarize is English-only 2-speaker
  heuristic. Unusable for multi-person German meetings.

### Chosen: mlx-whisper + pyannote.audio 4.0

- `mlx-whisper` with `mlx-community/whisper-large-v3-turbo` — MLX on Apple
  Silicon GPU natively. ~30-50× realtime on M3/M4. Word-level timestamps via
  DTW.
- `pyannote.audio` 4.0 with `speaker-diarization-community-1` — runs on MPS.
  Requires a free HF token plus accepting the gated-model terms on the hub.

### Future swap target: parakeet-mlx v3

NVIDIA Parakeet-TDT-0.6B-v3 (via `senstella/parakeet-mlx`) beats Whisper
large-v3 on German FLEURS (7.4% vs 9.9% WER) and is roughly 10× faster on
Apple Silicon. The `Transcriber` Protocol was designed with this swap in
mind; see the V2 issue in the tracker.

## Architecture summary

File-based post-processing pipeline. Three stages communicate only through
files in a per-session recording folder:

1. **Record** — mic (`sounddevice`) + system audio (`ScreenCaptureKit`) to
   two parallel WAVs.
2. **Process** — transcribe both tracks (mlx-whisper), diarize the system
   track (pyannote), merge with word-level speaker alignment.
3. **Sync** — upload transcript to Notion as a new page under a configured
   parent.

Each stage is idempotent and resumable. Audio is never deleted by the
pipeline — retention is a separate concern (V1.1 `prune` subcommand).

Full details: `superpowers/specs/2026-04-17-meeting-transcribe-design.md`.

## Implementation

Built via superpowers TDD / subagent-driven-development: 16 planned tasks,
each implemented by a fresh subagent with two-stage review (spec compliance
then code quality) per task. A cross-cutting review after T1-T5 and a final
end-to-end review before shipping.

Review loop caught and fixed before the first hardware run:

- `Segment.speaker` mutability guarded by a regression test — freezing the
  dataclass would silently break mic-track speaker labeling.
- `Transcriber` Protocol made `@runtime_checkable` so the swappable-impl
  invariant is verifiable.
- `_distance_to_turn` signature cleaned; original plan code had an unused
  `end` parameter.
- Merger tiebreak hardened to prefer earlier-start turn (deterministic
  without relying on caller sort order).
- Chunk-timing assertions added to the segment-split test — a regression
  that set `_Chunk.end = w.start` would otherwise still pass.
- `MicRecorder.start()` rejects double-start and cleans up its file on
  stream-setup failure (no more 0-byte WAV leaks).
- `Recorder.start()` stops the mic explicitly when `system.start()` fails.
- `_cmd_process` preflights `meta.json` and emits a friendly error instead
  of a `FileNotFoundError`.
- `_status` precedence locked by unit tests (`synced` > `processed` >
  `recorded` > `incomplete`).
- `format_duration` parametrized coverage — it's a public API used by the
  CLI to build Notion page titles.

## Hardware verification

First end-to-end run on real hardware caught two issues not visible in unit
tests:

1. **pyannote 4.x kwarg change** — `Pipeline.from_pretrained` removed
   `use_auth_token` entirely; must use `token=`. Found by inspecting the
   installed 4.0.4 signature. Fixed in `35b6fcc`.
2. **pyannote 4.x return type** — the pipeline now returns a `DiarizeOutput`
   dataclass instead of a bare `Annotation`. We use
   `output.exclusive_speaker_diarization` (no overlapping turns — matches
   our merger's max-overlap assumption). Fixed in `32c4bab`.

A silent `system.wav` on the first attempt turned out to be nothing playing
on the Mac (not a bug). With real audio playing, the ScreenCaptureKit
skeleton produced clean mono 16kHz PCM_16 output without modification.

A Notion 404 was a sharing issue — the parent page must be explicitly
shared with the integration. Documented in the README.

Final verified run: ~108s recording → mic + system tracks both captured →
Whisper transcribes both → pyannote finds 4 distinct speakers on the
system track → merger produces chronological transcript → Notion page
created.

## Known limitations (V1)

- No Teams auto-detect — you run `record` manually and Ctrl+C to stop.
  The daemon is Plan 2.
- Generic speaker labels (`SPEAKER_00`, `SPEAKER_01`, …) for remote
  participants. Voice-matching to real names is V2.
- Whisper occasionally hallucinates endless repetitions at near-silent
  audio (e.g. the tail of a recording). No filter in V1.
- No retry/backoff on Notion API failures — re-run `sync <folder>`
  manually.
- ScreenCaptureKit recorder is hardware-verified on a single-display M-series
  Mac. PyObjC skeleton may need iteration for edge cases (multi-display,
  external audio interfaces, captures >1h).

See the Issues tab for the tracked V1.1 and V2 backlog.

## Session conventions used

Development followed `superpowers` skills:

- `superpowers:brainstorming` → spec write-up
- `superpowers:writing-plans` → task breakdown with checkpoints
- `superpowers:subagent-driven-development` → one subagent per task +
  spec/code reviews between tasks
- `superpowers:test-driven-development` → failing test first, implementation
  second, verify, commit (per task)

Commit discipline: one logical unit per commit, message explains the *why*,
cleanup/hardening fixes live in separate commits so the review trail is
visible.
