# Contributing to Palaver

How to run Palaver from a checkout, test it, and make a release. What
Palaver does for its users is in the [README](README.md).

## Setup (from source)

You need macOS 15 or later on Apple Silicon, [uv](https://docs.astral.sh/uv/)
and the Xcode Command Line Tools (`xcode-select --install`, for cmake and the
echo-cancellation library).

1. Install the dependencies and build the vendored echo-cancellation library:

   ```bash
   uv venv
   uv pip install -e ".[dev]"
   make aec          # palaver/_vendored/webrtc_aec: cmake, once and after it changes
   ```

   `make aec` runs:

   ```bash
   cd palaver/_vendored/webrtc_aec
   cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
   cmake --build build
   ```

   Rebuild after pulling updates that touch `palaver/_vendored/`.

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
uv run palaver doctor    # --offline skips the Notion API check
uv run palaver --help
```

## Tests

```bash
make test            # the whole suite, in parallel (pytest-xdist); TEST_WORKERS=0 runs it in order
make test-changed    # only the tests for what changed since master (tools/changed_tests.py)
uv run pytest -m integration     # opt-in: real models or external services
uv run pytest -m soak tests/test_soak.py -s   # before a release: 60 min of live + stream at real speed under a memory ceiling
```

Use `make test-changed` while you work, and run `make test` once before a
merge. Both build the echo-cancellation library first.

- The default tests need no models, no hardware and no network: the root
  `tests/conftest.py` gives every test a temporary config folder, a fake
  Keychain, no notifications and no network beyond 127.0.0.1.
- `tests/e2e/` drives the Meetings window's page in Playwright's WebKit,
  served from synthetic recordings in a temporary folder
  (`tests/e2e/recordings.py`). Install WebKit once with
  `uv run --extra dev python -m playwright install webkit`; without it these
  tests are skipped (in CI they fail instead).
- `tests/js/` holds the page's JavaScript unit tests, run with node through
  `tests/test_js.py` (skipped without node).

CI (`.github/workflows/ci.yml`) runs `make aec` and `make test` on macOS 15.

## Make targets

`make help` lists them:

| Target | What it does |
|---|---|
| `aec` | Build the vendored WebRTC echo-cancellation library |
| `test` | Run the test suite (in parallel) |
| `test-changed` | Run the tests for what changed since master |
| `eval-engine` | Maintainer-only gate: the Swift engine against the old stack's numbers on your own recordings. Needs `PALAVER_EVAL_DIR` (a folder with a local `eval.json`); writes numbers only to `engine-gate.md`. The exit code contract is `tools/eval_engine.py`'s: 0 pass, 1 a check FAILED, 2 misconfigured. Through make both failures show as make's exit 2, so read the printed table |
| `wheel` | Build the wheel (includes the AEC library) |
| `requirements` | Export the locked dependency set the runtime is built from |
| `icons` | Draw the app and menu bar icons into `palaver/assets` (needs Pillow) |
| `runtime` | Build the runtime archive (kept while `uv.lock` is unchanged) |
| `models` | Pack the models Palaver hosts (none now; the engine downloads its own) |
| `app` | Build Palaver.app with the wheel's code inside, zipped |
| `manifest` | Write `manifest.json` and `upload.txt` over the assets in `dist/` |
| `release` | All release assets in `dist/` |
| `smoke-install` | Install `dist/` into a throwaway home, check it, and simulate an update |
| `publish` | Create the GitHub release of this version from `dist/upload.txt` |
| `clean` | Remove build output (the runtime archive too) |

## Running it from a checkout

As a menu bar app (auto-recording, manual start/stop, the Meetings window).
The app is native Swift since 0.5 (`native/`, target `Palaver`): it records,
runs the daemon, serves `app.sock`, hosts the window and starts the Python
workers (`process`, `notes`, `live`, `webapp-serve`, …) with the checkout's
`.venv/bin/python` (`PALAVER_PYTHON` overrides it):

```bash
make app-swift && native/.build/release/Palaver   # icon alone: waiting · 🔴 recording · ⏳ transcribing · ⏸ paused
palaver menubar          # the Python menu bar app of before (kept for one release)
```

A release's `Palaver.app` holds the Swift app as its executable
(`Contents/MacOS/Palaver`), the Python host `palaver-python` (Palaver's code
on the runtime, what every worker runs), `palaver-engine`, and the code in
`Contents/Resources/python`. `PALAVER_LEGACY_APP=1`, or an empty file
`~/Library/Application Support/palaver/legacy-app`, makes it start the
Python menu bar app (`palaver-python -m palaver menubar`) instead, for one
release, in case the Swift app fails on a Mac. A development build of the
Swift app asks for the microphone and system audio for the terminal that
runs it; run it only when you mean to record.

Install the Python menu bar app of this checkout as a Mac app that starts at
login (no terminal tab needed; the release's app is the Swift one):

```bash
palaver app install --login   # → ~/Applications/Palaver.app
palaver app uninstall
```

On first launch it asks for Microphone and System Audio Recording under its
own name — not Screen Recording: the microphone is captured with
AVCaptureSession and system audio with a Core Audio Process Tap.
ScreenCaptureKit (which needs Screen Recording) is only a fallback for a
source that fails. The bundle contains only a small launcher that runs this
checkout's virtualenv, so code changes apply on the next launch; rebuild with
`app install` if the venv moves. Tokens are read from `config.toml`, the
environment, or the login Keychain (`app install --store-tokens` copies them
there from the current shell).

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

Or without the menu bar, in a terminal tab:

```bash
palaver daemon           # watches for Teams calls and Slack huddles
palaver daemon status    # from another terminal
```

It runs in a terminal rather than as a launchd agent so it inherits the
terminal's microphone and system-audio permissions. Log:
`~/Library/Logs/palaver/daemon.log`.

Record by hand:

```bash
palaver record           # Ctrl+C stops
palaver record --run     # process + sync immediately after stop
palaver record --quiet   # no live level meter
```

While recording, a live meter shows both tracks once per second:

```
rec 00:42 | mic ███▂      -35 dB | system            -- dB (silent 12s)
```

`system` reading `--` with a silence counter is normal while nobody remote
is talking — the system-audio tap delivers nothing while no audio plays. If
the microphone delivers nothing for 30 s, `record` prints a warning.

Process an existing recording, list recordings, name speakers in a terminal:

```bash
palaver run ~/Meetings/Recordings/2026-04-17T14-30-00
palaver list
palaver rename ~/Meetings/Recordings/2026-04-17T14-30-00
```

`rename` plays a short sample of each speaker; Enter keeps the label, giving
two labels the same name merges them.

Delete synced recordings older than `retention_days` (unsynced ones are kept
unless `--include-unsynced`):

```bash
palaver prune --dry-run
palaver prune
```

`process`, `sync` and `run` show a macOS notification when the transcript is
ready or uploaded, or when a step fails (`--no-notify` to turn off).

## How it works

1. **Record**: captures the microphone and the Mac's sound as separate WAV
   tracks (16 kHz mono PCM_16) in a timestamped folder under `output_dir`.
2. **Process**: removes speaker bleed from the microphone track (below),
   transcribes both tracks with Parakeet-TDT v3 and diarizes the system
   track, both in `palaver-engine` (a Swift helper running FluidAudio's
   CoreML models; Whisper optional), merges words to speakers, writes `transcript.md` and
   `transcript.json`, then the notes.
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

Replay recorded meetings as if they were live, to measure the stream:

```bash
palaver bench-live <folder>... --out DIR [--speed 1.0]
```

It writes a numbers-only report (latency, disagreement with the final
transcript, echo, load) to `DIR/report.md`. At `--speed 1.0` it measures
latency; faster speeds measure accuracy and load only. It loads two engines
side by side (the live worker's and the stream's), and
the offline baseline after each replay, so don't run it during a call.
`--out` must lie outside the Recordings folder: it keeps full audio copies
of every replayed meeting and the stream's transcript text, which is meeting
content. Only `report.md` is numbers only.

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
--scope user meetings …`).

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
palaver report open <zip>                     # unpack and summarize (versions, errors, devices, pipeline)
palaver report usage <zip>...                 # feature use across testers
```

## Releases

`make release` builds every asset on this Mac into `dist/`. GitHub Actions'
`release.yml` runs the same recipe as a manual dry run but never publishes:
only the Mac with the signing certificate does (below).

- `palaver-app-<version>.zip`: Palaver.app with the code from the wheel
  (including the echo-cancellation library), compiled ahead
- `palaver-runtime-<id>.tar.gz`: built only when its id is new; the id is a
  hash of the locked requirements (exported from `uv.lock`), the Python
  version, its python-build-standalone release and the arch
  (`RUNTIME_PYTHON` and `PBS_RELEASE` in the Makefile). The build downloads
  [python-build-standalone](https://github.com/astral-sh/python-build-standalone)
  into `dist/build`, checked against the release's `SHA256SUMS`, installs the
  requirements into it with uv, makes the entry points relocatable, and
  `otool` checks that no library names `/Users`, Homebrew or `/usr/local`
- `manifest.json`, `install.sh`, and `upload.txt`: the files this release must
  upload. An asset the previous release published unchanged keeps its URL
  there and is not uploaded again; `make publish` creates the GitHub release
  from `upload.txt`.

An installed Palaver has three layers, each downloaded only when it changed:
the app (`~/Applications/Palaver.app`, every release), the runtime
(`~/Library/Application Support/palaver/runtime/<id>/`, when `uv.lock`
changes) and the models (`~/Library/Application Support/palaver/models/fluidaudio` for
speech and speakers, which the engine downloads itself, and
`~/.cache/huggingface` for the notes model and the search model). The updater checks each download
against the manifest's SHA-256. The runtime before the current one is kept,
so `PALAVER_VERSION=0.1.0 sh install.sh` goes back without a download, and
`PALAVER_ASSETS_DIR=dist sh install.sh` installs from local release assets.

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

`make smoke-install` installs `dist/` into a throwaway home under
`sandbox-exec` (no writes outside it, no network), imports Palaver and its
dependencies as the app runs them, and updates twice, with `install.sh` and with the app's
updater, checking the runtime is not downloaded again.

## README screenshots

The images in `docs/images/` show only made-up meetings, people and
companies, never real ones. They were taken from the window served over
fictional recordings in a throwaway home folder, the way `tests/e2e/` serves
it, in Playwright's WebKit at 1280×800 (device scale 2). When you replace
one, do the same: never screenshot your own meetings.
