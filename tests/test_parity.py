"""The parity harness (phase 3): Python and the Swift port run the same operations on copies
of the same folders, and every file they write is diffed. Also the corpus every scenario
starts from, and the anonymized copy of real folders."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
import time
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from tools.parity import anonymize, corpus, diff, ledger_check, run

from .e2e.recordings import LIVE, build_recordings

ROOT = Path(__file__).resolve().parent.parent
SCENARIOS = sorted(p.stem for p in (ROOT / "tools" / "parity" / "scenarios").glob("*.json"))
BIN = ROOT / "native" / ".build" / "debug" / "palaver-parity"
NOW = datetime(2026, 11, 4, 9, 0, tzinfo=ZoneInfo("Europe/Berlin"))


@pytest.mark.parametrize("name", SCENARIOS)
def test_scenario(name, tmp_path):
    if not BIN.exists():
        if os.environ.get("CI") or os.environ.get("PALAVER_PARITY_REQUIRED"):
            pytest.fail(f"{BIN.relative_to(ROOT)} is missing: make parity-helper")
        pytest.skip(f"{BIN.relative_to(ROOT)} is not built (make parity-helper)")
    scenario = json.loads((ROOT / "tools" / "parity" / "scenarios" / f"{name}.json").read_text())
    differences = run.run_scenario(scenario, tmp_path, parity_bin=BIN, now=NOW)
    assert differences == [], "\n".join(str(d) for d in differences)


def test_ledger_is_complete():
    """Every test of a ported Python module is a Swift test or a line in the phase 3 ledger (Task 69)."""
    gone = ledger_check.missing()
    assert gone == [], "\n".join(gone)


def test_the_ledger_check_finds_a_test_written_nowhere(tmp_path):
    (tmp_path / "tests").mkdir()
    (tmp_path / "tests" / "test_webapp.py").write_text(
        "def test_ported():\n    pass\n\ndef test_ported_in_camel_case():\n    pass\n\n"
        "def test_written_down():\n    pass\n\ndef test_forgotten():\n    pass\n")
    swift = tmp_path / "Swift"
    swift.mkdir()
    (swift / "X.swift").write_text("@Suite struct X {\n    @Test func test_ported() {}\n"
                                   "    @Test(arguments: [1,\n                      2])\n"
                                   "    func portedInCamelCase(_ n: Int) {}\n    func test_forgotten() {}  // a helper, not a test\n}\n")
    ledger = tmp_path / "ledger.md"
    ledger.write_text("- `tests/test_webapp.py::test_written_down` — stays Python.\n")
    gone = ledger_check.missing(tmp_path, ledger, swift)
    assert [g for g in gone if "::" in g] == ["tests/test_webapp.py::test_forgotten"]


@pytest.mark.parametrize("name", SCENARIOS)
def test_scenarios_compare_the_calendar(name):
    scenario = json.loads((ROOT / "tools" / "parity" / "scenarios" / f"{name}.json").read_text())
    assert "events.json" in scenario["compare"]


# --- only on a parity side ------------------------------------------------------------


_MEETING = "2026-10-27T16-03-07"


def _sentinel_meeting(recordings: Path) -> Path:
    """A meeting the render op would write transcript.md into."""
    folder = recordings / _MEETING
    folder.mkdir(parents=True)
    (folder / "transcript.json").write_text(json.dumps([{"speaker": "A", "start": 0.0, "end": 1.0, "text": "Hallo."}]))
    (folder / "meta.json").write_text(json.dumps({"start_time": "2026-10-27T16:03:07+01:00", "duration_seconds": 10.0}))
    return folder


def _files(root: Path) -> list[str]:
    return sorted(str(p.relative_to(root)) for p in root.rglob("*"))


def _side(side: Path, output_dir: str | None) -> None:
    (side / "config" / "palaver").mkdir(parents=True, exist_ok=True)
    (side / "home").mkdir(parents=True, exist_ok=True)
    if output_dir is not None:
        (side / "config" / "palaver" / "config.toml").write_text(f"[recording]\noutput_dir = {json.dumps(output_dir)}\n")


def test_the_helper_refuses_to_run_outside_a_parity_side(tmp_path):
    """palaver-parity runs only when XDG_CONFIG_HOME and PALAVER_HOME are the side's config/ and home/, the side has
    its config.toml and config.toml's output_dir is inside the side. Otherwise it answers bad_args before the op
    runs: a meeting outside the side (the sentinel) is never written to, and a fake HOME is never touched. Where a
    broken check could reach the real home, the op is one that does not exist (a broken check answers unknown_op
    and still reads nothing outside the side)."""
    if not BIN.exists():
        pytest.skip(f"{BIN.relative_to(ROOT)} is not built (make parity-helper)")
    import pwd
    import subprocess

    real = Path(pwd.getpwuid(os.getuid()).pw_dir)
    side, fake_home, sentinel = tmp_path / "side", tmp_path / "fake-home", tmp_path / "sentinel"
    fake_home.mkdir()
    outside = _sentinel_meeting(sentinel / "Recordings")
    before = _files(sentinel), _files(fake_home)
    base = {k: v for k, v in os.environ.items() if k not in ("XDG_CONFIG_HOME", "PALAVER_HOME")}
    base["HOME"] = str(fake_home)
    tied = {"XDG_CONFIG_HOME": str(side / "config"), "PALAVER_HOME": str(side / "home")}

    def answer(op="no-such-op", **env):
        proc = subprocess.run([str(BIN), op, "--side", str(side)], env={**base, **env},
                              capture_output=True, text=True, timeout=60)
        return proc.returncode, json.loads(proc.stdout)

    def refused(op="no-such-op", **env):
        code, out = answer(op, **env)
        assert code == 1 and out["kind"] == "bad_args" and "parity side" in out["error"], (env, out)

    # The environment: both variables, neither the real home or its .config, and the side's own.
    for env in ({}, {"PALAVER_HOME": str(side / "home")}, {"XDG_CONFIG_HOME": str(side / "config")},
                {**tied, "XDG_CONFIG_HOME": str(real / ".config")}, {**tied, "PALAVER_HOME": str(real)},
                {**tied, "XDG_CONFIG_HOME": str(real / ".config" / ".")},
                {**tied, "XDG_CONFIG_HOME": str(tmp_path / "other" / "config")},
                {**tied, "PALAVER_HOME": str(tmp_path / "other" / "home")}):
        refused(**env)
    # No config.toml: Swift's default output_dir would be the real ~/Meetings.
    _side(side, None)
    refused(**tied)
    # output_dir in the real home, outside the side, or out of it through a symlink.
    _side(side, str(real / "Meetings" / "Recordings"))
    refused(**tied)
    # `~` is the stores' home (PALAVER_HOME: phase 4 batch 8), here the side's: let through (an unknown op).
    _side(side, "~/Meetings/Recordings")
    code, out = answer(**tied)
    assert code == 1 and out["kind"] == "unknown_op", out
    _side(side, str(sentinel / "Recordings"))
    refused("render", **tied)
    (side / "link").symlink_to(sentinel, target_is_directory=True)
    _side(side, str(side / "link" / "Recordings"))
    refused("render", **tied)
    _side(side, str(side / "Recordings" / ".." / ".." / "sentinel" / "Recordings"))
    refused("render", **tied)
    # Lexically "<side>/into/.." is the side; the kernel's path is the sentinel's Recordings.
    (side / "into").symlink_to(outside, target_is_directory=True)
    _side(side, str(side / "into") + "/..")
    refused("render", **tied)
    _side(side, str(side / "into") + "/../NewRecordings")  # not there yet: the kernel's path is still outside
    refused("render", **tied)
    assert (_files(sentinel), _files(fake_home)) == before and not (outside / "transcript.md").exists()

    # The side's own recordings: the op runs (and render writes, so the sentinel above would have shown it).
    inside = _sentinel_meeting(side / "Recordings")
    _side(side, str(side / "Recordings"))
    assert answer(**tied)[1]["kind"] == "unknown_op"
    assert answer("render", **tied)[0] == 0 and (inside / "transcript.md").exists()
    assert (_files(sentinel), _files(fake_home)) == before


def test_the_python_ops_refuse_to_run_outside_a_parity_side(tmp_path, monkeypatch):
    from tools.parity import ops

    real = tmp_path / "me"
    (real / ".config").mkdir(parents=True)
    side = {"XDG_CONFIG_HOME": str(tmp_path / "side" / "config"), "PALAVER_HOME": str(tmp_path / "side" / "home")}
    assert ops.unsafe_environment(side, real) is None
    for env in ({}, {**side, "XDG_CONFIG_HOME": ""}, {"XDG_CONFIG_HOME": side["XDG_CONFIG_HOME"]},
                {**side, "XDG_CONFIG_HOME": str(real / ".config")}, {**side, "PALAVER_HOME": str(real)},
                {**side, "PALAVER_HOME": str(real / "x" / "..")}):
        assert "parity side" in ops.unsafe_environment(env, real), env
    # A side without config.toml, or one that holds the (fake) real home, is refused before it is read.
    root = tmp_path / "side"
    _side(root, None)
    assert "config.toml" in ops.unsafe_side(root, real)
    _side(root, str(root / "Recordings"))
    assert ops.unsafe_side(root, real) is None
    _side(tmp_path, str(tmp_path / "Recordings"))
    assert "real home" in ops.unsafe_side(tmp_path, root / "home")
    # run() and swift() check the environment a side gets before anything runs: a side whose home/ is the real home.
    monkeypatch.setattr(ops, "_REAL_HOME", tmp_path / "r" / "home")
    for answer in (ops.run("glossary", tmp_path / "r", {"action": "show"}),
                   run.swift(tmp_path / "no-helper", "glossary", tmp_path / "r", {"action": "show"})):
        assert answer["kind"] == "bad_args" and "PALAVER_HOME" in answer["error"]
    assert not (tmp_path / "r").exists()
    monkeypatch.undo()
    # output_dir outside the side (here through a symlink): refused, and the meeting there is never written to.
    sentinel = _sentinel_meeting(tmp_path / "sentinel" / "Recordings")
    (root / "link").symlink_to(tmp_path / "sentinel", target_is_directory=True)
    _side(root, str(root / "link" / "Recordings"))
    answer = ops.run("render", root, {})
    assert answer["kind"] == "bad_args" and "output_dir" in answer["error"]
    assert not (sentinel / "transcript.md").exists()
    assert ops.inside(root / "Recordings" / "new", root) and not ops.inside(root / "link" / "Recordings", root)
    (root / "into").symlink_to(sentinel, target_is_directory=True)
    assert not ops.inside(Path(str(root / "into") + "/.."), root)
    assert not ops.inside(Path(str(root / "into") + "/../NewRecordings"), root)


# --- the diff ------------------------------------------------------------------------


def _write(side: Path, rel: str, data) -> Path:
    f = side / rel
    f.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, bytes):
        f.write_bytes(data)
    else:
        f.write_text(data if isinstance(data, str) else json.dumps(data, indent=2, ensure_ascii=False))
    return f


def test_diff_flags_a_changed_byte(tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"
    wav = bytes(range(256)) * 4
    for side in (a, b):
        _write(side, "Recordings/X/system.wav", wav)
        _write(side, "Recordings/X/meta.json", {"start_time": "2026-10-27T09:00:00+01:00", "duration_seconds": 40.0})
    assert diff.compare(a, b) == []

    changed = bytearray(wav)
    changed[100] ^= 1
    _write(b, "Recordings/X/system.wav", bytes(changed))
    _write(b, "Recordings/X/meta.json", {"start_time": "2026-10-27T09:00:00+01:00", "duration_seconds": 40})
    found = diff.compare(a, b)
    assert {(d.path, d.where) for d in found} == {("Recordings/X/system.wav", "bytes"),
                                                   ("Recordings/X/meta.json", "$.duration_seconds")}
    meta = next(d for d in found if d.where == "$.duration_seconds")
    assert (meta.python, meta.swift) == ("40.0", "40")

    # The same value in another format (Python never writes "1e-5" or this indent) is a difference too.
    _write(b, "Recordings/X/meta.json", json.dumps({"start_time": "2026-10-27T09:00:00+01:00",
                                                    "duration_seconds": 40.0}, indent=4))
    assert [d.where for d in diff.compare(a, b) if d.path.endswith("meta.json")] == ["format"]

    # A file on one side only.
    _write(b, "config/palaver/glossary.json", {"terms": {}, "rejected": []})
    assert ("config/palaver/glossary.json", "file") in {(d.path, d.where) for d in diff.compare(a, b)}


def test_an_undo_manifest_compares_a_folder_stores_fingerprint_for_presence_only(tmp_path):
    """The voice bank's hash covers its samples' "added" seconds: the sides learn a voice a second apart under load."""
    a, b = tmp_path / "a", tmp_path / "b"
    token = "0123456789abcdef0123456789abcdef"
    rel = f"Recordings/.trash/.undo/{token}/manifest.json"

    def manifest(side: Path, voices: str, glossary: str) -> None:
        _write(side, rel, {"label": "voices", "stores": [{"path": "voices", "fingerprint": voices},
                                                          {"path": "glossary.json", "fingerprint": glossary}]})

    manifest(a, "dir:" + "1" * 64, "file:" + "a" * 64)
    manifest(b, "dir:" + "2" * 64, "file:" + "a" * 64)
    assert diff.compare(a, b) == []
    manifest(b, "", "file:" + "a" * 64)  # a folder that was missing is still a difference
    assert [d.where for d in diff.compare(a, b)] == ["$.stores[0].fingerprint"]
    manifest(b, "dir:" + "2" * 64, "file:" + "b" * 64)  # a file store's hash is compared as before
    assert [d.where for d in diff.compare(a, b)] == ["$.stores[1].fingerprint"]
    # With a scenario's own rule too.
    assert diff.compare(a, b, rules={"Recordings/.trash/.undo/*/manifest.json": diff.RULES["undo_fingerprints"]}) == []


def test_imported_audio_is_compared_within_2_lsb(tmp_path):
    import numpy as np
    import soundfile as sf

    a, b = tmp_path / "a", tmp_path / "b"
    tone = (1000 * np.sin(np.arange(1600) / 5)).astype(np.int16)
    rules = {"Recordings/*/system.wav": diff.RULES["pcm_within_2_lsb"]}

    def track(side: Path, samples: np.ndarray, rate: int = 16_000) -> None:
        (side / "Recordings" / "X").mkdir(parents=True, exist_ok=True)
        sf.write(str(side / "Recordings" / "X" / "system.wav"), samples, rate, subtype="PCM_16")

    track(a, tone)
    track(b, tone + 2)
    assert diff.compare(a, b, rules=rules) == []
    assert [d.where for d in diff.compare(a, b)] == ["bytes"]  # only where a scenario asks for the rule
    track(b, tone - 3)
    assert [(d.where, d.swift) for d in diff.compare(a, b, rules=rules)] == [("samples (more than 2 LSB apart)", "3 LSB")]
    track(b, tone[:-1])
    assert [d.where for d in diff.compare(a, b, rules=rules)] == ["audio format"]
    track(b, tone, rate=8000)
    assert [d.where for d in diff.compare(a, b, rules=rules)] == ["audio format"]


def test_a_search_index_is_compared_within_1e_3(tmp_path):
    import numpy as np

    a, b = tmp_path / "a", tmp_path / "b"
    rules = {"*.npy": diff.RULES["npy_within_1e_3"]}
    vectors = np.linspace(-1, 1, 64, dtype=np.float32).reshape(4, 16)

    def index(side: Path, matrix: np.ndarray) -> None:
        (side / "Recordings" / "X").mkdir(parents=True, exist_ok=True)
        np.save(side / "Recordings" / "X" / "search-index.npy", matrix)

    index(a, vectors.astype(np.float16))
    index(b, (vectors + np.float32(5e-4)).astype(np.float16))
    assert diff.compare(a, b, rules=rules) == []
    assert [d.where for d in diff.compare(a, b)] == ["bytes"]  # only where a scenario asks for the rule
    index(b, (vectors + np.float32(4e-3)).astype(np.float16))
    assert [d.where for d in diff.compare(a, b, rules=rules)] == ["npy values (more than 0.001 apart)"]
    index(b, vectors[:3].astype(np.float16))
    assert [d.where for d in diff.compare(a, b, rules=rules)] == ["npy header"]
    index(b, vectors)
    assert [d.where for d in diff.compare(a, b, rules=rules)] == ["npy header"]
    nan = vectors.astype(np.float16)
    nan[0, 0] = np.nan
    index(b, nan)
    assert [d.where for d in diff.compare(a, b, rules=rules)] == ["npy values (NaN)"]
    (b / "Recordings" / "X" / "search-index.npy").write_bytes(b"not numpy")
    assert [d.where for d in diff.compare(a, b, rules=rules)] == ["bytes"]


def test_diff_ignores_volatile_keys(tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"
    _write(a, "Recordings/X/local_only.json", {"since": "2026-11-04T09:00:01+01:00"})
    _write(b, "Recordings/X/local_only.json", {"since": "2026-11-04T09:00:02+01:00"})
    _write(a, "config/palaver/coach-baseline.json", {"computed_at": "x", "baseline": {"talk": 0.5}})
    _write(b, "config/palaver/coach-baseline.json", {"computed_at": "y", "baseline": {"talk": 0.5}})
    # Undo snapshots: the token names the folder and is stored inside.
    _write(a, "Recordings/.trash/.undo/" + "a" * 32 + "/manifest.json", {"token": "a" * 32, "at": "1"})
    _write(b, "Recordings/.trash/.undo/" + "b" * 32 + "/manifest.json", {"token": "b" * 32, "at": "2"})
    # Never compared: logs, locks, temp files.
    _write(a, "Recordings/X/session.log", "one\n")
    _write(b, "config/palaver/projects.lock", "")
    _write(b, "config/palaver/projects.json.tmp", "{}")
    _write(b, "Recordings/.DS_Store", b"\0")
    assert diff.compare(a, b) == []

    # Presence still counts.
    _write(b, "Recordings/X/local_only.json", {})
    assert [(d.path, d.where) for d in diff.compare(a, b)] == [("Recordings/X/local_only.json", "$.since")]


def test_new_ids_are_matched_by_order(tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"

    def projects(side, first, second):
        _write(side, "config/palaver/projects.json", {
            "projects": {"4e6f7274": {"name": "Northwind rollout"}, first: {"name": "Alpha"}, second: {"name": "Beta"}},
            "meetings": {"2026-10-28T14-00-00": {"assigned": {first: {"by": "you"}}, "rejected": [second]}},
        })

    projects(a, "1a2b3c4d", "5e6f7a8b")
    projects(b, "99887766", "deadbeef")
    assert diff.compare(a, b) == []

    # Beta got the id Alpha was given first: not the same.
    _write(b, "config/palaver/projects.json", {
        "projects": {"4e6f7274": {"name": "Northwind rollout"}, "99887766": {"name": "Beta"},
                     "deadbeef": {"name": "Alpha"}},
        "meetings": {"2026-10-28T14-00-00": {"assigned": {"99887766": {"by": "you"}}, "rejected": ["deadbeef"]}},
    })
    assert diff.compare(a, b) != []

    # A corpus id one side lost is no new id, with the ids the sides started with.
    _write(b, "config/palaver/projects.json", {
        "projects": {"0000aaaa": {"name": "Northwind rollout"}, "99887766": {"name": "Alpha"},
                     "deadbeef": {"name": "Beta"}},
        "meetings": {"2026-10-28T14-00-00": {"assigned": {"99887766": {"by": "you"}}, "rejected": ["deadbeef"]}},
    })
    found = diff.compare(a, b, known_ids={"4e6f7274"})
    assert (found[0].where, found[0].swift) == ('$.projects["4e6f7274"]', "missing")


def _snapshot(side: Path, step: int) -> None:
    token = os.urandom(16).hex()
    _write(side, f"Recordings/.trash/.undo/{token}/manifest.json", {"token": token, "step": step})
    time.sleep(0.01)  # the next one is born later


def test_undo_snapshots_are_paired_by_creation(tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"
    for side in (a, b):
        _snapshot(side, 1)
        _snapshot(side, 2)
    assert diff.compare(a, b) == []

    c = tmp_path / "c"  # Swift took one snapshot fewer
    _snapshot(c, 1)
    assert [(d.path, d.where) for d in diff.compare(a, c)] == [
        ("Recordings/.trash/.undo/<token2>/manifest.json", "file")]

    d = tmp_path / "d"  # in the other order
    _snapshot(d, 2)
    _snapshot(d, 1)
    assert {x.where for x in diff.compare(a, d)} == {"$.step"}


def test_what_an_undo_set_aside_is_paired_by_the_answers(tmp_path):
    """Restored snapshots are gone; their tokens are numbered in the order the answers gave them, and
    the folders a restore set aside (``undone-<first 8>``) read as those tokens, whatever their names sort."""
    tokens = {"a": ["1" * 32, "f" * 32], "b": ["e" * 32, "2" * 32]}
    for side, (first, second) in tokens.items():
        for token in (first, second):
            (tmp_path / side / "Recordings" / ".trash" / f"undone-{token[:8]}").mkdir(parents=True)
            (tmp_path / side / "Recordings" / ".trash" / f"undone-{token[:8]}" / "projects.json").write_text(token[:4])
    results = [(f"result[{i}]", {"undo": tokens["a"][i]}, {"undo": tokens["b"][i]}, False) for i in range(2)]
    found = diff.compare(tmp_path / "a", tmp_path / "b", results=results, known_ids=set())
    assert [(d.path, d.where) for d in found] == [
        ("Recordings/.trash/undone-<token1:8>/projects.json", "line 1"),
        ("Recordings/.trash/undone-<token2:8>/projects.json", "line 1")]  # only the contents differ


def test_paths_that_read_the_same_are_a_collision(tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"
    _write(a, "Recordings/X/<id1>.json", {"n": 1})
    _write(a, "Recordings/X/deadbeef.json", {"n": 2})  # new on this side: it reads <id1>.json too
    _write(b, "Recordings/X/<id1>.json", {"n": 1})
    found = diff.compare(a, b)
    assert [(d.path, d.where) for d in found] == [("Recordings/X/<id1>.json", "collision")]
    assert "deadbeef.json" in found[0].python


def test_jsonl_lines_keep_their_format(tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"
    rows = [{"event": "recording_start", "who": "Timo Strauß"}, {"event": "stop", "seconds": 12.5}]
    python = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
    _write(a, "home/usage.jsonl", python)
    _write(b, "home/usage.jsonl", python)
    assert diff.compare(a, b) == []

    _write(b, "home/usage.jsonl", "".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n"
                                          for r in rows))
    assert [d.where for d in diff.compare(a, b)] == ["line 1: format", "line 2: format"]
    _write(b, "home/usage.jsonl", "".join(json.dumps(r) + "\n" for r in rows))
    assert [d.where for d in diff.compare(a, b)] == ["line 1: format"]
    _write(b, "home/usage.jsonl", python.rstrip("\n"))
    assert [d.where for d in diff.compare(a, b)] == ["final newline"]


def _results(tmp_path: Path, p, s, expected=False) -> list[tuple[str, str | None]]:
    a, b = tmp_path / "a", tmp_path / "b"
    a.mkdir(exist_ok=True)
    b.mkdir(exist_ok=True)
    return [(d.where, d.swift) for d in diff.compare(a, b, results=[("result[0] op", p, s, expected)])]


def test_harness_errors_are_always_differences(tmp_path):
    for kind in ("crash", "no_json", "unknown_op", "bad_args"):
        err = {"error": "x", "kind": kind}
        assert _results(tmp_path, err, err, expected=True) == [("harness error", f"{kind}: x")]
        assert _results(tmp_path, {"error": "boom", "kind": "other"}, err, expected=True)[0][0] == "harness error"

    # Through the runner: a helper that crashes, and one that knows no such op.
    crash = _fake_bin(tmp_path / "crash", "import os, signal\nos.kill(os.getpid(), signal.SIGSEGV)\n")
    scenario = {"name": "t", "steps": [{"op": "json-roundtrip", "args": {}}], "compare": ["config"], "result": True}
    found = run.run_scenario(scenario, tmp_path / "w1", parity_bin=crash, now=NOW)
    assert [(d.where, d.swift) for d in found] == [("harness error", "crash: palaver-parity crashed (exit -11)")]

    unknown = _fake_bin(tmp_path / "unknown", 'print(json.dumps({"error": "unknown op no-such-op", '
                                                '"kind": "unknown_op"}))\nsys.exit(1)\n')
    scenario["steps"] = [{"op": "no-such-op", "args": {}, "error": True}]
    found = run.run_scenario(scenario, tmp_path / "w2", parity_bin=unknown, now=NOW)
    assert [d.where for d in found] == ["harness error"]  # though Python knows no such op either

    silent = _fake_bin(tmp_path / "silent", "sys.exit(0)\n")
    scenario["steps"] = [{"op": "json-roundtrip", "args": {}}]
    found = run.run_scenario(scenario, tmp_path / "w3", parity_bin=silent, now=NOW)
    assert [(d.where, d.swift.split(":")[0]) for d in found] == [("harness error", "no_json")]


def test_domain_errors_match_only_when_expected(tmp_path):
    gone = {"error": "can't undo this any more", "kind": "gone"}
    assert _results(tmp_path, gone, gone, expected=True) == []
    assert _results(tmp_path, gone, gone) == [("error", "gone: can't undo this any more")]
    assert _results(tmp_path, gone, {**gone, "error": "can't undo this"}, expected=True)[0][0] == "error"
    assert _results(tmp_path, gone, {**gone, "kind": "changed"}, expected=True)[0][0] == "error"
    assert _results(tmp_path, gone, {"undo": "x"}, expected=True) == [("error", "answered")]
    assert _results(tmp_path, {"undo": "x"}, {"undo": "x"}, expected=True) == [("error expected", "answered")]


def _fake_bin(folder: Path, body: str) -> Path:
    script = folder / "palaver-parity"
    folder.mkdir(parents=True)
    script.write_text(f"#!{sys.executable}\nimport json, sys\n{body}")
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    return script


def _fake_parity(tmp_path: Path, meeting: str) -> Path:
    """A stand-in for the Swift helper whose json-roundtrip writes a value of its own."""
    script = tmp_path / "bin" / "palaver-parity"
    script.parent.mkdir()
    script.write_text(f"""#!{sys.executable}
