// `/audio/transcriptions` with `verbose_json` and word timestamps (cloud_asr.py `OpenAICompatible`): OpenAI
// (whisper-1), Azure OpenAI, a company or self-hosted gateway.
// https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create
import Foundation
import PalaverCore
import PalaverDomain

public class OpenAITranscribe: TranscriptionAdapter, @unchecked Sendable {
    /// 16 kHz 16-bit audio: under 25 MB even uncompressed.
    public class var MAX_SECONDS: Double { 10 * 60.0 }
    /// OpenAI takes 25 MB.
    public static let MAX_BYTES = 24 * 1024 * 1024

    let url: String
    let headers: [(String, String)]

    init(pid: String, name: String, endpoint: String, model: String, auth: String, key: String?, http: HTTPClient,
         clock: @escaping @Sendable () -> Double) {
        url = Self.transcriptionURL(endpoint)
        var headers: [(String, String)] = []
        if let key, !key.isEmpty {
            let asAPIKey = auth == "api-key" || (auth == "auto" && ProviderSettings.isAzure(url))
            headers.append(asAPIKey ? ("api-key", key) : ("authorization", "Bearer \(key)"))
        }
        self.headers = headers
        super.init(pid: pid, name: name, model: model, key: key, host: ModelChoice.hostname(url) ?? "",
                   maxSeconds: Self.MAX_SECONDS, maxBytes: Self.MAX_BYTES, http: http, clock: clock)
    }

    /// `…/audio/transcriptions` under the endpoint, keeping its query (Azure's `?api-version=`).
    public static func transcriptionURL(_ endpoint: String) -> String {
        let trimmed = Py.strip(endpoint)
        guard var parts = URLComponents(string: trimmed) else { return trimmed }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/audio/transcriptions") { path += "/audio/transcriptions" }
        parts.percentEncodedPath = path
        return parts.string ?? trimmed
    }

    /// The form's fields besides the file.
    func fields(language: String?, keyterms: [String]) -> [(String, String)] {
        var out = [("model", model), ("response_format", "verbose_json"), ("timestamp_granularities[]", "word"),
                   ("timestamp_granularities[]", "segment")]
        if let language { out.append(("language", language)) }
        let chosen = Transcription.terms(keyterms, limit: 60, maxWords: 6)  // Whisper reads at most 224 tokens of prompt
        if !chosen.isEmpty { out.append(("prompt", "Glossary: " + chosen.joined(separator: ", ") + ".")) }
        return out
    }

    override public func transcribe(_ audio: Data, seconds: Double, language: String?, keyterms: [String],
                                    fallbackLanguage: String? = nil) async throws -> Heard {
        let (ctype, body) = Transcription.multipart(fields: fields(language: language, keyterms: keyterms),
                                                    files: [("file", Self.FILENAME, Self.CONTENT_TYPE, audio)])
        let data = try await send("POST", url, headers + [("content-type", ctype)], body,
                                  timeout: max(Self.uploadTimeout(body.count), 4 * seconds))
        let segments = (data["segments"]?.arrayValue ?? []).filter { if case .object = $0 { return true } else { return false } }
        let raw = (data["words"].flatMap { $0.truthy ? $0.arrayValue : nil })
            ?? segments.flatMap { $0["words"]?.arrayValue ?? [] }
        var words: [Word] = []
        for w in raw {
            guard case .object = w else { continue }
            let value = w["word"] ?? w["text"] ?? .string("")
            let text = Py.strip(value.stringValue ?? Py.str(value))
            guard !text.isEmpty, let start = Self.number(w["start"]), let end = Self.number(w["end"]) else { continue }
            words.append(Word(text: text, start: Py.round(start, 3), end: Py.round(end, 3)))
        }
        if !words.isEmpty {
            words = Self.punctuated(words, segments)
        } else if !segments.isEmpty {
            words = Self.spread(segments)
        } else if let text = data["text"], text.truthy, !Py.strip(text.stringValue ?? Py.str(text)).isEmpty {
            throw CloudError("\(name) (\(model)) answers without timestamps, so its text can't be lined up with who spoke. "
                             + "Choose a model that gives them (OpenAI: whisper-1).")
        }
        var usage = JSONValue.object([])
        if case .object? = data["usage"] { usage = data["usage"]! }
        let billed = data["duration"] ?? usage["seconds"] ?? usage["prompt_audio_seconds"]
        return Heard(words: words, language: Transcription.languageCode(data["language"]), billedSeconds: billed?.doubleValue)
    }

