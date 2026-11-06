# Palaver in Swift, Phase 2: the app — Design

**Date:** 2026-11-04
**Status:** Draft for Keno's review
**Parent:** `2026-11-03-swift-migration-design.md` (phase 2 of 4)
**Inventory:** `2026-11-04-phase2-inventory.md`. Everything the `palaver menubar` process does today, with file:line references. This design refers to it instead of repeating it.

## Why

Phase 1 moves the speech models to Swift. The process that runs all day
is still Python: menu bar, capture, call detection, daemon and window.
It is the part users feel most:

- it runs during every call;
- it owns the permissions;
- it is the reason the release ships a Python host as the app.

Phase 2 makes the app itself native. What is left in Python after it are
workers the app starts, the same way it starts them today.

## What changes, what stays

**Becomes Swift:** one native app binary, `Palaver`, the bundle's
executable. It replaces both the ObjC launcher and `palaver menubar`.
- **Launcher duties:** logging to `app.log`, notifications, notification
  clicks, signals.
- **Capture:** the process tap, the AVCaptureSession mic and the
  ScreenCaptureKit fallback, with resampling, PTS alignment, `.part`
  writing, finalize, audio health and levels.
- **Call detection** (Core Audio per-process properties) and the
  start/stop trigger.
- **The daemon:** state, queues, continuation, crash recovery, the
  left-behind marking, stop questions, silent calls, manual start/stop,
  the memory watchdog, notifications, and `daemon.json`.
- **`app.sock`:** all 13 calls, same wire format.
- **Menu bar:** icon, title, status lines, menu items.
- **The window:** WKWebView, native menus and the JS bridge. It still
  supervises the Python web server, with the same listen-fd/ready-fd
  handshake.
- **Permissions:** mic, system audio, calendar access, notifications.

**Stays Python, started by the app as workers** (as today):
- `webapp-serve`, `process`/`run`, `notes`, `live`, `stream`, `index`,
  `mcp`, and the window's helpers (`start_helper`).
- New small worker commands for what the menubar process did in-process
  and phase 2 does not port. The Swift app runs them as children:
  - `palaver coach <folder>`: the live coach (VoiceMonitor, nudges). It
    writes `coach.json` into the folder, and the daemon reads it for its
    status. *My call:* the coach is 770 lines of logic with 34 tests; it
    moves with the server in phase 3.
  - `palaver app housekeeping`: at app start, `storage.drop_retired`,
    `mcp_access.migrate`, pruning runtimes; hourly, `storage.Cleanup`.
  - `palaver calendar attach [--since HOURS]`: what the 5-minute calendar
    retry does in-process today. The app keeps the EventKit access request
    itself, so the permission belongs to Palaver.
  - `palaver app query <what> [args] --json`: the Python facts the daemon
    needs. Each one is asked rarely (every 30 s at most):
    - `missing-models <folder>`
    - `index-stale`
    - `notes-memory <folder>`
    - `next-event` and `event-key <time>`, for continuation and the coach
  - `palaver app update check|download|status --json`: the updater's
    network and staging. The app decides when to swap: it checks
    `busy_reason`, runs `swap.sh`, quits, and writes `started-ok` on the
    next start, as today.
  - `palaver onboarding analyze <wav>`: the test recording's analysis and
    transcription. The capture itself is Swift.
- **Echo cancellation** stays in the Python `live` and `process` workers
  until those move. The parent design said AEC moves in phase 2; *my
  call:* it moves with the live worker. Capture keeps the PTS alignment
  that AEC depends on.

**Contracts that must not change** (inventory §9 has the full list):
- the meeting folder files written during recording (`mic_raw.wav(.part)`,
  `system.wav(.part)`, `meta.json` fields, `audio_problems.json`,
  `session.log` event names, `parts.json`, `failed.json`);
- the end-of-recording rule: `meta.json` exists and there is no `.part`;
- `daemon.json` keys and meanings, since webapp, doctor, report and
  process read them;
