// The Projects page, a meeting's projects and meeting prep (api.py `list_projects`, `create_project`, `update_project`,
// `merge_projects`, `delete_project`, `set_meeting_project`, `upcoming`, `upcoming_meeting`, `set_upcoming_project`;
// their routes). Ports their tests of tests/test_webapp.py under their names.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"
/// test_webapp.py `OTHER`: the same title and people as MEETING, so its project is suggested.
private let OTHER = "2026-10-26T09-00-00"

private extension JSONValue {
    subscript(i: Int) -> JSONValue? { arrayValue.flatMap { $0.indices.contains(i) ? $0[i] : nil } }
    var list: [JSONValue] { arrayValue ?? [] }
    var names: [String] { list.compactMap { $0["name"]?.stringValue } }
}

/// `_post`: the status and the JSON answer.
private func post(_ s: TestServer, _ path: String, _ body: JSONValue = .object([])) -> (Int, JSONValue) {
    let r = s.post(path, body)
    return (r.status, r.json ?? .null)
}

private func projects(_ s: TestServer) -> [JSONValue] { s.get("/api/projects").json?["projects"]?.list ?? [] }

/// `_project_of`: the meeting's projects with who gave them, the suggested ones and every project, by name.
private struct ProjectOf: Equatable {
    var inIt: [String]
    var suggested: [String]
    var all: [String]
}

private func projectOf(_ s: TestServer, _ meeting: String = MEETING) -> ProjectOf {
    let m = s.get("/api/meetings/\(meeting)").json ?? .null
    return ProjectOf(inIt: (m["projects"]?.list ?? []).map { "\($0["name"]?.stringValue ?? "") \($0["by"]?.stringValue ?? "")" },
                     suggested: m["project_suggestions"]?.names ?? [], all: m["all_projects"]?.names ?? [])
}

/// `_undo`: the answer has a token, and undoing it works.
private func undo(_ s: TestServer, _ answer: JSONValue) {
    let token = answer["undo"]?.stringValue ?? ""
    #expect(!token.isEmpty)
    #expect(post(s, "/api/undo", .object([("token", .string(token))])).0 == 200)
}

/// `_unsure`: the model put the meeting in `pid`.
private func unsure(_ s: TestServer, _ pid: String, _ meeting: String = MEETING) throws {
    let store = ProjectStore(path: s.app.stores.projects)
    try store.assign(meeting, pid, by: "model", why: "the same people")
    try store.save()
}

private func created(_ s: TestServer, _ name: String = "Hiring", description: String? = nil) -> String {
    var body: [(String, JSONValue)] = [("name", .string(name))]
    if let description { body.append(("description", .string(description))) }
    let (_, answer) = post(s, "/api/projects", .object(body))
    return answer["projects"]?[0]?["id"]?.stringValue ?? ""
}

/// A recordings folder and the stores in a temporary folder, and the app over them for "Timo" (no HTTP).
private final class Fixture {
    let dir: URL
    let out: URL
    let app: ServerApp

    init(calendar: CalendarProvider? = nil) throws {
        dir = tempFolder("projects")
        out = dir.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                                home: dir.appendingPathComponent("home", isDirectory: true))
        app = ServerApp(outputDir: out, userName: "Timo", stores: stores, calendar: calendar)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func page(_ id: String = MEETING) throws -> JSONValue { try MeetingsAPI.getMeeting(app: app, id: id) }
    func list() throws -> [JSONValue] { try ProjectsAPI.listProjects(app)["projects"]?.list ?? [] }
}

