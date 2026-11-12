// daemon.json: the same keys, order and value shapes as the Python app's (fixtures written by the
// real Python Daemon: tools/make_daemon_json_fixture.py), taking over the Python app's queue, cut
// and ignored holds after the update, and the Swift-written fixture Python's readers are tested
// with (tests/test_daemon_json_fixtures.py).
import Foundation
import Testing
import PalaverCore
@testable import PalaverDaemon

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let pythonFixtures = repo.appendingPathComponent("tests/fixtures/python_daemon")
let swiftFixture = repo.appendingPathComponent("tests/fixtures/swift_daemon/daemon.json")

/// Python's daemon.json with its fictional root replaced by `root`.
func pythonState(_ name: String, root: URL) throws -> String {
    try String(contentsOf: pythonFixtures.appendingPathComponent(name), encoding: .utf8)
        .replacingOccurrences(of: "/tmp/palaver-fixture", with: root.path)
}

/// The kind of a value: what a reader can rely on.
func shape(_ v: JSONValue) -> String {
    switch v {
    case .null: return "null"
    case .bool: return "bool"
    case .int, .double: return "number"
    case .string: return "string"
    case .array: return "array"
    case .object: return "object"
    }
}

func keys(_ v: JSONValue?) -> [String] { if case .object(let f)? = v { return f.map(\.0) } else { return [] } }

/// Keys in the same order, and every value of the same shape where both have one (recursively).
func sameShape(_ a: JSONValue, _ b: JSONValue, path: String = "") -> [String] {
    var out: [String] = []
    if case .object(let fa) = a, case .object(let fb) = b {
        if fa.map(\.0) != fb.map(\.0) { out.append("\(path): keys \(fa.map(\.0)) != \(fb.map(\.0))") }
        for (k, va) in fa { if let vb = b[k] { out += sameShape(va, vb, path: path + "." + k) } }
    } else if case .array(let xa) = a, case .array(let xb) = b {
        if let x = xa.first, let y = xb.first { out += sameShape(x, y, path: path + "[0]") }
    } else if !a.isNull && !b.isNull && shape(a) != shape(b) {
        out.append("\(path): \(shape(a)) != \(shape(b))")
    }
    return out
}

/// A recording as the Python fixture has it: a Teams call with AirPods, an open audio problem and
/// a muted mic, while one meeting is transcribed and notes wait.
func pythonLikeRig(_ root: URL) throws -> Harness {
    let rec = root.appendingPathComponent("Recordings")
    mkdir(rec)
    let queued = ["2026-11-03T08-00-00", "2026-11-03T08-30-00"].map { rec.appendingPathComponent($0) }
    let notes = rec.appendingPathComponent("2026-11-02T16-00-00")
    for f in queued + [notes] { mkdir(f) }
    touch(notes.appendingPathComponent("transcript.md"))
    writeJSON(root.appendingPathComponent("state.json"),
              ["state": "stopped", "queued": queued.map(\.path), "notes_queued": [notes.path]])
    let h = try Harness(root, activity: { _ in .teams }) { deps, _ in
        deps.doneMarker = { "transcript.md" }
        deps.launchNotes = { _ in FakeWorker() }
        deps.ignored = { ["slack"] }
        deps.pid = 4242
    }
    h.launchProcessing = { _ in FakeWorker() }
    h.newSession = { trigger in
        let s = FakeSession(folder: rec.appendingPathComponent("2026-11-03T09-00-14"), duration: 400)
        s.trigger = trigger
        s.micDevice = "AirPods Pro"; s.micRate = 24000; s.micSource = "avcapture"
        s.systemDevice = "AirPods Pro"; s.systemRate = 48000; s.systemSource = "process-tap"
        s.problems = [RecordingProblem(id: 1, kind: "speed", track: "system", start: 6)]
        s.hints = [(kind: "silent", track: "mic")]
        return s
    }
    return h
}

extension DaemonTicksC {
    @Suite struct DaemonStateTests {

