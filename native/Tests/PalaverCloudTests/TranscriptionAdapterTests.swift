// The cloud transcription adapters (cloud_asr.py) against stub services: what each provider gets (upload, job, poll,
// delete), how its answer becomes words with timestamps, what can't be deleted becomes a pending entry, and that the
// key goes to the service's own host only.
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverCloud

let ASR_KEY = "aai-SECRET-abcdefghijklmnopqrstuvwxyz0123"
let AUDIO = Data("fLaC".utf8) + Data(count: 64)

/// Answers by method and URL: each route's answers in turn (the last one again when they run out). Keeps the requests
/// and the waits; its clock moves on by each wait.
final class Routes: @unchecked Sendable {
    enum Answer {
        case json(Int, String)
        case fail(Error)
        static func ok(_ body: String) -> Answer { .json(200, body) }
    }

    private let lock = NSLock()
    private var routes: [String: [Answer]] = [:]
    private(set) var requests: [URLRequest] = []
    private(set) var waits: [Double] = []
    private var now = 0.0

    init(_ routes: [String: [Answer]] = [:]) { self.routes = routes }

    func on(_ route: String, _ answers: Answer...) { lock.withLock { routes[route] = answers } }

    var client: HTTPClient {
        HTTPClient(transport: { [self] in try answer($0) }, sleep: { [self] s in lock.withLock { waits.append(s); now += s } })
    }

    var clock: @Sendable () -> Double { { [self] in lock.withLock { now } } }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let route = "\(request.httpMethod ?? "GET") \(request.url!.absoluteString)"
        let next: Answer? = lock.withLock {
            requests.append(request)
            guard var answers = routes[route], !answers.isEmpty else { return nil }
            let a = answers.count > 1 ? answers.removeFirst() : answers[0]
            routes[route] = answers
            return a
        }
        switch next {
        case nil: throw URLError(.cannotConnectToHost)  // a host or path no test expects
        case .fail(let e)?: throw e
        case .json(let status, let body)?:
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
    }

    func sent(_ method: String, _ url: String) -> [URLRequest] {
        requests.filter { $0.httpMethod == method && $0.url?.absoluteString == url }
    }

    func json(_ r: URLRequest) -> JSONValue? { r.httpBody.flatMap { try? PythonJSON.parse($0) } }
}

/// The parts of a multipart/form-data body: name -> values (a file part: its filename, content type and bytes).
func multipartFields(_ r: URLRequest) -> [String: [Any]] {
    let ctype = r.value(forHTTPHeaderField: "content-type") ?? ""
    guard ctype.hasPrefix("multipart/form-data; boundary="), let body = r.httpBody else { return [:] }
    let boundary = Data(("--" + ctype.components(separatedBy: "boundary=")[1]).utf8)
    var out: [String: [Any]] = [:]
    var rest = body
    var parts: [Data] = []
    while let r = rest.range(of: boundary) {
        parts.append(rest[rest.startIndex..<r.lowerBound])
        rest = rest[r.upperBound...]
    }
    for part in parts.dropFirst() {
        guard let split = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
        let head = String(decoding: part[part.startIndex..<split.lowerBound], as: UTF8.self)
        let value = part[split.upperBound..<(part.endIndex - 2)]
        let name = head.components(separatedBy: "name=\"")[1].components(separatedBy: "\"")[0]
        if head.contains("filename=\"") {
            let filename = head.components(separatedBy: "filename=\"")[1].components(separatedBy: "\"")[0]
            let type = head.components(separatedBy: "Content-Type: ").last ?? ""
            out[name, default: []].append((filename, type, Data(value)))
        } else {
            out[name, default: []].append(String(decoding: value, as: UTF8.self))
        }
    }
    return out
}

private let AAI_EU = "https://api.eu.assemblyai.com"
private let AAI_DONE = Routes.Answer.ok("""
    {"id": "t1", "status": "completed", "language_code": "de", "audio_duration": 12,
     "words": [{"text": "Hallo", "start": 1200, "end": 1500, "confidence": 0.98, "speaker": null},
               {"text": "zusammen.", "start": 1550, "end": 2100, "confidence": 0.71, "speaker": null}]}
    """)

