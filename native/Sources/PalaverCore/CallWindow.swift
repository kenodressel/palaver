// The meeting's name and who is in it, read off the call window (Accessibility; issue #24) while a call is recorded
// that no calendar event matched: an organizer outside the company sends invites that are in no calendar on this
// Mac. Only two things are read: the call window's title (new Teams: "<meeting> | Microsoft Teams") and the names in
// its people list (the roster), a few times during the call. Never the chat or anything said in the meeting: the
// walk does not enter the chat, a text field or a message list, and only short texts that look like names count.
//
// What is read is kept in the meeting's folder (call-window.json: {"app", "title", "participants", "read_at"}); the
// meeting takes the title when it has no event, the names as hints for its voices. Without Accessibility (the
// permission the mute already uses: nothing is asked here), or a window that shows nothing, nothing is written.
import AppKit
import ApplicationServices
import Foundation

/// One element of an app's Accessibility tree, as the call-window reading sees it: the real AXUIElement, or a fake
/// tree in tests.
public protocol AXNode {
    /// A text attribute ("AXTitle", "AXDescription", "AXRole", "AXDOMIdentifier", …), nil when it has none.
    func string(_ attribute: String) -> String?
    func children() -> [AXNode]
}

/// What a call window showed.
public struct CallWindowInfo: Equatable, Sendable {
    public var title: String?
    public var participants: [String]
    public init(title: String? = nil, participants: [String] = []) { self.title = title; self.participants = participants }
    public var isEmpty: Bool { title == nil && participants.isEmpty }
}

public enum CallWindowReading: Equatable, Sendable {
    case info(CallWindowInfo)
    /// No call window right now (none open, or its controls can't be found: screen sharing's compact bar).
    case noWindow
    case notTrusted
}

public protocol CallWindowReader: AnyObject {
    func read() -> CallWindowReading
}

/// How Teams' call window is read: which window is the call's (it holds the mic button), what of its title is the
/// meeting's name, and where its people are.
public enum TeamsCallWindow {
    public static let maxElements = 5_000
    public static let maxParticipants = 50

    /// Parts of a window title that are Teams' own, not the meeting's: "Weekly sync | Microsoft Teams".
    static let chrome: Set<String> = [
        "microsoft teams", "microsoft teams (work or school)", "microsoft teams classic", "teams", "meeting", "meetings",
        "meeting compact view", "compact view", "meeting stage", "meeting chat", "chat", "calendar", "activity", "calls",
        "call", "sharing control bar", "screen sharing", "besprechung", "anruf", "kalender", "aktivität",
    ]

    /// A people list: its DOM id begins so (not the button that opens it), or its label begins so.
    static let rosterIds = ["roster", "people-pane", "participants"]
    static let rosterLabels = ["in this meeting", "participants", "people", "attendees", "in dieser besprechung",
                               "teilnehmer", "personen"]
    /// Where the walk never goes: the chat and anything one types or reads messages in.
    static let skippedIds = ["chat", "message", "compose", "ckeditor", "caption", "transcript"]
    static let skippedRoles: Set<String> = ["AXTextArea", "AXTextField"]

    /// Labels in a people list that are controls or headings, not people.
    static let notNames: Set<String> = [
        "mute", "unmute", "mute all", "more options", "more actions", "people", "chat", "share", "leave", "raise", "camera",
        "mic", "microphone", "participants", "in this meeting", "invite", "invite people", "share invite", "search",
        "pin", "spotlight", "attendees", "presenters", "organizer", "organizers", "guest", "guests", "waiting in lobby",
        "suggestions", "others invited", "view", "react", "apps", "rooms", "more", "close", "admit", "admit all",
        "remove", "make an attendee", "make a presenter", "manage permissions", "download attendance list",
        "lower all hands", "teilnehmer", "personen", "einladen", "schließen", "stummschalten", "weitere optionen",
    ]

