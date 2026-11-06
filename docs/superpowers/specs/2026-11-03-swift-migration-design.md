# Palaver in Swift — Design

**Date:** 2026-11-03
**Status:** Draft for Keno's review

## Why

Palaver works, but the Python stack carries three costs.

- **Memory and speed.** Speaker detection (pyannote on PyTorch) peaks at
  ~5.5 GB for an hour of audio and takes 1–3 minutes per meeting.
  Parakeet on MLX peaks at ~5.5 GB over a long meeting. On a 16 GB Mac
  with Teams running, that is most of what is left.
- **A heavy, fragile runtime.** The release ships its own Python, PyTorch,
  MLX and dozens of packages. Each release has to rebuild and sign all of
  it, and a package update can break the bundle in ways the tests don't
  see.
- **It is not a native app.** The menu bar part is `rumps` over PyObjC,
  and the window is a WKWebView hosted from Python.

Sabbel (`~/dev/temp/sabbel-native`) moved from Python to Swift on
2026-11-03, on FluidAudio. The same building blocks fit Palaver.

## What the spike showed (2026-11-03)

The full report, numbers only, is in
`~/Meetings/Benchmarks/2026-11-03-swift-spike/report.md`, with the scripts.

| Part | Today (Python) | Swift | Verdict |
|---|---|---|---|
| Transcription: Parakeet v3, MLX vs CoreML (FluidAudio) | gold clips 45.5 % WER; 7.8 h of meetings in 363 s, 5.5 GB peak | 43.0 % WER; 136 s, 0.22 GB | Same accuracy and passages, 2.7× faster, 25× less memory |
| Speaker detection: pyannote community-1 vs FluidAudio's port of it | 58–184 s per meeting, ~5.5 GB | 3–11 s, ~0.8 GB; speaker confusion equal or lower on 7 of 8 meetings | Same pipeline, 10–20× faster |
| Voice embeddings (the voice bank) | stored pyannote vectors | cosine 0.95–1.00 to the stored vector of the same person | The voice bank carries over unchanged |
| Echo cancellation (vendored WebRTC) | ctypes | same library from Swift | Identical output, sample for sample |
| Notes model: Gemma 4 12B, mlx-lm vs mlx-swift-lm | 21 tok/s, 11.9 GB | 17–18 tok/s, 10.9 GB with a 1 GB cache limit | Works; same prompt tokens; valid notes. Speed in the same range (noisy) |

Lessons that carry over from Sabbel and the spike:

- SwiftPM hangs fetching FluidAudio's `NemoTextProcessing` binary here.
  Fetch it with `curl`, check its sha256 against the manifest, and point
  the target at a local path.
- SwiftPM cannot compile MLX's Metal shaders without Xcode. Building with
  MLX needs Xcode (`xcodebuild`), locally and in CI.
- A single `AVAudioFile.read` into a buffer of the whole file came back
  ~2,000 frames short on a 46-minute WAV. Read in chunks.
- Without a cache limit the mlx-swift process grew to 15.8 GB; with
  `Memory.cacheLimit` at 1 GB it stayed at 10.9 GB.

## The end state

Palaver is a Swift app with no Python. Seen from outside, it is the same
app:

- the same meeting folders in `~/Meetings/Recordings`, with the same files;
- the same voice bank, people, projects, glossary and settings;
- the same window (the HTML/JS frontend in `palaver/webapp/static`);
- the same MCP tools for Claude;
- the same bundle id and signing identity ("Palaver Release"), so macOS
  keeps the permissions it granted.

## Strategy: one process at a time

Palaver is already split into processes that talk through files:

| Process | Does | Contract |
|---|---|---|
| menu bar app (`palaver menubar`) | capture, call detection, daemon/queue, window host | meeting folder files, `daemon.json`, `app.sock` (appctl) |
| `palaver process` / `run` | AEC, transcription, speakers, notes, projects | meeting folder files, `failed.json` |
| `palaver live` | the same during the call | `live.json`, `speakers_live.json` |
| `palaver stream` | realtime words | the stream file the window reads |
| `palaver webapp-serve` | the window's HTTP API | `/api/...` JSON |
| `palaver index` | search by meaning | the search index |
| `palaver mcp` | Claude's tools | MCP tool schemas |

