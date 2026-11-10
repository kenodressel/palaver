// The page of a meeting being recorded and the realtime stream's tail (api.py `_live_meeting`, `live_stream`).
// Ports the live and stream tests of tests/test_webapp.py; where Python's test names a speaker or renames the
// meeting through api.py, this one writes the same files through the domain (the writers are their routes').
// Plus: live.json and stream.json read while they are written never answer 500, and `since=` read as
// Python's `float()`.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"

/// `json.dumps(value)` into `url`.
private func write(_ value: JSONValue, to url: URL) throws {
    try Data(PythonJSON.dumps(value).utf8).write(to: url)
}

private func read(_ url: URL) throws -> JSONValue { try PythonJSON.parse(Data(contentsOf: url)) }

private func dumps(_ v: JSONValue?) -> String { v.map { PythonJSON.dumps($0) } ?? "<none>" }

private func keys(_ v: JSONValue?) -> [String] {
    guard case .object(let fields)? = v else { return [] }
    return fields.map(\.0)
}

private func seg(_ t: Double, _ text: String, _ who: String? = nil) -> JSONValue {
    .object([("start", .double(t)), ("end", .double(t + 2)), ("text", .string(text)), ("speaker", .str(who)),
             ("words", .array([]))])
}

private func turn(_ speaker: String, _ start: Double, _ end: Double) -> JSONValue {
    .object([("speaker", .string(speaker)), ("start", .double(start)), ("end", .double(end))])
}

/// The live.json of test_webapp.py `_recording`.
private let LIVE: JSONValue = .object([
    ("until", .double(60.0)),
    ("mic", .array([seg(0.0, "Hallo zusammen.", "Timo")])),
    ("system", .array([seg(3.0, "Hi Timo."), seg(20.0, "Ja, passt.")])),
    ("turns", .array([turn("SPEAKER_00", 3.0, 15.0), turn("SPEAKER_01", 18.0, 30.0)])),
    ("embeddings", .object([("SPEAKER_00", .array([.double(1.0), .double(0.0)])),
                            ("SPEAKER_01", .array([.double(0.0), .double(1.0)]))])),
])

/// test_webapp.py `_recording`: a meeting being recorded, as far as the live worker got.
@discardableResult
private func recording(_ root: URL) throws -> RecordingPaths {
    let paths = RecordingPaths(root.appendingPathComponent(MEETING, isDirectory: true))
    try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
    try Data(count: 100).write(to: URL(fileURLWithPath: paths.systemWav.path + ".part"))  // still growing
    try write(LIVE, to: paths.live)
    return paths
}

/// test_webapp.py `_stream_json`, `updated_at` given.
private func streamJSON(_ paths: RecordingPaths, updatedAt: Double = Date().timeIntervalSince1970) throws {
    func s(_ t: Double, _ text: String) -> [(String, JSONValue)] {
        [("start", .double(t)), ("end", .double(t + 2)), ("text", .string(text)), ("speaker", .null),
         ("settled_at", .double(t + 3))]
    }
    try write(.object([
        ("until", .double(75.0)),
        ("system", .array([.object(s(50.0, "Alt, von vorher.")), .object(s(70.0, "Ähm, wir nehmen Atterkring.")),
                           .object(s(74.0, "Ja."))])),
        ("mic", .array([.object(s(72.0, "Äh, passt gut.") + [("words", .array([]))])])),
        ("draft", .object([("system", .string("und dann")), ("mic", .string("roh vom Mikro"))])),
        ("questions", .array([.object([("start", .double(70.0)), ("end", .double(72.0)), ("text", .string("Wie viel?"))])])),
        ("speaking", .object([("others", .bool(true)), ("me", .bool(false))])),
        ("updated_at", .double(updatedAt)),
    ]), to: paths.stream)
}

private func line(_ speaker: String, _ label: String?, _ start: Double, _ text: String, _ glossed: JSONValue = .array([])) -> JSONValue {
    .object([("speaker", .string(speaker)), ("label", .str(label)), ("start", .double(start)), ("end", .double(start + 2)),
             ("text", .string(text)), ("glossed", glossed)])
}

/// A recordings folder and the stores in a temporary folder, and the app over them for "Timo" (no HTTP).
private final class Fixture {
    let dir: URL
    let out: URL
    let stores: StorePaths
    let app: ServerApp

