// The live worker (tests/test_live.py): a recording grown by the test as the recorder grows it (a placeholder header,
// then samples appended to `<track>.part`), a fake transcriber and diarizer, no models, no audio device.
import Darwin
import Foundation
import PalaverCore
@testable import PalaverDomain
@testable import PalaverWorker
import Testing

private let SR = 16_000

/// What the recorder does: a placeholder header, then appended samples.
func appendPart(_ url: URL, _ samples: [Int16]) {
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: Data(Wav16.header(dataBytes: 0, rate: 16_000, channels: 1)))
    }
    let h = try! FileHandle(forWritingTo: url)
    h.seekToEndOfFile()
    h.write(samples.withUnsafeBytes { Data($0) })
    try! h.close()
}

/// The recorder's stop: `<final>.part` becomes `<final>` with its header patched.
func finalizePart(_ final: URL) {
    let part = URL(fileURLWithPath: final.path + ".part")
    let data = try! Data(contentsOf: part).dropFirst(44)
    try! (Data(Wav16.header(dataBytes: data.count, rate: 16_000, channels: 1)) + data).write(to: final)
    try! FileManager.default.removeItem(at: part)
}

func partURL(_ final: URL) -> URL { URL(fileURLWithPath: final.path + ".part") }

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// Loud constant "speech", silent for a second at each of `pauseAt`.
private func speech(_ seconds: Double, pauseAt: [Double] = []) -> [Int16] {
    var audio = [Int16](repeating: 5000, count: Int(seconds * Double(SR)))
    for t in pauseAt { for i in Int(t * Double(SR))..<Int((t + 1) * Double(SR)) { audio[i] = 0 } }
    return audio
}

/// One segment per non-silent block, at the block's first loud sample.
private final class FakeTranscriber: LiveTranscriber {
    var blocks: [Double] = []
    var lastLanguage: String? { nil }

    func transcribe(wav: URL, language: String?) async throws -> [Segment] {
        let audio = try Wav16.read(wav)
        blocks.append(Double(audio.count) / Double(SR))
        guard let loud = audio.firstIndex(where: { abs(Int($0)) > 1000 }) else { return [] }
        let t = Double(loud) / Double(SR)
        return [Segment(start: t, end: t + 1, text: "hallo", words: [Word(text: "hallo", start: t, end: t + 1)])]
    }
}

private final class FakeDiarizer: LiveDiarizer {
    var available: [Int] = []
    var finishedWith: Int?
    let lastEmbeddings = PyDict<[Double]>([("SPEAKER_00", [1.0, 0.0])])
    var chunksDone: Int { 0 }

    func advance(read: TrackRead, available: Int) async throws -> Int {
        self.available.append(available)
        return 0
    }

    func provisional() -> [SpeakerTurn] {
        available.last.map { [SpeakerTurn(speaker: "SPEAKER_00", start: 0, end: Double($0) / Double(SR))] } ?? []
    }

    func finish(read: TrackRead, until: Int) async throws -> [SpeakerTurn] {
        finishedWith = until
        return [SpeakerTurn(speaker: "SPEAKER_00", start: 0, end: Double(until) / Double(SR))]
    }
}

private final class IdentityAec: EchoCanceller {
    func process(mic: [Int16], system: [Int16]) throws -> [Int16] { mic }
}

/// A step that finds its folder gone (a recording dropped as too short).
private final class GoneMidStep: LiveProcessing {
    let folder: URL
    init(_ folder: URL) { self.folder = folder }
    func step() async throws -> Bool {
        try FileManager.default.removeItem(at: folder)
        throw WorkerError("\(folder.path)/.live-diarize.wav: no such file")
    }
    func snapshot() throws -> Bool { false }
    func finalUntil() -> Int { 0 }
    func finish() async throws {}
    func abort() {}
}

private func noSleep(_ s: Double) async throws {}

@Suite struct LiveWorkerTests {
    /// SIGTERM's cleanup (and `process` after a killed worker) leaves none of the live worker's scratch files.
    @Test func theScratchFilesGoAndNothingElse() throws {
        let t = Temp(); defer { t.remove() }
        for name in Live.SCRATCH + ["mic_raw.wav", "live.json"] { try Data([1]).write(to: t.file(name)) }
        Live.removeScratch(t.url)
        #expect(Live.SCRATCH.allSatisfy { !exists(t.file($0)) })
        #expect(exists(t.file("mic_raw.wav")) && exists(t.file("live.json")))
    }

