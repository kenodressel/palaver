// The system track through the transcription service the user chose (transcription.py `_cloud`, `_send`, `test`, #54).
//
// Only the system track goes out: what the others said. The mic track stays local, and who spoke when is worked out on
// this Mac: the service's word timestamps are lined up with the local speaker turns. Long silences are cut out first
// (Trim), the offsets kept; a recording longer than the service takes at once goes in overlapping chunks, stitched by
// word (Chunks, Stitch). Every upload is written to the access log: provider, host, seconds of audio, track, meeting,
// how it went; never the audio, the words or a key. What the service could not delete goes to cloud-pending.json.
//
// Deciding whether a meeting goes out at all (the choice, "Keep on This Mac", what was transcribed before) and the
// fallback to this Mac's engine are the worker's (PalaverWorker `Pipeline.systemTrack`).
import Foundation
import PalaverCore
import PalaverDomain

public enum CloudTranscription {
    public static let FEATURE = "transcription"
    public static let TEST_SECONDS = 2.0

    /// What a service made of the system track.
    public struct Outcome {
        public var segments: [Segment]
        public var language: String?
        public var sentSeconds: Double
        public var model: String

        public init(segments: [Segment], language: String?, sentSeconds: Double, model: String) {
            self.segments = segments
            self.language = language
            self.sentSeconds = sentSeconds
            self.model = model
        }
    }

    /// The provider's settings and key; EngineUnavailable when it is not set up (`ready_provider`).
    public static func ready(_ pid: String, settings: ProviderSettings) throws -> (PyDict<JSONValue>, String?) {
        let label = ModelChoice.provider(pid)?.label ?? pid
        if let trouble = try settings.problem(pid) { throw EngineUnavailable("\(label): \(trouble)") }
        return (try settings.settingsOf(pid), settings.apiKey(pid))
    }

    /// The glossary's terms and the names of the meeting's invitees.
    public static func keyterms(_ paths: RecordingPaths, userName: String, stores: StorePaths) -> [String] {
        var found = Glossary.current(stores: stores).terms.map { $0.value["term"]?.stringValue ?? "" }
        if let event = CalendarEvents.load(paths) {
            found += CalendarEvents.candidates(event, userName: userName).map(\.name)
        }
        return Transcription.terms(found, limit: 1000, maxWords: 6)
    }

    /// The estimated cost at the service's list price; nil when it has none.
    public static func cost(_ pid: String, seconds: Double) -> Double? {
        guard let price = ProviderRegistry.info[pid]?.usdPerHour else { return nil }
        return Py.round(seconds / 3600 * price, 4)
    }

