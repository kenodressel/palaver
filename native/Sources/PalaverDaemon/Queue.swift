// What the daemon's queues stand on: `failed.json` (palaver/process_state.py), the queue restored
// from daemon.json with its done markers, the live worker's `live.pid` (palaver/live.py
// worker_running/stop_worker), the running Palaver processes, free memory (vm_stat's sum) and the
// retry backoff.
import Darwin
import Foundation

// MARK: - failed.json

/// Why a recording has no transcript yet: `process` failed on it (`error`), or it waits for models
/// still being downloaded (`models`). Kept as failed.json in its folder until a run succeeds.
public enum ProcessState {
    public static let file = "failed.json"
    public static let models = "models"
    public static let error = "error"

    static func url(_ folder: URL) -> URL { folder.appendingPathComponent(file) }

    /// {"reason", "at", "missing", "error"}; nil when the last run did not fail (or none ran yet).
    public static func read(_ folder: URL) -> JSONValue? {
        guard let data = try? Data(contentsOf: url(folder)), let v = JSONValue.parse(data),
              let reason = v["reason"]?.stringValue, reason == models || reason == error else { return nil }
        return v
    }

    public static func mark(_ folder: URL, _ reason: String, missing: [String] = [], error: String? = nil,
                            now: Date = Date(), timeZone: TimeZone = .current) {
        let v = JSONValue.object([("reason", .string(reason)), ("at", .string(WallTime.iso(now, timeZone, seconds: true))),
                                  ("missing", .strings(missing)), ("error", .str(error))])
        let tmp = folder.appendingPathComponent("failed.json.tmp")
        guard (try? Data(v.encoded(indent: 2).utf8).write(to: tmp)) != nil else { return }
        rename(tmp.path, url(folder).path)
    }

    public static func clear(_ folder: URL) { unlink(url(folder).path) }
}

// MARK: - the folders

public enum RecordingFolders {
    static let namePattern = try! NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})(-\d+)?$"#)

    /// True for names `new` creates.
    public static func isRecordingName(_ name: String) -> Bool {
        namePattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// A fresh folder under `root`, named by the local time; "-2", "-3" … when it exists already.
    public static func new(in root: URL, at date: Date, timeZone: TimeZone = .current) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let base = String(format: "%04d-%02d-%02dT%02d-%02d-%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while true {
            if mkdir(candidate.path, 0o755) == 0 { return candidate }
            guard errno == EEXIST else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: candidate.path])
            }
            candidate = root.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
    }

    public static func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    public static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// `_restore_queue`: recordings a previous daemon queued (daemon.json's `key`) and never finished.
    public static func restoreQueue(_ state: JSONValue, key: String, doneMarker: String) -> [URL] {
        (state[key]?.arrayValue ?? []).compactMap(\.stringValue).map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { isDir($0) && !exists($0.appendingPathComponent(doneMarker)) }
    }
}

/// Folders as daemon.json writes them: the path without a trailing slash.
func folderPath(_ url: URL) -> String { url.path }

// MARK: - processes

public enum Processes {
    /// The command line of `pid` ("argv" joined by spaces, as `ps -o command=` prints it); nil when
    /// it can't be read (gone, or another user's).
    public static func commandLine(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && buffer[i] != 0 { i += 1 }  // the executable path
        while i < size && buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args.joined(separator: " ")
    }

    /// Every pid on the system.
    public static func allPids() -> [Int32] {
        var pids = [Int32](repeating: 0, count: 8192)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return n > 0 ? Array(pids.prefix(Int(n))).filter { $0 > 0 } : []
    }

