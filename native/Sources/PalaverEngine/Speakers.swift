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

/// The diarizer config the engine uses: one speaker at a time; with `maxSpeakers` (what the calendar says the track
/// can hold, #21), at most that many: FluidAudio clusters its voices again into that many when it finds more.
func diarizerConfig(maxSpeakers: Int? = nil) -> OfflineDiarizerConfig {
    var config = OfflineDiarizerConfig()
    config.postProcessing.exclusiveSegments = true
    if let maxSpeakers { config = config.withSpeakers(max: maxSpeakers) }
    return config
}

// MARK: - One person split in several (#21)

/// Two of the diarizer's speakers whose voices (the mean embedding of each) are at least this alike are one person
/// it split, by pauses, noise or a change of codec. Palaver's own numbers (`make eval-voices`, the owner's meetings):
/// two people stay below 0.52 in 99 of 100 pairs, one person in two meetings mostly scores 0.6-0.9. 0.82 is
/// FluidAudio's own cut between "one speaker" and "two" (its clustering threshold, 0.6 Euclidean between unit
/// vectors: 1 - 0.6² / 2): clear of the different people, and within one meeting (one codec, one room) the same
/// person's parts score higher than across meetings.
public let SAME_VOICE_SIMILARITY = 0.82

/// Folds the diarizer's speakers whose voices are SAME_VOICE_SIMILARITY alike into one, before they get labels:
/// average-voice (centroid) linkage, closest pair first, the voices weighted by talk time. The merged speaker keeps
/// the id of its part that talked most and the talk-weighted mean of the parts' vectors. A speaker without a usable
/// vector (none, not finite, of another length) is left as it is. `merged`: how many speakers were folded in.
func mergeCloseVoices(_ turns: [Turn], _ embeddings: [String: [Float]], threshold: Double = SAME_VOICE_SIMILARITY)
    -> (turns: [Turn], embeddings: [String: [Float]], merged: Int)
{
    var order: [String] = [], talk: [String: Double] = [:]
    for t in turns {
        if talk[t.speaker] == nil { order.append(t.speaker) }
        talk[t.speaker, default: 0] += t.end - t.start
    }
    var unit: [String: [Double]] = [:], dim: Int?
    for id in order {
        guard let v = embeddings[id], !v.isEmpty, v.allSatisfy(\.isFinite), (talk[id] ?? 0) > 0, dim == nil || dim == v.count
        else { continue }
        let norm = v.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        guard norm > 0 else { continue }
        dim = v.count
        unit[id] = v.map { Double($0) / norm }
    }
    func centroid(_ group: [String]) -> [Double] {
        var sum = [Double](repeating: 0, count: dim ?? 0)
        for id in group { for (i, x) in unit[id]!.enumerated() { sum[i] += x * talk[id]! } }
        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return sum.map { $0 / norm }
    }
    var groups = order.filter { unit[$0] != nil }.map { [$0] }
    while groups.count > 1 {
        let centroids = groups.map(centroid)
        var best: (Int, Int, Double)?
        for i in 0..<groups.count {
            for j in (i + 1)..<groups.count {
                let sim = zip(centroids[i], centroids[j]).reduce(0) { $0 + $1.0 * $1.1 }
                if sim >= threshold, sim > best?.2 ?? -2 { best = (i, j, sim) }
            }
        }
        guard let (i, j, _) = best else { break }
        let folded = groups.remove(at: j)  // i < j: still in place
        groups[i] += folded
    }
    var into: [String: String] = [:], out = embeddings, merged = 0
    for group in groups where group.count > 1 {
        let keep = group.max { (talk[$0]!, -order.firstIndex(of: $0)!) < (talk[$1]!, -order.firstIndex(of: $1)!) }!
        let total = group.reduce(0) { $0 + talk[$1]! }
        var mean = [Double](repeating: 0, count: dim!)
        for id in group {
            for (i, x) in embeddings[id]!.enumerated() { mean[i] += Double(x) * talk[id]! / total }
            if id != keep { into[id] = keep; out[id] = nil; merged += 1 }
        }
        out[keep] = mean.map(Float.init)
    }
    return (turns.map { Turn(speaker: into[$0.speaker] ?? $0.speaker, start: $0.start, end: $0.end) }, out, merged)
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
    /// Turns and one embedding per FluidAudio speaker id; `maxSpeakers`: at most that many speakers.
    func diarize(_ url: URL, maxSpeakers: Int?) async throws -> DiarizerOutput
    /// One embedding per span (seconds), in order.
    func embed(_ url: URL, spans: [Range<Double>]) async throws -> [[Float]]
}

