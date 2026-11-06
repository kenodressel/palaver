import FluidAudio
import Foundation

// MARK: - Words and sentences (pure, no model)

public struct Word: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Double

    public init(text: String, start: Double, end: Double, confidence: Double) {
        self.text = text; self.start = start; self.end = end; self.confidence = confidence
    }

    var json: [String: Any] {
        ["text": text, "start": start, "end": end, "confidence": confidence]
    }
}

public struct Segment: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [Word]

    var json: [String: Any] {
        ["start": start, "end": end, "text": text, "words": words.map(\.json)]
    }
}

/// Joins SentencePiece tokens into words: a leading "▁" (or space) starts a
/// word, anything else extends the previous one. A word is as sure as its
/// least sure piece, rounded to 3 decimals. Mirrors `_words_from_tokens` in
/// `palaver/transcriber.py`.
public func words(from tokens: [TokenTiming]) -> [Word] {
    let marks = CharacterSet(charactersIn: "▁ ")
    var out: [Word] = []
    for t in tokens {
        let confidence = (Double(t.confidence) * 1000).rounded(.toNearestOrEven) / 1000
        if t.token.hasPrefix("▁") || t.token.hasPrefix(" ") || out.isEmpty {
            let text = t.token.trimmingCharacters(in: marks)
            if text.isEmpty { continue }
            out.append(Word(text: text, start: t.startTime, end: t.endTime, confidence: confidence))
        } else {
            out[out.count - 1].text += t.token
            out[out.count - 1].end = t.endTime
            out[out.count - 1].confidence = min(out[out.count - 1].confidence, confidence)
        }
    }
    return out
}

private func hasLetterOrDigit(_ s: String) -> Bool {
    s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
}

/// Word-start marks: FluidAudio prefixes a word's first piece with a space
/// (SentencePiece itself uses "▁"); both count.
private func hasSpace(_ t: TokenTiming) -> Bool { t.token.contains(" ") || t.token.contains("▁") }
private func plain(_ t: TokenTiming) -> String { t.token.replacingOccurrences(of: "▁", with: " ") }

/// Groups tokens into segments exactly like parakeet-mlx's
/// `tokens_to_sentences`, as Palaver uses it today: a sentence closes after a
/// token that (a) holds ! ? 。 ？ ！, or holds "." and is the last token or is
/// followed by a word start; (b) is followed by a pause of at least `gap`
/// seconds; or (c) ends `maxDuration` or more after the sentence's first
/// token (so a sentence may run slightly past it). Then Palaver's rule: a
/// sentence with no letter or digit (orphaned punctuation) is attached to the
/// previous segment, text and last word, and the previous end stays.
public func sentences(_ tokens: [TokenTiming], gap: Double = 1.0, maxDuration: Double = 15.0) -> [Segment] {
    var groups: [[TokenTiming]] = []
    var current: [TokenTiming] = []
    for (i, t) in tokens.enumerated() {
        current.append(t)
        let isLast = i == tokens.count - 1
        let punctuation = ["!", "?", "。", "？", "！"].contains { t.token.contains($0) }
            || (t.token.contains(".") && (isLast || hasSpace(tokens[i + 1])))
        let pause = !isLast && tokens[i + 1].startTime - t.endTime >= gap
        let tooLong = t.endTime - current[0].startTime >= maxDuration
        if punctuation || pause || tooLong {
            groups.append(current)
            current = []
        }
    }
    if !current.isEmpty { groups.append(current) }

    var out: [Segment] = []
    for g in groups {
        let ws = words(from: g)
        if ws.isEmpty { continue }
        let text = g.map(plain).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty, !hasLetterOrDigit(text) {
            out[out.count - 1].text += text
            out[out.count - 1].words[out[out.count - 1].words.count - 1].text += text
            continue
        }
        out.append(Segment(start: g.first!.startTime, end: g.last!.endTime, text: text, words: ws))
    }
    return out
}

// MARK: - Models folder

/// Where the models live and whether each is ready. The one source of truth
/// for `hello` and `prepare`.
public struct ModelStore: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/palaver/models/fluidaudio")
    }

    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    /// Folder of the speech model (FluidAudio's repo folder name for Parakeet v3).
    var asrDirectory: URL { directory.appendingPathComponent(AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent) }
    static let diarizerFolder = "speaker-diarization"
    var diarizerDirectory: URL { directory.appendingPathComponent(Self.diarizerFolder) }

    public static let names = ["asr", "diarizer"]

    public func isReady(_ name: String) -> Bool {
        switch name {
        case "asr":
            return AsrModels.modelsExist(at: asrDirectory, version: .v3)
        case "diarizer":
            let files = ["Segmentation.mlmodelc", "Embedding.mlmodelc", "FBank.mlmodelc",
                         "PldaRho.mlmodelc", "plda-parameters.json"]
            return files.allSatisfy {
                FileManager.default.fileExists(atPath: diarizerDirectory.appendingPathComponent($0).path)
            }
        default:
            return false
        }
    }

    public func readiness() -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: Self.names.map { ($0, isReady($0)) })
    }
}

// MARK: - Recognizer

/// Turns 16 kHz mono samples into token timings, times from the first sample.
public protocol Recognizer: Sendable {
    func recognize(_ samples: [Float]) async throws -> [TokenTiming]
}

/// Parakeet v3 through FluidAudio.
public final class ParakeetRecognizer: Recognizer, @unchecked Sendable {
    private let manager: AsrManager
    init(manager: AsrManager) { self.manager = manager }

