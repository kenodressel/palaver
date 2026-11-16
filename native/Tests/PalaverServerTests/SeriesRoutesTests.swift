// Meeting series of Palaver's own in the window (#39): a meeting put into a series by hand and taken out, a series
// renamed, given a project, merged and deleted (each undoable), the series page, the list's `series` and the search's
// `series:` and `project:`.
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"
private let OTHER = "2026-10-26T09-00-00"

private extension JSONValue {
    var list: [JSONValue] { arrayValue ?? [] }
}

private func post(_ s: TestServer, _ path: String, _ body: JSONValue = .object([])) -> (Int, JSONValue) {
    let r = s.post(path, body)
    return (r.status, r.json ?? .null)
}

private func undo(_ s: TestServer, _ answer: JSONValue) {
    let token = answer["undo"]?.stringValue ?? ""
    #expect(!token.isEmpty)
    #expect(post(s, "/api/undo", .object([("token", .string(token))])).0 == 200)
}

private func series(_ s: TestServer) -> [JSONValue] { s.get("/api/series").json?["series"]?.list ?? [] }

private func found(_ s: TestServer, _ q: String) -> [String] {
    let query = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q
    return (s.get("/api/search?q=\(query)").json?["results"]?.list ?? []).compactMap { $0["id"]?.stringValue }
}

@Suite struct SeriesRoutesTests {
    private func server() throws -> TestServer {
        try TestServer(meetings: { out in
            try pageMeeting(out)
            try pageMeeting(out, OTHER)
        })
    }

    @Test func aMeetingGoesIntoASeriesByHandAndOutAgain() throws {
        let s = try server(); defer { s.stop() }
        // A new name: a new series of the user's, which the meeting page and the list show.
        var (status, page) = post(s, "/api/meetings/\(MEETING)/series", .object([("name", .string("Contoso weekly"))]))
        #expect(status == 200)
        #expect(page["series"]?["name"] == .string("Contoso weekly") && page["series"]?["learned"] == .string("you"))
        let sid = page["series"]?["id"]?.stringValue ?? ""
        let listed = s.get("/api/meetings").json?.list.first { $0["id"] == .string(MEETING) }
        #expect(listed?["series"] == .object([("id", .string(sid)), ("name", .string("Contoso weekly")), ("project", .null)]))
        // The other one into the same series, by its id; a series that isn't there is 404, no name 400.
        (status, page) = post(s, "/api/meetings/\(OTHER)/series", .object([("series", .string(sid))]))
        #expect(status == 200 && page["series"]?["meetings"] == .int(2))
        #expect(post(s, "/api/meetings/\(OTHER)/series", .object([("series", .string("s-gone"))])).0 == 404)
        #expect(post(s, "/api/meetings/\(OTHER)/series", .object([("name", .string("  "))])).1
                == .object([("error", .string("A series needs a name"))]))
        // The series page: its meetings newest first.
        let all = series(s)
        #expect(all.count == 1 && all[0]["meetings"]?.list.compactMap { $0["id"]?.stringValue } == [MEETING, OTHER])
        #expect(all[0]["latest"] == .string("2026-10-27T16:03:07+01:00"))
        // Out again; undo puts it back.
        (status, page) = post(s, "/api/meetings/\(MEETING)/series", .object([("remove", .bool(true))]))
        #expect(status == 200 && page["series"] == .null)
        #expect(post(s, "/api/meetings/\(MEETING)/series", .object([("remove", .bool(true))])).0 == 404)
        undo(s, page)
        #expect(s.get("/api/meetings/\(MEETING)").json?["series"]?["id"] == .string(sid))
    }

    @Test func aSeriesIsRenamedGivenAProjectMergedAndDeleted() throws {
        let s = try server(); defer { s.stop() }
        let a = post(s, "/api/meetings/\(MEETING)/series", .object([("name", .string("Northwind sync"))])).1["series"]?["id"]?.stringValue ?? ""
        let b = post(s, "/api/meetings/\(OTHER)/series", .object([("name", .string("NW weekly"))])).1["series"]?["id"]?.stringValue ?? ""
        var (status, answer) = post(s, "/api/series/\(a)", .object([("name", .string("Northwind weekly")), ("project", .string("Northwind"))]))
        #expect(status == 200)
        #expect(answer["series"]?.list.first { $0["id"] == .string(a) }?["project"] == .string("Northwind"))
        #expect(answer["projects"] == .strings(["Northwind"]))
        // Without an event the meeting is called by its series, before its notes' title.
        #expect(s.get("/api/meetings/\(MEETING)").json?["title"] == .string("Northwind weekly"))
        undo(s, answer)
        #expect(series(s).first { $0["id"] == .string(a) }?["name"] == .string("Northwind sync"))
        #expect(post(s, "/api/series/\(a)", .object([("name", .string(""))])).0 == 400)
        #expect(post(s, "/api/series/s-gone", .object([("name", .string("x"))])).0 == 404)
        _ = post(s, "/api/series/\(a)", .object([("project", .string("Northwind"))]))
        _ = post(s, "/api/series/\(a)", .object([("project", .null)]))
        #expect(series(s).first { $0["id"] == .string(a) }?["project"] == .null)
        // Merged: one series with both meetings.
        (status, answer) = post(s, "/api/series/\(b)/merge", .object([("into", .string(a))]))
        #expect(status == 200 && answer["series"]?.list.count == 1)
        #expect(answer["series"]?.list.first?["meetings"]?.list.count == 2)
        #expect(post(s, "/api/series/\(a)/merge", .object([("into", .string(a))])).0 == 400)
        undo(s, answer)
        #expect(series(s).count == 2)
        // Deleted: the meetings stay, in no series.
        (status, answer) = post(s, "/api/series/\(a)/delete")
        #expect(status == 200 && answer["series"]?.list.count == 1)
        #expect(s.get("/api/meetings/\(MEETING)").json?["series"] == .null)
        #expect(s.get("/api/meetings").json?.list.count == 2)
        undo(s, answer)
        #expect(s.get("/api/meetings/\(MEETING)").json?["series"]?["id"] == .string(a))
    }

    @Test func theSearchFiltersBySeriesAndProject() throws {
        let s = try server(); defer { s.stop() }
        let sid = post(s, "/api/meetings/\(MEETING)/series", .object([("name", .string("Contoso weekly"))])).1["series"]?["id"]?.stringValue ?? ""
        _ = post(s, "/api/series/\(sid)", .object([("project", .string("Contoso"))]))
        #expect(found(s, "series:\"contoso weekly\"") == [MEETING])
        #expect(found(s, "project:contoso") == [MEETING])
        #expect(found(s, "series:nothing") == [])
        let chips = s.get("/api/search?q=series:nothing").json?["understood"]?.list ?? []
        #expect(chips.first?["title"] == .string("No meeting series has this name"))
        // A project of the Projects page and the series' of the same name: both count.
        _ = try ProjectsAPI.setMeetingProject(s.app, id: OTHER, name: "Contoso")
        #expect(Set(found(s, "project:Contoso")) == [MEETING, OTHER])
        #expect(found(s, "project:Contoso salary series:\"Contoso weekly\"") == [MEETING])
    }
}
