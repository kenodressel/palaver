// `palaver-worker process`: the pipeline over a recording folder with the engine's answers from a fake (no models),
// real WAVs, the real cleanup filters, merge and rendering (tests/test_cli.py's `process` tests, test_pipeline_e2e.py).
import Foundation
import PalaverCore
@testable import PalaverDomain
@testable import PalaverWorker
import Testing

/// A track like the recorder's: a noise floor around -60 dBFS, a 220 Hz tone at 0.3 where someone speaks.
func track(_ seconds: Double, loud: [(Double, Double)], seed: UInt64 = 1) -> [Int16] {
    var state = seed &* 6364136223846793005 &+ 1442695040888963407
    func noise() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return (Double(state >> 11) / Double(1 << 53) - 0.5) * 2 * 0.0017
    }
    var x = (0..<Int(seconds * 16_000)).map { _ in noise() }
    for (a, b) in loud {
        for i in Int(a * 16_000)..<min(Int(b * 16_000), x.count) { x[i] = 0.3 * sin(2 * Double.pi * 220 * Double(i) / 16_000) }
    }
    return x.map { Int16(($0 * 32767).rounded()) }
}

/// The pieces of a pipeline run in `t`: stores, the user Timo, no calendar, no notes, the engine's answers `spec`.
struct Harness {
    let t: Temp
    let stores: StorePaths
    var config = Config()
    var said: [String] { box.lines }
    let box = Lines()

    final class Lines: @unchecked Sendable {
        var lines: [String] = []
    }

    init(_ t: Temp) {
        self.t = t
        stores = StorePaths(configDir: t.file("config/palaver"), home: t.file("home"))
        config.userName = "Timo"
        config.outputDir = t.file("Recordings")
        config.calendarEnabled = false
        config.notesEnabled = false
        try! FileManager.default.createDirectory(at: config.outputDir, withIntermediateDirectories: true)
    }

    func setup(_ engine: EngineCalls, python: String = "/usr/bin/false", calendar: CalendarProvider? = nil) -> Pipeline.Setup {
        let box = self.box
        return Pipeline.Setup(config: config, userName: "Timo", engine: engine, helper: HelperProgram(program: python, env: testEnv(t)),
                              calendar: (calendar != nil, calendar), stores: stores, say: { box.lines.append($0) })
    }

