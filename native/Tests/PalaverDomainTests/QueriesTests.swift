// `palaver-worker query`: the facts the app asks (tests/test_app_query.py's tests of the four queries the pipeline
// owns). Fake calendars only: no EventKit, no real meetings.
import Foundation
import PalaverCore
@testable import PalaverDomain
import Testing

@Suite struct QueriesTests {
    private func config(_ dir: URL) -> Config {
        var c = Config()
        c.outputDir = dir
        return c
    }

    private func parse(_ line: String) -> JSONValue { try! PythonJSON.parse(Data(line.utf8)) }

    private func event(_ title: String, _ start: PyDateTime, uid: String, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(title: title, start: start, end: try! start.adding(seconds: 3600),
                      attendees: [Attendee(name: "Timo Strauß")], allDay: allDay, uid: uid)
    }

    @Test func test_query_answers_one_json_line() throws {
        let t = TempFolder("queries"); defer { t.remove() }
        let r = Queries.run("index-stale", args: [], config: { self.config(t.url) }, calendar: { _ in nil })
        #expect(r.code == 0)
        #expect(!r.line.contains("\n"))
        #expect(parse(r.line)["stale"] == .array([]))
    }

    @Test func test_notes_memory_follows_the_choice_and_the_meeting() throws {
        let t = TempFolder("queries"); defer { t.remove() }
        let stores = StorePaths(configDir: t.url.appendingPathComponent("config"), home: t.url.appendingPathComponent("home"))
        let folder = t.url.appendingPathComponent("m")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(Queries.notesMemory(folder: folder, config: config(t.url), stores: stores)["gb"] == .double(14.0))  // the local model
        try SettingsFile.update([("engines", .object([("notes", .string("anthropic")), ("projects", .string("anthropic"))]))],
                                stores: stores)
        #expect(Queries.notesMemory(folder: folder, config: config(t.url), stores: stores)["gb"] == .double(0.0))  // cloud models
        try "{}".write(to: RecordingPaths(folder).localOnly, atomically: true, encoding: .utf8)
        #expect(Queries.notesMemory(folder: folder, config: config(t.url), stores: stores)["gb"] == .double(14.0))  // kept here
    }

    /// #26: notes by a cloud model, then the projects sort on the local model (chosen: local) in the same run.
    @Test func notesMemoryCountsTheLocalProjectsSortAfterCloudNotes() throws {
        let t = TempFolder("queries"); defer { t.remove() }
        let stores = StorePaths(configDir: t.url.appendingPathComponent("config"), home: t.url.appendingPathComponent("home"))
        let folder = t.url.appendingPathComponent("m")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SettingsFile.update([("engines", .object([("notes", .string("claude-cli")), ("projects", .string("local"))]))], stores: stores)
        #expect(Queries.notesMemory(folder: folder, config: config(t.url), stores: stores)["gb"] == .double(14.0))
        #expect(Queries.notesMemory(folder: t.url, config: config(t.url), stores: stores)["gb"] == .double(14.0))  // the Recordings folder
    }

