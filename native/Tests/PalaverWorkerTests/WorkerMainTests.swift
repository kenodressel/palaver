// palaver-worker's skeleton: the command line and its exit codes, stages in session.log, notifications, the engine
// in this process (fake recognizer and diarizer: no models), engine-serve, the resources it finds.
import Darwin
import FluidAudio
import PalaverCloud
import Foundation
import PalaverCore
@testable import PalaverDomain
import PalaverEngine
@testable import PalaverWorker
import Testing

/// A new empty folder under the system temp dir.
struct Temp {
    let url: URL
    init(_ name: String = "worker") {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
    func write(_ name: String, _ text: String) { try! text.write(to: file(name), atomically: false, encoding: .utf8) }
    func lines(_ name: String) -> [JSONValue] {
        ((try? String(contentsOf: file(name), encoding: .utf8)) ?? "").split(separator: "\n").map { try! PythonJSON.parse(Data($0.utf8)) }
    }
}

/// A 16 kHz mono PCM16 file of `seconds` (a soft tone, so it is not silence).
func writeTone(_ url: URL, seconds: Double) throws {
    let n = Int(seconds * 16_000)
    try Wav16.write((0..<n).map { Int16(3000 * sin(Double($0) * 0.05)) }, rate: 16_000, to: url)
}

private func tok(_ t: String, _ s: Double, _ e: Double, _ c: Float) -> TokenTiming {
    TokenTiming(token: t, tokenId: 0, startTime: s, endTime: e, confidence: c)
}

private final class Tokens: Recognizer, @unchecked Sendable {
    var calls = 0
    func recognize(_ samples: [Float]) async throws -> [TokenTiming] {
        calls += 1
        return [tok("▁hallo", 0, 0.4, 0.9), tok("▁cloud", 0.4, 0.8, 0.95), tok("▁ko", 0.8, 1.0, 0.7), tok("de", 1.0, 1.2, 0.8),
                tok(".", 1.2, 1.3, 1)]
    }
}

/// Counts how many recognitions run at once (Batch A review: the engine serves one call at a time).
private final class Overlaps: Recognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private(set) var most = 0
    func recognize(_ samples: [Float]) async throws -> [TokenTiming] {
        lock.withLock { running += 1; most = max(most, running) }
        try await Task.sleep(nanoseconds: 50_000_000)
        lock.withLock { running -= 1 }
        return [tok("▁ja", 0, 0.4, 0.9)]
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func add() { lock.withLock { n += 1 } }
}

/// The environment of a test run of the worker: a temporary config dir and home, never the real ones.
func testEnv(_ t: Temp) -> [String: String] {
    ["XDG_CONFIG_HOME": t.file("config").path, "PALAVER_HOME": t.file("home").path, "HOME": t.file("home").path]
}

private struct Voices: Diarizing {
    func diarize(_ url: URL) async throws -> DiarizerOutput {
        DiarizerOutput(segments: [("b", 3, 5), ("a", 0, 2)], embeddings: ["a": [0.5, 0.25], "b": [1, 0]])
    }
    func embed(_ url: URL, spans: [Range<Double>]) async throws -> [[Float]] { [] }
}

// Serialized: `WorkerMain.run` sets the process-wide `Notify.muted` the notification test checks.
@Suite(.serialized) struct WorkerMainTests {
    @Test func usageErrorIsExit2() async {
        #expect(await WorkerMain.run([]) == 2)
        #expect(await WorkerMain.run(["nope"]) == 2)
        #expect(await WorkerMain.run(["--config"]) == 2)
        #expect(await WorkerMain.run(["process"]) == 2)
        let t = Temp(); defer { t.remove() }
        t.write("config.toml", "[recording]\noutput_dir = \"\(t.url.path)\"\n")
        // Not a folder: exit 2 too.
        #expect(await WorkerMain.run(["--config", t.file("config.toml").path, "process", t.file("missing").path], env: testEnv(t)) == 2)
    }

