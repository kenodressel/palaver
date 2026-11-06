// The one-release fallback (spec "Rollout"): the Swift app does what the ObjC launcher did for the
// Python menu bar app. It starts `palaver-python -m palaver menubar` as its child, its output in
// app.log; a datagram socket pair carries notification clicks to it ("open <meeting>" on the fd in
// $PALAVER_LAUNCHER_FD, which notify.on_click reads); SIGTERM, SIGINT and SIGHUP are passed on; the
// app exits with the child's exit code (128+signal). There is no restart, as before.
import Darwin
import Foundation

public final class LegacyLauncher: @unchecked Sendable {
    public let process: Process
    /// The app's end of the click socket; -1 without one.
    private let appEnd: Int32
    private var sources: [(sig: Int32, source: DispatchSourceSignal)] = []

    /// `clicks`: hand the child a click socket (only the bundled app gets notification clicks).
    public init(argv: [String], env: [String: String], log: URL, clicks: Bool) throws {
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = Darwin.open(log.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard out >= 0 else { throw WorkerError(description: "cannot open \(log.lastPathComponent): \(String(cString: strerror(errno)))") }
        defer { close(out) }
        var merged = ProcessInfo.processInfo.environment
        for (k, v) in env { merged[k] = v }
        var pair: [Int32] = [-1, -1]
        var inherit: [Int32] = []
        if clicks, socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0 {
            _ = fcntl(pair[0], F_SETFD, FD_CLOEXEC)  // the child gets pair[1] only, at its number
            merged["PALAVER_LAUNCHER_FD"] = String(pair[1])
            inherit = [pair[1]]
        } else {
            merged.removeValue(forKey: "PALAVER_LAUNCHER_FD")
        }
        do {
            process = try spawnChild(argv, env: merged, inherit: inherit, output: out)
        } catch {
            if pair[0] >= 0 { close(pair[0]); close(pair[1]) }
            throw error
        }
        if pair[1] >= 0 { close(pair[1]) }
        appEnd = pair[0]
    }

    /// A click on a notification: the child opens the meeting (nil: no particular one).
    public func open(_ meeting: String?) {
        guard appEnd >= 0 else { return }
        let line = Array("open \(meeting ?? "")".utf8)
        _ = line.withUnsafeBytes { send(appEnd, $0.baseAddress, $0.count, 0) }
    }

    /// SIGTERM, SIGINT and SIGHUP to the app go to the child; the app goes on until the child ends.
    public func forwardSignals(_ signals: [Int32] = [SIGTERM, SIGINT, SIGHUP]) {
        for sig in signals {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler { [process] in process.signal(sig) }
            source.resume()
            sources.append((sig, source))
        }
    }

    /// Undoes `forwardSignals` (the signals' default actions again).
    public func stopForwarding() {
        for (sig, source) in sources {
            source.cancel()
            signal(sig, SIG_DFL)
        }
        sources = []
    }

    /// Blocks until the child ends: its exit code, or 128+signal.
    public func wait() -> Int32 {
        let code = process.waitUntilExit()
        if appEnd >= 0 { close(appEnd) }
        return code
    }
}