private func assemblyAI(_ status: [Routes.Answer], base: String = AAI_EU) -> Routes {
    Routes(["POST \(base)/v2/upload": [.ok(#"{"upload_url": "https://cdn.assemblyai.test/upload/abc"}"#)],
            "POST \(base)/v2/transcript": [.ok(#"{"id": "t1", "status": "queued"}"#)],
            "GET \(base)/v2/transcript/t1": status,
            "DELETE \(base)/v2/transcript/t1": [.ok(#"{"id": "t1"}"#)]])
}

private func adapter(_ pid: String, _ settings: [(String, JSONValue)], _ fake: Routes, key: String? = ASR_KEY) throws -> TranscriptionAdapter {
    try Transcription.adapter(pid, settings: PyDict(settings), key: key, http: fake.client, clock: fake.clock)
}

@Suite struct AssemblyAITests {
    @Test func uploadsTheAudioStartsAJobPollsAndDeletesIt() async throws {
        let fake = assemblyAI([.ok(#"{"id": "t1", "status": "processing"}"#), AAI_DONE])
        let a = try adapter("assemblyai", [("model", .string("universal-3-5-pro")), ("region", .string("eu"))], fake)
        let heard = try await a.transcribe(AUDIO, seconds: 12, language: nil, keyterms: ["Contoso", "Timo Strauß"], fallbackLanguage: "de")
        let upload = fake.requests[0]
        #expect(upload.url?.absoluteString == "\(AAI_EU)/v2/upload" && upload.httpBody == AUDIO)
        #expect(upload.value(forHTTPHeaderField: "authorization") == ASR_KEY)
        #expect(upload.value(forHTTPHeaderField: "content-type") == "application/octet-stream")
        let job = try #require(fake.json(fake.sent("POST", "\(AAI_EU)/v2/transcript")[0]))
        #expect(job["audio_url"] == .string("https://cdn.assemblyai.test/upload/abc"))
        #expect(job["speech_models"] == .strings(["universal-3-5-pro"]) && job["language_detection"] == .bool(true))
        #expect(job["language_detection_options"]?["code_switching"] == .bool(true))
        #expect(job["language_detection_options"]?["on_no_speech_detected"] == .string("fallback"))
        #expect(job["language_detection_options"]?["fallback_language"] == .string("de") && job["language_code"] == nil)
        #expect(job["keyterms_prompt"] == .strings(["Contoso", "Timo Strauß"]))
        #expect(job["speaker_labels"] == .bool(false))  // speakers are told apart on this Mac
        #expect(fake.sent("GET", "\(AAI_EU)/v2/transcript/t1").count == 2 && fake.waits == [2.0])
        #expect(fake.sent("DELETE", "\(AAI_EU)/v2/transcript/t1").count == 1)
        #expect(heard.words == [Word(text: "Hallo", start: 1.2, end: 1.5, confidence: 0.98),
                                Word(text: "zusammen.", start: 1.55, end: 2.1, confidence: 0.71)])
        #expect(heard.language == "de" && heard.billedSeconds == 12 && a.host == "api.eu.assemblyai.com" && a.pending.isEmpty)
        #expect(fake.requests.allSatisfy { $0.url?.host == "api.eu.assemblyai.com" })  // the key went nowhere else
    }

    @Test func aLanguageThatIsSetAndTheUSServers() async throws {
        let base = "https://api.assemblyai.com"
        let fake = assemblyAI([AAI_DONE], base: base)
        let a = try adapter("assemblyai", [("model", .string("universal-3-5-pro")), ("region", .string("us"))], fake)
        _ = try await a.transcribe(AUDIO, seconds: 12, language: "de", keyterms: [])
        let job = try #require(fake.json(fake.sent("POST", "\(base)/v2/transcript")[0]))
        #expect(job["language_code"] == .string("de") && job["language_detection"] == nil && job["keyterms_prompt"] == nil)
    }

    @Test func keytermsAreCappedToWhatItTakes() async throws {
        let terms = (0..<1500).map { "Term\($0)" } + ["one two three four five six seven"]
        for (model, limit) in [("universal-3-5-pro", 1000), ("universal-2", 200)] {
            let fake = assemblyAI([AAI_DONE])
            let a = try adapter("assemblyai", [("model", .string(model)), ("region", .string("eu"))], fake)
            _ = try await a.transcribe(AUDIO, seconds: 12, language: nil, keyterms: terms)
            let sent = fake.json(fake.sent("POST", "\(AAI_EU)/v2/transcript")[0])?["keyterms_prompt"]?.arrayValue ?? []
            #expect(sent.count == limit && sent.first == .string("Term0"))
        }
    }

    @Test func aClipWithoutSpeechIsAnEmptyTranscript() async throws {
        let fake = assemblyAI([.ok(#"{"id": "t1", "status": "error", "error": "No spoken audio found"}"#)])
        let a = try adapter("assemblyai", [("model", .string("universal-2")), ("region", .string("eu"))], fake)
        let heard = try await a.transcribe(AUDIO, seconds: 2, language: nil, keyterms: [], fallbackLanguage: "de")
        #expect(heard.words.isEmpty && heard.language == "de")
        #expect(fake.sent("DELETE", "\(AAI_EU)/v2/transcript/t1").count == 1)
    }

    @Test func aFailedJobSaysWhyWithoutTheKey() async throws {
        let fake = assemblyAI([.ok(#"{"id": "t1", "status": "error", "error": "bad audio for \#(ASR_KEY)"}"#)])
        let a = try adapter("assemblyai", [("model", .string("universal-2")), ("region", .string("eu"))], fake)
        let e = await thrown { try await a.transcribe(AUDIO, seconds: 2, language: nil, keyterms: []) } as? JobFailed
        #expect(e?.description.hasPrefix("AssemblyAI could not transcribe it: bad audio for") == true)
        #expect(e?.description.contains(ASR_KEY) == false)
        #expect(fake.sent("DELETE", "\(AAI_EU)/v2/transcript/t1").count == 1)
    }

    @Test func aRefusedDeleteBecomesPending() async throws {
        let fake = assemblyAI([AAI_DONE])
        fake.on("DELETE \(AAI_EU)/v2/transcript/t1", .json(500, #"{"error": "busy"}"#))
        let a = try adapter("assemblyai", [("model", .string("universal-2")), ("region", .string("eu"))], fake)
        _ = try await a.transcribe(AUDIO, seconds: 2, language: nil, keyterms: [])
        #expect(fake.sent("DELETE", "\(AAI_EU)/v2/transcript/t1").count == 1)  // once: the next process tries again
        let p = try #require(a.pending.first)
        #expect(a.pending.count == 1 && p["provider"] == .string("assemblyai") && p["host"] == .string("api.eu.assemblyai.com"))
        #expect(p["what"] == .string("transcript") && p["url"] == .string("\(AAI_EU)/v2/transcript/t1"))
        #expect(p["since"]?.stringValue != nil && p["error"] == .string("AssemblyAI failed after 1 try: HTTP 500"))
        // Gone already is no pending entry.
        let gone = assemblyAI([AAI_DONE])
        gone.on("DELETE \(AAI_EU)/v2/transcript/t1", .json(404, "{}"))
        let b = try adapter("assemblyai", [("model", .string("universal-2")), ("region", .string("eu"))], gone)
        _ = try await b.transcribe(AUDIO, seconds: 2, language: nil, keyterms: [])
        #expect(b.pending.isEmpty)
    }

    @Test func anUploadThatNeverBecameAJobIsNotedWithItsDate() async throws {
        let fake = assemblyAI([AAI_DONE])
        fake.on("POST \(AAI_EU)/v2/transcript", .json(400, #"{"error": "bad request"}"#))
        let a = try adapter("assemblyai", [("model", .string("universal-2")), ("region", .string("eu"))], fake)
        _ = await thrown { try await a.transcribe(AUDIO, seconds: 2, language: nil, keyterms: []) }
        let p = try #require(a.pending.first)
        #expect(p["what"] == .string("upload") && p["url"] == .null && p["until"]?.stringValue != nil)
        let until = try #require(Py.fromIso(p["until"]!.stringValue!))
        #expect(abs(until.timeIntervalSinceNow - 48 * 3600) < 120)
    }

    @Test func aJobThatTakesTooLongIsGivenUpAndStillDeleted() async throws {
        let fake = assemblyAI([.ok(#"{"id": "t1", "status": "processing"}"#)])
        let a = try adapter("assemblyai", [("model", .string("universal-2")), ("region", .string("eu"))], fake)
        let e = await thrown { try await a.transcribe(AUDIO, seconds: 2, language: nil, keyterms: []) } as? CloudError
        #expect(e?.message == "AssemblyAI did not finish within 10 min")
        #expect(fake.sent("DELETE", "\(AAI_EU)/v2/transcript/t1").count == 1)
    }
}

private let SONIOX = "https://api.eu.soniox.com"

@Suite struct SonioxTests {
    private func soniox() -> Routes {
        Routes(["POST \(SONIOX)/v1/files": [.ok(#"{"id": "f1"}"#)],
                "POST \(SONIOX)/v1/transcriptions": [.ok(#"{"id": "j1", "status": "queued"}"#)],
                "GET \(SONIOX)/v1/transcriptions/j1": [.ok(#"{"status": "processing"}"#), .ok(#"{"status": "completed", "audio_duration_ms": 3500}"#)],
                "GET \(SONIOX)/v1/transcriptions/j1/transcript": [.ok("""
                    {"tokens": [{"text": "Hal", "start_ms": 100, "end_ms": 300, "confidence": 0.9, "language": "de"},
                                {"text": "lo", "start_ms": 300, "end_ms": 500, "confidence": 0.8, "language": "de"},
                                {"text": ",", "start_ms": 500, "end_ms": 520, "language": "de"},
                                {"text": " Welt", "start_ms": 600, "end_ms": 900, "confidence": 0.95, "language": "de"},
                                {"text": " ok", "start_ms": 1000, "end_ms": 1100, "confidence": 0.99, "language": "en"}]}
                    """)],
                "DELETE \(SONIOX)/v1/transcriptions/j1": [.ok("")],
                "DELETE \(SONIOX)/v1/files/f1": [.ok("")]])
    }

    @Test func uploadsTheFileJoinsTheTokensAndDeletesBoth() async throws {
        let fake = soniox()
        let a = try adapter("soniox", [("model", .string("stt-async-v4")), ("region", .string("eu"))], fake)
        let heard = try await a.transcribe(AUDIO, seconds: 3.5, language: "de", keyterms: ["Northwind"])
        let upload = fake.requests[0]
        #expect(upload.value(forHTTPHeaderField: "authorization") == "Bearer \(ASR_KEY)")
        let file = multipartFields(upload)["file"]?.first as? (String, String, Data)
        #expect(file?.0 == "audio.flac" && file?.1 == "audio/flac" && file?.2 == AUDIO)
        let job = try #require(fake.json(fake.sent("POST", "\(SONIOX)/v1/transcriptions")[0]))
        #expect(job["file_id"] == .string("f1") && job["enable_speaker_diarization"] == .bool(false))
        #expect(job["language_hints"] == .strings(["de"]) && job["context"]?["terms"] == .strings(["Northwind"]))
        #expect(heard.words == [Word(text: "Hallo,", start: 0.1, end: 0.52, confidence: 0.8),
                                Word(text: "Welt", start: 0.6, end: 0.9, confidence: 0.95), Word(text: "ok", start: 1.0, end: 1.1, confidence: 0.99)])
        #expect(heard.language == "de" && heard.billedSeconds == 3.5)
        #expect(fake.sent("DELETE", "\(SONIOX)/v1/transcriptions/j1").count == 1 && fake.sent("DELETE", "\(SONIOX)/v1/files/f1").count == 1)
        #expect(fake.sent("GET", "\(SONIOX)/v1/transcriptions/j1/transcript").count == 1 && a.pending.isEmpty)
    }

    @Test func aFileThatCannotBeDeletedIsPendingAlsoWhenTheJobFailed() async throws {
        let fake = soniox()
        fake.on("POST \(SONIOX)/v1/transcriptions", .json(400, #"{"message": "bad model"}"#))
        fake.on("DELETE \(SONIOX)/v1/files/f1", .json(503, ""))
        let a = try adapter("soniox", [("model", .string("nope")), ("region", .string("eu"))], fake)
        let e = await thrown { try await a.transcribe(AUDIO, seconds: 3.5, language: nil, keyterms: []) } as? CloudError
        #expect(e?.message == "HTTP 400: bad model")
        #expect(a.pending.count == 1 && a.pending[0]["what"] == .string("file") && a.pending[0]["url"] == .string("\(SONIOX)/v1/files/f1"))
    }
}

@Suite struct OpenAITranscribeTests {
    @Test func askForWordTimestampsAndPutTheSegmentsPunctuationOnTheWords() async throws {
        let url = "https://gw.example.com/v1/audio/transcriptions"
        let fake = Routes(["POST \(url)": [.ok("""
            {"language": "german", "duration": 3.2, "text": "Hallo, Welt.",
             "words": [{"word": "Hallo", "start": 0.1, "end": 0.5}, {"word": "Welt", "start": 0.6, "end": 1.0}],
             "segments": [{"start": 0.0, "end": 1.1, "text": " Hallo, Welt."}]}
            """)]])
        let a = try adapter("openai-transcribe", [("endpoint", .string("https://gw.example.com/v1/")), ("model", .string("whisper-1"))], fake)
        let heard = try await a.transcribe(AUDIO, seconds: 3.2, language: "de", keyterms: ["Contoso", "Valerie"])
        let fields = multipartFields(fake.requests[0])
        #expect(fields["model"] as? [String] == ["whisper-1"] && fields["response_format"] as? [String] == ["verbose_json"])
        #expect(fields["timestamp_granularities[]"] as? [String] == ["word", "segment"] && fields["language"] as? [String] == ["de"])
        #expect(fields["prompt"] as? [String] == ["Glossary: Contoso, Valerie."])
        #expect(fake.requests[0].value(forHTTPHeaderField: "authorization") == "Bearer \(ASR_KEY)")
        #expect(heard.words.map(\.text) == ["Hallo,", "Welt."] && heard.language == "de" && heard.billedSeconds == 3.2)
        #expect(a.host == "gw.example.com")
    }

    @Test func azureGetsTheApiKeyHeaderAndKeepsTheQuery() async throws {
        let url = "https://acme.openai.azure.com/openai/deployments/w/audio/transcriptions?api-version=2024-06-01"
        let fake = Routes(["POST \(url)": [.ok(#"{"segments": [{"start": 1.0, "end": 2.0, "text": "eins zwei"}]}"#)]])
        let a = try adapter("openai-transcribe", [("endpoint", .string("https://acme.openai.azure.com/openai/deployments/w?api-version=2024-06-01")),
                                                  ("model", .string("whisper"))], fake)
        let heard = try await a.transcribe(AUDIO, seconds: 2, language: nil, keyterms: [])
        #expect(fake.requests[0].value(forHTTPHeaderField: "api-key") == ASR_KEY)
        #expect(fake.requests[0].value(forHTTPHeaderField: "authorization") == nil)
        // Only segments: their words spread over each segment's time.
        #expect(heard.words == [Word(text: "eins", start: 1.0, end: 1.5), Word(text: "zwei", start: 1.5, end: 2.0)])
    }

    @Test func textWithoutTimestampsIsAnError() async throws {
        let url = "https://gw.example.com/v1/audio/transcriptions"
        let fake = Routes(["POST \(url)": [.ok(#"{"text": "Hallo"}"#)]])
        let a = try adapter("openai-transcribe", [("endpoint", .string("https://gw.example.com/v1")), ("model", .string("gpt-4o-transcribe"))], fake)
        let e = await thrown { try await a.transcribe(AUDIO, seconds: 2, language: nil, keyterms: []) } as? CloudError
        #expect(e?.message.hasPrefix("OpenAI-compatible (gpt-4o-transcribe) answers without timestamps") == true)
    }

    @Test func mistralGetsContextBiasAndNoLanguage() async throws {
        let url = "https://api.mistral.ai/v1/audio/transcriptions"
        let fake = Routes(["POST \(url)": [.ok(#"{"segments": [{"start": 0.0, "end": 1.0, "text": "Hallo"}], "usage": {"prompt_audio_seconds": 2}}"#)]])
        let a = try adapter("mistral", [("model", .string("voxtral-mini-latest"))], fake)
        let heard = try await a.transcribe(AUDIO, seconds: 2, language: "de", keyterms: ["Timo Strauß", "Northwind"])
        let fields = multipartFields(fake.requests[0])
        #expect(fields["timestamp_granularities"] as? [String] == ["word", "segment"] && fields["language"] == nil)
        #expect(fields["context_bias"] as? [String] == ["Timo_Strauß", "Northwind"])
        #expect(heard.words.map(\.text) == ["Hallo"] && heard.billedSeconds == 2 && a.maxSeconds == 1800)
    }
}

@Suite struct TranscriptionTermsTests {
    @Test func termsAreOneLineEachOnceAndCapped() {
        #expect(Transcription.terms(["  Contoso\n Ltd ", "contoso ltd", "", "a b c d e f g", "Valerie"], limit: 10, maxWords: 6)
            == ["Contoso Ltd", "Valerie"])
        #expect(Transcription.terms(["a", "b", "c"], limit: 2, maxWords: 6) == ["a", "b"])
    }

    @Test func languageCodes() {
        for (given, code) in [("de", "de"), ("de-DE", "de"), ("German", "de"), ("klingon", nil), ("", nil)] as [(String, String?)] {
            #expect(Transcription.languageCode(.string(given)) == code)
        }
        #expect(Transcription.languageCode(.int(3)) == nil)
    }
}
