// Who read what through `palaver mcp` (issue #45; mcp_access.py's log, running servers and setup reads). Each MCP
// client starts its own Python `palaver mcp` process, which appends one JSON line per tool call to
// `mcp-access.jsonl` (never rotated: #59; an old `mcp-access.1.jsonl` is still read) and keeps a heartbeat file
// `mcp/<pid>.json` while it runs (the Swift `palaver mcp`, McpSession, writes the same files). The window polls both
// (`/api/mcp`); adding Palaver to Claude is McpSetup.
//
// The log is written by other processes while it is read: a line cut short or no JSON is skipped. Every change of it
// takes `mcp-access.lock` (`flock`, as `_locked` does). Claude's own config files are only read here, never written.
import Darwin
import Foundation
import PalaverCore

public enum McpLog {
    /// Log entries the window gets.
    public static let SHOWN = 200
    /// A cleared log can be brought back (Undo) this long.
    public static let CLEARED_KEEP_SECONDS = 600.0
    /// A heartbeat older than this: not shown as connected.
    public static let FRESH_SECONDS = 120.0
    /// ... and older than this, its file goes even if the pid lives (reused).
    public static let FORGET_SECONDS = 3600.0
    /// A call never waits longer for the log's lock; its line is dropped then.
    public static let APPEND_WAIT_SECONDS = 0.2
    /// How long a clear or restore waits for the log's lock (`_locked(wait=2.0)`).
    public static let LOCK_WAIT_SECONDS = 2.0
    /// Where Claude Desktop is installed (not under the home).
    public static let DESKTOP_APP = URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true)
    /// The installer before #60 put a venv here; the runtime replaced it.
    static let OLD_VENVS = ["/Library/Application Support/palaver/venv/", "/Library/Application Support/meeting-transcribe/venv/"]

    /// `TimeoutError("the MCP access log is locked")`: the lock stayed taken (a 500 with this text).
    public struct Locked: Error, CustomStringConvertible {
        public var description: String { "the MCP access log is locked" }
    }

    /// What Python raises for a value of the wrong type in the log or a config file (a 500 with its text).
    public struct TypeError: Error, CustomStringConvertible {
        public let description: String
    }

    /// The cleared log is no UTF-8 (`UnicodeDecodeError`: a 500); `clear` writes it as UTF-8, so never in practice.
    public struct Undecodable: Error, CustomStringConvertible {
        public var description: String { "'utf-8' codec can't decode the cleared MCP access log" }
    }

    // MARK: - paths

    static func logPath(_ stores: StorePaths) -> String { stores.mcpAccess.path }
    /// `_old(path)`: the file rotated before #59.
    static func oldPath(_ stores: StorePaths) -> String { stores.support.path + "/mcp-access.1.jsonl" }
    /// `path.with_suffix(".lock")`.
    static func lockPath(_ stores: StorePaths) -> String { stores.support.path + "/mcp-access.lock" }
    /// `_cleared(token)`.
    static func clearedPath(_ stores: StorePaths, _ token: String) -> String {
        stores.support.path + "/mcp-access.cleared-\(token).jsonl"
    }

    // MARK: - the lock

    /// `_locked(wait)`: the log, locked against the `palaver mcp` processes and the window; `Locked` when the lock stays
    /// taken for `wait` s.
    static func locked<T>(_ stores: StorePaths, wait: Double = LOCK_WAIT_SECONDS, _ body: () throws -> T) throws -> T {
        try Undo.makedirs(stores.support.path)
        let fd = open(lockPath(stores), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        let deadline = monotonic() + wait
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            guard errno == EWOULDBLOCK else { throw posixError() }
            if monotonic() >= deadline { throw Locked() }
            usleep(20_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    // MARK: - the log

    /// `append(entry)`: one line for one call (the Python MCP server's; tests write with it). Never throws and never
    /// waits long: with the log locked, the line is dropped. Every write also deletes a cleared log whose undo time is
    /// over.
    public static func append(_ entry: JSONValue, stores: StorePaths = .current()) {
        forgetCleared(stores)
        let line = Array((PythonJSON.dumps(entry, ensureAscii: false) + "\n").utf8)
        _ = try? locked(stores, wait: APPEND_WAIT_SECONDS) {
            let fd = open(logPath(stores), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o666)
            guard fd >= 0 else { return }
            defer { close(fd) }
            try? writeAll(fd, line)
        }
    }

    /// `_lines(path)`: the file's lines (`splitlines`, bad UTF-8 replaced); none when it is not there.
    static func lines(_ path: String) throws -> [String] {
        guard let data = try readFile(path) else { return [] }
        return splitlines(String(decoding: data, as: UTF8.self))
    }

    /// `read(limit, meeting)`: the newest `limit` entries, newest first; with `meeting`, only the calls that sent that
    /// meeting out. Lines that are not JSON (or no object) are skipped.
    public static func read(limit: Int = SHOWN, meeting: String? = nil, stores: StorePaths = .current()) throws -> [JSONValue] {
        forgetCleared(stores)
        var out: [JSONValue] = []
        for line in (try lines(oldPath(stores)) + lines(logPath(stores))).reversed() {
            if out.count >= limit { break }
            if let meeting, !contains(line, meeting) { continue }
            guard let entry = try? PythonJSON.parse(Data(line.utf8)), case .object = entry else { continue }
            if let meeting, !(try sentOut(entry["meetings"], meeting)) { continue }
            out.append(entry)
        }
        return out
    }

    /// `meeting in (entry.get("meetings") or [])`.
    static func sentOut(_ meetings: JSONValue?, _ meeting: String) throws -> Bool {
        guard let meetings, meetings.truthy else { return false }
        switch meetings {
        case .array(let items): return items.contains { if case .string(let s) = $0 { return Py.same(s, meeting) }; return false }
        case .string(let s): return contains(s, meeting)
        case .object(let fields): return fields.contains { Py.same($0.0, meeting) }
        default: throw TypeError(description: "argument of type '\(typeName(meetings))' is not iterable")
        }
    }

    /// `_forget_cleared(keep)`: cleared logs older than `keep` s go.
    static func forgetCleared(_ stores: StorePaths, keep: Double = CLEARED_KEEP_SECONDS) {
        let dir = stores.support.path
        guard let names = try? Undo.listdir(dir) else { return }
        for name in names where Undo.matches(name, "mcp-access.cleared-*.jsonl") {
            guard let st = Undo.statOf(dir + "/" + name) else { return }  // an OSError ends the sweep
            if Date().timeIntervalSince1970 - mtime(st) > keep {
                if unlink(dir + "/" + name) != 0 && errno != ENOENT { return }
            }
        }
    }

    /// `clear()`: empties the log (both files). The old lines are kept aside for `keep` s so the window can undo, then
    /// deleted; the token for `restore`, or nil when there was nothing to clear.
    public static func clear(stores: StorePaths = .current(), keep: Double = CLEARED_KEEP_SECONDS) throws -> String? {
        let aside: String? = try locked(stores) {
            let text = try (lines(oldPath(stores)) + lines(logPath(stores))).map { $0 + "\n" }.joined()
            forgetCleared(stores, keep: -1)  // an earlier clear can't be undone any more
            if text.isEmpty { return nil }
            let token = tokenHex(6)
            try writeText(clearedPath(stores, token), text)
            try unlinkMissingOK(oldPath(stores))
            try unlinkMissingOK(logPath(stores))
            return token
        }
        guard let token = aside else { return nil }
        // `_drop_later`: also when nobody reads the log meanwhile; if the app quits first, the next read or write does.
        let path = clearedPath(stores, token)
        // Its own thread, as Python's daemon Timer: a busy GCD pool must not hold the deletion back.
        let drop = Thread { Thread.sleep(forTimeInterval: keep); _ = unlink(path) }
        drop.name = "mcp-log-drop"
        drop.start()
        return token
    }

    /// `restore(token)`: undoes `clear`; the cleared lines come back before the ones written since. False when the
    /// token is no cleared log (any more).
    public static func restore(_ token: String, stores: StorePaths = .current()) throws -> Bool {
        guard !token.isEmpty, token.unicodeScalars.allSatisfy({ Py.isWordScalar($0) && $0 != "_" }) else { return false }
        forgetCleared(stores)
        let aside = clearedPath(stores, token)
        return try locked(stores) {
            guard Undo.exists(aside) else { return false }
            guard let data = try readFile(aside), let cleared = String(validatingUTF8Data: data) else {
                throw Undecodable()
            }
            let text = try cleared + (lines(oldPath(stores)) + lines(logPath(stores))).map { $0 + "\n" }.joined()
            let tmp = stores.support.path + "/mcp-access.tmp"
            try writeText(tmp, text)
            try unlinkMissingOK(oldPath(stores))
            guard rename(tmp, logPath(stores)) == 0 else { throw posixError() }
            guard unlink(aside) == 0 else { throw posixError() }
            return true
        }
    }

    // MARK: - running servers

    /// `clients()`: the running `palaver mcp` processes, oldest first. Files of processes that are gone (or long silent:
    /// their pid is someone else's now) are removed.
    public static func clients(stores: StorePaths = .current()) -> [JSONValue] {
        let dir = stores.mcpDir.path
        guard let names = try? Undo.listdir(dir) else { return [] }
        var out: [JSONValue] = []
        for name in names where Undo.matches(name, "*.json") {
            let file = dir + "/" + name
            let stem = String(String.UnicodeScalarView(name.unicodeScalars.dropLast(5)))
            guard let number = ModelCatalog.pyInt(Py.strip(stem)), let pid = pid_t(exactly: number),
                  let st = Undo.statOf(file) else { continue }
            let age = Date().timeIntervalSince1970 - mtime(st)
            var gone = false
            if kill(pid, 0) != 0 {
                guard errno == ESRCH || errno == EPERM else { continue }  // another OSError: skipped
                gone = errno == ESRCH
            }
            if gone || age > FORGET_SECONDS {
                _ = unlink(file)
                continue
            }
            if age > FRESH_SECONDS { continue }
            guard let data = try? readFile(file), let text = String(validatingUTF8Data: data),
                  let beat = try? PythonJSON.parse(Data(text.utf8)), case .object(var fields) = beat else { continue }
            if let i = fields.firstIndex(where: { Py.same($0.0, "pid") }) {
                fields[i].1 = .int(number)
            } else {
                fields.append(("pid", .int(number)))
            }
            out.append(.object(fields))
        }
        // `key=lambda c: c.get("started") or ""`
        func started(_ c: JSONValue) -> String { c["started"]?.stringValue ?? "" }
        return Py.stableSorted(out) { Py.less(started($0), started($1)) }
    }

    // MARK: - setup

    private static let cacheLock = NSLock()
    /// `_json_cache`: path -> (mtime and size, parsed JSON).
    nonisolated(unsafe) private static var cache: [String: (key: [Int64], value: JSONValue)] = [:]

    enum ConfigError: Error {
        case notFound
        /// ValueError/OSError: it can't be read.
        case unreadable
    }

    /// `_config(path)`: parsed; cached until the file changes.
    static func config(_ path: String) throws -> JSONValue {
        var st = stat()
        guard stat(path, &st) == 0 else { throw errno == ENOENT ? ConfigError.notFound : ConfigError.unreadable }
        let key = [Int64(st.st_mtimespec.tv_sec), Int64(st.st_mtimespec.tv_nsec), Int64(st.st_size)]
        if let hit = cacheLock.withLock({ cache[path] }), hit.key == key { return hit.value }
        guard let data = try? readFile(path), let text = String(validatingUTF8Data: data),
              let value = try? PythonJSON.parse(Data(text.utf8)) else { throw ConfigError.unreadable }
        cacheLock.withLock { cache[path] = (key, value) }
        return value
    }

    /// `_is_palaver(server)`: an entry that starts `palaver … mcp`.
    static func isPalaver(_ server: JSONValue) throws -> Bool {
        guard case .object = server else { return false }
        var words = [orText(server["command"])]
        if let args = server["args"], args.truthy {
            switch args {
            case .array(let items): words += items.map(Py.str)
            case .string(let s): words += s.unicodeScalars.map { String($0) }
            case .object(let fields): words += fields.map(\.0)
            default: throw TypeError(description: "'\(typeName(args))' object is not iterable")
            }
        }
        return words.contains { contains($0, "palaver") } && words.contains { Py.same($0, "mcp") }
    }

    /// `_palaver_servers(servers)`: the names of the entries that start this server.
    static func palaverServers(_ servers: JSONValue?) throws -> [String] {
        guard case .object(let fields)? = servers else { return [] }
        return try fields.filter { try isPalaver($0.1) }.map(\.0)
    }

    /// `_stale(server)`: an entry whose python was in the old installer's venv and is gone.
    static func stale(_ server: JSONValue) -> Bool {
        let command = orText(server["command"])
        guard OLD_VENVS.contains(where: { contains(command, $0) }) else { return false }
        // `Path(command).exists()`: a path with a NUL byte does not exist.
        return command.unicodeScalars.contains("\0") || !Undo.exists(command)
    }

    /// `config.get(key)` of a parsed config: AttributeError (`ConfigError.unreadable`) when it is no object.
    private static func get(_ config: JSONValue, _ key: String) throws -> JSONValue? {
        guard case .object = config else { throw ConfigError.unreadable }
        return config[key]
    }

    /// `registered()`: whether Claude Code starts this server, read from its config file (`~/.claude.json`, where
    /// `claude mcp add --scope user` writes). `registered` is null when that can't be told.
    public static func registered(stores: StorePaths = .current()) throws -> JSONValue {
        var found: [(name: String, scope: String, server: JSONValue)] = []
        do {
            let config = try config(stores.claudeConfig.path)
            let user = try get(config, "mcpServers").flatMap { $0.truthy ? $0 : nil } ?? .object([])
            found = try palaverServers(user).map { ($0, "user", user[$0]!) }
            let projects = try get(config, "projects").flatMap { $0.truthy ? $0 : nil } ?? .object([])
            guard case .object(let entries) = projects else { throw ConfigError.unreadable }  // `.values()`
            for (_, project) in entries {
                let servers = try get(project.truthy ? project : .object([]), "mcpServers").flatMap { $0.truthy ? $0 : nil }
                    ?? .object([])
                found += try palaverServers(servers).map { ($0, "project", servers[$0]!) }
            }
        } catch ConfigError.notFound {
            return .object([("registered", .bool(false))])
        } catch ConfigError.unreadable {
            return .object([("registered", .null)])
        }
        if let first = found.first(where: { !stale($0.server) }) {
            return .object([("registered", .bool(true)), ("name", .string(first.name)), ("scope", .string(first.scope))])
        }
        if let first = found.first {  // it starts a python that is gone: not working, Settings offers the fix
            return .object([("registered", .bool(false)), ("stale", .bool(true)), ("name", .string(first.name)),
                            ("scope", .string(first.scope))])
        }
        return .object([("registered", .bool(false))])
    }

    /// `desktop_registered()`: whether Claude Desktop is installed (`app`) and starts this server (its
    /// claude_desktop_config.json). `registered` null: the file can't be read.
    public static func desktopRegistered(stores: StorePaths = .current(), app: URL = DESKTOP_APP) throws -> JSONValue {
        let installed: (String, JSONValue) = ("installed", .bool(Undo.exists(app.path)))
        let servers: JSONValue, found: [String]
        do {
            servers = try get(try config(stores.claudeDesktopConfig.path), "mcpServers").flatMap { $0.truthy ? $0 : nil }
                ?? .object([])
            found = try palaverServers(servers)
        } catch ConfigError.notFound {
            return .object([installed, ("registered", .bool(false))])
        } catch ConfigError.unreadable {
            return .object([installed, ("registered", .null)])
        }
        if let name = found.first(where: { !stale(servers[$0]!) }) {
            return .object([installed, ("registered", .bool(true)), ("name", .string(name))])
        }
        if let name = found.first {
            return .object([installed, ("registered", .bool(false)), ("stale", .bool(true)), ("name", .string(name))])
        }
        return .object([installed, ("registered", .bool(false))])
    }

    // MARK: - helpers

    /// `str(x or "")`.
    private static func orText(_ v: JSONValue?) -> String {
        guard let v, v.truthy else { return "" }
        return Py.str(v)
    }

    /// `part in text`, by code points.
    static func contains(_ text: String, _ part: String) -> Bool {
        let t = Array(text.unicodeScalars), p = Array(part.unicodeScalars)
        guard p.count <= t.count else { return false }
        if p.isEmpty { return true }
        return (0...(t.count - p.count)).contains { Array(t[$0..<$0 + p.count]) == p }
    }

    static func typeName(_ v: JSONValue) -> String {
        switch v {
        case .null: return "NoneType"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "float"
        case .string: return "str"
        case .array: return "list"
        case .object: return "dict"
        }
    }

    static func splitlines(_ s: String) -> [String] { ModelJobs.splitlines(s) }

    /// `secrets.token_hex(n)`.
    static func tokenHex(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        arc4random_buf(&bytes, n)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func monotonic() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

    private static func mtime(_ st: stat) -> Double { Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9 }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    /// The file's bytes; nil when it is not there (`FileNotFoundError`), other errors thrown.
    static func readFile(_ path: String) throws -> Data? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        defer { close(fd) }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n < 0 { throw posixError() }
            if n == 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        return out
    }

    /// `path.write_text(text, encoding="utf-8")`.
    static func writeText(_ path: String, _ text: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        try writeAll(fd, Array(text.utf8))
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + done, bytes.count - done) }
            if n < 0 && errno == EINTR { continue }
            if n < 0 { throw posixError() }
            done += n
        }
    }

    private static func unlinkMissingOK(_ path: String) throws {
        if unlink(path) != 0 && errno != ENOENT { throw posixError() }
    }
}
