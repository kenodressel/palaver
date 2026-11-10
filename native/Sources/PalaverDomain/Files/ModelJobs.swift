// The language model's jobs the Meetings window starts — writing a meeting's notes, sorting or describing projects —
// recorded on disk with their pid (#57), in `<recordings>/.jobs/` (palaver/model_jobs.py).
//
// The helper's record says it runs until it exits, then its exit code. A restarted server reads the records: it
// shows a running job again, never starts a second one, and finishes what the old server could not (a sort's undo
// snapshot, `pendingUndo`). A record whose pid is gone without an exit code (the app quit) is stale. The files keep
// Python's format (`json.dump` without indent, through a `mkstemp` temp file), so either implementation reads and
// finishes what the other started.
import Darwin
import Foundation
import PalaverCore

/// What model_jobs.py raises: ValueError for a job, token or helper it refuses (the window answers 400), KeyError for
/// a finished undo without a token.
public struct ModelJobsError: Error, CustomStringConvertible {
    /// "ValueError" or "KeyError".
    public let python: String
    public let message: String
    public var description: String { message }

    init(_ message: String, python: String = "ValueError") {
        self.message = message
        self.python = python
    }
}

public enum ModelJobs {
    public static let KINDS = ["notes", "projects"]
    static let KEY = try! PyRegex(#"[A-Za-z0-9_.-]{1,80}"#)
    static let PROJECT_ID = try! PyRegex(#"[0-9a-f]{1,64}"#)
    public static let POLL_SECONDS = 0.2
    /// How long `wait` gives a launcher that reaped its helper to write the returncode before calling the job stale.
    public static let STALE_GRACE_SECONDS = 1.0
    /// `daemon.TASKPOLICY`.
    public static let TASKPOLICY = "/usr/sbin/taskpolicy"

    public typealias Job = PyDict<JSONValue>
    /// Starts argv in a session of its own, stdin from /dev/null, stdout and stderr on the given fd (`Popen(argv,
    /// stdin=DEVNULL, stdout=log, stderr=STDOUT, start_new_session=True)`).
    public typealias Spawn = (_ argv: [String], _ output: Int32) throws -> PalaverCore.Process

    /// `jobs_root(output_dir)`.
    public static func root(_ outputDir: URL) -> URL { outputDir.appendingPathComponent(".jobs", isDirectory: true) }

    // MARK: - Records

    /// `_alive`: `os.kill(pid, 0)` succeeds or is refused (another user's process).
    public static func pidAlive(_ pid: Int) -> Bool {
        guard let p = Int32(exactly: pid) else { return false }
        return kill(p, 0) == 0 || errno == EPERM
    }

    /// `int(pid)` of a record's pid as `_alive` takes it; nil where Python's `int()` fails (None, a list, text that
    /// is no ASCII integer, NaN, infinity).
    public static func pid(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let i)?: return i
        case .bool(let b)?: return b ? 1 : 0
        case .double(let d)?: return d.isFinite ? Int(exactly: d.rounded(.towardZero)) : nil
        case .string(let s)?:
            var t = Substring(Py.strip(s))
            var negative = false
            if let sign = t.first, sign == "+" || sign == "-" { negative = sign == "-"; t = t.dropFirst() }
            guard !t.isEmpty, t.first != "_", t.last != "_", !t.contains("__"),
                  t.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || $0 == "_" }),
                  let n = Int(t.replacingOccurrences(of: "_", with: "")) else { return nil }
            return negative ? -n : n
        default: return nil
        }
    }

    /// `value == text` for a value read from a record: text with the same code points.
    private static func says(_ value: JSONValue?, _ text: String) -> Bool { value?.stringValue.map { Py.same($0, text) } ?? false }

    private static func isAlive(_ value: JSONValue?, _ alive: (Int) -> Bool) -> Bool { pid(value).map(alive) ?? false }

    private static func path(_ root: URL, _ kind: String, _ key: String) throws -> URL {
        guard KINDS.contains(where: { Py.same($0, kind) }), KEY.fullMatch(key) != nil, !key.hasPrefix(".") else {
            throw ModelJobsError("not a job: \(kind) \(key)")
        }
        return root.appendingPathComponent("\(kind)-\(key).json")
    }

    /// `_write_json`: the parent made, then `json.dump` into a `mkstemp` file beside the target (`<name>.XXXXXXXX.tmp`,
    /// mode 0600), renamed over it.
    static func writeJSON(_ target: URL, _ data: Job) throws {
        let dir = target.deletingLastPathComponent().path
        try Undo.makedirs(dir)
        let (fd, tmp) = try mkstemp(dir: dir, prefix: target.lastPathComponent + ".", suffix: ".tmp")
        do {
            let bytes = Array(PythonJSON.dumps(data.json).utf8)
            var done = 0
            while done < bytes.count {
                let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + done, bytes.count - done) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { if n == 0 { errno = EIO }; throw posixError() }
                done += n
            }
            guard close(fd) == 0 else { throw posixError() }
            guard rename(tmp, target.path) == 0 else { throw posixError() }
        } catch {
            close(fd)  // EBADF when closed already
            unlink(tmp)
            throw error
        }
    }

    /// `tempfile.mkstemp(dir=, prefix=, suffix=)`: eight characters of `_RandomNameSequence`, created exclusively, 0600.
    private static func mkstemp(dir: String, prefix: String, suffix: String) throws -> (Int32, String) {
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789_")
        for _ in 0..<10000 {  // tempfile.TMP_MAX
            let name = prefix + String((0..<8).map { _ in letters.randomElement()! }) + suffix
            let file = dir + "/" + name
            let fd = open(file, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 { return (fd, file) }
            if errno != EEXIST { throw posixError() }
        }
        throw POSIXError(.EEXIST)
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    /// `_read_json`: the file's object; nil when it is missing, unreadable, not JSON or no object.
    static func readJSON(_ target: URL) -> Job? { PythonJSON.read(target).flatMap { PyDict<JSONValue>($0) } }

    /// `write(root, job)`: the record of `job["kind"]`/`job["key"]`.
    public static func write(_ root: URL, _ job: Job) throws {
        guard let kind = job["kind"]?.stringValue, let key = job["key"]?.stringValue else {
            throw ModelJobsError("not a job: the record names no kind or key")
        }
        try writeJSON(try path(root, kind, key), job)
    }

    /// `read`: the job's record; `stale` when it says running but its pid is gone.
    public static func read(_ root: URL, kind: String, key: String, alive: (Int) -> Bool = pidAlive) throws -> Job? {
        guard var job = readJSON(try path(root, kind, key)) else { return nil }
        if says(job["state"], "running") && !isAlive(job["pid"], alive) { job["stale"] = .bool(true) }
        return job
    }

    /// `log_path`: what the helper printed, its last run's (kept after the record, for the window's error and a
    /// problem report).
    public static func logPath(_ root: URL, kind: String, key: String) throws -> URL {
        try path(root, kind, key).deletingPathExtension().appendingPathExtension("log")
    }

    /// `last_error`: the line that says why the helper's last run failed: its last "error: …" line, else the
    /// exception a traceback ended with.
    public static func lastError(_ root: URL, kind: String, key: String) throws -> String? {
        let log = try logPath(root, kind: kind, key: key)
        guard let data = try? Data(contentsOf: log) else { return nil }
        let lines = splitlines(String(decoding: data, as: UTF8.self)).map(Py.strip).filter { !$0.isEmpty }
        let said = lines.filter { line in
            // `x.lower().startswith("error:")`: only "E", "R" and "O" lower to letters of "error:" (the one letter
            // that lowers to two, "İ", lowers to an "i").
            let head = Array(line.unicodeScalars.prefix(6))
            return head.count == 6 && zip(head, "error:".unicodeScalars).allSatisfy { a, b in
                a == b || ((65...90).contains(a.value) && a.value + 32 == b.value)
            }
        }
        if let last = said.last {
            let rest = Py.strip(String(String.UnicodeScalarView(last.unicodeScalars.dropFirst(6))))
            let cut = String(String.UnicodeScalarView(rest.unicodeScalars.prefix(300)))
            return cut.isEmpty ? nil : cut
        }
        if lines.contains(where: { $0.unicodeScalars.starts(with: "Traceback".unicodeScalars) }), let last = lines.last {
            return String(String.UnicodeScalarView(last.unicodeScalars.prefix(300)))
        }
        return nil
    }

    /// `str.splitlines()`: lines end at \n, \r, \r\n, \v, \f, \x1c, \x1d, \x1e, \x85,   and  .
    public static func splitlines(_ s: String) -> [String] {
        var lines: [String] = [], line = String.UnicodeScalarView()
        var previousCR = false
        for u in s.unicodeScalars {
            if u == "\n" && previousCR { previousCR = false; continue }
            previousCR = u == "\r"
            switch u.value {
            case 0x0A, 0x0D, 0x0B, 0x0C, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
                lines.append(String(line)); line = String.UnicodeScalarView()
            default:
                line.append(u)
            }
        }
        if !line.isEmpty { lines.append(String(line)) }
        return lines
    }

    /// `clear`: the record goes (its log stays).
    public static func clear(_ root: URL, kind: String, key: String) throws {
        let file = try path(root, kind, key).path
        if unlink(file) != 0 && errno != ENOENT { throw posixError() }
    }

    /// `running`: the jobs running now, oldest first. Throws, as Python does, for a record named after a kind whose
    /// key is no job key.
    public static func running(_ root: URL, alive: (Int) -> Bool = pidAlive) throws -> [Job] {
        guard Undo.isDir(root.path) else { return [] }
        // `sorted(root.glob("*.json"))`: hidden names too, folders too, by code points.
        let names = Py.stableSorted(((try? Undo.listdir(root.path)) ?? []).filter { Undo.matches($0, "*.json") }, by: Py.less)
        var out: [Job] = []
        for name in names {
            let suffix = Undo.suffix(name)
            let stem = String(String.UnicodeScalarView(name.unicodeScalars.dropLast(suffix.unicodeScalars.count)))
            // `stem.partition("-")`
            let scalars = stem.unicodeScalars
            let dash = scalars.firstIndex(of: "-")
            let kind = String(scalars[..<(dash ?? scalars.endIndex)])
            let key = dash.map { String(scalars[scalars.index(after: $0)...]) } ?? ""
            guard KINDS.contains(where: { Py.same($0, kind) }) else { continue }
            if let job = try read(root, kind: kind, key: key, alive: alive), says(job["state"], "running"),
               !(job["stale"]?.truthy ?? false) {
                out.append(job)
            }
        }
        // `key=lambda j: j.get("started") or 0`
        func started(_ job: Job) -> Double {
            switch job["started"] {
            case .int(let i)?: return Double(i)
            case .double(let d)?: return d
            case .bool(let b)?: return b ? 1 : 0
            default: return 0
            }
        }
        return Py.stableSorted(out) { started($0) < started($1) }
    }

    // MARK: - Launching

    /// `_launch_lock`.
    private static let launchLock = NSLock()

    /// The app's environment for the helper, as Popen passes it.
    public static func spawnHelper(_ argv: [String], output: Int32) throws -> PalaverCore.Process {
        try PalaverCore.spawnChild(argv, env: ProcessInfo.processInfo.environment, output: output)
    }

    /// `launch`: starts the helper `argv` in its own process group (a session of its own), its output in
    /// `<kind>-<key>.log`, and records it; a thread writes its exit code when it ends. The pid of the job already
    /// running under `kind`/`key` instead, if there is one (never a second run).
    public static func launch(root: URL, kind: String, key: String, argv: [String],
                              spawn: Spawn = spawnHelper) throws -> Int32 {
        let process: PalaverCore.Process
        launchLock.lock()
        do {
            defer { launchLock.unlock() }
            if let job = try read(root, kind: kind, key: key), says(job["state"], "running"),
               !(job["stale"]?.truthy ?? false), let pid = pid(job["pid"]) {
                return Int32(truncatingIfNeeded: pid)
            }
            let log = try logPath(root, kind: kind, key: key)  // a bad key fails before anything starts
            try Undo.makedirs(log.deletingLastPathComponent().path)
            let fd = open(log.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
            guard fd >= 0 else { throw posixError() }
            defer { close(fd) }
            process = try spawn(argv, fd)
            try write(root, Job([("kind", .string(kind)), ("key", .string(key)), ("pid", .int(Int(process.pid))),
                                 ("state", .string("running")), ("started", .double(Date().timeIntervalSince1970))]))
        }
        let t = Thread {
            process.waitUntilExit()
            let code = process.poll() ?? 0  // Popen's returncode: −signal when a signal ended it
            var job = (try? read(root, kind: kind, key: key))
                ?? Job([("kind", .string(kind)), ("key", .string(key)), ("pid", .int(Int(process.pid))), ("started", .null)])
            guard let pid = job["pid"], PythonJSON.equal(pid, .int(Int(process.pid))) else { return }
            job["state"] = .string("done")
            job["returncode"] = .int(Int(code))
            job["ended"] = .double(Date().timeIntervalSince1970)
            job["stale"] = .bool(false)
            try? write(root, job)
        }
        t.name = "\(kind)-helper"
        t.start()
        return process.pid
    }

    /// `wait`: the job's record once it is no longer running (done, stale or gone). `timeout` (not in Python, which
    /// waits as long as it takes): the record as it is when the time is up.
    public static func wait(_ root: URL, kind: String, key: String, poll: Double = POLL_SECONDS,
                            alive: (Int) -> Bool = pidAlive, timeout: Double? = nil) throws -> Job {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var staleSince: Date?
        while true {
            guard let job = try read(root, kind: kind, key: key, alive: alive) else {
                return Job([("kind", .string(kind)), ("key", .string(key)), ("state", .string("gone"))])
            }
            if !says(job["state"], "running") { return job }
            if job["stale"]?.truthy ?? false {
                // The launcher reaps the helper before it writes the returncode: a moment's grace, so a helper that
                // just ended is "done" with its code, not stale (Python's wait returns the stale record at once).
                let since = staleSince ?? Date()
                staleSince = since
                if Date().timeIntervalSince(since) >= STALE_GRACE_SECONDS { return job }
            }
            if let deadline, Date() >= deadline { return job }
            Thread.sleep(forTimeInterval: staleSince == nil ? poll : min(poll, 0.05))
        }
    }

    /// `helper_argv`: the command of a helper the window may have the app start: `palaver-lm notes <a meeting> --force`
    /// or `palaver-lm projects --no-wait suggest | describe <id>`, under `taskpolicy -c utility` when there is one;
    /// ModelJobsError (ValueError) for anything else. `lm`: palaver-lm (Python's `sys.executable -m palaver` before).
    public static func helperArgv(kind: String, args: [String], cliOptions: [String], lm: String, outputDir: URL,
                                  taskpolicy: String = TASKPOLICY) throws -> [String] {
        func equal(_ a: [String], _ b: [String]) -> Bool { a.count == b.count && zip(a, b).allSatisfy(Py.same) }
        if Py.same(kind, "notes") {
            guard args.count == 2, Py.same(args[1], "--force") else { throw ModelJobsError("not a notes helper") }
            let folder = Undo.pyPath(args[0])  // `Path(args[0])`
            let parent = folder == "/" || folder == "." ? folder : Undo.dirname(folder)
            guard Py.same(resolve(parent), resolve(Undo.pyPath(outputDir.path))),
                  RecordingPaths.isRecordingFolderName(folder == "/" || folder == "." ? "" : Undo.basename(folder)) else {
                throw ModelJobsError("not a meeting's folder")
            }
        } else if Py.same(kind, "projects") {
            guard equal(args, ["--no-wait", "suggest"])
                    || (args.count == 3 && equal(Array(args[..<2]), ["--no-wait", "describe"]) && PROJECT_ID.fullMatch(args[2]) != nil) else {
                throw ModelJobsError("not a projects helper")
            }
        } else {
            throw ModelJobsError("not a helper: \(kind)")
        }
        let argv = [lm] + cliOptions + ["--no-notify", kind] + args
        return Undo.exists(taskpolicy) ? [taskpolicy, "-c", "utility"] + argv : argv
    }

    /// `Path(p).resolve()` (Python 3.13's `posixpath.realpath`, not strict): symlinks followed as far as the path
    /// exists, the rest kept, ".." taken after the part before it was resolved; relative to the working directory.
    static func resolve(_ p: String) -> String {
        /// `s.split("/")`, reversed, by code points.
        func parts(_ s: String) -> [String?] {
            s.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
                .map { String(String.UnicodeScalarView($0)) }.reversed()
        }
        var rest = parts(p)  // nil: the symlink popped next has been resolved
        var count = rest.count
        var current = p.unicodeScalars.first == "/" ? "/" : FileManager.default.currentDirectoryPath
        // Symlinks met, by code points, with their resolved target (nil while it is being resolved).
        var seen: [(link: String, target: String?)] = []
        func known(_ link: String) -> Int? { seen.firstIndex { Py.same($0.link, link) } }
        while count > 0 {
            guard let name = rest.removeLast() else {
                let link = rest.removeLast()!
                if let i = known(link) { seen[i].target = current } else { seen.append((link, current)) }
                continue
            }
            count -= 1
            if name.isEmpty || Py.same(name, ".") { continue }
            if Py.same(name, "..") {
                let i = current.unicodeScalars.lastIndex(of: "/")!
                let head = String(current.unicodeScalars[..<i])
                current = head.isEmpty ? "/" : head
                continue
            }
            let next = Py.same(current, "/") ? "/" + name : current + "/" + name
            var st = stat()
            guard lstat(next, &st) == 0, st.st_mode & S_IFMT == S_IFLNK else { current = next; continue }
            if let i = known(next) {
                current = seen[i].target ?? next  // nil: a loop
                continue
            }
            var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = buffer.withUnsafeMutableBufferPointer { b in
                b.baseAddress!.withMemoryRebound(to: CChar.self, capacity: b.count) { readlink(next, $0, Int(PATH_MAX)) }
            }
            guard n >= 0 else { current = next; continue }
            let target = String(decoding: buffer[..<n], as: UTF8.self)
            seen.append((next, nil))
            if target.unicodeScalars.first == "/" { current = "/" }
            rest.append(next)
            rest.append(nil)
            let targetParts = parts(target)
            rest.append(contentsOf: targetParts)
            count += targetParts.count
        }
        return current
    }

    // MARK: - A sort's undo snapshot, finished by whichever server sees the job end

    private static func undoPath(_ root: URL, _ token: String) throws -> URL {
        // A hidden name is refused as for job keys (Python lets ".x" through; tokens are uuid4 hex).
        guard KEY.fullMatch(token) != nil, !token.hasPrefix(".") else { throw ModelJobsError("not an undo token") }
        return root.appendingPathComponent("undo", isDirectory: true).appendingPathComponent("\(token).json")
    }

    /// `pending_undo`: the snapshot `token` was taken for a model change about to run (`owner`: this process when
    /// nil or 0).
    public static func pendingUndo(_ root: URL, token: String, label: String, owner: Int? = nil) throws {
        let who = owner.flatMap { $0 == 0 ? nil : $0 } ?? Int(getpid())
        try writeJSON(try undoPath(root, token), Job([("token", .string(token)), ("label", .string(label)),
                                                      ("owner", .int(who)), ("state", .string("pending"))]))
    }

    private static func undos(_ root: URL, _ state: String) -> [Job] {
        let folder = root.appendingPathComponent("undo", isDirectory: true).path
        guard Undo.isDir(folder) else { return [] }
        let names = Py.stableSorted(((try? Undo.listdir(folder)) ?? []).filter { Undo.matches($0, "*.json") }, by: Py.less)
        return names.compactMap { name in
            guard let u = readJSON(URL(fileURLWithPath: folder + "/" + name)), !u.isEmpty,
                  says(u["state"], state) else { return nil }
            return u
        }
    }

    /// `pending_undos`: the records of model changes not finished yet, by token.
    public static func pendingUndos(_ root: URL) -> [Job] { undos(root, "pending") }

    /// `finish_undo`: the change is done (`ok`) or rolled back. `told`: the page got the token in its answer already
    /// (the record goes); else it is kept for the page to fetch.
    public static func finishUndo(_ root: URL, token: String, ok: Bool, told: Bool = false) throws {
        let file = try undoPath(root, token)
        if told {
            if unlink(file.path) != 0 && errno != ENOENT { throw posixError() }
            return
        }
        let u = readJSON(file).flatMap { $0.isEmpty ? nil : $0 } ?? Job([("token", .string(token)), ("label", .string(""))])
        try writeJSON(file, Job([("token", .string(token)), ("label", u["label"] ?? .string("")), ("ok", .bool(ok)),
                                 ("state", .string("finished"))]))
    }

    /// `finished_undos`: model changes finished after the server that ran them was gone: the page puts their undo in
    /// its history. Throws (Python's KeyError) for a finished record without a token.
    public static func finishedUndos(_ root: URL) throws -> [Job] {
        try undos(root, "finished").map { u in
            guard let token = u["token"] else { throw ModelJobsError("'token'", python: "KeyError") }
            return Job([("token", token), ("label", u["label"] ?? .string("")), ("ok", .bool(u["ok"]?.truthy ?? false))])
        }
    }

    /// `seen`: the page has the finished change's undo; its record goes.
    public static func seen(_ root: URL, token: String) throws {
        let file = try undoPath(root, token)
        if unlink(file.path) != 0 && errno != ENOENT { throw posixError() }
    }
}
