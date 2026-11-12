// Search in the window (#46; api.py `search`, `search_page`, `search_meaning`, `warm_search_cache`, `busy_recording`,
// `start_warming`): tests/test_search_api.py's 18 under their names, test_webapp.py's three search tests,
// test_semantic.py's window halves, and the server's start (the warming before the ready line).
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"
private let OTHER = "2026-09-15T10-00-00"
private let TODAY = PyDate(2026, 10, 29)!

private func write(_ value: JSONValue, to url: URL) throws { try Data(PythonJSON.dumps(value).utf8).write(to: url) }
private func read(_ url: URL) -> JSONValue { PythonJSON.read(url) ?? .null }

private extension JSONValue {
    subscript(i: Int) -> JSONValue? { arrayValue.flatMap { $0.indices.contains(i) ? $0[i] : nil } }
    var list: [JSONValue] { arrayValue ?? [] }
    /// The object with `key` set (added at the end when new).
    func with(_ key: String, _ value: JSONValue) -> JSONValue {
        var d = PyDict<JSONValue>(self) ?? PyDict()
        d[key] = value
        return d.json
    }
    /// The list with item `i` replaced by `f(item)`.
    func changing(_ i: Int, _ f: (JSONValue) -> JSONValue) -> JSONValue {
        var items = list
        items[i] = f(items[i])
        return .array(items)
    }
}

private func ids(_ results: [JSONValue]) -> [String] { results.compactMap { $0["id"]?.stringValue } }

/// Sets a file's modification time `seconds` after its current one (`os.utime(ns=...)`).
private func touch(_ url: URL, later seconds: Int) throws {
    var st = stat()
    precondition(stat(url.path, &st) == 0)
    var times = [st.st_atimespec, st.st_mtimespec]
    times[1].tv_sec += seconds
    precondition(utimensat(AT_FDCWD, url.path, &times, 0) == 0)
}

/// Stands in for multilingual-e5-small (test_semantic.py's FakeEncoder): one dimension per concept, the rest by length.
private final class FakeEncoder: MeaningEncoder, @unchecked Sendable {
    static let concepts = [["pricing", "price", "kosten", "angebot", "cost", "offer"], ["test", "testphase", "pilot"]]
    let dimension = 64
    let asked: Asked?

    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        var queries: [String] { lock.withLock { texts } }
        func add(_ text: String) { lock.withLock { texts.append(text) } }
    }

    init(asked: Asked? = nil) { self.asked = asked }

    private func vec(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: 64)
        var word = ""
        for u in Py.casefold(text).unicodeScalars + [" "] {
            if Py.isWordScalar(u) { word.unicodeScalars.append(u); continue }
            if !word.isEmpty, let hit = Self.concepts.firstIndex(where: { $0.contains { Py.same($0, word) } }) { v[hit] += 3 }
            word = ""
        }
        v[2 + text.unicodeScalars.count % 60] += 0.1
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / norm }
    }

    func query(_ text: String) throws -> [Float] {
        asked?.add(text)
        return vec(text)
    }

    func passages(_ texts: [String]) throws -> [[Float]] { texts.map(vec) }
}

/// The menu bar app as far as the warming and the search status ask it.
private final class BusyApp: RecordingRemote, @unchecked Sendable {
    let isBusy: Bool
    let status: JSONValue
    init(busy: Bool = false, indexing: JSONValue = .object([])) {
        isBusy = busy
        status = indexing
    }
    func question() -> JSONValue? { nil }
    func recording() -> JSONValue? { nil }
    func coach() -> JSONValue? { nil }
    func memory() -> JSONValue? { nil }
    func indexing() -> JSONValue { status }
    func busy() -> Bool { isBusy }
    func answer(choice: String, meeting: String) throws -> Bool { false }
    func watch(folder: URL, pid: Int32) {}
    func startHelper(kind: String, key: String, args: [String]) throws -> Int32 { throw AppCtlClient.CallFailed("fake") }
    func transcribe(folder: URL) throws -> Bool { false }
    func record(action: String, meeting: String?) throws -> JSONValue { throw Refused(AppAPI.NOT_IN_THE_APP) }
    func switchedOff(app: String) {}
    func calendarStatus() -> JSONValue { .object([]) }
    func calendarConnect() throws -> JSONValue { .object([]) }
    func test(_ args: JSONValue, timeout: Double) throws -> JSONValue { .object([]) }
    func updateCheck() throws -> JSONValue { throw Refused(Remote.APP_GONE) }
    func updateInstall() throws -> JSONValue { throw Refused(Remote.APP_GONE) }
    func uninstall(_ args: JSONValue) throws -> JSONValue { throw Refused(Remote.APP_GONE) }
}

