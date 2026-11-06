// Housekeeping and the calendar retry: Python workers the app starts (palaver/app_update.py), never
// more than one of each at a time. menubar.py ran these as threads: Cleanup.tick (audio older than
// Settings say, hourly), drop_retired and mcp_access.migrate and prune_runtimes at start, the 5 minute
// attach retry over 36 hours.
import Foundation
import PalaverCore

/// Starts `<python> -m palaver [options] <cmd> <extra...>` as a worker (`WorkerLauncher.launch`).
public typealias WorkerStarter = @Sendable (_ cmd: String, _ extra: [String]) throws -> WorkerProcess

/// `palaver app housekeeping` at start; `palaver app housekeeping --hourly` on the first tick and then
/// every hour (storage.Cleanup).
public final class Housekeeping: @unchecked Sendable {
    public static let every = 3600.0
    private let start: WorkerStarter
    private let now: @Sendable () -> Double
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var last: Double?
    private var hourly: WorkerProcess?
    private var startup: WorkerProcess?

    public init(start: @escaping WorkerStarter, now: @escaping @Sendable () -> Double = monotonicNow,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.start = start; self.now = now; self.log = log
    }

    /// At launch: retired models, MCP entries, old runtimes.
    public func atStart() {
        lock.lock(); defer { lock.unlock() }
        do { startup = try start("app", ["housekeeping"]) } catch { log("housekeeping did not start: \(error)") }
    }

    /// Each second: the hourly part, when due and the last one has ended.
    public func tick() {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        if let last, t - last < Self.every { return }
        if let hourly, hourly.poll() == nil { return }
        last = t
        do { hourly = try start("app", ["housekeeping", "--hourly"]) } catch { log("hourly housekeeping did not start: \(error)") }
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
/// decided by the Python command (it answers "skipped"), not here.
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
        let extra = ["attach"] + (hours.map { ["--since", String(Int($0))] } ?? [])
        do { running = try start("calendar", extra) } catch { log("attaching calendar events did not start: \(error)") }
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
