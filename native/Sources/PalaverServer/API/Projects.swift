// The Projects page and a meeting's projects (api.py `list_projects`, `create_project`, `update_project`,
// `merge_projects`, `delete_project`, `set_meeting_project`; server.py's `_projects_post` and the GET and POST
// branches for them). The language model's sorting and describing are ModelRuns.swift's.
//
// Every change holds `app.projectsLock` as api.py holds `_PROJECTS_LOCK`: the store is read, checked and changed under
// it, and a change that can be undone takes its snapshot and rolls back inside it (`ChangesAPI.undoable` with the lock
// already held). projects.json is read without its file lock and written under it (`ProjectStore.save`), as Python's.
import Foundation
import PalaverCore
import PalaverDomain

public enum ProjectsAPI {
    static let NEEDS_A_NAME = "a project or a name is needed"

    /// What `except (KeyError, ValueError)` turns into a 400 among the store's errors: a project without a name, a
    /// name taken already, a project merged into itself.
    static func python<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let e as ProjectValueError {
            throw BadRequest(e.description)
        }
    }

    static func store(_ app: ServerApp) -> ProjectStore { ProjectStore(path: app.stores.projects) }

    /// `_store_paths("projects")`.
    static func projectsStore(_ app: ServerApp) -> [URL] { ChangesAPI.storePaths(app, "projects") }

    /// `value or ""` of a value Python sorts by as text.
    private static func text(_ value: JSONValue?) -> String {
        guard let value, value.truthy else { return "" }
        return value.stringValue ?? Py.str(value)
    }

    // MARK: - the page

    /// `list_projects`: every project with its meetings and people, most recent first, and the meetings in no
    /// project yet, with suggestions.
    public static func listProjects(_ app: ServerApp) throws -> JSONValue {
        let store = store(app)
        var meetings = PyDict<JSONValue>()
        for m in try MeetingsAPI.listMeetings(app: app) {
            meetings[Py.str(try MeetingsAPI.key(m, "id"))] = m
        }
        let every = try ProjectRules.allFacts(outputDir: app.outputDir, userName: app.userName, stores: app.stores)
        let similarity = Similarity(every)
        var out: [PyDict<JSONValue>] = []
        for (pid, p) in store.projects {
            var members: [PyDict<JSONValue>] = []
            for (mid, how) in store.meetingsOf(pid) {
                guard let m = meetings[mid] else { continue }
                var member = PyDict<JSONValue>([("id", .string(mid))])
                for k in ["title", "start", "duration", "summary", "people"] { member[k] = try MeetingsAPI.key(m, k) }
                guard case .object(let fields) = how else {
                    throw PageError("'\(PyBody.typeName(how))' object is not a mapping")
                }
                for (k, v) in fields { member[k] = v }
                members.append(member)
            }
            // `members.sort(key=lambda m: m["id"], reverse=True)`: the ids are the dict's keys, never equal.
            members = Py.stableSorted(members) { Py.less(text($1["id"]), text($0["id"])) }
            var counts = PyDict<Int>()
            for m in members {
                for name in try MeetingsAPI.iterate(try MeetingsAPI.key(meetings[text(m["id"])]!, "people")) {
                    let n = Py.str(name)
                    counts[n] = (counts[n] ?? 0) + 1
                }
            }
            let people = Py.stableSorted(counts.keys) { a, b in
                counts[a]! != counts[b]! ? counts[a]! > counts[b]! : Py.less(Py.casefold(a), Py.casefold(b))
            }.prefix(8)
            var row = PyDict<JSONValue>([("id", .string(pid))])
            guard case .object(let fields) = p else { throw PageError("'\(PyBody.typeName(p))' object is not a mapping") }
            for (k, v) in fields { row[k] = v }
            row["meetings"] = .array(members.map(\.json))
            row["people"] = .strings(Array(people))
            row["latest"] = members.first?["start"] ?? .null
            out.append(row)
        }
        // `out.sort(key=lambda p: p["latest"] or "", reverse=True)`: stable, as Python's reverse sort is.
        out = Py.stableSorted(out) { Py.less(text($1["latest"]), text($0["latest"])) }
        var unsorted: [JSONValue] = []
        for (_, m) in meetings {
            let id = Py.str(try MeetingsAPI.key(m, "id"))
            guard every[id] != nil, !(try MeetingsAPI.key(m, "projects")).truthy else { continue }
            unsorted.append(.object([("id", .string(id)), ("title", try MeetingsAPI.key(m, "title")),
                                     ("start", try MeetingsAPI.key(m, "start")), ("duration", try MeetingsAPI.key(m, "duration")),
                                     ("suggestions", .array(ProjectRules.suggestions(id, store: store, every: every,
                                                                                     similarity: similarity)))]))
        }
        return .object([("projects", .array(out.map(\.json))), ("unsorted", .array(unsorted))])
    }

    // MARK: - changes

    /// `create_project`: the new project's id (or the one called so already).
    @discardableResult
    public static func createProject(_ app: ServerApp, name: String, description: String = "") throws -> String {
        try app.projectsLock.withLock {
            let store = store(app)
            let pid = try python { try store.create(name, description: description) }
            try store.save()
            return pid
        }
    }

    /// `update_project`: a project's name or description; the undo token.
    @discardableResult
    public static func updateProject(_ app: ServerApp, id pid: String, name: String? = nil,
                                     description: String? = nil) throws -> String {
        try app.projectsLock.withLock {
            let store = store(app)
            guard store.projects[pid] != nil else { throw NotFound(pid) }
            return try ChangesAPI.undoToken(app, label: "project", stores: projectsStore(app)) { _ in
                try python { try store.update(pid, name: name, description: description) }
                try store.save()
            }
        }
    }

    /// `merge_projects`: the undo token.
    @discardableResult
    public static func mergeProjects(_ app: ServerApp, id pid: String, into: String) throws -> String {
        try app.projectsLock.withLock {
            let store = store(app)
            guard store.projects[pid] != nil, store.projects[into] != nil else {
                throw NotFound(store.projects[pid] == nil ? pid : into)
            }
            return try ChangesAPI.undoToken(app, label: "merge projects", stores: projectsStore(app)) { _ in
                try python { try store.merge(pid, into: into) }
                try store.save()
            }
        }
    }

    /// `delete_project`: the undo token.
    @discardableResult
    public static func deleteProject(_ app: ServerApp, id pid: String) throws -> String {
        try app.projectsLock.withLock {
            let store = store(app)
            guard store.projects[pid] != nil else { throw NotFound(pid) }
            return try ChangesAPI.undoToken(app, label: "delete project", stores: projectsStore(app)) { _ in
                try store.delete(pid)
                try store.save()
            }
        }
    }

    /// `set_meeting_project`: put a meeting in a project (by id, or by name — a new name makes a new project), confirm
    /// a suggested one, or take it out. The undo token: the store as it was (an inverse call would leave the project
    /// rejected, confirmed, or made).
    @discardableResult
    public static func setMeetingProject(_ app: ServerApp, id meeting: String, project: String? = nil, name: String? = nil,
                                         remove: Bool = false) throws -> String {
        _ = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: meeting)
        return try app.projectsLock.withLock {
            let store = store(app)
            if let project {
                guard store.projects[project] != nil else { throw NotFound(project) }
            } else if Py.strip(name ?? "").isEmpty {
                throw BadRequest(NEEDS_A_NAME)
            }
            return try ChangesAPI.undoToken(app, label: "project", stores: projectsStore(app)) { _ in
                var pid = project ?? ""
                if project == nil {
                    pid = store.find(name!) ?? ""
                    if pid.isEmpty { pid = try python { try store.create(name!) } }
                }
                if remove {
                    store.unassign(meeting, pid)
                } else {
                    try store.assign(meeting, pid, why: "")
                }
                try store.save()
            }
        }
    }
}

