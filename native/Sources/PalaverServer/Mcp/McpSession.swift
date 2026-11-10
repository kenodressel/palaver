// One `palaver mcp` process as the window sees it (mcp_access.py `Session`, `watch_parent`; issue #45): its client from
// the initialize handshake, a heartbeat file `mcp/<pid>.json` while it runs (touched every BEAT_SECONDS; the window
// shows it as connected while it is fresher than McpLog.FRESH_SECONDS), and one line in `mcp-access.jsonl` per tool
// call (McpLog.append). The same files and keys the Python server wrote, so the window reads both alike. Logging
// never breaks a tool call: every write here swallows its errors.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

public final class McpSession: @unchecked Sendable {
    /// A running server touches its heartbeat file this often.
    public static let BEAT_SECONDS = 30.0
    /// How often it looks whether its client (the parent process) is still there.
    public static let PARENT_CHECK_SECONDS = 5.0

    public let pid: Int32
    public let started: String
    let stores: StorePaths
    private let lock = NSLock()
    private var client: JSONValue = .null
    private var calls = 0
    private var lastCall: String?
    private var lastTool: String?
    /// The heartbeat file once started; nil once stopped.
    private var file: String?

    public init(stores: StorePaths, pid: Int32 = getpid(), now: String = McpSession.now()) {
        self.stores = stores
        self.pid = pid
        self.started = now
    }

    /// `datetime.now().astimezone().isoformat(timespec="seconds")`.
    public static func now() -> String { Py.isoNow(timespec: "seconds") }

    /// The client as recorded (`{"name", "version"}`, or null before the handshake).
    public var clientInfo: JSONValue { lock.withLock { client } }

    var heartbeatPath: String { stores.mcpDir.path + "/\(pid).json" }

    /// `_write`: the heartbeat, atomically through `<pid>.tmp`. Call with `lock` held.
    private func write() {
        guard let file else { return }
        let beat = JSONValue.object([("pid", .int(Int(pid))), ("started", .string(started)), ("client", client),
                                     ("calls", .int(calls)), ("last_call", .str(lastCall)), ("last_tool", .str(lastTool))])
        let tmp = stores.mcpDir.path + "/\(pid).tmp"
        do {
            try FileManager.default.createDirectory(at: stores.mcpDir, withIntermediateDirectories: true)
            try Data(PythonJSON.dumps(beat).utf8).write(to: URL(fileURLWithPath: tmp))
            if rename(tmp, file) != 0 { _ = unlink(tmp) }
        } catch {
            _ = unlink(tmp)
        }
    }

    public func start() {
        lock.withLock {
            file = heartbeatPath
            write()
        }
    }

    /// Removes the heartbeat; no write after it brings it back. (The signals are handled on a dispatch queue, not in a
    /// signal handler, so taking the lock is safe: it is only held for a write.)
    public func stop() {
        lock.withLock { file = nil }
        _ = unlink(heartbeatPath)
    }

    /// Touches the heartbeat (written anew when it went missing).
    public func beat() {
        lock.withLock {
            guard let file else { return }
            if utimes(file, nil) != 0 { write() }
        }
    }

    /// `set_client`: from the initialize request's `clientInfo`: its name and version as text.
    public func setClient(_ info: JSONValue?) {
        guard case .object? = info else { return }
        var fields: [(String, JSONValue)] = []
        for key in ["name", "version"] {
            if let v = info?[key], v.truthy { fields.append((key, .string(Py.str(v)))) }
        }
        guard !fields.isEmpty else { return }
        lock.withLock {
            let new = JSONValue.object(fields)
            if new != client {
                client = new
                write()
            }
        }
    }

    /// `record`: one call into the log and into the heartbeat file. Never throws.
    public func record(tool: String, args: JSONValue, out: JSONValue, meetings: [String], ms: Int, error: String?) {
        var entry: [(String, JSONValue)] = [("time", .string(Self.now())), ("pid", .int(Int(pid))), ("client", clientInfo),
                                            ("tool", .string(tool)), ("args", args), ("out", out), ("ms", .int(ms))]
        if !meetings.isEmpty { entry.append(("meetings", .strings(meetings))) }
        if let error, !error.isEmpty { entry.append(("error", .string(error))) }
        McpLog.append(.object(entry), stores: stores)
        lock.withLock {
            calls += 1
            lastCall = Self.now()
            lastTool = tool
            write()
        }
    }

    /// `watch_parent`: keeps the heartbeat fresh, and calls `gone` when the client is gone. A client that closes the pipe
    /// gives the server EOF on stdin, and it ends; one that dies while a child of it still holds the pipe never does, so
    /// the server would wait for ever, reparented to launchd: when the parent changes, the heartbeat goes and `gone`
    /// runs (the process exits there; a test's `gone` returns and the watch ends).
    @discardableResult
    public func watchParent(interval: Double = PARENT_CHECK_SECONDS, beatEvery: Double = BEAT_SECONDS,
                            parent: @escaping () -> pid_t = { getppid() }, gone: @escaping () -> Void = { _exit(0) }) -> Thread {
        let first = parent()
        let t = Thread { [self] in
            var lastBeat = Self.monotonic()
            while true {
                Thread.sleep(forTimeInterval: interval)
                if parent() != first {
                    stop()
                    gone()
                    return
                }
                if Self.monotonic() - lastBeat >= beatEvery {
                    beat()
                    lastBeat = Self.monotonic()
                }
            }
        }
        t.name = "mcp-parent-watch"
        t.start()
        return t
    }

    static func monotonic() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }
}
