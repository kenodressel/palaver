# Meeting Transcribe — Design Spec

**Date:** 2026-04-17
**Status:** Approved for implementation planning

## Goal

Local, privacy-preserving meeting transcription with speaker diarization for
Microsoft Teams meetings on macOS. Replaces Notion AI's built-in transcription,
which lacks speaker detection. Transcripts land in a Notion page, one per
meeting.

## Non-Goals

- Live / streaming transcription (post-processing only)
- Bot that joins the Teams meeting
- Voice enrollment for named speakers (V2)
- Menu-bar UI (V2 — CLI + daemon only in V1)
- WER benchmarking or automated regression against audio fixtures
- Multi-user installations
- Support for anything other than Microsoft Teams as the meeting source
- Windows / Linux support

## Constraints

- macOS Tahoe (26.x) on Apple Silicon (M1+)
- Python 3.10+, no paid dependencies
- Quality over speed, but 1-hour meeting must process in under 30 minutes
  wall-clock (target: 5-10 min on M3/M4)
- German + English (often code-switched within a single utterance)
- No audio or text sent to any cloud service except the user's own Notion
  workspace via the official Notion API

## Architecture

File-based, loosely coupled post-processing pipeline. Each stage writes its
output to disk; each stage is independently re-runnable. A small background
daemon drives the capture trigger.

```
┌──────────┐      ┌──────────────────┐      ┌──────────┐      ┌────────┐
│ Capture  │ ───▶ │ Transcribe +     │ ───▶ │  Merge   │ ───▶ │ Notion │
│ (record) │      │ Diarize (process)│      │ (align)  │      │ (sync) │
└──────────┘      └──────────────────┘      └──────────┘      └────────┘
  mic.wav            segments.json           transcript.json    page
  system.wav         + turns.json            transcript.md      created
  meta.json
```

The trigger layer (Teams-detector daemon) is separate from the pipeline and
only decides when to invoke `record start` / `record stop`. All pipeline logic
is usable standalone from the CLI.

**Invariants:**

1. **Audio is sacred.** Once written to disk, WAV files are not deleted by the
   pipeline. Only a separate retention task deletes them after N days.
2. **Every stage is idempotent and resumable.** If `transcript.json` already
   exists in a recording folder, `process` skips the expensive steps. If Notion
   upload fails, `sync <folder>` can be re-run manually.
3. **Stages communicate only through files in the recording folder.** No
   in-process state between stages. Enables debugging one stage at a time.

## Technology Choices

**ASR (V1): `mlx-whisper` with `mlx-community/whisper-large-v3-turbo`.** Runs
natively on Apple Silicon GPU via MLX. Word-level timestamps via
`word_timestamps=True`. Proven on this machine (used by the `sabbel` project
next door).

**Diarization: `pyannote.audio` 4.0 with the `speaker-diarization-community-1`
model.** Runs on MPS. Requires a free HuggingFace token (gated repo).

**Transcriber abstraction:** `transcribe(wav_path) -> list[Segment]` with a
`Segment` dataclass carrying word-level timings. V1 implementation wraps
`mlx-whisper`. A V2 swap target is `parakeet-mlx` with `parakeet-tdt-0.6b-v3`
(NVIDIA Parakeet v3, MLX port — 7.4% WER German vs. Whisper large-v3 9.9% on
FLEURS, and roughly 10× faster on Apple Silicon). Swap is a one-file change;
the rest of the pipeline is model-agnostic.

**Explicitly ruled out:**

