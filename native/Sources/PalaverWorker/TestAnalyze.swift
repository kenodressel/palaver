// `palaver-worker test-analyze <mic|-> [--system WAV] [--mode JSON]`: what the setup assistant's test recording found
// (onboarding.py `level_db`, `_analyze`, `_transcribe`; cli.py `_cmd_onboarding` with --checks). The app records the
// test; this looks at the audio: both tracks' loudness, and the mic track's words through the speech engine in this
// process when the models are on this Mac (never downloaded for the test). With a cloud transcription service chosen,
// levels only: the test sends nothing. One JSON line: {"mic": {...}, "system": {...}, "checks": [...]}.
import AVFoundation
import Foundation
import PalaverCore
import PalaverDomain

public enum TestAnalysis {
    /// The track's loudness (RMS over every sample of every channel, dBFS, one decimal); nil when it has no audio or
    /// can't be read.
    public static func levelDb(_ wav: URL?) -> Double? {
        guard let wav, FileManager.default.fileExists(atPath: wav.path),
              let file = try? AVAudioFile(forReading: wav) else { return nil }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let chunk: AVAudioFrameCount = 262_144
        guard channels > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
        var sum = 0.0
        var count = 0
        while true {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let got = Int(buffer.frameLength)
            if got == 0 { break }
            guard let data = buffer.floatChannelData else { return nil }
            for c in 0..<channels {
                let p = data[c]
                for i in 0..<got { let x = Double(p[i]); sum += x * x }
            }
            count += got * channels
        }
        guard count > 0 else { return nil }
        let rms = (sum / Double(count)).squareRoot()
        return (20 * log10(max(rms, 1e-6)) * 10).rounded() / 10
    }

    /// `_analyze`: the levels of both tracks, and the mic track's words when someone spoke into it and the models are
    /// here; `speechHere`/`transcribe` are the engine's (the words joined, nil when it gave none or failed).
    public static func analyze(mic: URL?, system: URL?, mode: JSONValue, speechHere: () -> Bool,
                               transcribe: (URL) async -> String?) async -> JSONValue {
        let micLevel = levelDb(mic)
        var out: [(String, JSONValue)] = [("recorded", .bool(mic != nil)), ("level_db", .num(micLevel)), ("text", .null)]
        func set(_ key: String, _ value: JSONValue) {
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1 = value } else { out.append((key, value)) }
        }
        if let mic, (micLevel ?? -120) > TestVerdict.SPEECH_DB {
            if mode["transcribe"]?.stringValue == "cloud" {
                set("transcript", .string("cloud"))
                set("service", mode["service"] ?? .null)
            } else if !speechHere() {
                set("transcript", .string("not_downloaded"))
            } else {
                let text = await transcribe(mic)
                set("text", .str(text))
                set("transcript", .string(text != nil ? "done" : "failed"))
            }
        }
        return .object([("mic", .object(out)),
                        ("system", .object([("recorded", .bool(system != nil)), ("level_db", .num(levelDb(system)))]))])
    }

    /// The result with the verdict the setup page shows (`--checks`).
    public static func withChecks(_ result: JSONValue) -> JSONValue {
        guard case .object(var pairs) = result else { return result }
        let checks = TestVerdict.checks(PyDict<JSONValue>(result) ?? PyDict()).map(\.json)
        pairs.append(("checks", .array(checks)))
        return .object(pairs)
    }

    /// The words of `wav` through `engine` (its segments' texts joined); nil for none or a failure.
    public static func words(_ wav: URL, engine: EngineCalls) async -> String? {
        guard let segments = try? await engine.transcribe(wav: wav) else { return nil }
        let text = Py.strip(segments.map { Py.strip($0.text) }.joined(separator: " "))
        return text.isEmpty ? nil : text
    }
}

extension WorkerMain {
    /// `test-analyze <mic|-> [--system WAV] [--mode JSON]`: "-" means no microphone track was written.
    static func testAnalyze(_ o: Options, env: [String: String]) async throws -> Int32 {
        guard let first = o.args.first else { throw UsageError(description: "test-analyze needs the microphone track (or -)") }
        func existing(_ path: String?) -> URL? {
            guard let path, path != "-" else { return nil }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        var mode = JSONValue.object([])
        if let text = try flag("--mode", in: o.args) {
            guard let parsed = try? PythonJSON.parse(Data(text.utf8)), case .object = parsed else {
                throw UsageError(description: "--mode: not a JSON object")
            }
            mode = parsed
        }
        let mic = existing(first), system = existing(try flag("--system", in: o.args))
        // The test's own engine (the user's dictionary is not applied: the words only show that the mic hears).
        let engine = makeEngine(config: loadConfig(o, env: env), dictionary: TranscriberDictionary(), env: env, log: nil)
        let result = await TestAnalysis.analyze(mic: mic, system: system, mode: mode, speechHere: { engine.modelsReady() },
                                                transcribe: { await TestAnalysis.words($0, engine: engine) })
        await engine.release()
        return answerAlone { (TestAnalysis.withChecks(result).encoded(indent: nil), 0) }
    }
}