    /// The meeting's name in a window title, or nil when it only names Teams or one of its views.
    public static func title(_ windowTitle: String?) -> String? {
        guard let windowTitle else { return nil }
        let parts = windowTitle.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for part in parts where !part.isEmpty {
            let folded = part.lowercased()
            if chrome.contains(folded) { continue }
            if folded.range(of: #"^[\d:\s]+$"#, options: .regularExpression) != nil { continue }  // the call's timer
            return String(part.prefix(200))
        }
        return nil
    }

    /// A person's name in a label of the people list ("Valerie (Guest)", "Kim, Muted", "Timo Strauß, Organizer"), or
    /// nil for a control, a heading, the user ("(You)") or text that doesn't look like a name.
    public static func personName(_ label: String) -> String? {
        var s = label.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // "(Guest)", "(External)", "(Unverified)", "(Organizer)" go; "(You)" is the user.
        while let open = s.lastIndex(of: "("), s.hasSuffix(")") {
            let inner = s[s.index(after: open)..<s.index(before: s.endIndex)].lowercased()
            if ["you", "me", "du", "ich", "sie"].contains(inner) { return nil }
            s = String(s[..<open]).trimmingCharacters(in: .whitespaces)
        }
        guard !s.isEmpty, s.count <= 60, !notNames.contains(s.lowercased()) else { return nil }
        guard s.rangeOfCharacter(from: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ":/@#?!;|\"…<>=+*_"))) == nil
        else { return nil }
        let words = s.split(whereSeparator: \.isWhitespace)
        guard (1...5).contains(words.count), let first = s.first, first.isLetter, first.isUppercase else { return nil }
        return words.joined(separator: " ")
    }

    static func label(_ e: AXNode) -> String? {
        for attribute in ["AXDescription", "AXTitle", "AXValue"] {
            if let s = e.string(attribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        }
        return nil
    }

    static func skipped(_ e: AXNode) -> Bool {
        if let role = e.string("AXRole"), skippedRoles.contains(role) { return true }
        guard let id = e.string("AXDOMIdentifier")?.lowercased(), !id.isEmpty else { return false }
        return skippedIds.contains { id.contains($0) }
    }

    static func isRoster(_ e: AXNode) -> Bool {
        if let id = e.string("AXDOMIdentifier")?.lowercased(), !id.hasSuffix("-button"),
           rosterIds.contains(where: { id.hasPrefix($0) }) { return true }
        guard let role = e.string("AXRole"), ["AXList", "AXGroup", "AXOutline", "AXTable"].contains(role),
              let l = label(e)?.lowercased() else { return false }
        return rosterLabels.contains { l == $0 || l.hasPrefix($0 + " ") || l.hasPrefix($0 + " (") }
    }

    /// The call window among `windows` (the one holding the mic button) and what it shows; nil without one.
    /// At most `maxElements` elements are looked at, until `deadline` (host uptime) at the latest.
    public static func read(windows: [AXNode], maxElements: Int = maxElements,
                            deadline: Double = .infinity, now: () -> Double = { ProcessInfo.processInfo.systemUptime }) -> CallWindowInfo? {
        var seen = 0
        for window in windows {
            var hasMic = false
            var names: [String] = []
            // (element, inside a people list)
            var queue: [(AXNode, Bool)] = [(window, false)], next = 0
            while next < queue.count, seen < maxElements, now() < deadline {
                let (e, inRoster) = queue[next]
                next += 1
                seen += 1
                if e.string("AXDOMIdentifier") == AXTeamsMuteButton.domId { hasMic = true }
                if skipped(e) { continue }
                let roster = inRoster || isRoster(e)
                if inRoster, let l = label(e), let name = personName(l),
                   !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }), names.count < maxParticipants {
                    names.append(name)
                }
                queue.append(contentsOf: e.children().map { ($0, roster) })
            }
            if hasMic { return CallWindowInfo(title: title(window.string("AXTitle")), participants: names) }
        }
        return nil
    }
}

/// An AXUIElement as an `AXNode`; every call gives up after the mute's timeout.
struct AXElementNode: AXNode {
    let element: AXUIElement
    func string(_ attribute: String) -> String? { AXTeamsMuteButton.string(element, attribute) }
    func children() -> [AXNode] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list.map(AXElementNode.init)
    }
}

/// Teams' windows through the Accessibility API: a walk of at most half a second. Never asks for the permission.
public final class AXTeamsCallWindow: CallWindowReader, @unchecked Sendable {
    public static let walkSeconds = 0.5

