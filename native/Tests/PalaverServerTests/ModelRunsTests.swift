// The language model's runs the window starts — a meeting's notes, sorting and describing projects — and the best
// next question (api.py `model_change`, `model_jobs_view`, `_finish_orphaned`, `next_question_*`; server.py `_model`,
// `_notes`, `_next_question`; webapp/__init__.py `build_app`'s `helper` and `ask_model`). Ports their tests of
// tests/test_webapp.py, test_webapp_remote.py, test_web_process.py, test_live_coach_api.py and test_coach_review.py
// under their names. Helpers are fakes: a `HelperRunner` in this process, or `/bin/sh` and `/bin/sleep` where a real
// process is wanted (its record, its exit code, its session) — never Python, never a model.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"
private let OTHER = "2026-10-22T10-00-00"
private let EARLIER = "2026-10-20T16-03-07"
private let BUSY = "the language model is busy; try again in a minute"

private extension JSONValue {
    subscript(i: Int) -> JSONValue? { arrayValue.flatMap { $0.indices.contains(i) ? $0[i] : nil } }
    var list: [JSONValue] { arrayValue ?? [] }
}

private func dumps(_ v: JSONValue?) -> String { v.map { PythonJSON.dumps($0, ensureAscii: false) } ?? "nil" }

/// `_post`: the status and the JSON answer.
private func post(_ s: TestServer, _ path: String, _ body: JSONValue = .object([])) -> (Int, JSONValue) {
    let r = s.post(path, body)
    return (r.status, r.json ?? .null)
}

/// `_snapshots`: the undo snapshots in the recordings' trash.
private func snapshots(_ out: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent(".trash/.undo").path)) ?? []
}

/// `_jobs`: GET /api/model-jobs.
private func jobs(_ s: TestServer) -> JSONValue { s.get("/api/model-jobs").json ?? .null }

private func running(_ s: TestServer) -> [String] {
    (jobs(s)["running"]?.list ?? []).map { "\($0["kind"]?.stringValue ?? "") \($0["key"]?.stringValue ?? "")" }
}

/// The stores TestServer gives a server in `dir` (its meetings are in `dir`/Meetings).
private func testStores(_ out: URL) -> StorePaths {
    let dir = out.deletingLastPathComponent()
    return StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                      home: dir.appendingPathComponent("home", isDirectory: true))
}

/// `palaver notes` / `projects` faked in this process (Python's `write_notes` / `run_projects` lambdas): each call
/// kept, its exit code from `body`.
final class FakeHelpers: HelperRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [(kind: String, key: String, args: [String])] = []
    private let body: (String, String, [String]) throws -> Int32?

    init(_ body: @escaping (String, String, [String]) throws -> Int32?) { self.body = body }

    func run(kind: String, key: String, args: [String]) throws -> Int32? {
        lock.withLock { asked.append((kind, key, args)) }
        return try body(kind, key, args)
    }

    var keys: [String] { lock.withLock { asked.map(\.key) } }
    var args: [[String]] { lock.withLock { asked.map(\.args) } }
}

/// `_sort`: the model puts the meeting in a new project "Hiring".
private func sort(_ s: TestServer) throws -> Int32? {
    let store = ProjectStore(path: s.app.stores.projects)
    try store.assign(MEETING, try store.create("Hiring"), by: "model", why: "the title")
    try store.save()
    return 0
}

/// `_model_server`: a server whose `run_projects` is `run(server, args)`.
private func modelServer(_ run: @escaping (TestServer, [String]) throws -> Int32?) throws -> TestServer {
    final class Ref: @unchecked Sendable { weak var server: TestServer? }
    let ref = Ref()
    let s = try TestServer(helpers: FakeHelpers { _, _, args in try run(ref.server!, args) }, meetings: { try pageMeeting($0) })
    ref.server = s
    return s
}

/// Collected from other threads.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

@Suite(.serialized) struct ModelRunsTests {
    // MARK: - notes (test_webapp.py)

    /// `_concurrent_notes`: a notes request for each of `ids`, 0.2 s apart, all held in the model until released.
    private func concurrentNotes(_ ids: [String], meetings: [String]) throws -> (calls: [String], peak: Int, results: [Int]) {
        let release = Latch()
        let lock = NSLock()
        var now = 0, peak = 0
        let helpers = FakeHelpers { _, _, _ in
            lock.withLock { now += 1; peak = max(peak, now) }
            if !release.opened { release.wait(5) }  // a Latch wakes one waiter
            lock.withLock { now -= 1 }
            return 0
        }
        let s = try TestServer(helpers: helpers, meetings: { out in for m in meetings { try pageMeeting(out, m) } })
        defer { s.stop() }
        let results = Box<Int>()
        for id in ids {
            Thread { results.append(s.post("/api/meetings/\(id)/notes").status) }.start()
            usleep(200_000)
        }
        release.open()
        #expect(until(10) { results.all.count == ids.count })
        return (helpers.keys, lock.withLock { peak }, results.all)
    }

