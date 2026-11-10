// Speakers, people, voices and organizations (api.py `name_speaker`, `remove_speaker`, `merge_speaker`,
// `decide_imported_voices`, `directory`, `rename_organization`, `set_person_org`, `rename_person`, `name_voices`,
// `known_names`; their routes). Ports their tests of test_webapp.py, test_attribution.py, test_organizations.py,
// test_exchange.py and test_inference.py under their names; where Python's test also asks a route of a later task
// (`/api/questions`), that half is that task's (see the ledger).
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"

private func write(_ value: JSONValue, to url: URL) throws { try Data(PythonJSON.dumps(value).utf8).write(to: url) }
private func dumps(_ value: JSONValue?) -> String { value.map { PythonJSON.dumps($0, ensureAscii: false) } ?? "nil" }

private extension JSONValue {
    subscript(i: Int) -> JSONValue? { arrayValue.flatMap { $0.indices.contains(i) ? $0[i] : nil } }
    var list: [JSONValue] { arrayValue ?? [] }
}

/// A recordings folder and the stores in a temporary folder, and the app over them for "Timo" (no HTTP).
private final class Fixture {
    let dir: URL
    let out: URL
    let stores: StorePaths
    let app: ServerApp

    init(meeting: Bool = true) throws {
        dir = tempFolder("people")
        out = dir.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                            home: dir.appendingPathComponent("home", isDirectory: true))
        app = ServerApp(outputDir: out, userName: "Timo", stores: stores)
        if meeting { try pageMeeting(out) }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var paths: RecordingPaths { paths(MEETING) }
    func paths(_ id: String) -> RecordingPaths { RecordingPaths(out.appendingPathComponent(id, isDirectory: true)) }
    func page(_ id: String = MEETING) throws -> JSONValue { try MeetingsAPI.getMeeting(app: app, id: id) }
    @discardableResult
    func name(_ label: String, _ name: String, _ id: String = MEETING) throws -> String? {
        try PeopleAPI.nameSpeaker(app, id: id, label: label, name: name)
    }
    func undo(_ token: String) throws -> [String] { try UndoRoute.undoChange(app, token: token) }
    var bank: VoiceBank { VoiceBank(directory: stores.voices) }
}

/// `_post`: the status and the JSON answer.
private func post(_ s: TestServer, _ path: String, _ body: JSONValue = .object([])) -> (Int, JSONValue) {
    let r = s.post(path, body)
    return (r.status, r.json ?? .null)
}

private func page(_ s: TestServer, _ id: String = MEETING) -> JSONValue { s.get("/api/meetings/\(id)").json ?? .null }

private func speakersOf(_ page: JSONValue) -> [String] { page["transcript"]?.list.compactMap { $0["speaker"]?.stringValue } ?? [] }

/// A request body: text, true/false, numbers, nil (null) or JSON as given.
private func body(_ fields: [(String, Any?)]) -> JSONValue {
    .object(fields.map { key, value in
        switch value {
        case nil: return (key, .null)
        case let v as JSONValue: return (key, v)
        case let v as String: return (key, .string(v))
        case let v as Bool: return (key, .bool(v))
        case let v as Int: return (key, .int(v))
        default: preconditionFailure("no JSON for \(String(describing: value))")
        }
    })
}

/// test_webapp.py `_next_meeting`: the same meeting, started 23 s after the first.
@discardableResult
private func nextMeeting(_ root: URL, _ name: String = "2026-10-27T16-03-30") throws -> RecordingPaths {
    let paths = try pageMeeting(root, name)
    guard case .object(var meta) = PythonJSON.read(paths.meta)! else { throw BadRequest("meta") }
    meta = meta.map { $0.0 == "start_time" ? ($0.0, .string("2026-10-27T16:03:30+01:00")) : $0 }
    try write(.object(meta), to: paths.meta)
    return paths
}

/// `v / np.linalg.norm(v)`.
private func unit(_ v: Double...) -> [Double] {
    let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return v.map { $0 / norm }
}
private func vector(_ v: [Double]) -> JSONValue { .array(v.map { .double($0) }) }