So the migration replaces one process, or one part of a process, at a
time. Each replacement has to keep its contract, and each phase ships to
the testers as a normal release. Nothing is rewritten in one go.

The fixed contracts, in order of importance:

1. **The meeting folder:** file names, JSON shapes, and speaker labels
   (`SPEAKER_00`…).
2. **Settings and stores:** `config.toml`, `settings.json`, the voice bank
   in `~/.config/palaver/voices/`, people, projects and the glossary.
3. **The HTTP API** the frontend uses. The Playwright end-to-end tests
   check it through the real frontend.
4. **`app.sock`** (appctl) and `daemon.json`, while both sides still exist.
5. **The MCP tools.**

### Phases

1. **Engine.** A Swift binary, `palaver-engine`, runs the speech models:
   transcription, speaker detection and voice embeddings on FluidAudio.
   The Python workers call it in place of `parakeet-mlx` and pyannote.
   PyTorch and pyannote leave the runtime. *Specified below.*
2. **App.** The menu bar app becomes Swift: capture, call detection, the
   daemon and its queue, the window host, updates and permissions. The
   remaining Python runs as workers (web server, notes, MCP). Echo
   cancellation stays with the live and process workers until they move.
   *Own design: `2026-11-04-swift-app-phase2-design.md`.*
3. **Server.** The HTTP API and the domain logic move to Swift: meetings,
   people, projects, glossary, search, voices and speaker inference. The
   frontend stays as it is, and the end-to-end tests run against the
   Swift server. *Own design.*
4. **Language models and integrations.** Notes, coach and project
   suggestions move to mlx-swift-lm or the cloud providers, along with
   Notion, the MCP server and the search embeddings. Python leaves the
   app, and the installer ships no Python runtime. *Own design.*

*My call:* while the migration runs, **new features wait.** Bug fixes for
the testers go on in Python. Issues #13–#18 land in the phase that owns
their code, written in Swift there. Exception: #14 (vocabulary boosting)
is an evaluation, and fits phase 1's engine.

## Phase 1: the engine

### Goals

1. **Same transcripts, faster and lighter.** Every place that runs
   Parakeet or pyannote today runs `palaver-engine` instead: `process`,
   `run`, `live`, `stream`, `bench-live`, re-transcribing a meeting, and
   the setup assistant's model check. Nothing else about Palaver changes.
2. **No accuracy loss.** This is a local gate (`make eval-engine`, below):
   - gold clips: WER no worse than today's MLX run + 1 point (today 45.5 %);
   - whole meetings: no more lost passages (runs of ≥ 8 words present only
     in the other engine) than MLX loses against the engine;
   - speakers: confusion no worse than pyannote's + 2 points on any of the
     8 reference meetings, and the speaker count within ±1 where pyannote
     is exact;
   - voices: cosine to today's stored embedding ≥ 0.9 for every named
     speaker in the 19 named meetings.
3. **Lighter and faster, measured:**
   - `process` on a 73-minute meeting (measured at the end of phase 1: 85 s,
     2.5 GB peak for the process and the engine together; today ~5.5 GB and
     3–5 min) — the first targets of 1.5 GB and 60 s per hour were not met.
     Follow-ups that would lower both: the engine transcribes from disk
     instead of holding the whole float array of a track, and the Python
     side echo-cancels in a stream instead of loading both tracks;
   - the live worker stays under 1.5 GB over a 60-minute call (today
     2.4–3.7 GB, budget 6 GB), and the stream worker under 1 GB (today
     ~1.9 GB, budget 3.5 GB).
   - The memory budgets in `[memory]` drop to match (live 2 GB, stream
     1.5 GB, `process` 4 GB). `palaver doctor`
     checks them as before.