    @Test func test_two_notes_requests_for_one_meeting_run_the_model_once() throws {
        let (calls, _, results) = try concurrentNotes([MEETING, MEETING], meetings: [MEETING])
        #expect(calls == [MEETING] && results == [200, 200])
    }

    @Test func test_notes_for_different_meetings_never_overlap() throws {
        let (calls, peak, results) = try concurrentNotes([MEETING, OTHER], meetings: [MEETING, OTHER])
        #expect(calls.sorted() == [MEETING, OTHER].sorted() && peak == 1 && results == [200, 200])
    }

    // MARK: - sorting and describing with the model (test_webapp.py)

    @Test func test_http_sorting_with_the_model_can_be_undone() throws {
        let s = try modelServer { s, _ in try sort(s) }
        defer { s.stop() }
        let (status, answer) = post(s, "/api/projects/suggest")
        #expect(status == 200 && answer["projects"]?.list.compactMap { $0["name"]?.stringValue } == ["Hiring"])
        #expect(post(s, "/api/undo", .object([("token", answer["undo"] ?? .null)])).0 == 200)
        #expect(s.get("/api/projects").json?["projects"] == .array([]))
    }

    @Test func test_http_describing_with_the_model_can_be_undone() throws {
        let s = try modelServer { s, args in
            let store = ProjectStore(path: s.app.stores.projects)
            try store.update(args[2], description: "Written by the model.")  // ["--no-wait", "describe", pid]
            try store.save()
            return 0
        }
        defer { s.stop() }
        let pid = post(s, "/api/projects", .object([("name", .string("Hiring"))])).1["projects"]?[0]?["id"]?.stringValue ?? ""
        let (status, answer) = post(s, "/api/projects/\(pid)/describe")
        #expect(status == 200 && answer["projects"]?[0]?["description"] == .string("Written by the model."))
        #expect(post(s, "/api/undo", .object([("token", answer["undo"] ?? .null)])).0 == 200)
        #expect(s.get("/api/projects").json?["projects"]?[0]?["description"] == .string(""))
    }

    @Test func test_http_a_failed_model_run_is_rolled_back() throws {
        let s = try modelServer { s, _ in _ = try sort(s); return 1 }  // changed some, then failed
        defer { s.stop() }
        #expect(post(s, "/api/projects/suggest").0 == 502)
        #expect(s.get("/api/projects").json?["projects"] == .array([]))
        #expect(snapshots(s.app.outputDir) == [])
    }

    @Test func test_http_sorting_while_the_model_is_busy_answers_409_before_any_snapshot() throws {
        let runs = Box<[String]>()
        let s = try modelServer { _, args in runs.append(args); return 0 }
        defer { s.stop() }
        // Another process using the language model: its flock on notes.lock (`_hold_model`).
        let lock = s.app.stores.notesLock
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let holder = open(lock.path, O_WRONLY | O_CREAT | O_APPEND, 0o666)
        #expect(holder >= 0 && flock(holder, LOCK_EX) == 0)
        defer { close(holder) }
        let before = try? Data(contentsOf: s.app.stores.projects)
        let (status, body) = post(s, "/api/projects/suggest")
        #expect(status == 409 && dumps(body).contains(BUSY))
        #expect(runs.all.isEmpty && snapshots(s.app.outputDir) == [])
        #expect((try? Data(contentsOf: s.app.stores.projects)) == before)
    }

    @Test func test_http_the_model_taken_after_the_check_answers_409_and_rolls_back() throws {
        let s = try modelServer { _, _ in throw ModelBusy() }
        defer { s.stop() }
        let (status, body) = post(s, "/api/projects/suggest")
        #expect(status == 409 && dumps(body).contains("the language model is busy"))
        #expect(snapshots(s.app.outputDir) == [])
    }

    @Test func test_http_sorting_with_a_free_model_still_remembers_an_undo() throws {
        let s = try modelServer { s, _ in try sort(s) }
        defer { s.stop() }
        let (status, answer) = post(s, "/api/projects/suggest")
        #expect(status == 200 && answer["undo"]?.stringValue?.isEmpty == false)
    }

    // MARK: - the model's jobs across a server restart (test_webapp_remote.py)

