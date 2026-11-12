// A Slack huddle, read off Slack's window (Accessibility; issue #25). Slack lets go of the mic both
// when the user mutes and when they leave, and keeps its speaker output ~11 s after leaving, so by
// audio alone a left huddle looks muted until then. While in a huddle Slack shows "Leave huddle"
// buttons and a "Huddles actions" toolbar, and its mic button says "Mute microphone" (not muted) or
// "Unmute microphone" (muted); on leaving, those go within half a second (live test, 2026-11-11).
//
// While a Slack huddle is recorded, SlackHuddleFollower looks every 0.5 s: the mic button is the mute
// state (Core Audio's mic release otherwise), and the huddle controls gone (after having been seen),
// for a second, with a Slack window shown (not hidden, not minimized) and Slack holding no mic, is the
// user having left: the
// recording stops then, without waiting for Slack's speaker or the grace. Anything it can't read
// leaves the audio rules as they were.
import AppKit
import ApplicationServices
import Foundation

/// What Slack's windows show.
public struct HuddleUI: Equatable, Sendable {
    /// "Leave huddle" or the "Huddles actions" toolbar is there.
    public var inHuddle: Bool
    /// The mic button's label, if there is one.
    public var micLabel: String?
    /// Slack's windows that are not minimized (none: nothing can be told).
    public var windows: Int
    /// Slack is hidden (⌘H): nothing can be told either.
    public var hidden: Bool

    public init(inHuddle: Bool, micLabel: String? = nil, windows: Int = 1, hidden: Bool = false) {
        self.inHuddle = inHuddle; self.micLabel = micLabel; self.windows = windows; self.hidden = hidden
    }
}

public enum HuddleReading: Equatable, Sendable {
    case ui(HuddleUI)
    /// Slack isn't running.
    case noApp
    case notTrusted
}

public protocol HuddleUIReader: AnyObject {
    func read() -> HuddleReading
}

public enum SlackHuddleLabels {
    public static let leave = "Leave huddle"
    public static let toolbar = "Huddles actions"
    /// What a click on the mic button would do: "Unmute microphone" is shown while muted.
    public static let mic: [String: Bool] = ["Unmute microphone": true, "Mute microphone": false]
}

/// Whether the user left the recorded huddle, as its follower confirmed it; the detector and the
/// daemon read it (a Slack recording only; reset when its follower stops).
public final class SlackHuddleState: @unchecked Sendable {
    private let lock = NSLock()
    private var _left = false
    public init() {}
    public var left: Bool { lock.withLock { _left } }
    public func set(left: Bool) { lock.withLock { _left = left } }
}

/// Slack's windows through the Accessibility API: a walk of at most 0.4 s, every call giving up after
/// 0.25 s. Slack is an Electron app: its web content is in the tree once AXManualAccessibility is set.
public final class AXSlackHuddle: HuddleUIReader, @unchecked Sendable {
    public static let bundleId = "com.tinyspeck.slackmacgap"
    public static let walkSeconds = 0.4
    public static let maxElements = 8_000

    private var enabled: Set<pid_t> = []

    public init() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    public func read() -> HuddleReading {
        guard AXIsProcessTrusted() else { return .notTrusted }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).first else { return .noApp }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        if enabled.insert(app.processIdentifier).inserted {
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var value: CFTypeRef?
        let windows = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value) == .success
            ? (value as? [AXUIElement]) ?? [] : []
        let shown = windows.filter { w in
            var minimized: CFTypeRef?
            return AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minimized) == .success
                && (minimized as? Bool) == false
        }
        var ui = HuddleUI(inHuddle: false, micLabel: nil, windows: shown.count, hidden: app.isHidden)
        let deadline = ProcessInfo.processInfo.systemUptime + Self.walkSeconds
        var queue = windows, next = 0
        while next < queue.count, next < Self.maxElements, ProcessInfo.processInfo.systemUptime < deadline {
            let e = queue[next]
            next += 1
            let role = AXTeamsMuteButton.string(e, kAXRoleAttribute as String)
            if role == "AXButton" || role == "AXToolbar", let d = AXTeamsMuteButton.string(e, kAXDescriptionAttribute as String) {
                if d == SlackHuddleLabels.leave || d == SlackHuddleLabels.toolbar { ui.inHuddle = true }
                if SlackHuddleLabels.mic[d] != nil { ui.micLabel = d }
                if ui.inHuddle, ui.micLabel != nil { break }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list)
            }
        }
        return .ui(ui)
    }
}

