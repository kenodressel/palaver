# Palaver in Swift, Phase 3: domain, server and pipeline — Design

**Date:** 2026-11-04
**Status:** Draft for Keno's review
**Parent:** `2026-11-03-swift-migration-design.md` (phase 3 of 4; this design widens it, see "Scope")
**Inventory:** `2026-11-04-phase3-inventory.md` (the window's server) and
`2026-11-04-phase4-inventory.md` §5 (every Python process left after phase 2).
This design refers to them instead of repeating them.

## Why

After phase 2 the app is native, but everything that reads or writes a
meeting is still Python: the window's server, the processing pipeline,
the live and realtime workers, the coach. They make up most of the
remaining 36 000 lines. Phase 3 moves all of it, except the language
models, which are phase 4.

## Scope: why the pipeline comes along

The parent design put only the server and its domain (meetings, people,
projects, glossary, search, voices, speaker inference) into phase 3. The
inventory shows that this split leaves **two writers of one domain**:

- `palaver process` rewrites `speakers_auto.json`, `speakers_inferred.json`
  (over every meeting), `transcript.json/.md`, `projects.json` and the
  voice bank;
- the server writes the same files when the user names, merges, cuts or
  sorts;
- nothing locks those files across processes today
  (phase 3 inventory §4, §9 risk 1 and 2).

With a Swift server and a Python pipeline, any numeric drift between the
two (a rounding, a threshold compare) would flip names back and forth.
So **phase 3 owns everything that writes meeting folders and stores**:

- the domain and the HTTP server (as the parent design said);
- the `process`/`run` pipeline: promotion, continuation join, echo
  cancellation, transcription and diarization through the engine,
  cleanup filters, merge, calendar attach, shared-mic signals,
  recognition, inference, transcript files, coach baseline, rule-based
  project sorting;
- the `live`, `stream` and `coach` workers, and `index` (search by
  meaning, with the e5 encoder: search and Claude's tools need the query
  vector, so the encoder cannot wait for phase 4);
- the small facts the app asks Python today (`app query …`) that belong
  to these parts, and `calendar attach`.

**Stays Python until phase 4**, started as helpers exactly as today:
everything with a language model or a cloud service — `notes`,
`projects suggest|describe`, `next-question`, cloud transcription,
Notion upload — plus `mcp`, the updater back end, downloads of the notes
model, `doctor`, `report` and the user's `palaver` CLI.

How the Swift side reaches them (*my calls*, from the builder check):

- **Cloud transcription** becomes its own Python helper,
  `palaver cloud-transcribe <folder>`: it does what `_process` does for a
  cloud-chosen system track today (silence cutting, chunking, stitching,
  pending deletes, `sweep_pending`) and writes only
  `system_segments.json` and `transcription.json`. The Swift pipeline
  calls it in place of the engine for that track; exit codes as the
  engine's (3 models, 4 error). Its memory is accounted like a worker's:
  it runs as a child of `palaver-worker process`, so the watchdog counts
  it in that worker's process tree under the `process` budget (amended
  after the plan's preflight).
- **`run`** (Notion auto-sync) becomes: Swift `process`, then the Python
  `notes` helper, then Python `sync <folder>`. The `notes` helper keeps
  doing notes and then the model's project sorting in one process (one
  model load), as `run` does today.
