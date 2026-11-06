import AVFoundation
import FluidAudio
import Foundation

// MARK: - Turns (pure, no model)

public struct Turn: Equatable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double

    var json: [String: Any] { ["speaker": speaker, "start": start, "end": end] }
}

/// Renames FluidAudio's speaker ids to SPEAKER_00, SPEAKER_01, ... in order of
/// each speaker's first turn (by start time). Turns come back sorted by start.
public func relabel(_ segments: [(String, Double, Double)]) -> (turns: [Turn], map: [String: String]) {
    let sorted = segments.enumerated().sorted {
        ($0.element.1, $0.offset) < ($1.element.1, $1.offset)
    }.map(\.element)
    var map: [String: String] = [:]
    var turns: [Turn] = []
    for (id, start, end) in sorted {
        if map[id] == nil { map[id] = String(format: "SPEAKER_%02d", map.count) }
        turns.append(Turn(speaker: map[id]!, start: start, end: end))
    }
    return (turns, map)
}

/// Makes turns non-overlapping: a turn that runs into the next one is
/// cut at the next one's start; a turn left with no length is dropped.
/// (`exclusiveSegments` already guarantees this; the engine does not rely on it.)
func exclusive(_ turns: [Turn]) -> [Turn] {
    var out: [Turn] = []
    for t in turns.enumerated().sorted(by: { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }).map(\.element) {
        if var last = out.last, last.end > t.start {
            last.end = t.start
            out.removeLast()
            if last.end > last.start { out.append(last) }
        }
        if t.end > t.start { out.append(t) }
    }
    return out
}

/// The diarizer config the engine uses: one speaker at a time.
func diarizerConfig() -> OfflineDiarizerConfig {
    var config = OfflineDiarizerConfig()
    config.postProcessing.exclusiveSegments = true
    return config
}

// MARK: - Diarizer

public struct DiarizerOutput: Sendable {
    public var segments: [(String, Double, Double)]
    public var embeddings: [String: [Float]]
    public init(segments: [(String, Double, Double)], embeddings: [String: [Float]]) {
        self.segments = segments; self.embeddings = embeddings
    }
}

public protocol Diarizing: Sendable {
    /// Turns and one embedding per FluidAudio speaker id.
    func diarize(_ url: URL) async throws -> DiarizerOutput
    /// One embedding per span (seconds), in order.
    func embed(_ url: URL, spans: [Range<Double>]) async throws -> [[Float]]
}

/// FluidAudio's offline diarizer.
public final class FluidDiarizer: Diarizing, @unchecked Sendable {
    private let manager: OfflineDiarizerManager
    init(manager: OfflineDiarizerManager) { self.manager = manager }

    public func diarize(_ url: URL) async throws -> DiarizerOutput {
        let result = try await manager.process(url)  // disk-backed, resamples itself
        return DiarizerOutput(
            segments: result.segments.map { ($0.speakerId, Double($0.startTimeSeconds), Double($0.endTimeSeconds)) },
            embeddings: result.speakerDatabase ?? [:])
    }

    public func embed(_ url: URL, spans: [Range<Double>]) async throws -> [[Float]] {
        let (source, _) = try AudioSourceFactory().makeDiskBackedSource(from: url, targetSampleRate: 16000)
        defer { source.cleanup() }
        return try await manager.embedSpans(audioSource: source, spans: spans)
    }
}

/// Turns and embeddings of a WAV under the engine's labels. A track shorter than
/// 50 ms gives nothing, without loading the model.
func diarizeFile(_ url: URL, with load: () async throws -> Diarizing) async throws -> (turns: [Turn], embeddings: [String: [Float]]) {
    let file = try AVAudioFile(forReading: url)
    if Double(file.length) / file.processingFormat.sampleRate < Double(minSamples) / engineSampleRate { return ([], [:]) }
    let output: DiarizerOutput
    do {
        output = try await load().diarize(url)
    } catch OfflineDiarizationError.noSpeechDetected {
        return ([], [:])  // nobody spoke on this track (yet): no turns, not a failure
    }
    // Clip overlaps first, so a speaker left with no turn takes no label.
    let clipped = exclusive(output.segments.map { Turn(speaker: $0.0, start: $0.1, end: $0.2) })
    let (turns, map) = relabel(clipped.map { ($0.speaker, $0.start, $0.end) })
    var embeddings: [String: [Float]] = [:]
    for (id, vector) in output.embeddings {
        // A label that has turns, and a clean vector; anything else is left out.
        if let label = map[id], !vector.isEmpty, vector.allSatisfy(\.isFinite) { embeddings[label] = vector }
    }
    return (turns, embeddings)
}

