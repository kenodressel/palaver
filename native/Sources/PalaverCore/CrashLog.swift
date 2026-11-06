// The crash log (runlog.install_crash_log): `~/Library/Logs/palaver/crashes.log` gets an uncaught
// Objective-C exception (its reason and stack) and a fatal signal (a Swift trap, a bad access) with
// the stack of the crashing thread, then the process dies as it would have. The header names the
// app, its version and pid, as Python's does.
import Darwin
import Foundation

public enum CrashLog {
    /// Kept open: a signal handler may only write(2) to a descriptor it already has.
    nonisolated(unsafe) private static var fd: Int32 = -1
    nonisolated(unsafe) private static var signalHead: [CChar] = []
    public static let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE]

    /// `=== <time> <where> pid <pid> palaver <version> argv [...]`, as runlog.write_crash.
    public static func header(where place: String, version: String, pid: Int32 = getpid(),
                              argv: [String] = Array(CommandLine.arguments.dropFirst()), now: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        let args = "[" + argv.map { "'\($0)'" }.joined(separator: ", ") + "]"
        return "=== \(f.string(from: now)) \(place) pid \(pid) palaver \(version) argv \(args)\n"
    }

    /// Installs the handlers; at most once per process.
    public static func install(path: URL, version: String) {
        guard fd < 0 else { return }
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(path.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        // The time is when the app started: a handler cannot format one safely.
        signalHead = Array(header(where: "palaver app (fatal signal; started at the time shown)", version: version).utf8CString)
        NSSetUncaughtExceptionHandler { exception in
            let text = CrashLog.header(where: "palaver app", version: CrashLog.versionForExceptions)
                + "uncaught exception \(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.joined(separator: "\n") + "\n\n"
            CrashLog.write(text)
        }
        versionForExceptions = version
        for sig in signals { signal(sig, crashHandler) }
    }

    nonisolated(unsafe) static var versionForExceptions = "?"

    static func write(_ text: String) {
        guard fd >= 0 else { return }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
}

/// Async-signal-safe as far as it goes: the head was formatted at install time, the stack goes out
/// through backtrace_symbols_fd; then the default action (the crash report macOS writes too).
private func crashHandler(_ sig: Int32) {
    let fd = CrashLog.currentFD
    if fd >= 0 {
        CrashLog.writeSignalHead(fd)
        var digits = [UInt8](repeating: 0, count: 16)  // "signal N\n" without allocating
        var n = Int(sig), i = digits.count
        repeat { i -= 1; digits[i] = UInt8(48 + n % 10); n /= 10 } while n > 0 && i > 0
        _ = Darwin.write(fd, "signal ", 7)
        _ = digits.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + i, digits.count - i) }
        _ = Darwin.write(fd, "\n", 1)
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = backtrace(&frames, Int32(frames.count))
        backtrace_symbols_fd(&frames, count, fd)
        _ = Darwin.write(fd, "\n", 1)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

extension CrashLog {
    static var currentFD: Int32 { fd }
    static func writeSignalHead(_ fd: Int32) {
        signalHead.withUnsafeBufferPointer { p in
            if let base = p.baseAddress, p.count > 1 { _ = Darwin.write(fd, base, p.count - 1) }
        }
    }
}
