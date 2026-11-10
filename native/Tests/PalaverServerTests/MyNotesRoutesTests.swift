// The user's own notes over HTTP (server.py `_my_notes_get`, `_my_notes_post`; api.py's my-notes functions): the
// test_webapp.py tests of #44 under their names. Images are read by a fake (Python's `no_vision`), on the reading's
// own thread as the server starts it.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"
private let BASE = "/api/meetings/\(MEETING)"

private func dumps(_ v: JSONValue?) -> String { v.map { PythonJSON.dumps($0, ensureAscii: false) } ?? "nil" }

/// `_png()`: a small PNG (1 × 1, white).
private let PNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC")!

/// The text recognition faked (`no_vision`): every image reads "Slide: Budget Q3"; the names read are kept.
private final class NoVision: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    var read: [String] { lock.withLock { names } }
    func recognize(_ url: URL) throws -> String {
        lock.withLock { names.append(url.lastPathComponent) }
        return "Slide: Budget Q3"
    }
}

/// test_webapp.py's `server` fixture: the page's meeting, served for "Timo", with the fake reading.
private func server(_ vision: NoVision = NoVision(), calendar: CalendarProvider? = nil,
                    meetings: @escaping (URL) throws -> Void = { try pageMeeting($0) }) throws -> TestServer {
    try TestServer(userName: "Timo", calendar: calendar, meetings: meetings, routes: { _, app in app.recognizeText = vision.recognize })
}

private func doc(_ s: TestServer, _ base: String = BASE) -> JSONValue { s.get("\(base)/my-notes").json ?? .null }

/// `_post`: the status and the JSON answer.
private func post(_ s: TestServer, _ path: String, _ body: JSONValue = .object([])) -> (Int, JSONValue) {
    let r = s.post(path, body)
    return (r.status, r.json ?? .null)
}

/// `_upload`: an image as base64 in JSON.
private func upload(_ s: TestServer, _ base: String, _ data: Data) -> (Int, JSONValue) {
    post(s, "\(base)/my-notes/images", .object([("data", .string(data.base64EncodedString()))]))
}

/// `_save_notes`: a save from an editor that has just read the notes.
@discardableResult
private func saveNotes(_ s: TestServer, _ base: String, _ paragraphs: JSONValue) -> (Int, JSONValue) {
    let revision = doc(s, base)["revision"] ?? .null
    return post(s, "\(base)/my-notes", .object([("paragraphs", paragraphs), ("revision", revision)]))
}

