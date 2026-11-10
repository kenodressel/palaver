// AssemblyAI (cloud_asr.py `AssemblyAI`): upload the audio, start a job, check it until it is done, delete it.
// https://www.assemblyai.com/docs/api-reference/transcripts/submit
import Foundation
import PalaverCore
import PalaverDomain

public final class AssemblyAI: TranscriptionAdapter, @unchecked Sendable {
    public static let BASES = ["eu": "https://api.eu.assemblyai.com", "us": "https://api.assemblyai.com"]
    /// It takes 10 h.
    public static let MAX_SECONDS = 5 * 3600.0
    /// An upload takes 2.2 GB.
    public static let MAX_BYTES = 2_000_000_000

    let base: String

    init(model: String, region: String, key: String?, http: HTTPClient, clock: @escaping @Sendable () -> Double) {
        base = Self.BASES[region] ?? Self.BASES["eu"]!
        super.init(pid: "assemblyai", name: "AssemblyAI", model: model, key: key, host: URL(string: base)!.host!,
                   maxSeconds: Self.MAX_SECONDS, maxBytes: Self.MAX_BYTES, http: http, clock: clock)
    }

    override public func transcribe(_ audio: Data, seconds: Double, language: String?, keyterms: [String],
                                    fallbackLanguage: String? = nil) async throws -> Heard {
        let auth = [("authorization", key ?? "")]
        let uploaded = try await send("POST", "\(base)/v2/upload", auth + [("content-type", "application/octet-stream")], audio,
                                      timeout: Self.uploadTimeout(audio.count))
        guard let uploadURL = uploaded["upload_url"]?.stringValue, !uploadURL.isEmpty else {
            throw CloudError("\(name) answered the upload without an upload_url")
        }
        var job: [(String, JSONValue)] = [("audio_url", .string(uploadURL)), ("speech_models", .strings([model])),
                                          ("speaker_labels", .bool(false)), ("punctuate", .bool(true)), ("format_text", .bool(true))]
        if let language {
            job.append(("language_code", .string(language)))
        } else {  // German meetings switch to English and back
            job.append(("language_detection", .bool(true)))
            // A clip of music or noise only: an empty transcript in that language, instead of a failed job.
            job.append(("language_detection_options", .object([
                ("code_switching", .bool(true)), ("on_no_speech_detected", .string("fallback")),
                ("fallback_language", .string(fallbackLanguage ?? "en")),
            ])))
        }
        let chosen = Transcription.terms(keyterms, limit: model.contains("3") ? 1000 : 200, maxWords: 6)
        if !chosen.isEmpty { job.append(("keyterms_prompt", .strings(chosen))) }
        let tid: String
        do {
            let created = try await send("POST", "\(base)/v2/transcript", auth + [("content-type", "application/json")],
                                         Data(PythonJSON.dumps(.object(job)).utf8))
            tid = try id(created, "id")
        } catch {
            // Only deleting a transcript deletes its upload; this one has none.
            let until = Py.isoNow(timespec: "seconds", now: Date().addingTimeInterval(Self.UPLOAD_KEPT_SECONDS))
            pending.append(.object([("provider", .string(pid)), ("host", .string(host)), ("what", .string("upload")),
                                    ("url", .null), ("since", .string(Transcription.now())), ("until", .string(until))]))
            throw error
        }
        let url = "\(base)/v2/transcript/\(tid)"
        let data: JSONValue
        do {
            data = try await runJob({ try await self.send("GET", url, auth) }, seconds: seconds, failed: ["error"],
                                 message: "error", url: url, headers: auth, what: "transcript")
        } catch let failure as JobFailed where Py.casefold(failure.reason).contains(Self.NO_SPEECH) {
            return Heard(words: [], language: language ?? fallbackLanguage, billedSeconds: nil)
        }
        var words: [Word] = []
        for w in data["words"]?.arrayValue ?? [] {
            guard case .object = w, let raw = w["text"] else { continue }
            let text = Py.strip(raw.stringValue ?? Py.str(raw))
            if text.isEmpty { continue }
            words.append(Word(text: text, start: Transcription.ms(w["start"]), end: Transcription.ms(w["end"]),
                              confidence: Transcription.confidence(w["confidence"])))
        }
        return Heard(words: words, language: Transcription.languageCode(data["language_code"]),
                     billedSeconds: data["audio_duration"]?.doubleValue)
    }
}
