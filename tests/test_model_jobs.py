"""The language model's jobs the window starts (notes, sorting projects),
recorded on disk with their pid (#57): a restarted window server shows a
running job again, never starts a second one, and finishes an undo the
old server could not. Fake helpers only."""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

from palaver import model_jobs


def _until(condition, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.02)
    return condition()


def _sleeper(seconds: float, code: int = 0) -> list[str]:
    return [sys.executable, "-c", f"import sys, time; time.sleep({seconds}); sys.exit({code})"]


def test_a_launched_job_is_recorded_with_its_pid_until_it_ends(tmp_path: Path):
    root = tmp_path / ".jobs"
    pid = model_jobs.launch(root, "notes", "2026-10-30T08-02-13", _sleeper(0.3))
    job = model_jobs.read(root, "notes", "2026-10-30T08-02-13")
    assert job["pid"] == pid and job["state"] == "running" and not job.get("stale")
    assert [j["key"] for j in model_jobs.running(root)] == ["2026-10-30T08-02-13"]
    done = model_jobs.wait(root, "notes", "2026-10-30T08-02-13")
    assert done["state"] == "done" and done["returncode"] == 0
    assert model_jobs.running(root) == []


def test_the_exit_code_is_kept(tmp_path: Path):
    root = tmp_path / ".jobs"
    model_jobs.launch(root, "projects", "projects", _sleeper(0, 75))
    assert model_jobs.wait(root, "projects", "projects")["returncode"] == 75


def test_a_run_that_ended_is_done_before_its_pid_is_free(tmp_path: Path):
    """The launcher writes "done" while the helper is still unreaped (its pid taken): a reader in between never
    finds a dead pid under a "running" record, which it would call stale (a 502 for a notes run that just ended)."""
    proc = subprocess.Popen([sys.executable, "-c", "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"])
    assert model_jobs._exit_code_unreaped(proc.pid) == -15
    assert model_jobs._alive(proc.pid)  # ended, not yet reaped
    assert proc.wait() == -15
    done = subprocess.Popen([sys.executable, "-c", "raise SystemExit(3)"])
    assert model_jobs._exit_code_unreaped(done.pid) == 3 and done.wait() == 3
    assert model_jobs._exit_code_unreaped(os.getpid()) is None  # not a child


def test_a_second_launch_while_one_runs_is_the_same_job(tmp_path: Path):
    root = tmp_path / ".jobs"
    launched = []

    def popen(argv, **kw):
        launched.append(argv)
        return subprocess.Popen(argv, **kw)

    first = model_jobs.launch(root, "notes", "m", _sleeper(0.5), popen=popen)
    assert model_jobs.launch(root, "notes", "m", _sleeper(0.5), popen=popen) == first
    assert len(launched) == 1
    model_jobs.wait(root, "notes", "m")
    model_jobs.clear(root, "notes", "m")
    assert model_jobs.read(root, "notes", "m") is None


def test_a_record_whose_pid_is_gone_is_stale(tmp_path: Path):
    root = tmp_path / ".jobs"
    gone = subprocess.Popen(_sleeper(0))
    gone.wait()
    model_jobs.write(root, {"kind": "notes", "key": "m", "pid": gone.pid, "state": "running", "started": 0})
    job = model_jobs.read(root, "notes", "m")
    assert job["stale"] is True
    assert model_jobs.running(root) == []
    assert model_jobs.wait(root, "notes", "m")["stale"] is True  # no hang


def test_the_helper_runs_in_its_own_process_group_as_the_launchers_child(tmp_path: Path):
    root = tmp_path / ".jobs"
    pid = model_jobs.launch(root, "notes", "m", _sleeper(1))
    try:
        assert os.getpgid(pid) == pid
        ppid = int(subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True).stdout)
        assert ppid == os.getpid()
    finally:
        model_jobs.wait(root, "notes", "m")


def test_a_pending_undo_is_kept_until_finished(tmp_path: Path):
    root = tmp_path / ".jobs"
    model_jobs.pending_undo(root, "tok123", "sort projects")
    [pending] = model_jobs.pending_undos(root)
    assert pending["token"] == "tok123" and pending["label"] == "sort projects" and pending["owner"] == os.getpid()
    model_jobs.finish_undo(root, "tok123", ok=True)
    assert model_jobs.pending_undos(root) == []
    [finished] = model_jobs.finished_undos(root)
    assert finished == {"token": "tok123", "label": "sort projects", "ok": True}
    model_jobs.seen(root, "tok123")
    assert model_jobs.finished_undos(root) == []


def test_helper_argv_only_runs_notes_and_projects(tmp_path: Path):
    folder = tmp_path / "2026-10-30T08-02-13"
    argv = model_jobs.helper_argv("notes", [str(folder), "--force"], ["--config", "/c.toml"], output_dir=tmp_path)
    assert argv[-6:] == ["--config", "/c.toml", "--no-notify", "notes", str(folder), "--force"]
    assert model_jobs.helper_argv("projects", ["--no-wait", "suggest"], [], output_dir=tmp_path)[-3:] == [
        "projects", "--no-wait", "suggest"]
    assert model_jobs.helper_argv("projects", ["--no-wait", "describe", "ab12"], [], output_dir=tmp_path)[-2:] == [
        "describe", "ab12"]
    import pytest

    for kind, args in [("notes", ["/etc", "--force"]), ("notes", [str(tmp_path / "x/../../etc"), "--force"]),
                       ("projects", ["--no-wait", "rm"]), ("run", [str(folder)]),
                       ("projects", ["--no-wait", "describe", "../x"])]:
        with pytest.raises(ValueError):
            model_jobs.helper_argv(kind, args, [], output_dir=tmp_path)


def test_what_a_failed_helper_printed_is_kept_and_says_why(tmp_path: Path):
    """The window's error says why the model failed, not "see the log"."""
    root = tmp_path / ".jobs"
    script = "import sys; print('Asking Gemma 4 12B on this Mac…'); print('error: the model is not downloaded'); sys.exit(1)"
    model_jobs.launch(root, "projects", "projects", [sys.executable, "-c", script])
    job = model_jobs.wait(root, "projects", "projects")
    assert job["returncode"] == 1
    model_jobs.clear(root, "projects", "projects")
    assert "Asking Gemma" in model_jobs.log_path(root, "projects", "projects").read_text()
    assert model_jobs.last_error(root, "projects", "projects") == "the model is not downloaded"


def test_a_helper_that_crashed_is_said_by_its_exception(tmp_path: Path):
    root = tmp_path / ".jobs"
    model_jobs.launch(root, "projects", "projects", [sys.executable, "-c", "raise MemoryError('out of memory')"])
    model_jobs.wait(root, "projects", "projects")
    assert model_jobs.last_error(root, "projects", "projects") == "MemoryError: out of memory"
    assert model_jobs.last_error(root, "notes", "nothing-ran") is None
