// Debug builds only: the engine's answers from a JSON file (`PALAVER_TEST_ENGINE`), for the end-to-end and
// parity runs of the worker without models. The file:
//
//   {"models_ready": true,
//    "transcribe": {"system.wav": [segment, ...], "mic.wav": [...], "*": [...]},
//    "windows": [word, ...],
//    "diarize": {"system.wav": {"turns": [turn, ...], "embeddings": {"SPEAKER_00": [numbers]}}},
//    "fail": {"transcribe": "message", "diarize": "models missing: diarizer"},
//    "cloud": {"segments": [segment, ...], "language": "de", "model": "m", "sent_seconds": 20.0}}
//
// "cloud" is what the chosen transcription service hears (CloudServices.heard): no service, key or network is reached.
// Segments, words and turns are written as the meeting files write them; a WAV is looked up by its file name,
// then "*"; anything not listed answers nothing. The dictionary is applied as the real engine's mapping does.
#if DEBUG
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

public final class FakeEngine: EngineCalls {
    public static let ENV = "PALAVER_TEST_ENGINE"

    private let spec: JSONValue
    private let dictionary: TranscriberDictionary
    public private(set) var succeeded: Set<String> = []
    /// The calls in order ("transcribe mic.wav", "diarize system.wav", "release"): what a test checks.
    public private(set) var calls: [String] = []

    public init(spec: JSONValue, dictionary: TranscriberDictionary = TranscriberDictionary()) {
        self.spec = spec
        self.dictionary = dictionary
    }

    /// The fake `env` names, if any.
    public static func fromEnvironment(_ env: [String: String], dictionary: TranscriberDictionary) -> FakeEngine? {
        guard let file = env[ENV], !file.isEmpty else { return nil }
        return FakeEngine(spec: PythonJSON.read(URL(fileURLWithPath: file)) ?? .object([]), dictionary: dictionary)
    }

    /// The spec's `"cloud"` as the service's answer; nil without one.
    public static func cloudHeard(_ env: [String: String]) -> ((RecordingPaths, String) throws -> CloudTranscription.Outcome)? {
        guard let file = env[ENV], !file.isEmpty, let cloud = PythonJSON.read(URL(fileURLWithPath: file))?["cloud"],
              case .object = cloud else { return nil }
        return { _, _ in
            CloudTranscription.Outcome(segments: try (cloud["segments"]?.arrayValue ?? []).map { try Segment(json: $0) },
                                       language: cloud["language"]?.stringValue, sentSeconds: cloud["sent_seconds"]?.doubleValue ?? 0,
                                       model: cloud["model"]?.stringValue ?? "fake")
        }
    }

    private func entry(_ cmd: String, _ wav: URL) -> JSONValue? {
        spec[cmd]?[wav.lastPathComponent] ?? spec[cmd]?["*"]
    }

    private func failure(_ cmd: String) throws {
        guard let message = spec["fail"]?[cmd]?.stringValue else { return }
        if message.hasPrefix("models missing") { throw ModelsMissing(message) }
        throw WorkerError(message)
    }

    public func release() async { calls.append("release") }

    public func modelsReady() -> Bool { spec["models_ready"]?.truthy ?? true }

    public func transcribe(wav: URL) async throws -> [Segment] {
        calls.append("transcribe \(wav.lastPathComponent)")
        try failure("transcribe")
        guard EngineAudio.holdsAudio(wav) else { return [] }
        succeeded.insert("transcribe")
        return try (entry("transcribe", wav)?.arrayValue ?? []).map {
            var s = try Segment(json: $0)
            s.text = Py.strip(dictionary.apply(s.text))
            s.speaker = nil
            s.words = s.words.map { var w = $0; w.text = dictionary.apply(w.text); return w }
            return s
        }
    }

    public func transcribeWindow(_ samples: [Float]) async throws -> [Word] {
        try failure("transcribe_window")
        return try (spec["windows"]?.arrayValue ?? []).map {
            var w = try Word(json: $0)
            w.text = dictionary.apply(w.text)
            return w
        }
    }

    public func diarize(wav: URL) async throws -> (turns: [SpeakerTurn], embeddings: PyDict<[Double]>) {
        calls.append("diarize \(wav.lastPathComponent)")
        try failure("diarize")
        guard EngineAudio.holdsAudio(wav) else { return ([], PyDict()) }
        succeeded.insert("diarize")
        guard let found = entry("diarize", wav) else { return ([], PyDict()) }
        let turns = try (found["turns"]?.arrayValue ?? []).map { try SpeakerTurn(json: $0) }
        var embeddings = PyDict<[Double]>()
        if case .object(let fields)? = found["embeddings"] {
            for (label, row) in fields { embeddings[label] = (row.arrayValue ?? []).compactMap(\.doubleValue) }
        }
        return (Py.stableSorted(turns) { $0.start < $1.start }, embeddings)
    }
}
#endif
