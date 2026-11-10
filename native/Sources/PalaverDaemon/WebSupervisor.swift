// The Meetings window's server in its own process (#57; webapp/process.py `WebSupervisor`): a
// change to the window or its API needs only that process restarted, at any time, also during a
// call; the recording runs in the app and is never touched.
//
// The app keeps the listening socket and hands it to each server process it starts
// (`palaver webapp-serve --listen-fd N --ready-fd M --app-socket …`): the port never changes, and
// a request made while one server stops and the next starts waits in the socket's queue instead of
// failing. The app restarts a crashed server with backoff, a requested one (`palaver app
// restart-web`, app.sock's `restart_web`) at once, and stops it when it quits. The server exits by
// itself when the app is gone: its stdin, a pipe from the app, closes.
//
// The port is the same at every start of the app (`windowPorts`): the page keeps what it remembers
// (drafts, the palette's recent entries) per address. Each start of the app makes a new key, which
// every server it starts gets ($PALAVER_WEB_KEY) and answers nothing without (server.py).
import Darwin
import Foundation
import PalaverCore

public struct WebServerError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// The window's listening socket on 127.0.0.1, close-on-exec: only the server gets it, by name.
public final class WebListener: @unchecked Sendable {
    public let fd: Int32
    public let port: Int
    private let lock = NSLock()
    private var closed = false

    private init(fd: Int32, port: Int) {
        self.fd = fd
        self.port = port
    }

    /// A listening socket on 127.0.0.1; `port` 0 picks a free one (process.listen).
    public static func listen(port: Int = 0) throws -> WebListener {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WebServerError("socket: \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 128) == 0 else {
            let error = String(cString: strerror(errno))
            Darwin.close(fd)
            throw WebServerError("cannot listen on 127.0.0.1:\(port): \(error)")
        }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return WebListener(fd: fd, port: Int(UInt16(bigEndian: got.sin_port)))
    }

    /// The window's listening socket, kept by the app: on the first free port of `ports`, so the
    /// page's address stays the same from one start to the next; any free one when all are taken
    /// (process.listen_for_window).
    public static func forWindow(ports: [Int] = WebSupervisor.windowPorts,
                                 log: (String) -> Void = { _ in }) throws -> WebListener {
        for port in ports {
            if let listener = try? listen(port: port) { return listener }
            log("port \(port) is taken; trying the next")
        }
        log("all of the window's ports are taken; the page forgets what it remembered")
        return try listen()
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}

/// The wait before each restart of a crashed server (process.backoff_delays).
public struct BackoffDelays: Sendable {
    private let steps: [Double]
    private let stableAfter: Double
    private var crashes = 0

    public init(_ steps: [Double] = WebSupervisor.backoff, stableAfter: Double = WebSupervisor.stableAfter) {
        self.steps = steps
        self.stableAfter = stableAfter
    }

    /// A server that ran `stableAfter` seconds before it crashed starts over at the shortest wait.
    public mutating func next(ranFor: Double) -> Double {
        if ranFor >= stableAfter { crashes = 0 }
        let delay = steps[min(crashes, steps.count - 1)]
        crashes += 1
        return delay
    }

    public mutating func reset() { crashes = 0 }
}

/// A flag with a timed wait (Python's threading.Event).
final class WakeEvent: @unchecked Sendable {
    private let cond = NSCondition()
    private var isSet = false

    func set() { cond.lock(); isSet = true; cond.broadcast(); cond.unlock() }
    func clear() { cond.lock(); isSet = false; cond.unlock() }

    /// True when it was set within `timeout` seconds.
    @discardableResult
    func wait(_ timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock(); defer { cond.unlock() }
        while !isSet {
            if !cond.wait(until: deadline) { return isSet }
        }
        return true
    }
}

/// Starts the server process with `command(listenFD, readyFD)` and keeps it running, each one with
/// `key`. `onReady(restarted)` is called (from the supervisor's thread) each time a server is up:
/// `restarted` for every one after the first, so the window can load the page again.
public final class WebSupervisor: @unchecked Sendable {
    /// Seconds to wait before starting a crashed server again, one step per crash in a row; a
    /// server that ran `stableAfter` before it crashed starts over.
    public static let backoff: [Double] = [1, 2, 5, 15, 30]
    public static let stableAfter = 60.0
    /// A server not serving by then is ended and started again.
    public static let readyTimeout = 20.0
    /// A stopping server lets the changes being made finish this long (a cut or a join moves audio).
    public static let drainSeconds = 60.0
    /// SIGTERM, then SIGKILL after this long.
    public static let stopTimeout = drainSeconds + 5
    /// The window's port: the first of these that is free; any free one after them.
    public static let windowPorts = Array(47815...47824)
    public static let keyEnv = "PALAVER_WEB_KEY"

