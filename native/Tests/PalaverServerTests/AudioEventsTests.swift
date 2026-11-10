// A meeting's audio in byte ranges (api.py `AudioSource`, server.py `_audio`) and its calendar event choices
// (api.py `meeting_events`). Ports test_audio_mix_is_the_sum_and_any_range_matches, test_http_audio_ranges and
// test_http_meeting_events (its POST half is the event route's, Task 41); the other tests pin
// the range rules of server.py:816-841 and the choices of `_candidate_events` with a fake calendar.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"
private let SR = 16_000

/// A recordings folder with test_webapp.py's meeting in it, and the app over it (no HTTP).
private final class Fixture {
    let dir: URL
    let out: URL
    let paths: RecordingPaths
    let app: ServerApp

    init(calendar: CalendarProvider? = nil) throws {
        dir = tempFolder("audio")
        out = dir.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        paths = try pageMeeting(out)
        let stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                                home: dir.appendingPathComponent("home", isDirectory: true))
        app = ServerApp(outputDir: out, userName: "Timo", stores: stores, calendar: calendar)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func events() throws -> [JSONValue] { try EventsAPI.meetingEvents(app: app, id: MEETING) }
}

/// `np.clip(a + b, -32768, 32767)` as little-endian bytes, the shorter one ending in silence.
private func mixed(_ a: [Int16], _ b: [Int16]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 2 * max(a.count, b.count))
    for i in 0..<max(a.count, b.count) {
        let s = Int32(i < a.count ? a[i] : 0) + Int32(i < b.count ? b[i] : 0)
        let v = UInt16(bitPattern: Int16(max(-32768, min(32767, s))))
        out[2 * i] = UInt8(v & 0xFF)
        out[2 * i + 1] = UInt8(v >> 8)
    }
    return out
}

private func samples(_ n: Int, _ f: (Int) -> Int16) -> [Int16] { (0..<n).map(f) }

@Suite struct AudioEventsTests {
    // MARK: - the audio

    @Test func test_audio_mix_is_the_sum_and_any_range_matches() throws {
        let f = try Fixture()
        let src = try AudioSource(paths: f.paths, track: "mix")
        let whole = try src.read(range: 0..<src.size)
        #expect(whole.count == src.size)
        let expected = mixed(try Wav16.read(f.paths.micWav), try Wav16.read(f.paths.systemWav))
        #expect(Array(whole[44...]) == expected)
        // Odd, unaligned slices stitch back together.
        let cuts = [0, 7, 44, 45, 1001, 50_000, src.size]
        var stitched = Data()
        for (a, b) in zip(cuts, cuts.dropFirst()) { stitched.append(try src.read(range: a..<b)) }
        #expect(stitched == whole)
        let tmp = f.dir.appendingPathComponent("out.wav")
        try whole.write(to: tmp)
        #expect(try Wav16.info(tmp).frames == Wav16.info(f.paths.micWav).frames)
    }

