// The daemon as the app runs it (daemon.py `build_daemon` and `launch_run`): the worker commands
// with their QoS, the Python facts asked through `palaver app query`, the real capture, and the
// app.sock actions over the daemon.
import Darwin
import Foundation
import PalaverCapture
import PalaverCloud
import PalaverCore
import PalaverDomain

// MARK: - workers

/// `taskpolicy -c <qos> palaver-worker [--config …] [--dictionary …] [--no-notify] <cmd> [folder] [extra…]`, in a
/// session of its own, stdout and stderr appended to daemon.log; the notes as `palaver-lm [options] notes <folder>`.
public struct WorkerLauncher {
    /// palaver-worker (`AppLocation.binary`).
    public var worker: String
    /// palaver-lm.
    public var lm: String
    /// The commands palaver-worker runs; `notes` is palaver-lm's (housekeeping runs in the app itself).
    public static let workerCommands: Set<String> = ["process", "run", "live", "stream", "coach", "index", "calendar-attach"]
    /// The global options the app got: `--config <abs>`, `--dictionary <abs>`, `--no-notify`.
    public var cliOptions: [String]
    public var log: URL
    /// PALAVER_APP, PALAVER_NOTIFY, PALAVER_NOTIFY_STATE (never PALAVER_WEB_KEY).
    public var env: [String: String]
    public var taskpolicy = "/usr/sbin/taskpolicy"
    /// Runs the argv (after taskpolicy's options); tests record instead.
    public var spawn: (_ args: [String], _ qos: QoS) throws -> WorkerProcess

    public init(worker: String, lm: String, cliOptions: [String], log: URL, env: [String: String],
                spawn: ((_ args: [String], _ qos: QoS) throws -> WorkerProcess)? = nil) {
        self.worker = worker
        self.lm = lm
        self.cliOptions = cliOptions
        self.log = log
        self.env = env
        let taskpolicy = self.taskpolicy
        self.spawn = spawn ?? { args, qos in try spawnWorker(args, qos: qos, env: env, log: log, taskpolicy: taskpolicy) }
    }

    /// The command after taskpolicy's options: `notes` is palaver-lm's, every other one palaver-worker's.
    public func argv(_ cmd: String, _ folder: URL?, extra: [String] = []) -> [String] {
        let tail = (folder.map { [$0.path] } ?? []) + extra
        return [cmd == "notes" ? lm : worker] + cliOptions + [cmd] + tail
    }

    public func launch(_ cmd: String, _ folder: URL?, qos: QoS = .utility, extra: [String] = []) throws -> WorkerProcess {
        try spawn(argv(cmd, folder, extra: extra), qos)
    }

    /// `forwarded_cli_options`: the options to pass on, as absolute paths.
    public static func forwardedOptions(config: String?, dictionary: String?, noNotify: Bool) -> [String] {
        func abs(_ p: String) -> String {
            URL(fileURLWithPath: NSString(string: p).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path
        }
        var options: [String] = []
        if let config { options += ["--config", abs(config)] }
        if let dictionary { options += ["--dictionary", abs(dictionary)] }
        if noNotify { options.append("--no-notify") }
        return options
    }
}

// MARK: - the Python facts

/// What only the Python side knows, asked through `palaver app query … --json` on a queue of its
/// own (a Python start costs a second or two, too long for the main thread's tick). Each answer is
/// kept for `maxAge` seconds; while none is fresh, the getter starts one query (at most one per
/// question at a time) and answers nil: "not known yet", which the daemon treats as "wait".
public final class PythonFacts: @unchecked Sendable {
    /// Blocks its (background) thread until Python answers.
    public typealias Query = @Sendable ([String]) throws -> [String: Any]
    private let query: Query
    private let runner: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let clock: @Sendable () -> Double
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var answers: [String: (at: Double, value: [String: Any]?)] = [:]
    private var asking: Set<String> = []
    private var failing: Set<String> = []
    /// Settings.search_meaning: off, no index is wanted (and nothing asked).
    public var searchMeaning: @Sendable () -> Bool = { true }
    /// [calendar].enabled: off, there is no event (and nothing asked).
    public var calendarEnabled: @Sendable () -> Bool = { true }