    public typealias Command = (_ listenFD: Int32, _ readyFD: Int32) -> [String]
    /// Starts argv with `env` exactly, `stdin` as its stdin and `inherit` passed at their numbers.
    public typealias Spawner = (_ argv: [String], _ env: [String: String], _ stdin: Int32, _ inherit: [Int32]) throws -> PalaverCore.Process

    public let listener: WebListener
    public var port: Int { listener.port }
    /// The window signs in with it (WindowPage.withKey); the same for every server of this start.
    public let key: String

    private let command: Command
    private let env: [String: String]
    private let onReady: (Bool) -> Void
    private let log: (String) -> Void
    private let spawner: Spawner
    private let stopTimeout: Double
    private let readyTimeout: Double
    private var delays: BackoffDelays

    private let lock = NSLock()
    private let ready = NSCondition()
    private var spawned = 0  // servers started
    private var up = 0  // the number of the last server that said it serves
    private var child: Child?
    private var stopping = false
    private var restartWanted = false
    private let wake = WakeEvent()
    private var thread: Thread?
    private let finished = WakeEvent()

    // Test seams: the wait before a restart after a crash; just before a server is ended.
    var onBackoff: ((Double) -> Void)?
    var beforeEnd: ((Int32) -> Void)?

    /// A running server: its process and the app's end of its stdin.
    final class Child: @unchecked Sendable {
        let process: PalaverCore.Process
        private let lock = NSLock()
        private var stdin: Int32?

        init(process: PalaverCore.Process, stdin: Int32) {
            self.process = process
            self.stdin = stdin
        }

        func closeStdin() {
            lock.lock(); defer { lock.unlock() }
            if let fd = stdin { Darwin.close(fd) }
            stdin = nil
        }
    }

    /// `env` nil: the app's environment without the launcher's (`childEnv`). `key` nil: a new one.
    public init(command: @escaping Command, listener: WebListener, env: [String: String]? = nil,
                onReady: @escaping (Bool) -> Void = { _ in }, key: String? = nil,
                backoff: [Double] = WebSupervisor.backoff, stableAfter: Double = WebSupervisor.stableAfter,
                readyTimeout: Double = WebSupervisor.readyTimeout, stopTimeout: Double = WebSupervisor.stopTimeout,
                log: @escaping (String) -> Void = { _ in }, spawner: Spawner? = nil) {
        self.listener = listener
        self.key = key ?? WebSupervisor.newKey()
        self.command = command
        var env = env ?? WebSupervisor.childEnv(ProcessInfo.processInfo.environment)
        env[WebSupervisor.keyEnv] = self.key
        self.env = env
        self.onReady = onReady
        self.log = log
        self.spawner = spawner ?? { argv, env, stdin, inherit in try spawnChild(argv, env: env, stdin: stdin, inherit: inherit) }
        self.delays = BackoffDelays(backoff, stableAfter: stableAfter)
        self.readyTimeout = readyTimeout
        self.stopTimeout = stopTimeout
    }

    /// The app's supervisor: `palaver webapp-serve` from `python` with the app's forwarded
    /// options, on `listener` (the window's ports, `WebListener.forWindow`), with the app's
    /// environment minus the launcher's. app.sock's `restart_web` is its `restart()`, the app's quit
    /// its `stopInBackground()`, a menu bar click or a notification `url(meeting)` with `key`.
    /// `server`: palaver-server, serving `staticDir`; nil: Python's `webapp-serve` (the fallback, or it is missing).
    public static func forApp(python: String, cliOptions: [String], appSocket: URL, listener: WebListener,
                              server: String? = nil, staticDir: URL? = nil,
                              env: [String: String]? = nil, log: @escaping (String) -> Void = { _ in },
                              onReady: @escaping (Bool) -> Void = { _ in }) -> WebSupervisor {
        WebSupervisor(command: { listenFD, readyFD in
                          childArgv(python: python, cliOptions: cliOptions, listenFD: listenFD, readyFD: readyFD, appSocket: appSocket,
                                    server: server, staticDir: staticDir)
                      },
                      listener: listener, env: env, onReady: onReady, log: log)
    }

