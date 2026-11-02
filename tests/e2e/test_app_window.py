"""The page in the app's own window (WKWebView), where only the app does
things: its dialogs, its menu bar, its script messages, and the way the
menu bar's icon and a notification open the window.

Real windows, but off-screen and invisible, and the app never activates:
no test shows a window or takes the focus. Needs a window server, so these
are integration tests (`pytest -m integration`). tests/test_window.py has the
menu bar's layout and the key handling on stand-in pages; these run on the
real page over the E2E recordings.
"""

import json

import pytest

pytest.importorskip("WebKit")

from tests.test_window import _hash, _menu_item, _perform, _press, _spin, _until, offscreen  # noqa: E402,F401

from .recordings import A, B, C, LIVE  # noqa: E402

pytestmark = pytest.mark.integration

# Collects what would be a JS error in the window: uncaught errors, unhandled
# rejections and console.error calls (the app has no other way to see them).
COLLECT_ERRORS = """
window.__errors = [];
addEventListener("error", (e) => __errors.push("error: " + e.message));
addEventListener("unhandledrejection", (e) => __errors.push("rejection: " + (e.reason && e.reason.message || e.reason)));
const consoleError = console.error.bind(console);
console.error = (...args) => { __errors.push("console.error: " + args.join(" ")); consoleError(...args); };
"""


def _js(web, script, timeout=10.0):
    """The value of ``script`` (a JSON string) in the page."""
    got = {}
    web.evaluateJavaScript_completionHandler_(f"JSON.stringify({script})",
                                              lambda value, error: got.update(value=value, error=error))
    assert _until(lambda: "value" in got, timeout), f"no answer to {script}"
    assert got["error"] is None, got["error"]
    return json.loads(got["value"]) if got["value"] is not None else None


def _load(web, url):
    from Foundation import NSURL, NSURLRequest

    web.loadRequest_(NSURLRequest.requestWithURL_(NSURL.URLWithString_(url)))


def _go(web, hash_):
    web.evaluateJavaScript_completionHandler_(f"location.hash = {json.dumps(hash_)}", None)
    assert _until(lambda: _hash(web) == hash_.lstrip("#"))


def _title(web):
    return _js(web, "document.querySelector('#main h1')?.textContent ?? null")


def _collect_errors(web):
    """Install COLLECT_ERRORS in the window's page (before it loads)."""
    from WebKit import WKUserScript, WKUserScriptInjectionTimeAtDocumentStart

    script = WKUserScript.alloc().initWithSource_injectionTime_forMainFrameOnly_(
        COLLECT_ERRORS, WKUserScriptInjectionTimeAtDocumentStart, True)
    web.configuration().userContentController().addUserScript_(script)


def _no_errors(web):
    _spin(0.2)  # what the page reports late
    assert _js(web, "window.__errors") == []


@pytest.fixture
def window_with_errors(offscreen):
    """The offscreen window; its test fails when the page reported an error."""
    win, web, delegate = offscreen
    _collect_errors(web)
    yield win, web, delegate
    _no_errors(web)


def test_the_page_loads_in_the_app_window_without_errors(window_with_errors, app_server):
    _, web, delegate = window_with_errors
    _load(web, app_server.url)
    assert _until(lambda: _hash(web) == "/today", 20), "the page never opened Today"
    assert _until(lambda: _title(web) == "Today")
    pages = [(f"#/{A}", "Team standup"), ("#/people", "People"), ("#/projects", "Projects"),
             ("#/glossary", "Glossary"), ("#/settings", "Settings"), ("#/review", "Design review, part two"),
             (f"#/{C}", "Design review, part two")]
    for where, title in pages:
        _go(web, where)
        assert _until(lambda: _title(web) == title), f"{where} showed {_title(web)!r}"
    _go(web, f"#/{A}")
    assert _until(lambda: {"trash", "writeNotes", "changeEvent"} <= delegate.enabled), \
        "the page did not tell the window which commands work"
    assert _js(web, "window.__errors") == []
    # The collector itself works: an error thrown now is seen.
    _js(web, "(setTimeout(() => { throw new Error('probe'); }), 1)")
    assert _until(lambda: _js(web, "window.__errors") == ["error: Error: probe"])
    _js(web, "(window.__errors.length = 0)")  # the probe's error is no finding


def test_dialogs_answer_in_the_app_window(window_with_errors):
    """The window's own delegate answers (the one open_window builds, with its message handler)."""
    win, web, _ = window_with_errors
    web.loadHTMLString_baseURL_("<p>dialogs</p>", None)
    _spin(0.5)
    for script, button, expected in [("confirm('Sure?') ? 'ok' : 'cancel'", "Cancel", "cancel"),
                                     ("confirm('Sure?') ? 'ok' : 'cancel'", "OK", "ok"),
                                     ("alert('Note'), 'done'", "OK", "done")]:
        got = {}
        web.evaluateJavaScript_completionHandler_(script, lambda value, error: got.update(value=value))
        assert _until(lambda: win.attachedSheet() is not None, 5), "no dialog shown"
        _press(win, button)
        assert _until(lambda: "value" in got, 5), "the page never got its answer"
        assert got["value"] == expected