4. **Same results on disk.** Transcripts keep their JSON shape, with words,
   confidences and `SPEAKER_NN` labels. Speaker embeddings keep their
   256-d shape in `speaker_embeddings.json`. Every reader of these files
   (voice bank, speaker inference, people, merging, notes) works
   unchanged.
5. **Smaller runtime.** PyTorch, pyannote.audio and parakeet-mlx are gone
   from `pyproject.toml` and the release runtime. The release notes say
   how much smaller the download is.
6. **Seamless update.** Testers update as usual. The new models are
   downloaded once, with the setup assistant's progress. The old models
   (the pyannote copy, the Parakeet MLX cache) are removed only after the
   new ones work, and only with the user's yes.

### Non-goals

- Echo cancellation stays in Python (ctypes); it is already identical.
  It moves with capture in phase 2.
- Notes and the language models stay on mlx-lm. MLX stays in the runtime.
- Whisper (`[model].transcriber = "mlx-whisper"`) and cloud transcription
  keep working as they are.
- No new features: the transcript, the window and the menus don't change.
- Live speaker labels beyond what `live.json` shows today.

### Anti-goals

Any of these makes phase 1 a failure, even if the goals are met:

- a meeting that transcribed before and now fails, or loses its speakers;
- a voice the bank recognized before and now doesn't, or a voice now named
  wrongly;
- a meeting left "Transcribing" forever because the engine died: every
  engine failure ends as `failed.json` with a reason, like today;
- an update that deletes models before the new ones work.

### The engine

- **One binary,** `palaver-engine`, in the app bundle next to the
  launcher, signed with the same identity.
- **A long-lived child process** of the worker that uses it. It speaks
  JSON lines on stdin/stdout and logs on stderr into the worker's
  `session.log`. One request at a time, in order. Commands:
  - `hello`: the engine and FluidAudio versions, which models are ready.
  - `prepare`: download and compile the models, reporting progress.
  - `transcribe`: a WAV path, an optional sample range, and the options
    (sentence split at 1 s pauses, at most 15 s).
    - Returns segments with words, as `ParakeetMlxTranscriber` builds them
      today: SentencePiece tokens joined into words, a word's confidence
      is its least sure piece, and orphaned punctuation is attached to
      the previous segment.
    - The dictionary replacements stay in Python.
  - `transcribe_window`: float32 samples (base64) for the stream's 10 s
    window. Returns words.
  - `diarize`: a WAV path. Returns exclusive turns, one 256-d embedding per
    label, and the timings.
    - Labels are `SPEAKER_00`, `SPEAKER_01`… in order of each speaker's
      first turn.
    - A track shorter than `MIN_AUDIO_SECONDS` returns no turns, as today.
  - `embed`: a WAV path and spans. Returns one embedding per span group.
    For later voice work; not used by phase 1's code paths.
- **Where Python calls it:**
  - `EngineTranscriber` replaces `ParakeetMlxTranscriber` as the default
    `[model].transcriber` (`"parakeet"`).
  - `EngineDiarizer` replaces `PyannoteDiarizer`, with the same
    `diarize()` and `last_embeddings`.
  - The live worker's `IncrementalDiarizer` becomes "diarize what is there
    so far": `provisional()` runs `diarize` on the audio up to now, at
    most every 2 minutes, since a whole hour takes ~10 s. `finish()` runs
    it once on the whole file.
  - The stream's `window_transcriber` calls `transcribe_window`.
  - A config value that names the old backend (`"parakeet-mlx"`) maps to
    the engine, with a log line.
- **Memory:**
  - The engine's footprint is the worker's footprint. Workers count their
    engine child in the budget check.
  - When a worker exits or is killed, its engine goes with it: the engine
    exits when stdin closes, and the worker kills it on the way out.
- **Errors:** a crash or a refused request becomes the worker's error,
  with the engine's last stderr lines in `session.log`. The daemon's
  "it stopped unexpectedly" marking (0.3.13) covers the rest.

