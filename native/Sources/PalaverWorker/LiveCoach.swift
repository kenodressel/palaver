// The coach during the call (live_coach.py, #41/#42): quiet nudges from the voice activity of the two tracks and
// the stream's text of the user's own words, and `palaver-worker coach <folder>`, which writes them to coach.json
// every second for the daemon.
//
// - Talk share and monologues come from the voice activity (VoiceMonitor), within a second.
// - Pace and filler words come from the stream's text of the user's sentences over the last five minutes, compared
//   with the user's own baseline (Coach.loadBaseline): a nudge only when clearly above it, none without a baseline.
// - "Valerie hasn't said anything yet" only when it is sure: every voice heard so far has a name and the invitee is
//   none of them.
// - A series remembered as sharing one microphone (#56): no talk share, monologue or quiet-invitee nudge.
//
// At most one nudge every NUDGE_EVERY seconds, shown NUDGE_SHOWN seconds (the menu, the meeting's page) and, once, as
// a quiet notification (#19: no sound, removed after NUDGE_SHOWN, never a person's name; a switch in Settings). A
// nudge does not come again until what it said stopped being true. Each nudge's kind and time (never its text) go
// to the meeting's session.log.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

/// `threading.Event`: set once, waited for with a time limit.
public final class StopEvent: @unchecked Sendable {
    private let condition = NSCondition()
    private var flag = false

    public init() {}

    public var isSet: Bool { condition.withLock { flag } }

    public func set() {
        condition.withLock {
            flag = true
            condition.broadcast()
        }
    }

    /// Waits at most `timeout` seconds; whether it is set.
    @discardableResult
    public func wait(_ timeout: Double) -> Bool {
        condition.withLock {
            let deadline = Date(timeIntervalSinceNow: max(0, timeout))
            while !flag && condition.wait(until: deadline) {}
            return flag
        }
    }
}

/// A nudge as the status shows it: `{kind, text, at}` (`at`: seconds into the recording).
public struct Nudge: Equatable, Sendable {
    public let kind: String
    public let text: String
    public let at: Double?

    public init(kind: String, text: String, at: Double?) {
        self.kind = kind
        self.text = text
        self.at = at
    }

    public var json: JSONValue { .object([("kind", .string(kind)), ("text", .string(text)), ("at", .num(at))]) }
}

/// The user's pace and filler words over the last minutes (`pace_and_fillers`).
public struct Speech: Equatable, Sendable {
    public var seconds: Double
    public var wpm: Int
    public var fillersPerMinute: Double
    /// The most frequent filler word, nil when there is none.
    public var top: String?
    /// "de" or "en".
    public var language: String

    public init(seconds: Double, wpm: Int, fillersPerMinute: Double, top: String?, language: String) {
        self.seconds = seconds
        self.wpm = wpm
        self.fillersPerMinute = fillersPerMinute
        self.top = top
        self.language = language
    }
}

/// What the nudges need to know of the meeting (`meeting_context`).
public struct CoachContext: Equatable {
    /// The invitees whose silence is worth saying.
    public var invitees: [String]
    /// "1:1", "group" or nil.
    public var kind: String?
    /// The user's baseline (coach.baseline's `baseline`).
    public var baseline: JSONValue?
    /// The series shares one microphone (#56).
    public var shared: Bool

    public init(invitees: [String] = [], kind: String? = nil, baseline: JSONValue? = nil, shared: Bool = false) {
        self.invitees = invitees
        self.kind = kind
        self.baseline = baseline
        self.shared = shared
    }
}

/// Python's `round(x)` of a float: the nearest int, half to even.
private func roundInt(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }

