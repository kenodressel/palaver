// The HTTP transport every cloud call goes through (cloud_llm.py `send`, `urllib_transport`, `redact`).
//
// Redirects are never followed: the key headers would go along to wherever a 3xx points, so a redirect is an error
// naming its target. A refused key (401/403) and other client errors fail at once; rate limits (429), server errors
// and timeouts are tried again, up to ATTEMPTS times, waiting as long as the provider asks (Retry-After, capped) or
// BACKOFF_SECONDS. A request that creates something (`idempotent: false`) is sent again only after a 429, which says it
// was not taken. Error messages never hold the API key: they are built here, and the provider's own words pass through
// `redact`.
import Foundation
import PalaverCore
import PalaverDomain

/// A cloud call failed; the message is safe to show and to log. `status` and `providerMessage` (redacted) for a client
/// error the provider answered (a 4xx other than 401/403).
public struct CloudError: Error, CustomStringConvertible {
    public let message: String
    public let status: Int?
    public let providerMessage: String?

    public init(_ message: String, status: Int? = nil, providerMessage: String? = nil) {
        self.message = message
        self.status = status
        self.providerMessage = providerMessage
    }

    public var description: String { message }
}

public struct HTTPClient: Sendable {
    public static let ATTEMPTS = 3
    public static let BACKOFF_SECONDS = [2.0, 8.0]
    public static let MAX_WAIT_SECONDS = 60.0
    public static let MAX_ERROR_CHARS = 300
    public static let RETRY_STATUS: Set<Int> = [408, 409, 429, 500, 502, 503, 504, 529]

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public var transport: Transport
    public var sleep: @Sendable (Double) async -> Void

    /// `transport` nil: URLSession without redirects, cookies or caches (`HTTPClient.urlSession`).
    public init(transport: Transport? = nil,
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.transport = transport ?? HTTPClient.urlSession
        self.sleep = sleep
    }

