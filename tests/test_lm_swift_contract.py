"""Contract: the notes palaver-lm writes (native/Sources/PalaverLM, phase 4 batch 4) are the Python app's notes.

The built ``palaver-lm`` (debug, its model the test's: ``$PALAVER_TEST_LM``) writes a meeting's notes; the Python
fallback reads them (notes.load) as up to date (notes.is_stale) and shows the names given later (with_names). One
model at a time across both: while Python holds notes.lock, palaver-lm's ``projects --no-wait`` exits 75, and while
palaver-lm writes notes, Python sees the lock taken.
Build it with `make parity-helper` (``make test`` builds it too).
"""

import json
import os
import subprocess
import time
from pathlib import Path

import pytest

from palaver import cli, notes
from palaver.models import Utterance
from palaver.paths import RecordingPaths
from palaver.speakers import without_ignored

from .test_webapp import _meeting

LM = Path(__file__).resolve().parent.parent / "native" / ".build" / "debug" / "palaver-lm"

pytestmark = pytest.mark.skipif(not LM.exists(), reason="palaver-lm not built: run `make parity-helper` (or `make test`)")

ANSWER = {
    "title": "Hiring debrief", "summary": "SPEAKER_00 ran the debrief; the offer goes out.",
    "sections": [{"heading": "Salary", "points": [{"text": "The band is fine", "details": ["SPEAKER_01: fine"]}]}],
    "next_steps": [{"owner": "SPEAKER_01", "task": "Send the offer"}], "decisions": ["Make an offer"],
    "speaker_names": [{"label": "SPEAKER_00", "name": "Rico", "evidence": "Hi Rico"}],
}


def _setup(tmp_path: Path) -> tuple[RecordingPaths, list[str], dict[str, str], Path]:
    """A meeting, palaver-lm's command head and environment (its home, the test's config home and model), and the
    model's control folder."""
    out = tmp_path / "Meetings"
    paths = _meeting(out)
    config = tmp_path / "config.toml"
    config.write_text(f'[user]\nname = "Timo"\n[recording]\noutput_dir = {json.dumps(str(out))}\n'
                      f'[notes]\nclaude = {json.dumps(str(tmp_path / "no-claude"))}\n[calendar]\nenabled = false\n')
    control = tmp_path / "model"
    control.mkdir()
    (control / "answer-notes.json").write_text(json.dumps(ANSWER))
    home = tmp_path / "home"
    env = {**os.environ, "HOME": str(home), "PALAVER_HOME": str(home), "PALAVER_TEST_LM": str(control),
           "PALAVER_TEST_KEYSTORE": str(tmp_path / "keychain.json")}
    env.pop("PALAVER_NOTIFY", None)
    return paths, [str(LM), "--config", str(config), "--no-notify"], env, home


def _utterances(paths: RecordingPaths) -> list[Utterance]:
    return without_ignored(paths, [Utterance.from_dict(d) for d in json.loads(paths.transcript_json.read_text())])


def test_python_reads_the_notes_palaver_lm_wrote_as_up_to_date(tmp_path):
    paths, head, env, _ = _setup(tmp_path)
    paths.notes.unlink()  # none yet
    assert notes.is_stale(paths, _utterances(paths))
    done = subprocess.run(head + ["notes", str(paths.folder)], env=env, capture_output=True, text=True, timeout=60)
    assert done.returncode == 0, done.stdout + done.stderr
    written = notes.load(paths)
    assert written["title"] == "Hiring debrief" and written["decisions"] == ["Make an offer"]
    assert written["speaker_names"] == [{"evidence": "Hi Rico", "label": "SPEAKER_00", "name": "Rico"}]
    assert written["transcript_hash"] == notes.transcript_hash(_utterances(paths))
    assert not notes.is_stale(paths, _utterances(paths))
    assert notes.with_names(written, {"SPEAKER_01": "Valerie"})["next_steps"] == [{"owner": "Valerie", "task": "Send the offer"}]
    # Up to date for palaver-lm too: no second run.
    again = subprocess.run(head + ["notes", str(paths.folder)], env=env, capture_output=True, text=True, timeout=60)
    assert again.returncode == 0 and "Notes are up to date" in again.stdout


def test_one_model_at_a_time_across_python_and_swift(tmp_path, monkeypatch):
    paths, head, env, home = _setup(tmp_path)
    lock = home / "Library" / "Application Support" / "palaver" / "notes.lock"
    monkeypatch.setattr(cli, "NOTES_LOCK", lock)  # the one palaver-lm takes in this home
    with cli._one_model_at_a_time(wait=False):
        busy = subprocess.run(head + ["projects", "--no-wait", "suggest"], env=env, capture_output=True, text=True, timeout=60)
    assert busy.returncode == cli.EXIT_MODEL_BUSY and "the language model is busy" in busy.stdout
    # palaver-lm writing notes (held by the test's model) holds the lock against Python.
    (tmp_path / "model" / "hold-notes").touch()
    run = subprocess.Popen(head + ["notes", str(paths.folder), "--force"], env=env, stdout=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 20
        while cli.notes_lock_free() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert not cli.notes_lock_free()
    finally:
        (tmp_path / "model" / "hold-notes").unlink()
    assert run.wait(timeout=60) == 0
    assert cli.notes_lock_free()
