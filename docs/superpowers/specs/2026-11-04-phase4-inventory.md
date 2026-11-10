# Phase 4 inventory: language models, integrations, and the rest of Python

Repo at commit b120d78 (worktree `palaver-server`, branch `swift-server`, same commit as master).
All paths are relative to the repo root. Line numbers are `file:line`.

Phase 4 in the spec (`2026-11-03-swift-migration-design.md`, "Phases"): notes, coach and project
suggestions move to mlx-swift-lm or the cloud providers, along with Notion, the MCP server and the
search embeddings. After it, Python leaves the app and the installer ships no Python runtime.

This inventory covers two things:

1. Everything phase 4 itself replaces (§1–§4).
2. Everything else that still needs Python after phases 2 and 3 (§5). Without it, "no Python
   runtime" cannot be reached. The spec names no owner for most of these. They are marked
   **unassigned**.

Corrections to the task's assumptions:

- **`exchange.py` is not Notion.** It is the meeting export/import zip (#58). Notion is
  `notion_client.py` plus `cli._cmd_sync`/`_cmd_run`, and it only writes (§4.1).
- **The coach is two things.**
  - The live coach worker (`palaver coach`: talk share, pace, fillers) has no language model. The
    phase 2 design says it "moves with the server in phase 3"
    (`2026-11-04-swift-app-phase2-design.md:46-50`).
  - Only "Best next question" (`next_question.py`, provider feature id `"coach"`) uses a language
    model. That part is phase 4.
- **Glossary extraction is not LLM-based.** It uses wordfreq and rapidfuzz (`glossary.py:1-22`).
- **`memory.py` is not an LLM feature.** It is the memory watchdog.
- **`my_notes.py` is not an LLM feature either.** It is the user's own notes, with OCR by macOS
  Vision through PyObjC (`my_notes.py:312-350`).
- **There is no Gemini provider in code.** Gemini or Voxtral via Cortecs would go through the
  "OpenAI-compatible" provider. There is no chat-model audio path (`grep -i gemini palaver/` finds
  nothing).

## 0. Modules and line counts

**Phase 4 core**

| module | lines | role |
|---|---|---|
| palaver/notes.py | 681 | notes schema, prompt, local MLX runner, Claude CLI runner, parse/repair, staleness, name guesses |
| palaver/llm.py | 258 | which engine runs a feature; local-only rule; context check; access log; Test button |
| palaver/cloud_llm.py | 362 | HTTP transport, retries, redaction; Anthropic Messages and OpenAI Chat Completions runners |
| palaver/providers.py | 339 | provider registry (LLM + ASR), per-feature choice, settings.json storage, key presence |
| palaver/keychain.py | 88 | API keys in the login Keychain via `keyring` |
| palaver/access_log.py | ~60 | `access-log.jsonl`: every cloud call (no content, no key) |
| palaver/next_question.py | 156 | "Best next question" prompt, schema and parse |
| palaver/projects.py (model part) | 532 (≈160 of it: :370-532) | project suggestions and descriptions by the model; the rest (rules, store) is phase 3 |
| palaver/notion_client.py | 228 | Notion REST: create page or database row, append blocks |
| palaver/mcp_server.py | 482 | `palaver mcp`: 7 read-only tools over stdio |
| palaver/mcp_access.py | 494 | MCP access log, heartbeats, Claude Code/Desktop registration and migration |
| palaver/embeddings.py | 158 | multilingual-e5-small encoder in numpy (memory-mapped safetensors) |
| palaver/semantic.py | 350 | per-meeting search index (`search-index.*`), `Searcher` for queries |
| palaver/cloud_asr.py | 535 | cloud transcription adapters (AssemblyAI, Soniox, Mistral, OpenAI-compatible) |
| palaver/transcription.py | 598 | local vs cloud for the system track; silence cutting, chunking, stitching, pending deletes |

**Unassigned or shared** (the full list is in §5)

| module | lines | role |
|---|---|---|
| palaver/cli.py | 1715 | every command; `_process` pipeline :542-782; notes/projects glue :809-1046 |
| palaver/aec.py | 228 | WebRTC APM via ctypes (`libraven_aec.dylib`) |
| palaver/live.py | 366 | `palaver live` |
| palaver/stream.py, stream_engine.py | 287 + 178 | `palaver stream` |
| palaver/onboarding.py | 1415 | setup assistant: recommendations, model downloads, test analysis |
| palaver/updater.py, app_update.py, release.py, downloader.py | 569 + 214 + 226 + 93 | updates, swap script, manifest |
| palaver/uninstall.py | 107 | uninstall script |
| palaver/report.py | 772 | Report a Problem zip |
| palaver/doctor.py | 369 | `palaver doctor` |
| palaver/app_query.py | 93 | `palaver app query` facts for the Swift daemon |
| palaver/calendar_eventkit.py | 101 | EventKit reads via PyObjC |

## 1. Language models

### 1.1 Engine selection (llm.py)

| rule | where |
|---|---|
| Local models offered: only `mlx-community/gemma-4-12B-it-OptiQ-4bit`, label "Gemma 4 12B", `context_tokens` 131 072, `running_gb` 10, `memory_gb` 14 | llm.py:35-39, notes.py:36-45 |
| Unlisted local model: context 131 072, memory 20 GB (`NOTES_MEMORY_GB`) | llm.py:40, notes.py:44 |
| Feature choice comes from settings.json `engines[feature]`. A feature never chosen follows config.toml `[notes].engine` (`"claude"` → `claude-cli`, else local). Features with `own: True` (coach) default to local. | llm.py:100-114, providers.py:311-321 |
| `PENDING`: an LLM feature waiting for a cloud model (Mac too small) → `Unavailable` | llm.py:155-157, providers.py:34 |
| **Local only:** any meeting with `local_only.json` forces `LOCAL` for every feature that touches it | llm.py:75-94, 112-113 |
| The chosen engine never falls back to another engine | llm.py:9-11 |
| Context check before sending: `ceil(len/3.0)` tokens for prompt + schema, plus a reserve (local 4096, cloud 32 000, CLI 0). Too big → `ContextTooLong`. **No chunking anywhere:** a long meeting is refused, never split. | llm.py:44, 68-69, 193, 223-236 |
| Every cloud call is logged to `~/.config/palaver/access-log.jsonl` with provider, host, model, feature, meeting ids, chars, ok, seconds, and a redacted error | llm.py:195-221, access_log.py:24-30 |
| Local model: settings.json `local_model` if listed, else config `[notes].local_model` | llm.py:117-125 |
| Memory gate: `notes_memory_gb` is 0 for cloud, else 14 (Gemma). The daemon asks Python for it via `app query notes-memory`. | llm.py:133-144, app_query.py:40-43, Launch.swift:156-160 |

### 1.2 The local runner (notes.py:520-560)

| item | value |
|---|---|
| Library | `mlx_lm` 0.32.2 (Python 3.13 runtime; uv.lock:1079), mlx 0.32.4 |
| Model id | `mlx-community/gemma-4-12B-it-OptiQ-4bit`, snapshot `de9e1838…` |
| Model type | `gemma4_unified` (`Gemma4UnifiedForConditionalGeneration`) |
| Quantization | OptiQ mixed precision: base 4-bit affine, group 64; 329 per-layer overrides (156 layers at 8 bit); `achieved_bpw` 5.22 (`optiq_metadata.json`, `kv_config.json`) |
| Size on disk | 8.3 GB in `~/.cache/huggingface/hub/models--mlx-community--gemma-4-12B-it-OptiQ-4bit` |
| Load | `mlx_lm.load(repo)` from the HF cache (download by `huggingface_hub.snapshot_download`, onboarding.py:1407-1409). Kept loaded per process in `_LOADED` (notes, then projects in the same run). |
| Messages | system: `[schema.description + "\n\n"] + "Answer with a single JSON object that follows this JSON schema, and nothing else:\n" + json.dumps(schema)`; user: the prompt (notes.py:538-542) |
| Chat template | `tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False, enable_thinking=False)`, retried without `enable_thinking` on TypeError (notes.py:543-549). The template is `chat_template.jinja` (18.7 KB) and supports `system` and `enable_thinking`. |
| Sampling | `make_sampler(temp=0.2)` (top_p/top_k/min_p left at their defaults). `generation_config.json` (temp 1.0, top_k 64, top_p 0.95) is not used. |
| Max tokens | `LOCAL_MAX_TOKENS = 4096` (notes.py:45) |
| Constrained decoding | none; the schema goes only in the system text |
| Retries | 2 generations if `parse` raises ValueError, then `NotesError` (notes.py:550-558) |
| MLX cache limit | **none** for notes (only `live` sets 128 MB, cli.py:415-419, live.py:52) |
| One model at a time | `flock` on `~/Library/Application Support/palaver/notes.lock` (cli.py:809-850). `projects --no-wait` and `next-question` exit 75 (`EXIT_MODEL_BUSY`) when busy. |

**`json.dumps(schema)` is part of the prompt.** It uses Python's default separators (`", "`,
`": "`), insertion key order and `ensure_ascii=True`. For example, the "—" in projects'
`DESCRIPTION_RULES` becomes `—`. A Swift port must emit the same bytes, or the prompt tokens
differ.

