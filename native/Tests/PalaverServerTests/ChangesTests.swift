// The meeting changes and ⌘Z (api.py `set_meeting_event`, `forget_rule`, `set_title`, `edit_line`, `trash_meeting`,
// `split_meeting`, `join_meetings`, `delete_audio`, `dismiss_cut`, `set_local_only`, `undo_change`, `_undoable`).
// Ports their tests of test_webapp.py, test_cutting.py, test_attribution.py, test_semantic.py and
// test_webapp_remote.py under their names.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"
private let SR = 16_000

private func write(_ value: JSONValue, to url: URL) throws { try Data(PythonJSON.dumps(value).utf8).write(to: url) }
private func read(_ url: URL) -> JSONValue? { PythonJSON.read(url) }
private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
private func frames(_ url: URL) throws -> Int { try Wav16.info(url).frames }

private extension JSONValue {
    subscript(i: Int) -> JSONValue? { arrayValue.flatMap { $0.indices.contains(i) ? $0[i] : nil } }
    var objectKeys: [String] { if case .object(let f) = self { return f.map(\.0) } else { return [] } }
    var intValue: Int? { if case .int(let i) = self { return i } else { return nil } }
}

/// A recordings folder and the stores in a temporary folder, and the app over them (no HTTP).
private final class Fixture {
    let dir: URL
    let out: URL
    let stores: StorePaths
    let app: ServerApp

    init(calendar: CalendarProvider? = nil, meeting: Bool = true) throws {
        dir = tempFolder("changes")
        out = dir.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                            home: dir.appendingPathComponent("home", isDirectory: true))
        app = ServerApp(outputDir: out, userName: "Timo", stores: stores, calendar: calendar)
        if meeting { try pageMeeting(out) }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var paths: RecordingPaths { paths(MEETING) }
    func paths(_ id: String) -> RecordingPaths { RecordingPaths(out.appendingPathComponent(id, isDirectory: true)) }
    func page(_ id: String = MEETING) throws -> JSONValue { try MeetingsAPI.getMeeting(app: app, id: id) }
    func undo(_ token: String) throws -> [String] { try UndoRoute.undoChange(app, token: token) }
}

/// `_post`: the status and the JSON answer.
private func post(_ s: TestServer, _ path: String, _ body: JSONValue = .object([])) -> (Int, JSONValue) {
    let r = s.post(path, body)
    return (r.status, r.json ?? .null)
}

private func ids(_ s: TestServer) -> [String] {
    (s.get("/api/meetings").json?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
}

/// `.trash/.undo`'s snapshots.
private func snapshots(_ out: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent(".trash/.undo").path)) ?? []
}

/// test_webapp.py `_next_meeting`: the same meeting, started 23 s after the first.
@discardableResult
private func nextMeeting(_ root: URL, _ name: String = "2026-10-27T16-03-30") throws -> RecordingPaths {
    let paths = try pageMeeting(root, name)
    guard case .object(var meta) = read(paths.meta)! else { throw BadRequest("meta") }
    meta = meta.map { $0.0 == "start_time" ? ($0.0, .string("2026-10-27T16:03:30+01:00")) : $0 }
    try write(.object(meta), to: paths.meta)
    return paths
}

/// test_webapp.py `_short_meeting`: `seconds` of other tones, one speaker, one line.
private func shortMeeting(_ root: URL, _ name: String, _ start: String, _ seconds: Int) throws {
    let paths = try pageMeeting(root, name)
    let n = SR * seconds
    try Wav16.write((0..<n).map { Int16(3000 * sin(Double($0) / 5)) }, rate: SR, to: paths.systemWav)
    try Wav16.write((0..<n).map { Int16(2000 * sin(Double($0) / 2)) }, rate: SR, to: paths.micWav)
    try write(.object([("start_time", .string(start)), ("duration_seconds", .int(seconds))]), to: paths.meta)
    let end = JSONValue.double(Double(seconds) - 0.5)
    try write(.array([.object([("speaker", .string("SPEAKER_00")), ("start", .double(0.5)), ("end", end)])]), to: paths.systemTurns)
    try write(.array([Utterance(speaker: "SPEAKER_00", start: 0.5, end: Double(seconds) - 0.5, text: "Later.").json]),
              to: paths.transcriptJson)
}

/// test_webapp.py `_state`: each meeting's system track length, transcript and meta.json.
private func state(_ root: URL, _ ids: [String]) throws -> [String] {
    try ids.map { id in
        let folder = root.appendingPathComponent(id)
        return "\(try frames(folder.appendingPathComponent("system.wav"))) "
            + PythonJSON.dumps(read(folder.appendingPathComponent("transcript.json")) ?? .null) + " "
            + PythonJSON.dumps(read(folder.appendingPathComponent("meta.json")) ?? .null)
    }
}

/// test_cutting.py's `_recording`: `speakers` are (label, start, end, voice), one turn and one line each; every track
/// sample i is i % 100.
private func recording(_ root: URL, _ start: PyDateTime, _ seconds: Int, _ speakers: [(String, Double, Double, [Double])]) throws -> RecordingPaths {
    let name = String(start.iso.prefix(19)).replacingOccurrences(of: ":", with: "-")
    let paths = RecordingPaths(root.appendingPathComponent(name, isDirectory: true))
    try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
    let tone = (0..<(seconds * SR)).map { Int16($0 % 100) }
    for track in [paths.micRawWav, paths.micWav, paths.systemWav] { try Wav16.write(tone, rate: SR, to: track) }
    try write(.object([("start_time", .string(start.iso)), ("duration_seconds", .int(seconds)),
                       ("end_time", .string(try! start.adding(seconds: Double(seconds)).iso))]), to: paths.meta)
    func n(_ x: Double) -> JSONValue { x == x.rounded() ? .int(Int(x)) : .double(x) }
    try write(.array(speakers.map { .object([("speaker", .string($0.0)), ("start", n($0.1)), ("end", n($0.2))]) }), to: paths.systemTurns)
    try write(.array(speakers.map { s in
        .object([("start", n(s.1)), ("end", n(s.2)), ("text", .string("I am \(s.0).")), ("speaker", .null),
                 ("words", .array([.object([("text", .string("I")), ("start", n(s.1)), ("end", .double(s.1 + 0.5))])]))])
    }), to: paths.systemSegments)
    try write(.array([]), to: paths.micSegments)
    try write(.array(speakers.map { .object([("speaker", .string($0.0)), ("start", n($0.1)), ("end", n($0.2)),
                                             ("text", .string("I am \($0.0)."))]) }), to: paths.transcriptJson)
    try write(.object(speakers.map { ($0.0, .array($0.3.map(JSONValue.double))) }), to: paths.speakerEmbeddings)
    return paths
}

private let C0 = try! PyDateTime.parse("2026-10-21T15:34:00+02:00")
private let ANNA = [1.0, 0.0, 0.0], BEN = [0.0, 1.0, 0.0]

/// test_attribution.py `_with_events`: the meeting, its planned series event and an ad-hoc call at the same start.
private func withEvents(_ f: Fixture) throws -> (CalendarEvent, CalendarEvent, CalendarProvider) {
    let start = try PyDateTime.parse("2026-10-27T16:03:07+01:00")
    let planned = CalendarEvent(title: "Northwind", start: start, end: try! start.adding(seconds: 3600),
                                attendees: [Attendee(name: "Anna", email: "anna@x.com")], uid: "north", series: true)
    let adhoc = CalendarEvent(title: "Ad hoc", start: start, end: try! start.adding(seconds: 600),
                              attendees: [Attendee(name: "Bob", email: "bob@x.com")], uid: "adhoc")
    return (planned, adhoc, { _, _ in [planned, adhoc] })
}

