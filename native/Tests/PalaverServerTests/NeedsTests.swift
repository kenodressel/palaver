// What waits on the user ("Needs you", phase 2 of the UI spec; api.py `needs`, `_meeting_needs`, `_cut_later`,
// `open_questions`, `mark_reviewed`): tests/test_needs.py's 19 under their names (the "Don't Know" ones with them) and
// test_attribution.py's two open-question tests. Python's tests monkeypatch `cutting.suggest_cut` and `api._clock`;
// here `Background.cutLookup` and `Background.clock` are replaced before the first request.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"
private let OLDER = "2026-10-26T09-00-00"

private func write(_ value: JSONValue, to url: URL) throws { try Data(PythonJSON.dumps(value).utf8).write(to: url) }
private func read(_ url: URL) -> JSONValue { PythonJSON.read(url) ?? .null }
private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private extension JSONValue {
    subscript(i: Int) -> JSONValue? { arrayValue.flatMap { $0.indices.contains(i) ? $0[i] : nil } }
    var list: [JSONValue] { arrayValue ?? [] }
}

private func kinds(_ found: JSONValue, _ mid: String = MEETING) -> [String] {
    found["meetings"]?.list.filter { $0["id"] == .string(mid) }.flatMap { $0["items"]?.list ?? [] }
        .compactMap { $0["kind"]?.stringValue } ?? []
}

private func items(_ found: JSONValue, _ mid: String = MEETING) -> [JSONValue] {
    found["meetings"]?.list.first { $0["id"] == .string(mid) }?["items"]?.list ?? []
}

private let CUT: JSONValue = .object([("at", .double(13.0)), ("event", .string("Weekly")),
                                      ("event_start", .string("2026-10-27T16:03:20+01:00")), ("why", .string("new voices"))])

/// Something a lookup waits for, opened by the test.
private final class Gate: @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    func wait() { if sem.wait(timeout: .now() + 5) == .success { sem.signal() } }
    func set() { sem.signal() }
    func call() { lock.withLock { count += 1 } }
    var calls: Int { lock.withLock { count } }
}

/// The time the cut lookups see (`api._clock`).
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Double
    init(_ t: Double) { self.t = t }
    var now: Double {
        get { lock.withLock { t } }
        set { lock.withLock { t = newValue } }
    }
}

/// The window's meeting and the app over it for "Timo" (no HTTP); `calendar`: a calendar is connected.
private final class Fixture {
    let dir: URL
    let out: URL
    let stores: StorePaths
    let app: ServerApp
    var paths: RecordingPaths { RecordingPaths(out.appendingPathComponent(MEETING, isDirectory: true)) }

    init(calendar: CalendarProvider? = nil, meeting: Bool = true, dir: URL? = nil) throws {
        self.dir = dir ?? tempFolder("needs")
        out = self.dir.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        stores = StorePaths(configDir: self.dir.appendingPathComponent("config/palaver", isDirectory: true),
                            home: self.dir.appendingPathComponent("home", isDirectory: true))
        app = ServerApp(outputDir: out, userName: "Timo", stores: stores, calendar: calendar)
        if meeting { try pageMeeting(out) }
    }

    deinit {
        app.background.waitForCutLookups(5)
        try? FileManager.default.removeItem(at: dir)
    }

    func needs() throws -> JSONValue { try ReviewAPI.needs(app) }
    func reviewed(_ id: String = MEETING, done: Bool = true) throws { try ReviewAPI.markReviewed(app, id: id, done: done) }
    func page() throws -> JSONValue { try MeetingsAPI.getMeeting(app: app, id: MEETING) }
    func unnamed() throws -> JSONValue? { try MeetingsAPI.listMeetings(app: app).first?["unnamed"] }
    func undo(_ token: String) throws -> [String] { try UndoRoute.undoChange(app, token: token) }

    /// A project "Foundry" proposed by the rules for the meeting.
    func proposeFoundry() throws -> String {
        let store = ProjectStore(path: stores.projects)
        let pid = try store.create("Foundry")
        try store.assign(MEETING, pid, by: "auto", why: "title", confidence: 0.7)
        try store.save()
        return pid
    }