    @Test func test_live_processing_matches_the_files_process_writes() async throws {
        let t = Temp(); defer { t.remove() }
        let paths = RecordingPaths(t.url)
        let transcriber = FakeTranscriber(), diarizer = FakeDiarizer()
        let proc = try LiveProcessor(paths: paths, transcriber: transcriber, diarizer: diarizer, userName: "Timo",
                                     aec: { IdentityAec() })
        // 100 s recorded so far, a pause at 65 s: one block is transcribed, cut there.
        let mic = speech(100, pauseAt: [65])
        appendPart(partURL(paths.micRawWav), mic)
        appendPart(partURL(paths.systemWav), speech(100, pauseAt: [65]))
        while try await proc.step() {}
        #expect(transcriber.blocks.count == 2 && transcriber.blocks.allSatisfy { abs($0 - 65.5) <= 0.6 })
        #expect(diarizer.available.last == 97 * SR)  // 3 s margin
        #expect(!exists(paths.micWav))  // still recording

        // What the window shows meanwhile: the text so far, provisional speakers.
        #expect(try proc.snapshot())
        #expect(try !proc.snapshot())  // nothing new the second time
        let live = try #require(readJSON(paths.live))
        #expect(abs((live["until"]?.doubleValue ?? 0) - 65.5) <= 0.6)
        #expect(live["system"]?.arrayValue?.map { $0["text"] } == [.string("hallo")])
        #expect(live["mic"]?.arrayValue?.first?["speaker"] == .string("Timo"))
        #expect(live["turns"] == .array([.object([("speaker", .string("SPEAKER_00")), ("start", .double(0)), ("end", .double(97))])]))
        #expect(live["embeddings"] == .object([("SPEAKER_00", .array([.double(1), .double(0)]))]))
        #expect(!exists(t.file("live.json.tmp")))

        // Recording continues; system goes quiet (the tap delivers nothing), stops.
        let more = speech(40)
        appendPart(partURL(paths.micRawWav), more)
        finalizePart(paths.micRawWav)
        finalizePart(paths.systemWav)
        t.write("meta.json", "{}")
        #expect(try await Live.run(proc, paths: paths, sleep: noSleep))

        #expect(diarizer.finishedWith == 100 * SR)
        #expect(try Wav16.read(paths.micWav) == mic + more)
        let micSegments = try #require(readJSON(paths.micSegments)?.arrayValue).map { try Segment(json: $0) }
        #expect(Set(micSegments.map(\.speaker)) == ["Timo"])
        #expect(micSegments.map { $0.start.rounded() } == [0, 66, 125])  // absolute times
        #expect(readJSON(paths.systemTurns)?.arrayValue?.first?["speaker"] == .string("SPEAKER_00"))
        #expect(readJSON(paths.speakerEmbeddings) == .object([("SPEAKER_00", .array([.double(1), .double(0)]))]))
        #expect(readJSON(paths.systemSegments)?.arrayValue?.count == 2)
        #expect(!exists(paths.live))  // the final files replace it
        #expect(TranscriptionMarker.read(paths)["system"]?["engine"] == .string("live"))
        #expect(TranscriptionMarker.wantsCloud(paths))  // the live text: a chosen service still replaces it
    }

    @Test func test_live_gives_up_when_the_recorder_dies() async throws {
        let t = Temp(); defer { t.remove() }
        let paths = RecordingPaths(t.url)
        let proc = try LiveProcessor(paths: paths, transcriber: FakeTranscriber(), diarizer: FakeDiarizer(), userName: "Timo",
                                     aec: { IdentityAec() })
        appendPart(partURL(paths.micRawWav), speech(10))
        var clock = 0.0
        #expect(try await !Live.run(proc, paths: paths, clock: { clock }, sleep: { clock += $0 }))
        #expect(!exists(paths.micWav) && !exists(partURL(paths.micWav)))
    }

    @Test func test_live_stops_quietly_when_the_recording_is_dropped() async throws {
        // A recording stopped after a few seconds is dropped as too short: its folder goes away while the worker is
        // still in a step.
        let t = Temp(); defer { t.remove() }
        let folder = t.file("2026-11-04T09-24-38")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(try await !Live.run(GoneMidStep(folder), paths: RecordingPaths(folder), sleep: noSleep))
    }