def test_the_meeting_menu_follows_the_meeting_open(window_with_errors, app_server):
    _, web, _ = window_with_errors
    _load(web, app_server.url + f"#/{LIVE}")
    assert _until(lambda: _title(web) is not None and _title(web).startswith("Meeting at"), 20)
    trash = _menu_item("Meeting", "Move to Trash")[1]
    _spin(0.3)
    assert not trash.isEnabled()  # being recorded
    assert not _menu_item("Meeting", "Play/Pause")[1].isEnabled()  # nothing to play yet
    _go(web, f"#/{A}")
    assert _until(trash.isEnabled)
    assert not _menu_item("Meeting", "Join with Previous")[1].isEnabled()
    assert _menu_item("Meeting", "Play/Pause")[1].isEnabled()
    assert _menu_item("View", "Back")[1].isEnabled()
    _go(web, f"#/{C}")
    assert _until(_menu_item("Meeting", "Join with Previous")[1].isEnabled)
    _go(web, "#/people")
    assert _until(lambda: not trash.isEnabled())  # no meeting on the People page


def test_join_from_the_meeting_menu_and_edit_undo(window_with_errors, app_server):
    _, web, _ = window_with_errors
    _load(web, app_server.url + f"#/{C}")
    _, join = _menu_item("Meeting", "Join with Previous")
    assert _until(join.isEnabled, 20), "the page never enabled Join with Previous"
    _perform("Meeting", "Join with Previous")
    assert _until(lambda: app_server.meeting_ids() == [LIVE, B, A])
    assert _until(lambda: _title(web) == "Design review")
    _perform("Edit", "Undo")
    assert _until(lambda: app_server.meeting_ids() == [LIVE, C, B, A])


def test_write_notes_and_play_from_the_meeting_menu(window_with_errors, app_server):
    _, web, _ = window_with_errors
    _load(web, app_server.url + f"#/{A}")
    _, write = _menu_item("Meeting", "Write Notes")
    assert _until(write.isEnabled, 20)
    _js(web, "(() => { const a = document.getElementById('audio'); a.muted = true; a.volume = 0; return 1; })()")
    _perform("Meeting", "Write Notes")
    assert _until(lambda: app_server.notes.calls == [A])
    _perform("Meeting", "Play/Pause")
    assert _until(lambda: _js(web, "!document.getElementById('audio').paused"))
    _perform("Meeting", "Play/Pause")
    assert _until(lambda: _js(web, "document.getElementById('audio').paused"))


class _QuietApp:
    """NSApp, except that it never comes to the front: open_window's
    activation is recorded instead of done."""

    def __init__(self, real):
        self._real = real
        self.calls = []

    def setActivationPolicy_(self, policy):
        self.calls.append(("policy", policy))

    def activateIgnoringOtherApps_(self, flag):
        self.calls.append(("activate", flag))

    def __getattr__(self, name):
        return getattr(self._real, name)


def test_the_menu_bar_and_a_notification_open_the_window(monkeypatch, app_server):
    """What the menu bar's icon runs (open_window with the server's address)
    loads the page; a second click keeps the page as it is; a notification's
    meeting address opens that meeting in the same page."""
    import AppKit
    from AppKit import NSApplication, NSApplicationActivationPolicyRegular, NSMakeRect

    from palaver.webapp import window
    from palaver.webapp.server import url as meetings_url

    NSApplication.sharedApplication()
    quiet = _QuietApp(AppKit.NSApp)
    monkeypatch.setattr(AppKit, "NSApp", quiet)
    # The window open_window would make, but off-screen and invisible.
    win, delegate = window._new_window(NSMakeRect(-5000, -5000, 900, 600))
    win.setAlphaValue_(0.0)
    monkeypatch.setattr(window, "_window", win)
    monkeypatch.setattr(window, "_delegate", delegate)
    web = win.contentView()
    _collect_errors(web)
    try:
        window.open_window(meetings_url(app_server.server))
        assert ("policy", NSApplicationActivationPolicyRegular) in quiet.calls
        assert ("activate", True) in quiet.calls
        assert _until(lambda: _hash(web) == "/today", 20), "the menu bar's address did not open the page"
        _js(web, "(window.__same = 'yes')")
        window.open_window(meetings_url(app_server.server))  # the icon again
        _spin(0.5)
        assert _js(web, "window.__same ?? null") == "yes" and _hash(web) == "/today"
        window.open_window(meetings_url(app_server.server, A))  # a notification about meeting A
        assert _until(lambda: _hash(web) == f"/{A}")
        assert _until(lambda: _title(web) == "Team standup")
        assert _js(web, "window.__same ?? null") == "yes"  # the same page: its history stays
        assert _menu_item("View", "Back")[1].isEnabled()
        _no_errors(web)
    finally:
        win.close()