extension Router {
    /// The Projects page and a meeting's projects (server.py's GET and POST branches; `_projects_post`'s order, the
    /// language model's two in it).
    static func addProjectRoutes(_ r: Router, app: ServerApp) {
        /// `None if v is None else str(v)` of `body.get(key)`.
        func optionalText(_ body: JSONValue, _ key: String) throws -> String? {
            try PyBody.get(body, key).flatMap { $0 == .null ? nil : Py.str($0) }
        }
        /// Every change on the Projects page answers with all projects, and its undo when it has one.
        func projects(_ token: String?) throws -> Response {
            let answer = try ProjectsAPI.listProjects(app)
            return .json(token.map { answer.adding("undo", .string($0)) } ?? answer)
        }
        r.get("/api/projects") { _, _ in .json(try ProjectsAPI.listProjects(app)) }

        r.post("/api/meetings/([^/]+)/projects") { req, m in
            let id = m.group(1)!
            let token = try ProjectsAPI.setMeetingProject(app, id: id, project: try optionalText(req.json, "project"),
                                                          name: try optionalText(req.json, "name"),
                                                          remove: try PyBody.get(req.json, "remove")?.truthy ?? false)
            return .json(try MeetingsAPI.getMeeting(app: app, id: id, calendar: false).adding("undo", .string(token)))
        }
        r.post("/api/projects") { req, _ in
            let description = try PyBody.get(req.json, "description").map(Py.str) ?? ""
            try ProjectsAPI.createProject(app, name: Py.str(try PyBody.required(req.json, "name")), description: description)
            return try projects(nil)
        }
        r.post("/api/projects/suggest") { req, _ in
            try projects(try ModelRuns.model(app, args: ["suggest"], label: "sort projects",
                                             pageLabel: try PyBody.get(req.json, "label")))
        }
        r.post("/api/projects/([0-9a-f]+)") { req, m in
            try projects(try ProjectsAPI.updateProject(app, id: m.group(1)!, name: try optionalText(req.json, "name"),
                                                       description: try optionalText(req.json, "description")))
        }
        r.post("/api/projects/([0-9a-f]+)/merge") { req, m in
            try projects(try ProjectsAPI.mergeProjects(app, id: m.group(1)!, into: Py.str(try PyBody.required(req.json, "into"))))
        }
        r.post("/api/projects/([0-9a-f]+)/delete") { _, m in
            try projects(try ProjectsAPI.deleteProject(app, id: m.group(1)!))
        }
        r.post("/api/projects/([0-9a-f]+)/describe") { req, m in
            try projects(try ModelRuns.model(app, args: ["describe", m.group(1)!], label: "describe project",
                                             pageLabel: try PyBody.get(req.json, "label")))
        }
    }
}