/// test_attribution.py `_voice_meeting` (and test_inference.py's `_meeting` with `start`, `duration` and `invited`):
/// one turn and one line per voice, each talking its seconds, and the voices as the diarizer leaves them.
@discardableResult
private func voiceMeeting(_ root: URL, _ name: String, _ voices: [(String, [Double], Double)],
                          start: String = "2026-10-27T10:00:00+01:00", duration: Int = 600, invited: [String]? = nil) throws -> RecordingPaths {
    let paths = RecordingPaths(root.appendingPathComponent(name, isDirectory: true))
    try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
    try write(.object([("start_time", .string(start)), ("duration_seconds", .int(duration))]), to: paths.meta)
    var turns: [JSONValue] = [], transcript: [JSONValue] = [], t = 0.0
    for (label, _, talk) in voices {
        turns.append(.object([("speaker", .string(label)), ("start", .double(t)), ("end", .double(t + talk))]))
        transcript.append(.object([("speaker", .string(label)), ("start", .double(t)), ("end", .double(t + talk)),
                                   ("text", .string("I am \(label)."))]))
        t += talk
    }
    try write(.array(turns), to: paths.systemTurns)
    try write(.array(transcript), to: paths.transcriptJson)
    try write(.object(voices.map { ($0.0, vector($0.1)) }), to: paths.speakerEmbeddings)
    if let invited {
        let t0 = try PyDateTime.parse(start)
        let attendees = [Attendee(name: "Timo Strauss", email: "timo@kloud.io", isSelf: true)]
            + invited.map { Attendee(name: $0, email: "\($0.split(separator: " ")[0].lowercased())@x.com") }  // ASCII test names
        try CalendarEvents.save(paths, CalendarEvent(title: name, start: t0, end: try! t0.adding(seconds: Double(duration)), attendees: attendees))
    }
    return paths
}

/// What an import leaves (exchange.py `_write_meeting`, test_exchange.py's exported meeting): the record with the
/// sender's names (Tom by hand, Carla by the exporter), their hints, the voices waiting for the user's answer, and no
/// speaker_embeddings.json.
@discardableResult
private func importedMeeting(_ root: URL, _ name: String = "2026-10-28T09-00-00") throws -> RecordingPaths {
    let paths = try voiceMeeting(root, name, [("SPEAKER_00", unit(1, 0, 0, 0), 60), ("SPEAKER_01", unit(0, 1, 0, 0), 60)],
                                 start: "2026-10-28T09:00:00+01:00")
    try FileManager.default.removeItem(at: paths.speakerEmbeddings)
    try write(.object([
        ("from", .string("Anna Berg")), ("format", .int(Exchange.FORMAT)), ("imported_at", .string("2026-10-28T10:00:00+01:00")),
        ("projects", .array([])),
        ("names", .object([("SPEAKER_00", .object([("name", .string("Tom")), ("how", .string("hand"))])),
                           ("SPEAKER_01", .object([("name", .string("Carla")), ("how", .string("exporter"))]))])),
        ("voices_pending", .strings(["SPEAKER_00", "SPEAKER_01"])), ("beside", .null), ("title", .string("Budget review")),
    ]), to: paths.imported)
    try write(.object(ExchangeHints.hints(paths).map { ($0.key, $0.value) }), to: paths.speakersInferred)
    try write(.object([("SPEAKER_00", vector(unit(1, 0, 0, 0))), ("SPEAKER_01", vector(unit(0, 1, 0, 0)))]), to: paths.importedVoices)
    return paths
}

@Suite struct PeopleRoutesTests {
    // MARK: - test_webapp.py

    @Test func test_naming_a_speaker_updates_transcript_and_notes() throws {
        let f = try Fixture()
        try f.name("SPEAKER_00", "Rico")
        try f.name("SPEAKER_01", "Anna")
        let m = try f.page()
        #expect(speakersOf(m) == ["Timo", "Rico", "Anna"])
        #expect(m["transcript"]?[1]?["label"] == .string("SPEAKER_00"))
        #expect(m["notes"]?["summary"] == .string("Rico ran the debrief."))
        #expect(m["notes"]?["next_steps"]?[0]?["owner"] == .string("Anna"))
        #expect(m["speakers"]?[1]?["named_by"] == .string("you"))
        #expect(m["notes_stale"] == .bool(false))  // names don't make notes stale
        #expect(try PeopleAPI.knownNames(f.app) == ["Anna", "Rico", "Timo"])

        try f.name("SPEAKER_01", "")
        #expect(dumps(PythonJSON.read(f.paths.speakers)) == #"{"SPEAKER_00": "Rico"}"#)
        #expect(throws: NotFound.self) { try f.name("SPEAKER_09", "Bob") }
    }