/// FluidAudio's offline diarizer: one manager per speaker count asked for (a manager's config is fixed), all on the
/// same loaded models.
public final class FluidDiarizer: Diarizing, @unchecked Sendable {
    private let models: OfflineDiarizerModels
    private let manager: OfflineDiarizerManager
    private var bounded: [Int: OfflineDiarizerManager] = [:]
    private let lock = NSLock()

    init(models: OfflineDiarizerModels) {
        self.models = models
        manager = Self.manager(models, maxSpeakers: nil)
    }

    private static func manager(_ models: OfflineDiarizerModels, maxSpeakers: Int?) -> OfflineDiarizerManager {
        let manager = OfflineDiarizerManager(config: diarizerConfig(maxSpeakers: maxSpeakers))
        manager.initialize(models: models)
        return manager
    }

    private func manager(maxSpeakers: Int?) -> OfflineDiarizerManager {
        guard let maxSpeakers else { return manager }
        return lock.withLock {
            if let m = bounded[maxSpeakers] { return m }
            let m = Self.manager(models, maxSpeakers: maxSpeakers)
            bounded[maxSpeakers] = m
            return m
        }
    }

    public func diarize(_ url: URL, maxSpeakers: Int?) async throws -> DiarizerOutput {
        let result = try await manager(maxSpeakers: maxSpeakers).process(url)  // disk-backed, resamples itself
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

/// Turns and embeddings of a WAV under the engine's labels, speakers with the same voice folded into one
/// (`mergeCloseVoices`; `merged`: how many). A track shorter than 50 ms gives nothing, without loading the model.
func diarizeFile(_ url: URL, maxSpeakers: Int? = nil, with load: () async throws -> Diarizing) async throws
    -> (turns: [Turn], embeddings: [String: [Float]], merged: Int)
{
    let file = try AVAudioFile(forReading: url)
    if Double(file.length) / file.processingFormat.sampleRate < Double(minSamples) / engineSampleRate { return ([], [:], 0) }
    let output: DiarizerOutput
    do {
        output = try await load().diarize(url, maxSpeakers: maxSpeakers)
    } catch OfflineDiarizationError.noSpeechDetected {
        return ([], [:], 0)  // nobody spoke on this track (yet): no turns, not a failure
    }
    // Clip overlaps first, so a speaker left with no turn takes no label; then one person split in several is one.
    let clipped = exclusive(output.segments.map { Turn(speaker: $0.0, start: $0.1, end: $0.2) })
    let folded = mergeCloseVoices(clipped, output.embeddings)
    let (turns, map) = relabel(folded.turns.map { ($0.speaker, $0.start, $0.end) })
    var embeddings: [String: [Float]] = [:]
    for (id, vector) in folded.embeddings {
        // A label that has turns, and a clean vector; anything else is left out.
        if let label = map[id], !vector.isEmpty, vector.allSatisfy(\.isFinite) { embeddings[label] = vector }
    }
    return (turns, embeddings, folded.merged)
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
            d = FluidDiarizer(models: try await OfflineDiarizerModels.load(from: store.directory))
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
        var maxSpeakers: Int?
        if let raw = args["max_speakers"], !(raw is NSNull) {
            guard let n = number(raw), n >= 1, n == n.rounded(), n <= 1000 else {
                throw EngineError("max_speakers must be a whole number of at least 1")
            }
            maxSpeakers = Int(n)
        }
        let t0 = Date()
        let r = try await diarizeFile(url, maxSpeakers: maxSpeakers) { try await self.loadedDiarizer() }
        return ["turns": r.turns.map(\.json),
                "embeddings": r.embeddings.mapValues { $0.map(Double.init) },
                "merged_voices": r.merged,
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