    @Test func test_live_finishes_a_meeting_whose_system_track_got_nothing() async throws {
        // The tap delivered nothing for a whole Slack call: the live worker must still write the mic's transcript,
        // with no remote speakers. The engine must not be started for the empty track.
        let t = Temp(); defer { t.remove() }
        let paths = RecordingPaths(t.url)
        let transcriber = FakeTranscriber()
        let noEngine = fake(#"{"fail": {"diarize": "engine must not be started", "transcribe": "engine must not be started"}}"#)
        let proc = try LiveProcessor(paths: paths, transcriber: transcriber, diarizer: LiveEngineDiarizer(folder: t.url, engine: noEngine),
                                     userName: "Timo", aec: { IdentityAec() })
        let mic = speech(20)
        appendPart(partURL(paths.micRawWav), mic)
        finalizePart(paths.micRawWav)
        FileManager.default.createFile(atPath: paths.systemWav.path, contents: Data(Wav16.header(dataBytes: 0, rate: 16_000, channels: 1)))
        t.write("meta.json", "{}")

        #expect(try await Live.run(proc, paths: paths, sleep: noSleep))

        #expect(transcriber.blocks == [20.0])  // the mic only
        #expect(readJSON(paths.micSegments)?.arrayValue?.map { $0["speaker"] } == [.string("Timo")])
        #expect(readJSON(paths.systemSegments) == .array([]))
        #expect(readJSON(paths.systemTurns) == .array([]))
        #expect(readJSON(paths.speakerEmbeddings) == .object([]))
        #expect(try Wav16.read(paths.micWav) == mic)
    }

    @Test func theEngineDiarizerRediarizesTheWholeTrackEveryTwoMinutes() async throws {
        let t = Temp(); defer { t.remove() }
        let engine = fake(#"{"diarize": {"*": {"turns": [{"speaker": "SPEAKER_00", "start": 0.0, "end": 5.0}], "embeddings": {"SPEAKER_00": [0.5, 0.5]}}}}"#)
        let diarizer = LiveEngineDiarizer(folder: t.url, engine: engine)
        var asked: [Range<Int>] = []
        let read: TrackRead = { a, b in asked.append(a..<b); return [Int16](repeating: 100, count: b - a) }
        #expect(try await diarizer.advance(read: read, available: 119 * SR) == 0)
        #expect(try await diarizer.advance(read: read, available: 150 * SR) == 1)
        #expect(asked.first?.lowerBound == 0 && asked.last?.upperBound == 150 * SR)
        #expect(asked.allSatisfy { $0.count <= Live.READ_BLOCK })  // the scratch file is written a block at a time
        #expect(diarizer.provisional().map(\.speaker) == ["SPEAKER_00"] && diarizer.chunksDone == 1)
        #expect(diarizer.lastEmbeddings["SPEAKER_00"] == [0.5, 0.5])
        #expect(try await diarizer.advance(read: read, available: 200 * SR) == 0)  // < 2 min of new audio
        #expect(try await diarizer.advance(read: read, available: 270 * SR) == 1)
        #expect(!exists(t.file(".live-diarize.wav")))  // the scratch file goes
    }

    @Test func theCommandWritesItsPidFileAndTheFilesOfAFinishedRecording() async throws {
        let t = Temp(); defer { t.remove() }
        let folder = t.file("Recordings/2026-10-27T11-00-00")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paths = RecordingPaths(folder)
        appendPart(partURL(paths.micRawWav), speech(8))
        appendPart(partURL(paths.systemWav), speech(8))
        finalizePart(paths.micRawWav)
        finalizePart(paths.systemWav)
        t.write("Recordings/2026-10-27T11-00-00/meta.json", "{}")
        let seg = #"{"start": 0.5, "end": 1.0, "text": "hallo", "speaker": null, "words": []}"#
        t.write("engine.json", #"{"transcribe": {"*": [\#(seg)]}, "diarize": {"*": {"turns": [{"speaker": "SPEAKER_00", "start": 0.0, "end": 8.0}], "embeddings": {"SPEAKER_00": [1.0]}}}}"#)
        t.write("config.toml", "[user]\nname = \"Timo\"\n[recording]\noutput_dir = \"\(t.file("Recordings").path)\"\n")
        var env = testEnv(t)
        env[FakeEngine.ENV] = t.file("engine.json").path
        let rc = await WorkerMain.run(["--config", t.file("config.toml").path, "--no-notify", "live", folder.path], env: env)
        #expect(rc == 0)
        #expect(!exists(Live.pidFile(folder)))
        #expect(readJSON(paths.micSegments)?.arrayValue?.map { $0["speaker"] } == [.string("Timo")])
        #expect(readJSON(paths.systemSegments)?.arrayValue?.count == 1)
        #expect(readJSON(paths.systemTurns)?.arrayValue?.count == 1)
        #expect(try Wav16.info(paths.micWav).frames == 8 * SR)  // echo-cancelled, as long as the raw mic
        #expect(!exists(partURL(paths.micWav)))
        let names = events(paths)
        #expect(names.contains("live_start") && names.contains("live_finish_done") && names.last == "live_done")
    }
}
