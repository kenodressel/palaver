"""The meetings app: a small HTTP server on 127.0.0.1 serving the page in
``static/`` and the JSON API from api.py. The menu bar app runs it in its
own process (process.py, #57).

Only this machine can reach it. Against other web pages in the browser
(DNS rebinding, cross-site requests) it accepts only its own Host header and
JSON bodies, which a foreign page cannot send without a CORS preflight that
this server never answers.
"""

from __future__ import annotations

import json
import logging
import re
import socket
import sys
import tempfile
import threading
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable
from urllib.parse import parse_qs, unquote, urlparse

from .. import exchange, model_jobs, undo
from ..settings import Settings
from . import api
from .process import Inflight

LOGGER = logging.getLogger(__name__)
DEFAULT_PORT = 8765
STATIC = Path(__file__).parent / "static"
_CONTENT_TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
                  ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml", ".woff2": "font/woff2"}
# A browser asks for open-ended ranges ("bytes=0-"); answer in slices so a
# one-hour recording is never mixed in one go.
AUDIO_SLICE_BYTES = 1 << 21


# The user's own notes (#44) of a meeting or an upcoming one: the document,
# its images (one, or its deletion), clearing it.
_MY_NOTES = re.compile(r"/api/(meetings|upcoming)/([^/]+)/my-notes(?:/(images|clear)(?:/([^/]+)(/delete)?)?)?")


# Request bodies: an image pasted into the notes (base64) may be large; nothing else is.
MAX_IMAGE_BODY = 35 * 1024 * 1024
MAX_BODY = 2 * 1024 * 1024
# A .palaver file to import (#58): at most what exchange.py unpacks, and its zip headers.
MAX_IMPORT_BODY = exchange.MAX_FILE_BYTES


# The Settings page's changes: counted by key in the usage log (#59), never with a secret.
_SETTINGS_PATHS = ("/api/settings", "/api/language-model", "/api/language-model/key", "/api/transcription",
                   "/api/transcription/key")


def _body_limit(path: str) -> int:
    return MAX_IMAGE_BODY if re.fullmatch(r"/api/(meetings|upcoming)/[^/]+/my-notes/images", path) else MAX_BODY


class App:
    """What the handler needs: where recordings are, and how to run the
    language model (notes; sorting meetings into projects).

    ``recording``: the menu bar app's running recording, when there is one
    to ask about: ``question()`` the open question whether to stop a manual
    recording (or None), ``answer(choice, meeting)`` "stop" / "keep", False
    when that recording no longer runs (api.answer_recording_question)."""

    def __init__(self, output_dir: Path, user_name: str,
                 write_notes: Callable[[str], bool] | None = None,
                 run_projects: Callable[[list[str]], bool] | None = None,
                 calendar: Callable | None = None, settings: Settings = Settings(),
                 recording=None, cli_options: list[str] = (), cfg=None, probe=None,
                 ask_model: Callable[[str, dict], dict] | None = None,
                 free_memory_gb: Callable[[], float] = lambda: float("inf"), downloads: Path | None = None):
        from .. import onboarding

        self.output_dir = output_dir
        self.downloads = downloads or Path.home() / "Downloads"  # where an export is saved (#58)
        # The setup assistant's look at this Mac (#55); its downloads and test
        # recording run only when the user starts them.
        self.probe = probe if probe is not None else onboarding.Probe(cfg)
        self.cli_options = list(cli_options)  # global CLI options (--config) for what the app starts
        self.cfg = cfg  # config.toml, for the language model's defaults (None: its defaults)
        self.recording = recording
        self.user_name = user_name
        self.settings = settings  # the defaults for what settings.json leaves out
        self.calendar = calendar  # (start, end) -> events, for meetings still to come
        self.write_notes = write_notes
        self.run_projects = run_projects
        self.notes_lock = threading.Lock()  # one language model at a time
        self.notes_jobs: dict[str, dict] = {}  # meeting id -> the notes job running for it
        self.notes_jobs_lock = threading.Lock()
        # The best next question (#41): (meeting id, inputs) -> {"questions", "engine"}, in a
        # helper process; and the free memory, checked before a local model starts.
        self.ask_model = ask_model
        self.free_memory_gb = free_memory_gb
        # The language model's jobs on disk (#57): a restarted server finds them.
        self.jobs = model_jobs.jobs_root(output_dir)
        # Changes being made now: a stopping server lets them finish (process.py).
        self.inflight = Inflight()


def sweep_leftovers(app: App) -> None:
    """At a start: what an import cut short by a stop left behind (#58).
    Not Downloads: macOS may ask the user before the server may look there,
    and a start would wait on the answer; the next export sweeps it."""
    try:
        exchange.sweep(app.output_dir)
    except OSError:
        LOGGER.warning("could not sweep import and export leftovers", exc_info=True)