    public func recognize(_ samples: [Float]) async throws -> [TokenTiming] {
        // A fresh decoder state per call: calls are independent.
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)
        return result.tokenTimings ?? []
    }
}

/// Less audio than this (50 ms at 16 kHz) holds no word: no model call.
let minSamples = 800
/// FluidAudio refuses less than 0.3 s (`ASRConstants.minimumRequiredSamples`),
/// so shorter audio is padded with silence at the end; word times don't move.
let modelMinSamples = 4_800

/// `samples` ready for the model, or nil when there is too little audio to bother.
func preparedForModel(_ samples: [Float]) -> [Float]? {
    if samples.count < minSamples { return nil }
    if samples.count >= modelMinSamples { return samples }
    return samples + [Float](repeating: 0, count: modelMinSamples - samples.count)
}

/// Segments of a WAV (or a slice of it); `[]` without a model call when it holds too little audio.
public func transcribeFile(_ url: URL, start: Int?, end: Int?, with recognizer: Recognizer) async throws -> [Segment] {
    let samples = try readWav(url, start: start, end: end)
    guard let ready = preparedForModel(samples) else { return [] }
    return sentences(try await recognizer.recognize(ready))
}

// MARK: - Commands

final class SpeechEngine: @unchecked Sendable {
    let store: ModelStore
    private let makeRecognizer: (() async throws -> Recognizer)?
    private var recognizer: Recognizer?

    init(store: ModelStore, recognizer: (() async throws -> Recognizer)?) {
        self.store = store
        self.makeRecognizer = recognizer
    }

    /// Loaded on first use and kept. Never downloads: that is `prepare`'s job.
    func loadedRecognizer() async throws -> Recognizer {
        if let r = recognizer { return r }
        let r: Recognizer
        if let make = makeRecognizer {
            r = try await make()
        } else {
            guard store.isReady("asr") else { throw EngineError("models missing: asr") }
            // A load must never download: that is `prepare`'s job.
            let was = ModelHub.offlineMode
            ModelHub.offlineMode = true
            defer { ModelHub.offlineMode = was }
            r = try await loadParakeet(directory: store.asrDirectory)
        }
        recognizer = r
        return r
    }

    private func loadParakeet(directory: URL) async throws -> Recognizer {
        let models = try await AsrModels.load(from: directory, version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return ParakeetRecognizer(manager: manager)
    }

    func prepare(_ requested: Any?, emit: Emitter) async throws -> [String: Any] {
        var names = ModelStore.names
        if let requested {
            guard let list = requested as? [String] else { throw EngineError("prepare: models must be an array of names") }
            names = list
        }
        if let bad = names.first(where: { !ModelStore.names.contains($0) }) {
            throw EngineError("unknown model: \(bad)")
        }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        for name in names {
            let report: ProgressHandler = { p in
                let phase: String
                switch p.phase {
                case .listing, .downloading: phase = "downloading"
                case .compiling: phase = "compiling"
                }
                emit.progress(p.fractionCompleted, phase: phase)
            }
            switch name {
            case "asr":
                try await AsrModels.download(to: store.asrDirectory, version: .v3, progressHandler: report)
                if recognizer == nil {  // already loaded: nothing to reload
                    emit.progress(0, phase: "loading")
                    recognizer = try await loadParakeet(directory: store.asrDirectory)
                    emit.progress(1, phase: "loading")
                }
            default:  // diarizer: loading downloads and compiles what is missing
                _ = try await OfflineDiarizerModels.load(from: store.directory, progressHandler: report)
            }
        }
        return ["ready": names.filter { store.isReady($0) }]
    }

    func transcribe(_ args: [String: Any]) async throws -> [String: Any] {
        guard let wav = args["wav"] as? String else { throw EngineError("transcribe needs a wav path") }
        let start = try optionalInt(args["start"], "start"), end = try optionalInt(args["end"], "end")
        if let start, start < 0 { throw EngineError("start must not be negative") }
        if let start, let end, end < start { throw EngineError("end must not be before start") }
        let url = URL(fileURLWithPath: wav)
        // Check the file before the model, so a bad path says so even without models.
        guard FileManager.default.fileExists(atPath: url.path) else { throw EngineError("no such file: \(wav)") }
        let r = try await loadedRecognizer()
        let segments = try await transcribeFile(url, start: start, end: end, with: r)
        return ["segments": segments.map(\.json)]
    }

    func transcribeWindow(_ args: [String: Any]) async throws -> [String: Any] {
        guard let b64 = args["pcm"] as? String, let data = Data(base64Encoded: b64), data.count % 4 == 0 else {
            throw EngineError("transcribe_window needs pcm: base64 of float32 little-endian samples")
        }
        let samples: [Float] = data.withUnsafeBytes { raw in
            (0..<data.count / 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        guard let ready = preparedForModel(samples) else { return ["words": [Any]()] }
        let r = try await loadedRecognizer()
        return ["words": words(from: try await r.recognize(ready)).map(\.json)]
    }
}

/// An integer argument, or nil when absent; anything else is an error.
func optionalInt(_ value: Any?, _ name: String) throws -> Int? {
    guard let value, !(value is NSNull) else { return nil }
    // JSONSerialization gives NSNumber: reject booleans and non-integral numbers.
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
          n.doubleValue == n.doubleValue.rounded(), abs(n.doubleValue) < 1e15 else {
        throw EngineError("\(name) must be an integer sample index")
    }
    return n.intValue
}