    // MARK: - URLSession

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)  // the 3xx comes back as it is
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// Sends `request` (its `timeoutInterval` is the time allowed without an answer). An HTTP error status (a redirect
    /// too, never followed) is an answer like any other; a host that can't be reached or a timeout throws URLError.
    public static let urlSession: Transport = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    // MARK: - Sending

    /// `text` without the key, without anything that looks like a key, and short.
    public static func redact(_ text: String, key: String?) -> String {
        var out = text
        if let key, !key.isEmpty { out = out.replacingOccurrences(of: key, with: "…", options: .literal) }
        let range = NSRange(out.startIndex..., in: out)
        out = keyish.stringByReplacingMatches(in: out, range: range, withTemplate: "…")
        let scalars = out.unicodeScalars
        guard scalars.count > MAX_ERROR_CHARS else { return out }
        return String(String.UnicodeScalarView(scalars.prefix(MAX_ERROR_CHARS))) + "…"
    }

    /// An unexpected error's text for a log or an answer: its description with URL queries (a service may take its key
    /// as `?key=…`), `key` and key-like strings left out (`redact`).
    public static func redactedDescription(_ error: Error, key: String?) -> String {
        let text = String(describing: error)
        let range = NSRange(text.startIndex..., in: text)
        return redact(urlQuery.stringByReplacingMatches(in: text, range: range, withTemplate: "$1?…"), key: key)
    }

    private static let urlQuery = try! NSRegularExpression(pattern: #"(\b[a-z][a-z0-9+.-]*://[^\s?#"']+)\?[^\s#"']*"#,
                                                           options: [.caseInsensitive])

    /// Things that look like API keys, also half-masked ("sk-abc***wxyz").
    private static let keyish = try! NSRegularExpression(
        pattern: #"\b(?:sk|pk|rk|key|api)[-_][\w*.-]{3,}|\b[A-Za-z0-9]{32,}\b"#, options: [.caseInsensitive])

    /// The provider's own words in an error answer: `error.message`, `error.type`, `error`, `message`, else the text.
    static func providerMessage(_ body: Data) -> String {
        guard let data = try? PythonJSON.parse(body) else {
            return Py.strip(String(decoding: body, as: UTF8.self))
        }
        guard case .object = data else { return "" }
        if case .object = data["error"] ?? .null {
            let e = data["error"]!
            for k in ["message", "type"] { if let v = e[k], v.truthy { return Py.str(v) } }
            return ""
        }
        if let e = data["error"], e.truthy { return Py.str(e) }
        if let m = data["message"], m.truthy { return Py.str(m) }
        return ""
    }

    static func backoff(_ attempt: Int) -> Double { BACKOFF_SECONDS[min(attempt, BACKOFF_SECONDS.count - 1)] }

    /// Retry-After in seconds (capped), else the backoff.
    static func wait(_ response: HTTPURLResponse, attempt: Int) -> Double {
        if let asked = response.value(forHTTPHeaderField: "Retry-After").flatMap({ Double(Py.strip($0)) }), asked >= 0 {
            return min(asked, MAX_WAIT_SECONDS)
        }
        return backoff(attempt)
    }

    /// Sends `request` with the retry policy; the answer of a 2xx. `name` (the provider's label) and `key` (left out of
    /// every message) are for the errors.
    public func send(_ request: URLRequest, name: String, key: String?, idempotent: Bool = true,
                     attempts: Int = ATTEMPTS) async throws -> (Data, HTTPURLResponse) {
        let host = request.url.flatMap { ModelChoice.hostname($0.absoluteString) } ?? request.url?.absoluteString ?? "?"
        var problem = ""
        var wait = 0.0
        for attempt in 0..<attempts {
            if attempt > 0 { await sleep(wait) }
            try Task.checkCancellation()
            let data: Data, response: HTTPURLResponse
            do {
                (data, response) = try await transport(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as URLError where e.code == .timedOut {
                if !idempotent { throw CloudError("\(name): \(host) timed out; not sent again, as it may have arrived") }
                (problem, wait) = ("\(host) timed out", Self.backoff(attempt))
                continue
            } catch {
                if !idempotent {
                    throw CloudError("\(name): the connection to \(host) failed; not sent again, as it may have arrived")
                }
                (problem, wait) = ("could not reach \(host)", Self.backoff(attempt))
                continue
            }
            let status = response.statusCode
            if (200..<300).contains(status) { return (data, response) }
            if (300..<400).contains(status) {
                let location = response.value(forHTTPHeaderField: "Location") ?? ""
                let target = request.url.flatMap { URL(string: location, relativeTo: $0)?.absoluteURL }
                let where_ = target.flatMap { ModelChoice.hostname($0.absoluteString) } ?? "an address it did not give"
                throw CloudError("\(name) answered with a redirect to \(where_) (HTTP \(status)). Palaver does not follow "
                                 + "redirects, so nothing was sent there; check the endpoint in Settings.")
            }
            if status == 401 || status == 403 {
                throw CloudError("\(name) refused the API key (HTTP \(status)); check or replace it in Settings")
            }
            if Self.RETRY_STATUS.contains(status) && (idempotent || status == 429) {
                (problem, wait) = ("HTTP \(status)", Self.wait(response, attempt: attempt))
                continue
            }
            let said = Self.redact(Self.providerMessage(data), key: key)
            throw CloudError(said.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(said)", status: status, providerMessage: said)
        }
        throw CloudError("\(name) failed after \(attempts) tr\(attempts == 1 ? "y" : "ies"): \(problem)")
    }

    /// `send` for a JSON API: the answer's object. `emptyOK`: an answer without a body (a DELETE's 204) is `{}`.
    public func sendJSON(_ request: URLRequest, name: String, key: String?, idempotent: Bool = true,
                         emptyOK: Bool = false) async throws -> JSONValue {
        let (data, _) = try await send(request, name: name, key: key, idempotent: idempotent)
        if emptyOK && Py.strip(String(decoding: data, as: UTF8.self)).isEmpty { return .object([]) }
        guard let answer = try? PythonJSON.parse(data), case .object = answer else {
            throw CloudError("\(name) answered with something that is not JSON")
        }
        return answer
    }
}

/// `runBlocking(timeout:)` gave up waiting.
public struct TimedOut: Error, CustomStringConvertible {
    public let seconds: Double
    public var description: String { "no answer within \(Int(seconds)) seconds" }
}

/// Runs `work` to its end from synchronous code (a request's own thread, never the cooperative pool): its answer or
/// its error. With `timeout`, waits that long at most: then `work` is cancelled (left to end in the background) and
/// this throws `TimedOut`. `work` runs on `BlockingWorkExecutor`'s threads, not the cooperative pool's: threads that
/// block in a busy process (other requests waiting here, synchronous tests) can't keep it from running.
public func runBlocking<T>(timeout: Double? = nil, _ work: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    let task = Task.detached(executorPreference: BlockingWorkExecutor.shared) {
        do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
        done.signal()
    }
    if let timeout {
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw TimedOut(seconds: timeout)
        }
    } else {
        done.wait()
    }
    return try box.result!.get()
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// The executor of `runBlocking`'s work: each job on a thread of its own, so the work and what it awaits (URLSession's
/// answers, sleeps) never wait for a cooperative pool that blocked callers hold, nor for GCD's: a concurrent queue's
/// block starts only while fewer of GCD's threads than cores are busy, and while a transcription (or a test run on a
/// 3-core CI runner) keeps them busy the work did not start at all and a `timeout` passed without it.
public final class BlockingWorkExecutor: TaskExecutor, @unchecked Sendable {
    public static let shared = BlockingWorkExecutor()

    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        let thread = Thread { job.runSynchronously(on: executor) }
        thread.name = "palaver-run-blocking"
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}
