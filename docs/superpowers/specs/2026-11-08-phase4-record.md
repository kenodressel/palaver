# Phase 3 and 4 record: rulings, gates, open items

Written 2026-11-11 from the controller's notes after the SDD workspaces (git-ignored `.superpowers/`)
were lost with their worktrees. The code of every branch is in master; this file keeps the decisions
and results that only lived in those workspaces. Numbers only, no meeting content.

## Keno's rulings

- 2026-11-07: **feature parity, not byte parity.** Same features, existing files read and written in
  the same formats; no emulation of Python/numpy quirks, no golden files of Python output.
- 2026-11-08: **the release contains no Python.** Python stays only as a local developer fallback
  (legacy-server marker / `PALAVER_LEGACY_SERVER=1`, from a checkout's `.venv` only).
- Phase 4 answers: `palaver record` and `palaver rename` dropped; one-release `bin/python` shim that
  forwards old Claude MCP entries; every older version updates in-app (placeholder runtime, below).
- 2026-11-08: keep the 1 s grace in `ModelJobs.wait`; live-transcribed words keep their confidence
  (unsure marks, as `process` already did).

## Controller rulings

- Meaning-search scores in Float32 as numpy computes them (parity with Python).
- Python `sum()` over floats is Neumaier-compensated: use `Py.sum`. Found visible differences in coach
  minutes, shared-mic detection and people totals.
- In-process locks (projects, glossary, my notes) are taken where api.py takes them, always before a
  StoreLock; `Undo.restore` never runs under a StoreLock; rollback of a failed change holds the
  projects lock (a concurrent change could otherwise be overwritten).
- StoreLock keys are the realpath of the folder (`/var` vs `/private/var` deadlocked cut/join/trash).
- No automatic fallback to Python in a release (withdrawn after Keno's 2026-11-08 ruling).
- Hardened runtime stays off for 0.6.x (0.5 never had it; untested on a real start). The entitlements
  file is kept for later notarization.
- Keychain: keys are copied once into service `palaver.v2` with an access list of all Palaver programs;
  the Python item is never deleted. Measured on a temporary keychain: after one read every signed
  program reads silently, also after re-signing with a new cdhash.
- Plain `http://` only for local-network gateways (localhost, `.local`, `.lan`, `.home.arpa`, private
  IPs); public hosts https-only.
- System-audio permission judged as Python does (newest recording's session.log).
- `palaver-lm` ships in the bundle (no Python fallback in worker/server); its memory watchdog follows
  Python: budget max(model need, `[memory] notes_gb`), stop only when free memory stays under 1.5 GB,
  hard ceiling ×1.5.
- `$HOME` is honoured like Python (stores home: `PALAVER_HOME`, else `$HOME`, else the account home).
- Call end (0.6.0rc2): the recorded app stays the call while it is in it (a Slack call during Teams no
  longer cuts it); an app that drops to mic-only (no speaker) counts as hung up; grace 10 s → 5 s.
  From Keno's log: hang-up → stop went from ~19 s to ~5 s.

## Update path

- Every published release from 0.1.0 to 0.5.0rcN has an updater that only checks that the runtime
  archive contains `<id>/bin/python3` and that runtime.json names the id; none runs it. 0.6 ships a
  238-byte placeholder runtime `no-python-1`. Every future manifest must keep that runtime block, and
  runtime.json must keep naming it, because old installs skip versions.
- The old Python runtime is deleted only after the new app started fine, `previous-app` is gone and
  update.json records no failed swap.
- Verified on Keno's Mac 2026-11-09: rc6 → 0.6.0rc1 through the real in-app updater, 3.3 GB freed.

## Gates (0.6.0rc1)

- Gate 1: `make test` green; release build, smoke-install (fresh, 0.3.14 → 0.6, rc6 → 0.6, 0.6 → 0.6+1).
- Gate 2 (54 real meetings, on copies): 0 feature differences; 254 steps naming test-corpus meetings
  gave the same error on both sides, 11 differ only in error wording, 4 empty `.speakers.lock` files.
- Gate 3: eval-engine == eval-engine-worker == the 2026-11-04 baseline (WER 43.0 %; lost passages
  215 vs 198 and one speaker-count miss fail as before, accepted ruling R18).
- Long notes, real 84-min meeting, Gemma 12B: Python 196 s / 12.26 GB, Swift 200.8 s / 12.87 GB,
  both written; blind A/B 15.5 vs 15.5 of 20. A fictional 105-min transcript peaked at 16.75 GB.
- Gates 4/5 on Keno's Mac: 0.6.0rc1 running since 2026-11-09 without errors in the logs.

## Open items (not blocking)

- Notarization (Developer ID) and the hardened runtime.
- A keyless LAN Ollama still shows "Add the API key".
- Measure Parakeet Ultra vs v3 on meetings; FluidAudio streaming/Nemotron for live (from Sabbel #20/#34);
  CTC vocabulary boosting only for long distinct terms (Sabbel #22 → Palaver #14).
- Devices that reconfigure on every start (Insta360 case in Sabbel) could loop Palaver's mic follow
  logic; worth a test when such a device report comes in.
- zip64 for problem reports with more than 4 GB of audio.
- tools/memcap.sh caps phys_footprint (RSS missed MLX GPU memory).