def test_the_palette_opens_from_the_view_menu(window_with_errors, app_server):
    """View → Search or Command… (⌘K) opens the page's palette, and closes it again."""
    _, web, _ = window_with_errors
    _load(web, app_server.url + f"#/{A}")
    assert _until(lambda: _title(web) == "Team standup", 20)
    _, item = _menu_item("View", "Search or Command…")
    assert _until(item.isEnabled), "the page did not enable the palette"
    _perform("View", "Search or Command…")
    assert _until(lambda: _js(web, "!!document.querySelector('.palette')"))
    assert _js(web, "document.querySelector('.palette-option kbd')?.textContent ?? null") is not None  # shortcuts shown
    _perform("View", "Search or Command…")
    assert _until(lambda: not _js(web, "!!document.querySelector('.palette')"))


def test_a_restarted_server_reloads_the_window_where_it_was(monkeypatch, app_server):
    """After the server process restarts (#57) the window loads the page
    again, from the new server, and stays on the page it showed."""
    import AppKit
    from AppKit import NSApplication, NSMakeRect

    from palaver.webapp import window

    NSApplication.sharedApplication()
    monkeypatch.setattr(AppKit, "NSApp", _QuietApp(AppKit.NSApp))
    win, delegate = window._new_window(NSMakeRect(-5000, -5000, 900, 600))
    win.setAlphaValue_(0.0)
    monkeypatch.setattr(window, "_window", win)
    monkeypatch.setattr(window, "_delegate", delegate)
    web = win.contentView()
    _collect_errors(web)
    try:
        window.open_window(app_server.url + f"#/{A}")
        assert _until(lambda: _title(web) == "Team standup", 20)
        _js(web, "(window.__old = 'old page')")
        assert window.reload_in_place(app_server.url) is True
        assert _until(lambda: _js(web, "window.__old ?? null") is None, 20), "the window did not reload"
        assert _hash(web) == f"/{A}"
        assert _until(lambda: _title(web) == "Team standup", 20)
        _js(web, "(window.__old = 'old page')")
        assert window.reload_in_place("http://127.0.0.1:1/") is False  # another server's restart: not this page
        _spin(0.5)
        assert _js(web, "window.__old ?? null") == "old page"
        _no_errors(web)
    finally:
        win.close()


def test_the_window_signs_in_with_the_apps_key(monkeypatch, keyed_server):
    """The menu bar opens the page with the app's key: it shows at its
    route, without the key in its address, and everything it loads later
    (the API, the audio, a reload after a restart) goes through its cookie."""
    import AppKit
    from AppKit import NSApplication, NSMakeRect

    from palaver.webapp import window

    NSApplication.sharedApplication()
    monkeypatch.setattr(AppKit, "NSApp", _QuietApp(AppKit.NSApp))
    win, delegate = window._new_window(NSMakeRect(-5000, -5000, 900, 600))
    win.setAlphaValue_(0.0)
    monkeypatch.setattr(window, "_window", win)
    monkeypatch.setattr(window, "_delegate", delegate)
    web = win.contentView()
    _collect_errors(web)
    try:
        window.open_window(keyed_server.url + f"#/{A}", keyed_server.key)
        assert _until(lambda: _title(web) == "Team standup", 20), "the page did not sign in"
        assert _js(web, "location.href") == keyed_server.url + f"#/{A}"  # the key left the address
        assert _js(web, "document.cookie") == ""  # out of the page's reach
        _js(web, f"fetch('/api/meetings/{A}/audio?track=mix', {{headers: {{Range: 'bytes=0-99'}}}})"
                 ".then((r) => (window.__audio = r.status))")  # loaded, never played: no sound
        assert _until(lambda: _js(web, "window.__audio ?? null") == 206)
        assert window.reload_in_place(keyed_server.url) is True
        assert _until(lambda: _title(web) == "Team standup", 20), "the reload was not let in"
        _no_errors(web)
    finally:
        win.close()


def test_reloading_before_the_window_was_ever_opened_does_nothing(monkeypatch):
    from palaver.webapp import window

    def no_window(*_):
        raise AssertionError("a reload made a window")

    monkeypatch.setattr(window, "_window", None)
    monkeypatch.setattr(window, "_new_window", no_window)
    assert window.reload_in_place("http://127.0.0.1:8765/") is False
    assert window._window is None
