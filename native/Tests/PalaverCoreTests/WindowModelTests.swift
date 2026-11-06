// The Meetings window's pure parts (webapp/window.py, server.with_key): tests/test_window_url.py and
// the menu layout and key handling of tests/test_window.py, without a window.
import Foundation
import Testing
@testable import PalaverCore

private let BASE = "http://127.0.0.1:8765/"

@Suite struct WindowURLTests {
    @Test func aNewWindowLoads() {
        #expect(WindowPage.needsLoad(current: nil, url: BASE))
    }

    @Test func reopeningFromTheMenuBarKeepsThePageAndItsHistory() {
        // The menu bar passes the bare address; the page is somewhere under it.
        #expect(!WindowPage.needsLoad(current: BASE + "#/people", url: BASE))
        #expect(!WindowPage.needsLoad(current: BASE + "#/2026-10-21T16-29-29", url: BASE))
        #expect(!WindowPage.needsLoad(current: BASE, url: BASE))
    }

    @Test func aNotificationOpensItsMeeting() {
        #expect(WindowPage.needsLoad(current: BASE + "#/people", url: BASE + "#/2026-10-21T16-29-29"))
        #expect(!WindowPage.needsLoad(current: BASE + "#/2026-10-21T16-29-29", url: BASE + "#/2026-10-21T16-29-29"))
    }

    @Test func anotherServerLoads() {
        #expect(WindowPage.needsLoad(current: "http://127.0.0.1:9999/#/people", url: BASE))
    }

    @Test func aRestartedServerReloadsItsOwnPageOnly() {
        #expect(WindowPage.reloadsAfterRestart(current: BASE + "#/people", base: BASE))
        #expect(WindowPage.reloadsAfterRestart(current: BASE, base: BASE))
        #expect(!WindowPage.reloadsAfterRestart(current: nil, base: BASE))  // nothing loaded yet: the next open loads it
        #expect(!WindowPage.reloadsAfterRestart(current: "http://127.0.0.1:9999/#/people", base: BASE))
        #expect(!WindowPage.reloadsAfterRestart(current: "about:blank", base: BASE))
    }

    /// server.with_key: the key goes before the #route, urlencoded like Python's urlencode.
    @Test func theFirstLoadCarriesTheKeyBeforeTheRoute() {
        #expect(WindowPage.withKey(BASE, key: nil) == BASE)
        #expect(WindowPage.withKey(BASE, key: "") == BASE)
        #expect(WindowPage.withKey(BASE, key: "Ab-_9") == BASE + "?key=Ab-_9")
        #expect(WindowPage.withKey(BASE + "#/2026-10-21T16-29-29", key: "k") == BASE + "?key=k#/2026-10-21T16-29-29")
        #expect(WindowPage.withKey(BASE + "#/a#b", key: "k") == BASE + "?key=k#/a#b")
        #expect(WindowPage.withKey(BASE, key: "a b/c+=~.") == BASE + "?key=a+b%2Fc%2B%3D~.")
    }
}

@Suite struct WindowBridgeTests {
    @Test func menuCommandsRunThePagesCode() {
        #expect(WindowPage.commandScript("trash") == #"window.palaver && palaver.command("trash")"#)
        #expect(WindowPage.commandScript(#"a"b\c"#) == #"window.palaver && palaver.command("a\"b\\c")"#)
        #expect(WindowPage.undoScript == "window.palaver && palaver.undo()")
        #expect(WindowPage.messageHandler == "palaver")
    }

    @Test func thePagesCommandsMessage() {
        #expect(WindowPage.enabledCommands(["type": "commands", "enabled": ["trash", "back"]]) == ["trash", "back"])
        #expect(WindowPage.enabledCommands(["type": "commands", "enabled": NSNull()]) == [])
        #expect(WindowPage.enabledCommands(["type": "commands"]) == [])
        #expect(WindowPage.enabledCommands(["type": "commands", "enabled": [1, "x"]]) == ["1", "x"])
        #expect(WindowPage.enabledCommands(["type": "other", "enabled": ["trash"]]) == nil)
        #expect(WindowPage.enabledCommands("commands") == nil)
        #expect(WindowPage.enabledCommands(NSDictionary(dictionary: ["type": "commands", "enabled": NSArray(array: ["play"])])) == ["play"])
    }

