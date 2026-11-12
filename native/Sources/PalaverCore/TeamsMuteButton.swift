// Teams' mute, read off its mic button (Accessibility): instant, where its log is seconds to minutes
// late. New Teams' call window has a button with the DOM id "microphone-button" whose label says
// what a click does: "Unmute mic" while muted, "Mute mic" while not. Only those exact labels count:
// another label (another language, a changed Teams) leaves the button unread. Without the
// Accessibility permission, with another label, or while the button can't be found (screen
// sharing's compact bar), Teams' log is followed instead, with a long hold (CallMute): only then,
// since reading it may make macOS ask the user.
import AppKit
import ApplicationServices
import Foundation

/// What the mic button shows.
public enum MuteButtonReading: Equatable, Sendable {
    case label(String)
    /// No Teams window with the button (no call window, or it can't be found right now).
    case missing
    /// Palaver may not use Accessibility.
    case notTrusted
}

public protocol MuteButtonReader: AnyObject {
    func read() -> MuteButtonReading
    /// Teams is not hidden and has a window that is not minimized: a call window could be seen, so its
    /// button gone means something (nothing can be told otherwise).
    func windowShown() -> Bool
}

extension MuteButtonReader {
    public func windowShown() -> Bool { false }
}

/// Whether the user hung up the recorded Teams call, as its follower sees it (the call window's mic button
/// gone); the daemon reads it (a Teams recording only; reset when its follower stops).
public final class TeamsCallState: @unchecked Sendable {
    private let lock = NSLock()
    private var _left = false
    public init() {}
    public var left: Bool { lock.withLock { _left } }
    public func set(left: Bool) { lock.withLock { _left = left } }
}

public enum MuteButtonLabels {
    /// The labels Palaver knows, lowercased: what a click would do, so "unmute mic" is shown while muted.
    public static let known: [String: Bool] = ["unmute mic": true, "mute mic": false]

    /// Muted, not muted, or nil for a label Palaver doesn't know.
    public static func muted(_ label: String) -> Bool? {
        known[label.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")]
    }
}

/// The real button, through the Accessibility API. The element is kept while it answers and looked
/// for again (at most once a second, a walk of at most half a second) when it doesn't. Every
/// Accessibility call gives up after 0.25 s (a busy Teams never stalls Palaver).
public final class AXTeamsMuteButton: MuteButtonReader, @unchecked Sendable {
    public static let bundleIds = ["com.microsoft.teams2", "com.microsoft.teams"]
    public static let domId = "microphone-button"
    public static let searchSeconds = 1.0
    public static let walkSeconds = 0.5
    public static let timeout: Float = 0.25
    /// A walk stops after this many elements (Teams' call window has a few hundred).
    public static let maxElements = 5_000

    private var element: AXUIElement?
    private var lastSearch: Double?

    public init() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.timeout)  // for every element
    }

    public func read() -> MuteButtonReading {
        guard AXIsProcessTrusted() else { return .notTrusted }
        if let element, let label = Self.label(element) { return .label(label) }
        element = nil
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastSearch, now - last < Self.searchSeconds { return .missing }
        lastSearch = now
        element = Self.find()
        return element.flatMap(Self.label).map { .label($0) } ?? .missing
    }

    public func windowShown() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        for id in Self.bundleIds {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where !app.isHidden {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, Self.timeout)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value) == .success,
                      let windows = value as? [AXUIElement] else { continue }
                let shown = windows.contains { w in
                    var minimized: CFTypeRef?
                    return AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minimized) == .success
                        && (minimized as? Bool) == false
                }
                if shown { return true }
            }
        }
        return false
    }

    static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func label(_ e: AXUIElement) -> String? {
        for attribute in [kAXDescriptionAttribute as String, kAXTitleAttribute as String] {
            if let s = string(e, attribute), !s.isEmpty { return s }
        }
        return nil
    }

    /// A breadth-first walk of each running Teams' elements for the button.
    static func find() -> AXUIElement? {
        let deadline = ProcessInfo.processInfo.systemUptime + walkSeconds
        for id in bundleIds {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, timeout)
                var queue = [root], next = 0
                while next < queue.count, next < maxElements, ProcessInfo.processInfo.systemUptime < deadline {
                    let e = queue[next]
                    next += 1
                    if string(e, "AXDOMIdentifier") == domId { return e }
                    var children: CFTypeRef?
                    if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) == .success,
                       let list = children as? [AXUIElement] {
                        queue.append(contentsOf: list)
                    }
                }
            }
        }
        return nil
    }

    /// Asks macOS to let Palaver use Accessibility (its dialog, once per run of the app).
    public static func askForPermission() {
        guard !AXIsProcessTrusted(), !asked.exchange() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static let asked = Flag()
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    /// Sets it; whether it was set before.
    func exchange() -> Bool { lock.withLock { defer { set = true }; return set } }
}

