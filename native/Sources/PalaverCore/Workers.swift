import Foundation

/// The QoS a worker runs at, as `taskpolicy -c` names it.
public enum QoS: String, Sendable { case background, utility }

public struct WorkerError: Error, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
}

/// Starts a worker: `/usr/sbin/taskpolicy -c <qos> <args...>`, in a session of its own (it outlives
/// the app's process group and gets no terminal signals), with the environment merged over the
/// app's and stdout and stderr appended to `log`. `args` is the whole command after taskpolicy's
/// options: `[python, "-m", "palaver", ..., cmd]`. `taskpolicy` is `taskpolicy` here so tests can
/// substitute it.
@discardableResult
public func spawnWorker(_ args: [String], qos: QoS, env: [String: String] = [:], log: URL,
                        taskpolicy: String = "/usr/sbin/taskpolicy",
                        onExit: (@Sendable (Int32) -> Void)? = nil) throws -> Process {
    try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(log.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw WorkerError(description: "cannot open \(log.lastPathComponent): \(String(cString: strerror(errno)))") }
    defer { close(fd) }
    return try spawn([taskpolicy, "-c", qos.rawValue] + args, env: env, outputFD: fd, onExit: onExit)
}

/// Runs argv as a child in a new session (POSIX_SPAWN_SETSID), stdin from /dev/null, stdout+stderr
/// on `outputFD`, the app's environment with `env` merged over it. Returns a `Process`-like handle.
func spawn(_ argv: [String], env: [String: String], outputFD: Int32, onExit: (@Sendable (Int32) -> Void)? = nil) throws -> Process {
    var merged = ProcessInfo.processInfo.environment
    for (k, v) in env { merged[k] = v }
    return try spawnChild(argv, env: merged, output: outputFD, onExit: onExit)
}

/// Starts argv in a session of its own with exactly the environment `env` (not merged with the
/// app's). stdin is `stdin` (a pipe's read end, say), else /dev/null; stdout and stderr go to
/// `output`, else they are the app's own (fds 1 and 2). Of everything else the app has open only
/// the descriptors in `inherit` pass, at the same numbers (the web server's listening socket and
/// ready pipe): POSIX_SPAWN_CLOEXEC_DEFAULT closes the rest, close-on-exec or not.
/// Signal dispositions and the mask start at their defaults.
public func spawnChild(_ argv: [String], env: [String: String], stdin: Int32? = nil, inherit: [Int32] = [],
                       output: Int32? = nil, onExit: (@Sendable (Int32) -> Void)? = nil) throws -> Process {
    // Foundation's Process has no setsid: spawn with posix_spawn and wrap the pid.
    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if let stdin {
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
    } else {
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    }
    if let output {
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, output, 2)
    } else {
        posix_spawn_file_actions_addinherit_np(&actions, 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
    }
    for fd in inherit { posix_spawn_file_actions_addinherit_np(&actions, fd) }
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    // A session of its own; only the fds named above pass; default signal state: the app may
    // ignore SIGPIPE or block signals, and a child must not inherit that.
    let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
    posix_spawnattr_setflags(&attr, Int16(flags))
    var empty = sigset_t(), all = sigset_t()
    sigemptyset(&empty)
    sigemptyset(&all)
    for sig in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2, SIGCHLD, SIGALRM] { sigaddset(&all, sig) }
    posix_spawnattr_setsigmask(&attr, &empty)
    posix_spawnattr_setsigdefault(&attr, &all)

    let cArgs = argv.map { strdup($0) } + [nil]
    let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { cArgs.forEach { free($0) }; cEnv.forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, argv[0], &actions, &attr, cArgs, cEnv)
    guard rc == 0 else { throw WorkerError(description: "cannot start \(argv[0]): \(String(cString: strerror(rc)))") }
    return Process(pid: pid, onExit: onExit)
}