    /// `runner` runs a query off the main thread: a thread of its own by default, so a busy
    /// dispatch pool never holds an answer back.
    public init(query: @escaping Query, clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                log: @escaping @Sendable (String) -> Void = { _ in },
                runner: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { work in
                    let t = Thread(block: work)
                    t.name = "palaver-app-query"
                    t.qualityOfService = .utility
                    t.start()
                }) {
        self.query = query
        self.runner = runner
        self.clock = clock
        self.log = log
    }

    /// The questions the domain answers in this process (`Queries`).
    public static let inProcess: Set<String> = ["missing-models", "index-stale", "notes-memory", "event-key"]

    /// `missing-models`, `index-stale`, `notes-memory` and `event-key` from `Queries` in this process
    /// (config.toml read again for each; `calendar`: the events, nil when the calendar is off or not allowed);
    /// anything else is an error.
    public static func query(config: @escaping @Sendable () -> Config,
                             calendar: @escaping @Sendable (Config) -> CalendarProvider?) -> Query {
        { what in
            guard let first = what.first, inProcess.contains(first) else { throw Queries.QueryError(what.first ?? "") }
            let cfg = config()
            let answer = try Queries.answer(first, args: Array(what.dropFirst()), config: cfg, calendar: calendar(cfg))
            return answer.anyValue as? [String: Any] ?? [:]
        }
    }

    /// The calendar `event-key` reads: this Mac's (EventKit) when [calendar].enabled and access is given.
    @Sendable public static func eventKitCalendar(_ config: Config) -> CalendarProvider? {
        guard config.calendarEnabled else { return nil }
        let kit = EventKitCalendar()
        guard kit.hasAccess() else { return nil }
        return { try kit.eventsBetween($0, $1) }
    }

    /// The fresh answer to `what`, or nil while it is being asked. A failed query answers nil in
    /// `value` (the caller's fallback) and is asked again after `maxAge`.
    /// `stale`: once answered, an expired answer keeps being served (a failed refresh keeps it too)
    /// while the refresh runs; only a never-answered question is "not known yet".
    private func ask(_ what: [String], maxAge: Double, stale: Bool = false) -> (value: [String: Any]?, known: Bool) {
        let key = what.joined(separator: "\u{1f}")
        let now = clock()
        lock.lock()
        let old = answers[key]
        if let a = old, now - a.at < maxAge { lock.unlock(); return (a.value, true) }
        let start = asking.insert(key).inserted
        lock.unlock()
        if start {
            let query = self.query
            runner { [self] in
                var value: [String: Any]?
                do {
                    value = try query(what)
                    record(key, recovered: true)
                } catch {
                    if record(key, recovered: false) { log("palaver app query \(what[0]) failed: \(error)") }
                }
                keep(key, value ?? (stale ? old?.value : nil))
            }
        }
        if stale, let old { return (old.value, true) }
        return (nil, false)
    }

    private func keep(_ key: String, _ value: [String: Any]?) {
        lock.withLock {
            answers[key] = (clock(), value)
            asking.remove(key)
        }
    }

    /// Keeps whether `key` fails; true when it just started failing (said once).
    @discardableResult
    private func record(_ key: String, recovered: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if recovered { failing.remove(key); return false }
        return failing.insert(key).inserted
    }

    /// Whether `process` would find the models it needs for `folder` (`missing-models`). A failed
    /// query says yes: `process` then exits 4 again if they are missing.
    public func modelsReady(_ folder: URL) -> Bool? {
        let (value, known) = ask(["missing-models", folder.path], maxAge: 25)
        guard known else { return nil }
        return ((value?["missing"] as? [Any]) ?? []).isEmpty
    }

    /// The free memory in GB the notes of `folder` need (`notes-memory`); unknown models need 20.
    public func notesMemoryGB(_ folder: URL) -> Double? {
        let (value, known) = ask(["notes-memory", folder.path], maxAge: 60, stale: true)
        guard known else { return nil }
        return (value?["gb"] as? NSNumber)?.doubleValue ?? 20
    }

