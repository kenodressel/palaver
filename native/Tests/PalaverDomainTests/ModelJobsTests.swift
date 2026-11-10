// tests/test_model_jobs.py: the language model's jobs the window starts (notes, sorting projects), recorded on disk
// with their pid (#57): a restarted window server shows a running job again, never starts a second one, and finishes
// an undo the old server could not. The helpers are harmless shell commands in temporary folders; every test waits
// for its child (and kills it when the wait runs out), so no process is left behind.
import Darwin
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

/// Python's `_sleeper(seconds, code)`: a helper that sleeps, then exits with `code`.
private func sleeper(_ seconds: Double, _ code: Int = 0) -> [String] {
    ["/bin/sh", "-c", "sleep \(seconds); exit \(code)"]
}

/// `model_jobs.wait`, bounded: the record once the job ended; a child still running after `seconds` is killed (its
/// group) and the test fails.
@discardableResult
private func finish(_ root: URL, _ kind: String, _ key: String, pid: Int32? = nil,
                    seconds: Double = 10) throws -> PyDict<JSONValue> {
    let job = try ModelJobs.wait(root, kind: kind, key: key, timeout: seconds)
    if job["state"] == .string("running"), job["stale"] != .bool(true) {
        if let pid { killpg(pid, SIGKILL) }
        Issue.record("the job \(kind)-\(key) still runs after \(seconds) s")
    }
    return job
}

/// The parent pid of `pid`, as `ps -o ppid=` says it.
private func parentPid(_ pid: Int32) -> Int32? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

private func keys(_ jobs: [PyDict<JSONValue>]) -> [String] { jobs.compactMap { $0["key"]?.stringValue } }

@Suite struct ModelJobsTests {
    @Test func test_a_launched_job_is_recorded_with_its_pid_until_it_ends() throws {
        let t = TempFolder("model-jobs")
        defer { t.remove() }
        let root = t.url.appendingPathComponent(".jobs")
        let pid = try ModelJobs.launch(root: root, kind: "notes", key: "2026-10-30T08-02-13", argv: sleeper(0.3))
        let job = try #require(try ModelJobs.read(root, kind: "notes", key: "2026-10-30T08-02-13"))
        #expect(job["pid"] == .int(Int(pid)) && job["state"] == .string("running") && !(job["stale"]?.truthy ?? false))
        #expect(keys(try ModelJobs.running(root)) == ["2026-10-30T08-02-13"])
        let done = try finish(root, "notes", "2026-10-30T08-02-13", pid: pid)
        #expect(done["state"] == .string("done") && done["returncode"] == .int(0))
        #expect(try ModelJobs.running(root).isEmpty)
        // The record as Python writes it: the reaper's read marks the reaped pid stale, the write says it is not.
        let text = try String(contentsOf: root.appendingPathComponent("notes-2026-10-30T08-02-13.json"), encoding: .utf8)
        #expect(text.hasPrefix(#"{"kind": "notes", "key": "2026-10-30T08-02-13", "pid": \#(pid), "state": "done", "started": "#))
        #expect(text.contains(#", "stale": false, "returncode": 0, "ended": "#) && !text.hasSuffix("\n"))
    }

    @Test func test_the_exit_code_is_kept() throws {
        let t = TempFolder("model-jobs")
        defer { t.remove() }
        let root = t.url.appendingPathComponent(".jobs")
        let pid = try ModelJobs.launch(root: root, kind: "projects", key: "projects", argv: sleeper(0, 75))
        #expect(try finish(root, "projects", "projects", pid: pid)["returncode"] == .int(75))
    }

    @Test func test_a_second_launch_while_one_runs_is_the_same_job() throws {
        let t = TempFolder("model-jobs")
        defer { t.remove() }
        let root = t.url.appendingPathComponent(".jobs")
        var launched: [[String]] = []
        let spawn: ModelJobs.Spawn = { argv, output in
            launched.append(argv)
            return try spawnChild(argv, env: ProcessInfo.processInfo.environment, output: output)
        }
        let first = try ModelJobs.launch(root: root, kind: "notes", key: "m", argv: sleeper(0.5), spawn: spawn)
        #expect(try ModelJobs.launch(root: root, kind: "notes", key: "m", argv: sleeper(0.5), spawn: spawn) == first)
        #expect(launched.count == 1)
        try finish(root, "notes", "m", pid: first)
        try ModelJobs.clear(root, kind: "notes", key: "m")
        #expect(try ModelJobs.read(root, kind: "notes", key: "m") == nil)
    }