/// A Slack recording's mute and end, from Slack's huddle UI while it can be read, from Slack's mic
/// (SlackMuteWatcher) otherwise.
public final class SlackHuddleFollower: CallMuteSource, @unchecked Sendable {
    public static let pollSeconds = 0.5
    /// The huddle controls gone this long (two looks) is the user having left.
    public static let goneSeconds = 1.0

    private let reader: HuddleUIReader
    private let timeline: MuteTimeline
    private let state: SlackHuddleState
    private let host: @Sendable () -> Int64
    private let log: @Sendable (String) -> Void
    private let poll: Double?
    private var audio: SlackMuteWatcher!
    private let queue = DispatchQueue(label: "palaver.slack-huddle")
    private var timer: DispatchSourceTimer?
    // The queue's (or, without polling, the caller's):
    private var seen = false
    private var goneSince: Int64?
    private var lastLook: Int64?
    private var told: Set<String> = []
    private let followingLock = NSLock()
    private var _following = false

    /// `audio(sink)`: Slack's mic, telling each look to the sink. `poll`: nil looks only on `check` (tests).
    public init(reader: HuddleUIReader, timeline: MuteTimeline, state: SlackHuddleState,
                audio: (@escaping @Sendable (Bool, Int64) -> Void) -> SlackMuteWatcher,
                host: @escaping @Sendable () -> Int64 = hostNanos, poll: Double? = SlackHuddleFollower.pollSeconds,
                log: @escaping @Sendable (String) -> Void) {
        self.reader = reader
        self.timeline = timeline
        self.state = state
        self.host = host
        self.poll = poll
        self.log = log
        self.audio = audio { [weak self] muted, at in self?.heard(muted, at: at) }
    }

    /// The mic button is read (else Slack's mic release is the mute state).
    public var followingButton: Bool { followingLock.withLock { _following } }

    public func start() {
        state.set(left: false)
        audio.start()
        guard let poll else { check(); return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: poll, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    /// Never waits on the UI: Slack's mic is looked at at once; the UI on its own queue.
    public func refresh() {
        audio.refresh()
        if poll == nil { check() }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        audio.stop()
        state.set(left: false)
    }

    /// One look at Slack's windows (on the follower's queue; tests call it).
    public func check() {
        let at = host()
        let before = lastLook ?? at
        lastLook = at
        let ui: HuddleUI
        switch reader.read() {
        case .ui(let read): ui = read
        case .notTrusted:
            once("trust", "Palaver may not use Accessibility: Slack's mute and the huddle's end come from its audio")
            unknown()
            return
        case .noApp:
            unknown()
            return
        }
        // The mute state.
        if let label = ui.micLabel, let muted = SlackHuddleLabels.mic[label] {
            if !followingButton {
                followingLock.withLock { _following = true }
                log("following Slack's mic button")
            }
            timeline.set(muted, at: muted && !timeline.muted(at: at) ? before : at)
        } else if followingButton {
            followingLock.withLock { _following = false }
            log("Slack's mic button can't be read; following Slack's mic")
            audio.refresh()
        }
        // The huddle.
        if ui.inHuddle {
            seen = true
            goneSince = nil
            if state.left { state.set(left: false); log("back in the Slack huddle") }
            return
        }
        // Slack hidden, minimized or closed: its controls may just not be shown. Unknown: the audio rules.
        guard seen, ui.windows > 0, !ui.hidden, audio.micHeld == false else { goneSince = nil; return }
        if goneSince == nil { goneSince = at }
        if Double(at - goneSince!) / 1e9 >= Self.goneSeconds, !state.left {
            state.set(left: true)
            log("left the Slack huddle: its controls are gone and Slack holds no mic")
        }
    }

    // MARK: - private

    private func unknown() {
        goneSince = nil
        if followingButton {
            followingLock.withLock { _following = false }
            log("Slack's window can't be read; following Slack's mic")
            audio.refresh()
        }
    }

    private func once(_ key: String, _ text: String) {
        if told.insert(key).inserted { log(text) }
    }

    /// A look at Slack's mic: the mute state while the button isn't read.
    private func heard(_ muted: Bool, at: Int64) {
        if !followingButton { timeline.set(muted, at: at) }
    }
}
