// Export and import over HTTP (#58) (api.py `export_meeting`, `import_meeting`; server.py's `/export` branch and
// `_import`): test_exchange.py's tests of the server under their names, and those of `api.import_meeting` (its undo,
// `_PROJECTS_LOCK`) the domain tasks left to the server. Synthetic meetings only: Valerie exports, Timo imports.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let ID = "2026-10-29T10-00-00"
private let START = "2026-10-29T10:00:00+01:00"
private let SENDER = "Valerie"

private func dumps(_ v: JSONValue?) -> String { v.map { PythonJSON.dumps($0, ensureAscii: false) } ?? "nil" }
private func write(_ v: JSONValue, _ url: URL) throws { try PythonJSON.write(v, to: url, indent: nil, ensureAscii: true) }
private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
private func keys(_ v: JSONValue) -> [String] { if case .object(let fields) = v { return fields.map(\.0) } else { return [] } }

private func attendee(_ name: String, _ email: String, organizer: Bool = false, isSelf: Bool = false) -> JSONValue {
    var fields: [(String, JSONValue)] = [("name", .string(name)), ("email", .string(email)), ("response", .string("accepted"))]
    if organizer { fields.append(("organizer", .bool(true))) }
    if isSelf { fields.append(("is_self", .bool(true))) }
    return .object(fields)
}

/// test_exchange.py's `EVENT`.
private let EVENT = JSONValue.object([
    ("title", .string("Budget review")), ("start", .string("2026-10-29T10:00:00+01:00")), ("end", .string("2026-10-29T10:30:00+01:00")),
    ("uid", .string("ABC-123")), ("series", .bool(true)), ("location", .string("Teams")),
    ("attendees", .array([attendee("Valerie", "valerie@northwind.example", organizer: true, isSelf: true),
                          attendee("Timo Strauß", "timo.s@contoso.example"), attendee("Timo", "timo@contoso.example")])),
    ("link", .object([("source", .string("calendar")), ("confidence", .double(0.9)), ("reason", .string("time match"))])),
])

/// 64 numbers, a direction of its own per seed (`_vector`).
private func vector(_ seed: Int) -> [Double] { (0..<64).map { sin(Double(seed * 64 + $0) * 0.7) } }

/// `make_meeting`: `user`'s recording — Timo Strauß named by hand, Carla recognized by voice, SPEAKER_02 merged into
/// Timo Strauß, SPEAKER_03 removed as noise; with its notes and (`event`) its calendar event.
@discardableResult
private func makeMeeting(_ root: URL, _ name: String = ID, start: String = START, event: JSONValue? = EVENT,
                         user: String = SENDER) throws -> RecordingPaths {
    let paths = RecordingPaths(root.appendingPathComponent(name, isDirectory: true))
    try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
    try write(.object([("start_time", .string(start)), ("duration_seconds", .int(60))]), paths.meta)
    try Data("de".utf8).write(to: paths.language)
    try write(.array([
        SpeakerTurn(speaker: "SPEAKER_00", start: 2, end: 20).json, SpeakerTurn(speaker: "SPEAKER_01", start: 21, end: 40).json,
        SpeakerTurn(speaker: "SPEAKER_02", start: 41, end: 44).json, SpeakerTurn(speaker: "SPEAKER_03", start: 45, end: 45.5).json,
    ]), paths.systemTurns)
    let utterances = [
        Utterance(speaker: user, start: 0, end: 2, text: "Hallo zusammen."),
        Utterance(speaker: "Timo Strauß", start: 2, end: 20, text: "Das Budget steht.", label: "SPEAKER_00"),
        Utterance(speaker: "Carla", start: 21, end: 40, text: "Wir brauchen mehr Zeit.", label: "SPEAKER_01"),
        Utterance(speaker: "SPEAKER_02", start: 41, end: 44, text: "Genau."),
        Utterance(speaker: "SPEAKER_03", start: 45, end: 45.5, text: "Hm."),
        Utterance(speaker: user, start: 50, end: 55, text: "Dann machen wir das so."),
    ]
    try write(.array(utterances.map(\.json)), paths.transcriptJson)
    try write(.object([("SPEAKER_00", .string("Timo Strauß"))]), paths.speakers)
    try write(.object([("SPEAKER_01", .object([("name", .string("Carla")), ("similarity", .double(0.9))]))]), paths.speakersAuto)
    try write(.object([("SPEAKER_02", .string("SPEAKER_00"))]), paths.speakersMerged)
    try write(.strings(["SPEAKER_03"]), paths.speakersIgnored)
    try write(.object((0..<4).map { ("SPEAKER_0\($0)", .array(vector($0).map { .double($0) })) }), paths.speakerEmbeddings)
    if let event { try write(event, paths.calendar) }
    try NotesFile.save(paths, .object([
        ("title", .string("Budget review")), ("summary", .string("SPEAKER_00 presented the budget.")),
        ("sections", .array([])), ("next_steps", .array([])), ("decisions", .strings(["Budget approved"])),
        ("speaker_names", .array([])), ("transcript_hash", .string(Notes.transcriptHash(utterances))),
    ]))
    return paths
}

