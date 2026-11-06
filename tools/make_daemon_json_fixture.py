"""Write tests/fixtures/python_daemon/{recording,stopped}.json: daemon.json as the Python app's
Daemon writes it (fake clock, fake sessions, fictional folders), for the Swift daemon's tests
(native/Tests/PalaverDaemonTests: `daemonJsonKeysMatchPython`, `restoresPythonDaemonJson`).

    uv run python tools/make_daemon_json_fixture.py [out_dir]

tests/test_daemon_json_fixtures.py checks the committed files are what this writes.
recording.json: a Teams call being recorded (AirPods mic, an open audio problem, a muted-mic
hint) while another meeting is transcribed and notes wait. stopped.json: the same app quit for an
update (SIGTERM): the call held back as `cut`, a meeting still queued, notes still to write and
Slack's stale hold on the microphone ignored."""

from __future__ import annotations

import json
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

ROOT = "/tmp/palaver-fixture"  # the fictional folder the fixture's paths start with
WALL0 = datetime.fromisoformat("2026-11-03T09:00:00+01:00")
PID = 4242


class _Session:
    def __init__(self, folder: Path):
        self.folder = folder
        self.mic_device, self.mic_rate, self.mic_source = "AirPods Pro", 24000.0, "avcapture"
        self.system_device, self.system_rate, self.system_source = "AirPods Pro", 48000.0, "process-tap"
        self.missing: list[str] = []
        self.problems = [{"id": 1, "kind": "speed", "track": "system", "start": 6.0, "end": None}]
        self.hints = [{"kind": "silent", "track": "mic"}]

    def start(self):
        self.folder.mkdir(exist_ok=True)
        return self.folder

    def stop(self, reason=None):
        return 400.0


class _Running:
    def poll(self):
        return None

    def terminate(self):
        pass


class _Detector:
    """Teams is in a call; Slack's hold on the microphone is ignored (#7)."""

    ignored = {"slack"}

    def __call__(self):
        return "teams"

    def ignore(self, app):
        self.ignored.add(app)


def _normalize(state: dict, root: Path) -> dict:
    text = json.dumps(state, indent=2).replace(str(root), ROOT)
    out = json.loads(text)
    out["pid"] = PID
    return out


def make(out_dir: Path) -> None:
    from palaver.daemon import Daemon, Trigger

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp).resolve()
        rec = root / "Recordings"
        rec.mkdir()
        queued = [rec / "2026-11-03T08-00-00", rec / "2026-11-03T08-30-00"]
        notes = rec / "2026-11-02T16-00-00"
        for f in (*queued, notes):
            f.mkdir()
        (notes / "transcript.md").write_text("")
        state_path = root / "daemon.json"
        state_path.write_text(json.dumps({"state": "stopped", "queued": [str(f) for f in queued],
                                          "notes_queued": [str(notes)]}))
        clock = [0.0]
        d = Daemon(detect=_Detector(), new_session=lambda trigger: _Session(rec / "2026-11-03T09-00-14"),
                   launch_processing=lambda folder: _Running(), launch_notes=lambda folder: _Running(),
                   trigger=Trigger(start_after=4, grace=10, max_session=4 * 3600), state_path=state_path,
                   done_marker="transcript.md", clock=lambda: clock[0], sleep=lambda s: clock.__setitem__(0, clock[0] + s),
                   wall=lambda: WALL0 + timedelta(seconds=clock[0]), poll_seconds=2)
        d.run(until=lambda: clock[0] > 400)
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / "recording.json").write_text(json.dumps(_normalize(json.loads(state_path.read_text()), root), indent=2) + "\n")
        d.shutdown()
        (out_dir / "stopped.json").write_text(json.dumps(_normalize(json.loads(state_path.read_text()), root), indent=2) + "\n")


if __name__ == "__main__":
    make(Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent.parent / "tests" / "fixtures" / "python_daemon")