    func guessRicoByVoice() throws {
        try write(.object([("SPEAKER_01", .object([("name", .string("Rico")), ("similarity", .double(0.7))]))]), to: paths.speakersAuto)
    }

    func inferCarla() throws {
        try write(.object([("SPEAKER_00", .object([("name", .string("Carla")), ("rule", .string("elimination")),
                                                   ("why", .string("the one invitee left")), ("confidence", .double(0.8))]))]),
                  to: paths.speakersInferred)
    }
}

/// test_attribution.py `_with_events`: the planned series event and an ad-hoc call at the meeting's start.
private func withEvents() throws -> (CalendarEvent, CalendarEvent) {
    let start = try PyDateTime.parse("2026-10-27T16:03:07+01:00")
    let planned = CalendarEvent(title: "Northwind", start: start, end: try! start.adding(seconds: 3600),
                                attendees: [Attendee(name: "Anna", email: "anna@x.com")], uid: "north", series: true)
    let adhoc = CalendarEvent(title: "Ad hoc", start: start, end: try! start.adding(seconds: 600),
                              attendees: [Attendee(name: "Bob", email: "bob@x.com")], uid: "adhoc")
    return (planned, adhoc)
}

@Suite struct NeedsTests {
    @Test func test_an_unreviewed_meeting_lists_what_is_open_in_the_order_of_the_page() throws {
        let f = try Fixture()
        try f.guessRicoByVoice()
        let pid = try f.proposeFoundry()
        let found = try f.needs()
        // SPEAKER_00 talks 11 s and has no name; SPEAKER_01 is a guess by voice; the project is a proposal.
        #expect(kinds(found) == ["unnamed", "speaker", "project", "review"])
        let all = items(found)
        try #require(all.count == 4)
        let (unnamed, speaker, project, review) = (all[0], all[1], all[2], all[3])
        #expect(unnamed["label"] == .string("SPEAKER_00") && unnamed["display"] == .string("Speaker 1"))
        #expect(unnamed["talk_seconds"] == .double(11.0))
        #expect(unnamed["clip"] == .object([("start", .double(1.0)), ("end", .double(9.0))]))
        #expect(unnamed["guesses"] == .strings(["Rico"]))  // "Hi Rico" — and SPEAKER_00 answers
        #expect(speaker["label"] == .string("SPEAKER_01") && speaker["name"] == .string("Rico"))
        #expect(speaker["why"] == .string("voice 70% alike"))
        #expect(project["project"] == .string(pid) && project["name"] == .string("Foundry"))
        #expect(PythonJSON.dumps(review) == #"{"kind": "review", "id": "review"}"#)
        #expect([unnamed, speaker, project].compactMap { $0["id"]?.stringValue }
                == ["unnamed|SPEAKER_00", "speaker|SPEAKER_01|Rico", "project|\(pid)"])
        let m = found["meetings"]?[0]
        #expect(m?["id"] == .string(MEETING) && m?["title"] == .string("Hiring debrief") && m?["start"] == .string("2026-10-27T16:03:07+01:00"))
        #expect(found["count"] == .int(1))  // meetings waiting
    }

    @Test func test_a_reviewed_meeting_needs_nothing_it_had_and_the_newest_comes_first() throws {
        let f = try Fixture(meeting: false)
        try pageMeeting(f.out, OLDER)
        try pageMeeting(f.out)
        #expect(try f.needs()["meetings"]?.list.compactMap { $0["id"]?.stringValue } == [MEETING, OLDER])
        try f.reviewed()
        let found = try f.needs()
        #expect(found["meetings"]?.list.compactMap { $0["id"]?.stringValue } == [OLDER] && found["count"] == .int(1))
    }

    @Test func test_a_reviewed_meeting_shows_what_appeared_after_its_review() throws {
        let f = try Fixture()  // Speaker 1 has no name
        try f.reviewed()
        #expect(read(f.paths.review)["seen"] == .strings(["unnamed|SPEAKER_00"]))  // left as it was: answered
        #expect(PythonJSON.dumps(try f.needs()) == #"{"count": 0, "meetings": []}"#)

        _ = try f.proposeFoundry()  // a project proposed after the review, and a name guessed
        try f.guessRicoByVoice()
        let found = try f.needs()
        #expect(kinds(found) == ["speaker", "project"] && found["count"] == .int(1))  // no review item: it is reviewed

        try f.reviewed(done: false)  // not reviewed: everything again
        #expect(kinds(try f.needs()) == ["unnamed", "speaker", "project", "review"])
    }

    @Test func test_which_event_an_unsure_one_and_none_at_all() throws {
        let plain = try Fixture()
        let f = try Fixture(calendar: { _, _ in [] }, meeting: false, dir: plain.dir)  // connected, nothing runs into another meeting
        let start = try PyDateTime.parse("2026-10-27T16:03:07+01:00")
        let planned = CalendarEvent(title: "Northwind", start: start, end: try! start.adding(seconds: 3600),
                                    attendees: [Attendee(name: "Anna", email: "anna@x.com")], uid: "north")
        let adhoc = CalendarEvent(title: "Ad hoc", start: start, end: try! start.adding(seconds: 600),
                                  attendees: [Attendee(name: "Bob", email: "bob@x.com")], uid: "adhoc")

        // No event, no question: which was it? Only asked with a calendar to pick from.
        #expect(!kinds(try plain.needs()).contains("no_event"))
        #expect(kinds(try f.needs()).first == "no_event")

        try CalendarEvents.ask(f.paths, [planned, adhoc])
        var item = items(try f.needs()).first
        #expect(item?["kind"] == .string("which_event") && item?["reason"] == .string("2 events overlapped the recording"))
        #expect(item?["choices"]?.list.compactMap { $0["title"]?.stringValue } == ["Ad hoc", "Northwind"])

        try CalendarEvents.save(f.paths, planned, Link("event", "Northwind", "calendar", 0.6, "time match"))
        item = items(try f.needs()).first
        #expect(item?["kind"] == .string("event") && item?["title"] == .string("Northwind") && item?["why"] == .string("time match"))

        try CalendarEvents.dismiss(f.paths)  // "an ad-hoc call": not asked again
        f.app.background.waitForCutLookups(5)
        #expect(kinds(try f.needs()) == ["unnamed", "review"])
    }

    @Test func test_a_suggested_cut_is_open_until_dismissed() throws {
        let f = try Fixture(calendar: { _, _ in [] })
        f.app.background.cutLookup = { _, paths in exists(paths.cutDismissed) ? .null : CUT }
        _ = try f.needs()
        f.app.background.waitForCutLookups(5)
        let shown = items(try f.needs())
        #expect(shown.count > 1 && shown[1] == .object([("kind", .string("cut")), ("id", .string("cut"))] + [
            ("at", .double(13.0)), ("event", .string("Weekly")), ("event_start", .string("2026-10-27T16:03:20+01:00")),
            ("why", .string("new voices")),
        ]))
        try ChangesAPI.dismissCut(f.app, id: MEETING, dismiss: true, what: "cut")
        _ = try f.needs()
        f.app.background.waitForCutLookups(5)
        #expect(!kinds(try f.needs()).contains("cut"))
    }

    /// The first request never waits for the lookup: the lookup is held until after it answered.
    @Test func test_the_cut_is_looked_up_in_the_background_and_again_later() throws {
        let f = try Fixture(calendar: { _, _ in [] })
        let gate = Gate()
        f.app.background.cutLookup = { _, _ in
            gate.call()
            gate.wait()
            return CUT
        }
        let clock = Clock(Date().timeIntervalSince1970)
        f.app.background.clock = { clock.now }
        #expect(!kinds(try f.needs()).contains("cut"))  // never waits for it
        gate.set()
        f.app.background.waitForCutLookups(5)
        #expect(kinds(try f.needs()).contains("cut"))
        #expect(gate.calls == 1)  // kept
        clock.now += Background.CUT_FRESH_SECONDS  // ten minutes on: looked up again
        #expect(kinds(try f.needs()).contains("cut"))  // the last answer meanwhile
        f.app.background.waitForCutLookups(5)
        #expect(gate.calls == 2)
    }

    @Test func test_a_lookup_that_takes_too_long_counts_as_failed_and_is_tried_later() throws {
        let f = try Fixture(calendar: { _, _ in [] })
        let gate = Gate()
        f.app.background.cutLookup = { _, _ in
            gate.call()
            gate.wait()
            return .null
        }
        let span = Background.CUT_FRESH_SECONDS
        let clock = Clock((Date().timeIntervalSince1970 / span).rounded(.down) * span + 1)  // early in a ten minutes' span
        f.app.background.clock = { clock.now }
        _ = try f.needs()
        clock.now += Background.CUT_LOOKUP_SECONDS + 1
        _ = try f.needs()  // timed out: not asked again at once
        #expect(until { gate.calls == 1 })  // the lookup runs in a thread of its own
        usleep(50_000)
        #expect(gate.calls == 1)
        gate.set()
        f.app.background.waitForCutLookups(5)
        clock.now += Background.CUT_FRESH_SECONDS
        _ = try f.needs()
        f.app.background.waitForCutLookups(5)
        #expect(until { gate.calls == 2 })
    }

    /// `look()`'s `except`: a lookup that fails keeps the last answer (api.py's `found = last`).
    @Test func aFailedLookupKeepsTheLastAnswer() throws {
        struct Broken: Error {}
        let f = try Fixture(calendar: { _, _ in [] })
        let fail = Clock(0)  // 1: the lookup throws
        f.app.background.cutLookup = { _, _ in
            if fail.now == 1 { throw Broken() }
            return CUT
        }
        let clock = Clock(Date().timeIntervalSince1970)
        f.app.background.clock = { clock.now }
        _ = try f.needs()
        f.app.background.waitForCutLookups(5)
        #expect(kinds(try f.needs()).contains("cut"))
        fail.now = 1
        clock.now += Background.CUT_FRESH_SECONDS  // stale: looked up again, and that fails
        _ = try f.needs()
        f.app.background.waitForCutLookups(5)
        #expect(kinds(try f.needs()).contains("cut"))  // the fresh answer is the last one
    }

    @Test func test_needs_are_cached_per_meeting_by_its_files() throws {
        let f = try Fixture()
        let first = try f.needs()
        let made = f.app.reviewCaches.needs.misses
        #expect(PythonJSON.dumps(try f.needs()) == PythonJSON.dumps(first))
        #expect(f.app.reviewCaches.needs.misses == made && f.app.reviewCaches.needs.hits == 1)  // not built again
        try write(.object([("SPEAKER_00", .string("Rico"))]), to: f.paths.speakers)  // named: built again
        #expect(kinds(try f.needs()) == ["review"])
    }

    @Test func test_live_and_unfinished_meetings_need_nothing_yet() throws {
        let f = try Fixture()
        try FileManager.default.removeItem(at: f.paths.transcriptJson)  // still being processed
        #expect(PythonJSON.dumps(try f.needs()) == #"{"count": 0, "meetings": []}"#)
    }

    @Test func test_http_needs_and_undoing_a_dismissed_cut() throws {
        let s = try TestServer(userName: "Timo", meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let r = s.get("/api/needs")
        #expect(r.status == 200 && r.json?["meetings"]?.list.compactMap { $0["id"]?.stringValue } == [MEETING])
        let paths = RecordingPaths(s.app.outputDir.appendingPathComponent(MEETING, isDirectory: true))
        _ = s.post("/api/meetings/\(MEETING)/cut-suggestion", .object([("dismiss", .bool(true))]))
        #expect(exists(paths.cutDismissed))
        #expect(s.post("/api/meetings/\(MEETING)/cut-suggestion", .object([("dismiss", .bool(false))])).status == 200)
        #expect(!exists(paths.cutDismissed))
    }

    @Test func test_confirming_a_guessed_name_can_be_undone() throws {
        let f = try Fixture()
        try f.inferCarla()
        #expect(kinds(try f.needs()).contains("speaker"))
        let token = try #require(try PeopleAPI.nameSpeaker(f.app, id: MEETING, label: "SPEAKER_00", name: "Carla"))
        // A confirmation is a change like any other: Today's card comes back with its undo.
        #expect(kinds(try f.needs()) == ["review"])
        _ = try f.undo(token)
        let lane = try f.page()["speakers"]?[1]
        #expect(lane?["name"] == .string("Carla") && lane?["named_by"] == .string("inferred"))
    }

    // MARK: - "Don't Know": a voice the user can't name

    @Test func test_a_voice_nobody_knows_is_no_to_do_but_stays_an_unnamed_lane() throws {
        let f = try Fixture()
        #expect(try f.unnamed() == .int(1) && kinds(try f.needs()).contains("unnamed"))
        let token = try PeopleAPI.setUnknown(f.app, id: MEETING, label: "SPEAKER_00", on: true)
        #expect(!token.isEmpty && read(f.paths.speakersUnknown) == .strings(["SPEAKER_00"]))
        #expect(kinds(try f.needs()) == ["review"])
        let entry = try MeetingsAPI.listMeetings(app: f.app).first
        #expect(entry?["unnamed"] == .int(0) && entry?["nameless"] == .int(1))  // no to-do, still a voice in the meeting
        var lane = try f.page()["speakers"]?[1]
        #expect(lane?["label"] == .string("SPEAKER_00") && lane?["name"] == .null && lane?["unknown"] == .bool(true))
        #expect(lane?["guesses"]?.truthy == true)  // a normal unnamed lane: its suggestions stay

        _ = try PeopleAPI.setUnknown(f.app, id: MEETING, label: "SPEAKER_00", on: false)  // Ask Me Again
        #expect(!exists(f.paths.speakersUnknown))
        #expect(try f.unnamed() == .int(1) && kinds(try f.needs()).contains("unnamed"))
        lane = try f.page()["speakers"]?[1]
        #expect(lane?["unknown"] == .bool(false))
    }

    @Test func test_dont_know_is_undone_with_its_token() throws {
        let f = try Fixture()
        let token = try PeopleAPI.setUnknown(f.app, id: MEETING, label: "SPEAKER_00", on: true)
        #expect(try f.undo(token) == [MEETING])
        #expect(try !exists(f.paths.speakersUnknown) && f.unnamed() == .int(1))
    }

    @Test func test_dont_know_is_said_of_a_voice_of_the_meeting() throws {
        let f = try Fixture()
        #expect(throws: NotFound.self) { try PeopleAPI.setUnknown(f.app, id: MEETING, label: "SPEAKER_09", on: true) }
        try write(.object([("SPEAKER_01", .string("SPEAKER_00"))]), to: f.paths.speakersMerged)
        _ = try PeopleAPI.setUnknown(f.app, id: MEETING, label: "SPEAKER_01", on: true)  // a merged voice is the lane it joined
        #expect(read(f.paths.speakersUnknown) == .strings(["SPEAKER_00"]))
    }

    @Test func test_naming_a_voice_nobody_knew_takes_it_out_of_dont_know() throws {
        let f = try Fixture()
        _ = try PeopleAPI.setUnknown(f.app, id: MEETING, label: "SPEAKER_00", on: true)
        _ = try PeopleAPI.nameSpeaker(f.app, id: MEETING, label: "SPEAKER_00", name: "Rico")
        #expect(!exists(f.paths.speakersUnknown))
        _ = try PeopleAPI.nameSpeaker(f.app, id: MEETING, label: "SPEAKER_00", name: "")  // unnamed again: asked again
        #expect(try f.unnamed() == .int(1))
    }

    @Test func test_the_undo_of_a_naming_brings_dont_know_back() throws {
        let f = try Fixture()
        _ = try PeopleAPI.setUnknown(f.app, id: MEETING, label: "SPEAKER_00", on: true)
        // Inferred later, then confirmed: the speaker-file snapshot of that confirmation holds speakers_unknown.json too.
        try f.inferCarla()
        let token = try #require(try PeopleAPI.nameSpeaker(f.app, id: MEETING, label: "SPEAKER_00", name: "Carla"))
        #expect(!exists(f.paths.speakersUnknown))
        _ = try f.undo(token)
        #expect(read(f.paths.speakersUnknown) == .strings(["SPEAKER_00"]))
    }

    @Test func test_a_reviewed_meeting_has_no_voices_to_name_left_in_the_list() throws {
        let f = try Fixture()
        try f.reviewed()  // Speaker 1 was open then: the user saw it and left it
        let entry = try MeetingsAPI.listMeetings(app: f.app).first
        #expect(entry?["unnamed"] == .int(0) && entry?["nameless"] == .int(1))
        try f.reviewed(done: false)
        #expect(try f.unnamed() == .int(1))
    }

    @Test func test_a_voice_unnamed_after_the_review_is_to_name_again() throws {
        let f = try Fixture()
        try write(.object([("SPEAKER_00", .string("Rico"))]), to: f.paths.speakers)
        try f.reviewed()
        #expect(try f.unnamed() == .int(0))
        _ = try PeopleAPI.nameSpeaker(f.app, id: MEETING, label: "SPEAKER_00", name: "")  // not seen at the review: a to-do
        #expect(try f.unnamed() == .int(1) && kinds(try f.needs()) == ["unnamed"])
    }

    @Test func test_http_dont_know() throws {
        let s = try TestServer(userName: "Timo", meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let path = "/api/meetings/\(MEETING)/unknown"
        let r = s.post(path, .object([("label", .string("SPEAKER_00")), ("on", .bool(true))]))
        let answer = r.json ?? .null
        #expect(r.status == 200 && answer["undo"]?.stringValue?.isEmpty == false && answer["speakers"]?[1]?["unknown"] == .bool(true))
        #expect(s.post(path, .object([("label", .string("SPEAKER_00")), ("on", .string("yes"))])).status == 400)
        #expect(s.post(path, .object([("label", .string("SPEAKER_09")), ("on", .bool(true))])).status == 404)
        #expect(s.post("/api/undo", .object([("token", answer["undo"] ?? .null)])).status == 200)
        #expect(!exists(RecordingPaths(s.app.outputDir.appendingPathComponent(MEETING, isDirectory: true)).speakersUnknown))
    }

    // MARK: - test_attribution.py

    @Test func test_open_questions_list_overlapping_events_and_unsure_links() throws {
        let f = try Fixture()
        let (planned, adhoc) = try withEvents()
        try CalendarEvents.ask(f.paths, [planned, adhoc])
        try write(.object([("SPEAKER_00", .object([("name", .string("Rico")), ("similarity", .double(0.7))]))]), to: f.paths.speakersAuto)
        let found = try ReviewAPI.questions(f.app)
        #expect(found.map { [$0["meeting"], $0["kind"]] } == [[.string(MEETING), .string("event")], [.string(MEETING), .string("speaker")]])
        try #require(found.count == 2)
        #expect(found[0]["question"] == .string("Which calendar event was this recording?"))
        #expect(found[0]["choices"]?.list.compactMap { $0["title"]?.stringValue } == ["Ad hoc", "Northwind"])
        #expect(found[1]["link"]?["label"] == .string("Speaker: Rico (voice 70% alike)"))
        #expect(found[1]["label"] == .string("SPEAKER_00"))
    }

    /// Python fails the test if `_speakers` (the page's lanes) is called, and on the second call if `_lane_links` is: here
    /// the questions' own cache counts what it made.
    @Test func test_open_questions_do_not_build_every_meeting() throws {
        let f = try Fixture()
        try write(.object([("SPEAKER_00", .object([("name", .string("Rico")), ("similarity", .double(0.7))]))]), to: f.paths.speakersAuto)
        let first = try ReviewAPI.questions(f.app)
        #expect(first.compactMap { $0["kind"]?.stringValue } == ["speaker"])
        #expect(first.first?["link"]?["label"] == .string("Speaker: Rico (voice 70% alike)"))
        #expect(f.app.reviewCaches.questions.misses == 1)
        #expect(PythonJSON.dumps(.array(try ReviewAPI.questions(f.app))) == PythonJSON.dumps(.array(first)))
        #expect(f.app.reviewCaches.questions.misses == 1 && f.app.reviewCaches.questions.hits == 1)
    }
}