/// Teams' mute for one recording: the button, read every 250 ms on its own queue, while it can be
/// read; Teams' log only when it can't. Reading the log may make macOS ask the user whether Palaver may
/// access another app's data, so it starts only once the button is unusable: Accessibility not allowed, a
/// label Palaver doesn't know, or no button for `fallbackSeconds` from the start or from its last reading.
/// Once started, the log is followed on to the end; its changes count only while the button isn't read.
/// The timeline's hold is short (`buttonDelay`) while the button is read or looked for, long (`logDelay`)
/// while only the log is. Until the button is read the state is unknown: the mic is recorded.
/// The button gone (after having been read) for `goneSeconds`, with a Teams window shown (not hidden, not
/// minimized), is the call window closed: hung up, once Teams lets go of the call's audio too (the daemon
/// then stops without the grace). Gone longer than `goneAtMostSeconds` it is no longer told (screen
/// sharing's compact bar hides it for minutes; a mid-call audio drop then must not end the recording).
/// A mute seen on a look is dated to the look before (it happened in between: the earlier moment keeps
/// more out); an unmute to the look that saw it.
public final class TeamsMuteFollower: CallMuteSource, @unchecked Sendable {
    public static let pollSeconds = 0.25
    public static let buttonDelay = 1.0
    /// Teams' log reached its file 1 to 32 s late in a live test (and a lone change later still).
    public static let logDelay = 30.0
    /// The button not found this long from the start: Teams' log is followed.
    public static let fallbackSeconds = 5.0
    /// The button gone this long after it was read: Teams' log is followed (a moment's absence is a window
    /// being rebuilt). Longer than the trigger's grace after a hang-up: an ended call never touches the log.
    public static let lostFallbackSeconds = 10.0
    /// The button gone this long (four looks), a Teams window shown: the call window closed.
    public static let goneSeconds = 1.0
    public static let goneAtMostSeconds = 10.0

    private let button: MuteButtonReader
    private let timeline: MuteTimeline
    private let state: TeamsCallState
    private let host: @Sendable () -> Int64
    private let log: @Sendable (String) -> Void
    private let poll: Double?
    private var watcher: TeamsMuteWatcher!
    private let queue = DispatchQueue(label: "palaver.teams-button")
    private var timer: DispatchSourceTimer?
    // The queue's (or, without polling, the caller's):
    private var startedAt: Int64?
    private var lastLook: Int64?
    private var told: Set<String> = []
    // Shared with the log's sink (its own queue), under `lock`:
    private let lock = NSLock()
    private var _following = false
    private var _logStarted = false
    /// When the button was last read (host ns): what happened before it was the button's to say.
    private var lastSeen: Int64?
    /// Changes the log told while the button was read, from after its last reading: they count if it is lost.
    private var heard: [(muted: Bool, at: Int64)] = []

    /// `watcher(sink)`: Teams' log, telling its changes to the sink; started only when the button can't be read.
    /// `poll`: nil looks only on `check` (tests).
    /// `state`: where it says the user hung up.
    public init(button: MuteButtonReader, timeline: MuteTimeline, state: TeamsCallState = TeamsCallState(),
                watcher: (@escaping @Sendable (Bool, Int64) -> Void) -> TeamsMuteWatcher,
                host: @escaping @Sendable () -> Int64 = hostNanos, poll: Double? = TeamsMuteFollower.pollSeconds,
                log: @escaping @Sendable (String) -> Void) {
        self.button = button
        self.timeline = timeline
        self.state = state
        self.host = host
        self.poll = poll
        self.log = log
        self.watcher = watcher { [weak self] muted, at in self?.logged(muted, at: at) }
    }

    public var followingButton: Bool { lock.withLock { _following } }
    /// Teams' log is read (the button couldn't be, at some moment of this recording).
    public var readingLog: Bool { lock.withLock { _logStarted } }
    /// Only Teams' log is followed now (its changes come late: the stop waits for them).
    public var followingLog: Bool { lock.withLock { _logStarted && !_following } }
    public var tellsLate: Bool { followingLog }
    /// Neither the button nor the log can be read: the mic is recorded while muted.
    public var unfollowed: Bool { followingLog && watcher.failing }