- **WhisperX** — MPS path broken (PyTorch sparse-tensor limitation, issue #109
  open for 3+ years); CTranslate2 has no Metal backend (#1562). Falls back to
  CPU, 25–40 min per hour of audio, misses the time budget.
- **faster-whisper** — same CTranslate2 / no-Metal problem. CPU-only on Mac.
- **WhisperKit + SpeakerKit (Argmax)** — SpeakerKit is commercial and not open
  source.
- **whisper.cpp + tinydiarize** — tinydiarize is English-only, 2-speaker
  heuristic. Unusable for German meetings with 3+ people.

## Components

Each module has a single purpose, ~100–300 lines. Sabbel code is copied in
where the problem overlaps (no shared library in V1).

### Capture stage

- **`recorder.py`** — coordinates `MicRecorder` + `SystemRecorder`. Both start
  and stop synchronously and share a `start_time` wall-clock anchor written to
  `meta.json`. WAVs are flushed to disk every 30 seconds so a crash loses at
  most 30 s of audio.
  - **`MicRecorder`** — `sounddevice` input stream → `mic.wav`, 16 kHz mono.
    Ported from `sabbel/recorder.py`.
  - **`SystemRecorder`** — `ScreenCaptureKit` via PyObjC → `system.wav`,
    16 kHz mono. New to this project. Captures the mix of remote speakers that
    Teams pushes to the system output.

### Process stage

- **`transcriber.py`** — `transcribe(wav: Path) -> list[Segment]`. V1 impl:
  `mlx-whisper` with `word_timestamps=True`. Injects `initial_prompt` and
  post-replacements from `dictionary.py` (sabbel pattern). Auto-language-detect
  by default; configurable override.
- **`diarizer.py`** — thin wrapper around pyannote.audio 4.0 community-1.
  `diarize(wav: Path) -> list[SpeakerTurn]`. Runs on MPS. Only invoked on
  `system.wav`, never on the mic track — the user's own mic is labeled by
  construction (see Merge).

### Merge stage

- **`merger.py`** — pure logic, no I/O beyond reading JSON. Takes:
  - mic segments (labeled as the user's name from config — "Timo" by default)
  - system segments (words + timings, no speaker yet)
  - system turns (speaker IDs + timings from pyannote)
  Produces:
  - word-to-turn alignment for system track: each word is assigned the speaker
    whose turn has the largest overlap with the word's interval
  - a single chronologically sorted stream `list[Utterance]` across both tracks
  - `transcript.json` (structured) + `transcript.md` (human-readable)

### Sync stage

- **`notion.py`** — thin wrapper around the Notion REST API (`requests` +
  bearer token). Patterns copied from `notion-transfer/transfer.py`, including
  the 100-blocks-per-append chunking. One entry point:
  `create_meeting_page(parent_id, title, transcript) -> page_url`.

### Trigger layer

- **`teams_detector.py`** — polls every 2 seconds to see whether Teams is
  actively using the microphone. Implementation is swappable behind a
  `TeamsMicActive() -> bool` interface; V1 uses whichever of the following
  is simplest and reliable on Tahoe: `lsof` on the default input device,
  CoreAudio `kAudioDevicePropertyDeviceIsRunning` via ctypes, or
  NSWorkspace-based Teams-process-plus-call-window detection. Exact API
  pinned during implementation.
  - Grace period: after "released" is observed, wait 10 s before firing
    `stop`. Guards against transient device switches and mute toggles.
  - Max-duration safety: if a session runs longer than 4 hours, force stop and
    reset. Guards against detector hang / laptop sleep.
- **`daemon.py`** — launchd-backed process that owns the detector. Shells out
  to the CLI for `record start` / `record stop` / `run <folder>`. Also handles
  the daily retention sweep.

### Cross-cutting

- **`config.py`** — TOML at `~/.config/meeting-transcribe/config.toml`.
  Sabbel loader pattern. Schema:

  ```toml
  [user]
  name = "Timo"                 # used to label the mic track in transcripts

  [notion]
  token = "ntn_..."             # or read from env NOTION_TOKEN
  parent_page_id = "..."        # target page for new meeting pages

  [hf]
  token = "hf_..."              # or read from env HF_TOKEN (pyannote gate)

  [recording]
  output_dir = "~/Meetings/Recordings"
  retention_days = 14
  max_session_hours = 4
  grace_period_seconds = 10

  [model]
  transcriber = "mlx-whisper"   # v2 swap target: "parakeet-mlx"
  whisper_repo = "mlx-community/whisper-large-v3-turbo"
  diarizer_repo = "pyannote/speaker-diarization-community-1"
  language = "auto"             # "auto", "de", "en"
  ```
- **`dictionary.py`** — copy of `sabbel/dictionary.py`. Own file at
  `~/.config/meeting-transcribe/dictionary.toml`.
- **`cli.py`** — entry point. Subcommands:
  - `daemon start|stop|status`
  - `record start|stop`
  - `process <folder>`
  - `sync <folder>`
  - `run <folder>` (process + sync in one go)
  - `list` (show all recording folders + status)

## Data Flow (concrete example)

```
T=0       daemon observes Teams claiming the mic (polled every 2s)
T=0       daemon executes: meeting-transcribe record start
          creates ~/Meetings/Recordings/2026-04-17T14-30/
            mic.wav, system.wav, meta.json   (all streamed, flushed /30s)

T=0..N    daemon keeps polling; recorders keep streaming.
          (N is dynamic — a meeting is as long as it is.)

T=N       daemon observes mic released, waits 10s grace period,
          confirms still released, then executes:
          meeting-transcribe record stop
          WAVs are finalized; meta.json gets end_time.

T=N+ε     daemon automatically invokes:
          meeting-transcribe run <folder>  (= process + sync)

Process (typically 5–10 min on M3/M4):
  1. transcribe(mic.wav)    → mic_segments.json     speaker = "Timo"
  2. transcribe(system.wav) → system_segments.json  speaker = unassigned
  3. diarize(system.wav)    → system_turns.json     speakers = S1, S2, …
  4. merger.merge():
       - align system_segments words with system_turns (max-overlap)
       - concatenate mic_segments (labeled Timo) + labeled system_segments
       - sort by start_time
     → transcript.json + transcript.md

Sync:
  5. render transcript as Notion blocks:
       H1:   "2026-04-17 14:30 — Meeting (58 min, 3 speakers)"
       Body: one paragraph per utterance, format:
             **Timo** [14:32:05]  Das sollten wir…
             **Speaker 1** [14:32:18]  Ja, aber…
  6. POST /v1/pages with parent page ID from config
     → returns page URL; stored in transcript.json
  7. macOS notification with "Open in Notion" action

Retention:
  launchd runs daily; deletes recording folders older than retention_days
  (default 14). transcript.md / transcript.json are retained with the folder,
  so deletion wipes them too — the Notion page remains authoritative.
```

## Storage Layout

```
~/.config/meeting-transcribe/
    config.toml           # Notion token, parent page, user name, retention
    dictionary.toml       # initial_prompt + replacements

~/Meetings/Recordings/
    2026-04-17T14-30/
        mic.wav
        system.wav
        meta.json             # start_time, end_time, model versions
        mic_segments.json     # from transcriber (stage output)
        system_segments.json
        system_turns.json     # from diarizer
        transcript.json       # from merger (primary output)
        transcript.md         # from merger (human-readable)
        notion.json           # from sync (page_url, created_at)
        session.log           # structured events for this session

~/Library/Logs/meeting-transcribe/
    daemon.log                # daemon-level events across sessions
```

## Error Handling

**Philosophy:** A meeting is not reproducible. Priority #1 is never losing the
audio. Everything else is re-runnable.

| Stage     | Failure Mode                                         | Handling                                                                                                                                   |
| --------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Capture   | Mic / ScreenCaptureKit permission missing, disk full | Pre-flight check on `daemon start`. Refuse if free disk <2 GB. WAV writers flush every 30 s.                                               |
| Process   | Model download missing, OOM, pyannote HF-token bad   | Clear error + non-zero exit. Stage is resumable: fix issue, re-run `process <folder>`. Re-run skips stages whose output files exist.       |
| Merge     | Time drift between mic and system tracks             | Merger uses `meta.json` start timestamp as anchor, computes per-track offsets. Warn in log if drift > 100 ms.                              |
| Sync      | Notion API down, rate limit, parent page gone        | Exponential backoff, 3 retries. On final failure: `transcript.md` remains on disk, user can re-run `sync <folder>`. No data is ever lost. |
| Daemon    | Detector hangs, false positive, laptop sleep         | Max-duration safety (4 h). Structured log. `daemon status` shows current recording age.                                                    |

## Observability

- Structured log (one JSON event per line) at
  `~/Library/Logs/meeting-transcribe/daemon.log`: session_start,
  transcribe_start, transcribe_done, diarize_done, merge_done, notion_uploaded,
  errors.
- Per-session log inside each recording folder.
- macOS notifications on: recording started, transcription done & uploaded,
  any error.
- `meeting-transcribe list` shows all recording folders with status:
  `recorded` / `processed` / `synced` / `failed`.

## Testing Strategy

**Primary feedback loop** during the prototype phase: the user runs real
Teams meetings with Notion AI in parallel. Side-by-side comparison of the two
transcripts is the main quality signal. No automated WER benchmarks in V1.

**Unit tests** (fast, deterministic):

- `merger.py` — fixture-based: mic-segments + system-segments + turns →
  expected utterances. Edge cases covered: overlapping speakers, silence
  between utterances, drift compensation, single-speaker meeting.
- `config.py`, `dictionary.py` — copy from sabbel.

**Integration tests** (slow, one-off CI or manual):

- `transcriber` + `diarizer` against a ~2 min sample WAV (checked in, or
  referenced from a fixtures URL). Assertions are smoke-level: "produces ≥1
  segment", "identifies ≥2 speakers", "output text is >N characters". Not
  strict on exact text (model outputs shift).

**Not tested automatically:**

- ScreenCaptureKit capture — manual on hardware.
- Teams detector — manual on hardware.
- Notion API — manual against a dedicated sandbox page.

## Out of Scope (V2 candidates)

- Menu-bar UI with status indicator (rumps, sabbel-style)
- Hotkey-based manual start/stop
- Speaker renaming wizard (post-process: "who is Speaker 1?")
- Voice enrollment + automatic recognition of known colleagues
- Notion database with properties (date, duration, participants)
- Transcriber swap to `parakeet-mlx` v3 (prep: abstraction already in V1)
- Language auto-detect per utterance (rather than per file)
- Support for Zoom, Webex, Google Meet
- Real-time / streaming mode

## References

- Research report on ASR+diarization stacks for Apple Silicon (2026),
  attached conversation context.
- `../../wispr-flow-clone/` — sabbel, source of `recorder.py`, `transcriber.py`,
  `config.py`, `dictionary.py`, `permissions.py` patterns.
- `../../notion-transfer/transfer.py` — Notion API client patterns,
  including 100-blocks-per-request chunking.
- pyannote.audio 4.0 community-1 model card:
  https://huggingface.co/pyannote/speaker-diarization-community-1
- mlx-community whisper-large-v3-turbo: https://huggingface.co/mlx-community/whisper-large-v3-turbo
- senstella/parakeet-mlx (V2 swap target): https://github.com/senstella/parakeet-mlx
