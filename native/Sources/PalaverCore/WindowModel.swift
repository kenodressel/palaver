// The Meetings window's pure parts (webapp/window.py, server.with_key): its menus as data, the
// address it loads, the JS bridge's scripts and messages, and the repeat-key guard. The AppKit
// window (Sources/Palaver/Window.swift) is built from these; tests check them without a window.
import Foundation

public enum WindowMenus {
    /// A menu item that runs the page's command `name` (`palaver.command(name)`); `key` is its key
    /// equivalent: an uppercase letter means ⇧⌘, "\u{8}" is ⌘⌫.
    public struct Command: Equatable, Sendable {
        public let title: String
        public let name: String
        public let key: String
        public init(_ title: String, _ name: String, _ key: String) {
            self.title = title
            self.name = name
            self.key = key
        }
    }

    /// Where a fixed item's action goes: the responder chain (AppKit's own: hide:, cut:, …), the
    /// window's delegate (the page's undo, Palaver's quit), or the web view itself (reload:).
    public enum Target: Equatable, Sendable { case responder, delegate, webView }

    public struct Item: Equatable, Sendable {
        public let title: String
        public let action: String
        public let key: String
        public let target: Target
        public init(_ title: String, _ action: String, _ key: String = "", _ target: Target = .responder) {
            self.title = title
            self.action = action
            self.key = key
            self.target = target
        }
    }

    /// The "Meeting" menu (window.py MEETING_MENU); nil is a separator. The page binds these keys
    /// itself (Space plays/pauses).
    public static let meeting: [Command?] = [
        Command("Start Recording", "startRecording", "R"),  // ⌘⇧R (#11)
        Command("Stop Recording", "stopRecording", ""),
        nil,
        Command("Play/Pause", "play", ""),
        Command("Write Notes", "writeNotes", "N"),  // ⌘⇧N
        Command("Transcribe Again", "transcribe", ""),
        Command("Rename…", "rename", ""),
        Command("Change Event…", "changeEvent", ""),
        Command("Join with Previous", "joinPrevious", "j"),
        Command("Join with Next", "joinNext", ""),
        Command("Split At…", "split", ""),
        Command("Review Again", "reviewAgain", ""),
        Command("Report a Problem with This Meeting…", "report", ""),
        nil,
        Command("Export…", "export", ""),
        Command("Import…", "importMeeting", ""),  // needs no meeting; here for lack of a File menu (#58)
        nil,
        Command("Delete Audio…", "deleteAudio", ""),  // #9
        Command("Move to Trash", "trash", "\u{8}"),  // ⌘⌫
    ]

    /// Help → Report a Problem… (#59): the report form, from any page (HELP_MENU).
    public static let help: [Command?] = [
        Command("Report a Problem…", "reportProblem", ""),
    ]

    /// View → Back and Forward: the page's own history (hash routes with pushState), so they run
    /// the page's commands like the Meeting menu (VIEW_MENU). The ⌘K palette: the page opens it on
    /// the key itself (also in a field); the item is there to be found, and for a click.
    public static let view: [Command?] = [
        Command("Back", "back", "["),
        Command("Forward", "forward", "]"),
        nil,
        Command("Search or Command…", "palette", "k"),
    ]

    /// After View's commands and a separator: Reload goes to the web view itself; with the items
    /// enabled by hand it must work whoever has the focus.
    public static let reload = Item("Reload", "reload:", "r", .webView)

    public static let palaver: [Item?] = [
        Item("Hide Palaver", "hide:", "h"),
        nil,
        Item("Close Window", "performClose:", "w"),
        nil,
        Item("Quit Palaver", "quitPalaver:", "q", .delegate),
    ]

    public static let edit: [Item?] = [
        Item("Undo", "pageUndo:", "z", .delegate),  // the page's undo; it hands text fields theirs
        Item("Redo", "redo:", "Z"),
        nil,
        Item("Cut", "cut:", "x"),
        Item("Copy", "copy:", "c"),
        Item("Paste", "paste:", "v"),
        Item("Select All", "selectAll:", "a"),
    ]