    /// A ⌘ key that reaches the menu while the web view has the focus was the page's to take: it
    /// left it (a field, a held key's repeats), so the menu must not run it (holding ⌘⌫ trashed
    /// meeting after meeting). A click, or a key while focus is elsewhere, runs it.
    @Test func aKeyThePageAlreadySawDoesNotRunAgain() {
        #expect(WindowPage.pageSawThisKey(keyDown: true, command: true, responderInWebView: true))
        #expect(!WindowPage.pageSawThisKey(keyDown: true, command: true, responderInWebView: false))
        #expect(!WindowPage.pageSawThisKey(keyDown: true, command: false, responderInWebView: true))
        #expect(!WindowPage.pageSawThisKey(keyDown: false, command: true, responderInWebView: true))  // a click
    }

    @Test func theWindowsShape() {
        #expect(WindowPage.size == (1280, 860) && WindowPage.minSize == (720, 480))
        #expect(WindowPage.title == "Palaver" && WindowPage.autosaveName == "Meetings")
    }
}

@Suite struct WindowMenuTests {
    private func titles(_ entries: [WindowMenus.Command?]) -> [String?] { entries.map { $0?.title } }

    @Test func theMenuBarsMenusInOrder() {
        #expect(WindowMenus.bar.map(\.title) == ["Palaver", "Edit", "Meeting", "View", "Help"])
        #expect(WindowMenus.bar.map(\.runsPageCommands) == [false, false, true, true, true])
        #expect(WindowMenus.helpMenuTitle == "Help")
    }

    /// MEETING_MENU, verbatim: titles, the page's command names and the key equivalents (an
    /// uppercase key is ⇧⌘, "\u{8}" is ⌘⌫).
    @Test func theMeetingMenu() {
        let m = WindowMenus.meeting
        #expect(titles(m) == [
            "Start Recording", "Stop Recording", nil, "Play/Pause", "Write Notes", "Transcribe Again", "Rename…",
            "Change Event…", "Join with Previous", "Join with Next", "Split At…", "Review Again",
            "Report a Problem with This Meeting…", nil, "Export…", "Import…", nil, "Delete Audio…", "Move to Trash"])
        #expect(m.compactMap { $0?.name } == [
            "startRecording", "stopRecording", "play", "writeNotes", "transcribe", "rename", "changeEvent", "joinPrevious",
            "joinNext", "split", "reviewAgain", "report", "export", "importMeeting", "deleteAudio", "trash"])
        let keys = Dictionary(uniqueKeysWithValues: m.compactMap { $0 }.filter { !$0.key.isEmpty }.map { ($0.title, $0.key) })
        #expect(keys == ["Start Recording": "R", "Write Notes": "N", "Join with Previous": "j", "Move to Trash": "\u{8}"])
    }

    @Test func theViewMenuHasBackForwardAndThePalette() {
        #expect(titles(WindowMenus.view) == ["Back", "Forward", nil, "Search or Command…"])
        #expect(WindowMenus.view.compactMap { $0.map { "\($0.name) \($0.key)" } } == ["back [", "forward ]", "palette k"])
        // Then a separator and Reload, sent to the web view itself.
        #expect(WindowMenus.reload == WindowMenus.Item("Reload", "reload:", "r", .webView))
    }

    @Test func theHelpMenu() {
        #expect(WindowMenus.help == [WindowMenus.Command("Report a Problem…", "reportProblem", "")])
    }

    @Test func thePalaverAndEditMenus() {
        #expect(WindowMenus.palaver == [
            WindowMenus.Item("Hide Palaver", "hide:", "h"), nil,
            WindowMenus.Item("Close Window", "performClose:", "w"), nil,
            WindowMenus.Item("Quit Palaver", "quitPalaver:", "q", .delegate)])
        #expect(WindowMenus.edit == [
            WindowMenus.Item("Undo", "pageUndo:", "z", .delegate),  // the page's undo; it hands text fields theirs
            WindowMenus.Item("Redo", "redo:", "Z"),  // the text fields' own
            nil,
            WindowMenus.Item("Cut", "cut:", "x"),
            WindowMenus.Item("Copy", "copy:", "c"),
            WindowMenus.Item("Paste", "paste:", "v"),
            WindowMenus.Item("Select All", "selectAll:", "a")])
    }

    /// The command menus are enabled from the page's message, not by AppKit: an item is enabled
    /// when its command is one the page says works now.
    @Test func commandItemsFollowThePagesMessage() {
        let enabled: Set<String> = ["trash", "back"]
        #expect(WindowMenus.isEnabled(command: "trash", enabled: enabled))
        #expect(!WindowMenus.isEnabled(command: "joinPrevious", enabled: enabled))
        #expect(!WindowMenus.isEnabled(command: "forward", enabled: []))
    }
}
