// The language model's runs the window starts (#57): a meeting's notes (`palaver-lm notes`), sorting meetings into
// projects and describing a project (`palaver-lm projects`), and the page's view of them (api.py `model_change`,
// `model_jobs_view`, `_finish_orphaned`; server.py `_model`, `_notes` and the model-jobs branches; webapp/__init__.py
// `write_notes`, `run_projects`; cli.py `notes_lock_free`).
//
// One language model at a time: `app.notesLock` in this process, notes.lock (a flock) across processes, and a projects
// run recorded in `.jobs/` by an earlier server. A run is the app's (its helper outlives this server), so a request
// that waits for it leaves the drain (`inflight.detached`) and a restarted server waits for the job it finds instead of
// starting a second one. A sort is undoable: its snapshot is noted in `.jobs/undo/` while it runs, so a server started
// after this one finishes it (`finishOrphaned`).
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

/// The notes runs this server waits for, by meeting (`App.notes_jobs`, `notes_jobs_lock`): the first request for a
/// meeting leads, the others wait for it and share its result.
public final class NotesJobs: @unchecked Sendable {
    final class Job: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var ok = false
    }

    let lock = NSLock()
    var running: [ScalarKey: Job] = [:]

    public init() {}
}

public enum ModelRuns {
    static let OFF = "the language model is turned off"
    static let NOTES_OFF = "notes are turned off"
    static let NOTES_FAILED = "The language model could not write the notes; see the log"
    static let logger = "palaver.webapp.server"