/// Which nudge to show now, from the voice activity (`talk`, VoiceActivity's snapshot), the user's speech and the
/// invitees not heard.
public final class Nudges {
    // live_coach.py:37-58.
    public static let NUDGE_EVERY = 180.0  // at most one nudge in this long
    public static let NUDGE_SHOWN = 120.0  // a nudge is shown this long
    /// In this order when several are due.
    public static let KINDS = ["monologue", "talk_share", "quiet_invitee", "pace", "fillers"]
    /// Left out where one microphone is shared (#56).
    public static let SHARED_KINDS = ["monologue", "talk_share", "quiet_invitee"]
    public static let LABELS = ["talk_share": "Talk share", "monologue": "Monologues",
                                "quiet_invitee": "Invitees who haven't spoken", "pace": "Speaking pace",
                                "fillers": "Filler words"]
    public static let SHARE_MIN_WINDOW = 300.0  // the talk share is said after five minutes ...
    public static let SHARE_MIN_ME = 120.0  // ... with two minutes of the user talking
    public static let SHARE_DEFAULT = 0.7
    public static let SHARE_ABOVE_USUAL = 0.2
    public static let SHARE_RANGE = (0.6, 0.85)
    public static let SHARE_REARM = 0.1  // said again only after the share fell this far below the threshold
    public static let MONOLOGUE_SECONDS = 180.0
    public static let SPEECH_WINDOW = 300.0  // pace and fillers over the last five minutes ...
    public static let SPEECH_MIN_SECONDS = 90.0  // ... of at least this much of the user's speech
    public static let BASELINE_MIN_MEETINGS = 3
    public static let PACE_FACTOR = 1.2, PACE_ABOVE = 25.0  // fast: both this much above the usual pace
    public static let FILLER_FACTOR = 1.5, FILLER_ABOVE = 1.5  // filler words: both this much above the usual rate
    public static let PACE_REARM = 10.0, FILLER_REARM = 0.5  // said again only after falling this far below
    public static let QUIET_AFTER = 600.0  // an invitee is said to be quiet after ten minutes ...
    public static let QUIET_MIN_OTHERS = 60.0  // ... of a call with this much of the others talking
    public static let MIN_TALK_SECONDS = 10.0  // a voice with less is not worth a name

    public var baseline: JSONValue?
    public var kind: String?
    public var shared: Bool
    private let clock: () -> Double
    private var current: (nudge: Nudge, shownAt: Double)?
    private var lastAt: Double?
    private var armed: [String: Bool] = Dictionary(uniqueKeysWithValues: KINDS.map { ($0, true) })
    /// Invitees already said to be quiet.
    private var told = Set<ScalarKey>()
    /// The nudge the last update chose (new then), else nil.
    public private(set) var fresh: Nudge?

    public init(baseline: JSONValue? = nil, kind: String? = nil, shared: Bool = false,
                clock: @escaping () -> Double = Live.monotonic) {
        self.baseline = baseline
        self.kind = kind
        self.shared = shared
        self.clock = clock
    }

    /// The nudge to show now (nil: none). `enabled`: the kinds switched on (missing ones are on).
    @discardableResult
    public func update(_ talk: JSONValue?, speech: Speech? = nil, quiet: [String] = [],
                       enabled: [String: Bool]? = nil) -> Nudge? {
        let now = clock()
        fresh = nil
        let due = self.due(talk, speech, quiet)
        if let c = current, now - c.shownAt > Self.NUDGE_SHOWN { current = nil }
        if lastAt.map({ now - $0 >= Self.NUDGE_EVERY }) ?? true {
            for kind in Self.KINDS {
                guard let text = due[kind], enabled?[kind] ?? true, armed[kind] == true,
                      !(shared && Self.SHARED_KINDS.contains(kind)) else { continue }
                armed[kind] = kind == "quiet_invitee"  // the next name may come later
                if kind == "quiet_invitee" { told.formUnion(quiet.map(ScalarKey.init)) }
                let nudge = Nudge(kind: kind, text: text, at: talk?["until"]?.doubleValue)
                current = (nudge, now)
                lastAt = now
                fresh = nudge
                break
            }
        }
        return current?.nudge
    }