    /// A recording folder `name` with mic.wav (or mic_raw.wav) and system.wav and its meta.json.
    func meeting(_ name: String = "2026-10-20T14-35-17", mic: [Int16], system: [Int16], raw: Bool = false,
                 start: String = "2026-10-20T14:35:17+02:00", seconds: Double = 10) throws -> RecordingPaths {
        let paths = RecordingPaths(config.outputDir.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        try Wav16.write(mic, rate: 16_000, to: raw ? paths.micRawWav : paths.micWav)
        try Wav16.write(system, rate: 16_000, to: paths.systemWav)
        try PythonJSON.write(.object([("start_time", .string(start)), ("duration_seconds", .double(seconds))]), to: paths.meta,
                             indent: nil, ensureAscii: true)
        return paths
    }
}

func fake(_ json: String) -> FakeEngine { FakeEngine(spec: try! PythonJSON.parse(Data(json.utf8))) }

func readJSON(_ url: URL) -> JSONValue? { PythonJSON.read(url) }

func events(_ paths: RecordingPaths) -> [String] {
    ((try? String(contentsOf: paths.sessionLog, encoding: .utf8)) ?? "").split(separator: "\n")
        .compactMap { try? PythonJSON.parse(Data($0.utf8))["event"]?.stringValue }
}

private func seg(_ start: Double, _ end: Double, _ text: String, words: Bool = false) -> String {
    var ws: [String] = []
    if words {
        for (i, w) in text.split(separator: " ").enumerated() {
            ws.append(#"{"text": "\#(w)", "start": \#(start + Double(i) * 0.4), "end": \#(start + Double(i + 1) * 0.4)}"#)
        }
    }
    return #"{"start": \#(start), "end": \#(end), "text": "\#(text)", "speaker": null, "words": [\#(ws.joined(separator: ", "))]}"#
}

/// test_pipeline_e2e.py's call: Timo opens, the AEC lets a remote sentence through, a hallucination over silence.
private let E2E = """
{"transcribe": {
   "mic.wav": [\(seg(0.5, 2.0, "Let's start the review.")), \(seg(3.0, 5.0, "the numbers look good this quarter")),
               \(seg(6.0, 6.5, "Thank you."))],
   "system.wav": [\(seg(3.0, 5.4, "The numbers look good this quarter.", words: true)),
                  \(seg(7.0, 8.2, "Agreed, ship it.", words: true))]},
 "diarize": {"system.wav": {"turns": [{"speaker": "SPEAKER_00", "start": 2.8, "end": 5.6},
                                      {"speaker": "SPEAKER_01", "start": 6.8, "end": 8.6}],
                            "embeddings": {"SPEAKER_00": [1.0, 0.0], "SPEAKER_01": [0.0, 1.0]}}}}
"""

private let HALLO = #"{"transcribe": {"*": [\#(seg(0.0, 1.0, "hallo"))]}}"#

@Suite(.serialized) struct ProcessTests {
    @Test func test_process_then_sync_end_to_end() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let paths = try h.meeting(mic: track(10, loud: [(0.5, 2.0), (3.0, 5.0)]), system: track(10, loud: [(3.0, 5.4), (7.0, 8.2)], seed: 2))
        let engine = fake(E2E)
        #expect(try await Pipeline.process(paths.folder, h.setup(engine), notes: false) == 0)
        let transcript = readJSON(paths.transcriptJson)?.arrayValue ?? []
        #expect(transcript.map { [$0["speaker"]?.stringValue ?? "", $0["text"]?.stringValue ?? ""] } == [
            ["Timo", "Let's start the review."], ["SPEAKER_00", "The numbers look good this quarter."],
            ["SPEAKER_01", "Agreed, ship it."]])
        let md = try String(contentsOf: paths.transcriptMd, encoding: .utf8)
        #expect(md.split(separator: "\n").first == "# 2026-10-20 14:35 — Meeting (0 min, 3 speakers)")
        #expect(md.contains("**Timo** [14:35:17]  Let's start the review."))
        #expect(!md.contains("Thank you."))
        let logged = events(paths)
        #expect(logged.first == "process_start")
        #expect(Set(["transcribe_done", "diarize_done", "merge_done", "process_done"]).isSubset(of: Set(logged)))
        // Who transcribed the system track, the files a later run skips, the proof that the engine works.
        #expect(readJSON(paths.transcription)?["system"]?["engine"] == .string("local"))
        #expect(readJSON(paths.micSegments)?.arrayValue?.first?["speaker"] == .string("Timo"))
        #expect(readJSON(paths.systemTurns)?.arrayValue?.count == 2)
        #expect(readJSON(paths.speakerEmbeddings)?["SPEAKER_01"] == .array([.double(0), .double(1)]))
        #expect(readJSON(paths.speakersAuto) == .object([]))
        #expect(FileManager.default.fileExists(atPath: h.stores.engineProvenMarker.path))
        #expect(FileManager.default.fileExists(atPath: h.stores.coachBaseline.path))
        #expect(ProcessState.read(paths) == nil)
        #expect(h.said.contains("Dropped 1 segments over silence (likely hallucinations) and 1 mic segments that were remote speech heard through the speakers."))
        #expect(h.said.last == "Wrote \(paths.transcriptMd.path)")
        // Run again: every step skips what is there; the transcript is the same.
        let again = Harness(t)
        #expect(try await Pipeline.process(paths.folder, again.setup(fake("{}")), notes: false) == 0)
        #expect(readJSON(paths.transcriptJson)?.arrayValue?.count == 3)
        #expect(again.said.prefix(4) == ["Skipping AEC (mic.wav already present)", "Skipping system transcription (already done)",
                                         "Skipping mic transcription (already done)", "Skipping diarization (already done)"])
    }

    @Test func test_a_call_whose_system_track_got_nothing_is_transcribed_from_the_mic() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let raw = track(10, loud: [(0.5, 2.0)])
        let paths = try h.meeting("2026-10-30T12-46-50", mic: raw, system: [], raw: true, start: "2026-10-30T12:46:50+01:00")
        let engine = fake(#"{"transcribe": {"mic.wav": [\#(seg(0.5, 2.0, "Let's start the review."))]}, "fail": {"diarize": "a model refuses an empty waveform"}}"#)
        #expect(try await Pipeline.process(paths.folder, h.setup(engine), notes: false) == 0)
        #expect(readJSON(paths.transcriptJson)?.arrayValue?.map { $0["speaker"]?.stringValue } == ["Timo"])
        #expect(readJSON(paths.systemSegments) == .array([]))
        #expect(readJSON(paths.systemTurns) == .array([]))
        #expect(try Wav16.read(paths.micWav) == raw)  // no reference: nothing to cancel
        #expect(events(paths).contains("system_track_empty"))
        #expect(h.said.contains("System track holds no audio; transcribing the microphone only"))
    }

    @Test func test_mic_language_follows_system_track_when_auto() async throws {
        // The engine's Parakeet detects no language; one the live worker found (language.txt) is the mic's.
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let paths = try h.meeting(mic: track(1, loud: []), system: track(1, loud: []), seconds: 1)
        try Data("de\n".utf8).write(to: paths.language)
        #expect(try await Pipeline.process(paths.folder, h.setup(fake(HALLO)), notes: false) == 0)
        #expect(h.said.contains("Transcribing mic track (de)…"))
        let lines = ((try? String(contentsOf: paths.sessionLog, encoding: .utf8)) ?? "").split(separator: "\n").map { try! PythonJSON.parse(Data($0.utf8)) }
        let mic = lines.first { $0["event"] == .string("transcribe_start") && $0["track"] == .string("mic") }
        #expect(mic?["language"] == .string("de"))
        #expect(try String(contentsOf: paths.language, encoding: .utf8) == "de\n")
    }

    @Test func test_process_removes_the_echo_cancelled_part_a_stopped_live_worker_left() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let paths = try h.meeting(mic: track(1, loud: []), system: track(1, loud: []), seconds: 1)
        let stale = URL(fileURLWithPath: paths.micWav.path + ".part")
        try Data(count: 1000).write(to: stale)
        #expect(try await Pipeline.process(paths.folder, h.setup(fake(HALLO)), notes: false) == 0)
        #expect(FileManager.default.fileExists(atPath: paths.micWav.path) && !FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func test_process_removes_the_live_diarizers_scratch_a_killed_worker_left() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let paths = try h.meeting(mic: track(1, loud: []), system: track(1, loud: []), seconds: 1)
        let scratch = paths.folder.appendingPathComponent(".live-diarize.wav")
        try Data(count: 1000).write(to: scratch)
        #expect(try await Pipeline.process(paths.folder, h.setup(fake(HALLO)), notes: false) == 0)
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }

    @Test func test_process_waits_for_models_not_downloaded_yet() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let paths = try h.meeting(mic: track(1, loud: []), system: track(1, loud: []), seconds: 1)
        let refused = WorkerMain.refusal(paths.folder, WorkerMain.Options(), config: h.config, stores: h.stores, speechModelsHere: { false })
        #expect(refused?.1 == 4)
        #expect(refused?.0.contains("waiting for Speech models, not downloaded yet") == true)
        #expect(ProcessState.read(paths)?["missing"] == .strings(["Speech models"]))
        #expect(!FileManager.default.fileExists(atPath: paths.transcriptJson.path))
    }

    @Test func test_run_without_models_marks_models_reason() async throws {
        // The engine says "models missing" although the check let the run start (a half-downloaded folder): the
        // meeting waits for the download instead of failing for good.
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let paths = try h.meeting(mic: track(1, loud: []), system: track(1, loud: []), seconds: 1)
        let engine = fake(#"{"transcribe": {"*": []}, "fail": {"diarize": "models missing: diarizer"}}"#)
        #expect(try await Pipeline.process(paths.folder, h.setup(engine), notes: false, runMode: true) == 4)
        let state = ProcessState.read(paths)
        #expect(state?["reason"] == .string("models") && state?["missing"] == .strings(["Speech models"]))
        #expect(h.said.last?.hasSuffix("is transcribed once the speech models are downloaded.") == true)
        #expect(!FileManager.default.fileExists(atPath: paths.transcriptJson.path))
    }

    @Test func test_a_failed_process_is_marked_with_why_and_a_good_run_clears_it() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let paths = try h.meeting(mic: track(1, loud: []), system: track(1, loud: []), seconds: 1)
        let broken = fake(#"{"fail": {"transcribe": "Unable to load kernel\nno GPU"}}"#)
        await #expect(throws: PalaverWorker.WorkerError.self) { try await Pipeline.process(paths.folder, h.setup(broken), notes: false) }
        #expect(ProcessState.read(paths)?["reason"] == .string("error"))
        #expect(ProcessState.read(paths)?["error"] == .string("no GPU"))
        #expect(ProcessState.read(paths)?["missing"] == .strings([]))
        // A failure it says itself (no meta.json, no audio to rebuild it from): exit 2, marked.
        let bare = RecordingPaths(h.config.outputDir.appendingPathComponent("2026-10-21T09-00-00", isDirectory: true))
        try FileManager.default.createDirectory(at: bare.folder, withIntermediateDirectories: true)
        #expect(try await Pipeline.process(bare.folder, h.setup(fake(HALLO)), notes: false) == 2)
        #expect(ProcessState.read(bare)?["reason"] == .string("error") && ProcessState.read(bare)?["error"] == .null)
        #expect(h.said.last?.hasPrefix("error: \(bare.meta.path) not found.") == true)
        // A good run clears it.
        #expect(try await Pipeline.process(paths.folder, h.setup(fake(HALLO)), notes: false) == 0)
        #expect(ProcessState.read(paths) == nil)
    }

    @Test func test_process_marks_failed_when_engine_dies() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let paths = try h.meeting(mic: track(1, loud: []), system: track(1, loud: []), seconds: 1)
        let engine = fake(#"{"transcribe": {"*": []}, "fail": {"diarize": "the speech engine stopped"}}"#)
        await #expect(throws: PalaverWorker.WorkerError.self) { try await Pipeline.process(paths.folder, h.setup(engine), notes: false) }
        #expect(ProcessState.read(paths)?["error"] == .string("the speech engine stopped"))
        #expect(!FileManager.default.fileExists(atPath: paths.transcriptJson.path))
        #expect(!FileManager.default.fileExists(atPath: paths.systemTurns.path))
    }

    @Test func test_process_uses_dictionary_flag() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let paths = try h.meeting(mic: track(1, loud: [(0, 1)]), system: track(1, loud: []), seconds: 1)
        t.write("legal.toml", "[replacements]\n\"kay pee eye\" = \"KPI\"\n")
        t.write("engine.json", #"{"transcribe": {"mic.wav": [\#(seg(0.0, 1.0, "the kay pee eye is up"))]}}"#)
        t.write("config.toml", "[user]\nname = \"Timo\"\n[recording]\noutput_dir = \"\(h.config.outputDir.path)\"\n[calendar]\nenabled = false\n[notes]\nenabled = false\n")
        var env = testEnv(t)
        env[FakeEngine.ENV] = t.file("engine.json").path
        let rc = await WorkerMain.run(["--config", t.file("config.toml").path, "--dictionary", t.file("legal.toml").path, "--no-notify",
                                       "process", paths.folder.path], env: env)
        #expect(rc == 0)
        #expect(readJSON(paths.transcriptJson)?.arrayValue?.first?["text"] == .string("the KPI is up"))
        let start = ((try? String(contentsOf: paths.sessionLog, encoding: .utf8)) ?? "").split(separator: "\n")
            .map { try! PythonJSON.parse(Data($0.utf8)) }.first { $0["event"] == .string("process_start") }
        #expect(start?["dictionary"] == .string(t.file("legal.toml").path))
    }

    @Test func test_process_rejects_missing_explicit_dictionary() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let paths = try h.meeting(mic: track(1, loud: []), system: track(1, loud: []), seconds: 1)
        var o = WorkerMain.Options()
        o.dictionary = t.file("nope.toml").path
        let refused = WorkerMain.refusal(paths.folder, o, config: h.config, stores: h.stores, speechModelsHere: { true })
        #expect(refused?.1 == 2 && refused?.0.contains("nope.toml") == true)
    }

    @Test func test_missing_models_are_only_those_a_run_still_needs() throws {
        let t = Temp(); defer { t.remove() }
        let paths = RecordingPaths(t.url)
        var here = false
        #expect(ProcessState.missingModels(transcriber: "parakeet-mlx", paths: paths, speechModelsHere: { here }) == ["Speech models"])
        here = true
        #expect(ProcessState.missingModels(transcriber: "parakeet-mlx", paths: paths, speechModelsHere: { here }).isEmpty)
        here = false
        for f in [paths.micSegments, paths.systemSegments] { try Data("[]".utf8).write(to: f) }  // transcribed, not diarized
        #expect(ProcessState.missingModels(transcriber: "parakeet-mlx", paths: paths, speechModelsHere: { here }) == ["Speech models"])
        for f in [paths.systemTurns, paths.speakerEmbeddings] { try Data("[]".utf8).write(to: f) }
        #expect(ProcessState.missingModels(transcriber: "parakeet-mlx", paths: paths, speechModelsHere: { here }).isEmpty)
        try FileManager.default.removeItem(at: paths.micSegments)
        #expect(ProcessState.missingModels(transcriber: "mlx-whisper", paths: paths, speechModelsHere: { here }).isEmpty)
    }

    @Test func test_a_failed_command_notifies_with_the_short_reason_not_the_whole_message() {
        let error = PalaverWorker.WorkerError("the speech engine died (exit 3)\n" + String(repeating: "stderr line\n", count: 3) + "the speech engine died")
        #expect(Pipeline.failureReason(error) == "the speech engine died")
        #expect(Pipeline.failureReason(PalaverWorker.WorkerError("one line")) == "one line")
    }

    @Test func test_process_closes_the_transcribers_engine_before_diarizing() async throws {
        // One model at a time: Parakeet goes after both tracks, the diarizer before the notes (Batch B review).
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let paths = try h.meeting(mic: track(1, loud: []), system: track(1, loud: []), seconds: 1)
        let engine = fake(HALLO)
        #expect(try await Pipeline.process(paths.folder, h.setup(engine), notes: false) == 0)
        #expect(engine.calls == ["transcribe system.wav", "transcribe mic.wav", "release", "diarize system.wav", "release"])
    }

    @Test func aLiveOrFallbackSystemTrackBecomesThisMacsWithoutAService() async throws {
        // Kept as this Mac made it: a service chosen later never sends it (transcription.system_track).
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let paths = try h.meeting(mic: track(1, loud: []), system: track(1, loud: []), seconds: 1)
        try PythonJSON.write(.array([]), to: paths.systemSegments, indent: 2, ensureAscii: true)
        try TranscriptionMarker.write(paths, track: "system", info: [("engine", .string("live"))])
        #expect(try await Pipeline.process(paths.folder, h.setup(fake(HALLO)), notes: false) == 0)
        #expect(readJSON(paths.transcription)?["system"]?["engine"] == .string("local"))
        #expect(!TranscriptionMarker.wantsCloud(paths))
        #expect(h.said.contains("Skipping system transcription (already done)"))
    }

    @Test func aKnownVoiceIsRecognizedAndNamesTheTranscript() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let paths = try h.meeting(mic: track(14, loud: [(0.2, 0.9)]), system: track(14, loud: [(1, 13)], seed: 5), seconds: 14)
        #expect(try VoiceBank(directory: h.stores.voices).add("Valerie", [0.9, 0.1, 0.42], source: "test"))
        let engine = fake(#"{"transcribe": {"mic.wav": [], "system.wav": [\#(seg(2.0, 4.0, "Grüße aus Köln.", words: true))]}, "diarize": {"system.wav": {"turns": [{"speaker": "SPEAKER_00", "start": 1.0, "end": 13.0}], "embeddings": {"SPEAKER_00": [0.9, 0.1, 0.4]}}}}"#)
        #expect(try await Pipeline.process(paths.folder, h.setup(engine), notes: false) == 0)
        let auto = readJSON(paths.speakersAuto)
        #expect(auto?["SPEAKER_00"]?["name"] == .string("Valerie"))
        let similarity = auto?["SPEAKER_00"]?["similarity"]?.doubleValue ?? 0
        #expect(similarity > 0.99 && similarity == Py.round(similarity, 3))
        #expect(try String(contentsOf: paths.speakersAuto, encoding: .utf8).hasPrefix("{\n  \"SPEAKER_00\": {\n    \"name\": \"Valerie\""))
        #expect(h.said.contains { $0.hasPrefix("Recognized SPEAKER_00 as Valerie (voice similarity ") })
        #expect(readJSON(paths.transcriptJson)?.arrayValue?.map { $0["speaker"]?.stringValue } == ["Valerie"])
        #expect(try String(contentsOf: paths.transcriptMd, encoding: .utf8).contains("**Valerie** [14:35:19]  Grüße aus Köln."))
    }

    @Test func aContinuedRecordingIsJoinedAndEchoCancelledFirst() async throws {
        // A recording cut by a restart (G and G2 of the parity corpus): the parts joined into the first, mic.wav made
        // by the echo canceller from mic_raw.wav, the whole meeting transcribed once.
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let head = try h.meeting("2026-10-30T16-00-00", mic: track(20, loud: [(0, 1)]), system: track(20, loud: [(1, 19)], seed: 3),
                                 raw: true, start: "2026-10-30T16:00:00+01:00", seconds: 20)
        let part = try h.meeting("2026-10-30T16-00-30", mic: track(15, loud: [(0, 1)]), system: track(15, loud: [(1, 14)], seed: 4),
                                 raw: true, start: "2026-10-30T16:00:30+01:00", seconds: 15)
        try Continuation.addPart(head.folder, part.folder)
        let engine = fake(#"{"transcribe": {"mic.wav": [\#(seg(0.2, 0.9, "Hallo zusammen."))], "system.wav": [\#(seg(2.0, 4.0, "Guten Tag allerseits.", words: true))]}, "diarize": {"system.wav": {"turns": [{"speaker": "SPEAKER_00", "start": 1.0, "end": 19.0}], "embeddings": {"SPEAKER_00": [1.0, 0.0]}}}}"#)
        #expect(try await Pipeline.process(head.folder, h.setup(engine), notes: false) == 0)
        #expect(!FileManager.default.fileExists(atPath: part.folder.path))
        #expect(events(head).contains("aec_done"))
        #expect(try Wav16.info(head.micWav).frames == (try Wav16.info(head.micRawWav).frames))
        #expect(readJSON(head.transcriptJson)?.arrayValue?.map { $0["text"]?.stringValue } == ["Hallo zusammen.", "Guten Tag allerseits."])
        #expect(h.said.first == "Running AEC (mic_raw.wav + system.wav → mic.wav)…")
    }
}
