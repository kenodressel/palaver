// Meetings from before Palaver (#4): a Notion AI meeting note taken in as a meeting folder without audio — the summary
// as notes, the transcript spread over the meeting, the attendees as its people, and no import of a note twice or of a
// call Palaver recorded. Fictional people and companies only (Valerie, Timo Strauß, Anna, Contoso, Northwind); the
// Notion links are made up.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct LegacyImportTests {
    static let berlin = TimeZone(identifier: "Europe/Berlin")!
    static let URL_ = "https://www.notion.so/example-weekly-sync-0123456789abcdef0123456789abcdef"

    static let SUMMARY = """
        ### Action Items

        - [ ] Valerie: send the revised offer to Northwind [^https://app.notion.com/p/example#block-1]
        - [ ] Book the workshop room (Timo Strauß) [^https://app.notion.com/p/example#block-2]
        - [x] Update the roadmap slide

        ### Pricing for Northwind

        - <b>Discount:</b> 10 % for a two-year contract [^https://app.notion.com/p/example#block-3]
            - Anna wants it in writing [^https://app.notion.com/p/example#block-4]
        - <b>Timeline:</b> start in Q2

        ### Hiring

        - Two interviews next week
        """

    static let TRANSCRIPT = """
        Hallo zusammen, let's start with the pricing for Northwind.

        Okay. Wir können zehn Prozent geben,
        if they sign for two years.

        Good, then Valerie sends the offer.
        """

    static func time(_ text: String) -> ExchangeTime { try! JSONSchemaCheck.time(text, where: "test") }

    static func note(start: String = "2026-03-04T10:00:00+01:00", end: String? = "2026-03-04T10:30:00+01:00",
                     attendees: [String] = [], id: String = "0123456789abcdef0123456789abcdef",
                     transcript: String = TRANSCRIPT, summary: String = SUMMARY) -> LegacyNote {
        LegacyNote(title: "Weekly sync", start: time(start), end: end.map(time), attendees: attendees, summary: summary,
                   transcript: transcript, sourceURL: id.isEmpty ? "" : URL_, sourceId: id)
    }

    /// Recordings and stores in a folder of the test's own.
    final class World {
        let t = TempFolder("legacy")
        let out: URL
        let stores: StorePaths

        init() {
            out = t.url.appendingPathComponent("Meetings", isDirectory: true)
            stores = StorePaths(configDir: t.url.appendingPathComponent("cfg/palaver"), home: t.url)
        }

        deinit { t.remove() }

        func run(_ note: LegacyNote, user: String = "Timo") throws -> LegacyImported {
            try LegacyImport.importNote(note, outputDir: out, userName: user, stores: stores,
                                        now: Date(timeIntervalSince1970: 1_790_000_000), timeZone: LegacyImportTests.berlin)
        }

        func paths(_ id: String) -> RecordingPaths { RecordingPaths(out.appendingPathComponent(id, isDirectory: true)) }

        /// A recording of Palaver's own that started at `start` and took `seconds`.
        func recording(_ id: String, start: String, seconds: Double) throws {
            let paths = paths(id)
            try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
            try PythonJSON.write(.object([("start_time", .string(start)), ("duration_seconds", .double(seconds))]),
                                 to: paths.meta, indent: 2, ensureAscii: true)
            try PythonJSON.write(.array([]), to: paths.transcriptJson, indent: 2, ensureAscii: true)
        }
    }

    // MARK: - the summary

    @Test func notionsSummaryBecomesTheNotesShape() {
        let (summary, sections, steps) = LegacyImport.notes(fromSummary: Self.SUMMARY)
        #expect(summary == "Topics: Pricing for Northwind, Hiring.")
        #expect(steps == [
            .object([("owner", .string("Valerie")), ("task", .string("send the revised offer to Northwind"))]),
            .object([("owner", .string("Timo Strauß")), ("task", .string("Book the workshop room"))]),
            .object([("owner", .string("")), ("task", .string("Update the roadmap slide"))]),
        ])
        #expect(sections.count == 2)
        #expect(sections[0]["heading"] == .string("Pricing for Northwind"))
        #expect(sections[0]["points"] == .array([
            .object([("text", .string("Discount: 10 % for a two-year contract")), ("details", .strings(["Anna wants it in writing"]))]),
            .object([("text", .string("Timeline: start in Q2")), ("details", .strings([]))]),
        ]))
        #expect(sections[1]["points"]?.arrayValue?.first?["text"] == .string("Two interviews next week"))
    }

    @Test func leadTextIsTheSummary() {
        let (summary, sections, _) = LegacyImport.notes(fromSummary: "Contoso's kickoff went well.\n\n## Scope\n* Phase one only")
        #expect(summary == "Contoso's kickoff went well.")
        #expect(sections == [.object([("heading", .string("Scope")),
                                      ("points", .array([.object([("text", .string("Phase one only")), ("details", .strings([]))])]))])])
    }

    // MARK: - the transcript

    @Test func paragraphsAreSpreadOverTheMeetingByWords() {
        let lines = LegacyImport.paragraphs(Self.TRANSCRIPT)
        #expect(lines == ["Hallo zusammen, let's start with the pricing for Northwind.",
                          "Okay. Wir können zehn Prozent geben, if they sign for two years.",
                          "Good, then Valerie sends the offer."])
        let u = LegacyImport.utterances(lines, duration: 270)  // 9 + 12 + 6 words
        #expect(u.map(\.start) == [0, 90, 210] && u.map(\.end) == [90, 210, 270])
        #expect(u.allSatisfy { $0.speaker == LegacyImport.LABEL && $0.label == nil })
    }

    // MARK: - import

    @Test func aNoteBecomesAMeetingLikeARecording() throws {
        let w = World()
        let result = try w.run(Self.note())
        #expect(result == LegacyImported(outcome: .imported, id: "2026-03-04T10-00-00", title: "Weekly sync"))
        let paths = w.paths(result.id)
        let meta = try #require(PythonJSON.read(paths.meta))
        #expect(meta["start_time"] == .string("2026-03-04T10:00:00+01:00") && meta["end_time"] == .string("2026-03-04T10:30:00+01:00"))
        #expect(meta["duration_seconds"] == .double(1800) && meta["trigger"] == .string("import"))
        let lines = try (PythonJSON.read(paths.transcriptJson)?.arrayValue ?? []).map { try Utterance(json: $0) }
        #expect(lines.count == 3 && lines[0].start == 0 && lines[2].end == 1800)
        #expect(Speakers.loadUnknown(paths) == [LegacyImport.LABEL])
        #expect(MeetingStatus.status(paths) == "processed")
        #expect(!FileManager.default.fileExists(atPath: paths.systemWav.path))
        #expect(FileManager.default.fileExists(atPath: paths.transcriptMd.path))
        // Notion's notes, current: nothing writes them again unless asked.
        let notes = try #require(Notes.load(paths))
        #expect(notes["source"] == .string("notion") && notes["title"] == .string("Weekly sync"))
        #expect(notes["next_steps"]?.arrayValue?.count == 3 && notes["decisions"] == .array([]))
        #expect(Notes.staleReason(paths, lines) == nil)
        let source = try #require(LegacyImport.source(paths))
        #expect(source["kind"] == .string("notion") && source["url"] == .string(Self.URL_))
        #expect(source["id"] == .string("0123456789abcdef0123456789abcdef"))
        #expect(source["content_hash"] == .string(LegacyImport.contentHash(Self.note())))
        #expect(CalendarEvents.load(paths) == nil)  // no attendees: no event
        #expect(Titles.resolve(paths, stores: w.stores).title == "Weekly sync")
        #expect(!FileManager.default.fileExists(atPath: w.out.appendingPathComponent(Exchange.STAGING).path))
    }

    @Test func attendeesAreTheMeetingsPeople() throws {
        let w = World()
        let result = try w.run(Self.note(attendees: ["Valerie", "Timo", "Anna Huber (Northwind)"]))
        let event = try #require(CalendarEvents.load(w.paths(result.id)))
        #expect(event.attendees.map(\.name) == ["Valerie", "Timo", "Anna Huber"])
        #expect(event.attendees.allSatisfy { $0.email == nil })
        #expect(event.attendees.map(\.isSelf) == [false, true, false])
        #expect(CalendarEvents.candidates(event, userName: "Timo").map(\.name) == ["Valerie", "Anna Huber"])
        #expect(CalendarEvents.loadLink(w.paths(result.id))?.reason == "from the Notion meeting note")
        let facts = try ProjectRules.facts(w.paths(result.id), userName: "Timo", stores: w.stores)
        #expect(Set(facts.people) == ["valerie", "anna huber"])
    }

    @Test func withoutAnEndTheWordsSayHowLong() throws {
        let w = World()
        let words = Array(repeating: "Wort", count: 300).joined(separator: " ")
        let result = try w.run(Self.note(end: nil, transcript: words))
        #expect(PythonJSON.read(w.paths(result.id).meta)?["duration_seconds"] == .double(120))
        // A note of a few words still lasts a minute.
        let short = try w.run(Self.note(start: "2026-03-05T09:00:00Z", end: nil, id: "other", transcript: "Kurz."))
        #expect(short.id == "2026-03-05T10-00-00")  // the folder is named on this Mac's clock
        #expect(PythonJSON.read(w.paths(short.id).meta)?["duration_seconds"] == .double(60))
    }

    @Test func theSameNoteTwiceIsImportedOnce() throws {
        let w = World()
        let first = try w.run(Self.note())
        #expect(try w.run(Self.note()) == LegacyImported(outcome: .already, id: first.id, title: "Weekly sync"))
        // Fetched again without its id: the same content.
        #expect(try w.run(Self.note(start: "2026-03-04T10:01:00+01:00", id: "")).outcome == .already)
        // Another note at the same time is a meeting of its own.
        let other = try w.run(Self.note(id: "fedcba", transcript: "Something else entirely."))
        #expect(other.outcome == .imported && other.id == "2026-03-04T10-00-00-2")
    }

    @Test func aCallPalaverRecordedIsNotImportedAgain() throws {
        let w = World()
        try w.recording("2026-03-04T10-02-10", start: "2026-03-04T10:02:10+01:00", seconds: 1500)
        #expect(try w.run(Self.note()) == LegacyImported(outcome: .recorded, id: "2026-03-04T10-02-10", title: ""))
        // The note started in the middle of a recording.
        let mid = World()
        try mid.recording("2026-03-04T09-30-00", start: "2026-03-04T09:30:00+01:00", seconds: 3600)
        #expect(try mid.run(Self.note()).outcome == .recorded)
        // Back to back: the recording before ended as the note began.
        let before = World()
        try before.recording("2026-03-04T09-00-00", start: "2026-03-04T09:00:00+01:00", seconds: 3600)
        #expect(try before.run(Self.note()).outcome == .imported)
    }

    @Test func importedMeetingsAreSortedByTheProjectsRules() throws {
        let w = World()
        let a = try w.run(Self.note(attendees: ["Valerie", "Anna Huber"]))
        let store = ProjectStore(path: w.stores.projects)
        let pid = try store.locked { () throws -> String in
            let pid = try store.create("Northwind")
            _ = try store.assign(a.id, pid, by: "you")
            try store.save()
            return pid
        }
        let b = try w.run(Self.note(start: "2026-03-11T10:00:00+01:00", end: "2026-03-11T10:30:00+01:00",
                                    attendees: ["Valerie", "Anna Huber"], id: "next-week", transcript: "Wieder Northwind."))
        #expect(ProjectStore(path: w.stores.projects).ofMeeting(b.id).map(\.0) == [pid])
    }

    // MARK: - reading a note

    @Test func aNoteFromJSON() throws {
        let json = try PythonJSON.parse(Data(#"""
            {"title": " Weekly   sync ", "start": "2026-03-04T09:00:00.000Z", "attendees": ["Valerie", " Anna  Huber "],
             "summary": "### Hiring\n- One opening", "transcript": "Hallo.",
             "source": {"kind": "notion", "url": "https://www.notion.so/example-abc", "id": "abc"}}
            """#.utf8))
        let note = try LegacyNote(json: json)
        #expect(note.title == "Weekly sync" && note.start == Self.time("2026-03-04T10:00:00+01:00") && note.end == nil)
        #expect(note.attendees == ["Valerie", "Anna Huber"] && note.sourceId == "abc" && note.sourceKind == "notion")
        let flat = try LegacyNote(json: .object([("start", .string("2026-03-04T10:00:00+01:00")), ("transcript", .string("Hallo.")),
                                                 ("source_url", .string("https://www.notion.so/example-abc")),
                                                 ("source_id", .string("abc"))]))
        #expect(flat.sourceURL == "https://www.notion.so/example-abc" && flat.sourceKind == "notion")
    }

    @Test func whatIsNotANote() {
        func refused(_ fields: [(String, JSONValue)]) -> String? {
            do { _ = try LegacyNote(json: .object(fields)); return nil } catch let e as ExchangeRejected { return e.message } catch { return "\(error)" }
        }
        let start: (String, JSONValue) = ("start", .string("2026-03-04T10:00:00+01:00"))
        let words: (String, JSONValue) = ("transcript", .string("Hallo."))
        #expect(refused([words])?.hasPrefix("start is missing") == true)
        #expect(refused([("start", .string("2026-03-04T10:00:00")), words]) == "start has no time zone")
        #expect(refused([start]) == "The note has neither a transcript nor a summary.")
        #expect(refused([start, words, ("end", .string("2026-03-04T09:00:00+01:00"))]) == "end is not after start.")
        #expect(refused([start, words, ("attendees", .string("Valerie"))]) == "attendees is a list of names.")
        #expect(refused([start, words, ("source_url", .string("javascript:alert(1)"))]) == "source url is not a web link.")
        #expect(refused([start, words]) == nil)
    }
}
