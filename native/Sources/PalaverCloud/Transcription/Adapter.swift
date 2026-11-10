// Transcription services in the cloud, over HTTP (palaver/cloud_asr.py, #54): AssemblyAI, Soniox, Mistral Voxtral and
// OpenAI-compatible endpoints. An adapter takes one piece of audio (FLAC, 16 kHz mono) and returns the words it heard,
// with timestamps in seconds from the start of that piece, so they can be lined up with the speaker turns worked out
// on this Mac.
//
// Only CloudTranscription makes adapters, and only for the provider the user chose; nothing here decides to send
// anything. Requests go through HTTPClient: the same transport, retries, refused redirects and redacted keys as the
// language models. Speaker diarization is never asked for: who spoke when stays on this Mac.
//
// What a service keeps is deleted there as soon as the words are back (AssemblyAI: the transcript, and the upload with
// it; Soniox: the transcription and the file). A job that has not ended yet can't be deleted: it gets
// CLEANUP_WAIT_SECONDS more to end, and what still can't be deleted is left in `pending` for the caller to keep and
// retry (TranscriptionPending) until the service says it is gone. An AssemblyAI upload that never became a job can't be
// deleted by anyone but AssemblyAI (within 48 hours); it is noted with that date.
//
// Requests that create something (uploads, jobs) are never sent twice after a timeout or a server error, only after a
// 429 (`idempotent: false`): a second job would be a second copy at the service.
import Foundation
import PalaverCore
import PalaverDomain

/// What a service heard in one piece of audio.
public struct Heard: Sendable {
    public var words: [Word]
    public var language: String?
    public var billedSeconds: Double?

    public init(words: [Word], language: String? = nil, billedSeconds: Double? = nil) {
        self.words = words
        self.language = language
        self.billedSeconds = billedSeconds
    }
}

/// The service ended the job with an error; `reason` is its (redacted) word.
public struct JobFailed: Error, CustomStringConvertible {
    public let name: String
    public let reason: String
    public var description: String { "\(name) could not transcribe it: \(reason)" }
}

/// The base of every adapter: the requests, waiting for a job, deleting what the service keeps.
public class TranscriptionAdapter: @unchecked Sendable {
    public static let FILENAME = "audio.flac"
    public static let CONTENT_TYPE = "audio/flac"
    /// Waits between status checks; the last one repeats.
    public static let POLL_SECONDS = [2.0, 3.0, 5.0, 10.0]
    /// How long a job may take: this, or twice the audio.
    public static let MIN_WAIT_SECONDS = 600.0
    /// More time for a job given up on to end, so it can be deleted.
    public static let CLEANUP_WAIT_SECONDS = 300.0
    /// AssemblyAI deletes an upload without a transcript within this.
    public static let UPLOAD_KEPT_SECONDS = 48 * 3600.0
    /// AssemblyAI's error for a clip without speech.
    public static let NO_SPEECH = "no spoken audio"
    /// A slow uplink, for an upload's timeout.
    public static let UPLOAD_BYTES_PER_SECOND = 250_000.0
    public static let MIN_TIMEOUT_SECONDS = 120.0
    public static let REQUEST_TIMEOUT_SECONDS = 60.0

    public let pid: String
    public let name: String
    public let model: String
    let key: String?
    public let host: String
    /// Audio one request may carry.
    public let maxSeconds: Double
    public let maxBytes: Int
    let http: HTTPClient
    let clock: @Sendable () -> Double
    /// What could not be deleted at the service: for the caller to keep and retry (cloud-pending.json entries).
    public var pending: [JSONValue] = []

    init(pid: String, name: String, model: String, key: String?, host: String, maxSeconds: Double, maxBytes: Int,
         http: HTTPClient, clock: @escaping @Sendable () -> Double) {
        self.pid = pid
        self.name = name
        self.model = model
        self.key = key
        self.host = host
        self.maxSeconds = maxSeconds
        self.maxBytes = maxBytes
        self.http = http
        self.clock = clock
    }

    /// The words in `audio` (FLAC), `seconds` long. `language` nil: the service detects it (`fallbackLanguage` for a
    /// clip without speech, where the service asks for one).
    public func transcribe(_ audio: Data, seconds: Double, language: String?, keyterms: [String],
                           fallbackLanguage: String? = nil) async throws -> Heard {
        fatalError("an adapter transcribes")
    }

