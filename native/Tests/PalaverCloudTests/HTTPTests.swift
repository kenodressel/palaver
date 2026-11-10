// The HTTP transport (cloud_llm.send's policy): retries, waits, redirects refused, a refused key, redaction — through a
// fake transport, and over real sockets against a stub server on this Mac.
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverCloud

private func request(_ url: String = "https://api.example.com/v1/x", timeout: Double = 5) -> URLRequest {
    var r = URLRequest(url: URL(string: url)!, timeoutInterval: timeout)
    r.httpMethod = "POST"
    r.setValue(KEY, forHTTPHeaderField: "x-api-key")
    r.httpBody = Data("{}".utf8)
    return r
}

@Suite struct HTTPPolicyTests {
    @Test func a429WaitsAsLongAsTheProviderAsks() async throws {
        let fake = FakeTransport(.answer(429, ["Retry-After": "7"], errorBody("slow down")), .answer(200, [:], "{\"ok\": true}"))
        let (data, _) = try await fake.client.send(request(), name: "P", key: KEY)
        #expect(String(decoding: data, as: UTF8.self) == "{\"ok\": true}" && fake.waits == [7.0])
    }

    @Test func retryAfterIsCapped() async throws {
        let fake = FakeTransport(.answer(429, ["Retry-After": "3600"], ""), .answer(200, [:], "{}"))
        _ = try await fake.client.send(request(), name: "P", key: KEY)
        #expect(fake.waits == [HTTPClient.MAX_WAIT_SECONDS])
    }

    @Test(arguments: [408, 409, 500, 502, 503, 504, 529])
    func serverErrorsAreRetriedWithBackoffThenGivenUp(status: Int) async {
        let fake = FakeTransport(.answer(status, [:], errorBody("x")), .answer(status, [:], errorBody("x")), .answer(status, [:], errorBody("x")))
        let e = await thrown { try await fake.client.send(request(), name: "P", key: KEY) } as? CloudError
        #expect(fake.requests.count == 3 && fake.waits == [2.0, 8.0])
        #expect(e?.message == "P failed after 3 tries: HTTP \(status)")
    }

    @Test func aServerErrorThenSuccess() async throws {
        let fake = FakeTransport(.answer(503, [:], ""), .answer(200, [:], "{}"))
        _ = try await fake.client.send(request(), name: "P", key: KEY)
        #expect(fake.waits == [2.0])
    }

    @Test(arguments: [401, 403])
    func aRefusedKeyIsNotRetriedAndNeverQuoted(status: Int) async {
        let fake = FakeTransport(.answer(status, [:], errorBody("Incorrect API key provided: \(KEY.prefix(12))***\(KEY.suffix(4)) (\(KEY))")))
        let e = await thrown { try await fake.client.send(request(), name: "Anthropic API", key: KEY) } as? CloudError
        #expect(fake.requests.count == 1 && fake.waits.isEmpty)
        #expect(e?.message == "Anthropic API refused the API key (HTTP \(status)); check or replace it in Settings")
    }

    @Test(arguments: [400, 404, 422])
    func otherClientErrorsKeepTheProvidersWordsWithoutTheKey(status: Int) async {
        let fake = FakeTransport(.answer(status, [:], errorBody("model gpt-x not found for key \(KEY)")))
        let e = await thrown { try await fake.client.send(request(), name: "P", key: KEY) } as? CloudError
        #expect(fake.requests.count == 1)
        #expect(e?.status == status && e?.message.contains("model gpt-x not found") == true && e?.message.contains(KEY) == false)
    }

    @Test(arguments: [301, 302, 303, 307, 308])
    func aRedirectIsAnErrorNamingItsTarget(status: Int) async {
        let fake = FakeTransport(.answer(status, ["Location": "https://collector.evil.example/steal"], ""))
        let e = await thrown { try await fake.client.send(request(), name: "P", key: KEY) } as? CloudError
        #expect(fake.requests.count == 1 && fake.waits.isEmpty)
        #expect(e?.message.contains("redirect to collector.evil.example (HTTP \(status))") == true)
    }

    @Test func timeoutsAndUnreachableHostsAreRetried() async {
        var fake = FakeTransport(.fail(URLError(.timedOut)), .fail(URLError(.timedOut)), .fail(URLError(.timedOut)))
        var e = await thrown { try await fake.client.send(request(), name: "P", key: KEY) } as? CloudError
        #expect(fake.requests.count == 3 && e?.message == "P failed after 3 tries: api.example.com timed out")
        fake = FakeTransport(.fail(URLError(.cannotConnectToHost)), .fail(URLError(.cannotConnectToHost)),
                             .fail(URLError(.cannotConnectToHost)))
        e = await thrown { try await fake.client.send(request(), name: "P", key: KEY) } as? CloudError
        #expect(e?.message == "P failed after 3 tries: could not reach api.example.com")
    }

    @Test func aRequestThatCreatesSomethingIsSentAgainOnlyAfterA429() async throws {
        var fake = FakeTransport(.fail(URLError(.timedOut)))
        var e = await thrown { try await fake.client.send(request(), name: "P", key: KEY, idempotent: false) } as? CloudError
        #expect(fake.requests.count == 1 && e?.message == "P: api.example.com timed out; not sent again, as it may have arrived")
        fake = FakeTransport(.answer(503, [:], ""))
        e = await thrown { try await fake.client.send(request(), name: "P", key: KEY, idempotent: false) } as? CloudError
        #expect(fake.requests.count == 1 && e?.status == 503)
        fake = FakeTransport(.answer(429, ["Retry-After": "1"], ""), .answer(201, [:], "{}"))
        _ = try await fake.client.send(request(), name: "P", key: KEY, idempotent: false)
        #expect(fake.requests.count == 2 && fake.waits == [1.0])
    }