    @Test func aFolderBeingRecordedIsExit3() async throws {
        let t = Temp(); defer { t.remove() }
        t.write("config.toml", "[recording]\noutput_dir = \"\(t.url.path)\"\n")
        let folder = t.file("2026-11-04T10-00-00")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2]).write(to: folder.appendingPathComponent("system.wav.part"))  // the writer appends right now
        #expect(await WorkerMain.run(["--config", t.file("config.toml").path, "process", folder.path], env: testEnv(t)) == 3)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("failed.json").path))
        // A finished first part whose continuation still records waits too, and says which.
        let head = t.file("2026-11-04T09-00-00")
        try FileManager.default.createDirectory(at: head, withIntermediateDirectories: true)
        try Continuation.addPart(head, folder)
        let refused = WorkerMain.refusal(head, WorkerMain.Options(), config: Config(), stores: .current(env: testEnv(t)),
                                         speechModelsHere: { true })
        #expect(refused?.1 == 3)
        #expect(refused?.0 == "error: 2026-11-04T10-00-00 is still being recorded; 2026-11-04T09-00-00 is processed once the recording stops.")
    }

    @Test func aFolderWaitingForItsModelsIsExit4AndMarked() async throws {
        let t = Temp(); defer { t.remove() }
        let folder = t.file("2026-11-04T10-00-00")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let refused = WorkerMain.refusal(folder, WorkerMain.Options(), config: Config(), speechModelsHere: { false })
        #expect(refused?.1 == 4)
        #expect(refused?.0 == "error: waiting for Speech models, not downloaded yet; 2026-11-04T10-00-00 is transcribed once it is.")
        #expect(ProcessState.read(RecordingPaths(folder))?["reason"] == .string("models"))
        #expect(WorkerMain.refusal(folder, WorkerMain.Options(), config: Config(), speechModelsHere: { true }) == nil)
    }

    /// `palaver sync` starts `palaver-worker sync <folder>`: a folder without a transcript is exit 2; without a Notion
    /// token the upload fails (exit 1) before anything goes out, and no notion.json is written.
    @Test func syncUploadsAProcessedRecordingOnly() async throws {
        let t = Temp(); defer { t.remove() }
        t.write("config.toml", "[recording]\noutput_dir = \"\(t.url.path)\"\n[notion]\nparent_page_id = \"p\"\n")
        let folder = t.file("2026-11-04T10-00-00")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var env = testEnv(t)
        env[KeyStores.TEST_ENV] = t.file("keys.json").path  // never the Keychain
        let args = ["--config", t.file("config.toml").path, "sync", folder.path]  // no --no-notify: it would stay set (Notify.muted)
        #expect(await WorkerMain.run(args, env: env) == 2)
        let paths = RecordingPaths(folder)
        try PythonJSON.write(.object([("start_time", .string("2026-11-04T10:00:00+01:00")), ("duration_seconds", .int(60))]),
                             to: paths.meta, indent: 2, ensureAscii: true)
        try PythonJSON.write(.array([Utterance(speaker: "Timo", start: 0, end: 2, text: "Hallo.").json]), to: paths.transcriptJson,
                             indent: 2, ensureAscii: true)
        #expect(await WorkerMain.run(args, env: env) == 1)
        #expect(!FileManager.default.fileExists(atPath: paths.notionInfo.path))
        #expect(WorkerMain.commands.contains("sync"))
    }

    @Test func stageWritesStartAndDone() throws {
        let t = Temp(); defer { t.remove() }
        let log = SessionLog(url: t.file("session.log"))
        let n = Stage.with("transcribe", log: log, fields: [("track", .string("system"))]) { info -> Int in
            info["segments"] = .int(3)
            info["track"] = .string("mic")  // set again: keeps its place
            return 3
        }
        #expect(n == 3)
        Stage.event("process_start", log: log, [("dictionary", .null)])
        let lines = t.lines("session.log")
        #expect(lines.count == 3)
        #expect(lines[0]["event"] == .string("transcribe_start") && lines[0]["track"] == .string("system"))
        #expect(lines[0]["logger"] == .string("palaver"))
        guard case .object(let done) = lines[1] else { Issue.record("not an object"); return }
        #expect(done.map(\.0) == ["ts", "level", "logger", "event", "seconds", "track", "segments"])
        #expect(lines[1]["event"] == .string("transcribe_done") && lines[1]["segments"] == .int(3))
        #expect(lines[1]["track"] == .string("mic"))
        #expect(lines[1]["seconds"]?.doubleValue == 0.0)
        // A stamped event says which Palaver wrote it.
        #expect(lines[2]["swift"] == .bool(true) && lines[2]["pid"] == .int(Int(getpid())))
        #expect(lines[2]["version"]?.stringValue != nil && lines[2]["argv"]?.arrayValue != nil && lines[2]["python"] == nil)
        #expect(lines[2]["dictionary"] == .null)
    }

    @Test func notifyIsSilentWithoutTheSocket() throws {
        #expect(!Notify.send(title: "Transcript ready", message: "x", env: [:]))
        // With the app's socket: one datagram, its message cut at 200 characters.
        let dir = URL(fileURLWithPath: "/tmp/pw-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("n.sock").path
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(socketPath.utf8)); raw[socketPath.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        #expect(Notify.send(title: "Transcript ready", message: String(repeating: "a", count: 300), meeting: "2026-11-04T10-00-00",
                            env: [Notify.ENV: socketPath]))
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, 0)
        let got = try? PythonJSON.parse(Data(buf.prefix(max(n, 0))))
        #expect(got?["title"] == .string("Transcript ready"))
        #expect(got?["message"]?.stringValue?.count == 200)
        #expect(got?["open"] == .string("2026-11-04T10-00-00"))
        #expect(got?["quiet"] == nil)
        // --no-notify mutes it.
        Notify.muted = true
        defer { Notify.muted = false }
        #expect(!Notify.send(title: "t", message: "m", env: [Notify.ENV: socketPath]))
    }

    @Test func theCoachCommandWritesTheStatusAndEndsWithTheRecording() async throws {
        // Here, not in CoachWorkerTests: `--no-notify` sets the process-wide `Notify.muted` the test above checks.
        let t = Temp(); defer { t.remove() }
        let folder = t.file("2026-11-07T10-00-00")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paths = RecordingPaths(folder)
        appendPart(partURL(paths.micRawWav), (0..<5 * 16_000).map { Int16(3000 * sin(Double($0) * 0.05)) })
        appendPart(partURL(paths.systemWav), [Int16](repeating: 0, count: 5 * 16_000))
        t.write("config.toml", "[user]\nname = \"Timo\"\n")
        let env = testEnv(t)
        let command = Task.detached {
            await WorkerMain.run(["--config", t.file("config.toml").path, "--no-notify", "coach", folder.path], env: env)
        }
        var seen = false
        for _ in 0..<500 where !seen {
            seen = PythonJSON.read(LiveCoachRunner.coachPath(folder))?["talk"]?.truthy == true
            if !seen { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        #expect(seen)
        finalizePart(paths.micRawWav)
        finalizePart(paths.systemWav)
        t.write("2026-11-07T10-00-00/meta.json", "{}")
        #expect(await command.value == 0)
        #expect(!FileManager.default.fileExists(atPath: LiveCoachRunner.coachPath(folder).path))
    }

    @Test func engineCallsRunOneAtATimeAndLoadTheRecognizerOnce() async throws {
        let t = Temp(); defer { t.remove() }
        try writeTone(t.file("a.wav"), seconds: 1)
        try writeTone(t.file("b.wav"), seconds: 1)
        let recognizer = Overlaps(), loads = Counter()
        let engine = InProcessEngine(version: "t", modelsDir: t.file("models"), recognizer: {
            loads.add()
            try await Task.sleep(nanoseconds: 50_000_000)  // a slow load: a second call must not start another
            return recognizer
        })
        async let a = engine.transcribe(wav: t.file("a.wav"))
        async let b = engine.transcribe(wav: t.file("b.wav"))
        async let c = engine.transcribe(wav: t.file("a.wav"))
        let all = try await [a, b, c]
        #expect(all.map(\.count) == [1, 1, 1])
        #expect(loads.value == 1)
        #expect(recognizer.most == 1)
    }

    @Test func releaseDropsTheModelsUntilTheNextCall() async throws {
        let t = Temp(); defer { t.remove() }
        try writeTone(t.file("a.wav"), seconds: 1)
        let loads = Counter()
        let engine = InProcessEngine(version: "t", modelsDir: t.file("models"), recognizer: { loads.add(); return Tokens() })
        _ = try await engine.transcribe(wav: t.file("a.wav"))
        _ = try await engine.transcribe(wav: t.file("a.wav"))
        #expect(loads.value == 1)
        await engine.release()
        #expect(loads.value == 1)  // nothing loaded until a call needs it
        _ = try await engine.transcribe(wav: t.file("a.wav"))
        #expect(loads.value == 2)
        #expect(engine.succeeded == ["transcribe"])  // what was proven stays
    }

    @Test func engineServeAnswersHello() async throws {
        let t = Temp(); defer { t.remove() }
        let input = Pipe(), output = Pipe()
        let wav: String = t.file("x.wav").path
        let lines: [String] = [#"{"id": 1, "cmd": "hello"}"#, #"{"id": 2, "cmd": "prepare"}"#,
                               #"{"id": 3, "cmd": "transcribe", "wav": "\#(wav)"}"#]
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        await EngineServe.run(engine: InProcessEngine(version: "9.9", modelsDir: t.file("models")),
                              input: input.fileHandleForReading, output: output.fileHandleForWriting)
        try output.fileHandleForWriting.close()
        let replies = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map { try! PythonJSON.parse(Data($0.utf8)) }
        #expect(replies.count == 3)
        #expect(replies[0]["ok"] == .bool(true) && replies[0]["engine"] == .string("9.9"))
        #expect(replies[0]["models"]?["asr"] == .bool(false))
        #expect(replies[1]["ok"] == .bool(false))  // downloads are not the worker's
        #expect(replies[2]["error"]?.stringValue?.hasPrefix("no such file") == true)
    }

    @Test func zipfIsFoundByTheResourceQuery() async {
        let t = Temp(); defer { t.remove() }
        #expect(Queries.resources() == .object([("zipf", .bool(true))]))
        #expect(await WorkerMain.run(["query", "resources", "--json"], env: testEnv(t)) == 0)
    }

    @Test func whisperConfigsRunOnTheEngineWithALogLine() {
        #expect(WorkerMain.transcriberNote("parakeet") == nil)
        #expect(WorkerMain.transcriberNote("mlx-whisper")?.contains("speech engine") == true)
        #expect(WorkerMain.transcriberNote("parakeet-mlx") != nil)
    }
}
