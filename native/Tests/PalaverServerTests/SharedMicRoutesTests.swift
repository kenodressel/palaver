// Voices that can't be told apart (#56) through the window (api.py `set_shared`, `_derive_shared`, `remember_series`,
// `dismiss_shared_suggestion`, `_undo_shared`; their routes). Ports test_shared_mic.py's window tests under their
// names; the marks themselves are SharedMicTests'. Python's two tests on the e2e recordings run on the window's meeting
// here. `test_mcp_and_search_show_the_room_not_a_guessed_person` is here with its search and MCP halves.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"

private func write(_ value: JSONValue, to url: URL) throws { try Data(PythonJSON.dumps(value).utf8).write(to: url) }
private func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

private extension JSONValue {
    subscript(i: Int) -> JSONValue? { arrayValue.flatMap { $0.indices.contains(i) ? $0[i] : nil } }
    var list: [JSONValue] { arrayValue ?? [] }
}

/// `_lanes`: the speakers but the user, by label.
private func lanes(_ m: JSONValue) -> [String: JSONValue] {
    var out: [String: JSONValue] = [:]  // test labels are ASCII
    for s in m["speakers"]?.list ?? [] where s["is_user"] != .bool(true) { if let l = s["label"]?.stringValue { out[l] = s } }
    return out
}

private func speakersOf(_ m: JSONValue) -> [String] { m["transcript"]?.list.compactMap { $0["speaker"]?.stringValue } ?? [] }

/// test_shared_mic.py `_event`: an hour from 16:00 with `invited` people ("Person 0", …), a room, and the user.
private func event(_ title: String = "Weekly", invited: Int = 2, room: Bool = false, location: String = "", uid: String = "abc",
                   series: Bool = false) throws -> CalendarEvent {
    let start = try PyDateTime.parse("2026-10-27T16:00:00+01:00")
    let people = (0..<invited).map { Attendee(name: "Person \($0)") }
    let rooms = room ? [Attendee(name: "Raum 3.12", isRoom: true)] : []
    return CalendarEvent(title: title, start: start, end: try! start.adding(seconds: 3600),
                         attendees: people + rooms + [Attendee(name: "Timo", isSelf: true)], uid: uid, series: series, location: location)
}

/// The window's meeting (`_window_meeting`) and the app over it for "Timo" (no HTTP).
private final class Fixture {
    let dir: URL
    let out: URL
    let stores: StorePaths
    let app: ServerApp
    let paths: RecordingPaths

    init() throws {
        dir = tempFolder("shared")
        out = dir.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                            home: dir.appendingPathComponent("home", isDirectory: true))
        app = ServerApp(outputDir: out, userName: "Timo", stores: stores)
        paths = try pageMeeting(out)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func page(_ id: String = MEETING) throws -> JSONValue { try MeetingsAPI.getMeeting(app: app, id: id) }
    @discardableResult
    func shared(on: Bool, label: String? = nil, name: String? = nil, series: Bool? = nil, id: String = MEETING) throws -> String {
        try PeopleAPI.setShared(app, id: id, on: on, label: label, name: name, series: series)
    }
    func undo(_ token: String) throws { _ = try UndoRoute.undoChange(app, token: token) }
}

private func post(_ s: TestServer, _ path: String, _ body: JSONValue) -> (Int, JSONValue) {
    let r = s.post(path, body)
    return (r.status, r.json ?? .null)
}

@Suite struct SharedMicRoutesTests {
    @Test func test_a_room_lane_shows_the_room_and_offers_no_names() throws {
        let f = try Fixture()
        try CalendarEvents.save(f.paths, try event("Hiring debrief", invited: 3))
        let token = try f.shared(on: true, label: "SPEAKER_00", name: "Raum 3.12")
        #expect(!token.isEmpty)
        var m = try f.page()
        let room = lanes(m)["SPEAKER_00"]
        #expect(room?["display"] == .string("Room (Raum 3.12)") && room?["name"] == .null)
        #expect(room?["shared"] == .string("room") && room?["room"] == .string("Raum 3.12"))
        #expect(room?["guesses"] == .array([]) && room?["maybe"] == .array([]) && room?["link"] == .null)  // not "Rico" from the notes
        #expect(Array(speakersOf(m).prefix(2)) == ["Timo", "Room (Raum 3.12)"])
        #expect(m["notes"]?["summary"] == .string("Room (Raum 3.12) ran the debrief."))
        #expect(m["shared"]?["line"] == .string(SharedMic.LINE))
        #expect(m["shared"]?["rooms"] == .object([("SPEAKER_00", .string("Raum 3.12"))]))
        #expect(text(f.paths.transcriptMd).contains("Room (Raum 3.12)"))

        try f.undo(token)
        m = try f.page()
        #expect(lanes(m)["SPEAKER_00"]?["shared"] == .null && m["shared"]?["line"] == .null)
        #expect(Array(speakersOf(m).prefix(2)) == ["Timo", "Speaker 1"])
    }