/// What the daemon needs of a worker it started: its pid, whether it ended, and a way to stop it.
/// `Process` (spawned here) and `PidProcess` (a helper known by pid) are workers; tests use fakes.
public protocol WorkerProcess: AnyObject {
    var pid: Int32 { get }
    /// nil while it runs; once it ended, Popen's returncode: the exit code, or −signal when a
    /// signal ended it (failed.json says "exit -9" as the Python app did).
    func poll() -> Int32?
    /// SIGTERM (never to a pid already reaped).
    func terminate()
    /// SIGKILL (never to a pid already reaped).
    func kill()
    /// `sig` to the worker and everything it started: workers run in their own session (setsid),
    /// so their pid is their group. A worker that leads no group gets it alone (memory.signal_group).
    func signalGroup(_ sig: Int32)
}

public extension WorkerProcess {
    func signalGroup(_ sig: Int32) { if sig == SIGKILL { kill() } else { terminate() } }
}

/// A started child. It is reaped as soon as it exits (a thread waits for it), so it never stays a
/// zombie whether or not anyone waits; callers read the status, wait for it or get a callback.
///
/// Signals never reach a pid the reaper already reaped (and the system may have given to another
/// program): the reaper first waits with WNOWAIT, which leaves the exited child a zombie that
/// keeps its pid, then reaps and records the status under the same lock signals are sent under.
public final class Process: WorkerProcess, @unchecked Sendable {
    public let pid: pid_t
    private let cond = NSCondition()
    private var status: Int32?
    private var killedBy: Int32?

    init(pid: pid_t, onExit: (@Sendable (Int32) -> Void)? = nil) {
        self.pid = pid
        let t = Thread { [self] in
            var info = siginfo_t()
            // Wait for the exit without reaping: the pid stays ours until the lock below.
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
            cond.lock()
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0 && errno == EINTR {}
            let sig = raw & 0x7f
            let code: Int32 = sig == 0 ? (raw >> 8) & 0xff : 128 + sig
            status = code
            killedBy = sig == 0 ? nil : sig
            cond.broadcast()
            cond.unlock()
            onExit?(code)
        }
        t.name = "palaver-reap-\(pid)"
        t.start()
    }

    /// The exit code (128+signal when killed) once the child has ended; nil while it runs.
    public var exitCode: Int32? { cond.lock(); defer { cond.unlock() }; return status }

    /// The signal that ended the child, if one did.
    public var terminationSignal: Int32? { cond.lock(); defer { cond.unlock() }; return killedBy }

    /// Waits at most `timeout` seconds for the child to end: its exit code (128+signal), or nil
    /// while it still runs.
    @discardableResult
    public func waitUntilExit(timeout: Double) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock(); defer { cond.unlock() }
        while status == nil {
            if !cond.wait(until: deadline) { break }
        }
        return status
    }

    public func poll() -> Int32? {
        cond.lock(); defer { cond.unlock() }
        guard let status else { return nil }
        return killedBy.map { -$0 } ?? status
    }

    /// Blocks until the child ends; its exit code, or 128+signal.
    @discardableResult
    public func waitUntilExit() -> Int32 {
        cond.lock(); defer { cond.unlock() }
        while status == nil { cond.wait() }
        return status!
    }

    /// Sends `sig` to the child (`group`: to its process group, which it leads: setsid) unless it
    /// was reaped already. False when nothing was sent.
    @discardableResult
    public func signal(_ sig: Int32, group: Bool = false) -> Bool {
        cond.lock(); defer { cond.unlock() }
        guard status == nil else { return false }
        return (group ? killpg(pid, sig) : Darwin.kill(pid, sig)) == 0
    }

    public func terminate() { signal(SIGTERM) }
    public func kill() { signal(SIGKILL) }

    /// The group when this child leads one (it does after setsid), else the child alone; under
    /// the reaper's lock, so never to a pid that was reaped.
    public func signalGroup(_ sig: Int32) {
        cond.lock(); defer { cond.unlock() }
        guard status == nil else { return }
        if getpgid(pid) == pid, killpg(pid, sig) == 0 { return }
        _ = Darwin.kill(pid, sig)
    }
}
