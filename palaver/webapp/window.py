"""The Meetings window: a native macOS window (WKWebView) inside the menu
bar app, showing the page its server process serves (process.py, #57). Call
everything here on the main thread.

The app is a menu bar app (no Dock icon) until the window opens; while it is
open the app shows in the Dock and the app switcher, and gets a main menu so
copy/paste and Cmd+W work in the window.
"""

from __future__ import annotations

import json

_window = None
_delegate = None
# Palaver → Quit Palaver (⌘Q): the menu bar app's own quit, set by it, so a
# recording is handled as after its Quit; None: the process just ends.
_quit = None


def on_quit(fn) -> None:
    global _quit
    _quit = fn

# The "Meeting" menu: (title, the page's command, key equivalent); None is a
# separator. The page binds these keys itself (Space plays/pauses).
MEETING_MENU = [
    ("Start Recording", "startRecording", "R"),  # ⌘⇧R (#11)
    ("Stop Recording", "stopRecording", ""),
    None,
    ("Play/Pause", "play", ""),
    ("Write Notes", "writeNotes", "N"),  # ⌘⇧N
    ("Transcribe Again", "transcribe", ""),
    ("Rename…", "rename", ""),
    ("Change Event…", "changeEvent", ""),
    ("Join with Previous", "joinPrevious", "j"),
    ("Join with Next", "joinNext", ""),
    ("Split At…", "split", ""),
    ("Review Again", "reviewAgain", ""),
    ("Report a Problem with This Meeting…", "report", ""),
    None,
    ("Export…", "export", ""),
    ("Import…", "importMeeting", ""),  # needs no meeting; here for lack of a File menu (#58)
    None,
    ("Delete Audio…", "deleteAudio", ""),  # #9
    ("Move to Trash", "trash", "\x08"),  # ⌘⌫
]

# Help → Report a Problem… (#59): the report form, from any page.
HELP_MENU = [
    ("Report a Problem…", "reportProblem", ""),
]

# View → Back and Forward: the page's own history (its pages are hash routes
# with pushState), so they run the page's commands like the Meeting menu.
VIEW_MENU = [
    ("Back", "back", "["),
    ("Forward", "forward", "]"),
    None,
    # The ⌘K palette: the page opens it on the key itself (also in a field);
    # the item is there to be found, and for a click.
    ("Search or Command…", "palette", "k"),
]


