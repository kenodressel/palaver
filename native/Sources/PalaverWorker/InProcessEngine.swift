// The speech engine in the worker's own process: the palaver-engine command table (`engineHandler`) called
// directly instead of over JSON lines, its replies mapped to the domain's segments, words and turns as
// transcriber.py's `EngineTranscriber` and diarizer.py's `EngineDiarizer` map palaver-engine's.
import Foundation
import PalaverCore
import PalaverDomain
import PalaverEngine

public final class InProcessEngine: EngineCalls, @unchecked Sendable {
    public typealias Handler = (Request, Emitter) async throws -> [String: Any]

    private var handler: Handler
    private let makeHandler: () -> Handler
    private let store: ModelStore
    private let dictionary: TranscriberDictionary
    private let lock = NSLock()
    /// One command at a time, as palaver-engine serves them and engine.py's client sends them: a second call waits
    /// for the first (two loads of Parakeet at once would double the memory, and the engine's model state is not
    /// made for concurrent use).
    private let gate = AsyncGate()
    private var nextID = 0
    private var _succeeded: Set<String> = []

    /// The engine's models in `modelsDir` (loaded on first use, never downloaded); `recognizer`/`diarizer` replace
    /// the models (tests).
    public init(version: String, modelsDir: URL = ModelStore.defaultDirectory, dictionary: TranscriberDictionary = TranscriberDictionary(),
                recognizer: (() async throws -> Recognizer)? = nil, diarizer: (() async throws -> Diarizing)? = nil) {
        makeHandler = { engineHandler(version: version, modelsDir: modelsDir, recognizer: recognizer, diarizer: diarizer) }
        handler = makeHandler()
        store = ModelStore(directory: modelsDir)
        self.dictionary = dictionary
    }

    /// The commands answered well so far (engine.py `SUCCEEDED`): "transcribe" and "diarize" both make the proof
    /// that the speech models work.
    public var succeeded: Set<String> {
        lock.withLock { _succeeded }
    }

    /// One command, its reply as the engine writes it (without `id`/`ok`). An engine error that says the models are
    /// missing throws `ModelsMissing`, any other `EngineError`.
    public func call(_ cmd: String, _ args: [String: Any] = [:], progress: FileHandle = .nullDevice) async throws -> [String: Any] {
        await gate.enter()
        defer { gate.leave() }
        let id = lock.withLock { nextID += 1; return nextID }
        var all = args
        all["id"] = id
        all["cmd"] = cmd
        do {
            let reply = try await handler(Request(id: id, cmd: cmd, args: all), Emitter(id: id, output: progress))
            _ = lock.withLock { _succeeded.insert(cmd) }
            return reply
        } catch let error as EngineError where error.description.hasPrefix("models missing") {
            throw ModelsMissing(error.description)
        }
    }

    /// Drops the loaded models (Parakeet, the diarizer), after the call running now; the next call loads what it
    /// needs again. Python's pipeline closed its engine after the tracks and before the notes (`_close_engine`).
    public func release() async {
        await gate.enter()
        defer { gate.leave() }
        handler = makeHandler()
    }

    public func modelsReady() -> Bool { ModelStore.names.allSatisfy(store.isReady) }

    public func transcribe(wav: URL) async throws -> [PalaverDomain.Segment] {
        guard EngineAudio.holdsAudio(wav) else { return [] }
        let reply = try await call("transcribe", ["wav": wav.path])
        return (reply["segments"] as? [[String: Any]] ?? []).map { raw in
            PalaverDomain.Segment(start: number(raw["start"]), end: number(raw["end"]),
                                  text: Py.strip(dictionary.apply(raw["text"] as? String ?? "")),
                                  speaker: nil, words: words(raw["words"]))
        }
    }

    public func transcribeWindow(_ samples: [Float]) async throws -> [PalaverDomain.Word] {
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
        let reply = try await call("transcribe_window", ["pcm": pcm])
        return words(reply["words"])
    }

    public func diarize(wav: URL) async throws -> (turns: [SpeakerTurn], embeddings: PyDict<[Double]>) {
        guard EngineAudio.holdsAudio(wav) else { return ([], PyDict()) }
        let reply = try await call("diarize", ["wav": wav.path])
        let turns = (reply["turns"] as? [[String: Any]] ?? []).map {
            SpeakerTurn(speaker: "\($0["speaker"] ?? "")", start: number($0["start"]), end: number($0["end"]))
        }
        // The engine writes its labels in order (palaver-engine sorts the reply's keys): SPEAKER_00, SPEAKER_01, ...
        let raw = reply["embeddings"] as? [String: Any] ?? [:]
        var embeddings = PyDict<[Double]>()
        for label in raw.keys.sorted() {
            embeddings[label] = (raw[label] as? [Any] ?? []).map(number)
        }
        return (Py.stableSorted(turns) { $0.start < $1.start }, embeddings)
    }

    private func words(_ value: Any?) -> [PalaverDomain.Word] {
        (value as? [[String: Any]] ?? []).map {
            PalaverDomain.Word(text: dictionary.apply($0["text"] as? String ?? ""), start: number($0["start"]),
                               end: number($0["end"]), confidence: ($0["confidence"]).map(number))
        }
    }
}

/// A first-come, first-served lock for async code: `enter` waits (without blocking a thread) until the holder
/// `leave`s.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if held { waiting.append(c); return false }
                held = true
                return true
            }
            if now { c.resume() }
        }
    }

    func leave() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiting.isEmpty { held = false; return nil }
            return waiting.removeFirst()  // stays held: handed to the next one
        }
        next?.resume()
    }
}

/// A reply's number (`float(raw["start"])`).
private func number(_ value: Any?) -> Double {
    switch value {
    case let d as Double: return d
    case let f as Float: return Double(f)
    case let i as Int: return Double(i)
    case let n as NSNumber: return n.doubleValue
    default: return 0
    }
}