    @Test func aMarksUndoLooksForTheMeetingUnderTheProjectsLock() throws {
        // A trash holding the projects lock takes the folder while the undo waits for it: the undo then finds the
        // meeting gone (409), and puts nothing back into a folder that is no longer there.
        let f = try Fixture()
        let token = try f.shared(on: true, label: "SPEAKER_01")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Error?
        f.app.projectsLock.lock()
        Thread.detachNewThread {
            do { try f.undo(token) } catch { outcome = error }
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.3)  // the undo is waiting for the lock by now
        try FileManager.default.moveItem(at: f.paths.folder, to: f.dir.appendingPathComponent("trashed"))
        f.app.projectsLock.unlock()
        #expect(done.wait(timeout: .now() + 30) == .success)
        // The meeting is what changed (not a file the snapshot's fingerprints would find missing later).
        #expect((outcome as? UndoChanged)?.what == MEETING)
        #expect(!FileManager.default.fileExists(atPath: f.paths.folder.path))
    }

    @Test func test_a_marks_undo_keeps_only_this_meetings_marks_and_ignores_other_meetings() throws {
        let f = try Fixture()
        let other = try pageMeeting(f.out, "2026-10-27T10-00-00")
        let token = try f.shared(on: true, label: "SPEAKER_01")
        let manifest = try #require(PythonJSON.read(f.out.appendingPathComponent(".trash/.undo/\(token)/manifest.json")))
        #expect(manifest["meetings"] == .object([]))  // no meeting's speaker files, no voice bank
        #expect(try Undo.stores(f.out, token).map(\.lastPathComponent) == ["speakers_shared.json"])
        try write(.object([]), to: other.speakersAuto)  // a call got processed meanwhile
        try f.undo(token)
        #expect(lanes(try f.page())["SPEAKER_01"]?["shared"] == .null)
        #expect(!text(f.paths.transcriptMd).contains("Room"))
    }

    /// Python counts the calls of `refresh_recognition` and `_remember_voices` (monkeypatched); here the undo snapshots
    /// say nothing is derived (`derive` false), which is what `set_shared` and its undo decide by.
    @Test func test_naming_a_room_or_remembering_a_series_recognizes_nothing_again() throws {
        let f = try Fixture()
        try CalendarEvents.save(f.paths, try event("All Hands", series: true))
        let marked = try f.shared(on: true, label: "SPEAKER_00")
        let whole = try f.shared(on: true)
        #expect(try Undo.extra(f.out, marked)["derive"] == .bool(true) && Undo.extra(f.out, whole)["derive"] == .bool(true))
        let named = try f.shared(on: true, label: "SPEAKER_00", name: "Lab")
        let remembered = try f.shared(on: true, series: true)
        #expect(try Undo.extra(f.out, named)["derive"] == .bool(false))
        #expect(try Undo.extra(f.out, remembered)["derive"] == .bool(false))
        try f.undo(remembered)
        try f.undo(named)
    }

    @Test func test_a_room_named_and_both_changes_undone_in_turn() throws {
        let f = try Fixture()
        let marked = try f.shared(on: true, label: "SPEAKER_01")
        let named = try f.shared(on: true, label: "SPEAKER_01", name: "Raum 3.12")
        try f.undo(named)
        try f.undo(marked)
        #expect(lanes(try f.page())["SPEAKER_01"]?["shared"] == .null)
    }

    @Test func test_a_room_is_no_open_question_and_no_unnamed_voice() throws {
        let f = try Fixture()
        func unnamed() throws -> [String] {
            try ReviewAPI.needs(f.app)["meetings"]?.list.flatMap { $0["items"]?.list ?? [] }
                .filter { $0["kind"] == .string("unnamed") }.compactMap { $0["label"]?.stringValue } ?? []
        }
        #expect(try unnamed() == ["SPEAKER_00"] && MeetingsAPI.listMeetings(app: f.app).first?["unnamed"] == .int(1))
        try f.shared(on: true, label: "SPEAKER_00")
        #expect(try unnamed() == [])
        let entry = try MeetingsAPI.listMeetings(app: f.app).first
        #expect(entry?["unnamed"] == .int(0) && entry?["people"] == .array([]))
    }

