# Palaver in Swift, Phase 4: language models, integrations, no Python — Design

**Date:** 2026-11-04
**Status:** Draft for Keno's review
**Parent:** `2026-11-03-swift-migration-design.md` (phase 4 of 4)
**Inventory:** `2026-11-04-phase4-inventory.md`
**Depends on:** phase 3 (`2026-11-04-swift-server-phase3-design.md`): the
domain library, the server and the pipeline are Swift.

## Why

After phase 3 the Python runtime is only started for language models,
cloud services, Claude's tools and a few maintenance commands. Phase 4
moves those and removes Python from the app: no `palaver-python`, no
runtime archive, a smaller download and one language for the whole app.

## What changes

### Language models: a `palaver-lm` worker

- One Swift executable, `palaver-lm`, runs every generation: notes,
  project suggestions and descriptions, best next question. It is a
  separate process like `palaver-engine`, so the watchdog can stop it,
  requeue the job, and macOS gets the memory back.
- Local model: Gemma 4 12B (`mlx-community/gemma-4-12B-it-OptiQ-4bit`)
  through mlx-swift-lm, loaded **from the existing Hugging Face snapshot
  folder** (no second download). `Memory.cacheLimit` set (the spike
  reached 15.8 GB without it; the watchdog budget is 14 GB).
- Same prompts, schemas, sampling (temperature 0.2), 4096 max tokens,
  2 retries, parse and repair, the context check that refuses (never
  cuts) a meeting that does not fit, the `notes.lock` flock and exit 75.
- Builds with `xcodebuild` (MLX's Metal shaders need it); the Makefile
  and CI move the targets that link MLX.

**Gates** (inventory §8 risks 1–3, they decide whether the switch happens):
1. **Golden prompts:** the Swift prompt text equals Python's byte for byte
   for fixtures (notes with and without my notes, shared lanes, projects,
   next question), including `json.dumps(schema)`'s separators and
   `\uXXXX` escapes.
2. **Token ids:** the chat template plus tokenizer give Python's token ids
   on the same fixtures (`enable_thinking: false`).
3. **A notes eval, new:** `tools/eval_notes`, run locally on Keno's real
   meetings (reports stay local). *My call on scoring:* 10 meetings,
   3 Python runs and 3 Swift runs each.
   - Automatic: parse failures, schema-valid rate, next-step owners and
     speaker-name guesses that match the meeting's named speakers, and
     overlap of next steps and decisions (token F1 against each other run).
     The spread of Python-vs-Python sets the bar; Swift-vs-Python must be
     inside it, and parse failures must not rise.
   - Then a blind side-by-side review (A/B order shuffled per meeting) by
     Claude Opus in the Claude Code session that runs the migration. Keno
     chose this on 2026-11-04 instead of reading them himself. Opus reads
     the transcript and both notes of each of the 10 meetings and judges
     correctness, completeness, owners and names. The verdict and its
     reasons go into the local eval report. The notes never go to
     another service, and the report stays local.

If a gate fails, *my call:* the rest of phase 4 ships, and local notes
keep running Python mlx-lm as a helper (with the runtime) until the gate
passes. Removing Python is then the last step, after the LM worker.

### Cloud providers and keys

Anthropic Messages, OpenAI-compatible chat completions (also Cortecs and
similar), the `claude-cli` runner, and the cloud transcription adapters
(AssemblyAI, Soniox, Mistral, OpenAI-compatible) move to Swift on
URLSession: same retries, redaction, access log, the local-only rule
everywhere it is enforced today. API keys stay in the login Keychain,
same service and accounts; Swift reads them with Security.framework.
*My call:* testers may see one Keychain prompt per key after the update
("Always Allow"); the release notes say so.

### Notion upload

Stays, in Swift: transcript upload only, the same blocks, database
column matching, retries and `notion.json`. *My call:* it is 230 lines
and someone relies on it; dropping it would be a feature change.

### Claude's tools (MCP)

- `palaver-mcp`, a Swift executable on the official MCP Swift SDK
  (stdio): the same 7 read-only tools, schemas, instructions, access log
  and heartbeats, over the phase 3 domain.
- Existing Claude Code and Claude Desktop entries point at
  `Resources/bin/python -m palaver mcp`. Two things keep them working:
  `migrate()` (in housekeeping) rewrites Palaver's entries to
  `palaver-mcp`, and for one release `Resources/bin/python` stays as a
  shim that execs `palaver-mcp` when its arguments end in `mcp`.
- Gate: `tools/list` and the tool answers on fixtures equal Python's.

### Everything else that still runs Python

| today | after phase 4 |
|---|---|
| model downloads (`onboarding download`, `snapshot_download`) | Swift: plain HTTPS GETs of `resolve/<rev>/<file>` into the same HF cache layout, with progress and the `downloading-models` marker |
| updater back end (`app update …`), swap script, uninstall | Swift, same state file, manifest, staging, sha256, started-ok |
| `app housekeeping` (retired models, MCP migrate, runtime pruning, old audio) | Swift, in the app |
| `doctor`, `report` (Report a Problem zip) | Swift: `palaver doctor`, and the report built by the server |
| test recording analysis (`onboarding analyze`) | Swift: levels plus the engine |
| `palaver` CLI | a Swift `palaver` with the commands testers and docs use: `daemon status`, `app ping\|restart-web\|install\|uninstall`, `doctor`, `report`, `list`, `rename`, `export`, `import`, `voices`, `process`, `notes`, `sync`. *My call:* `bench` and `bench-live` stay developer tools in the repo, not in the app |
| mlx-whisper transcriber option | dropped; a config naming it runs Parakeet and logs that it did |
| the legacy Python app and server (`legacy-app`, `legacy-server`) | removed |

### Releasing without a runtime

Installed updaters (0.3.x–0.6.x) reject a manifest without a valid
runtime id. So:

1. The first Python-free release (0.7.0) still names the current runtime
   id. Every installed Mac has it, so nothing is downloaded; the new app
   simply never starts it.
2. Its own updater no longer needs a runtime. A later release stops
   naming it, and housekeeping deletes the old runtime folder (~600 MB).
3. `make smoke-install` checks the update from 0.6.x and from 0.3.14.

### Removing Python from the repo

At the end of phase 4 the `palaver/` package, its Python tests and the
runtime build leave the repo. Kept as developer tools: `tools/eval_*`,
the bench scripts, the parity harness's recorded fixtures. The README and
CONTRIBUTING describe a Swift-only build.

*My call:* developer tooling may stay Python, as standalone scripts under
`tools/` with their own `uv` dependencies, not importing an app package.
`build_release.py` and `smoke_install.sh` lose their runtime parts;
`eval_engine.py` and `echo_bench.py` call the Swift binaries; `bench` and
`bench-live` move to `tools/`.

## Not in phase 4

New features (#13–#18 land after the migration, in Swift).

## Gates before release (0.7.0)

1. The three language-model gates above.
2. Full test suite green (Swift, JS, e2e).
3. Claude Code and Claude Desktop use the tools after the update without
   the user doing anything (Desktop needs a restart).
4. Update from 0.6.x and from 0.3.14 through the in-app updater; the app
   starts no Python process (checked with `pgrep`).
5. A real call: recorded, processed, notes written by the Swift model,
   uploaded to Notion when enabled.

## Left to the builder

- The order: providers and keys first (smallest), then the LM worker
  behind its gates, then MCP, then the rest and the removal.
- Whether `palaver-lm` and `palaver-mcp` become subcommands of one binary.