    @Test func test_a_record_whose_pid_is_gone_is_stale() throws {
        let t = TempFolder("model-jobs")
        defer { t.remove() }
        let root = t.url.appendingPathComponent(".jobs")
        let gone = try spawnChild(["/usr/bin/true"], env: [:])
        #expect(gone.waitUntilExit(timeout: 10) != nil)
        try ModelJobs.write(root, PyDict<JSONValue>([("kind", .string("notes")), ("key", .string("m")),
                                                    ("pid", .int(Int(gone.pid))), ("state", .string("running")),
                                                    ("started", .int(0))]))
        let job = try #require(try ModelJobs.read(root, kind: "notes", key: "m"))
        #expect(job["stale"] == .bool(true))
        #expect(try ModelJobs.running(root).isEmpty)
        #expect(try ModelJobs.wait(root, kind: "notes", key: "m", timeout: 10)["stale"] == .bool(true))  // no hang
    }

    @Test func aHelperJustReapedIsDoneNotStale() throws {
        // The launcher reaps the helper, then writes its returncode: in between, the record says running with a pid
        // that is gone. The wait gives the launcher a moment before it calls the job stale.
        let t = TempFolder("model-jobs")
        defer { t.remove() }
        let root = t.url.appendingPathComponent(".jobs")
        func record(_ fields: [(String, JSONValue)]) throws {
            try ModelJobs.write(root, PyDict<JSONValue>([("kind", .string("projects")), ("key", .string("projects")),
                                                        ("pid", .int(999_999))] + fields))
        }
        try record([("state", .string("running"))])
        let launcher = Thread { usleep(100_000); try? record([("state", .string("done")), ("returncode", .int(0))]) }
        launcher.start()
        let job = try ModelJobs.wait(root, kind: "projects", key: "projects", poll: 0.02, alive: { _ in false }, timeout: 10)
        #expect(job["state"] == .string("done") && job["returncode"] == .int(0))
    }

    @Test func test_the_helper_runs_in_its_own_process_group_as_the_launchers_child() throws {
        let t = TempFolder("model-jobs")
        defer { t.remove() }
        let root = t.url.appendingPathComponent(".jobs")
        let pid = try ModelJobs.launch(root: root, kind: "notes", key: "m", argv: sleeper(1))
        defer { _ = try? finish(root, "notes", "m", pid: pid) }
        #expect(getpgid(pid) == pid)
        #expect(parentPid(pid) == getpid())
    }

    @Test func test_a_pending_undo_is_kept_until_finished() throws {
        let t = TempFolder("model-jobs")
        defer { t.remove() }
        let root = t.url.appendingPathComponent(".jobs")
        try ModelJobs.pendingUndo(root, token: "tok123", label: "sort projects")
        let pending = ModelJobs.pendingUndos(root)
        #expect(pending.count == 1)
        #expect(pending.first.map { PythonJSON.dumps($0.json) }
                == #"{"token": "tok123", "label": "sort projects", "owner": \#(getpid()), "state": "pending"}"#)
        try ModelJobs.finishUndo(root, token: "tok123", ok: true)
        #expect(ModelJobs.pendingUndos(root).isEmpty)
        let finished = try ModelJobs.finishedUndos(root)
        #expect(finished.map { PythonJSON.dumps($0.json) } == [#"{"token": "tok123", "label": "sort projects", "ok": true}"#])
        try ModelJobs.seen(root, token: "tok123")
        #expect(try ModelJobs.finishedUndos(root).isEmpty)
    }

