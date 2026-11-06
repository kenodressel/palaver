import AVFoundation
import FluidAudio
import Foundation
import Testing
@testable import PalaverEngine

private func sh(_ tool: String, _ args: [String]) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    try p.run(); p.waitUntilExit()
    return p.terminationStatus
}

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-spk-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// A 16 kHz mono 16-bit WAV of `samples` samples of silence.
private func writeSilence(_ url: URL, samples: Int) throws {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatInt16, interleaved: true)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(samples, 1)))!
    buf.frameLength = AVAudioFrameCount(samples)
    if samples > 0 { try file.write(from: buf) }
}

private struct FakeDiarizer: Diarizing {
    var output: DiarizerOutput
    var spanVectors: [[Float]] = []
    func diarize(_ url: URL) async throws -> DiarizerOutput { output }
    func embed(_ url: URL, spans: [Range<Double>]) async throws -> [[Float]] { spanVectors }
}

private func call(_ lines: [String], diarizer: (() async throws -> Diarizing)?) async throws -> [[String: Any]] {
    let inPipe = Pipe(), outPipe = Pipe()
    inPipe.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    try inPipe.fileHandleForWriting.close()
    await serve(input: inPipe.fileHandleForReading, output: outPipe.fileHandleForWriting,
                handler: engineHandler(version: "t", modelsDir: try tempDir(), diarizer: diarizer))
    try outPipe.fileHandleForWriting.close()
    return try String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
}

@Test func relabelByFirstTurn() {
    let r = relabel([("S3", 0, 4), ("S1", 5, 8), ("S3", 9, 12)])
    #expect(r.turns.map(\.speaker) == ["SPEAKER_00", "SPEAKER_01", "SPEAKER_00"])
    #expect(r.map == ["S3": "SPEAKER_00", "S1": "SPEAKER_01"])
}