/// Element-wise mean of equally long vectors.
func mean(_ vectors: [[Float]]) -> [Float] {
    guard let n = vectors.first?.count else { return [] }
    var sum = [Float](repeating: 0, count: n)
    for v in vectors { for i in 0..<n { sum[i] += v[i] } }
    return sum.map { $0 / Float(vectors.count) }
}

// MARK: - Commands

final class SpeakerEngine: @unchecked Sendable {
    let store: ModelStore
    private let makeDiarizer: (() async throws -> Diarizing)?
    private var diarizer: Diarizing?

    init(store: ModelStore, diarizer: (() async throws -> Diarizing)?) {
        self.store = store
        self.makeDiarizer = diarizer
    }

    /// Loaded on first use and kept. Never downloads: that is `prepare`'s job.
    func loadedDiarizer() async throws -> Diarizing {
        if let d = diarizer { return d }
        let d: Diarizing
        if let make = makeDiarizer {
            d = try await make()
        } else {
            guard store.isReady("diarizer") else { throw EngineError("models missing: diarizer") }
            let was = ModelHub.offlineMode
            ModelHub.offlineMode = true
            defer { ModelHub.offlineMode = was }
            // Not `prepareModels`: on a failed load it deletes the models folder
            // and downloads again. A lazy load only reads; errors surface as is.
            let models = try await OfflineDiarizerModels.load(from: store.directory)
            let manager = OfflineDiarizerManager(config: diarizerConfig())
            manager.initialize(models: models)
            d = FluidDiarizer(manager: manager)
        }
        diarizer = d
        return d
    }

    private func existingURL(_ args: [String: Any], cmd: String) throws -> URL {
        guard let wav = args["wav"] as? String else { throw EngineError("\(cmd) needs a wav path") }
        let url = URL(fileURLWithPath: wav)
        guard FileManager.default.fileExists(atPath: url.path) else { throw EngineError("no such file: \(wav)") }
        return url
    }

    func diarize(_ args: [String: Any]) async throws -> [String: Any] {
        let url = try existingURL(args, cmd: "diarize")
        let t0 = Date()
        let r = try await diarizeFile(url) { try await self.loadedDiarizer() }
        return ["turns": r.turns.map(\.json),
                "embeddings": r.embeddings.mapValues { $0.map(Double.init) },
                "seconds": Date().timeIntervalSince(t0)]
    }

    func embed(_ args: [String: Any]) async throws -> [String: Any] {
        let url = try existingURL(args, cmd: "embed")
        guard let spec = args["spans"] as? [String: Any] else {
            throw EngineError("embed needs spans: an object of key to [[start, end], ...]")
        }
        var parsed: [(String, [Range<Double>])] = []
        for key in spec.keys.sorted() {
            guard let list = spec[key] as? [Any], !list.isEmpty else {
                throw EngineError("spans for \(key) must be a non-empty list of [start, end]")
            }
            var ranges: [Range<Double>] = []
            for item in list {
                guard let pair = item as? [Any], pair.count == 2,
                      let s = number(pair[0]), let e = number(pair[1]), s.isFinite, e.isFinite, s >= 0, e > s
                else { throw EngineError("spans for \(key) must be [start, end] seconds with 0 <= start < end") }
                ranges.append(s..<e)
            }
            parsed.append((key, ranges))
        }
        var out: [String: Any] = [:]
        if !parsed.isEmpty {
            let d = try await loadedDiarizer()
            for (key, ranges) in parsed {
                let vectors = try await d.embed(url, spans: ranges)
                guard vectors.count == ranges.count, vectors.allSatisfy({ $0.count == vectors[0].count && !$0.isEmpty }) else {
                    throw EngineError("no embedding for \(key)")
                }
                let m = mean(vectors)
                guard m.allSatisfy(\.isFinite) else { throw EngineError("no embedding for \(key)") }
                out[key] = m.map(Double.init)
            }
        }
        return ["embeddings": out]
    }
}

/// A JSON number (not a boolean) as a Double.
private func number(_ value: Any) -> Double? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    return n.doubleValue
}