/// A recordings folder and the stores in a temporary folder, and the app over them for "Timo" (no HTTP).
private final class Fixture {
    let dir: URL
    let out: URL
    let stores: StorePaths
    let app: ServerApp

    init(recording: RecordingRemote? = nil) throws {
        dir = tempFolder("search")
        out = dir.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                            home: dir.appendingPathComponent("home", isDirectory: true))
        app = ServerApp(outputDir: out, userName: "Timo", stores: stores, recording: recording)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func paths(_ id: String = MEETING) -> RecordingPaths { RecordingPaths(out.appendingPathComponent(id, isDirectory: true)) }
    func search(_ text: String) throws -> [JSONValue] { try SearchAPI.search(app, text, userName: "Timo", today: TODAY) }
    func name(_ id: String, _ label: String, _ name: String) throws { _ = try PeopleAPI.nameSpeaker(app, id: id, label: label, name: name) }

    /// `_copy`: MEETING again as `name`, starting at `start`.
    @discardableResult
    func copy(_ name: String, start: String) throws -> RecordingPaths {
        try FileManager.default.copyItem(at: paths().folder, to: paths(name).folder)
        let p = paths(name)
        try write(read(p.meta).with("start_time", .string(start)), to: p.meta)
        return p
    }

    /// `_invite`: the meeting's event "Weekly", the user and `people` invited.
    func invite(_ p: RecordingPaths, _ people: [(String, String)]) throws {
        let t = try PyDateTime.parse("2026-10-27T16:00:00+01:00")
        let attendees = [Attendee(name: "Timo Strauss", email: "timo@kloud.io", isSelf: true)]
            + people.map { Attendee(name: $0.0, email: $0.1) }
        try CalendarEvents.save(p, CalendarEvent(title: "Weekly", start: t, end: t, attendees: attendees))
    }

    /// `_two`: MEETING (Rico and Anna spoke) and OTHER (September: Rico spoke, Thomas invited from ACB).
    func two() throws {
        try pageMeeting(out)
        let second = try copy(OTHER, start: "2026-09-15T10:00:00+02:00")
        try name(MEETING, "SPEAKER_00", "Rico")
        try name(MEETING, "SPEAKER_01", "Anna")
        try name(OTHER, "SPEAKER_00", "Rico")
        try invite(second, [("Thomas Kraus", "thomas@acb.de")])
    }

    /// test_semantic.py's `meeting`: the window's meeting and two lines about the price.
    func semanticMeeting() throws -> RecordingPaths {
        let p = try pageMeeting(out)
        let more: [JSONValue] = [
            .object([("speaker", .string("SPEAKER_00")), ("start", .double(16.0)), ("end", .double(19.0)),
                     ("text", .string("Die Kosten für das Angebot sind noch zu hoch für den Kunden."))]),
            .object([("speaker", .string("SPEAKER_00")), ("start", .double(19.0)), ("end", .double(20.0)),
                     ("text", .string("Das müssen wir mit dem Einkauf klären, bevor wir zusagen."))]),
        ]
        try write(.array(read(p.transcriptJson).list + more), to: p.transcriptJson)
        return p
    }
}

@Suite struct SearchRoutesTests {
    // MARK: - test_search_api.py

    @Test func test_people_who_all_took_part() throws {
        let f = try Fixture()
        try f.two()
        #expect(ids(try f.search("Rico")) == [MEETING, OTHER])
        #expect(ids(try f.search("Rico and Anna")) == [MEETING])
        #expect(ids(try f.search("Anna and Thomas")) == [])
        #expect(ids(try f.search("Anna or Thomas")) == [MEETING, OTHER])
    }

    @Test func test_an_invitee_took_part_but_a_speaker_ranks_first() throws {
        let f = try Fixture()
        try f.two()
        #expect(ids(try f.search("Thomas")) == [OTHER])  // invited only
        try f.name(MEETING, "SPEAKER_00", "")  // Rico no longer speaks in MEETING …
        try f.invite(f.paths(), [("Rico Lanza", "rico@kloud.io")])  // … he is invited
        // MEETING is newer, but in OTHER Rico spoke ("Rico" there is "Rico Lanza" here).
        #expect(ids(try f.search("rico lanza")) == [OTHER, MEETING])
    }