        /// Review focus 4: the update from the Python app takes over its queue, notes, cut and ignored holds.
        @Test func restoresPythonDaemonJson() async throws {
            let root = tempDir()
            let rec = root.appendingPathComponent("Recordings")
            for n in ["2026-11-03T08-00-00", "2026-11-03T08-30-00", "2026-11-02T16-00-00", "2026-11-03T09-00-14"] {
                mkdir(rec.appendingPathComponent(n))
            }
            touch(rec.appendingPathComponent("2026-11-02T16-00-00/transcript.md"))
            try pythonState("stopped.json", root: root).write(to: root.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
            var ignoredNow: [String] = []
            // Started 30 s after the quit (09:06:42), the Teams call still on.
            let h = try Harness(root, activity: { _ in .teams }, sessions: Sessions([nil]), start: 0) { deps, h in
                deps.wall = { WallTime.parse("2026-11-03T09:07:12+01:00")!.addingTimeInterval(h.clock) }
                deps.doneMarker = { "transcript.md" }
                deps.ignore = { ignoredNow.append($0) }
                deps.launchNotes = { _ in FakeWorker() }
            }
            #expect(h.daemon.queue == [rec.appendingPathComponent("2026-11-03T08-30-00").path])
            #expect(h.daemon.notesQueue == [rec.appendingPathComponent("2026-11-02T16-00-00").path])
            #expect(h.status()["cut"] == Cut(folders: [rec.appendingPathComponent("2026-11-03T09-00-14").path], trigger: "teams",
                                             at: "2026-11-03T09:06:42+01:00", since: "2026-11-03T09:00:04+01:00", seconds: 400).json)
            #expect(ignoredNow == ["slack"])
            let next = rec.appendingPathComponent("2026-11-03T09-07-16")
            h.newSession = { trigger in
                let s = FakeSession(folder: next, duration: 600)
                s.trigger = trigger
                return s
            }
            await h.run { $0 > 10 }
            // The call goes on as one meeting with the part the Python app recorded.
            #expect(parts(rec.appendingPathComponent("2026-11-03T09-00-14")) == [next.path])
            #expect(h.titles.contains("Recording continued"))
            #expect(h.status()["why"]?["since"] == .string("2026-11-03T09:00:04+01:00"))
            // The queued meeting is transcribed meanwhile (notes wait for the call to end).
            #expect(p(h.launched) == [rec.appendingPathComponent("2026-11-03T08-30-00").path])
        }

