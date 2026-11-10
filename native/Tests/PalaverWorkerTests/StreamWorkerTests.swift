// The realtime stream (tests/test_stream.py): scripted engines, no model; the recording grown by the test as the
// recorder grows its .part files.
import Darwin
import Foundation
import PalaverCore
@testable import PalaverDomain
@testable import PalaverWorker
import Testing

private let SR = 16_000
private let LOUD: Int16 = 3000  // about -21 dBFS
private let SCHEMA: Set<String> = ["until", "system", "mic", "draft", "questions", "speaking", "updated_at"]

/// `add` returns the next preset (settled, draft); `flush` the preset rest. Remembers how many samples each `add` got.
private final class ScriptedEngine: StreamEngine {
    private var calls: [([Word], [Word])]
    private var rest: [Word]
    var fed: [Int] = []

    init(_ calls: ([Word], [Word])..., flush: [Word] = []) {
        self.calls = calls
        rest = flush
    }

    func add(_ audio: [Float]) async throws -> (settled: [Word], draft: [Word]) {
        fed.append(audio.count)
        return calls.isEmpty ? ([], []) : calls.removeFirst()
    }

    func flush() -> [Word] {
        defer { rest = [] }
        return rest
    }

    func startAt(_ seconds: Double) {}
}

/// Remembers where it was told it starts and what it was fed.
private final class OffsetEngine: StreamEngine {
    var start: Double?
    var fed = 0
    func startAt(_ seconds: Double) { start = seconds }
    func add(_ audio: [Float]) async throws -> (settled: [Word], draft: [Word]) {
        fed += audio.count
        let end = (start ?? 0) + Double(fed) / Double(SR)
        return ([w("spät", end - 1.0, end - 0.5)], [])
    }
    func flush() -> [Word] { [] }
}

/// The recorder's .part files in a recording folder.
private struct Recording {
    let paths: RecordingPaths

    init(_ folder: URL) {
        paths = RecordingPaths(folder)
        appendPart(partURL(paths.systemWav), [])
        appendPart(partURL(paths.micRawWav), [])
    }

    func add(_ seconds: Double, system: Int16 = 0, mic: Int16 = 0, only: String? = nil) {
        let n = Int(seconds * Double(SR))
        if only == nil || only == "system" { appendPart(partURL(paths.systemWav), [Int16](repeating: system, count: n)) }
        if only == nil || only == "mic" { appendPart(partURL(paths.micRawWav), [Int16](repeating: mic, count: n)) }
    }
}

private final class Clock: @unchecked Sendable {
    var now: Double
    init(_ now: Double = 1000) { self.now = now }
}

private func w(_ text: String, _ start: Double, _ end: Double) -> Word { Word(text: text, start: start, end: end) }

private func texts(_ segments: JSONValue?) -> [String] { (segments?.arrayValue ?? []).compactMap { $0["text"]?.stringValue } }

private func state(_ processor: RealtimeProcessor, _ paths: RecordingPaths) throws -> JSONValue {
    try processor.write()
    return try #require(readJSON(paths.stream))
}

private func processor(_ rec: Recording, system: StreamEngine = ScriptedEngine(), mic: StreamEngine = ScriptedEngine(),
                       clock: Clock = Clock()) -> RealtimeProcessor {
    RealtimeProcessor(paths: rec.paths, systemEngine: system, micEngine: mic, clock: { clock.now })
}

/// step() grows nothing unless told; counts calls.
private final class FakeProcessor: StreamProcessing {
    var steps = 0, finished = 0, writes = 0
    let onStep: ((Int) -> Bool)?
    init(_ onStep: ((Int) -> Bool)? = nil) { self.onStep = onStep }
    func step() async throws -> Bool {
        steps += 1
        return onStep?(steps) ?? false
    }
    func write() throws { writes += 1 }
    func finish() async throws { finished += 1 }
}

private struct Stop: Error {}