- **Settings that touch keys or the cloud** (`/api/language-model[/key|/test]`,
  `/api/transcription[/key|/test]`, the month's usage) go through one
  Python helper, `palaver provider <action> --json`. The Keychain stays
  Python until phase 4, so 0.6.0 brings no new Keychain prompt. The rest
  of these pages (settings.json reads and writes) is Swift.
- **Setup assistant:** the probe, permission states and recommendations
  are Swift; model downloads keep running the Python download command
  (the speech models through the engine, as today).
- **Report a Problem:** the server runs `palaver report create` as today.

## What changes

### One Swift domain library: `PalaverDomain`

A Swift module with the logic of the phase 3 modules (inventory §0):
paths, models, readable, render, titles, lifecycle, speakers, voices,
people, inference, attribution, calendar events (EventKit native),
organizations, shared mic, projects (store and rules), prep, glossary,
search (the query parser), undo, cutting, exchange, my notes (Vision
OCR native), storage, settings, model jobs, usage, the notes read side
(`transcript_hash`, staleness), coach and voice activity, merger,
cleanup, the search index and the e5 encoder.

It is used by three executables:

| binary | replaces | started by |
|---|---|---|
| `palaver-server` | `palaver webapp-serve` | the app's WebSupervisor, same listen-fd/ready-fd handshake, same env, same timings |
| `palaver-worker <cmd> <folder>` with `process`, `run`, `live`, `stream`, `coach`, `index`, `calendar-attach`, `query <what>` | the Python workers of the same names | the app's daemon, same QoS, same exit codes (3/4 and 75), same pid files |
| `Palaver` (the app) | — | links the domain for what it already asked Python (`app query`) |

*My call:* the server stays a **separate process**. A restart of the
window's server must stay possible during a call (`restart_web`, #57),
and a crash in a request must not take the recording with it.

*My call:* `palaver-worker` links the engine module directly instead of
talking JSON lines to `palaver-engine`. The worker is already its own
process, so the watchdog can still stop it. `palaver-engine` stays for
the Python helpers that still need it until phase 4.

### The HTTP server

- Same routes, shapes, status codes and texts (inventory §2, §3), same
  auth (host check, key sign-in, cookie), same static serving, same quirks
  the page relies on (§9 risk 14).
- Same concurrency semantics: a request may block up to 10 minutes on a
  model helper; notes requests are deduplicated per meeting; `Inflight`
  drains POSTs on restart but not helper waits; 409 behaviour as in
  test_webapp.py.
- Same background work (§4): search warming, import sweep, glossary
  warm-up, cut look-ups, OCR, idle timer of the encoder.
- *My call:* built on SwiftNIO (accepts on an inherited bound socket,
  streams request bodies, serves byte ranges), not on a hand-written
  HTTP parser.
- The language-model routes start the same Python helpers through the
  app (`start_helper`) or directly, as today.

### Echo cancellation

The WebRTC APM C library (`libraven_aec`) is linked into `palaver-worker`
as a C target. The spike showed identical output to the Python ctypes
path. The capture's PTS alignment stays as it is.

### File formats and parity

Nothing on disk changes. To keep it that way:

- **JSON is written like Python writes it:** key order as built, the
  same indent and separators, `ensure_ascii=False`, floats in Python's
  shortest `repr` (`1.0`, not `1`). One `PythonJSON` writer in the domain
  library; every store goes through it.
- **Byte-exact values** have golden tests against Python's output:
  `transcript_hash`, `my_notes.prompt_hash`, undo fingerprints, project
  and glossary ids, folder names.
- **Number-exact values:** cosines in Double; `round(x, 3)` with Python's
  correctly rounded semantics; average-linkage clustering (UPGMA) cut at
  0.25 with the same tie order; stable sorts everywhere.
- **Text rules:** Python `casefold()` (ß → ss) and Unicode `\w`/`\b`
  semantics in the search parser and the glossary.
- **Glossary data:** wordfreq's German and English Zipf tables ship as a
  data file (wordfreq's data is CC BY-SA 4.0, already shipped inside the
  Python runtime; THIRD_PARTY_LICENSES gets the entry). rapidfuzz ratio,
  Kölner Phonetik and difflib's matcher are ported with their tests.
- **e5 encoder:** a direct port of `embeddings.py` (BERT positions from 0,
  fairseq id offset, SentencePiece) on Accelerate. Gate: the tiny fixture
  bit-close and the real model's cosine ≥ 0.999 against Python. If it
  misses, the `model` string in `search-index.sig` changes and every
  meeting is reindexed (seconds each); then Python's `palaver mcp` gets
  its query vectors from `palaver-worker query embed` instead of its own
  encoder, so Claude's search keeps finding every meeting. With the
  `legacy-server` fallback active the two would reindex back and forth;
  that is accepted for the one release the fallback exists.
- **Export:** Ogg Opus through vendored libopus and libogg (BSD), as C
  targets. The exchange format does not change, so old exports import.

*My call:* a **parity harness** runs the Python and the Swift
implementation on the same fixture folders (the test meetings plus
anonymized copies of real meeting folders, kept local) and diffs every
written file. It runs in `make test` for the fixtures and on demand for
real folders. A module counts as ported when its harness diff is empty.

### Locks across processes

Until phase 4 the Python helpers still write a few stores
(`projects suggest` writes `projects.json`; the CLI's `rename` and
`voices` write names and the voice bank). Phase 3 adds one `flock` per
store (`<store>.lock` beside it), taken by Swift and by the remaining
Python writers, for: projects, glossary, organizations, attributions,
the voice bank, and each meeting's speaker files. The Python side of
this is a small change to code that otherwise stays as it is.

### Undo across the switch

Undo snapshots are a file format (`.trash/.undo/<token>/manifest.json`,
fingerprints). Swift restores snapshots the last Python server took; a
snapshot it cannot read is refused with the existing 404 text. Pending
model-sort undos (`.jobs/undo/`) are finished by whichever server sees
the job end, as today.

### The coach

The live coach worker (voice activity, nudges, `coach.json`) and the
coach numbers move. With it comes **#19**: a nudge shows as a Palaver
notification (no sound, goes away by itself), on by default, with a
switch in Settings → Live coach; each nudge is logged to `session.log`
(kind and time, not what was said); the Settings text says where nudges
appear.

### The end-to-end tests

The 227 Playwright tests run against the Swift server:

- the conftest starts `palaver-server` as a child with a fake app.sock
  (Python's own `palaver.appctl.serve` with test handlers, contract-tested
  against the Swift socket by `palaver-appctl-helper`; amended after the
  plan's preflight: the tests need answers they can change), a written `daemon.json`, fake
  helper commands for notes, projects and next question, and a test
  probe (hardware, downloads, test recording, calendar) behind an env
  switch that release builds ignore;
- tests that monkeypatch Python internals are rewritten to arrange files
  instead (inventory §7 lists them).

The Python unit tests of ported modules stay as the parity reference
until phase 4 deletes the Python code. *My call:* every Python test of a
ported module that pins behaviour gets a Swift counterpart (swift-testing,
the repo's convention; amended after the plan's preflight; same
name), because after phase 4 the Swift tests are the only coverage.
Tests that only pin Python internals (monkeypatching, import layout) are
skipped and listed in the ledger.

### Releases

*My call:* phase 3 ships as **one 0.6.0**, not one release per process.
The five processes share one domain; intermediate mixes would each need
their own parity and lock story. Keno gets release candidates through
the in-app updater as in phase 2 (rc1, rc2, …) before testers do.

### Fallback for one release

A marker `~/Library/Application Support/palaver/legacy-server` (or
`PALAVER_LEGACY_SERVER=1`) makes the app start the Python server and
Python workers again, like `legacy-app` in phase 2. The parity harness
and the locks make switching back safe.

## Not in phase 3

- language models, cloud providers, cloud transcription, Notion, MCP
  (phase 4);
- updater back end, uninstall, doctor, report, model downloads, the
  `palaver` CLI (phase 4, see its design);
- new features other than #19.

## Gates before release (0.6.0)

1. Full `make test` green: Python suite, Swift tests, JS tests, the e2e
   suite against the Swift server, the parity harness on the fixtures.
2. The parity harness on Keno's real meeting folders (copies, locally):
   no diff, or every diff explained and accepted in the ledger.
3. The in-process engine measured: `make eval-engine-worker` drives
   `palaver-worker engine-serve` (the engine as the pipeline now calls it,
   in-process) and its numbers equal a baseline recorded from
   `palaver-engine` before the switch (amended after the plan's
   preflight: `make eval-engine` alone never exercises the in-process
   path).
4. A real call recorded, processed and named by the Swift pipeline, and
   the window used for an afternoon.
5. Update path: 0.5.x → 0.6.0 through the in-app updater, and the
   fallback marker tested.

## Left to the builder

- Module order inside the domain (bottom-up from paths/models is the
  obvious one).
- SwiftNIO specifics, request threading, cache invalidation shapes, as
  long as the semantics above hold.
- How the parity harness anonymizes real folders.
