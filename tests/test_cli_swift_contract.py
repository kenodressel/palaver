"""Contract: the Swift `palaver` command (native/Sources/PalaverServer/CLI, phase 4 batch 8) and cli.py.

Both run as programs on the same temporary home, config dir and recordings: what testers paste (`list`,
`daemon status`) and what the other in-process commands say (`voices`, `prune --dry-run`) is the same, with
the same exit codes; every command of cli.py is either one the Swift command has, or it says in one line
what replaces it and exits 2. Build it with `make parity-helper` (``make test`` builds it too).
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from palaver.cli import command_names

CLI = Path(__file__).resolve().parent.parent / "native" / ".build" / "debug" / "palaver-cli"

pytestmark = pytest.mark.skipif(not CLI.exists(), reason="palaver-cli not built: run `make parity-helper` (or `make test`)")

# The commands the Swift `palaver` has (Usage.CLI_COMMANDS).
KEPT = {"app", "daemon", "doctor", "export", "import", "index", "list", "mcp", "notes", "process", "projects", "prune",
        "report", "run", "sync", "voices"}


def _world(tmp_path: Path) -> tuple[dict, Path, Path]:
    """A home, a config dir and config.toml naming its recordings folder."""
    home, config_home, rec = tmp_path / "home", tmp_path / "cfg", tmp_path / "home" / "rec"
    home.mkdir()
    config = tmp_path / "config.toml"
    config.write_text(f'[user]\nname = "Timo"\n[recording]\noutput_dir = {json.dumps(str(rec))}\nretention_days = 14\n'
                      "[calendar]\nenabled = false\n")
    env = {"HOME": str(home), "PALAVER_HOME": str(home), "XDG_CONFIG_HOME": str(config_home), "PATH": "/usr/bin:/bin",
           "PALAVER_TEST_QUIET_MAC": "1"}
    return env, config, rec


def _both(env: dict, args: list[str]) -> tuple[tuple[int, str], tuple[int, str]]:
    """(exit code, stdout) of cli.py's and of the Swift command's run of `args`."""
    py = subprocess.run([sys.executable, "-m", "palaver", *args], env={**os.environ, **env}, capture_output=True,
                        text=True, timeout=60, stdin=subprocess.DEVNULL)
    sw = subprocess.run([str(CLI), *args], env=env, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    return (py.returncode, py.stdout), (sw.returncode, sw.stdout)


def _folder(rec: Path, name: str, *files: str, start: str | None = None) -> Path:
    folder = rec / name
    folder.mkdir(parents=True)
    for f in files:
        (folder / f).write_text("{}" if f.endswith(".json") else "x")
    if start:
        (folder / "meta.json").write_text(json.dumps({"start_time": start}))
    return folder


def test_list_says_the_same_of_every_folder(tmp_path):
    env, config, rec = _world(tmp_path)
    py, sw = _both(env, ["--config", str(config), "list"])
    assert py == sw == (0, "(no recordings yet)\n")
    _folder(rec, "2026-10-20T09-00-00")
    _folder(rec, "2026-10-21T09-00-00", "mic_raw.wav", "system.wav")
    _folder(rec, "2026-10-22T09-00-00", "transcript.json")
    _folder(rec, "2026-10-23T09-00-00", "transcript.json", "notion.json")
    _folder(rec, "2026-10-24T09-00-00", "system.wav.part")  # still growing: a recording
    (rec / "notes.txt").write_text("not a folder")
    py, sw = _both(env, ["--config", str(config), "list"])
    assert py == sw and py[1].count("\n") == 5


def test_daemon_status_is_the_same_line(tmp_path):
    env, config, rec = _world(tmp_path)
    assert _both(env, ["daemon", "status"]) == ((0, "daemon has never run\n"),) * 2
    state = Path(env["HOME"]) / "Library" / "Application Support" / "palaver" / "daemon.json"
    state.parent.mkdir(parents=True, exist_ok=True)
    state.write_text(json.dumps({"pid": os.getpid(), "state": "recording", "since": "2026-11-08T10:00:00+01:00",
                                 "folder": str(rec / "2026-11-08T10-00-00"), "queued": ["a"], "talk_text": "Timo 60%"}))
    py, sw = _both(env, ["daemon", "status"])
    assert py == sw and py[1].startswith(f"daemon running (pid {os.getpid()}): recording since ")
    state.write_text(json.dumps({"pid": 999999, "state": "idle", "updated": "2026-11-08T11:00:00+01:00"}))
    py, sw = _both(env, ["daemon", "status"])
    assert py == sw == (0, "daemon not running (last update 2026-11-08T11:00:00+01:00)\n")


def test_voices_and_forgetting_one_say_the_same(tmp_path):
    env, config, rec = _world(tmp_path)
    voices = Path(env["XDG_CONFIG_HOME"]) / "palaver" / "voices"
    voices.mkdir(parents=True)
    for slug, name, n in (("rico", "Rico", 1), ("valerie", "Valerie", 2)):
        samples = [{"embedding": [1.0, 0.0], "source": f"2026-10-2{i}T09-00-00:SPEAKER_00", "added": "2026-10-20"} for i in range(n)]
        (voices / f"{slug}.json").write_text(json.dumps({"name": name, "samples": samples}))
    py, sw = _both(env, ["voices"])
    assert py == sw == (0, "Rico  (1 sample)\nValerie  (2 samples)\n")
    py, sw = _both(env, ["voices", "forget", "Nobody"])
    assert py == sw == (1, "No stored voice for Nobody.\n")
    assert _both(env, ["voices", "forget"]) == ((2, "usage: palaver voices forget <name>\n"),) * 2


def test_prune_dry_run_plans_the_same(tmp_path):
    env, config, rec = _world(tmp_path)
    _folder(rec, "2020-01-01T10-00-00", "notion.json", "mic_raw.wav")
    _folder(rec, "2020-01-02T10-00-00", "mic_raw.wav", start="2020-01-02T10:00:00+01:00")
    _folder(rec, "2099-01-01T10-00-00", "notion.json")
    py, sw = _both(env, ["--config", str(config), "prune", "--dry-run"])
    assert py == sw and "would delete 2020-01-01T10-00-00 (0 MB)" in py[1] and py[0] == 0
    assert (rec / "2020-01-01T10-00-00").is_dir()


def test_every_command_of_cli_py_is_kept_or_says_what_replaces_it(tmp_path):
    env, _, _ = _world(tmp_path)
    for name in command_names():
        if name in KEPT:
            continue
        r = subprocess.run([str(CLI), name], env=env, capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
        assert r.returncode == 2 and r.stdout == "", name
        assert len(r.stderr.splitlines()) == 1 and r.stderr.startswith(f"palaver {name}"), (name, r.stderr)
    for action in ("query", "housekeeping", "update", "uninstall-start"):
        r = subprocess.run([str(CLI), "app", action], env=env, capture_output=True, text=True, timeout=30,
                           stdin=subprocess.DEVNULL)
        assert r.returncode == 2 and r.stderr.startswith(f"palaver app {action} is gone"), (action, r.stderr)
    help_text = subprocess.run([str(CLI), "--help"], env=env, capture_output=True, text=True, timeout=30).stdout
    assert all(f"\n  {name} " in help_text for name in KEPT)