@Suite struct StreamWorkerTests {
    @Test func test_sentences_close_at_gaps_and_punctuation() async throws {
        let t = Temp(); defer { t.remove() }
        let rec = Recording(t.url)
        let clock = Clock(100)
        let system = ScriptedEngine(([w("Hallo", 0.1, 0.4), w("zusammen.", 0.5, 0.9)], []), ([], []),
                                    ([w("Wie", 2.4, 2.6), w("geht's", 2.7, 2.9)], []))
        let p = processor(rec, system: system, clock: clock)
        rec.add(1)
        _ = try await p.step()
        var s = try state(p, rec.paths)
        #expect(texts(s["system"]) == ["Hallo zusammen."])  // the full stop closes it
        #expect(s["system"]?.arrayValue?[0]["settled_at"] == .double(100))
        for _ in 0..<2 {
            clock.now += 1
            rec.add(1)
            _ = try await p.step()
        }
        #expect(texts(try state(p, rec.paths)["system"]) == ["Hallo zusammen."])  // still open
        for _ in 0..<2 {
            clock.now += 1
            rec.add(1)
            _ = try await p.step()
        }
        s = try state(p, rec.paths)
        #expect(texts(s["system"]) == ["Hallo zusammen.", "Wie geht's"])  // a second of quiet
        let second = s["system"]?.arrayValue?[1]
        #expect(second?["settled_at"] == .double(102))  // when "geht's" settled
        #expect(second?["start"] == .double(2.4) && second?["end"] == .double(2.9))
    }

    @Test func test_settled_words_split_at_a_gap_and_at_max_sentence() async throws {
        let t = Temp(); defer { t.remove() }
        let rec = Recording(t.url)
        var words = [w("ja", 0.1, 0.3), w("genau", 1.5, 1.8)]  // 1.2 s apart
        words += (0..<40).map { w("w\($0)", 2.0 + Double($0) * 0.5, 2.3 + Double($0) * 0.5) }  // 20 s, no pause
        let p = processor(rec, system: ScriptedEngine((words, [])))
        rec.add(25)
        _ = try await p.step()
        let sentences = try state(p, rec.paths)["system"]?.arrayValue ?? []
        #expect(texts(.array(sentences)).first == "ja")
        #expect(sentences[1]["text"]?.stringValue?.hasPrefix("genau w0") == true)
        #expect(sentences.allSatisfy { ($0["end"]?.doubleValue ?? 0) - ($0["start"]?.doubleValue ?? 0) <= StreamWorker.MAX_SENTENCE })
        #expect(texts(.array(sentences)).map { $0.split(separator: " ").count }.reduce(0, +) == 42)  // the rest closed after 3 s of quiet
    }

    @Test func test_question_from_the_other_side_is_listed() async throws {
        let t = Temp(); defer { t.remove() }
        let rec = Recording(t.url)
        let p = processor(rec, system: ScriptedEngine(([w("Was", 0.1, 0.3), w("kostet", 0.4, 0.6), w("das?", 0.7, 0.9)], [])),
                          mic: ScriptedEngine(([w("Kommt", 3.1, 3.3), w("er?", 3.4, 3.6)], [])))
        rec.add(5)
        _ = try await p.step()
        let s = try state(p, rec.paths)
        #expect(s["questions"] == .array([.object([("start", .double(0.1)), ("end", .double(0.9)), ("text", .string("Was kostet das?"))])]))
        #expect(texts(s["mic"]) == ["Kommt er?"])
    }

    @Test(arguments: [(["Das", "ist", "ein", "Test."], [String]()),
                      (["Ich", "sehe", "das", "anders."], ["Ich sehe das anders."])])
    func test_mic_sentence_that_echoes_remote_is_dropped(_ mine: [String], _ kept: [String]) async throws {
        let t = Temp(); defer { t.remove() }
        let rec = Recording(t.url)
        let times = [(0.1, 0.25), (0.3, 0.4), (0.45, 0.55), (0.6, 0.75)]
        let remote = zip(["Das", "ist", "ein", "Test."], times).map { w($0, $1.0, $1.1) }
        let heard = zip(mine, times).map { w($0, $1.0 + 0.2, $1.1 + 0.2) }
        let p = processor(rec, system: ScriptedEngine((remote, [])), mic: ScriptedEngine((heard, [])))
        rec.add(1)
        _ = try await p.step()
        #expect(try state(p, rec.paths)["mic"] == .array([]))  // waits for the system track past 1.45 s
        rec.add(1)
        _ = try await p.step()  // same clock: decided because the system track is fed to 2.0 s
        let s = try state(p, rec.paths)
        #expect(texts(s["system"]) == ["Das ist ein Test."])
        #expect(texts(s["mic"]) == kept)
    }