    // MARK: - Requests

    static func uploadTimeout(_ bytes: Int) -> Double { max(MIN_TIMEOUT_SECONDS, Double(bytes) / UPLOAD_BYTES_PER_SECOND) }

    /// One request through the transport; the answer's JSON object (`emptyOK`: `{}` for an answer without a body).
    func send(_ method: String, _ url: String, _ headers: [(String, String)], _ body: Data? = nil,
              timeout: Double = REQUEST_TIMEOUT_SECONDS, emptyOK: Bool = false, attempts: Int = HTTPClient.ATTEMPTS) async throws -> JSONValue {
        guard let target = URL(string: url) else { throw CloudError("\(name): not a usable address") }
        var request = URLRequest(url: target, timeoutInterval: timeout)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let body { request.httpBody = body }
        let (data, _) = try await http.send(request, name: name, key: key, idempotent: method != "POST", attempts: attempts)
        if emptyOK && Py.strip(String(decoding: data, as: UTF8.self)).isEmpty { return .object([]) }
        guard let answer = try? PythonJSON.parse(data), case .object = answer else {
            throw CloudError("\(name) answered with something that is not JSON")
        }
        return answer
    }

    /// Checks the job until it is completed: JobFailed when it ended with an error, a CloudError when it takes longer
    /// than `limit`.
    func wait(_ fetch: () async throws -> JSONValue, limit: Double, failed: [String], message: String) async throws -> JSONValue {
        let deadline = clock() + limit
        var attempt = 0
        while true {
            let data = try await fetch()
            let status = data["status"]?.stringValue
            if status == "completed" { return data }
            if let status, failed.contains(status) {
                let said = data[message].flatMap { $0.truthy ? Py.str($0) : nil } ?? "no reason given"
                throw JobFailed(name: name, reason: HTTPClient.redact(said, key: key))
            }
            if clock() > deadline {
                throw CloudError("\(name) did not finish within \(Int((limit / 60).rounded())) min")
            }
            await http.sleep(Self.POLL_SECONDS[min(attempt, Self.POLL_SECONDS.count - 1)])
            attempt += 1
        }
    }

    /// Waits for the job at `url` and deletes it, however it ends: one given up on gets CLEANUP_WAIT_SECONDS more to
    /// end first.
    func runJob(_ fetch: () async throws -> JSONValue, seconds: Double, failed: [String], message: String, url: String,
             headers: [(String, String)], what: String) async throws -> JSONValue {
        do {
            let data = try await wait(fetch, limit: max(Self.MIN_WAIT_SECONDS, 2 * seconds), failed: failed, message: message)
            await forget(url, headers, what)
            return data
        } catch let failure as JobFailed {
            await forget(url, headers, what)
            throw failure
        } catch {
            // Still running, not reachable, or ended with an error while waiting: the delete says.
            _ = try? await wait(fetch, limit: Self.CLEANUP_WAIT_SECONDS, failed: failed, message: message)
            await forget(url, headers, what)
            throw error
        }
    }

    /// Deletes `url` at the service; what can't be deleted now goes to `pending`.
    func forget(_ url: String, _ headers: [(String, String)], _ what: String) async {
        do {
            _ = try await send("DELETE", url, headers, emptyOK: true, attempts: 1)
        } catch {
            if let e = error as? CloudError, e.status == 404 { return }  // gone already
            let problem = (error as? CloudError).map { HTTPClient.redact($0.message, key: key) } ?? "\(type(of: error))"
            pending.append(.object([("provider", .string(pid)), ("host", .string(host)), ("what", .string(what)),
                                    ("url", .string(url)), ("since", .string(Transcription.now())), ("error", .string(problem))]))
        }
    }

    /// An id from the answer, usable in a URL path.
    func id(_ data: JSONValue, _ what: String) throws -> String {
        guard let value = data[what]?.stringValue, !value.isEmpty, !value.contains("/") else {
            throw CloudError("\(name) answered without a usable \(what)")
        }
        return value
    }
}