### 1.3 Features that call a language model

| feature (provider id) | prompt (verbatim at) | schema | parser | invoked by | output |
|---|---|---|---|---|---|
| Notes (`notes`) | `PROMPT` notes.py:104-152; `MY_NOTES_PROMPT` :156-175 (inserted before the closing language rule, :313-320); `LANGUAGE_RULES`/`ANY_LANGUAGE_RULE` :180-186; `SHARED_RULE`/`MIC_RULE` :189-201; assembly in `generate` :277-340 | `SCHEMA` :47-102; with my notes `_schema_with_mine` :260-274; `description` = language rule (:322) | `parse_notes` :397-436 | `palaver notes <folder> [--force]` (daemon, Launch.swift:314; window helper, HelperJobs.swift:56-76) and `palaver run` (`_process` → `_write_notes`, cli.py:780, 853-911) | `notes.json` (atomic via `.json.tmp`, notes.py:570-574) |
| Project sort (`projects`) | `PROMPT` projects.py:420-433, `DESCRIPTION_RULES` :372-376, meeting lines `_describe` :436-443 | `SCHEMA` :378-418 | `parse_answer` :446-455 (strict `json.loads`) | after notes (`_sort_into_projects`, cli.py:923-952); `palaver projects [--no-wait] suggest [folder]` (cli.py:990-1042, window helper) | `~/.config/palaver/projects.json` (assignments `by="model"`, new projects, descriptions) |
| Project description (`projects`) | inline f-string projects.py:523-526 | inline `{description: string}` :526 | `_parse_description` cli.py:1116-1121 | `palaver projects --no-wait describe <id>` (window helper) | projects.json `description`, `description_by="model"` |
| Best next question (`coach`) | `RULES` next_question.py:49-57 + `build_prompt` :81-108 (last 5 min / ≥2 lines / ≤120 lines; my notes ≤4000 chars) | `SCHEMA` :29-47 (≤3 questions) | `parse` → `checked` :111-126 | web server `ask_model` → `palaver next-question <folder>` with inputs on stdin (webapp/__init__.py:65-101; cli.py:496-531); inputs built in api.py:2634-2675 | stdout JSON `{questions:[{question,why}], engine}`; nothing written |
| Test button (cloud only) | `TEST_PROMPT` llm.py:241 | `TEST_SCHEMA` :242 | `_any_json` | `POST /api/language-model/test` (server.py:516) | `{answer, seconds, model}` |

**`notes.json` shape** (written by `generate`, cli.py:909):

- From the model:
  - `title`, `summary`: str.
  - `sections`: `[{heading, points: [{text, details: [str], mine?: true}]}]`.
  - `next_steps`: `[{owner, task, mine?: true}]`.
  - `decisions`: `[str]`, plus `decisions_mine: [int]` when some decisions came from the user's
    notes.
  - `speaker_names`: `[{label: "SPEAKER_xx", name, evidence}]`, filtered to the transcript's
    unnamed labels (notes.py:327-329).
- Added in code:
  - `transcript_hash` (sha256 prefix 16, notes.py:230-235).
  - `shared_lanes?`.
  - `my_notes_hash?`.
  - `generated_at` (ISO, seconds).