    @Test func test_http_audio_ranges() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        var r = s.get("/api/meetings/\(MEETING)/audio", headers: [("Range", "bytes=0-99")])
        #expect(r.status == 206 && r.body.count == 100 && r.body.prefix(4) == Data("RIFF".utf8))
        let total = Int(r.header("Content-Range")!.split(separator: "/")[1])!
        #expect(total == 44 + 2 * SR * 20)
        r = s.get("/api/meetings/\(MEETING)/audio?track=system", headers: [("Range", "bytes=100-")])
        #expect(r.status == 206 && r.header("Content-Range")!.hasPrefix("bytes 100-"))
        #expect(s.get("/api/meetings/\(MEETING)/audio", headers: [("Range", "bytes=\(total)-")]).status == 416)
    }

    /// server.py:818-841, each branch: the headers, and bytes that are the whole file's.
    @Test func rangesAsPythonAnswersThem() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let paths = RecordingPaths(s.app.outputDir.appendingPathComponent(MEETING, isDirectory: true))
        let whole = try AudioSource(paths: paths, track: "mix").read(range: 0..<(44 + 2 * SR * 20))
        let size = whole.count, target = "/api/meetings/\(MEETING)/audio"
        func get(_ range: String?, method: String = "GET", track: String = "") -> Reply {
            s.get(target + track, headers: range.map { [("Range", $0)] } ?? [], method: method)
        }
        func expectRange(_ r: Reply, _ start: Int, _ end: Int, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(r.status == 206, sourceLocation: sourceLocation)
            #expect(r.header("Content-Range") == "bytes \(start)-\(end)/\(size)", sourceLocation: sourceLocation)
            #expect(r.header("Content-Length") == String(end - start + 1), sourceLocation: sourceLocation)
            #expect(r.body == whole.subdata(in: start..<end + 1), sourceLocation: sourceLocation)
        }
        let first = get(nil)  // no range: from the start, at most a slice (all of this short file)
        expectRange(first, 0, size - 1)
        #expect(first.headers.map(\.0) == ["Server", "Date", "Content-Type", "Accept-Ranges", "Content-Range", "Content-Length"])
        #expect(first.header("Content-Type") == "audio/wav" && first.header("Accept-Ranges") == "bytes")
        expectRange(get("bytes=-"), 0, size - 1)
        expectRange(get("  bytes=5-9 "), 5, 9)
        expectRange(get("bytes=1001-"), 1001, size - 1)
        expectRange(get("bytes=-10"), size - 10, size - 1)  // the last 10 bytes
        expectRange(get("bytes=-99999999"), 0, size - 1)
        expectRange(get("bytes=3-99999999999999999999999"), 3, size - 1)
        for notOne in ["bytes=0-1,5-6", "bytes=a-b", "items=0-1", "bytes=0", "bytes=-1-"] {
            expectRange(get(notOne), 0, size - 1)  // not one range: as without
        }
        let backwards = get("bytes=10-5")
        #expect(backwards.status == 206 && backwards.header("Content-Range") == "bytes 10-5/\(size)")
        #expect(backwards.header("Content-Length") == "-4" && backwards.body.isEmpty)
        for past in ["bytes=\(size)-", "bytes=-0", "bytes=99999999999999999999999-1"] {
            let r = get(past)
            #expect(r.status == 416 && r.header("Content-Range") == "bytes */\(size)" && r.body.isEmpty)
            #expect(r.headers.map(\.0) == ["Server", "Date", "Content-Range"])
        }
        let head = get("bytes=5-9", method: "HEAD")
        #expect(head.status == 206 && head.header("Content-Length") == "5" && head.body.isEmpty)
        #expect(head.header("Content-Range") == "bytes 5-9/\(size)")
        // The track: blank is the mix; only "mix" and "system" are tracks.
        expectRange(get("bytes=0-99", track: "?track="), 0, 99)
        let system = get(nil, track: "?track=system&track=mix")
        #expect(system.status == 206 && system.body != whole && system.body.count == size)
        for bad in ["mic", "..%2Fmeta.json", "MIX"] {
            let r = get(nil, track: "?track=\(bad)")
            #expect(r.status == 404 && r.error == "not found: \(PyURL.unquote(bad))")
        }
        #expect(s.get("/api/meetings/..%2F..%2Fetc/audio").error == "not found: ..%2F..%2Fetc")
        #expect(s.get("/api/meetings/2026-01-01T00-00-00/audio").status == 404)
    }

    /// A range past a slice: at most a slice from its start, and the last N bytes in full (read a slice at a time).
    @Test func aLongTrackIsAnsweredASliceAtATime() throws {
        let f = try Fixture()
        let n = SR * 70  // 2.24 MB of samples: more than a slice
        let mic = samples(n) { Int16(truncatingIfNeeded: $0 &* 7919) }, system = samples(n - 5) { Int16(truncatingIfNeeded: $0 &* 104_729) }
        try Wav16.write(mic, rate: SR, to: f.paths.micWav)
        try Wav16.write(system, rate: SR, to: f.paths.systemWav)
        let src = try AudioSource(paths: f.paths, track: "mix")
        #expect(src.size == 44 + 2 * n)
        let whole = try src.read(range: 0..<src.size)
        #expect(Array(whole[44...]) == mixed(mic, system))  // clipped where the sum overflows int16
        #expect(try src.read(range: 3..<src.size - 1) == whole.subdata(in: 3..<src.size - 1))

        let s = try TestServer(meetings: { out in
            let paths = try pageMeeting(out)
            try Wav16.write(mic, rate: SR, to: paths.micWav)
            try Wav16.write(system, rate: SR, to: paths.systemWav)
        })
        defer { s.stop() }
        let slice = AudioSource.AUDIO_SLICE_BYTES
        let from = s.get("/api/meetings/\(MEETING)/audio", headers: [("Range", "bytes=1-")])
        #expect(from.header("Content-Range") == "bytes 1-\(slice)/\(src.size)" && from.body == whole.subdata(in: 1..<slice + 1))
        let tail = s.get("/api/meetings/\(MEETING)/audio", headers: [("Range", "bytes=-\(slice + 3)")])
        #expect(tail.body.count == slice + 3 && tail.body == whole.subdata(in: src.size - slice - 3..<src.size))
    }

    /// The mix is the cleaned microphone, else the raw one, with the system track; either alone where only it is there.
    @Test func theMixTakesTheTracksThatAreThere() throws {
        let f = try Fixture()
        let mic = try Wav16.read(f.paths.micWav), system = try Wav16.read(f.paths.systemWav)
        let raw = samples(SR) { Int16($0 % 100) }
        try Wav16.write(raw, rate: SR, to: f.paths.micRawWav)
        func mix() throws -> [UInt8] {
            let src = try AudioSource(paths: f.paths, track: "mix")
            return Array(try src.read(range: 0..<src.size)[44...])
        }
        #expect(try mix() == mixed(mic, system))
        try FileManager.default.removeItem(at: f.paths.micWav)
        #expect(try mix() == mixed(raw, system))
        try FileManager.default.removeItem(at: f.paths.systemWav)
        #expect(try mix() == mixed(raw, []))
        #expect(throws: NotFound.self) { try AudioSource(paths: f.paths, track: "system") }
        try FileManager.default.removeItem(at: f.paths.micRawWav)
        #expect(throws: NotFound.self) { try AudioSource(paths: f.paths, track: "mix") }
    }

    /// A track still recorded: the size is the one seen at the start; bytes it grew by are read, bytes gone read as
    /// silence; nothing fails.
    @Test func aTrackThatGrowsOrShrinksIsReadAsItIsNow() throws {
        let f = try Fixture()
        try FileManager.default.removeItem(at: f.paths.micWav)
        let first = samples(1000) { Int16($0) }
        try Wav16.write(first, rate: SR, to: f.paths.systemWav)
        let src = try AudioSource(paths: f.paths, track: "system")
        #expect(src.size == 44 + 2000)
        let h = try FileHandle(forWritingTo: f.paths.systemWav)
        try h.seekToEnd()
        try h.write(contentsOf: Data(repeating: 1, count: 400))  // more written, the header not yet patched
        try h.close()
        #expect(try src.read(range: 44..<src.size) == Data(mixed(first, [])))
        #expect(truncate(f.paths.systemWav.path, 44 + 600) == 0)  // cut short
        let now = try src.read(range: 0..<src.size)
        #expect(now.count == src.size && Array(now[44..<644]) == mixed(Array(first[0..<300]), []))
        #expect(now[644...].allSatisfy { $0 == 0 })
    }

    // MARK: - the event choices

    @Test func test_http_meeting_events() throws {
        let s = try TestServer(meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let r = s.get("/api/meetings/\(MEETING)/events")
        #expect(r.status == 200 && r.json == .array([]))  // no calendar connected in tests
        #expect(s.get("/api/meetings/nope/events").error == "not found: nope")
        let chosen = s.post("/api/meetings/\(MEETING)/event", .object([("key", .null)]))
        #expect(chosen.status == 200 && chosen.json?["calendar"] == .null && chosen.json?["undo"]?.stringValue?.count == 32)
    }

    /// The read half of test_choosing_the_calendar_event_of_a_meeting and test_a_rule_shows_in_the_picker_…: the
    /// calendar's events around the recording, the stored one marked current, by start and title.
    @Test func theChoicesAreTheCalendarsAroundTheRecordingAndTheStoredOne() throws {
        let start = try PyDateTime.parse("2026-10-27T16:03:07+01:00")
        func event(_ title: String, _ minutes: Double, _ uid: String, from: Double = 0, allDay: Bool = false) -> CalendarEvent {
            CalendarEvent(title: title, start: try! start.adding(seconds: from * 60), end: try! start.adding(seconds: (from + minutes) * 60),
                          attendees: [Attendee(name: "Anna", email: "anna@x.com")], allDay: allDay, uid: uid, series: true)
        }
        let planned = event("Northwind Zwischenstand", 60, "u1"), adhoc = event("Ad hoc", 10, "u2")
        var window: (Date, Date)?
        let f = try Fixture(calendar: { s, e in
            window = (s, e)
            return [planned, adhoc, event("Later", 30, "u3", from: 21), event("Holiday", 1440, "u4", allDay: true)]
        })
        try CalendarEvents.save(f.paths, planned)
        let found = try f.events()
        #expect(found.map { [$0["title"]!, $0["current"]!] } == [[.string("Ad hoc"), .bool(false)],
                                                                 [.string("Northwind Zwischenstand"), .bool(true)]])
        #expect(window.map { [$0.0, $0.1] } == [try! start.adding(seconds: -45 * 60).date, try! start.adding(seconds: 20 + 45 * 60).date])
        #expect(found[0] == .object([("key", .string("u2|2026-10-27")), ("title", .string("Ad hoc")),
                                     ("start", .string("2026-10-27T16:03:07+01:00")), ("end", .string("2026-10-27T16:13:07+01:00")),
                                     ("invited", .int(1)), ("current", .bool(false)), ("rejected", .int(0)), ("rule", .null)]))

        let evidence = Evidence(path: f.app.stores.attributions, outputDir: f.out)
        evidence.rejectEvent(planned, "x1")
        evidence.rejectEvent(planned, "x2")
        try evidence.save()
        let ruled = try f.events()[1]
        #expect(ruled["rejected"] == .int(2))
        #expect(ruled["rule"] == .object([("series", .string("u1")),
                                          ("text", .string("Not linked by time any more: Northwind Zwischenstand — rejected 2×"))]))
    }

    /// Without a calendar (or one that fails), the stored event, or the ones asked about (calendar.json holds one or
    /// the other); one without an id is "stored|<i>"; an event already among them is not added twice.
    @Test func withoutACalendarTheStoredOrTheAskedEvents() throws {
        let start = try PyDateTime.parse("2026-10-27T16:00:00+01:00")
        let plain = CalendarEvent(title: "Contoso", start: start, end: try! start.adding(seconds: 3600))
        let other = CalendarEvent(title: "Ad hoc", start: try! start.adding(seconds: 60), end: try! start.adding(seconds: 600), uid: "u2")
        struct Down: Error {}
        let f = try Fixture(calendar: { _, _ in throw Down() })
        try CalendarEvents.save(f.paths, other)
        var found = try f.events()
        #expect(found.map { $0["key"] } == [.string("u2|2026-10-27")] && found[0]["current"] == .bool(true))
        try CalendarEvents.ask(f.paths, [plain, other, plain, other])
        found = try f.events()
        #expect(found.map { $0["key"] } == [.string("stored|0"), .string("u2|2026-10-27")])
        #expect(found.map { $0["current"] } == [.bool(false), .bool(false)])
        try FileManager.default.removeItem(at: f.paths.meta)
        #expect(throws: (any Error).self) { try f.events() }  // no start: as Python's KeyError, a 500
    }
}