    @Test func test_helper_argv_only_runs_notes_and_projects() throws {
        let t = TempFolder("model-jobs")
        defer { t.remove() }
        let out = t.url
        let folder = out.appendingPathComponent("2026-10-30T08-02-13").path
        let argv = try ModelJobs.helperArgv(kind: "notes", args: [folder, "--force"], cliOptions: ["--config", "/c.toml"],
                                            lm: "/lm", outputDir: out)
        #expect(Array(argv.suffix(6)) == ["--config", "/c.toml", "--no-notify", "notes", folder, "--force"])
        let taskpolicy = FileManager.default.fileExists(atPath: "/usr/sbin/taskpolicy") ? ["/usr/sbin/taskpolicy", "-c", "utility"] : []
        #expect(Array(argv.prefix(taskpolicy.count + 1)) == taskpolicy + ["/lm"])  // palaver-lm, no Python
        #expect(Array(try ModelJobs.helperArgv(kind: "projects", args: ["--no-wait", "suggest"], cliOptions: [],
                                               lm: "/lm", outputDir: out).suffix(3)) == ["projects", "--no-wait", "suggest"])
        #expect(Array(try ModelJobs.helperArgv(kind: "projects", args: ["--no-wait", "describe", "ab12"], cliOptions: [],
                                               lm: "/lm", outputDir: out).suffix(2)) == ["describe", "ab12"])
        for (kind, args) in [("notes", ["/etc", "--force"]), ("notes", [out.path + "/x/../../etc", "--force"]),
                             ("projects", ["--no-wait", "rm"]), ("run", [folder]),
                             ("projects", ["--no-wait", "describe", "../x"])] {
            #expect(throws: ModelJobsError.self) {
                try ModelJobs.helperArgv(kind: kind, args: args, cliOptions: [], lm: "/lm", outputDir: out)
            }
        }
    }

    @Test func test_what_a_failed_helper_printed_is_kept_and_says_why() throws {
        let t = TempFolder("model-jobs")
        defer { t.remove() }
        let root = t.url.appendingPathComponent(".jobs")
        let script = "echo 'Asking Gemma 4 12B on this Mac…'; echo 'error: the model is not downloaded'; exit 1"
        let pid = try ModelJobs.launch(root: root, kind: "projects", key: "projects", argv: ["/bin/sh", "-c", script])
        let job = try finish(root, "projects", "projects", pid: pid)
        #expect(job["returncode"] == .int(1))
        try ModelJobs.clear(root, kind: "projects", key: "projects")
        let log = try String(contentsOf: try ModelJobs.logPath(root, kind: "projects", key: "projects"), encoding: .utf8)
        #expect(log.contains("Asking Gemma"))
        #expect(try ModelJobs.lastError(root, kind: "projects", key: "projects") == "the model is not downloaded")
    }

    @Test func test_a_helper_that_crashed_is_said_by_its_exception() throws {
        let t = TempFolder("model-jobs")
        defer { t.remove() }
        let root = t.url.appendingPathComponent(".jobs")
        // What `python -c "raise MemoryError('out of memory')"` prints.
        let script = #"printf 'Traceback (most recent call last):\n  File "<string>", line 1, in <module>\nMemoryError: out of memory\n' >&2; exit 1"#
        let pid = try ModelJobs.launch(root: root, kind: "projects", key: "projects", argv: ["/bin/sh", "-c", script])
        try finish(root, "projects", "projects", pid: pid)
        #expect(try ModelJobs.lastError(root, kind: "projects", key: "projects") == "MemoryError: out of memory")
        #expect(try ModelJobs.lastError(root, kind: "notes", key: "nothing-ran") == nil)
    }

    // Not in Python's tests: the folder check resolves symlinks on both sides, and the error line is found by
    // `lower()` and `splitlines()`.
    @Test func aMeetingSeenThroughASymlinkIsInTheOutputFolder() throws {
        let t = TempFolder("model-jobs")
        defer { t.remove() }
        let real = t.url.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = t.url.appendingPathComponent("link")
        #expect(symlink(real.path, link.path) == 0)
        let folder = real.path + "/2026-10-30T08-02-13"
        #expect(try ModelJobs.helperArgv(kind: "notes", args: [folder, "--force"], cliOptions: [], lm: "/lm",
                                         outputDir: link).suffix(2) == [folder, "--force"])
        #expect(try ModelJobs.helperArgv(kind: "notes", args: [link.path + "/../real/./2026-10-30T08-02-13", "--force"],
                                         cliOptions: [], lm: "/lm", outputDir: real).count > 0)
        #expect(ModelJobs.resolve(link.path + "/missing/../x") == ModelJobs.resolve(real.path) + "/x")
    }

    @Test func theLastErrorLineIsFoundWhateverItsCaseAndLineEnds() throws {
        let t = TempFolder("model-jobs")
        defer { t.remove() }
        let root = t.url.appendingPathComponent(".jobs")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = try ModelJobs.logPath(root, kind: "notes", key: "m")
        try "ERROR: first\r\nnoise\u{2028}Error:   the disk is full  \r\n".write(to: log, atomically: false, encoding: .utf8)
        #expect(try ModelJobs.lastError(root, kind: "notes", key: "m") == "the disk is full")
        try "error:\n".write(to: log, atomically: false, encoding: .utf8)
        #expect(try ModelJobs.lastError(root, kind: "notes", key: "m") == nil)
        #expect(throws: ModelJobsError.self) { try ModelJobs.lastError(root, kind: "notes", key: ".hidden") }
    }

    /// Keys and tokens come from requests: none may name a file outside `.jobs` (or `.jobs/undo`), a hidden one, or
    /// one Python's fullmatch would refuse (81 characters, a trailing newline `$` would let through).
    static let badNames = ["../x", "a/b", ".hidden", String(repeating: "a", count: 81), "abc\n", "", "..", "a b", "ü"]

    @Test(arguments: badNames) func aBadKeyIsRefusedEverywhere(_ bad: String) throws {
        let t = TempFolder("model-jobs")
        defer { t.remove() }
        let root = t.url.appendingPathComponent(".jobs")
        let job = PyDict<JSONValue>([("kind", .string("notes")), ("key", .string(bad)), ("state", .string("running"))])
        #expect(throws: ModelJobsError.self) { try ModelJobs.write(root, job) }
        #expect(throws: ModelJobsError.self) { try ModelJobs.read(root, kind: "notes", key: bad) }
        #expect(throws: ModelJobsError.self) { try ModelJobs.clear(root, kind: "notes", key: bad) }
        #expect(throws: ModelJobsError.self) { try ModelJobs.logPath(root, kind: "notes", key: bad) }
        #expect(throws: ModelJobsError.self) { try ModelJobs.wait(root, kind: "notes", key: bad, timeout: 1) }
        var spawned = false
        #expect(throws: ModelJobsError.self) {
            try ModelJobs.launch(root: root, kind: "notes", key: bad, argv: sleeper(0)) { argv, output in
                spawned = true
                return try ModelJobs.spawnHelper(argv, output: output)
            }
        }
        #expect(!spawned, "a bad key started a helper")
        #expect(throws: ModelJobsError.self) { try ModelJobs.pendingUndo(root, token: bad, label: "sort") }
        #expect(throws: ModelJobsError.self) { try ModelJobs.finishUndo(root, token: bad, ok: true) }
        #expect(throws: ModelJobsError.self) { try ModelJobs.finishUndo(root, token: bad, ok: true, told: true) }
        #expect(throws: ModelJobsError.self) { try ModelJobs.seen(root, token: bad) }
        // Nothing was written anywhere: not in the temporary folder, not beside it.
        let left = FileManager.default.enumerator(atPath: t.url.path)?.allObjects as? [String] ?? []
        #expect(left.allSatisfy { $0 == ".jobs" || $0 == ".jobs/undo" }, "\(left)")
    }

    @Test func aGoodKeyAndTokenAtTheLimitsAreTaken() throws {
        let t = TempFolder("model-jobs")
        defer { t.remove() }
        let root = t.url.appendingPathComponent(".jobs")
        let longest = String(repeating: "a", count: 80)
        for key in [longest, "a.b-c_D9", "x..y"] {
            try ModelJobs.write(root, PyDict<JSONValue>([("kind", .string("projects")), ("key", .string(key)), ("state", .string("done"))]))
            #expect(try ModelJobs.read(root, kind: "projects", key: key)?["state"] == .string("done"))
            try ModelJobs.clear(root, kind: "projects", key: key)
            try ModelJobs.pendingUndo(root, token: key, label: "sort")
            try ModelJobs.finishUndo(root, token: key, ok: true)
            try ModelJobs.seen(root, token: key)
        }
        #expect(throws: ModelJobsError.self) { try ModelJobs.read(root, kind: "sort", key: "abc") }  // no such kind
    }
}
