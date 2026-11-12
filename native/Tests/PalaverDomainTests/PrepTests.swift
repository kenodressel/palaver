// prep.py (test_prep.py): upcoming meetings, projects chosen before them, and the meetings that lead up to them.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct PrepTests {
    /// 2026-10-28T09:00:00+01:00
    static let NOW = try! PyDateTime.parse("2026-10-28T09:00:00+01:00")

    /// test_prep.py's `_event`: the user and `people` (at contoso.com) invited, `hours` from NOW, 30 minutes.
    private func event(_ title: String, _ hours: Double, _ people: String..., uid: String = "", series: Bool = false) -> CalendarEvent {
        let start = try! Self.NOW.adding(seconds: hours * 3600)
        let attendees = [Attendee(name: "Timo Strauss", email: "timo@kloud.io", isSelf: true)]
            + people.map { Attendee(name: $0, email: "\(Py.strLower(Py.split($0)[0]))@contoso.com") }
        return CalendarEvent(title: title, start: start, end: try! start.adding(seconds: 1800), attendees: attendees,
                             uid: uid.isEmpty ? title : uid, series: series)
    }

    /// test_prep.py's `_recorded`: a processed meeting of `event`, with notes when there is a `summary`.
    @discardableResult
    private func recorded(_ root: ProjectsRoot, _ name: String, _ event: CalendarEvent, summary: String = "",
                          steps: [String] = []) throws -> RecordingPaths {
        let paths = RecordingPaths(root.recordings.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        try PythonJSON.write(.object([("start_time", .string(event.start.iso)), ("duration_seconds", .int(1800))]),
                             to: paths.meta, indent: nil, ensureAscii: true)
        try PythonJSON.write(.array([]), to: paths.transcriptJson, indent: nil, ensureAscii: true)
        try CalendarEvents.save(paths, event)
        if !summary.isEmpty {
            let next: [JSONValue] = steps.map { .object([("owner", .string("SPEAKER_01")), ("task", .string($0))]) }
            try PythonJSON.write(.object([("title", .string(event.title)), ("summary", .string(summary)), ("next_steps", .array(next))]),
                                 to: paths.notes, indent: nil, ensureAscii: true)
        }
        return paths
    }

    @Test func test_upcoming_lists_what_is_still_to_come() throws {
        let events = [event("Done", -2, "Anna"), event("Running", -0.2, "Anna"), event("Later", 3, "Anna"),
                      event("Day after", 60, "Anna"), event("Kita reminder", 1),  // nobody invited: not a meeting
                      CalendarEvent(title: "Holiday", start: Self.NOW, end: try! Self.NOW.adding(seconds: 86400), allDay: true, uid: "h")]
        #expect(try Prep.upcoming(provider: { _, _ in events }, now: Self.NOW).map(\.title) == ["Running", "Later"])
    }

    @Test func test_a_project_chosen_before_goes_to_the_recording() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        let store = root.store()
        let pid = try store.create("Northwind rollout")
        try store.save()
        let e = event("Northwind Sync", 2, "Valerie", uid: "abc", series: true)
        try Prep.choose(e, pid, stores: root.stores)
        #expect(Prep.chosen(e, stores: root.stores) == [pid])

        let paths = try recorded(root, "2026-10-28T11-00-00", e)
        #expect(try Prep.apply(paths, event: e, stores: root.stores) == [pid])
        #expect(PythonJSON.dumps(root.store().ofMeeting("2026-10-28T11-00-00").json)
                == PythonJSON.dumps(.object([(pid, .object([("by", .string("you")), ("why", .string("chosen before the meeting"))]))])))
        #expect(Prep.chosen(e, stores: root.stores).isEmpty)  // used up
    }

    @Test func test_a_recurring_event_goes_where_its_series_went_and_brings_context() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        let past = event("Northwind Sync", -24 * 7, "Valerie", uid: "series-1", series: true)
        try recorded(root, "2026-10-21T11-00-00", past, summary: "Pilot in Australia.", steps: ["Book the engineer"])
        try recorded(root, "2026-10-14T11-00-00", event("Lunch", -24 * 14, "Valerie", uid: "x"))
        let store = root.store()
        let pid = try store.create("Northwind rollout")
        try store.assign("2026-10-21T11-00-00", pid)
        try store.save()

        // A changed occurrence: its id is the series' plus when it was.
        let upcoming = event("Northwind Sync (moved)", 2, "Carla", uid: "series-1/RID=814282200", series: true)
        let s = try Prep.suggestions(upcoming, outputDir: root.recordings, userName: "Timo", stores: root.stores)
        #expect(s.count == 1)
        #expect(s.first?["id"]?.stringValue == pid && s.first?["why"]?.stringValue?.hasPrefix("series") == true)
        let c = try Prep.context(upcoming, outputDir: root.recordings, userName: "Timo", stores: root.stores)
        #expect(c.count == 1)
        #expect(c.first?["id"]?.stringValue == "2026-10-21T11-00-00" && c.first?["why"]?.stringValue == "same series")
        #expect(c.first?["summary"]?.stringValue == "Pilot in Australia.")
        let step = c.first?["next_steps"]?.arrayValue?.first
        #expect(step?["task"]?.stringValue == "Book the engineer")
        #expect(step?["owner"]?.stringValue == "Speaker 2")  // no label shows

        let other = event("Contoso chat", 3, "Valerie", uid: "new")
        #expect(try Prep.context(other, outputDir: root.recordings, userName: "Timo", stores: root.stores)
                    .map { $0["why"]?.stringValue } == ["same people", "same people"])
    }

    @Test func test_the_meetings_before_are_called_what_the_user_renamed_them_to() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        let past = event("Northwind Sync", -24 * 7, "Valerie", uid: "series-1", series: true)
        let paths = try recorded(root, "2026-10-21T11-00-00", past, summary: "Pilot in Australia.")
        try Titles.save(paths, "Pilot go/no-go")
        let upcoming = event("Northwind Sync", 2, "Valerie", uid: "series-1/RID=814282200", series: true)
        let c = try Prep.context(upcoming, outputDir: root.recordings, userName: "Timo", stores: root.stores)
        #expect(c.count == 1 && c.first?["title"]?.stringValue == "Pilot go/no-go")
    }

    // MARK: Swift's own

    @Test func notesNamesAndTheGlossaryReachTheContext() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        let past = event("Northwind Sync", -24, "Valerie", uid: "series-1", series: true)
        let paths = try recorded(root, "2026-10-27T09-00-00", past, summary: "SPEAKER_01 and SPEAKER_10 talk to Nordwind.",
                                 steps: ["Book the engineer"])
        try PythonJSON.write(.object([("SPEAKER_01", .string("Valerie"))]), to: paths.speakers, indent: 2, ensureAscii: false)
        let glossary = Glossary(path: root.stores.glossary)
        _ = try glossary.add(term: "Northwind", variants: ["Nordwind"])
        try glossary.save()
        let c = try Prep.context(event("Northwind Sync", 2, "Valerie", uid: "series-1"), outputDir: root.recordings,
                                 userName: "Timo", stores: root.stores)
        #expect(c.first?["summary"]?.stringValue == "Valerie and Speaker 11 talk to Northwind.")
        #expect(c.first?["next_steps"]?.arrayValue?.first?["owner"]?.stringValue == "Valerie")
    }

    @Test func applyBringsTheNotesWrittenBeforeTheMeeting() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        let e = event("Northwind Sync", 2, "Valerie", uid: "abc")
        let prep = MyNotes.prepFolder(e.key, stores: root.stores)
        _ = try MyNotes.save(prep, paragraphs: .array([.object([("text", .string("Ask about the budget")), ("at", .null)])]))
        let paths = try recorded(root, "2026-10-28T11-00-00", e)
        #expect(try Prep.apply(paths, event: e, stores: root.stores).isEmpty)  // no project chosen
        #expect(MyNotes.load(paths.folder).map(\.text) == ["Ask about the budget"])
        #expect(!FileManager.default.fileExists(atPath: prep.path))
    }
}