def _handler(app: App, port: int) -> type[BaseHTTPRequestHandler]:
    allowed_hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}

    class Handler(BaseHTTPRequestHandler):
        server_version = "palaver"

        def log_message(self, fmt, *args):  # quiet; errors are logged below
            LOGGER.debug(fmt, *args)

        def log_request(self, code="-", size="-"):
            """Changes (POSTs) and failed requests into the log (#59); the
            page's polling (GETs every few seconds) and its usage counts not."""
            status = int(code) if str(code).isdigit() else 0
            if status >= 400:
                LOGGER.warning("%s %s → %s", self.command, self.path, status)
            elif self.command == "POST" and self.path != "/api/usage":
                LOGGER.info("%s %s → %s", self.command, self.path, status)

        def _send(self, status: int, body: bytes, content_type: str, headers: dict | None = None):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _json(self, data: Any, status: int = 200):
            self._send(status, json.dumps(data, ensure_ascii=False).encode(), "application/json")

        def _error(self, status: int, message: str):
            self._json({"error": message}, status)

        def _host_ok(self) -> bool:
            return self.headers.get("Host", "") in allowed_hosts

        def do_GET(self):
            if not self._host_ok():
                return self._error(HTTPStatus.FORBIDDEN, "wrong host")
            url = urlparse(self.path)
            query = parse_qs(url.query)
            try:
                if url.path == "/api/ping":  # the page's heartbeat: "Reconnecting…" while there is no answer
                    return self._json({"ok": True})
                if url.path == "/api/model-jobs":
                    return self._json(api.model_jobs_view(app.output_dir, app.jobs))
                if url.path == "/api/meetings":
                    return self._json(api.list_meetings(app.output_dir))
                if url.path == "/api/names":
                    return self._json(api.known_names(app.output_dir, app.user_name))
                if url.path == "/api/people":
                    return self._json(api.directory(app.output_dir, app.user_name))
                if url.path == "/api/projects":
                    return self._json(api.list_projects(app.output_dir, user_name=app.user_name))
                if url.path == "/api/glossary":
                    return self._json(api.glossary_page(app.output_dir, user_name=app.user_name))
                if url.path == "/api/settings":
                    return self._json(api.get_settings(app.settings))
                if url.path == "/api/language-model":
                    return self._json(api.language_model(app.cfg))
                if url.path == "/api/transcription":
                    return self._json(api.transcription(app.cfg))
                if url.path == "/api/setup":
                    return self._json(api.setup_page(app))
                if url.path == "/api/setup/offer":
                    return self._json({"offer": api.setup_offer(app)})
                if url.path == "/api/setup/recommendations":
                    return self._json(api.setup_recommendations(app))
                if url.path == "/api/setup/downloads":
                    return self._json(api.setup_downloads(app))
                if url.path == "/api/setup/test":
                    return self._json(api.setup_test(app, {}))
                if url.path == "/api/recording/question":
                    return self._json(api.recording_question(app.recording))
                if url.path == "/api/recording/coach":
                    return self._json(api.live_coach(app.recording))
                if url.path == "/api/memory":
                    return self._json(api.memory_status(app.recording))
                if url.path == "/api/upcoming":
                    return self._json(api.upcoming(app.calendar))
                if url.path == "/api/mcp":
                    meeting = query.get("meeting", [None])[0]
                    return self._json(api.mcp_reads(meeting) if meeting else api.mcp_status())
                m = _MY_NOTES.fullmatch(url.path)
                if m:
                    return self._my_notes_get(m)
                m = re.fullmatch(r"/api/upcoming/([^/]+)", url.path)
                if m:
                    return self._json(api.upcoming_meeting(app.output_dir, app.calendar, unquote(m.group(1)),
                                                           user_name=app.user_name))
                if url.path == "/api/coach":
                    return self._json(api.coach_overview(app.output_dir, user_name=app.user_name))
                m = re.fullmatch(r"/api/meetings/([^/]+)/coach", url.path)
                if m:
                    return self._json(api.coach_meeting(app.output_dir, m.group(1), user_name=app.user_name))
                m = re.fullmatch(r"/api/meetings/([^/]+)/events", url.path)
                if m:
                    return self._json(api.meeting_events(app.output_dir, m.group(1), app.calendar))
                if url.path == "/api/questions":
                    return self._json(api.open_questions(app.output_dir, user_name=app.user_name))
                if url.path == "/api/needs":
                    return self._json(api.needs(app.output_dir, user_name=app.user_name, calendar=app.calendar))
                if url.path == "/api/review":
                    return self._json(api.review_queue(app.output_dir, user_name=app.user_name))
                if url.path == "/api/search":
                    q = query.get("q", [""])[0]
                    return self._json(api.search_page(app.output_dir, q, user_name=app.user_name))
                if url.path == "/api/search/status":
                    return self._json(api.search_status(app.recording))
                if url.path == "/api/search/meaning":
                    q = query.get("q", [""])[0]
                    return self._json(api.search_meaning(app.output_dir, q, user_name=app.user_name))
                m = re.fullmatch(r"/api/meetings/([^/]+)/next-question", url.path)
                if m:
                    return self._json(api.next_question_info(app.cfg, app.output_dir, m.group(1),
                                                             enabled=app.ask_model is not None))
                m = re.fullmatch(r"/api/meetings/([^/]+)/stream", url.path)
                if m:
                    try:
                        since = float(query.get("since", ["0"])[0])
                    except ValueError:
                        since = 0.0
                    return self._json(api.live_stream(app.output_dir, m.group(1), user_name=app.user_name,
                                                      since=since))
                m = re.fullmatch(r"/api/meetings/([^/]+)", url.path)
                if m:
                    return self._json(api.get_meeting(app.output_dir, m.group(1), user_name=app.user_name,
                                                      calendar=app.calendar))
                m = re.fullmatch(r"/api/meetings/([^/]+)/audio", url.path)
                if m:
                    return self._audio(m.group(1), query.get("track", ["mix"])[0])
                return self._static(url.path)
            except api.NotFound as exc:
                return self._error(HTTPStatus.NOT_FOUND, f"not found: {exc}")
            except ConnectionError:  # the page let go, e.g. the player seeked: nobody to answer
                return None
            except Exception as exc:  # keep serving; show the error in the page
                LOGGER.exception("GET %s failed", self.path)
                return self._error(HTTPStatus.INTERNAL_SERVER_ERROR, str(exc))

        do_HEAD = do_GET

        def do_POST(self):
            with app.inflight.change():
                return self._post()

        def _post(self):
            if not self._host_ok():
                return self._error(HTTPStatus.FORBIDDEN, "wrong host")
            if urlparse(self.path).path == "/api/import":
                return self._import()
            if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json":
                return self._error(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, "JSON only")
            try:
                length = int(self.headers.get("Content-Length") or 0)
                if length > _body_limit(self.path):  # refused before it is read
                    self.close_connection = True
                    return self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "too large")
                body = json.loads(self.rfile.read(length) or b"{}")
                m = _MY_NOTES.fullmatch(self.path)
                if m:
                    return self._my_notes_post(m, body)
                m = re.fullmatch(r"/api/meetings/([^/]+)/speakers", self.path)
                if m:
                    token = api.name_speaker(app.output_dir, m.group(1), str(body["label"]), str(body.get("name", "")))
                    meeting = api.get_meeting(app.output_dir, m.group(1), user_name=app.user_name)
                    return self._json({**meeting, "undo": token} if token else meeting)
                m = re.fullmatch(r"/api/meetings/([^/]+)/split", self.path)
                if m:
                    discard = body.get("discard")
                    return self._json(api.split_meeting(app.output_dir, m.group(1), float(body["at"]),
                                                        join_next=bool(body.get("join_next")),
                                                        discard=None if discard is None else str(discard),
                                                        user_name=app.user_name, calendar=app.calendar))
                m = re.fullmatch(r"/api/meetings/([^/]+)/join", self.path)
                if m:
                    return self._json(api.join_meetings(app.output_dir, m.group(1), str(body["with"]),
                                                        user_name=app.user_name))
                m = re.fullmatch(r"/api/meetings/([^/]+)/shared", self.path)
                if m:
                    label, series, name = body.get("label"), body.get("series"), body.get("name")
                    if not isinstance(body.get("on"), bool) or not isinstance(series, (bool, type(None))):
                        raise ValueError("'on' and 'series' are true or false")
                    if not isinstance(name, (str, type(None))):
                        raise ValueError("a room's name is text")
                    token = api.set_shared(app.output_dir, m.group(1), on=body["on"],
                                           label=None if label is None else str(label), name=name, series=series)
                    return self._json({**api.get_meeting(app.output_dir, m.group(1), user_name=app.user_name,
                                                         calendar=app.calendar), "undo": token})
                m = re.fullmatch(r"/api/meetings/([^/]+)/shared-series", self.path)
                if m:
                    if not isinstance(body.get("remember"), bool):
                        raise ValueError("'remember' is true or false")
                    token = api.remember_series(app.output_dir, m.group(1), body["remember"])
                    return self._json({**api.get_meeting(app.output_dir, m.group(1), user_name=app.user_name,
                                                         calendar=app.calendar), "undo": token})
                m = re.fullmatch(r"/api/meetings/([^/]+)/shared-suggestion", self.path)
                if m:
                    api.dismiss_shared_suggestion(app.output_dir, m.group(1), bool(body.get("dismiss", True)))
                    return self._json(api.get_meeting(app.output_dir, m.group(1), user_name=app.user_name,
                                                      calendar=app.calendar))
                m = re.fullmatch(r"/api/meetings/([^/]+)/cut-suggestion", self.path)
                if m:
                    api.dismiss_cut(app.output_dir, m.group(1), bool(body.get("dismiss", True)))
                    return self._json(api.get_meeting(app.output_dir, m.group(1), user_name=app.user_name,
                                                      calendar=app.calendar))
                m = re.fullmatch(r"/api/meetings/([^/]+)/line", self.path)
                if m:
                    text = body.get("text")
                    api.edit_line(app.output_dir, m.group(1), start=float(body["start"]),
                                  text=None if text is None else str(text))
                    return self._json(api.get_meeting(app.output_dir, m.group(1), user_name=app.user_name,
                                                      calendar=app.calendar))
                m = re.fullmatch(r"/api/meetings/([^/]+)/title", self.path)
                if m:
                    token = api.set_title(app.output_dir, m.group(1), body["title"])
                    return self._json({**api.get_meeting(app.output_dir, m.group(1), user_name=app.user_name,
                                                         calendar=app.calendar), "undo": token})
                m = re.fullmatch(r"/api/meetings/([^/]+)/export", self.path)
                if m:
                    return self._json(api.export_meeting(
                        app.output_dir, m.group(1), app.downloads, user_name=app.user_name,
                        notes=bool(body.get("notes", True)), voices=bool(body.get("voices")),
                        audio=bool(body.get("audio")), confirm_local=bool(body.get("confirm_local"))))
                m = re.fullmatch(r"/api/meetings/([^/]+)/imported-voices", self.path)
                if m:
                    if not isinstance(body.get("add"), bool):
                        raise ValueError("'add' is true or false")
                    token = api.decide_imported_voices(app.output_dir, m.group(1), body["add"],
                                                       user_name=app.user_name)
                    return self._json({**api.get_meeting(app.output_dir, m.group(1), user_name=app.user_name,
                                                         calendar=app.calendar), "undo": token})
                m = re.fullmatch(r"/api/meetings/([^/]+)/trash", self.path)
                if m:
                    token = api.trash_meeting(app.output_dir, m.group(1), user_name=app.user_name)
                    return self._json({"trashed": m.group(1), "undo": token})
                m = re.fullmatch(r"/api/recording/(stop|keep)", self.path)
                if m:
                    return self._json(api.answer_recording_question(app.recording, m.group(1), str(body["meeting"])))
                if self.path == "/api/mcp/clear":
                    return self._json(api.clear_mcp_log())
                if self.path == "/api/mcp/restore":
                    return self._json(api.restore_mcp_log(str(body["token"])))
                if self.path == "/api/mcp/install":
                    return self._json(api.install_mcp(str(body.get("target") or "code"), app.cli_options))
                if self.path == "/api/model-jobs/seen":
                    model_jobs.seen(app.jobs, str(body["token"]))
                    return self._json(api.model_jobs_view(app.output_dir, app.jobs))
                if self.path == "/api/undo":
                    return self._json({"restored": api.undo_change(app.output_dir, str(body["token"]),
                                                                   user_name=app.user_name)})
                m = re.fullmatch(r"/api/meetings/([^/]+)/event", self.path)
                if m:
                    key = body.get("key")
                    token = api.set_meeting_event(app.output_dir, m.group(1), app.calendar,
                                                  key=None if key is None else str(key), user_name=app.user_name)
                    return self._json({**api.get_meeting(app.output_dir, m.group(1), user_name=app.user_name,
                                                         calendar=app.calendar), "undo": token})
                m = re.fullmatch(r"/api/meetings/([^/]+)/remove", self.path)
                if m:
                    api.remove_speaker(app.output_dir, m.group(1), str(body["label"]), bool(body.get("removed", True)))
                    return self._json(api.get_meeting(app.output_dir, m.group(1), user_name=app.user_name))
                m = re.fullmatch(r"/api/meetings/([^/]+)/unknown", self.path)
                if m:
                    if not isinstance(body.get("on"), bool):
                        raise ValueError("'on' is true or false")
                    token = api.set_unknown(app.output_dir, m.group(1), str(body["label"]), body["on"])
                    return self._json({**api.get_meeting(app.output_dir, m.group(1), user_name=app.user_name,
                                                         calendar=app.calendar), "undo": token})
                m = re.fullmatch(r"/api/meetings/([^/]+)/merge", self.path)
                if m:
                    into = body.get("into")
                    token = api.merge_speaker(app.output_dir, m.group(1), str(body["label"]),
                                              None if into is None else str(into))
                    meeting = api.get_meeting(app.output_dir, m.group(1), user_name=app.user_name)
                    return self._json({**meeting, "undo": token} if token else meeting)
                if self.path == "/api/rules/forget":
                    return self._json({"undo": api.forget_rule(app.output_dir, str(body["series"]))})
                if self.path == "/api/organizations":
                    api.rename_organization(str(body["key"]), str(body.get("name", "")))
                    return self._json(api.directory(app.output_dir))
                if self.path == "/api/people/org":
                    org = body.get("org")
                    api.set_person_org(str(body["name"]), None if org is None else str(org))
                    return self._json(api.directory(app.output_dir))
                if self.path == "/api/people/rename":
                    token = api.rename_person(app.output_dir, str(body["old"]), str(body["new"]))
                    return self._json({**api.directory(app.output_dir), "undo": token})
                if self.path == "/api/voices/name":
                    members = [(str(m), str(l)) for m, l in body["voices"]]
                    token = api.name_voices(app.output_dir, members, str(body["name"]))
                    return self._json({**api.directory(app.output_dir), "undo": token})
                m = re.fullmatch(r"/api/meetings/([^/]+)/notes", self.path)
                if m:
                    return self._notes(m.group(1))
                m = re.fullmatch(r"/api/meetings/([^/]+)/next-question", self.path)
                if m:
                    return self._next_question(m.group(1), body)
                m = re.fullmatch(r"/api/meetings/([^/]+)/reviewed", self.path)
                if m:
                    api.mark_reviewed(app.output_dir, m.group(1), bool(body.get("done", True)), calendar=app.calendar)
                    return self._json(api.review_queue(app.output_dir, user_name=app.user_name))
                m = re.fullmatch(r"/api/upcoming/([^/]+)/projects", self.path)
                if m:
                    key = unquote(m.group(1))
                    project, name = body.get("project"), body.get("name")
                    api.set_upcoming_project(app.calendar, key, project=None if project is None else str(project),
                                             name=None if name is None else str(name), remove=bool(body.get("remove")))
                    return self._json(api.upcoming_meeting(app.output_dir, app.calendar, key, user_name=app.user_name))
                if self.path == "/api/usage":
                    return self._json(api.record_usage(body))
                if self.path == "/api/report":
                    return self._json(api.create_report(app, body))
                if self.path in _SETTINGS_PATHS:
                    answer = self._settings_post(body)
                    api.count_setting(self.path, body)
                    return self._json(answer)
                if self.path.startswith("/api/setup/"):
                    return self._setup_post(body)
                if self.path == "/api/language-model/test":
                    return self._model_test(body)
                if self.path == "/api/transcription/test":
                    return self._model_test(body, test=api.test_transcription)
                m = re.fullmatch(r"/api/meetings/([^/]+)/local-only", self.path)
                if m:
                    api.set_local_only(app.output_dir, m.group(1), bool(body.get("on", True)))
                    return self._json(api.get_meeting(app.output_dir, m.group(1), user_name=app.user_name,
                                                      calendar=app.calendar))
                if self.path.startswith("/api/glossary"):
                    return self._glossary_post(body)
                m = re.fullmatch(r"/api/meetings/([^/]+)/projects", self.path)
                if m:
                    project, name = body.get("project"), body.get("name")
                    token = api.set_meeting_project(app.output_dir, m.group(1),
                                                    project=None if project is None else str(project),
                                                    name=None if name is None else str(name),
                                                    remove=bool(body.get("remove")))
                    return self._json({**api.get_meeting(app.output_dir, m.group(1), user_name=app.user_name),
                                       "undo": token})
                return self._projects_post(body)
            except undo.Gone:
                return self._error(HTTPStatus.NOT_FOUND, "can't undo this any more")
            except undo.Changed:
                return self._error(HTTPStatus.CONFLICT, "the meeting changed since")
            except api.NotFound as exc:
                return self._error(HTTPStatus.NOT_FOUND, f"not found: {exc}")
            except api.Refused as exc:
                return self._error(HTTPStatus.BAD_REQUEST, str(exc))
            except (KeyError, ValueError) as exc:
                return self._error(HTTPStatus.BAD_REQUEST, f"bad request: {exc}")
            except ConnectionError:
                return None
            except Exception as exc:
                LOGGER.exception("POST %s failed", self.path)
                return self._error(HTTPStatus.INTERNAL_SERVER_ERROR, str(exc))

        def _import(self):
            """A .palaver file, as the bytes it is (not JSON: it may be large).
            A foreign page can't send this type without a CORS preflight,
            which this server never answers. Kept in a temporary file while
            it is checked and imported."""
            if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/octet-stream":
                return self._error(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, "a .palaver file only")
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = -1
            if not 0 < length <= MAX_IMPORT_BODY:
                self.close_connection = True
                return self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE if length > 0 else HTTPStatus.BAD_REQUEST,
                                   "Not imported: the file is too large." if length > 0 else "no file")
            query = parse_qs(urlparse(self.path).query)
            with tempfile.TemporaryDirectory(prefix="palaver-import-") as tmp:
                file = Path(tmp) / "import.palaver"
                with file.open("wb") as sink:
                    left = length
                    while left:
                        chunk = self.rfile.read(min(left, 1 << 20))
                        if not chunk:
                            return self._error(HTTPStatus.BAD_REQUEST, "Not imported: the file arrived only in part.")
                        sink.write(chunk)
                        left -= len(chunk)
                try:
                    return self._json(api.import_meeting(app.output_dir, file, user_name=app.user_name,
                                                         separate=query.get("separate", [""])[0] == "1",
                                                         calendar=app.calendar))
                except api.Refused as exc:
                    return self._error(HTTPStatus.BAD_REQUEST, str(exc))
                except Exception as exc:
                    LOGGER.exception("import failed")
                    return self._error(HTTPStatus.INTERNAL_SERVER_ERROR, f"Not imported: {exc}")

        def _notes_folder(self, m: re.Match) -> Path:
            """The folder of the notes a /my-notes path is about: a meeting's,
            or an upcoming meeting's (prep)."""
            if m.group(1) == "meetings":
                return api.my_notes_folder(app.output_dir, m.group(2))
            return api.prep_notes_folder(app.calendar, unquote(m.group(2)))

        def _my_notes_get(self, m: re.Match):
            if m.group(1) == "meetings" and not m.group(3):
                api.adopt_prepared_notes(app.output_dir, m.group(2), app.calendar)
            folder = self._notes_folder(m)
            if m.group(3) == "images" and m.group(4) and not m.group(5):
                data, content_type = api.my_notes_image(folder, m.group(4))
                return self._send(200, data, content_type)
            if m.group(3):
                return self._error(HTTPStatus.NOT_FOUND, "not found")
            return self._json(api.get_my_notes(folder))

        def _my_notes_post(self, m: re.Match, body: dict):
            from .. import my_notes

            folder = self._notes_folder(m)
            what, name, delete = m.group(3), m.group(4), m.group(5)
            if not what:
                try:
                    return self._json(api.save_my_notes(folder, body))
                except my_notes.Conflict as exc:  # changed elsewhere: the editor merges
                    return self._json({"error": str(exc), "document": exc.document}, HTTPStatus.CONFLICT)
            if what == "images" and not name:
                return self._json(api.add_my_notes_image(folder, body))
            if what == "images" and delete:
                return self._json(api.delete_my_notes_image(app.output_dir, folder, name))
            if what == "clear" and not name:
                return self._json(api.clear_my_notes(app.output_dir, folder))
            return self._error(HTTPStatus.NOT_FOUND, "not found")

        def _settings_post(self, body: dict):
            """A change on the Settings page: switches, the language model, transcription, their keys."""
            if self.path == "/api/settings":
                answer = api.set_settings(body, app.settings)
                api.switches_turned_off(app.recording, body)
                return answer
            routes = {"/api/language-model": api.set_language_model, "/api/language-model/key": api.set_provider_key,
                      "/api/transcription": api.set_transcription, "/api/transcription/key": api.set_transcription_key}
            return routes[self.path](app.cfg, body)

        def _setup_post(self, body: dict):
            """The setup assistant's changes (#55): each one the user's click."""
            routes = {"/api/setup/apply": api.apply_setup, "/api/setup/profile": api.setup_profile,
                      "/api/setup/glossary": api.seed_glossary, "/api/setup/autostart": api.setup_autostart,
                      "/api/setup/finish": api.finish_setup, "/api/setup/downloads": api.start_downloads,
                      "/api/setup/test": api.setup_test}
            if self.path not in routes:
                return self._error(HTTPStatus.NOT_FOUND, "not found")
            return self._json(routes[self.path](app, body))

        def _model_test(self, body: dict, test=api.test_provider):
            """The Test button: the provider's answer, or why it failed (502)."""
            from ..notes import NotesError

            try:
                return self._json(test(app.cfg, body))
            except NotesError as exc:  # its message never holds the key (cloud_llm.redact)
                return self._error(HTTPStatus.BAD_GATEWAY, str(exc))

        def _glossary_post(self, body: dict):
            """Glossary changes; each answers with what changed in the
            meetings and the glossary page."""
            changed, token = None, None
            if self.path == "/api/glossary/respell":  # from a meeting: no glossary page needed
                return self._json(api.respell(app.output_dir, heard=str(body["heard"]), term=str(body["term"])))
            if self.path == "/api/glossary/accept":
                changed = api.accept_suggestion(app.output_dir, term=str(body["term"]),
                                                variants=[str(v) for v in body.get("variants", [])],
                                                note=str(body.get("note", "")))
            elif self.path == "/api/glossary/reject":
                keys = body["keys"] if isinstance(body.get("keys"), list) else [body["key"]]
                token = api.reject_suggestion(app.output_dir, [str(k) for k in keys])
            elif m := re.fullmatch(r"/api/glossary/([0-9a-f]+)", self.path):
                term, note, remove = body.get("term"), body.get("note"), body.get("remove_variant")
                changed = api.update_term(app.output_dir, m.group(1),
                                          term=None if term is None else str(term),
                                          note=None if note is None else str(note),
                                          remove_variant=None if remove is None else str(remove),
                                          add_variants=[str(v) for v in body.get("add_variants", [])],
                                          delete=bool(body.get("delete")))
                token = changed.pop("undo", None)
            else:
                return self._error(HTTPStatus.NOT_FOUND, "not found")
            answer = {"changed": changed, **api.glossary_page(app.output_dir, user_name=app.user_name)}
            return self._json({**answer, "undo": token} if token else answer)

        def _projects_post(self, body: dict):
            """Changes on the Projects page; each answers with all projects."""
            token = None
            if self.path == "/api/projects":
                api.create_project(str(body["name"]), str(body.get("description", "")))
            elif self.path == "/api/projects/suggest":
                if not (token := self._model(["suggest"], "sort projects", body.get("label"))):
                    return None
            elif m := re.fullmatch(r"/api/projects/([0-9a-f]+)", self.path):
                name, description = body.get("name"), body.get("description")
                token = api.update_project(app.output_dir, m.group(1), name=None if name is None else str(name),
                                           description=None if description is None else str(description))
            elif m := re.fullmatch(r"/api/projects/([0-9a-f]+)/merge", self.path):
                token = api.merge_projects(app.output_dir, m.group(1), str(body["into"]))
            elif m := re.fullmatch(r"/api/projects/([0-9a-f]+)/delete", self.path):
                token = api.delete_project(app.output_dir, m.group(1))
            elif m := re.fullmatch(r"/api/projects/([0-9a-f]+)/describe", self.path):
                if not (token := self._model(["describe", m.group(1)], "describe project", body.get("label"))):
                    return None
            else:
                return self._error(HTTPStatus.NOT_FOUND, "not found")
            answer = api.list_projects(app.output_dir, user_name=app.user_name)
            return self._json({**answer, "undo": token} if token else answer)

        def _model(self, args: list[str], label: str, page_label=None) -> str | None:
            """Run `palaver projects ARGS`, undoable (``label``): returns the
            undo token; on failure answers with the error and returns None.
            ``page_label``: what the page calls the change, for its undo
            when this server is gone by the time the run ends (#57)."""
            if app.run_projects is None:
                self._error(HTTPStatus.SERVICE_UNAVAILABLE, "the language model is turned off")
                return None
            if any(j["kind"] == "projects" for j in model_jobs.running(app.jobs)):  # an earlier server's run
                self._error(HTTPStatus.CONFLICT, "the language model is busy; try again in a minute")
                return None
            if not app.notes_lock.acquire(blocking=False):
                self._error(HTTPStatus.CONFLICT, "the language model is busy; try again in a minute")
                return None
            from ..cli import ModelBusy, notes_lock_free

            # Not while the daemon holds the model: the snapshot would be stale
            # by the time the run got its turn.
            try:
                if not notes_lock_free():
                    self._error(HTTPStatus.CONFLICT, "the language model is busy; try again in a minute")
                    return None
                with app.inflight.detached():  # the run is the app's: a restart need not wait for it
                    token = api.model_change(app.output_dir, label, lambda: app.run_projects(args),
                                             jobs=app.jobs, page_label=str(page_label or label))
            except ModelBusy:  # the daemon got in between; nothing changed
                self._error(HTTPStatus.CONFLICT, "the language model is busy; try again in a minute")
                return None
            finally:
                app.notes_lock.release()
            if token is None:
                self._error(HTTPStatus.BAD_GATEWAY, "the language model failed; see the log")
            return token

        def _next_question(self, meeting_id: str, body: dict):
            """1–3 questions to ask next (#41), on the user's click. The local
            model during a call needs a second click (``confirmed``)."""
            from ..next_question import NothingYet
            from ..notes import NotesError

            info = api.next_question_info(app.cfg, app.output_dir, meeting_id, enabled=app.ask_model is not None)
            if app.ask_model is None:
                return self._error(HTTPStatus.SERVICE_UNAVAILABLE, info["reason"])
            if not info["ready"]:
                raise api.Refused(info["reason"])
            problem = api.next_question_problem(app.cfg, app.output_dir, meeting_id, free_gb=app.free_memory_gb())
            if problem:
                raise api.Refused(problem)
            if info["warning"] and body.get("confirmed") is not True:
                return self._error(HTTPStatus.CONFLICT, info["warning"])
            try:
                coach = api.live_coach(app.recording)["coach"]
                inputs = api.next_question_inputs(app.output_dir, meeting_id, user_name=app.user_name,
                                                  calendar=app.calendar, coach=coach, cfg=app.cfg)
                from ..next_question import build_prompt

                build_prompt(inputs)  # nothing said yet: say so before a model starts
            except NothingYet:
                raise api.Refused("Nothing has been said yet. Ask again once the meeting has started.") from None
            if not app.notes_lock.acquire(blocking=False):
                return self._error(HTTPStatus.CONFLICT, "the language model is busy; try again in a minute")
            try:
                return self._json(app.ask_model(meeting_id, inputs))
            except NotesError as exc:
                return self._error(HTTPStatus.BAD_GATEWAY, str(exc))
            finally:
                app.notes_lock.release()

        def _notes(self, meeting_id: str):
            api.meeting_paths(app.output_dir, meeting_id)
            if app.write_notes is None:
                return self._error(HTTPStatus.SERVICE_UNAVAILABLE, "notes are turned off")
            # One notes job at a time (each starts a large local model): a second
            # request for the same meeting waits for the running job and shares its
            # result; one for another meeting waits its turn. A job an earlier
            # server started (#57) is waited for too, never started again.
            with app.notes_jobs_lock:
                job = app.notes_jobs.get(meeting_id)
                leader = job is None
                if leader:
                    job = app.notes_jobs[meeting_id] = {"done": threading.Event(), "ok": False}
            with app.inflight.detached():  # the run is the app's: a restart need not wait for it
                if leader:
                    try:
                        earlier = model_jobs.read(app.jobs, "notes", meeting_id)
                        if earlier and earlier.get("state") == "running" and not earlier.get("stale"):
                            done = model_jobs.wait(app.jobs, "notes", meeting_id)
                            model_jobs.clear(app.jobs, "notes", meeting_id)
                            job["ok"] = done.get("returncode") == 0
                        else:
                            with app.notes_lock:
                                job["ok"] = bool(app.write_notes(meeting_id))
                    finally:
                        with app.notes_jobs_lock:
                            app.notes_jobs.pop(meeting_id, None)
                        job["done"].set()
                else:
                    job["done"].wait()
            ok = job["ok"]
            if not ok:
                return self._error(HTTPStatus.BAD_GATEWAY, "The language model could not write the notes; see the log")
            return self._json(api.get_meeting(app.output_dir, meeting_id, user_name=app.user_name))

        def _audio(self, meeting_id: str, track: str):
            source = api.AudioSource(api.meeting_paths(app.output_dir, meeting_id), track)
            m = re.fullmatch(r"bytes=(\d*)-(\d*)", self.headers.get("Range", "").strip())
            if not m or (not m.group(1) and not m.group(2)):
                start, end, status = 0, min(source.size, AUDIO_SLICE_BYTES) - 1, HTTPStatus.PARTIAL_CONTENT
            elif not m.group(1):  # last N bytes
                start, end, status = max(0, source.size - int(m.group(2))), source.size - 1, HTTPStatus.PARTIAL_CONTENT
            else:
                start = int(m.group(1))
                end = int(m.group(2)) if m.group(2) else start + AUDIO_SLICE_BYTES - 1
                end, status = min(end, source.size - 1, start + AUDIO_SLICE_BYTES - 1), HTTPStatus.PARTIAL_CONTENT
            if start >= source.size:
                self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                self.send_header("Content-Range", f"bytes */{source.size}")
                self.end_headers()
                return
            body = source.read(start, end) if self.command != "HEAD" else b""
            self.send_response(status)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Range", f"bytes {start}-{end}/{source.size}")
            self.send_header("Content-Length", str(end - start + 1))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _static(self, path: str):
            name = "index.html" if path in ("/", "") or not Path(path).suffix else path.lstrip("/")
            file = (STATIC / name).resolve()
            if STATIC.resolve() not in file.parents or not file.is_file():
                return self._error(HTTPStatus.NOT_FOUND, "not found")
            self._send(200, file.read_bytes(), _CONTENT_TYPES.get(file.suffix, "application/octet-stream"))

    return Handler


