# Palaver

Aus dem Palaver wird ein Plan. Local transcription with speaker diarization
for Microsoft Teams meetings and Slack huddles on macOS: a menu bar app that
records, transcribes, says who spoke when, and writes notes. Fully offline
except for the optional Notion upload. Until October 2026 it was called
meeting-transcribe; its settings move to the new folders on the first start.

## Requirements

- macOS Tahoe (26.x) on Apple Silicon (M1 or later)
- Python 3.10+
- A HuggingFace account + token for pyannote's gated model
- A Notion internal integration with write access to a parent page

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/kenodressel/palaver/master/install.sh | sh
# or, to also start the menu bar app at login:
curl -fsSL https://raw.githubusercontent.com/kenodressel/palaver/master/install.sh | sh -s -- --autostart
```

This installs the latest GitHub release: a Python venv with exactly the
locked dependencies (via [uv](https://docs.astral.sh/uv/), ~1 GB on first
install) in `~/Library/Application Support/palaver/venv`, the
`palaver` command in `~/.local/bin`, and `Palaver.app` in
`~/Applications`. While the repository is private, install the GitHub CLI
and `gh auth login` first — the installer then downloads through it. Re-run
the same command to update.

Releases are built by GitHub Actions when a `v*` tag is pushed
(`.github/workflows/release.yml`): tests, the wheel (with the echo-cancellation
library prebuilt), `requirements.txt` exported from `uv.lock`, the app, and a
smoke install of all of it into a throwaway home directory. `make release`
and `make smoke-install` do the same locally.

## Setup (from source)

1. Install dependencies and build the vendored AEC library:

   ```bash
   uv venv
   uv pip install -e ".[dev]"
   ```

   Then build the WebRTC AEC library (see [V2: Speaker-bleed removal](#v2-speaker-bleed-removal)
   for details — requires Xcode Command Line Tools):

   ```bash
   cd palaver/_vendored/webrtc_aec
   cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
   cd -
   ```

2. On HuggingFace, accept the gated-model terms for
   `pyannote/speaker-diarization-community-1`. Create a token with Read
   permission.

3. In Notion, create an internal integration at notion.so/profile/integrations.
   Share a parent page with the integration (this is where meeting transcripts
   will appear).

4. Create `~/.config/palaver/config.toml`:

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

5. Export tokens (or add them to `config.toml` directly):

   ```bash
   export HF_TOKEN=hf_xxx
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

## Usage

Check the setup first — permissions, tokens, models, disk — with exact fixes:

```bash
palaver doctor           # --offline skips the Notion API check
```

Record a meeting:

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

Record Teams calls automatically — leave this running in a terminal tab:

```bash
palaver daemon           # watches for Teams calls
palaver daemon status    # from another terminal
```

