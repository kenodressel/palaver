// The window server's view of the recording process (webapp/remote.py, #57): the server runs in its
// own process, so what the menu bar app's daemon knows comes from daemon.json (written on every
// tick) and what it does goes through app.sock (AppCtlClient). When the app does not answer — not
// running, quit, or hung — the page still shows, without the live bits, and an action says why it
// did not happen. Also api.py's update and uninstall calls (#60), which go to the same socket.
import Darwin
import EventKit
import Foundation
import PalaverCore
import PalaverDomain

public final class Remote: RecordingRemote, @unchecked Sendable {
    /// daemon.json is written every second while the app runs; older than this, the app is hung or gone.
    public static let STALE_SECONDS = 30.0
    /// Stopping a recording finishes its files on the app's main thread, which waits MAIN_THREAD_TIMEOUT for it:
    /// wait longer here, so the app's own answer (done, or busy) arrives.
    public static let ANSWER_TIMEOUT = AppCtlClient.MAIN_THREAD_TIMEOUT + 2.0
    /// api.uninstall_palaver's timeout (`appctl.MAIN_THREAD_TIMEOUT + 2.0`).
    public static let UNINSTALL_TIMEOUT = AppCtlClient.MAIN_THREAD_TIMEOUT + 2.0
    public static let NO_ANSWER = "Palaver's menu bar app did not answer; try again in a moment."
    /// api.APP_GONE: what an update or uninstall says when the app does not answer.
    public static let APP_GONE = "Palaver's menu bar app does not answer; open Palaver and try again."

    public let statePath: URL
    public let socketPath: URL
    private let now: () -> Date
    private let alive: (JSONValue?) -> Bool
    private let localCalendar: () -> JSONValue
    private let log: (String) -> Void

    /// `statePath`: daemon.json; `socketPath`: app.sock. `alive(pid)`: whether daemon.json's `pid` runs;
    /// `localCalendar`: the calendar permission as this process sees it (onboarding.calendar_permission), for
    /// when the app does not answer; `log`: the INFO lines remote.py logs.
    public init(statePath: URL, socketPath: URL, now: @escaping () -> Date = Date.init,
                alive: @escaping (JSONValue?) -> Bool = Remote.pidAlive,
                localCalendar: @escaping () -> JSONValue = Remote.calendarPermission,
                log: @escaping (String) -> Void = { _ in }) {
        #if DEBUG
        TestIsolation.checkOutsideHome(statePath, "daemon.json")
        TestIsolation.checkOutsideHome(socketPath, "the app socket")
        #endif
        self.statePath = statePath
        self.socketPath = socketPath
        self.now = now
        self.alive = alive
        self.localCalendar = localCalendar
        self.log = log
    }

    /// The app of `stores`' home: its daemon.json and app.sock in Application Support.
    public convenience init(stores: StorePaths, log: @escaping (String) -> Void = { _ in }) {
        self.init(statePath: stores.daemonJson, socketPath: stores.appSock, log: log)
    }

    // MARK: - what daemon.json says

    enum Read {
        /// The recording process runs and writes it.
        case live(JSONValue)
        /// It does not run (or never ran).
        case gone
        /// It runs but has not written for a while.
        case unknown
    }

    func read() -> Read {
        guard let data = try? Data(contentsOf: statePath), let status = try? PythonJSON.parse(data),
              case .object = status else { return .gone }
        let state = status["state"]
        if state == nil || state == .null || state == .string("stopped") { return .gone }
        if !alive(status["pid"]) { return .gone }
        // `now - datetime.fromisoformat(updated)`: a time without an offset can't be subtracted (TypeError).
        guard case .string(let text)? = status["updated"], let updated = try? PyDateTime.parse(text),
              updated.offset != nil else { return .unknown }
        let age = PyDateTime(now(), offset: 0).seconds(since: updated)
        return age > Self.STALE_SECONDS ? .unknown : .live(status)
    }

    private func status() -> JSONValue? {
        if case .live(let s) = read() { return s }
        return nil
    }

    public func question() -> JSONValue? { status().flatMap { Self.value($0["stop_question"]) } }

    public func recording() -> JSONValue? { Self.recordingView(status()) }

    public func coach() -> JSONValue? { Self.coachView(status()) }

    public func memory() -> JSONValue? { status().flatMap { Self.value($0["memory"]) } }

    public func indexing() -> JSONValue {
        let s = status()
        return .object([("indexing", .bool(s?["indexing"]?.truthy ?? false)),
                        ("downloading", .bool(s?["index_downloading"]?.truthy ?? false))])
    }

