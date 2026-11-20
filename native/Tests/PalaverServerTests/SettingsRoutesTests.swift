// The Settings page's switches and Storage section, the coach's pages, what the page counts, and Report a Problem
// (api.py `get_settings`, `set_settings`, `switches_turned_off`, `storage_status`, `set_storage`, `coach_meeting`,
// `coach_overview`, `record_usage`, `create_report`; server.py's branches and `count_setting`). Ports their tests of
// tests/test_webapp.py, test_report_api.py, test_webapp_remote.py and the route half of test_coach.py. Report a
// Problem's route is tested in ReportTests.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"

private func dumps(_ v: JSONValue?) -> String { v.map { PythonJSON.dumps($0, ensureAscii: false) } ?? "nil" }
private func parse(_ s: String) -> JSONValue { try! PythonJSON.parse(Data(s.utf8)) }

private func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// A transcribed meeting with its audio, as test_webapp.py `_meeting` leaves it as far as these routes look.
@discardableResult
private func meeting(_ root: URL, _ name: String = MEETING) throws -> RecordingPaths {
    let paths = RecordingPaths(root.appendingPathComponent(name, isDirectory: true))
    try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
    for track in [paths.systemWav, paths.micWav] { try Data(repeating: 1, count: 3200).write(to: track) }
    try write(paths.meta, #"{"start_time": "2026-10-27T16:03:07+01:00", "duration_seconds": 20}"#)
    try write(paths.transcriptJson, "[]")
    return paths
}

/// test_coach.py's `_meeting` with its `LINES`: meta.json, the transcript (labels for SPEAKER_xx), no system turns.
private func coachMeeting(_ root: URL, _ name: String) throws {
    let lines: [(String, Double, Double, String)] = [
        ("Timo", 0, 100, "Also ich habe das halt irgendwie quasi so gedacht, halt ganz anders und irgendwie besser."),
        ("Timo", 101, 200, "Und dann halt nochmal, weil das halt wichtig ist und ich das so sehe, ähm, genau."),
        ("SPEAKER_00", 205, 230, "Okay, verstehe ich, und was machen wir mit dem Budget, das ist ja noch offen?"),
        ("Timo", 228, 240, "Das Budget klären wir morgen mit dem Team, ganz sicher."),
        ("SPEAKER_00", 240.5, 241, "Ja."),
        ("Timo", 245, 250, "Wie siehst du das?"),
        ("SPEAKER_00", 254, 280, "Ich finde das gut, wir sollten aber die Kosten im Blick behalten."),
    ]
    let paths = RecordingPaths(root.appendingPathComponent(name, isDirectory: true))
    try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
    try PythonJSON.write(.object([("start_time", .string("2026-10-27T10:00:00+01:00")), ("duration_seconds", .int(900))]),
                         to: paths.meta, indent: nil, ensureAscii: true)
    try PythonJSON.write(.array(lines.map { who, s, e, t in
        var fields: [(String, JSONValue)] = [("speaker", .string(who)), ("start", .double(s)), ("end", .double(e)),
                                             ("text", .string(t))]
        if who.hasPrefix("SPEAKER") { fields.append(("label", .string(who))) }
        return .object(fields)
    }), to: paths.transcriptJson, indent: nil, ensureAscii: true)
    try PythonJSON.write(.array([]), to: paths.systemTurns, indent: nil, ensureAscii: true)
}

/// A provider helper that answers every change with an empty page.
private final class QuietProvider: ProviderHelper {
    func call(_ action: String, body: JSONValue, timeout: Double) throws -> JSONValue { .object([]) }
}

@Suite struct SettingsRoutesTests {
    // MARK: - settings (test_webapp.py, test_report_api.py, test_webapp_remote.py)

    @Test func test_http_settings_and_a_change_is_counted_by_its_key() throws {
        let s = try TestServer(meetings: { try meeting($0) })
        defer { s.stop() }
        var r = s.get("/api/settings")
        #expect(r.status == 200 && r.json?["realtime"] == .bool(true))
        r = s.post("/api/settings", .object([("realtime", .bool(false))]))
        #expect(r.status == 200 && r.json?["realtime"] == .bool(false))
        #expect(s.get("/api/settings").json?["realtime"] == .bool(false))
        // A settings change is counted by its key.
        let settings = Usage.read(s.app.stores.usage).filter { $0["kind"] == .string("setting") }
        #expect(settings.count == 1)
        #expect(settings.first?["id"] == .string("realtime") && settings.first?["value"] == .bool(false))
        r = s.post("/api/settings", .object([("realtime", .string("yes"))]))
        #expect(r.status == 400 && r.error == "bad request: realtime must be true or false")
    }

    @Test func test_set_settings_writes_only_what_changed() throws {
        let s = try TestServer()
        defer { s.stop() }
        let stores = s.app.stores
        func file() -> String { dumps(PythonJSON.read(stores.settings)) }
        var noSlack = SettingsValues()  // config.toml: [recording] slack = false
        noSlack.recordSlack = false
        #expect(try SettingsAPI.set(.object([("realtime", .bool(false))]), defaults: noSlack, stores: stores)["record_slack"]
                == .bool(false))
        #expect(file() == #"{"realtime": false}"#)
        #expect(SettingsAPI.get(defaults: SettingsValues(), stores: stores)["record_slack"] == .bool(true))  // config.toml changed
        try write(stores.settings, #"{"realtime": false, "future": 1}"#)
        #expect(dumps(try SettingsAPI.set(.object([("record_teams", .bool(false))]), defaults: noSlack, stores: stores)) == dumps(parse("""
            {"realtime": false, "record_teams": false, "record_slack": false, "search_meaning": true,
             "live_processing": true, "nudge_talk_share": true, "nudge_monologue": true, "nudge_quiet_invitee": true,
             "nudge_pace": false, "nudge_fillers": false, "nudge_notify": true, "check_updates": true,
             "share_usage": true, "respect_call_mute": true}
            """)))
        #expect(file() == #"{"realtime": false, "future": 1, "record_teams": false}"#)
        try write(stores.settings, "[broken")
        _ = try SettingsAPI.set(.object([("record_slack", .bool(true))]), defaults: noSlack, stores: stores)
        #expect(file() == #"{"record_slack": true}"#)
        // The server's own defaults (config.toml's) are what GET answers for a key settings.json leaves out.
        let t = try TestServer(settingsDefaults: noSlack)
        defer { t.stop() }
        #expect(t.get("/api/settings").json?["record_slack"] == .bool(false))
    }

    @Test func test_http_a_record_switch_turned_off_stops_its_call_now() throws {
        let rec = FakeRecording()
        let s = try TestServer(recording: rec)
        defer { s.stop() }
        #expect(s.post("/api/settings", .object([("record_teams", .bool(false))])).status == 200)
        #expect(s.post("/api/settings", .object([("record_slack", .bool(true))])).status == 200)
        #expect(s.post("/api/settings", .object([("record_slack", .bool(false)), ("realtime", .bool(false))])).status == 200)
        #expect(rec.off == ["teams", "slack"])
        // A refused change tells nobody; outside the app there is nobody to tell.
        #expect(s.post("/api/settings", .object([("record_teams", .bool(false)), ("realtime", .int(1))])).status == 400)
        #expect(rec.off == ["teams", "slack"])
        let none = try TestServer()
        defer { none.stop() }
        #expect(none.post("/api/settings", .object([("record_teams", .bool(false))])).status == 200)
    }

    /// Every change of the Settings page is counted by its key (`_SETTINGS_PATHS`).
    @Test func everySettingsPathIsCountedInTheUsageLog() throws {
        let s = try TestServer(provider: QuietProvider())
        defer { s.stop() }
        for path in SettingsAPI.SETTINGS_PATHS {
            let body: JSONValue = Py.same(path, "/api/settings") ? .object([("realtime", .bool(false))])
                : .object([("provider", .string("anthropic")), ("remove", .bool(true))])
            #expect(s.post(path, body).status == 200)
        }
        #expect(Usage.read(s.app.stores.usage).filter { $0["kind"] == .string("setting") }.count == SettingsAPI.SETTINGS_PATHS.count)
    }

    // MARK: - storage (test_webapp.py)

    @Test func test_http_storage_reads_and_sets_the_days() throws {
        let s = try TestServer(meetings: { try meeting($0) })
        defer { s.stop() }
        var r = s.get("/api/storage")
        #expect(r.status == 200 && r.json?["meetings"] == .int(1) && r.json?["audio_days"] == .int(0))
        #expect(r.json?["models"] == .array([]))  // no model in this test's home
        r = s.post("/api/storage", .object([("audio_days", .int(7)), ("now", .bool(true))]))
        #expect(r.status == 200 && r.json?["audio_days"] == .int(7))
        guard case .object(let dropped)? = r.json?["dropped"] else { Issue.record("no dropped: \(r.text)"); return }
        #expect(dropped.map(\.0) == ["meetings", "bytes"])  // what goes by age: StorageTests
        r = s.post("/api/storage", .object([("audio_days", .int(5))]))
        #expect(r.status == 400 && r.error == "bad request: audio_days must be one of 0, 7, 14, 30, 90")
        r = s.post("/api/storage", .object([("audio_days", .int(14))]))
        #expect(r.status == 200 && r.json?["audio_days"] == .int(14) && r.json?["dropped"] == .null)
        r = s.post("/api/storage", .object([("delete_model", .string("mlx-community/gemma-4-12B-it-OptiQ-4bit"))]))
        #expect(r.status == 400 && r.error == "bad request: only a notes model Palaver doesn't use can be deleted")
    }

    // MARK: - the coach (test_coach.py)

    @Test func test_the_window_gets_numbers_and_an_overview() throws {
        let s = try TestServer(userName: "Timo", meetings: { try coachMeeting($0, "2026-10-27T10-00-00") })
        defer { s.stop() }
        var r = s.get("/api/meetings/2026-10-27T10-00-00/coach")
        #expect(r.status == 200)
        #expect(r.json?["baseline"]?["meetings"] == .int(1) && r.json?["highlights"]?.arrayValue?.isEmpty == false)
        guard case .object(let fields)? = r.json else { Issue.record("\(r.text)"); return }
        #expect(fields.suffix(3).map(\.0) == ["baseline", "highlights", "live"])  // after the numbers
        r = s.get("/api/coach")
        #expect(r.status == 200)
        let row = try #require(r.json?["meetings"]?.arrayValue?.first)
        #expect(row["longest"] == .int(200) && row["questions"] == .int(1))
        #expect(row["title"] != nil && row["id"] == .string("2026-10-27T10-00-00"))
        #expect(dumps(r.json?["trends"]?["weeks"]) == dumps(.array([.object([
            ("week", .string("2026-10-26")), ("meetings", .int(1)), ("share", .double(0.807)), ("wpm", row["wpm"]!),
            ("fillers", row["fillers"]!),
        ])])))
        #expect(r.json?["trends"]?["kinds"]?.arrayValue?.map { $0["kind"] } == [.string("1:1")])
        #expect(r.json?["baseline"]?["meetings"] == .int(1))
    }

    /// The overview's numbers for the charts (#43): per meeting its length, words, people and glossary terms; the
    /// totals; the share by meeting size.
    @Test func theOverviewHasWhatTheChartsNeed() throws {
        let s = try TestServer(userName: "Timo", meetings: { root in
            try coachMeeting(root, "2026-10-27T10-00-00")
            try coachMeeting(root, "2026-10-28T10-00-00")
        })
        defer { s.stop() }
        try write(s.app.stores.glossary, #"{"terms": {"t1": {"term": "Budget", "variants": ["Bucket"], "note": ""}}, "rejected": []}"#)
        let r = s.get("/api/coach")
        #expect(r.status == 200)
        let rows = try #require(r.json?["meetings"]?.arrayValue)
        #expect(rows.map { $0["id"] } == [.string("2026-10-28T10-00-00"), .string("2026-10-27T10-00-00")])
        let row = rows[0]
        let mine = ["Also ich habe das halt irgendwie quasi so gedacht, halt ganz anders und irgendwie besser.",
                    "Und dann halt nochmal, weil das halt wichtig ist und ich das so sehe, ähm, genau.",
                    "Das Budget klären wir morgen mit dem Team, ganz sicher.", "Wie siehst du das?"]
        let theirs = ["Okay, verstehe ich, und was machen wir mit dem Budget, das ist ja noch offen?", "Ja.",
                      "Ich finde das gut, wir sollten aber die Kosten im Blick behalten."]
        let said = mine.reduce(0) { $0 + Coach.words($1) }, all = said + theirs.reduce(0) { $0 + Coach.words($1) }
        #expect(row["kind"] == .string("1:1") && row["fair"] == .double(0.5) && row["duration"] == .int(900))
        #expect(row["words"] == .int(said) && row["words_all"] == .int(all))
        #expect(row["cut_off"] == .int(0) && row["monologues"] == .int(1) && row["minutes_talked"] == .double(3.6))
        #expect(row["names"] == .array([]) && row["projects"] == .array([]) && row["series"] == .null)
        #expect(dumps(row["terms"]) == #"[{"term": "Budget", "count": 2}]"#)
        let totals = try #require(r.json?["totals"])
        #expect(totals["meetings"] == .int(2) && totals["seconds"] == .int(1800) && totals["talked_seconds"] == .int(432))
        #expect(totals["words"] == .int(2 * said) && totals["words_all"] == .int(2 * all))
        #expect(totals["longest"]?["id"] == .string("2026-10-27T10-00-00") && totals["longest"]?["seconds"] == .int(900))
        #expect(dumps(r.json?["by_size"]) == #"[{"size": "2", "meetings": 2, "share": 0.807, "fair": 0.5}]"#)
    }

    @Test func theTotalsCountThePeopleMetMostAndTheSizesGoUpToFivePlus() throws {
        func row(_ id: String, people: Int, share: JSONValue, fair: JSONValue, names: [String], duration: Int) -> JSONValue {
            .object([("id", .string(id)), ("title", .string("Meeting \(id)")), ("people", .int(people)), ("share", share),
                     ("fair", fair), ("names", .strings(names)), ("duration", .int(duration)),
                     ("minutes_talked", .double(1.5)), ("words", .int(10)), ("words_all", .int(30))])
        }
        let rows = [  // newest first, as the overview has them
            row("d", people: 10, share: .double(0.1), fair: .double(0.1), names: ["Valerie", "Carla"], duration: 600),
            row("c", people: 5, share: .double(0.3), fair: .double(0.2), names: ["Carla"], duration: 1200),
            row("b", people: 3, share: .null, fair: .null, names: ["Valerie"], duration: 1200),
            row("a", people: 2, share: .double(0.5), fair: .double(0.5), names: ["Dana"], duration: 300),
        ]
        let totals = CoachAPI.totals(rows)
        #expect(totals["longest"]?["id"] == .string("b"))  // the first of the longest
        #expect(dumps(totals["people"])
            == #"[{"name": "Valerie", "meetings": 2}, {"name": "Carla", "meetings": 2}, {"name": "Dana", "meetings": 1}]"#)
        #expect(totals["seconds"] == .int(3300) && totals["talked_seconds"] == .int(360) && totals["words_all"] == .int(120))
        // A meeting without a share (a shared microphone) is left out; 5 and 10 people are both 5+.
        #expect(dumps(try CoachAPI.bySize(rows)) == #"[{"size": "2", "meetings": 1, "share": 0.5, "fair": 0.5}, "#
            + #"{"size": "5+", "meetings": 2, "share": 0.2, "fair": 0.15}]"#)
    }

    @Test func aMeetingWithoutATranscriptHasNoCoachPage() throws {
        let s = try TestServer(meetings: { root in
            try meeting(root)
            try FileManager.default.removeItem(at: RecordingPaths(root.appendingPathComponent(MEETING)).transcriptJson)
        })
        defer { s.stop() }
        #expect(s.get("/api/meetings/\(MEETING)/coach").error == "not found: \(MEETING)")
        #expect(s.get("/api/meetings/nope/coach").status == 404)
        let r = s.get("/api/coach")
        #expect(r.status == 200 && r.json?["meetings"] == .array([]))
    }

    // MARK: - usage (test_report_api.py)

    @Test func test_http_usage_records_the_pages_events_and_keeps_its_catalog() throws {
        let s = try TestServer()
        defer { s.stop() }
        let r = s.post("/api/usage", parse("""
            {"events": [{"kind": "action", "id": "meeting.trash"}, {"kind": "view", "id": "people"},
                        {"kind": "error", "text": "Not joined: boom"}, {"kind": "recording_stop", "seconds": 1},
                        "nonsense"],
             "catalog": {"action": ["meeting.trash", "meeting.split"]}}
            """))
        #expect(r.status == 200 && r.json == .object([("ok", .bool(true))]))
        let events = Usage.read(s.app.stores.usage)
        #expect(events.map { [$0["kind"] ?? .null, $0["id"] ?? .null] }
                == [[.string("action"), .string("meeting.trash")], [.string("view"), .string("people")], [.string("error"), .null]])
        #expect(events.count == 3 && events[2]["text"] == .string("Not joined: boom"))
        // The window's half of `usage.catalog()` (Python merges the CLI's and the menu bar's into it).
        #expect(dumps(PythonJSON.read(s.app.stores.usageFeatures)) == #"{"action": ["meeting.split", "meeting.trash"]}"#)
        #expect(s.post("/api/usage", .object([("events", .string("x"))])).error == "bad request: events is a list")
        // At most MAX_USAGE_EVENTS of a post; an id cut to 80.
        let many = (0..<250).map { _ in JSONValue.object([("kind", .string("tab")), ("id", .string(String(repeating: "é", count: 100)))]) }
        #expect(s.post("/api/usage", .object([("events", .array(many))])).status == 200)
        let tabs = Usage.read(s.app.stores.usage).filter { $0["kind"] == .string("tab") }
        #expect(tabs.count == UsageAPI.MAX_USAGE_EVENTS && tabs[0]["id"] == .string(String(repeating: "é", count: 80)))
    }

    // Report a Problem (test_report_api.py's report tests): ReportTests (the zip in Swift, its route).

    // MARK: - the last failed run (test_report_api.py)

    @Test func test_a_failed_run_is_found_until_it_is_done_right() throws {
        let dir = tempFolder("failure")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = RecordingPaths(dir.appendingPathComponent("m", isDirectory: true))
        func log(_ rows: [String]) throws -> JSONValue? {
            try write(paths.sessionLog, rows.map { $0 + "\n" }.joined())
            return MeetingsAPI.lastFailure(paths)
        }
        let ok = [#"{"event": "process_start"}"#, #"{"event": "notes_start"}"#, #"{"event": "notes_done"}"#,
                  #"{"event": "process_done", "rc": 0}"#]
        #expect(try log(ok) == nil)
        let notes = [#"{"event": "process_start"}"#, #"{"event": "notes_start"}"#,
                     #"{"event": "notes_failed", "error": "the model ran out of memory"}"#, #"{"event": "process_done", "rc": 0}"#]
        #expect(try log(notes)?["step"] == .string("notes"))
        #expect(try log(notes)?["error"] == .string("the model ran out of memory"))
        let crashed = [#"{"event": "process_start"}"#, #"{"event": "transcribe_start"}"#,
                       #"{"level": "ERROR", "message": "command failed", "traceback": "Traceback…\nRuntimeError: no GPU"}"#]
        #expect(try dumps(log(crashed)) == #"{"step": "process", "error": "RuntimeError: no GPU", "at": null}"#)
        let again = [#"{"event": "process_done", "rc": 3}"#, #"{"event": "process_start"}"#, #"{"event": "process_done", "rc": 0}"#]
        #expect(try log(again) == nil)
    }
}