The daemon starts recording once Teams has held the microphone for 4 s
(Teams keeps it open while you're muted), stops 10 s after Teams releases it
(`[recording] grace_period_seconds`), force-stops after
`max_session_hours`, and transcribes + uploads each recording longer than a
minute in the background, one at a time. It reads Teams' microphone use from
CoreAudio's per-process audio objects (macOS 14.4+). Slack huddles start
the same way (Slack holding the microphone); since Slack may close it while
you're muted, a huddle goes on while Slack still plays sound. No Slack
account access is needed. `[recording] slack = false` turns it off. It runs in a terminal
rather than as a launchd agent so it inherits the terminal's microphone,
screen and system-audio permissions. Log: `~/Library/Logs/palaver/daemon.log`.

**Processing during the call.** While it records, the daemon runs
`palaver live <folder>` at background priority (efficiency
cores, yields to Teams). It echo-cancels and transcribes the audio in ~1
minute blocks cut at pauses, and computes the expensive part of
diarization — the voice embeddings of pyannote's sliding windows — as the
audio arrives. When the call ends only the last block and the speaker
clustering are left, so the transcript is ready in seconds instead of
minutes, and the result is the same as processing the finished file. If the
live worker fails, `run` does everything after the call as before. Turn it
off with:

```toml
[processing]
live = false
```

**Memory budgets.** Each worker has a budget, measured as Activity Monitor's
"Memory" (the phys_footprint, GPU memory included). A live or realtime
worker over its budget for 10 s is restarted (twice per meeting, then
stopped: the transcript is then written after the call); the recording
itself goes on, since capture runs in the app. Notes, transcriptions and the
search index over budget only get a notification and finish, unless the Mac runs low on
memory (under 1.5 GB free for 10 s): then they stop and are tried again
later; the third time Palaver says what to do instead. The status line
shows what Palaver costs during a call ("· Palaver 5.4 GB"), Settings →
Memory shows each worker, and `palaver doctor` checks the budgets. The
defaults:

```toml
[memory]
live_gb = 6             # measured 2.4–3.7 GB over a 60-min call, 4.8 GB peak
stream_gb = 3.5         # measured ~1.9 GB, 2.5 GB peak
process_gb = 8
# notes_gb = 14         # default: what the notes model chosen in Settings needs (Gemma 14)
index_gb = 1            # the search index
```

With the Notion upload on, `run` writes the notes in the same process, so
its budget is at least what the notes model needs.

To keep transcripts local and upload by hand with `palaver sync
<folder>`, turn off the upload after each call:

```toml
[notion]
auto_sync = false
```

Or as a menu bar app (same auto-recording, plus manual start/stop, pause,
the Meetings window, and shortcuts to the latest recording and Notion page):

```bash
palaver menubar          # icon alone: waiting · 🔴 recording · ⏳ transcribing · ⏸ paused
```

Install it as a real Mac app that starts at login (no terminal tab needed):

```bash
palaver app install --login   # → ~/Applications/Palaver.app
palaver app uninstall
```

On first launch it asks for Microphone and System Audio Recording under its
own name — not Screen Recording: the microphone is captured with
AVCaptureSession and system audio with a Core Audio Process Tap.
ScreenCaptureKit (which needs Screen Recording) is only a fallback for a
source that fails. The bundle contains only a small
launcher that runs this checkout's virtualenv, so code changes apply on the
next launch; rebuild with `app install` if the venv moves. Tokens are read
from `config.toml`, the environment, or the login Keychain
(`app install --store-tokens` copies them there from the current shell).

The Meetings window's server runs in a process of its own, which the app
starts again when it crashes. After a change to the window or its API,
restart only that process, at any time, also during a call (the recording
is never touched; the window reloads where it was):

```bash
palaver app restart-web
```

A change anywhere else (recording, call detection, the menu) still needs the
whole app restarted, and that should wait until nothing records or processes
(`palaver daemon status`).

**Meetings window.** "Open Meetings" (⌘M in the menu) opens a window of the
menu bar app with every recording:

- **Notes:** title, one-line summary, the topics in order, next steps with
  owners and decisions, written by a language model after each call.
- **Transcript:** without filler words and stutters (`transcript.json` keeps
  the verbatim text). Click a line to hear it.
- **Who spoke when:** one lane per speaker. Click a lane to play from there,
  type a name next to it, or pick a suggestion — a voice-bank match or a
  name the conversation reveals ("Hi Rico"). Naming takes effect in the
  transcript and the notes at once; giving two speakers the same name
  merges them, and correcting a name moves the voice sample to the right
  person.
- **Search** across all notes and transcripts (⌘F).

The window is part of the menu bar app — the same process that records — and
reads the recordings folder directly; nothing leaves the Mac.

**Notes.** By default a local model writes them through MLX
(`mlx-community/gemma-4-12B-it-OptiQ-4bit`: an 8.3 GB download on first
use, about 10 GB of memory while writing, up to ~12 GB for a long meeting). It writes the notes in the
meeting's language (German or English, detected from the transcript).
`process` writes notes after the transcript and rewrites them only when the
words change; `palaver notes <folder> [--force]` writes them by
hand. To use Claude instead (needs the Claude Code CLI, logged in; the
transcript is sent to Anthropic):

```toml
[notes]
engine = "claude"     # "local" (default) or "claude"
# local_model = "mlx-community/gemma-4-12B-it-OptiQ-4bit"  # or another MLX model
# model = "sonnet"    # for engine = "claude"
# enabled = false     # no notes at all
```

**Cloud models (optional).** Settings → Language model chooses the model
per feature (notes, projects): on this Mac (the default), the Anthropic
API, an OpenAI-compatible endpoint (OpenAI, your Azure OpenAI tenant, a
company or self-hosted gateway) or the Claude Code CLI. A choice made there
overrides `[notes].engine`. Nothing goes to the cloud until you choose it
for a feature; a provider that isn't set up never runs, and nothing falls
back to another model. API keys live in the login Keychain (service
`palaver`, account `<provider>.api_key`), never in a file; the page only
shows whether one is set. The Settings page says what each feature sends
where and lists every call sent to a cloud model (`access-log.jsonl` next
to `settings.json`, without content). A meeting marked "Keep on This Mac"
(its ⋯ menu) is never sent to a cloud model, and Claude can't read it
through MCP: the tools leave it out of lists, searches, projects, people
and next steps, and `get_meeting` says it is kept on this Mac. An
OpenAI-compatible endpoint is ready only once its endpoint is saved and,
unless it runs on this Mac, its key is set; for Azure the endpoint must be
your resource's. Redirects are never followed, so a key is only ever sent
to the endpoint you set. A meeting too long for the
model's context window is refused with a message, never cut short.

**Cloud transcription (optional).** Settings → Transcription chooses who
transcribes meetings: Parakeet on this Mac (the default), AssemblyAI,
Soniox (both EU servers by default), Mistral Voxtral or an
OpenAI-compatible endpoint (`/audio/transcriptions` with word timestamps,
e.g. `whisper-1`). Only the system track goes out, after the call, in
`process`: long silences are cut out first and the offsets kept, and a
recording longer than the service takes at once is sent in overlapping
chunks and stitched back together. Your microphone stays on Parakeet, and
who spoke when is still worked out on this Mac: the service's word
timestamps are lined up with the local speaker turns. The glossary's terms
and the invitees' names go along as keyterms. The live worker and the
realtime stream stay local; their text is replaced by the service's. If the
service fails (or is no longer set up), the meeting is transcribed on this
Mac and a notification says so; no other cloud is tried. A meeting marked
"Keep on This Mac" is always transcribed here, and a meeting transcribed
before you chose a service is never sent. Keys live in the Keychain like
the language models'; every upload is in the same access log (provider,
host, seconds of audio, meeting, how it went), and Settings shows the
estimated cost this month. `transcription.json` in the meeting's folder
says who transcribed it (split and join carry it along; parts transcribed
differently join as "mixed", never sent again). What a service keeps is
deleted there once the words are back; what it refuses to delete yet (a
job still running) is listed in the meeting's `cloud-pending.json` and
deleted at the start of the next `process`. Uploads and new jobs are never
sent twice after a timeout or a server error.

