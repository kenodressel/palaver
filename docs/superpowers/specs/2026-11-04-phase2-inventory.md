# Phase 2 inventory: what `palaver menubar` does today

Repo at commit 2e31afc. All paths are relative to the repository root.

## 0. Modules and line counts
| module | lines | role in the menubar process |
|---|---|---|
| palaver/menubar.py | 786 | UI shell, Updates, permissions, calendar retry, finalize |
| palaver/daemon.py | 1642 | state machine, queues, workers, daemon.json |
| palaver/appctl.py | 301 | app.sock server and client |
| palaver/lifecycle.py | 174 | pure texts: why/stop/gap/problem wording |
| palaver/app_bundle.py | 549 | launcher ObjC and host C source, Info.plist, LaunchAgent |
| palaver/install_layout.py | 127 | Application Support layout, markers |
| palaver/session.py | 153 | RecordingSession: folder, session.log, meta.json |
| palaver/recorder.py | 42 | writes meta.json start/end/duration |
| palaver/capture_recorder.py | 1133 | capture, resample, align, write .part, health wiring |
| palaver/_audio/process_tap.py | 777 | Core Audio process tap |
| palaver/_audio/av_mic.py | 248 | AVCaptureSession mic |
| palaver/audio_health.py | 276 | incident detection |
| palaver/meter.py | 166 | LevelTracker reading .part files for the menu and silence |
| palaver/continuation.py | 171 | parts.json (add_part at record time; join is in `process`) |
| palaver/cutting.py | 603 | not used at record time (split/join run in process and web) |
| palaver/shared_mic.py | 396 | only `remembered(event)`, used by the live-coach context |
| palaver/teams_detector.py | 214 | CallDetector |
| palaver/memory.py | 504 | Watchdog, footprint, signal_group |
| palaver/process_state.py | 67 | failed.json |
| palaver/notify.py | 114 | notifications through the launcher or osascript, click listener |
| palaver/updater.py | 549 | Updater state machine, Installer, swap script |
| palaver/uninstall.py | 107 | uninstall script |
| palaver/webapp/window.py | 355 | WKWebView window and native menus |
| palaver/webapp/process.py | 408 | WebSupervisor and the server side of webapp-serve |
| palaver/webapp/remote.py | 260 | server-side clients of app.sock and daemon.json |
| palaver/calendar_eventkit.py | 101 | EventKit |
| palaver/keychain.py | 88 | provider API keys (not called by the menubar process directly) |
| palaver/onboarding.py | 1301 | TestRecording, Calendar, meeting_starting, downloads_running |
| palaver/live_coach.py | 332 / voice_activity.py 442 | in-process live coach |
| palaver/storage.py | 227 | Cleanup (hourly), drop_retired |
| palaver/model_jobs.py | 241 | helper launch for start_helper |
| palaver/settings.py | 156 / config.py 149 | settings.json, config.toml |
| palaver/session_log.py | 127 / runlog.py 130 / usage.py 238 | logs, crash log, usage.jsonl |
| palaver/live.py | 366 | worker_running/stop_worker (live.pid), recording_finished |
| palaver/mcp_access.py | 494 | `migrate()` at start |

## 1. Process model

**Launcher** (app_bundle.py:98-301, compiled by `compile_launcher` at :394; argv `python -m palaver [opts] menubar` at :402):
- Opens the log `~/Library/Logs/palaver/app.log` (`RELEASE_LOG` :40, `APP_LOG` :34), O_APPEND, and dups it onto the child's stdout and stderr (:247-255).
- Only when bundled (:258), it does the following:
  - Creates a `socketpair(SOCK_DGRAM)`; the child's end becomes fd 3 and `PALAVER_LAUNCHER_FD=3` is set (:259-265). Clicks arrive as the datagram `"open <meeting>"` (:158-165).
  - Binds a notify socket `$TMPDIR/palaver-<pid>.sock` (SOCK_DGRAM) and sets `PALAVER_NOTIFY` (:216-240). Each datagram is a JSON `{title, message, open}` and is posted through UNUserNotificationCenter. If macOS refuses, it falls back to osascript and logs that once to app.log (:168-194).
  - Calls `requestAuthorization(Alert)` and writes `$TMPDIR/palaver-<pid>.notifications` with `allowed|denied|not_asked`, then again every 10 s; that path goes in `PALAVER_NOTIFY_STATE` (:196-212, :270-280).
- Forwards SIGTERM, SIGINT and SIGHUP to the child (:123-125, :282-284). Starts the child with `posix_spawn` (:285).
- A waiter thread at QOS_UTILITY unlinks both temp files and exits with the child's exit code, or 128+signal (:286-293). **There is no restart.**
- In a release build, a prelude checks that the runtime's python3 exists; if not, it shows an NSAlert "Palaver can't start" and returns 78. It then runs `Contents/MacOS/Palaver` (the host) instead (:317-328).
- The host C (:336-373) sets `PYTHONHOME=<runtime>`, `PYTHONPATH=Contents/Resources/python`, `PALAVER_APP=<bundle>`, `PYTHONNOUSERSITE`, `PYTHONDONTWRITEBYTECODE`, then dlopens libpython and calls `Py_BytesMain`. `sys.executable` is therefore the host, and every worker is "Palaver" too.
- `__main__.py:6` calls `clean_environment()` (install_layout.py:108), which drops PYTHONHOME and PYTHONPATH when `PALAVER_APP` is set.
- Info.plist (:49-72): bundle id `com.kenodressel.meeting-transcribe`, `LSUIElement`, min macOS 15.0, usage texts for microphone, audio capture and calendars (full access and legacy). Signing (:385-440) is ad hoc unless `PALAVER_SIGN_IDENTITY` is set.
- LaunchAgent `~/Library/LaunchAgents/com.kenodressel.meeting-transcribe.plist` runs `/usr/bin/open -g -a <app>` with RunAtLoad and no KeepAlive (:75-82, :501-507). Install deletes the permissions marker (:495).