@Test func shortTrackGivesNoTurns() async throws {
    let dir = try tempDir()
    let wav = dir.appendingPathComponent("short.wav")
    try writeSilence(wav, samples: 400)  // 25 ms
    // No models folder, no injected diarizer: it must not even try to load.
    let r = try await call([#"{"id":1,"cmd":"diarize","wav":"\#(wav.path)"}"#], diarizer: nil)
    #expect(r[0]["ok"] as? Bool == true)
    #expect((r[0]["turns"] as? [Any])?.isEmpty == true)
    #expect((r[0]["embeddings"] as? [String: Any])?.isEmpty == true)
}

/// The diarizer finds no speech (the other side silent so far): no turns, not a failure.
private struct SilentDiarizer: Diarizing {
    func diarize(_ url: URL) async throws -> DiarizerOutput { throw OfflineDiarizationError.noSpeechDetected }
    func embed(_ url: URL, spans: [Range<Double>]) async throws -> [[Float]] { [] }
}

@Test func aTrackWithoutSpeechGivesNoTurns() async throws {
    let dir = try tempDir()
    let wav = dir.appendingPathComponent("quiet.wav")
    try writeSilence(wav, samples: 16000 * 120)  // two minutes nobody spoke on the other side
    let r = try await call([#"{"id":1,"cmd":"diarize","wav":"\#(wav.path)"}"#], diarizer: { SilentDiarizer() })
    #expect(r[0]["ok"] as? Bool == true)
    #expect((r[0]["turns"] as? [Any])?.isEmpty == true)
    #expect((r[0]["embeddings"] as? [String: Any])?.isEmpty == true)
}

@Test func turnsAreExclusiveAndSorted() async throws {
    let dir = try tempDir()
    let wav = dir.appendingPathComponent("a.wav")
    try writeSilence(wav, samples: 16000 * 20)
    let fake = FakeDiarizer(output: DiarizerOutput(
        segments: [("S2", 6, 12), ("S1", 0, 7), ("S2", 11, 11.5), ("S1", 12, 19)],
        embeddings: ["S1": [1, 2], "S2": [3, 4], "S9": [5, 6], "S3": []]))
    let r = try await call([#"{"id":1,"cmd":"diarize","wav":"\#(wav.path)"}"#], diarizer: { fake })
    #expect(r[0]["ok"] as? Bool == true)
    let turns = r[0]["turns"] as! [[String: Any]]
    let starts = turns.map { $0["start"] as! Double }, ends = turns.map { $0["end"] as! Double }
    #expect(starts == starts.sorted())
    for i in 1..<turns.count { #expect(ends[i - 1] <= starts[i]) }
    #expect(turns.first?["speaker"] as? String == "SPEAKER_00")
    // Only labels with turns and a usable vector get an embedding.
    let emb = r[0]["embeddings"] as! [String: [Double]]
    #expect(emb.keys.sorted() == ["SPEAKER_00", "SPEAKER_01"])
    #expect(emb["SPEAKER_00"] == [1, 2])
    #expect(r[0]["seconds"] is Double)
}

@Test func clippedAwaySpeakerLeavesNoLabelGapOrEmbedding() async throws {
    let dir = try tempDir()
    let wav = dir.appendingPathComponent("a.wav")
    try writeSilence(wav, samples: 16000 * 20)
    // S2's only turn has no length: it must not take a label or keep an embedding.
    let fake = FakeDiarizer(output: DiarizerOutput(
        segments: [("S1", 0, 4), ("S2", 4, 4), ("S3", 4, 9)],
        embeddings: ["S1": [1], "S2": [2], "S3": [3]]))
    let r = try await call([#"{"id":1,"cmd":"diarize","wav":"\#(wav.path)"}"#], diarizer: { fake })
    let turns = r[0]["turns"] as! [[String: Any]]
    #expect(turns.map { $0["speaker"] as! String } == ["SPEAKER_00", "SPEAKER_01"])
    let emb = r[0]["embeddings"] as! [String: [Double]]
    #expect(emb == ["SPEAKER_00": [1], "SPEAKER_01": [3]])
}

@Test func failedLoadLeavesTheModelsFolderIntact() async throws {
    let models = try tempDir()
    let folder = models.appendingPathComponent(ModelStore.diarizerFolder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let names = ["Segmentation.mlmodelc", "Embedding.mlmodelc", "FBank.mlmodelc", "PldaRho.mlmodelc", "plda-parameters.json"]
    for n in names { try Data("not a model".utf8).write(to: folder.appendingPathComponent(n)) }
    let wav = models.appendingPathComponent("a.wav")
    try writeSilence(wav, samples: 16000 * 2)
    let inPipe = Pipe(), outPipe = Pipe()
    inPipe.fileHandleForWriting.write(Data((#"{"id":1,"cmd":"diarize","wav":"\#(wav.path)"}"# + "\n").utf8))
    try inPipe.fileHandleForWriting.close()
    await serve(input: inPipe.fileHandleForReading, output: outPipe.fileHandleForWriting,
                handler: engineHandler(version: "t", modelsDir: models))
    try outPipe.fileHandleForWriting.close()
    let reply = try JSONSerialization.jsonObject(with: outPipe.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
    #expect(reply["ok"] as? Bool == false)
    #expect((reply["error"] as? String)?.isEmpty == false)
    for n in names {
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(n).path), "\(n) was deleted")
    }
}

@Test func engineConfigIsExclusive() {
    #expect(diarizerConfig().postProcessing.exclusiveSegments == true)
}

@Test func embedAveragesSpansPerKey() async throws {
    let dir = try tempDir()
    let wav = dir.appendingPathComponent("a.wav")
    try writeSilence(wav, samples: 16000 * 10)
    let fake = FakeDiarizer(output: DiarizerOutput(segments: [], embeddings: [:]), spanVectors: [[1, 2], [3, 6]])
    let r = try await call([
        #"{"id":1,"cmd":"embed","wav":"\#(wav.path)","spans":{"a":[[0,2],[3,5]]}}"#,
        #"{"id":2,"cmd":"embed","wav":"\#(wav.path)","spans":{"a":[]}}"#,
        #"{"id":3,"cmd":"embed","wav":"\#(wav.path)","spans":{"a":[[2,1]]}}"#,
        #"{"id":4,"cmd":"embed","wav":"\#(wav.path)"}"#,
    ], diarizer: { fake })
    #expect(r[0]["ok"] as? Bool == true)
    #expect((r[0]["embeddings"] as? [String: [Double]])?["a"] == [2, 4])
    for i in 1...3 { #expect(r[i]["ok"] as? Bool == false) }
}

@Test func missingDiarizerModelsIsNamed() async throws {
    let dir = try tempDir()
    let wav = dir.appendingPathComponent("a.wav")
    try writeSilence(wav, samples: 16000 * 2)
    let r = try await call([#"{"id":1,"cmd":"diarize","wav":"\#(wav.path)"}"#], diarizer: nil)
    #expect(r[0]["ok"] as? Bool == false)
    #expect((r[0]["error"] as? String)?.hasPrefix("models missing: diarizer") == true)
}

// MARK: - Model test

private let enabled = ProcessInfo.processInfo.environment["PALAVER_ENGINE_MODEL_TESTS"] == "1"
/// Anna plus the first installed German second voice (Markus on older systems).
private let voices: [String]? = {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", "?"]
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return nil }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    let names = out.split(separator: "\n")
    guard names.contains(where: { $0.hasPrefix("Anna ") }) else { return nil }
    for second in ["Markus", "Reed (German (Germany))", "Rocko (German (Germany))", "Grandpa (German (Germany))", "Eddy (German (Germany))"]
    where names.contains(where: { $0.hasPrefix(second + " ") }) {
        return ["Anna", second]
    }
    return nil
}()

/// Two synthetic voices, alternating in ~5 s turns, ~40 s in all.
private let diarizerCache = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/FluidAudio/Models/\(ModelStore.diarizerFolder)")
private let cachePresent = ModelStore(directory: diarizerCache.deletingLastPathComponent()).isReady("diarizer")

@Test(.enabled(if: enabled && voices != nil && cachePresent, "needs PALAVER_ENGINE_MODEL_TESTS=1 and Anna and a second German voice, and FluidAudio's cached diarizer models"))
func diarizesTwoVoices() async throws {
    let tmp = try tempDir()
    defer { try? FileManager.default.removeItem(at: tmp) }
    let text = "Wir haben heute viel zu besprechen. Zuerst geht es um das Deployment für Contoso, danach um die Planung der nächsten Woche, und zum Schluss um die offenen Fragen von Northwind."
    var samples: [[Float]] = []
    var owner: [String] = []
    for turn in 0..<8 {
        let voice = voices![turn % 2]
        let aiff = tmp.appendingPathComponent("t\(turn).aiff").path, wav = tmp.appendingPathComponent("t\(turn).wav").path
        #expect(try sh("/usr/bin/say", ["-v", voice, "-o", aiff, text]) == 0)
        #expect(try sh("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav]) == 0)
        var s = try readWav(URL(fileURLWithPath: wav))
        s = Array(s.prefix(16000 * 5))  // ~5 s turns
        samples.append(s); owner.append(voice)
    }
    // Concatenate in Swift, remembering each turn's time range.
    var all: [Float] = [], ranges: [(String, Double, Double)] = []
    for (s, v) in zip(samples, owner) {
        ranges.append((v, Double(all.count) / 16000, Double(all.count + s.count) / 16000))
        all += s
    }
    let wav = tmp.appendingPathComponent("mix.wav")
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    do {
        let file = try AVAudioFile(forWriting: wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(all.count))!
        buf.frameLength = AVAudioFrameCount(all.count)
        all.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: all.count) }
        try file.write(from: buf)
    }

    // Models: a copy of FluidAudio's default cache (never deleted).
    let models = tmp.appendingPathComponent("models")
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: diarizerCache, to: models.appendingPathComponent(ModelStore.diarizerFolder))

    // `prepare` (which may download) first, then the lazy load in `diarize`.
    let inPipe = Pipe(), outPipe = Pipe()
    inPipe.fileHandleForWriting.write(Data((#"{"id":0,"cmd":"prepare","models":["diarizer"]}"# + "\n"
        + #"{"id":1,"cmd":"diarize","wav":"\#(wav.path)"}"# + "\n").utf8))
    try inPipe.fileHandleForWriting.close()
    await serve(input: inPipe.fileHandleForReading, output: outPipe.fileHandleForWriting,
                handler: engineHandler(version: "t", modelsDir: models))
    try outPipe.fileHandleForWriting.close()
    let lines = try String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    let prep = lines.first { $0["id"] as? Int == 0 && $0["ok"] != nil }!
    #expect(prep["ready"] as? [String] == ["diarizer"], "prepare: \(prep)")
    let reply = lines.last!
    #expect(reply["ok"] as? Bool == true, "\(reply["error"] ?? "")")
    let turns = reply["turns"] as! [[String: Any]]
    let labels = Set(turns.map { $0["speaker"] as! String })
    #expect(labels == ["SPEAKER_00", "SPEAKER_01"], "\(labels.count) labels, \(turns.count) turns, \(all.count / 16000) s audio")
    #expect((reply["embeddings"] as? [String: [Double]])?.values.allSatisfy { $0.count == 256 } == true)

    // For each voice: share of its audio that falls in its most common label.
    for voice in voices! {
        var overlap: [String: Double] = [:], total = 0.0
        for (v, s, e) in ranges where v == voice {
            total += e - s
            for t in turns {
                let ts = t["start"] as! Double, te = t["end"] as! Double
                overlap[t["speaker"] as! String, default: 0] += max(0, min(e, te) - max(s, ts))
            }
        }
        let best = overlap.values.max() ?? 0
        #expect(best / total >= 0.8, "\(voice == "Anna" ? "Anna" : "second voice"): \(Int(100 * best / total)) % in one label")
    }
}
