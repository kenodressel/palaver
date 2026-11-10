// The app.sock server (phase 2, Task 4): the local interface between the Meetings window's
// server and this process, wire-compatible with palaver/appctl.py (`appctl.call`).
// One JSON line per connection {"call", "args"}, at most 64 KiB, 5 s read timeout; the reply is one
// line: {"ok": …} | {"error", "refused": true} | {"error", "refused": false}.
// Socket mode 0600 (bound in a private folder, chmod, then moved into place); a stale file is unlinked first.
// Handlers are injected; later tasks provide them.
import Darwin
import Foundation
import PalaverCloud
import PalaverCore

/// The recording process answered no, and says why (shown on the page): `refused: true`.
public struct CallRefused: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A call that took the main thread longer than the timeout (appctl's TimeoutError): refused:false.
public struct MainThreadBusy: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? { "the menu bar app is busy" }
}

public typealias AppHandler = @Sendable ([String: Any]) async throws -> Any?

/// Runs work on the main thread, where the daemon ticks, and waits for it. `schedule` hands a block
/// to the main queue (tests inject a fake that never runs it); the wait is at most `timeout`
/// (10 s, appctl.MAIN_THREAD_TIMEOUT), then `MainThreadBusy`.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; defer { done = true }; return !done }
}

public final class MainRunner: @unchecked Sendable {
    public static let defaultTimeout: TimeInterval = 10
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = MainRunner.defaultTimeout,
                schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.timeout = timeout
        self.schedule = schedule
    }

    public func run<T>(_ fn: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let once = Once()
            let finish: @Sendable (Result<T, Error>) -> Void = { result in
                if once.first() { cont.resume(with: result) }
            }
            schedule { finish(Result { try fn() }) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.failure(MainThreadBusy())) }
        }
    }
}

public final class AppSocket: @unchecked Sendable {
    public static let maxRequest = 64 * 1024
    public let path: String
    private let handlers: [String: AppHandler]
    private let readTimeout: TimeInterval
    private let log: @Sendable (String) -> Void
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var stopped = false
    private var bound: (dev: dev_t, ino: ino_t)?
    // Test hooks: a failing listen/accept, and the fd flags of the last accepted connection.
    var listenOverride: (@Sendable (Int32, Int32) -> Int32)?
    var acceptOverride: (@Sendable (Int32) -> Int32)?
    private(set) var lastAcceptedFlags: Int32?

    public init(path: String, handlers: [String: AppHandler], readTimeout: TimeInterval = 5,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.path = path
        self.handlers = handlers
        self.readTimeout = readTimeout
        self.log = log
    }

