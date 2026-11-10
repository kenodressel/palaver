// The pid files of a recording's workers: live.pid (the live worker, palaver/live.py `worker_running`,
// `_works_on`, `stop_worker`) and stream.pid (the realtime stream, palaver/stream.py `running_pid`).
import Darwin
import Foundation
import PalaverCore

public enum WorkerPids {
    private static func pidFile(_ folder: URL) -> URL { folder.appendingPathComponent("live.pid") }

    /// Python's `int(text)` for a pid file: optional whitespace, a sign, digits (single underscores between them).
    private static func pid(_ url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        var s = Substring(Py.strip(text))
        var negative = false
        if let sign = s.first, sign == "+" || sign == "-" { negative = sign == "-"; s = s.dropFirst() }
        guard !s.isEmpty, s.first != "_", s.last != "_", !s.contains("__") else { return nil }
        let digits = s.replacingOccurrences(of: "_", with: "")
        guard let n = Int(digits) else { return nil }
        return negative ? -n : n
    }

    /// Whether a live worker is still processing `folder`. A pid file left behind (the worker was killed,
    /// or its pid now belongs to another program) is removed; an exited worker that is our child is
    /// reaped — a zombie still answers `kill(pid, 0)`. A pid that is no process id at all (0, negative)
    /// is removed too, as Python ends up doing; unreadable text is left as it is.
    public static func liveRunning(_ folder: URL) -> Bool {
        let file = pidFile(folder)
        guard let pid = pid(file) else { return false }
        func remove() { try? FileManager.default.removeItem(at: file) }
        guard pid > 0, pid <= Int(Int32.max) else { remove(); return false }
        var status: Int32 = 0
        if waitpid(pid_t(pid), &status, WNOHANG) == pid_t(pid) {  // our child, and it has exited
            remove()
            return false
        }  // not our child (ECHILD) or still running: ask the system
        if kill(pid_t(pid), 0) != 0 {
            if errno == EPERM { return true }  // alive, under another user
            remove()  // ESRCH: gone
            return false
        }
        if let command = commandLine(pid_t(pid)), !worksOn(command, folder) {
            remove()  // the pid was reused
            return false
        }
        return true
    }

    /// Whether `command` is `palaver … live <folder>` for this folder: the text after the last ` live `
    /// is the folder's path.
    public static func worksOn(_ command: String, _ folder: URL) -> Bool {
        guard let range = command.range(of: " live ", options: .backwards) else { return false }
        let given = Py.strip(String(command[range.upperBound...]))
        return resolved(given) == resolved(folder.path)
    }

    /// Python's `Path(p).resolve()`: symlinks followed as far as the path exists, the rest kept; relative
    /// to the working directory.
    private static func resolved(_ path: String) -> String {
        let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        let parts = absolute.split(separator: "/").filter { $0 != "." }.map(String.init)
        var known = parts.count
        while known > 0 {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            if realpath("/" + parts[..<known].joined(separator: "/"), &buffer) != nil {
                var out = String(cString: buffer).split(separator: "/").map(String.init)
                for part in parts[known...] {
                    if part == ".." { _ = out.popLast() } else { out.append(part) }
                }
                return "/" + out.joined(separator: "/")
            }
            known -= 1
        }
        return "/"
    }

    /// daemon.py `_OWNS_RECORDING` (lowercased command lines): the Python app or daemon, the Swift app in a bundle or a
    /// development build. Not `…/MacOS/Palaver -m palaver …`: up to 0.3.14 that path was the Python host running a worker.
    static let ownsRecording = try! NSRegularExpression(
        pattern: #"\bpalaver\s+(menubar|daemon)\b|/contents/macos/palaver(?!\S)(?!.*\s-m\s+palaver\b)"#
            + #"|/\.build/(\S+/)?(debug|release)/palaver(?!\S)(?!.*\s-m\s+palaver\b)"#)

    /// daemon.py `palaver_alive`: whether `pid` is a running Palaver that owns a recording (the Swift app, the Python
    /// menu bar app or `palaver daemon`). A pid the system gave to another program since (`palaver mcp`, a worker) is
    /// not.
    public static func palaverAlive(_ pid: Int32?, commandLine: (Int32) -> String? = commandLine) -> Bool {
        guard let pid, pid > 0 else { return false }
        if kill(pid, 0) != 0 { return errno == EPERM }
        guard let command = commandLine(pid)?.lowercased() else { return true }  // alive, and nothing says it is not Palaver
        return ownsRecording.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }

    /// daemon.py `recording_into`: whether a running Palaver records into `folder` (its daemon.json, `stateFile`).
    public static func recordingInto(_ folder: URL, stateFile: URL) -> Bool {
        guard let state = PythonJSON.read(stateFile), case .object = state else { return false }
        guard let running = state["state"], !running.isNull, running.stringValue != "stopped",
              let named = state["folder"], named.truthy, case .string(let path) = named else { return false }
        guard resolved(path) == resolved(folder.path) else { return false }
        let pid: Int32?
        switch state["pid"] {
        case .int(let n)?: pid = Int32(exactly: n)
        case .string(let s)?: pid = Int32(Py.strip(s))
        default: pid = nil
        }
        return palaverAlive(pid)
    }

    /// The pid of the stream still running for `folder`, if any: any pid `kill(pid, 0)` accepts
    /// (another user's process answers EPERM: not ours, not running).
    public static func streamPid(_ folder: URL) -> Int? {
        guard let pid = pid(RecordingPaths(folder).streamPid), pid >= Int(Int32.min), pid <= Int(Int32.max),
              kill(pid_t(pid), 0) == 0 else { return nil }
        return pid
    }

    /// Whether a stream is still running for `folder`.
    public static func streamRunning(_ folder: URL) -> Bool { streamPid(folder) != nil }

    /// SIGTERM to the live worker of `folder`; nothing when there is no pid, or it is not a process id.
    public static func stopLive(_ folder: URL) {
        guard let pid = pid(pidFile(folder)), pid > 0, pid <= Int(Int32.max) else { return }
        _ = kill(pid_t(pid), SIGTERM)
    }

    /// What `ps -p <pid> -o command=` prints: the arguments joined by spaces. nil when they can't be
    /// read (the caller assumes the pid is what it was); "" when there is no such process.
    public static func commandLine(_ pid: Int32) -> String? {
        var maxArgs: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &maxArgs, &size, nil, 0) == 0, maxArgs > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(maxArgs))
        size = buffer.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return errno == ESRCH || errno == EINVAL ? "" : nil }
        guard size > MemoryLayout<Int32>.size else { return "" }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }  // the executable path
        while i < size, buffer[i] == 0 { i += 1 }  // its padding
        var args: [String] = []
        while args.count < argc, i < size {
            var end = i
            while end < size, buffer[end] != 0 { end += 1 }
            args.append(String(decoding: buffer[i..<end], as: UTF8.self))
            i = end + 1
        }
        return args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
