"""Menu bar app hosting the Teams auto-record daemon (issue #14).

Started from a terminal (``palaver menubar``) it inherits the
terminal's microphone / system-audio permissions, like ``daemon``.
The daemon is ticked from a rumps timer on the main thread; everything the
menu shows comes from ``Daemon.status()`` through the pure helpers below.
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path

from . import install_layout, notify, settings, usage
from .meter import level_bar

LOGGER = logging.getLogger(__name__)
PROCESS_STEPS = 7
MENUBAR_ICON = Path(__file__).parent / "assets" / "menubar.png"  # black: macOS tints it
_SOURCES = {"process-tap": "Process Tap", "scstream": "ScreenCaptureKit"}


def _clock_text(seconds: float) -> str:
    seconds = max(0, int(seconds))
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    return f"{hours}:{minutes:02d}:{secs:02d}" if hours else f"{minutes}:{secs:02d}"


def _elapsed(status: dict, now: datetime) -> float:
    return (now - datetime.fromisoformat(status["since"])).total_seconds()


def menu_title(
    status: dict,
    *,
    error: bool = False,
    now: datetime | None = None,
    progress: tuple[int, int, str] | None = None,
) -> str:
    """Menu bar text next to the icon: what is happening, if anything."""
    if error:
        return "⚠️"
    if status["state"] == "recording":
        icon = "🔴⚠" if status.get("missing") or status.get("warnings") else "🔴"  # never for a hint
        return icon + (f" {_clock_text(_elapsed(status, now))}" if now else "")
    if status.get("transcribing"):
        return "⏳" + (f" {progress[0]}/{progress[1]}" if progress and progress[0] else "")
    if status["state"] == "paused":
        return "⏸"
    return ""


# Audio warnings shown in the menu while recording; the rest as "+N more".
MENU_WARNINGS = 2
# Lines the menu has for a running recording; the coach's one line only fits in what is left.
MENU_LINES = 8

START_TITLE = "Start recording now"
STOP_TITLE = "Stop recording"
KEEP_TITLE = "Keep recording"


def manual_title(status: dict) -> str:
    """The start/stop item: it asks to stop when a manual recording ran on
    after its call ended or went silent (issue #52)."""
    if status["state"] != "recording":
        return START_TITLE
    q = status.get("stop_question")
    if not q:
        return STOP_TITLE
    if q["reason"] == "silence":
        return f"Silent for {q['minutes']} min — Stop recording"
    return "Call ended — Stop recording"


def manual_action(shown: str, recording: bool) -> str | None:
    """What a click on the start/stop item does: what it said. A call that
    ended while the menu was open makes "Stop recording" do nothing, not
    start a new recording."""
    if shown != START_TITLE:  # one of the stop titles
        return "stop" if recording else None
    return None if recording else "start"


def status_line(
    status: dict, now: datetime, progress: tuple[int, int, str] | None = None
) -> str:
    if status["state"] == "recording":
        if status.get("why_text"):  # "Recording · Teams call since 12:06 · mic AirPods (24 kHz)" (#47)
            return status["why_text"]
        minutes = int(_elapsed(status, now) // 60)
        name = Path(status["folder"]).name if status.get("folder") else ""
        how = " (manual)" if status.get("manual") else ""
        return f"Recording for {minutes} min{how} → {name}".rstrip(" →")
    if status.get("transcribing"):
        queued = len(status.get("queued", []))
        details = [f"{progress[0]}/{progress[1]}"] if progress and progress[0] else []
        if queued:
            details.append(f"{queued} more queued")
        label = progress[2] if progress and progress[0] else "Transcribing"
        return label + (f" ({', '.join(details)})" if details else "")
    if status.get("indexing"):  # #46, in the background when nothing else runs
        return "Downloading the search model (470 MB)" if status.get("index_downloading") else "Indexing meetings for search"
    if status["state"] == "paused":
        return "Not recording calls automatically"
    return "Waiting for a Teams call or Slack huddle"


def recording_lines(
    status: dict, levels: list[tuple[str, float | None, float]], now: datetime
) -> list[str]:
    """Live details shown in the menu while recording, under the status
    item that says why it records."""
    lines = []
    for label, db, silent_for in levels:
        level = f"{db:.0f} dB" if db is not None else "-- dB"
        line = f"{label.capitalize():<7} {level_bar(db)} {level}"
        if silent_for >= 5:
            line += f" (silent {silent_for:.0f} s)"
        lines.append(line)
    if status.get("missing"):
        lines.append(f"⚠ Not recording: {', '.join(status['missing'])} — see `palaver doctor`")
    warnings = status.get("warnings") or []  # issue #50: two at most, the window has them all
    lines += [f"⚠ {warning}" for warning in warnings[:MENU_WARNINGS]]
    if len(warnings) > MENU_WARNINGS:
        lines.append(f"+{len(warnings) - MENU_WARNINGS} more — open Palaver for all")
    source = _SOURCES.get(status.get("system_source") or "", "unknown")
    rate = ((status.get("why") or {}).get("system") or {}).get("rate")
    if rate:
        source += f" ({rate / 1000:g} kHz)"
    if status.get("manual"):
        trigger = "manual recording"
    else:
        trigger = "Call active" if status.get("teams_active") else "Call ended — stopping soon"
    lines.append(f"System audio via {source} · {trigger}")
    lines += list(status.get("hints") or [])
    # The live coach (#41): one line, last, only with room left; the nudge before the talk line.
    nudge = (status.get("nudge") or {}).get("text")
    coach = f"Coach: {nudge}" if nudge else status.get("talk_text")
    if coach and len(lines) < MENU_LINES:
        lines.append(coach)
    return lines[:MENU_LINES]


# session.log event → (step, label) of the processing pipeline.
_STEP_EVENTS = {
    ("aec_start", None): (1, "Removing speaker echo"),
    ("transcribe_start", "system"): (2, "Transcribing the other side"),
    ("transcribe_start", "mic"): (3, "Transcribing your microphone"),
    ("diarize_start", None): (4, "Identifying speakers"),
    ("diarize_done", None): (5, "Writing the transcript"),
    ("merge_done", None): (5, "Writing the transcript"),
    ("notes_start", None): (6, "Writing notes"),
    ("process_done", None): (7, "Uploading to Notion"),
    ("notion_upload_start", None): (7, "Uploading to Notion"),
}


def processing_progress(session_log: Path) -> tuple[int, int, str]:
    """(step, total, label) of a recording's processing, from its session.log."""
    current = (0, "Starting")
    try:
        lines = session_log.read_text().splitlines()
    except OSError:
        lines = []
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        key = (row.get("event"), row.get("track"))
        hit = _STEP_EVENTS.get(key) or _STEP_EVENTS.get((row.get("event"), None))
        if hit:
            current = hit
    return current[0], PROCESS_STEPS, current[1]


# Which calls start a recording: the same two switches as the window's
# Settings page (settings.json), one item each.
AUTO_RECORD = (
    ("record_teams", "Record Teams calls automatically"),
    ("record_slack", "Record Slack huddles automatically"),
)
OPEN_TITLE = "Open Meetings"
UPDATE_TITLE = "Update available"  # #60: shown only when there is one, with its version
CALENDAR_TITLE = "Connect Calendar…"
REPORT_TITLE = "Report a Problem…"  # #59: the window's report form
QUIT_TITLE = "Quit"


def menu_layout() -> list[str | None]:
    """The menu under the status line and the live lines, by first title
    (None: a separator): the record switches, starting and stopping, the
    window, reporting a problem. The old quick settings (latest folder,
    Notion page, log) are the window's business now (#37)."""
    return [*(title for _, title in AUTO_RECORD), START_TITLE, KEEP_TITLE, None,
            OPEN_TITLE, CALENDAR_TITLE, REPORT_TITLE, None, UPDATE_TITLE, QUIT_TITLE]


def auto_record_states(defaults: settings.Settings, current=None) -> dict[str, bool]:
    """Each record switch as Settings has it now (``current``: a settings.Cached)."""
    s = current() if current is not None else settings.load(defaults)
    return {key: bool(getattr(s, key)) for key, _ in AUTO_RECORD}


# The app each record switch is about, as the daemon names a call's app.
SWITCH_APP = {"record_teams": "teams", "record_slack": "slack"}


def with_record_switches(status: dict, states: dict[str, bool]) -> dict:
    """The status as the menu shows it: with every record switch off and
    nothing recording, paused (⏸, "Not recording calls automatically")."""
    if status["state"] == "idle" and not any(states.values()):
        return {**status, "state": "paused"}
    return status


def toggle_auto_record(key: str, defaults: settings.Settings) -> bool:
    """A record switch clicked in the menu: flipped and saved, as the
    Settings page saves it. Returns whether it is on now."""
    on = not getattr(settings.load(defaults), key)
    settings.update({key: on})
    return on


# The Calendar app may sync an event after the recording was processed:
# look again for recent recordings without one, this often and this far back.
CALENDAR_RETRY_SECONDS = 300
CALENDAR_RETRY_WINDOW = timedelta(hours=36)


def attach_calendar_events(output_dir: Path, provider, since: datetime | None = None, *, user_name: str = "") -> int:
    """Give earlier recordings their calendar events, then recognize voices
    again with the invitees known. Returns how many recordings got one."""
    from . import calendar_events, people

    found = calendar_events.attach_all(output_dir, provider, since)
    if found:
        people.refresh_recognition(output_dir, user_name=user_name)
    return found


def update_busy(daemon_status: dict, *, jobs: list, test: str, downloading: bool) -> str | None:
    """What an update waits for (#60): the daemon's reasons (a call, a
    recording, its processing, notes), the window's language model jobs, the
    setup assistant's test recording and its model downloads. None: idle."""
    from .daemon import busy_reason

    reason = busy_reason(daemon_status)
    if reason:
        return reason
    if jobs:
        return "writing notes" if any(j.get("kind") == "notes" for j in jobs) else "sorting projects"
    if test not in ("idle", "done", "failed"):
        return "a test recording"
    if downloading:
        return "downloading models"
    return None


def _move_mcp_entries() -> None:
    """Claude's entries for the installer's venv before #60, moved to this
    app's own python (it survives runtime updates)."""
    from . import install_layout, mcp_access

    try:
        moved = mcp_access.migrate(install_layout.stable_python())
    except Exception:
        LOGGER.warning("moving Claude's MCP entries failed", exc_info=True)
        return
    if moved:
        LOGGER.info("moved the MCP server's entries for %s to this app's python", ", ".join(moved))


class Updates:
    """The updater as the menu bar app runs it (#60): checks and downloads
    on threads of their own, the swap on the main thread's tick (``tick``
    says when the app must quit for it). Uninstalling goes through here
    too: both end the app the same way.

    The idle gate is asked on the main thread, where the daemon ticks, and
    once more right before the swap script starts; the app quits in that
    same tick, so no recording can start while an update installs. A call
    that began before is recorded and the update waits: recording wins."""

    def __init__(self, daemon, *, output_dir: Path | None = None, test_recording=None):
        from . import downloader, install_layout, model_jobs, onboarding, updater

        self._bundled = install_layout.bundle() is not None
        self._installer = updater.Installer()
        self.updater = updater.Updater(
            installed=updater.installed_now, fetch_manifest=downloader.fetch_manifest,
            stage=self._installer.stage,
            apply=lambda staged: self._installer.apply(staged, wait_for=self.app_pids(), still_busy=self.busy),
            busy=lambda: self.busy(),
            enabled=lambda: settings.load().check_updates,
            macos=updater.macos_version(), save=updater.write_status, previous=updater.read_status())
        self._worker: threading.Thread | None = None

        def busy() -> str | None:
            return update_busy(
                daemon.status(),
                jobs=model_jobs.running(model_jobs.jobs_root(output_dir)) if output_dir else [],
                test=(test_recording.status().get("state") if test_recording is not None else None) or "idle",
                downloading=onboarding.downloads_running(install_layout.downloads_marker()))

        self.busy = busy
        self.quit_now = False
        if self._bundled:  # runtimes before the one before this one go
            info = install_layout.bundle_info()
            if info.get("runtime"):
                threading.Thread(target=updater.prune_runtimes, args=(info["runtime"],), daemon=True).start()
            threading.Thread(target=_move_mcp_entries, daemon=True).start()
        self.updater._changed()  # update.json says what this version is

    def started(self) -> None:
        """The app is up (its first tick ran): the swap that installed it
        may drop the version before (#60)."""
        from . import install_layout

        version = install_layout.bundle_info().get("version")
        if version:
            path = install_layout.started_ok_path()
            try:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(version)
            except OSError:
                LOGGER.warning("could not write %s", path)

    def app_pids(self) -> list[int]:
        """What must have quit before the app is replaced: this process, and
        the launcher above it when it runs under one (the launcher hands it
        $PALAVER_LAUNCHER_FD; a terminal does not)."""
        return [os.getpid(), *([os.getppid()] if os.environ.get("PALAVER_LAUNCHER_FD") else [])]

    def _background(self, fn) -> bool:
        if self._worker is not None and self._worker.is_alive():
            return False
        self._worker = threading.Thread(target=fn, name="updates", daemon=True)
        self._worker.start()
        return True

    def check(self) -> dict:
        self._background(self.updater.check)
        return self.updater.status()

    def install(self) -> dict:
        """The user's click: download in the background, install when idle."""
        if self.updater.request():
            self._background(self.updater.download)
        return self.updater.status()

    def tick(self) -> bool:
        """Each second: start a due check; True when the app must quit now
        (an update is swapped in, or the user uninstalled)."""
        if self.updater.due():
            self._background(self.updater.check)
        return self.quit_now or self.updater.tick()

    def uninstall(self, *, output_dir: Path, models: bool, recordings: bool) -> dict:
        import tempfile

        from . import uninstall

        paths = uninstall.plan(Path.home(), output_dir=output_dir, models=models, recordings=recordings)
        uninstall.start(paths, wait_for=self.app_pids(), work=Path(tempfile.gettempdir()),
                        then_if_empty=uninstall.emptied(Path.home(), output_dir=output_dir) if recordings else [])
        self.quit_now = True
        return {"removing": [str(p) for p in paths]}


def finalize(app) -> threading.Thread:
    """Before the app quits (Quit, logout, SIGTERM from the launcher): finish
    the WAVs and queue the recording instead of leaving .part files, then
    stop the window's server in the background (#57): it may finish its
    last change, the main thread never waits for it. Returns that thread."""
    from .webapp.process import stop_in_background

    app.timer.stop()
    app.daemon.shutdown(getattr(app, "quit_reason", "restart"))
    stopping = stop_in_background(app.web)
    app.control.close()
    return stopping


PERMISSIONS_MARKER = install_layout.permissions_marker()


def click_action(event_type: int, modifier_flags: int) -> str:
    """What a click on the menu bar icon does: a right click (or ctrl-click) shows the menu, any other click opens the window."""
    from AppKit import NSEventModifierFlagControl, NSEventTypeRightMouseUp

    if event_type == NSEventTypeRightMouseUp or modifier_flags & NSEventModifierFlagControl:
        return "menu"
    return "open"


def event_action(event) -> str:
    """``click_action`` for the click being handled; no event (the button
    was triggered without one) opens the window."""
    if event is None:
        return "open"
    return click_action(event.type(), event.modifierFlags())


def show_menu_once(item, button, menu) -> None:
    """The status item's menu for this one click, then off again even when
    showing it fails: else every left click would open the menu."""
    item.setMenu_(menu)
    try:
        button.performClick_(None)
    finally:
        item.setMenu_(None)


def permissions_to_request(*, mic_status: int, marker: Path) -> list[str]:
    """Which permission prompts to trigger at launch, so macOS asks now and
    not in the middle of the first meeting. Only Microphone and System Audio
    Recording — Screen Recording is no longer needed. System-audio capture
    has no status API, so it is requested once per install (marker file)."""
    wanted = []
    if mic_status == 0:  # not determined
        wanted.append("microphone")
    if not marker.exists():
        wanted.append("system-audio")
    return wanted


def request_permissions(marker: Path = PERMISSIONS_MARKER) -> None:  # pragma: no cover - OS prompts
    import AVFoundation

    wanted = permissions_to_request(
        mic_status=AVFoundation.AVCaptureDevice.authorizationStatusForMediaType_(AVFoundation.AVMediaTypeAudio),
        marker=marker,
    )
    if "microphone" in wanted:
        AVFoundation.AVCaptureDevice.requestAccessForMediaType_completionHandler_(
            AVFoundation.AVMediaTypeAudio, lambda _granted: None
        )
    if "system-audio" in wanted:
        from ._audio.process_tap import ProcessTap

        try:
            tap = ProcessTap(lambda *_: None, route_poll_interval=None)
            tap.start()  # triggers the System Audio Recording prompt; captures nothing
            tap.stop()
        except Exception:
            pass
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text("1")


def create_app(cfg, cli_options: list[str] = ()):  # pragma: no cover - UI shell
    import rumps
    from AppKit import NSAttributedString, NSFont, NSFontAttributeName
    from AppKit import NSApp, NSEventMaskLeftMouseUp, NSEventMaskRightMouseUp
    from Foundation import NSObject, NSRunLoop, NSRunLoopCommonModes
    from PyObjCTools import AppHelper

    mono = {NSFontAttributeName: NSFont.monospacedSystemFontOfSize_weight_(12.0, 0.0)}

    from . import appctl, model_jobs, onboarding
    from .daemon import build_daemon
    from .meter import LevelTracker
    from .webapp import process as web_process
    from .webapp.window import open_window, reload_in_place
    from .calendar_eventkit import has_access as calendar_access
    from .calendar_eventkit import request_access as request_calendar_access

    # The record switches' defaults, as the daemon has them (config.toml's record_slack).
    record_defaults = settings.Settings(record_slack=getattr(cfg, "record_slack", True))
    record_settings = settings.Cached(record_defaults)

    class Clicker(NSObject):
        """Target of the icon's button: sends each click to `on_click(action)`."""

        def clicked_(self, _sender):
            self.on_click(event_action(NSApp.currentEvent()))

    class MeetingApp(rumps.App):
        def __init__(self):
            super().__init__("Palaver", title="", icon=str(MENUBAR_ICON), template=True, quit_button=None)
            self._tracker: LevelTracker | None = None
            self._tracked_folder: str | None = None
            self._quiet_for: float | None = None  # both tracks, from the live levels
            self.daemon = build_daemon(cfg, cli_options, silence=lambda: self._quiet_for)
            # The Meetings window's page and data, served by a process of its
            # own (#57): restarted at any time, it never touches a recording.
            # What it needs from this process goes through the app socket.
            self.test_recording = onboarding.TestRecording()  # the setup assistant's (#55): recorded here
            self.updates = Updates(self.daemon, output_dir=cfg.output_dir, test_recording=self.test_recording)  # #60
            calls = appctl.app_calls(
                self.daemon, on_main=on_main, test_recording=self.test_recording,
                restart_web=lambda: self.web.restart(), refresh=self.refresh,
                launch_helper=lambda kind, key, args: model_jobs.launch(
                    model_jobs.jobs_root(cfg.output_dir), kind, key,
                    model_jobs.helper_argv(kind, args, cli_options, output_dir=cfg.output_dir)))
            # The setup assistant's Connect Calendar button: asked here, the process that reads it.
            app_calendar = onboarding.Calendar(ask=lambda: on_main(lambda: request_calendar_access(lambda granted: None)))
            calls.update(
                calendar=lambda args: app_calendar.connect() if args.get("action") == "connect" else app_calendar.status(),
                update_check=lambda args: self.updates.check(),
                update_install=lambda args: self.updates.install(),
                uninstall=lambda args: on_main(lambda: self.updates.uninstall(
                    output_dir=cfg.output_dir, models=bool(args.get("models")),
                    recordings=bool(args.get("recordings")))))
            self.control = appctl.serve(appctl.APP_SOCKET, calls)
            self.web = web_process.WebSupervisor(
                lambda listen_fd, ready_fd: web_process.child_argv(
                    cli_options, listen_fd=listen_fd, ready_fd=ready_fd, app_socket=appctl.APP_SOCKET),
                listener=web_process.listen(), env=web_process.child_env(os.environ),
                on_ready=lambda restarted: restarted and AppHelper.callAfter(reload_in_place, self.web.url()))
            self.web.start()
            self._error = False
            self._started = False  # the first tick ran (#60: the update's swap waits for it)
            self._click_installed = False
            self.status_item = rumps.MenuItem("Starting…")
            self.live_items = [rumps.MenuItem("") for _ in range(MENU_LINES)]
            self.record_items = {key: rumps.MenuItem(title, callback=self.toggle_record) for key, title in AUTO_RECORD}
            self.manual_item = rumps.MenuItem(START_TITLE, callback=self.toggle_manual)
            self.keep_item = rumps.MenuItem(KEEP_TITLE, callback=self.keep_recording)
            self.calendar_item = rumps.MenuItem(CALENDAR_TITLE, callback=self.connect_calendar)
            self.update_item = rumps.MenuItem(UPDATE_TITLE, callback=self.install_update)
            self._calendar_retried = time.monotonic()  # connecting looks everything up first
            self._refresh_calendar_item()
            items = {**{title: self.record_items[key] for key, title in AUTO_RECORD},
                     START_TITLE: self.manual_item, KEEP_TITLE: self.keep_item,
                     OPEN_TITLE: rumps.MenuItem(OPEN_TITLE, callback=self.open_meetings, key="m"),
                     CALENDAR_TITLE: self.calendar_item,
                     REPORT_TITLE: rumps.MenuItem(REPORT_TITLE, callback=self.report_problem),
                     UPDATE_TITLE: self.update_item,
                     QUIT_TITLE: rumps.MenuItem(QUIT_TITLE, callback=self.quit)}
            self.menu = [
                self.status_item,
                *self.live_items,
                None,
                *(None if title is None else items[title] for title in menu_layout()),
            ]
            self.timer = rumps.Timer(self.tick, 1.0)

        def _install_click(self):
            # rumps gives the status item its menu, which would open on every click.
            # Take the menu off and keep it: a left click opens the window, a right click puts it back for one click.
            item = self._nsapp.nsstatusitem
            if item is None:
                return
            self._click_installed = True
            menu = item.menu()
            button = item.button()
            item.setMenu_(None)

            def on_click(action):
                if action == "open":
                    self.open_meetings(None)
                else:
                    show_menu_once(item, button, menu)

            self._clicker = Clicker.alloc().init()  # kept: the button holds its target weakly
            self._clicker.on_click = on_click
            button.setTarget_(self._clicker)
            button.setAction_("clicked:")
            button.sendActionOn_(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)

        def tick(self, _timer=None):
            if not self._click_installed:
                self._install_click()
            try:
                self.daemon.tick()
                self._error = False
                if not self._started:
                    self._started = True
                    self.updates.started()
            except Exception:
                if not self._error:  # once when it starts failing, not every second
                    LOGGER.exception("the daemon's tick failed")
                self._error = True
            self.refresh()
            self._retry_calendar()
            if self.updates.tick():  # an update is swapped in after the quit, or the user uninstalled
                self.timer.stop()
                rumps.quit_application()

        def _retry_calendar(self):
            now = time.monotonic()
            if not self._calendar_connected or now - self._calendar_retried < CALENDAR_RETRY_SECONDS:
                return
            self._calendar_retried = now
            if self.daemon.status().get("transcribing"):
                return  # processing looks the event up itself
            since = datetime.now().astimezone() - CALENDAR_RETRY_WINDOW
            threading.Thread(target=self._attach_calendar_events, args=(since,), daemon=True).start()

        def refresh(self):
            if not self._calendar_connected:  # picks up consent given in the dialog
                self._refresh_calendar_item()
            switches = auto_record_states(record_defaults, record_settings)
            status = with_record_switches(self.daemon.status(), switches)
            now = datetime.now().astimezone()
            progress = None
            if status.get("transcribing_folder"):
                progress = processing_progress(Path(status["transcribing_folder"]) / "session.log")
            self.title = menu_title(status, error=self._error, now=now, progress=progress)
            self.status_item.title = status_line(status, now, progress)
            self.manual_item.title = manual_title(status)
            self.keep_item._menuitem.setHidden_(not status.get("stop_question"))
            from .updater import menu_title as update_title

            update = update_title(self.updates.updater.status())
            self.update_item.title = update or UPDATE_TITLE
            self.update_item._menuitem.setHidden_(update is None)
            for key, on in switches.items():
                self.record_items[key].state = on  # also when switched in the window's Settings
            lines = []
            if status["state"] == "recording" and status.get("folder"):
                if self._tracked_folder != status["folder"]:
                    folder = Path(status["folder"])
                    self._tracker = LevelTracker([
                        ("mic", folder / "mic_raw.wav.part"),
                        ("system", folder / "system.wav.part"),
                    ])
                    self._tracked_folder = status["folder"]
                lines = recording_lines(status, self._tracker.read(), now)
                self._quiet_for = self._tracker.quiet_for()
            else:
                self._tracker = self._tracked_folder = self._quiet_for = None
            for item, text in zip(self.live_items, lines + [""] * len(self.live_items)):
                item.title = text
                # Monospaced so the level bars line up.
                item._menuitem.setAttributedTitle_(
                    NSAttributedString.alloc().initWithString_attributes_(text, mono)
                )
                item._menuitem.setHidden_(not text)

        def toggle_record(self, sender):
            key = next(k for k, item in self.record_items.items() if item is sender)
            sender.state = toggle_auto_record(key, record_defaults)
            if not sender.state:  # its call stops now, as the old switch did ("auto_off")
                self.daemon.switched_off(SWITCH_APP[key])
            self.refresh()

        def toggle_manual(self, sender):
            action = manual_action(sender.title, self.daemon.status()["state"] == "recording")
            if action == "stop":
                self.daemon.stop_manual()
            elif action == "start":
                self.daemon.start_manual()
            self.refresh()

        def keep_recording(self, _sender):
            self.daemon.answer_stop_question("keep")
            self.refresh()

        def _refresh_calendar_item(self):
            try:
                connected = calendar_access()
            except Exception:
                connected = False
            if connected and not getattr(self, "_calendar_connected", False) and cfg.calendar_enabled:
                threading.Thread(target=self._attach_calendar_events, daemon=True).start()
            self._calendar_connected = connected
            self.calendar_item.title = "Calendar connected" if connected else "Connect Calendar…"
            self.calendar_item.set_callback(None if connected else self.connect_calendar)

        def _attach_calendar_events(self, since=None):
            from .calendar_eventkit import events_between

            try:
                attach_calendar_events(cfg.output_dir, events_between, since,
                                       user_name=settings.current_user_name(cfg.user_name))
            except Exception as exc:  # the next start tries again
                print(f"warning: attaching calendar events failed: {exc}")

        def connect_calendar(self, _sender):
            def done(granted):  # on an EventKit thread: notify, the menu updates on the next tick
                if granted:
                    notify.notify("Calendar connected", "Meetings get their title and invitees from your calendar.")
                else:
                    notify.notify("No calendar access", "Allow it in System Settings → Privacy & Security → Calendars.")

            request_calendar_access(done)

        def open_meetings(self, _sender):
            open_window(self.web.url())

        def install_update(self, _sender):
            self.updates.install()
            self.refresh()

        def report_problem(self, _sender):
            """One form for the report, in the window (#59): its server writes the zip."""
            usage.record("action", "menubar.reportProblem")
            open_window(self.web.url("report"))

        def quit(self, _sender):
            # The user's own stop: the recording is processed now. A quit from
            # outside (SIGTERM: an update, a restart) holds a call's recording
            # for the next start to continue (issue #47).
            self.quit_reason = "by_you"
            rumps.quit_application()  # before_quit finalizes the recording

    def on_main(fn, timeout: float = appctl.MAIN_THREAD_TIMEOUT):
        """``fn()`` on the main thread, where the daemon ticks; its result.
        Called from the app socket's threads."""
        done, result, error = threading.Event(), [], []

        def run():
            try:
                result.append(fn())
            except Exception as exc:
                error.append(exc)
            finally:
                done.set()

        AppHelper.callAfter(run)
        if not done.wait(timeout):
            raise TimeoutError("the menu bar app is busy")
        if error:
            raise error[0]
        return result[0]

    def start_timer(app) -> None:
        app.timer.start()
        # rumps schedules timers for the default run-loop mode only; add the
        # common modes so the live lines keep updating while the menu is open.
        NSRunLoop.currentRunLoop().addTimer_forMode_(app.timer._nstimer, NSRunLoopCommonModes)

    MeetingApp.start_timer = start_timer
    app = MeetingApp()
    # A click on one of the app's notifications opens its meeting.
    notify.on_click(lambda meeting: AppHelper.callAfter(open_window, app.web.url(meeting)))

    @rumps.events.before_quit.register
    def _finalize():
        finalize(app)

    return app


def run_app(cfg, cli_options: list[str] = ()) -> None:  # pragma: no cover - UI shell
    from .daemon import LOG_PATH
    from .session_log import session_log

    import signal

    import rumps

    from PyObjCTools import AppHelper

    from . import runlog
    from .session_log import event

    # rumps prints a failed callback's traceback and goes on, as PyObjC's event loop does: into the crash log too.
    runlog.log_printed_exceptions(rumps.rumps, "palaver menubar callback")
    runlog.log_printed_exceptions(AppHelper, "palaver menubar event loop")
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with session_log(LOG_PATH):
        event("app_start")
        app = create_app(cfg, cli_options)
        # Off the main thread: the system-audio tap blocks until its prompt is
        # answered, and the menu bar icon should be up while the user decides.
        threading.Thread(target=request_permissions, daemon=True).start()
        # Handled on the next timer tick (Python runs signal handlers between
        # bytecodes), which then quits through before_quit.
        signal.signal(signal.SIGTERM, lambda *_: rumps.quit_application())
        app.start_timer()
        app.refresh()
        app.run()