**CLI entry**: `main` (cli.py:1533) installs the crash log (`~/Library/Logs/palaver/crashes.log`), calls `usage.record("cli","menubar",by=app)`, `migrate.move_old_folders()` (meeting-transcribe → palaver) and `notify.set_enabled(not --no-notify)`. `_cmd_menubar` (cli.py:158) line-buffers stdout and calls `run_app`. On `DaemonRunning` it prints, notifies "Palaver is already running" and returns 1.

**run_app** (menubar.py:758-786):
- Routes rumps and PyObjC printed exceptions into the crash log.
- Wraps everything in `session_log(~/Library/Logs/palaver/daemon.log)` (JSON lines) and emits `event("app_start")` with the version stamp.
- Calls `create_app`.
- Starts the `request_permissions` thread.
- Sets SIGTERM → `rumps.quit_application()`.
- Adds the 1 s timer to common run-loop modes (:739-743), so it keeps ticking while the menu is open, then calls `app.run()`.

**create_app / MeetingApp.__init__** (menubar.py:459-755), in order:
1. `record_settings = settings.Cached(Settings(record_slack=cfg.record_slack))` (:477-478).
2. `build_daemon(cfg, cli_options, silence=…, others_silence=…)` (:493). The silence callbacks are fed from the LevelTracker.
3. `onboarding.TestRecording()` (:498), `Updates(...)` (:499), `storage.Cleanup(output_dir)` (:500), and a `retired-models` thread running `storage.drop_retired` (:501).
4. `appctl.app_calls(...)` plus calendar, update_check, update_install and uninstall (:503-517); `appctl.serve(APP_SOCKET)` (:518).
5. `WebSupervisor(child_argv, listener=listen_for_window(), env=child_env(os.environ), on_ready=reload_in_place if restarted)` and `.start()` (:519-524).
6. Menu items (:528-546), the 1 s `rumps.Timer(self.tick)` (:547), `notify.on_click(open meeting)` (:748), `window.on_quit(app.quit)` (:749), and `before_quit → finalize(app)` (:751-753).

**Threads in the process**:
- main (AppKit run loop, timer, all daemon ticks)
- `app-socket`, plus one thread per connection (daemon_threads)
- `web-supervisor`, and `web-stop` at quit
- `notification-clicks`
- `request_permissions`
- `retired-models`
- Updates: `prune_runtimes`, `_move_mcp_entries`, `updates` (check and download worker)
- `audio-cleanup` (hourly)
- calendar attach threads
- Capture: writer thread, AVMic route watcher (1 s), ProcessTap route watcher (1 s), Core Audio realtime IOProc, dispatch queue `palaver.mic`
- Live coach: VoiceMonitor (0.25 s), `coach-context`, `coach-stop`
- model_jobs reaper `<kind>-helper`
- TestRecording Timer and finish thread

**Children of the menubar process**:
| child | argv | QoS / session | stdout | where |
|---|---|---|---|---|
| window server | `sys.executable -m palaver [opts] webapp-serve --listen-fd N --ready-fd M --app-socket ~/Library/Application Support/palaver/app.sock` | `start_new_session`, stdin=PIPE (parent-death signal), pass_fds; env has `PALAVER_WEB_KEY`, no `PALAVER_LAUNCHER_FD`; no taskpolicy | inherited (app.log) | webapp/process.py:79-88, 257-270 |
| live | `/usr/sbin/taskpolicy -c background python -m palaver [opts] live <folder>` | start_new_session | appended to daemon.log | daemon.py:389-413, 1607 |
| stream | `… -c utility … stream <folder>` (only when Settings.realtime) | same | daemon.log | :1610 |
| process | `-c utility … run <folder>` if `cfg.notion_auto_sync`, else `… process <folder> --no-notes` | same | daemon.log | :1592-1595 |
| notes | `-c utility … notes <folder>` (only without auto_sync and with notes_enabled) | same | daemon.log | :1596-1599 |
| index | `-c background … index` | same | daemon.log | :1603 |
| window helpers (start_helper) | `taskpolicy -c utility python -m palaver [opts] --no-notify notes <folder> --force` or `projects --no-wait suggest\|describe <id>` | start_new_session; job record `<output_dir>/.jobs/<kind>-<key>.json` with log `.log` | job log | model_jobs.py:127-189 |
| test-recording transcription | `python -m palaver.onboarding transcribe <wav> <repo>` (HF_HUB_OFFLINE=1, 120 s timeout) | – | captured | onboarding.py:875-884 |
| swap / uninstall | `/bin/sh <support>/updates/swap.sh` and `/bin/sh $TMPDIR/palaver-uninstall.sh` | start_new_session, outlive the app | devnull | updater.py:466, uninstall.py:99-106 |
| misc | `ps -p … -o command=`, `ps -axo command=`, `vm_stat`, `osascript` (notify fallback), `open x-apple.systempreferences…` (calendar) | | | |

`cli_options` passed on: `--config <abs>`, `--dictionary <abs>`, `--no-notify` (daemon.py:1633-1642).

**Lifecycle**:
- Quit menu → `quit_reason="by_you"`. ⌘Q in the window → `app.quit` → by_you.
- SIGTERM, logout or the update quit → default `"restart"` (menubar.py:712-717, :386).
- `finalize` (:378-389): stops the timer, calls `daemon.shutdown(reason)` (finalizes the WAVs; a call is kept as a `cut` when the reason is restart), stops the web server in the background, and closes app.sock (which unlinks it).
- `Updates.tick()` returning True → stop the timer and `rumps.quit_application()` (:588-590).
- started-ok: the first successful `daemon.tick()` writes `install_layout.started_ok_path()` (`<support>/started-ok`) containing the bundle version (:315-327, :578-580). swap.sh waits up to 120 s for it.
- Crash recovery: at the next start, from daemon.json (section 4).
- Single instance: `DaemonRunning` when daemon.json has a live state and `palaver_alive(pid)` (daemon.py:541-544).
- **Latent bug**: `notify.on_click` (notify.py:96) pops `PALAVER_LAUNCHER_FD` at startup. `Updates.app_pids` (menubar.py:329-333) later reads that env var, so the launcher's pid is never in `wait_for`. This is masked by swap.sh's `pgrep -f "$target/Contents/MacOS/"` wait (updater.py:420). test_menubar.py:448 tests `app_pids` alone, so it does not catch this.