    @Test func redactHidesTheKeyAndAnythingLikeOne() {
        let out = HTTPClient.redact("bad key \(KEY); also sk-proj-ABCDEFGHIJKLMNOP1234 and sk-abc***wxyz and "
                                    + "0123456789abcdef0123456789abcdef", key: KEY)
        #expect(!out.contains(KEY) && !out.contains("sk-proj-ABCDEFGHIJKLMNOP1234") && !out.contains("sk-abc")
                && !out.contains("0123456789abcdef0123456789abcdef"))
        #expect(out.hasPrefix("bad key"))
        #expect(HTTPClient.redact(String(repeating: "x ", count: 2500), key: KEY).count <= HTTPClient.MAX_ERROR_CHARS + 1)
    }

    @Test func jsonAnswersAndWhatIsNotJSON() async throws {
        var fake = FakeTransport(.answer(200, [:], "<html>proxy login</html>"))
        let e = await thrown { try await fake.client.sendJSON(request(), name: "P", key: nil) } as? CloudError
        #expect(e?.message == "P answered with something that is not JSON")
        fake = FakeTransport(.answer(204, [:], ""))
        #expect(try await fake.client.sendJSON(request(), name: "P", key: nil, emptyOK: true) == .object([]))
    }
}

@Suite(.serialized) struct HTTPOverTheWireTests {
    @Test func theRealTransportRefusesRedirectsAndTheKeyStaysHome() async throws {
        // Two servers on this Mac: the endpoint answers 302 to the other one, which must never see a request.
        let target = try StubServer()
        defer { target.stop() }
        let endpoint = try StubServer { _ in StubServer.Answer(status: 302, headers: [("Location", "http://localhost:\(target.port)/steal")]) }
        defer { endpoint.stop() }
        let e = await thrown { try await HTTPClient().send(request(endpoint.url + "/v1/messages"), name: "P", key: KEY) } as? CloudError
        #expect(e?.message.contains("redirect to localhost") == true)
        #expect(endpoint.requests.count == 1 && target.requests.isEmpty)
    }

    @Test func aRefusedKeyAndRetryAfterOverTheWire() async throws {
        var calls = 0
        let server = try StubServer { _ in
            calls += 1
            return calls == 1 ? .json(.object([("error", .string("busy"))]), status: 429, headers: [("Retry-After", "0")])
                : .json(.object([("ok", .bool(true))]))
        }
        defer { server.stop() }
        let answer = try await HTTPClient().sendJSON(request(server.url + "/v1/x"), name: "P", key: KEY)
        #expect(answer["ok"] == .bool(true) && server.requests.count == 2)
        #expect(server.requests[0].headers["x-api-key"] == KEY && server.requests[0].method == "POST")

        let refusing = try StubServer { _ in .json(.object([("error", .object([("message", .string("invalid x-api-key \(KEY)"))]))]), status: 401) }
        defer { refusing.stop() }
        let e = await thrown { try await HTTPClient().send(request(refusing.url + "/v1/x"), name: "P", key: KEY) } as? CloudError
        #expect(e?.message == "P refused the API key (HTTP 401); check or replace it in Settings" && refusing.requests.count == 1)
    }

    @Test func aSlowServerTimesOutAndIsTriedAgain() async throws {
        let server = try StubServer { _ in StubServer.Answer(delay: 1.5) }
        defer { server.stop() }
        final class Seen: @unchecked Sendable { var errors: [String] = []; let lock = NSLock() }
        let seen = Seen()
        let client = HTTPClient(transport: { r in
            do { return try await HTTPClient.urlSession(r) } catch { seen.lock.withLock { seen.errors.append("\(error)") }; throw error }
        }, sleep: { _ in })
        let e = await thrown { try await client.send(request(server.url + "/v1/x", timeout: 0.3), name: "P", key: KEY) } as? CloudError
        #expect(e?.message == "P failed after 3 tries: 127.0.0.1 timed out", "\(seen.errors)")
        #expect(server.requests.count == 3)
    }
}

/// runBlocking from a thread that waits for it (a request's thread in palaver-server) must not need the cooperative pool:
/// in a busy process (the parallel test run: synchronous tests blocking pool threads) its work would wait for a free one,
/// and a provider's Test button took 10+ s (ProviderRoutesInProcessTests.test_http_language_model, a recurring flake).
@Suite struct RunBlockingTests {
    /// The label of the dispatch queue the calling code runs on.
    static func queueLabel() -> String { String(cString: __dispatch_queue_get_label(nil)) }

    @Test func itsWorkAndWhatItAwaitsRunOnItsOwnQueueNotTheCooperativePool() throws {
        // Checked by where the work runs rather than by starving the pool, which would slow every other test of this
        // process down while it runs.
        let labels = try runBlocking(timeout: 10) { () -> [String] in
            let before = RunBlockingTests.queueLabel()
            try await Task.sleep(nanoseconds: 10_000_000)  // resumed on runBlocking's executor too
            return [before, RunBlockingTests.queueLabel()]
        }
        #expect(labels == ["palaver.run-blocking", "palaver.run-blocking"])
    }
}
