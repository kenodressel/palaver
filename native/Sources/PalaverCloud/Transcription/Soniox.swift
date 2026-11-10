// Soniox (cloud_asr.py `Soniox`): upload the file, start a transcription, check it, read the tokens, delete both.
// https://soniox.com/docs/stt/async/async-transcription
import Foundation
import PalaverCore
import PalaverDomain

public final class Soniox: TranscriptionAdapter, @unchecked Sendable {
    public static let BASES = ["eu": "https://api.eu.soniox.com", "us": "https://api.soniox.com"]
    /// It takes 300 min.
    public static let MAX_SECONDS = 4.5 * 3600
    public static let MAX_BYTES = 1_000_000_000

    let base: String

    init(model: String, region: String, key: String?, http: HTTPClient, clock: @escaping @Sendable () -> Double) {
        base = Self.BASES[region] ?? Self.BASES["eu"]!
        super.init(pid: "soniox", name: "Soniox", model: model, key: key, host: URL(string: base)!.host!,
                   maxSeconds: Self.MAX_SECONDS, maxBytes: Self.MAX_BYTES, http: http, clock: clock)
    }

    /// Soniox's sub-word tokens as words: a leading space starts a word, anything else (word pieces, punctuation)
    /// extends the one before. A word is as sure as its least sure piece.
    public static func joinTokens(_ tokens: [JSONValue]) -> [Word] {
        var words: [Word] = []
        for t in tokens {
            guard case .object = t, let text = t["text"]?.stringValue else { continue }
            let start = Transcription.ms(t["start_ms"] ?? .int(0)), end = Transcription.ms(t["end_ms"] ?? .int(0))
            let conf = Transcription.confidence(t["confidence"])
            let stripped = Py.strip(text)
            if stripped.isEmpty { continue }
            if text.hasPrefix(" ") || words.isEmpty {
                words.append(Word(text: stripped, start: start, end: end, confidence: conf))
            } else {
                let last = words[words.count - 1]
                let least: Double? = last.confidence == nil ? conf : conf == nil ? last.confidence : min(last.confidence!, conf!)
                words[words.count - 1] = Word(text: last.text + stripped, start: last.start, end: end, confidence: least)
            }
        }
        return words
    }

    override public func transcribe(_ audio: Data, seconds: Double, language: String?, keyterms: [String],
                                    fallbackLanguage: String? = nil) async throws -> Heard {
        let auth = [("authorization", "Bearer \(key ?? "")")]
        let (ctype, body) = Transcription.multipart(fields: [], files: [("file", Self.FILENAME, Self.CONTENT_TYPE, audio)])
        let uploaded = try await send("POST", "\(base)/v1/files", auth + [("content-type", ctype)], body,
                                      timeout: Self.uploadTimeout(body.count))
        let fid = try id(uploaded, "id")
        let fileURL = "\(base)/v1/files/\(fid)"
        let status: JSONValue
        var data: JSONValue = .object([])
        do {
            var job: [(String, JSONValue)] = [("model", .string(model)), ("file_id", .string(fid)),
                                              ("enable_speaker_diarization", .bool(false)),
                                              ("enable_language_identification", .bool(true))]
            if let language { job.append(("language_hints", .strings([language]))) }
            let chosen = Transcription.terms(keyterms, limit: 500, maxWords: 10)
            if !chosen.isEmpty { job.append(("context", .object([("terms", .strings(chosen))]))) }
            let created = try await send("POST", "\(base)/v1/transcriptions", auth + [("content-type", "application/json")],
                                         Data(PythonJSON.dumps(.object(job)).utf8))
            let tid = try id(created, "id")
            let url = "\(base)/v1/transcriptions/\(tid)"
            status = try await runJob({
                let s = try await self.send("GET", url, auth)
                if s["status"]?.stringValue == "completed" && !data.truthy {
                    data = try await self.send("GET", "\(url)/transcript", auth)
                }
                return s
            }, seconds: seconds, failed: ["error", "failed"], message: "error_message", url: url, headers: auth,
               what: "transcription")
        } catch {
            await forget(fileURL, auth, "file")
            throw error
        }
        await forget(fileURL, auth, "file")
        let tokens = (data["tokens"]?.arrayValue ?? []).filter { if case .object = $0 { return true } else { return false } }
        // The language most tokens are in (the first seen of a tie).
        var counts: [(String, Int)] = []
        for t in tokens {
            guard let lang = t["language"], lang.truthy, let code = Transcription.languageCode(lang) else { continue }
            if let i = counts.firstIndex(where: { $0.0 == code }) { counts[i].1 += 1 } else { counts.append((code, 1)) }
        }
        let top = counts.reduce(nil as (String, Int)?) { best, c in best == nil || c.1 > best!.1 ? c : best }
        let billed = status["audio_duration_ms"]?.doubleValue.map { Py.round($0 / 1000, 3) }
        return Heard(words: Self.joinTokens(tokens), language: top?.0, billedSeconds: billed)
    }
}
