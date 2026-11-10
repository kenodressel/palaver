// Housekeeping and the calendar retry. menubar.py ran these as threads: Cleanup.tick (audio older than
// Settings say, hourly), drop_retired and mcp_access.migrate and prune_runtimes at start, the 5 minute
// attach retry over 36 hours. Housekeeping runs in this process (app_update.py `housekeeping`'s work, in
// Swift); the calendar's attach is palaver-worker's `calendar-attach`. Never more than one of each at a time.
import Foundation
import PalaverCore
import PalaverDomain

/// Starts `<python> -m palaver [options] <cmd> <extra...>` (or palaver-worker's command) as a worker
/// (`WorkerLauncher.launch`).
public typealias WorkerStarter = @Sendable (_ cmd: String, _ extra: [String]) throws -> WorkerProcess

/// At start: the retired models go (and what `atStart` adds); on the first tick and then every hour: the audio
/// older than Settings say (storage.Cleanup). Each part on a thread of its own, never two of a part at once.
public final class Housekeeping: @unchecked Sendable {
    public static let every = 3600.0
    /// One part of the work; it logs what it did itself.
    public typealias Work = @Sendable () -> Void
    /// Runs `work` in the background and calls `done` after it (a thread by default; tests run it at once).
    public typealias Runner = @Sendable (_ name: String, _ work: @escaping Work, _ done: @escaping @Sendable () -> Void) -> Void

    private let startup: Work
    private let hourly: Work
    private let run: Runner
    private let now: @Sendable () -> Double
    private let lock = NSLock()
    private var last: Double?
    private var hourlyRunning = false
    private var started = false

    public init(atStart startup: @escaping Work, hourly: @escaping Work, run: @escaping Runner = Housekeeping.thread,
                now: @escaping @Sendable () -> Double = monotonicNow) {
        self.startup = startup; self.hourly = hourly; self.run = run; self.now = now
    }

    /// app_update.housekeeping's work: at start the retired models (`Storage.dropRetired`, unless config.toml still
    /// names one), then each of `extras` (the MCP entries, old runtimes: their batches add them); hourly the audio
    /// older than Settings' days (`Storage.dropOldAudio`, nothing when the setting is off).
    public static func inProcess(config: @escaping @Sendable () -> Config, stores: @escaping @Sendable () -> StorePaths = { .current() },
                                 extras: [(String, @Sendable () throws -> Void)] = [],
                                 log: @escaping @Sendable (String) -> Void = { _ in }, run: @escaping Runner = Housekeeping.thread,
                                 now: @escaping @Sendable () -> Double = monotonicNow) -> Housekeeping {
        Housekeeping(atStart: {
            let freed = Storage.dropRetired(config: config(), stores: stores())
            if freed > 0 {
                log("deleted the models no longer offered: \(String(format: "%.1f", Double(freed) / 1e9)) GB free again")
            }
            for (what, work) in extras {
                do { try work() } catch { log("\(what) failed: \(error)") }
            }
        }, hourly: {
            let days = Storage.audioDays(stores: stores())
            guard days > 0 else { return }
            do {
                let (meetings, bytes) = try Storage.dropOldAudio(config().outputDir, days: days)
                if meetings > 0 {
                    log("deleted the audio of \(meetings) meeting(s) older than \(days) days: "
                        + "\(String(format: "%.1f", Double(bytes) / 1e6)) MB free again")
                }
            } catch {
                log("deleting the audio older than \(days) days failed: \(error)")
            }
        }, run: run, now: now)
    }

    /// The extra that moves Claude's MCP entries (phase 4 batch 6): every Claude Code and Claude Desktop entry that
    /// starts Palaver's Python (or an app's `bin/palaver` that is gone) now starts `bundle`'s `bin/palaver mcp`
    /// (McpSetup.migrateAtStart); from a checkout, a translocated or not installed bundle nothing.
    public static func movingMcpEntries(bundle: URL?, stores: @escaping @Sendable () -> StorePaths = { .current() },
                                        log: @escaping @Sendable (String) -> Void) -> (String, @Sendable () throws -> Void) {
        ("moving Claude's MCP entries", { McpSetup.migrateAtStart(bundle: bundle, stores: stores(), log: log) })
    }

    /// The extra that deletes the old Python runtime folder (phase 4 batch 9, RuntimeCleanup): after the MCP entries'
    /// move, once this version's started-ok is written and the swap's previous-app is gone (it waits up to `wait`
    /// seconds: the first tick writes started-ok right after the start), and only when nothing still needs that runtime.
    public static func removingOldRuntime(_ facts: RuntimeCleanup.Facts, wait: Double = 300,
                                          sleep: @escaping @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
                                          log: @escaping @Sendable (String) -> Void) -> (String, @Sendable () throws -> Void) {
        ("deleting the old Python runtime", {
            guard FileManager.default.fileExists(atPath: facts.root.path), let version = facts.bundleVersion else { return }
            let ok = facts.support.appendingPathComponent("started-ok")
            let previous = facts.support.appendingPathComponent("previous-app")
            // started-ok, then the swap's own end: it deletes previous-app within 0.2 s of seeing started-ok.
            var waited = 0.0
            while waited < wait,
                  (try? String(contentsOf: ok, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) != version
                    || FileManager.default.fileExists(atPath: previous.path) {
                sleep(1)
                waited += 1
            }
            RuntimeCleanup.run(facts, log: log)
        })
    }

    /// A thread of its own, named `palaver.<name>`.
    public static let thread: Runner = { name, work, done in
        let t = Thread { work(); done() }
        t.name = "palaver.\(name)"
        t.qualityOfService = .background
        t.start()
    }

    /// At launch, once.
    public func atStart() {
        let first: Bool = lock.withLock {
            defer { started = true }
            return !started
        }
        if first { run("housekeeping", startup, {}) }
    }

    /// Each second: the hourly part, when due and the last one has ended.
    public func tick() {
        let due: Bool = lock.withLock {
            let t = now()
            if let last, t - last < Self.every { return false }
            if hourlyRunning { return false }
            last = t
            hourlyRunning = true
            return true
        }
        guard due else { return }
        run("audio-cleanup", hourly, { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.hourlyRunning = false }
        })
    }
}

