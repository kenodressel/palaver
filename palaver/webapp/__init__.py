"""The Meetings window: notes, transcript and speakers of every recording,
shown by the menu bar app (window.py) from a server in a process of its own
(process.py, server.py, api.py, static/; #57)."""

from __future__ import annotations

import logging
import subprocess
import sys
from pathlib import Path

from ..settings import Settings

LOGGER = logging.getLogger(__name__)


def _popen(*args, **kwargs):
    """subprocess.Popen, replaced in tests."""
    return subprocess.Popen(*args, **kwargs)


def build_app(cfg, cli_options: list[str] = (), recording=None) -> "App":  # noqa: F821
    """The app for ``cfg``. The language model runs in a helper process
    (`palaver notes` / `projects`), so its memory is freed when
    it is done. ``recording``: the running recording's question (see App)."""

    def helper(kind: str, key: str, args: list[str]) -> bool:
        """`palaver notes` / `projects`, started by the menu bar app (#57):
        the app's descendant, so the memory watchdog counts it during calls
        and it outlives a restart of this server, which waits for it through
        its record (model_jobs). Run from here when the app does not answer."""
        from .. import appctl, model_jobs
        from ..cli import EXIT_MODEL_BUSY, ModelBusy

        root = model_jobs.jobs_root(cfg.output_dir)
        start = getattr(recording, "start_helper", None)
        started = False
        if start is not None:
            try:
                start(kind, key, args)
                started = True
            except appctl.CallFailed:
                LOGGER.info("the app did not answer: %s runs from the window's server", kind)
            except appctl.CallRefused as exc:
                LOGGER.warning("the app did not start %s: %s", kind, exc)
                return False
        if not started:
            model_jobs.launch(root, kind, key,
                              model_jobs.helper_argv(kind, args, cli_options, output_dir=cfg.output_dir))
        job = model_jobs.wait(root, kind, key)
        model_jobs.clear(root, kind, key)
        code = job.get("returncode")
        if code == EXIT_MODEL_BUSY:
            raise ModelBusy
        return code == 0

    def write_notes(meeting_id: str) -> bool:
        from .api import meeting_paths

        return helper("notes", meeting_id, [str(meeting_paths(cfg.output_dir, meeting_id).folder), "--force"])

    def run_projects(args: list[str]) -> bool:
        return helper("projects", "projects", ["--no-wait", *args])

    def ask_model(meeting_id: str, inputs: dict) -> dict:
        """The best next question (#41) from `palaver next-question`: its
        memory is freed when it is done. Raises NotesError, safe to show."""
        import json

        from ..daemon import TASKPOLICY
        from ..notes import NotesError
        from .api import meeting_paths

        folder = str(meeting_paths(cfg.output_dir, meeting_id).folder)
        argv = [sys.executable, "-m", "palaver", *cli_options, "--no-notify", "next-question", folder]
        if TASKPOLICY.exists():
            argv = [str(TASKPOLICY), "-c", "utility", *argv]
        try:
            # Its own session, so the memory watchdog (#49) can stop it and its children.
            process = _popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True, start_new_session=True)
        except OSError:
            raise NotesError("The language model gave no answer; see the log.") from None
        watch = getattr(recording, "watch", None)
        if watch is not None:  # the daemon watches it with the notes' budget for this meeting
            watch(Path(folder), process)
        try:
            stdout, _ = process.communicate(json.dumps(inputs, ensure_ascii=False), timeout=600)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            raise NotesError("The language model took more than 10 minutes; it was stopped.") from None
        if process.returncode is not None and process.returncode < 0:
            raise NotesError("The local model was stopped: the Mac ran low on memory.")
        try:
            out = json.loads((stdout.strip().splitlines() or ["{}"])[-1])
        except ValueError:
            raise NotesError("The language model gave no answer; see the log.") from None
        if not isinstance(out, dict) or "error" in out or "questions" not in out:
            raise NotesError(str((out or {}).get("error") or "The language model gave no answer; see the log."))
        return out

    def calendar(start, end):
        from ..calendar_eventkit import events_between, has_access

        return events_between(start, end) if has_access() else []

    from ..daemon import available_memory_gb
    from .server import App  # here: the menu bar app imports this package without the server (#57)

    enabled = cfg.notes_enabled
    return App(cfg.output_dir, cfg.user_name, write_notes if enabled else None, run_projects if enabled else None,
               calendar if getattr(cfg, "calendar_enabled", False) else None,
               Settings(record_slack=getattr(cfg, "record_slack", True),
                        live_processing=getattr(cfg, "live_processing", True)), recording=recording,
               cli_options=list(cli_options), cfg=cfg, ask_model=ask_model if enabled else None,
               free_memory_gb=available_memory_gb)