    @Test func test_an_organization_took_part() throws {
        let f = try Fixture()
        try f.two()
        let page = try SearchAPI.page(f.app, "meetings with ACB people", userName: "Timo", today: TODAY)
        #expect(ids(page["results"]?.list ?? []) == [OTHER])
        #expect(page["understood"]?.list.compactMap { $0["kind"]?.stringValue } == ["org"])
    }

    @Test func test_a_project_and_a_time_range() throws {
        let f = try Fixture()
        try f.two()
        _ = try ProjectsAPI.setMeetingProject(f.app, id: MEETING, name: "ÖNW")
        _ = try ProjectsAPI.setMeetingProject(f.app, id: OTHER, project: ProjectStore(path: f.stores.projects).find("ÖNW"))
        #expect(ids(try f.search("ÖNW")) == [MEETING, OTHER])
        #expect(ids(try f.search("ÖNW last month")) == [OTHER])
        #expect(ids(try f.search("önw since 2026-10-01")) == [MEETING])
    }

    @Test func test_people_and_words_together() throws {
        let f = try Fixture()
        try f.two()
        let second = f.paths(OTHER)
        try write(read(second.transcriptJson).changing(1) { $0.with("text", .string("Welcome to the pricing talk.")) },
                  to: second.transcriptJson)
        let found = try f.search("with Rico about pricing")
        #expect(found.count == 1 && found[0]["id"] == .string(OTHER))
        #expect(PythonJSON.dumps(found[0]["hits"] ?? .null)
                == #"[{"start": 1.0, "speaker": "Rico", "text": "Welcome to the pricing talk."}]"#)
    }

    @Test func test_what_was_decided_shows_the_decision_first() throws {
        let f = try Fixture()
        try f.two()
        var found = try f.search("what did we decide about the offer")
        #expect(found.count == 2)
        #expect(PythonJSON.dumps(found[0]["notes_hits"] ?? .null) == #"[{"kind": "decision", "text": "Make an offer"}]"#)
        #expect(found[0]["hits"] == .array([]))  // the transcript is not where decisions are
        found = try f.search("offer")
        #expect(found.count == 2)
        #expect(found[0]["notes_hits"]?.list.compactMap { $0["kind"]?.stringValue } == ["decision", "step"])  // decisions, then next steps
        #expect(PythonJSON.dumps(found[0]["notes_hits"]?[1] ?? .null) == #"{"kind": "step", "text": "Send the offer", "owner": "Anna"}"#)
    }

    @Test func test_decisions_alone_list_the_meetings_decisions() throws {
        let f = try Fixture()
        try f.two()
        let first = f.paths()
        try write(read(first.notes).with("decisions", .array([])), to: first.notes)
        let found = try f.search("in:decisions")
        #expect(found.count == 1 && found[0]["id"] == .string(OTHER))
        #expect(PythonJSON.dumps(found[0]["notes_hits"] ?? .null) == #"[{"kind": "decision", "text": "Make an offer"}]"#)
    }

    @Test func test_lines_a_person_said() throws {
        let f = try Fixture()
        try f.two()
        var found = try f.search("where did Anna talk about salary")
        #expect(found.count == 1 && found[0]["id"] == .string(MEETING))
        #expect(found[0]["hits"]?.list.compactMap { $0["speaker"]?.stringValue } == ["Anna"])
        #expect(try f.search("where did Rico talk about salary") == [])  // Anna said it, not Rico
        found = try f.search("by:Anna")
        #expect(found.count == 1 && found[0]["hit_count"] == .int(1))  // all she said
    }

    @Test func test_reviewed_and_next_steps() throws {
        let f = try Fixture()
        try f.two()
        try ReviewAPI.markReviewed(f.app, id: OTHER, done: true)
        #expect(ids(try f.search("is:reviewed")) == [OTHER])
        #expect(ids(try f.search("is:unreviewed")) == [MEETING])
        let first = f.paths()
        try write(read(first.notes).with("next_steps", .array([])), to: first.notes)
        #expect(ids(try f.search("has:steps")) == [OTHER])
    }

    @Test func test_a_quoted_name_is_a_word() throws {
        let f = try Fixture()
        try f.two()
        #expect(ids(try f.search(#""Rico" salary"#)) == [MEETING, OTHER])  // said in both
        #expect(try f.search(#""Tom""#) == [])  // nobody says Tom
    }