    // MARK: the server's command and environment

    /// `<python> -m palaver [options] webapp-serve --listen-fd N --ready-fd M --app-socket <path>`
    /// (process.child_argv); with `server`, the same handshake with palaver-server:
    /// `<server> [options] --listen-fd N --ready-fd M --app-socket <path> [--static <dir>]`.
    public static func childArgv(python: String, cliOptions: [String], listenFD: Int32, readyFD: Int32, appSocket: URL,
                                 server: String? = nil, staticDir: URL? = nil) -> [String] {
        let handshake = ["--listen-fd", "\(listenFD)", "--ready-fd", "\(readyFD)", "--app-socket", appSocket.path]
        guard let server else { return [python, "-m", "palaver"] + cliOptions + ["webapp-serve"] + handshake }
        return [server] + cliOptions + handshake + (staticDir.map { ["--static", $0.path] } ?? [])
    }

    /// The server's environment: it posts notifications like the app ($PALAVER_NOTIFY), but clicks
    /// on them stay the app's (it opens the window): no PALAVER_LAUNCHER_FD.
    public static func childEnv(_ environ: [String: String]) -> [String: String] {
        environ.filter { $0.key != "PALAVER_LAUNCHER_FD" }
    }

    /// secrets.token_urlsafe(32): 32 random bytes, base64url without padding.
    public static func newKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: running

    /// The running server's pid; nil when none runs.
    public var pid: Int32? {
        let c = lock.withLock { child }
        guard let c, c.process.poll() == nil else { return nil }
        return c.process.pid
    }

    /// `http://127.0.0.1:PORT/`, or a meeting's page `…/#/<id>`.
    public func url(_ meetingId: String? = nil) -> String {
        "http://127.0.0.1:\(port)/" + (meetingId.map { "#/\($0)" } ?? "")
    }

    public func start() {
        let t = Thread { [self] in run() }
        t.name = "web-supervisor"
        t.qualityOfService = .utility
        lock.withLock { thread = t }
        t.start()
    }

    /// A new server now (no backoff), after the running one finished its changes; the new one's
    /// pid once it is up, nil if it is not within `timeout` (default: the ready timeout) or the
    /// app is quitting.
    public func restart(timeout: Double? = nil) -> Int32? {
        lock.lock()
        if stopping { lock.unlock(); return nil }
        restartWanted = true
        let current = child
        let target = spawned + 1  // the server started after this one, not this one coming up
        wake.set()
        lock.unlock()
        if let current { end(current) }
        let deadline = Date().addingTimeInterval(timeout ?? readyTimeout)
        ready.lock()
        while !(up >= target || isStopping) {
            if !ready.wait(until: deadline) { break }
        }
        let isUp = up >= target
        ready.unlock()
        return isUp ? pid : nil
    }

    /// The app quits: stop the server, start no other. Blocks until the server ended (at most the
    /// stop timeout, then it is killed); call it off the main thread.
    public func stop() {
        lock.lock()
        stopping = true
        let current = child
        let t = thread
        wake.set()
        lock.unlock()
        if let current { end(current) }
        ready.lock(); ready.broadcast(); ready.unlock()
        if let t, t !== Thread.current { finished.wait(stopTimeout + 2) }
    }

    /// stop() off the caller's thread: quitting never waits for a server finishing its last change
    /// (process.stop_in_background).
    @discardableResult
    public func stopInBackground() -> Thread {
        let t = Thread { [self] in stop() }
        t.name = "web-stop"
        t.start()
        return t
    }

    /// For tests: what the server sees when the app is gone (the kernel closes the app's end).
    func closeStdinAsIfTheAppWereGone() {
        lock.withLock { child }?.closeStdin()
    }