## 2. Capture

**Session** (session.py:26-142):
- `new_recording_folder(output_dir, now)` makes `YYYY-MM-DDTHH-MM-SS[-N]` (paths.py:218).
- `CaptureRecorder(mic_raw_path=mic_raw.wav, system_path=system.wav, problems_path=audio_problems.json)`.
- `session_log(<folder>/session.log)` is entered for the whole recording. All `palaver.*` log records of the process, including daemon and detector lines, land there too.
- `event("record_start", system_source, mic_source, missing, trigger)` plus the version stamp; `usage.record("recording_start", …)`.
- Stop: `Recorder.stop` → `capture.stop()` (finalize and rename), then writes meta.json `{start_time, end_time, duration_seconds}` (recorder.py:33-42). Session then adds `trigger` (teams|slack|manual|test), `stop_reason`, `audio_problems` (list without `id`), unlinks audio_problems.json, and emits `event("record_stop", reason, mic_seconds, system_seconds)` and `usage.record("recording_stop", …)` (session.py:117-142).
- **End-of-recording contract**: workers detect the end as `meta.json` existing and no `.part` file (live.py:335-338). `cli._status` calls a folder "recording" while a .part changed within 60 s (cli.py:1196-1213). `process` renames .part to final (cli.py:1217-1230) and rebuilds meta from the audio after a crash.

**Sources** (capture_recorder.py:729-821):
- The process tap and AVMic are tried first; ScreenCaptureKit only fills in for a source that failed (`_start_scstream_with_retries`: 3 attempts, 2 s apart, :762-774).
- `system_source`: `process-tap` or `scstream`. `mic_source`: `avcapture` or `scstream`.
- If both sources fail, start raises "neither the microphone nor system audio…". If one fails, the recording continues and `missing` gets "microphone" or "system audio".

**Process tap** (_audio/process_tap.py):
- `CATapDescription initMonoGlobalTapButExcludeProcesses([own pid, parent pid])`, private, unmuted, mixdown, mono (:159-171). Excluded pids are translated with `kAudioHardwarePropertyTranslatePIDToProcessObject` (:631-650).
- Private aggregate "Palaver System Audio", UID `palaver.system-tap.<uuid>`, main sub-device = default output, TapAutoStart, drift compensation (:215-261).
- `AudioDeviceCreateIOProcIDWithBlock`; the IOProc must return `inOutputTime` (:263-287, :660-676).
- PTS = `AudioConvertHostTimeToNanos(mInputTime.mHostTime)` (:682-688). The rate is the aggregate's nominal rate, not the tap format's (:527-529, :616-629).
- Route watcher every 1 s (:549-579):
  - Default output changed → rebuild.
  - Rate changed → follow it.
  - Nothing delivered for 5 s → rebuild, doubling the wait up to 60 s.
  - A failed rebuild sets `problem="device"` and retries every tick (:581-607).
- Error mapping (:408-423): IllegalOperation → "permission denied - System Settings -> Privacy -> System Audio Recording"; Unsupported → "requires macOS 14.4+".

**AVMic** (_audio/av_mic.py):
- `AVCaptureDevice.defaultDeviceWithMediaType(audio)` → AVCaptureSession + AVCaptureAudioDataOutput on serial queue `palaver.mic` (:101-128).
- Authorization 1 or 2 → `AVMicPermissionError` (:37-41).
- Route poll every 1 s: a new default input UID → reopen. `problem` is `"access"` or `"device"` (:215-248). `device_name` is the device's localizedName.

**ScreenCaptureKit fallback** (:823-943):
- Display filter, `capturesAudio`, 16 kHz mono, `captureMicrophone`, 2×2 video at 1 fps, `excludesCurrentProcessAudio`.
- `getShareableContent` timeout 5 s, `startCapture` timeout 10 s.
- A generation counter discards a late start.

**Decode** (:113-218): LPCM only, float32/64 or int16/32, interleaved or planar, averaged to mono. PTS comes from `CMSampleBufferGetPresentationTimeStamp`.

**Resample and align**:
- `_TrackResampler` (:230-303): soxr `ResampleStream(native→16000)`. The output PTS is kept from the output sample count. It re-anchors (flush and restart) when the rate changes or the accumulated drift exceeds 20 ms (`PTS_TOLERANCE_FRAMES = 320`). A re-anchor is reported to health.
- Writer thread (:947-968): drains both queues, checks health every 0.25 s, waits 20 ms when idle.
- Phase A buffers until both tracks have a first PTS, or one track alone has run 2 s. Then `start_pts = min(first PTS)` (:1087-1110).
- Placement (:1112-1133): offset = round((pts − start_pts) × 16000).
  - Drift within ±320 frames: write contiguously.
  - Overlap: trim.
  - Gap: zero-pad (in `_IncrementalTrackWriter.write_chunk_at_offset`).
- float → int16 with clip at 32767.

