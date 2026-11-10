// Meeting prep (#31): the meetings still to come, from the calendar, with the projects chosen for them, and one of
// them with its invitees, suggestions and the meetings that lead up to it (api.py `_upcoming_entry`, `upcoming`,
// `_event`, `upcoming_meeting`, `set_upcoming_project`; server.py's branches for them). Without a calendar there are
// none.
import Foundation
import PalaverCore
import PalaverDomain

public enum UpcomingAPI {
    /// `datetime.now().astimezone()`.
    static func now() -> PyDateTime {
        let date = Date()
        return PyDateTime(date, offset: TimeZone.current.secondsFromGMT(for: date))
    }

    /// `_upcoming_entry`.
    static func entry(_ event: CalendarEvent, _ store: ProjectStore, _ app: ServerApp) throws -> PyDict<JSONValue> {
        let named = store.projects
        let projects = try Prep.chosen(event, stores: app.stores).compactMap { pid -> JSONValue? in
            guard let p = named[pid] else { return nil }
            return .object([("id", .string(pid)), ("name", try MeetingsAPI.key(p, "name"))])
        }
        return PyDict([("key", .string(event.key)), ("title", .string(event.title)), ("start", .string(event.start.iso)),
                       ("end", .string(event.end.iso)), ("series", .bool(event.series)), ("projects", .array(projects))])
    }

    /// `upcoming`: meetings still to come, with the projects chosen for them.
    public static func upcoming(_ app: ServerApp, now: PyDateTime? = nil) throws -> JSONValue {
        guard let provider = app.calendar else { return .array([]) }
        let store = ProjectStore(path: app.stores.projects)
        return .array(try Prep.upcoming(provider: provider, now: now ?? self.now()).map { try entry($0, store, app).json })
    }

    /// `_event`: the upcoming event `key`, else NotFound.
    static func event(_ app: ServerApp, _ key: String, _ now: PyDateTime?) throws -> CalendarEvent {
        guard let provider = app.calendar, let event = try Prep.find(provider: provider, key: key, now: now ?? self.now()) else {
            throw NotFound(key)
        }
        return event
    }

    /// `upcoming_meeting`: one upcoming meeting — invitees, projects (chosen and suggested), and the meetings that lead
    /// up to it.
    public static func upcomingMeeting(_ app: ServerApp, key: String, now: PyDateTime? = nil) throws -> JSONValue {
        let event = try event(app, key, now)
        let store = ProjectStore(path: app.stores.projects)
        let every = try ProjectRules.allFacts(outputDir: app.outputDir, userName: app.userName, stores: app.stores)
        var out = try entry(event, store, app)
        out["attendees"] = .array(event.attendees.filter { !$0.isRoom && !$0.isSelf }.map { a in
            .object([("name", .string(a.name)), ("organizer", .bool(a.organizer)), ("response", .string(a.response))])
        })
        out["suggestions"] = .array(try Prep.suggestions(event, outputDir: app.outputDir, userName: app.userName, store: store,
                                                         every: every, stores: app.stores))
        out["context"] = .array(try Prep.context(event, outputDir: app.outputDir, userName: app.userName, every: every,
                                                 stores: app.stores))
        let all = try store.projects.map { pid, p -> (name: String, row: JSONValue) in
            let name = try MeetingsAPI.key(p, "name")
            guard case .string(let text) = name else { throw PageError("'\(PyBody.typeName(name))' object has no attribute 'casefold'") }
            return (text, .object([("id", .string(pid)), ("name", name)]))
        }
        out["all_projects"] = .array(Py.stableSorted(all) { Py.less(Py.casefold($0.name), Py.casefold($1.name)) }.map(\.row))
        return out.json
    }

    /// `set_upcoming_project`: choose a project for an upcoming meeting (by id, or by name — a new name makes a new
    /// project), or (`remove`) no longer.
    public static func setUpcomingProject(_ app: ServerApp, key: String, project: String? = nil, name: String? = nil,
                                          remove: Bool = false, now: PyDateTime? = nil) throws {
        let event = try event(app, key, now)
        let pid: String = try app.projectsLock.withLock {
            let store = ProjectStore(path: app.stores.projects)
            var pid = project ?? ""
            if project == nil {
                guard !Py.strip(name ?? "").isEmpty else { throw BadRequest(ProjectsAPI.NEEDS_A_NAME) }
                pid = store.find(name!) ?? ""
                if pid.isEmpty { pid = try ProjectsAPI.python { try store.create(name!) } }
                try store.save()
            }
            guard store.projects[pid] != nil else { throw NotFound(pid) }
            return pid
        }
        try Prep.choose(event, pid, remove: remove, stores: app.stores)
    }
}

extension Router {
    /// Meeting prep (server.py's GET and POST branches). The key is unquoted (`unquote(m.group(1))`).
    static func addUpcomingRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/upcoming") { _, _ in .json(try UpcomingAPI.upcoming(app)) }
        r.get("/api/upcoming/([^/]+)") { _, m in .json(try UpcomingAPI.upcomingMeeting(app, key: PyURL.unquote(m.group(1)!))) }
        r.post("/api/upcoming/([^/]+)/projects") { req, m in
            let key = PyURL.unquote(m.group(1)!)
            func optionalText(_ name: String) throws -> String? { try PyBody.get(req.json, name).flatMap { $0 == .null ? nil : Py.str($0) } }
            try UpcomingAPI.setUpcomingProject(app, key: key, project: try optionalText("project"), name: try optionalText("name"),
                                               remove: try PyBody.get(req.json, "remove")?.truthy ?? false)
            return .json(try UpcomingAPI.upcomingMeeting(app, key: key))
        }
    }
}