    /// The search half; the MCP half is the Python `palaver mcp` server's (not ported; see the ledger).
    @Test func test_mcp_and_search_show_the_room_not_a_guessed_person() throws {
        let f = try Fixture()
        _ = try PeopleAPI.nameSpeaker(f.app, id: MEETING, label: "SPEAKER_01", name: "Rico")
        _ = try ProjectsAPI.setMeetingProject(f.app, id: MEETING, name: "Hiring")
        try f.shared(on: true, label: "SPEAKER_01", name: "Lab")
        let hits = try SearchAPI.search(f.app, "salary", userName: "Timo").first?["hits"]?.list ?? []
        #expect(hits.compactMap { $0["speaker"]?.stringValue } == ["Room (Lab)"])
        // The MCP half (phase 4 batch 6: the Swift `palaver mcp`).
        let m = McpTools(app: f.app, userName: "Timo")
        m.meaning = { _, _, _ in [] }
        let found = try m.searchMeetings(query: "salary")["meetings"]?.list ?? []
        #expect(found.count == 1 && found[0]["lines"] == .strings(["[0:13] Room (Lab): Thanks Rico, the salary band is fine."]))
        let speakers = (try m.getMeeting(meetingId: MEETING)["speakers"]?.list ?? []).compactMap(\.stringValue)
        #expect(speakers.contains("Room (Lab)") && !speakers.contains("Rico"))
        #expect(try m.getProject(project: "Hiring")["next_steps"]?[0]?["owner"] == .string("Room (Lab)"))
        #expect(try m.listPeople() == .array([]))
    }

    @Test func test_a_whole_meeting_mark_can_be_remembered_for_its_series() throws {
        let f = try Fixture()
        try CalendarEvents.save(f.paths, try event("All Hands", series: true))
        var m = try f.page()
        #expect(m["shared_suggestion"] == .object([("why", .string("The calendar calls it “All Hands”."))]))
        #expect(m["shared"]?["series"] == .object([("can", .bool(true)), ("remembered", .bool(false))]))

        let token = try f.shared(on: true, series: true)
        m = try f.page()
        #expect(Set(lanes(m).values.compactMap { $0["display"]?.stringValue }) == ["Several people"])
        #expect(m["shared"]?["series"]?["remembered"] == .bool(true) && m["shared_suggestion"] == .null)
        try f.undo(token)
        m = try f.page()
        #expect(m["shared"]?["meeting"] == .bool(false) && m["shared"]?["series"]?["remembered"] == .bool(false))
    }

    @Test func test_a_meeting_marked_from_its_series_can_forget_the_series_after_it_was_unmarked() throws {
        let f = try Fixture()
        let e = try event("All Hands", series: true)
        try SharedMic.remember(e, true, stores: f.stores)
        try CalendarEvents.assign(f.paths, e, stores: f.stores)
        var m = try f.page()
        #expect(m["shared"]?["meeting"] == .bool(true) && m["shared"]?["from_series"] == .bool(true))
        #expect(m["shared"]?["series"]?["remembered"] == .bool(true))

        try f.shared(on: false)
        m = try f.page()
        #expect(m["shared"]?["meeting"] == .bool(false) && m["shared"]?["from_series"] == .bool(false))
        #expect(m["shared"]?["series"]?["remembered"] == .bool(true))
        let token = try PeopleAPI.rememberSeries(f.app, id: MEETING, remember: false)
        #expect(!SharedMic.remembered(e, stores: f.stores) && !SharedMic.meetingMarked(f.paths))
        try f.undo(token)
        #expect(SharedMic.remembered(e, stores: f.stores))
    }

    @Test func test_several_people_at_my_mic_show_as_the_room_not_as_me() throws {
        let f = try Fixture()
        try f.shared(on: true, label: SharedMic.MIC)
        var m = try f.page()
        let me = m["speakers"]?[0]
        #expect(me?["is_user"] == .bool(true) && me?["display"] == .string("Room (with you)"))
        #expect(me?["shared"] == .string("mic") && me?["room"] == .string(""))
        #expect(m["transcript"]?[0]?["speaker"] == .string("Room (with you)") && m["transcript"]?[0]?["label"] == .null)
        #expect(m["shared"]?["line"] == .string(SharedMic.LINE) && m["shared"]?["mic"] == .string(""))
        #expect(text(f.paths.transcriptMd).contains("Room (with you)") && !text(f.paths.transcriptMd).contains("**Timo**"))
        #expect(PythonJSON.read(f.paths.transcriptJson)?[0]?["speaker"] == .string("Timo"))  // still the microphone's line
        let hits = try SearchAPI.search(f.app, "welcome", userName: "Timo")
        #expect(hits.count == 1 && hits.first?["hits"]?[0]?["speaker"] == .string("Room (with you)"))

        try f.shared(on: true, label: SharedMic.MIC, name: "Raum 3.12")
        #expect(try f.page()["transcript"]?[0]?["speaker"] == .string("Room (Raum 3.12)"))
        try f.shared(on: false, label: SharedMic.MIC)
        m = try f.page()
        #expect(m["transcript"]?[0]?["speaker"] == .string("Timo") && m["shared"]?["line"] == .null)
        #expect(text(f.paths.transcriptMd).contains("**Timo**"))
    }

