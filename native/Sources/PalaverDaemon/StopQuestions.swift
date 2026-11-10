// Whether to ask if a recording should stop (daemon.py:174-284): a manual recording whose call
// ended or that went silent (issue #52), and a call recorded automatically that nothing of the
// others is heard of on this Mac (#7). Pure: fed the time, the call and the silence.
import Foundation
import PalaverDomain

public enum DaemonTiming {
    public static let startAfter = 4.0
    public static let minProcessSeconds = 60.0
    public static let liveFinishTimeout = 15 * 60.0
    public static let indexCheckSeconds = 5 * 60.0
    public static let indexRetrySeconds = 60 * 60.0
    public static let indexMemoryGB = 1.0
    public static let silenceAskSeconds = 10 * 60.0
    public static let keepQuietSeconds = 30 * 60.0
    public static let silentCallStopSeconds = 30 * 60.0
    public static let doubleClickSeconds = 3.0
    public static let continueWithin = 5 * 60.0
    public static let notifyGroupSeconds = 30.0
    public static let exitBusy: Int32 = 3
    public static let exitModels: Int32 = 4
    public static let retrySeconds = 60.0
    public static let modelsCheckSeconds = 30.0
    public static let stopGrace = 60.0
    public static let killAfter = 10.0
    /// Only recordings of a call are continued; a manual one is processed at once.
    public static let callTriggers = ["teams", "slack"]
}

let callNames = Lifecycle.callNames

/// The question for a recording that ran on: `reason` is the call app that ended ("teams",
/// "slack"), "silence", or "silent_call" for a call recorded automatically (`app`).
public func stopQuestionText(_ reason: String, minutes: Int, app: String? = nil) -> String {
    if reason == "silent_call" {
        return "Nothing has been heard from the others in your \(callNames[app ?? ""] ?? "call") on this Mac "
            + "for \(minutes) minutes. Taken on another device? Stop recording?"
    }
    if let name = callNames[reason] {
        return "You started this recording yourself, and your \(name) just ended. Stop recording?"
    }
    return "You started this recording yourself, and it has been silent for \(minutes) minutes. Stop recording?"
}

/// The notification's title for the same question.
public func stopQuestionTitle(_ reason: String, minutes: Int) -> String {
    callNames[reason] != nil ? "Call ended — still recording" : "Silent for \(minutes) min — still recording"
}

/// Python's `round(seconds / 60)`: halves to even.
func roundedMinutes(_ seconds: Double) -> Int { Int((seconds / 60).rounded(.toNearestOrEven)) }

/// Asks once when a call seen during a manual recording has been released for `grace` seconds,
/// or after `silenceAfter` seconds of silence when no call was seen. "Keep recording" waits for
/// the next call to end, or for `quietAfterKeep` seconds of silence counted from the answer. A
/// call coming back closes the question. It never decides to stop: that is the user's answer.
public struct StopQuestion: Sendable {
    public let grace: Double
    public let silenceAfter: Double
    public let quietAfterKeep: Double
    /// The reason of the question asked, until answered.
    public private(set) var open: String?
    /// Of silence, for a "silence" question.
    public private(set) var minutes = 0
    private var call: String?
    private var seenCall = false
    private var releasedSince: Double?
    private var keptAt: Double?

    public init(grace: Double, silenceAfter: Double = DaemonTiming.silenceAskSeconds,
                quietAfterKeep: Double = DaemonTiming.keepQuietSeconds) {
        self.grace = grace
        self.silenceAfter = silenceAfter
        self.quietAfterKeep = quietAfterKeep
    }

    public mutating func keep(_ now: Double) { open = nil; keptAt = now }

    /// The reason when a question is to be asked now, else nil.
    public mutating func update(_ now: Double, call: String?, silentFor: Double?) -> String? {
        if let call {
            self.call = call; seenCall = true; releasedSince = nil
            open = nil  // the call is back on: nothing ended
            return nil
        }
        if open != nil { return nil }
        if let c = self.call {
            if releasedSince == nil { releasedSince = now }
            return now - releasedSince! >= grace ? ask(c) : nil
        }
        guard let silentFor, !(seenCall && keptAt == nil) else { return nil }
        let threshold = keptAt == nil ? silenceAfter : quietAfterKeep
        let quiet = keptAt.map { min(silentFor, now - $0) } ?? silentFor
        if quiet >= threshold {
            minutes = roundedMinutes(threshold)
            return ask("silence")
        }
        return nil
    }

    private mutating func ask(_ reason: String) -> String {
        open = reason; call = nil; releasedSince = nil
        return reason
    }
}

/// Whether a call recorded automatically runs on this Mac (#7): the app holds the microphone,
/// but nothing of the others is heard. Asks after `askAfter` without the others, even while the
/// user talks; stops by itself only after `stopAfter` with both silent, so a long talk of the
/// user's is never cut. Kept, it asks again after `quietAfterKeep` from the answer, never stops.
public struct SilentCall: Sendable {
    public let askAfter: Double
    public let stopAfter: Double
    public let quietAfterKeep: Double
    /// "silent_call" while asked, until answered or sound comes back.
    public private(set) var open: String?
    public private(set) var minutes: Int
    private var asked = false
    private var keptAt: Double?

    public init(askAfter: Double = DaemonTiming.silenceAskSeconds, stopAfter: Double = DaemonTiming.silentCallStopSeconds,
                quietAfterKeep: Double = DaemonTiming.keepQuietSeconds) {
        self.askAfter = askAfter
        self.stopAfter = stopAfter
        self.quietAfterKeep = quietAfterKeep
        minutes = roundedMinutes(askAfter)
    }

    public mutating func keep(_ now: Double) { open = nil; asked = false; keptAt = now }

    public enum Action: String, Sendable { case ask, stop }

    /// `othersSilent`: seconds the system track was silent; `allSilent`: both (nil: not known).
    public mutating func update(_ now: Double, othersSilent: Double?, allSilent: Double? = nil) -> Action? {
        guard var others = othersSilent else { return nil }
        let threshold: Double
        if let keptAt {
            others = min(others, now - keptAt)
            threshold = quietAfterKeep
        } else {
            threshold = askAfter
        }
        if others < threshold {
            open = nil; asked = false  // the others are heard: nothing to ask
            return nil
        }
        if keptAt == nil, let allSilent, allSilent >= stopAfter { return .stop }
        if asked { return nil }
        open = "silent_call"; asked = true; minutes = roundedMinutes(threshold)
        return .ask
    }
}