private func p(_ text: String, _ at: Double?, image: String? = nil) -> JSONValue {
    var fields: [(String, JSONValue)] = [("text", .string(text)), ("at", at.map { $0 == $0.rounded() ? .int(Int($0)) : .double($0) } ?? .null)]
    if let image { fields.append(("image", .string(image))) }
    return .object(fields)
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// `datetime.now().astimezone()`.
private func now() -> PyDateTime { PyDateTime(Date(), offset: TimeZone.current.secondsFromGMT()) }

/// `_prep_server`: a calendar with one event an hour after `now`, "ev/1+=" (a key that must be quoted).
private func prepCalendar(_ now: PyDateTime) -> (CalendarProvider, CalendarEvent) {
    let event = CalendarEvent(title: "Budget call", start: try! now.adding(seconds: 3600), end: try! now.adding(seconds: 7200),
                              attendees: [Attendee(name: "Valerie", email: "valerie@northwind.example")], uid: "ev/1+=")
    let provider: CalendarProvider = { s, e in
        let sp = PyDateTime(s, offset: nil), ep = PyDateTime(e, offset: nil)
        return (sp <= event.start && event.start < ep) || (sp < event.end && event.end <= ep) ? [event] : []
    }
    return (provider, event)
}

@Suite struct MyNotesRoutesTests {
    /// `b64decode(text, validate=True)`, decoded over the UTF-8 bytes: every length and padding, and what Python refuses.
    @Test func base64IsDecodedStrictly() {
        var bytes = [UInt8]()
        for n in 0..<70 {
            let data = Data(bytes)
            #expect(MyNotesAPI.base64Strict(data.base64EncodedString()) == data, "\(n) bytes")
            bytes.append(UInt8((n * 37 + 11) % 256))
        }
        for bad in ["Zg", "Zg=", "Zg===", "Zm8", "Z", "Zg=a", "Z g==", "Zg==\n", "Zé==", "ab-_", "====", "a==="] {
            #expect(MyNotesAPI.base64Strict(bad) == nil, "\(bad)")
        }
        #expect(MyNotesAPI.base64Strict("") == Data())
    }

    @Test func test_http_my_notes_are_saved_and_read_back() throws {
        let s = try server()
        defer { s.stop() }
        #expect(dumps(doc(s)) == #"{"paragraphs": [], "images": {}, "revision": ""}"#)
        let paragraphs = JSONValue.array([p("Ask about the **budget**", nil), p("- yes", 4.5)])
        let (status, answer) = saveNotes(s, BASE, paragraphs)
        #expect(status == 200 && answer["saved"] == .int(2) && answer["revision"]?.truthy == true)
        #expect(try MeetingsAPI.getMeeting(app: s.app, id: MEETING)["my_notes_revision"] == answer["revision"])
        #expect(dumps(doc(s)["paragraphs"]) == dumps(paragraphs))
        #expect(dumps(PythonJSON.read(s.app.outputDir.appendingPathComponent("\(MEETING)/my-notes.json"))) == dumps(paragraphs))
    }

    @Test func test_http_my_notes_refuse_garbage() throws {
        let s = try server()
        defer { s.stop() }
        saveNotes(s, BASE, .array([p("kept", nil)]))
        let revision = doc(s)["revision"] ?? .null
        #expect(post(s, "\(BASE)/my-notes", .object([("paragraphs", .array([]))])).0 == 400)  // a save says what it was based on
        let bodies: [JSONValue] = [
            .object([("revision", revision)]),
            .object([("paragraphs", .string("x")), ("revision", revision)]),
            .object([("paragraphs", .array([.object([("text", .int(1)), ("at", .null)])])), ("revision", revision)]),
            .object([("paragraphs", .array([p("", nil, image: "../meta.json")])), ("revision", revision)]),
        ]
        for body in bodies { #expect(post(s, "\(BASE)/my-notes", body).0 == 400, "\(dumps(body))") }
        #expect(post(s, "/api/meetings/2026-01-01T00-00-00/my-notes", .object([("paragraphs", .array([])), ("revision", .string(""))])).0 == 404)
        #expect(dumps(PythonJSON.read(s.app.outputDir.appendingPathComponent("\(MEETING)/my-notes.json"))) == dumps(.array([p("kept", nil)])))
    }

    @Test func test_http_a_pasted_image_is_stored_served_and_read() throws {
        let vision = NoVision()
        let s = try server(vision)
        defer { s.stop() }
        let (status, answer) = upload(s, BASE, PNG)
        #expect(status == 200)
        let name = try #require(answer["name"]?.stringValue)
        let images = s.app.outputDir.appendingPathComponent("\(MEETING)/my-notes", isDirectory: true)
        #expect(FileManager.default.contents(atPath: images.appendingPathComponent(name).path) == PNG)
        let served = s.get("\(BASE)/my-notes/images/\(name)")
        #expect(served.status == 200 && served.header("Content-Type") == "image/png" && served.body == PNG)
        #expect(until { exists(images.appendingPathComponent("\(name).txt")) })
        saveNotes(s, BASE, .array([p("", 3, image: name)]))
        #expect(dumps(doc(s)["images"]) == dumps(.object([(name, .object([("text", .string("Slide: Budget Q3"))]))])))
        #expect(vision.read == [name])
    }

    @Test func test_http_only_images_and_only_image_names() throws {
        let s = try server()
        defer { s.stop() }
        #expect(upload(s, BASE, Data("<svg/>".utf8)).0 == 400)
        #expect(post(s, "\(BASE)/my-notes/images", .object([("data", .string("not base64 !!"))])).0 == 400)
        #expect(post(s, "\(BASE)/my-notes/images", .object([("data", .string(""))])).0 == 400)
        #expect(s.get("\(BASE)/my-notes/images/meta.json").status == 404)
        #expect(s.get("\(BASE)/my-notes/images/img-0123456789ab.png").status == 404)
        #expect(s.get("\(BASE)/my-notes/images/..%2Fmeta.json").status == 404)
    }

    @Test func test_http_deleting_an_image_can_be_undone() throws {
        let s = try server()
        defer { s.stop() }
        let name = try #require(upload(s, BASE, PNG).1["name"]?.stringValue)
        let images = s.app.outputDir.appendingPathComponent("\(MEETING)/my-notes", isDirectory: true)
        #expect(until { exists(images.appendingPathComponent("\(name).txt")) })
        let paragraphs = [p("before", 1), p("", 2, image: name), p("after", 3)]
        saveNotes(s, BASE, .array(paragraphs))
        let (status, answer) = post(s, "\(BASE)/my-notes/images/\(name)/delete")
        #expect(status == 200 && answer["undo"]?.truthy == true)
        #expect(dumps(answer["paragraphs"]) == dumps(.array([paragraphs[0], paragraphs[2]])) && dumps(answer["images"]) == "{}")
        #expect(!exists(images.appendingPathComponent(name)))
        #expect(post(s, "/api/undo", .object([("token", answer["undo"] ?? .null)])).0 == 200)
        let again = doc(s)
        #expect(dumps(again["paragraphs"]) == dumps(.array(paragraphs)))
        #expect(dumps(again["images"]) == dumps(.object([(name, .object([("text", .string("Slide: Budget Q3"))]))])))
        #expect(post(s, "\(BASE)/my-notes/images/img-0123456789ab.png/delete").0 == 404)
    }

    @Test func test_http_undoing_a_delete_keeps_what_was_typed_since() throws {
        let s = try server()
        defer { s.stop() }
        let name = try #require(upload(s, BASE, PNG).1["name"]?.stringValue)
        let images = s.app.outputDir.appendingPathComponent("\(MEETING)/my-notes", isDirectory: true)
        #expect(until { exists(images.appendingPathComponent("\(name).txt")) })
        saveNotes(s, BASE, .array([p("before", 1), p("", 2, image: name)]))
        let answer = post(s, "\(BASE)/my-notes/images/\(name)/delete").1
        saveNotes(s, BASE, .array([p("before", 1), p("typed since", 9)]))
        #expect(post(s, "/api/undo", .object([("token", answer["undo"] ?? .null)])).0 == 200)
        let now = doc(s)
        #expect(dumps(now["paragraphs"]) == dumps(.array([p("before", 1), p("", 2, image: name), p("typed since", 9)])))
        #expect(dumps(now["images"]) == dumps(.object([(name, .object([("text", .string("Slide: Budget Q3"))]))])))
    }

    @Test func test_http_clearing_my_notes_can_be_undone_also_after_typing() throws {
        let s = try server()
        defer { s.stop() }
        let name = try #require(upload(s, BASE, PNG).1["name"]?.stringValue)
        let folder = s.app.outputDir.appendingPathComponent(MEETING, isDirectory: true)
        #expect(until { exists(folder.appendingPathComponent("my-notes/\(name).txt")) })
        let paragraphs = JSONValue.array([p("mine", nil), p("", 2, image: name)])
        saveNotes(s, BASE, paragraphs)
        var (status, answer) = post(s, "\(BASE)/my-notes/clear")
        #expect(status == 200 && answer["paragraphs"] == .array([]) && !exists(folder.appendingPathComponent("my-notes.json")))
        _ = post(s, "/api/undo", .object([("token", answer["undo"] ?? .null)]))
        #expect(dumps(doc(s)["paragraphs"]) == dumps(paragraphs))

        (_, answer) = post(s, "\(BASE)/my-notes/clear")
        saveNotes(s, BASE, .array([p("new words", 30)]))
        #expect(post(s, "/api/undo", .object([("token", answer["undo"] ?? .null)])).0 == 200)  // put back beside the new words
        #expect(dumps(doc(s)["paragraphs"]) == dumps(.array([p("mine", nil), p("", 2, image: name), p("new words", 30)])))
    }

    @Test func test_http_a_save_on_an_old_revision_is_refused_with_the_notes_as_they_are() throws {
        let s = try server()
        defer { s.stop() }
        let old = doc(s)["revision"] ?? .null
        saveNotes(s, BASE, .array([p("from the other window", nil)]))
        let (status, answer) = post(s, "\(BASE)/my-notes", .object([("paragraphs", .array([p("mine", nil)])), ("revision", old)]))
        #expect(status == 409 && dumps(answer["document"]?["paragraphs"]) == dumps(.array([p("from the other window", nil)])))
        #expect(answer["document"]?["revision"]?.truthy == true && answer["error"]?.truthy == true)
    }

    @Test func test_http_notes_written_before_the_meeting() throws {
        let (calendar, event) = prepCalendar(now())
        let s = try server(calendar: calendar, meetings: { _ in })
        defer { s.stop() }
        let base = "/api/upcoming/\(PyURL.quotePlus(event.key))"
        let paragraphs = JSONValue.array([p("Ask about the budget", nil)])
        let (status, answer) = saveNotes(s, base, paragraphs)
        #expect(status == 200 && answer["saved"] == .int(1))
        let name = try #require(upload(s, base, PNG).1["name"]?.stringValue)
        #expect(s.get("\(base)/my-notes/images/\(name)").body == PNG)
        #expect(dumps(doc(s, base)["paragraphs"]) == dumps(paragraphs))
        #expect(post(s, "/api/upcoming/nope%7C2026-10-28/my-notes", .object([("paragraphs", paragraphs), ("revision", .string(""))])).0 == 404)
        let prepared = MyNotes.prepFolder(event.key, stores: s.app.stores)
        #expect(dumps(.array(MyNotes.load(prepared).map(\.json))) == dumps(paragraphs))

        let recording = try pageMeeting(s.app.outputDir)
        _ = try Prep.apply(recording, event: event, stores: s.app.stores)  // the recording is matched to its event
        #expect(dumps(.array(MyNotes.load(recording.folder).map(\.json))) == dumps(paragraphs))
        #expect(doc(s, base)["paragraphs"] == .array([]))
    }

    @Test func test_http_prep_notes_show_in_the_meeting_while_it_is_recorded() throws {
        let now = now()
        let (calendar, event) = prepCalendar(try! now.adding(seconds: -(3600 + 5 * 60)))  // began 5 minutes ago
        let s = try server(calendar: calendar, meetings: { _ in })
        defer { s.stop() }
        let prepared = MyNotes.prepFolder(event.key, stores: s.app.stores)
        _ = try MyNotes.save(prepared, paragraphs: .array([p("Ask about the budget", nil)]))
        // `_recording`: a meeting being recorded, as far as the live worker got.
        let paths = RecordingPaths(s.app.outputDir.appendingPathComponent(MEETING, isDirectory: true))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        try Data(count: 100).write(to: URL(fileURLWithPath: paths.systemWav.path + ".part"))
        try Data(PythonJSON.dumps(.object([("until", .double(60)), ("mic", .array([])), ("system", .array([])),
                                           ("turns", .array([])), ("embeddings", .object([]))])).utf8).write(to: paths.live)
        try Data(PythonJSON.dumps(.object([("start_time", .string(try! now.adding(seconds: -240).iso))])).utf8).write(to: paths.meta)
        try Data("\(getpid())".utf8).write(to: paths.folder.appendingPathComponent("live.pid"))
        #expect(dumps(doc(s)["paragraphs"]) == dumps(.array([p("Ask about the budget", nil)])))
        #expect(!exists(prepared))
    }
}