    /// What would be said now, by kind; re-arms what is no longer true.
    private func due(_ talk: JSONValue?, _ speech: Speech?, _ quiet: [String]) -> [String: String] {
        var due: [String: String] = [:]
        let share = talk?["share"]?.doubleValue, threshold = Self.shareThreshold(baseline, kind)
        let window = talk?["window"]?.doubleValue ?? 0, me = talk?["me"]?.doubleValue ?? 0
        if let share, window >= Self.SHARE_MIN_WINDOW, me >= Self.SHARE_MIN_ME, share >= threshold {
            due["talk_share"] = "You've talked \(roundInt(100 * share)) % of the last \(roundInt(window / 60)) min"
        } else if share.map({ $0 < threshold - Self.SHARE_REARM }) ?? true {
            armed["talk_share"] = true
        }
        let monologue = talk?["monologue"]?.doubleValue ?? 0
        if monologue >= Self.MONOLOGUE_SECONDS {
            due["monologue"] = "\(Int((monologue / 60).rounded(.down)))-min monologue"
        } else if monologue == 0 {
            armed["monologue"] = true
        }
        let new = quiet.filter { !told.contains(ScalarKey($0)) }
        if !new.isEmpty {
            due["quiet_invitee"] = "\(Self.namesText(new)) \(new.count == 1 ? "hasn" : "haven")'t said anything yet"
        }
        if let speech, (baseline?["meetings"]?.doubleValue ?? 0) >= Double(Self.BASELINE_MIN_MEETINGS) {
            let usual = baseline?["wpm"]?.doubleValue
            let limit = usual.flatMap { $0 != 0 ? max($0 * Self.PACE_FACTOR, $0 + Self.PACE_ABOVE) : nil }
            if let limit, let usual, Double(speech.wpm) >= limit {
                due["pace"] = "You're speaking fast: \(speech.wpm) words a minute (usual \(roundInt(usual)))"
            } else if let limit, Double(speech.wpm) < limit - Self.PACE_REARM {
                armed["pace"] = true
            }
            let usualFillers = baseline?["fillers_per_minute"]?[speech.language]?.doubleValue
            let rate = speech.fillersPerMinute
            let fillerLimit = usualFillers.flatMap { $0 != 0 ? max($0 * Self.FILLER_FACTOR, $0 + Self.FILLER_ABOVE) : nil }
            if let fillerLimit, let usualFillers, let top = speech.top, !top.isEmpty, rate >= fillerLimit {
                due["fillers"] = "More filler words than usual: \(String(format: "%.1f", rate)) a minute "
                    + "(usual \(String(format: "%.1f", usualFillers))), mostly “\(top)”"
            } else if let fillerLimit, rate < fillerLimit - Self.FILLER_REARM {
                armed["fillers"] = true
            }
        }
        return due
    }

