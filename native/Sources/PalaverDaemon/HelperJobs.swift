// The language model's helpers the Meetings window has the app start (app.sock `start_helper`;
// palaver/model_jobs.py `helper_argv` and `launch`): `palaver notes <a meeting> --force` or
// `palaver projects --no-wait suggest | describe <id>`, recorded in `<recordings>/.jobs/<kind>-<key>.json`
// with their pid, and their output in `<kind>-<key>.log`. The app starts them, so they are its
// descendants (the memory watchdog sees them) and outlive a restart of the window's server, which
// reads the records. Never two runs of one kind and key.
import Darwin
import Foundation
import PalaverCore

public final class HelperJobs: @unchecked Sendable {
    public static let kinds = ["notes", "projects"]
    static let keyPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_.-]{1,80}$"#)
    static let projectId = try! NSRegularExpression(pattern: #"^[0-9a-f]{1,64}$"#)
    static let folderName = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}(-\d+)?$"#)

    /// Starts argv with its output on the given fd, in a session of its own; the app's environment.
    public typealias Spawn = (_ argv: [String], _ output: Int32) throws -> WorkerProcess

    private let outputDir: () -> URL
    private let python: String
    private let cliOptions: [String]
    private let taskpolicy: String?
    private let spawn: Spawn
    private let now: () -> Double
    private let alive: (Int32) -> Bool
    private let lock = NSLock()

    /// `env`: what the app adds for its children (PALAVER_APP, PALAVER_NOTIFY, …).
    public init(outputDir: @escaping () -> URL, python: String, cliOptions: [String], env: [String: String] = [:],
                taskpolicy: String? = FileManager.default.fileExists(atPath: "/usr/sbin/taskpolicy") ? "/usr/sbin/taskpolicy" : nil,
                spawn: Spawn? = nil, now: @escaping () -> Double = { Date().timeIntervalSince1970 },
                alive: @escaping (Int32) -> Bool = UpdateBusy.pidAlive) {
        self.outputDir = outputDir
        self.python = python
        self.cliOptions = cliOptions
        self.taskpolicy = taskpolicy
        self.spawn = spawn ?? { argv, output in
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            return try spawnChild(argv, env: merged, output: output)
        }
        self.now = now
        self.alive = alive
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    public var root: URL { outputDir().appendingPathComponent(".jobs", isDirectory: true) }

    /// `helper_argv`: the helper's command, or CallRefused (Python's ValueError) for anything else.
    public func argv(kind: String, args: [String]) throws -> [String] {
        switch kind {
        case "notes":
            guard args.count == 2, args[1] == "--force" else { throw CallRefused("not a notes helper") }
            let folder = URL(fileURLWithPath: args[0])
            let parent = folder.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            let output = outputDir().resolvingSymlinksInPath().standardizedFileURL.path
            guard parent == output, Self.matches(Self.folderName, folder.lastPathComponent) else {
                throw CallRefused("not a meeting's folder")
            }
        case "projects":
            let ok = args == ["--no-wait", "suggest"]
                || (args.count == 3 && Array(args[..<2]) == ["--no-wait", "describe"] && Self.matches(Self.projectId, args[2]))
            guard ok else { throw CallRefused("not a projects helper") }
        default:
            throw CallRefused("not a helper: \(kind)")
        }
        let command = [python, "-m", "palaver"] + cliOptions + ["--no-notify", kind] + args
        return taskpolicy.map { [$0, "-c", "utility"] + command } ?? command
    }

    func record(kind: String, key: String) throws -> URL {
        guard Self.kinds.contains(kind), Self.matches(Self.keyPattern, key), !key.hasPrefix(".") else {
            throw CallRefused("not a job: \(kind) \(key)")
        }
        return root.appendingPathComponent("\(kind)-\(key).json")
    }

    func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Atomically, through a temp file beside it (model_jobs._write_json).
    func write(_ url: URL, _ job: [String: Any]) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: job) else { return }
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        if (try? data.write(to: tmp)) != nil, rename(tmp.path, url.path) != 0 { unlink(tmp.path) }
    }

    /// `launch`: starts the helper and records it; the pid of the run going on under `kind`/`key`
    /// instead, if there is one.
    public func launch(kind: String, key: String, args: [String]) throws -> Int32 {
        let argv = try argv(kind: kind, args: args)  // a bad helper fails before anything starts
        lock.lock(); defer { lock.unlock() }
        let url = try record(kind: kind, key: key)
        if let job = read(url), job["state"] as? String == "running", let pid = (job["pid"] as? NSNumber)?.int32Value, alive(pid) {
            return pid
        }
        let log = url.deletingPathExtension().appendingPathExtension("log")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(log.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw WorkerError(description: "cannot open \(log.lastPathComponent): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let process = try spawn(argv, fd)
        let started = now()
        write(url, ["kind": kind, "key": key, "pid": Int(process.pid), "state": "running", "started": started])
        let t = Thread { [self] in
            if let child = process as? PalaverCore.Process { child.waitUntilExit() }
            while process.poll() == nil { Thread.sleep(forTimeInterval: 0.2) }  // a fake, or one known by pid
            let code = process.poll() ?? 0
            lock.lock(); defer { lock.unlock() }
            var job = read(url) ?? ["kind": kind, "key": key, "pid": Int(process.pid), "started": NSNull()]
            guard (job["pid"] as? NSNumber)?.int32Value == process.pid else { return }
            job["state"] = "done"; job["returncode"] = Int(code); job["ended"] = now(); job["stale"] = false
            write(url, job)
        }
        t.name = "\(kind)-helper"
        t.start()
        return process.pid
    }
}