/// The `server` fixture: Timo's own recording of the meeting, served for "Timo" (downloads: the test's home's).
private func server() throws -> TestServer {
    try TestServer(userName: "Timo", meetings: { try makeMeeting($0, user: "Timo") })
}

/// `export`: Valerie's recording (made under the server's folder, apart from its recordings) as a zip.
private func export(_ s: TestServer, _ name: String = ID, start: String = START, event: JSONValue? = EVENT, voices: Bool = false,
                    file: String = "x.zip") throws -> URL {
    let root = s.dir.appendingPathComponent("valerie", isDirectory: true)
    let paths = try makeMeeting(root, name, start: start, event: event)
    return try Exchange.exportMeeting(paths, dest: s.dir.appendingPathComponent("out/\(file)"), userName: SENDER, voices: voices,
                                      stores: s.app.stores)
}

/// `call`: a POST, JSON or the bytes as they are, with its type.
private func call(_ s: TestServer, _ path: String, _ body: JSONValue? = nil, raw: Data? = nil,
                  contentType: String = "application/json") -> (Int, JSONValue) {
    let data = raw ?? body.map { Data(PythonJSON.dumps($0).utf8) }
    let r = Wire.send(port: s.port, Wire.request("POST", path, headers: [s.host, ("Content-Type", contentType)], body: data))
    return (r.status, r.json ?? .null)
}

private func importing(_ s: TestServer, _ file: URL, path: String = "/api/import") throws -> (Int, JSONValue) {
    call(s, path, raw: try Data(contentsOf: file), contentType: "application/octet-stream")
}

/// `names_in`: the zip's entries.
private func namesIn(_ file: URL) throws -> Set<String> {
    let zip = try ExchangeZip.open(file)
    return Set(try ExchangeZip.entries(zip).entries.keys)
}

@Suite struct ExchangeRoutesTests {
    // MARK: - HTTP

    @Test func test_http_export_saves_to_downloads() throws {
        let s = try server()
        defer { s.stop() }
        let (status, answer) = call(s, "/api/meetings/\(ID)/export", .object([("notes", .bool(false)), ("voices", .bool(true))]))
        #expect(status == 200 && answer["name"] == .string("2026-10-29 Budget review.zip") && answer["folder"] == .string("Downloads"))
        let saved = s.app.downloads.appendingPathComponent(answer["name"]?.stringValue ?? "")
        #expect(answer["saved"] == .string(saved.path))
        let names = try namesIn(saved)
        #expect(!names.contains("meeting/notes.json") && names.contains("voices/SPEAKER_00.json"))
        #expect(answer["bytes"] == .int(try FileManager.default.attributesOfItem(atPath: saved.path)[.size] as? Int ?? -1))
        let again = call(s, "/api/meetings/\(ID)/export", .object([])).1
        #expect(again["name"] == .string("2026-10-29 Budget review 2.zip"))  // never over an earlier one
    }

