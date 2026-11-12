# Contributing to Palaver

How to run Palaver from a checkout, test it, and make a release. What
Palaver does for its users is in the [README](README.md).

Palaver is a Swift app (`native/`, a Swift package): the menu bar app, the
window's server (`palaver-server`), the pipeline (`palaver-worker`), the
language model (`palaver-lm`, MLX), the speech engine (`palaver-engine`) and
the `palaver` command (`palaver-cli`). The window's page is plain HTML, CSS
and JavaScript in `web/`. The version is in `VERSION`.

Python is developer tooling only, nothing of it ships: the end-to-end tests
(`tests/e2e`, Playwright), the release build (`tools/build_release.py`,
`tools/app_bundle.py`), the tests of `install.sh` and the release assets, and
the local engine gate (`tools/eval_engine.py`). `pyproject.toml` lists what
they need. The Python app of 0.5 and before was removed on 2026-11-11; it is in
the git history (last commit with it: `542d028`).

Layout:

| Folder | What it holds |
|---|---|
| `native/` | The Swift package: `Sources/` (the app and its programs), `Tests/`, `Bundle/` (the release bundle's icons, entitlements, the one-release MCP shim), `Vendored/webrtc_aec` (the echo canceller's prebuilt libraries) |
| `web/` | The Meetings window's page, served by `palaver-server` |
| `tests/` | `e2e/` (the window in WebKit against `palaver-server`), `js/` (the page's unit tests, run with node), the tests of the release tooling and `install.sh`, `fixtures/` (shared with the Swift tests) |
| `tools/` | The release build, `smoke_install.sh`, `release_keychain.sh` (signing on CI), the engine gate, and generators of checked-in data (icons, Unicode tables, the zipf table, the embedder fixture) |
| `install.sh` | The installer testers run |

## Setup (from source)

You need macOS 15 or later on Apple Silicon, Xcode (not only the Command Line
Tools: `make lm` compiles MLX's Metal shaders), [uv](https://docs.astral.sh/uv/)
(the developer tooling: tests and release scripts) and node (the page's JS
tests).

1. Install the developer tooling and Playwright's WebKit (for the end-to-end
   tests):

   ```bash
   uv sync --extra dev
   uv run --extra dev python -m playwright install webkit
   ```

   The first Swift build fetches FluidAudio and NemoTextProcessing into
   `native/vendor` (`make engine` does it; see the Makefile).

2. The speech and speaker models need no account or token: the first run
   downloads them (about 0.5 GB) into
   `~/Library/Application Support/palaver/models/fluidaudio`, and
   `make engine` builds the Swift helper (`palaver-engine`) that runs them.

3. (Optional) In Notion, create an internal integration at
   notion.so/profile/integrations. Share a parent page with the integration
   (this is where meeting transcripts will appear).

4. (Optional: without it the defaults apply) Create
   `~/.config/palaver/config.toml`:

   ```toml
   [user]
   name = "Timo"

   [notion]
   parent_page_id = "<your-parent-page-id>"

   [recording]
   output_dir = "~/Meetings/Recordings"
   retention_days = 14
   ```

   To file meetings as rows of a Notion **database** instead of child pages,
   share the database with the integration and set:

   ```toml
   [notion]
   mode = "database"
   database_id = "<your-database-id>"
   ```

   Columns are matched by type and name, and only those that exist are
   filled: the title column, a date column (`Date`/`Datum`), number columns
   for duration (`Duration`/`Dauer`) and speakers (`Speakers`/`Teilnehmer`),
   and a select column `Source` (set to "Teams").

5. Export the token (or add it to `config.toml` directly); without a Notion
   token meetings stay on this Mac:

   ```bash
   export NOTION_TOKEN=ntn_xxx
   ```

6. (Optional) Create `~/.config/palaver/dictionary.toml` for
   domain-specific terms:

   ```toml
   [initial_prompt]
   text = "Sprint Planning, OKRs, KPIs, Kubernetes."

   [replacements]
   "kay pee eye" = "KPI"
   ```

   Use a meeting-specific vocabulary for one run with
   `palaver --dictionary ~/vocab/legal.toml run <folder>`.

Then check the setup — permissions, tokens, models, disk — with exact fixes:

```bash
make cli && alias palaver="$PWD/native/.build/release/palaver-cli"   # the Swift command, as the app ships it
palaver doctor    # --offline skips the Notion API check
palaver --help
```

## Tests

```bash
make test            # the tests of what changed since master: Swift and pytest side by side, on half the cores
make test-all        # every test (CI runs it, with the long ones: make test-long)
make swift-test FILTER=<Suite>   # one Swift suite or test
make test-changed    # only the Python tests for what changed since master
```

`make test` runs what a change can break (`tools/changed_tests.py`): a change
to a Swift target runs every test bundle built from it (PalaverCore and
PalaverDomain: nearly all) and the bundles that start a program built from
it; a changed Swift test file runs its suites; a change to the page runs its
JS tests and the e2e tests of its area (all of them for `web/app.js`); a
change to `palaver-server` or `palaver-lm` runs the e2e tests. It builds once
(`make test-build`), then runs the Swift bundles and pytest at the same time,
reniced, on about half the cores (`TEST_JOBS`), so the Mac stays usable in a
call. `make test-all` runs everything; CI runs `make test-long` on every push
and pull request. Run `make test-all` before a merge when the change is wide.

- The default tests need no models, no hardware and no network: the root
  `tests/conftest.py` gives every test a temporary config folder and no
  network beyond 127.0.0.1.
- `tests/e2e/` drives the Meetings window's page in Playwright's WebKit,
  served from synthetic recordings in a temporary folder
  (`tests/e2e/recordings.py`). Install WebKit once with
  `uv run --extra dev python -m playwright install webkit`; without it these
  tests are skipped (in CI they fail instead).
- `tests/js/` holds the page's JavaScript unit tests, run with node through
  `tests/test_js.py` (skipped without node).
- The Swift tests (`native/Tests`, swift-testing; all: `make engine-test`,
  one suite: `make swift-test FILTER=<Suite>`) run from the tests' build,
  `native/.build/test` (`make test-build`: debug, so assertions and test hooks
  are on, but optimized), each bundle in its own process
  (`tools/swift_tests_parallel.sh`) with a temporary config and home: a debug
  build stops a test that reaches the real `~/.config`, home or `~/Meetings`.
  A test that needs minutes of synthetic audio runs only with
  `PALAVER_LONG_TESTS=1` (`make test-long`).
- `tests/e2e/` runs against the same build's `palaver-server` and
  `palaver-lm`, with a fake menu bar app
  (`tests/e2e/fake_app.py`) and palaver-lm's test model; it sets up and checks
  the meetings' and stores' files itself (`tests/e2e/stores.py`).
- The tests of the release tooling build bundles from stand-in programs
  (`tests/test_app_bundle.py`), check that the updaters of every release
  before 0.6 take what `make release` makes (`tests/test_release_compat.py`,
  their code frozen in `tests/fixtures/updater_*`) and run `install.sh` in a
  throwaway home (`tests/test_install_sh.py`).
- A few Swift tests read files earlier releases wrote (exports, an undo
  folder: `native/Tests/PalaverDomainTests/Goldens`, `tests/fixtures`) or the
  reference tokenizer's ids (SentencePiece): they are frozen.

CI (`.github/workflows/ci.yml`) runs `make test-long` on every push to master
and every pull request; a release waits for it to pass on the tagged commit.

## Make targets

`make help` lists them:

| Target | What it does |
|---|---|
| `test` / `test-all` / `test-long` | Run the tests of what changed since master / every test (Swift, e2e on `palaver-server`, the page's JS tests, the release tooling and install.sh) / every test and the long ones |
| `engine` / `app-swift` / `server` / `worker` / `lm` / `cli` | Build `palaver-engine`, the Swift app, `palaver-server`, `palaver-worker`, `palaver-lm` (xcodebuild, with MLX's shaders) and `palaver-cli` (release; all but the engine and the app fail when the program holds this Mac's paths) |
| `engine-test` / `swift-test` | Run all Swift tests / the ones `FILTER` names |
| `test-build` | Build the tests and the programs they and the e2e tests start (`native/.build/test`: debug, optimized) |
| `debug-programs` | Build `palaver-cli`, `palaver-lm`, `palaver-server` and `palaver-worker` (debug, to run by hand) |
| `eval-engine-worker` | `eval-engine` through `palaver-worker engine-serve` (the in-process engine), writes `engine-gate-worker.md` |
| `test-changed` | Run only the Python tests for what changed since master |
| `eval-engine` | Maintainer-only gate: the Swift engine against the old stack's numbers on your own recordings. Needs `PALAVER_EVAL_DIR` (a folder with a local `eval.json`); writes numbers only to `engine-gate.md`. The exit code contract is `tools/eval_engine.py`'s: 0 pass, 1 a check FAILED, 2 misconfigured. Through make both failures show as make's exit 2, so read the printed table |
| `icons` | Draw the app and menu bar icons into `native/Bundle` |
| `models` | Pack the models Palaver hosts (none now; the engine downloads its own) |
| `app` | Build Palaver.app from the Swift programs (no Python), zipped; refuses a bundle with anything of Python or a path of this Mac in it |
| `compat-runtime` | Write the placeholder runtime the updaters of releases before 0.6 need (a few hundred bytes, the same every build) |
| `manifest` | Write `manifest.json` and `upload.txt` over the assets in `dist/` |
| `release` | All release assets in `dist/` |
| `smoke-install` | Install `dist/` into a throwaway home, check it, and simulate an update |
| `publish` | Create the GitHub release of this version from `dist/upload.txt` (the fallback: a pushed tag publishes on CI) |
| `clean` | Remove build output |

## Running it from a checkout

As a menu bar app (auto-recording, manual start/stop, the Meetings window).
The app is native Swift (`native/`, target `Palaver`): it records, runs the
daemon, serves `app.sock` and hosts the window. It starts `palaver-server`
(the window's server), `palaver-worker` (`process`, `live`, `stream`, `coach`,
`index`, …) and `palaver-lm` (notes, projects, the next question) from
`native/.build` (`PALAVER_SERVER_BIN` / `PALAVER_WORKER_BIN` / `PALAVER_LM_BIN`
name other builds); see [Architecture](#architecture):

```bash
make app-swift server worker lm && native/.build/release/Palaver   # icon alone: waiting · 🔴 recording · ⏳ transcribing · ⏸ paused
```

A release's `Palaver.app` holds the Swift app as its executable
(`Contents/MacOS/Palaver`), `palaver-server`, `palaver-worker`, `palaver-lm`
and `palaver-engine` beside it, the `palaver` command (`palaver-cli`) as
`Contents/Resources/bin/palaver`, the window's page files in
`Contents/Resources/web`, MLX's shaders (`mlx.metallib`) and, for 0.6 only,
`Contents/Resources/bin/python`: a shell script that starts `bin/palaver mcp`
for Claude Code and Claude Desktop entries of older versions (the app rewrites
them at every start). There is no Python in it, and every program is signed
with the one identity as in 0.5, without the hardened runtime for now
(`native/Bundle/Palaver.entitlements` is kept for notarization). A development
build of the Swift app asks for the microphone and system audio for the
terminal that runs it; run it only when you mean to record.

Install the app built from this checkout as a Mac app that starts at login
(the Swift `palaver` command runs `make app` and puts the built Palaver.app
in `~/Applications`, in place of the one there; it refuses while the app
records or transcribes):

```bash
native/.build/debug/palaver-cli app install --login   # → ~/Applications/Palaver.app
native/.build/debug/palaver-cli app uninstall
```

On first launch it asks for Microphone and System Audio Recording under its
own name — not Screen Recording: the microphone is captured with
AVCaptureSession and system audio with a Core Audio Process Tap.
ScreenCaptureKit (which needs Screen Recording) is only a fallback for a
source that fails. Tokens are read from `config.toml`, the environment, or the
login Keychain.

The Meetings window's server runs in a process of its own, which the app
starts again when it crashes. After a change to the window or its API,
restart only that process, at any time, also during a call (the recording
is never touched; the window reloads where it was):

```bash
palaver app restart-web
```

`palaver app ping` says whether the running app answers on its socket
(`app.sock`), and with which pid.

A change anywhere else (recording, call detection, the menu) still needs the
whole app restarted, and that should wait until nothing records or processes
(`palaver daemon status`).

Process an existing recording and list recordings:

```bash
palaver run ~/Meetings/Recordings/2026-04-17T14-30-00
palaver list
```

Speakers are named in the Meetings window.

Delete synced recordings older than `retention_days` (unsynced ones are kept
unless `--include-unsynced`):

```bash
palaver prune --dry-run
palaver prune
```

`process`, `sync` and `run` show a macOS notification when the transcript is
ready or uploaded, or when a step fails (`--no-notify` to turn off).

## Architecture

Since 0.6 everything Palaver.app runs is Swift (phases 1 to 4 of the migration):

- **The app** (`native/Sources/Palaver`, `PalaverDaemon`, `PalaverCapture`):
  the menu bar, call detection, recording, `app.sock`, the window.
- **`palaver-server`** (`PalaverServer`, SwiftNIO): the Meetings window's
  server and its API (the port of `palaver/webapp`), a child of the app that
  it restarts when it crashes (`palaver app restart-web`).
- **`palaver-worker`** (`PalaverWorker`): the pipeline — `process` (echo
  removal, transcription and speakers with the engine in process, names),
  `live`, `stream`, `coach`, `index`, `query`, `engine-serve`.
- **`palaver-lm`** (`PalaverLM`, `PalaverMLX`): the language model — notes,
  projects and the next question, on MLX on this Mac, a cloud provider or the
  Claude Code CLI; one model at a time, under the memory rules.
- **`PalaverCloud`**: the Keychain, the providers and their HTTP transport, the
  access log, cloud transcription, Notion and the model downloads.
- **`PalaverDomain`**: what all share — the meeting folders, stores and
  their locks (`<store>.lock`, compatible with the locks of the releases before 0.6),
  undo, people, projects, glossary, search, exchange files.
- **The `palaver` command** (`PalaverServer/CLI`, product `palaver-cli`, in
  the bundle as `Contents/Resources/bin/palaver`, which install.sh links to
  `~/.local/bin/palaver`; phase 4): `process`, `run`, `index` and `sync`
  start `palaver-worker`, `notes` and `projects` start `palaver-lm`, each in
  its place with the same options; `list`, `export`, `import`, `voices`,
  `prune`, `doctor`, `report create`, `daemon status`, `app …` and `mcp`
  run in it. The commands of earlier versions that the app does now
  (`record`, `rename`, `daemon` without `status`, `menubar`, `live`, …) say
  in one line what replaces them and exit 2.

The files on disk (meetings, stores, settings, undo snapshots, exchange files)
are the same as before, so 0.5 and 0.6 read each other's. What the migration
decided, skipped and measured is in
`docs/superpowers/specs/2026-11-04-phase3-ledger.md` and
`docs/superpowers/specs/2026-11-08-phase4-record.md`.

## How it works

1. **Record**: captures the microphone and the Mac's sound as separate WAV
   tracks (16 kHz mono PCM_16) in a timestamped folder under `output_dir`.
2. **Process**: removes speaker bleed from the microphone track (below),
   transcribes both tracks with Parakeet-TDT v3 and diarizes the system
   track with FluidAudio's CoreML models, in `palaver-worker process` (the
   engine in process), merges words to speakers, writes `transcript.md` and
   `transcript.json`, then the notes (`palaver-lm`).
3. **Sync**: uploads the transcript as a new Notion page under the
   configured parent (only with a Notion token).

Stages are independent and resumable — if a step fails (e.g. a model
download dies), rerun `process` or `sync` and it skips what's already done.

Before merging, `process` drops Whisper hallucinations over silence ("Thank
you.", "Yeah." at 30 s window boundaries) and mic segments that repeat
remote speech from the same moment (speaker bleed the AEC let through). With
`language = "auto"` the system track's detected language is reused for the
mic track.

Each recording folder gets a `session.log` (JSON lines): capture warnings
(tap fallback, mic stalls, resampler re-anchors), stage durations, dropped
segment counts, the Notion page URL, and any failure with its traceback.

Design notes, specs and plans are in `docs/` (`docs/superpowers/specs`,
`docs/superpowers/plans`).

### Capture and speaker-bleed removal

The microphone is captured with AVCaptureSession (ScreenCaptureKit's
microphone output is the fallback) and system audio with a Core Audio Process
Tap on every process except the recorder itself. All sources timestamp on the
CoreAudio host-time clock, so the tracks are aligned by presentation
timestamp. The Process Tap coexists with other system-audio recorders (Notion
Meeting Recorder, QuickTime, OBS, Teams cloud recording), which can starve
ScreenCaptureKit's audio output. It follows default-output changes
(headphones, AirPods) by rebuilding itself on the new device. If the tap
cannot start — e.g. the app lacks the *System Audio Recording* permission —
`record` warns and falls back to ScreenCaptureKit system audio.

The microphone arrives at the input device's native rate (e.g. 48 kHz), not
16 kHz; the recorder reads each buffer's format and resamples per track,
following rate changes when the input device switches mid-meeting.

The recorder writes:

- `mic_raw.wav` — raw microphone audio.
- `system.wav` — system-output loopback.

During `palaver process`, an AEC step produces `mic.wav` from those two
tracks using WebRTC's AudioProcessing (vendored from
`Laxcorp-Research/project-raven`, MIT; pre-built WebRTC static libs, BSD-3).
The downstream transcription and diarization consume `mic.wav` unchanged.

Result: participants' voices coming out of laptop speakers are not
re-captured in the mic track. This works with any output configuration
(built-in speakers, headphones, AirPods, external speakers).

### Call detection

The daemon starts recording once Teams has held the microphone for 4 s
(Teams keeps it open while you're muted), stops 10 s after Teams releases it
(`[recording] grace_period_seconds`), force-stops after `max_session_hours`,
and transcribes + uploads each recording longer than a minute in the
background, one at a time. It reads Teams' microphone use from CoreAudio's
per-process audio objects (macOS 14.4+). Slack huddles start the same way
(Slack holding the microphone); since Slack may close it while you're muted,
a huddle goes on while Slack still plays sound. No Slack account access is
needed. `[recording] slack = false` turns it off.

### Processing during the call

While it records, the daemon runs `palaver live <folder>` at background
priority (efficiency cores, yields to Teams). It echo-cancels and transcribes
the audio in ~1 minute blocks cut at pauses, and computes the expensive part
of the speaker detection — it runs over the recording so far every two
minutes — as the audio arrives. When the call ends only the last block and
the final speaker pass are left, so the transcript is ready in seconds
instead of minutes, and the result is the same as processing the finished
file. If the
live worker fails, `run` does everything after the call as before. Turn it
off with:

```toml
[processing]
live = false
```

The live worker writes `live.json` after each block; the window shows a
meeting being recorded from it and refreshes every 10 s. Speakers are
clustered from the voices heard so far, so labels may still change. A name
given meanwhile is stored with the voice (`speakers_live.json`) and moves to
the right speaker in the final transcript.

**Realtime.** While a call is recorded, `palaver stream <folder>` (started by
the app) transcribes the last 10 s every second. The window shows the other
side's words about 2–3 s after they are said, and your own words once their
echo is filtered out. It is only for watching live: the final transcript is
made as before, and nothing depends on the stream. "Realtime transcription"
in Settings → Recording applies from the next recording.

### Memory budgets

Each worker has a budget, measured as Activity Monitor's "Memory" (the
phys_footprint, GPU memory included) of the worker and the engine helper it
started. A live or realtime worker over its
budget for 10 s is restarted (twice per meeting, then stopped: the
transcript is then written after the call); the recording itself goes on,
since capture runs in the app. Notes, transcriptions and the search index
over budget only get a notification and finish, unless the Mac runs low on
memory (under 1.5 GB free for 10 s): then they stop and are tried again
later; the third time Palaver says what to do instead. The status line shows
what Palaver costs during a call ("· Palaver 5.4 GB"), Settings → Memory
shows each worker, and `palaver doctor` checks the budgets. The defaults:

```toml
[memory]
live_gb = 2             # the worker plus the engine (CoreML models)
stream_gb = 1.5         # two engine windows on one engine process
process_gb = 4          # a 73-min meeting peaked at 2.5 GB (the process plus the engine)
# notes_gb = 14         # default: what the notes model chosen in Settings needs (Gemma 14)
index_gb = 1            # the search index
```

With the Notion upload on, `run` writes the notes in the same process, so
its budget is at least what the notes model needs.

### Notes

By default a local model writes them through MLX
(`mlx-community/gemma-4-12B-it-OptiQ-4bit`: an 8.3 GB download on first
use, about 10 GB of memory while writing, up to ~12 GB for a long meeting).
It writes the notes in the meeting's language (German or English, detected
from the transcript). `process` writes notes after the transcript and
rewrites them only when the words change; `palaver notes <folder> [--force]`
writes them by hand. To use Claude instead (needs the Claude Code CLI,
logged in; the transcript is sent to Anthropic):

```toml
[notes]
engine = "claude"     # "local" (default) or "claude"
# local_model = "mlx-community/gemma-4-12B-it-OptiQ-4bit"  # or another MLX model
# model = "sonnet"    # for engine = "claude"
# enabled = false     # no notes at all
```

A choice in Settings → Language Model overrides `[notes].engine`. Qwen3 30B
A3B, offered until 0.3.9, is deleted at the first start after the update
unless config.toml names it.

### Cloud models and cloud transcription

API keys live in the login Keychain (service `palaver`, account
`<provider>.api_key`), never in a file. Every call sent to a cloud model or
service is listed in `access-log.jsonl` next to `settings.json`, without
content. An OpenAI-compatible endpoint is ready only once its endpoint is
saved and, unless it runs on this Mac, its key is set; for Azure the
endpoint must be your resource's. Redirects are never followed, so a key is
only ever sent to the endpoint you set.

Cloud transcription sends only the system track, after the call, in
`process`: long silences are cut out first and the offsets kept, and a
recording longer than the service takes at once is sent in overlapping
chunks and stitched back together. The service's word timestamps are lined
up with the local speaker turns. The glossary's terms and the invitees'
names go along as keyterms. The live worker and the realtime stream stay
local; their text is replaced by the service's. A meeting transcribed before
you chose a service is never sent. `transcription.json` in the meeting's
folder says who transcribed it (split and join carry it along; parts
transcribed differently join as "mixed", never sent again). What a service
refuses to delete yet (a job still running) is listed in the meeting's
`cloud-pending.json` and deleted at the start of the next `process`. Uploads
and new jobs are never sent twice after a timeout or a server error.

### Speakers, people and projects

**Speaker recognition.** Every speaker you name is remembered by voice;
later meetings name them automatically during `process` (and `rename`
pre-fills them). Matching is conservative — cosine similarity >= 0.75 and
clearly ahead of the next person, speakers with at least 10 s of speech —
so an unknown voice stays `SPEAKER_xx` rather than getting a wrong name.
Among a meeting's calendar invitees 0.65 is enough. Names you give manually
always win. Voice samples are stored in `~/.config/palaver/voices/`, one
file per person.

**Inferred names.** With the calendar and enough meetings, voices name
themselves. Four rules:
- calendar: a 1:1 with one voice that talks;
- elimination: all invitees but one are known;
- intersection: a recurring voice, and the one invitee its meetings share;
- voice: like a voice named by those rules.

Each inferred name says why, how sure it is, and which names it rests on
(`speakers_inferred.json`). They are recomputed from the facts whenever
names change, so rejecting one ("No") takes back everything built on it.
Guards: a voice must talk 30 s, other unnamed voices little, no meeting
room on the invite, no more voices than invitees. Inferred voices stay out
of the voice bank until you confirm the name ("Yes").

**Organizations** come from the invitees' email domain (contoso.es, .com and
.de are all Contoso; gmail and other private addresses are "Extern"); the
People page renames them and gives a person one by hand
(`~/.config/palaver/organizations.json`).