    /// Binds and serves from background threads. False when the socket could not be bound.
    @discardableResult
    public func start() -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        unlink(path)  // left over from a crash
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        // Not umask 0177 as appctl.py does: umask is process-wide and would hit files other threads
        // create meanwhile. The socket is bound inside a private 0700 folder, chmod 0600, then moved
        // into place: nobody else can ever open it before it is private.
        let stage = path + ".d"
        let staged = stage + "/s"
        unlink(staged)  // a leftover from a crash
        rmdir(stage)
        guard mkdir(stage, 0o700) == 0 else { close(fd); return false }
        defer { rmdir(stage) }
        let sb = Array(staged.utf8CString)
        guard sb.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in sb.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0, chmod(staged, 0o600) == 0 else { unlink(staged); close(fd); return false }
        guard rename(staged, path) == 0 else { unlink(staged); close(fd); return false }
        guard (listenOverride?(fd, 16) ?? listen(fd, 16)) == 0 else {
            unlink(path)  // ours: we just moved it there
            close(fd)
            return false
        }
        var st = stat()
        if stat(path, &st) == 0 { lock.lock(); bound = (st.st_dev, st.st_ino); lock.unlock() }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        listener = fd
        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "app-socket"
        t.start()
        return true
    }

    public func stop() {
        lock.lock()
        let was = stopped
        stopped = true
        lock.unlock()
        guard !was else { return }
        // The accept loop polls every 100 ms and closes the listener when it sees `stopped`.
        // Only the socket this server bound: a new server may have replaced the file already.
        lock.lock(); let mine = bound; lock.unlock()
        var st = stat()
        if let mine, stat(path, &st) == 0, st.st_dev == mine.dev, st.st_ino == mine.ino { unlink(path) }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private var loggedAcceptError = false

    private func acceptLoop(_ fd: Int32) {
        while !isStopped {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let n = poll(&p, 1, 100)
            if n <= 0 { continue }
            let conn = acceptOverride?(fd) ?? accept(fd, nil, nil)
            if conn < 0 {
                if errno == EINTR || errno == EAGAIN || errno == ECONNABORTED { continue }
                if !loggedAcceptError {  // e.g. EMFILE: back off instead of spinning
                    loggedAcceptError = true
                    log("app.sock: accept failed (\(String(cString: strerror(errno)))); backing off")
                }
                usleep(100_000)
                continue
            }
            _ = fcntl(conn, F_SETFD, FD_CLOEXEC)
            lock.lock(); lastAcceptedFlags = fcntl(conn, F_GETFD); lock.unlock()
            let t = Thread { [self] in serve(conn) }
            t.name = "app-socket-conn"
            t.start()
        }
        close(fd)
    }

    // MARK: one connection

    private func serve(_ conn: Int32) {
        defer { close(conn) }
        var one: Int32 = 1
        setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(readTimeout), tv_usec: Int32((readTimeout - Double(Int(readTimeout))) * 1_000_000))
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let line = readLine(conn) else { return }  // a client that sends nothing: no answer
        let answer = respond(to: line)
        guard var out = try? JSONSerialization.data(withJSONObject: answer, options: [.fragmentsAllowed]) else { return }
        out.append(0x0A)
        out.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let w = write(conn, raw.baseAddress! + off, raw.count - off)
                if w <= 0 { return }  // the caller gave up
                off += w
            }
        }
    }

    /// Reads up to one line or `maxRequest` bytes, like Python's readline(MAX_REQUEST).
    /// nil on a read timeout or error.
    private func readLine(_ conn: Int32) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < Self.maxRequest {
            let want = min(buf.count, Self.maxRequest - data.count)
            let n = read(conn, &buf, want)
            if n < 0 { return nil }  // timeout (EAGAIN) or error
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(0x0A) { break }
        }
        if let nl = data.firstIndex(of: 0x0A) { data = data.prefix(upTo: nl + 1) }
        return data
    }

    private func respond(to line: Data) -> [String: Any] {
        let request: [String: Any]
        let trimmed = line.filter { $0 != 0x0A && $0 != 0x20 && $0 != 0x0D && $0 != 0x09 }
        if trimmed.isEmpty {
            request = [:]
        } else {
            guard let obj = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]) else {
                return ["error": "invalid request", "refused": false]
            }
            guard let dict = obj as? [String: Any] else {
                return ["error": "invalid request", "refused": false]
            }
            request = dict
        }
        let name = request["call"]
        let args = request["args"] as? [String: Any] ?? [:]
        guard let key = name as? String, let handler = handlers[key] else {
            return ["error": "unknown call \(pyRepr(name))", "refused": true]
        }
        do {
            let result = try runBlocking { try await handler(args) }
            if let result, !(result is NSNull) {
                guard JSONSerialization.isValidJSONObject(["ok": result]) else {
                    return ["error": "the answer is not JSON", "refused": false]
                }
                return ["ok": result]
            }
            return ["ok": NSNull()]
        } catch let refused as CallRefused {
            return ["error": refused.message, "refused": true]
        } catch {
            log("the app socket's call \(key) failed: \(error)")
            let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return ["error": text.isEmpty ? String(describing: type(of: error)) : text, "refused": false]
        }
    }
}

private final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

/// Waits for an async handler from a plain thread (a connection's own), never the cooperative pool.
private func runBlocking<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let sem = DispatchSemaphore(value: 0)
    // Off the cooperative pool (PalaverCloud's runBlocking does the same): the waiting threads can't starve it.
    Task.detached(executorPreference: BlockingWorkExecutor.shared) {
        do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try box.result!.get()
}

/// Python's repr() of what a request put in "call": enough for the "unknown call 'x'" text.
func pyRepr(_ value: Any?) -> String {
    switch value {
    case nil, is NSNull: return "None"
    case let s as String:
        let quote = s.contains("'") && !s.contains("\"") ? "\"" : "'"
        var out = quote
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if String(ch) == quote { out += "\\" + quote } else { out.unicodeScalars.append(ch) }
            }
        }
        return out + quote
    case let n as NSNumber:
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "True" : "False" }
        return "\(n)"
    default: return "\(value!)"
    }
}