Staleness: `stale_reason` compares `transcript_hash`, `my_notes_hash` and `shared_lanes`
(notes.py:576-593).

Readers (phase 3 side): api.py (incl. `backed_name_guesses` :307, :2354), titles.py, semantic.py
(index chunks), mcp_server.py, prep.py, projects facts, search, exchange.

**Repair rules in `parse_notes`** (must be kept for parity; small models need them):

- Strip `<think>…</think>` and anything up to a dangling `</think>`.
- Strip leaked special tokens such as `<|image>` and `<audio|>` (:400-404).
- Take the text from the first `{` to the last `}`; `json.loads(strict=False)` (raw tabs and
  newlines inside strings) (:405-409).
- `speaker_names` given as a dict becomes a list (:415-418).
- Sections, points, steps or decisions given as text instead of objects, or as objects instead of
  text, are normalised.
- A section with no heading and no points raises an error, which triggers a retry (:473-481).
- `mine` accepts `true`/`false` as strings (:484-491).

**Session-log events** (the menu's progress and doctor read these):

- `notes_start`/`notes_done` with `engine` and `model` (session_log.py:119-127).
- `notes_skipped`, `notes_failed`.
- `projects_start`/`_done`, `projects_failed`.
- `usage.record("notes", engine, model, seconds, ok)` (cli.py:883-889).

### 1.4 Claude Code CLI runner (provider `claude-cli`)

- Command: `claude -p --model <sonnet> --tools "" --setting-sources "" --no-session-persistence
  --output-format json --json-schema <schema>`.
- The prompt goes in on stdin, in a temporary cwd, with a 600 s timeout. The runner reads
  `structured_output` (notes.py:364-394).
- `find_claude` looks at `[notes].claude`, then PATH, then `~/.local/bin`, `/opt/homebrew/bin` and
  `/usr/local/bin` (:349-361).
- In Swift this is a plain subprocess.

## 2. Cloud providers

### 2.1 Registry (providers.py:54-106)

| id | kind | key | default endpoint / model | context | notes |
|---|---|---|---|---|---|
| `anthropic` | LLM | required | `https://api.anthropic.com` / `claude-opus-5-5` | 1 000 000 | Messages API |
| `openai` | LLM | optional (none only for localhost) | `https://api.openai.com/v1` / "" (user names it) | 128 000 | OpenAI, Azure OpenAI, any gateway (Cortecs, Gemini proxies) |
| `claude-cli` | LLM | none | – / `sonnet` | 200 000 | §1.4 |
| `assemblyai` | ASR | required | region eu/us / `universal-3-5-pro` | – | $0.28/h |
| `soniox` | ASR | required | region eu/us / `stt-async-v5` | – | $0.10/h |
| `mistral` | ASR | required | `https://api.mistral.ai/v1` / `voxtral-mini-latest` | – | $0.21/h |
| `openai-transcribe` | ASR | optional | `https://api.openai.com/v1` / `whisper-1` | – | |

**Features** (`FEATURES`, :91-106): `notes`, `projects`, `coach` (own, local by default),
`transcription`. Each has the "sends" text shown in Settings.

**Storage**

| what | where |
|---|---|
| per-provider endpoint, model, context, `auth` (auto/bearer/api-key), `region` | settings.json `providers.<id>`; values that fail the checks are ignored (providers.py:184-208) |
| per-feature choice | settings.json `engines.<feature>`; only `choose` writes it, and that is the user's consent (:324-339) |
| API keys | login Keychain, service `palaver`, account `<id>.api_key`, via `keyring` (keychain.py:22-51; providers.py:229-252). Validation: ≤4096 chars, no whitespace, latin-1 (keychain.py:66-81). |
| Notion and HF tokens | env `NOTION_TOKEN`/`HF_TOKEN`, then config.toml, then Keychain `palaver` (fallback `meeting-transcribe`), account = the env name (config.py:51-68) |

**Readiness** (`problem`, :255-295):

- Every provider needs a model name.
- A required key must be present.
- A gateway (`openai`) needs a *saved* endpoint, and a key unless it is on localhost. An Azure host
  must be a tenant host.

### 2.2 HTTP behaviour (cloud_llm.py)

- Transport is urllib. **Redirects are never followed**: a 3xx raises an error that names the
  target (:78-90, 190-194).
- Retries: 3 attempts on 408/409/429/5xx/529 and on timeouts. The wait is `Retry-After` capped at
  60 s, else 2 s then 8 s. Non-idempotent requests are retried only after a 429 (:151-201).
- A 401/403 means the key was refused.
- Errors are redacted: the key itself, plus anything that looks like a key (`_KEYISH`), cut to 300
  chars (:46, 113-119).
- **Anthropic** (:257-289):
  - `POST <endpoint>/v1/messages` with `anthropic-version: 2026-10-21`, `max_tokens` 32 000, a
    600 s timeout and no streaming.
  - `output_config.format = {type: json_schema, schema: closed(schema)}`, where `closed` adds
    `additionalProperties: false`. The system prompt is the schema description plus a short
    instruction.
  - `stop_reason` `max_tokens` or `refusal` raises an error. A parse failure is asked once more.
- **OpenAI-compatible** (:316-362):
  - `POST <endpoint>/chat/completions`, keeping the query string (Azure `api-version`).
  - Header: `api-key` for Azure hosts or when `auth=api-key`, else `Authorization: Bearer`.
  - The schema goes in the system prompt and in `response_format: json_schema, strict: false`. A
    400 that says this is unsupported is retried without `response_format`.
  - `finish_reason` `length` or `content_filter` raises an error.
- In Swift: URLSession with a delegate that refuses redirects
  (`willPerformHTTPRedirection` → nil). The Security framework replaces `keyring`.

### 2.3 Local-only rule, everywhere it is enforced

| place | effect |
|---|---|
| llm.py:108-114 `choice_for` | a cloud choice becomes local for a meeting marked local only |
| projects.py:458-510 `private` | local-only meetings are left out of a cloud prompt; a project with only such meetings is hidden |
| cli.py:516-521, api.py:2663-2664 | next question: earlier local-only meetings are dropped from the cloud context |
| transcription.py (#54) | a local-only meeting is always transcribed on this Mac |
| mcp_server.py:79-130 | local-only meetings and all-private projects are invisible to Claude |
| exchange.py:1074 | import can set local only |

### 2.4 Cloud transcription (cloud_asr.py, transcription.py)

- **What goes out**:
  - Only the **system track**. The mic stays local.
  - Silences of 2 s or more are cut out (−50 dBFS, transcription.py:66-70, 159+).
  - The audio is resampled with soxr if needed, encoded as FLAC 16 kHz mono (soundfile), and sent
    in chunks with overlap that are stitched back by word (`plan_chunks`, `stitch` :258-306).
- **Keyterms** (`keyterms` :330): glossary terms and invitee names, at most 1000/200 (AssemblyAI),
  500 (Soniox), 100 (Mistral `context_bias`) or 60 (OpenAI `prompt`).
- **Adapters**:
  - AssemblyAI: upload, job, poll, delete; regions eu/us (:218-298).
  - Soniox: files, transcriptions, delete (:300-400).
  - OpenAI-compatible: multipart `/audio/transcriptions` (:402-458).
  - Mistral: the same endpoint, with `context_bias` (:460-485).
- **Pending deletes**: deletes the service refused are kept in `cloud-pending.json` (per meeting and
  `~/.config/palaver/cloud-pending.json`) and retried at the next `process` (`sweep_pending`).
- **Test**: `POST /api/transcription/test`.
- Uploads are logged to access-log.jsonl with `audio_seconds` and `track`.
- **Phase**: the spec does not name cloud ASR. It sits inside the `process` pipeline (§5). It shares
  the provider registry, keys and transport with the LLMs, so **suggest phase 4**, with the
  providers.

## 3. MCP server

### 3.1 Process and transport

- **Server**: `palaver mcp` serves one client over **stdio** (mcp_server.py:453-470), built on the
  Python `mcp` SDK 2.3.0 `MCPServer("meetings", instructions=INSTRUCTIONS, middleware=[...])`
  (:382-387).
- **Lifetime**: it ends on stdin close, SIGTERM/SIGHUP, or when the parent client is gone
  (`watch_parent`, every 5 s).
- **Middleware** `_client_watch` (:357-371) records `clientInfo` from `initialize`.
- **How it is started**: each MCP client starts its own process.
  - Claude Code: `claude mcp add --scope user meetings -- <app>/Contents/Resources/bin/python -m
    palaver [--config X] mcp` (mcp_server.py:473-481; mcp_access.py:423-439). The entry lands in
    `~/.claude.json`.
  - Claude Desktop: merged into
    `~/Library/Application Support/Claude/claude_desktop_config.json` as
    `mcpServers.meetings = {command: <…/bin/python>, args: ["-m","palaver",…,"mcp"]}`. The previous
    file is kept as `.bak` (mcp_access.py:442-474).
  - `Resources/bin/python` is a shell wrapper that execs `Contents/MacOS/palaver-python`
    (app_bundle.py:443-450). `install_layout.stable_python()` returns it (install_layout.py:124-133).
  - An entry counts as Palaver's when "palaver" is in the command or args and "mcp" is in the args
    (mcp_access.py:356-360).
  - `migrate()` rewrites stale venv entries (:477-494). Today the Swift app runs it via
    `palaver app housekeeping` (app_update.py:151-171).
- **Window side**: `/api/mcp` shows connected clients and the log. `/api/mcp/install`,
  `/api/mcp/clear` and `/api/mcp/restore` act on them (server.py:253, 436-440; api.py:3124-3126).

### 3.2 Tools (mcp_server.py:392-448; all read-only)

| tool | parameters (defaults) | answers |
|---|---|---|
| `list_meetings` | project?, person?, since?, until? (YYYY-MM-DD), limit=30 | list of meeting briefs (title, people, projects, summary) |
| `search_meetings` | query, project?, person?, organization?, since?, until?, limit=10 | `{understood, meetings}`: word hits, then meaning hits (needs the e5 query embedding) |
| `get_meeting` | meeting_id, include_transcript=false, from_minute?, to_minute? | invitees, speakers, projects, notes, my notes; transcript ≤400 lines (`TRANSCRIPT_LINES`) on request |
| `list_projects` | – | projects with description, count, people (≤8), latest |
| `get_project` | project (name or id) | description, meetings with summaries, people, next steps |
| `list_people` | – | people, meeting count, last meeting |
| `open_next_steps` | project?, person?, owner?, since? | next steps, newest first |

- Every tool is a thin wrapper over **webapp/api.py** functions (`list_meetings`, `get_meeting`,
  `list_projects`, search, …), so it depends on phase 3's domain port.
- **Access log**: `~/Library/Application Support/palaver/mcp-access.jsonl`, never rotated. One line
  per call with tool, short args, counts, meeting ids (≤100), ms and error (mcp_server.py:286-354;
  mcp_access.py:79-185).
- **Heartbeat**: `…/palaver/mcp/<pid>.json` every 30 s, fresh for 120 s (mcp_access.py:187-341).
- Both files are read by the window.

## 4. Integrations

### 4.1 Notion (write-only)

| item | detail |
|---|---|
| Enabled | only with a token; `notion_auto_sync = bool(token) and [notion].auto_sync` (default true) (config.py:123-158) |
| Token | `NOTION_TOKEN`: env, then config.toml `[notion].token`, then Keychain `palaver`/`meeting-transcribe` |
| Effect on the daemon | auto_sync → the app launches `palaver run` (process + notes + sync) instead of `process --no-notes` then `notes` (Launch.swift:298-306). The queue's done marker becomes `notion.json`. |
| How Swift learns it | `palaver app query notion-auto-sync` (app_query.py:63-67; Launch.swift:184-252, cached in Application Support), because only Python reads the Keychain token |
| API | `https://api.notion.com/v1`, `Notion-Version: 2022-06-28` (notion_client.py:14-15) |
| Calls | `GET /databases/{id}` (schema, database mode); `POST /pages` with the first 100 blocks; `PATCH /blocks/{page}/children` 100 at a time (notion_client.py:130-197) |
| What it writes | one paragraph block per readable utterance: **bold speaker**, ` [HH:MM:SS]`, text (:25-56). Title from `render.build_meeting_title`. Database columns are matched by type + keyword (date/datum, duration/dauer, speaker/teilnehmer, source/quelle) (:59-100). **Notes are not uploaded**, only the transcript. |
| Retries | 429/502/503/504 only, 0.5/1/2 s, Retry-After ≤30 s; connection errors only when never sent (:18-22, 199-228) |
| Output | `notion.json` `{page_url, uploaded_at}` (cli.py:1166-1168); session events `notion_upload_start/_done`; notification "Uploaded to Notion" |
| Doctor | `GET /users/me` and the page/database (doctor.py:62-79) |
| Read use | none (`bench.py` reads Notion AI transcripts from local `.txt` files, not the API) |

### 4.2 Calendar (EventKit)

- **Swift today**: authorization status and request only (native/Sources/Palaver/Calendar.swift).
  **No Swift code reads events.**
- **Python reads events** (`calendar_eventkit.events_between`, PyObjC) in:
  - `process`/`run`, to attach the event (cli.py:785-806);
  - `palaver calendar attach [--since H]`, started by the Swift app every 5 min while connected
    (Housekeeping.swift:120-147 → app_update.py:174-190);
  - `app query next-event` / `event-key` (continuation ±2 h, the coach context; app_query.py:44-62;
    Launch.swift:176-180);
  - the web server (upcoming meetings / prep, next question; webapp/__init__.py:103-106).
- **Matching logic**: `calendar_events.py` (378 lines; attribution, `ask`, invitees). This is domain
  logic, so phase 3.
- **The EventKit read itself is unassigned.** It is small; it fits phase 3 with the server, or the
  app.

### 4.3 Search embeddings

| item | value |
|---|---|
| Model | `intfloat/multilingual-e5-small`, revision `614241f622f53c4eeff9890bdc4f31cfecc418b3` (embeddings.py:26-27) |
| Files | `config.json`, `sentencepiece.bpe.model`, `model.safetensors` (:28). 470 MB snapshot (the "470 MB" in the menu); the vocabulary is most of it (250k × 384). |
| Download | `hf_hub_download(..., revision)` into the HF cache. Triggered by the first `palaver index` or by setup (`python -m palaver.onboarding download e5`, onboarding.py:1395-1405). Queries never download. |
| Architecture | stored as BERT (positions from 0); XLM-R vocabulary with the fairseq id offset (`piece+1`, unk→3, BOS 0, EOS 2); 12 layers, 12 heads… mean-pooled, L2-normalised; GELU via `scipy.special.erf` (:76-158) |
| Runtime | hand-written numpy over a memory-mapped safetensors; SentencePiece tokenizer (~60 MB vs ~300 MB for `tokenizers`) |
| Prefixes | `"query: "` and `"passage: "` |
| Limits | 512 tokens, batch 8 |
| Index | per meeting: `search-index.npy` (float16 rows, 384 dims), `search-index.json` `{model, chunks:[{kind, text, heading?, owner?, speaker?…}]}`, `search-index.sig` `{model, sources:{file: mtime_ns}, count}` written last, `search-index.failed` (semantic.py:34-40, 163-181) |
| Chunks | summary, decisions, steps, section points; transcript runs of one speaker ≤80 words, ≥8 words (:42-43, 119-157) |
| Scoring | `MIN_SCORE` 0.78, `MARGIN` 0.06 over the median, `SMALL_SCORE` 0.80 under 100 pieces, 3 hits/meeting (:44-56) |
| Who runs it | `palaver index` (daemon, background QoS, idle only, ≥1 GB free; Launch.swift:319). Queries run in the **web server** (`semantic.Searcher`, api.py:1964) and in **`palaver mcp`** (search_meetings). The encoder is dropped after 300 s idle. |
| Memory | index peak ~240 MB footprint (semantic.py:58) |

Phase 3 owns search but needs the query encoder. **Unless phase 3 ports the encoder, its Swift
server must call Python for query vectors**, so this boundary should be settled first (§7).

## 5. Every Python process still in use after phase 2

Launch sites in Swift:

- `Launch.swift:298-319` (workers): `<palaver-python> -m palaver <opts> <cmd> <folder>` under
  `/usr/sbin/taskpolicy -c <qos>`, `spawnWorker` (Workers.swift:17).
- `WebSupervisor.swift:231-235`.
- `HelperJobs.swift:76`.
- `Housekeeping.swift:31, 41, 145`.
- `UpdateBackend.swift:32-70` (`pythonCommandBlocking`, PythonCommand.swift).
- `Launch.swift:95-193` (`pythonQueryBlocking`, PythonQuery.swift).
- `TestRecording.swift:209-240`.
- `LegacyLauncher.swift` (`PALAVER_LEGACY_APP=1`: the whole Python menu bar).

The Python host is `Contents/MacOS/palaver-python` (AppEnvironment.swift:44, 66).

| process / command | launched by | what it does | Swift today | owner |
|---|---|---|---|---|
| `webapp-serve` | WebSupervisor.swift:234 | the window's HTTP API | supervisor, port, key, handshake | **3** |
| `process <folder> --no-notes` / `run <folder>` | Launch.swift:305-306 | promote `.part`, join parts (continuation), **AEC** (aec.py), transcribe system (engine or **cloud ASR**) and mic (engine), diarize (engine), cleanup filters (`drop_silent_segments`, `drop_bleed_duplicates`, `drop_echo`), merge, calendar attach, shared-mic signals, voice recognition, live names, inference, `transcript.json`/`.md`, coach baseline, then notes and projects (`run`), then Notion sync (`run`) (cli.py:264-322, 542-782, 1124-1177) | palaver-engine does transcribe/diarize/embed; queue, retries and exit codes 3/4 are in the daemon | **unassigned**: orchestration and AEC (spec: AEC "moves with the live worker"); speakers, voices and inference are 3; notes, projects, Notion and cloud ASR are 4 |
| `notes <folder>` | Launch.swift:314 (daemon), HelperJobs `notes <folder> --force` | §1 | memory gate (asks `notes-memory`), watchdog budget | **4** |
| `projects --no-wait suggest\|describe <id>` | HelperJobs.swift:64-76 | §1.3 | job record `.jobs/<kind>-<key>.json` | **4** (the store is 3) |
| `next-question <folder>` | **web server** (webapp/__init__.py:75), stdin JSON | §1.3 | the watchdog watches it via app.sock `watch` | **4** |
| `index` | Launch.swift:319 | §4.3 | idle and memory gating; `index-stale` query | **4** |
| `live <folder>` | Launch.swift:316 | AEC as a stream (`AecStream`), ~1-min blocks to the engine, `LiveEngineDiarizer`; writes mic.wav, segments, turns, embeddings, live.json, speakers_live.json; `live.pid` (live.py; cli.py:380-412) | the engine does the models | **unassigned** |
| `stream <folder>` | Launch.swift:317 | `transcribe_window` sliding window, local agreement, echo-word drop, questions; `stream.json`, `stream.pid` (stream.py, stream_engine.py) | the engine has `transcribe_window` | **unassigned** |
| `coach <folder>` | Launch.swift:318 | live coach: VoiceMonitor (voice_activity.py, no model), nudges, `coach.json` (cli.py:455-473) | the daemon reads coach.json | **3** (phase 2 design :46-50) |
| `app query missing-models\|index-stale\|notes-memory\|next-event\|event-key\|notion-auto-sync` | Launch.swift:95-193 | facts (app_query.py) | caches answers | each with its feature: models 4 (downloads), index 4, notes 4, events 3/unassigned, notion 4 |
| `app housekeeping [--hourly]` | Housekeeping.swift:31, 41 | `storage.drop_retired` (HF cache), `mcp_access.migrate`, `updater.prune_runtimes`; hourly `drop_old_audio` (app_update.py:151-171) | scheduling only | **unassigned** (MCP migrate: 4) |
| `calendar attach [--since H]` | Housekeeping.swift:145 | attach events, refresh voice recognition (app_update.py:174-190) | 5-min retry, auth | 3 / **unassigned** |
| `app update check\|status\|download\|prepare\|commit`, `app uninstall-start` | UpdateBackend.swift:32-70 | manifest fetch, sha256 staging, runtime unpack, swap.sh, uninstall script (updater.py, release.py, downloader.py, uninstall.py) | state machine, idle gate, started-ok | **unassigned**, and it must change for a release without a runtime (§7) |
| `onboarding analyze <wav> [--system] --checks` | TestRecording.swift:211 | levels, mic transcription via the engine, verdict (onboarding.py:674-713, 879-912) | capture | **unassigned** (small: levels + engine call) |
| `python -m palaver.onboarding download <id> <repo>` | web server Downloads (onboarding.py:1219) | `snapshot_download` (gemma) or the e5 files; the speech models go through the engine's `prepare` | – | **4** (model downloads), UI in 3 |
| `mcp` | Claude Code / Desktop | §3 | – | **4** |
| `doctor` | user, in Terminal (the menu and window point to it) | 8 checks incl. Notion, speech models, AEC lib, mic (doctor.py) | – | **unassigned** |
| `report create\|open\|usage` | web server `/api/report` (server.py:508) and CLI | zip with logs, settings (secrets redacted, values scrubbed), daemon.json, HF cache scan, crash reports (report.py) | – | **unassigned** (`create` with the server, 3; `open`/`usage` are maintainer tools) |
| user CLI: `list`, `rename`, `export`, `import`, `voices`, `prune`, `sync`, `bench`, `bench-live`, `record`, `daemon`, `app install\|autostart\|restart-web\|ping\|uninstall` | `~/.local/bin/palaver` → `Resources/bin/palaver` → palaver-python (install.sh:315-321, app_bundle.py:447-449) | developer and tester tools | – | **unassigned**: drop, or a Swift `palaver` CLI |
| `menubar` (legacy) | LegacyLauncher.swift, `PALAVER_LEGACY_APP` | the whole Python app | – | delete in phase 4 |
| `stage` events / `usage.jsonl` | Python workers and Swift (`UsageLog`, Launch.swift:281) | append-only usage | Swift writes its own events | goes with each worker |

## 6. Python dependencies still in the runtime

The runtime is Python 3.13 (python-build-standalone), 133 locked packages. Its id is checked by
`import mlx.core, rumps, mlx_lm` (tools/build_release.py:244).

| package (locked) | used by | after phase 3 | Swift equivalent |
|---|---|---|---|
| mlx 0.32.4, mlx-metal | mlx-lm; `live` cache limit (cli.py:415) | 4 | mlx-swift (needs `xcodebuild` for Metal shaders) |
| mlx-lm 0.32.2 (+ transformers 5.21, tokenizers, jinja2, safetensors, protobuf, sentencepiece) | notes.py:532 | 4 | mlx-swift-lm 3.32.3 (`MLXLLM`, `MLXLMCommon`) + swift-transformers Tokenizers (spike: same token ids) |
| mlx-whisper 0.4.3 (+ numba, llvmlite, tiktoken, torch overridden away, pyproject.toml:69-72) | transcriber.py:66, only when `[model].transcriber = "mlx-whisper"` | **unassigned** | drop the option (Parakeet in the engine is the default) |
| huggingface-hub 2.3.0 (+ hf-xet, httpx2, fsspec, filelock, tqdm) | onboarding downloads/scan, embeddings, doctor, report | 4 | swift-huggingface (`HubApi`) or plain HTTPS GETs of `resolve/<rev>/<file>` |
| sentencepiece 0.2.2 | embeddings tokenizer | 4 | swift-transformers (tokenizer.json, Unigram), or a small SentencePiece port; ids must match |
| scipy 1.17.1 | `erf` in embeddings; `linkage`/`fcluster` in people.py:117 | 4 / 3 | Foundation `erf`; hierarchical clustering by hand (phase 3) |
| numpy 2.4.4 | 24 modules: audio, embeddings, voices, AEC, etc. | all | Accelerate / vDSP / MLX |
| mcp 2.3.0 (+ pydantic, starlette, uvicorn, sse-starlette, anyio, httpx2, jsonschema, typer) | mcp_server.py:383 | 4 | `modelcontextprotocol/swift-sdk` (official; stdio server transport, tools API) |
| keyring 25.7.0 (+ jaraco.*) | keychain.py, config.py:65, app_bundle.py:524 | 4 | Security.framework `SecItem*` (generic password, service `palaver`) |
| requests 2.33.1 | notion_client.py, doctor.py | 4 | URLSession |
| soundfile 0.13.1 (libsndfile) | 14 modules; FLAC for cloud ASR | 3/4/unassigned | AVAudioFile (WAV, FLAC) |
| soxr 1.1.0 | cloud ASR resample, exchange, transcriber | 4 / 3 | AVAudioConverter (the Swift capture already resamples) |
| wordfreq 3.1.1 (+ ftfy, langcodes, msgpack, regex) | glossary.py | 3 | ship the Zipf tables as a data file |
| rapidfuzz 3.14.6 | glossary, coach, bench | 3 | a small Levenshtein/ratio port |
| rumps 0.4.0, pyobjc-* (Cocoa, AVFoundation, CoreAudio, ScreenCaptureKit, CoreMedia, WebKit, EventKit, Vision, Quartz, CoreML) | legacy menubar, EventKit reads, my-notes OCR (Vision), doctor | 3/unassigned | native frameworks |
| ctypes + `libraven_aec.dylib` (built by `make aec`, CMake) | aec.py | unassigned | the same C library linked from Swift (spike: identical output) |

## 7. Tests and evaluation

Python suite: 1986 test functions in `tests/test_*.py`, plus 227 Playwright e2e in `tests/e2e/`.

**LLM and providers** (phase 4)

| file | tests |
|---|---|
| test_notes.py | 52 |
| test_llm.py | 18 |
| test_cloud_llm.py | 27 |
| test_providers.py | 21 |
| test_keychain.py | 5 |
| test_access_log.py | 5 |
| test_next_question.py | 10 |
| test_projects.py | 16 (rules and model mixed) |
| test_setup_api.py | 37 (recommendations, downloads, LLM choices) |
| test_onboarding.py | 63 |
| js language-model.test.mjs | 7 |
| e2e test_notes.py | 7 |
| e2e test_setup.py | 15 |

**Integrations** (phase 4)

| file | tests |
|---|---|
| test_notion_client.py | 12 |
| test_mcp_server.py | 15 |
| test_mcp_access.py | 29 |
| js mcp.test.mjs | 9 |
| test_semantic.py | 17 |
| test_embeddings.py | 6 (golden files `tests/fixtures/tiny_embedder`, made by `tools/make_embedder_fixture.py` with torch and transformers) |
| test_search_api.py | 18 |
| test_cloud_asr.py | 25 |
| test_transcription.py | 37 |
| test_app_query.py | 14 |

**Unassigned processes**

| file | tests |
|---|---|
| test_cli.py | 41 |
| test_pipeline_e2e.py | 2 |
| test_aec.py | 9 |
| test_live.py | 10 |
| test_stream.py | 19 |
| test_stream_engine.py | 14 |
| test_stream_bench.py | 20 |
| test_engine.py | 19 |
| test_diarizer.py | 7 |
| test_transcriber.py | 13 |
| test_cleanup.py | 14 |
| test_merger.py | 10 |
| test_cutting.py | 29 |
| test_continuation.py | 17 |
| test_attribution.py | 38 |
| test_calendar_events.py | 16 |
| test_app_update.py | 24 |
| test_updater.py | 35 |
| test_update_api.py | 5 |
| test_release.py | 15 |
| test_downloader.py | 3 |
| test_uninstall.py | 9 |
| test_install_sh.py | 11 |
| test_runtime_requirements.py | 1 |
| test_app_bundle.py | 16 |
| test_doctor.py | 18 |
| test_report.py | 17 |
| test_report_api.py | 5 |
| test_report_cli.py | 5 |
| test_usage.py | 8 |
| test_storage.py | 16 |
| test_model_jobs.py | 9 |
| test_model_store.py | 12 |

**Coach** (phase 3 per the phase 2 design)

| file | tests |
|---|---|
| test_coach.py | 13 |
| test_coach_review.py | 10 |
| test_coach_worker.py | 8 |
| test_live_coach.py | 25 |
| test_live_coach_api.py | 13 |
| test_daemon_coach.py | 9 |
| test_voice_activity.py | 25 |
| e2e test_live_coach.py | 7 |

**Evaluation tooling**

- `make eval-engine` (`tools/eval_engine.py`): the speech engine's gate (WER, diarization). It
  covers no LLM.
- `tools/echo_bench.py`: AEC.
- `palaver bench` / `bench-live`: transcripts against Notion AI's.
- `~/Meetings/Benchmarks/2026-11-03-swift-spike/` (report.md "Local notes model from Swift";
  `scripts/llmspike-*.swift`): one meeting, 10 379 prompt tokens.
- **There is no notes-quality evaluation in the repo.** The Gemma choice rests on a hand count:
  "about 6 errors in 5 meetings vs 21 for Qwen3" (notes.py:33-35; commit 016226e). There is no
  script, gold set or score.

## 8. Risks

| # | risk | evidence | mitigation to decide |
|---|---|---|---|
| 1 | **Notes output drifts with the runtime.** Greedy outputs diverged after 33 tokens (80 % overlap) on one meeting; production samples at temp 0.2, so runs differ anyway. With no notes eval there is no gate. | spike report.md:64-80; notes.py:552-553 | Build a small notes eval before the switch: N real meetings, compare mlx-lm vs mlx-swift-lm on title, steps and owners, decisions and `speaker_names`, and parse failures. Keep `parse_notes` repairs byte-for-byte. |
| 2 | **Prompt bytes must match.** `json.dumps(schema)` (separators, key order, `ensure_ascii` escapes such as `—`) is in the system text; `JSONSerialization` differs. | notes.py:538-541, projects.py:372-376 | A golden-prompt test: the Swift prompt equals the Python prompt for fixtures (notes with and without my notes, shared lanes, projects, next question). |
| 3 | **Chat template and tokenizer parity.** The Gemma 4 template branches on a system message and `enable_thinking`. The spike matched token ids with `additionalContext: ["enable_thinking": false]`, but only on one prompt. | spike `llmspike-main.swift:29`; chat_template.jinja | Make token-id equality a unit test on fixtures; pin mlx-swift-lm and swift-transformers. |
| 4 | **Memory.** Without `Memory.cacheLimit` Swift reached 15.8 GB (Python 11.9). Python's notes run has no cache limit, but stays ~12 GB. The watchdog budget for notes is 14 GB. | spike; notes.py:40-45 | Set cacheLimit (1 GB tested). Keep the model in a **separate worker process** (like palaver-engine), not in the app, so the watchdog can kill and requeue it and its memory is freed. |
| 5 | **Model file reuse.** The 8.3 GB Gemma and the 470 MB e5 sit in the Python HF cache layout (`~/.cache/huggingface/hub/models--…/snapshots/<rev>`). The spike loaded Gemma with `ModelConfiguration(directory:)`. swift-transformers' `HubApi` defaults to a different base folder. | onboarding.py:915-958; spike main.swift:19-21 | Resolve the snapshot directory ourselves (refs/main → snapshots/<hash>) and pass `directory:`. Keep onboarding's `complete()` and `cached_bytes()` semantics. Never download twice. |
| 6 | **OptiQ mixed-precision quantization** (per-layer 4/8 bit, `kv_config.json`) needs mlx-swift-lm support for per-layer quant overrides and the `gemma4_unified` architecture. 3.32.3 worked in the spike; a version bump could break it. | config.json, optiq_metadata.json | Pin the version; add a load smoke test in CI (needs the model: run it locally only). |
| 7 | **Build toolchain.** MLX Metal shaders need `xcodebuild`; the Makefile builds with `swift build`, and this Mac has only the Command Line Tools. | Makefile:53-60; spike report.md:80 | Move the app/LM targets to xcodebuild, locally and in CI, before phase 4 starts. |
| 8 | **Embeddings parity.** The encoder is custom numpy: BERT positions from 0, the fairseq id offset, SentencePiece ids. MLXEmbedders' BERT path may not match the offset and tokenizer. Existing `search-index.npy` files are float16 from numpy. | embeddings.py:80-158 | Port the 12-layer encoder directly (Accelerate or MLX). Gate on `tests/fixtures/tiny_embedder` plus real-model cosine ≥0.999 against Python. Otherwise change the `model` string in `search-index.sig` to force a reindex (seconds per meeting). The `.npy` reader is trivial. |
| 9 | **Search crosses phases.** Phase 3's Swift server and the MCP server need the query encoder; phase 4 owns embeddings. | api.py:1964; mcp `search_meetings` | Move the encoder into phase 3, or keep a tiny Python query helper until phase 4. Decide now. |
| 10 | **MCP in Swift.** The official `modelcontextprotocol/swift-sdk` exists (stdio server, tool handlers), but its API is younger than Python's. The tools wrap phase 3's API functions; middleware (clientInfo) and the access log must be rebuilt. | mcp_server.py:357-390 | Golden tests on tool JSON (args, outputs, local-only hiding); compare `tools/list` schemas with Python's. |
| 11 | **Existing Claude configs point at `Resources/bin/python -m palaver mcp`.** Removing Python breaks every tester's Claude Code/Desktop entry. `migrate()` detects only stale venv paths. | mcp_access.py:356-375, 477-494; app_bundle.py:443-450 | Keep a `Resources/bin/python` shim that execs the Swift MCP binary when the args end in `mcp`, and/or extend `migrate()` to rewrite entries to the new binary. Desktop must be reopened. |
| 12 | **Keychain ACLs.** Keys written by `palaver-python` via keyring. A different signed binary reading them may trigger a prompt per item (config.py:104-105 already avoids reads for this reason). | config.py:100-106; keychain.py | Read once in Swift with the same service and account; accept one "Always Allow"; test on a tester-like install. |
| 13 | **The update path to a runtime-less release.** Installed updaters (Python `release.parse_manifest`) reject a manifest without a valid `runtime.id`; install.sh errors "names no valid runtime"; swap.sh of the old version runs the swap. | release.py:129-133, 207-219; install.sh:246-262; updater.py:556-566 | The first Python-free release still names the current runtime id (already installed → nothing downloaded), and a later release stops naming it once all testers run the Swift updater. Smoke-install from 0.5.x. Prune the runtime folder afterwards. |
| 14 | **Unassigned work is large.** `process`/`run` orchestration, AEC, `live`, `stream`, updater, uninstall, doctor, report, onboarding analyze/downloads, the user CLI and housekeeping: ~6 000 lines of Python with ~450 tests. Nothing in phases 3 or 4 owns them. | §5 | Add a phase (or widen 3/4) explicitly; the `live` and `stream` workers, with AEC, are the biggest. |
| 15 | **Long transcripts.** No chunking: >~390 k chars is refused locally (131 072 tokens × 3 chars). Behaviour must stay identical (refuse, never cut). | llm.py:44, 223-228 | Port `_fits` as is. |
| 16 | **Cross-process model lock.** `notes.lock` (flock) serialises notes, projects and next-question across processes. While Python and Swift coexist, both must take it. | cli.py:809-850 | Swift uses the same file and `flock`; exit 75 semantics are kept for helpers. |
| 17 | **Notes-gated features read Python state.** `notes-memory`, `missing-models` and `index-stale` are Python queries today. | app_query.py | Port them with their features; they are small. |
| 18 | **mlx-whisper option.** Users with `[model].transcriber = "mlx-whisper"` lose it. | transcriber.py:162-180 | Drop it, and map it to parakeet with a log line (as `parakeet-mlx` already is). |

## 9. Spec gaps to settle before the phase 4 design

1. Who owns `process`/`run` orchestration, AEC, `live` and `stream`. The phase 2 design ties AEC to
   "the live worker", which no phase names.
2. Who owns the updater/uninstall back end (`app update …`), doctor, report, onboarding analyze,
   housekeeping, and the `palaver` CLI that testers use.
3. Whether the query encoder moves in phase 3 (search) or phase 4 (embeddings).
4. Whether Notion stays: it uploads only transcripts, never notes, and needs a Keychain token.
5. Where the LLM runs: a separate `palaver-lm` worker binary (recommended, §8 #4) or inside the app.
6. Cloud ASR: phase 4 (with providers) or with the `process` pipeline.