    /// Not known (the app does not answer): as if busy.
    public func busy() -> Bool {
        switch read() {
        case .unknown: return true
        case .gone: return false
        case .live(let s): return s["state"] == .string("recording") || (s["transcribing"]?.truthy ?? false)
        }
    }

    /// `recording_view`: why the running recording records (#47), what is wrong with its audio (#50), the call
    /// app the mic is muted in now ("teams": not kept), and the one whose mute can't be followed (the mic is kept).
    static func recordingView(_ status: JSONValue?) -> JSONValue? {
        guard let status, let folder = status["folder"], folder.truthy, let why = status["why_text"], why.truthy,
              let meeting = pathName(folder) else { return nil }
        func app(_ v: JSONValue?) -> JSONValue { v?.stringValue.map(JSONValue.string) ?? .null }
        return .object([("meeting", .string(meeting)), ("text", why), ("warnings", orEmpty(status["warnings"])),
                        ("hints", orEmpty(status["hints"])), ("muted", app(status["muted"])),
                        ("mute_unfollowed", app(status["why"]?["mute_unfollowed"]))])
    }

    /// `coach_view`: who talks in the running recording and the coach's nudge (#41), or nil.
    static func coachView(_ status: JSONValue?) -> JSONValue? {
        guard let status, let folder = status["folder"], folder.truthy, let talk = status["talk"], talk.truthy,
              let meeting = pathName(folder) else { return nil }
        return .object([("meeting", .string(meeting)), ("talk", talk), ("text", status["talk_text"] ?? .null),
                        ("nudge", status["nudge"] ?? .null), ("quiet", orEmpty(status["quiet"]))])
    }

    /// `Path(folder).name`; nil when the folder is no text.
    static func pathName(_ folder: JSONValue) -> String? {
        guard case .string(let s) = folder else { return nil }
        return s.split(separator: "/", omittingEmptySubsequences: true).last { $0 != "." }.map(String.init) ?? ""
    }

    /// `value or []`.
    private static func orEmpty(_ v: JSONValue?) -> JSONValue { v.flatMap { $0.truthy ? $0 : nil } ?? .array([]) }

    /// A missing key and JSON null are both Python's None.
    private static func value(_ v: JSONValue?) -> JSONValue? { v == .null ? nil : v }

    /// `_pid_alive`: `os.kill(int(pid), 0)` answers (a process of another user counts). `int()` takes an int, a
    /// bool, a float (cut toward zero) or a text of digits; anything else, or a pid no process can have, is gone.
    public static func pidAlive(_ pid: JSONValue?) -> Bool {
        let number: Int?
        switch pid {
        case .int(let i)?: number = i
        case .bool(let b)?: number = b ? 1 : 0
        case .double(let d)?: number = d.isFinite ? Int(exactly: d.rounded(.towardZero)) : nil
        case .string(let s)?: number = ModelCatalog.pyInt(Py.strip(s))
        default: number = nil
        }
        guard let number, let p = pid_t(exactly: number) else { return false }
        if kill(p, 0) == 0 { return true }
        return errno == EPERM
    }

    /// onboarding.calendar_permission: EventKit's authorization as this process has it.
    public static func calendarPermission() -> JSONValue {
        func state(_ s: String, _ detail: String) -> JSONValue { .object([("state", .string(s)), ("detail", .string(detail))]) }
        switch EKEventStore.authorizationStatus(for: .event).rawValue {
        case 0: return state("not_asked", "not connected")
        case 3: return state("granted", "connected (read only)")
        case 4: return state("denied", "write-only access: Palaver can't read events")
        default: return state("denied", "not allowed")
        }
    }

    // MARK: - what the recording process does

    private func call(_ name: String, _ args: JSONValue, timeout: Double = AppCtlClient.TIMEOUT) throws -> JSONValue {
        try AppCtlClient.call(name, args, path: socketPath, timeout: timeout)
    }

    /// The app's answer; its refusal as `Refused` with its text, no answer as `Refused(gone)`.
    private func refusedOr<T>(_ gone: String = NO_ANSWER, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let e as AppCtlClient.CallRefused {
            throw Refused(e.message)
        } catch is AppCtlClient.CallFailed {
            throw Refused(gone)
        }
    }

    public func answer(choice: String, meeting: String) throws -> Bool {
        try refusedOr {
            try call("answer", .object([("choice", .string(choice)), ("meeting", .string(meeting))]),
                     timeout: Self.ANSWER_TIMEOUT).truthy
        }
    }