public func monotonicNow() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

// MARK: - the calendar

/// EKAuthorizationStatus as Palaver tells it (onboarding.calendar_permission).
public enum CalendarAuth: Equatable, Sendable {
    case notDetermined, fullAccess, writeOnly, denied, unknown
}

/// What EventKit offers, as far as Palaver needs it. The real adapter is in the app target (the permission
/// must belong to the app); tests use a fake and never ask.
public protocol CalendarAccess: Sendable {
    func authorization() -> CalendarAuth
    /// Asks once (macOS shows its dialog once); the answer comes in `authorization()` later.
    func requestAccess()
}

/// The setup assistant's button (onboarding.Calendar): asks once, else opens System Settings at Calendars.
public final class CalendarOnboarding: @unchecked Sendable {
    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    private let access: CalendarAccess
    private let open: @Sendable (String) -> Void

    public init(access: CalendarAccess, open: @escaping @Sendable (String) -> Void) {
        self.access = access; self.open = open
    }

    public func status() -> [String: Any] {
        switch access.authorization() {
        case .notDetermined: return ["state": "not_asked", "detail": "not connected"]
        case .fullAccess: return ["state": "granted", "detail": "connected (read only)"]
        case .writeOnly: return ["state": "denied", "detail": "write-only access: Palaver can't read events"]
        case .denied: return ["state": "denied", "detail": "not allowed"]
        case .unknown: return ["state": "unknown", "detail": "could not check"]
        }
    }

    public func connect() -> [String: Any] {
        var now = status()
        if now["state"] as? String == "not_asked" {
            access.requestAccess()
            now["asked"] = true
        } else if now["state"] as? String == "denied" {
            open(Self.settingsURL)
            now["opened_settings"] = true
        }
        return now
    }
}

/// menubar.py's calendar upkeep: until access is given (in the window or the setup assistant) look each
/// refresh; on connect (with [calendar].enabled) every earlier recording gets its event; then every 5
/// minutes the last 36 hours again (the Calendar app may sync an event after the recording was
/// processed), skipped while transcribing (processing looks the event up itself). [calendar].enabled is
/// decided by the command (it answers "skipped"), not here.
public final class CalendarAttach: @unchecked Sendable {
    public static let retryEvery = 300.0
    public static let window = 36.0  // hours

    private let access: CalendarAccess
    private let transcribing: @Sendable () -> Bool
    private let start: WorkerStarter
    private let now: @Sendable () -> Double
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var connected = false
    private var retried: Double
    private var running: WorkerProcess?

    public init(access: CalendarAccess, transcribing: @escaping @Sendable () -> Bool,
                start: @escaping WorkerStarter, now: @escaping @Sendable () -> Double = monotonicNow,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.access = access; self.transcribing = transcribing
        self.start = start; self.now = now; self.log = log
        self.retried = now()  // connecting looks everything up first
    }

    public var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connected }

    /// Each refresh while not connected: picks up consent given in Settings or the setup assistant.
    public func check() {
        lock.lock(); defer { lock.unlock() }
        let granted = access.authorization() == .fullAccess
        if granted && !connected { attach(since: nil) }
        connected = granted
    }

    /// Each second: the 5 minute retry over the last 36 hours.
    public func retryTick() {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        guard connected, t - retried >= Self.retryEvery else { return }
        retried = t
        if transcribing() { return }
        attach(since: Self.window)
    }

    private func attach(since hours: Double?) {
        if let running, running.poll() == nil { return }
        // `palaver-worker calendar-attach [--since H]` (Python's `palaver calendar attach` in the fallback).
        let extra = hours.map { ["--since", String(Int($0))] } ?? []
        do { running = try start("calendar-attach", extra) } catch { log("attaching calendar events did not start: \(error)") }
    }
}

// MARK: - the app.sock actions

public extension JSONValue {
    /// As JSONSerialization takes it (for app.sock's replies).
    var anyValue: Any {
        (try? JSONSerialization.jsonObject(with: Data(description.utf8), options: [.fragmentsAllowed])) ?? NSNull()
    }
}

public enum ExtraCalls {
    /// The `extra` of `AppCalls.make`: calendar (status, or connect: asks once or opens Settings),
    /// update_check, update_install and uninstall (on the main thread, then the app quits at its next tick).
    public static func make(calendar: CalendarOnboarding, updates: Updates, main: MainRunner) -> [String: AppHandler] {
        [
            "calendar": { args in args["action"] as? String == "connect" ? calendar.connect() : calendar.status() },
            "update_check": { _ in updates.check().anyValue },
            "update_install": { _ in updates.install().anyValue },
            "uninstall": { args in
                let models = args["models"] as? Bool == true, recordings = args["recordings"] as? Bool == true
                return try await main.run { try updates.uninstall(models: models, recordings: recordings) }
            },
        ]
    }
}