**Calendar.** With "Connect Calendar…" in the menu, a recording is matched
to the event in the macOS Calendar app that overlaps it most (any account
added there, e.g. Microsoft Exchange; read-only, on this Mac). The event's
title becomes the meeting's title, its invitees are listed and offered as
names for unnamed speakers, the notes know who was invited, and voice
recognition among the invitees needs only 0.65 similarity instead of 0.75
— a voice only has to be told apart from the few people invited. You,
rooms and people who declined are left out. `[calendar] enabled = false`
turns it off.

**Projects.** Meetings are grouped into projects (a customer, an initiative,
a topic such as hiring); a meeting may be in several. After its notes are
written, a meeting joins the project whose meetings it clearly resembles —
the same people, title words, or customer (the invitees' email domain) —
and otherwise the notes model places it, proposing a new project with a
description when none fits. The Projects tab lists them: rename them, edit
or let the model write their descriptions, merge two into one, confirm or
remove meetings. A meeting you take out of a project stays out. Stored in
`~/.config/palaver/projects.json`; from a terminal:

```bash
palaver projects suggest     # sort every meeting in no project
palaver projects describe    # describe projects that have no description
```

**Glossary.** Names and terms come out of transcription misspelled, and
differently each time ("Atterkring", "CAREL", "Wasti"/"Vasti"). The
Glossary tab suggests fixes, which you accept (correcting the spelling if
needed) or reject:
- words that look or sound like a name the app knows: calendar titles and
  attendees, people, projects, the glossary itself;
- alike-sounding spellings across meetings;
- rare capitalized terms that recur ("Databricks").

"Rare" means uncommon in German and English (`wordfreq`), so ordinary nouns
are left alone. The glossary is applied whenever a transcript is shown,
searched or summarized, while `transcript.json` keeps what was heard. Each
change reports how many words it respelled in which meetings, and their
`transcript.md` is rendered again. Stored in
`~/.config/palaver/glossary.json`.

**Claude (MCP).** `palaver mcp` serves the meetings to Claude
and other MCP clients over stdio, read-only. Tools:
- `list_meetings`, `search_meetings`: filter by project, person, dates;
- `get_meeting`: notes first, the transcript or a time range only on request;
- `list_projects`, `get_project`;
- `list_people`;
- `open_next_steps`.

They use the same data as the window, with names, merges and the glossary
applied. Add it to Claude Code with `palaver mcp --install`
(runs `claude mcp add --scope user meetings …`).

**Coming up.** The meeting list starts with the next day and a half of
calendar meetings (events with someone invited). Each can be prepared:
- pick its project now, from suggestions; a recurring meeting suggests where
  its earlier occurrences went. The recording gets the project once it is
  matched to the event.
- see the meetings that lead up to it: earlier occurrences of the series,
  else the last ones with the same people, with their summary and next
  steps.

**Live.** A meeting being recorded can be opened in the window: the
transcript builds up minute by minute (the live worker writes `live.json`
after each block) and refreshes every 10 s. Speakers are clustered from the
voices heard so far, so labels may still change. A name given meanwhile is
stored with the voice (`speakers_live.json`) and moves to the right
speaker in the final transcript. The project can be set too.

**Realtime.** While a call is recorded, `palaver stream <folder>` (started by
the app) transcribes the last 10 s every second. The Meetings window shows
the other side's words about 2–3 s after they are said, and your own words
once their echo is filtered out. It is only for watching live: the final
transcript is made as before, and nothing depends on the stream. Switch it
in the settings page (the gear next to the Palaver name): "Realtime
transcription" applies from the next recording; "Record Teams calls
automatically" and "Record Slack huddles automatically" apply at once.
Settings are stored in `~/.config/palaver/settings.json`, not in
`config.toml`; only switches you changed are written there, so the Slack
switch follows `[recording] slack` in `config.toml` until you change it.

Replay recorded meetings as if they were live, to measure the stream:

```bash
palaver bench-live <folder>... --out DIR [--speed 1.0]
```

It writes a numbers-only report (latency, disagreement with the final
transcript, echo, load) to `DIR/report.md`. At `--speed 1.0` it measures
latency; faster speeds measure accuracy and load only.

It loads two Parakeet models side by side (the live worker's and the
stream's) plus pyannote, and the offline baseline after each replay, so
don't run it during a call. `--out` must
lie outside the Recordings folder: it keeps full audio copies of every
replayed meeting and the stream's transcript text, which is meeting
content. Only `report.md` is numbers only.

**Cut and join.** Back-to-back calls can run into each other. Hover over a
transcript line (in the meeting or in the review) and press ✂ to cut
there: the rest becomes a meeting of its own, the start of the recording
that follows, or goes to the trash; what came before can go to the trash
too. "join with the one
before/after" in a meeting's header puts two recordings of one meeting
back together. Audio, transcript, speakers and names move along; the same
voice in both parts becomes one speaker. The longer recording keeps the
meeting (calendar, names, project). The other is moved to
`<recordings>/.trash`, and notes become stale. When a calendar meeting
starts while a recording runs and voices come or go around then, the
meeting page and the review suggest the cut ("Cut at 28:10…", or "Not
this").

**Review.** "Review · N waiting" at the top of the meeting list steps
through finished meetings one by one: confirm the project, name the
speakers, take or skip 1–3 glossary suggestions from that meeting, check
the notes. "Done, next" marks the meeting reviewed (`review.json`).

Process an existing recording:

```bash
palaver run ~/Meetings/Recordings/2026-04-17T14-30-00
```

List recordings and their state:

```bash
palaver list
```

Or name the remote speakers in a terminal (plays a short sample of each;
Enter keeps the label, giving two labels the same name merges them):

```bash
palaver rename ~/Meetings/Recordings/2026-04-17T14-30-00
```

**Speaker recognition.** Every speaker you name in `rename` is remembered
by voice; later meetings name them automatically during `process` (and
`rename` pre-fills them, Enter confirms). Matching is conservative — cosine
similarity >= 0.75 and clearly ahead of the next person, speakers with at
least 10 s of speech — so an unknown voice stays `SPEAKER_xx` rather than
getting a wrong name. Names you give manually always win.

**Coach.** A meeting's "Coach" tab shows how you talked, compared with
what is usual for you (1:1s and groups apart, filler words per language):
- talk share against a fair share;
- monologues (over 1:30 without anyone else), pace, filler words;
- questions, and whether you waited for an answer;
- interruptions both ways, and invitees who barely spoke.

Moments link into the audio. "All meetings →" lists every meeting's
numbers. Only your own speech is analyzed.

**Organizations.** People show with their organization: "Timo Strauß
(KLOUD)", "Stefan D (Extern)". It comes from the invitees' email domain
(contoso.es, .com and .de are all Contoso; gmail and other private
addresses are "Extern"). The People page renames organizations and gives
a person one by hand (`~/.config/palaver/organizations.json`).
Big rounds list their invitees grouped by organization.

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

Voice embeddings are biometric data. They are stored only on this machine in
`~/.config/palaver/voices/` (one file per person) and never
uploaded:

```bash
palaver voices                 # who is stored
palaver voices forget "Anna"   # delete someone's voice
```

Delete synced recordings older than `retention_days` (unsynced ones are kept
unless `--include-unsynced`):

```bash
palaver prune --dry-run
palaver prune
```

Use a meeting-specific vocabulary for one run with
`palaver --dictionary ~/vocab/legal.toml run <folder>`.

`process`, `sync` and `run` show a macOS notification when the transcript is
ready or uploaded, or when a step fails (`--no-notify` to turn off).

### Reporting a problem

"Report a Problem…" (menu bar menu, Help, ⌘K, Settings, a meeting's ⋯, an
error) writes one zip to the Desktop, `Palaver report <date>.zip`, and
shows it in Finder: the form, versions, this Mac's setup, `palaver doctor`,
the settings without secrets, every log (none is ever rotated or trimmed),
Palaver's crash reports, every meeting's logs and state, the chosen meeting
complete (its audio only when ticked) and the local usage counts
(`~/Library/Application Support/palaver/usage.jsonl`). Nothing is uploaded.

```bash
palaver report create -m "Notes never came"   # the same zip, about the latest meeting
palaver report open <zip>                     # unpack and summarize (versions, errors, devices, pipeline)
palaver report usage <zip>...                 # feature use across testers
```

## Transcription backends

`[model] transcriber` selects the speech-to-text model:

- `"parakeet-mlx"` (default) — NVIDIA Parakeet-TDT v3, same model as sabbel.
  Transcribes in 15 s chunks: with longer chunks German meetings full of
  English terms flipped into wrong English. On real meetings it matched
  Whisper on German and beat it on English (35 s instead of several minutes
  for 24 min of audio, no text over silence, passages Whisper skipped). It
  is verbatim (keeps "um", "äh") and has no `initial_prompt`; fix recurring
  misspellings with `[replacements]` in `dictionary.toml`.
- `"mlx-whisper"` — Whisper large-v3-turbo, uses the dictionary's
  `initial_prompt`.

## First run

- macOS will request **Microphone** permission the first time `record` runs.
- macOS will request **System Audio Recording** permission the first time
  system audio is captured. Screen Recording is not needed.
- The Parakeet model (~1.2GB) downloads on first use.
- The pyannote diarization model downloads on first use.

## How it works

1. **Record**: captures mic and system audio as two separate WAVs (16kHz mono PCM_16) in a timestamped folder under `output_dir`.
2. **Process**: transcribes both tracks via Parakeet-TDT v3 (`parakeet-mlx`, Apple Silicon GPU; Whisper optional), diarizes the system track via `pyannote.audio`, merges words to speakers, writes `transcript.md` and `transcript.json`.
3. **Sync**: uploads the transcript as a new Notion page under the configured parent.

Stages are independent and resumable — if a step fails (e.g. model download dies), rerun `process` or `sync` and it skips what's already done.

Before merging, `process` drops Whisper hallucinations over silence ("Thank
you.", "Yeah." at 30 s window boundaries) and mic segments that repeat
remote speech from the same moment (speaker bleed the AEC let through). With
`language = "auto"` the system track's detected language is reused for the
mic track.

Each recording folder gets a `session.log` (JSON lines): capture warnings
(tap fallback, mic stalls, resampler re-anchors), stage durations, dropped
segment counts, the Notion page URL, and any failure with its traceback.

## V2: Speaker-bleed removal

Recordings capture the microphone via ScreenCaptureKit and system audio via a
Core Audio Process Tap on every process except the recorder itself. All
sources timestamp on the CoreAudio host-time clock, so the tracks are aligned
by presentation timestamp. The Process Tap coexists with other system-audio
recorders (Notion Meeting Recorder, QuickTime, OBS, Teams cloud recording),
which can starve ScreenCaptureKit's audio output. It follows default-output
changes (headphones, AirPods) by rebuilding itself on the new device. If the
tap cannot start — e.g. the terminal lacks the *System Audio Recording*
permission — `record` warns and falls back to ScreenCaptureKit system audio.

ScreenCaptureKit delivers the microphone at the input device's native rate
(e.g. 48 kHz), not the configured 16 kHz; the recorder reads each buffer's
format and resamples per track, following rate changes when the input device
switches mid-meeting.

The recorder writes:

- `mic_raw.wav` — raw microphone audio.
- `system.wav` — system-output loopback.

During `palaver process`, a new AEC step produces `mic.wav` from
those two tracks using WebRTC's AudioProcessing (vendored from
`Laxcorp-Research/project-raven`, MIT; pre-built WebRTC static libs, BSD-3).
The downstream transcription / diarization pipeline consumes `mic.wav`
unchanged.

Result: participants' voices coming out of laptop speakers are no longer
re-captured in the mic track. Works with any output configuration (built-in
speakers, headphones, AirPods, external speakers).

### Build step

The vendored WebRTC library needs to be built once after install:

```bash
cd palaver/_vendored/webrtc_aec
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

Requires Xcode Command Line Tools (`xcode-select --install`). Rebuild after
pulling updates that touch `palaver/_vendored/`.

## Limitations (V1)

- No auto-detect daemon: you run `record` manually and Ctrl+C to stop. Teams auto-start is in Plan 2.
- Generic speaker labels (`SPEAKER_00`, `SPEAKER_01`, …) for remote participants. Your mic track is labeled with your `[user].name`. Naming remote speakers by voice is a V2 item.
- SCStream (microphone) can stop delivering without an error (issue #18); there is no watchdog yet.

## Development

```bash
uv run pytest                    # default tests (no models, no hardware)
uv run pytest -m integration     # opt-in integration tests
uv run pytest -m soak tests/test_soak.py -s   # before a release: 60 min of live + stream at real speed under a memory ceiling
uv run palaver --help
```