    @Test func test_http_a_notes_run_of_an_earlier_server_shows_and_is_not_started_again() throws {
        let written = FakeHelpers { _, _, _ in 0 }
        // The earlier server's run, still going: recorded by whoever started it.
        let s = try TestServer(helpers: written, meetings: { out in
            try pageMeeting(out)
            _ = try ModelJobs.launch(root: ModelJobs.root(out), kind: "notes", key: MEETING, argv: ["/bin/sleep", "1"])
        })
        defer { s.stop() }
        #expect(running(s) == ["notes \(MEETING)"])
        let (status, _) = post(s, "/api/meetings/\(MEETING)/notes")
        #expect(status == 200 && written.keys.isEmpty)  // it waited for that run
        #expect(running(s) == [])
        #expect(try ModelJobs.read(s.app.jobs, kind: "notes", key: MEETING) == nil)  // cleared once seen done
    }

    @Test func test_http_a_failed_notes_run_of_an_earlier_server_says_so() throws {
        let s = try TestServer(helpers: FakeHelpers { _, _, _ in 0 }, meetings: { out in
            try pageMeeting(out)
            _ = try ModelJobs.launch(root: ModelJobs.root(out), kind: "notes", key: MEETING,
                                     argv: ["/bin/sh", "-c", "sleep 0.5; exit 1"])
        })
        defer { s.stop() }
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/notes")
        #expect(status == 502 && (answer["error"]?.stringValue ?? "").contains("could not write"))
    }

    /// The earlier server took the snapshot and noted it, the app ran the sort to its end with `returncode`, then that
    /// server was gone; `change` is what the sort did. The token.
    private func orphanedSort(_ out: URL, returncode: Int, _ change: (ProjectStore) throws -> Void) throws -> String {
        let stores = testStores(out)
        try pageMeeting(out)
        let root = ModelJobs.root(out)
        let token = try Undo.take(out, "sort projects", stores: [stores.projects])
        try ModelJobs.pendingUndo(root, token: token, label: "Meetings sorted by the model", owner: 999999)
        try ModelJobs.write(root, ModelJobs.Job([("kind", .string("projects")), ("key", .string("projects")),
                                                 ("pid", .int(999999)), ("state", .string("done")),
                                                 ("returncode", .int(returncode)), ("started", .int(0))]))
        let store = ProjectStore(path: stores.projects)
        try change(store)
        try store.save()
        return token
    }