        @Test func aRecordingPythonStateIsACrashToRecover() async throws {
            // The Python app killed while recording (no shutdown): its recording.json comes back as a cut.
            let root = tempDir()
            let rec = root.appendingPathComponent("Recordings")
            mkdir(rec.appendingPathComponent("2026-11-03T09-00-14"))
            try pythonState("recording.json", root: root).write(to: root.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
            let h = try Harness(root, activity: noCall) { deps, h in
                deps.wall = { WallTime.parse("2026-11-03T09:07:00+01:00")!.addingTimeInterval(h.clock) }
            }
            #expect(h.status()["cut"]?["folders"] == .strings([rec.appendingPathComponent("2026-11-03T09-00-14").path]))
            #expect(h.status()["cut"]?["seconds"] == .double(396))  // 09:00:04 to 09:06:40
        }

        @Test func daemonJsonIsWrittenAtomicallyEveryTick() async throws {
            let h = try Harness(tempDir(), activity: noCall)
            await h.run { $0 > 4 }
            #expect(exists(h.statePath) && !exists(h.dir.appendingPathComponent("state.tmp")))
            let first = h.state()["updated"]
            await h.run { $0 > 8 }
            #expect(h.state()["updated"] != first)  // rewritten on each tick
            h.daemon.shutdown()
            #expect(h.state()["state"] == .string("stopped"))
            let text = try String(contentsOf: h.statePath, encoding: .utf8)
            #expect(text.hasPrefix("{\n  \"state\": \"stopped\",\n  \"auto\": true,"))  // json.dumps(indent=2)
        }

        @Test func wallTimesAreIsoformat() async {
            let d = WallTime.parse("2026-10-29T12:06:00+01:00")!
            #expect(WallTime.iso(d, TZ) == "2026-10-29T12:06:00+01:00")
            #expect(WallTime.iso(d.addingTimeInterval(0.25), TZ) == "2026-10-29T12:06:00.250000+01:00")
            #expect(WallTime.iso(d.addingTimeInterval(0.25), TZ, seconds: true) == "2026-10-29T12:06:00+01:00")
            #expect(WallTime.parse("2026-10-29T12:06:00.250000+01:00") == d.addingTimeInterval(0.25))
            #expect(WallTime.parse("2026-10-29T11:06:00Z") == d)
            #expect(WallTime.parse("2026-10-29T12:06:00", TZ) == d)  // naive: local time
            #expect(WallTime.parse("nonsense") == nil && WallTime.parse(nil) == nil)
            #expect(WallTime.iso(d, TimeZone(secondsFromGMT: -5 * 3600 - 1800)!) == "2026-10-29T05:36:00-05:30")
        }

        /// The fixture tests/test_daemon_json_fixtures.py reads through Python's readers (webapp/remote.py,
        /// doctor, `recording_into`, `read_status`, `busy_reason`). Fictional folders; written anew with
        /// PALAVER_UPDATE_FIXTURES=1.
        @Test func swiftDaemonJsonFixture() async throws {
            let root = tempDir()
            let rec = root.appendingPathComponent("Recordings")
            mkdir(rec)
            let queued = rec.appendingPathComponent("2026-11-04T08-00-00")
            mkdir(queued)
            writeJSON(root.appendingPathComponent("state.json"), ["state": "stopped", "queued": [queued.path]])
            let watchdog = FakeWatchdog()
            let h = try Harness(root, activity: noCall) { deps, h in
                deps.wall = { WallTime.parse("2026-11-04T09:00:00+01:00")!.addingTimeInterval(h.clock) }
                deps.pid = 4242
                deps.watchdog = watchdog
                deps.silence = { h.clock }  // silent since the start
                deps.launchIndex = { FakeWorker() }
            }
            h.launchProcessing = { _ in FakeWorker() }
            h.newSession = { trigger in
                let s = FakeSession(folder: rec.appendingPathComponent("2026-11-04T09-00-00"), duration: 700)
                s.trigger = trigger
                s.micDevice = "MacBook Pro Microphone"; s.micRate = 48000; s.micSource = "avcapture"
                s.systemDevice = "MacBook Pro Speakers"; s.systemRate = 48000; s.systemSource = "process-tap"
                s.problems = [RecordingProblem(id: 1, kind: "stalled", track: "system", start: 300, at: "2026-11-04T09:05:00+01:00")]
                return s
            }
            #expect(h.daemon.startManual())
            await h.run { $0 > 620 }
            let text = try String(contentsOf: h.statePath, encoding: .utf8).replacingOccurrences(of: root.path, with: "/Users/timo/Meetings") + "\n"
            if ProcessInfo.processInfo.environment["PALAVER_UPDATE_FIXTURES"] == "1" {
                try FileManager.default.createDirectory(at: swiftFixture.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: swiftFixture, atomically: true, encoding: .utf8)
            }
            #expect(text == (try? String(contentsOf: swiftFixture, encoding: .utf8)))
            let python = try #require(JSONValue.parse(Data(try pythonState("recording.json", root: root).utf8)))
            #expect(keys(h.state()) == keys(python))
            h.daemon.shutdown()
        }
    }
}

/// The memory watchdog's seam (Task 9), with the shape memory.Watchdog.status() has.
final class FakeWatchdog: MemoryWatching {
    var seen: [[DaemonWorker]] = []
    func watch(_ workers: [DaemonWorker], now: Double) -> [MemoryAction] { seen.append(workers); return [] }
    func status() -> JSONValue? {
        .object([("total", .int(1_610_612_736)), ("app", .int(268_435_456)),
                 ("workers", .array([.object([("kind", .string("process")), ("label", .string("Transcription")),
                                               ("meeting", .string("2026-11-04T08-00-00")), ("pid", .int(4343)),
                                               ("used", .int(1_342_177_280)), ("budget", .double(8.0)), ("state", .string("running"))])])),
                 ("budgets", .object([("live", .double(6.0)), ("stream", .double(3.5)), ("process", .double(8.0)),
                                      ("notes", .double(14.0)), ("index", .double(1.0))]))])
    }
    func costText() -> String? { "Palaver 1.5 GB" }
}