    static func namesText(_ names: [String]) -> String {
        names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    // MARK: - the rules

    /// "1:1" with one other person invited, "group" with more.
    public static func speechKind(_ invitees: Int) -> String? {
        invitees == 1 ? "1:1" : invitees > 1 ? "group" : nil
    }

    /// The talk share worth a nudge: well above what is usual for the user in this kind of meeting, within
    /// SHARE_RANGE.
    public static func shareThreshold(_ baseline: JSONValue?, _ kind: String?) -> Double {
        var usual: Double?
        if let baseline, baseline.truthy, let kind {
            usual = baseline[kind == "1:1" ? "share_1on1" : "share_group"]?.doubleValue
        }
        guard let usual else { return SHARE_DEFAULT }
        return Py.round(min(SHARE_RANGE.1, max(SHARE_RANGE.0, usual + SHARE_ABOVE_USUAL)), 3)
    }

    /// Words a minute and filler words a minute of the user's sentences (the stream's mic track) in the last
    /// `window` seconds; nil with less than SPEECH_MIN_SECONDS of them.
    public static func paceAndFillers(_ mine: [VoiceMonitor.Sentence], until: Double,
                                      window: Double = SPEECH_WINDOW) -> Speech? {
        let recent = mine.filter { $0.end >= until - window }
        let seconds = Py.sum(recent.map { max(0.0, $0.end - $0.start) })
        guard seconds >= SPEECH_MIN_SECONDS else { return nil }
        let text = recent.map(\.text).joined(separator: " ")
        let tics = Py.stableSorted(Coach.TICS.map { ($0, Coach.count(text, $0)) }) { $0.1 > $1.1 }
        let german = Coach.GERMAN.reduce(0) { $0 + Coach.count(text, $1) } >= Coach.ENGLISH.reduce(0) { $0 + Coach.count(text, $1) }
        let fillers = tics.reduce(0) { $0 + $1.1 }
        return Speech(seconds: Py.round(seconds, 1), wpm: roundInt(Double(Coach.words(text)) / seconds * 60),
                      fillersPerMinute: Py.round(Double(fillers) / seconds * 60, 1),
                      top: tics.first.flatMap { $0.1 > 0 ? $0.0 : nil }, language: german ? "de" : "en")
    }

    /// Invitees who have not said anything, when that is sure: the call has run QUIET_AFTER seconds with the others
    /// talking, every voice heard has a name (`names`: label → name), and the invitee is none of them.
    public static func quietInvitees(_ invitees: [String], talk: PyDict<Double>, names: PyDict<String>,
                                     elapsed: Double) -> [String] {
        if elapsed < QUIET_AFTER || Py.sum(talk.values) < QUIET_MIN_OTHERS { return [] }
        let voices = talk.filter { $0.value >= MIN_TALK_SECONDS }.map(\.key)
        let named = voices.compactMap { names[$0] }
        if named.count < voices.count { return [] }
        let distinct = Set(named.map(ScalarKey.init))
        if distinct.count < voices.count { return [] }  // two voices, one name: not sure who is who
        var seen = Set<ScalarKey>()
        let heard = Py.stableSorted(named.filter { seen.insert(ScalarKey($0)).inserted }, by: Py.less)
        return invitees.filter { person in
            CalendarEvents.resolve(person, heard) == nil
                && !heard.contains { Py.same(Py.casefold(person), Py.casefold($0)) }
        }
    }

    /// The nudge kinds switched on in Settings.
    public static func enabledKinds(_ s: SettingsValues) -> [String: Bool] {
        ["monologue": s.nudgeMonologue, "talk_share": s.nudgeTalkShare, "quiet_invitee": s.nudgeQuietInvitee,
         "pace": s.nudgePace, "fillers": s.nudgeFillers]
    }

    /// What the nudges need to know of the meeting: its kind (by who was invited and did not decline), the invitees
    /// whose silence is worth saying (who accepted, when the calendar gives responses; else only those whose voice is
    /// known: `voices`, the voice bank's names), and whether its series shares one microphone (#56).
    public static func meetingContext(_ event: CalendarEvent?, userName: String, baseline: JSONValue?,
                                      voices: [String] = [], stores: StorePaths = .current()) -> CoachContext {
        let people = event.map { CalendarEvents.candidates($0, userName: userName) } ?? []
        let watched: [String]
        if let event, event.attendees.contains(where: { $0.response != "unknown" }) {
            watched = people.filter { $0.response == "accepted" }.map(\.name)
        } else {
            watched = people.filter { CalendarEvents.resolve($0.name, voices) != nil }.map(\.name)
        }
        return CoachContext(invitees: watched, kind: speechKind(people.count), baseline: baseline,
                            shared: SharedMic.remembered(event, stores: stores))
    }
}

// MARK: - one recording's live coach

/// The voice activity and nudges of the recording in a folder. `enabled()`: the nudge kinds switched on (Settings);
/// `context()`: the meeting's invitees, kind and the user's baseline, loaded once on a thread of its own.
public final class LiveCoach: @unchecked Sendable {
    // live_coach.py:214-217.
    public static let QUIET_CHECK_SECONDS = 30.0  // who has spoken: live.json is read this often
    public static let SPEECH_EVERY = 1.0  // pace and fillers are read from the stream's text this often
    public static let STOP_WAIT = 5.0  // a stopped coach's threads get this long to end
    public static let CONTEXT_AFTER = 60.0  // the context is loaded this long after the start

    /// (talk seconds by label, label → name) of the voices heard so far, for the invitees given.
    public typealias Names = (RecordingPaths, [String]) throws -> (talk: PyDict<Double>, names: PyDict<String>)

    /// The voice bank's and the live names (`live_names`), from the bank in `stores` (nil: the user's, looked up
    /// when asked).
    public static func liveNames(stores: StorePaths? = nil) -> Names {
        { paths, invitees in
            try Speakers.liveNames(paths, invitees: invitees, bank: VoiceBank(directory: (stores ?? .current()).voices))
        }
    }

    private final class Relay: @unchecked Sendable {
        weak var coach: LiveCoach?
    }

    public let monitor: VoiceMonitor
    /// Set once `stop`'s threads have ended.
    public let stopped = StopEvent()
    private let nudges: Nudges
    private let enabled: () -> [String: Bool]
    private let context: () throws -> CoachContext
    private let clock: () -> Double
    private let names: Names
    private let onNudge: ((Nudge) -> Void)?
    private let stopping = StopEvent()
    private let lock = NSLock()
    // Under the lock (the context thread, the monitor's thread and `status` meet here):
    private var invitees: [String] = []
    private var quiet: [String] = []
    private var nudge: Nudge?
    private var contextEnded: DispatchSemaphore?
    // The monitor's thread only:
    private var quietChecked = -1e9
    private var speech: Speech?
    private var speechAt = -1e9