@Suite struct ProjectsRoutesTests {
    @Test func test_projects_page_and_meeting_projects() throws {
        let f = try Fixture()
        try pageMeeting(f.out)
        try pageMeeting(f.out, OTHER)
        let d = try ProjectsAPI.listProjects(f.app)
        #expect(d["projects"] == .array([]))
        #expect(Set(d["unsorted"]?.list.compactMap { $0["id"]?.stringValue } ?? []) == [MEETING, OTHER])

        try ProjectsAPI.setMeetingProject(f.app, id: MEETING, name: "Hiring")  // a new name makes a project
        let hiring = try f.list()
        #expect(hiring.count == 1)
        let pid = hiring.first?["id"]?.stringValue ?? ""
        // the faces beside the meeting in the project: its named people, as in the meeting list
        let listed = try MeetingsAPI.listMeetings(app: f.app).first { $0["id"] == .string(MEETING) }
        #expect(hiring.first?["meetings"]?[0]?["people"] == listed?["people"])
        try ProjectsAPI.updateProject(f.app, id: pid, description: "Lead engineer hiring.")
        let m = try f.page()
        #expect((m["projects"]?.list ?? []).map { [$0["name"], $0["by"]] } == [[.string("Hiring"), .string("you")]])
        #expect(m["all_projects"] == .array([.object([("id", .string(pid)), ("name", .string("Hiring"))])]))
        // the other meeting has the same title and people: suggested
        #expect(try f.page(OTHER)["project_suggestions"]?.names == ["Hiring"])
        #expect(try MeetingsAPI.listMeetings(app: f.app).first?["projects"]?[0]?["name"] == .string("Hiring"))

        let other = try ProjectsAPI.createProject(f.app, name: "Recruiting")
        try ProjectsAPI.setMeetingProject(f.app, id: OTHER, project: other)
        try ProjectsAPI.mergeProjects(f.app, id: other, into: pid)
        let merged = try f.list()
        #expect(merged.count == 1 && merged.first?["description"] == .string("Lead engineer hiring."))
        #expect(merged.first?["meetings"]?.list.count == 2)

        try ProjectsAPI.setMeetingProject(f.app, id: MEETING, project: pid, remove: true)
        #expect(try f.page()["project_suggestions"] == .array([]))  // stays out
        try ProjectsAPI.deleteProject(f.app, id: pid)
        #expect(throws: NotFound.self) { try ProjectsAPI.updateProject(f.app, id: pid, name: "X") }
        #expect(throws: NotFound.self) { try ProjectsAPI.setMeetingProject(f.app, id: "2026-01-01T00-00-00", name: "X") }
    }

    @Test func test_http_projects() throws {
        let runs = FakeHelpers { _, _, _ in 0 }
        let s = try TestServer(helpers: runs, meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let pid = created(s)
        var (status, answer) = post(s, "/api/meetings/\(MEETING)/projects", .object([("project", .string(pid))]))
        #expect(status == 200 && answer["projects"]?[0]?["name"] == .string("Hiring"))
        (status, answer) = post(s, "/api/projects/\(pid)", .object([("name", .string("Recruiting"))]))
        #expect(status == 200 && answer["projects"]?[0]?["name"] == .string("Recruiting"))
        (status, _) = post(s, "/api/projects/suggest")
        #expect(status == 200 && runs.args == [["--no-wait", "suggest"]])
        #expect(post(s, "/api/projects/zz/delete").0 == 404)
        (status, answer) = post(s, "/api/projects/\(pid)/delete")
        #expect(status == 200 && answer["projects"] == .array([]))
    }

    @Test func test_upcoming_meetings_can_be_prepared() throws {
        let now = try PyDateTime.parse("2026-10-28T09:00:00+01:00")
        let event = CalendarEvent(title: "Hiring debrief", start: try! now.adding(seconds: 2 * 3600), end: try! now.adding(seconds: 3 * 3600),
                                  attendees: [Attendee(name: "Anna Huber", email: "anna@x.com")], uid: "ev/1+=", series: true)
        let f = try Fixture(calendar: { _, _ in [event] })
        try pageMeeting(f.out)
        let upcoming = try UpcomingAPI.upcoming(f.app, now: now).list
        #expect(upcoming.count == 1)
        let key = upcoming.first?["key"]?.stringValue ?? ""
        #expect(key == "ev/1+=|2026-10-28" && upcoming.first?["projects"] == .array([]))

        try UpcomingAPI.setUpcomingProject(f.app, key: key, name: "Hiring", now: now)
        let m = try UpcomingAPI.upcomingMeeting(f.app, key: key, now: now)
        #expect(m["projects"]?.names == ["Hiring"] && m["attendees"]?[0]?["name"] == .string("Anna Huber"))
        let without = ServerApp(outputDir: f.out, userName: "Timo", stores: f.app.stores)
        #expect(try UpcomingAPI.upcoming(without) == .array([]))
        #expect(throws: NotFound.self) { try UpcomingAPI.upcomingMeeting(f.app, key: "nope|2026-10-28", now: now) }
    }

    @Test func test_http_upcoming_without_a_calendar() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let r = s.get("/api/upcoming")
        #expect(r.status == 200 && r.json == .array([]))
        #expect(s.get("/api/upcoming/x%7C2026-10-28").status == 404)
    }