**Projects** are stored in `~/.config/palaver/projects.json`. A meeting
joins the project whose meetings it clearly resembles — the same people,
title words, or customer (the invitees' email domain) — and otherwise the
notes model places it, proposing a new project with a description when none
fits. From a terminal:

```bash
palaver projects suggest     # sort every meeting in no project
palaver projects describe    # describe projects that have no description
```

**Glossary.** Suggestions come from words that look or sound like a name
the app knows (calendar titles and attendees, people, projects, the
glossary itself), alike-sounding spellings across meetings, and rare
capitalized terms that recur ("rare": uncommon in German and English, by
`wordfreq`). The glossary is applied whenever a transcript is shown,
searched or summarized, while `transcript.json` keeps what was heard.
Stored in `~/.config/palaver/glossary.json`.

**Settings** from the window are stored in `~/.config/palaver/settings.json`,
not in `config.toml`; only switches you changed are written there, so the
Slack switch follows `[recording] slack` in `config.toml` until you change
it.

### Claude (MCP)

`palaver mcp` serves the meetings to Claude and other MCP clients over
stdio, read-only. Tools:
- `list_meetings`, `search_meetings`: filter by project, person, dates;
- `get_meeting`: notes first, the transcript or a time range only on request;
- `list_projects`, `get_project`;
- `list_people`;
- `open_next_steps`.

They use the same data as the window, with names, merges and the glossary
applied. A meeting marked "Keep on This Mac" is left out of lists, searches,
projects, people and next steps, and `get_meeting` says it is kept on this
Mac. `palaver mcp --install` adds it to Claude Code (runs `claude mcp add
--scope user palaver …`); `--install --desktop` adds it to Claude Desktop.
The server is called "palaver" (its instructions and tool descriptions name
meetings, calls, Teams, transcripts, next steps, customers, so Claude picks it
for such questions). Before 0.6.3 it was "meetings": at every start the app
renames Palaver's "meetings" entry to "palaver" in `~/.claude.json` (user and
project servers, and a project's `mcp__meetings__…` allowed tools) and in
Claude Desktop's config, its options and place kept; another server called
"meetings" is never touched.

### Transcription backends

`[model] transcriber` selects the speech-to-text model:

- `"parakeet"` (default; the old name `"parakeet-mlx"` still works) — NVIDIA
  Parakeet-TDT v3, run by `palaver-engine` on CoreML. On real meetings it matched Whisper on German and beat
  it on English (35 s instead of several minutes for 24 min of audio, no
  text over silence, passages Whisper skipped). It is verbatim (keeps "um",
  "äh") and has no `initial_prompt`; fix recurring misspellings with
  `[replacements]` in `dictionary.toml`.
- `"mlx-whisper"` — Whisper large-v3-turbo, uses the dictionary's
  `initial_prompt`.

### Problem reports

A report zip (from "Report a Problem…" or `palaver report create`) holds the
form, versions, this Mac's setup, `palaver doctor`, the settings without
secrets, every log (none is ever rotated or trimmed), Palaver's crash
reports, every meeting's logs and state, the chosen meeting complete (its
audio only when ticked) and the local usage counts
(`~/Library/Application Support/palaver/usage.jsonl`).

