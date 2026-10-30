"""The Meetings window answers the page's confirm() and alert(), and its
native menu bar runs the page's commands (in real, invisible WKWebView
windows: needs a window server)."""

import json
import threading
import time
import urllib.request

import pytest

pytest.importorskip("WebKit")

pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def page():
    from AppKit import NSApplication, NSBackingStoreBuffered, NSMakeRect, NSWindow, NSWindowStyleMaskTitled
    from WebKit import WKWebView, WKWebViewConfiguration

    from palaver.webapp import window

    NSApplication.sharedApplication()
    win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
        NSMakeRect(-5000, -5000, 400, 300), NSWindowStyleMaskTitled, NSBackingStoreBuffered, False)
    win.setAlphaValue_(0.0)
    web = WKWebView.alloc().initWithFrame_configuration_(NSMakeRect(0, 0, 400, 300), WKWebViewConfiguration.alloc().init())
    win.setContentView_(web)
    delegate = window._delegate_class().alloc().init()
    web.setUIDelegate_(delegate)
    win.orderFront_(None)
    web.loadHTMLString_baseURL_("<p>test</p>", None)
    _spin(1.0)
    yield win, web, delegate
    win.close()


def _spin(seconds):
    from Foundation import NSDate, NSRunLoop

    NSRunLoop.currentRunLoop().runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(seconds))


def _press(win, title):
    from AppKit import NSButton

    def buttons(view):
        for v in view.subviews():
            if v.isKindOfClass_(NSButton):
                yield v
            yield from buttons(v)

    sheet = win.attachedSheet()
    assert sheet is not None, "no dialog shown"
    next(b for b in buttons(sheet.contentView()) if b.title() == title).performClick_(None)


@pytest.mark.parametrize("script, button, expected", [
    ("confirm('Move to the trash?') ? 'ok' : 'cancel'", "OK", "ok"),
    ("confirm('Move to the trash?') ? 'ok' : 'cancel'", "Cancel", "cancel"),
    ("alert('Not moved'), 'done'", "OK", "done"),
])
def test_the_page_gets_its_answer(page, script, button, expected):
    """Calling WebKit's completion handler used to raise ("cannot call block
    without a signature"): the page waited forever on "move to trash"."""
    win, web, _ = page
    result = {}
    web.evaluateJavaScript_completionHandler_(script, lambda value, error: result.update(value=value))
    _spin(0.5)
    _press(win, button)
    _spin(0.5)
    assert result.get("value") == expected


# --- the native menu bar ---------------------------------------------------

@pytest.fixture
def offscreen():
    """A window as open_window builds it (web view, delegate, message handler,
    menu bar), but off-screen and invisible: no activation, no saved frame."""
    from AppKit import NSApplication, NSMakeRect

    from palaver.webapp import window

    NSApplication.sharedApplication()
    win, delegate = window._new_window(NSMakeRect(-5000, -5000, 400, 300))
    win.setAlphaValue_(0.0)
    window._main_menu(delegate)
    win.orderFront_(None)
    yield win, win.contentView(), delegate
    win.close()