    /// `onNudge`: each new nudge, once (`LiveCoachRunner.nudgeNotifier`).
    public init(folder: URL, enabled: @escaping () -> [String: Bool] = { [:] },
                context: @escaping () throws -> CoachContext = { CoachContext() },
                clock: @escaping () -> Double = Live.monotonic, names: @escaping Names = LiveCoach.liveNames(),
                onNudge: ((Nudge) -> Void)? = nil) {
        let relay = Relay()
        monitor = VoiceMonitor(folder: folder, clock: clock, onPoll: { relay.coach?.polled($0) })
        nudges = Nudges(clock: clock)
        self.enabled = enabled
        self.context = context
        self.clock = clock
        self.names = names
        self.onNudge = onNudge
        relay.coach = self
    }

    public func start(contextAfter: Double = CONTEXT_AFTER) {
        let ended = DispatchSemaphore(value: 0)
        lock.withLock { contextEnded = ended }
        let thread = Thread { [self] in
            loadContext(after: contextAfter)
            ended.signal()
        }
        thread.name = "coach-context"
        thread.start()
        monitor.start()
    }

    /// Returns at once: the threads are waited for on a thread of their own; `stopped` is set once they ended.
    public func stop() {
        stopping.set()
        let ended = lock.withLock { contextEnded }
        let thread = Thread { [self] in
            monitor.stop(wait: Self.STOP_WAIT)
            _ = ended?.wait(timeout: .now() + Self.STOP_WAIT)
            stopped.set()
        }
        thread.name = "coach-stop"
        thread.start()
    }

    /// Not in the first minute: the recording is starting, and nothing needs the context before 3 minutes.
    func loadContext(after: Double = 0) {
        if stopping.wait(after) { return }
        let ctx: CoachContext
        do {
            ctx = try context()
        } catch {
            FileHandle.standardError.write(Data("could not load the coach's context: \(error)\n".utf8))
            return
        }
        if stopping.isSet { return }
        lock.withLock {
            nudges.shared = ctx.shared
            invitees = ctx.shared ? [] : ctx.invitees
            nudges.baseline = ctx.baseline
            nudges.kind = ctx.kind
        }
    }

    private func polled(_ monitor: VoiceMonitor) {
        update(talk: monitor.snapshot(), mine: monitor.mine)
    }

    /// One step after the monitor's poll: who is quiet (every QUIET_CHECK_SECONDS), the user's pace (every
    /// SPEECH_EVERY), the nudge; a new one goes to `onNudge`.
    func update(talk: JSONValue?, mine: @autoclosure () -> [VoiceMonitor.Sentence]) {
        guard let talk, talk.truthy else { return }
        let now = clock()
        let until = talk["until"]?.doubleValue ?? 0
        let invitees = lock.withLock { self.invitees }
        if !invitees.isEmpty && now - quietChecked >= Self.QUIET_CHECK_SECONDS {
            quietChecked = now
            var found: [String] = []
            if let (byVoice, names) = try? names(monitor.paths, invitees) {  // unreadable: not sure, nobody is quiet
                found = Nudges.quietInvitees(invitees, talk: byVoice, names: names, elapsed: until)
            }
            lock.withLock { quiet = found }
        }
        if now - speechAt >= Self.SPEECH_EVERY {  // the text changes every second at most
            speechAt = now
            speech = Nudges.paceAndFillers(mine(), until: until)
        }
        let switches = enabled()
        let fresh: Nudge? = lock.withLock {
            nudge = nudges.update(talk, speech: speech, quiet: quiet, enabled: switches)
            return nudges.fresh
        }
        if let fresh { onNudge?(fresh) }
    }