    /// A number, or a numeric string (Python's `float()`); nil otherwise.
    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let i)?: return Double(i)
        case .double(let d)?: return d
        case .string(let s)?: return Double(Py.strip(s))
        default: return nil
        }
    }

    static func norm(_ text: String) -> String {
        String(String.UnicodeScalarView(Py.casefold(text).unicodeScalars.filter {
            $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "_"
        }))
    }

    /// Whisper's words come without punctuation, its segments with it: where a segment's text has the same words, its
    /// spelling goes onto them.
    static func punctuated(_ words: [Word], _ segments: [JSONValue]) -> [Word] {
        var out = words
        for seg in segments {
            guard let start = number(seg["start"]), let end = number(seg["end"]) else { continue }
            let idx = out.indices.filter { start - 0.05 <= out[$0].start && out[$0].start <= end + 0.05 }
            let text = seg["text"].map { $0.stringValue ?? Py.str($0) } ?? ""
            let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if !idx.isEmpty && tokens.count == idx.count && zip(tokens, idx).allSatisfy({ norm($0) == norm(out[$1].text) }) {
                for (t, i) in zip(tokens, idx) { out[i] = Word(text: t, start: out[i].start, end: out[i].end, confidence: out[i].confidence) }
            }
        }
        return out
    }

    /// Words over each segment's time, evenly: a service that times only its segments still lines up with the speaker
    /// turns about as well.
    static func spread(_ segments: [JSONValue]) -> [Word] {
        var out: [Word] = []
        for seg in segments {
            guard let start = number(seg["start"]), let end = number(seg["end"]) else { continue }
            let text = seg["text"].map { $0.stringValue ?? Py.str($0) } ?? ""
            let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if tokens.isEmpty || end < start { continue }
            let step = (end - start) / Double(tokens.count)
            for (i, t) in tokens.enumerated() {
                out.append(Word(text: t, start: Py.round(start + Double(i) * step, 3), end: Py.round(start + Double(i + 1) * step, 3)))
            }
        }
        return out
    }
}

/// Voxtral through Mistral's `/v1/audio/transcriptions` (cloud_asr.py `Mistral`): word and segment timestamps
/// (segments spread into words when no words come back) and `context_bias`, one token per term (spaces become
/// underscores); no `language` (Mistral takes it only without timestamps).
/// https://docs.mistral.ai/api/endpoint/audio/transcriptions
public final class Mistral: OpenAITranscribe, @unchecked Sendable {
    public static let URL_ = "https://api.mistral.ai/v1"
    /// It takes up to 3 h; its upload limit is not documented.
    override public class var MAX_SECONDS: Double { 30 * 60.0 }

    init(model: String, key: String?, http: HTTPClient, clock: @escaping @Sendable () -> Double) {
        super.init(pid: "mistral", name: "Mistral", endpoint: Self.URL_, model: model, auth: "bearer", key: key, http: http,
                   clock: clock)
    }

    override func fields(language: String?, keyterms: [String]) -> [(String, String)] {
        [("model", model), ("timestamp_granularities", "word"), ("timestamp_granularities", "segment")]
            + Transcription.terms(keyterms, limit: 100, maxWords: 6).map { ("context_bias", $0.replacingOccurrences(of: " ", with: "_")) }
    }
}