    @Test func test_http_export_of_a_meeting_kept_on_this_mac_asks_first() throws {
        let s = try server()
        defer { s.stop() }
        try Data("{}".utf8).write(to: s.app.outputDir.appendingPathComponent("\(ID)/local_only.json"))
        let (status, answer) = call(s, "/api/meetings/\(ID)/export", .object([]))
        #expect(status == 200 && dumps(answer) == #"{"question": "local_only"}"#)
        #expect(!exists(s.app.downloads))
        let (status2, answer2) = call(s, "/api/meetings/\(ID)/export", .object([("confirm_local", .bool(true))]))
        #expect(status2 == 200 && answer2["name"]?.stringValue?.hasSuffix(".zip") == true)
    }

    @Test func test_mcp_says_a_meeting_was_imported_and_from_whom() throws {
        let s = try server()
        defer { s.stop() }
        let (status, answer) = try importing(s, try export(s), path: "/api/import?separate=1")
        let imported = try #require(answer["imported"]?.stringValue)
        #expect(status == 200)
        let m = McpTools(app: s.app, userName: "Timo")  // the Swift `palaver mcp`'s tools (phase 4 batch 6)
        var listed: [String: JSONValue] = [:]
        for brief in try m.listMeetings().arrayValue ?? [] { listed[brief["id"]?.stringValue ?? ""] = brief }
        #expect(listed[imported]?["imported_from"] == .string(SENDER) && listed[ID]?["imported_from"] == nil)
        let got = try m.getMeeting(meetingId: imported)
        #expect(got["imported_from"] == .string(SENDER) && got["note"]?.stringValue?.hasPrefix("Imported from \(SENDER)") == true)
    }

    @Test func test_http_import_asks_before_going_beside_my_own_recording() throws {
        let s = try server()
        defer { s.stop() }
        let exported = try export(s)
        var (status, answer) = try importing(s, exported)
        #expect(status == 200 && answer["question"] == .string("collision") && answer["own"] == .bool(true))
        #expect(answer["meeting"]?["id"] == .string(ID) && answer["from"] == .string(SENDER))
        #expect(answer["meeting"]?["title"] == .string("Budget review") && answer["meeting"]?["start"] == .string(START))
        #expect(answer["how"] == .string("event"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.app.outputDir.path).filter { !$0.hasPrefix(".") } == [ID])
        (status, answer) = try importing(s, exported, path: "/api/import?separate=1")
        #expect(status == 200 && answer["imported"] == .string("\(ID)-2") && answer["beside"] == .string(ID) && answer["undo"]?.truthy == true)
        #expect(keys(answer) == ["imported", "from", "voices", "warnings", "beside", "undo"])
        let (undone, _) = call(s, "/api/undo", .object([("token", answer["undo"] ?? .null)]))
        #expect(undone == 200 && !exists(s.app.outputDir.appendingPathComponent("\(ID)-2")))
    }

    @Test func test_http_import_refuses_json_and_says_why_a_file_is_rejected() throws {
        let s = try server()
        defer { s.stop() }
        #expect(call(s, "/api/import", .object([("file", .string("x"))])).0 == 415)
        let (status, answer) = call(s, "/api/import", raw: Data("not a zip".utf8), contentType: "application/octet-stream")
        #expect(status == 400 && answer["error"]?.stringValue?.hasPrefix("Not imported: This is not a zip") == true)
    }