    @Test func test_mic_sentence_waits_for_system_then_times_out() async throws {
        let t = Temp(); defer { t.remove() }
        let rec = Recording(t.url)
        let clock = Clock()
        let p = processor(rec, mic: ScriptedEngine(([w("Ich", 0.1, 0.3), w("bin", 0.4, 0.6), w("hier.", 0.7, 0.9)], [])), clock: clock)
        rec.add(1, only: "mic")
        _ = try await p.step()
        clock.now += StreamWorker.ECHO_WAIT_SECONDS - 0.5
        rec.add(1, only: "mic")
        _ = try await p.step()
        #expect(try state(p, rec.paths)["mic"] == .array([]))
        clock.now += 0.5
        _ = try await p.step()
        let s = try state(p, rec.paths)
        #expect(texts(s["mic"]) == ["Ich bin hier."])
        #expect(s["mic"]?.arrayValue?[0]["settled_at"] == .double(1000))
        #expect(s["mic"]?.arrayValue?[0]["published_at"] == .double(1000 + StreamWorker.ECHO_WAIT_SECONDS))  // the echo wait counts
    }

    @Test func test_open_settled_words_show_in_the_draft() async throws {
        // Settled words of a sentence that has neither ended nor paused are in no closed sentence: they show with
        // the draft.
        let t = Temp(); defer { t.remove() }
        let rec = Recording(t.url)
        let p = processor(rec, system: ScriptedEngine(([w("wir", 0.1, 0.3), w("nehmen", 0.4, 0.7)], [w("das", 0.8, 0.95)])),
                          mic: ScriptedEngine(([w("also", 0.2, 0.5), w("gut", 0.6, 0.8)], [])))
        rec.add(1)
        _ = try await p.step()
        let s = try state(p, rec.paths)
        #expect(s["system"] == .array([]) && s["mic"] == .array([]))
        #expect(s["draft"] == .object([("system", .string("wir nehmen das")), ("mic", .string("also gut"))]))
    }

    @Test func test_a_stalled_track_settles_its_draft_after_max_age() async throws {
        // The tap writes nothing in a silence: the last sentence before a pause settles by the clock, without
        // waiting for audio to resume.
        let t = Temp(); defer { t.remove() }
        let rec = Recording(t.url)
        let clock = Clock()
        let system = ScriptedEngine(([w("Was", 0.1, 0.3), w("kostet", 0.4, 0.6)], [w("das?", 0.7, 0.9)]), flush: [w("das?", 0.7, 0.9)])
        let p = processor(rec, system: system, clock: clock)
        rec.add(1)
        _ = try await p.step()
        #expect(try state(p, rec.paths)["questions"] == .array([]))
        for _ in 0..<2 {  // the system track stalls; the mic goes on
            clock.now += WindowEngine.MAX_AGE / 2 - 0.1
            rec.add(1, only: "mic")
            _ = try await p.step()
        }
        #expect(try state(p, rec.paths)["questions"] == .array([]))
        clock.now += 0.2
        _ = try await p.step()
        let s = try state(p, rec.paths)
        #expect(s["questions"] == .array([.object([("start", .double(0.1)), ("end", .double(0.9)), ("text", .string("Was kostet das?"))])]))
        #expect(texts(s["system"]) == ["Was kostet das?"] && s["draft"]?["system"] == .string(""))
    }

