// Meeting series of Palaver's own in the window (#39): a meeting put into a series by hand (⋯ → Add to Series…, a new
// one by typing its name) or taken out; a series renamed, given a project, merged into another or deleted; and the
// series page with its meetings, newest first. Every change can be undone: series.json as it was.
import Foundation
import PalaverCore
import PalaverDomain

public enum SeriesAPI {
    /// The domain's refusals are the page's to show (400 with the text).
    static func refused<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let e as MeetingSeriesError {
            throw Refused(e.description)
        }
    }

    static func stores(_ app: ServerApp) -> [URL] { ChangesAPI.storePaths(app, "meeting_series") }

    static func known(_ app: ServerApp, _ id: String) throws -> MeetingSeriesEntry {
        guard let entry = MeetingSeries.find(id, stores: app.stores) else { throw NotFound(id) }
        return entry
    }

    /// The meeting as a series lists it.
    static func meeting(_ m: JSONValue) -> JSONValue {
        .object(["id", "title", "start", "duration", "status", "people", "summary"].map { ($0, m[$0] ?? .null) })
    }

    /// A series with its meetings (those still there, newest first), from the meeting list's entries.
    static func series(_ e: MeetingSeriesEntry, _ list: [JSONValue]) -> JSONValue {
        let members = Set(e.meetings.map(ScalarKey.init))
        let meetings = list.filter { members.contains(ScalarKey($0["id"]?.stringValue ?? "")) }.map(meeting)
        guard case .object(var fields) = e.page else { return e.page }
        McpSetup.set(&fields, "meetings", .array(meetings))
        McpSetup.set(&fields, "latest", meetings.first?["start"] ?? .null)
        return .object(fields)
    }

    /// The series page: every series, the one met last first (those without meetings last, by name), and the
    /// projects to offer: the series' own and the Projects page's.
    public static func page(_ app: ServerApp) throws -> JSONValue {
        let list = try MeetingsAPI.listMeetings(app: app)
        let all = MeetingSeries.all(stores: app.stores).map { series($0, list) }
        let sorted = Py.stableSorted(all) { a, b in
            let x = a["latest"]?.stringValue ?? "", y = b["latest"]?.stringValue ?? ""
            if x != y { return Py.less(y, x) }
            return Py.less(Py.casefold(a["name"]?.stringValue ?? ""), Py.casefold(b["name"]?.stringValue ?? ""))
        }
        var projects = MeetingSeries.projects(stores: app.stores)
        var seen = Set(projects.map { ScalarKey(Py.casefold($0)) })
        for (_, p) in ProjectStore(path: app.stores.projects).projects {
            if let name = p["name"]?.stringValue, seen.insert(ScalarKey(Py.casefold(name))).inserted { projects.append(name) }
        }
        return .object([("series", .array(sorted)), ("projects", .strings(projects))])
    }

    /// Meeting `id` goes into series `series`, or the one called `name` (a new one when none is), or out of its own
    /// (`remove`). The undo token.
    public static func setMeetingSeries(_ app: ServerApp, id: String, series: String?, name: String?, remove: Bool) throws -> String {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        if remove {
            guard MeetingSeries.of(meeting: id, stores: app.stores) != nil else { throw NotFound("\(id)'s series") }
        } else if let series {
            _ = try known(app, series)
        } else if MeetingSeries.cleaned(name) == nil {
            throw Refused("A series needs a name")
        }
        return try ChangesAPI.undoToken(app, label: "series", stores: stores(app)) { _ in
            try refused {
                if remove { try MeetingSeries.takeOut(id, stores: app.stores) }
                else if let series { try MeetingSeries.put(paths, into: series, stores: app.stores) }
                else { try MeetingSeries.put(paths, intoNamed: name ?? "", stores: app.stores) }
            }
        }
    }

    /// A series renamed and/or given a project (`project` .null or "": none). The undo token.
    public static func update(_ app: ServerApp, id: String, name: String?, project: JSONValue?) throws -> String {
        _ = try known(app, id)
        return try ChangesAPI.undoToken(app, label: "series", stores: stores(app)) { _ in
            try refused {
                if let name { try MeetingSeries.rename(id, to: name, stores: app.stores) }
                if let project { try MeetingSeries.setProject(id, project.stringValue, stores: app.stores) }
            }
        }
    }

    public static func merge(_ app: ServerApp, id: String, into: String) throws -> String {
        _ = try known(app, id)
        _ = try known(app, into)
        return try ChangesAPI.undoToken(app, label: "series", stores: stores(app)) { _ in
            try refused { try MeetingSeries.merge(id, into: into, stores: app.stores) }
        }
    }

    /// Deleted: its meetings stay, in no series, and no recording joins it any more; the note template it remembered
    /// (#13) is forgotten with it.
    public static func delete(_ app: ServerApp, id: String) throws -> String {
        _ = try known(app, id)
        return try ChangesAPI.undoToken(app, label: "series", stores: stores(app) + [app.stores.noteTemplates]) { _ in
            try MeetingSeries.forget(id, stores: app.stores)
            try NoteTemplates.forgetSeries(NoteTemplates.meetingSeriesKey(id), stores: app.stores)
        }
    }
}

extension Router {
    static func addSeriesRoutes(_ r: Router, app: ServerApp) {
        func optionalText(_ body: JSONValue, _ key: String) throws -> String? {
            try PyBody.get(body, key).flatMap { $0 == .null ? nil : Py.str($0) }
        }
        /// Every change on the series page answers with the page, and its undo.
        func page(_ token: String) throws -> Response { .json(try SeriesAPI.page(app).adding("undo", .string(token))) }

        r.get("/api/series") { _, _ in .json(try SeriesAPI.page(app)) }
        r.post("/api/meetings/([^/]+)/series") { req, m in
            let id = m.group(1)!
            let token = try SeriesAPI.setMeetingSeries(app, id: id, series: try optionalText(req.json, "series"),
                                                       name: try optionalText(req.json, "name"),
                                                       remove: try PyBody.get(req.json, "remove")?.truthy ?? false)
            return .json(try MeetingsAPI.getMeeting(app: app, id: id).adding("undo", .string(token)))
        }
        r.post("/api/series/([^/]+)") { req, m in
            try page(try SeriesAPI.update(app, id: m.group(1)!, name: try optionalText(req.json, "name"),
                                          project: try PyBody.get(req.json, "project")))
        }
        r.post("/api/series/([^/]+)/merge") { req, m in
            try page(try SeriesAPI.merge(app, id: m.group(1)!, into: Py.str(try PyBody.required(req.json, "into"))))
        }
        r.post("/api/series/([^/]+)/delete") { _, m in try page(try SeriesAPI.delete(app, id: m.group(1)!)) }
    }
}