    @Test func test_http_a_sort_finished_after_a_restart_still_hands_its_undo_to_the_page() throws {
        var token = ""
        let s = try TestServer(helpers: FakeHelpers { _, _, _ in 0 }, meetings: { out in
            token = try orphanedSort(out, returncode: 0) { try $0.assign(MEETING, try $0.create("Hiring"), by: "model", why: "the title") }
        })
        defer { s.stop() }
        #expect(dumps(jobs(s)["finished"]) == dumps(.array([.object([("token", .string(token)),
                                                                       ("label", .string("Meetings sorted by the model")),
                                                                       ("ok", .bool(true))])])))
        #expect(post(s, "/api/model-jobs/seen", .object([("token", .string(token))])).0 == 200)
        #expect(jobs(s)["finished"] == .array([]))
        #expect(post(s, "/api/undo", .object([("token", .string(token))])).0 == 200)  // the undo works
        #expect(s.get("/api/projects").json?["projects"] == .array([]))
    }

    @Test func test_http_a_sort_that_failed_after_a_restart_is_rolled_back() throws {
        var token = ""
        let s = try TestServer(helpers: FakeHelpers { _, _, _ in 0 }, meetings: { out in
            token = try orphanedSort(out, returncode: 1) { try $0.create("Half done") }
        })
        defer { s.stop() }
        #expect(dumps(jobs(s)["finished"]) == dumps(.array([.object([("token", .string(token)),
                                                                       ("label", .string("Meetings sorted by the model")),
                                                                       ("ok", .bool(false))])])))
        #expect(s.get("/api/projects").json?["projects"] == .array([]))
    }

    @Test func test_http_a_sort_while_one_runs_is_refused() throws {
        let runs = FakeHelpers { _, _, _ in 0 }
        let s = try TestServer(helpers: runs, meetings: { out in
            try pageMeeting(out)
            _ = try ModelJobs.launch(root: ModelJobs.root(out), kind: "projects", key: "projects", argv: ["/bin/sleep", "2"])
        })
        defer {
            _ = try? ModelJobs.wait(s.app.jobs, kind: "projects", key: "projects", timeout: 5)  // its record written before the folder goes
            s.stop()
        }
        #expect(running(s) == ["projects projects"])
        #expect(post(s, "/api/projects/suggest").0 == 409 && runs.args.isEmpty)
    }

    // MARK: - who starts the helper (test_webapp_remote.py `build_app`)

    /// A recordings folder with MEETING and the app over it, its helpers `AppHelperRunner` with `recording`.
    private func helperApp(_ recording: FakeRecording, argv: AppHelperRunner.Argv? = nil) throws -> (URL, ServerApp) {
        let dir = tempFolder("helpers")
        let out = dir.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try pageMeeting(out)
        let helpers = argv.map { AppHelperRunner(outputDir: out, recording: recording, argv: $0) }
            ?? AppHelperRunner(outputDir: out, recording: recording, cliOptions: ["--config", "/c.toml"], lm: "palaver-lm")
        return (dir, ServerApp(outputDir: out, userName: "Timo", stores: testStores(out), recording: recording, helpers: helpers))
    }

    @Test func test_build_app_has_the_app_start_the_notes_helper() throws {
        let rec = FakeRecording()
        let asked = Box<[String]>()
        let (dir, app) = try helperApp(rec)
        defer { try? FileManager.default.removeItem(at: dir) }
        rec.onStartHelper = { kind, key, args in
            asked.append([kind, key] + args)
            return try ModelJobs.launch(root: app.jobs, kind: kind, key: key, argv: ["/bin/sh", "-c", "exit 0"])
        }
        #expect(try ModelRuns.writeNotes(app, id: MEETING))
        #expect(asked.all == [["notes", MEETING, app.outputDir.appendingPathComponent(MEETING).path, "--force"]])
        #expect(try ModelRuns.runProjects(app, args: ["suggest"]))
        #expect(asked.all.last == ["projects", "projects", "--no-wait", "suggest"])
    }

    @Test func test_build_app_runs_the_helper_itself_when_the_app_does_not_answer() throws {
        let rec = FakeRecording()
        rec.onStartHelper = { _, _, _ in throw AppCtlClient.CallFailed("gone") }
        let started = Box<[String]>()
        let (dir, app) = try helperApp(rec) { _, args in
            started.append(args)
            return ["/bin/sh", "-c", "exit 0"]
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try ModelRuns.writeNotes(app, id: MEETING))
        #expect(started.all == [[app.outputDir.appendingPathComponent(MEETING).path, "--force"]])
    }

    @Test func test_build_app_model_busy() throws {
        let rec = FakeRecording()
        let (dir, app) = try helperApp(rec)
        defer { try? FileManager.default.removeItem(at: dir) }
        rec.onStartHelper = { kind, key, _ in
            try ModelJobs.launch(root: app.jobs, kind: kind, key: key, argv: ["/bin/sh", "-c", "exit 75"])
        }
        #expect(throws: ModelBusy.self) { try ModelRuns.runProjects(app, args: ["suggest"]) }
    }

    // MARK: - restarts and long waits

    /// test_web_process.py: notes run in a helper the app starts (not the server's child): a restarted server shows
    /// the run, starts no second one, and answers when it is done. In this process the first server's wait can't be
    /// killed with it: it looks at the record only every 30 s, so it does not take part before the test is over.
    @Test func test_a_restart_while_notes_are_written_keeps_the_run() throws {
        let dir = tempFolder("restart")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try pageMeeting(out)
        let root = ModelJobs.root(out)
        let launched = Box<String>()
        let rec = FakeRecording()
        rec.onStartHelper = { kind, key, _ in
            launched.append(key)
            return try ModelJobs.launch(root: root, kind: kind, key: key, argv: ["/bin/sleep", "2"])
        }
        let gone = try TestServer(helpers: AppHelperRunner(outputDir: out, recording: rec, argv: { _, _ in [] }, poll: 30),
                                  recording: rec, dir: dir)
        let firstDone = DispatchSemaphore(value: 0)
        Thread { _ = gone.post("/api/meetings/\(MEETING)/notes"); firstDone.signal() }.start()  // the first server goes away while it waits
        #expect(until(10) { !((try? ModelJobs.running(root)) ?? []).isEmpty }, "no notes job started")
        let job = try ModelJobs.running(root).first
        #expect(job?["pid"].flatMap(ModelJobs.pid).map { parentPid(Int32($0)) } == getpid())  // the app's child

        gone.stop()
        #expect(gone.server.waitIdle(timeout: 1), "the restart waited for the notes")
        let s = try TestServer(helpers: AppHelperRunner(outputDir: out, recording: rec, argv: { _, _ in [] }),
                               recording: rec, dir: dir)
        defer { s.stop() }
        #expect(running(s) == ["notes \(MEETING)"])
        #expect(s.post("/api/meetings/\(MEETING)/notes").status == 200)
        #expect(launched.all.count == 1)  // waited for the running job: no second run
        #expect(try ModelJobs.running(root).isEmpty)
        // The first server's waiter looks at the record every 30 s: it may not outlive the folder it reads.
        _ = firstDone.wait(timeout: .now() + 1)
    }

    @Test func test_polling_answers_while_two_notes_runs_wait() throws {
        let release = Latch()
        let entered = Box<String>()
        let s = try TestServer(helpers: FakeHelpers { _, key, _ in
            entered.append(key)
            if !release.opened { release.wait(20) }  // a Latch wakes one waiter
            return 0
        }, meetings: { out in try pageMeeting(out); try pageMeeting(out, OTHER) })
        defer { s.stop() }
        let replies = Box<Int>()
        for id in [MEETING, OTHER] { Thread { replies.append(s.post("/api/meetings/\(id)/notes").status) }.start() }
        #expect(until(5) { entered.all.count == 1 })
        usleep(200_000)  // the other one waits for the model
        for path in ["/api/ping", "/api/meetings", "/api/model-jobs", "/api/meetings/\(MEETING)/next-question"] {
            #expect(s.get(path).status == 200, "\(path)")
        }
        #expect(replies.all.isEmpty)  // both still wait
        release.open()
        #expect(until(10) { replies.all.count == 2 } && replies.all == [200, 200])
        #expect(entered.all.count == 2)
    }

    @Test func test_a_rename_during_a_model_sort_survives() throws {
        let started = Latch(), renamed = Latch()
        final class Pid: @unchecked Sendable { var value = "" }
        let pid = Pid()
        let s = try modelServer { s, _ in
            started.open()
            renamed.wait(10)
            // `palaver projects suggest`: its own process writes the store under its lock, read again first.
            let store = ProjectStore(path: s.app.stores.projects)
            try store.locked {
                store.reload()
                try store.assign(MEETING, pid.value, by: "model", why: "the title")
                try store.save()
            }
            return 0
        }
        defer { s.stop() }
        pid.value = post(s, "/api/projects", .object([("name", .string("Hiring"))])).1["projects"]?[0]?["id"]?.stringValue ?? ""
        let sorted = Box<Int>()
        Thread { sorted.append(s.post("/api/projects/suggest").status) }.start()
        started.wait()
        let (status, answer) = post(s, "/api/projects/\(pid.value)", .object([("name", .string("Recruiting"))]))
        #expect(status == 200 && answer["projects"]?[0]?["name"] == .string("Recruiting"))
        renamed.open()
        #expect(until(10) { !sorted.all.isEmpty } && sorted.all == [200])
        let project = s.get("/api/projects").json?["projects"]?[0]
        #expect(project?["name"] == .string("Recruiting"))
        #expect(project?["meetings"]?.list.map { "\($0["id"]?.stringValue ?? "") \($0["by"]?.stringValue ?? "")" } == ["\(MEETING) model"])
    }
}

