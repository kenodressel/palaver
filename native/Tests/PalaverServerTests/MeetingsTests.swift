// The meeting list and the meeting page (api.py `list_meetings`, `get_meeting`, `meeting_paths`), and the
// list's cache. Ports the list and page tests of tests/test_webapp.py: where Python's test sets a meeting up
// through an api.py writer (`name_speaker`, `merge_speaker`, `remove_speaker`, `set_title`), this one writes
// the same files through the domain; the writers' own behaviour is tested with their routes. The four tests
// of the transcribe route keep their names in AppRoutesTests, with their list and page halves.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"
private let SR = 16_000

/// A finished meeting as test_webapp.py `_meeting` makes it: 20 s of both tracks, three turns (SPEAKER_02 never in
/// the transcript), three lines, notes with two name guesses written from that transcript.
@discardableResult
func pageMeeting(_ root: URL, _ name: String = "2026-10-27T16-03-07") throws -> RecordingPaths {
    let paths = RecordingPaths(root.appendingPathComponent(name, isDirectory: true))
    try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
    let n = SR * 20
    var system = [Int16](repeating: 0, count: n), mic = [Int16](repeating: 0, count: n)
    for t in 0..<n {  // numpy's astype(int16) truncates
        system[t] = Int16(3000 * sin(Double(t) / 7))
        mic[t] = Int16(2000 * sin(Double(t) / 3))
    }
    try Wav16.write(system, rate: SR, to: paths.systemWav)
    try Wav16.write(mic, rate: SR, to: paths.micWav)
    try write(.object([("start_time", .string("2026-10-27T16:03:07+01:00")), ("duration_seconds", .int(20))]), to: paths.meta)
    try write(.array([turn("SPEAKER_00", 1.0, 12.0), turn("SPEAKER_01", 13.0, 15.0), turn("SPEAKER_02", 16.0, 16.2)]),
              to: paths.systemTurns)
    let utterances = [
        Utterance(speaker: "Timo", start: 0.0, end: 1.0, text: "Hi Rico, äh, welcome."),
        Utterance(speaker: "SPEAKER_00", start: 1.0, end: 12.0, text: "Welcome to the hiring debrief."),
        Utterance(speaker: "SPEAKER_01", start: 13.0, end: 15.0, text: "Thanks Rico, the salary band is fine."),
    ]
    try write(.array(utterances.map(\.json)), to: paths.transcriptJson)
    func guess(_ label: String, _ evidence: String) -> JSONValue {
        .object([("label", .string(label)), ("name", .string("Rico")), ("evidence", .string(evidence))])
    }
    try NotesFile.save(paths, .object([
        ("title", .string("Hiring debrief")),
        ("summary", .string("SPEAKER_00 ran the debrief.")),
        ("sections", .array([])),
        ("next_steps", .array([.object([("owner", .string("SPEAKER_01")), ("task", .string("Send the offer"))])])),
        ("decisions", .strings(["Make an offer"])),
        ("speaker_names", .array([guess("SPEAKER_00", "Hi Rico"), guess("SPEAKER_01", "Thanks Rico")])),
        ("transcript_hash", .string(Notes.transcriptHash(utterances))),
    ]))
    return paths
}

private func turn(_ speaker: String, _ start: Double, _ end: Double) -> JSONValue {
    .object([("speaker", .string(speaker)), ("start", .double(start)), ("end", .double(end))])
}

/// `json.dumps(value)` into `url`.
private func write(_ value: JSONValue, to url: URL) throws {
    try Data(PythonJSON.dumps(value).utf8).write(to: url)
}

private func read(_ url: URL) throws -> JSONValue { try PythonJSON.parse(Data(contentsOf: url)) }

/// A file's modification time set by hand, so a test never depends on the clock moving between two writes.
private func touch(_ url: URL, _ seconds: Int) throws {
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(seconds))],
                                          ofItemAtPath: url.path)
}

