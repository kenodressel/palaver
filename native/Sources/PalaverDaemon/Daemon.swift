// The daemon (palaver/daemon.py `Daemon`, inventory §4): records calls (the trigger) and manual
// recordings, holds back a call cut by a restart for the next start to continue, queues the
// recordings for `process`/`run`, then their notes and the search index, asks whether to stop a
// recording that ran on, and writes daemon.json on every tick. One instance, driven from the main
// thread; everything it touches (capture, workers, Python facts, the clock) is injected.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

/// Another Palaver is running: a second one must not touch its recording or queue.
/// A calendar lookup that answers later: `.pending` while Python is asked, then the event's key
/// (nil: no event then, no calendar, or the lookup failed).
public enum EventLookup: Equatable, Sendable {
    case pending
    case known(String?)
}

public struct DaemonRunning: Error, CustomStringConvertible {
    public let description: String
}

/// A worker this daemon started, for the memory watchdog.
public struct DaemonWorker {
    /// "live", "stream", "process", "notes", "index" or "question".
    public let kind: String
    /// Its meeting's folder; nil for the search index.
    public let folder: String?
    public let process: WorkerProcess
}

/// The memory watchdog's seam (Task 9): shown the workers once a tick.
public protocol MemoryWatching: AnyObject {
    /// Samples the workers and says what to do with those over budget; the daemon acts.
    func watch(_ workers: [DaemonWorker], now: Double) -> [MemoryAction]
    /// daemon.json's `memory` ({total, app, workers, budgets}); nil when not measured.
    func status() -> JSONValue?
    /// "Palaver 5.4 GB", appended to `why_text`.
    func costText() -> String?
}

struct Ending {
    let kind: String
    let folder: String?
    let process: WorkerProcess
    let since: Double
    let restart: Bool
    let told: (title: String, message: String)
    var killed = false
}

/// Everything the daemon works with. Tests pass fakes; `DaemonFactory` the real ones.
public struct DaemonDeps {
    /// The call app in a call now; may throw (the last answer then stands). Given the app whose
    /// call is recorded (nil: none, or a manual recording): it stays the call while it is in it.
    public var detect: (CallApp?) throws -> CallApp?
    /// The detector's ignored holds (#7): ignore an app's hold until it lets go; those ignored now.
    public var ignore: ((String) -> Void)?
    public var ignored: () -> [String] = { [] }
    /// A recording session for a trigger ("teams", "slack", "manual").
    public var newSession: (String) -> RecordingSessionLike
    public var launchProcessing: (URL) throws -> WorkerProcess
    public var launchNotes: ((URL) throws -> WorkerProcess)?
    /// Whether a processed recording's notes are written apart (`launchNotes`), asked as its processing
    /// starts: not with the Notion upload (`run` writes them) or with notes turned off.
    public var notesWanted: () -> Bool = { true }
    public var launchLive: ((URL) throws -> WorkerProcess)?
    public var launchStream: ((URL) throws -> WorkerProcess)?
    public var launchIndex: (() throws -> WorkerProcess)?
    /// `palaver coach <folder>`: the live coach of a call (#41); it writes coach.json, ends with the
    /// recording. Not one of the memory watchdog's workers (memory.py has no coach kind).
    public var launchCoach: ((URL) throws -> WorkerProcess)?
    /// The wall clock coach.json's age is told against (the file's own modification time is real).
    public var coachNow: () -> Date = Date.init
    public var memoryFreeGB: () -> Double = { .infinity }
    /// Free memory the notes of a meeting need (`notes-memory`); nil while not known yet.
    public var notesMemoryGB: (URL) -> Double? = { _ in 20 }
    /// Whether a meeting needs indexing (`index-stale`, Settings.search_meaning); nil while not known yet.
    public var indexWanted: () -> Bool? = { false }
    public var indexModelReady: () -> Bool = { true }
    /// Whether a meeting's models are here (`missing-models`); nil while not known yet.
    public var modelsReady: (URL) -> Bool? = { _ in true }
    public var realtime: () -> Bool = { false }
    public var live: () -> Bool = { true }
    /// Wraps a recording's start: the setup assistant's test recording gives way (#55).
    public var beforeRecord: (() throws -> URL) throws -> URL = { try $0() }
    /// Seconds both tracks were silent; the system track (the others in a call). nil: not known.
    public var silence: () -> Double? = { nil }
    public var othersSilence: () -> Double? = { nil }
    public var liveRunning: (URL) -> Bool = { _ in false }
    public var stopLive: (URL) -> Void = { _ in }
    public var addPart: (URL, URL) throws -> Void = Continuation.addPart
    /// What says a queued recording is done: notion.json with the upload, else transcript.md.
    public var doneMarker: () -> String = { "notion.json" }
    /// Where recordings are; at start, those left behind are marked.
    public var outputDir: URL?
    /// The command lines of Palaver's running processes.
    public var processes: () -> [String] = { [] }
    public var statePath: URL
    public var trigger: Trigger
    public var clock: () -> Double
    /// The wall clock: survives a restart, unlike `clock`.
    public var wall: () -> Date = Date.init
    public var timeZone: TimeZone = .current
    /// The calendar event's key at a moment (`event-key`): never blocks; `.pending` while asked.
    public var eventKeyAt: (Date) -> EventLookup = { _ in .known(nil) }
    public var watchdog: MemoryWatching?
    /// (title, message, meeting to open).
    public var notify: (String, String, String?) -> Void = { _, _, _ in }
    /// (level, message) into daemon.log.
    public var log: (String, String) -> Void = { _, _ in }
    public var pid: Int32 = getpid()
    public var palaverAlive: (Int32?) -> Bool = { Processes.palaverAlive($0) }

    public init(detect: @escaping (CallApp?) throws -> CallApp?, newSession: @escaping (String) -> RecordingSessionLike,
                launchProcessing: @escaping (URL) throws -> WorkerProcess, statePath: URL, trigger: Trigger,
                clock: @escaping () -> Double) {
        self.detect = detect
        self.newSession = newSession
        self.launchProcessing = launchProcessing
        self.statePath = statePath
        self.trigger = trigger
        self.clock = clock
    }
}

func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }
func name(_ path: String) -> String { (path as NSString).lastPathComponent }

public final class Daemon {
    public var deps: DaemonDeps
    public var trigger: Trigger
    /// The live levels of the running recording, read after each tick.
    public var levels: RecordingLevels?

