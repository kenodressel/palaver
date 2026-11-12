// Pure start/stop decisions from a stream of (time, call app) samples, as daemon.py's Trigger.
// idle -> recording once active for startAfter seconds; recording -> idle once released for
// grace seconds. After maxSession seconds the session is force-stopped and nothing restarts
// until the call is released. When another app holds the call for startAfter seconds, the
// meeting ends and the new app's starts (["stop", "start"]).
import Foundation

public enum TriggerState: String, Sendable { case idle, recording, blocked }
public enum TriggerAction: String, Sendable { case start, stop }
public enum StopReason: String, Sendable {
    case maxLength = "max_length"
    case callEnded = "call_ended"
}

public struct Trigger: Sendable {
    public var startAfter: Double
    public var grace: Double
    public var maxSession: Double
    public private(set) var state: TriggerState = .idle
    public private(set) var stoppedBecause: StopReason?
    public private(set) var app: CallApp?
    private var activeSince: Double?
    private var releasedSince: Double?
    private var started: Double = 0
    private var switchedSince: Double?

    public init(startAfter: Double = 4, grace: Double = 10, maxSession: Double = 4 * 3600) {
        self.startAfter = startAfter
        self.grace = grace
        self.maxSession = maxSession
    }

    public mutating func blockUntilReleased() { state = .blocked }

    /// The running session counts from `when` (a meeting continued after a restart).
    public mutating func startedAt(_ when: Double) { started = when }

    public mutating func reset() {
        state = .idle; activeSince = nil; releasedSince = nil
        app = nil; switchedSince = nil
    }

    /// `ended`: the recorded call's app says the user left it (Slack's huddle controls are gone): no
    /// grace then, the grace being for a call app that lets go of its audio for a moment.
    public mutating func update(now: Double, active: Bool, app: CallApp? = nil, ended: Bool = false) -> [TriggerAction] {
        switch state {
        case .blocked:
            if !active { state = .idle; activeSince = nil }
            return []
        case .idle:
            if !active { activeSince = nil; return [] }
            if activeSince == nil { activeSince = now }
            if now - activeSince! >= startAfter {
                state = .recording; started = now; releasedSince = nil
                self.app = app; switchedSince = nil
                return [.start]
            }
            return []
        case .recording:
            break
        }
        if now - started >= maxSession {
            state = active ? .blocked : .idle
            activeSince = nil
            stoppedBecause = .maxLength
            return [.stop]
        }
        if active {
            releasedSince = nil
            return switchCheck(now: now, app: app)
        }
        switchedSince = nil
        if releasedSince == nil { releasedSince = now }
        if ended || now - releasedSince! >= grace {
            state = .idle; activeSince = nil
            stoppedBecause = .callEnded
            return [.stop]
        }
        return []
    }

    private mutating func switchCheck(now: Double, app: CallApp?) -> [TriggerAction] {
        guard let app, let mine = self.app else {
            self.app = self.app ?? app  // a session continued after a restart learns its app
            return []
        }
        if app == mine { switchedSince = nil; return [] }
        if switchedSince == nil { switchedSince = now }
        if now - switchedSince! < startAfter { return [] }
        self.app = app; started = now; switchedSince = nil
        stoppedBecause = .callEnded
        return [.stop, .start]
    }
}