/// The parent of `pid` (`ps -o ppid= -p pid`).
private func parentPid(_ pid: Int32) -> Int32 {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return -1 }
    return info.kp_eproc.e_ppid
}

// MARK: - the best next question

private let COACH: JSONValue = .object([
    ("meeting", .string(MEETING)), ("talk", .object([("speaking", .string("me")), ("share", .double(0.62))])),
    ("text", .string("You 62 % of the last 10 min")),
    ("nudge", .object([("kind", .string("monologue")), ("text", .string("4-min monologue")), ("at", .double(610.0))])),
])
private let ANSWER: JSONValue = .object([
    ("questions", .array([.object([("question", .string("Who owns the salary band?")),
                                   ("why", .string("It was called fine, without an owner."))])])),
    ("engine", .string("Fake model")),
])

/// test_live_coach_api.py `_Model`: the language model's answer, or its error; each question kept.
private final class FakeModel: NextQuestionAsker, @unchecked Sendable {
    let answer: Result<JSONValue, Error>
    private let lock = NSLock()
    private var asked: [(String, JSONValue)] = []
    init(_ answer: Result<JSONValue, Error> = .success(ANSWER)) { self.answer = answer }
    func ask(meetingId: String, inputs: JSONValue) throws -> JSONValue {
        lock.withLock { asked.append((meetingId, inputs)) }
        return try answer.get()
    }
    var inputs: [(String, JSONValue)] { lock.withLock { asked } }
}

/// test_live_coach_api.py `_server`: the app with the live coach's recording, `model` and `free` GB free.
private func coachServer(_ model: FakeModel = FakeModel(), free: Double = 64.0, notes: Bool? = nil,
                         recording: Bool = false) throws -> TestServer {
    let rec = FakeRecording()
    rec.live = COACH
    let s = try TestServer(userName: "Timo", recording: rec, notesEnabled: notes, nextQuestion: model, freeMemoryGB: { free },
                           meetings: { try pageMeeting($0) })
    if recording { s.app.meetingStatus = { _ in "recording" } }  // Python's tests monkeypatch `api._status`
    return s
}

/// A recordings folder with MEETING and the app over it for "Timo" (no HTTP).
private final class Folder {
    let dir: URL
    let out: URL
    let app: ServerApp