    /// The menu bar's menus in order; the command menus have autoenable off (the page's
    /// `commands` message enables their items).
    public struct Menu: Sendable {
        public let title: String
        public let runsPageCommands: Bool
    }

    public static let bar: [Menu] = [
        Menu(title: "Palaver", runsPageCommands: false),
        Menu(title: "Edit", runsPageCommands: false),
        Menu(title: "Meeting", runsPageCommands: true),
        Menu(title: "View", runsPageCommands: true),
        Menu(title: "Help", runsPageCommands: true),
    ]

    /// NSApp.helpMenu: macOS adds its search field to it.
    public static let helpMenuTitle = "Help"

    /// Whether a command menu's item is enabled: its command is one the page says works now.
    public static func isEnabled(command: String, enabled: Set<String>) -> Bool { enabled.contains(command) }
}

public enum WindowPage {
    public static let title = "Palaver"
    public static let size = (1280, 860)
    public static let minSize = (720, 480)
    /// The window's saved frame.
    public static let autosaveName = "Meetings"
    /// `window.webkit.messageHandlers.palaver`: the page posts {type: "commands", enabled: [...]}.
    public static let messageHandler = "palaver"
    public static let undoScript = "window.palaver && palaver.undo()"

    /// Native → page: a menu item's command.
    public static func commandScript(_ name: String) -> String {
        "window.palaver && palaver.command(\(jsonString(name)))"
    }

    /// The page's commands message: the commands that work now; nil when it is no such message.
    public static func enabledCommands(_ body: Any) -> Set<String>? {
        guard let dict = body as? [String: Any] ?? (body as? NSDictionary).flatMap({ $0 as? [String: Any] }),
              dict["type"] as? String == "commands" else { return nil }
        guard let list = dict["enabled"] as? [Any] else { return [] }
        return Set(list.map { "\($0)" })
    }

    /// server.with_key: `url` with the key before its #route, what the window opens first. The
    /// server keeps the key as a cookie and drops it from the address.
    public static func withKey(_ url: String, key: String?) -> String {
        guard let key, !key.isEmpty else { return url }
        let (base, route) = splitFragment(url)
        return "\(base)?key=\(quotePlus(key))" + (route.map { "#\($0)" } ?? "")
    }

    /// Whether showing `url` must load the page. The menu bar passes the bare address: the page
    /// open anywhere under it stays, with its history. A meeting's address (from a notification)
    /// differs by its #fragment, which WebKit follows inside the page.
    public static func needsLoad(current: String?, url: String) -> Bool {
        guard let current else { return true }
        if !url.contains("#") { return splitFragment(current).base != url }
        return current != url
    }

    /// Whether the window shows a page of the server at `base`, which was restarted (#57): that
    /// page loads again, from the new server, at the same address (its route stays).
    public static func reloadsAfterRestart(current: String?, base: String) -> Bool {
        guard let current else { return false }
        return splitFragment(current).base == base
    }

    /// A key equivalent reaches the menu after the web view only when the page did not take it:
    /// typing in a field, a held key's repeats, a command that does not apply. Running it then
    /// would undo the page's choice (holding ⌘⌫ would trash meeting after meeting). A click in
    /// the menu (or Return while moving through it) is no ⌘ key.
    public static func pageSawThisKey(keyDown: Bool, command: Bool, responderInWebView: Bool) -> Bool {
        keyDown && command && responderInWebView
    }

    static func splitFragment(_ url: String) -> (base: String, route: String?) {
        guard let hash = url.firstIndex(of: "#") else { return (url, nil) }
        return (String(url[..<hash]), String(url[url.index(after: hash)...]))
    }

    /// urllib's quote_plus: letters, digits and "_.-~" stay, a space is "+", the rest %XX of UTF-8.
    static func quotePlus(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            case UInt8(ascii: " "):
                out += "+"
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// json.dumps of a string (ensure_ascii, as Python writes it).
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for unit in s.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20...0x7F: out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            default: out += String(format: "\\u%04x", unit)
            }
        }
        return out + "\""
    }
}