    /// `{talk, talk_text, nudge, quiet}`: what coach.json holds.
    public func status() -> JSONValue {
        let talk = monitor.snapshot()
        let (nudge, quiet) = lock.withLock { (self.nudge, self.quiet) }
        return .object([("talk", talk ?? .null), ("talk_text", .str(VoiceActivity.talkText(talk))),
                        ("nudge", nudge?.json ?? .null), ("quiet", .strings(quiet))])
    }
}

// MARK: - the coach as a worker of its own (`palaver-worker coach <folder>`)

/// A nudge as a notification: Palaver's, without sound, gone after `expires` seconds; a click opens `meeting`.
public struct CoachNotification: Equatable, Sendable {
    public let title: String
    public let message: String
    public let meeting: String
    public let quiet: Bool
    public let expires: Double?
}

public enum LiveCoachRunner {
    // live_coach.py:337-339.
    public static let COACH_FILE = "coach.json"
    public static let WRITE_EVERY = 1.0  // the status is written this often
    public static let SETTINGS_CHECK_SECONDS = 5.0  // the nudge switches are read again this often

    public static let NUDGE_TITLE = "Live coach"
    /// A banner is seen by everyone when the whole screen is shared and stays in Notification Center: a nudge that
    /// names people says so without names there (the menu and the meeting's page name them).
    public static let NOTIFICATION_TEXT = ["quiet_invitee": "Someone invited hasn't spoken yet"]

    public static func coachPath(_ folder: URL) -> URL { folder.appendingPathComponent(COACH_FILE) }

    /// A value read again from settings.json every `ttl` seconds (the monitor asks on every poll).
    private final class Cached<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var at = -1e9
        private var value: Value
        private let ttl: Double
        private let clock: () -> Double
        private let read: () -> Value

        init(_ initial: Value, ttl: Double, clock: @escaping () -> Double, read: @escaping () -> Value) {
            value = initial
            self.ttl = ttl
            self.clock = clock
            self.read = read
        }

        func get() -> Value {
            lock.withLock {
                let now = clock()
                if now - at >= ttl {
                    at = now
                    value = read()
                }
                return value
            }
        }
    }

    /// The nudge kinds switched on in settings.json, read again every `ttl` seconds.
    public static func settingsSwitches(ttl: Double = SETTINGS_CHECK_SECONDS, clock: @escaping () -> Double = Live.monotonic,
                                        stores: StorePaths = .current()) -> () -> [String: Bool] {
        let cached = Cached([String: Bool](), ttl: ttl, clock: clock) { Nudges.enabledKinds(SettingsFile.load(stores: stores)) }
        return cached.get
    }

    /// Whether nudges show as notifications (settings.json's `nudge_notify`), read again every `ttl` seconds.
    public static func notifySwitch(ttl: Double = SETTINGS_CHECK_SECONDS, clock: @escaping () -> Double = Live.monotonic,
                                    stores: StorePaths = .current()) -> () -> Bool {
        let cached = Cached(SettingsValues().nudgeNotify, ttl: ttl, clock: clock) { SettingsFile.load(stores: stores).nudgeNotify }
        return cached.get
    }

    /// What the coach does with each new nudge (#19): a line in the meeting's session.log (its kind and when in the
    /// call, not the words), and, while `show()` (Settings → Live coach), a quiet notification that names nobody
    /// (NOTIFICATION_TEXT) and goes away after NUDGE_SHOWN; a click opens the meeting.
    public static func nudgeNotifier(_ folder: URL, show: @escaping () -> Bool,
                                     send: @escaping (CoachNotification) -> Void) -> (Nudge) -> Void {
        let log = SessionLog(url: RecordingPaths(folder).sessionLog, logger: "palaver.live_coach")
        return { nudge in
            log.event("coach_nudge", [("kind", nudge.kind), ("at", JSONValue.num(nudge.at))])
            guard show() else { return }
            send(CoachNotification(title: NUDGE_TITLE, message: NOTIFICATION_TEXT[nudge.kind] ?? nudge.text,
                                   meeting: folder.lastPathComponent, quiet: true, expires: Nudges.NUDGE_SHOWN))
        }
    }

    /// coach.json, atomically (through coach.json.tmp): the daemon reads it every tick.
    public static func writeStatus(_ folder: URL, _ status: JSONValue) throws {
        let value = JSONValue.object(["talk", "talk_text", "nudge"].map { ($0, status[$0] ?? .null) }
            + [("quiet", status["quiet"] ?? .array([]))])
        try PythonJSON.write(value, to: coachPath(folder), indent: nil, ensureAscii: true, via: COACH_FILE + ".tmp")
    }