    public func start() {
        state.set(left: false)
        timeline.delay = Self.buttonDelay  // while the button is looked for
        startedAt = host()
        guard let poll else { check(); return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: poll, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    /// Never waits: the log is read if it is followed and free; the button is looked at on its own queue anyway.
    public func refresh() {
        if readingLog { watcher.refresh() }
        if poll == nil { check() }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        watcher.stop()
        state.set(left: false)
    }

    /// One look at the button (on the follower's queue; tests call it).
    public func check() {
        let at = host()
        let before = lastLook ?? at
        lastLook = at
        switch button.read() {
        case .label(let label):
            guard let muted = MuteButtonLabels.muted(label) else {
                callWindow(closed: false)
                once("label:\(label)", "Teams' mic button says “\(label)”, which Palaver doesn't know; following Teams' log")
                fallBack()
                return
            }
            let found: Bool = lock.withLock {
                lastSeen = at
                heard.removeAll { $0.at <= at }  // the button says what was
                defer { _following = true }
                return !_following
            }
            if found {
                timeline.delay = Self.buttonDelay
                log("following Teams' mic button")
            }
            callWindow(closed: false)
            timeline.set(muted, at: muted && !timeline.muted(at: at) ? before : at)
        case .missing:
            let seen = lock.withLock { lastSeen }
            let gone = seen.map { Double(at - $0) / 1e9 }
            callWindow(closed: gone.map { $0 >= Self.goneSeconds && $0 <= Self.goneAtMostSeconds } == true && button.windowShown())
            if (gone ?? Double(at - (startedAt ?? at)) / 1e9) >= (seen == nil ? Self.fallbackSeconds : Self.lostFallbackSeconds) {
                fallBack(say: "Teams' mic button isn't found; following Teams' log")
            }
        case .notTrusted:
            callWindow(closed: false)
            once("trust", "⚠ Palaver may not use Accessibility, so it can't see Teams' mic button: "
                 + "Teams' mute comes from its log, up to half a minute late (System Settings → Privacy & Security → Accessibility)")
            fallBack()
        }
    }

    // MARK: - private

    /// The button can't be read: Teams' log is followed (started the first time), with the long hold; what it
    /// told since the button's last reading counts.
    private func fallBack(say: String? = nil) {
        let (left, first, missed) = lock.withLock { () -> (Bool, Bool, [(muted: Bool, at: Int64)]) in
            defer { _following = false; _logStarted = true; heard = [] }
            return (_following, !_logStarted, heard)
        }
        guard left || first else { return }
        timeline.delay = Self.logDelay
        if left { log("Teams' mic button can't be read; following Teams' log") } else if let say { log(say) }
        for change in missed { timeline.set(change.muted, at: change.at) }
        if first { watcher.start() }
    }

    /// The call window closed (or not): told to the daemon through `state`.
    private func callWindow(closed: Bool) {
        guard closed != state.left else { return }
        state.set(left: closed)
        if closed { log("Teams' call window is gone: hung up, once Teams lets go of the call's audio") }
    }

    private func once(_ key: String, _ text: String) {
        if told.insert(key).inserted { log(text) }
    }

    /// A change from Teams' log: the state while the button isn't read, after its last reading.
    private func logged(_ muted: Bool, at: Int64) {
        let counts: Bool = lock.withLock {
            if let seen = lastSeen, at <= seen { return false }
            if _following { heard.append((muted, at)); return false }
            return true
        }
        if counts { timeline.set(muted, at: at) }
    }
}

/// Whether the app may use Accessibility, for the window's server (Settings says when it's missing): the
/// app writes "allowed" or "denied" to `$PALAVER_AX_STATE` now and every 10 s, as for notifications.
public final class AccessibilityStateFile: @unchecked Sendable {
    public let path: String
    private let trusted: @Sendable () -> Bool
    private var timer: DispatchSourceTimer?

    public init(directory: String, pid: Int32 = getpid(), trusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        let dir = directory.hasSuffix("/") ? directory : directory + "/"
        path = "\(dir)palaver-\(pid).accessibility"
        self.trusted = trusted
    }

    public func start(every seconds: Double = 10) {
        write()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "palaver.accessibility-state"))
        t.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.write() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        unlink(path)
    }

    public func write() {
        let tmp = path + ".tmp"
        guard (try? Data((trusted() ? "allowed" : "denied").utf8).write(to: URL(fileURLWithPath: tmp))) != nil else { return }
        rename(tmp, path)
    }

    /// What the file says: "allowed", "denied", or "unknown" (no app wrote it).
    public static func read(_ path: String?) -> String {
        guard let path, !path.isEmpty, let data = FileManager.default.contents(atPath: path) else { return "unknown" }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ["allowed", "denied"].contains(text) ? text : "unknown"
    }
}