```bash
palaver report create -m "Notes never came"   # the same zip, about the latest meeting
```

## Releases

`make release` builds every asset into `dist/`. A pushed tag `vX.Y.Z` has
GitHub Actions (`.github/workflows/release.yml`) build them, sign them with the
kept certificate, smoke-install them and publish the release (below); on a Mac
the same recipe is the fallback.

- `palaver-app-<version>.zip`: Palaver.app, the Swift programs only
  (`tools/build_release.py app`); the build refuses a bundle with a Python
  interpreter, a `.py` file, `palaver-python` or a path of this Mac in it
- `palaver-runtime-no-python-1.tar.gz`: a placeholder of a few hundred bytes
  (the same every build). The updaters of releases before 0.6 refuse a manifest
  without a runtime and an app whose runtime.json names another one; they never
  run it. 0.6.0rc1 uploads it once, later releases keep its URL. The app deletes
  an old runtime folder after its first good start.
- `manifest.json`, `install.sh`, and `upload.txt`: the files this release must
  upload. An asset the previous release published unchanged keeps its URL
  there and is not uploaded again; the GitHub release is created from
  `upload.txt`. The manifest carries `docs/release-notes/<version>.md` as its
  notes, which the app's update shows.

### Publishing a release

1. Bump `VERSION` (`X.Y.Z`).
2. Write `docs/release-notes/X.Y.Z.md`: what testers notice, in Markdown. It
   heads the GitHub release (GitHub's generated list of changes follows it) and
   is the manifest's notes. A release without it fails.
3. Merge to master.
4. Run the maintainer's publish script. It syncs master to the public
   repository (kenodressel/palaver) as one commit, where `ci.yml` runs every
   test on it. Tags are not synced.
5. Tag that public commit and push the tag, from the publish script's clone of
   the public repository:

   ```bash
   git fetch origin
   git tag -a vX.Y.Z -m "Palaver X.Y.Z" origin/master
   git push origin vX.Y.Z
   gh run watch --repo kenodressel/palaver   # pick the Release run
   ```

`release.yml` then fails unless the tag is `v` + `VERSION` and the notes exist.
It builds `make release` on macOS (the newest Xcode, as `ci.yml`) with the
certificate in a temporary keychain, checks that the app is signed with it,
runs `make smoke-install` (which downloads 0.3.14 and 0.5.0rc6 from this
repository's releases) and deletes the keychain. Meanwhile it waits for
`ci.yml` to pass on the tagged commit instead of running the tests again.
Then a job without the certificate creates the release with `gh release
create` (the files `upload.txt` names, `--latest`) and waits until
`releases/latest/download/manifest.json` names the new version. Only the
owner's tag pushes and runs in kenodressel/palaver get that far; the workflow
has no `pull_request` trigger.

Actions → Release → Run workflow (or `gh workflow run release.yml --repo
kenodressel/palaver --ref master`) is a dry run: built, signed and
smoke-installed, nothing published. Unchecking "dry run" publishes only when
run on the tag `vVERSION`.

**Fallback** (CI down): on the Mac with the certificate,
`PALAVER_SIGN_IDENTITY="Palaver Release" make release smoke-install publish`
uploads from this Mac. `make publish` takes the same notes file.

An installed Palaver has two layers, each downloaded only when it changed:
the app (`~/Applications/Palaver.app`, every release) and the models
(`~/Library/Application Support/palaver/models/fluidaudio` for speech and
speakers, which the engine downloads itself, and `~/.cache/huggingface` for the
notes model and the search model). The updater (Swift, in the app) and install.sh
check each download against the manifest's SHA-256. `PALAVER_ASSETS_DIR=dist sh
install.sh` installs from local release assets; going back to a release before
0.6 takes that release's own install.sh, which installs its runtime.

### Signing releases

`make publish` refuses an app signed ad hoc. macOS remembers Microphone and
System Audio Recording for an app by its signature: a release signed with
the same certificate every time keeps them, while an ad-hoc signature (a
local `make release` without `PALAVER_SIGN_IDENTITY`) is new with every
build. Create one code-signing certificate, keep it (with a backup), and
sign every release with it:

- **Keychain Access:** Keychain Access → Certificate Assistant → Create a
  Certificate… → Name "Palaver Release", Identity Type "Self-Signed Root",
  Certificate Type "Code Signing" → Create. Export it with its private key as
  a `.p12` for the backup.
- **Or in a terminal:**

  ```bash
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Palaver Release" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout palaver-release.key -out palaver-release.crt
  openssl pkcs12 -export -inkey palaver-release.key -in palaver-release.crt \
    -name "Palaver Release" -out palaver-release.p12   # asks for a password: this is the backup
  security import palaver-release.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
  rm palaver-release.key                               # the .p12 holds it; keep that somewhere safe
  security find-identity -p codesigning                # "Palaver Release" is listed
  ```

Then `PALAVER_SIGN_IDENTITY="Palaver Release" make release publish`. A lost
certificate means a new one, and every tester is asked for the permissions
once more. A Developer ID certificate works the same way and also satisfies
Gatekeeper for downloads.

**For GitHub Actions** (once, and again for a new certificate): store the
`.p12` backup (from Keychain Access: the "Palaver Release" identity → Export →
`.p12`) and its password as the public repository's secrets:

```bash
base64 -i palaver-release.p12 | gh secret set PALAVER_SIGN_P12 --repo kenodressel/palaver
gh secret set PALAVER_SIGN_P12_PASSWORD --repo kenodressel/palaver   # asks for the .p12's password
```

`tools/release_keychain.sh` imports it into a temporary keychain with a random
password (`security import -T /usr/bin/codesign`, then `security
set-key-partition-list`), puts that keychain first on the search list (where
`codesign --sign "Palaver Release"` in `tools/app_bundle.py` finds it; there
is no `--keychain`), and signs a probe before the build. Self-signed, the
certificate shows as `CSSMERR_TP_NOT_TRUSTED` in `security find-identity`,
and codesign signs with it all the same. The keychain and the decoded `.p12`
are deleted at the end of the job, also when it fails.

`make smoke-install` installs `dist/` into a throwaway home under
`sandbox-exec` (no writes outside it, no network, no Python on `PATH`), checks
the bundle (no Python, signed without the hardened runtime, the programs answer), updates with
`install.sh` and with the app's Swift updater (`palaver-update-driver`, a
test-only program that does what the Updates menu does), runs 0.3.14's frozen
swap.sh, updates the published 0.3.14 and 0.5.0rc6 with their own updaters, and
uninstalls.

## README screenshots

The images in `docs/images/` show only made-up meetings, people and
companies, never real ones. They were taken from the window served over
fictional recordings in a throwaway home folder, the way `tests/e2e/` serves
it, in Playwright's WebKit at 1280×800 (device scale 2). When you replace
one, do the same: never screenshot your own meetings.