import json, pathlib, sys
side = pathlib.Path(sys.argv[sys.argv.index("--side") + 1])
f = side / "Recordings" / {meeting!r} / "transcript.json"
data = json.loads(f.read_text())
data[0]["text"] = "Swiftgeheimnis"
f.write_text(json.dumps(data, indent=2))
print(json.dumps({{"rewritten": 99}}))
""")
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    return script


def _tree_hash(folder: Path) -> str:
    h = hashlib.sha256()
    for f in sorted(folder.rglob("*")):
        h.update(str(f.relative_to(folder)).encode())
        if f.is_file():
            h.update(f.read_bytes())
    return h.hexdigest()


def test_real_mode_reports_paths_not_values(tmp_path, capsys):
    a, b = tmp_path / "a", tmp_path / "b"
    _write(a, "Recordings/X/notes.json", {"summary": "Pythongeheimnis"})
    _write(b, "Recordings/X/notes.json", {"summary": "Swiftgeheimnis"})
    found = diff.compare(a, b, real=True)
    assert [(d.path, d.where, d.python, d.swift) for d in found] == [("Recordings/X/notes.json", "$.summary", None, None)]

    meeting = "2026-10-01T10-00-00"
    real = tmp_path / "Recordings"
    _write(real, f"{meeting}/transcript.json",
           [{"speaker": "Timo", "start": 0.0, "end": 2.0, "text": "Das Pythongeheimnis bleibt hier."}])
    _write(real, f"{meeting}/meta.json", {"start_time": "2026-10-01T10:00:00+02:00", "duration_seconds": 2.0})
    before = _tree_hash(real)
    out = tmp_path / "out"
    code = run.main(["--real", str(real), "--out", str(out), "--scenario", "json-roundtrip",
                     "--parity-bin", str(_fake_parity(tmp_path, meeting))])
    printed = capsys.readouterr()
    text = printed.out + printed.err
    assert code == 1
    assert f"{meeting}/transcript.json" in text and "$[0].text" in text
    assert "geheimnis" not in text.casefold() and "99" not in text
    assert _tree_hash(real) == before  # never written to
    assert (out / "json-roundtrip" / "python" / "Recordings" / meeting / "transcript.json").exists()

    with pytest.raises(SystemExit):  # --out inside the real folder: refused
        run.main(["--real", str(real), "--out", str(real / "parity")])


def test_real_mode_sides_are_independent_copies(tmp_path, monkeypatch):
    # The recordings go to each side as clones where the disk can (real mode copies them twice per scenario,
    # too much as bytes), else as plain copies; either way a side's write never reaches the other or the source.
    real = tmp_path / "Recordings"
    _write(real, "2026-10-01T10-00-00/meta.json", {"duration_seconds": 2.0})
    (real / "2026-10-01T10-00-00" / "system.wav").write_bytes(b"RIFF" + bytes(range(256)) * 64)
    before = _tree_hash(real)

    class NoClones:
        def clonefile(self, *_):
            return -1

    for name, libc in (("cloned", run._LIBC), ("copied", NoClones())):
        monkeypatch.setattr(run, "_LIBC", libc)
        py, sw = run.prepare(tmp_path / name, now=NOW, real=real)
        for side in (py, sw):
            assert _tree_hash(side / "Recordings") == before
        (py / "Recordings" / "2026-10-01T10-00-00" / "system.wav").write_bytes(b"python")
        assert (sw / "Recordings" / "2026-10-01T10-00-00" / "system.wav").read_bytes().startswith(b"RIFF")
        assert _tree_hash(real) == before


def test_a_raw_file_a_side_never_wrote_is_sent_empty(tmp_path):
    # In real mode the scenario's export names a corpus meeting, so neither side wrote the zip: the import step is
    # sent with an empty body (a difference only if the answers differ) instead of ending the whole run.
    (tmp_path / "exports").mkdir()
    (tmp_path / "exports" / "here.zip").write_bytes(b"PK")
    req = {"method": "POST", "path": "/api/import", "raw_file": "exports/here.zip"}
    assert run.with_tokens(req, tmp_path)["data"] == b"PK"
    assert run.with_tokens({**req, "raw_file": "exports/rollout.zip"}, tmp_path)["data"] == b""


def test_a_request_that_gets_no_answer_is_an_answer(tmp_path):
    # Nothing listens, or the path can't be sent (a <project:NAME> real mode has no project for stays as is): the
    # step's answer says so, with a body, so the run goes on and compares it.
    import socket

    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    assert run.http_request(port, {"path": "/api/ping"}) == {"status": None, "error": "ConnectionRefusedError",
                                                             "body": None}
    assert run.http_request(port, {"path": "/api/projects/<project:Contoso Group>/merge"}) == {
        "status": None, "error": "InvalidURL", "body": None}


# --- the corpus ----------------------------------------------------------------------


def _files(side: Path) -> dict[str, bytes]:
    return {str(f.relative_to(side)): f.read_bytes().replace(str(side).encode(), b"<side>")
            for f in sorted(side.rglob("*")) if f.is_file()}


def test_corpus_is_deterministic(tmp_path):
    corpus.build(tmp_path / "one", now=NOW)
    corpus.build(tmp_path / "two", now=NOW)
    one, two = _files(tmp_path / "one"), _files(tmp_path / "two")
    assert len(one) > 40
    assert one == two
    assert diff.compare(tmp_path / "one", tmp_path / "two") == []


def _json(f: Path):
    return json.loads(f.read_text())


def test_corpus_has_what_the_scenarios_need(tmp_path):
    side = tmp_path / "side"
    corpus.build(side, now=NOW)
    rec = side / "Recordings"
    stores = side / "config" / "palaver"
    assert (side / "home" / "Downloads").is_dir()
    assert "[user]" in (stores / "config.toml").read_text()
    assert f'output_dir = "{rec}"' in (stores / "config.toml").read_text()
    assert {p.name for p in rec.iterdir()} == {corpus.A, corpus.B, corpus.C, corpus.LIVE, corpus.D, corpus.E,
                                                corpus.E2, corpus.F, corpus.G, corpus.G2}

    # D: three system speakers, one voice at cosine 0.8 to the bank's Timo Strauß, a Northwind event.
    voices = {_json(f)["name"]: _json(f) for f in (stores / "voices").glob("*.json")}
    assert set(voices) == {"Timo Strauß", "Valerie"}
    embeddings = _json(rec / corpus.D / "speaker_embeddings.json")
    assert sorted(embeddings) == ["SPEAKER_00", "SPEAKER_01", "SPEAKER_02"]

    def cos(x, y):
        dot = sum(p * q for p, q in zip(x, y))
        return dot / (sum(p * p for p in x) ** 0.5 * sum(q * q for q in y) ** 0.5)

    best = {label: max(cos(e, s["embedding"]) for s in voices["Timo Strauß"]["samples"]) for label, e in embeddings.items()}
    assert best["SPEAKER_00"] == pytest.approx(0.8, abs=1e-3)
    assert max(best["SPEAKER_01"], best["SPEAKER_02"]) < 0.5
    event = _json(rec / corpus.D / "calendar.json")
    assert "Northwind" in event["title"] and "Valerie" in [a["name"] for a in event["attendees"]]

    # E and E2: the weekly series, E's microphone marked as several people, E2 unmarked.
    e_event = _json(rec / corpus.E / "calendar.json")
    assert (e_event["uid"], e_event["series"]) == ("northwind-weekly", True)
    assert "mic" in _json(rec / corpus.E / "speakers_shared.json")
    assert not (rec / corpus.E2 / "speakers_shared.json").exists()
    events = _json(side / "events.json")
    series = [e for e in events if e["uid"] == "northwind-weekly"]
    assert [e["start"][:10] for e in series] == ["2026-10-22", "2026-10-29"]
    assert any(e["title"] == event["title"] for e in events)

    # F: imported, with two name hints.
    imported = _json(rec / corpus.F / "imported.json")
    assert len(imported["names"]) == 2
    assert len(_json(rec / corpus.F / "speakers_inferred.json")) == 2

    # G: continued once.
    assert _json(rec / corpus.G / "parts.json") == {"parts": [corpus.G2]}
    assert (rec / corpus.G2 / "system.wav").exists()

    # LIVE: being recorded, but no live worker pid.
    assert (rec / LIVE / "live.json").exists() and (rec / LIVE / "system.wav.part").exists()
    assert not (rec / LIVE / "live.pid").exists()

    # The words the glossary and search scenarios look for.
    lines = {m: _json(rec / m / "transcript.json") for m in (corpus.D, corpus.E)}
    texts = {m: " ".join(u["text"] for u in ls) for m, ls in lines.items()}
    assert "Wasti" in texts[corpus.D] and "Vasti" in texts[corpus.E]
    assert "Kontoso" in texts[corpus.D]
    assert any("KLOUD" in u.get("unsure", ()) for u in lines[corpus.D])
    words = [w for s in _json(rec / corpus.D / "system_segments.json") for w in s["words"]]
    assert [w["confidence"] for w in words if w["text"].strip(".,") == "KLOUD"] == [0.5]
    assert any("🎉" in u["text"] and "ö" in u["text"] for u in lines[corpus.D])

    # The stores.
    assert [p["name"] for p in _json(stores / "projects.json")["projects"].values()] == ["Northwind rollout"]
    assert "Contoso" in [t["term"] for t in _json(stores / "glossary.json")["terms"].values()]
    for name in ("organizations.json", "attributions.json", "settings.json"):
        assert (stores / name).exists()

    # Upcoming: in 2 h with Valerie, in 20 h with Contoso people; the first one prepared.
    later = [e for e in events if e["start"] > NOW.isoformat()]
    assert [e["start"] for e in later] == [datetime(2026, 11, 4, 11, tzinfo=NOW.tzinfo).isoformat(),
                                           datetime(2026, 11, 5, 5, tzinfo=NOW.tzinfo).isoformat()]
    assert "Valerie" in [a["name"] for a in later[0]["attendees"]]
    assert any((a.get("email") or "").endswith("@contoso.example") for a in later[1]["attendees"])
    prepared = _json(stores / "prepared.json")
    assert list(prepared) == [f"{later[0]['uid']}|2026-11-04"]


def test_anonymize_keeps_shapes(tmp_path):
    side = tmp_path / "side"
    corpus.build(side, now=NOW)
    src, dst = side / "Recordings", tmp_path / "anon"
    anonymize.copy(src, dst)

    def shape(v):
        if isinstance(v, dict):
            return {k: shape(x) for k, x in v.items()}
        if isinstance(v, list):
            return [shape(x) for x in v]
        return type(v).__name__

    before = {str(f.relative_to(src)) for f in src.rglob("*") if f.is_file()}
    assert {str(f.relative_to(dst)) for f in dst.rglob("*") if f.is_file()} == before
    for rel in before:
        a, b = src / rel, dst / rel
        if rel.endswith(".wav") or rel.endswith(".part"):
            assert a.read_bytes() == b.read_bytes()
        elif rel.endswith(".json"):
            assert shape(_json(a)) == shape(_json(b)), rel

    d_lines = _json(dst / corpus.D / "transcript.json")
    original = _json(src / corpus.D / "transcript.json")
    for x, y in zip(original, d_lines):
        assert len(x["text"]) == len(y["text"]) and x["text"] != y["text"]
        assert [c.isupper() for c in x["text"]] == [c.isupper() for c in y["text"]]
        assert [c for c in x["text"] if not c.isalnum()] == [c for c in y["text"] if not c.isalnum()]
    everything = "\n".join(f.read_text() for f in dst.rglob("*") if f.suffix in (".json", ".md"))
    for word in ("Kontoso", "Wasti", "Vasti", "Valerie", "Northwind", "Strauß", "Timo"):
        assert word not in everything, word
    attendees = _json(dst / corpus.D / "calendar.json")["attendees"]
    assert all(a["name"].startswith("Person ") for a in attendees)
    assert all(a["email"] is None or a["email"].endswith("@contoso.example") for a in attendees)
    # The same name is the same person in every file.
    hint = _json(dst / corpus.F / "imported.json")["names"]["SPEAKER_00"]["name"]  # Valerie's
    assert hint in {a["name"] for a in attendees}


def test_anonymize_rewrites_people_in_keys(tmp_path):
    src = tmp_path / "src"
    _write(src, "organizations.json", {"names": {"northwind": "Northwind Traders"},
                                       "people": {"timo strauss": "KLOUD"}})
    _write(src, "X/calendar.json", {"title": "Sync", "attendees": [{"name": "Timo Strauß", "email": "t@kloud.example"}]})
    _write(src, "X/index.json", {"emails": {"t@kloud.example": 2}})
    anonymize.copy(src, tmp_path / "dst")
    orgs = _json(tmp_path / "dst" / "organizations.json")
    assert orgs["names"] == {"northwind": "Northwind Traders"}  # an organization's key, no person
    person = _json(tmp_path / "dst" / "X" / "calendar.json")["attendees"][0]
    assert list(orgs["people"]) == [person["name"].casefold()]
    assert list(_json(tmp_path / "dst" / "X" / "index.json")["emails"]) == [person["email"]]


def test_build_recordings_without_a_live_pid(tmp_path):
    build_recordings(tmp_path / "none", None)
    live = tmp_path / "none" / LIVE
    assert (live / "live.json").exists() and (live / "system.wav.part").exists()
    assert not (live / "live.pid").exists()

    build_recordings(tmp_path / "pid", 4242)
    assert (tmp_path / "pid" / LIVE / "live.pid").read_text() == "4242"