    /// Runs `coach` over the recording in `folder`, writing coach.json every `every` seconds, until the recording is
    /// finished (meta.json, no `.part`) or `stop` is set (SIGTERM). Also when nothing is left to follow: the tracks
    /// stopped growing for `stall` seconds without finishing, the app that started this is gone (the parent changed:
    /// an orphan is adopted by launchd), or the folder is. coach.json is removed on the way out: no file, no coach.
    public static func run(folder: URL, coach: LiveCoach, stop: StopEvent, every: Double = WRITE_EVERY,
                           contextAfter: Double = LiveCoach.CONTEXT_AFTER,
                           finished: @escaping (RecordingPaths) -> Bool = Live.recordingFinished,
                           stall: Double = Live.STALL_SECONDS, clock: @escaping () -> Double = Live.monotonic,
                           parentAlive: (() -> Bool)? = nil,
                           log: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) -> Int32 {
        let parent = getppid()
        let alive: () -> Bool = parentAlive ?? { getppid() == parent && parent != 1 }
        let paths = coach.monitor.paths
        func size() -> Int {
            var total = 0
            for track in [paths.micRawWav.path, paths.systemWav.path] {
                for file in [track, track + ".part"] {
                    var st = stat()
                    if stat(file, &st) == 0 { total += Int(st.st_size) }
                }
            }
            return total
        }
        var lastSize = -1, lastGrowth = clock()
        coach.start(contextAfter: contextAfter)
        defer {
            coach.stop()
            _ = coach.stopped.wait(LiveCoach.STOP_WAIT + 1)
            unlink(coachPath(folder).path)
        }
        while true {
            try? writeStatus(folder, coach.status())
            if stop.wait(every) || finished(paths) { break }
            if !alive() {
                log("the app that started the coach is gone; ending")
                break
            }
            if access(folder.path, F_OK) != 0 { break }
            let now = size()
            if now != lastSize {
                (lastSize, lastGrowth) = (now, clock())
            } else if clock() - lastGrowth > stall {
                log("recording stopped growing without finishing; ending the coach")
                break
            }
        }
        return 0
    }
}

// MARK: - the command

extension WorkerMain {
    /// `coach <folder>` (cli.py `_cmd_coach`): coach.json every second until the recording ends or SIGTERM (which ends
    /// it the same way: coach.json removed, exit 0).
    static func coach(_ o: Options, env: [String: String]) throws -> Int32 {
        let folder = try folderArgument(o)
        let config = loadConfig(o, env: env)
        let stores = stores(env)
        let stop = StopEvent()
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        term.setEventHandler { stop.set() }
        term.resume()
        defer {
            term.cancel()
            signal(SIGTERM, SIG_DFL)
        }
        let notifier = LiveCoachRunner.nudgeNotifier(folder, show: LiveCoachRunner.notifySwitch(stores: stores)) { n in
            Notify.send(title: n.title, message: n.message, meeting: n.meeting, quiet: n.quiet, expires: n.expires, env: env)
        }
        let coach = LiveCoach(folder: folder, enabled: LiveCoachRunner.settingsSwitches(stores: stores),
                              context: { try coachContext(config, env: env) }, names: LiveCoach.liveNames(stores: stores),
                              onNudge: notifier)
        return LiveCoachRunner.run(folder: folder, coach: coach, stop: stop)
    }

    /// The live coach's context (daemon.py `_coach_context`): the invitees of the calendar event on now, the user's
    /// baseline (saved by `process` after the last call) and the voice bank's names.
    static func coachContext(_ config: Config, env: [String: String]) throws -> CoachContext {
        let stores = stores(env)
        var event: CalendarEvent?
        if let provider = calendar(config, env: env).provider {
            let now = Queries.localNow()
            if let events = try? provider(now.date.addingTimeInterval(-2 * 3600), now.date.addingTimeInterval(2 * 3600)) {
                event = CalendarEvents.match(events, now, try now.adding(seconds: 1))
            }
        }
        let voices = try VoiceBank(directory: stores.voices).names().keys
        return Nudges.meetingContext(event, userName: SettingsFile.currentUserName(default: config.userName, stores: stores),
                                     baseline: Coach.loadBaseline(stores: stores), voices: voices, stores: stores)
    }
}