    @Test func test_http_merges_speakers() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        var (status, answer) = post(s, "/api/meetings/\(MEETING)/merge", body([("label", "SPEAKER_01"), ("into", "SPEAKER_00")]))
        #expect(status == 200 && answer["speakers"]?.list.count == 2)
        (status, answer) = post(s, "/api/meetings/\(MEETING)/merge", body([("label", "SPEAKER_01"), ("into", nil)]))
        #expect(status == 200 && answer["speakers"]?.list.count == 3)
    }

    @Test func test_http_merge_undo_puts_names_and_earlier_merges_back() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        // A (SPEAKER_00) is "Henrik" and has C (SPEAKER_02) merged in; then A goes into the unnamed B (SPEAKER_01).
        _ = post(s, "/api/meetings/\(MEETING)/speakers", body([("label", "SPEAKER_00"), ("name", "Henrik")]))
        _ = post(s, "/api/meetings/\(MEETING)/merge", body([("label", "SPEAKER_02"), ("into", "SPEAKER_00")]))
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/merge", body([("label", "SPEAKER_00"), ("into", "SPEAKER_01")]))
        #expect(status == 200 && answer["undo"]?.stringValue?.isEmpty == false)
        #expect(answer["speakers"]?.list.map { $0["label"] ?? .null } == [.null, .string("SPEAKER_01")])
        #expect(answer["speakers"]?[1]?["name"] == .string("Henrik"))  // the merge moved the name

        let undone = post(s, "/api/undo", body([("token", answer["undo"] ?? .null)]))
        #expect(undone.0 == 200 && undone.1 == .object([("restored", .strings([MEETING]))]))
        let m = page(s)
        let a = m["speakers"]?[1], b = m["speakers"]?[2]
        #expect(a?["label"] == .string("SPEAKER_00") && a?["name"] == .string("Henrik"))
        #expect(b?["label"] == .string("SPEAKER_01") && b?["name"] == .null)
        #expect(dumps(a?["merged"]) == #"[{"label": "SPEAKER_02", "display": "Speaker 3"}]"#)
        #expect(m["transcript"]?.list.dropFirst().map { [$0["speaker"] ?? .null, $0["label"] ?? .null] }
                == [[.string("Henrik"), .string("SPEAKER_00")], [.string("Speaker 2"), .string("SPEAKER_01")]])
    }

    /// The `/notes` half (the language model writing the notes) is Task 43's.
    @Test func test_http_names_speakers_and_writes_notes() throws {
        let written = FakeHelpers { _, _, _ in 0 }
        let s = try TestServer(helpers: written, meetings: { try pageMeeting($0) })
        defer { s.stop() }
        var (status, answer) = post(s, "/api/meetings/\(MEETING)/speakers", body([("label", "SPEAKER_00"), ("name", "Rico")]))
        #expect(status == 200 && answer["transcript"]?[1]?["speaker"] == .string("Rico"))
        (status, _) = post(s, "/api/meetings/\(MEETING)/notes")
        #expect(status == 200 && written.keys == [MEETING])
    }

    @Test func test_http_people_directory_rename_and_name_voices() throws {
        let s = try TestServer(userName: "Timo", meetings: { try pageMeeting($0) })
        defer { s.stop() }
        _ = post(s, "/api/meetings/\(MEETING)/speakers", body([("label", "SPEAKER_00"), ("name", "Rico")]))
        let r = s.get("/api/people")
        let people = r.json?["people"]?.list ?? []
        #expect(r.status == 200 && people.count == 1 && people.first?["name"] == .string("Rico"))
        let first = people.first?["meetings"]?[0]
        #expect(first?["title"] == .string("Hiring debrief"))
        #expect(first?["clip"] == .object([("start", .double(1.0)), ("end", .double(9.0))]))
        #expect(first?["projects"] == .array([]))  // shown next to the day, each a link to its filter

        var (status, answer) = post(s, "/api/people/rename", body([("old", "Rico"), ("new", "Rico Lanza")]))
        #expect(status == 200 && answer["people"]?[0]?["name"] == .string("Rico Lanza"))
        #expect(page(s)["transcript"]?[1]?["speaker"] == .string("Rico Lanza"))

        (status, _) = post(s, "/api/voices/name", body([("voices", JSONValue.array([.strings([MEETING, "SPEAKER_01"])])), ("name", "Anna")]))
        #expect(status == 200)
        #expect(post(s, "/api/voices/name", body([("voices", JSONValue.array([.strings([MEETING, "SPEAKER_09"])])), ("name", "X")])).0 == 404)
        #expect(post(s, "/api/people/rename", body([("old", "Anna"), ("new", " ")])).0 == 400)
        #expect(s.get("/api/names").json == .strings(["Anna", "Rico Lanza", "Timo"]))
    }

    @Test func test_http_person_rename_can_be_undone() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        _ = post(s, "/api/meetings/\(MEETING)/speakers", body([("label", "SPEAKER_00"), ("name", "Ana")]))
        let (status, answer) = post(s, "/api/people/rename", body([("old", "Ana"), ("new", "Anna")]))
        #expect(status == 200 && answer["undo"]?.stringValue?.isEmpty == false)
        #expect(page(s)["transcript"]?[1]?["speaker"] == .string("Anna"))
        #expect(post(s, "/api/undo", body([("token", answer["undo"] ?? .null)])).0 == 200)
        #expect(page(s)["transcript"]?[1]?["speaker"] == .string("Ana"))
    }

    @Test func test_http_removes_a_voice() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/remove", body([("label", "SPEAKER_01")]))
        #expect(status == 200 && answer["removed"]?[0]?["label"] == .string("SPEAKER_01"))
        #expect(post(s, "/api/meetings/\(MEETING)/remove", body([("label", "SPEAKER_09")])).0 == 404)
    }

    @Test func test_http_splitting_off_a_merged_speaker_has_no_undo_token() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        _ = post(s, "/api/meetings/\(MEETING)/merge", body([("label", "SPEAKER_01"), ("into", "SPEAKER_00")]))
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/merge", body([("label", "SPEAKER_01"), ("into", nil)]))
        #expect(status == 200 && answer.isObject && answer["undo"] == nil)
    }

    @Test func test_http_undo_rename_after_one_meeting_was_trashed() throws {
        let other = "2026-10-27T16-03-30"
        let s = try TestServer(meetings: { out in
            try pageMeeting(out)
            try nextMeeting(out, other)
        })
        defer { s.stop() }
        for id in [MEETING, other] {
            _ = post(s, "/api/meetings/\(id)/speakers", body([("label", "SPEAKER_00"), ("name", "Ana")]))
        }
        let (_, answer) = post(s, "/api/people/rename", body([("old", "Ana"), ("new", "Anna")]))
        _ = post(s, "/api/meetings/\(other)/trash")
        let (status, restored) = post(s, "/api/undo", body([("token", answer["undo"] ?? .null)]))
        #expect(status == 200 && restored["restored"] == .strings([MEETING]))
        #expect(page(s)["transcript"]?[1]?["speaker"] == .string("Ana"))
        #expect(s.get("/api/names").json?.list.contains(.string("Ana")) == true)
        #expect(post(s, "/api/undo", body([("token", answer["undo"] ?? .null)])).0 == 404)  // used up
    }

    // MARK: - the routes' requests

    @Test func speakerRoutesTakeTheirBodiesAsServerPyDoes() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let base = "/api/meetings/\(MEETING)"
        #expect(post(s, "\(base)/speakers", body([("name", "Rico")])).1 == .object([("error", .string("bad request: 'label'"))]))
        #expect(post(s, "/api/meetings/nope/speakers", body([("label", "SPEAKER_00")])).0 == 404)
        #expect(post(s, "\(base)/merge", body([("label", "SPEAKER_00"), ("into", "SPEAKER_09")])).1
                == .object([("error", .string("not found: SPEAKER_09"))]))
        #expect(post(s, "\(base)/merge", body([("label", "SPEAKER_00"), ("into", "SPEAKER_00")])).1
                == .object([("error", .string("bad request: a speaker cannot be merged into itself"))]))
        #expect(post(s, "\(base)/unknown", body([("label", "SPEAKER_00"), ("on", "yes")])).1
                == .object([("error", .string("bad request: 'on' is true or false"))]))
        #expect(post(s, "\(base)/imported-voices", body([("add", 1)])).1
                == .object([("error", .string("bad request: 'add' is true or false"))]))
        #expect(post(s, "\(base)/shared-series", body([])).1
                == .object([("error", .string("bad request: 'remember' is true or false"))]))
        #expect(post(s, "\(base)/shared-series", body([("remember", true)])).1
                == .object([("error", .string("Only a meeting of a recurring calendar event can be remembered for its series."))]))
        #expect(post(s, "/api/people/org", body([("name", " "), ("org", "Contoso")])).1
                == .object([("error", .string("bad request: a person is needed"))]))
        #expect(post(s, "/api/voices/name", body([("voices", JSONValue.array([])), ("name", "Anna")])).1
                == .object([("error", .string("bad request: a name and at least one voice are needed"))]))
        #expect(post(s, "/api/voices/name", body([("voices", JSONValue.array([.strings([MEETING])])), ("name", "Anna")])).1
                == .object([("error", .string("bad request: not enough values to unpack (expected 2, got 1)"))]))
        #expect(post(s, "/api/voices/name", body([("voices", JSONValue.array([.strings([MEETING, "SPEAKER_00", "x"])])), ("name", "Anna")])).1
                == .object([("error", .string("bad request: too many values to unpack (expected 2)"))]))
        let r = s.post("/api/voices/name", body([("voices", JSONValue.array([.int(7)])), ("name", "Anna")]))
        #expect(r.status == 500 && r.error == "cannot unpack non-iterable int object")
    }

    @Test func dontKnowIsUndoneWithItsTokenAndRefusedBeforeTheTranscript() throws {
        let s = try TestServer(meetings: { out in
            try pageMeeting(out)
            let waiting = out.appendingPathComponent("2026-10-27T17-00-00")
            try FileManager.default.createDirectory(at: waiting, withIntermediateDirectories: true)
            try Data().write(to: waiting.appendingPathComponent("mic_raw.wav"))
        })
        defer { s.stop() }
        let paths = RecordingPaths(s.app.outputDir.appendingPathComponent(MEETING, isDirectory: true))
        let (status, answer) = post(s, "/api/meetings/\(MEETING)/unknown", body([("label", "SPEAKER_01"), ("on", true)]))
        #expect(status == 200 && Speakers.loadUnknown(paths) == ["SPEAKER_01"])
        #expect(post(s, "/api/undo", body([("token", answer["undo"] ?? .null)])) == (200, .object([("restored", .strings([MEETING]))])))
        #expect(Speakers.loadUnknown(paths).isEmpty)
        #expect(post(s, "/api/meetings/2026-10-27T17-00-00/unknown", body([("label", "SPEAKER_00"), ("on", true)])).1
                == .object([("error", .string(PeopleAPI.NOT_TRANSCRIBED))]))
    }

    @Test func organizationsRoutesAnswerTheDirectory() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        _ = post(s, "/api/meetings/\(MEETING)/speakers", body([("label", "SPEAKER_00"), ("name", "Rico")]))
        var (status, answer) = post(s, "/api/organizations", body([("key", "muellerbau"), ("name", "Müllerbau")]))
        #expect(status == 200 && answer["people"]?[0]?["name"] == .string("Rico") && answer["undo"] == nil)
        (status, answer) = post(s, "/api/people/org", body([("name", "Rico"), ("org", "Northwind")]))
        #expect(status == 200 && answer["people"]?[0]?["org"] == .string("Northwind") && answer["people"]?[0]?["org_given"] == .bool(true))
        let file = PythonJSON.read(s.app.stores.organizations)
        #expect(dumps(file) == #"{"names": {"muellerbau": "Müllerbau"}, "people": {"rico": "Northwind"}}"#)
    }

    // MARK: - test_attribution.py

    @Test func test_http_questions_and_an_undoable_not_name() throws {
        let s = try TestServer(userName: "Timo", meetings: { try pageMeeting($0) })
        defer { s.stop() }
        var r = s.get("/api/questions")
        #expect(r.status == 200 && r.json == .array([]))
        let paths = RecordingPaths(s.app.outputDir.appendingPathComponent(MEETING, isDirectory: true))
        try write(.object([("SPEAKER_00", .object([("name", .string("Rico")), ("similarity", .double(0.7))]))]), to: paths.speakersAuto)
        r = s.get("/api/questions")
        #expect(r.json?.arrayValue?.compactMap { $0["kind"]?.stringValue } == ["speaker"])
        var (status, m) = post(s, "/api/meetings/\(MEETING)/speakers", body([("label", "SPEAKER_00"), ("name", "")]))
        #expect(status == 200 && m["undo"]?.stringValue?.isEmpty == false && m["speakers"]?[1]?["name"] == .null)
        #expect(post(s, "/api/undo", body([("token", m["undo"] ?? .null)])).0 == 200)
        #expect(try MeetingsAPI.getMeeting(app: s.app, id: MEETING)["speakers"]?[1]?["name"] == .string("Rico"))
        (status, m) = post(s, "/api/meetings/\(MEETING)/speakers", body([("label", "SPEAKER_01"), ("name", "Anna")]))
        #expect(status == 200 && m["undo"] == nil)  // a name typed is set back by the page, as before
    }

    @Test func test_merging_labels_carries_their_rejections() throws {
        let f = try Fixture(meeting: false)
        let a = try voiceMeeting(f.out, "2026-10-21T10-00-00", [("SPEAKER_00", unit(1, 0, 0), 60), ("SPEAKER_01", unit(0, 1, 0), 60)])
        try Speakers.setRejectedName(a, "SPEAKER_01", "Tom")
        try Speakers.setRejectedName(a, "SPEAKER_00", "Uli")
        _ = try PeopleAPI.mergeSpeaker(f.app, id: a.id, label: "SPEAKER_01", into: "SPEAKER_00")
        #expect(Speakers.loadRejectedNames(a)["SPEAKER_00"] == ["Uli", "Tom"])
    }

    @Test func test_undoing_a_typed_name_brings_the_rejection_back() throws {
        let f = try Fixture()
        try write(.object([("SPEAKER_00", .object([("name", .string("Rico")), ("similarity", .double(0.8))]))]), to: f.paths.speakersAuto)
        try f.name("SPEAKER_00", "")  // not Rico
        let token = try #require(try f.name("SPEAKER_00", "Rico"))  // it was Rico after all
        #expect(Speakers.loadRejectedNames(f.paths).isEmpty)
        _ = try f.undo(token)
        #expect(dumps(.object(Speakers.loadRejectedNames(f.paths).map { ($0.key, .strings($0.value)) })) == #"{"SPEAKER_00": ["Rico"]}"#)
        #expect(try f.page()["speakers"]?[1]?["name"] == .null)
    }

    @Test func test_a_maybe_suggestion_goes_with_not_tom() throws {
        let f = try Fixture(meeting: false)
        let named = try voiceMeeting(f.out, "2026-10-20T10-00-00", [("SPEAKER_00", unit(1, 0, 0), 60)])
        let a = try voiceMeeting(f.out, "2026-10-21T10-00-00", [("SPEAKER_00", unit(1, 1, 0), 60)])  // 0.71 alike
        try People.nameVoices(outputDir: f.out, members: [(named.id, "SPEAKER_00")], name: "Tom", stores: f.stores)
        var lane = try f.page(a.id)["speakers"]?[1]
        #expect(lane?["maybe"]?.list.map { $0["name"] ?? .null } == [.string("Tom")])
        try Speakers.setRejectedName(a, "SPEAKER_00", "Tom")
        lane = try f.page(a.id)["speakers"]?[1]
        #expect(lane?["maybe"] == .array([]))
    }

    // MARK: - test_organizations.py (the page halves; the domain halves are OrganizationsTests')

    private func withInvitees(_ f: Fixture) throws {
        let start = try PyDateTime.parse("2026-10-27T16:03:07+01:00")
        try CalendarEvents.save(f.paths, CalendarEvent(title: "Debrief", start: start, end: try! start.adding(seconds: 1800), attendees: [
            Attendee(name: "Timo Strauß", email: "timo@kloud.io", isSelf: true),
            Attendee(name: "Rico Lanza", email: "rico@muellerbau.at"),
            Attendee(name: "Anna Huber", email: "anna@gmail.com"),
            Attendee(name: "Room 3", email: "room@kloud.io", isRoom: true),
        ]))
    }

    @Test func test_speakers_and_invitees_show_their_organization() throws {
        let f = try Fixture()
        try withInvitees(f)
        try f.name("SPEAKER_00", "Rico")  // first name: resolves to Rico Lanza
        let m = try f.page()
        #expect(m["speakers"]?.list.map { [$0["name"] ?? .null, $0["org"] ?? .null] }
                == [[.string("Timo"), .string("KLOUD")], [.string("Rico"), .string("Muellerbau")], [.null, .null]])
        #expect(dumps(.object(m["calendar"]?["attendees"]?.list.map { ($0["name"]?.stringValue ?? "", $0["org"] ?? .null) } ?? []))
                == #"{"Rico Lanza": "Muellerbau", "Anna Huber": "Extern"}"#)
    }

    @Test func test_organizations_can_be_renamed_and_people_given_one() throws {
        let f = try Fixture()
        try withInvitees(f)
        try f.name("SPEAKER_00", "Rico")
        try f.name("SPEAKER_01", "Stefan D")
        try PeopleAPI.renameOrganization(f.app, key: "muellerbau", name: "Müllerbau")
        try PeopleAPI.setPersonOrg(f.app, person: "Stefan D", org: "Extern")
        #expect(try f.page()["speakers"]?.list.map { $0["org"] ?? .null } == [.string("KLOUD"), .string("Müllerbau"), .string("Extern")])

        let d = try PeopleAPI.directory(f.app, userName: "")
        #expect(dumps(.object(d["organizations"]?.list.map { ($0["key"]?.stringValue ?? "", $0["name"] ?? .null) } ?? []))
                == #"{"extern": "Extern", "kloud": "KLOUD", "muellerbau": "Müllerbau"}"#)
        let stefan = d["people"]?.list.first { $0["name"] == .string("Stefan D") }
        #expect(stefan?["org"] == .string("Extern") && stefan?["org_given"] == .bool(true))
        try PeopleAPI.setPersonOrg(f.app, person: "Stefan D", org: "")
        #expect(try f.page()["speakers"]?[2]?["org"] == .null)
        #expect(dumps(PythonJSON.read(f.stores.organizations)?["names"]) == #"{"muellerbau": "Müllerbau"}"#)
    }

    // MARK: - test_exchange.py (the meeting an import leaves is written here; `test_http_voices_of_an_import_are_added_on_a_yes`,
    // which imports it over HTTP, is ExchangeRoutesTests')

    @Test func test_yes_to_a_hint_teaches_no_voice_while_the_voices_wait() throws {
        let f = try Fixture(meeting: false)
        let paths = try importedMeeting(f.out)
        try f.name("SPEAKER_00", "Tom", paths.id)  // "Yes, Tom" on the hint
        #expect(ExchangeHints.loadRecord(paths)?["voices_pending"]?.truthy == true)
        #expect(try f.bank.names()["Tom"] == nil)
    }

    // MARK: - test_inference.py (the window's lane; the domain half is InferenceTests')

    @Test func test_the_window_shows_inferred_names_and_confirming_makes_them_facts() throws {
        let f = try Fixture(meeting: false)
        let m = try voiceMeeting(f.out, "2026-10-20T10-00-00", [("SPEAKER_00", unit(1, 0, 0, 0), 600)],
                                 start: "2026-10-20T10:00:00+02:00", duration: 3600, invited: ["Anna Huber"])
        _ = try Inference.refresh(outputDir: f.out, stores: f.stores)
        var lane = try f.page(m.id)["speakers"]?[1]
        #expect(lane?["name"] == .string("Anna Huber") && lane?["named_by"] == .string("inferred"))
        #expect(lane?["inferred"]?["rule"] == .string("calendar"))

        try f.name("SPEAKER_00", "Anna Huber", m.id)  // ✓
        lane = try f.page(m.id)["speakers"]?[1]
        #expect(lane?["named_by"] == .string("you") && lane?["inferred"] == .null)
        #expect(try f.bank.names() == PyDict([("Anna Huber", 1)]))  // now in the voice bank
    }
}