    @Test func test_the_page_gets_what_was_understood_and_whether_meaning_can_help() throws {
        let f = try Fixture()
        try f.two()
        let page = try SearchAPI.page(f.app, "Rico last month salary", userName: "Timo", today: TODAY)
        #expect(PythonJSON.dumps(page["understood"] ?? .null) == PythonJSON.dumps(.array([
            .object([("kind", .string("person")), ("label", .string("Rico")), ("title", .string("Took part: named speaker or invited")),
                     ("span", .array([.int(0), .int(4)])), ("text", .string("Rico")), ("written", .bool(false))]),
            .object([("kind", .string("date")), ("label", .string("Last month")), ("title", .string("2026-09-01 to 2026-09-30")),
                     ("span", .array([.int(5), .int(15)])), ("text", .string("last month")), ("written", .bool(false))]),
        ])))
        #expect(page["words"] == .strings(["salary"]) && ids(page["results"]?.list ?? []) == [OTHER])
        #expect(page["meaning"] == .string("off"))  // no index yet in this folder
        #expect(try SearchAPI.page(f.app, "", userName: "Timo")["results"] == .array([]))
    }

    /// Python replaces `api.search_meaning`; here the meeting is indexed with the fake encoder, which records what it is
    /// asked.
    @Test func test_the_window_asks_over_http() throws {
        let asked = FakeEncoder.Asked()
        let s = try TestServer(userName: "Timo", routes: { _, app in
            app.background.makeSearcher = { Searcher(outputDir: $0.outputDir, encoderFactory: { FakeEncoder(asked: asked) }, timer: nil) }
        })
        defer { s.stop() }
        try pageMeeting(s.app.outputDir)
        try FileManager.default.copyItem(at: s.app.outputDir.appendingPathComponent(MEETING),
                                         to: s.app.outputDir.appendingPathComponent(OTHER))
        for (id, label, name) in [(MEETING, "SPEAKER_00", "Rico"), (MEETING, "SPEAKER_01", "Anna"), (OTHER, "SPEAKER_00", "Rico")] {
            _ = try PeopleAPI.nameSpeaker(s.app, id: id, label: label, name: name)
        }
        _ = try SearchIndex.indexStale(outputDir: s.app.outputDir, encoder: { FakeEncoder() })
        var r = s.get("/api/search?q=Rico%20and%20Anna")
        #expect(r.status == 200 && ids(r.json?["results"]?.list ?? []) == [MEETING])
        #expect(r.json?["understood"]?.list.compactMap { $0["label"]?.stringValue } == ["Rico", "Anna"])
        r = s.get("/api/search/meaning?q=offer")
        #expect(r.status == 200 && Set(ids(r.json?.list ?? [])) == [MEETING, OTHER] && asked.queries == ["offer"])
    }

    @Test func test_the_lines_of_a_meeting_are_made_readable_once_per_change() throws {
        let f = try Fixture()
        try f.two()
        _ = try f.search("salary")
        _ = try f.search("band")
        _ = try SearchAPI.meaning(f.app, "salary", userName: "Timo")  // the meaning request uses them too
        #expect(f.app.searchCaches.linesMade == 2)  // one per meeting
        let first = f.paths()
        try write(read(first.transcriptJson).changing(2) { $0.with("text", .string("Thanks Rico, the salary band is too low.")) },
                  to: first.transcriptJson)
        try touch(first.transcriptJson, later: 1)
        let found = try f.search("salary")
        #expect(f.app.searchCaches.linesMade == 3 && found.count == 2)
        #expect(found.first?["hits"]?[0]?["text"] == .string("Thanks Rico, the salary band is too low."))
    }

    @Test func test_the_window_learns_when_the_index_is_built() throws {
        let s = try TestServer(recording: BusyApp(indexing: .object([("indexing", .bool(true)), ("downloading", .int(1))])))
        defer { s.stop() }
        #expect(s.get("/api/search/status").json == .object([("indexing", .bool(true)), ("downloading", .bool(true))]))
        let none = try TestServer()  // no menu bar app
        defer { none.stop() }
        #expect(none.get("/api/search/status").json == .object([("indexing", .bool(false)), ("downloading", .bool(false))]))
    }

    /// At start the window's server makes every meeting readable for the search, after a delay, and never while a
    /// recording or processing runs.
    @Test func test_the_search_cache_is_warmed_in_the_background() throws {
        let f = try Fixture()
        try f.two()
        var states = [true, true, false, false, false, false], slept: [Double] = []  // busy at first: it waits
        try Background.warmSearchCache(f.app, busy: { states.isEmpty ? false : states.removeFirst() }, sleep: { slept.append($0) },
                                       delay: 20.0)
        #expect(Array(slept.prefix(3)) == [20.0, Background.WARM_RETRY_SECONDS, Background.WARM_RETRY_SECONDS])
        #expect(f.app.searchCaches.linesMade == 2)  // both meetings
        _ = try f.search("salary")
        #expect(f.app.searchCaches.linesMade == 2)  // the search found them ready
    }

    @Test func test_warming_stops_when_a_recording_starts_and_goes_on_after_it() throws {
        let f = try Fixture()
        try f.two()
        var states = [false, false, true, true, false, false, false, false], slept: [Double] = []  // a call starts after the first
        try Background.warmSearchCache(f.app, busy: { states.isEmpty ? false : states.removeFirst() }, sleep: { slept.append($0) },
                                       delay: 0.0)
        #expect(f.app.searchCaches.linesMade == 2 && slept.filter { $0 == Background.WARM_RETRY_SECONDS }.count == 1)
    }

    @Test func test_the_menu_bar_says_when_it_is_busy() throws {
        let f = try Fixture()
        #expect(!Background.busyRecording(f.app))  // no menu bar app, no daemon
        try FileManager.default.createDirectory(at: f.stores.daemonJson.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(.object([("state", .string("recording")), ("pid", .int(1))]), to: f.stores.daemonJson)
        #expect(Background.busyRecording(f.app))  // `palaver app` beside `palaver daemon`: its state file says
        try Data("{".utf8).write(to: f.stores.daemonJson)
        #expect(Background.busyRecording(f.app))  // not known: as if busy
        for busy in [true, false] {
            let g = try Fixture(recording: BusyApp(busy: busy))
            #expect(Background.busyRecording(g.app) == busy)
        }
    }

    @Test func test_the_server_warms_the_search_at_start() throws {
        let f = try Fixture()
        let held = Latch()
        defer { held.open() }
        ServeMain.started(f.app, log: nil, port: 0, url: nil, readyFD: nil, warmClock: { _ in held.wait(5) })
        #expect(f.app.background.warming != nil)
    }

    /// The warming thread exists before the ready line is written, and the line is written once. The ready pipe is
    /// filled first, so the server's write of the line blocks until the test drains it: whatever `started` does before
    /// that write is done while it waits, and nothing after it is.
    @Test func test_ready_is_written_once_after_warming_started() throws {
        let f = try Fixture()
        final class Waits: @unchecked Sendable {
            let lock = NSLock()
            var seconds: [Double] = []
        }
        let waits = Waits(), held = Latch(), done = Latch()
        defer { held.open() }
        var fds: [Int32] = [0, 0]
        precondition(pipe(&fds) == 0)
        defer { close(fds[0]) }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        // Fill the pipe: the line's write blocks until it is drained.
        let flags = fcntl(writeEnd, F_GETFL)
        _ = fcntl(writeEnd, F_SETFL, flags | O_NONBLOCK)
        let chunk = [UInt8](repeating: 0x2E, count: 4096)
        var filler = 0
        while true {
            let n = chunk.withUnsafeBytes { Darwin.write(writeEnd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            filler += n
        }
        _ = fcntl(writeEnd, F_SETFL, flags)
        Thread {
            ServeMain.started(f.app, log: nil, port: 0, url: nil, readyFD: writeEnd, warmClock: { s in
                waits.lock.withLock { waits.seconds.append(s) }
                held.wait(60)  // until the test ends (a shorter hold ran out under load and the warming went on)
            }, warmQoS: .userInitiated)  // background QoS starves for half a minute on a busy Mac
            done.open()
        }.start()
        #expect(until(2) { f.app.background.warming != nil })  // started while the line waits to be written
        #expect(!done.opened)  // still writing the line
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {  // until the server closed its end
            let n = buffer.withUnsafeMutableBytes { read(readEnd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        #expect(out.count == filler + 6 && String(decoding: out.suffix(6), as: UTF8.self) == "ready\n")  // once
        done.wait(5)
        #expect(until(10) { waits.lock.withLock { waits.seconds } == [Background.WARM_DELAY_SECONDS] })  // no sleeping: held
    }

    // MARK: - test_webapp.py

    @Test func test_search_finds_transcript_lines_and_notes() throws {
        let f = try Fixture()
        try pageMeeting(f.out)
        var found = try SearchAPI.search(f.app, "SALARY", userName: "Timo")
        #expect(found.count == 1 && found[0]["id"] == .string(MEETING) && found[0]["hits"]?[0]?["start"] == .double(13.0))
        found = try SearchAPI.search(f.app, "make an offer", userName: "Timo")
        #expect(found.count == 1 && found[0]["in_notes"] == .bool(true) && found[0]["hits"] == .array([]))
        #expect(try SearchAPI.search(f.app, "nothing like this", userName: "Timo") == [])
    }

    @Test func test_search_matches_words_from_their_start() throws {
        let f = try Fixture()
        let paths = try pageMeeting(f.out)
        let transcript = read(paths.transcriptJson).changing(1) { $0.with("text", .string("Lass uns den Wortvorrat prüfen.")) }
            .changing(2) { $0.with("text", .string("Das RTV-Projekt läuft gut.")) }
        try write(transcript, to: paths.transcriptJson)
        var found = try SearchAPI.search(f.app, "rtv", userName: "Timo")
        #expect(found.count == 1 && found[0]["hits"]?.list.compactMap { $0["text"]?.stringValue } == ["Das RTV-Projekt läuft gut."])  // not "Wortvorrat"
        #expect(try SearchAPI.search(f.app, "rojekt", userName: "Timo") == [])
        found = try SearchAPI.search(f.app, "projekt rtv", userName: "Timo")  // every word, any order
        #expect(found.count == 1 && found[0]["hit_count"] == .int(1))
        #expect(!(try SearchAPI.search(f.app, "rtv rico", userName: "Timo")).isEmpty)  // the words may be in different lines
    }

    @Test func test_search_ranks_title_and_notes_before_the_transcript() throws {
        let f = try Fixture()
        try pageMeeting(f.out)
        let second = try f.copy("2026-10-20T09-00-00", start: "2026-10-20T09:00:00+02:00")
        try write(read(second.notes).with("title", .string("Salary review")), to: second.notes)
        #expect(ids(try SearchAPI.search(f.app, "salary", userName: "Timo")) == ["2026-10-20T09-00-00", MEETING])
    }

    // MARK: - test_semantic.py, the window's halves

    @Test func test_search_by_meaning_in_the_window() throws {
        let f = try Fixture()
        _ = try f.semanticMeeting()
        try f.name(MEETING, "SPEAKER_00", "Mara")
        _ = try SearchIndex.indexStale(outputDir: f.out, encoder: { FakeEncoder() })
        f.app.background.modelFolder = { _ in f.dir }
        let searcher = Searcher(outputDir: f.out, encoderFactory: { FakeEncoder() }, timer: nil)
        var found = try SearchAPI.meaning(f.app, "where did Mara talk about pricing", userName: "Timo", searcher: searcher)
        #expect(found.count == 1 && found[0]["id"] == .string(MEETING))
        #expect(found.first?["meaning"]?.list.map { [$0["kind"], $0["speaker"], $0["start"]] }
                == [[.string("line"), .string("Mara"), .double(16.0)]])
        found = try SearchAPI.meaning(f.app, "pricing", userName: "Timo", searcher: searcher)
        let step = found.first?["meaning"]?.list.first { $0["kind"] == .string("step") }
        #expect(found.count == 1 && step?["owner"] == .string("Speaker 2"))  // names are put in when shown
        #expect(try SearchAPI.meaning(f.app, "where did Timo talk about pricing", userName: "Timo", searcher: searcher) == [])
        #expect(try SearchAPI.meaning(f.app, "pricing since 2026-11-01", userName: "Timo", searcher: searcher,
                                      today: PyDate(2026, 12, 1)) == [])
        #expect(try SearchAPI.page(f.app, "pricing", userName: "Timo")["meaning"] == .string("ready"))
    }

    /// The window's half (`api.search_meaning`); the `ready` half is SearchIndexTests'.
    @Test func test_search_by_meaning_can_be_switched_off() throws {
        let f = try Fixture()
        _ = try f.semanticMeeting()
        f.app.background.modelFolder = { _ in f.dir }
        _ = try SearchIndex.indexStale(outputDir: f.out, encoder: { FakeEncoder() })
        try SettingsFile.update([("search_meaning", .bool(false))], stores: f.stores)
        #expect(try SearchAPI.page(f.app, "pricing", userName: "Timo")["meaning"] == .string("off"))
        let searcher = Searcher(outputDir: f.out, encoderFactory: { FakeEncoder() }, timer: nil)
        #expect(try SearchAPI.meaning(f.app, "pricing", userName: "Timo", searcher: searcher) == [])
    }
}
