// Note templates through the window (#13): the list Settings shows, the user's own added, edited and deleted, a
// meeting's template chosen (and remembered for its series), and what the meeting page and Claude's get_meeting say.
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"

private func weekly(_ title: String = "Weekly Kim", series: Bool = true) throws -> CalendarEvent {
    let start = try PyDateTime.parse("2026-10-27T16:00:00+01:00")
    return CalendarEvent(title: title, start: start, end: try start.adding(seconds: 1800), uid: "W1", series: series)
}

@Suite struct NoteTemplatesRoutesTests {
    @Test func settingsListsEveryTemplateAndTheUsersOwnAreAddedEditedAndDeleted() throws {
        let s = try TestServer()
        defer { s.stop() }
        let first = s.get("/api/note-templates").json ?? .null
        #expect(first["templates"]?.arrayValue?.map { $0["name"] } == ["Default", "1:1", "Customer call", "Interview", "Workshop",
                                                                         "Stand-up"].map { .string($0) })
        #expect(first["templates"]?.arrayValue?.allSatisfy { $0["builtin"] == .bool(true) } == true)
        let made = s.post("/api/note-templates", .object([("name", .string("Board")), ("instructions", .string("Per agenda item."))]))
        #expect(made.status == 200)
        let id = try #require(made.json?["id"]?.stringValue)
        #expect(made.json?["templates"]?.arrayValue?.last == NoteTemplate(id: id, name: "Board", instructions: "Per agenda item.").json)
        let edited = s.post("/api/note-templates/\(id)", .object([("name", .string("Board meeting")), ("instructions", .string("Per item."))]))
        #expect(edited.json?["templates"]?.arrayValue?.last?["name"] == .string("Board meeting"))
        // What can't be done says why.
        let empty = s.post("/api/note-templates", .object([("name", .string("")), ("instructions", .string("x"))]))
        #expect(empty.status == 400 && empty.json?["error"] == .string("a template needs a name"))
        let builtin = s.post("/api/note-templates/interview", .object([("delete", .bool(true))]))
        #expect(builtin.status == 400 && builtin.json?["error"] == .string("a built-in template can't be changed"))
        let deleted = s.post("/api/note-templates/\(id)", .object([("delete", .bool(true))]))
        #expect(deleted.status == 200 && deleted.json?["templates"]?.arrayValue?.count == 6)
    }

    @Test func aMeetingsTemplateIsChosenShownAndRememberedForItsSeries() throws {
        let s = try TestServer(meetings: { _ = try pageMeeting($0) })
        defer { s.stop() }
        let paths = RecordingPaths(s.app.outputDir.appendingPathComponent(MEETING, isDirectory: true))
        var m = s.get("/api/meetings/\(MEETING)").json ?? .null
        // No event: Default; the notes there are from before templates.
        #expect(m["template"]?["id"] == .string("default") && m["template"]?["from"] == .string("default"))
        #expect(m["template"]?["series"]?["can"] == .bool(false) && m["notes_template"] == .null)
        try CalendarEvents.save(paths, try weekly("1:1 Kim / Timo"))
        m = s.get("/api/meetings/\(MEETING)").json ?? .null
        #expect(m["template"]?["id"] == .string("one-on-one") && m["template"]?["from"] == .string("title"))
        #expect(m["template"]?["series"] == .object([("can", .bool(true)), ("template", .null)]))
        // Chosen for the meeting: the page answers with the meeting as it is now. Nothing is written yet.
        let chosen = s.post("/api/meetings/\(MEETING)/template", .object([("template", .string("workshop"))]))
        #expect(chosen.status == 200 && chosen.json?["template"]?["id"] == .string("workshop"))
        #expect(chosen.json?["template"]?["from"] == .string("meeting") && chosen.json?["template"]?["name"] == .string("Workshop"))
        #expect(NoteTemplates.seriesChoice(try weekly(), stores: s.app.stores) == nil)
        // And for its series.
        let series = s.post("/api/meetings/\(MEETING)/template", .object([("template", .string("workshop")), ("series", .bool(true))]))
        #expect(series.json?["template"]?["series"]?["template"] == .string("workshop"))
        let listed = s.get("/api/note-templates").json ?? .null
        #expect(listed["series"] == .array([.object([("series", .string("W1")), ("title", .string("1:1 Kim / Timo")),
                                                     ("template", .string("workshop")), ("template_name", .string("Workshop"))])]))
        // Forgotten from Settings.
        #expect(s.post("/api/note-templates/series", .object([("series", .string("W1"))])).json?["series"] == .array([]))
        // Unknown templates and meetings are refused.
        let unknown = s.post("/api/meetings/\(MEETING)/template", .object([("template", .string("nope"))]))
        #expect(unknown.status == 400 && unknown.json?["error"] == .string("no template nope"))
        #expect(s.post("/api/meetings/2026-01-01T00-00-00/template", .object([("template", .string("workshop"))])).status == 404)
        // null takes the choice back.
        let back = s.post("/api/meetings/\(MEETING)/template", .object([("template", .null)]))
        #expect(back.json?["template"]?["id"] == .string("one-on-one"))
    }

    @Test func notesWrittenWithATemplateSayWhichOneOnThePageAndToClaude() throws {
        let s = try TestServer(meetings: { _ = try pageMeeting($0) })
        defer { s.stop() }
        let paths = RecordingPaths(s.app.outputDir.appendingPathComponent(MEETING, isDirectory: true))
        var notes = PyDict<JSONValue>(Notes.load(paths)!)!
        notes["template"] = .string("interview")
        notes["template_name"] = .string("Interview")
        try NotesFile.save(paths, notes.json)
        let m = s.get("/api/meetings/\(MEETING)").json ?? .null
        #expect(m["notes_template"] == .object([("id", .string("interview")), ("name", .string("Interview"))]))
        #expect(m["template"]?["id"] == .string("interview") && m["template"]?["from"] == .string("notes"))
        let got = try McpTools(app: s.app, userName: "Timo Strauß").getMeeting(meetingId: MEETING)
        #expect(got["notes"]?["template"] == .string("Interview"))
        // A deleted template of the user's keeps its name on the notes it wrote.
        notes["template"] = .string("my-gone")
        notes["template_name"] = .string("Board")
        try NotesFile.save(paths, notes.json)
        let gone = s.get("/api/meetings/\(MEETING)").json ?? .null
        #expect(gone["notes_template"]?["name"] == .string("Board") && gone["template"]?["id"] == .string("default"))
    }
}