    @Test func test_http_project_delete_can_be_undone() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let pid = created(s)
        _ = post(s, "/api/meetings/\(MEETING)/projects", .object([("project", .string(pid))]))
        let (status, answer) = post(s, "/api/projects/\(pid)/delete")
        #expect(status == 200 && answer["projects"] == .array([]) && answer["undo"]?.stringValue?.isEmpty == false)
        #expect(post(s, "/api/undo", .object([("token", answer["undo"] ?? .null)])).0 == 200)
        let after = projects(s)
        #expect(after.map { $0["name"]?.stringValue } == ["Hiring"])
        #expect(after.first?["meetings"]?.list.map { $0["id"]?.stringValue } == [MEETING])
    }

    @Test func test_http_adding_a_suggested_project_undone_leaves_it_suggested() throws {
        let s = try TestServer(meetings: { try pageMeeting($0); try pageMeeting($0, OTHER) })
        defer { s.stop() }
        let pid = created(s)
        _ = post(s, "/api/meetings/\(OTHER)/projects", .object([("project", .string(pid))]))
        #expect(projectOf(s).suggested == ["Hiring"])
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/projects", .object([("project", .string(pid))]))
        #expect(status == 200 && answer["projects"]?[0]?["name"] == .string("Hiring"))
        undo(s, answer)
        #expect(projectOf(s) == ProjectOf(inIt: [], suggested: ["Hiring"], all: ["Hiring"]))  // not rejected
    }

    @Test func test_http_removing_an_unsure_project_undone_brings_it_back_unsure() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let pid = created(s)
        try unsure(s, pid)
        let (_, answer) = post(s, "/api/meetings/\(MEETING)/projects", .object([("project", .string(pid)), ("remove", .bool(true))]))
        #expect(answer["projects"] == .array([]))
        undo(s, answer)
        #expect(projectOf(s).inIt == ["Hiring model"])
    }

    @Test func test_http_adding_a_new_project_by_name_undone_removes_the_project() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let (_, answer) = post(s, "/api/meetings/\(MEETING)/projects", .object([("name", .string("Hiring"))]))
        #expect(answer["projects"]?.names == ["Hiring"])
        undo(s, answer)
        #expect(projectOf(s) == ProjectOf(inIt: [], suggested: [], all: []))
        #expect(projects(s).isEmpty)
    }

    @Test func test_http_confirming_a_project_undone_leaves_it_unsure() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let pid = created(s)
        try unsure(s, pid)
        let (_, answer) = post(s, "/api/meetings/\(MEETING)/projects", .object([("project", .string(pid))]))
        #expect((answer["projects"]?.list ?? []).map { [$0["name"], $0["by"]] } == [[.string("Hiring"), .string("you")]])
        undo(s, answer)
        #expect(projectOf(s).inIt == ["Hiring model"])
    }

    @Test func test_http_chip_undo_refused_after_a_project_rename() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let pid = created(s)
        let (_, chip) = post(s, "/api/meetings/\(MEETING)/projects", .object([("project", .string(pid))]))
        _ = post(s, "/api/projects/\(pid)", .object([("name", .string("Recruiting"))]))  // an unrelated later edit of the store
        let (status, error) = post(s, "/api/undo", .object([("token", chip["undo"] ?? .null)]))
        #expect(status == 409 && (error["error"]?.stringValue ?? "").contains("changed"))
        #expect(projects(s).map { $0["name"]?.stringValue } == ["Recruiting"])
    }

    @Test func test_http_two_chip_changes_undone_in_order() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let pid = created(s)
        let (_, first) = post(s, "/api/meetings/\(MEETING)/projects", .object([("project", .string(pid))]))
        let (_, second) = post(s, "/api/meetings/\(MEETING)/projects", .object([("project", .string(pid)), ("remove", .bool(true))]))
        undo(s, second)
        #expect(projectOf(s).inIt == ["Hiring you"])
        undo(s, first)
        #expect(projectOf(s).inIt == [])
    }

    @Test func test_http_project_rename_can_be_undone() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let pid = created(s)
        let (status, answer) = post(s, "/api/projects/\(pid)", .object([("name", .string("Recruiting"))]))
        #expect(status == 200 && answer["projects"]?[0]?["name"] == .string("Recruiting"))
        undo(s, answer)
        #expect(projects(s).first?["name"] == .string("Hiring"))
    }

    @Test func test_http_project_description_can_be_undone() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let pid = created(s, description: "Old words.")
        let (status, answer) = post(s, "/api/projects/\(pid)", .object([("description", .string("New words."))]))
        #expect(status == 200 && answer["projects"]?[0]?["description"] == .string("New words."))
        undo(s, answer)
        #expect(projects(s).first?["description"] == .string("Old words."))
    }
}