**Files** (:306-411):
- `<name>.part` starts with a 44-byte header with data size 0.
- PCM16 mono 16 kHz is appended through Python's buffered file. `flush()` exists but CaptureRecorder never calls it, so readers see data in OS-buffer-sized steps.
- `finalize_to(own length)`: truncate, patch the header, rename `.part` → final. Each track keeps its own length (issue #18).
- `abort()`: patch the header in place and do not rename. After SIGKILL the header stays at the placeholder.

**Health**:
- Mic stall: warning after 30 s, repeated every 60 s; "microphone audio resumed" logged (:1020-1037, :1064-1071).
- System stall: 30 s, process-tap only (:997-1000).
- `AudioHealth` (audio_health.py), incident kinds:
  - `speed`: 5 of the last 10 s off by more than 4 %, judged per 1 s bucket; whole-cycle jumps count as lost cycles unless they are most of the pairs.
  - `length`: written length vs the clock, more than 3 s, closed after 5 s fine.
  - `stalled`.
  - `access` / `device`: open only after 4 s.
- Soft hint `silent` mic: digital silence for 60 s while the system side is heard (≥ 0.01 peak); shown once per recording, and kept as a problem only if it lasts to the end.
- Incident shape: `{id, kind, track, start, end, at}`.
- Each open/close logs event `audio_problem` (with `text` and `reanchors_per_minute`) or `audio_problem_over` into session.log and rewrites `audio_problems.json` atomically with fsync (:986-1018, :678-694).
- Health failures are guarded: after 3 failures health is switched off for the recording with a one-time warning (:658-676).

**Live levels** (meter.py:71-124, menubar.py:637-649):
- `LevelTracker` reads at most the last 16 000 bytes of each `.part` file per tick.
- dBFS RMS; sound threshold −45 dBFS.
- Gives `quiet_for()` (both tracks) and `quiet_for("system")`. These feed `Daemon` `silence` and `others_silence`.

**Not at record time**:
- "10 ms mic lead": aec.py:58-66 (`MIC_LEAD_MS=10`) in `process`, which assumes PTS-aligned WAVs (`STREAM_DELAY_MS=0`, aec.py:51-56). That makes alignment accuracy a contract.
- cutting.py (split/join) and most of shared_mic.py.

**Max length and splits**:
- `max_session_hours` (default 4) → stop `max_length`, then `blocked` until the mic is released.
- An app switch held for ≥ 4 s → stop (call_ended) and start a new meeting.
- Continuation across restarts: section 4.

**Test recording** (onboarding.py:693-840):
- Up to 20 s into a temp dir, through `RecordingSession(trigger="test", log=False)`.
- Aborted by `meeting_starting()`, a lock held around `daemon._start`.
- `_analyze`: levels (speech above −50 dB on the mic, quiet below −60 dB on the system track), plus an offline Parakeet transcription in a subprocess.

## 3. Call detection (teams_detector.py)

- Core Audio system object `prs#` → per process `pbid` (bundle id), `ppid`, `piri` (running input), `piro` (running output). Read-only, through ctypes (:24-122).
- Teams: bundle prefix `com.microsoft.teams` with input running (a muted mic still counts).
- Slack: `com.tinyspeck.slackmacgap` with input running → in huddle. While in huddle, output alone keeps the call (muted mic) (:174-202).
- Both holding: the app that took the mic last wins; a tie goes to Teams (:196).
- Switches are asked on every call: `teams=lambda: current().record_teams`, `slack=…record_slack` from settings.json (daemon.py:1588).
- `ignore(app)`: after a silent-call stop, the app's hold is not a call until it has let go for 10 s (`RELEASED_SECONDS`). Persisted in daemon.json `ignored` and restored at start (daemon.py:547-548, :789).
- Every change in the call apps' audio is logged ("call apps' audio: …").
- Trigger (daemon.py:84-169): `start_after=4.0`, `grace=cfg.grace_period_seconds` (default 10), `max_session=max_session_hours*3600`, states idle/recording/blocked. Polled once per 1 s tick.
- When the detector fails, the last state is kept; logged once on failure and once on recovery (:843-858).

## 4. Daemon (daemon.py)

**Constants** (:35-81):

| constant | value |
|---|---|
| START_AFTER | 4 s |
| MIN_PROCESS_SECONDS | 60 |
| LIVE_FINISH_TIMEOUT | 15 min |
| INDEX_CHECK_SECONDS | 5 min |
| INDEX_RETRY_SECONDS | 60 min |
| INDEX_MEMORY_GB | 1.0 |
| SILENCE_ASK_SECONDS | 10 min |
| KEEP_QUIET_SECONDS | 30 min |
| SILENT_CALL_STOP_SECONDS | 30 min |
| DOUBLE_CLICK_SECONDS | 3 |
| CONTINUE_WITHIN | 5 min |
| NOTIFY_GROUP_SECONDS | 30 |
| EXIT_BUSY | 3 |
| RETRY_SECONDS | 60, doubling up to 15 min |
| MODELS_CHECK_SECONDS | 30 |
| STOP_GRACE | 60 |
| KILL_AFTER | 10 |
| process_state.EXIT_MODELS | 4 |

**tick** (:560-577): reap children → watch memory → release an expired cut → (manual: `_watch_manual`; auto: detect and Trigger) → silent-call check → audio notifications → pump (notes, then work, then index) → `_write_state`.

**State and status**: `state` is `recording`, `paused` (only when `_auto` is False; `set_auto` is never called in production) or `idle`. The menu shows `paused` when both record switches are off (menubar.py:217-222). `stopped` is written by `shutdown`.

**daemon.json** (`~/Library/Application Support/palaver/daemon.json`, atomic write through `.tmp`, every tick; :763-801, :1465-1475). Keys:
- Recording state: `state`, `auto`, `manual`, `since`, `folder`, `system_source`, `mic_source`, `missing`, `teams_active`, `stop_question` (`{meeting, reason, minutes, message}`), `ignored`.
- Queues and work: `queued[]`, `transcribing`, `transcribing_folder`, `notes_queued[]`, `writing_notes`, `indexing`, `index_downloading`.
- Why it records:
  - `why`: `{trigger, since, restarts, mic{device,rate,source}, system{device,rate,source}, problems[{kind,track,start}], hints[{kind,track}]}`
  - `why_text` (lifecycle.recording_text plus "Palaver 5.4 GB")
  - `warnings[]`, `hints[]`
- `memory`: `{total, app, workers[{kind,label,meeting,pid,used,budget,state}], budgets}`, plus a notes entry while it waits for memory.
- Coach: `talk`, `talk_text`, `nudge`, `quiet[]`.
- Stops and continuation: `last_stop` (`{folder, reason, text, at}`), `continues[]`, `cut` (`{folders, trigger, at, since, seconds}`).
- `pid`, `updated`.

Readers: webapp/remote.py (stale after 30 s), api.py:1857, doctor.py:306, report.py:253, `recording_into` (used by `process` through continuation.being_recorded).

**Queues**:
- `_queue` is restored from `queued`, dropping folders that are gone or already have the done marker: `notion.json` with auto-sync, else `transcript.md` (:353-362, :1622).
- `_notes_queue` is restored from `notes_queued`, done marker `notes.json`.

**_pump_work** (:1264-1326):
- When the running `process` exits:
  - rc 0 → queue notes.
  - rc 3 → retry later with backoff.
  - rc 4 → wait for models: notify "transcribed once the models are downloaded" and check every 30 s.
  - other → mark failed.json ERROR "it stopped unexpectedly, exit N" (unless `process` already wrote one) and notify "Transcription failed".
  - A run stopped by the memory watchdog is handled by `_watch_memory`.
- Picking the next folder: the first one past its `retry_at`. It waits for its models if needed, and waits up to 15 min for live workers of it and all its parts (`live.pid`). After that it sends `stop_live` (SIGTERM) and gives 60 s grace, then launches.
- `transcribe_again` (:1346-1360) clears failed.json and puts the folder first.

**_pump_notes** (:1373-1414): one at a time, never during a recording or while processing; a call that starts terminates notes and puts them back at the front. Free memory comes from `vm_stat` (free + inactive + speculative + purgeable, :365-376) and must be at least `llm.notes_memory_gb(cfg, folder)` (0 for cloud, else MODEL_MEMORY_GB or 20). Notes stopped for memory back off.

**_pump_index** (:1416-1457): only when fully idle and ≥ 1 GB free. `index_wanted = Settings.search_meaning and semantic.stale(output_dir)`. Any other work terminates it. Failure → retry after 1 h; success → check again after 5 min. `shutdown` terminates it.

**Start** (:986-1051):
- `before_record` (test-recording gate) → `session.start()`. On an exception it notifies "Meeting recording failed" and blocks until the mic is released.
- Continuation check, then notifications: "Recording without the {missing}", or "Recording continued", or "Recording meeting".
- Launch live (Settings.live_processing), the live coach (calls only), and stream (Settings.realtime).

**Stop** (:1210-1255):
- `session.stop(reason)`. On an exception it notifies and queues anyway.
- reason `restart` with a call trigger → hold back as `cut`.
- Otherwise `_queue_meeting(parts+folder, duration)`. Under 60 s → failed.json ERROR "shorter than a minute" and the notification "under a minute, not transcribed". Else "Meeting recorded" / "N min — transcribing in the background".

**Continuation** (:908-934, :1005-1021): the next start with the same call app within 5 min, with a part still on disk and not a different calendar event (EventKit ±2 h, `event_key_at`), calls `continuation.add_part` (writes `parts.json` on the head) and restores `since` and the max-length clock.

**Crash recovery** (`_recover_crash`, :878-899): daemon.json not "stopped" with a folder → a call becomes a `cut`; manual or unknown is queued at once.

**_mark_left_behind** (:936-961): at start, any recording folder with both WAVs, no transcript, no failed.json, not queued, not a part, no live worker and no running `palaver … <folder>` process gets failed.json ERROR.

**Stop questions** (:174-284, :695-723, :860-876):
- Manual recording: `StopQuestion` asks once when a call it saw is released for the grace period, or after 10 min of silence without a call. "Keep" waits for the next call end or 30 min of quiet.
- Automatic recording: `SilentCall` asks after 10 min with the others silent, and stops by itself after 30 min with both silent (unless kept). The stop notifies "Recording stopped: nothing heard" and makes the app's hold ignored.
- `answer_stop_question("stop"|"keep", meeting)` returns False when the meeting is not the running one or there is no question.

**Manual control**: `start_manual` returns False if already recording, if it is a double click within 3 s of a stop, or if the start failed. `stop_manual` stops with `by_you` and makes the call app's hold ignored, or blocks until release (:662-693). `switched_off(app)` stops an automatic recording of that app with `auto_off` (:653-660).

**Memory watchdog** (memory.py:270-410, daemon.py:1099-1204):
- Samples `proc_pid_rusage` phys_footprint per worker tree (live, stream, process, notes, index, question helpers registered through `watch`), plus the app process and its other children.
- Budgets in GB: live 6, stream 3.5, process 8, notes = model need or 14 (cloud 2), index 1. Overridable in `[memory]`.
- Over budget for ≥ 3 samples and 10 s:
  - live/stream → restart (2 per meeting), then stop.
  - notes/process/index → act only when free memory is under 1.5 GB: requeue, and drop the third time.
  - Otherwise warn once.
- SIGTERM goes to the process group (`signal_group`); SIGKILL after 10 s; then relaunch live/stream while still recording.
- Notification texts are in memory.py:418-448.

**Notifications sent by the daemon** (title / click target):
- "Recording meeting", "Recording continued", "Recording without the microphone|system audio"
- "Meeting recording failed"
- "Meeting recorded" (three variants)
- "Transcription failed"
- "Audio problem while recording" (one per cause, grouped within 30 s)
- Stop-question titles "Call ended — still recording" / "Silent for N min — still recording"
- "Recording stopped: nothing heard"
- memory.py texts
- The menu sends update notifications.

**busy_reason** (:1533-1546; gate for updates): recording / a call / transcribing (or anything queued) / writing notes.

## 5. IPC: app.sock (appctl.py)

- Path `~/Library/Application Support/palaver/app.sock`, AF_UNIX stream. A stale file is unlinked first; umask 0177 then chmod 0600 (:91-104).
- Request: one line of JSON `{"call": name, "args": {...}}`, at most 64 KiB, 5 s server read timeout.
- Reply: one line `{"ok": result}`, or `{"error": msg, "refused": true}` (CallRefused or unknown call), or `{"error": msg, "refused": false}` (an exception).
- Client: default timeout 1.0 s; `CallFailed` covers no socket, timeout and no answer.
- `on_main(fn)` runs the call on the main thread through `AppHelper.callAfter`, with a 10 s timeout ("the menu bar app is busy") (menubar.py:719-737).

| call | args | reply | refusals / notes | callers |
|---|---|---|---|---|
| ping | – | `{pid}` | – | webapp (drain test), any |
| answer | `{choice, meeting}` | bool | runs on main, then refresh | remote.py:132 (timeout 12 s) |
| switched_off | `{app: teams\|slack}` | null | "no record switch for …" | remote.py:190 ← api.switches_turned_off (api.py:2751) |
| watch | `{folder, pid}` | null | pid must descend from the app ("… is not a process Palaver started") | remote.py:145 |
| start_helper | `{kind, key, args[]}` | `{pid}` | ValueError → refused; "this app starts no helpers" | remote.py:154 ← webapp/__init__.py:32-46 |
| transcribe | `{folder}` | bool | "no recording at …" | remote.py:162 |
| record | `{action: start\|stop, meeting?}` | `{meeting}` or `{stopped}` | "This recording is no longer running." / "Palaver is recording already." / "The recording did not start; the log says why." / "no recording action …" | remote.py:176 |
| test | `{action: start\|stop\|(status), mode}` | TestRecording status | ValueError → refused | remote.RemoteTest |
| restart_web | – | `{pid}` (None if not up within 20 s) | – | `palaver app restart-web` (cli.py:120-140, timeout 100 s) |
| calendar | `{action?: connect}` | onboarding.Calendar status/connect | – | remote.RemoteCalendar |
| update_check / update_install | – | Updater.status() | – | api.update_action (api.py:3060-3073) |
| uninstall | `{models, recordings}` | `{removing:[paths]}`, then the app quits | – | api.uninstall_palaver (api.py:3076-3089) |

`PidProcess` (:241-271) wraps a non-child pid for the watchdog; `descendant()` walks `proc_listchildpids` (:220-238).

## 6. Menu bar UI (menubar.py)

- Icon: `assets/menubar.png`, template image.
- Title text next to the icon (`menu_title`, :39-60):
  - "⚠️" when a daemon tick failed.
  - "🔴 m:ss" while recording; "🔴⚠" when a track is missing or there are warnings (not for hints).
  - "⏳ n/7" while processing.
  - "⏸" when paused.
  - "↑" when an update is available or failed.
  - otherwise empty.
- Click (:395-419, :549-570): left click opens the window; right click or ctrl-click shows the menu once (the menu is detached from the status item, so the button target is a `Clicker`).
- Items:
  1. Status line, starting as "Starting…" (`status_line`, :95-116): `why_text`, or "Recording for N min (manual) → folder", "<step label> (n/7, k more queued)", "Downloading the search model (470 MB)" / "Indexing meetings for search", "Not recording calls automatically", or "Waiting for a Teams call or Slack huddle".
  2. Up to 8 live lines in a monospaced font (`recording_lines`, :119-152):
     - `Mic ▁▂▃ -20 dB (silent N s)` and `System …`
     - "⚠ Not recording: … — see `palaver doctor`"
     - at most 2 warnings, then "+N more — open Palaver for all"
     - "System audio via Process Tap|ScreenCaptureKit (24 kHz) · Call active|Call ended — stopping soon|manual recording"
     - hints
     - "Coach: <nudge>" or the talk line, if there is room
  3. Start/stop item (`manual_title`, :73-92): "Start recording now" / "Stop recording" / "Silent for N min — Stop recording" / "Call ended — Stop recording". The click does what the title said (`manual_action`).
  4. "Keep recording": visible only while a stop question is open.
  5. Separator; "Open Meetings" ⌘M; "Settings…" ⌘, (opens `#/settings`); "Report a Problem…" (opens `#/report`, usage `action:menubar.reportProblem`).
  6. Separator; update item (`updater.menu_title`, updater.py:243-265): "Check for Updates… (Palaver x.y)" / "Checking…" / "Update available (v)" / "Downloading update v… N %" / "Update v installs when Palaver is idle (reason)" / "Installing update v…" / "Update v failed — try again". Hidden from a checkout. A click installs, or checks and then notifies the result.
  7. "Quit Palaver" ⌘Q.
- Progress steps from session.log events (:156-185): aec_start=1, transcribe_start system=2 / mic=3, diarize_start=4, diarize_done/merge_done=5, notes_start=6, process_done/notion_upload_start=7.
- Updates class (:274-375):
  - Checks at start, hourly, when the window opens (if older than 10 min), and 1 h after a failed check.
  - `update.json` lives in support.
  - An announcement notification goes out once per version; a click opens `settings/update`.
  - The swap happens on a main tick when not busy (busy also covers model jobs, a test recording, and the `downloading-models` marker with a live pid).
  - Prunes runtimes; migrates MCP entries (`mcp_access.migrate(stable_python())`).
  - `uninstall` → `uninstall.start` script → quit.
- Permissions (:422-456), in a thread at launch:
  - Mic `authorizationStatus == 0` → `requestAccess`.
  - System audio: if `<support>/permissions-requested` is missing, a dummy ProcessTap start/stop triggers the prompt, then the marker is written.
  - Screen Recording is never requested.
- Doctor and diagnostics: only text pointers to `palaver doctor`. Report a Problem is the window's form; the report reads daemon.json and the logs.

## 7. Window hosting (webapp/window.py, webapp/process.py)

- `open_window(url, key)` (:312-334):
  - ActivationPolicy Regular plus the Dock icon (Palaver.icns).
  - NSWindow 1280×860, min 720×480, titled/closable/miniaturizable/resizable, autosave name "Meetings", not released on close.
  - Closing returns to Accessory (:109-111).
  - Loads only when needed (`needs_load`, :288-297: the bare address keeps the page; a `#meeting` fragment differs).
  - URL = `with_key(url, key)` → `http://127.0.0.1:PORT/?key=…#/route`. The server sets the HttpOnly SameSite=Strict cookie `key_cookie(port)` and drops the key from the address (server.py:46-57, 179-192).
- WKWebView:
  - `userContentController.addScriptMessageHandler(delegate, "palaver")`.
  - Back/forward gestures on.
  - UI delegate handles `confirm()` / `alert()` as sheets (not modal, so the timer keeps ticking) and `<input type=file>` with an NSOpenPanel sheet (:113-134).
- JS bridge:
  - Page → native: `{type:"commands", enabled:[names]}` after every render. It enables or disables the menu items whose representedObject is a command (:136-151).
  - Native → page: `window.palaver && palaver.command("<name>")` and `palaver.undo()`. A ⌘-key the page already saw is not run again (`page_saw_this_key`, :177-191).
- Menus (`_main_menu`, :196-252):
  - Palaver: Hide ⌘H, Close Window ⌘W, Quit Palaver ⌘Q → `_quit`.
  - Edit: Undo ⌘Z → page undo; Redo ⇧⌘Z, Cut, Copy, Paste, Select All.
  - MEETING_MENU (:27-47): Start Recording ⇧⌘R, Stop Recording, Play/Pause, Write Notes ⇧⌘N, Transcribe Again, Rename…, Change Event…, Join with Previous ⌘J, Join with Next, Split At…, Review Again, Report a Problem with This Meeting…, Export…, Import…, Delete Audio…, Move to Trash ⌘⌫.
  - VIEW_MENU: Back ⌘[, Forward ⌘], Search or Command… ⌘K, Reload ⌘R (sent to the web view).
  - Help: Report a Problem… (and macOS's search field).
  - Command menus have autoenable off.
- Server process (process.py):
  - The port is the first free one of 47815-47824, else any free port (:49, :66-76).
  - Key `secrets.token_urlsafe(32)` per app start, passed in `PALAVER_WEB_KEY`.
  - Ready handshake: the child writes `ready\n` on the ready fd within 20 s, else it is killed.
  - Crash backoff 1, 2, 5, 15, 30 s, reset after 60 s of stable running.
  - stop: SIGTERM, wait 65 s, then SIGKILL.
  - The child exits when stdin closes.
  - `restart()` returns the new pid. `on_ready(restarted=True)` → `reload_in_place(base)`, which reloads only if the window shows that server (:337-355).
- Notification clicks → `open_window(web.url(meeting), key)` on main (menubar.py:748).

## 8. Other native integrations in the process

- **EventKit** (calendar_eventkit.py):
  - `has_access()` (status 3), `request_access` (`requestFullAccessToEvents`, with a macOS 13 fallback), `events_between`.
  - Menubar uses: `_check_calendar` on every refresh until connected. On connect (with `calendar_enabled`) a thread runs `calendar_events.attach_all` + `people.refresh_recognition`, writing per-meeting calendar.json and transcripts. A retry runs every 5 min over the last 36 h, skipped while transcribing (menubar.py:225-239, 592-600, 670-687).
  - Daemon uses: `_calendar_lookup` for continuation (±2 h) and `_event_now` for the coach context (daemon.py:1486-1530).
  - The setup button goes through `onboarding.Calendar` (asks once, else opens `x-apple.systempreferences:…Privacy_Calendars`).
  - Processing (`process` worker) also reads EventKit and inherits the app's consent (calendar_eventkit.py docstring).
- **Keychain**: `config.load_config` reads `NOTION_TOKEN` / `HF_TOKEN` from env, then config.toml, then keyring service `palaver` (fallback `meeting-transcribe`) (config.py:56-68). keychain.py (provider API keys) is used by the workers and the web server, not by the menubar code directly. Keychain ACLs are tied to the reading binary.
- **Live coach** (in-process): `LiveCoach` → `VoiceMonitor` thread every 0.25 s reading the `.part` files. It also reads `stream.json` and `live.json`. Context loads after 60 s from EventKit, `~/.config/palaver/voices/*.json`, `coach-baseline.json` and `shared-series.json`. Status feeds the daemon status (live_coach.py:246-332; daemon.py:1039-1046, 1516-1530). Nudge switches live in settings.json.
- **Login item**: the LaunchAgent (section 1), toggled from the web server (`onboarding.Probe.set_autostart`, `palaver app autostart`), not from the menubar.
- **MCP**: only `mcp_access.migrate` at start (menubar.py:260-271).
- **Storage**: `Cleanup.tick` every second; hourly it runs `drop_old_audio` when settings.json `audio_days` is set (storage.py:184-205). `drop_retired` deletes retired HF model caches at start.
- **Model-state checks the daemon calls in Python**: `process_state.missing_models` (HF cache inspection through onboarding), `semantic.stale`, `semantic.embeddings.model_folder`, `llm.notes_memory_gb`/`choice_for` (settings.json providers and per-meeting local-only). A Swift daemon must port these or ask a Python helper.

## 9. Config and files

**config.toml** (`$XDG_CONFIG_HOME|~/.config/palaver/config.toml`; never written by the app). Keys this process reads:
- `[recording]`: output_dir (default ~/Meetings/Recordings), max_session_hours (4), grace_period_seconds (10), slack (true), retention_days
- `[processing].live`
- `[notion]`: token, auto_sync, mode, parent_page_id, database_id (auto_sync selects run vs process+notes)
- `[notes]`: enabled, engine, local_model
- `[calendar].enabled`
- `[memory]`: live_gb, stream_gb, process_gb, notes_gb, index_gb
- `[user].name`
- `[hf].token`
- CLI `--config`, `--dictionary`, `--no-notify` are forwarded to children.

**settings.json** (`~/.config/palaver/settings.json`; mtime-cached, atomic writes under a `.lock` flock). Keys read here:
- record_teams, record_slack, live_processing, realtime, search_meaning, check_updates
- nudge_talk_share, nudge_monologue, nudge_quiet_invitee, nudge_pace, nudge_fillers
- user_name, audio_days, local_model, provider choices (providers.py)

**Application Support `~/Library/Application Support/palaver/`**:

| file | written by this process | read |
|---|---|---|
| daemon.json | every tick | webapp, process, doctor, report |
| app.sock | 0600 | |
| update.json | via write_status | web |
| started-ok | yes | swap.sh |
| permissions-requested | yes | |
| downloading-models | – | read (web server writes it) |
| previous-app/, updates/ (swap.sh, staged app), runtime/<id>, runtime/.previous | updater | |
| models/ | updater installs model archives | |
| usage.jsonl | append | |

**Logs `~/Library/Logs/palaver/`**: app.log (launcher stdout/err), daemon.log (JSON lines plus children's plain stdout), crashes.log.

**Per meeting folder** (written during recording): `mic_raw.wav(.part)`, `system.wav(.part)`, `audio_problems.json`, `meta.json`, `session.log`, `parts.json` (head), `failed.json`, `live.pid` (written by the live worker; read and signalled here), `.jobs/` under output_dir.

**Temp**: `$TMPDIR/palaver-<launcherpid>.sock` / `.notifications`, `palaver-test-*` dirs, `palaver-uninstall.sh`.

**Env passed to children**: PALAVER_APP, PALAVER_NOTIFY, PALAVER_NOTIFY_STATE, PALAVER_WEB_KEY (web only), PALAVER_LAUNCHER_FD (stripped for web), PALAVER_MANIFEST_URL (updater override), HF_HUB_OFFLINE (test transcription).

## 10. Tests that pin this (counts of `def test_`)

- **tests/test_daemon.py** (116): detector (Teams/Slack, muted huddle, last-taker, switches, ignore until let go), Trigger timing/grace/max, queue persistence, auto_sync vs local commands, cli forwarding, taskpolicy QoS, live wait and stuck-live stop, missing-track notice, app switch splits, stream/live switches, test-recording gate, notes gating (call, memory, model need, restart persistence), vm_stat parsing, stop question and silent call (ask, keep, stop, phone huddle), double-click guard, index scheduling, continuation across restarts (cut, 5 min window, other app or event, manual), crash recovery, why/status texts, retry/backoff, failed.json marking, left-behind marking, models wait, reaping, audio-problem notification once, silent-mic hint, switch off, shutdown stops the index, single-instance and `palaver_alive` command-line rule.
- **test_daemon_memory.py** (19): watchdog actions, SIGTERM→SIGKILL, process groups, requeue/drop, status, the question helper budget. **test_memory.py** (31): Watchdog and budgets unit tests.
- **test_daemon_coach.py** (9), **test_live_coach.py** (25): coach lifecycle and nudges.
- **test_appctl.py** (25): every call, 0600 socket, stale socket, refusal and error shapes, timeouts, main-thread execution, descendant check, PidProcess, timeout ordering (12 s web > 10 s main).
- **test_webapp_remote.py** (25): daemon.json reading and staleness, every remote call with the app present and absent, HTTP-level live bits, helper fallback.
- **test_menubar.py** (27): title/status/recording_lines/manual_title texts, menu layout, progress steps, permissions_to_request, click routing, show_menu_once, paused-from-switches, finalize non-blocking, Updates check/quit/busy/started-ok, app_pids.
- **test_capture_recorder.py** (39): PCM decode, alignment and Phase A/B, resampling and rate change, jitter/gap/overlap, part writer/abort, source fallbacks, missing-track behaviour, stall warnings, SCStream retries, long drift, problem file sync. **test_process_tap.py** (13), **test_av_mic.py** (6), **test_audio_health.py** (14), **test_device_matrix.py** (12: AirPods rate misread, lost cycles, permission loss, rebuild failure, muted mic). **test_integration_capture.py** (1, real hardware), **test_soak.py** (2).
- **test_meter.py** (8), **test_recorder.py** (1), **test_session.py** (5), **test_session_log.py** (8), **test_continuation.py** (17), **test_live.py** (14; worker_running, recording_finished, GrowingTrack).
- **test_web_process.py** (22): port choice, key, backoff, restart/reload, stop/kill, env stripping, parent-death exit, ready timeout, drain. **test_window.py** (10; menus, key-repeat guard, real page), **test_window_url.py** (5).
- **test_notify.py** (14): launcher socket, osascript fallback, clicks, permission file. **test_app_bundle.py** (12): Info.plist, LaunchAgent, launcher spawn/exit/signals, release host, autostart, marker path.
- **test_updater.py** (33), **test_update_api.py** (5), **test_uninstall.py** (9), **test_install_layout.py** (1).
- **test_onboarding.py** (54; TestRecording vs meeting start, Calendar), **test_storage.py** (10; hourly cleanup, drop_retired), **test_calendar_events.py** (16), **test_settings.py** (7), **test_config.py** (18), **test_keychain.py** (5), **test_runlog.py** (5), **test_lifecycle.py** (8).
- **e2e** (tests/e2e, Playwright/WebKit): test_app_window.py (window menus, dialogs, menu bar and notification open, restarted server reload, key sign-in), test_record.py (start/stop from Today, the list, the palette). These use an in-process `FakeRecording` (tests/e2e/conftest.py:151), so they pin the web side of the recording contract, not app.sock.

For a Swift equivalent:
- Port the pure-logic tests as XCTest. That covers Trigger, StopQuestion, SilentCall, queue and continuation, the wording, the alignment writer, AudioHealth and the menu texts.
- Keep the Python test_webapp_remote and appctl client tests running against the Swift socket as cross-language contract tests.
- Keep daemon.json and session.log event-shape fixtures for doctor, report and webapp.