    private var session: RecordingSessionLike?
    private var folder: String?
    private var since: Date
    private var triggerName: String?
    private var cut: Cut? {
        didSet { if let cut, cut != oldValue { askCutsEvent(cut) } }
    }
    /// A started call recording that may continue the cut one: decided once the calendar answered.
    private var pending: (cut: Cut, startedAt: Date, askedAt: Double, missingTold: Bool)?
    /// How long a recording waits for the calendar before it takes "no key" for an answer.
    public static let calendarWaitSeconds = 15.0
    private let snapshotLock = NSLock()
    private var snapshot: (state: String, folder: String?) = ("idle", nil)
    private var parts: [String] = []
    private var partsSeconds = 0.0
    private var lastStop: JSONValue = .null
    public private(set) var queue: [String]
    private var processing: WorkerProcess?
    private var processingFolder: String?
    /// The running processing leaves the notes for later (decided when it started).
    private var processingWantsNotes = false
    public private(set) var notesQueue: [String]
    private var notes: WorkerProcess?
    private var notesFolder: String?
    private var notesWaiting: JSONValue?
    private var notesWaitingLogged = false
    private var notesRetryAt: [String: Double] = [:]
    private var notesRetries: [String: Int] = [:]
    /// Notes palaver-lm stopped for low memory, per meeting.
    private var notesMemoryStops: [String: Int] = [:]
    private var indexer: WorkerProcess?
    private var indexDownloading = false
    public var indexCheckSeconds = DaemonTiming.indexCheckSeconds
    private var indexNext: Double?
    /// Workers stopped for their memory, until they exit (daemon.py `_ending`).
    private var ending: [Ending] = []
    /// A `process` stopped for its memory: "requeue" or "drop" (queued again, or given up, already).
    private var memoryEnded: [ObjectIdentifier: String] = [:]
    private var indexTries = 0
    /// When the index may run again after a stop for low memory (.infinity: not before the next start).
    private var indexResumeAt = 0.0
    private var retryAt: [String: Double] = [:]
    private var retries: [String: Int] = [:]
    private var waitingModels: Set<String> = []
    private var waitingSince: [String: Double] = [:]
    private var stopSent: [String: Double] = [:]
    /// Live and stream workers started, by folder.
    private var children: [String: [(kind: String, process: WorkerProcess)]] = [:]
    private var coach: WorkerProcess?
    private var helpers: [(folder: String, process: WorkerProcess)] = []
    private let helpersLock = NSLock()
    private var lastActive = false
    private var lastCall: CallApp?
    private var detectorFailing = false
    private var callApp = "teams"
    public private(set) var auto = true
    public private(set) var manual = false
    private var question: StopQuestion?
    private var silent: SilentCall?
    private var stoppedAt: Double?
    private var notifiedProblems: Set<Int> = []
    private var notifiedAt: Double?
    private let pidsLock = NSLock()
    private var workerPids: [Int32] = []

    public init(_ deps: DaemonDeps) throws {
        self.deps = deps
        trigger = deps.trigger
        since = deps.wall()
        let state = DaemonStateFile.read(deps.statePath)
        cut = Cut(state["cut"], timeZone: deps.timeZone)
        queue = RecordingFolders.restoreQueue(state, key: "queued", doneMarker: deps.doneMarker()).map(\.path)
        notesQueue = RecordingFolders.restoreQueue(state, key: "notes_queued", doneMarker: "notes.json").map(\.path)
        if !queue.isEmpty { info("resuming \(queue.count) queued transcription(s)") }
        let pid = state["pid"]?.doubleValue.map { Int32(clamping: Int($0)) }
        let running = state["state"]?.stringValue
        if running != nil, running != "stopped", pid != deps.pid, deps.palaverAlive(pid) {
            throw DaemonRunning(description: "Palaver is already running (pid \(pid!)); quit it before starting another one.")
        }
        recoverCrash(state)
        markLeftBehind()
        for app in state["ignored"]?.arrayValue?.compactMap(\.stringValue) ?? [] {  // a stale hold, across a restart (#7)
            _ = ignore(app)
        }
        if let cut { askCutsEvent(cut) }  // observers don't run in init
    }

    public func now() -> Double { deps.clock() }
    private func info(_ m: String) { deps.log("INFO", m) }
    private func warning(_ m: String) { deps.log("WARNING", m) }
    private func logError(_ m: String) { deps.log("ERROR", m) }
    private func iso(_ d: Date, seconds: Bool = false) -> String { WallTime.iso(d, deps.timeZone, seconds: seconds) }

    /// Python's `run`: ticks until `until`, `sleep`ing `poll` seconds between.
    public func run(until: () -> Bool, poll: Double = 2, sleep: (Double) -> Void) {
        info("daemon started; waiting for a Teams call")
        writeState()
        while !until() {
            tick()
            sleep(poll)
        }
    }

    // MARK: - the tick

    public func tick() {
        reapChildren()
        watchMemory()
        releaseCut()
        decideContinuation()
        if manual {
            watchManual()
        } else if auto {
            let active = detectSafely()
            for action in trigger.update(now: now(), active: active, app: lastCall) {
                if action == .start {
                    callApp = trigger.app?.rawValue ?? callApp
                    start()
                } else {
                    stop(trigger.stoppedBecause?.rawValue)
                }
            }
        }
        watchSilentCall()
        watchAudio()
        pumpProcessing()
        writeState()
        levels?.update(recording: session != nil ? folder : nil)
    }

    /// A call recorded automatically that nothing is heard of on this Mac (#7): asked about, then
    /// stopped; no new recording until the app lets go of the microphone.
    private func watchSilentCall() {
        guard session != nil, !manual, let folder else { silent = nil; return }
        if silent == nil { silent = SilentCall() }
        let others = deps.othersSilence(), silentFor = deps.silence()
        let action = silent!.update(now(), othersSilent: others, allSilent: silentFor)
        let app = callApp
        let callName = callNames[app] ?? "call"
        switch action {
        case .ask?:
            let minutes = silent!.minutes
            info("asking whether to stop \(name(folder)): silent for \(minutes) min")
            deps.notify(stopQuestionTitle("silence", minutes: minutes),
                        stopQuestionText("silent_call", minutes: minutes, app: callApp), name(folder))
        case .stop?:
            info("stopping \(name(folder)): silent for \(roundedMinutes(silentFor ?? 0)) min")
            stop("silence")
            releaseHold(app)
            deps.notify("Recording stopped: nothing heard",
                        "Your \(callName) was silent on this Mac for \(roundedMinutes(DaemonTiming.silentCallStopSeconds)) minutes. "
                        + "Palaver records \(callName)s again once the app lets go of the microphone; other calls as always.", nil)
        case nil:
            break
        }
    }

    private func ignore(_ app: String?) -> Bool {
        guard let ignore = deps.ignore, let app else { return false }
        ignore(app)
        return true
    }