@Suite struct ChangesTests {
    // MARK: - the calendar event

    @Test func test_choosing_the_calendar_event_of_a_meeting() throws {
        let start = try PyDateTime.parse("2026-10-27T16:03:07+01:00")
        let planned = CalendarEvent(title: "Northwind Zwischenstand", start: start, end: try! start.adding(seconds: 3600), uid: "u1")
        let adhoc = CalendarEvent(title: "Ad hoc", start: start, end: try! start.adding(seconds: 600), uid: "u2")
        let f = try Fixture(calendar: { _, _ in [planned, adhoc] })  // two at once
        try CalendarEvents.save(f.paths, planned)
        let found = try EventsAPI.meetingEvents(app: f.app, id: MEETING)
        #expect(found.map { [$0["title"]!, $0["current"]!] } == [[.string("Ad hoc"), .bool(false)],
                                                                 [.string("Northwind Zwischenstand"), .bool(true)]])
        try ChangesAPI.setMeetingEvent(f.app, id: MEETING, key: adhoc.key)
        #expect(CalendarEvents.load(f.paths)?.title == "Ad hoc")
        try ChangesAPI.setMeetingEvent(f.app, id: MEETING, key: nil)  // none of them
        #expect(CalendarEvents.load(f.paths) == nil && CalendarEvents.dismissed(f.paths))
        #expect(!(try EventsAPI.meetingEvents(app: f.app, id: MEETING)).contains { $0["current"] == .bool(true) })
        #expect(throws: NotFound.self) { try ChangesAPI.setMeetingEvent(f.app, id: MEETING, key: "nope|2026-10-27") }
    }

    @Test func test_http_event_change_to_none_can_be_undone_exactly() throws {
        var stored = ""
        let s = try TestServer(meetings: { out in
            let paths = try pageMeeting(out)
            let start = try PyDateTime.parse("2026-10-27T16:03:07+01:00")
            try CalendarEvents.save(paths, CalendarEvent(title: "Stored only", start: start, end: try! start.adding(seconds: 1800)))
            stored = try String(contentsOf: paths.calendar, encoding: .utf8)
        })
        defer { s.stop() }
        let store = ProjectStore(path: s.app.stores.projects)
        let pid = try store.create("Hiring")
        _ = try store.assign(MEETING, pid, why: "test")
        try store.save()
        let before = s.get("/api/meetings/\(MEETING)").json?["projects"]
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/event", .object([("key", .null)]))
        #expect(status == 200 && answer["calendar"] == .null && answer["undo"] != nil)
        let paths = RecordingPaths(s.app.outputDir.appendingPathComponent(MEETING, isDirectory: true))
        #expect(CalendarEvents.dismissed(paths))
        let (st, restored) = post(s, "/api/undo", .object([("token", answer["undo"]!)]))
        #expect(st == 200 && restored == .object([("restored", .strings([MEETING]))]))
        #expect(try String(contentsOf: paths.calendar, encoding: .utf8) == stored)
        #expect(s.get("/api/meetings/\(MEETING)").json?["projects"] == before)
    }

    @Test func test_http_choosing_an_event_can_be_undone_to_nothing_stored() throws {
        let start = try PyDateTime.parse("2026-10-27T16:03:07+01:00")
        let planned = CalendarEvent(title: "Planned", start: start, end: try! start.adding(seconds: 1800), uid: "u1")
        let s = try TestServer(calendar: { _, _ in [planned] }, meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let store = ProjectStore(path: s.app.stores.projects)
        let pid = try store.create("Hiring")
        try store.save()
        try Prep.choose(planned, pid, stores: s.app.stores)  // chosen before the meeting: the event gives the meeting it
        let paths = RecordingPaths(s.app.outputDir.appendingPathComponent(MEETING, isDirectory: true))
        #expect(!exists(paths.calendar))
        let key = try #require(s.get("/api/meetings/\(MEETING)/events").json?[0]?["key"])
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/event", .object([("key", key)]))
        #expect(status == 200 && answer["calendar"]?["title"] == .string("Planned") && answer["undo"] != nil)
        #expect(answer["projects"]?.arrayValue?.map { $0["id"] } == [.string(pid)] && Prep.chosen(planned, stores: s.app.stores) == [])
        #expect(post(s, "/api/undo", .object([("token", answer["undo"]!)])).0 == 200)
        #expect(!exists(paths.calendar) && !CalendarEvents.dismissed(paths))  // matching by time stays possible
        #expect(s.get("/api/meetings/\(MEETING)").json?["projects"] == .array([]))
        #expect(Prep.chosen(planned, stores: s.app.stores) == [pid])
    }

    @Test func test_picking_the_event_brings_its_prepared_notes_and_undo_takes_them_back() throws {
        let f = try Fixture()
        let start = try PyDateTime.parse("2026-10-27T16:03:07+01:00")
        let event = CalendarEvent(title: "Hiring debrief", start: start, end: try! start.adding(seconds: 1800), uid: "hire-1")
        let other = CalendarEvent(title: "Other", start: start, end: try! start.adding(seconds: 1800), uid: "other")
        try write(.object([("question", .array([event.json, other.json]))]), to: f.paths.calendar)
        let prepared = MyNotes.prepFolder(event.key, stores: f.stores)
        _ = try MyNotes.save(prepared, paragraphs: .array([.object([("text", .string("Ask about the salary band")), ("at", .null)])]))
        _ = try MyNotes.save(f.paths.folder, paragraphs: .array([.object([("text", .string("typed in the call")), ("at", .int(5))])]))
        let before = MyNotes.document(f.paths.folder)["revision"]

        let token = try ChangesAPI.setMeetingEvent(f.app, id: MEETING, key: event.key)
        #expect(MyNotes.load(f.paths.folder).map(\.text) == ["Ask about the salary band", "typed in the call"])
        #expect(try f.page()["my_notes_revision"] != before)
        _ = try f.undo(token)
        #expect(MyNotes.load(f.paths.folder) == [MyNotes.Paragraph(text: "typed in the call", at: 5)])
        #expect(MyNotes.load(prepared) == [MyNotes.Paragraph(text: "Ask about the salary band")])  // waiting again
    }

    @Test func test_the_meeting_shows_the_event_link_and_the_question() throws {
        let f = try Fixture()
        let (planned, adhoc, _) = try withEvents(f)
        try CalendarEvents.ask(f.paths, [planned, adhoc])
        let q = try f.page()["event_question"]
        #expect(try f.page()["calendar"] == .null)
        #expect(q?["reason"] == .string("2 events overlapped the recording"))
        #expect(q?["choices"]?.arrayValue?.map { [$0["title"]!, $0["invited"]!] }
                == [[.string("Ad hoc"), .int(1)], [.string("Northwind"), .int(1)]])
        // Answered without a calendar at hand: the stored candidates are the choices.
        let token = try ChangesAPI.setMeetingEvent(f.app, id: MEETING, key: try #require(q?["choices"]?[1]?["key"]?.stringValue))
        let m = try f.page()
        #expect(m["event_question"] == .null)
        #expect(m["calendar"]?["link"]?["label"] == .string("Event: Northwind (you)") && m["calendar"]?["link"]?["unsure"] == .bool(false))
        _ = try f.undo(token)
        #expect(try f.page()["event_question"] != .null)
    }

    @Test func test_confirming_an_unsure_event_makes_it_the_users() throws {
        let f = try Fixture()
        let (planned, _, _) = try withEvents(f)
        try CalendarEvents.assign(f.paths, planned, link: Link("event", "Northwind", "calendar", 0.6, "time match, 2 events overlapped"),
                                  stores: f.stores)
        #expect(try f.page()["calendar"]?["link"]?["unsure"] == .bool(true))
        try ChangesAPI.setMeetingEvent(f.app, id: MEETING, key: "current")
        #expect(CalendarEvents.loadLink(f.paths)?.byYou == true && CalendarEvents.load(f.paths).map { EventsAPI.same($0, planned) } == true)
    }

    @Test func test_changing_the_event_is_negative_evidence_for_the_one_rejected() throws {
        let f = try Fixture(calendar: { _, _ in [] })
        let (planned, adhoc, calendar) = try withEvents(f)
        let app = ServerApp(outputDir: f.out, userName: "Timo", stores: f.stores, calendar: calendar)
        try CalendarEvents.assign(f.paths, planned, link: Link("event", "Northwind", "calendar", 0.9, "time match"), stores: f.stores)
        let token = try ChangesAPI.setMeetingEvent(app, id: MEETING, key: adhoc.key)
        #expect(Evidence(path: f.stores.attributions).eventRejections(planned) == 1)
        _ = try UndoRoute.undoChange(app, token: token)  // the evidence goes with the change
        #expect(Evidence(path: f.stores.attributions).eventRejections(planned) == 0)
        try ChangesAPI.setMeetingEvent(app, id: MEETING, key: nil)  // none of these
        #expect(Evidence(path: f.stores.attributions).eventRejections(planned) == 1)
    }

    /// Python counts the calls of `refresh_recognition` and `assign_by_rules`; here their effect on the page: the
    /// event's invitees are offered for the speakers, and its undo asks the question again.
    @Test func test_answering_the_question_catches_up_on_what_processing_skipped() throws {
        let f = try Fixture()
        let (planned, adhoc, _) = try withEvents(f)
        try CalendarEvents.ask(f.paths, [planned, adhoc])
        let token = try ChangesAPI.setMeetingEvent(f.app, id: MEETING, key: planned.key)
        #expect(try f.page()["calendar"]?["invited"] == .strings(["Anna"]))  // its invitees are offered for the speakers now
        _ = try f.undo(token)
        #expect(CalendarEvents.loadQuestion(f.paths) != nil && CalendarEvents.load(f.paths) == nil)
        try ChangesAPI.setMeetingEvent(f.app, id: MEETING, key: nil)  // none of these: the same
        #expect(CalendarEvents.dismissed(f.paths))
    }

    @Test func test_a_user_chosen_event_wins_over_a_question_when_joining() throws {
        let f = try Fixture(meeting: false)
        let first = try recording(f.out, C0, 60, [("SPEAKER_00", 1, 50, ANNA)])
        let second = try recording(f.out, try! C0.adding(seconds: 62), 30, [("SPEAKER_00", 2, 28, BEN)])
        let sync = CalendarEvent(title: "Sync", start: C0, end: try! C0.adding(seconds: 1800), uid: "sync")
        try CalendarEvents.ask(first, [sync, CalendarEvent(title: "Other", start: C0, end: try! C0.adding(seconds: 1800), uid: "other")])
        try CalendarEvents.assign(second, sync, link: Link("event", "Sync", "you"), stores: f.stores)
        let kept = try Cutting.join(first, second)
        #expect(kept.folder.path == first.folder.path)
        #expect(CalendarEvents.load(kept).map { EventsAPI.same($0, sync) } == true && CalendarEvents.loadLink(kept)?.byYou == true)
        #expect(CalendarEvents.loadQuestion(kept) == nil)
    }

    @Test func test_a_rule_shows_in_the_picker_and_can_be_forgotten_with_undo() throws {
        let f = try Fixture()
        let (planned, _, calendar) = try withEvents(f)
        let app = ServerApp(outputDir: f.out, userName: "Timo", stores: f.stores, calendar: calendar)
        let ev = Evidence(path: f.stores.attributions)
        ev.rejectEvent(planned, "x1")
        ev.rejectEvent(planned, "x2")
        try ev.save()
        let found = try EventsAPI.meetingEvents(app: app, id: MEETING)
        let north = found.first { $0["title"] == .string("Northwind") }, adhoc = found.first { $0["title"] == .string("Ad hoc") }
        #expect(north?["rule"] == .object([("series", .string("north")),
                                           ("text", .string("Not linked by time any more: Northwind — rejected 2×"))]))
        #expect(adhoc?["rule"] == .null)
        let token = try ChangesAPI.forgetRule(app, series: "north")
        #expect(Evidence(path: f.stores.attributions).rules().isEmpty)
        _ = try UndoRoute.undoChange(app, token: token)
        #expect(Evidence(path: f.stores.attributions).rules().map(\.series) == ["north"])
    }

    @Test func forgettingARuleOverHTTPAnswersItsUndo() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let (status, answer) = post(s, "/api/rules/forget", .object([("series", .string("north"))]))
        #expect(status == 200 && answer["undo"]?.stringValue?.count == 32)
        #expect(post(s, "/api/rules/forget").1 == .object([("error", .string("bad request: 'series'"))]))
    }

    // MARK: - the trash

    @Test func test_a_meeting_goes_to_the_trash() throws {
        let f = try Fixture()
        try ChangesAPI.trashMeeting(f.app, id: MEETING)
        #expect(!exists(f.paths.folder) && exists(f.out.appendingPathComponent(".trash/\(MEETING)/meta.json")))
        #expect(try MeetingsAPI.listMeetings(app: f.app).isEmpty)
        #expect(throws: NotFound.self) { try ChangesAPI.trashMeeting(f.app, id: MEETING) }
    }

    /// Python makes `_status` say "recording"; here a live worker runs for the meeting.
    @Test func test_a_meeting_being_recorded_is_not_trashed() throws {
        let f = try Fixture()
        let worker = try fakeLiveWorker(f.paths.folder)
        defer { worker.terminate(); worker.waitUntilExit() }
        #expect(throws: Refused.self) { try ChangesAPI.trashMeeting(f.app, id: MEETING) }
        #expect(exists(f.paths.folder))
        #expect(snapshots(f.out).isEmpty)
    }

    @Test func test_http_trash() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/trash")
        #expect(status == 200 && answer == .object([("trashed", .string(MEETING)), ("undo", answer["undo"] ?? .null)]))
        #expect(answer["undo"]?.stringValue?.count == 32)
    }

    @Test func test_a_failed_meeting_can_go_to_the_trash() throws {
        let f = try Fixture()  // It was "processing" for ever before: nothing could be done with it.
        try FileManager.default.removeItem(at: f.paths.transcriptJson)
        try FileManager.default.removeItem(at: f.paths.notes)
        try ProcessState.mark(f.paths, reason: ProcessState.error)
        #expect(!(try ChangesAPI.trashMeeting(f.app, id: MEETING)).isEmpty)
    }

    /// Python makes `_status` say "processing"; here the meeting is recorded and not transcribed yet.
    @Test func test_http_a_meeting_being_processed_is_not_trashed_or_reviewed_again() throws {
        let s = try TestServer(meetings: { out in
            let paths = try pageMeeting(out)
            try write(.object([("reviewed", .string("2026-10-27T17:00:00+01:00")), ("seen", .array([]))]), to: paths.review)
            try FileManager.default.removeItem(at: paths.transcriptJson)
        })
        defer { s.stop() }
        let folder = s.app.outputDir.appendingPathComponent(MEETING)
        var (status, error) = post(s, "/api/meetings/\(MEETING)/trash")
        #expect(status == 400 && error["error"] == .string("This meeting is still being transcribed. It can go to the trash once that is done."))
        #expect(exists(folder))
        (status, error) = post(s, "/api/meetings/\(MEETING)/reviewed", .object([("done", .bool(false))]))
        #expect(status == 400 && error["error"] == .string("This meeting is still being transcribed. It can be reviewed again once that is done."))
        #expect(exists(folder.appendingPathComponent("review.json")))
        #expect(post(s, "/api/meetings/\(MEETING)/reviewed", .object([("done", .bool(true))])).0 == 200)  // marking it done is fine
    }

    /// The trash half: a change is counted in the drain while it runs, and not after.
    @Test func test_http_changes_count_for_the_drain_and_ping_answers() throws {
        final class Seen: @unchecked Sendable { var counts: [Int] = [] }
        let seen = Seen()
        let s = try TestServer(meetings: { try pageMeeting($0) }, routes: { _, app in
            app.changeOps.trash = { paths in
                seen.counts.append(app.inflight.count)
                return try Cutting.trash(paths)
            }
        })
        defer { s.stop() }
        #expect(s.get("/api/ping").status == 200)
        #expect(post(s, "/api/meetings/\(MEETING)/trash").0 == 200)
        #expect(seen.counts == [1])
        #expect(until { s.app.inflight.count == 0 })
    }

    @Test func test_http_trash_can_be_undone() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/trash")
        #expect(status == 200 && answer["undo"] != nil)
        #expect(s.get("/api/meetings/\(MEETING)").status == 404)
        let (st, restored) = post(s, "/api/undo", .object([("token", answer["undo"]!)]))
        #expect(st == 200 && restored == .object([("restored", .strings([MEETING]))]))
        #expect(s.get("/api/meetings/\(MEETING)").status == 200)
    }

    @Test func test_http_undo_with_a_meeting_still_being_processed() throws {
        let waitingId = "2026-10-27T17-00-00"
        let s = try TestServer(meetings: { out in
            try pageMeeting(out)
            let waiting = out.appendingPathComponent(waitingId)
            try FileManager.default.createDirectory(at: waiting, withIntermediateDirectories: true)
            try Data().write(to: waiting.appendingPathComponent("mic_raw.wav"))  // no transcript yet
        })
        defer { s.stop() }
        _ = post(s, "/api/meetings/\(MEETING)/speakers", .object([("label", .string("SPEAKER_00")), ("name", .string("Ana"))]))
        let (_, renamed) = post(s, "/api/people/rename", .object([("old", .string("Ana")), ("new", .string("Anna"))]))
        #expect(post(s, "/api/undo", .object([("token", renamed["undo"] ?? .null)])).0 == 200)
        #expect(s.get("/api/meetings/\(MEETING)").json?["transcript"]?[1]?["speaker"] == .string("Ana"))
        // trash it and undo
        let (status, answer) = post(s, "/api/meetings/\(waitingId)/trash")
        #expect(status == 200)
        let undone = post(s, "/api/undo", .object([("token", answer["undo"] ?? .null)]))
        #expect(undone.0 == 200 && undone.1 == .object([("restored", .strings([waitingId]))]))
        #expect(MeetingsAPI.isDirectory(s.app.outputDir.appendingPathComponent(waitingId)))
    }

    // MARK: - undo

    @Test func test_http_undo_unknown_token_is_404() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let (status, error) = post(s, "/api/undo", .object([("token", .string(String(repeating: "0", count: 32)))]))
        #expect(status == 404 && error["error"]?.stringValue?.contains("can't undo") == true)
        #expect(post(s, "/api/undo", .object([("token", .string("../../x"))])).0 == 404)
        #expect(post(s, "/api/undo").1 == .object([("error", .string("bad request: 'token'"))]))
    }

    @Test func test_http_undo_refused_after_the_meeting_changed() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let (_, answer) = post(s, "/api/meetings/\(MEETING)/split", .object([("at", .int(10))]))
        _ = post(s, "/api/meetings/\(MEETING)/speakers", .object([("label", .string("SPEAKER_00")), ("name", .string("Ana"))]))
        let (status, error) = post(s, "/api/undo", .object([("token", answer["undo"] ?? .null)]))
        #expect(status == 409 && error["error"]?.stringValue?.contains("changed") == true)
    }

    @Test func test_http_failed_change_leaves_no_snapshot() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let (status, error) = post(s, "/api/meetings/\(MEETING)/split", .object([("at", .int(500))]))
        #expect(status >= 400 && error["error"] == .string("bad request: cut between 0:01 and 0:19"))
        #expect(snapshots(s.app.outputDir).isEmpty)
    }

    @Test func test_http_change_failing_half_way_is_rolled_back() throws {
        struct DiskFull: Error, CustomStringConvertible { var description: String { "disk full" } }
        let s = try TestServer(meetings: { try pageMeeting($0) }, routes: { _, app in
            app.changeOps.split = { paths, _ in
                try Data("[]".utf8).write(to: paths.systemTurns)
                try Data().write(to: paths.systemWav)
                throw DiskFull()
            }
        })
        defer { s.stop() }
        let folder = s.app.outputDir.appendingPathComponent(MEETING)
        let before = try Data(contentsOf: folder.appendingPathComponent("system_turns.json"))
        let r = s.post("/api/meetings/\(MEETING)/split", .object([("at", .int(10))]))
        #expect(r.status == 500 && r.error == "disk full")
        #expect(try Data(contentsOf: folder.appendingPathComponent("system_turns.json")) == before)
        #expect(try frames(folder.appendingPathComponent("system.wav")) == SR * 20)
        #expect(snapshots(s.app.outputDir).isEmpty)
    }

    @Test func test_http_failed_rollback_keeps_the_snapshot() throws {
        struct Nope: Error {}
        let s = try TestServer(meetings: { try pageMeeting($0) }, routes: { _, app in
            app.changeOps.split = { _, _ in throw Nope() }
            app.changeOps.restore = { _, _, _ in throw Nope() }
        })
        defer { s.stop() }
        #expect(post(s, "/api/meetings/\(MEETING)/split", .object([("at", .int(10))])).0 == 500)
        #expect(snapshots(s.app.outputDir).count == 1)
    }

    /// The rollback runs holding the projects lock, as api.py's `with _PROJECTS_LOCK, _undoable(...)` rolls back before
    /// it lets go; the change ran holding it too.
    @Test func aRollbackRunsInsideTheProjectsLock() throws {
        let f = try Fixture()
        var heldInChange = false, heldInRollback = false
        f.app.changeOps.restore = { out, token, check in
            heldInRollback = !f.app.projectsLock.try()
            if !heldInRollback { f.app.projectsLock.unlock() }
            return try Undo.restore(out, token, check: check)
        }
        struct Fails: Error {}
        #expect(throws: Fails.self) {
            try ChangesAPI.undoable(f.app, label: "trash", stores: ChangesAPI.storePaths(f.app, "projects"), projectsLock: true) { _ in
                heldInChange = !f.app.projectsLock.try()
                throw Fails()
            }
        }
        #expect(heldInChange && heldInRollback)
        #expect(snapshots(f.out).isEmpty)
    }

    /// A change asked for while another one fails waits until that one is rolled back: it never snapshots (or
    /// moves) the half-changed meeting.
    @Test func aChangeWaitsForTheRollbackOfAFailedOne() throws {
        struct DiskFull: Error {}
        let rolling = Latch(), release = Latch()
        let s = try TestServer(meetings: { try pageMeeting($0) }, routes: { _, app in
            app.changeOps.split = { paths, _ in
                try Data("[]".utf8).write(to: paths.systemTurns)
                throw DiskFull()
            }
            app.changeOps.restore = { out, token, check in
                rolling.open()
                release.wait(10)
                return try Undo.restore(out, token, check: check)
            }
        })
        defer { s.stop() }
        final class Box: @unchecked Sendable { var split = 0, trash = 0 }
        let box = Box(), splitDone = Latch(), trashDone = Latch()
        Thread { box.split = s.post("/api/meetings/\(MEETING)/split", .object([("at", .int(10))])).status; splitDone.open() }.start()
        rolling.wait(10)
        #expect(rolling.opened)
        Thread { box.trash = s.post("/api/meetings/\(MEETING)/trash").status; trashDone.open() }.start()
        usleep(300_000)
        #expect(!trashDone.opened)  // waits for the projects lock
        #expect(exists(s.app.outputDir.appendingPathComponent("\(MEETING)/meta.json")))
        release.open()
        splitDone.wait(10)
        trashDone.wait(10)
        #expect(box.split == 500 && box.trash == 200)
        let trashed = s.app.outputDir.appendingPathComponent(".trash/\(MEETING)/system_turns.json")
        #expect(read(trashed)?.arrayValue?.count == 3)  // trashed as it was before the failed split
        #expect(snapshots(s.app.outputDir).count == 1)  // the trash's own
    }

    @Test func aFailedRollbackSaysSoInDaemonLog() throws {
        struct Nope: Error, CustomStringConvertible { var description: String { "nope" } }
        let s = try TestServer(meetings: { try pageMeeting($0) }, routes: { _, app in
            app.changeOps.split = { _, _ in throw Nope() }
            app.changeOps.restore = { _, _, _ in throw Nope() }
        })
        defer { s.stop() }
        #expect(post(s, "/api/meetings/\(MEETING)/split", .object([("at", .int(10))])).0 == 500)
        let token = try #require(snapshots(s.app.outputDir).first)
        #expect(until { s.log.contains("rolling back split failed; the snapshot \(token) is kept: nope") })
    }

    @Test func test_undo_route_restores_a_python_snapshot() throws {
        // The domain tests' copy (Goldens/python-undo, tools/parity/goldens.py undo_fixture), read in the checkout.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PalaverDomainTests/Goldens/python-undo", isDirectory: true)
        try #require(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("root/Meetings").path))
        let s = try TestServer(meetings: { out in
            let fm = FileManager.default
            let root = fixture.appendingPathComponent("root")
            for name in try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Meetings").path) {
                try fm.copyItem(at: root.appendingPathComponent("Meetings/\(name)"), to: out.appendingPathComponent(name))
            }
            let config = out.deletingLastPathComponent().appendingPathComponent("config/palaver", isDirectory: true)
            try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: root.appendingPathComponent("config/palaver"), to: config)
            // Taken a minute ago (each undo prunes what is older than a day), in the order Python took them.
            let taken = DateFormatter()
            taken.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            taken.timeZone = TimeZone(secondsFromGMT: 3600)
            taken.locale = Locale(identifier: "en_US_POSIX")
            let undo = out.appendingPathComponent(".trash/.undo")
            for token in try fm.contentsOfDirectory(atPath: undo.path) {
                let m = undo.appendingPathComponent("\(token)/manifest.json")
                let text = try String(contentsOf: m, encoding: .utf8)
                    .replacingOccurrences(of: "/PALAVER-UNDO-ROOT/root", with: out.deletingLastPathComponent().path)
                    .replacingOccurrences(of: "2026-11-04T22:10:33", with: taken.string(from: Date(timeIntervalSinceNow: -60)))
                try Data(text.utf8).write(to: m)
            }
        })
        defer { s.stop() }
        // Newest first. Only the newest is undone: what follows an undo (the notes' paragraphs written again, the
        // names and projects derived again) changes what the older snapshots expect, so Python refuses them too
        // (`api.undo_change` on this fixture answers [], then Changed four times).
        let steps: [(String, Int, JSONValue)] = [
            ("a45aa10eb21240649258f89290a5dcf4", 200, .object([("restored", .array([]))])),
            ("8602c958df4647eeaba72b7824f618bc", 409, .object([("error", .string("the meeting changed since"))])),
            ("bdb38b70a69d44e2a39c2a3c1b1546d6", 409, .object([("error", .string("the meeting changed since"))])),
            ("fcdac49802bf49e6a1ce74e8693a6e37", 409, .object([("error", .string("the meeting changed since"))])),
            ("bb7cbf3039184bda85933c0080b279b7", 409, .object([("error", .string("the meeting changed since"))])),
        ]
        for (token, status, answer) in steps {
            let got = post(s, "/api/undo", .object([("token", .string(token))]))
            #expect(got.0 == status && got.1 == answer, "\(token): \(got)")
        }
        for id in ["2026-10-20T14-35-17", "2026-10-22T10-00-00", "2026-10-22T10-00-30"] {  // the refusals moved nothing
            #expect(MeetingsAPI.isDirectory(s.app.outputDir.appendingPathComponent(id)))
        }
        #expect(snapshots(s.app.outputDir).count == 4)
        // The cleared notes are back as Python's undo leaves them: the image, its text, the paragraph merged in.
        let folder = s.app.outputDir.appendingPathComponent("2026-10-20T14-35-17")
        #expect(exists(folder.appendingPathComponent("my-notes/img-0123456789ab.png")))
        #expect(exists(folder.appendingPathComponent("my-notes/img-0123456789ab.png.txt")))
        #expect(try Data(contentsOf: folder.appendingPathComponent("my-notes.json")) == Data("""
            [
             {
              "text": "Budget f\u{fc}r Contoso",
              "at": 0.1
             },
             {
              "text": "",
              "at": null,
              "image": "img-0123456789ab.png"
             }
            ]
            """.utf8))
    }

    /// The general undo's glossary half (test_http_glossary_undo_renders_the_markdown_again goes through the glossary
    /// routes, Task 44): a snapshot of the glossary put back renders every transcript.md again.
    @Test func undoingAGlossaryChangeRendersTheMarkdownAgain() throws {
        let f = try Fixture()
        try Data("rendered".utf8).write(to: f.paths.transcriptMd)  // only a Markdown that exists is rendered again
        let token = try ChangesAPI.undoToken(f.app, label: "delete term", stores: ChangesAPI.storePaths(f.app, "glossary")) { _ in
            try FileManager.default.createDirectory(at: f.stores.glossary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(.object([("terms", .object([]))]), to: f.stores.glossary)
        }
        #expect(try UndoRoute.undoChange(f.app, token: token) == [])
        let md = try String(contentsOf: f.paths.transcriptMd, encoding: .utf8)
        #expect(md.hasPrefix("# ") && md.contains("Welcome to the hiring debrief."))
        #expect(!exists(f.stores.glossary))  // it was not there before
    }

    // MARK: - cutting

    @Test func test_http_join_can_be_undone() throws {
        let s = try TestServer(meetings: { try pageMeeting($0); try nextMeeting($0) })
        defer { s.stop() }
        let out = s.app.outputDir, other = "2026-10-27T16-03-30"
        let before = read(out.appendingPathComponent("\(MEETING)/transcript.json"))?.arrayValue?.count ?? 0
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/join", .object([("with", .string(other))]))
        #expect(status == 200 && answer["undo"] != nil)
        let kept = try #require(answer["id"]?.stringValue)
        #expect(!exists(out.appendingPathComponent(other)) || kept == other)
        #expect((read(out.appendingPathComponent("\(kept)/transcript.json"))?.arrayValue?.count ?? 0) > before)
        let (st, restored) = post(s, "/api/undo", .object([("token", answer["undo"]!)]))
        #expect(st == 200 && Set(restored["restored"]?.arrayValue?.compactMap(\.stringValue) ?? []) == [MEETING, other])
        for id in [MEETING, other] {
            #expect(s.get("/api/meetings/\(id)").status == 200)
            #expect(read(out.appendingPathComponent("\(id)/transcript.json"))?.arrayValue?.count == before)
            #expect(try frames(out.appendingPathComponent("\(id)/system.wav")) == SR * 20)
        }
    }

    @Test func test_http_split_can_be_undone() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let out = s.app.outputDir
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/split", .object([("at", .int(10))]))
        let rest = try #require(answer["rest"]?.stringValue)
        #expect(status == 200 && answer["undo"] != nil && ids(s).contains(rest))
        #expect(try frames(out.appendingPathComponent("\(MEETING)/system.wav")) == SR * 10)
        #expect(post(s, "/api/undo", .object([("token", answer["undo"]!)])).0 == 200)
        #expect(ids(s) == [MEETING])
        #expect(try frames(out.appendingPathComponent("\(MEETING)/system.wav")) == SR * 20)
        #expect(read(out.appendingPathComponent("\(MEETING)/meta.json"))?["duration_seconds"] == .int(20))
    }

    @Test func test_http_older_split_undo_works_after_a_later_split_was_undone() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let (_, first) = post(s, "/api/meetings/\(MEETING)/split", .object([("at", .int(10))]))
        let (status, second) = post(s, "/api/meetings/\(MEETING)/split", .object([("at", .int(5)), ("join_next", .bool(true))]))
        #expect(status == 200 && second["joined"] == .bool(true))
        #expect(post(s, "/api/undo", .object([("token", second["undo"] ?? .null)])).0 == 200)
        #expect(post(s, "/api/undo", .object([("token", first["undo"] ?? .null)])).0 == 200)
        #expect(ids(s) == [MEETING])
        #expect(try frames(s.app.outputDir.appendingPathComponent("\(MEETING)/system.wav")) == SR * 20)
    }

    @Test(arguments: [(20, "following"), (3, "tail")])
    func test_http_split_joining_on_can_be_undone(_ followingSeconds: Int, _ kept: String) throws {
        let after = "2026-10-27T16-03-30"
        let s = try TestServer(meetings: { out in
            try pageMeeting(out)
            try shortMeeting(out, after, "2026-10-27T16:03:30+01:00", followingSeconds)
        })
        defer { s.stop() }
        let out = s.app.outputDir
        let before = try state(out, [MEETING, after])
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/split", .object([("at", .int(12)), ("join_next", .bool(true))]))
        #expect(status == 200 && answer["joined"] == .bool(true) && answer["undo"] != nil)
        #expect((answer["rest"] == .string(after)) == (kept == "following"))  // the longer one keeps the meeting
        #expect(try frames(out.appendingPathComponent("\(MEETING)/system.wav")) == SR * 12)
        let (st, restored) = post(s, "/api/undo", .object([("token", answer["undo"]!)]))
        #expect(st == 200 && Set(restored["restored"]?.arrayValue?.compactMap(\.stringValue) ?? []).isSuperset(of: [MEETING, after]))
        #expect(ids(s).sorted() == [MEETING, after].sorted())
        #expect(try state(out, [MEETING, after]) == before)
        let trash = out.appendingPathComponent(".trash")
        let undone = try FileManager.default.contentsOfDirectory(atPath: trash.path).filter { $0.contains(".undone-") }
        for folder in undone {  // the undone audio is not kept twice
            #expect(try FileManager.default.contentsOfDirectory(atPath: trash.appendingPathComponent(folder).path)
                .allSatisfy { !$0.hasSuffix(".wav") })
        }
    }

    @Test(arguments: ["before", "after"])
    func test_http_discarding_part_of_a_meeting_can_be_undone(_ side: String) throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let out = s.app.outputDir
        let before = try state(out, [MEETING])
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/split", .object([("at", .int(12)), ("discard", .string(side))]))
        #expect(status == 200 && answer["discarded"] == .string(side) && answer["undo"] != nil)
        #expect(Array(answer.objectKeys) == ["id", "rest", "joined", "discarded", "undo"])
        #expect(try frames(out.appendingPathComponent("\(MEETING)/system.wav")) == SR * (side == "after" ? 12 : 8))
        let undone = post(s, "/api/undo", .object([("token", answer["undo"]!)]))
        #expect(undone.0 == 200 && undone.1 == .object([("restored", .strings([MEETING]))]))
        #expect(ids(s) == [MEETING])
        #expect(try state(out, [MEETING]) == before)
    }

    @Test func test_cut_and_add_to_the_next_meeting_from_the_window() throws {
        let f = try Fixture(meeting: false)
        let a = try recording(f.out, C0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
        let b = try recording(f.out, try! C0.adding(seconds: 62), 30, [("SPEAKER_00", 2, 28, [0.05, 1.0, 0.0])])
        try write(.object([("SPEAKER_00", .string("Ben"))]), to: b.speakers)
        #expect(try f.page(a.id)["neighbours"]?["next"]?["id"] == .string(b.id))
        let result = try ChangesAPI.splitMeeting(f.app, id: a.id, at: 40, joinNext: true, discard: nil)
        #expect(result == .object([("id", .string(a.id)), ("rest", .string(b.id)), ("joined", .bool(true)), ("undo", result["undo"]!)]))
        let m = try f.page(b.id)
        #expect(m["transcript"]?.arrayValue?.map { $0["speaker"] } == [.string("Ben"), .string("Ben")])
        #expect(m["speakers"]?.arrayValue?.dropFirst().map { $0["name"] } == [.string("Ben")])  // one lane: the merged voice
        let first = try f.page(a.id)
        #expect(first["transcript"]?.arrayValue?.map { $0["speaker"] } == [.string("Speaker 1")])
        #expect(first["duration"] == .int(40))
    }

    @Test func test_discard_from_the_window() throws {
        let f = try Fixture(meeting: false)
        let a = try recording(f.out, C0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
        let result = try ChangesAPI.splitMeeting(f.app, id: a.id, at: 40, joinNext: false, discard: "after")
        #expect(result["discarded"] == .string("after"))
        #expect(try f.page(a.id)["duration"] == .int(40))
    }

    @Test func test_the_window_offers_the_silence_and_removing_it_keeps_the_meeting() throws {
        let f = try Fixture(meeting: false)
        let a = try recording(f.out, C0, 1800, [("SPEAKER_00", 420, 1790, ANNA)])
        let silence = try #require(try f.page(a.id)["silence"]?.arrayValue)
        #expect(silence.count == 1)
        try ChangesAPI.splitMeeting(f.app, id: a.id, at: try #require(silence.first?["at"]?.doubleValue), joinNext: false, discard: "before")
        let m = try f.page(a.id)
        #expect(m["duration"]?.doubleValue == Double(1800 - 418) && m["silence"] == .array([]))
    }

    @Test func test_the_window_suggests_a_cut_from_the_next_recordings_event() throws {
        let f = try Fixture(meeting: false)
        let a = try recording(f.out, C0, 600, [("SPEAKER_00", 10, 300, ANNA), ("SPEAKER_01", 420, 580, BEN)])
        let b = try recording(f.out, try! C0.adding(seconds: 610), 300, [("SPEAKER_00", 2, 280, [0.05, 1.0, 0.0])])
        // It started while the first one recorded.
        try CalendarEvents.save(b, CalendarEvent(title: "Checkin", start: try! C0.adding(seconds: 400), end: try! C0.adding(seconds: 900),
                                                 attendees: [Attendee(name: "Ben", email: "ben@x.com")], uid: "checkin"))
        let suggestion = try f.page(a.id)["cut_suggestion"]
        #expect(suggestion?["at"]?.doubleValue == 420 && suggestion?["event"] == .string("Checkin"))
        try ChangesAPI.dismissCut(f.app, id: a.id, dismiss: true, what: "cut")
        #expect(try f.page(a.id)["cut_suggestion"] == .null)
    }

    @Test func test_silence_said_no_to_is_not_offered_again_and_the_undo_offers_it_again() throws {
        let f = try Fixture(meeting: false)
        let a = try recording(f.out, C0, 1800, [("SPEAKER_00", 420, 1790, ANNA)])
        try ChangesAPI.dismissCut(f.app, id: a.id, dismiss: true, what: "silence")
        #expect(try Cutting.suggestTrim(a).isEmpty)
        #expect(try Cutting.suggestCut(a, events: []) == nil)  // the other suggestion is untouched by it
        #expect(!exists(a.cutDismissed))
        #expect(read(a.silenceDismissed).map { Array($0.objectKeys) } == ["dismissed"])
        try ChangesAPI.dismissCut(f.app, id: a.id, dismiss: false, what: "silence")
        #expect(try Cutting.suggestTrim(a).first?["edge"] == .string("start"))
    }

    @Test func aCutSuggestionOverHTTPSaysWhichOnesThereAre() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/cut-suggestion", .object([("what", .string("nope"))]))
        #expect(status == 400 && answer["error"] == .string("bad request: no suggestion 'nope'"))
        #expect(post(s, "/api/meetings/\(MEETING)/cut-suggestion").0 == 200)
        #expect(exists(s.app.outputDir.appendingPathComponent("\(MEETING)/cut_dismissed.json")))
        #expect(post(s, "/api/meetings/\(MEETING)/cut-suggestion", .object([("dismiss", .null)])).0 == 200)  // `bool(None)`
        #expect(!exists(s.app.outputDir.appendingPathComponent("\(MEETING)/cut_dismissed.json")))
    }

    @Test func test_a_cut_can_be_undone_after_the_index_was_rewritten() throws {
        let f = try Fixture()
        guard var lines = read(f.paths.transcriptJson)?.arrayValue else { throw BadRequest("transcript") }
        lines.append(Utterance(speaker: "SPEAKER_00", start: 16, end: 19, text: "Die Kosten für das Angebot sind noch zu hoch für den Kunden.").json)
        lines.append(Utterance(speaker: "SPEAKER_00", start: 19, end: 20, text: "Das müssen wir mit dem Einkauf klären, bevor wir zusagen.").json)
        try write(.array(lines), to: f.paths.transcriptJson)
        try SearchIndex.indexStale(outputDir: f.out, encoder: { TinyEncoder() })
        let r = try ChangesAPI.splitMeeting(f.app, id: MEETING, at: 13, joinNext: false, discard: nil)
        #expect(try SearchIndex.indexStale(outputDir: f.out, encoder: { TinyEncoder() }) == 2)  // both halves, in the background
        _ = try f.undo(try #require(r["undo"]?.stringValue))
        #expect(!exists(f.out.appendingPathComponent(try #require(r["rest"]?.stringValue))))
        #expect(SearchIndex.stale(outputDir: f.out).map(\.id) == [MEETING])  // indexed again, whole
    }

    // MARK: - title, lines, audio, kept on this Mac

    @Test func test_an_empty_title_falls_back_to_the_next_one() throws {
        let f = try Fixture()
        try ChangesAPI.setTitle(f.app, id: MEETING, title: .string("Mine"))
        try ChangesAPI.setTitle(f.app, id: MEETING, title: .string("   "))
        #expect(!exists(f.paths.title))
        #expect(try MeetingsAPI.listMeetings(app: f.app)[0]["title_from"] == .string("notes"))
    }

    @Test func test_http_rename_strips_caps_and_can_be_undone() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/title", .object([("title", .string("  Offer for Rico  "))]))
        #expect(status == 200 && answer["title"] == .string("Offer for Rico") && answer["title_from"] == .string("you") && answer["undo"] != nil)
        let (st, second) = post(s, "/api/meetings/\(MEETING)/title", .object([("title", .string(String(repeating: "y", count: 300)))]))
        #expect(st == 200 && second["title"] == .string(String(repeating: "y", count: 200)))
        let undone = post(s, "/api/undo", .object([("token", second["undo"]!)]))
        #expect(undone.0 == 200 && undone.1 == .object([("restored", .strings([MEETING]))]))
        #expect(s.get("/api/meetings").json?[0]?["title"] == .string("Offer for Rico"))
        #expect(post(s, "/api/undo", .object([("token", answer["undo"]!)])).0 == 200)
        let m = s.get("/api/meetings/\(MEETING)").json
        #expect(m?["title"] == .string("Hiring debrief") && m?["title_from"] == .string("notes"))
        #expect(!exists(s.app.outputDir.appendingPathComponent("\(MEETING)/title.json")))
    }

    @Test func test_http_rename_takes_only_text() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        for bad: JSONValue in [.object([("title", .null)]), .object([("title", .int(7))]), .object([("title", .strings(["Rico"]))]), .object([])] {
            #expect(post(s, "/api/meetings/\(MEETING)/title", bad).0 == 400, "\(bad)")
        }
        #expect(post(s, "/api/meetings/2026-01-01T00-00-00/title", .object([("title", .string("x"))])).0 == 404)
        #expect(snapshots(s.app.outputDir).isEmpty)
    }

    @Test func test_http_rename_undone_after_the_meeting_went_to_the_trash_brings_nothing_back() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let (_, answer) = post(s, "/api/meetings/\(MEETING)/title", .object([("title", .string("Offer for Rico"))]))
        _ = post(s, "/api/meetings/\(MEETING)/trash")
        #expect(post(s, "/api/undo", .object([("token", answer["undo"] ?? .null)])).0 == 409)
        #expect(!exists(s.app.outputDir.appendingPathComponent(MEETING)))  // no folder made for the title alone
    }

    @Test func test_a_transcript_line_can_be_edited_and_reverted() throws {
        let f = try Fixture()
        try Data("old".utf8).write(to: f.paths.transcriptMd)
        let line = try #require(try f.page()["transcript"]?.arrayValue?.last)
        #expect(line["text"] == .string("Thanks Rico, the salary band is fine.") && line["edited"] == .bool(false))
        let start = try #require(line["start"]?.doubleValue)

        try ChangesAPI.editLine(f.app, id: MEETING, start: start, text: "Thanks, Rico. The salary band is fine, äh, really.")
        let edited = try #require(try f.page()["transcript"]?.arrayValue?.last)
        #expect(edited["edited"] == .bool(true) && edited["text"] == .string("Thanks, Rico. The salary band is fine, äh, really."))  // as typed
        #expect(edited["heard"] == .string("Thanks Rico, the salary band is fine."))
        let raw = try #require(read(f.paths.transcriptJson)?.arrayValue?.last)
        #expect(raw["heard"] == .string("Thanks Rico, the salary band is fine."))  // what was heard is kept
        #expect(try String(contentsOf: f.paths.transcriptMd, encoding: .utf8).contains("really"))  // rendered again
        #expect(!(try SearchAPI.search(f.app, "really", userName: "Timo")).isEmpty)

        try ChangesAPI.editLine(f.app, id: MEETING, start: start, text: nil)  // back to what was heard
        let back = try #require(try f.page()["transcript"]?.arrayValue?.last)
        #expect(back["text"] == .string("Thanks Rico, the salary band is fine.") && back["edited"] == .bool(false))
        #expect(read(f.paths.transcriptJson)?.arrayValue?.last?["heard"] == nil)

        #expect(throws: NotFound.self) { try ChangesAPI.editLine(f.app, id: MEETING, start: 999.0, text: "x") }
        #expect(throws: BadRequest.self) { try ChangesAPI.editLine(f.app, id: MEETING, start: start, text: "   ") }
    }

    /// A hand-edited meta.json with a NaN or endless duration: rendering transcript.md again fails that request
    /// (500, as Python's ValueError), and the server goes on answering instead of trapping.
    @Test func aBrokenDurationFailsTheRequestNotTheServer() throws {
        for duration in ["NaN", "Infinity", "1e300"] {
            let s = try TestServer(meetings: { try pageMeeting($0) })
            defer { s.stop() }
            let folder = s.app.outputDir.appendingPathComponent(MEETING)
            try Data("old".utf8).write(to: folder.appendingPathComponent("transcript.md"))
            try Data(#"{"start_time": "2026-10-27T16:03:07+01:00", "duration_seconds": \#(duration)}"#.utf8)
                .write(to: folder.appendingPathComponent("meta.json"))
            let r = s.post("/api/meetings/\(MEETING)/line", .object([("start", .double(13.004)), ("text", .string("Thanks."))]))
            #expect(r.status == 500, "\(duration)")
            #expect(s.get("/api/ping").status == 200, "\(duration)")
        }
    }

    @Test func anEditedLineKeepsItsKeysInTheirOrderAndPythonsFormat() throws {
        let f = try Fixture()
        try ChangesAPI.editLine(f.app, id: MEETING, start: 13.004, text: " Thanks, Rico. ")
        let text = try String(contentsOf: f.paths.transcriptJson, encoding: .utf8)
        let raw = try #require(read(f.paths.transcriptJson)?.arrayValue?.last)
        #expect(Array(raw.objectKeys) == ["speaker", "start", "end", "text", "heard"])
        #expect(text == PythonJSON.dumps(read(f.paths.transcriptJson)!, indent: 2, ensureAscii: false))
        try ChangesAPI.editLine(f.app, id: MEETING, start: 13, text: "Thanks Rico, the salary band is fine.")  // as heard: the edit goes
        #expect(Array(try #require(read(f.paths.transcriptJson)?.arrayValue?.last).objectKeys) == ["speaker", "start", "end", "text"])
        #expect(throws: NotFound.self) { try ChangesAPI.editLine(f.app, id: MEETING, start: 13.02, text: "x") }
    }

    @Test func test_http_edit_line() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let line = try #require(s.get("/api/meetings/\(MEETING)").json?["transcript"]?[0])
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/line", .object([("start", line["start"]!), ("text", .string("Hi Rico, welcome."))]))
        #expect(status == 200 && answer["transcript"]?[0]?["text"] == .string("Hi Rico, welcome."))
        #expect(post(s, "/api/meetings/\(MEETING)/line", .object([("start", .string("x"))])).1["error"]
                == .string("bad request: could not convert string to float: 'x'"))
        #expect(post(s, "/api/meetings/\(MEETING)/line", .object([("start", .double(999))])).1["error"]
                == .string("not found: \(MEETING) at 999.0"))
    }

    @Test func test_unsure_words_reach_the_window_until_the_line_is_edited() throws {
        let f = try Fixture()
        guard var transcript = read(f.paths.transcriptJson)?.arrayValue else { throw BadRequest("transcript") }
        transcript[2] = transcript[2].adding("unsure", .strings(["salary"]))
        try write(.array(transcript), to: f.paths.transcriptJson)
        let line = try #require(try f.page()["transcript"]?.arrayValue?.last)
        #expect(line["unsure"] == .strings(["salary"]))
        try ChangesAPI.editLine(f.app, id: MEETING, start: try #require(line["start"]?.doubleValue), text: "Thanks Rico, the salary band is fine!")
        #expect(try f.page()["transcript"]?.arrayValue?.last?["unsure"] == .array([]))
    }

    @Test func test_http_delete_audio_keeps_the_meeting() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/delete-audio")
        let freed = try #require(answer["freed"]?.intValue)
        #expect(status == 200 && freed > 0)
        #expect(answer["has_audio"] == .bool(false) && answer["audio_deleted"]?["bytes"] == .int(freed))
        #expect(answer["transcript"]?.arrayValue?.isEmpty == false)
        let (again, error) = post(s, "/api/meetings/\(MEETING)/delete-audio")
        #expect(again == 400 && error["error"] == .string("bad request: only a transcribed meeting's audio can be deleted"))
    }

    @Test func test_meeting_can_be_kept_on_this_mac() throws {
        let f = try Fixture()
        #expect(try f.page()["local_only"] == .bool(false))
        try ChangesAPI.setLocalOnly(f.app, id: MEETING, on: true)
        #expect(try f.page()["local_only"] == .bool(true))
        #expect(exists(f.paths.localOnly))
        try ChangesAPI.setLocalOnly(f.app, id: MEETING, on: false)
        #expect(try f.page()["local_only"] == .bool(false))
    }

    @Test func keptOnThisMacOverHTTPIsOnUnlessSaidOtherwise() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        #expect(post(s, "/api/meetings/\(MEETING)/local-only").1["local_only"] == .bool(true))
        #expect(post(s, "/api/meetings/\(MEETING)/local-only", .object([("on", .bool(false))])).1["local_only"] == .bool(false))
        #expect(post(s, "/api/meetings/nope/local-only").0 == 404)
    }

    // MARK: - the review

    @Test func markingReviewedKeepsWhatWasOpenAndUnmarkingPutsItBack() throws {
        let f = try Fixture()
        try ChangesAPI.markReviewed(f.app, id: MEETING, done: true) { entry in
            #expect(entry["id"] == .string(MEETING))
            return ["unnamed|SPEAKER_00"]
        }
        let review = try #require(read(f.paths.review))
        #expect(Array(review.objectKeys) == ["reviewed", "seen"] && review["seen"] == .strings(["unnamed|SPEAKER_00"]))
        try ChangesAPI.markReviewed(f.app, id: MEETING, done: false) { _ in [] }
        #expect(!exists(f.paths.review))
        try FileManager.default.removeItem(at: f.paths.transcriptJson)  // processing: nothing is open to see
        try ChangesAPI.markReviewed(f.app, id: MEETING, done: true) { _ in Issue.record("asked"); return [] }
        #expect(read(f.paths.review)?["seen"] == .array([]))
        #expect(throws: Refused.self) { try ChangesAPI.markReviewed(f.app, id: MEETING, done: false) { _ in [] } }
    }
}

/// Any vectors will do: the test is about which meetings are indexed, not what they mean.
private final class TinyEncoder: MeaningEncoder {
    let dimension = 4
    func query(_ text: String) throws -> [Float] { [1, 0, 0, 0] }
    func passages(_ texts: [String]) throws -> [[Float]] { texts.map { _ in [0.5, 0.5, 0.5, 0.5] } }
}