    init() throws {
        dir = tempFolder("live")
        out = dir.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                            home: dir.appendingPathComponent("home", isDirectory: true))
        app = ServerApp(outputDir: out, userName: "Timo", stores: stores)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func page() throws -> JSONValue { try MeetingsAPI.getMeeting(app: app, id: MEETING) }
    func stream(since: Double = 0.0, now: Double? = nil) throws -> JSONValue {
        try LivePage.stream(app: app, id: MEETING, since: since, now: now)
    }
}

@Suite struct LivePageTests {
    // MARK: - the page

    @Test func test_a_meeting_being_recorded_shows_what_is_there_so_far() throws {
        let f = try Fixture()
        let paths = try recording(f.out)
        var m = try f.page()
        #expect(m["status"] == .string("recording") && dumps(m["live"]) == #"{"until": 60.0}"#)
        #expect(m["transcript"]?.arrayValue?.map { [$0["speaker"]!, $0["text"]!] } == [
            [.string("Timo"), .string("Hallo zusammen.")], [.string("Speaker 1"), .string("Hi Timo.")],
            [.string("Speaker 2"), .string("Ja, passt.")]])
        #expect(m["speakers"]?.arrayValue?.map { $0["label"]! } == [.null, .string("SPEAKER_00"), .string("SPEAKER_01")])

        try Speakers.nameLiveSpeaker(paths, "SPEAKER_01", "Konrad")  // api.name_speaker while recording
        // The next snapshot clusters differently: Konrad's voice is now SPEAKER_00.
        var live = PyDict<JSONValue>(try read(paths.live))!
        live["embeddings"] = .object([("SPEAKER_00", .array([.double(0.1), .double(1.0)])),
                                      ("SPEAKER_01", .array([.double(1.0), .double(0.1)]))])
        try write(live.json, to: paths.live)
        m = try f.page()
        #expect(m["transcript"]?.arrayValue?[1]["speaker"] == .string("Konrad") && m["speakers"]?.arrayValue?[1]["named_by"] == .string("you"))

        // Recording done and processed: the final label with Konrad's voice gets his name.
        try write(.object([("SPEAKER_00", .array([.double(0.9), .double(0.2)])), ("SPEAKER_01", .array([.double(0.05), .double(1.0)]))]),
                  to: paths.speakerEmbeddings)
        #expect(dumps(.object(try Speakers.adoptLiveNames(paths).map { ($0.key, .string($0.value)) })) == #"{"SPEAKER_01": "Konrad"}"#)
        #expect(dumps(try read(paths.speakers)) == #"{"SPEAKER_01": "Konrad"}"#)
        #expect(!FileManager.default.fileExists(atPath: paths.speakersLive.path))
    }

    @Test func test_a_meeting_being_recorded_can_be_renamed() throws {
        let f = try Fixture()
        let paths = try recording(f.out)
        #expect(try f.page()["title"] == .null)
        try Titles.save(paths, Titles.clean("Call with Konrad"))  // api.set_title
        let m = try f.page()
        #expect(m["status"] == .string("recording") && m["title"] == .string("Call with Konrad") && m["title_from"] == .string("you"))
        #expect(FileManager.default.fileExists(atPath: paths.live.path))
    }

    /// The whole page, key by key: the live shape (no notes, no audio), each lane's talk, a voice the bank knows.
    @Test func theLivePageHasPythonsShape() throws {
        let f = try Fixture()
        let paths = try recording(f.out)
        let bank = VoiceBank(directory: f.stores.voices)
        _ = try bank.add("Valerie", [0.0, 1.0], source: "2026-10-20T10-00-00:SPEAKER_01")
        try write(.object([("start_time", .string("2026-10-27T16:03:07+01:00"))]), to: paths.meta)
        let m = try f.page()
        #expect(keys(m) == ["id", "title", "title_from", "calendar", "start", "duration", "status", "live", "notes",
                                 "notes_stale", "notes_stale_reason", "my_notes_revision", "speakers", "transcript",
                                 "has_audio", "projects", "project_suggestions", "all_projects"])
        #expect(m["start"] == .string("2026-10-27T16:03:07+01:00") && m["has_audio"] == .bool(false) && m["notes"] == .null)
        let speakers = m["speakers"]!.arrayValue!
        #expect(dumps(speakers[0]) == #"{"label": null, "name": "Timo", "display": "Timo", "is_user": true, "clips": [], "#
            + #""talk_seconds": 2.0, "org": null, "org_link": null}"#)
        #expect(dumps(speakers[2]) == #"{"label": "SPEAKER_01", "name": "Valerie", "display": "Valerie", "is_user": false, "#
            + #""named_by": "voice", "recognized": {"name": "Valerie", "similarity": 1.0}, "guesses": [], "maybe": [], "#
            + #""merged": [], "clips": [], "talk_seconds": 12.0, "org": null, "org_link": null}"#)
        #expect(dumps(m["transcript"]?.arrayValue?[2]) == #"{"speaker": "Valerie", "label": "SPEAKER_01", "start": 20.0, "end": 22.0, "#
            + #""text": "Ja, passt.", "glossed": []}"#)
        #expect(m["transcript"]?.arrayValue?[0]["label"] == .null)
    }

    /// live.json is replaced whole (`live.json.tmp`, then a rename): one half-written beside it is not read; and a
    /// live.json that is no JSON at all reads as nothing yet (api `_read_json(paths.live, {})`), as in Python. Never a 500.
    @Test func test_a_half_written_live_json_shows_the_last_good_state() throws {
        let server = try TestServer(meetings: { out in try recording(out) })
        defer { server.stop() }
        let paths = RecordingPaths(server.app.outputDir.appendingPathComponent(MEETING, isDirectory: true))
        let full = PythonJSON.dumps(LIVE)
        let half = String(full.prefix(full.count / 2))
        try Data(half.utf8).write(to: paths.folder.appendingPathComponent("live.json.tmp"))
        var r = server.get("/api/meetings/\(MEETING)")
        #expect(r.status == 200)
        #expect(r.json?["transcript"]?.arrayValue?.count == 3 && r.json?["live"]?["until"] == .double(60.0))

        for cut in [half, "", "{\"until\": 60.0, \"mic\": [{\"start\": 0.0, \"te", "\u{FF}\u{FE}"] {
            try Data(cut.utf8).write(to: paths.live)
            r = server.get("/api/meetings/\(MEETING)")
            #expect(r.status == 200, "\(cut.prefix(20))")
            #expect(r.json?["status"] == .string("recording") && r.json?["transcript"] == .array([]))
            #expect(r.json?["live"]?["until"] == .int(0) && r.json?["speakers"]?.arrayValue?.count == 1)
        }
        try Data([0xFF, 0xFE, 0x7B]).write(to: paths.live)  // no UTF-8
        #expect(server.get("/api/meetings/\(MEETING)").status == 200)
        try FileManager.default.removeItem(at: paths.live)  // the worker finished between the check and the read
        #expect(try LivePage.meeting(app: server.app, paths: paths)["transcript"] == .array([]))
    }

    // MARK: - the stream's tail (#42)

    @Test func test_stream_tail_without_stream_json() throws {
        let f = try Fixture()
        try recording(f.out)
        #expect(dumps(try f.stream()) == #"{"stream": false}"#)
    }

    @Test func test_stream_tail_after_block_text() throws {
        let f = try Fixture()
        let g = Glossary(path: f.stores.glossary)
        _ = try g.add(term: "Attakring", variants: ["Atterkring"])
        try g.save()
        try streamJSON(try recording(f.out))  // live.json says until=60
        let tail = try f.stream(since: 60.0)
        #expect(tail["stream"] == .bool(true) && dumps(tail["until"]) == "75.0")
        #expect(dumps(tail["lines"]) == dumps(.array([
            line("Others", "stream", 70.0, "Wir nehmen Attakring.", .array([.array([.int(11), .int(20), .string("Atterkring")])])),
            line("Timo", nil, 72.0, "Passt gut."),
            line("Others", "stream", 74.0, "Ja."),
        ])))
        #expect(dumps(tail["draft"]) == #"{"system": "und dann", "mic": "roh vom Mikro"}"#)
        #expect(dumps(tail["speaking"]) == #"{"others": true, "me": false}"#)
        #expect(dumps(tail["questions"]) == #"[{"start": 70.0, "end": 72.0, "text": "Wie viel?"}]"#)
        #expect(keys(tail) == ["stream", "until", "lines", "draft", "speaking", "questions"])
    }

    @Test func test_http_stream_endpoint() throws {
        let server = try TestServer(meetings: { out in try recording(out) })
        defer { server.stop() }
        #expect(dumps(server.get("/api/meetings/\(MEETING)/stream?since=0").json) == #"{"stream": false}"#)
        try streamJSON(RecordingPaths(server.app.outputDir.appendingPathComponent(MEETING, isDirectory: true)))
        let r = server.get("/api/meetings/\(MEETING)/stream?since=71")
        #expect(r.status == 200)
        #expect(dumps(r.json) == dumps(try LivePage.stream(app: server.app, id: MEETING, since: 71.0)))
        #expect(r.json?["lines"]?.arrayValue?.map { $0["start"]! } == [.double(72.0), .double(74.0)])
        #expect(server.get("/api/meetings/nope/stream").status == 404)
        #expect(server.get("/api/meetings/nope/stream").error == "not found: nope")
    }

    @Test func test_stream_tail_survives_wrong_shapes() throws {
        let f = try Fixture()
        let paths = try recording(f.out)
        let good: JSONValue = .object([("start", .double(70.0)), ("end", .double(72.0)), ("text", .string("Gut.")), ("speaker", .null)])
        try write(.object([
            ("until", .string("soon")),
            ("system", .array([good, .null, .string("x"), .object([("end", .int(3)), ("text", .string("no start"))]),
                               .object([("start", .string("7")), ("end", .int(8)), ("text", .string("str start"))]),
                               .object([("start", .double(71.0)), ("end", .double(72.0))]),
                               .object([("start", .double(71.0)), ("end", .double(72.0)), ("text", .int(5))])])),
            ("mic", .null),
            ("draft", .string("not a dict")),
            ("speaking", .array([.int(1)])),
            ("questions", .null),
        ]), to: paths.stream)
        #expect(dumps(try f.stream()) == dumps(.object([
            ("stream", .bool(true)), ("until", .int(0)), ("lines", .array([line("Others", "stream", 70.0, "Gut.")])),
            ("draft", .object([("system", .string("")), ("mic", .string(""))])), ("speaking", .object([])), ("questions", .array([])),
        ])))
        try write(.object([("system", .object([("a", .int(1))])), ("draft", .null)]), to: paths.stream)
        #expect(try f.stream()["lines"] == .array([]))
        try Data("[1, 2]".utf8).write(to: paths.stream)
        #expect(dumps(try f.stream()) == #"{"stream": false}"#)
    }

    /// stream.json appears once the model has loaded; until then a running stream says it is starting, so the window
    /// keeps asking.
    @Test func test_stream_tail_while_the_stream_starts() throws {
        let f = try Fixture()
        let paths = try recording(f.out)
        try Data("\(getpid())".utf8).write(to: paths.streamPid)
        #expect(dumps(try f.stream()) == #"{"stream": false, "starting": true}"#)
        try Data("999999999".utf8).write(to: paths.streamPid)  // gone
        #expect(dumps(try f.stream()) == #"{"stream": false}"#)
    }

    @Test func test_a_stale_stream_is_no_stream() throws {
        let f = try Fixture()
        let paths = try recording(f.out)
        let updated = 1_793_000_000.25
        try streamJSON(paths, updatedAt: updated)
        let tail = try f.stream(now: updated + 9.5)
        #expect(tail["stream"] == .bool(true) && tail["draft"]?["system"] == .string("und dann"))
        try Data("\(getpid())".utf8).write(to: paths.streamPid)  // even with its pid file left
        #expect(dumps(try f.stream(now: updated + 10.5)) == #"{"stream": false, "stale": true}"#)
        #expect(try f.stream(now: updated + LivePage.STREAM_STALE_SECONDS)["stream"] == .bool(true))  // not over it yet
    }

    @Test func test_stream_tail_filler_only_draft_is_empty() throws {
        let f = try Fixture()
        let paths = try recording(f.out)
        try write(.object([("draft", .object([("system", .string("Mm-hmm.")), ("mic", .string("äh"))]))]), to: paths.stream)
        #expect(dumps(try f.stream()["draft"]) == #"{"system": "", "mic": ""}"#)
    }

    /// stream.json is replaced whole once a second (`stream.json.tmp`, then a rename): a half-written one beside it is
    /// not read, and a stream.json cut short anyway is no stream (`_read_json(paths.stream, None)`). Never a 500.
    @Test func test_stream_json_cut_mid_write_is_no_error() throws {
        let server = try TestServer(meetings: { out in try recording(out) })
        defer { server.stop() }
        let paths = RecordingPaths(server.app.outputDir.appendingPathComponent(MEETING, isDirectory: true))
        try streamJSON(paths)
        let full = try String(contentsOf: paths.stream, encoding: .utf8)
        try Data(full.prefix(full.count / 2).utf8).write(to: paths.folder.appendingPathComponent("stream.json.tmp"))
        var r = server.get("/api/meetings/\(MEETING)/stream?since=0")
        #expect(r.status == 200 && r.json?["lines"]?.arrayValue?.count == 4)
        try Data("\(getpid())".utf8).write(to: paths.streamPid)  // a stream running: still not "starting", the file is there
        for cut in [String(full.prefix(full.count / 2)), "", "{\"until\": 75.0, \"system\": [{\"start\": 7", "\u{FF}"] {
            try Data(cut.utf8).write(to: paths.stream)
            r = server.get("/api/meetings/\(MEETING)/stream?since=0")
            #expect(r.status == 200 && dumps(r.json) == #"{"stream": false}"#, "\(cut.prefix(20))")
        }
        try Data([0x7B, 0xFF]).write(to: paths.stream)  // no UTF-8
        #expect(dumps(server.get("/api/meetings/\(MEETING)/stream").json) == #"{"stream": false}"#)
    }

    // MARK: - since=

    /// server.py: `float(query.get("since", ["0"])[0])`, 0.0 where that raises.
    @Test func sinceIsReadAsPythonsFloat() throws {
        for (text, value) in [("71", 71.0), (" 71.5\n", 71.5), ("1_0", 10.0), ("1e1", 10.0), ("1.e1", 10.0), (".5", 0.5),
                              ("5.", 5.0), ("+3", 3.0), ("-0", -0.0), ("٧١", 71.0), ("\u{2003}7\u{3000}", 7.0),
                              ("1e400", .infinity), ("-Infinity", -.infinity), ("iNf", .infinity)] {
            #expect(Py.float(text) == value, "\(text)")
        }
        #expect(Py.float("nan")?.isNaN == true && Py.float("-NaN")?.isNaN == true)
        for bad in ["", " ", "abc", "1__0", "_1", "1_", "1_.5", "1._5", "0x10", "1e", "e5", ".", "1 2", "in_f", "nan(1)",
                    "infinit", "1,5", "７x", "½", "1e1_", "++1", "1\u{0}"] {
            #expect(Py.float(bad) == nil, "\(bad)")
        }

        let server = try TestServer(meetings: { out in try recording(out) })
        defer { server.stop() }
        let paths = RecordingPaths(server.app.outputDir.appendingPathComponent(MEETING, isDirectory: true))
        try streamJSON(paths)
        func starts(_ query: String) -> [JSONValue]? {
            server.get("/api/meetings/\(MEETING)/stream\(query)").json?["lines"]?.arrayValue?.map { $0["start"]! }
        }
        let all: [JSONValue] = [.double(50.0), .double(70.0), .double(72.0), .double(74.0)]
        #expect(starts("") == all && starts("?since=") == all && starts("?since=abc") == all && starts("?since=%FF") == all)
        #expect(starts("?since=-inf") == all && starts("?since=nan") == [] && starts("?since=inf") == [])
        #expect(starts("?since=7_1") == [.double(72.0), .double(74.0)] && starts("?since=+71&since=0") == [.double(72.0), .double(74.0)])
        #expect(starts("?since=%2071%20") == [.double(72.0), .double(74.0)] && starts("?since=71+") == [.double(72.0), .double(74.0)])
    }

    /// A stream.json number that is an int stays one in the answer (`round(70, 2)` is 70), as Python writes it.
    @Test func intTimesStayInts() throws {
        let f = try Fixture()
        let paths = try recording(f.out)
        try write(.object([("system", .array([.object([("start", .int(70)), ("end", .double(72.456)), ("text", .string("Gut."))]),
                                              .object([("start", .double(69.5)), ("end", .int(70)), ("text", .string("Ja."))])])),
                           ("until", .int(75))]), to: paths.stream)
        let tail = try f.stream()
        let times: [JSONValue] = (tail["lines"]?.arrayValue ?? []).map { JSONValue.array([$0["start"]!, $0["end"]!]) }
        #expect(dumps(.array(times)) == "[[69.5, 70], [70, 72.46]]")
        #expect(tail["until"] == .int(75))
    }
}