    static let palaverWord = try! NSRegularExpression(pattern: #"\bpalaver\b"#)
    /// daemon.py `_OWNS_RECORDING`: the Python app or daemon, the Swift app in a bundle or a development build.
    /// Not `…/MacOS/Palaver -m palaver …`: up to 0.3.14 that path was the Python host running a worker.
    static let ownsRecording = try! NSRegularExpression(
        pattern: #"\bpalaver\s+(menubar|daemon)\b|/contents/macos/palaver(?!\S)(?!.*\s-m\s+palaver\b)"#
            + #"|/\.build/(\S+/)?(debug|release)/palaver(?!\S)(?!.*\s-m\s+palaver\b)"#)

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// `palaver_processes`: the command lines of the running `palaver` processes.
    public static func palaverProcesses() -> [String] {
        allPids().compactMap(commandLine).filter { matches(palaverWord, $0) }
    }

    /// `palaver_alive`: whether `pid` is a running Palaver that owns a recording: the Swift app,
    /// or the Python menu bar app or `palaver daemon`. A pid the system gave to another program
    /// since (`palaver mcp`, `palaver process`) is not.
    public static func palaverAlive(_ pid: Int32?, commandLine: (Int32) -> String? = commandLine) -> Bool {
        guard let pid, pid > 0 else { return false }
        if Darwin.kill(pid, 0) != 0 { return errno == EPERM }
        guard let command = commandLine(pid) else { return true }  // alive, and nothing says it is not Palaver
        return matches(ownsRecording, command.lowercased())
    }
}

// MARK: - the live worker (live.pid)

public enum LiveWorker {
    public static func pidFile(_ folder: URL) -> URL { folder.appendingPathComponent("live.pid") }

    /// Whether a live worker still processes `folder`. A pid file left behind (the worker was killed,
    /// or its pid belongs to another program now) is removed. Our own children are reaped by their
    /// reaper threads, so no waitpid here (it would race them).
    public static func running(_ folder: URL, commandLine: (Int32) -> String? = Processes.commandLine) -> Bool {
        let file = pidFile(folder)
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        if Darwin.kill(pid, 0) != 0 {
            if errno == EPERM { return true }  // alive, under another user
            unlink(file.path)
            return false
        }
        if let command = commandLine(pid), !worksOn(command, folder) {
            unlink(file.path)  // the pid was reused
            return false
        }
        return true
    }

    /// Whether `command` is `palaver … live <folder>` for this folder.
    static func worksOn(_ command: String, _ folder: URL) -> Bool {
        guard let r = command.range(of: " live ", options: .backwards) else { return false }
        let tail = command[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return URL(fileURLWithPath: tail).resolvingSymlinksInPath().standardizedFileURL.path
            == folder.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// SIGTERM to the folder's live worker.
    public static func stop(_ folder: URL) {
        guard let text = try? String(contentsOf: pidFile(folder), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        Darwin.kill(pid, SIGTERM)
    }
}

// MARK: - memory

public enum FreeMemory {
    /// Memory macOS can hand out without swapping: free, inactive, speculative and purgeable pages
    /// (daemon.py available_memory_gb, from the kernel's counters instead of `vm_stat`); unknown
    /// counts as plenty.
    public static func availableGB() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return .infinity }
        var page: vm_size_t = 0
        host_page_size(mach_host_self(), &page)
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
            + UInt64(stats.purgeable_count)
        return Double(pages) * Double(page) / 1_073_741_824
    }

    /// The same sum from `vm_stat`'s output; nil when it can't be read.
    public static func fromVMStat(_ out: String) -> Double? {
        guard let r = out.range(of: #"page size of (\d+)"#, options: .regularExpression),
              let page = Double(out[r].split(separator: " ").last ?? "") else { return nil }
        var pages: [String: Double] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let v = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard let n = Double(v) else { return nil }
            pages[parts[0].trimmingCharacters(in: .whitespaces)] = n
        }
        let kinds = ["Pages free", "Pages inactive", "Pages speculative", "Pages purgeable"]
        return kinds.reduce(0) { $0 + (pages[$1] ?? 0) } * page / 1_073_741_824
    }
}

/// RETRY_SECONDS doubling with each try (`n` from 1), up to LIVE_FINISH_TIMEOUT.
func backoff(_ n: Int) -> Double {
    min(DaemonTiming.retrySeconds * pow(2, Double(n - 1)), DaemonTiming.liveFinishTimeout)
}