    /// What `except (KeyError, ValueError)` turns into a 400 among model_jobs.py's errors (a token that is none).
    static func python<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let e as ModelJobsError {
            throw BadRequest(e.description)
        }
    }

    // MARK: - one language model at a time

    /// `notes_lock_free`: whether no process uses the language model right now (notes.lock is free).
    public static func notesLockFree(stores: StorePaths = .current()) throws -> Bool {
        let lock = stores.notesLock
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lock.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        flock(fd, LOCK_UN)
        return true
    }

    // MARK: - the helpers

    /// `write_notes`: `palaver-lm notes <folder> --force`; whether it worked.
    public static func writeNotes(_ app: ServerApp, id: String) throws -> Bool {
        let folder = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id).folder.path
        return try app.helpers.run(kind: "notes", key: id, args: [folder, "--force"]) == 0
    }

    /// `run_projects`: `palaver-lm projects --no-wait <args>`; whether it worked. `ModelBusy` when the model was taken.
    public static func runProjects(_ app: ServerApp, args: [String]) throws -> Bool {
        try app.helpers.run(kind: "projects", key: "projects", args: ["--no-wait"] + args) == 0
    }

    // MARK: - a change the model makes

    private struct ModelFailed: Error {}

    /// `model_change`: the model changes the projects (sorts meetings, describes a project); `run()` says whether it
    /// worked. The undo token, or nil when it failed (what it changed by then is rolled back). The snapshot is noted in
    /// `.jobs/undo/` while the run goes on, so a server started after this one finishes it.
    public static func modelChange(_ app: ServerApp, label: String, pageLabel: String? = nil,
                                   _ run: () throws -> Bool) throws -> String? {
        var taken: String?
        let token: String
        do {
            token = try ChangesAPI.undoToken(app, label: label, stores: ProjectsAPI.projectsStore(app)) { token in
                taken = token
                try ModelJobs.pendingUndo(app.jobs, token: token, label: pageLabel ?? label)
                if !(try run()) { throw ModelFailed() }
            }
        } catch is ModelFailed {
            try ModelJobs.finishUndo(app.jobs, token: taken!, ok: false, told: true)
            return nil
        } catch {
            if let taken { try ModelJobs.finishUndo(app.jobs, token: taken, ok: false, told: true) }
            throw error
        }
        try ModelJobs.finishUndo(app.jobs, token: token, ok: true, told: true)
        return token
    }

    /// `_model`: `palaver projects <args>`, undoable (`label`); the undo token. `pageLabel` (the body's "label"): what
    /// the page calls the change, for its undo when this server is gone by the time the run ends. Unavailable when the
    /// model is off, ModelBusy while it is in use (nothing changed), BadGateway with the helper's last error line when
    /// it failed (rolled back).
    public static func model(_ app: ServerApp, args: [String], label: String, pageLabel: JSONValue?) throws -> String {
        guard app.notesEnabled else { throw Unavailable(OFF) }
        let running = try python { try ModelJobs.running(app.jobs) }
        if try running.contains(where: { Py.same(Py.str(try ChangesAPI.item($0.json, "kind")), "projects") }) {
            throw ModelBusy()  // an earlier server's run
        }
        guard app.notesLock.try() else { throw ModelBusy() }
        let token: String?
        do {
            defer { app.notesLock.unlock() }
            // Not while the daemon holds the model: the snapshot would be stale by the time the run got its turn.
            guard try notesLockFree(stores: app.stores) else { throw ModelBusy() }
            let page = pageLabel.flatMap { $0.truthy ? Py.str($0) : nil } ?? label
            token = try app.inflight.detached {  // the run is the app's: a restart need not wait for it
                try modelChange(app, label: label, pageLabel: page) { try runProjects(app, args: args) }
            }
        }
        guard let token else {
            let why = try python { try ModelJobs.lastError(app.jobs, kind: "projects", key: "projects") }
            app.log?.message("the projects helper failed: \(why ?? "no error line in its log")", level: "WARNING",
                             logger: logger)
            throw BadGateway(why.map { "the language model failed: \($0)" } ?? "the language model failed; see the log")
        }
        return token
    }

    // MARK: - the page's view of the jobs

    /// `model_jobs_view`: the jobs running (the page shows them, also after the server was restarted) and the model
    /// changes finished after the server that started them was gone, with their undo.
    public static func modelJobsView(_ app: ServerApp) throws -> JSONValue {
        try finishOrphaned(app)
        let running = try ModelJobs.running(app.jobs).map { j -> JSONValue in
            .object([("kind", try ChangesAPI.item(j.json, "kind")), ("key", try ChangesAPI.item(j.json, "key")),
                     ("started", j["started"] ?? .null)])
        }
        return .object([("running", .array(running)), ("finished", .array(try ModelJobs.finishedUndos(app.jobs).map(\.json)))])
    }

    /// `_finish_orphaned`: a sort whose server is gone is sealed once its run ended well (or it is not known how it
    /// ended), rolled back when it failed.
    static func finishOrphaned(_ app: ServerApp) throws {
        for pending in ModelJobs.pendingUndos(app.jobs) {
            let owner = pending["owner"] ?? .null
            if PythonJSON.equal(owner, .int(Int(getpid()))) || (ModelJobs.pid(owner).map(ModelJobs.pidAlive) ?? false) {
                continue  // its server waits for it
            }
            let run = try ModelJobs.read(app.jobs, kind: "projects", key: "projects")
            if let run, !run.isEmpty, run["state"].map({ PythonJSON.equal($0, .string("running")) }) ?? false,
               !(run["stale"]?.truthy ?? false) {
                continue
            }
            // `run is None or run.get("stale") or run.get("returncode") == 0`
            var ok = run == nil || (run?["stale"]?.truthy ?? false)
                || (run?["returncode"].map { PythonJSON.equal($0, .int(0)) } ?? false)
            let given = try ChangesAPI.item(pending.json, "token")
            guard case .string(let token) = given else {  // `re.fullmatch` of a token that is no text
                throw PyBody.TypeError(description: "expected string or bytes-like object, got '\(PyBody.typeName(given))'")
            }
            app.projectsLock.withLock {
                do {
                    if ok {
                        try Undo.sealed(app.outputDir, token)
                    } else {
                        _ = try app.changeOps.restore(app.outputDir, token, false)
                    }
                } catch {
                    app.log?.message("finishing the model's change \(token) failed: \(error)", level: "ERROR",
                                     logger: "palaver.webapp.api")
                    ok = false
                }
            }
            try ModelJobs.finishUndo(app.jobs, token: token, ok: ok)
            try ModelJobs.clear(app.jobs, kind: "projects", key: "projects")
        }
    }

    // MARK: - a meeting's notes

    /// `_notes`: the meeting's notes written again by the model; the meeting as it is then. One notes run at a time
    /// (each starts a large local model): a second request for the same meeting waits for the running one and shares
    /// its result; one for another meeting waits its turn. A run an earlier server started is waited for, never started
    /// again.
    public static func notes(_ app: ServerApp, id: String) throws -> JSONValue {
        _ = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        guard app.notesEnabled else { throw Unavailable(NOTES_OFF) }
        let jobs = app.notesJobs
        let (job, leader): (NotesJobs.Job, Bool) = jobs.lock.withLock {
            if let job = jobs.running[ScalarKey(id)] { return (job, false) }
            let job = NotesJobs.Job()
            jobs.running[ScalarKey(id)] = job
            return (job, true)
        }
        try app.inflight.detached {  // the run is the app's: a restart need not wait for it
            guard leader else {
                job.done.wait()
                job.done.signal()  // for the next follower (`Event.set` stays set)
                return
            }
            defer {
                jobs.lock.withLock { jobs.running[ScalarKey(id)] = nil }
                job.done.signal()
            }
            let earlier = try python { try ModelJobs.read(app.jobs, kind: "notes", key: id) }
            if let earlier, earlier["state"].map({ PythonJSON.equal($0, .string("running")) }) ?? false,
               !(earlier["stale"]?.truthy ?? false) {
                let done = try ModelJobs.wait(app.jobs, kind: "notes", key: id)
                try ModelJobs.clear(app.jobs, kind: "notes", key: id)
                job.ok = done["returncode"].map { PythonJSON.equal($0, .int(0)) } ?? false
            } else {
                try app.notesLock.withLock { job.ok = try writeNotes(app, id: id) }
            }
        }
        guard job.ok else { throw BadGateway(NOTES_FAILED) }
        return try MeetingsAPI.getMeeting(app: app, id: id)
    }
}

extension Router {
    /// The language model's jobs and a meeting's notes (server.py's branches for them).
    static func addModelRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/model-jobs") { _, _ in .json(try ModelRuns.modelJobsView(app)) }
        r.post("/api/model-jobs/seen") { req, _ in
            try ModelRuns.python {
                try ModelJobs.seen(app.jobs, token: Py.str(try PyBody.required(req.json, "token")))
                return .json(try ModelRuns.modelJobsView(app))
            }
        }
        r.post("/api/meetings/([^/]+)/notes") { _, m in .json(try ModelRuns.notes(app, id: m.group(1)!)) }
    }
}