    @Test func test_missing_models_lists_the_labels() throws {
        let t = TempFolder("queries"); defer { t.remove() }
        let folder = t.url.appendingPathComponent("m")
        var asked = 0
        let out = Queries.missingModels(folder: folder, config: config(t.url), speechModelsHere: { asked += 1; return false })
        #expect(PythonJSON.dumps(out) == #"{"missing": ["Speech models"]}"#)
        #expect(asked == 1)
        // Transcribed and diarized: nothing left to download for it, nothing asked.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["mic_segments.json", "system_segments.json", "system_turns.json", "speaker_embeddings.json"] {
            try "[]".write(to: folder.appendingPathComponent(name), atomically: false, encoding: .utf8)
        }
        #expect(Queries.missingModels(folder: folder, config: config(t.url), speechModelsHere: { asked += 1; return false })
                == .object([("missing", .array([]))]))
        #expect(asked == 1)
    }

    @Test func test_index_stale_lists_folders() throws {
        let t = TempFolder("queries"); defer { t.remove() }
        let folder = t.url.appendingPathComponent("2026-10-21T16-29-29")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"[{"speaker": "Timo Strauß", "start": 0.0, "end": 2.0, "text": "Hallo zusammen."}]"#
            .write(to: folder.appendingPathComponent("transcript.json"), atomically: false, encoding: .utf8)
        let out = Queries.indexStale(outputDir: t.url, modelReady: { false })
        #expect(out["stale"] == .strings([folder.path]))
        #expect(out["model_ready"] == .bool(false))
        #expect(Queries.indexStale(outputDir: t.url, modelReady: { true })["model_ready"] == .bool(true))
    }

    @Test func test_next_event_is_the_first_timed_event_to_come() throws {
        let now = Queries.localNow()
        let events = [event("Past", try! now.adding(seconds: -3600), uid: "p"),
                      event("Holiday", try! now.adding(seconds: 3600), uid: "h", allDay: true),
                      event("Later", try! now.adding(seconds: 5 * 3600), uid: "l"),
                      event("Sync KLOUD", try! now.adding(seconds: 2 * 3600), uid: "s")]
        var window: (Date, Date)?
        let out = try Queries.nextEvent(calendar: { a, b in window = (a, b); return events }, now: now)
        #expect(out["event"]?["title"] == .string("Sync KLOUD"))
        #expect(out["event"]?["key"]?.stringValue?.hasPrefix("s|") == true)
        #expect(out["event"]?["start"] == .string(events[3].start.iso))
        let w = try #require(window)
        #expect(abs(w.1.timeIntervalSince(w.0) - 24 * 3600) < 0.001)
    }

    @Test func test_next_event_without_calendar_access_is_null() throws {
        // No provider: the calendar is off, or not allowed.
        #expect(try Queries.nextEvent(calendar: nil) == .object([("event", .null)]))
        let r = Queries.run("next-event", args: [], config: { Config() }, calendar: { _ in nil })
        #expect(r.code == 0 && r.line == #"{"event": null}"#)
    }

    @Test func test_event_key_at_a_time() throws {
        let when = try PyDateTime.parse("2026-11-04T10:30:00+01:00")
        let ev = event("Sync", try! when.adding(seconds: -1800), uid: "abc")
        var window: (Date, Date)?
        let out = try Queries.eventKey(at: when.iso, calendar: { a, b in window = (a, b); return [ev] })
        #expect(out == .object([("key", .string(ev.key))]))
        let w = try #require(window)
        #expect(abs(w.1.timeIntervalSince(w.0) - 4 * 3600) < 0.001)
        #expect(try Queries.eventKey(at: when.iso, calendar: nil) == .object([("key", .null)]))
        #expect(try Queries.eventKey(at: when.iso, calendar: { _, _ in [] }) == .object([("key", .null)]))
        // A time without an offset is local time.
        let naive = try Queries.eventKey(at: "2026-11-04T10:30:00", calendar: { a, _ in
            #expect(abs(a.timeIntervalSince(Queries.localized(try! PyDateTime.parse("2026-11-04T08:30:00")).date)) < 1)
            return []
        })
        #expect(naive == .object([("key", .null)]))
    }

    @Test func test_bad_usage_and_failures_are_json_errors() throws {
        let cfg: () throws -> Config = { Config() }
        var r = Queries.run("nope", args: [], config: cfg, calendar: { _ in nil })
        #expect(r.code == 2 && parse(r.line)["error"]?.stringValue?.contains("usage") == true)
        r = Queries.run("missing-models", args: [], config: cfg, calendar: { _ in nil })
        #expect(r.code == 2)
        r = Queries.run("event-key", args: ["not a time"], config: cfg, calendar: { _ in nil })
        #expect(r.code == 1 && parse(r.line)["error"] != nil)
        struct Broken: Error, CustomStringConvertible { var description: String { "config.toml is malformed" } }
        r = Queries.run("index-stale", args: [], config: { throw Broken() }, calendar: { _ in nil })
        #expect(r.code == 1 && r.line == #"{"error": "config.toml is malformed"}"#)
    }
}