    /// Whether a meeting has no search index yet (`index-stale`), and whether the index's model is
    /// here (its first run downloads it).
    public func indexWanted() -> Bool? {
        guard searchMeaning() else { return false }
        let (value, known) = ask(["index-stale"], maxAge: 30)
        guard known else { return nil }
        return !((value?["stale"] as? [Any]) ?? []).isEmpty
    }

    public func indexModelReady() -> Bool {
        let (value, known) = ask(["index-stale"], maxAge: 30)
        return !known || ((value?["model_ready"] as? Bool) ?? true)
    }

    /// The key of the calendar event on at `when` (`event-key`), never waiting: `.pending` while
    /// Python is asked, then kept 10 minutes. A failed lookup is no event.
    public func eventKey(at when: Date) -> EventLookup {
        guard calendarEnabled() else { return .known(nil) }
        let (value, known) = ask(["event-key", WallTime.iso(when, .current)], maxAge: 600)
        return known ? .known(value?["key"] as? String) : .pending
    }
}

// MARK: - notion-auto-sync

/// `notion-auto-sync`: whether a recording is uploaded after the call (`run`, which writes its notes
/// itself) or processed with its notes written apart. Known at once: the last answer (kept in Application
/// Support), else config.toml's view; the app then works it out (`current`: the token may be in the
/// Keychain) and `set`s it. The daemon reads the answer each time a worker starts.
public final class AutoSyncAnswer: @unchecked Sendable {
    public struct Value: Equatable, Sendable {
        public var autoSync: Bool
        public var notes: Bool
        public init(autoSync: Bool, notes: Bool) { self.autoSync = autoSync; self.notes = notes }
    }

    private let lock = NSLock()
    private var current: Value
    private var gotAnswer = false
    private let cache: URL?

    /// A fixed answer (tests).
    public init(autoSync: Bool, notes: Bool) {
        current = Value(autoSync: autoSync, notes: notes)
        cache = nil
    }

    /// The answer given last time (`cache`), else `fallback` (config.toml's view).
    public init(cache: URL, fallback: Value) {
        self.cache = cache
        if let data = try? Data(contentsOf: cache), let obj = JSONValue.parse(data),
           case .bool(let a)? = obj["auto_sync"], case .bool(let n)? = obj["notes"] {
            current = Value(autoSync: a, notes: n)
        } else {
            current = fallback
        }
    }

    public var value: Value { lock.lock(); defer { lock.unlock() }; return current }
    public var autoSync: Bool { value.autoSync }
    public var notes: Bool { value.notes }
    /// An answer was set during this run.
    public var answered: Bool { lock.lock(); defer { lock.unlock() }; return gotAnswer }

    /// The answer: used from now on and kept for the next start.
    public func set(_ value: Value) {
        lock.lock()
        current = value
        gotAnswer = true
        lock.unlock()
        guard let cache else { return }
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = JSONValue.object([("auto_sync", .bool(value.autoSync)), ("notes", .bool(value.notes))]).encoded(indent: nil)
        try? text.write(to: cache, atomically: true, encoding: .utf8)
    }

