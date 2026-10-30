"""Which Palaver wrote a log, and crashes with their tracebacks (#59)."""

import subprocess
import sys
import textwrap
from pathlib import Path

from palaver import __version__, runlog


def _git(repo: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)


def test_git_info_names_the_commit_and_whether_the_checkout_has_changes(tmp_path):
    _git(tmp_path, "init", "-q", "-b", "main")
    (tmp_path / "a.py").write_text("x = 1\n")
    _git(tmp_path, "add", "a.py")
    _git(tmp_path, "-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "one")
    clean = runlog.git_info.__wrapped__(tmp_path)
    assert len(clean["commit"]) == 40 and clean["dirty"] is False and clean["branch"] == "main"
    (tmp_path / "a.py").write_text("x = 2\n")
    assert runlog.git_info.__wrapped__(tmp_path)["dirty"] is True


def test_a_release_install_has_no_git_info(tmp_path):
    assert runlog.git_info.__wrapped__(tmp_path) == {}


def test_version_text_says_commit_and_dirty(monkeypatch):
    monkeypatch.setattr(runlog, "git_info", lambda: {"commit": "abc1234def", "dirty": True})
    assert runlog.version_text() == f"{__version__} (abc1234, dirty)"
    monkeypatch.setattr(runlog, "git_info", lambda: {})
    assert runlog.version_text() == __version__


def test_exceptions_a_library_catches_and_prints_reach_the_crash_log_too(report_home, capsys):
    import types

    rumps_like = types.SimpleNamespace(traceback=None)
    runlog.log_printed_exceptions(rumps_like, "palaver menubar callback")
    try:
        raise ValueError("menu item broke")
    except ValueError:
        rumps_like.traceback.print_exc()
    assert "ValueError: menu item broke" in capsys.readouterr().err
    text = runlog.CRASH_LOG.read_text()
    assert "palaver menubar callback" in text and "ValueError: menu item broke" in text
    assert rumps_like.traceback.format_exc is not None  # the rest of the module is still there


def test_uncaught_exceptions_of_the_process_and_its_threads_go_to_the_crash_log(tmp_path):
    log = tmp_path / "crashes.log"
    script = textwrap.dedent(f"""
        import threading
        from pathlib import Path
        from palaver import runlog
        runlog.CRASH_LOG = Path({str(log)!r})
        runlog.install_crash_log("palaver webapp-serve")
        t = threading.Thread(target=lambda: {{}}["speakers"], name="request")
        t.start(); t.join()
        raise RuntimeError("diarization exploded")
    """)
    run = subprocess.run([sys.executable, "-c", script], capture_output=True, text=True,
                         cwd=Path(runlog.__file__).parent.parent)
    assert run.returncode == 1
    assert "diarization exploded" in run.stderr  # still printed as before
    text = log.read_text()
    assert "palaver webapp-serve thread request" in text and "KeyError: 'speakers'" in text
    assert "=== " in text and "RuntimeError: diarization exploded" in text
    assert f"palaver {__version__}" in text