def make_server(app: App, port: int = DEFAULT_PORT, sock: socket.socket | None = None) -> ThreadingHTTPServer:
    """Bound to 127.0.0.1; ``port`` 0 picks a free one. ``sock``: a socket
    already listening, handed over by the menu bar app (#57), so a new
    server process answers on the same port."""
    if sock is None:
        server = ThreadingHTTPServer(("127.0.0.1", port), None)
    else:
        server = ThreadingHTTPServer(sock.getsockname(), None, bind_and_activate=False)
        server.socket.close()
        server.socket = sock
        server.server_address = sock.getsockname()
    server.RequestHandlerClass = _handler(app, server.server_address[1])
    server.daemon_threads = True

    def handle_error(request, client_address):
        """Into the log, not only to stderr; a page that let go is no error."""
        exc = sys.exc_info()[1]
        if isinstance(exc, ConnectionError):
            LOGGER.debug("the page let go of a request: %s", exc)
        else:
            LOGGER.exception("a request from %s failed", client_address)

    server.handle_error = handle_error
    return server


def url(server: ThreadingHTTPServer, meeting_id: str | None = None) -> str:
    base = f"http://127.0.0.1:{server.server_address[1]}/"
    return base + (f"#/{meeting_id}" if meeting_id else "")


def start_in_background(app: App, port: int = DEFAULT_PORT) -> ThreadingHTTPServer:
    server = make_server(app, port)
    threading.Thread(target=server.serve_forever, name="meetings-app", daemon=True).start()
    sweep_leftovers(app)
    # The first search after a start reads every meeting: do that before
    # it is asked, a little later and never during a recording (#46).
    api.start_warming(app.output_dir, user_name=app.user_name, recording=app.recording)
    return server


def open_in_browser(server: ThreadingHTTPServer, meeting_id: str | None = None) -> None:
    webbrowser.open(url(server, meeting_id))