    /// The answer as it is now (app_query `notion-auto-sync`): a Notion token — the environment, config.toml,
    /// or the Keychain by its attributes only (never a prompt) — and `[notion].auto_sync` (default true);
    /// `notes` is `[notes].enabled`.
    public static func current(config: Config, configToml: URL, env: [String: String] = ProcessInfo.processInfo.environment,
                               keys: KeyStore) -> Value {
        let a = Tokens.notionAutoSync(config: config, configToml: configToml, env: env, keys: keys)
        return Value(autoSync: a.autoSync, notes: a.notes)
    }
}

// MARK: - build_daemon

public enum DaemonFactory {
    /// The daemon as the app runs it. `notion`: notion-auto-sync, read as each worker starts (Python's
    /// answer may come late). `notify`: (title, message, meeting). `log`: (level, message) into
    /// daemon.log. The capture sources are the real ones unless given.
    public static func build(config: Config, settings: Settings, paths: Paths, launcher: WorkerLauncher,
                             facts: PythonFacts, notion: AutoSyncAnswer,
                             detector: CallDetector, version: String,
                             notify: @escaping (String, String, String?) -> Void,
                             log: @escaping (String, String) -> Void,
                             sources: ((Daemon?) -> CaptureSources)? = nil,
                             beforeRecord: @escaping (() throws -> URL) throws -> URL = { try $0() },
                             askAccessibility: (() -> Void)? = nil,
                             testRecorder: TestRecorder? = nil) throws -> Daemon {
        let levels = RecordingLevels()
        let usage = UsageLog(url: paths.support.appendingPathComponent("usage.jsonl"))
        let stamp: [(String, Any)] = [("version", version), ("pid", Int(getpid())),
                                      ("argv", Array(CommandLine.arguments.dropFirst())), ("app", "native")]
        weak var made: Daemon?
        let captureSources: () -> CaptureSources = {
            if let sources { return sources(made) }
            return CaptureSources.live(excludedPIDs: { made?.excludedPIDs() ?? [getpid()] },
                                       log: { log("INFO", $0) })
        }
        facts.searchMeaning = { settings.searchMeaning }
        facts.calendarEnabled = { config.calendarEnabled }
        // A Slack recording's follower says when the user left the huddle (#25): the detector stops counting
        // Slack's speaker as the huddle, and the daemon stops without the grace.
        let huddle = SlackHuddleState()
        detector.huddleLeft = { huddle.left }
        // A Teams recording's follower says when the call window closed: with Teams' call audio gone, hung up,
        // and the daemon stops without the grace.
        let teamsCall = TeamsCallState()
        // A call's recording does not keep the mic while the user is muted in it (respect_call_mute).
        // With the real capture only: given sources (tests) never read another app's mute.
        // A Slack huddle is followed without it too, for its end (the mic is then kept: `gatesMic` false).
        let mute: (String) -> ((@escaping @Sendable (String) -> Void) -> (MuteTimeline, CallMuteSource))? = { trigger in
            guard sources == nil, let app = CallApp(rawValue: trigger), settings.respectCallMute || app == .slack else { return nil }
            // The call began when its app took the mic, or, going on from before a restart, when it began then.
            let callStart = made?.continuingSince.map { hostNanos() - Int64(Date().timeIntervalSince($0) * 1e9) }
                ?? detector.callSince(app)
            askAccessibility?()  // to read Teams' mic button, Slack's huddle
            return { log in CallMute.make(app: app, callStart: callStart, home: paths.home, huddle: huddle,
                                        teams: teamsCall, log: log) }
        }
        var deps = DaemonDeps(
            detect: { detector.detect(recording: $0) },
            newSession: { trigger in
                let muted = mute(trigger), gates = settings.respectCallMute
                return RecordingSession(outputDir: config.outputDir, trigger: trigger,
                                        capture: { folder, sessionLog in
                                            LiveCapture(folder: folder, log: sessionLog, sources: captureSources(), mute: muted,
                                                        gatesMic: gates)
                                        },
                                        stamp: stamp, usage: usage)
            },
            // Locally, notes are written apart, when no call is recorded; the Notion upload needs
            // them at once, so `run` keeps writing them itself.
            launchProcessing: { folder in
                notion.autoSync
                    ? try launcher.launch("run", folder, qos: .utility)
                    : try launcher.launch("process", folder, qos: .utility, extra: ["--no-notes"])
            },
            statePath: paths.daemonJson,
            trigger: Trigger(startAfter: DaemonTiming.startAfter, grace: Double(config.gracePeriodSeconds),
                             maxSession: Double(config.maxSessionHours) * 3600),
            clock: { ProcessInfo.processInfo.systemUptime })
        deps.ignore = { detector.ignore(named: $0) }
        deps.callLeft = { $0 == .slack ? huddle.left : teamsCall.left }
        deps.ignored = { detector.ignored.map(\.rawValue) }
        deps.launchNotes = { try launcher.launch("notes", $0, qos: .utility) }
        deps.notesWanted = { let v = notion.value; return !v.autoSync && v.notes }
        deps.launchLive = { try launcher.launch("live", $0, qos: .background) }
        deps.launchStream = { try launcher.launch("stream", $0, qos: .utility) }
        deps.launchCoach = { try launcher.launch("coach", $0, qos: .background) }
        deps.launchIndex = { try launcher.launch("index", nil, qos: .background) }
        deps.memoryFreeGB = FreeMemory.availableGB
        deps.notesMemoryGB = { facts.notesMemoryGB($0) }
        // `budgetsNow` asks for the Recordings folder, no one meeting: the Settings' choice, shown in daemon.json and
        // standing in until a meeting's own answer is known; a running meeting's notes are judged by `budgetFor`.
        deps.watchdog = Watchdog(
            MemoryBudgets(config: config.memory),
            budgetsNow: { MemoryBudgets(config: config.memory, notes: facts.notesMemoryGB(config.outputDir)) },
            freeGB: FreeMemory.availableGB,
            budgetFor: memoryBudgetHook(config: config.memory, notesInRun: { let v = notion.value; return v.autoSync && v.notes },
                                        need: { facts.notesMemoryGB(URL(fileURLWithPath: $0, isDirectory: true)) }),
            log: log)
        deps.indexWanted = { facts.indexWanted() }
        deps.indexModelReady = { facts.indexModelReady() }
        deps.modelsReady = { facts.modelsReady($0) }
        deps.realtime = { settings.realtime }
        deps.live = { settings.liveProcessing }
        // A meeting goes first: a running test recording is stopped before the meeting's capture starts.
        deps.beforeRecord = testRecorder.map { test in { start in try test.meetingStarting { try beforeRecord(start) } } } ?? beforeRecord
        deps.silence = { levels.quietFor }
        deps.othersSilence = { levels.othersQuietFor }
        deps.liveRunning = { LiveWorker.running($0) }
        deps.stopLive = { LiveWorker.stop($0) }
        deps.doneMarker = { notion.autoSync ? "notion.json" : "transcript.md" }
        deps.outputDir = config.outputDir
        deps.processes = Processes.palaverProcesses
        deps.eventKeyAt = { facts.eventKey(at: $0) }
        deps.notify = notify
        deps.log = log
        let daemon = try Daemon(deps)
        daemon.levels = levels
        made = daemon
        return daemon
    }
}

// MARK: - app.sock

/// The daemon's side of app.sock's calls (`AppActions`). `refresh` redraws the menu; the window's
/// helpers, the web server's restart and the test recording belong to later tasks and are injected.
public final class DaemonActions: AppActions {
    public let daemon: Daemon
    private let onRefresh: () -> Void
    private let helper: (String, String, [String]) throws -> Int32
    private let restart: () -> Int32?
    private let test: (String?, [String: Any], () -> Bool) throws -> Any?