    @Test func test_speaking_flags_from_levels() async throws {
        let t = Temp(); defer { t.remove() }
        let rec = Recording(t.url)
        let p = processor(rec)
        func speaking() throws -> JSONValue? { try state(p, rec.paths)["speaking"] }
        rec.add(1, system: LOUD, mic: LOUD)
        _ = try await p.step()
        #expect(try speaking() == .object([("others", .bool(true)), ("me", .bool(false))]))  // doubletalk
        rec.add(1, system: 0, mic: LOUD)
        _ = try await p.step()
        #expect(try speaking() == .object([("others", .bool(false)), ("me", .bool(true))]))
        rec.add(1, system: 0, mic: 10)  // about -70 dBFS: room noise
        _ = try await p.step()
        #expect(try speaking() == .object([("others", .bool(false)), ("me", .bool(false))]))
    }

    @Test func test_speaking_is_judged_at_the_same_moment_when_a_track_stalls() async throws {
        let t = Temp(); defer { t.remove() }
        let rec = Recording(t.url)
        let p = processor(rec)
        rec.add(1, system: LOUD, mic: 0)
        _ = try await p.step()
        #expect(try state(p, rec.paths)["speaking"] == .object([("others", .bool(true)), ("me", .bool(false))]))
        rec.add(1, mic: LOUD, only: "mic")  // the system track stops growing: the others went quiet
        _ = try await p.step()
        #expect(try state(p, rec.paths)["speaking"] == .object([("others", .bool(false)), ("me", .bool(true))]))
    }

    @Test func test_engines_get_half_a_second_at_least() async throws {
        let t = Temp(); defer { t.remove() }
        let rec = Recording(t.url)
        let system = ScriptedEngine(), mic = ScriptedEngine()
        let p = processor(rec, system: system, mic: mic)
        rec.add(0.3)
        #expect(try await p.step())  // new samples, but too few to feed
        #expect(system.fed.isEmpty && mic.fed.isEmpty)
        #expect(try await !p.step())
        rec.add(0.3)
        _ = try await p.step()
        #expect(system.fed == [Int(0.6 * Double(SR))] && mic.fed == [Int(0.6 * Double(SR))])
        rec.add(0.2)
        _ = try await p.step()
        try await p.finish()
        #expect(system.fed == [Int(0.6 * Double(SR)), Int(0.2 * Double(SR))])  // finish feeds the rest
        #expect(readJSON(rec.paths.stream)?["until"] == .double(0.8))
    }

    @Test func test_finish_settles_the_draft() async throws {
        let t = Temp(); defer { t.remove() }
        let rec = Recording(t.url)
        let draft = [w("und", 0.2, 0.4), w("dann", 0.5, 0.8)]
        let p = processor(rec, mic: ScriptedEngine(([], draft), flush: draft))
        rec.add(1)
        _ = try await p.step()
        #expect(try state(p, rec.paths)["draft"] == .object([("system", .string("")), ("mic", .string("und dann"))]))
        try await p.finish()
        let s = try #require(readJSON(rec.paths.stream))
        #expect(texts(s["mic"]).last?.contains("und dann") == true)
        #expect(s["draft"] == .object([("system", .string("")), ("mic", .string(""))]))
    }