    /// Without the app the helper runs unwatched.
    public func watch(folder: URL, pid: Int32) {
        do {
            _ = try call("watch", .object([("folder", .string(folder.path)), ("pid", .int(Int(pid)))]))
        } catch is AppCtlClient.CallFailed, is AppCtlClient.CallRefused {
            log("the helper \(pid) runs without the memory watchdog: the app did not answer")
        } catch {}
    }

    /// The pid the app answers (`int(answer["pid"])`); an answer without one is `CallFailed`.
    public func startHelper(kind: String, key: String, args: [String]) throws -> Int32 {
        let answer = try call("start_helper", .object([("kind", .string(kind)), ("key", .string(key)), ("args", .strings(args))]),
                              timeout: Self.ANSWER_TIMEOUT)
        let pid: Int?
        switch answer["pid"] {
        case .int(let i)?: pid = i
        case .double(let d)? where d.isFinite: pid = Int(exactly: d.rounded(.towardZero))
        case .string(let s)?: pid = ModelCatalog.pyInt(Py.strip(s))
        default: pid = nil
        }
        guard let pid, let p = Int32(exactly: pid) else { throw AppCtlClient.CallFailed("start_helper: no pid in the answer") }
        return p
    }

    public func transcribe(folder: URL) throws -> Bool {
        try refusedOr { try call("transcribe", .object([("folder", .string(folder.path))]), timeout: Self.ANSWER_TIMEOUT).truthy }
    }

    public func record(action: String, meeting: String?) throws -> JSONValue {
        try refusedOr {
            try call("record", .object([("action", .string(action)), ("meeting", .str(meeting))]), timeout: Self.ANSWER_TIMEOUT)
        }
    }

    /// Without the app, the daemon sees the switch on its next start.
    public func switchedOff(app: String) {
        do {
            _ = try call("switched_off", .object([("app", .string(app))]), timeout: Self.ANSWER_TIMEOUT)
        } catch is AppCtlClient.CallFailed, is AppCtlClient.CallRefused {
            log("the app did not answer the record switch \(app)")
        } catch {}
    }

    /// RemoteCalendar.status: the page still shows what this process sees when the app does not answer.
    public func calendarStatus() -> JSONValue {
        (try? call("calendar", .object([]))) ?? localCalendar()
    }

    public func calendarConnect() throws -> JSONValue {
        try refusedOr { try call("calendar", .object([("action", .string("connect"))]), timeout: Self.ANSWER_TIMEOUT) }
    }

    public func test(_ args: JSONValue, timeout: Double) throws -> JSONValue {
        try call("test", args, timeout: timeout)
    }

    public func updateCheck() throws -> JSONValue {
        try refusedOr(Self.APP_GONE) { try call("update_check", .object([])) }
    }

    public func updateInstall() throws -> JSONValue {
        try refusedOr(Self.APP_GONE) { try call("update_install", .object([])) }
    }

    public func uninstall(_ args: JSONValue) throws -> JSONValue {
        try refusedOr(Self.APP_GONE) { try call("uninstall", args, timeout: Self.UNINSTALL_TIMEOUT) }
    }
}

/// The setup assistant's test recording (#55), recorded by the recording process (webapp/remote.py `RemoteTest`):
/// the server needs no mic or system audio permission, and a meeting starting stops the test there at once.
public struct RemoteTest {
    public static let MAX_SECONDS = 20.0
    public let remote: RecordingRemote

    public init(_ remote: RecordingRemote) { self.remote = remote }

    private var idle: JSONValue { .object([("state", .string("idle")), ("max_seconds", .double(Self.MAX_SECONDS))]) }

    /// Throws `Refused` (Python's ValueError, which setup_test turns into Refused) while a meeting is recorded, when the
    /// app refuses, or when it does not answer.
    public func start(busy: () -> Bool, mode: JSONValue? = nil) throws -> JSONValue {
        if busy() { throw Refused("a meeting is being recorded; try the test after it") }
        let m = mode.flatMap { $0.truthy ? $0 : nil } ?? .object([])
        do {
            return try remote.test(.object([("action", .string("start")), ("mode", m)]), timeout: Remote.ANSWER_TIMEOUT)
        } catch let e as AppCtlClient.CallRefused {
            throw Refused(e.message)
        } catch is AppCtlClient.CallFailed {
            throw Refused(Remote.NO_ANSWER)
        }
    }

    public func stop() -> JSONValue {
        (try? remote.test(.object([("action", .string("stop"))]), timeout: Remote.ANSWER_TIMEOUT)) ?? idle
    }

    public func status() -> JSONValue {
        (try? remote.test(.object([]), timeout: AppCtlClient.TIMEOUT)) ?? idle
    }
}