    init(notes: Bool? = nil) throws {
        dir = tempFolder("next-question")
        out = dir.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        app = ServerApp(outputDir: out, userName: "Timo", stores: testStores(out), notesEnabled: notes)
        try pageMeeting(out)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func choose(_ engine: String) throws {
        try SettingsFile.update([("engines", .object([("coach", .string(engine))]))], stores: app.stores)
    }
}

@Suite(.serialized) struct NextQuestionTests {
    // MARK: test_live_coach_api.py

    @Test func test_http_best_next_question() throws {
        let model = FakeModel()
        let s = try coachServer(model)
        defer { s.stop() }
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/next-question")
        #expect(status == 200 && dumps(answer) == dumps(ANSWER))
        let (meeting, inputs) = try #require(model.inputs.first)
        #expect(meeting == MEETING)
        #expect(inputs["lines"]?.list.last?["text"] == .string("Thanks Rico, the salary band is fine."))
        #expect(inputs["user"] == .string("Timo") && inputs["now"] == .double(15.0))
    }

    @Test func test_the_local_model_does_not_start_without_its_memory_during_a_call() throws {
        let model = FakeModel()
        let s = try coachServer(model, free: 6.0, recording: true)
        defer { s.stop() }
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/next-question")
        #expect(status == 400)
        #expect(answer["error"] == .string("Not enough free memory for the local model during the call; choose a cloud model "
                                           + "in Settings → Language model, or ask after the call"))
        #expect(model.inputs.isEmpty)
    }

    @Test func test_a_cloud_model_needs_no_free_memory() throws {
        let model = FakeModel()
        let s = try coachServer(model, free: 1.0, recording: true)
        defer { s.stop() }
        try SettingsFile.update([("engines", .object([("coach", .string("anthropic"))]))], stores: s.app.stores)
        #expect(post(s, "/api/meetings/\(MEETING)/next-question").0 == 200 && !model.inputs.isEmpty)
    }

    /// A meeting kept on this Mac is never sent to a cloud model, whatever the coach's choice: the local model's memory
    /// check applies.
    @Test func test_keep_on_this_mac_keeps_it_local() throws {
        let f = try Folder()
        let folder = f.out.appendingPathComponent(MEETING, isDirectory: true)
        try LocalOnly.set(folder, on: true)
        try f.choose("claude-cli")
        #expect(ModelChoice.choiceFor(feature: "coach", folders: [folder], config: Config(), stores: f.app.stores) == "local")
        #expect(ModelChoice.memoryGB(feature: "coach", folder: folder, config: Config(), stores: f.app.stores) == 14.0)
    }

    @Test func test_a_model_that_fails_says_why() throws {
        let s = try coachServer(FakeModel(.failure(BadGateway("Anthropic API: the key was refused"))))
        defer { s.stop() }
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/next-question")
        #expect(status == 502 && answer["error"] == .string("Anthropic API: the key was refused"))
    }

    @Test func test_no_question_without_a_language_model() throws {
        let s = try coachServer(notes: false)
        defer { s.stop() }
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/next-question")
        #expect(status == 503 && (answer["error"]?.stringValue ?? "").contains("turned off"))
    }

    @Test func test_the_question_inputs_carry_the_prep() throws {
        let f = try Folder()
        let paths = RecordingPaths(f.out.appendingPathComponent(MEETING, isDirectory: true))
        try Data(#"[{"text": "ask about the budget", "at": null}, {"text": "", "at": 3}]"#.utf8)
            .write(to: paths.folder.appendingPathComponent("my-notes.json"))
        let at = try PyDateTime.parse("2026-10-27T16:00:00+01:00")
        try CalendarEvents.save(paths, CalendarEvent(title: "Hiring debrief", start: at, end: try! at.adding(seconds: 3600), attendees: [
            Attendee(name: "Timo", isSelf: true), Attendee(name: "Rico Lanza"), Attendee(name: "Valerie Vogel")]))
        let inputs = try NextQuestionAPI.inputs(f.app, id: MEETING, coach: .object([("quiet", .strings(["Valerie Vogel"]))]))
        #expect(inputs["title"] == .string("Hiring debrief"))
        #expect(inputs["invitees"] == .strings(["Rico Lanza", "Valerie Vogel"]))
        #expect(inputs["quiet"] == .strings(["Valerie Vogel"]))
        #expect(inputs["my_notes"] == .strings(["ask about the budget"]))
        #expect(inputs["last_time"] == .array([]))
    }

    @Test func test_the_app_asks_in_a_helper_process() throws {
        let f = try Folder()
        // `palaver-lm … next-question <folder>` faked by a shell script: it keeps its arguments and stdin, then
        // prints the answer and ends as told.
        let script = f.dir.appendingPathComponent("python")
        try Data("""
            #!/bin/sh
            echo "$@" > "\(f.dir.path)/argv"
            cat > "\(f.dir.path)/input"
            cat "\(f.dir.path)/answer"
            if [ "$(cat "\(f.dir.path)/end")" = term ]; then kill -TERM $$; fi
            exit "$(cat "\(f.dir.path)/end")"

            """.utf8).write(to: script)
        chmod(script.path, 0o755)
        func outcome(_ answer: String, _ end: String) throws {
            try Data(answer.utf8).write(to: f.dir.appendingPathComponent("answer"))
            try Data(end.utf8).write(to: f.dir.appendingPathComponent("end"))
        }
        let rec = FakeRecording()
        let ask = LMNextQuestion(outputDir: f.out, lm: script.path, cliOptions: ["--config", "/c.toml"], recording: rec,
                                     taskpolicy: f.dir.appendingPathComponent("no-taskpolicy").path)
        try outcome(PythonJSON.dumps(ANSWER) + "\n", "0")
        #expect(dumps(try ask.ask(meetingId: MEETING, inputs: .object([("lines", .array([]))]))) == dumps(ANSWER))
        let argv = try String(contentsOf: f.dir.appendingPathComponent("argv"), encoding: .utf8)
        #expect(argv == "--config /c.toml --no-notify next-question \(f.out.appendingPathComponent(MEETING).path)\n")  // palaver-lm's
        #expect(rec.watched.count == 1 && rec.watched.first?.folder.lastPathComponent == MEETING)  // the notes' memory budget (#49)
        #expect(rec.watched.first?.ownGroup == true)  // a session of its own
        #expect(PythonJSON.read(f.dir.appendingPathComponent("input")) == .object([("lines", .array([]))]))
        for (out, end, said) in [(PythonJSON.dumps(.object([("error", .string("Anthropic API: no key"))])), "1", "Anthropic API: no key"),
                                 ("", "term", "The local model was stopped: the Mac ran low on memory.")] {
            try outcome(out, end)
            #expect(throws: BadGateway.self) { _ = try ask.ask(meetingId: MEETING, inputs: .object([])) }
            do {
                _ = try ask.ask(meetingId: MEETING, inputs: .object([]))
            } catch let e as BadGateway {
                #expect(e.text == said)
            }
        }
        #expect(FreeMemory.availableGB() > 0)
    }

    /// `communicate(timeout=…)` covers the reads and the exit: a helper that closed its output but keeps running, and
    /// one whose grandchild still holds stdout, both end with the "took more than 10 minutes" error, in time, with the
    /// helper's whole group gone and nothing left to reap.
    @Test(arguments: [
        "exec 1>&- 2>&-; sleep 30",  // closed stdio, still running
        "sleep 30 & sleep 30",       // a grandchild holds stdout
    ]) func test_a_helper_past_the_budget_is_killed_with_its_group(body: String) throws {
        let f = try Folder()
        let script = f.dir.appendingPathComponent("python")
        let pidFile = f.dir.appendingPathComponent("pid")
        try Data("#!/bin/sh\necho $$ > \"\(pidFile.path)\"\n\(body)\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        let recording = FakeRecording()
        // A budget the script's first line fits in even when every suite runs at once (0.4 s did not).
        let ask = LMNextQuestion(outputDir: f.out, lm: script.path, cliOptions: [], recording: recording,
                                     taskpolicy: f.dir.appendingPathComponent("no-taskpolicy").path, timeout: 3)
        let started = Date()
        do {
            _ = try ask.ask(meetingId: MEETING, inputs: .object([]))
            Issue.record("no error")
        } catch let e as BadGateway {
            #expect(e.text == LMNextQuestion.TOO_LONG)
        }
        #expect(Date().timeIntervalSince(started) < 10)
        // The pid as spawned (the app is told to watch it); the script's own echo agrees once it ran.
        let pid = try #require(recording.watched.first?.pid)
        if let written = try? String(contentsOf: pidFile, encoding: .utf8) { #expect(Int32(Py.strip(written)) == pid) }
        // A group with a member left (a zombie leader too) can still be signalled; this one is gone.
        #expect(until(2) { killpg(pid, 0) != 0 && errno == ESRCH }, "the helper's group is still there")
    }

    @Test func test_http_the_button_says_which_model() throws {
        let s = try coachServer()
        defer { s.stop() }
        let r = s.get("/api/meetings/\(MEETING)/next-question")
        #expect(r.status == 200 && r.json?["label"] == .string("Best next question (Gemma, on this Mac)"))
    }

    @Test func test_the_local_model_during_a_call_needs_a_second_click() throws {
        let model = FakeModel()
        let s = try coachServer(model, recording: true)
        defer { s.stop() }
        var (status, answer) = post(s, "/api/meetings/\(MEETING)/next-question")
        #expect(status == 409 && (answer["error"]?.stringValue ?? "").hasPrefix("Runs Gemma on this Mac during the call"))
        #expect(model.inputs.isEmpty)
        (status, answer) = post(s, "/api/meetings/\(MEETING)/next-question", .object([("confirmed", .bool(true))]))
        #expect(status == 200 && !model.inputs.isEmpty)
    }

    @Test func test_no_helper_without_a_model_chosen() throws {
        let model = FakeModel()
        let s = try coachServer(model)
        defer { s.stop() }
        try SettingsFile.update([("engines", .object([("coach", .string(ModelChoice.PENDING))]))], stores: s.app.stores)
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/next-question", .object([("confirmed", .bool(true))]))
        #expect(status == 400 && (answer["error"]?.stringValue ?? "").contains("No model yet") && model.inputs.isEmpty)
    }

    // MARK: test_coach_review.py

    /// `_earlier` and `_last_time`: an earlier meeting with the same people (kept on this Mac or not), which prep.context
    /// finds for the event the meeting has.
    private func lastTime(_ f: Folder, localOnly: Bool) throws -> JSONValue {
        let paths = try pageMeeting(f.out, EARLIER)
        if localOnly { try LocalOnly.set(paths.folder, on: true) }
        let at = try PyDateTime.parse("2026-10-27T16:00:00+01:00")
        let event = CalendarEvent(title: "Hiring", start: at, end: at)
        let earlier: JSONValue = .object([
            ("id", .string(EARLIER)), ("title", .string("Hiring")), ("start", .string("2026-10-20T16:03:07+01:00")),
            ("why", .string("same people")), ("summary", .string("SECRET kept on this Mac")),
            ("next_steps", .array([.object([("task", .string("Check the band")), ("owner", .string("Rico"))])])),
        ])
        return try NextQuestionAPI.inputs(f.app, id: MEETING, coach: nil, context: { _ in [earlier] }, eventOf: { _ in event })
    }

    @Test func test_a_cloud_engine_never_gets_a_meeting_kept_on_this_mac() throws {
        let f = try Folder()
        try f.choose("anthropic")
        let inputs = try lastTime(f, localOnly: true)
        #expect(inputs["last_time"] == .array([]))
        #expect(!dumps(inputs).contains("SECRET"))
        #expect(inputs["meetings"] == .strings([MEETING]))
    }

    @Test func test_the_local_engine_may_read_it() throws {
        let f = try Folder()
        let inputs = try lastTime(f, localOnly: true)
        #expect(inputs["last_time"]?.list.map { $0["id"] } == [.string(EARLIER)])
        #expect(inputs["meetings"] == .strings([MEETING, EARLIER]))
    }

    @Test func test_a_meeting_not_kept_here_goes_to_the_cloud_with_its_name_in_the_log() throws {
        let f = try Folder()
        try f.choose("anthropic")
        let inputs = try lastTime(f, localOnly: false)
        #expect(inputs["meetings"] == .strings([MEETING, EARLIER]))
    }

    @Test func test_the_button_names_the_model_and_where_it_runs() throws {
        let f = try Folder()
        #expect(dumps(try NextQuestionAPI.info(f.app, id: MEETING)) == dumps(.object([
            ("ready", .bool(true)), ("reason", .null), ("label", .string("Best next question (Gemma, on this Mac)")),
            ("local", .bool(true)), ("warning", .null)])))
        f.app.meetingStatus = { _ in "recording" }
        #expect(try NextQuestionAPI.info(f.app, id: MEETING)["warning"]
                == .string("Runs Gemma on this Mac during the call (about 10 GB, may slow the call)"))
        try f.choose("anthropic")
        let info = try NextQuestionAPI.info(f.app, id: MEETING)
        #expect(info["label"] == .string("Best next question (Claude Opus 5.5, cloud)") && info["warning"] == .null)
    }

    @Test func test_the_button_is_off_with_the_reason() throws {
        let without = try Folder(notes: false)
        let off = try NextQuestionAPI.info(without.app, id: MEETING)
        #expect(off["ready"] == .bool(false) && off["reason"] == .string("Notes are turned off, and with them the language model."))
        let f = try Folder()
        try f.choose(ModelChoice.PENDING)
        let pending = try NextQuestionAPI.info(f.app, id: MEETING)
        #expect(pending["ready"] == .bool(false))
        #expect(pending["reason"] == .string("No model yet: choose one for Best next question in Settings → Language model."))
    }

    @Test func test_model_names() {
        #expect(NextQuestionAPI.modelName("claude-opus-5-5") == "Claude Opus 5.5")
        #expect(NextQuestionAPI.modelName("claude-sonnet-4-5-20250929") == "Claude Sonnet 4.5")
        #expect(NextQuestionAPI.modelName("sonnet") == "Claude Sonnet")
        #expect(NextQuestionAPI.modelName("gpt-5") == "gpt-5")
    }
}