    /// One upload, written to the access log however it goes; what the service could not delete goes to `pending`
    /// (`kept` is told how many).
    static func send(_ adapter: TranscriptionAdapter, audio: Data, seconds: Double, meetings: [String], feature: String,
                     track: String?, language: String?, terms: [String], pending: URL, fallbackLanguage: String?,
                     stores: StorePaths, kept: (String, Int) -> Void) async throws -> Heard {
        func log(ok: Bool, error: String? = nil, took: Double) {
            let entry = AccessLog.Entry(provider: adapter.pid, host: adapter.host, model: adapter.model, feature: feature,
                                        meetings: meetings, chars: 0, ok: ok, seconds: took, error: error,
                                        audioSeconds: seconds, track: track)
            try? AccessLog.record(entry, stores: stores)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let heard: Heard
        do {
            heard = try await adapter.transcribe(audio, seconds: seconds, language: language, keyterms: terms,
                                                 fallbackLanguage: fallbackLanguage)
        } catch {
            let n = TranscriptionPending.keep(adapter, in: pending)
            if n > 0 { kept(adapter.pid, n) }
            log(ok: false, error: HTTPClient.redact(message(error), key: adapter.key), took: ProcessInfo.processInfo.systemUptime - started)
            throw error
        }
        let n = TranscriptionPending.keep(adapter, in: pending)
        if n > 0 { kept(adapter.pid, n) }
        log(ok: true, took: ProcessInfo.processInfo.systemUptime - started)
        return heard
    }

    /// An error as it may be shown and logged: a cloud failure's own message, else only its kind.
    public static func message(_ error: Error) -> String {
        switch error {
        case let e as CloudError: return e.message
        case let e as JobFailed: return e.description
        case let e as EngineUnavailable: return e.message
        default: return "\(type(of: error))"
        }
    }

    /// The system track of `paths` through `pid`: silence cut, chunked, stitched, the dictionary applied. `language`:
    /// config.toml's ("auto" or empty: the service detects it). `kept`: a deletion the service still owes was noted.
    public static func transcribe(_ paths: RecordingPaths, pid: String, settings: ProviderSettings, language: String,
                                  dictionary: TranscriberDictionary?, keyterms: [String], http: HTTPClient, stores: StorePaths,
                                  kept: (String, Int) -> Void = { _, _ in }) async throws -> Outcome {
        let (s, key) = try ready(pid, settings: settings)
        let adapter = try Transcription.adapter(pid, settings: s, key: key, http: http)
        let spans = try Trim.speechSpans(paths.systemWav)
        if spans.isEmpty { return Outcome(segments: [], language: nil, sentSeconds: 0, model: adapter.model) }
        let line = Timeline(spans)
        let longest = min(adapter.maxSeconds, Double(adapter.maxBytes) / Chunks.RAW_BYTES_PER_SECOND)
        let language: String? = language.isEmpty || language == "auto" ? nil : language
        let fallback = language ?? meetingLanguage(paths) ?? "en"
        var heardChunks: [(start: Double, end: Double, words: [Word])] = []
        var languages: [(String, Int)] = []
        var sent = 0.0
        for (start, end) in Chunks.plan(total: line.seconds, maxSeconds: longest) {
            let chunk = try Chunks.flac(paths.systemWav, line: line, start: start, end: end)
            let heard = try await send(adapter, audio: chunk.flac, seconds: chunk.seconds, meetings: [paths.folder.lastPathComponent],
                                       feature: FEATURE, track: "system", language: language, terms: keyterms,
                                       pending: paths.cloudPending, fallbackLanguage: fallback, stores: stores, kept: kept)
            sent += chunk.seconds
            if let lang = heard.language {
                let weight = heard.words.isEmpty ? 1 : heard.words.count
                if let i = languages.firstIndex(where: { $0.0 == lang }) { languages[i].1 += weight } else { languages.append((lang, weight)) }
            }
            heardChunks.append((start, end, heard.words.map {
                Word(text: $0.text, start: $0.start + start, end: $0.end + start, confidence: $0.confidence)
            }))
        }
        var words = Stitch.stitch(heardChunks).map(line.wordToSource)
        if let dictionary {
            words = words.map { Word(text: dictionary.apply($0.text), start: $0.start, end: $0.end, confidence: $0.confidence) }
        }
        words = words.filter { !Py.strip($0.text).isEmpty }
        let top = languages.reduce(nil as (String, Int)?) { best, c in best == nil || c.1 > best!.1 ? c : best }
        return Outcome(segments: Stitch.segments(words), language: top?.0 ?? language, sentSeconds: sent, model: adapter.model)
    }

    /// language.txt as a two-letter code.
    static func meetingLanguage(_ paths: RecordingPaths) -> String? {
        guard let text = try? String(contentsOf: paths.language, encoding: .utf8) else { return nil }
        return Transcription.languageCode(.string(text))
    }

    /// The Test button: two seconds of a tone (no meeting) to `pid`; how long it took, the model, what an hour costs and
    /// what it heard. SettingRefused for what is no transcription service, EngineUnavailable for one not set up,
    /// CloudError / JobFailed for a call that failed (every message safe to show).
    public static func test(_ pid: String, settings: ProviderSettings, http: HTTPClient = HTTPClient()) async throws -> JSONValue {
        guard ProviderRegistry.transcribers().contains(where: { Py.same($0, pid) }) else {
            throw SettingRefused("no transcription service \(Py.repr(.string(pid)))")
        }
        let (s, key) = try ready(pid, settings: settings)
        let adapter = try Transcription.adapter(pid, settings: s, key: key, http: http)
        let started = ProcessInfo.processInfo.systemUptime
        let heard = try await send(adapter, audio: try Chunks.tone(seconds: TEST_SECONDS), seconds: TEST_SECONDS, meetings: [],
                                   feature: "test", track: nil, language: nil, terms: [], pending: settings.stores.cloudPending,
                                   fallbackLanguage: "en", stores: settings.stores, kept: { _, _ in })
        let said = heard.words.map(\.text).joined(separator: " ")
        return .object([
            ("seconds", .double(Py.round(ProcessInfo.processInfo.systemUptime - started, 1))), ("model", .string(adapter.model)),
            ("usd_per_hour", ProviderRegistry.info[pid].flatMap(\.usdPerHour).map(JSONValue.double) ?? .null),
            ("heard", .string(String(String.UnicodeScalarView(said.unicodeScalars.prefix(200))))),
        ])
    }
}