    @Test func test_stream_json_is_written_atomically() async throws {
        let t = Temp(); defer { t.remove() }
        let rec = Recording(t.url)
        let p = processor(rec, system: ScriptedEngine(([w("Gut.", 0.1, 0.3)], [])), mic: ScriptedEngine(([w("Ja.", 0.1, 0.3)], [])),
                          clock: Clock(500))
        rec.add(1)
        _ = try await p.step()
        try p.write()
        let s = try #require(readJSON(rec.paths.stream))
        guard case .object(let fields) = s else { Issue.record("not an object"); return }
        #expect(Set(fields.map(\.0)) == SCHEMA)
        // System sentences leave their words out (R6); the mic keeps them for the bench.
        #expect(s["system"] == .array([.object([("start", .double(0.1)), ("end", .double(0.3)), ("text", .string("Gut.")),
                                                ("speaker", .null), ("settled_at", .double(500)), ("published_at", .double(500))])]))
        #expect(s["mic"] == .array([.object([("start", .double(0.1)), ("end", .double(0.3)), ("text", .string("Ja.")),
                                             ("speaker", .null), ("settled_at", .double(500)), ("published_at", .double(500)),
                                             ("words", .array([.object([("text", .string("Ja.")), ("start", .double(0.1)),
                                                                        ("end", .double(0.3))])]))])]))
        #expect(s["until"] == .double(1.0) && s["updated_at"] == .double(500))
        let left = try FileManager.default.contentsOfDirectory(atPath: t.url.path).filter { $0.hasSuffix(".tmp") }
        #expect(left.isEmpty)
        #expect(rec.paths.stream == t.url.appendingPathComponent("stream.json"))
        #expect(rec.paths.streamPid == t.url.appendingPathComponent("stream.pid"))
    }

    @Test func test_run_stream_finishes_when_recording_finishes() async throws {
        let t = Temp(); defer { t.remove() }
        let rec = Recording(t.url)
        rec.add(1)
        finalizePart(rec.paths.systemWav)  // the recorder renamed its .part files
        finalizePart(rec.paths.micRawWav)
        let clock = Clock(0)
        let p = FakeProcessor { n in
            if n == 3 { t.write("meta.json", "{}") }
            return true
        }
        #expect(try await StreamWorker.run(p, paths: rec.paths, clock: { clock.now }, sleep: { clock.now += $0 }))
        #expect(p.finished == 1)
        #expect(p.steps == 3)
    }

    @Test func test_run_stream_idles_through_silence() async throws {
        let t = Temp(); defer { t.remove() }
        let rec = Recording(t.url)
        let clock = Clock(0)
        let p = FakeProcessor()
        await #expect(throws: Stop.self) {
            try await StreamWorker.run(p, paths: rec.paths, stall: 120, clock: { clock.now }, sleep: { s in
                clock.now += s
                if clock.now >= 60 { throw Stop() }  // stop the test's loop
            })
        }
        #expect(p.steps >= 59)
        #expect(p.finished == 0)
    }

    @Test func test_run_stream_gives_up_on_a_dead_recorder() async throws {
        let t = Temp(); defer { t.remove() }
        let rec = Recording(t.url)
        let clock = Clock(0)
        let p = FakeProcessor()
        #expect(try await !StreamWorker.run(p, paths: rec.paths, stall: 30, clock: { clock.now }, sleep: { clock.now += $0 }))
        #expect(p.finished == 0)
        #expect(clock.now > 30)
    }

    @Test func test_a_late_stream_reads_only_the_last_window() async throws {
        let t = Temp(); defer { t.remove() }
        let rec = Recording(t.url)
        rec.add(60, system: LOUD, mic: LOUD)
        let system = OffsetEngine(), mic = OffsetEngine()
        let p = processor(rec, system: system, mic: mic)
        _ = try await p.step()
        #expect(system.start == 50.0)
        #expect(system.fed == 10 * SR)  // not the 60 s backlog
        #expect(try state(p, rec.paths)["until"] == .double(60))
        rec.add(1, system: LOUD, mic: LOUD)
        _ = try await p.step()
        #expect(system.fed == 11 * SR)
        try await p.finish()
        let s = try #require(readJSON(rec.paths.stream))
        #expect((s["system"]?.arrayValue?.first?["start"]?.doubleValue ?? 0) > 50)  // track time, not window time
    }

    @Test func test_run_stream_stops_above_the_memory_cap() async throws {
        // Every MEMORY_CHECK_STEPS steps the stream reads its memory; above the cap it logs and ends without
        // finishing or touching the recording.
        let t = Temp(); defer { t.remove() }
        let rec = Recording(t.url)
        rec.add(1)
        let clock = Clock(0)
        let p = FakeProcessor { _ in true }
        var readings = [StreamWorker.STREAM_MEMORY_LIMIT, StreamWorker.STREAM_MEMORY_LIMIT + 1]  // at the cap is fine; above is not
        let parts = [partURL(rec.paths.systemWav), partURL(rec.paths.micRawWav)].map { try! Data(contentsOf: $0) }
        let log = SessionLog(url: rec.paths.sessionLog, logger: "palaver")
        #expect(try await !StreamWorker.run(p, paths: rec.paths, clock: { clock.now }, sleep: { clock.now += $0 },
                                      memory: { readings.removeFirst() }, log: log))
        #expect(readings.isEmpty)
        #expect(p.steps == 2 * StreamWorker.MEMORY_CHECK_STEPS && p.finished == 0)
        #expect([partURL(rec.paths.systemWav), partURL(rec.paths.micRawWav)].map { try! Data(contentsOf: $0) } == parts)
        let capped = events(rec.paths).filter { $0 == "stream_memory_cap" }
        #expect(capped.count == 1)
        let line = try #require(t.lines("session.log").first { $0["event"] == .string("stream_memory_cap") })
        #expect(line["mb"] == .int(Int((Double(StreamWorker.STREAM_MEMORY_LIMIT + 1) / 1_048_576).rounded())))
        // twice the stream's budget, measured as this process (the engine is in it)
        #expect(StreamWorker.STREAM_MEMORY_LIMIT == 3 * 1_073_741_824)
    }

    @Test func test_the_stream_cap_follows_the_configured_budget() {
        var config = Config()
        config.memory["stream_gb"] = 2.5
        #expect(StreamWorker.memoryLimit(config) == 5 * 1_073_741_824)
        #expect(StreamWorker.memoryLimit(Config()) == Int(2 * StreamWorker.DEFAULT_STREAM_GB * 1_073_741_824))
    }

    @Test func theCommandLeavesAStreamAlreadyRunningAlone() async throws {
        // Two streams would both load the model and rewrite stream.json.
        let t = Temp(); defer { t.remove() }
        let folder = t.file("2026-10-27T11-00-00")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paths = RecordingPaths(folder)
        let other = Foundation.Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        defer { other.terminate(); other.waitUntilExit() }
        try Data("\(other.processIdentifier)".utf8).write(to: paths.streamPid)
        t.write("config.toml", "[user]\nname = \"Timo\"\n")
        var env = testEnv(t)
        env[FakeEngine.ENV] = t.file("none.json").path
        let rc = await WorkerMain.run(["--config", t.file("config.toml").path, "--no-notify", "stream", folder.path], env: env)
        #expect(rc == 0)
        #expect(events(paths) == ["stream_already_running"])
        #expect((try? String(contentsOf: paths.streamPid, encoding: .utf8)) == "\(other.processIdentifier)")  // still the other's
    }

    @Test func theCommandStreamsAFinishedRecordingAndRemovesItsPidFile() async throws {
        let t = Temp(); defer { t.remove() }
        let folder = t.file("2026-10-27T11-00-00")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rec = Recording(folder)
        rec.add(2, system: LOUD, mic: 0)
        finalizePart(rec.paths.systemWav)
        finalizePart(rec.paths.micRawWav)
        t.write("2026-10-27T11-00-00/meta.json", "{}")
        t.write("engine.json", #"{"windows": [{"text": "Gut.", "start": 0.2, "end": 0.6}]}"#)
        t.write("config.toml", "[user]\nname = \"Timo\"\n")
        var env = testEnv(t)
        env[FakeEngine.ENV] = t.file("engine.json").path
        let rc = await WorkerMain.run(["--config", t.file("config.toml").path, "--no-notify", "stream", folder.path], env: env)
        #expect(rc == 0)
        #expect(!FileManager.default.fileExists(atPath: rec.paths.streamPid.path))
        let s = try #require(readJSON(rec.paths.stream))
        #expect(texts(s["system"]) == ["Gut."])
        #expect(s["speaking"] == .object([("others", .bool(false)), ("me", .bool(false))]))  // nobody speaks after the stop
        let names = events(rec.paths)
        #expect(names.first == "stream_start" && names.last == "stream_done")
        let done = try #require(t.lines("2026-10-27T11-00-00/session.log").last)
        #expect(done["finished"] == .bool(true) && done["peak_mb"]?.doubleValue != nil)
    }
}