/// A recordings folder and the stores in a temporary folder, and the app over them for "Timo" (no HTTP).
private final class Fixture {
    let dir: URL
    let out: URL
    let stores: StorePaths
    let app: ServerApp

    init(userName: String = "Timo") throws {
        dir = tempFolder("meetings")
        out = dir.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                            home: dir.appendingPathComponent("home", isDirectory: true))
        app = ServerApp(outputDir: out, userName: userName, stores: stores)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func list() throws -> [JSONValue] { try MeetingsAPI.listMeetings(app: app) }
    func page(_ id: String = MEETING) throws -> JSONValue { try MeetingsAPI.getMeeting(app: app, id: id) }
    func paths(_ id: String = MEETING) -> RecordingPaths { RecordingPaths(out.appendingPathComponent(id, isDirectory: true)) }

    /// What api.name_speaker leaves in speakers.json (the writer is the speaker routes').
    func name(_ label: String, _ name: String, id: String = MEETING) throws {
        var names = try Speakers.loadSpeakerNames(paths(id))
        names[label] = name
        try Speakers.saveSpeakerNames(paths(id), names, stores: stores)
    }
}

/// A process the live worker's pid check takes for `palaver … live <folder>` (`sh` keeps its arguments while it
/// waits for `sleep`), with its pid in live.pid; stopped by the caller.
func fakeLiveWorker(_ folder: URL) throws -> Foundation.Process {
    let p = Foundation.Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "sleep 60; :", "palaver", "live", folder.path]
    p.standardInput = FileHandle.nullDevice
    try p.run()
    try Data("\(p.processIdentifier)\n".utf8).write(to: folder.appendingPathComponent("live.pid"))
    return p
}

@Suite struct MeetingsTests {
    // MARK: - the list

    @Test func test_list_meetings_newest_first_with_titles() throws {
        let f = try Fixture()
        try pageMeeting(f.out, "2026-10-26T09-00-00")
        try pageMeeting(f.out)
        try FileManager.default.createDirectory(at: f.out.appendingPathComponent("not-a-recording"), withIntermediateDirectories: true)
        let meetings = try f.list()
        #expect(meetings.map { $0["id"] } == [.string(MEETING), .string("2026-10-26T09-00-00")])
        #expect(meetings[0]["title"] == .string("Hiring debrief") && meetings[0]["status"] == .string("ready"))
        #expect(meetings[0]["start"] == .string("2026-10-27T16:03:07+01:00"))
    }

    @Test func test_list_shows_who_was_there_and_what_is_left_to_do() throws {
        let f = try Fixture()
        let paths = try pageMeeting(f.out)
        var m = try #require(f.list().first)
        // SPEAKER_00 talked 11 s, SPEAKER_01 only 2 s: too little to ask for a name
        #expect(m["people"] == .array([]) && m["unnamed"] == .int(1))
        #expect(m["has_notes"] == .bool(true) && m["notes_stale"] == .bool(false) && m["title_from"] == .string("notes"))

        try f.name("SPEAKER_00", "Rico")
        try touch(paths.speakers, 2_000_000_000)
        m = try #require(f.list().first)  // file times changed: not the cached entry
        #expect(m["people"] == .strings(["Rico"]) && m["unnamed"] == .int(0))

        var transcript = try read(paths.transcriptJson).arrayValue!
        var line = PyDict<JSONValue>(transcript[1])!
        line["text"] = .string("Welcome to the new hiring debrief.")
        transcript[1] = line.json
        try write(.array(transcript), to: paths.transcriptJson)
        try touch(paths.transcriptJson, 2_000_000_001)
        m = try #require(f.list().first)
        #expect(m["notes_stale"] == .bool(true))
    }