    @Test func test_a_whole_meeting_mark_covers_my_mic_only_in_person() throws {
        let f = try Fixture()
        try f.shared(on: true)
        #expect(try f.page()["transcript"]?[0]?["speaker"] == .string("Timo"))  // a call
        try Data("[]".utf8).write(to: f.paths.systemTurns)  // nobody on the system track: in person
        let m = try f.page()
        #expect(m["transcript"]?[0]?["speaker"] == .string("Room (with you)") && m["speakers"]?[0]?["shared"] == .string("meeting"))
    }

    @Test func test_one_person_after_all_keeps_the_rooms_name_for_when_it_is_marked_again() throws {
        let f = try Fixture()
        try f.shared(on: true, label: "SPEAKER_00", name: "Lab")
        try f.shared(on: false, label: "SPEAKER_00")
        #expect(lanes(try f.page())["SPEAKER_00"]?["shared"] == .null)
        try f.shared(on: true, label: "SPEAKER_00")
        #expect(lanes(try f.page())["SPEAKER_00"]?["display"] == .string("Room (Lab)"))
    }

    @Test func test_only_a_recurring_event_is_remembered() throws {
        let f = try Fixture()
        try CalendarEvents.save(f.paths, try event("All Hands", series: false))
        #expect(throws: Refused.self) { try f.shared(on: true, series: true) }
    }

    @Test func test_the_quiet_line_shows_only_while_a_marked_voice_is_in_the_meeting() throws {
        let f = try Fixture()
        try write(.object([("lanes", .object([("SPEAKER_09", .string("Lab"))]))]), to: f.paths.speakersShared)  // a voice cut away since
        #expect(try f.page()["shared"]?["line"] == .null)
    }

    @Test func test_http_marks_a_room_and_dismisses_the_suggestion() throws {
        let s = try TestServer(userName: "Timo", meetings: { try pageMeeting($0) })
        defer { s.stop() }
        var (status, m) = post(s, "/api/meetings/\(MEETING)/shared",
                               .object([("label", .string("SPEAKER_01")), ("on", .bool(true)), ("name", .string("Lab"))]))
        #expect(status == 200 && m["undo"]?.stringValue?.isEmpty == false && lanes(m)["SPEAKER_01"]?["display"] == .string("Room (Lab)"))
        #expect(post(s, "/api/meetings/\(MEETING)/shared", .object([("label", .string("SPEAKER_09")), ("on", .bool(true))])).0 == 404)
        (status, m) = post(s, "/api/meetings/\(MEETING)/shared-suggestion", .object([("dismiss", .bool(true))]))
        #expect(status == 200 && m["shared_suggestion"] == .null)
    }

    @Test func test_http_takes_marks_only_as_said_plainly() throws {
        let s = try TestServer(userName: "Timo", meetings: { try pageMeeting($0) })
        defer { s.stop() }
        func send(_ fields: [(String, JSONValue)]) -> (Int, JSONValue) { post(s, "/api/meetings/\(MEETING)/shared", .object(fields)) }
        let lane: JSONValue = .string("SPEAKER_01")
        #expect(send([("label", lane), ("on", .string("false"))]).0 == 400)  // not a JSON boolean
        #expect(send([("label", lane)]).0 == 400)
        #expect(send([("on", .bool(false)), ("series", .bool(true))]).0 == 400)  // a series only with the whole meeting marked
        #expect(send([("label", lane), ("on", .bool(true)), ("series", .bool(true))]).0 == 400)
        #expect(send([("label", lane), ("on", .bool(true)), ("name", .strings(["Lab"]))]).0 == 400)
        let (status, m) = send([("label", lane), ("on", .bool(true)), ("name", .string("  " + String(repeating: "R", count: 120) + " "))])
        #expect(status == 200 && lanes(m)["SPEAKER_01"]?["room"] == .string(String(repeating: "R", count: 80)))
    }
}