### Models

- **FluidAudio's CoreML models:** Parakeet v3 (~460 MB) and the offline
  diarizer (~22 MB). They live under
  `~/Library/Application Support/palaver/models/fluidaudio/`, not
  FluidAudio's default folder, so `palaver uninstall --models` and the
  storage view (#9) find them.
- **Where they come from** (*my call*): Hugging Face, as FluidAudio
  fetches them. The repos are public and need no token. Hosting copies on
  the release (#60) can follow if Hugging Face proves unreliable.
- **The first launch after the update:**
  - The setup assistant downloads the models in the background, the way
    it handles a missing model today.
  - A meeting that ends before they are ready waits in the queue
    ("Waiting for the speech models").
- **Old models:**
  - The pyannote copy (`pyannote-community-1`), Parakeet MLX in the
    Hugging Face cache (2.3 GB), and PyTorch in the runtime.
  - After the first meeting transcribes with the engine, Settings →
    Storage offers to delete them, with their sizes. The release notes say
    the same.
- **v3 vs "ultra":** v3, as in Sabbel. Ultra was not better on the gold
  clips (43.9 % vs 43.0 %) and kept fewer English terms in Sabbel.

### Evaluation (`make eval-engine`)

- **A local gate,** like Sabbel's `make eval`. It runs only with
  `PALAVER_EVAL_DIR` set, which points at
  `~/Meetings/Benchmarks/2026-11-03-swift-spike/`. It refuses to run
  without it.
- **It runs goal 2's checks** with the spike's scripts, turned into a
  repeatable target: gold clips, 4 whole meetings, 8 reference meetings
  for speakers, 19 named meetings for voices.
- **It prints numbers only.** Meeting audio, transcripts and embeddings
  never enter the repo, CI, an issue or an upload.
- **CI** runs the engine's unit tests and a real-model test on synthetic
  speech (macOS `say`, German with English terms, kept as text in the
  repo, generated at test time), as Sabbel's CI does.
  *Status (phase 1 as built):* CI runs the engine's unit tests and starts
  the built binary once (a `hello` round trip); the real-model test is
  not run in CI yet. Open follow-up, Keno's call (it needs the models
  downloaded on the runner).

### Repo and build

- **The Swift package** lives in `native/` in this repo: SwiftPM, with
  FluidAudio pinned to an exact version.
  - `make engine` builds it, with the `NemoTextProcessing` workaround
    scripted.
  - `make test` runs the Swift tests too.
  - Phase 1 needs no MLX in Swift, so plain `swift build` is enough.
    Phase 2 onwards needs Xcode.
- **The release:**
  - `make release` builds the engine, puts it in the app bundle, and signs
    it with "Palaver Release".
  - `make smoke-install` checks that a fresh install, an update and an
    uninstall all work with the engine.
  - CI builds it on its macOS runner.
- **Python tests** use a fake engine, the way they fake the transcriber
  and diarizer today. A small set of contract tests runs the real binary
  on a short synthetic clip, marked like today's model tests.

### Risks

- **Speaker boundaries differ from pyannote's** by a few percent (see the
  spike). Words near a turn change could move to the neighbouring
  speaker. The merger assigns words by overlap, which is tolerant, but
  the gate checks confusion on real meetings.
- **The process boundary.** One more process per worker, and JSON instead
  of numpy. The stream's window is 10 s of float32 audio (640 KB base64)
  every second; if that costs too much, the engine reads the growing WAV
  itself, the way `GrowingTrack` does.
- **FluidAudio moves fast** (0.18.x). Pin the exact version, and update it
  only with `make eval-engine`.
- **CoreML compile on first load** takes a minute or two. The setup
  assistant does it right after the download, not during the first call.

## Left to the builder

- The Swift package layout and the engine's concurrency inside.
- The exact JSON field names of the protocol. The command list above is
  the contract.
- How workers count their engine child in the memory check.
- Whether `provisional()` re-diarizes on a timer or on each live block.
