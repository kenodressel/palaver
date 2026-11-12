// titles.py (test_titles.py, notes.py's load): the user's own title, the imported one, the event's, the notes'.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct TitlesTests {
    private static let START = try! PyDateTime.parse("2026-10-27T12:04:00+01:00")

    private struct Setup {
        let t = TempFolder("titles")
        let paths: RecordingPaths
        let stores: StorePaths
        init(event: String? = nil, notesTitle: String? = nil) throws {
            paths = RecordingPaths(t.url.appendingPathComponent("2026-10-27T12-04-00", isDirectory: true))
            stores = StorePaths(configDir: t.url.appendingPathComponent("palaver"), home: t.url)
            try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
            if let event {
                try CalendarEvents.save(paths, CalendarEvent(title: event, start: TitlesTests.START, end: TitlesTests.START.adding(micros: 30 * 60_000_000)))
            }
            if let notesTitle {
                try PythonJSON.write(.object([("title", .string(notesTitle)), ("summary", .string("")), ("sections", .array([])),
                                              ("next_steps", .array([])), ("decisions", .array([]))]),
                                     to: paths.notes, indent: 2, ensureAscii: false)
            }
        }
        func resolve(event: Titles.Known<CalendarEvent> = .unread, notes: Titles.Known<JSONValue> = .unread) -> [String?] {
            let r = Titles.resolve(paths, event: event, meetingNotes: notes, stores: stores)
            return [r.title, r.source]
        }
    }

    @Test func test_the_users_title_wins_over_the_event_and_the_notes() throws {
        let s = try Setup(event: "Weekly sync", notesTitle: "Budget talk"); defer { s.t.remove() }
        try Titles.save(s.paths, "Budget with Anna")
        #expect(s.resolve() == ["Budget with Anna", "you"])
    }

    @Test func test_the_event_comes_before_the_notes() throws {
        let s = try Setup(event: "Weekly sync", notesTitle: "Budget talk"); defer { s.t.remove() }
        #expect(s.resolve() == ["Weekly sync", "calendar"])
    }

    @Test func test_the_notes_title_is_spelled_as_the_glossary_says() throws {
        let s = try Setup(notesTitle: "Atterkrink rollout"); defer { s.t.remove() }
        let g = Glossary(path: s.stores.glossary)
        try g.add(term: "Atterkring", variants: ["Atterkrink"])
        try g.save()
        #expect(s.resolve() == ["Atterkring rollout", "notes"])
    }

    @Test func test_without_any_title_there_is_none() throws {
        let s = try Setup(); defer { s.t.remove() }
        #expect(s.resolve() == [nil, nil])
    }

    @Test func test_saving_an_empty_title_gives_it_back_to_the_event() throws {
        let s = try Setup(event: "Weekly sync"); defer { s.t.remove() }
        try Titles.save(s.paths, "Mine")
        try Titles.save(s.paths, "")
        #expect(!FileManager.default.fileExists(atPath: s.paths.title.path))
        #expect(s.resolve() == ["Weekly sync", "calendar"])
        try Titles.save(s.paths, "")  // nothing to remove is no error (missing_ok)
    }

    @Test func test_what_is_known_already_is_not_read_again() throws {
        let s = try Setup(event: "Weekly sync", notesTitle: "Budget talk"); defer { s.t.remove() }
        #expect(s.resolve(event: .known(nil), notes: .known(nil)) == [nil, nil])
        #expect(s.resolve(event: .known(nil)) == ["Budget talk", "notes"])
        #expect(s.resolve(notes: .known(nil)) == ["Weekly sync", "calendar"])
        let given = try PythonJSON.parse(Data(#"{"title": "Given"}"#.utf8))
        #expect(s.resolve(event: .known(nil), notes: .known(given)) == ["Given", "notes"])
    }

    @Test func test_a_broken_title_file_is_no_title() throws {
        let s = try Setup(event: "Weekly sync"); defer { s.t.remove() }
        try Data("{not json".utf8).write(to: s.paths.title)
        #expect(Titles.load(s.paths) == nil)
        try Data(#"{"title": 42}"#.utf8).write(to: s.paths.title)
        #expect(s.resolve() == ["Weekly sync", "calendar"])
        try Data(#"["title"]"#.utf8).write(to: s.paths.title)
        #expect(Titles.load(s.paths) == nil)
        try Data(#"{"title": "  Padded  "}"#.utf8).write(to: s.paths.title)
        #expect(Titles.load(s.paths) == "Padded")
    }

    @Test func test_a_title_is_cleaned_and_capped() throws {
        #expect(Titles.clean("  Budget\n with  Anna \t") == "Budget with Anna")
        #expect(Titles.clean(String(repeating: "x", count: 250)) == String(repeating: "x", count: Titles.maxLength))
        #expect(Titles.clean("   ") == "")
        #expect(throws: TitleError.self) { try Titles.clean(nil) }
        #expect(throws: TitleError.self) { try Titles.clean(.array([.string("Budget")])) }
        #expect(try Titles.clean(.string(" Budget ")) == "Budget")
    }

    @Test func test_the_fallback_says_when_the_meeting_started() throws {
        let vienna = try #require(TimeZone(identifier: "Europe/Vienna"))
        #expect(Titles.fallback("2026-10-27T12:04:00+01:00", timeZone: vienna) == "Meeting at 12:04")
        #expect(Titles.fallback("2026-10-27T12:04:00+01:00", timeZone: TimeZone(identifier: "UTC")!) == "Meeting at 11:04")
        #expect(Titles.fallback("2026-07-01T00:05:00Z", timeZone: vienna) == "Meeting at 02:05")  // summer time
        #expect(Titles.fallback("2026-10-27T09:07:00", timeZone: vienna) == "Meeting at 09:07")  // no zone: this clock
        #expect(Titles.fallback(nil) == "Meeting" && Titles.fallback("") == "Meeting" && Titles.fallback("soon") == "Meeting")
        // This Mac's clock, as `astimezone()` reads it.
        let here = DateFormatter(); here.dateFormat = "HH:mm"; here.timeZone = .current
        #expect(Titles.fallback("2026-10-27T12:04:00+01:00") == "Meeting at \(here.string(from: Self.START.date))")
    }

    @Test func theImportedTitleCountsBeforeTheEvent() throws {
        let s = try Setup(event: "Weekly sync"); defer { s.t.remove() }
        try Data(#"{"title": "  Sent\n by  Valerie ", "other": 1}"#.utf8).write(to: s.paths.imported)
        #expect(Titles.imported(s.paths) == "Sent by Valerie")
        #expect(s.resolve() == ["Sent by Valerie", "imported"])
        try Data(#"{"title": "   "}"#.utf8).write(to: s.paths.imported)
        #expect(s.resolve() == ["Weekly sync", "calendar"])
    }

    @Test func theNotesFileIsWhatTheNotesSay() throws {
        let s = try Setup(notesTitle: "T"); defer { s.t.remove() }
        #expect(NotesFile.load(s.paths)?["title"]?.stringValue == "T")
        try Data("{broken".utf8).write(to: s.paths.notes)
        #expect(NotesFile.load(s.paths) == nil)
        try FileManager.default.removeItem(at: s.paths.notes)
        #expect(NotesFile.load(s.paths) == nil)
    }
}
