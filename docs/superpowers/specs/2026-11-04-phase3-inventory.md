# Phase 3 inventory: what `palaver webapp-serve` does today

Repo at commit b120d78 (master, 0.5.0rc1). All paths are relative to
the palaver-server worktree. Line numbers are `file:line`.
"Owner" uses the phase lists of `2026-11-03-swift-migration-design.md`
(Strategy → Phases): **3** = meetings, people, projects, glossary, search,
voices, speaker inference, the HTTP API; **4** = notes, coach, project
suggestions by a model, mlx/cloud providers, Notion, MCP, search
embeddings; **3\*** = only the window's server uses it, but neither list
names it (my reading: it moves with the server); **U** = unassigned (see
§9).

## 0. Modules and line counts

### The server itself

| module | lines | role | owner |
|---|---|---|---|
| palaver/webapp/server.py | 892 | HTTP handler: routing, auth, body limits, audio ranges, static files, notes/projects job orchestration | 3 |
| palaver/webapp/api.py | 3537 | every answer as plain data; undo wrapper; in-memory caches; search warming | 3 (with 4 parts, below) |
| palaver/webapp/process.py | 408 | `serve()` (the server process: fds, signals, drain) and the Python `WebSupervisor` (now unused: Swift has it) | 3 (serve), legacy (supervisor) |
| palaver/webapp/remote.py | 260 | daemon.json reader + app.sock client (`RemoteRecording`, `RemoteCalendar`, `RemoteTest`) | 3 |
| palaver/webapp/\_\_init\_\_.py | 117 | `build_app`: wires cfg, calendar, helpers (`notes`, `projects`, `next-question`) | 3 (wiring), 4 (helpers) |
| palaver/webapp/window.py | 355 | PyObjC WKWebView window (legacy `palaver menubar` only) | U (legacy) |
| palaver/webapp/static/ | 11 824 (js/html/css) + fonts | the frontend; stays as is | — |
| palaver/cli.py:193-204, :1616-1623 | — | `webapp-serve` argparse and `_cmd_webapp_serve` | 3 |

### Domain modules the server calls (import closure of api.py/server.py, excluding cli/daemon)