    private var isStopping: Bool { lock.withLock { stopping } }

    private func end(_ c: Child) {
        beforeEnd?(c.process.pid)
        if c.process.poll() == nil {
            c.process.terminate()
            if c.process.waitUntilExit(timeout: stopTimeout) == nil {
                log("the window's server did not stop; killing it")
                c.process.kill()
                c.process.waitUntilExit()
            }
        }
        c.closeStdin()
    }

    /// The server with the listening socket, a ready pipe's write end and a stdin pipe's read end;
    /// returns it and the ready pipe's read end.
    private func spawn() throws -> (Child, Int32) {
        var readyPipe: [Int32] = [0, 0], stdinPipe: [Int32] = [0, 0]
        guard pipe(&readyPipe) == 0 else { throw WebServerError("pipe: \(String(cString: strerror(errno)))") }
        guard pipe(&stdinPipe) == 0 else {
            readyPipe.forEach { Darwin.close($0) }
            throw WebServerError("pipe: \(String(cString: strerror(errno)))")
        }
        // Never another child's (Foundation's Process passes everything not close-on-exec).
        for fd in readyPipe + stdinPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        defer {
            Darwin.close(readyPipe[1])  // the server's ends: the app keeps none
            Darwin.close(stdinPipe[0])
        }
        do {
            // Its own session (spawnChild): a Ctrl+C meant for the app in a terminal reaches the
            // app, which then stops the server itself.
            let p = try spawner(command(listener.fd, readyPipe[1]), env, stdinPipe[0], [listener.fd, readyPipe[1]])
            return (Child(process: p, stdin: stdinPipe[1]), readyPipe[0])
        } catch {
            Darwin.close(readyPipe[0])
            Darwin.close(stdinPipe[1])
            throw error
        }
    }

    /// Whether the server said it serves (`ready\n`); false when it exited first, the ready
    /// timeout passed or the app is quitting. Closes `fd`.
    private func waitReady(_ fd: Int32) -> Bool {
        defer { Darwin.close(fd) }
        let deadline = Date().addingTimeInterval(readyTimeout)
        var got = [UInt8]()
        while !got.contains(UInt8(ascii: "\n")) {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 || isStopping { return false }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let n = poll(&pfd, 1, Int32(min(left, 0.5) * 1000))
            if n < 0 && errno == EINTR { continue }
            if n > 0 {
                var buf = [UInt8](repeating: 0, count: 64)
                let r = read(fd, &buf, 64)
                if r < 0 && errno == EINTR { continue }
                if r <= 0 { return false }
                got += buf[0..<r]
            }
        }
        return got.starts(with: Array("ready".utf8))
    }

    private func run() {
        defer { finished.set() }
        var restarted = false
        while true {
            lock.lock()
            if stopping { lock.unlock(); return }
            restartWanted = false
            wake.clear()
            var started: (Child, Int32)?
            do {
                started = try spawn()
            } catch {
                log("could not start the window's server: \(error)")
            }
            child = started?.0
            spawned += 1
            let number = spawned
            lock.unlock()
            let since = Date()
            if case let (c, readFD)? = started {
                if waitReady(readFD) {
                    if !isStopping {
                        ready.lock()
                        up = number
                        ready.broadcast()
                        ready.unlock()
                        onReady(restarted)
                    }
                } else if c.process.poll() == nil {  // it never said it serves: hung while starting
                    log("the window's server did not start within \(Int(readyTimeout)) s; ending it")
                    c.process.kill()
                }
                c.process.waitUntilExit()
                c.closeStdin()
            }
            lock.lock()
            if stopping { lock.unlock(); return }
            let wanted = restartWanted
            lock.unlock()
            restarted = true
            if wanted {
                delays.reset()
                continue
            }
            let delay = delays.next(ranFor: Date().timeIntervalSince(since))
            let code = started.flatMap { $0.0.process.poll() }.map { "\($0)" } ?? "None"
            log("the window's server exited (\(code)); starting it again in \(String(format: "%.1f", delay)) s")
            onBackoff?(delay)
            wake.wait(delay)
        }
    }
}