    public init() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AXTeamsMuteButton.timeout)
    }

    public func read() -> CallWindowReading {
        guard AXIsProcessTrusted() else { return .notTrusted }
        var windows: [AXNode] = []
        for id in AXTeamsMuteButton.bundleIds {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, AXTeamsMuteButton.timeout)
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value) == .success,
                   let list = value as? [AXUIElement] {
                    windows += list.map(AXElementNode.init)
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + Self.walkSeconds
        return TeamsCallWindow.read(windows: windows, deadline: deadline).map { .info($0) } ?? .noWindow
    }
}

/// One recording's call window: read a few times (`readsAt`, seconds after the start: cheap, bounded), what it showed
/// kept in `call-window.json`. `wanted`: false while a calendar event matches the call (then nothing is read).
public final class CallWindowWatcher: @unchecked Sendable {
    public static let readsAt: [Double] = [5, 30, 120, 300, 900, 1800]
    public static let fileName = "call-window.json"

    private let app: String
    private let reader: CallWindowReader
    private let file: URL
    private let wanted: () -> Bool
    private let wall: () -> Date
    private let timeZone: TimeZone
    private let log: (String) -> Void
    private let schedule: Bool
    private let queue = DispatchQueue(label: "palaver.call-window", qos: .utility)
    private let lock = NSLock()
    private var timers: [DispatchSourceTimer] = []
    private var known = CallWindowInfo()
    private var told: Set<String> = []

    /// `schedule` false: reads only on `check` (tests).
    public init(app: String, reader: CallWindowReader, folder: URL, wanted: @escaping () -> Bool = { true },
                wall: @escaping () -> Date = Date.init, timeZone: TimeZone = .current, schedule: Bool = true,
                log: @escaping (String) -> Void) {
        self.app = app
        self.reader = reader
        self.file = folder.appendingPathComponent(Self.fileName)
        self.wanted = wanted
        self.wall = wall
        self.timeZone = timeZone
        self.schedule = schedule
        self.log = log
    }

    public func start() {
        guard schedule else { return }
        lock.withLock {
            for at in Self.readsAt {
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now() + at, leeway: .seconds(2))
                t.setEventHandler { [weak self] in self?.check() }
                t.resume()
                timers.append(t)
            }
        }
    }

    public func stop() {
        lock.withLock {
            for t in timers { t.cancel() }
            timers = []
        }
    }

    /// What was read so far.
    public var info: CallWindowInfo { lock.withLock { known } }

    /// One read; what is new is written at once.
    public func check() {
        guard wanted() else { return }
        let name = app == "teams" ? "Teams'" : app.capitalized + "'s"
        switch reader.read() {
        case .notTrusted:
            once("trust", "Palaver may not use Accessibility: the meeting's title isn't read from \(name) call window")
        case .noWindow:
            once("none", "\(name) call window isn't found: its title is read later, if it shows")
        case .info(let read):
            let (changed, now) = lock.withLock { () -> (Bool, CallWindowInfo) in
                var next = known
                if let title = read.title { next.title = title }
                for p in read.participants where next.participants.count < TeamsCallWindow.maxParticipants
                    && !next.participants.contains(where: { $0.caseInsensitiveCompare(p) == .orderedSame }) {
                    next.participants.append(p)
                }
                defer { known = next }
                return (next != known, next)
            }
            if now.isEmpty { once("empty", "\(name) call window shows no meeting title or names Palaver can read") }
            guard changed else { return }
            write(now)
            // Never the title or the names themselves: session.log goes into reports.
            once("read", "read the meeting's title from \(name) call window" + (now.title == nil ? " (none shown)" : "")
                 + ", \(now.participants.count) name\(now.participants.count == 1 ? "" : "s") so far")
        }
    }

    private func once(_ key: String, _ text: String) {
        let first = lock.withLock { told.insert(key).inserted }
        if first { log(text) }
    }

    private func write(_ info: CallWindowInfo) {
        let object: [String: Any] = ["app": app, "title": info.title as Any? ?? NSNull(), "participants": info.participants,
                                     "read_at": WallTime.iso(wall(), timeZone, seconds: true)]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]) else { return }
        let tmp = file.appendingPathExtension("tmp")
        guard (try? data.write(to: tmp)) != nil else { return }
        _ = rename(tmp.path, file.path)
    }
}