    /// A call stopped while `app` keeps the mic: that app's hold is no call until it lets go;
    /// another app's call records as always. A detector that can't tell apps apart blocks.
    private func releaseHold(_ app: String?) {
        if ignore(app) { trigger.reset() } else { trigger.blockUntilReleased() }
    }

    /// One notification per cause of audio trouble in the running recording (issue #50).
    private func watchAudio() {
        guard let session, let folder else { return }
        for p in session.problems where !notifiedProblems.contains(p.id) {
            notifiedProblems.insert(p.id)
            if let at = notifiedAt, p.start - at < DaemonTiming.notifyGroupSeconds { continue }
            notifiedAt = p.start
            deps.notify("Audio problem while recording", Lifecycle.problemWarning(kind: p.kind, track: p.track), name(folder))
        }
    }

    // MARK: - the user's controls

    /// Pause or resume automatic recording. Pausing stops an automatic session now.
    public func setAuto(_ enabled: Bool) {
        auto = enabled
        if !enabled, session != nil, !manual { stop("auto_off") }
        trigger.reset()
        pumpProcessing()
        writeState()
    }

    /// A record switch turned off in the menu: an automatic recording of a call in that app stops now.
    public func switchedOff(_ app: String) {
        if session != nil, !manual, callApp == app {
            stop("auto_off")
            trigger.reset()
            pumpProcessing()
            writeState()
        }
    }

    /// Record now, regardless of a call. False when nothing started: already recording, a double
    /// click right after a stop, or the recording failed.
    @discardableResult
    public func startManual() -> Bool {
        if session != nil { return false }
        if let stoppedAt, now() - stoppedAt < DaemonTiming.doubleClickSeconds {
            info(String(format: "ignored a manual start %.1f s after a recording stopped (a double click)", now() - stoppedAt))
            return false
        }
        manual = true
        start()
        if session == nil { manual = false } else { question = StopQuestion(grace: trigger.grace) }
        writeState()
        return session != nil
    }

    /// Stop whatever is recording; don't restart until the call app releases the mic.
    public func stopManual() {
        let call = session != nil && !manual
        if session != nil { stop("by_you") }
        manual = false
        if call { releaseHold(callApp) } else { trigger.blockUntilReleased() }
        pumpProcessing()
        writeState()
    }

    /// The open question whether to stop the running recording, or null.
    public func stopQuestion() -> JSONValue {
        let open: String?, minutes: Int
        if manual { open = question?.open; minutes = question?.minutes ?? 0 } else { open = silent?.open; minutes = silent?.minutes ?? 0 }
        guard let open, let folder else { return .null }
        return .object([("meeting", .string(name(folder))), ("reason", .string(open)), ("minutes", .int(minutes)),
                        ("message", .string(stopQuestionText(open, minutes: minutes, app: callApp)))])
    }

    /// "stop" or "keep", for the recording `meeting` (nil: the one running). False when that
    /// recording no longer runs, or no question is open.
    @discardableResult
    public func answerStopQuestion(_ choice: String, meeting: String? = nil) -> Bool {
        guard choice == "stop" || choice == "keep", let folder else { return false }
        if !manual && silent?.open == nil { return false }  // an automatic recording is asked about only when silent (#7)
        if let meeting, meeting != name(folder) { return false }
        if choice == "stop" {
            info("stopping the recording \(name(folder)) as asked")
            stopManual()
            return true
        }
        if manual {
            guard question?.open != nil else { return false }
            question!.keep(now())
        } else {
            guard silent?.open != nil else { return false }
            silent!.keep(now())
        }
        info("keeping the recording \(name(folder))")
        writeState()
        return true
    }

    // MARK: - status

    private func why() -> JSONValue {
        guard let s = session else { return .null }
        func known(_ fields: [(String, JSONValue)]) -> JSONValue { .object(fields.filter { $0.1.truthy }) }
        var fields: [(String, JSONValue)] = [
            ("trigger", .str(triggerName)), ("since", .string(iso(since, seconds: true))), ("restarts", .int(parts.count)),
            ("mic", known([("device", .str(s.micDevice)), ("rate", .num(s.micRate)), ("source", .str(s.micSource))])),
            ("system", known([("device", .str(s.systemDevice)), ("rate", .num(s.systemRate)), ("source", .str(s.systemSource))])),
        ]
        let problems = s.problems.filter { $0.end == nil }
        if !problems.isEmpty {  // what is wrong with its audio right now (issue #50)
            fields.append(("problems", .array(problems.map {
                .object([("kind", .string($0.kind)), ("track", .string($0.track)), ("start", .double($0.start))])
            })))
        }
        let hints = s.hints
        if !hints.isEmpty {  // soft: no notification, no ⚠ (a muted mic)
            fields.append(("hints", .array(hints.map { .object([("kind", .string($0.kind)), ("track", .string($0.track))]) })))
        }
        return .object(fields)
    }