/// What the adapters share.
public enum Transcription {
    /// Two-letter codes for the language names Whisper-style endpoints answer with.
    static let LANGUAGE_NAMES = ["german": "de", "english": "en", "french": "fr", "spanish": "es", "italian": "it",
                                 "dutch": "nl", "portuguese": "pt", "polish": "pl", "czech": "cs", "turkish": "tr"]

    /// The local time with its offset, to the second.
    static func now() -> String { Py.isoNow(timespec: "seconds") }

    /// "de", "de_de", "German" -> "de"; nil when it is no language.
    public static func languageCode(_ value: JSONValue?) -> String? {
        guard case .string(let raw)? = value else { return nil }
        let v = Py.strip(raw).lowercased().replacingOccurrences(of: "-", with: "_")
        guard !v.isEmpty else { return nil }
        let chars = Array(v)
        func letter(_ c: Character) -> Bool { c.isLetter }
        if chars.count == 2 && chars.allSatisfy(letter) { return v }
        if chars.count > 2 && chars[2] == "_" && chars[0..<2].allSatisfy(letter) { return String(chars[0..<2]) }
        return LANGUAGE_NAMES[v]
    }

    /// The keyterms a service takes: one line each, at most `maxWords` words, each once (casefolded), the first `limit`.
    public static func terms(_ keyterms: [String], limit: Int, maxWords: Int) -> [String] {
        var out: [String] = []
        var seen = Set<ScalarKey>()
        for raw in keyterms {
            let words = raw.split(whereSeparator: { $0.isWhitespace })
            let t = words.joined(separator: " ")
            if t.isEmpty || words.count > maxWords { continue }
            let folded = ScalarKey(Py.casefold(t))
            if seen.contains(folded) { continue }
            seen.insert(folded)
            out.append(t)
            if out.count >= limit { break }
        }
        return out
    }

    /// A multipart/form-data body: its content type and its bytes. The file parts' data is copied in once.
    public static func multipart(fields: [(String, String)], files: [(name: String, filename: String, type: String, data: Data)])
        -> (String, Data) {
        let boundary = "palaver-" + (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        var out = Data()
        out.reserveCapacity(files.reduce(1024) { $0 + $1.data.count })
        for (name, value) in fields {
            out.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            out.append(Data(value.utf8))
            out.append(Data("\r\n".utf8))
        }
        for f in files {
            out.append(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(f.name)\"; filename=\"\(f.filename)\"\r\n"
                + "Content-Type: \(f.type)\r\n\r\n").utf8))
            out.append(f.data)
            out.append(Data("\r\n".utf8))
        }
        out.append(Data("--\(boundary)--\r\n".utf8))
        return ("multipart/form-data; boundary=\(boundary)", out)
    }

    /// Milliseconds as seconds, to the millisecond.
    static func ms(_ value: JSONValue?) -> Double { Py.round((value?.doubleValue ?? 0) / 1000, 3) }

    static func confidence(_ value: JSONValue?) -> Double? {
        guard let v = value?.doubleValue else { return nil }
        return Py.round(v, 3)
    }

    /// The adapter for provider `pid` with its settings (ProviderSettings.settingsOf); its key for the requests only.
    public static func adapter(_ pid: String, settings: PyDict<JSONValue>, key: String?, http: HTTPClient = HTTPClient(),
                               clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) throws
        -> TranscriptionAdapter {
        func setting(_ k: String) -> String { settings[k].map { $0.stringValue ?? Py.str($0) } ?? "" }
        let model = setting("model")
        switch pid {
        case "assemblyai":
            return AssemblyAI(model: model, region: setting("region"), key: key, http: http, clock: clock)
        case "soniox":
            return Soniox(model: model, region: setting("region"), key: key, http: http, clock: clock)
        case "mistral":
            return Mistral(model: model, key: key, http: http, clock: clock)
        case "openai-transcribe":
            let auth = settings["auth"]?.stringValue ?? "auto"
            return OpenAITranscribe(pid: pid, name: "OpenAI-compatible", endpoint: setting("endpoint"), model: model,
                                    auth: auth, key: key, http: http, clock: clock)
        default:
            throw SettingRefused("no transcription service \(Py.repr(.string(pid)))")
        }
    }
}