    @Test func test_http_voices_of_an_import_are_added_on_a_yes() throws {
        let s = try server()
        defer { s.stop() }
        let out = try export(s, "2026-10-28T09-00-00", start: "2026-10-28T09:00:00+01:00", event: nil, voices: true)
        let (_, answer) = try importing(s, out)
        #expect(dumps(answer["voices"]) == dumps(.array([
            .object([("label", .string("SPEAKER_00")), ("name", .string("Timo Strauß"))]),
            .object([("label", .string("SPEAKER_01")), ("name", .string("Carla"))]),
        ])))
        let bank = VoiceBank(directory: s.app.stores.voices)
        let before = try bank.names()
        #expect(before["Carla"] == nil)
        let id = try #require(answer["imported"]?.stringValue)
        let (status, meeting) = call(s, "/api/meetings/\(id)/imported-voices", .object([("add", .bool(true))]))
        let carla = try bank.names()["Carla"]
        #expect(status == 200 && meeting["imported"]?["voices"] == .array([]) && carla == 1)
        _ = call(s, "/api/undo", .object([("token", meeting["undo"] ?? .null)]))
        #expect(dumps(.object(try bank.names().map { ($0.key, .int($0.value)) })) == dumps(.object(before.map { ($0.key, .int($0.value)) })))
    }

    /// test_exchange.py `test_leftovers_of_imports_are_swept_at_start_and_of_exports_on_the_next_export`, its export half
    /// (`Exchange.sweep` itself is ExchangeExportTests'): an export sweeps what an export cut short left in Downloads.
    @Test func anExportSweepsWhatAnEarlierExportLeftInDownloads() throws {
        let s = try server()
        defer { s.stop() }
        let old = s.app.downloads.appendingPathComponent(".palaver-export-x1", isDirectory: true)
        let other = s.app.downloads.appendingPathComponent("keep.zip")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: other)
        let hoursAgo = Date(timeIntervalSinceNow: -2 * 3600)
        for url in [old, other] { try FileManager.default.setAttributes([.modificationDate: hoursAgo], ofItemAtPath: url.path) }
        #expect(call(s, "/api/meetings/\(ID)/export", .object([])).0 == 200)
        #expect(!exists(old) && exists(other))
    }

    @Test func test_the_web_route_takes_files_as_large_as_the_core_does() {
        #expect(Router.MAX_IMPORT_BODY == ExchangeZip.MAX_FILE_BYTES)
    }

    // MARK: - api.import_meeting

    @Test func test_undoing_an_import_forgets_the_voices_it_taught() throws {
        let s = try TestServer(userName: "Timo")
        defer { s.stop() }
        let out = try export(s, voices: true)
        let answer = try ExchangeAPI.importMeeting(s.app, file: out)
        let bank = VoiceBank(directory: s.app.stores.voices)
        _ = try bank.add("Timo Strauß", vector(0), source: "\(ID):SPEAKER_00")  // learned from it meanwhile
        _ = try bank.add("Zoe", vector(9), source: "2026-10-01T10-00-00:SPEAKER_00")
        _ = try UndoRoute.undoChange(s.app, token: answer["undo"]?.stringValue ?? "")
        #expect(try bank.names() == PyDict([("Zoe", 1)]))
    }

    @Test func test_an_import_can_be_undone_through_the_trash() throws {
        let s = try TestServer(userName: "Timo")
        defer { s.stop() }
        let mine = s.app.outputDir
        let answer = try ExchangeAPI.importMeeting(s.app, file: try export(s))
        #expect(answer["imported"] == .string(ID) && MeetingsAPI.isDirectory(mine.appendingPathComponent(ID)))
        let token = answer["undo"]?.stringValue ?? ""
        _ = try UndoRoute.undoChange(s.app, token: token)
        #expect(!exists(mine.appendingPathComponent(ID)))
        #expect(exists(mine.appendingPathComponent(".trash/\(ID)/transcript.json")))
        #expect(throws: UndoGone.self) { try Undo.restore(mine, token) }
    }

    /// Python spies on `_write_audio` (part of `stage`); here the calendar `stage` asks for the event says whether the
    /// projects were held then.
    @Test func test_an_import_is_built_before_the_projects_are_held() throws {
        final class Held: @unchecked Sendable {
            let lock = NSLock()
            var held: [Bool] = []
        }
        let seen = Held()
        var app: ServerApp?
        let s = try TestServer(userName: "Timo", calendar: { _, _ in
            if let projects = app?.projectsLock {
                let free = projects.try()
                if free { projects.unlock() }
                seen.lock.withLock { seen.held.append(!free) }
            }
            return []
        })
        defer { s.stop() }
        app = s.app
        _ = try ExchangeAPI.importMeeting(s.app, file: try export(s))
        #expect(seen.lock.withLock { seen.held } == [false])
    }
}