    public init(daemon: Daemon, refresh: @escaping () -> Void = {},
                launchHelper: @escaping (String, String, [String]) throws -> Int32 = { kind, _, _ in
                    throw CallRefused("no helper \(kind)")
                },
                restartWeb: @escaping () -> Int32? = { nil },
                testRecording: @escaping (String?, [String: Any], () -> Bool) throws -> Any? = { _, _, _ in nil }) {
        self.daemon = daemon
        self.onRefresh = refresh
        self.helper = launchHelper
        self.restart = restartWeb
        self.test = testRecording
    }

    public func answerStopQuestion(choice: String, meeting: String?) -> Bool { daemon.answerStopQuestion(choice, meeting: meeting) }
    public func switchedOff(app: String) { daemon.switchedOff(app) }
    public func transcribeAgain(folder: String) -> Bool { daemon.transcribeAgain(URL(fileURLWithPath: folder, isDirectory: true)) }
    public func status() -> (state: String, folder: String?) { daemon.state }
    public func stopManual() { daemon.stopManual() }
    public func startManual() -> Bool { daemon.startManual() }
    public func refresh() { onRefresh() }
    public func watchHelper(folder: String, process: PidProcess) { daemon.watchHelper(folder: folder, process: process) }
    public func launchHelper(kind: String, key: String, args: [String]) throws -> Int32 { try helper(kind, key, args) }
    public func restartWeb() -> Int32? { restart() }
    public func testRecording(action: String?, mode: [String: Any], busy: () -> Bool) throws -> Any? {
        try test(action, mode, busy)
    }
}