@pytest.fixture
def served(tmp_path):
    from palaver.webapp.server import App, make_server
    from tests.test_webapp import _meeting

    _meeting(tmp_path)
    srv = make_server(App(tmp_path, "Timo", write_notes=lambda mid: True, run_projects=lambda args: True), port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield srv
    srv.shutdown()
    srv.server_close()


def _menu_item(menu_title, title):
    from AppKit import NSApp

    holder = NSApp.mainMenu().itemWithTitle_(menu_title)
    assert holder is not None, f"no {menu_title} menu"
    menu = holder.submenu()
    item = menu.itemWithTitle_(title)
    assert item is not None, f"no {menu_title} → {title}"
    return menu, item


def _perform(menu_title, title):
    menu, item = _menu_item(menu_title, title)
    menu.performActionForItemAtIndex_(menu.indexOfItem_(item))


def _until(condition, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        _spin(0.1)
    return condition()


COMMANDS_PAGE = """<script>
window.palaver = {command: (n) => document.title = n, undo: () => document.title = "undo"};
window.webkit.messageHandlers.palaver.postMessage({type: "commands", enabled: ["trash"]});
</script>"""


def test_meeting_menu_sits_between_edit_and_view(offscreen):
    from AppKit import NSApp, NSEventModifierFlagCommand, NSEventModifierFlagShift

    bar = NSApp.mainMenu()
    assert [bar.itemAtIndex_(i).title() for i in range(bar.numberOfItems())] == ["Palaver", "Edit", "Meeting", "View", "Help"]
    menu = bar.itemWithTitle_("Meeting").submenu()
    assert not menu.autoenablesItems()
    items = [menu.itemAtIndex_(i) for i in range(menu.numberOfItems())]
    assert [None if i.isSeparatorItem() else i.title() for i in items] == [
        "Play/Pause", "Write Notes", "Rename…", "Change Event…", "Join with Previous", "Join with Next",
        "Split At…", "Review Again", "Report a Problem with This Meeting…", None, "Export…", "Import…", None,
        "Move to Trash"]
    keys = {i.title(): i.keyEquivalent() for i in items if i.keyEquivalent()}
    assert keys == {"Write Notes": "N", "Join with Previous": "j", "Move to Trash": "\x08"}
    cmd = NSEventModifierFlagCommand
    assert menu.itemWithTitle_("Write Notes").keyEquivalentModifierMask() & (cmd | NSEventModifierFlagShift) == cmd
    # Redo stays the text fields' own.
    assert _menu_item("Edit", "Redo")[1].action() == "redo:"


def test_view_menu_has_back_and_forward(offscreen):
    from AppKit import NSApp

    _, web, _ = offscreen
    menu = NSApp.mainMenu().itemWithTitle_("View").submenu()
    assert not menu.autoenablesItems()
    items = [menu.itemAtIndex_(i) for i in range(menu.numberOfItems())]
    assert [None if i.isSeparatorItem() else i.title() for i in items] == [
        "Back", "Forward", None, "Search or Command…", None, "Reload"]
    assert {i.title(): i.keyEquivalent() for i in items if not i.isSeparatorItem()} == {
        "Back": "[", "Forward": "]", "Search or Command…": "k", "Reload": "r"}
    assert menu.itemWithTitle_("Search or Command…").representedObject() == "palette"  # the page's ⌘K palette
    assert menu.itemWithTitle_("Reload").target() == web
    assert web.allowsBackForwardNavigationGestures()  # the trackpad swipe


BACK_PAGE = """<script>
window.palaver = {command: (n) => document.title = n, undo: () => document.title = "undo"};
window.webkit.messageHandlers.palaver.postMessage({type: "commands", enabled: ["back"]});
</script>"""


def test_view_menu_runs_back_on_the_page(offscreen):
    _, web, _ = offscreen
    web.loadHTMLString_baseURL_(BACK_PAGE, None)
    _, back = _menu_item("View", "Back")
    assert _until(back.isEnabled), "the page's commands message did not enable Back"
    assert not _menu_item("View", "Forward")[1].isEnabled()
    _perform("View", "Back")
    assert _until(lambda: web.title() == "back")


def test_meeting_menu_runs_page_commands(offscreen):
    _, web, _ = offscreen
    web.loadHTMLString_baseURL_(COMMANDS_PAGE, None)
    _, trash = _menu_item("Meeting", "Move to Trash")
    assert _until(trash.isEnabled), "the page's commands message did not enable Move to Trash"
    assert not _menu_item("Meeting", "Join with Previous")[1].isEnabled()
    _perform("Meeting", "Move to Trash")
    assert _until(lambda: web.title() == "trash")
    _perform("Edit", "Undo")
    assert _until(lambda: web.title() == "undo")


def _cmd_backspace():
    from AppKit import NSEvent, NSEventModifierFlagCommand, NSEventTypeKeyDown

    return NSEvent.keyEventWithType_location_modifierFlags_timestamp_windowNumber_context_characters_charactersIgnoringModifiers_isARepeat_keyCode_(
        NSEventTypeKeyDown, (0, 0), NSEventModifierFlagCommand, 0, 0, None, "\x08", "\x08", True, 51)


def _send(event):
    """Through the event queue, so the event is NSApp.currentEvent while it is handled."""
    from AppKit import NSApp, NSDate, NSDefaultRunLoopMode, NSEventMaskAny

    NSApp.postEvent_atStart_(event, True)
    got = NSApp.nextEventMatchingMask_untilDate_inMode_dequeue_(
        NSEventMaskAny, NSDate.dateWithTimeIntervalSinceNow_(1.0), NSDefaultRunLoopMode, True)
    assert got is not None
    NSApp.sendEvent_(got)


def test_a_key_the_page_already_saw_does_not_run_again(offscreen):
    """⌘⌫ reaches the menu after the web view only when the page left it alone
    (typing in a field, a held key's repeats): the menu must not trash then."""
    win, web, _ = offscreen
    web.loadHTMLString_baseURL_(COMMANDS_PAGE, None)
    _, trash = _menu_item("Meeting", "Move to Trash")
    assert _until(trash.isEnabled)
    try:
        win.makeFirstResponder_(web)
        _send(_cmd_backspace())
        _spin(0.5)
        assert web.title() == ""
        # Not from the web view (it is not first responder): the menu runs the command.
        win.makeFirstResponder_(None)
        _send(_cmd_backspace())
        assert _until(lambda: web.title() == "trash")
    finally:
        _send(_nothing())  # NSApp.currentEvent would stay ⌘⌫ for the next test


def _nothing():
    from AppKit import NSEvent, NSEventTypeApplicationDefined

    return NSEvent.otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2_(
        NSEventTypeApplicationDefined, (0, 0), 0, 0, 0, None, 0, 0, 0)


def _meeting_ids(srv):
    port = srv.server_address[1]
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/meetings") as resp:
        return [m["id"] for m in json.loads(resp.read())]


def test_meeting_menu_trash_and_edit_undo_on_the_real_page(offscreen, served):
    from Foundation import NSURL, NSURLRequest

    from tests.test_webapp import MEETING

    _, web, _ = offscreen
    port = served.server_address[1]
    web.loadRequest_(NSURLRequest.requestWithURL_(NSURL.URLWithString_(f"http://127.0.0.1:{port}/#/{MEETING}")))
    _, trash = _menu_item("Meeting", "Move to Trash")
    assert _until(trash.isEnabled, 20), "the page never enabled Move to Trash"
    _perform("Meeting", "Move to Trash")
    assert _until(lambda: MEETING not in _meeting_ids(served))
    _perform("Edit", "Undo")
    assert _until(lambda: MEETING in _meeting_ids(served))


def _hash(web):
    url = web.URL()
    return str(url.fragment() or "") if url is not None else ""


def test_back_and_forward_on_the_real_page(offscreen, served):
    """The page's routes are hashes with pushState: View → Back returns to the
    page a tab click left (the window opens on Today), Forward goes on to the page again."""
    from Foundation import NSURL, NSURLRequest

    _, web, _ = offscreen
    port = served.server_address[1]
    web.loadRequest_(NSURLRequest.requestWithURL_(NSURL.URLWithString_(f"http://127.0.0.1:{port}/")))
    assert _until(lambda: _hash(web) == "/today", 20), "the page never opened Today"
    assert not _menu_item("View", "Back")[1].isEnabled()
    web.evaluateJavaScript_completionHandler_("document.querySelector('[data-view=people]').click()", None)
    assert _until(lambda: _hash(web) == "/people")
    _, back = _menu_item("View", "Back")
    assert _until(back.isEnabled), "Back is not enabled after going to People"
    _perform("View", "Back")
    assert _until(lambda: _hash(web) == "/today")
    _, forward = _menu_item("View", "Forward")
    assert _until(forward.isEnabled), "Forward is not enabled after going back"
    _perform("View", "Forward")
    assert _until(lambda: _hash(web) == "/people")


def test_cmd_f_on_a_full_width_page_goes_to_the_meeting_search(offscreen, served):
    """The search is in the meeting list, hidden beside People: ⌘F goes to the
    meeting open last and focuses the search there."""
    from Foundation import NSURL, NSURLRequest

    from tests.test_webapp import MEETING

    win, web, _ = offscreen
    win.setContentSize_((1000, 700))  # under 760 px the list is hidden on every page
    port = served.server_address[1]
    web.loadRequest_(NSURLRequest.requestWithURL_(NSURL.URLWithString_(f"http://127.0.0.1:{port}/")))
    assert _until(lambda: _hash(web) == "/today", 20)  # Today: full width, no list
    web.evaluateJavaScript_completionHandler_(
        "document.dispatchEvent(new KeyboardEvent('keydown', {key: 'f', metaKey: true, bubbles: true}))", None)
    assert _until(lambda: _hash(web) == f"/{MEETING}")
    # The test window never has the focus, so WebKit moves none: check that the search is shown.
    web.evaluateJavaScript_completionHandler_(
        "document.title = document.querySelector('#search').getClientRects().length ? 'shown' : 'hidden'", None)
    assert _until(lambda: web.title() == "shown")