| module | lines | what the server uses it for | owner |
|---|---|---|---|
| paths.py | 231 | `RecordingPaths` (all meeting file names), folder-name regex | 3 |
| models.py | 128 | `Word`, `Segment`, `SpeakerTurn`, `Utterance` (JSON shapes) | 3 |
| readable.py | 133 | clean verbatim (fillers, stutters) + glossary marks for display | 3 |
| render.py | 56 | `transcript.md` rendering (rewritten after every name/glossary change) | 3 |
| titles.py | 89 | title resolution (title.json > imported > event > notes > "Meeting at …") | 3 |
| lifecycle.py | 179 | texts for "recorded", gaps, audio problems | 3 |
| process_state.py | 67 | `failed.json`, `missing_models` | 3 (reads onboarding model checks) |
| speakers.py | 412 | names/merges/ignored/unknown/rejected per meeting, `save_speaker_names` (rewrites transcript.json + .md, teaches the voice bank), live names | 3 |
| voices.py | 232 | voice bank (`~/.config/palaver/voices/*.json`), cosine recognition | 3 |
| people.py | 253 | `refresh_recognition` over all meetings, directory, unnamed-voice clustering (scipy), rename/name voices | 3 |
| inference.py | 313 | rule-based name inference (calendar, elimination, voice, intersection) | 3 |
| attribution.py | 270 | `Link` (source/confidence/reason), `Evidence` (attributions.json), Needs-you questions | 3 |
| calendar_events.py | 378 | `Event`/`Attendee`, calendar.json, matching, invitees | 3 |
| calendar_eventkit.py | 101 | EventKit provider (PyObjC) used in-process by the server (`build_app.calendar`) | 3 (native in Swift) |
| organizations.py | 193 | email-domain organizations, organizations.json | 3 |
| shared_mic.py | 396 | "several people" marks, speakers_shared.json, shared-series.json | 3 |
| projects.py | 532 | `ProjectStore` (projects.json), rules (`Similarity`, `assign_by_rules`, `suggestions`) — and `suggest_with_model`/`describe_with_model` (run by the helper) | 3 (store, rules), 4 (model parts :372-532) |
| prep.py | 146 | upcoming meetings, prepared.json, context | 3 |
| glossary.py | 517 | glossary.json, apply/marks, suggestions (wordfreq, rapidfuzz, Kölner Phonetik) | 3 |
| search.py | 454 | query parser (filters, chips, dates) — rules, no model | 3 |
| semantic.py | 350 | `ready`, `Searcher` (loads e5 in the server process), index files | 4 |
| embeddings.py | 158 | multilingual-e5-small in numpy | 4 |
| undo.py | 319 | snapshots in `.trash/.undo/<token>/`, fingerprints, restore | 3\* |
| cutting.py | 603 | split/join/discard/trash/neighbours/suggest_cut | 3\* (also used by `process`) |
| exchange.py | 1200 | export/import zip (#58) | 3\* |
| my_notes.py | 535 | the user's own notes, images, Vision OCR, prepared notes | 3\* |
| storage.py | 246 | storage summary, delete audio, audio days, model deletion | 3\* (Cleanup itself is housekeeping, U) |
| settings.py | 156 | settings.json (flock'd, atomic) | 3\* |
| model_jobs.py | 241 | `<recordings>/.jobs/` records of language-model helpers, pending undos | 3\* (records) / 4 (what runs) |
| coach.py | 393 | coach numbers per meeting and baseline (rule-based, no model) | 4 per spec; phase-2 design says 3 (see §8) |
| notes.py | 681 | **read side**: `load`, `stale_reason`, `transcript_hash`, `with_names`, `backed_name_guesses`; generation is 4 | 3 (read helpers) / 4 |
| merger.py | 114 | `merge` of mic/system segments for the live view (`_live_meeting`) | 3 (also `process`) |
| live.py | 366 | only `worker_running` (live.pid) | U (worker) — helper needed by 3 |
| stream.py | 287 | only `worker_running` (stream.pid) | U (worker) — helper needed by 3 |
| onboarding.py | 1415 | setup assistant: `Probe`, `Downloads`, recommendations, seed terms, permission states | 3\*/U (see §9) |
| providers.py | 339 | Settings → language model/transcription choices (settings.json `engines`/`providers`), keys | 4 |
| llm.py | 258 | `choice_for`, local model list, `test`, local-only marker | 4 (`set_local_only` is a one-file marker: 3) |
| cloud_llm.py | 362 | provider HTTP calls (only via `llm.test`) | 4 |
| keychain.py | 88 | provider API keys (keyring) | 4 |
| transcription.py | 598 | `month()`, `test()` for the Transcription section | U (cloud ASR is part of `process`) |
| access_log.py | 67 | `~/.config/palaver/access-log.jsonl` (what left the Mac) | 4 (written by cloud calls), read by 3 |
| next_question.py | 156 | best-next-question prompt, memory check | 4 |
| mcp_access.py | 494 | MCP log, clients, `claude mcp add` | 4 |
| usage.py | 238 | usage.jsonl (`/api/usage`, settings counts) | 3\* |
| report.py | 772 | Report a Problem zip | U |
| updater.py | 569 | only `read_status` (update.json) | U |
| notify.py | 114 | `permission()` ($PALAVER_NOTIFY_STATE), `SETTINGS_URL` | 3\* |
| appctl.py | 301 | client `call()` | 3 |
| install_layout.py | 133 | paths in Application Support, `stable_python` (MCP install) | U |
| daemon.py | 1653 | only `STATE_PATH`, `LOG_PATH`, `TASKPOLICY`, `available_memory_gb` (vm_stat) | legacy |
| cli.py | 1715 | `_status` (folder status), `notes_lock_free`, `ModelBusy`, `EXIT_MODEL_BUSY` | U |

Not in the server process but sharing its stores: `palaver process/run` (cli.py, writes speakers_auto, transcript, projects via `assign_by_rules`, inference), `palaver mcp` (mcp_server.py imports `webapp.api`: `list_meetings`, `get_meeting`, `directory`, `list_projects`, `run_search`, `search_meaning`, `_display_names`), `palaver index` (semantic), `palaver coach` (live_coach worker), `palaver app query|housekeeping`.

## 1. Process model and the handshake

**Started by** the Swift app's `WebSupervisor` (native/Sources/PalaverDaemon/WebSupervisor.swift:216-236):
`<python> -m palaver [--config X --dictionary Y --no-notify] webapp-serve --listen-fd N --ready-fd M --app-socket ~/Library/Application Support/palaver/app.sock`.
- Listening socket: 127.0.0.1, first free of ports 47815–47824 (`WINDOW_PORTS`, process.py:49), else any. Held by the app, FD_CLOEXEC, passed by number. The same port for every server the app starts.
- Env: the app's minus `PALAVER_LAUNCHER_FD`, plus `PALAVER_WEB_KEY` (32 random bytes, base64url, new per app start), `PALAVER_NOTIFY`, `PALAVER_NOTIFY_STATE`, `PALAVER_APP`.
- stdin: a pipe from the app; its EOF means the app is gone.
- Supervisor timings (Swift mirrors process.py:41-47): ready within 20 s or killed; crash backoff 1/2/5/15/30 s, reset after 60 s up; stop = SIGTERM, SIGKILL after 65 s; `restart_web` (app.sock) restarts at once; the window reloads on every `ready` after the first.

**Server side** (`_cmd_webapp_serve` cli.py:193-204 → `process.serve` process.py:369-409):
1. stdout line-buffered; `session_log(~/Library/Logs/palaver/daemon.log)` (JSON lines; all `palaver.*` log records); `event("webapp_start")`.
2. `RemoteRecording(socket_path=app_socket)`; `build_app(cfg, cli_options, recording)` (webapp/\_\_init\_\_.py:22-117); `probe.test = RemoteTest`, `probe.calendar = RemoteCalendar`.
3. `socket.socket(fileno=listen_fd)` adopted into `ThreadingHTTPServer` (server.py:848-873; `daemon_threads = True`, `bind_and_activate=False`).
4. key = `$PALAVER_WEB_KEY` or a fresh one; `--port` without `--listen-fd` binds itself and prints `Open http://127.0.0.1:PORT/?key=…`.
5. SIGTERM → `server.shutdown()` from a thread (process.py:385-388). With `--listen-fd` and a non-tty stdin, a `parent-watch` thread reads fd 0 raw until EOF, then does the same (process.py:338-355, 389-390).
6. `api.start_warming` thread (§4), then **writes `ready\n` to ready-fd and closes it** (process.py:397-399), then starts `sweep` and `warm-up` threads.
7. `serve_forever()`; on exit `server_close()` (no new accepts; queued connections wait in the app's socket for the next server) and `Inflight.wait_idle(60 s)` for POSTs still running (process.py:403-408).

**Inflight** (process.py:91-135): every POST is counted (`do_POST` wraps `_post` in `change()`, server.py:315-317); a request that only waits for a model helper leaves the count (`detached()`, server.py:728, :790). A restart therefore waits for cuts/joins/imports, never for a 10-minute notes run.

**App object** (`server.App`, server.py:81-122) carries: `output_dir`, `downloads` (~/Downloads), `probe` (onboarding.Probe), `cli_options`, `cfg`, `recording` (RemoteRecording), `user_name` (mutable: setup profile changes it), `settings` defaults (`record_slack`, `live_processing` from config.toml), `calendar` (`events_between` if `cfg.calendar_enabled` and EventKit full access, else None), `write_notes`/`run_projects`/`ask_model` (None when `notes_enabled` is false), `notes_lock`, `notes_jobs`, `free_memory_gb` (vm_stat), `jobs` (= `<output_dir>/.jobs`), `inflight`.

**Tests/dev**: `make_server(app, port=0, key=None)` in-process (tests/e2e/conftest.py:256-271, tests/test_webapp.py). `start_in_background`/`open_in_browser` (server.py:881-892) are used only by tests/test_search_api.py.

## 2. HTTP transport, auth and errors

| concern | behaviour | where |
|---|---|---|
| Protocol | `BaseHTTPRequestHandler` defaults: HTTP/1.0 responses, connection closed after each; `Server: palaver Python/3.x` | server.py:139-140 |
| Host check | every GET/POST: `Host` must be `127.0.0.1:<port>` or `localhost:<port>`, else 403 `{"error":"wrong host"}` (DNS-rebinding guard) | :136, :171-172, :198, :320 |
| Sign-in | GET with `?key=` → constant-time compare; wrong → 403 `wrong key`; right → 302 to the same path without `key` (other query params kept), `Set-Cookie: palaver_key_<port>=<key>; Path=/; HttpOnly; SameSite=Strict`, `Cache-Control: no-store`. Done before any other routing, also for `/api/...` | :46-57, :184-195, :201-203 |
| Key check | every other GET/POST: cookie `palaver_key_<port>` must equal the key (hmac.compare_digest); else 403 `open Palaver from its menu bar icon`. `key=None` (tests) → open | :174-182 |
| Origin/CSRF | no CORS headers, no OPTIONS handler (501): a foreign page cannot send `application/json` or `application/octet-stream` without a preflight | :1-11 |
| POST body | `Content-Type` must be `application/json` (params ignored) else 415 `JSON only`; `Content-Length` > 2 MiB (35 MiB for `/api/{meetings,upcoming}/<id>/my-notes/images`) → 413 `too large`, connection closed, body unread; empty body = `{}` | :64-78, :326-333 |
| JSON out | `json.dumps(ensure_ascii=False)` UTF-8, `Content-Type: application/json`, `Content-Length`, `Cache-Control: no-store` | :154-166 |
| GET errors | `api.NotFound` → 404 `not found: <what>`; `ConnectionError` → no answer; anything else → 500 `{"error": str(exc)}` + log | :305-311 |
| POST errors | `undo.Gone` → 404 `can't undo this any more`; `undo.Changed` → 409 `the meeting changed since`; `NotFound` → 404; `api.Refused` → 400 (message shown in the page); `KeyError`/`ValueError` → 400 `bad request: …`; other → 500 | :537-551 |
| Unknown paths | GET of a suffix-less unknown path (also `/api/whatever`) serves **index.html with 200** (`_static`); unknown POST → 404 `not found` (falls to `_projects_post`) | :838-843, :682-702 |
| Methods | GET, HEAD (= GET, bodies suppressed), POST. Nothing else | :313 |
| Logging | POSTs (except `/api/usage`) at INFO, ≥400 at WARNING, GET polling not logged | :145-152 |
| Static | `/` or any path without a suffix → `static/index.html`; else the file under `static/` (resolved, must stay inside); types: html, js, css, svg, woff2, else octet-stream; read whole per request | :37-40, :838-843 |

## 3. Every route

Request bodies are JSON unless noted. "→ meeting" means the answer is `get_meeting(...)` (§3.2 shape). "+undo" means the key `undo` (32-hex token) is added. Calls are `api.*` unless prefixed.

### 3.1 Infrastructure and app pass-through

| M | path | request | response | calls | side effects | errors |
|---|---|---|---|---|---|---|
| GET | /api/ping | — | `{"ok":true}` | — | — | — |
| GET | /api/recording/question | — | `{"question": daemon.json stop_question \| null, "recording": {"meeting","text","warnings","hints"} \| null}` | `recording_question` :72; remote.py:100-106, :45-51 | reads daemon.json | — |
| GET | /api/recording/coach | — | `{"coach": {"meeting","talk","text","nudge","quiet"} \| null}` | `live_coach` :90; remote.py:54-58 | daemon.json | — |
| GET | /api/memory | — | `{"memory": daemon.json memory \| null}` | `memory_status` :83 | daemon.json | — |
| GET | /api/search/status | — | `{"indexing":bool,"downloading":bool}` (unused by the page) | `search_status` :97 | daemon.json `indexing`, `index_downloading` | — |
| POST | /api/recording/start, /api/recording/end | `{"meeting"?}` | app.sock answer: `{"meeting"}` or `{"stopped"}` | `record` :118 → app.sock `record {action: start\|stop, meeting}` | the app records | 400 Refused (no app / refused, text `NO_ANSWER`) |
| POST | /api/recording/stop, /api/recording/keep | `{"meeting"}` | `{"stopped":id}` / `{"kept":id}` | `answer_recording_question` :108 → app.sock `answer` | — | 400 "This recording is no longer running…" |
| POST | /api/meetings/{id}/transcribe | `{}` | → meeting | `transcribe_again` :172 → `process_state.missing_models`, app.sock `transcribe {folder}` | the app queues it | 400 if not failed/waiting, models missing, or no app |
| GET | /api/update | — | update.json content (or `{"state":"unsupported"}`) + `check_updates` | `update_status` :3053 | reads `~/Library/Application Support/palaver/update.json`, settings.json | — |
| POST | /api/update/check, /api/update/install | `{}` | app.sock answer | `update_action` :3061 → `update_check`/`update_install` | — | 400 `APP_GONE` |
| POST | /api/uninstall | `{"confirm":true,"models":bool,"recordings":bool}` | app.sock answer | `uninstall_palaver` :3076 → `uninstall` (timeout 12 s) | the app quits and removes itself | 400 without confirm |
| GET | /api/notifications | — | `{"state":"granted\|denied\|not_asked\|unknown","detail"}` | `notifications_status` → onboarding.notifications_permission → notify.permission (file in `$PALAVER_NOTIFY_STATE`) | — | — |
| POST | /api/notifications/open | `{}` | same as GET | `open_notification_settings` :2023 | `subprocess.run(["open", notify.SETTINGS_URL])` | — |
| GET | /api/model-jobs | — | `{"running":[{kind,key,started}], "finished":[{token,label,ok}]}` | `model_jobs_view` :1518, `_finish_orphaned` :1528 | may seal or restore an orphaned projects undo; deletes job record | — |
| POST | /api/model-jobs/seen | `{"token"}` | same as GET | model_jobs.seen | deletes `.jobs/undo/<token>.json` | 400 bad token |
| POST | /api/usage | `{"events":[{kind,id,text?,from?}], "catalog"?}` | `{"ok":true}` | `record_usage` :3514 | appends usage.jsonl (≤200 events; kinds action/view/tab/palette/error), writes usage-features.json | 400 events not a list |
| POST | /api/report | report.Form dict | `{path,size,...,"size_text","shown"}` | `create_report` :3499 → report.create | zip on the Desktop; `open -R` | 400 bad form, 500 |

### 3.2 Meetings: list, page, live, audio

| M | path | request | response | calls | side effects | errors |
|---|---|---|---|---|---|---|
| GET | /api/meetings | — | list, newest first, of `{id,start,duration,status,title,title_from,summary,people,unnamed,nameless,invited,has_notes,imported,notes_stale,projects:[{id,name,by,why,confidence?,link}]}` | `list_meetings` :269, `_list_entry` :219 | `_status` may delete stale live.pid (live.py:75-102, runs `ps`) | — |
| GET | /api/meetings/{id} | — | finished: `{id,title,title_from,calendar:{title,attendees[{name,organizer,response,org,org_link}],invited,link},event_question,start,duration,status,untranscribed,notes,notes_stale,notes_stale_reason,notes_from_my_notes,my_notes_revision,speakers[…],transcript[{speaker,label,start,end,text,glossed,edited,heard,unsure}],has_audio,audio_deleted,reviewed,local_only,imported,transcribed_by,failure,neighbours{previous,next},cut_suggestion,shared,shared_suggestion,removed,recorded,gaps,audio_problems,projects,project_suggestions,all_projects}`; recording with live.json: `_live_meeting` shape (`live:{until}`, provisional speakers, `has_audio:false`) | `get_meeting` :680 → `_meeting` :719 / `_live_meeting` :438, `_with_orgs` :689 | none (but `_neighbours` calls `list_meetings`; `_cut_suggestion` calls the calendar synchronously) | 404 not a recording folder name or no folder |
| GET | /api/meetings/{id}/audio?track=mix\|system | `Range: bytes=a-b` | 206 `audio/wav` slice ≤ 2 MiB of a synthetic 44-byte-header mono 16-bit WAV; mix = mic.wav (or mic_raw.wav) + system.wav summed and clipped, length = longest; no Range → first slice; `bytes=-N` suffix; start ≥ size → 416 `Content-Range: bytes */size` | `_audio` server.py:812-836, `AudioSource` api.py:2065-2103 | none | 404 unknown track or no audio |
| GET | /api/meetings/{id}/stream?since=S | — | `{"stream":false[, "starting":true \| "stale":true]}` or `{"stream":true,until,lines[{speaker,label,start,end,text,glossed}],draft{system,mic},speaking,questions}` | `live_stream` :497 | reads stream.json; `stream.worker_running` (stream.pid + kill 0) | 404 |
| GET | /api/meetings/{id}/events | — | `[{key,title,start,end,invited,current,rejected,rule:{series,text}\|null}]` | `meeting_events` :609, `_candidate_events` :590 | calendar ±45 min | 404 |
| POST | /api/meetings/{id}/event | `{"key": "current" \| event key \| "question\|i" \| "stored\|i" \| null}` | → meeting +undo | `set_meeting_event` :650 | calendar.json (assign or `{"none":true,...}`), prep.apply, shared_mic.apply_series, attributions.json, speakers files/transcripts of all meetings (refresh), projects.json; undo covers meeting files (no audio), projects, prepared, attributions, prepared-notes folder | 404 key |
| POST | /api/rules/forget | `{"series"}` | `{"undo"}` | `forget_rule` :623 | attributions.json | — |
| POST | /api/meetings/{id}/title | `{"title": str}` | → meeting +undo | `set_title` :1008, titles.save | title.json `{"title"}` (or removed for ""); undo label `title` | 400 not text |
| POST | /api/meetings/{id}/line | `{"start": float, "text": str \| null}` | → meeting | `edit_line` :1033 | transcript.json line gets `heard` + new `text` (null reverts), atomic; transcript.md re-rendered | 400 not ready / empty; 404 no line within 0.01 s |
| POST | /api/meetings/{id}/trash | `{}` | `{"trashed":id,"undo"}` | `trash_meeting` :1057, cutting.trash | moves folder to `<recordings>/.trash/<id>[-n]`; projects.json forget; refresh recognition | 400 recording/processing |
| POST | /api/meetings/{id}/delete-audio | `{}` | → meeting + `freed` (bytes) | `delete_audio` :2010 → storage.drop_audio | deletes mic_raw/mic/system wav + `.live-diarize.wav`, writes `audio_deleted.json {at,bytes}` | 400 not transcribed |
| POST | /api/meetings/{id}/local-only | `{"on":bool}` | → meeting | `set_local_only` :2915 → llm.set_local_only | local_only.json `{"since"}` or removed | 404 |
| POST | /api/meetings/{id}/split | `{"at":s,"join_next"?:bool,"discard"?:"after"\|"before"}` | `{"id","rest","joined","discarded"?,"undo"}` | `split_meeting` :1159; cutting.split/join/discard | rewrites WAVs (int16), segments, turns, transcript, per-label files, meta, my-notes; new folder; undo with **audio**; projects, calendar attach for the new part | 400 not ready / out of range / no next |
| POST | /api/meetings/{id}/join | `{"with": other id}` | `{"id","undo"}` | `join_meetings` :1192; cutting.keeper/join | merges into the keeper, the other to `.trash`; `.join-backup` crash safety (cutting.py:284-346) | 400 not ready |
| POST | /api/meetings/{id}/cut-suggestion | `{"dismiss":bool}` | → meeting | `dismiss_cut` :580 | cut_dismissed.json `{"dismissed"}` / removed | — |
| POST | /api/meetings/{id}/reviewed | `{"done":bool}` | review queue (as GET /api/review) | `mark_reviewed` :2525 | review.json `{"reviewed","seen":[need ids]}` / removed | 400 processing |
| GET | /api/review | — | ready, unreviewed meetings (list entries) + `open:{unnamed,projects:"none\|unsure\|ok",glossary:[≤3 suggestions with titles],notes:"missing\|stale\|ok"}` | `review_queue` :2279 | — | — |
| GET | /api/needs | — | `{"count", "meetings":[{id,title,start,items[{kind,id,…}]}]}`, kinds in order which_event, event, no_event, cut, unnamed, speaker, project, review | `needs` :2495, `_meeting_needs` :2475, `_need_items` :2388 | may start background cut lookups (§4) | — |
| GET | /api/questions | — | attribution.questions per ready meeting (unused by the page) | `open_questions` :2318 | — | — |
| POST | /api/undo | `{"token"}` | `{"restored":[meeting ids]}` | `undo_change` :959 (special cases: my-notes, shared, title/unknown, import) | restore snapshot; re-derive names/projects; re-render transcript.md of all meetings if the glossary came back | 404 Gone, 409 Changed |

### 3.3 Speakers, voices, people, organizations

| M | path | request | response | calls | side effects | errors |
|---|---|---|---|---|---|---|
| POST | /api/meetings/{id}/speakers | `{"label","name"}` | → meeting (+undo when rejecting/confirming/"after all") | `name_speaker` :862 | live: speakers_live.json; else speakers.json, speakers_rejected.json, speakers_unknown.json, voice bank, then `people.refresh_recognition` over **all** meetings (speakers_auto, speakers_inferred, transcript.json + .md rewrites) | 404 label |
| POST | /api/meetings/{id}/remove | `{"label","removed":bool}` | → meeting | `remove_speaker` :1211 | speakers_ignored.json; transcripts; refresh | 404 |
| POST | /api/meetings/{id}/unknown | `{"label","on":bool}` | → meeting +undo | `set_unknown` :1222 | speakers_unknown.json | 400 not ready / `on` not bool; 404 |
| POST | /api/meetings/{id}/merge | `{"label","into": label \| null}` | → meeting (+undo for a merge) | `merge_speaker` :1240, speakers.merge_speakers | speakers_merged.json, names moved, rejected copied, shared follow, transcripts; voice bank in snapshot | 404; 400 into itself |
| POST | /api/meetings/{id}/shared | `{"on":bool,"label"?: label\|"mic","name"?: str,"series"?: bool}` | → meeting +undo | `set_shared` :1262 | speakers_shared.json, shared-series.json; derive transcript (+ refresh when voices changed) | 400 types / not ready / not recurring |
| POST | /api/meetings/{id}/shared-series | `{"remember":bool}` | → meeting +undo | `remember_series` :1329 | shared-series.json | 400 |
| POST | /api/meetings/{id}/shared-suggestion | `{"dismiss":bool}` | → meeting | `dismiss_shared_suggestion` :1342 | speakers_shared.json `dismissed` | — |
| POST | /api/meetings/{id}/imported-voices | `{"add":bool}` | → meeting +undo | `decide_imported_voices` :1149 → exchange.decide_voices | imported_voices.json → speaker_embeddings / voice bank; organizations | 400 |
| GET | /api/names | — | sorted names (user, voice bank, every meeting's names) | `known_names` :1612 | — | — |
| GET | /api/people | — | `{"people":[{name,meetings[{id,label,talk_seconds,named_by,title,start,projects,clip}],talk_seconds,voice_samples,you,org,org_given}], "unknown":[{voices[…],talk_seconds}], "organizations":[{key,name,default,people}]}` | `directory` :1356, people.directory, organizations.summary | — (clusters all unnamed voices with scipy every call) | — |
| POST | /api/people/rename | `{"old","new"}` | people +undo | `rename_person` :1397 → people.rename_person | voice bank rename/merge, speakers.json + rejected in all meetings, refresh | 400 empty |
| POST | /api/people/org | `{"name","org": str\|null}` | people | `set_person_org` :1388 | organizations.json `people` | 400 |
| POST | /api/organizations | `{"key","name"}` | people | `rename_organization` :1382 | organizations.json `names` | — |
| POST | /api/voices/name | `{"voices":[[meeting,label],…],"name"}` | people +undo | `name_voices` :1414 → people.name_voices | speakers.json per meeting, voice bank, refresh | 404 label; 400 |

Undo for name changes takes `speaker_files_of_all=True` (every meeting's `speakers*.json`) plus the voices folder and organizations.json (api.py:1405-1411).

### 3.4 Projects, prep, model jobs

| M | path | request | response | calls | side effects | errors |
|---|---|---|---|---|---|---|
| GET | /api/projects | — | `{"projects":[{id,name,description,description_by,meetings[{id,title,start,duration,summary,people,by,why,confidence?}],people(≤8),latest}], "unsorted":[{id,title,start,duration,suggestions[{id,name,score,why}]}]}` | `list_projects` :1431, projects.all_facts/Similarity/suggestions | — | — |
| POST | /api/projects | `{"name","description"?}` | projects | `create_project` :1465 | projects.json | 400 empty |
| POST | /api/projects/{pid} | `{"name"?,"description"?}` | projects +undo | `update_project` :1473 | projects.json | 404; 400 duplicate name |
| POST | /api/projects/{pid}/merge | `{"into"}` | projects +undo | `merge_projects` :1563 | projects.json | 404 |
| POST | /api/projects/{pid}/delete | `{}` | projects +undo | `delete_project` :1575 | projects.json | 404 |
| POST | /api/projects/suggest | `{"label"?}` | projects +undo | `_model(["suggest"])` server.py:706-741 → `model_change` :1490 → `run_projects` → helper `palaver projects --no-wait suggest` | snapshot of projects.json, `.jobs/undo/<token>.json` pending → finished | 503 notes off; 409 busy (a projects job record running, `notes_lock` held, or `notes.lock` flock held, or `ModelBusy` exit 75); 502 failed (+last log line) |
| POST | /api/projects/{pid}/describe | `{"label"?}` | same | `_model(["describe", pid])` | same | same |
| POST | /api/meetings/{id}/projects | `{"project": pid \| null, "name"?: str, "remove"?: bool}` | → meeting +undo | `set_meeting_project` :1587 | projects.json (assign by "you", or reject) | 404 project; 400 no name |
| GET | /api/upcoming | — | `[{key,title,start,end,series,projects[{id,name}]}]` (next 36 h, someone invited) | `upcoming` :2552, prep.upcoming | calendar | — |
| GET | /api/upcoming/{key} | — | entry + `attendees`, `suggestions` (≤3), `context` (≤2 earlier meetings: id,title,start,why,summary,next_steps), `all_projects` | `upcoming_meeting` :2567 | — | 404 |
| POST | /api/upcoming/{key}/projects | `{"project"?,"name"?,"remove"?}` | upcoming meeting | `set_upcoming_project` :2585 | prepared.json; projects.json (new by name) | 404 |

### 3.5 Glossary

| M | path | request | response | calls | side effects | errors |
|---|---|---|---|---|---|---|
| GET | /api/glossary | — | `{"terms":[{id,term,variants,note}], "suggestions":[≤20 {kind:variant\|cluster\|term,key,term,variants,count,meetings,examples[{meeting,start,text,title}]}]}` | `glossary_page` :2137, `_suggestions` :2114 (cached by mtimes of glossary, projects and every transcript/calendar/speakers file) | — | — |
| POST | /api/glossary/accept | `{"term","variants":[],"note"?}` | `{"changed":{meetings,replacements,in_notes}, terms, suggestions}` | `accept_suggestion` :2197 → `change_glossary` :2177 | glossary.json; transcript.md of changed meetings | 400 |
| POST | /api/glossary/reject | `{"keys":[…]}` or `{"key"}` | `{changed:null, terms, suggestions, undo}` | `reject_suggestion` :2233 | glossary.json `rejected` | — |
| POST | /api/glossary/respell | `{"heard","term"}` | `{"changed","term":{id,term,variants,note},"undo"}` (no page) | `respell` :2205 | glossary.json, transcript.md | 400 |
| POST | /api/glossary/{tid} | `{"term"?,"note"?,"remove_variant"?,"add_variants"?:[],"delete"?:bool}` | `{changed, terms, suggestions, undo}` | `update_term` :2244 | glossary.json, transcript.md | 404 (NotFound); **LookupError from Glossary → 500** |

`change_glossary` counts respelled words per meeting with `difflib.SequenceMatcher(autojunk=False)` over the raw transcript texts (`clean_text`) and the JSON of notes (api.py:2168-2194).

### 3.6 Search

| M | path | request | response | calls | side effects | errors |
|---|---|---|---|---|---|---|
| GET | /api/search?q= | — | `{"query","understood":[chips],"words",results:[list entry + in_title,in_notes,notes_hits(≤3 {kind,text,owner?,heading?}),hits(≤5 {start,speaker,text}),hit_count], "meaning":"ready"\|"off"}`; ≤50 results | `search_page` :1941 → `run_search` :1919, search.parse, `_filtered` :1767, `_matched` :1806; `semantic.ready` | — | — |
| GET | /api/search/meaning?q= | — | list entries + `meaning:[{kind,text/speaker/start…,score}]`, ≤6, best first; `[]` when off | `search_meaning` :1968 → `semantic.Searcher.search` | loads the e5 model **in the server process** on first use; released after 300 s idle | — |

Ranking (api.py:1839-1840, :1927): sort by `(in_title, has decision/step hit, in_notes, len(line hits), people score)` descending, stable over the newest-first list. Words match at a word start, case-insensitive (`(?<!\w)` + escaped word, api.py:1622-1630).

### 3.7 The user's own notes (#44)

`_MY_NOTES` regex (server.py:62) covers `/api/meetings/{id}/my-notes…` and `/api/upcoming/{key}/my-notes…` (prep; key URL-decoded, must be an event still to come, cached in `_KNOWN_EVENTS`).

| M | path | request | response | calls | side effects | errors |
|---|---|---|---|---|---|---|
| GET | …/my-notes | — | `{"paragraphs":[{text,at,image?}],"images":{name:{text}},"revision"}` | `get_my_notes` :2966; for a meeting first `adopt_prepared_notes` :2943 | while recording: moves prepared notes from `~/.config/palaver/prepared-notes/<sha256(key)[:24]>/` into the meeting (calendar lookup) | 404 |
| POST | …/my-notes | `{"paragraphs":[…],"revision":str}` | `{"saved":n,"revision"}` | `save_my_notes` :2970 → my_notes.save (flock `.my-notes.lock`) | my-notes.json atomic | **409 `{"error","document"}`** on a stale revision (server.py:615-616); 400 |
| GET | …/my-notes/images/{name} | — | image bytes with its type (png/jpeg/gif/webp/heic) | `my_notes_image` :2998 | — | 404 bad name (`img-[0-9a-f]{12}.ext`) |
| POST | …/my-notes/images | `{"data": base64}` (≤35 MiB body, ≤25 MiB image) | `{"name"}` | `add_my_notes_image` :2981 | `my-notes/<name>`; background Vision OCR → `my-notes/<name>.txt` | 400 not base64 / not an image |
| POST | …/my-notes/images/{name}/delete | `{}` | document +undo | `delete_my_notes_image` :3006 | removes image + .txt + its paragraph | 404 |
| POST | …/my-notes/clear | `{}` | document +undo | `clear_my_notes` :3022 | empties notes and images | — |

### 3.8 Export and import (#58)

| M | path | request | response | calls | side effects | errors |
|---|---|---|---|---|---|---|
| POST | /api/meetings/{id}/export | `{"notes":bool=true,"voices":bool,"audio":bool,"confirm_local":bool}` | `{"saved":path,"name","folder","bytes"}` or `{"question":"local_only"}` | `export_meeting` :1094 → exchange.export_meeting | sweeps old leftovers; writes `~/Downloads/<name>.zip` (free name); audio as Ogg Opus (or FLAC) | 400 not ready |
| POST | /api/import?separate=1 | **raw zip, `Content-Type: application/octet-stream`**, 0 < length ≤ 1400 MiB | `{"imported":id,"from","voices","warnings","beside","undo"}` or `{"question":"collision","from","how","own","meeting":{id,title,start}}` | `_import` server.py:553-587 → `import_meeting` :1115 → exchange.read_package/find_match/stage/place/settle | body streamed to a temp dir; staged in `<recordings>/.importing/`, moved in by rename; imported.json, imported_voices.json, decoded+mixed system.wav (soxr), projects; undo label `import` (undo also removes bank samples of that meeting) | 415, 413, 400 "Not imported: …", 500 |

### 3.9 Notes, next question, coach (phase-4 material served by this server)

| M | path | request | response | calls | side effects | errors |
|---|---|---|---|---|---|---|
| POST | /api/meetings/{id}/notes | `{}` | → meeting (after the run) | `_notes` server.py:777-810 → `write_notes` → helper `palaver notes <folder> --force` via app.sock `start_helper` (fallback: `model_jobs.launch` from the server) then `model_jobs.wait` (0.2 s poll) | `.jobs/notes-<id>.json` + `.log`; notes.json by the helper. One run per meeting (followers share the leader's result), one model at a time (`notes_lock`); a job left by an earlier server is waited for, never restarted | 503 notes off; 502 failed |
| GET | /api/meetings/{id}/next-question | — | `{ready,reason,label,local,warning}` | `next_question_info` :2678 | — | 404 |
| POST | /api/meetings/{id}/next-question | `{"confirmed"?:true}` | `{"questions":[…],"engine",…}` | `_next_question` server.py:743-775: info, `next_question_problem` (vm_stat), `live_coach`, `next_question_inputs` :2634 (meeting + stream + prep.context + my notes), `build_prompt`, `ask_model` | spawns `[taskpolicy -c utility] python -m palaver --no-notify next-question <folder>` (stdin JSON, last stdout line JSON, 600 s timeout); app.sock `watch {folder,pid}` | 503 off; 400 not ready / no memory / nothing said; 409 warning needs confirm or busy; 502 model error |
| GET | /api/coach | — | `{"baseline","meetings":[{id,title,start,people,share,wpm,fillers,language,longest,questions,interruptions}],"trends"}` | `coach_overview` :2731 | — | — |
| GET | /api/meetings/{id}/coach | — | coach.result + `baseline` + `highlights` | `coach_meeting` :2720 | — | 404 no transcript |

### 3.10 Settings, storage, language model, transcription

| M | path | request | response | calls | side effects | errors |
|---|---|---|---|---|---|---|
| GET | /api/settings | — | `Settings` dataclass as dict (realtime, record_teams, record_slack, search_meaning, live_processing, nudge_*, check_updates) | `get_settings` :2748 | — | — |
| POST | /api/settings | `{key: bool,…}` (unknown keys ignored) | same | `set_settings` :2764, `switches_turned_off` :2752, `count_setting` | settings.json (flock, merge); app.sock `switched_off {app}` for record_teams/record_slack false; usage.jsonl | 400 not bool |
| GET | /api/storage | — | `{folder,meetings,bytes,audio_bytes,audio_meetings,audio_days,days:[0,7,14,30,90],older:{"7":{meetings,bytes},…},models:[{id,label,purpose,bytes,deletable}]}` | `storage_status` → storage.summary :110 | walks every meeting folder's size | — |
| POST | /api/storage | `{"audio_days"?:int,"now"?:bool,"delete_model"?:id}` | storage + `dropped:{meetings,bytes}\|null` | `set_storage` :2037 | settings.json `audio_days`; deletes old audio; deletes a model from the HF cache / Application Support | 400 |
| GET | /api/language-model | — | `{features[…choice,default], providers[public, never keys], local:{model,models}, log: access_log.recent(20), labels}` | `language_model` :2780 | — | — |
| POST | /api/language-model | `{"use":{feature:choice}}` / `{"provider",endpoint,model,context_tokens,auth}` / `{"local_model"}` | same | `set_language_model` :2805 | settings.json `engines`, `providers`, `local_model` | 400 |
| POST | /api/language-model/key | `{"provider","key"}` / `{"provider","remove":true}` | same | `set_provider_key` :2824 | login Keychain (keyring), account `<provider>.api_key` | 400 |
| POST | /api/language-model/test | `{"provider"}` | `{"answer","seconds","model"}` | `_model_test` → llm.test (cloud HTTP) | access-log.jsonl | 502 NotesError, 400 |
| GET | /api/transcription | — | `{feature, providers, month:{seconds,usd,meetings}, log, labels}` | `transcription` :2854 | — | — |
| POST | /api/transcription, /api/transcription/key | as language model (`use`, `provider`+`model/region/endpoint/auth`; key) | same | :2870, :2887 | settings.json, Keychain | 400 |
| POST | /api/transcription/test | `{"provider"}` | `{seconds, …cost}` | transcription.test (2 s tone to the service) | access log | 502, 400 |

### 3.11 Setup assistant (#55)

| M | path | request | response | calls | side effects | errors |
|---|---|---|---|---|---|---|
| GET | /api/setup | — | `{offer,state,hardware,installed,permissions,recommendations,downloads:{needed,total_gb,free_disk_gb,status},profile,glossary(seed terms),storage:{recordings,audio_days,cloud,autostart},mcp,summary,test}` | `setup_page` :3265 | sysctl, disk usage, Teams/Slack/Claude app checks, permission checks (AVFoundation mic, app.sock `calendar`, doctor.check_system_audio over recordings, notify state), calendar 30 days back/14 ahead | — |
| GET | /api/setup/offer | — | `{"offer": {...,labels?} \| null}` | `setup_offer` :3213 | — | — |
| GET | /api/setup/recommendations | — | `{hardware,recommendations}` | :3229 | — | — |
| GET/POST | /api/setup/downloads | POST `{"models":[ids]}` | Downloads status | `setup_downloads`/`start_downloads` :3423-3436 → onboarding.Downloads | background download thread in the server; `downloading-models` marker with the server pid; spawns `python -m palaver.onboarding download <id> <repo>` (HF token from config.toml in env) or `palaver-engine prepare` | 400 |
| GET/POST | /api/setup/test | POST `{"action":"start"\|"stop"}` | test status | `setup_test` :3462 → RemoteTest → app.sock `test` | the app records 20 s | 400 busy/no app |
| GET/POST | /api/setup/calendar | POST `{"action":"connect"}` | permission state | `setup_calendar` :3478 → RemoteCalendar → app.sock `calendar` | the app asks macOS / opens Settings | 400 |
| POST | /api/setup/apply | `{"changes":{rid: value}}` | recommendations | `apply_setup` :3351, `_apply_one` :3314 | settings.json; providers; MCP install | 400 |
| POST | /api/setup/profile | `{"name","organization"?}` | `{"name","organization"}` | `setup_profile` :3363 | settings.json `user_name`, `user_aliases`; organizations.json; **mutates `app.user_name`** | 400 |
| POST | /api/setup/glossary | `{"terms":[…]}` | `{"added","undo"}` | `seed_glossary` :3385 | glossary.json, transcript.md | — |
| POST | /api/setup/autostart | `{"on":bool}` | `{"autostart"}` | Probe.set_autostart → app_bundle.set_autostart | LaunchAgent plist | 400 |
| POST | /api/setup/finish | `{"how":"done"\|"skipped"}` | `{"state"}` | `finish_setup` :3411 | settings.json `setup:{done\|skipped, hardware}` | 400 |

### 3.12 Claude access (MCP, #45)

| M | path | request | response | calls | side effects | errors |
|---|---|---|---|---|---|---|
| GET | /api/mcp[?meeting=id] | — | `{clients,log,registered,desktop}` or `{"reads":[…]}` | `mcp_status`/`mcp_reads` :3092-3101 | reads `~/Library/Application Support/palaver/mcp-access.jsonl`, `…/mcp/<pid>.json`, `~/.claude.json`, Claude Desktop config | — |
| POST | /api/mcp/clear | `{}` | status + `cleared`, `undo` | `clear_mcp_log` :3104 | log moved aside (own token, not undo.py) | — |
| POST | /api/mcp/restore | `{"token"}` | status | `restore_mcp_log` :3112 | — | 404 Gone |
| POST | /api/mcp/install | `{"target":"code"\|"desktop"}` | status | `install_mcp` :3118 | runs `claude mcp add --scope user …` (mcp_access.py:420) or edits Claude Desktop config, with `install_layout.stable_python()` | 500 |

Routes the page never calls: `/api/questions` and `/api/search/status`. The speaker routes (`…/speakers`, `remove`, `unknown`, `merge`, `shared`) don't show up in a grep for `/api/` because the page builds them with `speakersApi(id, path)` (app.js:1555), but they are used.

### 3.13 Polling load (what the Swift server must answer fast)

From static/app.js: `/api/ping` every 3 s (:6390), `/api/model-jobs` every 3 s (:6418), `poll()` every 10 s → `/api/meetings` (+ Today's `/api/needs` etc.) (:6357), `/api/meetings/{id}/stream` every 1 s while a live transcript is open (:1981), next-question info every 10 s (:2086), memory every 5 s on its page (:4460), review every 30 s (:6377), `/api/mcp` every 10 s (:6378), `/api/update` every 60 s (:6380), my-notes image text every 1 s while reading (mynotes.js:626), `/api/usage` flush every 5 s (ui.js:560). `/api/meetings` re-stats ~19 files per meeting and calls `_status` (live.pid check, maybe `ps`) for each, every 10 s.

## 4. Background work and in-process state

| what | started | does | where |
|---|---|---|---|
| request threads | per connection (`ThreadingHTTPServer`, daemon threads) | — | server.py:862 |
| `parent-watch` | serve | stdin EOF → shutdown | process.py:338-355 |
| `search-warm` | serve (before ready) | sleeps 20 s, QoS background (`pthread_set_qos_class_self_np`), builds `_SEARCH_CACHE` lines for every ready meeting with 50 ms pauses; stops while daemon.json says recording/transcribing (unknown = busy) and retries every 30 s | api.py:1843-1912 |
| `sweep` | after ready | `exchange.sweep(output_dir)`: `.importing` leftovers older than 1 h | process.py:400, server.py:125-132 |
| `warm-up` | after ready | `glossary_page` once (suggestions read every transcript) | process.py:358-366 |
| `cut-lookup` | GET /api/needs | per meeting, ≤4 at once, calendar lookup + `suggest_cut`; 10 s counts as failed; fresh for 600 s | api.py:2415-2472 |
| `my-notes-ocr` | image upload | Vision text recognition (de-DE, en-US), writes `<image>.txt` | my_notes.py:329-406 |
| Searcher idle timer | first meaning search | `threading.Timer` 300 s; drops encoder, indexes, query cache | semantic.py:234-282 |
| `<kind>-helper` reaper | only when the server launches a helper itself (app did not answer) | waits, writes the job record's returncode | model_jobs.py:127-152 |
| Downloads thread | POST /api/setup/downloads | sequential downloads, progress, marker | onboarding.py:1061-1178 |
| blocked waits | notes/projects/next-question requests | poll job records every 0.2 s for up to the run's length (10 min) | server.py:777-810, model_jobs.py:155-164 |

In-memory caches (all keyed by `st_mtime_ns` signatures of the files, never invalidated otherwise): `_LIST_CACHE` (19 files incl. glossary.json, api.py:257-286), `_PARTICIPANTS_CACHE` (:1636), `_ORG_INDEX` (all calendar.json mtimes, :1637-1663), `_SEARCH_CACHE` (names, glossed notes, readable lines ~100 B/line, :1724), `_SUGGESTIONS` (glossary, :2111), `_QUESTIONS_CACHE` (:2315), `_NEEDS_CACHE` (+ cut_dismissed, :2367), `_CUT_CACHE`/`_CUT_PENDING` (:2424-2425), `_KNOWN_EVENTS` (:2927), `_SEARCHER` (:1955), `glossary._CURRENT` (glossary.py:204-222), `coach._RESULTS` (coach.py:300-331).

Locks: in-process `_PROJECTS_LOCK` (every change that touches projects, names, events, cuts, imports), `_GLOSSARY_LOCK`, `_MY_NOTES_LOCK`, `_CUT_LOCK`, `app.notes_lock`, `app.notes_jobs_lock`, `model_jobs._launch_lock`. Cross-process (flock): settings.json.lock (settings.py:107-117), `<folder>/.my-notes.lock` (my_notes.py:74-95), `~/Library/Application Support/palaver/notes.lock` (cli.py:809-830, "a language model is in use"), mcp-access lock. **No cross-process lock** on projects.json, glossary.json, organizations.json, attributions.json, the voice bank or a meeting's speaker files, which `palaver process`, `palaver projects` and the server all write.

## 5. Files on disk

### 5.1 Meeting folder `<output_dir>/<YYYY-MM-DDTHH-MM-SS[-N]>/` (paths.py)

| file | shape (key fields) | server reads | server writes |
|---|---|---|---|
| meta.json | `{start_time, end_time?, duration_seconds, trigger, stop_reason, gaps[{start,end,…}], audio_problems[…]}` | list, page, lifecycle texts, cutting | split/join/discard |
| mic_raw.wav, mic.wav, system.wav (+ `.part` while recording) | 16-bit PCM | audio ranges, `has_audio`, storage | split/join (rewrites), delete-audio, import (system.wav) |
| `.live-diarize.wav` | live scratch | storage size | delete-audio |
| mic_segments.json, system_segments.json | `[Segment{start,end,text,speaker,words[{text,start,end,confidence?}]}]` | missing_models, suggest_cut | split/join |
| system_turns.json | `[{speaker:"SPEAKER_NN",start,end}]` | everywhere (labels, talk time, clips) | split/join |
| transcript.json | `[Utterance{speaker,start,end,text,label?,heard?,unsure?}]` | everywhere | edit line; `save_speaker_names` rewrites it after any name change (speaker = shown name, label = diarization label) |
| transcript.md | rendered | — | re-rendered after names, glossary, line edits |
| speaker_embeddings.json | `{label: [256 floats]}` | recognition, clustering, inference | join/split, import decision |
| speakers.json | `{label: name}` (label→itself = "not the recognized one") | names | naming, rename, merge |
| speakers_auto.json | `{label: {name, similarity (3 dp)}}` | names, links | `refresh_recognition` |
| speakers_inferred.json | `{label: {name, rule, why, confidence, depends[], by?, how?}}` | names, links, needs | `inference.refresh` |
| speakers_rejected.json | `{label: [names]}` | | "not Tom", rename |
| speakers_merged.json | `{label: into}` | | merge |
| speakers_ignored.json | `[labels]` | | remove |
| speakers_unknown.json | `[labels]` | | unknown |
| speakers_shared.json | `{meeting?:bool, from_series?, lanes:{label:room}, mic?:room, names:{…}, dismissed?}` | | shared |
| speakers_live.json | `[{name, embedding}]` | live page | naming while recording |
| live.json | `{until, mic[Segment], system[Segment], turns[…], embeddings{label:vec}}` | live page | — |
| live.pid, stream.pid | pid | `_status`, stream | live.pid **deleted** by `worker_running` when stale |
| stream.json | `{until, mic[], system[{start,end,text,…}], draft{system,mic}, speaking{}, questions[], updated_at}` | stream | — |
| calendar.json | `Event{title,start,end,attendees[{name,email,organizer,response,is_self,is_room}],all_day,source,uid,series,location, link{source,confidence?,reason?}}` or `{question:[Event…]}` or `{none:true, link:{source:"you"}}` | everywhere | event choice, cut (attach) |
| title.json | `{title}` | titles | rename |
| notes.json | `{title,summary,sections[{heading,points[{text,details[],mine?}]}],next_steps[{task,owner,…}],decisions[],speaker_names[{label,name,evidence}],transcript_hash,my_notes_hash?,shared_lanes?,…}` | page, list, search, stale check | — (helper writes) |
| my-notes.json, my-notes/ | `[{text, at, image?}]`; images `img-<12 hex>.<ext>` + `.txt` | | my notes routes |
| `.my-notes.lock` | flock | | |
| review.json | `{reviewed, seen:[need ids]}` | | reviewed |
| cut_dismissed.json | `{dismissed}` | | cut-suggestion |
| local_only.json | `{since}` | | local-only |
| failed.json | `{reason:"models"\|"error", at, missing[], error}` | status, untranscribed | — |
| transcription.json | `{system:{engine, fallback_from?, at,…}, mic:{…}}` | transcribed_by | copied by split |
| imported.json, imported_voices.json | `{from, imported_at, title, projects, beside{meeting}, names{label:{name,how}}, voices_pending[]}`; `{label:{…embedding}}` | page, hints, inference | import, decide voices |
| parts.json | continuation | `recorded` text | — |
| audio_deleted.json | `{at, bytes}` | page, storage | delete-audio |
| session.log | JSON lines (`event`, `level`, `message`, `traceback`, `ts`) | `last_failure` (api.py:793-826) | — |
| search-index.{npy,json,sig,failed} | float16 rows + pieces | meaning search, `ready` | — (`palaver index`) |
| notion.json, language.txt, audio_problems.json, coach.json | | `_status` ("synced") / carried by cuts | — |

### 5.2 Recordings root `<output_dir>/`

| path | what |
|---|---|
| `.trash/<id>[-n]` | trashed / joined-away meetings; `.trash/<id>.undone-<8>` and `.trash/undone-<8>/` hold what a restore replaced |
| `.trash/.undo/<32-hex token>/` | `manifest.json {label, time, meetings{id:{partial,audio,fingerprint}}, stores[{path,index,existed,dir,fingerprint}], moves[[src,dst]], created[], created_fingerprints{}, extra{}}`, `meetings/<id>/…`, `stores/<i>/<name>`. Pruned to 20 newest / 24 h (undo.py:296-319) |
| `.jobs/<kind>-<key>.json`, `.log` | `{kind,key,pid,state:"running"\|"done",started,returncode?,ended?,stale?}` |
| `.jobs/undo/<token>.json` | `{token,label,owner(pid),state:"pending"\|"finished",ok?}` |
| `.importing/` | import staging |
| `<id>/.join-backup/` | crash-safe join (`files.json`, `done`) |

### 5.3 Config and Application Support

| path | shape | read/written by the server |
|---|---|---|
| ~/.config/palaver/config.toml | user config (tokens; never opened here) | read via `_load_cfg`; never written |
| ~/.config/palaver/settings.json (+ `.lock`) | Settings booleans + `user_name`, `user_aliases`, `setup`, `audio_days`, `engines{feature:choice}`, `providers{pid:{…}}`, `local_model` | R/W |
| ~/.config/palaver/voices/<slug>.json | `{name, samples:[{embedding[256], source:"<meeting>:<label>", added}]}` (≤20 samples) | R/W |
| ~/.config/palaver/projects.json | `{projects:{pid(8 hex):{name,description,description_by}}, meetings:{id:{assigned:{pid:{by:"you"\|"auto"\|"model",why,confidence?}}, rejected:[pid]}}}` | R/W |
| ~/.config/palaver/glossary.json | `{terms:{tid(8 hex):{term,variants[],note}}, rejected:[keys]}` | R/W |
| ~/.config/palaver/organizations.json | `{names:{domain key:name}, people:{casefolded person:org}}` | R/W |
| ~/.config/palaver/attributions.json | event-series evidence (rejections, confirmations, rules) | R/W |
| ~/.config/palaver/prepared.json | `{event key:{title,start,projects[]}}` | R/W |
| ~/.config/palaver/prepared-notes/<24 hex>/ | my-notes for an upcoming event | R/W |
| ~/.config/palaver/shared-series.json | remembered "several people" series | R/W |
| ~/.config/palaver/coach-baseline.json | written by `process`; the server computes its own baseline | — |
| ~/.config/palaver/access-log.jsonl | what left the Mac | R (cloud tests append) |
| ~/.config/palaver/dictionary.toml | transcriber replacements | — |
| ~/Library/Application Support/palaver/daemon.json | the app's state (`state`, `pid`, `updated`, `folder`, `why_text`, `warnings`, `hints`, `talk`, `talk_text`, `nudge`, `quiet`, `stop_question`, `memory`, `indexing`, `index_downloading`, `transcribing`) | R (stale after 30 s) |
| …/app.sock | appctl | client |
| …/update.json | updater state | R |
| …/notes.lock | flock: a model is in use | R (non-blocking probe) |
| …/usage.jsonl, usage-features.json | page usage | W |
| …/mcp-access.jsonl, mcp/<pid>.json | MCP log, clients | R/W (clear/restore) |
| …/downloading-models | server pid while downloading | W |
| …/models/, ~/.cache/huggingface | models | R (presence, sizes), delete |
| ~/Library/Logs/palaver/daemon.log | the server's log (shared with the Python daemon/workers) | W |
| `$PALAVER_NOTIFY_STATE` file | `allowed\|denied\|not_asked` | R |
| ~/Downloads/*.zip | exports | W |
| ~/Desktop/…zip | problem reports | W |
| ~/Library/LaunchAgents/com.kenodressel.meeting-transcribe.plist | autostart | W (setup) |
| login Keychain, service `KEYCHAIN_SERVICE`, account `<provider>.api_key` | provider keys | W (never returned) |

## 6. Calls out to other processes

| target | how | when | phase |
|---|---|---|---|
| app.sock (`appctl.call`, one JSON line each way, timeout 1 s or 12 s) | `answer`, `record`, `transcribe`, `switched_off`, `watch`, `start_helper`, `test`, `calendar` (status/connect), `update_check`, `update_install`, `uninstall` | routes in §3.1, §3.9-3.11 | 3 (contract with the Swift app; the Swift side exists: AppCalls.swift) |
| daemon.json | read per request, `_pid_alive(pid)`, `updated` ≤ 30 s | recording/question/coach/memory, busy checks | 3 |
| update.json, `$PALAVER_NOTIFY_STATE` | file reads | Settings | 3 |
| `palaver notes <folder> --force` | via app.sock `start_helper` (app launches, records `.jobs/`), fallback `model_jobs.launch` with `taskpolicy -c utility` | POST notes | 4 |
| `palaver projects --no-wait suggest\|describe <pid>` | same | projects suggest/describe | 4 |
| `palaver next-question <folder>` | `Popen` from the server, own session, stdin JSON, 600 s | POST next-question | 4 |
| `python -m palaver.onboarding download <id> <repo>` | `subprocess.run`, HF token in env | setup downloads | U (setup/models) |
| `palaver-engine` (`prepare`) | engine.Engine child, JSON lines | setup downloads of the speech model | 1 (engine) / U |
| `claude mcp add --scope user …` | `subprocess.run`, 60 s | MCP install, setup apply | 4 |
| `open <url>`, `open -R <zip>` | `subprocess.run`/`Popen` | notifications settings, report, calendar fallback | 3\* |
| `ps -p <pid> -o command=` | live.worker_running | every `_status` with a live.pid | 3 (Swift: `proc_pidpath`/sysctl) |
| `vm_stat` | daemon.available_memory_gb | next-question memory check | 4 |
| `/usr/sbin/sysctl -n`, `system_profiler`, … | onboarding.Probe, report | setup, report | U |
| EventKit (in process, PyObjC) | `events_between`, `has_access` | every calendar lookup (page, events, needs, upcoming, prep notes, setup) | 3 |
| Vision (in process) | OCR | image paste | 3\* |
| AVFoundation (in process) | mic authorization status | setup | U |
| cloud HTTP | `llm.test`, `transcription.test` | Settings Test buttons | 4 / U |
| e5 encoder (in process, numpy, mmap 471 MB) | `semantic.Searcher` | meaning search | 4 |

No language model runs inside the server process; every generation is a helper process.

## 7. Tests that pin the behaviour

Counts are `def test_` per file (parametrized cases count once).

| area | files (count) | total |
|---|---|---|
| HTTP layer and server process | test_webapp.py 141, test_web_process.py 22, test_webapp_remote.py 26, test_search_api.py 18, test_setup_api.py 37, test_needs.py 19, test_live_coach_api.py 13, test_memory_api.py 2, test_update_api.py 5, test_report_api.py 5, test_window_url.py 5 | 293 |
| Meetings domain | test_paths 5, test_models 6, test_titles 9, test_readable 5, test_render 9, test_merger 10, test_lifecycle 8, test_cutting 29, test_undo 28, test_model_jobs 9, test_calendar_events 16, test_attribution 38, test_organizations 5, test_prep 4, test_shared_mic 40, test_settings 7, test_storage 16 | 244 |
| Export/import, my notes | test_exchange 86, test_my_notes 27 | 113 |
| Voices, people, inference | test_voices 9, test_speakers 15, test_people 9, test_inference 8 | 41 |
| Projects | test_projects 16 | 16 |
| Glossary | test_glossary 13 | 13 |
| Search (rules) | test_search 17 | 17 |
| Setup assistant | test_onboarding 63 | 63 |
| Usage, access log | test_usage 8, test_access_log 5 | 13 |
| Coach (spec: 4) | test_coach 13, test_coach_review 10, test_coach_worker 8, test_live_coach 25, test_voice_activity 25, test_daemon_coach 9 | 90 |
| Phase 4 material | test_notes 52, test_llm 18, test_providers 21, test_cloud_llm 27, test_next_question 10, test_semantic 17, test_embeddings 6, test_mcp_server 15, test_mcp_access 29, test_notion_client 12, test_keychain 5 | 212 |
| Playwright e2e (tests/e2e/) | app_window 10 (integration, legacy PyObjC window), attribution 8, exchange 9, feedback 7, guard 9 (the guard itself), header 7, live_coach 7, meeting_actions 18, meeting 14, my_notes 21, navigation 8, notes 7, pages 14, reconnecting 1, record 4, rename 4, report 5, setup 15, shared_mic 5, speakers 12, stores 14, today 17, transcript 11 | 227 |
| Frontend JS (node, tests/js/*.mjs, stays) | 23 files | 265 |

**How the e2e tests start the server** (tests/e2e/conftest.py):
- `_serve(root, key)` (:256-271) builds four synthetic meetings with `build_recordings` (tests/e2e/recordings.py: A `2026-10-27T09-00-00` Team standup, B, C back to back, LIVE with live.json, a growing `.part`, and a fake live worker `python -c "sleep 3600"` whose pid goes into live.pid), then constructs `App(...)` **in-process** with fakes and calls `make_server(app, port=0, key=key)` on a thread.
- Fakes injected through `App`: `FakeNotes` (write_notes; hold/release gate), `run_projects` → `served.model_runs` + `on_model_run` hook, `FakeRecording` (question/coach/transcribe/record/answer), `FakeProbe` (tests/fake_probe.py: hardware, downloads, test recorder, calendar permission), `FakeModel` (ask_model), `free_memory_gb`, `downloads = root.parent/"Downloads"`.
- Fixtures: `app_server` (fresh per test), `keyed_server` (key `the-apps-key`), `shared_server` (module-scoped, read-only tests), `page` (WebKit context 1280×860, init script mutes media and fakes the clipboard; `Guard` fails a test on console.error, page errors, dialogs), `audio_decoding` probe.
- Stores live in a temporary `XDG_CONFIG_HOME` (tests/conftest.py:61-66); autouse fixtures fake the Keychain, block the network, fake notifications and models.
- Coupling to Python internals inside e2e tests: `monkeypatch.setattr` on `api.install_mcp`, `api.update_action`, `storage.models`, `updater.read_status`, `subprocess.run`; direct imports of `process_state`, `projects`, `attribution`, `calendar_events`, `model_jobs`, `my_notes`, `usage`, `providers`, `settings`, `onboarding` to arrange or check files (test_pages.py, test_setup.py, test_attribution.py, test_meeting_actions.py, test_notes.py, test_live_coach.py). `served.recording/probe/notes/model/free_gb` are poked directly in several tests.

## 8. Python dependencies of phase-3 code and Swift equivalents

| Python | used for | Swift needs |
|---|---|---|
| http.server (ThreadingHTTPServer) | the server; adopts a listening fd | an HTTP/1.x server that accepts on an **inherited listening fd** (SwiftNIO `ServerBootstrap.withBoundSocket`, or a small accept loop on the fd); Range responses, streaming request bodies up to 1.4 GB |
| json (`ensure_ascii=False`, `indent=2`) | every store | JSONSerialization/Codable; key order and float formatting differ (Python writes `1.0`, shortest repr; see §9 risks) |
| numpy | cosine similarity (voices, people, inference, live names, cutting.keeper), audio mixing (AudioSource), import mix | Accelerate/vDSP or plain loops; Float64 math for parity |
| scipy.cluster.hierarchy (`linkage(average, cosine)`, `fcluster(t=1-0.75, distance)`) | unknown-voice groups (people.py:107-118), intersections in inference | own UPGMA implementation |
| soundfile (libsndfile) | WAV info/range reads, cut/rewrite int16 WAVs, Ogg Opus / FLAC encode (export), decode (import) | own RIFF reader/writer (avoid `AVAudioFile.read` short reads, spec lesson); **Ogg Opus** needs libopus+libogg (AudioToolbox has no Ogg container); FLAC via AudioToolbox or libFLAC |
| soxr | resample a sender's mic on import | AVAudioConverter or the phase-2 `Resampler.swift` |
| wordfreq (`zipf_frequency` de + en) | "rare word" test in glossary suggestions | ship Zipf tables for de/en (data licence to check), same tokenization as wordfreq for parity |
| rapidfuzz `fuzz.ratio` | glossary similarity (and coach) | normalized Indel similarity (0–100) |
| difflib.SequenceMatcher | respelled-word counts | port of Ratcliff/Obershelp opcodes, `autojunk=False` |
| re (Unicode `\w`, lookbehind, IGNORECASE) | search words, glossary apply, name guesses, query parser | NSRegularExpression/Swift Regex; check `\w`/`\b` and case-folding parity |
| hashlib sha256, uuid4 | undo fingerprints, revisions, tokens, prep folder digests | CryptoKit, UUID |
| zipfile | export/import with strict caps | ZIPFoundation or minizip (no Foundation zip writer) |
| fcntl.flock | settings, my notes, notes.lock | `flock(2)` |
| datetime (`fromisoformat`, `astimezone`, `isoformat(timespec="seconds")`) | all timestamps | ISO8601 with local offset, same precision |
| PyObjC EventKit, Vision, AVFoundation, Quartz | calendar, OCR, permissions | native frameworks (simpler in Swift) |
| keyring | provider keys | Security framework (phase 4) |
| huggingface_hub, sentencepiece, mlx | downloads, embeddings, local models | phase 4 / U |

## 9. Hard parts, risks and unassigned Python

### Risks

1. **Two implementations of one domain during phase 3.** `palaver process` (unassigned, stays Python) writes the same files the server writes: speakers_auto.json, transcript.json/md, speakers_inferred.json (via `inference.refresh` over **all** meetings, cli.py:762), projects.json (`assign_by_rules`, cli.py:932, :1025), the voice bank. `palaver mcp` (phase 4) imports `webapp.api` for its reads. So Python's speakers/voices/people/inference/projects/glossary/api cannot be deleted in phase 3, and Swift and Python must produce identical results on the same files. Any drift (a threshold compare, a rounding) flips names back and forth between the two writers.
2. **No cross-process locking** on projects.json, glossary.json, organizations.json, attributions.json, voices/ and per-meeting speaker files. Today the in-process `_PROJECTS_LOCK` serializes the server only; `process` and the helpers race it. A Swift server keeps that race unless the design adds file locks on both sides.
3. **Undo is a file-format contract.** Snapshots in `.trash/.undo/` are restored by fingerprint (sha256 over `name\0size\0` + content hash of every non-WAV file, sorted by relative POSIX path; undo.py:85-101). A snapshot taken by the last Python server must be restorable (or refused cleanly) by the Swift server across the update; `.jobs/undo/*.json` pending sorts are finished by "whichever server sees the job end" (api.py:1528-1550), possibly the other implementation. `_undoable` rolls back on any exception, so Swift error paths must restore before answering. The undo special cases (my-notes, shared, title/unknown, import, glossary re-render) are in `undo_change` (api.py:959-984).
4. **Notes staleness depends on a hash phase 4 still writes.** `notes.transcript_hash` (notes.py:230-235: `f"{label}\t{start:.2f}\t{text}\n"`, sha256, 16 hex) and `my_notes.prompt_hash`/`shared_lanes` must be computed byte-identically in Swift, or every meeting shows "notes out of date".
5. **Speaker-inference and recognition math.** Thresholds compare floats at 0.65/0.75 with margins 0.1, `round(sim, 3)` stored, `round(conf, 3)`; UPGMA cut at distance 0.25; six inference rounds with order-dependent `add` (sorted labels, dict insertion order). Python `round` is correctly rounded on the binary value; Swift needs the same. Cosines are float64 over 256-d float lists.
6. **Search ranking and parsing parity.** Rank tuples rely on Python's stable sort over a newest-first list (Swift `sort` is stable in practice but not documented). The query parser (search.py, 454 lines) has German/English word lists, month names, relative dates, name matching (`is_person`), and chips with spans. Casefolding differs: Python `casefold()` maps "ß" to "ss" (Timo Strauß = timo strauss), Swift `lowercased()` does not.
7. **Glossary suggestions** need wordfreq's Zipf data for two languages and its tokenizer, rapidfuzz ratio, Kölner Phonetik and difflib; the suggestion list order is user-visible (top 20).
8. **The live/stream page reads files written while they change** (live.json, stream.json, `.part`); `_status` uses `.part` mtimes (60 s) and live.pid, and `worker_running` deletes stale pid files as a side effect of a GET (live.py:75-102).
9. **Audio.** Range-served on-the-fly mix (§3.2) assumes all tracks share the first file's sample rate. Split/join rewrite whole WAVs in memory (`sf.read` of a full track). Export writes Ogg Opus (the exchange format's `audio/*.opus`): no AudioToolbox path.
10. **Concurrency model.** One thread per request with blocking waits of up to 10 minutes (notes, next question); `Inflight` drain semantics on restart; a notes request deduplicated per meeting; `notes.lock` probed non-blocking across processes. Swift needs the same leader/follower and 409 behaviour (tests: test_webapp.py:1239-1255, :1472-1516).
11. **Coach ownership conflict.** The spec lists coach in phase 4, but the phase-2 design says the coach "moves with the server in phase 3" and today's `palaver coach <folder>` worker (live_coach.py, voice_activity.py) is a Python child of the Swift app. The coach has no language model.
12. **e2e harness.** The e2e suite builds `App` in-process with Python fakes and monkeypatches Python modules (§7). Running it against a Swift server needs a fake app.sock (the repo already has `palaver-appctl-helper`, test_appctl_swift_contract.py), a written daemon.json, fake helper commands for notes/projects/next-question, and a test hook for the probe (hardware, downloads, test recording, calendar), update.json and storage models.
13. **Setup assistant runs model downloads inside the server process** (and writes the `downloading-models` marker the updater waits on). A restart of the server during a download kills it.
14. **Quirks the page may rely on:** unknown suffix-less GET paths return index.html with 200; HTTP/1.0 close-per-request; `LookupError` (not `NotFound`) from `Glossary._term`/`ProjectStore._project` becomes 500; `/api/meetings/{id}` for a recording without live.json falls back to the finished shape.

### Unassigned Python (in neither phase-3 nor phase-4 list)

| module(s) | lines | what | note |
|---|---|---|---|
| cli.py (`process`, `run`, `rename`, `list`, `export`, `import`, `voices`, `prune`, `sync`, `bench*`, `app query/housekeeping/update`, `calendar attach`, `onboarding analyze`) | 1715 | the CLI and the processing pipeline | `process` shares the phase-3 domain (risk 1) |
| live.py, stream.py, stream_engine.py, merger.py (pipeline use) | 366 + 287 + 178 + 114 | live and realtime workers | |
| transcription.py, cloud_asr.py, transcriber.py, engine.py, diarizer.py | 598 + 535 + 197 + 239 + 97 | ASR/diarization clients, cloud transcription | Settings → Transcription is served by the server |
| aec.py, cleanup.py, voice_activity.py | 228 + 174 + 442 | echo cancellation, cleanup, VAD | |
| live_coach.py | 435 | `palaver coach` worker | see risk 11 |
| cutting.py | 603 | split/join (also crash recovery in `process`) | server-only use otherwise; 3\* |
| onboarding.py (Downloads, TestRecording analysis, model checks) | 1415 | setup and models | its HTTP side is the server's |
| doctor.py, report.py, runlog.py, session_log.py, usage.py | 369 + 772 + 130 + 127 + 238 | diagnostics, logs | report and usage have routes |
| updater.py, app_update.py, release.py, uninstall.py, install_layout.py, model_store.py, downloader.py, migrate.py, prune.py | 569 + 214 + 226 + 107 + 133 + 147 + 93 + 46 + 90 | updates, install, models | |
| app_bundle.py, daemon.py, menubar.py, webapp/window.py, process.py `WebSupervisor`, appctl.py server side, memory.py, meter.py, teams_detector.py, capture_recorder.py, _audio/, audio_health.py, recorder.py, session.py, continuation.py, notify.py, calendar_eventkit.py (request side) | — | the legacy Python app (`PALAVER_LEGACY_APP` fallback) | phase 2 replaced them; kept for one release |
| config.py, dictionary.py, keychain.py, paths/_xdg | 168 + 42 + 88 + 11 | config | needed by every phase |
| bench.py, stream_bench.py | 245 + 440 | benchmarks | |