def _delegate_class():
    import objc
    import WebKit  # noqa: F401  (loads the metadata for the WKUIDelegate methods)
    from AppKit import (
        NSAlert,
        NSAlertFirstButtonReturn,
        NSApp,
        NSApplicationActivationPolicyAccessory,
        NSEventModifierFlagCommand,
        NSEventTypeKeyDown,
        NSView,
    )
    from Foundation import NSDictionary, NSObject

    try:
        return objc.lookUpClass("MeetingsWindowDelegate")
    except objc.nosuchclass_error:
        pass

    def sheet(web, message, buttons, done):
        # A sheet, not a modal: the run loop (and with it the daemon's timer)
        # keeps going while the question is open.
        alert = NSAlert.alloc().init()
        alert.setMessageText_(message)
        for title in buttons:
            alert.addButtonWithTitle_(title)
        alert.beginSheetModalForWindow_completionHandler_(web.window(), done)

    # No protocols=[WKUIDelegate]: its signatures would replace pyobjc's
    # metadata for the completion handlers, which could then not be called
    # (WebKit waited for an answer forever and the page froze on confirm()).
    # For the same reason no protocols=[WKScriptMessageHandler] either: the
    # message handler method below carries its own signature.
    class MeetingsWindowDelegate(NSObject):
        def init(self):
            self = objc.super(MeetingsWindowDelegate, self).init()
            if self is None:
                return None
            self.web = None
            self.command_menus = []  # the menus whose items run the page's commands
            self.enabled = set()  # the page's commands that work right now
            return self

        def windowWillClose_(self, _notification):
            # Back to a menu bar only app.
            NSApp.setActivationPolicy_(NSApplicationActivationPolicyAccessory)

        # The page's confirm() and alert(): without these WebKit answers
        # "Cancel" at once, so "join", "delete project" etc. did nothing.
        def webView_runJavaScriptConfirmPanelWithMessage_initiatedByFrame_completionHandler_(
                self, web, message, _frame, handler):
            sheet(web, message, ["OK", "Cancel"], lambda answer: handler(answer == NSAlertFirstButtonReturn))

        def webView_runJavaScriptAlertPanelWithMessage_initiatedByFrame_completionHandler_(
                self, web, message, _frame, handler):
            sheet(web, message, ["OK"], lambda _answer: handler())

        # <input type="file">: Import… (#58) and Add image in my notes. Without
        # this WebKit opens no panel and the click does nothing.
        def webView_runOpenPanelWithParameters_initiatedByFrame_completionHandler_(
                self, web, parameters, _frame, handler):
            from AppKit import NSModalResponseOK, NSOpenPanel

            panel = NSOpenPanel.openPanel()
            panel.setCanChooseFiles_(True)
            panel.setCanChooseDirectories_(False)
            panel.setAllowsMultipleSelection_(bool(parameters.allowsMultipleSelection()))
            panel.beginSheetModalForWindow_completionHandler_(
                web.window(), lambda answer: handler(panel.URLs() if answer == NSModalResponseOK else None))

        # WKScriptMessageHandler: the page posts {type: "commands", enabled: [...]}
        # after every render.
        @objc.typedSelector(b"v@:@@")
        def userContentController_didReceiveScriptMessage_(self, _controller, message):
            body = message.body()
            if not isinstance(body, NSDictionary) or body.get("type") != "commands":
                return
            self.enabled = {str(name) for name in (body.get("enabled") or [])}
            self.show_enabled()

        @objc.python_method
        def show_enabled(self):
            for menu in self.command_menus:
                for item in menu.itemArray():
                    if item.representedObject() is not None:
                        item.setEnabled_(str(item.representedObject()) in self.enabled)

        # The Meeting menu's items, View → Back/Forward and Edit → Undo run the page's own code.
        @objc.typedSelector(b"v@:@")
        def runPageCommand_(self, item):
            self.run_on_page(f"window.palaver && palaver.command({json.dumps(str(item.representedObject()))})")

        @objc.typedSelector(b"v@:@")
        def quitPalaver_(self, _item):
            if _quit is not None:
                _quit()
            else:
                from AppKit import NSApp

                NSApp.terminate_(None)

        @objc.typedSelector(b"v@:@")
        def pageUndo_(self, _item):
            self.run_on_page("window.palaver && palaver.undo()")

        @objc.python_method
        def run_on_page(self, script):
            if self.web is None or self.page_saw_this_key():
                return
            self.web.evaluateJavaScript_completionHandler_(script, None)

        @objc.python_method
        def page_saw_this_key(self):
            """A key equivalent reaches the menu after the web view only when the
            page did not take it: typing in a field, a held key's repeats, a
            command that does not apply. Running it then would undo the page's
            choice (holding ⌘⌫ would trash meeting after meeting). A click
            in the menu (or Return while moving through it) is no ⌘ key."""
            event = NSApp.currentEvent()
            if (event is None or event.type() != NSEventTypeKeyDown
                    or not event.modifierFlags() & NSEventModifierFlagCommand):
                return False
            window = self.web.window()
            responder = window.firstResponder() if window is not None else None
            return (responder is not None and responder.isKindOfClass_(NSView)
                    and responder.isDescendantOf_(self.web))

    return MeetingsWindowDelegate


def _main_menu(delegate):
    """The window's menu bar; the Meeting menu and Edit → Undo go to ``delegate``."""
    from AppKit import NSApp, NSMenu, NSMenuItem

    def item(title, action, key="", target=None):
        i = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, action, key)
        if target is not None:
            i.setTarget_(target)
        return i

    def menu(title, items):
        m = NSMenu.alloc().initWithTitle_(title)
        for i in items:
            m.addItem_(i if i is not None else NSMenuItem.separatorItem())
        holder = item(title, None)
        holder.setSubmenu_(m)
        return holder

    def command(entry):
        if entry is None:
            return None
        title, name, key = entry
        i = item(title, "runPageCommand:", key, delegate)
        i.setRepresentedObject_(name)
        return i

    bar = NSMenu.alloc().init()
    bar.addItem_(menu("Palaver", [
        item("Hide Palaver", "hide:", "h"),
        None,
        item("Close Window", "performClose:", "w"),
        None,
        item("Quit Palaver", "quitPalaver:", "q", delegate),
    ]))
    bar.addItem_(menu("Edit", [
        item("Undo", "pageUndo:", "z", delegate),  # the page's undo; it hands text fields theirs
        item("Redo", "redo:", "Z"),
        None,
        item("Cut", "cut:", "x"),
        item("Copy", "copy:", "c"),
        item("Paste", "paste:", "v"),
        item("Select All", "selectAll:", "a"),
    ]))
    meeting = menu("Meeting", [command(entry) for entry in MEETING_MENU])
    bar.addItem_(meeting)
    # Reload goes to the web view itself: with the items enabled by hand it
    # must work whoever has the focus.
    view = menu("View", [command(entry) for entry in VIEW_MENU] + [None, item("Reload", "reload:", "r", delegate.web)])
    bar.addItem_(view)
    help_menu = menu("Help", [command(entry) for entry in HELP_MENU])
    bar.addItem_(help_menu)
    NSApp.setMainMenu_(bar)
    NSApp.setHelpMenu_(help_menu.submenu())  # macOS adds its search field to it
    delegate.command_menus = [meeting.submenu(), view.submenu(), help_menu.submenu()]
    for m in delegate.command_menus:
        m.setAutoenablesItems_(False)  # enabled from the page's commands message
    delegate.show_enabled()