    /// The window polls the list every few seconds: an entry is made again only when one of its files changed; the
    /// status and the projects, which change without them, are read every time.
    @Test func test_the_list_is_cached_until_a_file_changes() throws {
        let f = try Fixture()
        let paths = try pageMeeting(f.out)
        try pageMeeting(f.out, "2026-10-26T09-00-00")
        let cache = f.app.meetingList
        let first = try f.list()
        #expect(cache.misses == 2 && cache.hits == 0)
        #expect(try f.list() == first)
        #expect(cache.misses == 2 && cache.hits == 2)

        // Not in the entry's files: served from the cache, read anew.
        let store = ProjectStore(path: f.stores.projects)
        let pid = try store.create("Hiring")
        _ = try store.assign(MEETING, pid)
        try store.save()
        let withProject = try f.list()
        #expect(cache.misses == 2 && cache.hits == 4)
        #expect(withProject[0]["projects"]?.arrayValue?.first?["name"] == .string("Hiring"))
        let live = try fakeLiveWorker(paths.folder)
        defer { live.terminate(); live.waitUntilExit() }
        #expect(try f.list()[0]["status"] == .string("recording"))
        #expect(cache.misses == 2 && cache.hits == 6)
        live.terminate()
        live.waitUntilExit()

        // One file of the meeting changed: that entry is made again, the other one is not.
        try f.name("SPEAKER_00", "Rico")
        try touch(paths.speakers, 2_000_000_000)
        #expect(try f.list()[0]["people"] == .strings(["Rico"]))
        #expect(cache.misses == 3 && cache.hits == 7)
        // The glossary respells every meeting: all entries are made again.
        try FileManager.default.createDirectory(at: f.stores.glossary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(.object([("terms", .object([]))]), to: f.stores.glossary)
        _ = try f.list()
        #expect(cache.misses == 5 && cache.hits == 7)
        // A file that goes away counts as a change too.
        try FileManager.default.removeItem(at: paths.speakers)
        #expect(try f.list()[0]["people"] == .array([]))
        #expect(cache.misses == 6 && cache.hits == 8)
    }

    @Test func requestsFromSeveralThreadsShareTheCache() throws {
        let f = try Fixture()
        for i in 0..<4 { try pageMeeting(f.out, "2026-10-2\(i)T09-00-00") }
        let expected = try f.list()
        let lock = NSLock()
        var answers: [[JSONValue]] = []
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let got = try? f.list()
            lock.withLock { answers.append(got ?? []) }
        }
        #expect(answers.count == 16 && answers.allSatisfy { $0 == expected })
        #expect(f.app.meetingList.hits + f.app.meetingList.misses == 17 * 4)
        #expect(f.app.meetingList.misses >= 4)
    }

    @Test func aMissingFileSignsAsZeroAndAnyChangeIsSeen() throws {
        let dir = tempFolder("signature")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.json"), b = dir.appendingPathComponent("b.json")
        try Data("1".utf8).write(to: a)
        try touch(a, 1_700_000_000)
        #expect(SignatureCache<Int>.signature([a, b]) == [1_700_000_000 * 1_000_000_000, 0])
        let cache = SignatureCache<Int>()
        var made = 0
        func value() -> Int { cache.get(key: "k", files: [a, b]) { made += 1; return made } }
        #expect(value() == 1 && value() == 1)
        try Data("2".utf8).write(to: b)
        #expect(value() == 2 && value() == 2)
        try touch(a, 1_700_000_001)
        #expect(value() == 3)
        // Keys are code points: "Zoë" as one letter and as e + diaeresis are two entries.
        #expect(cache.get(key: "Zo\u{EB}", files: [a]) { 10 } == 10)
        #expect(cache.get(key: "Zoe\u{308}", files: [a]) { 11 } == 11)
        #expect(cache.hits == 2 && cache.misses == 5)
    }

    // MARK: - which folders