    private func whyText(_ why: JSONValue) -> JSONValue {
        guard !why.isNull else { return .null }
        let cost = deps.watchdog?.costText()
        return .string([Lifecycle.recordingText(why, timeZone: deps.timeZone), cost].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · "))
    }

    private func memoryStatus() -> JSONValue {
        guard let watchdog = deps.watchdog, var status = watchdog.status() else { return .null }
        if let waiting = notesWaiting, case .object(var fields) = status,
           let i = fields.firstIndex(where: { $0.0 == "workers" }), case .array(var workers) = fields[i].1,
           case .object(let w) = waiting {
            workers.append(.object([("kind", .string("notes")), ("label", .string("Notes"))] + w
                                   + [("state", .string("waiting for memory"))]))
            fields[i].1 = .array(workers)
            status = .object(fields)
        }
        return status
    }

    /// The live coach's talk line and nudge (#41, #42): coach.json of the recording, as the worker
    /// wrote it; nulls while there is none, it is unreadable or older than `coachStale` (a dead
    /// worker's last word is not who talks now).
    private func coachStatus() -> (talk: JSONValue, talkText: JSONValue, nudge: JSONValue, quiet: JSONValue) {
        let none = (JSONValue.null, JSONValue.null, JSONValue.null, JSONValue.array([]))
        guard session != nil, let folder, let file = CoachStatusFile.read(url(folder), now: deps.coachNow()) else { return none }
        return (file["talk"] ?? .null, file["talk_text"] ?? .null, file["nudge"] ?? .null, file["quiet"] ?? .array([]))
    }

    /// daemon.json, in daemon.py's key order.
    public func status() -> JSONValue {
        let why = self.why()
        let state = session != nil ? "recording" : (!auto ? "paused" : "idle")
        let notesListed = (notesFolder.map { [$0] } ?? []) + notesQueue
        let coach = coachStatus()
        return .object([
            ("state", .string(state)),
            ("auto", .bool(auto)),
            ("manual", .bool(manual)),
            ("since", .string(iso(since, seconds: true))),
            ("folder", .str(folder)),
            ("queued", .strings(queue)),
            ("transcribing", .bool(processing != nil)),
            ("transcribing_folder", .str(processingFolder)),
            ("notes_queued", .strings(notesListed)),
            ("writing_notes", .str(notesFolder)),
            ("indexing", .bool(indexer != nil)),
            ("index_downloading", .bool(indexer != nil && indexDownloading)),
            ("system_source", .str(session?.systemSource)),
            ("mic_source", .str(session?.micSource)),
            ("missing", .strings(session?.missing ?? [])),
            ("teams_active", .bool(lastActive)),
            ("stop_question", stopQuestion()),
            ("ignored", .strings(deps.ignored().sorted())),  // kept across a restart (#7)
            ("why", why),
            ("why_text", whyText(why)),
            ("warnings", .strings(Lifecycle.recordingWarnings(why))),
            ("hints", .strings(Lifecycle.recordingHints(why))),
            ("memory", memoryStatus()),
            ("talk", coach.talk), ("talk_text", coach.talkText), ("nudge", coach.nudge), ("quiet", coach.quiet),
            ("last_stop", lastStop),
            ("continues", .strings(parts)),
            ("cut", (cut ?? pending?.cut)?.json ?? .null),  // held back until decided
            ("pid", .int(Int(deps.pid))),
            ("updated", .string(iso(deps.wall(), seconds: true))),
        ])
    }

    /// The state for app.sock's calls: "recording" | "idle" | "paused" | "stopped", and the folder.
    /// A snapshot taken with daemon.json (under a lock): safe from any thread, as the `test` call
    /// reads it from its connection's.
    public var state: (state: String, folder: String?) {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return snapshot
    }

    /// Finalize a running recording before exiting. "restart" (quit from outside): a call's
    /// recording is held back for the next start to continue (#47); "by_you" (the menu's Quit):
    /// processed as any recording stopped by hand.
    public func shutdown(_ reason: String = "restart") {
        if session != nil { stop(reason) }
        pumpProcessing()
        if let indexer {  // it goes on after the next start; never on the old code (#60)
            indexer.terminate()
            self.indexer = nil
        }
        writeState(state: "stopped")
    }

    // MARK: - detection

    private func detectSafely() -> Bool {
        let call = detectCall()
        if let call, session == nil { callApp = call.rawValue }  // a call's app is fixed once it records
        return call != nil
    }

    private func detectCall() -> CallApp? {
        let found: CallApp?
        do {
            // Another app's call (a Slack call ringing or answered) never cuts the one recorded.
            found = try deps.detect(session != nil && !manual ? CallApp(rawValue: callApp) : nil)
        } catch {
            if !detectorFailing { warning("call detection failed; keeping the last state: \(error)") }
            detectorFailing = true
            return lastCall
        }
        if detectorFailing { info("call detection recovered") }
        detectorFailing = false
        lastCall = found
        lastActive = found != nil
        return found
    }

    /// A manual recording runs on: ask once whether to stop it when its call ended or it has been silent long.
    private func watchManual() {
        guard question != nil, let folder else { return }
        let call = detectCall()
        guard let reason = question!.update(now(), call: call?.rawValue, silentFor: deps.silence()) else { return }
        let minutes = question!.minutes
        info("asking whether to stop the manual recording \(name(folder)) (\(reason))")
        deps.notify(stopQuestionTitle(reason, minutes: minutes), stopQuestionText(reason, minutes: minutes), name(folder))
    }

    // MARK: - restarts and crashes (#47)

    /// The last run died while it recorded: what it recorded is held back like a quit's, to be
    /// continued, or queued; never left behind.
    private func recoverCrash(_ state: JSONValue) {
        let s = state["state"]?.stringValue
        guard s != nil, s != "stopped", let folder = state["folder"]?.stringValue, !folder.isEmpty else { return }
        let folders = (state["continues"]?.arrayValue?.compactMap(\.stringValue) ?? []) + [folder]
        let why = state["why"] ?? .null
        let trigger = why["trigger"]?.stringValue ?? (state["manual"]?.truthy == true ? "manual" : nil)
        var atText = state["updated"]?.stringValue
        var sinceText = why["since"]?.stringValue ?? state["since"]?.stringValue
        var at = WallTime.parse(atText, deps.timeZone), since = WallTime.parse(sinceText, deps.timeZone)
        if at == nil || since == nil {
            let w = deps.wall()
            at = w; since = w
            atText = iso(w); sinceText = iso(w)
        }
        warning("the last run ended while recording \(name(folders.last!)); recovering it")
        let seconds = max(0, at!.timeIntervalSince(since!))
        if let trigger, DaemonTiming.callTriggers.contains(trigger) {
            releaseCut(now: true)
            cut = Cut(folders: folders, trigger: trigger, at: atText!, since: sinceText!, seconds: seconds)
        } else {
            queueMeeting(folders, seconds: seconds)
        }
    }

    /// Whether a recording of `trigger` starting now may continue the one cut when Palaver quit: a
    /// call in the same app, soon enough, with a part of it still there. Whether it is the next
    /// calendar event's call is decided after the start (`decideContinuation`).
    private func continuable(_ trigger: String) -> Bool {
        guard let cut, DaemonTiming.callTriggers.contains(trigger), cut.trigger == trigger, !cutExpired(cut) else { return false }
        return cut.folders.contains(where: { RecordingFolders.isDir(url($0)) })
    }

    /// The cut's calendar event, asked ahead (Python answers later): at the next start only the
    /// event on then is left to ask.
    private func askCutsEvent(_ cut: Cut) {
        if let at = WallTime.parse(cut.at, deps.timeZone) { _ = deps.eventKeyAt(at) }
    }

    /// The running recording continues the cut one unless the calendar says it is another event's
    /// call (Python's rule: both keys known and different). Waits for the calendar's answers on
    /// later ticks, at most `calendarWaitSeconds`; `force` (the recording stops): decides now, an
    /// answer not in yet counting as no key.
    private func decideContinuation(force: Bool = false) {
        guard let pc = pending else { return }
        guard let folder else { pending = nil; return }
        let force = force || now() - pc.askedAt >= Self.calendarWaitSeconds
        var other = false
        switch WallTime.parse(pc.cut.at, deps.timeZone).map(deps.eventKeyAt) ?? .known(nil) {
        case .pending:
            if !force { return }
        case .known(nil):
            break  // no event then: nothing to compare, no second lookup
        case .known(let then?):
            switch deps.eventKeyAt(pc.startedAt) {
            case .pending: if !force { return }
            case .known(let current): other = current != nil && current != then
            }
        }
        pending = nil
        var continued = false
        if other {
            info("a call in another calendar event: not continuing \(name(pc.cut.folders[0]))")
            cut = pc.cut  // held back until its window passes, as before
        } else {
            let parts = pc.cut.folders.filter { RecordingFolders.isDir(url($0)) }
            do {
                for part in parts.dropFirst() + [folder] { try deps.addPart(url(parts[0]), url(part)) }
                self.parts = parts
                partsSeconds = pc.cut.seconds
                since = WallTime.parse(pc.cut.since, deps.timeZone) ?? since
                // The maximum length is the whole meeting's.
                trigger.startedAt(now() - deps.wall().timeIntervalSince(since))
                info("\(name(folder)) continues \(name(parts[0])) (cut when Palaver quit)")
                continued = true
            } catch {
                // Not one meeting then: the earlier parts on their own, this one as its own.
                logError("could not mark \(name(folder)) as continuing \(name(parts[0])): \(error)")
                queueMeeting(parts, seconds: pc.cut.seconds)
            }
        }
        if !pc.missingTold {
            if continued {
                deps.notify("Recording continued", "Palaver restarted during the call; it stays one meeting.", name(parts[0]))
            } else {
                let said = MenuText.recordingStarted(trigger: triggerName)
                deps.notify(said.title, said.message, name(folder))
            }
        }
    }

    private func cutExpired(_ cut: Cut) -> Bool {
        guard let at = WallTime.parse(cut.at, deps.timeZone) else { return true }
        return deps.wall().timeIntervalSince(at) > DaemonTiming.continueWithin
    }

    /// Process the recording cut when Palaver quit once it can no longer be continued (`now`: it can't anyway).
    private func releaseCut(now: Bool = false) {
        guard let cut, now || cutExpired(cut) else { return }
        self.cut = nil
        if let head = queueMeeting(cut.folders, seconds: cut.seconds) {
            info("\(name(head)) was not continued after the restart; transcribing it")
        }
    }

    /// At start: a recording without a transcript that nothing will transcribe is marked not
    /// transcribed, so the window offers Transcribe Again.
    private func markLeftBehind() {
        guard let outputDir = deps.outputDir,
              let names = try? FileManager.default.contentsOfDirectory(atPath: outputDir.path) else { return }
        let folders = names.filter(RecordingFolders.isRecordingName).map { outputDir.appendingPathComponent($0).path }
            .filter { RecordingFolders.isDir(url($0)) }
        var held = Set(queue + (cut?.folders ?? []))
        for f in folders { held.formUnion(Continuation.parts(url(f)).map(\.path)) }
        var running: [String]?
        for folder in folders.sorted() {
            let f = url(folder)
            let exists = { RecordingFolders.exists(f.appendingPathComponent($0)) }
            let recorded = (exists("mic.wav") || exists("mic_raw.wav")) && exists("system.wav")
            if held.contains(folder) || !recorded || exists("transcript.json") || ProcessState.read(f) != nil
                || deps.liveRunning(f) { continue }
            if running == nil { running = deps.processes() }
            if running!.contains(where: { $0.contains(folder) }) { continue }  // a `process` from before the restart
            info("\(name(folder)) has no transcript and nothing transcribes it; marked not transcribed")
            ProcessState.mark(f, ProcessState.error, now: deps.wall(), timeZone: deps.timeZone)
        }
    }

    /// Queue the meeting recorded in `folders` (its parts, in order): the first one still there,
    /// with the others listed as its parts. Returns it; nil when nothing is left or it is too short.
    @discardableResult
    private func queueMeeting(_ folders: [String], seconds: Double? = nil) -> String? {
        let alive = folders.filter { RecordingFolders.isDir(url($0)) }
        guard let head = alive.first else { return nil }
        if let seconds, seconds < DaemonTiming.minProcessSeconds {
            info(String(format: "recording %@ too short (%.0f s); not transcribing", name(head), seconds))
            ProcessState.mark(url(head), ProcessState.error, error: "shorter than a minute", now: deps.wall(), timeZone: deps.timeZone)
            return nil
        }
        var alone: [String] = []
        for part in alive.dropFirst() {
            do { try deps.addPart(url(head), url(part)) } catch {
                logError("could not list \(name(part)) as a part of \(name(head)); processing it alone: \(error)")
                alone.append(part)
            }
        }
        for f in [head] + alone where !queue.contains(f) { queue.append(f) }
        return head
    }

    // MARK: - start and stop

    private func start() {
        let trig = manual ? "manual" : callApp
        // The session starts at once; whether it continues the cut one is decided after (the
        // calendar answers later), so nothing of the call is lost waiting for it.
        let candidate = continuable(trig) ? cut : nil
        let session = deps.newSession(trig)
        let started: URL
        do {
            started = try deps.beforeRecord { try session.start() }
        } catch {
            logError("could not start recording: \(error)")
            deps.notify("Meeting recording failed", "\(error)", nil)
            trigger.blockUntilReleased()
            return
        }
        let folder = started.path
        self.session = session
        self.folder = folder
        triggerName = trig
        notifiedProblems = []
        notifiedAt = nil
        since = deps.wall()
        if manual { info("recording started by you; recording to \(folder)") }
        else { info("\(callApp.prefix(1).uppercased() + callApp.dropFirst()) call detected; recording to \(folder)") }
        let missing = session.missing
        if let first = missing.first {
            deps.notify("Recording without the \(first)", "Check Privacy & Security settings, then run `palaver doctor`.", name(folder))
        } else if candidate == nil {
            let said = MenuText.recordingStarted(trigger: trig)
            deps.notify(said.title, said.message, name(folder))
        }
        if let candidate {
            cut = nil
            pending = (candidate, since, now(), !missing.isEmpty)
        }
        if let launchLive = deps.launchLive, deps.live() {
            do { keepChild(folder, try launchLive(started), kind: "live") } catch {
                logError("could not start live processing; transcribing after the call: \(error)")
            }
        }
        if let launchStream = deps.launchStream, deps.realtime() {  // read now: applies from this recording
            do { keepChild(folder, try launchStream(started), kind: "stream") } catch {
                logError("could not start the live stream: \(error)")
            }
        }
        if let launchCoach = deps.launchCoach, DaemonTiming.callTriggers.contains(trig) {  // calls only
            do { coach = try launchCoach(started) } catch {
                logError("could not start the live coach: \(error)")
                coach = nil
            }
        }
        decideContinuation()  // a calendar asked ahead may know already
    }

    /// Kept to reap it once it exits, and for the memory watchdog.
    private func keepChild(_ folder: String, _ process: WorkerProcess, kind: String) {
        children[folder, default: []].append((kind, process))
        updateWorkerPids()
    }

    private func reapChildren() {
        if let c = coach, c.poll() != nil { coach = nil }  // ended: not started again, its file goes stale
        for (folder, procs) in children {
            let running = procs.filter { $0.process.poll() == nil }
            children[folder] = running.isEmpty ? nil : running
        }
    }

    private func workerBusy(_ folder: String) -> Bool {
        reapChildren()
        return deps.liveRunning(url(folder))
    }

    /// `reason`: "call_ended", "max_length", "by_you", "auto_off", "silence" or "restart"; kept in meta.json.
    private func stop(_ reason: String?) {
        decideContinuation(force: true)
        let session = self.session, folder = self.folder, trig = triggerName, since = self.since
        let parts = self.parts, before = partsSeconds
        self.session = nil; self.folder = nil; triggerName = nil
        if let c = coach { c.terminate(); coach = nil }  // it ends with the recording by itself too
        self.parts = []; partsSeconds = 0
        manual = false; question = nil; silent = nil
        if session != nil { stoppedAt = now() }
        self.since = deps.wall()
        guard let session, let folder else { return }
        let head = parts.first ?? folder
        let duration: Double
        do {
            duration = try session.stop(reason: reason)
        } catch {
            logError("stopping the recording failed: \(error)")
            deps.notify("Meeting recording failed", "\(error)", nil)
            // `process` recovers what was written, and joins it to the earlier parts.
            queueMeeting(parts + [folder])
            return
        }
        lastStop = .object([("folder", .string(folder)), ("reason", .str(reason)),
                            ("text", .str(Lifecycle.stoppedText(trigger: trig, reason: reason))),
                            ("at", .string(iso(deps.wall())))])
        if reason == "restart", let trig, DaemonTiming.callTriggers.contains(trig) {
            // Held back: the next start continues it if the call is still on.
            releaseCut(now: true)  // only one can be continued
            cut = Cut(folders: parts + [folder], trigger: trig, at: iso(deps.wall()), since: iso(since),
                      seconds: ((before + duration) * 1000).rounded() / 1000)
            info("Palaver quits while recording \(name(head)); a call still on within \(Int(DaemonTiming.continueWithin / 60)) min continues it")
            return
        }
        let total = duration + before
        if queueMeeting(parts + [folder], seconds: total) == nil {
            deps.notify("Meeting recorded", "\(name(head)): under a minute, not transcribed", name(head))
            return
        }
        info(String(format: "call ended after %.1f min; queued transcription of %@", total / 60, name(head)))
        deps.notify("Meeting recorded", String(format: "%.0f min — transcribing in the background", total / 60), name(head))
    }

    // MARK: - the queues

    public func pumpProcessing() {
        pumpNotes()
        pumpWork()
        pumpIndex()
    }

    private func pumpWork() {
        if let p = processing {
            guard let rc = p.poll() else { return }
            if let stopped = memoryEnded.removeValue(forKey: ObjectIdentifier(p)) {
                // Stopped for its memory: queued again by watchMemory, or given up.
                if stopped == "drop", let done = processingFolder { retries[done] = nil }
            } else if let done = processingFolder {
                if rc == 0 && processingWantsNotes { notesQueue.append(done) }
                if rc == DaemonTiming.exitBusy {
                    retryLater(done)
                } else if rc == DaemonTiming.exitModels {
                    waitForModels(done)
                } else {
                    retries[done] = nil
                    if rc != 0 {
                        // Not retried: running it again would fail the same way.
                        logError("processing \(name(done)) failed (exit \(rc)); its session.log says why")
                        if ProcessState.read(url(done)) == nil {  // killed before it could say so
                            ProcessState.mark(url(done), ProcessState.error, error: "it stopped unexpectedly, exit \(rc)",
                                              now: deps.wall(), timeZone: deps.timeZone)
                        }
                        deps.notify("Transcription failed", "\(name(done)): open it to see why and to transcribe it again", name(done))
                    }
                }
            }
            indexNext = nil  // a new transcript to index
        }
        processing = nil
        processingFolder = nil
        let now = self.now()
        guard let folder = queue.first(where: { (retryAt[$0] ?? now) <= now }) else { return }
        if waitsForModels(folder) {
            switch deps.modelsReady(url(folder)) {
            case true?:
                info("the models of \(name(folder)) are here")
                waitingModels.remove(folder)
            case false?:
                retryAt[folder] = now + DaemonTiming.modelsCheckSeconds
                return
            case nil:
                return  // being asked
            }
        }
        // A meeting continued after a restart: the live workers of all its parts.
        let busy = ([folder] + Continuation.parts(url(folder)).map(\.path)).filter(workerBusy)
        if !busy.isEmpty {
            let waiting = waitingSince[folder] ?? now
            waitingSince[folder] = waiting
            if now - waiting < DaemonTiming.liveFinishTimeout { return }  // it writes most of the transcript
            if let asked = stopSent[folder] {
                if now - asked < DaemonTiming.stopGrace { return }
                warning("live processing of \(name(busy[0])) did not exit; `process` decides")
            } else {
                for f in busy {
                    warning("live processing of \(name(f)) is stuck; stopping it")
                    deps.stopLive(url(f))
                }
                stopSent[folder] = now
                return  // `process` runs once it has exited
            }
        }
        queue.removeAll { $0 == folder }
        waitingSince[folder] = nil; stopSent[folder] = nil; retryAt[folder] = nil
        info("transcribing \(name(folder))")
        do {
            let wantsNotes = deps.launchNotes != nil && deps.notesWanted()
            processing = try deps.launchProcessing(url(folder))
            processingFolder = folder
            processingWantsNotes = wantsNotes
            updateWorkerPids()
        } catch {
            logError("could not start transcribing \(name(folder)): \(error)")
            retryLater(folder, why: "could not be started")
        }
    }

    private func waitsForModels(_ folder: String) -> Bool {
        if waitingModels.contains(folder) { return true }
        return ProcessState.read(url(folder))?["reason"]?.stringValue == ProcessState.models  // since before a restart
    }

    /// `process` found models missing: the meeting stays queued and is transcribed once they are here.
    private func waitForModels(_ folder: String) {
        if !waitingModels.contains(folder) {
            waitingModels.insert(folder)
            info("\(name(folder)) waits for its models to download")
            deps.notify("Meeting recorded", "\(name(folder)): transcribed once the models are downloaded", name(folder))
        }
        retryAt[folder] = now() + DaemonTiming.modelsCheckSeconds
        if !queue.contains(folder) { queue.append(folder) }
    }

    /// Transcribe Again in the window: the meeting goes first in the queue. False while it is
    /// being transcribed already.
    @discardableResult
    public func transcribeAgain(_ folderURL: URL) -> Bool {
        let folder = folderURL.path
        if folder == processingFolder { return false }
        ProcessState.clear(folderURL)
        waitingModels.remove(folder)
        retryAt[folder] = nil; retries[folder] = nil; waitingSince[folder] = nil; stopSent[folder] = nil
        queue.removeAll { $0 == folder }
        queue.insert(folder, at: 0)
        info("transcribing \(name(folder)) again, as asked")
        return true
    }

    /// `process` refused: something of the meeting is still busy. It stays queued, tried again later.
    private func retryLater(_ folder: String, why: String = "is still busy") {
        let n = (retries[folder] ?? 0) + 1
        retries[folder] = n
        let delay = backoff(n)
        retryAt[folder] = now() + delay
        if !queue.contains(folder) { queue.append(folder) }
        info(String(format: "%@ %@; trying again in %.0f s", name(folder), why, delay))
    }

    /// Notes one at a time: not while a call is recorded, not while a recording is processed, and
    /// only with enough free memory. A call that starts meanwhile stops them; they start over after.
    private func pumpNotes() {
        if let n = notes {
            if let rc = n.poll() {
                let folder = notesFolder
                notes = nil; notesFolder = nil
                indexNext = nil  // new notes to index
                // palaver-lm stopped itself: the Mac ran low on memory while it was over its budget (the watchdog's rule).
                if rc == MemoryRules.lowMemoryExit, let folder { notesStoppedForMemory(folder) }
            } else if session != nil, let f = notesFolder {
                info("a call started; writing the notes of \(name(f)) again after it")
                n.terminate()
                notesQueue.insert(f, at: 0)
                notes = nil; notesFolder = nil
            }
            return
        }
        notesWaiting = nil
        guard let first = notesQueue.first, let launchNotes = deps.launchNotes else { return }
        if session != nil || processing != nil { return }
        if ending.contains(where: { $0.kind == "notes" }) { return }  // the run stopped for low memory has not exited yet
        let now = self.now()
        if (notesRetryAt[first] ?? now) > now {
            guard let ready = notesQueue.first(where: { (notesRetryAt[$0] ?? now) <= now }) else { return }
            notesQueue.removeAll { $0 == ready }
            notesQueue.insert(ready, at: 0)
        }
        let next = notesQueue[0]
        guard let needed = deps.notesMemoryGB(url(next)) else { return }  // being asked
        let free = needed > 0 ? deps.memoryFreeGB() : .infinity
        if free < needed {
            if !notesWaitingLogged {
                info(String(format: "notes wait for memory: %.0f GB free, %.0f GB needed", free, needed))
                notesWaitingLogged = true
            }
            notesWaiting = .object([("meeting", .string(name(next))), ("need", .double(needed)), ("free", .double(free))])
            return
        }
        notesWaitingLogged = false
        notesQueue.removeFirst()
        notesRetryAt[next] = nil
        info("writing notes for \(name(next))")
        do {
            notes = try launchNotes(url(next))
            notesFolder = next
            updateWorkerPids()
        } catch {
            logError("could not start writing the notes of \(name(next)): \(error)")
            let n = (notesRetries[next] ?? 0) + 1
            notesRetries[next] = n
            notesRetryAt[next] = now + backoff(n)
            notesQueue.append(next)
        }
    }

    /// The search index (`palaver index`): only when nothing else runs or waits, with free memory.
    /// Anything starting stops it; it goes on from where it was afterwards.
    private func pumpIndex() {
        guard let launchIndex = deps.launchIndex else { return }
        let busy = session != nil || processing != nil || notes != nil || !notesQueue.isEmpty || !queue.isEmpty
        if let ix = indexer {
            if let rc = ix.poll() {
                indexer = nil
                let wait = rc == 0 ? indexCheckSeconds : DaemonTiming.indexRetrySeconds
                if rc != 0 {
                    warning(String(format: "building the search index failed (exit %d); trying again in %.0f min", rc, wait / 60))
                }
                indexNext = now() + wait
            } else if busy {
                info("pausing the search index while something else runs")
                ix.terminate()
                indexer = nil; indexNext = nil
            }
            return
        }
        if busy { return }
        if let next = indexNext, now() < next { return }
        if now() < indexResumeAt || ending.contains(where: { $0.kind == "index" }) { return }  // stopped for low memory (#49)
        indexNext = now() + indexCheckSeconds
        if deps.memoryFreeGB() < DaemonTiming.indexMemoryGB { return }
        guard let wanted = deps.indexWanted() else { indexNext = nil; return }  // being asked
        guard wanted else { return }
        indexDownloading = !deps.indexModelReady()
        info("building the search index" + (indexDownloading ? " (downloading its model first)" : ""))
        do {
            indexer = try launchIndex()
            updateWorkerPids()
        } catch {
            logError("could not start the search index: \(error)")
        }
    }

    // MARK: - workers

    /// A best-next-question helper the window started: watched like notes (#41, #49). Any thread.
    public func watchHelper(folder: String, process: WorkerProcess) {
        helpersLock.lock(); defer { helpersLock.unlock() }
        helpers.append((folder, process))
    }

    /// Every worker this daemon started that may still run, by kind.
    public func workers() -> [DaemonWorker] {
        var out: [DaemonWorker] = []
        for (folder, procs) in children { out += procs.map { DaemonWorker(kind: $0.kind, folder: folder, process: $0.process) } }
        helpersLock.lock()
        helpers.removeAll { $0.process.poll() != nil }
        out += helpers.map { DaemonWorker(kind: "question", folder: $0.folder, process: $0.process) }
        helpersLock.unlock()
        if let processing, let processingFolder { out.append(DaemonWorker(kind: "process", folder: processingFolder, process: processing)) }
        if let notes, let notesFolder { out.append(DaemonWorker(kind: "notes", folder: notesFolder, process: notes)) }
        if let indexer { out.append(DaemonWorker(kind: "index", folder: nil, process: indexer)) }
        for e in ending where !out.contains(where: { $0.process === e.process }) {
            out.append(DaemonWorker(kind: e.kind, folder: e.folder, process: e.process))
        }
        return out
    }

    /// Samples the workers; restarts a live or stream worker over budget, stops notes, `process`
    /// or the index over budget while the Mac is low on memory. The recording itself is never
    /// touched: capture runs in this process.
    private func watchMemory() {
        guard let watchdog = deps.watchdog else { return }
        for a in watchdog.watch(workers(), now: now()) {
            let isIndex = a.kind == "index"
            let folder: String? = isIndex ? nil : a.folder
            if a.kind == "question" {  // stopped, nothing queued, no notification: the window says so
                ending.append(Ending(kind: a.kind, folder: folder, process: a.process, since: now(), restart: false, told: ("", "")))
                a.process.signalGroup(SIGTERM)
                continue
            }
            if !a.title.isEmpty && a.what != "restart" {  // a restart is told once it happened
                deps.notify(a.title, a.message, isIndex ? nil : name(a.folder))
            }
            if a.what == "warn" { continue }
            switch a.kind {
            case "process":
                memoryEnded[ObjectIdentifier(a.process)] = a.what
                if a.what == "requeue" {
                    retryLater(a.folder, why: "was stopped: the Mac is low on memory")
                } else if a.what == "drop" {  // given up: the window offers to try again
                    ProcessState.mark(url(a.folder), ProcessState.error, error: "stopped too often: the Mac was low on memory",
                                      now: deps.wall(), timeZone: deps.timeZone)
                }
            case "index":
                if indexer === a.process { indexer = nil }
                indexLater(a.what)
            case "notes":
                if notes === a.process { notes = nil; notesFolder = nil }
                if a.what == "requeue" { notesLater(a.folder) }
            default: break
            }
            ending.append(Ending(kind: a.kind, folder: folder, process: a.process, since: now(),
                                 restart: a.what == "restart", told: (a.title, a.message)))
            a.process.signalGroup(SIGTERM)
        }
        finishEnding()
    }

    /// The search index stopped for low memory goes on after a backoff; the last time, not before
    /// Palaver starts again.
    private func indexLater(_ what: String) {
        if what == "drop" {
            indexResumeAt = .infinity
            warning("the search index was stopped too often for low memory; not before the next start")
            return
        }
        indexTries += 1
        let delay = backoff(indexTries)
        indexResumeAt = now() + delay
        info(String(format: "the search index was stopped: the Mac is low on memory; trying again in %.0f s", delay))
    }

    /// Notes stopped for low memory wait in the queue, with a backoff, then for the free memory
    /// their model needs as any notes do.
    /// Notes palaver-lm stopped for low memory: queued again like a stop of the watchdog's own ("requeue"), given up
    /// with the watchdog's words after `maxRequeues` ("drop").
    private func notesStoppedForMemory(_ folder: String) {
        let n = (notesMemoryStops[folder] ?? 0) + 1
        notesMemoryStops[folder] = n
        if n <= MemoryRules.maxRequeues {
            if n == 1 { deps.notify("Notes paused: the Mac is low on memory", "They are written again later.", name(folder)) }
            notesLater(folder)
        } else {
            let (title, message) = MemoryTexts.texts(kind: "notes", what: "drop", used: 0, limit: 0, meeting: name(folder), free: nil)
            deps.notify(title, message, name(folder))
            warning("notes of \(name(folder)) were stopped for low memory \(n) times; given up")
        }
    }

    private func notesLater(_ folder: String) {
        let n = (notesRetries[folder] ?? 0) + 1
        notesRetries[folder] = n
        let delay = backoff(n)
        notesRetryAt[folder] = now() + delay
        if !notesQueue.contains(folder) { notesQueue.append(folder) }
        info(String(format: "notes of %@ were stopped: the Mac is low on memory; trying again in %.0f s", name(folder), delay))
    }

    /// Kills the workers stopped for their memory that did not exit in time; starts a live or
    /// stream worker again once its old one is gone, while its recording still runs.
    private func finishEnding() {
        for e in ending {
            if e.process.poll() == nil {
                if now() - e.since >= DaemonTiming.killAfter, let i = ending.firstIndex(where: { $0.process === e.process }),
                   !ending[i].killed {
                    warning("\(MemoryRules.labels[e.kind]!.lowercased()) of \(name(e.folder ?? MemoryRules.indexFolder)) did not exit; killing it")
                    e.process.signalGroup(SIGKILL)
                    ending[i].killed = true
                }
                continue
            }
            ending.removeAll { $0.process === e.process }
            guard e.restart, let folder = e.folder else { continue }
            let label = MemoryRules.labels[e.kind]!.lowercased()
            if session == nil || self.folder != folder {
                info("\(label) of \(name(folder)) not started again: the recording stopped; `process` does the rest")
                continue
            }
            guard let launch = e.kind == "live" ? deps.launchLive : deps.launchStream else { continue }
            info("starting \(label) of \(name(folder)) again")
            do { keepChild(folder, try launch(url(folder)), kind: e.kind) } catch {
                logError("could not start \(label) again: \(error)")
                continue
            }
            if !e.told.title.isEmpty { deps.notify(e.told.title, e.told.message, name(folder)) }
        }
    }

    private func updateWorkerPids() {
        var pids: [Int32] = []
        for procs in children.values { pids += procs.map(\.process.pid) }
        pids += [processing?.pid, notes?.pid, indexer?.pid].compactMap { $0 }
        pidsLock.lock(); workerPids = pids; pidsLock.unlock()
    }

    /// What the process tap leaves out, asked when it starts (from any thread): the app and the
    /// workers already running then. The recording's own live and stream workers start after the
    /// tap and are not in it; harmless, they play no audio.
    public func excludedPIDs() -> [pid_t] {
        pidsLock.lock(); defer { pidsLock.unlock() }
        return [deps.pid] + workerPids
    }

    // MARK: - daemon.json

    public func writeState(state: String? = nil) {
        updateWorkerPids()
        let current = state ?? (session != nil ? "recording" : (!auto ? "paused" : "idle"))
        snapshotLock.lock(); snapshot = (current, folder); snapshotLock.unlock()
        var payload = status()
        if let state, case .object(var fields) = payload {
            fields[0].1 = .string(state)
            payload = .object(fields)
        }
        if !DaemonStateFile.write(payload, to: deps.statePath) {
            deps.log("DEBUG", "could not write daemon state")
        }
    }
}

/// What keeps Palaver from restarting now (an update waits for it, #60): a recording, a call, its
/// processing, notes being written or waiting. nil: idle. The search index is no reason.
public func busyReason(_ status: JSONValue) -> String? {
    if status["state"]?.stringValue == "recording" { return "recording" }
    if status["teams_active"]?.truthy == true { return "a call" }
    if status["transcribing"]?.truthy == true || status["queued"]?.truthy == true { return "transcribing" }
    if status["writing_notes"]?.truthy == true || status["notes_queued"]?.truthy == true { return "writing notes" }
    return nil
}


/// `<folder>/coach.json` (live_coach.write_status): {talk, talk_text, nudge, quiet}, rewritten
/// every second by `palaver coach`.
public enum CoachStatusFile {
    /// The file is this old at most (the worker writes every second).
    public static let stale = 10.0

    public static func read(_ folder: URL, now: Date) -> JSONValue? {
        let file = folder.appendingPathComponent("coach.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date, now.timeIntervalSince(modified) <= stale,
              let data = try? Data(contentsOf: file),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return JSONValue(any: obj)
    }
}