def _new_window(rect):
    """The window with its web view and their delegate, which also gets the
    page's messages. Returns (window, delegate)."""
    from AppKit import (
        NSBackingStoreBuffered,
        NSWindow,
        NSWindowStyleMaskClosable,
        NSWindowStyleMaskMiniaturizable,
        NSWindowStyleMaskResizable,
        NSWindowStyleMaskTitled,
    )
    from WebKit import WKWebView, WKWebViewConfiguration

    style = (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
             | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
    window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
        rect, style, NSBackingStoreBuffered, False)
    window.setTitle_("Palaver")
    window.setReleasedWhenClosed_(False)
    window.setMinSize_((720, 480))
    delegate = _delegate_class().alloc().init()
    config = WKWebViewConfiguration.alloc().init()
    config.userContentController().addScriptMessageHandler_name_(delegate, "palaver")
    web = WKWebView.alloc().initWithFrame_configuration_(((0, 0), rect.size), config)
    web.setAutoresizingMask_(18)  # width + height sizable
    web.setAllowsBackForwardNavigationGestures_(True)  # a two-finger swipe goes Back and Forward
    window.setContentView_(web)
    delegate.web = web
    window.setDelegate_(delegate)
    web.setUIDelegate_(delegate)
    return window, delegate


def needs_load(current: str | None, url: str) -> bool:
    """Whether showing ``url`` must load the page. The menu bar passes the bare
    address: the page open anywhere under it stays, with its history. A
    meeting's address (from a notification) differs by its #fragment, which
    WebKit follows inside the page."""
    if current is None:
        return True
    if "#" not in url:
        return current.split("#", 1)[0] != url
    return current != url


def _dock_icon() -> None:
    """Palaver's icon in the Dock while the window is open: the process is
    Python's, not Palaver.app's, so the Dock would show Python's (none)."""
    from AppKit import NSApp, NSImage

    from ..app_bundle import ICON

    image = NSImage.alloc().initWithContentsOfFile_(str(ICON))
    if image is not None:
        NSApp.setApplicationIconImage_(image)


def open_window(url: str, key: str | None = None) -> None:
    """Show the Meetings window at ``url``, creating it on first use. A load
    carries the app's ``key``, which the server keeps as a cookie and drops
    from the address (server.with_key)."""
    global _window, _delegate
    from AppKit import NSApp, NSApplicationActivationPolicyRegular, NSMakeRect
    from Foundation import NSURL, NSURLRequest

    from .server import with_key

    NSApp.setActivationPolicy_(NSApplicationActivationPolicyRegular)
    _dock_icon()
    if _window is None:
        _window, _delegate = _new_window(NSMakeRect(0, 0, 1280, 860))
        _window.center()
        _window.setFrameAutosaveName_("Meetings")
    _main_menu(_delegate)
    web = _window.contentView()
    current = web.URL()
    if needs_load(None if current is None else str(current.absoluteString()), url):
        web.loadRequest_(NSURLRequest.requestWithURL_(NSURL.URLWithString_(with_key(url, key))))
    _window.makeKeyAndOrderFront_(None)
    NSApp.activateIgnoringOtherApps_(True)


def reloads_after_restart(current: str | None, base: str) -> bool:
    """Whether the window shows a page of the server at ``base``, which was
    restarted (#57): that page loads again, from the new server, at the
    same address (its route stays)."""
    return current is not None and current.split("#", 1)[0] == base


def reload_in_place(base: str) -> bool:
    """The server at ``base`` was restarted: load the window's page again
    where it is. Nothing before the window was first opened. Whether it
    reloaded."""
    if _window is None:
        return False
    web = _window.contentView()
    current = web.URL()
    if not reloads_after_restart(None if current is None else str(current.absoluteString()), base):
        return False
    web.reload()
    return True