    @Test func test_meeting_ids_cannot_leave_the_recordings_folder() throws {
        let f = try Fixture()
        try pageMeeting(f.out)
        try FileManager.default.createDirectory(at: f.out.appendingPathComponent(".2026-10-27T16-03-07"), withIntermediateDirectories: true)
        for bad in ["..", "../etc", "2026-10-27T16-03-07/../..", "x", ".2026-10-27T16-03-07", "2026-10-27T16-03-07/",
                    "2026-10-27T16-03-08", ""] {
            #expect(throws: NotFound.self, "\(bad)") { try MeetingsAPI.meetingPaths(outputDir: f.out, id: bad) }
        }
        #expect(try MeetingsAPI.meetingPaths(outputDir: f.out, id: MEETING).folder.path == f.paths().folder.path)
    }

    @Test func overHTTPTheListAndAPageAndNothingOutside() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let list = s.get("/api/meetings")
        #expect(list.status == 200 && list.json?.arrayValue?.first?["id"] == .string(MEETING))
        let page = s.get("/api/meetings/\(MEETING)")
        #expect(page.status == 200 && page.json?["id"] == .string(MEETING) && page.json?["speakers"]?.arrayValue?.count == 3)
        #expect(page.header("Content-Type") == "application/json")
        let outside = s.get("/api/meetings/..%2F..%2Fetc")
        #expect(outside.status == 404 && outside.error == "not found: ..%2F..%2Fetc")
        #expect(s.get("/api/meetings/2026-01-01T00-00-00").error == "not found: 2026-01-01T00-00-00")
    }

    // MARK: - the page

    @Test func test_meeting_has_clean_transcript_speakers_and_named_notes() throws {
        let f = try Fixture()
        try pageMeeting(f.out)
        let m = try f.page()
        let transcript = try #require(m["transcript"]?.arrayValue)
        #expect(transcript[0] == .object([("speaker", .string("Timo")), ("label", .null), ("start", .double(0.0)),
                                          ("end", .double(1.0)), ("text", .string("Hi Rico welcome.")), ("glossed", .array([])),
                                          ("edited", .bool(false)), ("heard", .null), ("unsure", .array([])), ("fixed", .null),
                                          ("track", .string("mic"))]))
        let speakers = try #require(m["speakers"]?.arrayValue)
        #expect(speakers.map { $0["label"] } == [.null, .string("SPEAKER_00"), .string("SPEAKER_01")])
        let rico = speakers[1]
        #expect(rico["name"] == .null && rico["display"] == .string("Speaker 1"))
        #expect(rico["guesses"] == .array([.object([("name", .string("Rico")), ("evidence", .string("Hi Rico"))])]))
        #expect(speakers[2]["guesses"] == .array([]))  // said "Thanks Rico" itself: not a hint
        #expect(rico["clips"] == .array([.object([("start", .double(1.0)), ("end", .double(9.0))])]))  // capped at 8 s
        #expect(m["notes"]?["summary"] == .string("Speaker 1 ran the debrief."))
        #expect(transcript.map { $0["speaker"] } == [.string("Timo"), .string("Speaker 1"), .string("Speaker 2")])
        #expect(transcript[1]["label"] == .string("SPEAKER_00"))
        #expect(m["notes_stale"] == .bool(false))
    }

    /// The page's keys in Python's order, and what a plain finished meeting answers for the parts no other test looks at.
    @Test func thePageHasPythonsKeysInPythonsOrder() throws {
        let f = try Fixture()
        try pageMeeting(f.out)
        guard case .object(let fields) = try f.page() else { Issue.record("no object"); return }
        #expect(fields.map(\.0) == ["id", "title", "title_from", "calendar", "event_question", "start", "duration", "status",
                                    "finishing", "untranscribed", "notes", "notes_stale", "notes_stale_reason",
                                    "notes_from_my_notes", "my_notes_revision", "speakers", "transcript", "has_audio",
                                    "audio_deleted", "reviewed", "local_only", "imported", "transcribed_by", "failure",
                                    "neighbours", "cut_suggestion", "silence", "shared", "shared_suggestion", "removed",
                                    "recorded", "gaps", "audio_problems", "projects", "project_suggestions", "all_projects"])
        let page = JSONValue.object(fields)
        #expect(page["neighbours"] == .object([("previous", .null), ("next", .null)]))
        #expect(page["recorded"] == .null && page["silence"] == .array([]))
        let me = try #require(page["speakers"]?.arrayValue?.first)
        #expect(me == .object([("label", .null), ("name", .string("Timo")), ("display", .string("Timo")), ("is_user", .bool(true)),
                               ("shared", .null), ("room", .string("")), ("talk_seconds", .double(1.0)), ("clips", .array([])),
                               ("org", .null), ("org_link", .null)]))
        #expect(page["shared"] == .object([("meeting", .bool(false)), ("rooms", .object([])), ("mic", .null),
                                           ("from_series", .bool(false)), ("line", .null),
                                           ("series", .object([("can", .bool(false)), ("remembered", .bool(false))]))]))
    }

    @Test func test_meeting_shows_its_calendar_event_and_offers_invitees() throws {
        let f = try Fixture()
        let paths = try pageMeeting(f.out)
        let t = try PyDateTime.parse("2026-10-27T16:00:00+01:00")
        try CalendarEvents.save(paths, CalendarEvent(title: "Hiring debrief: Data Parks", start: t, end: t, attendees: [
            Attendee(name: "Timo Strauss", isSelf: true),
            Attendee(name: "Rico Lanza", organizer: true),
            Attendee(name: "Anna Berg"),
            Attendee(name: "Bob Weiss", response: "declined"),
            Attendee(name: "Wien 3", isRoom: true),
        ]))
        try f.name("SPEAKER_00", "Rico Lanza")
        let m = try f.page()
        #expect(m["calendar"]?["title"] == .string("Hiring debrief: Data Parks"))
        #expect(m["calendar"]?["attendees"]?.arrayValue?.map { $0["name"] } == [.string("Rico Lanza"), .string("Anna Berg"), .string("Bob Weiss")])
        #expect(m["calendar"]?["invited"] == .strings(["Anna Berg"]))  // Rico has a speaker already, Bob declined
        #expect(try f.list()[0]["title"] == .string("Hiring debrief: Data Parks"))
    }

    /// The page half: merged lanes, a merged label named, the merge undone (the merge route is the speakers' task).
    @Test func test_merged_speakers_share_one_lane() throws {
        let f = try Fixture()
        let paths = try pageMeeting(f.out)
        try Speakers.mergeSpeakers(paths, "SPEAKER_01", into: "SPEAKER_00", stores: f.stores)
        var m = try f.page()
        #expect(m["speakers"]?.arrayValue?.map { $0["label"] } == [.null, .string("SPEAKER_00")])
        let lane = try #require(m["speakers"]?.arrayValue?[1])
        #expect(lane["talk_seconds"] == .double(13.0))
        #expect(lane["merged"] == .array([.object([("label", .string("SPEAKER_01")), ("display", .string("Speaker 2"))])]))
        #expect(m["transcript"]?.arrayValue?.dropFirst().map { [$0["speaker"]!, $0["label"]!] }
                == [[.string("Speaker 1"), .string("SPEAKER_00")], [.string("Speaker 1"), .string("SPEAKER_00")]])
        #expect(m["notes"]?["next_steps"]?.arrayValue?.first?["owner"] == .string("Speaker 1"))

        try f.name("SPEAKER_00", "Konrad")  // naming the merged label names the person it joined
        m = try f.page()
        #expect(m["transcript"]?.arrayValue?.map { $0["speaker"] } == [.string("Timo"), .string("Konrad"), .string("Konrad")])

        try Speakers.mergeSpeakers(paths, "SPEAKER_01", into: nil, stores: f.stores)
        m = try f.page()
        #expect(m["transcript"]?.arrayValue?.map { $0["speaker"] } == [.string("Timo"), .string("Konrad"), .string("Speaker 2")])
    }

    /// The page and search halves (removing is the speakers' task; transcript.md theirs too).
    @Test func test_a_voice_removed_as_noise_disappears_with_its_lines_until_restored() throws {
        let f = try Fixture()
        let paths = try pageMeeting(f.out)
        try Speakers.setIgnored(paths, "SPEAKER_01")
        var m = try f.page()
        #expect(m["speakers"]?.arrayValue?.map { $0["label"] } == [.null, .string("SPEAKER_00")])
        #expect(m["transcript"]?.arrayValue?.map { $0["speaker"] } == [.string("Timo"), .string("Speaker 1")])
        #expect(m["removed"] == .array([.object([("label", .string("SPEAKER_01")), ("display", .string("Speaker 2"))])]))
        #expect(try read(paths.transcriptJson).arrayValue?.count == 3)  // kept as heard
        #expect(try SearchAPI.search(f.app, "salary", userName: "Timo") == [])

        try Speakers.setIgnored(paths, "SPEAKER_01", false)
        m = try f.page()
        #expect(m["speakers"]?.arrayValue?.count == 3 && m["removed"] == .array([]))
    }

    /// The first minute of a call: audio growing, no live.json and no speaker turns yet.
    @Test func test_a_meeting_just_started_opens_before_its_first_live_block() throws {
        let f = try Fixture()
        let paths = f.paths()
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        for track in [paths.systemWav, paths.micRawWav] {
            try Data(count: 100).write(to: URL(fileURLWithPath: track.path + ".part"))
        }
        let m = try f.page()
        #expect(m["status"] == .string("recording"))
        // No meta.json yet: the start is the folder's name, in this Mac's zone.
        #expect(m["start"] == .string(try MeetingsAPI.localStart("2026-10-27T16-03-07")))
        #expect(try f.list()[0]["status"] == .string("recording"))
    }

    @Test func aStartFromTheFolderNameIsLocalTime() throws {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        #expect(try MeetingsAPI.localStart("2026-10-27T16-03-07", timeZone: berlin) == "2026-10-27T16:03:07+01:00")
        #expect(try MeetingsAPI.localStart("2026-07-01T09-00-00", timeZone: berlin) == "2026-07-01T09:00:00+02:00")
        #expect(try MeetingsAPI.localStart("٢٠٢٦-07-01T09-00-00", timeZone: berlin) == "2026-07-01T09:00:00+02:00")
        #expect(throws: PageError.self) { try MeetingsAPI.localStart("2026-02-30T09-00-00", timeZone: berlin) }
        #expect(throws: PageError.self) { try MeetingsAPI.localStart("2026-13-01T09-00-00", timeZone: berlin) }
    }

    @Test func aLabelShowsAsItsNumberPlusOne() {
        #expect(MeetingsAPI.labelDisplay("SPEAKER_01") == "Speaker 2")
        #expect(MeetingsAPI.labelDisplay("SPEAKER_09") == "Speaker 10")
        #expect(MeetingsAPI.labelDisplay("SPEAKER_99999999999999999999") == "Speaker 100000000000000000000")
        #expect(MeetingsAPI.labelDisplay("7") == "Speaker 8")
        #expect(MeetingsAPI.labelDisplay("SPEAKER_") == "SPEAKER_")
        #expect(MeetingsAPI.labelDisplay("SPEAKER_x1") == "SPEAKER_x1")
        #expect(MeetingsAPI.labelDisplay("Room") == "Room")
    }

    @Test func test_a_meeting_says_how_it_was_recorded_and_where_it_paused() throws {
        let f = try Fixture()
        let paths = try pageMeeting(f.out)
        var meta = PyDict<JSONValue>(try read(paths.meta))!
        meta["end_time"] = .string("2026-10-27T16:03:27+01:00")
        meta["trigger"] = .string("teams")
        meta["stop_reason"] = .string("call_ended")
        meta["gaps"] = .array([.object([("start", .double(12.0)), ("end", .double(12.5)), ("why", .string("restart"))])])
        try write(meta.json, to: paths.meta)
        let m = try f.page()
        #expect(m["recorded"] == .string("Teams call detected 16:03 · Teams call ended 16:03 · Palaver restarted — continued"))
        #expect(m["gaps"] == .array([.object([("start", .double(12.0)), ("end", .double(12.5)),
                                              ("text", .string("Recording paused 16:03:19–16:03:19 (Palaver restarted)"))])]))
    }

    @Test func test_a_part_cut_by_a_restart_says_it_is_continued() throws {
        let f = try Fixture()
        let paths = try pageMeeting(f.out)
        var meta = PyDict<JSONValue>(try read(paths.meta))!
        meta["end_time"] = .string("2026-10-27T16:03:27+01:00")
        meta["trigger"] = .string("teams")
        meta["stop_reason"] = .string("restart")
        try write(meta.json, to: paths.meta)
        #expect(try f.page()["recorded"] == .string("Teams call detected 16:03 · Palaver restarted 16:03"))
        try write(.object([("parts", .strings(["2026-10-27T16-03-40"]))]), to: paths.parts)
        #expect(try f.page()["recorded"]?.stringValue?.hasSuffix("Palaver restarted 16:03 — continued") == true)
        #expect(try f.page()["gaps"] == .array([]))
    }

    /// Issue #50: "Audio problem at 16:04 (system audio played at the wrong speed)".
    @Test func test_a_meeting_says_when_its_audio_went_wrong() throws {
        let f = try Fixture()
        let paths = try pageMeeting(f.out)
        let plain = try read(paths.meta)
        var meta = PyDict<JSONValue>(plain)!
        meta["audio_problems"] = .array([.object([("kind", .string("speed")), ("track", .string("system")),
                                                  ("start", .double(60.0)), ("end", .double(75.0))])])
        try write(meta.json, to: paths.meta)
        #expect(try f.page()["audio_problems"] == .array([.object([
            ("start", .double(60.0)), ("end", .double(75.0)),
            ("text", .string("Audio problem at 16:04 (system audio played at the wrong speed)"))])]))
        try write(plain, to: paths.meta)
        #expect(try f.page()["audio_problems"] == .array([]))
    }

    @Test func test_meeting_says_which_service_transcribed_it() throws {
        let f = try Fixture()
        let paths = try pageMeeting(f.out)
        #expect(try f.page()["transcribed_by"] == .null)
        try TranscriptionMarker.write(paths, track: "system", info: [("engine", .string("local")),
                                                                     ("fallback_from", .string("soniox")),
                                                                     ("error", .string("HTTP 503"))])
        var t = try #require(f.page()["transcribed_by"])
        #expect(t["engine"] == .string("local") && t["fallback_label"] == .string("Soniox") && t["error"] == .string("HTTP 503"))
        try TranscriptionMarker.write(paths, track: "system", info: [("engine", .string("assemblyai")),
                                                                     ("sent_seconds", .double(60.0)), ("usd", .double(0.0047))])
        t = try #require(f.page()["transcribed_by"])
        #expect(t["label"] == .string("AssemblyAI") && t["sent_seconds"] == .double(60.0))
    }

    @Test func test_my_notes_changed_after_the_notes_were_written() throws {
        let f = try Fixture()
        let paths = try pageMeeting(f.out)
        var m = try f.page()
        #expect(m["notes_stale"] == .bool(false) && m["notes_stale_reason"] == .null)
        #expect(try f.list()[0]["notes_stale"] == .bool(false))
        _ = try MyNotes.save(paths.folder, paragraphs: .array([.object([("text", .string("They said yes")), ("at", .int(4))])]))
        m = try f.page()
        #expect(m["notes_stale"] == .bool(true) && m["notes_stale_reason"] == .string("my_notes"))
        #expect(m["my_notes_revision"] == .string(MyNotes.revision(paths.folder)) && m["my_notes_revision"] != .string(""))
        #expect(try f.list()[0]["notes_stale"] == .bool(true))  // the list notices the change too
    }

    /// Renamed through the domain (renaming is the title route's), then the list, the page and the search.
    @Test func test_a_meeting_renamed_is_called_so_in_the_list_the_page_and_the_search() throws {
        let f = try Fixture()
        let paths = try pageMeeting(f.out)
        #expect(try f.list()[0]["title"] == .string("Hiring debrief"))  // cached now
        try Titles.save(paths, "Offer for Rico")
        try touch(paths.title, 2_000_000_000)
        let entry = try f.list()[0]
        #expect(entry["title"] == .string("Offer for Rico") && entry["title_from"] == .string("you"))
        let m = try f.page()
        #expect(m["title"] == .string("Offer for Rico") && m["title_from"] == .string("you"))
        let hits = try SearchAPI.search(f.app, "offer in:title", userName: "Timo")
        #expect(hits.count == 1 && hits.first?["id"] == .string(MEETING) && hits.first?["in_title"] == .bool(true))
    }

    @Test func test_a_renamed_meeting_keeps_its_calendar_event_beside_the_title() throws {
        let f = try Fixture()
        let paths = try pageMeeting(f.out)
        let start = try PyDateTime.parse("2026-10-27T16:03:07+01:00")
        try CalendarEvents.save(paths, CalendarEvent(title: "Weekly sync", start: start, end: try! start.adding(seconds: 1800)))
        var m = try f.page()
        #expect(m["title"] == .string("Weekly sync") && m["title_from"] == .string("calendar"))
        try Titles.save(paths, "Hiring: Rico")
        m = try f.page()
        #expect(m["title"] == .string("Hiring: Rico") && m["title_from"] == .string("you"))
        #expect(m["calendar"]?["title"] == .string("Weekly sync"))  // the page's "Calendar: Weekly sync"
    }

    // MARK: - the last failure (#59)

    @Test func theLastFailedRunOfTheLogIsOfferedForAReport() throws {
        let dir = tempFolder("failure")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = RecordingPaths(dir)
        func log(_ lines: [String]) throws -> JSONValue? {
            try Data(lines.joined(separator: "\n").utf8).write(to: paths.sessionLog)
            return MeetingsAPI.lastFailure(paths)
        }
        #expect(MeetingsAPI.lastFailure(paths) == nil)  // no log
        let start = #"{"ts": "t1", "event": "process_start"}"#
        let tb = #"{"ts": "t2", "level": "ERROR", "message": "command failed", "traceback": "Traceback\n  File x\nRuntimeError: boom  \n\n"}"#
        #expect(try log([start, tb]) == .object([("step", .string("process")), ("error", .string("RuntimeError: boom")),
                                                ("at", .string("t2"))]))
        #expect(try log([start, tb, start]) == nil)  // done again since
        #expect(try log([#"{"event": "live_start"}"#, tb]) == nil)  // a live run's error is not shown
        #expect(try log([#"{"ts": "t3", "event": "process_done", "rc": 3}"#]) == .object([
            ("step", .string("process")), ("error", .string("exit code 3")), ("at", .string("t3"))]))
        #expect(try log([#"{"event": "process_done", "rc": 0}"#, #"{"event": "process_done", "rc": 0.0}"#,
                         #"{"event": "process_done", "rc": false}"#, #"{"event": "process_done"}"#]) == nil)
        let long = String(repeating: "é", count: 400)
        let notes = try #require(try log([#"{"event": "notes_start"}"#, "not json \"event\"", "[\"event\"]",
                                          #"{"ts": 5, "event": "notes_failed", "error": "\#(long)"}"#]))
        #expect(notes == .object([("step", .string("notes")), ("error", .string(String(repeating: "é", count: 300))), ("at", .int(5))]))
        // Transcribing first: its failure wins over the notes'.
        #expect(try log([#"{"event": "notes_failed", "error": null}"#, #"{"event": "process_start"}"#,
                         #"{"level": "ERROR", "message": "command failed"}"#])?["error"] == .string("it stopped"))
        #expect(try log([#"{"event": "notes_failed", "error": null}"#])?["error"] == .string(""))
    }
}