- `app.sock` calls, arguments, replies and refusal texts;
- the environment for children: `PALAVER_APP`, `PALAVER_NOTIFY`,
  `PALAVER_NOTIFY_STATE`, `PALAVER_WEB_KEY`, `--app-socket`, and the
  forwarded `--config`, `--dictionary` and `--no-notify`;
- the bundle id `com.kenodressel.meeting-transcribe`, the signing
  identity, Info.plist usage texts, `LSUIElement`, minimum macOS 15.0;
- the LaunchAgent, the `started-ok` and `permissions-requested` markers,
  and `swap.sh`'s expectations;
- the window URL and key cookie scheme, the native menus (`MEETING_MENU`,
  `VIEW_MENU`), and the bridge messages.

`palaver_alive` (daemon.py:291) recognizes the app by command line. It
learns the Swift binary's path, so `DaemonRunning` and the left-behind
marking still see the running app.

## Goals

1. **Same behaviour.** Every row of the inventory is either ported or
   covered by a worker command above. The ~600 Python tests that pin it
   become Swift tests where the logic moves, or stay as cross-language
   contract tests where Python is the client: appctl client,
   `webapp/remote.py`, `daemon.json` readers.
2. **Lighter app.** The app at rest uses under 80 MB (today ~170 MB for
   menubar plus ~30 MB for the launcher). During a call the app itself,
   without workers, stays under 150 MB.
3. **Seamless update** from the last Python-app release:
   - permissions stay, since the identity and bundle id are the same;
   - a recording that was running is recovered as a `cut`;
   - the queue in `daemon.json` is taken over.
4. **Alignment preserved.** On a synthetic test, mic and system tracks
   stay within ±20 ms. The AEC's 10 ms mic lead depends on this.

## Non-goals

- No UI changes: the window, the menus and their texts stay.
- No port of the web server, notes, people, projects, search or MCP
  (phase 3/4).
- No new call apps (#16) and no floating indicator.

## Anti-goals

- A call that is not recorded, or is recorded into the wrong meeting.
- Tracks that drift apart, or a `.part` that never gets finalized.
- Users asked for permissions again after the update.
- A meeting stuck "Recording" or "Transcribing" after a crash of the app.

## Testing and safety

- **Pure logic** gets Swift unit tests ported from the Python ones:
  - the trigger, stop questions and silent calls;
  - queue and continuation;
  - texts (`menu_title`, `status_line`, `recording_lines`,
    `manual_title`, lifecycle wording);
  - alignment, resampling and the part writer, audio health, the level
    tracker;
  - the memory watchdog;
  - the appctl wire format.
- **Contract tests** run the Python clients (`appctl.call`, `remote.py`,
  doctor's `daemon.json` reading) against the Swift server and its
  written files, with a fake capture.
- **Capture on real hardware** needs the mic, so it is never run without
  Keno's OK.
  - Unattended tests use synthetic sources only: a fake source that
    delivers buffers with PTS, including jitter, gaps, rate changes and
    stalls.
  - The process tap is started only with nothing playing. Starting it
    plays no sound.
- **The e2e suite** keeps running against the Python web server, as
  before.

## Rollout

- The release builds the Swift app as the bundle executable. The Python
  host is renamed `palaver-python` and is what workers run.
- A hidden fallback, `PALAVER_LEGACY_APP=1` (environment) or a marker file
  in Application Support, starts the old `palaver menubar` path for one
  release, in case the Swift app fails on a tester's Mac.
- Keno tests with real calls first. The testers get it as a normal update
  after that.

## Left to the builder

- The Swift module split. Suggested: `PalaverCore` (pure logic and
  texts), `PalaverCapture`, `PalaverDaemon`, `PalaverApp` (AppKit UI,
  window, entry point).
- Resampling: AVAudioConverter or vDSP. It must meet the alignment goal
  and reproduce the re-anchor rule (drift > 320 frames, or a rate change).
- A minimal TOML reader for the `config.toml` keys the app needs, or a
  pinned TOML package.
- The concurrency design: a main-actor tick every 1 s, as today, or
  actors.
