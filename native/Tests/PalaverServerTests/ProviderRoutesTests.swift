// The Settings page's Language model and Transcription sections (api.py `language_model` … `test_transcription`,
// server.py's GET branches, `_settings_post`, `_model_test`, `count_setting`). Ports the language-model and
// transcription tests of tests/test_webapp.py under their names, against a fake provider helper; these pin what the
// window's server adds — which action each route asks, with which body and budget, how the answers and errors come
// back, the usage count, and that a key never comes back to the page or into a log. The second suite runs the routes
// over the in-process providers (`Providers`): a file key store (never the Keychain) and stub services on this Mac.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
import PalaverCloud
@testable import PalaverServer

private let KEY = "sk-ant-api03-SECRET-abcdefghijklmnop"
private let ASR_KEY = "aai-SECRET-abcdefghijklmnopqrstuvwxyz0123"

private func dumps(_ v: JSONValue?) -> String { v.map { PythonJSON.dumps($0, ensureAscii: false) } ?? "nil" }
private func parse(_ s: String) -> JSONValue { try! PythonJSON.parse(Data(s.utf8)) }

/// `palaver provider` faked in this process: each call kept (action, body, budget); `answer` gives what it says.
private final class FakeProvider: ProviderHelper, @unchecked Sendable {
    struct Call {
        let action: String
        let body: JSONValue
        let timeout: Double
    }

    private let lock = NSLock()
    private var kept: [Call] = []
    var answer: (String, JSONValue) throws -> JSONValue

    init(_ answer: @escaping (String, JSONValue) throws -> JSONValue = { _, _ in .object([]) }) { self.answer = answer }

    var calls: [Call] { lock.withLock { kept } }

    func call(_ action: String, body: JSONValue, timeout: Double) throws -> JSONValue {
        lock.withLock { kept.append(Call(action: action, body: body, timeout: timeout)) }
        return try answer(action, body)
    }
}

/// The helper's side as Python keeps it, much simplified: the keys set (never shown), each feature's choice; a
/// provider without its key can't be chosen; a Test button fails with what the provider said.
private final class Settings: @unchecked Sendable {
    var keys: [String: String] = [:]
    var notes = "local"
    var transcription = "local"
    var testFails = false

    func page(_ action: String) -> JSONValue {
        let lm: [(String, JSONValue)] = [
            ("features", .array([.object([("id", .string("notes")), ("choice", .string(notes))])])),
            ("providers", .array([.object([("id", .string("anthropic")), ("key_set", .bool(keys["anthropic"] != nil))])])),
            ("log", .array([])),
        ]
        let tr: [(String, JSONValue)] = [
            ("feature", .object([("id", .string("transcription")), ("choice", .string(transcription))])),
            ("providers", .array([.object([("id", .string("assemblyai")), ("key_set", .bool(keys["assemblyai"] != nil))])])),
            ("month", .object([("seconds", .double(0.0)), ("usd", .double(0.0)), ("meetings", .int(0))])),
        ]
        return .object(action.contains("transcription") ? tr : lm)
    }

    func answer(_ action: String, _ body: JSONValue) throws -> JSONValue {
        let provider = body["provider"]?.stringValue ?? ""
        switch action {
        case "set-key", "set-transcription-key":
            if provider == "claude-cli" { throw Refused("Claude Code CLI takes no API key") }
            if body["remove"] == .bool(true) {
                keys[provider] = nil
                return page(action)
            }
            guard let key = body["key"]?.stringValue, !key.contains("\n") else { throw Refused("that is not an API key") }
            keys[provider] = key
        case "set-language-model":
            if let use = body["use"]?["notes"]?.stringValue {
                if use != "local" && keys[use] == nil { throw Refused("Anthropic API: Add the API key") }
                notes = use
            }
        case "set-transcription":
            if let use = body["use"]?.stringValue {
                if use != "local" && keys[use] == nil { throw Refused("Soniox: Add the API key") }
                transcription = use
            }
        case "test":
            if testFails { throw BadGateway("Anthropic API answered 401: invalid x-api-key [redacted]") }
            return parse(#"{"answer": "Hello there", "seconds": 0.4, "model": "claude-opus-5-5"}"#)
        case "test-transcription":
            if testFails { throw BadGateway("AssemblyAI refused the API key (401)") }
            return parse(#"{"seconds": 1.2, "model": "universal-3-5-pro", "usd_per_hour": 0.28}"#)
        default: break
        }
        return page(action)
    }
}

private func usage(_ s: TestServer) -> String { (try? String(contentsOf: s.app.stores.usage, encoding: .utf8)) ?? "" }

@Suite(.serialized) struct ProviderRoutesTests {
    @Test func test_language_model_page_starts_local_and_says_what_goes_where() throws {
        // The helper's answer reaches the page as it is: key order, floats and all.
        let page = #"{"features": [{"id": "notes", "choice": "local"}], "providers": [], "local": {"model": "x"}, "log": [], "n": 1.0}"#
        let fake = FakeProvider { _, _ in parse(page) }
        let s = try TestServer(provider: fake)
        defer { s.stop() }
        let r = s.get("/api/language-model")
        #expect(r.status == 200 && r.text == page)
        #expect(fake.calls.map(\.action) == ["language-model"])
        #expect(dumps(fake.calls.first?.body) == "{}" && fake.calls.first?.timeout == Providers.TIMEOUT)
        #expect(usage(s).isEmpty)  // looking counts nothing
    }

    @Test func test_set_key_never_comes_back_to_the_page() throws {
        let settings = Settings()
        let fake = FakeProvider(settings.answer)
        let s = try TestServer(provider: fake)
        defer { s.stop() }
        var r = s.post("/api/language-model/key", .object([("provider", .string("anthropic")), ("key", .string(KEY))]))
        #expect(r.status == 200 && settings.keys == ["anthropic": KEY])
        #expect(fake.calls.last?.action == "set-key" && fake.calls.last?.body["key"]?.stringValue == KEY)
        #expect(r.json?["providers"]?.arrayValue?.first?["key_set"] == .bool(true))
        #expect(!r.text.contains(KEY) && !s.log.contains(KEY) && !usage(s).contains(KEY))
        #expect(usage(s).contains(#""kind": "setting", "id": "key.anthropic", "removed": false"#))
        r = s.post("/api/language-model/key", .object([("provider", .string("anthropic")), ("remove", .bool(true))]))
        #expect(r.status == 200 && fake.calls.last?.action == "set-key")
        #expect(usage(s).contains(#""id": "key.anthropic", "removed": true"#))
    }

    @Test func test_choosing_a_provider_needs_it_set_up() throws {
        let settings = Settings()
        let fake = FakeProvider(settings.answer)
        let s = try TestServer(provider: fake)
        defer { s.stop() }
        var r = s.post("/api/language-model", .object([("use", .object([("notes", .string("anthropic"))]))]))
        #expect(r.status == 400 && r.error == "Anthropic API: Add the API key")
        #expect(usage(s).isEmpty)  // a change refused is no change
        _ = s.post("/api/language-model/key", .object([("provider", .string("anthropic")), ("key", .string(KEY))]))
        r = s.post("/api/language-model", .object([("use", .object([("notes", .string("anthropic"))]))]))
        #expect(r.status == 200 && r.json?["features"]?.arrayValue?.first?["choice"] == .string("anthropic"))
        #expect(fake.calls.map(\.action) == ["set-language-model", "set-key", "set-language-model"])
        #expect(usage(s).contains(#""id": "use.notes", "value": "anthropic""#))
    }

    @Test func test_provider_settings_and_the_local_model() throws {
        let fake = FakeProvider { action, body in
            if body["endpoint"]?.stringValue == "http://evil.example.com" { throw Refused("the endpoint must use https") }
            return .object([("action", .string(action))])
        }
        let s = try TestServer(provider: fake)
        defer { s.stop() }
        let body = parse(#"{"provider": "openai", "endpoint": "https://acme.openai.azure.com/openai/v1", "model": "gpt-x", "context_tokens": 200000}"#)
        #expect(s.post("/api/language-model", body).status == 200)
        #expect(dumps(fake.calls.last?.body) == dumps(body))  // as it came: the helper checks it
        #expect(usage(s).contains(#""id": "provider.openai", "fields": ["context_tokens", "endpoint", "model"]"#))
        let r = s.post("/api/language-model", parse(#"{"provider": "openai", "endpoint": "http://evil.example.com"}"#))
        #expect(r.status == 400 && r.error == "the endpoint must use https")
        #expect(s.post("/api/language-model", parse(#"{"local_model": "mlx-community/gemma-4-12B-it-OptiQ-4bit"}"#)).status == 200)
        #expect(usage(s).contains(#""id": "local_model", "value": "mlx-community/gemma-4-12B-it-OptiQ-4bit""#))
        #expect(fake.calls.allSatisfy { $0.action == "set-language-model" && $0.timeout == Providers.TIMEOUT })
    }

    @Test func test_test_button() throws {
        let fake = FakeProvider(Settings().answer)
        let s = try TestServer(provider: fake)
        defer { s.stop() }
        let r = s.post("/api/language-model/test", .object([("provider", .string("anthropic"))]))
        #expect(r.status == 200 && r.text == #"{"answer": "Hello there", "seconds": 0.4, "model": "claude-opus-5-5"}"#)
        #expect(fake.calls.map(\.action) == ["test"] && fake.calls.first?.timeout == Providers.TEST_TIMEOUT)
        #expect(usage(s).isEmpty)  // a test is no setting
    }

    @Test func test_http_language_model() throws {
        let settings = Settings()
        let s = try TestServer(provider: FakeProvider(settings.answer))
        defer { s.stop() }
        var r = s.get("/api/language-model")
        #expect(r.status == 200 && r.json?["features"]?.arrayValue?.first?["choice"] == .string("local"))
        r = s.post("/api/language-model", .object([("use", .object([("notes", .string("anthropic"))]))]))
        #expect(r.status == 400 && (r.error ?? "").contains("API key"))
        r = s.post("/api/language-model/key", .object([("provider", .string("anthropic")), ("key", .string(KEY))]))
        #expect(r.status == 200 && !r.text.contains(KEY) && settings.keys["anthropic"] == KEY)
        r = s.post("/api/language-model", .object([("use", .object([("notes", .string("anthropic"))]))]))
        #expect(r.status == 200 && r.json?["features"]?.arrayValue?.first?["choice"] == .string("anthropic"))
        r = s.post("/api/language-model/test", .object([("provider", .string("anthropic"))]))
        #expect(r.status == 200 && r.json?["answer"] == .string("Hello there"))
        settings.testFails = true
        r = s.post("/api/language-model/test", .object([("provider", .string("anthropic"))]))
        #expect(r.status == 502 && (r.error ?? "").contains("401") && !r.text.contains(KEY))
        r = s.get("/api/language-model")
        #expect(!r.text.contains(KEY) && !s.log.contains(KEY))
    }

    @Test func test_transcription_page_starts_local_and_says_what_goes_where() throws {
        let fake = FakeProvider(Settings().answer)
        let s = try TestServer(provider: fake)
        defer { s.stop() }
        let r = s.get("/api/transcription")
        #expect(r.status == 200 && r.json?["feature"]?["choice"] == .string("local"))
        #expect(r.json?["month"]?["seconds"] == .double(0.0))  // what was sent this month comes with it
        #expect(fake.calls.map(\.action) == ["transcription"] && fake.calls.first?.timeout == Providers.TIMEOUT)
    }

    @Test func test_transcription_choice_key_region_and_test() throws {
        let settings = Settings()
        let fake = FakeProvider(settings.answer)
        let s = try TestServer(provider: fake)
        defer { s.stop() }
        #expect(s.post("/api/transcription", .object([("use", .string("assemblyai"))])).status == 400)
        var r = s.post("/api/transcription/key", .object([("provider", .string("assemblyai")), ("key", .string(ASR_KEY))]))
        #expect(r.status == 200 && settings.keys == ["assemblyai": ASR_KEY] && !r.text.contains(ASR_KEY))
        r = s.post("/api/transcription", .object([("use", .string("assemblyai"))]))
        #expect(r.status == 200 && r.json?["feature"]?["choice"] == .string("assemblyai"))
        let region = parse(#"{"provider": "assemblyai", "region": "us", "model": "universal-2"}"#)
        #expect(s.post("/api/transcription", region).status == 200 && dumps(fake.calls.last?.body) == dumps(region))
        r = s.post("/api/transcription/test", .object([("provider", .string("assemblyai"))]))
        #expect(r.status == 200 && r.json?["usd_per_hour"] == .double(0.28))
        #expect(fake.calls.map(\.action) == ["set-transcription", "set-transcription-key", "set-transcription", "set-transcription",
                                             "test-transcription"])
        #expect(fake.calls.last?.timeout == Providers.TEST_TIMEOUT)
        let counted = usage(s)
        #expect(counted.contains(#""id": "key.assemblyai", "removed": false"#) && counted.contains(#""id": "use", "value": "assemblyai""#))
        #expect(counted.contains(#""id": "provider.assemblyai", "fields": ["model", "region"]"#) && !counted.contains(ASR_KEY))
    }

    @Test func test_http_transcription() throws {
        let settings = Settings()
        let s = try TestServer(provider: FakeProvider(settings.answer))
        defer { s.stop() }
        var r = s.get("/api/transcription")
        #expect(r.status == 200 && r.json?["feature"]?["choice"] == .string("local"))
        r = s.post("/api/transcription", .object([("use", .string("soniox"))]))
        #expect(r.status == 400 && (r.error ?? "").contains("API key"))
        r = s.post("/api/transcription/key", .object([("provider", .string("assemblyai")), ("key", .string(ASR_KEY))]))
        #expect(r.status == 200 && !r.text.contains(ASR_KEY))
        r = s.post("/api/transcription", .object([("use", .string("assemblyai"))]))
        #expect(r.status == 200 && r.json?["feature"]?["choice"] == .string("assemblyai"))
        settings.testFails = true
        r = s.post("/api/transcription/test", .object([("provider", .string("assemblyai"))]))
        #expect(r.status == 502 && (r.error ?? "").contains("refused the API key") && !r.text.contains(ASR_KEY))
        r = s.get("/api/transcription")
        #expect(!r.text.contains(ASR_KEY) && !s.log.contains(ASR_KEY))
    }
}

// MARK: - The routes over the in-process providers

/// A window's server whose provider actions run in this process (`Providers`): settings.json and access-log.jsonl in its
/// config dir, keys in a file key store (never the Keychain), no `claude` anywhere; `services` answers what goes to a
/// fixed cloud host (the transcription services), anything else goes over URLSession (a stub on this Mac).
private final class InProcess {
    let dir = tempFolder("providers")
    let services = StubServices()
    let server: TestServer
    var stores: StorePaths { server.app.stores }
    var keychain: String { (try? String(contentsOf: dir.appendingPathComponent("keychain.json"), encoding: .utf8)) ?? "" }

    /// `notes`: more lines of config.toml's [notes].
    init(notes: String = "") throws {
        let stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                                home: dir.appendingPathComponent("home", isDirectory: true))
        let toml = dir.appendingPathComponent("config.toml")
        try ("[notes]\nclaude = \"\(dir.appendingPathComponent("no-claude").path)\"\n" + notes)
            .write(to: toml, atomically: true, encoding: .utf8)
        let services = self.services
        let http = HTTPClient(transport: { request in
            if request.url?.host == "127.0.0.1" { return try await HTTPClient.urlSession(request) }
            return try services.answer(request)
        }, sleep: { _ in })
        let providers = Providers(configURL: toml, stores: stores, keys: FileKeyStore(dir.appendingPathComponent("keychain.json")),
                                  env: ["PATH": ""], http: http)
        server = try TestServer(provider: providers, dir: dir)
    }

    func stop() {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }
}

/// The cloud services' hosts faked in this process: answers by "METHOD URL", each request kept (with its headers).
final class StubServices: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: (Int, String)] = [:]
    private var kept: [URLRequest] = []

    func on(_ method: String, _ url: String, _ status: Int = 200, _ body: String) {
        lock.withLock { routes["\(method) \(url)"] = (status, body) }
    }

    var requests: [URLRequest] { lock.withLock { kept } }

    func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let route = "\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")"
        let found: (Int, String)? = lock.withLock {
            kept.append(request)
            return routes[route]
        }
        guard let (status, body) = found else { throw URLError(.cannotConnectToHost) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}

/// A stub Anthropic API on this Mac: answers `{"reply": …}`, or refuses the key (quoting it) while `refusing`.
private final class StubAnthropic: @unchecked Sendable {
    let fd: Int32
    let port: Int
    var refusing = false
    private(set) var keys: [String] = []

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 8)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.fd = fd
        port = Int(UInt16(bigEndian: addr.sin_port))
        Thread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { return }
                // A client that gave up (a timeout) closed its end: writing to it must be an error, not SIGPIPE, which ends
                // the whole test process (it does not ignore SIGPIPE).
                var noSigpipe: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
                answer(c)
            }
        }.start()
    }

    private func answer(_ c: Int32) {
        defer { close(c) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(c, &buffer, buffer.count)
            guard n > 0 else { return }
            data.append(contentsOf: buffer[0..<n])
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
            let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            if data.count - end.upperBound >= length {
                if let key = head.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("x-api-key:") }) {
                    keys.append(key.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces))
                }
                break
            }
        }
        let (status, body) = refusing
            ? (401, #"{"error": {"message": "invalid x-api-key \#(KEY)"}}"#)
            : (200, #"{"content": [{"type": "text", "text": "{\"reply\": \"Hello there\"}"}], "stop_reason": "end_turn"}"#)
        let out = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = out.withCString { write(c, $0, strlen($0)) }
    }

    func stop() { shutdown(fd, SHUT_RDWR); close(fd) }
}

@Suite(.serialized) struct ProviderRoutesInProcessTests {
    @Test func test_http_language_model() throws {
        let p = try InProcess()
        defer { p.stop() }
        let s = p.server
        let anthropic = try StubAnthropic()
        defer { anthropic.stop() }
        var r = s.get("/api/language-model")
        #expect(r.status == 200 && r.json?["features"]?.arrayValue?.first?["choice"] == .string("local"))
        #expect(r.json?["local"]?["models"]?.arrayValue?.first?["repo"] == .string(ModelChoice.DEFAULT_LOCAL_MODEL))
        #expect(r.json?["labels"]?["soniox"] == .string("Soniox") && r.json?["log"] == .array([]))
        r = s.post("/api/language-model", .object([("use", .object([("notes", .string("anthropic"))]))]))
        #expect(r.status == 400 && r.error == "Anthropic API: Add the API key")
        r = s.post("/api/language-model/key", .object([("provider", .string("anthropic")), ("key", .string(KEY))]))
        #expect(r.status == 200 && !r.text.contains(KEY) && p.keychain.contains(KEY))
        #expect(r.json?["providers"]?.arrayValue?.first?["key_set"] == .bool(true))
        r = s.post("/api/language-model", .object([("use", .object([("notes", .string("anthropic"))]))]))
        #expect(r.status == 200 && r.json?["features"]?.arrayValue?.first?["choice"] == .string("anthropic"))
        r = s.post("/api/language-model", .object([("provider", .string("anthropic")), ("endpoint", .string("http://127.0.0.1:\(anthropic.port)"))]))
        #expect(r.status == 200)
        r = s.post("/api/language-model/test", .object([("provider", .string("anthropic"))]))
        #expect(r.status == 200 && r.json?["answer"] == .string("Hello there") && r.json?["model"] == .string("claude-opus-5-5"))
        #expect(anthropic.keys == [KEY])  // the key went to the provider, and only there
        anthropic.refusing = true
        r = s.post("/api/language-model/test", .object([("provider", .string("anthropic"))]))
        #expect(r.status == 502 && (r.error ?? "").contains("401") && !r.text.contains(KEY))
        r = s.get("/api/language-model")
        #expect(r.json?["log"]?.arrayValue?.count == 2)  // both tests in the access log, newest first
        #expect(r.json?["log"]?.arrayValue?.first?["ok"] == .bool(false))
        #expect(!r.text.contains(KEY) && !s.log.contains(KEY) && !usage(s).contains(KEY))
        #expect(!((try? String(contentsOf: p.stores.accessLog, encoding: .utf8)) ?? "").contains(KEY))
        #expect(PythonJSON.read(p.stores.settings)?["engines"]?["notes"] == .string("anthropic"))
    }

    @Test func test_config_toml_choices_show_as_the_default() throws {
        let p = try InProcess(notes: "engine = \"claude\"\nmodel = \"opus\"\nlocal_model = \"someone/else\"\n")
        defer { p.stop() }
        let lm = p.server.get("/api/language-model").json
        #expect(lm?["features"]?.arrayValue?.map { $0["choice"]?.stringValue } == ["claude-cli", "claude-cli", "local"])  // the coach: its own
        #expect(lm?["providers"]?.arrayValue?.first { $0["id"] == .string("claude-cli") }?["model"] == .string("opus"))
        #expect(lm?["local"]?["model"] == .string("someone/else"))
        #expect(lm?["local"]?["models"]?.arrayValue?.contains { $0["repo"] == .string("someone/else") } == true)  // shown though not listed
    }

    @Test func test_http_a_bad_key_request_does_not_echo_it() throws {
        let p = try InProcess()
        defer { p.stop() }
        for (provider, key, said) in [("claude-cli", KEY, "Claude Code CLI takes no API key"),
                                      ("anthropic", "two\nlines " + KEY, "that is not an API key"),
                                      ("anthropic", "sk-ant- " + KEY, "an API key has no spaces inside; copy it again without them"),
                                      ("nope", KEY, "no provider 'nope'")] {
            let r = p.server.post("/api/language-model/key", .object([("provider", .string(provider)), ("key", .string(key))]))
            #expect(r.status == 400 && r.error == said && !r.text.contains(KEY))
        }
        #expect(p.keychain.isEmpty && !p.server.log.contains(KEY) && !usage(p.server).contains(KEY))
    }

    @Test func test_provider_settings_are_checked() throws {
        let p = try InProcess()
        defer { p.stop() }
        let s = p.server
        var r = s.post("/api/language-model", parse(#"{"provider": "openai", "endpoint": "https://acme.openai.azure.com/openai/v1", "model": "gpt-x", "context_tokens": 200000}"#))
        #expect(r.status == 200)
        let openai = r.json?["providers"]?.arrayValue?.first { $0["id"] == .string("openai") }
        #expect(openai?["endpoint"] == .string("https://acme.openai.azure.com/openai/v1") && openai?["context_tokens"] == .int(200_000))
        #expect(openai?["problem"] == .string("Add the API key"))
        r = s.post("/api/language-model", parse(#"{"provider": "openai", "endpoint": "http://evil.example.com"}"#))
        #expect(r.status == 400 && r.error == "the endpoint must be an https:// URL (http:// only for a gateway on this Mac or your local network)")
        r = s.post("/api/language-model", parse(#"{"provider": "openai", "endpoint": "http://llm.lan:8080/v1"}"#))
        #expect(r.status == 200)
        r = s.post("/api/language-model", parse(#"{"local_model": "mlx-community/nothing"}"#))
        #expect(r.status == 400 && r.error == "no local model 'mlx-community/nothing'")
        r = s.post("/api/language-model", parse(#"{"local_model": "mlx-community/gemma-4-12B-it-OptiQ-4bit"}"#))
        #expect(r.status == 200 && r.json?["local"]?["model"] == .string("mlx-community/gemma-4-12B-it-OptiQ-4bit"))
        #expect(usage(s).contains(#""id": "provider.openai", "fields": ["context_tokens", "endpoint", "model"]"#))
        #expect(s.post("/api/language-model/test", .object([("provider", .string("soniox"))])).error == "no language model 'soniox'")
        r = s.post("/api/language-model/test", .object([("provider", .string("claude-cli"))]))
        #expect(r.status == 502 && (r.error ?? "").contains("not found on this Mac"))
    }

    @Test func test_http_transcription() throws {
        let p = try InProcess()
        defer { p.stop() }
        let s = p.server
        var r = s.get("/api/transcription")
        #expect(r.status == 200 && r.json?["feature"]?["choice"] == .string("local") && r.json?["month"]?["seconds"] == .double(0))
        #expect(r.json?["providers"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == ["assemblyai", "soniox", "mistral", "openai-transcribe"])
        r = s.post("/api/transcription", .object([("use", .string("soniox"))]))
        #expect(r.status == 400 && r.error == "Soniox: Add the API key")
        r = s.post("/api/transcription/key", .object([("provider", .string("anthropic")), ("key", .string(KEY))]))
        #expect(r.status == 400 && r.error == "no transcription service 'anthropic'")
        r = s.post("/api/transcription/key", .object([("provider", .string("assemblyai")), ("key", .string(ASR_KEY))]))
        #expect(r.status == 200 && !r.text.contains(ASR_KEY) && p.keychain.contains(ASR_KEY))
        r = s.post("/api/transcription", .object([("use", .string("assemblyai"))]))
        #expect(r.status == 200 && r.json?["feature"]?["choice"] == .string("assemblyai"))
        r = s.post("/api/transcription", parse(#"{"provider": "assemblyai", "region": "us", "model": "universal-2"}"#))
        let aai = r.json?["providers"]?.arrayValue?.first
        #expect(r.status == 200 && aai?["region"] == .string("us") && aai?["model"] == .string("universal-2"))
        #expect(s.post("/api/transcription", parse(#"{"provider": "assemblyai", "region": "mars"}"#)).error == "the region must be one of eu, us")
        // The Test button: two seconds of a tone to the service's US servers, the job polled and deleted there.
        let base = "https://api.assemblyai.com"
        p.services.on("POST", "\(base)/v2/upload", 200, #"{"upload_url": "https://cdn.assemblyai.test/upload/abc"}"#)
        p.services.on("POST", "\(base)/v2/transcript", 200, #"{"id": "t1", "status": "queued"}"#)
        p.services.on("GET", "\(base)/v2/transcript/t1", 200,
                      #"{"id": "t1", "status": "completed", "words": [{"text": "Hm.", "start": 100, "end": 400}]}"#)
        p.services.on("DELETE", "\(base)/v2/transcript/t1", 200, "{}")
        r = s.post("/api/transcription/test", .object([("provider", .string("assemblyai"))]))
        #expect(r.status == 200 && r.json?["usd_per_hour"] == .double(0.28) && r.json?["model"] == .string("universal-2"))
        #expect(r.json?["heard"] == .string("Hm.") && r.json?["seconds"]?.doubleValue != nil)
        #expect(p.services.requests.map { "\($0.httpMethod!) \($0.url!.path)" }
            == ["POST /v2/upload", "POST /v2/transcript", "GET /v2/transcript/t1", "DELETE /v2/transcript/t1"])
        #expect(p.services.requests.allSatisfy { $0.value(forHTTPHeaderField: "authorization") == ASR_KEY && $0.url?.host == "api.assemblyai.com" })
        let upload = p.services.requests[0].httpBody ?? Data()
        #expect(upload.prefix(4) == Data("fLaC".utf8))  // FLAC, not WAV
        let logged = AccessLog.recent(nil, stores: p.stores).first
        #expect(logged?["feature"] == .string("test") && logged?["audio_seconds"] == .double(2.0) && logged?["track"] == nil)
        #expect(logged?["meetings"] == .array([]) && logged?["ok"] == .bool(true))
        // A refused key is a 502 that never quotes it; a service that is not set up, or no service, says so.
        p.services.on("POST", "\(base)/v2/upload", 401, #"{"error": "bad key \#(ASR_KEY)"}"#)
        r = s.post("/api/transcription/test", .object([("provider", .string("assemblyai"))]))
        #expect(r.status == 502 && (r.error ?? "").contains("refused the API key") && !r.text.contains(ASR_KEY))
        r = s.post("/api/transcription/test", .object([("provider", .string("soniox"))]))
        #expect(r.status == 502 && r.error == "Soniox: Add the API key")
        r = s.post("/api/transcription/test", .object([("provider", .string("anthropic"))]))
        #expect(r.status == 400 && r.error == "no transcription service 'anthropic'")
        r = s.post("/api/transcription/key", .object([("provider", .string("assemblyai")), ("remove", .bool(true))]))
        #expect(r.status == 200 && !p.keychain.contains(ASR_KEY))
        #expect(!s.log.contains(ASR_KEY) && !usage(s).contains(ASR_KEY))
    }

    @Test func nothingGoesToPython() {
        // Every provider action is answered in this process; the shipped server starts no Python for them.
        let p = try? InProcess()
        defer { p?.stop() }
        for action in ["language-model", "transcription", "registry"] {
            #expect((try? p?.server.app.provider.call(action, body: .object([]), timeout: 5)) != nil, "\(action)")
        }
        #expect(p?.services.requests.isEmpty == true)
    }

    @Test func theSetupAssistantReadsTheRegistryInProcess() throws {
        let p = try InProcess()
        defer { p.stop() }
        let r = p.server.get("/api/setup")
        #expect(r.status == 200)
        let reg = try p.server.app.provider.call("registry", body: .object([]), timeout: 1)
        #expect(reg["providers"]?.arrayValue?.count == ModelChoice.providers.count)
    }

    @Test func theTestButtonKeepsItsBudget() throws {
        // A provider that never answers: the Test stops at its budget (650 s from the route, as Python's helper had),
        // not after the transport's own timeouts and retries.
        let dir = tempFolder("providers-budget")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                                home: dir.appendingPathComponent("home", isDirectory: true))
        let toml = dir.appendingPathComponent("config.toml")
        try "[notes]\nclaude = \"\(dir.appendingPathComponent("no-claude").path)\"\n".write(to: toml, atomically: true, encoding: .utf8)
        let silent = HTTPClient(transport: { _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw URLError(.timedOut)
        })
        let providers = Providers(configURL: toml, stores: stores, keys: FileKeyStore(dir.appendingPathComponent("keychain.json")),
                                  env: ["PATH": ""], http: silent)
        _ = try providers.call("set-key", body: .object([("provider", .string("anthropic")), ("key", .string(KEY))]), timeout: 5)
        _ = try providers.call("set-language-model", body: .object([("provider", .string("anthropic")),
                                                                    ("endpoint", .string("http://127.0.0.1:9"))]), timeout: 5)
        let started = Date()
        var said: String?
        do { _ = try providers.call("test", body: .object([("provider", .string("anthropic"))]), timeout: 1) } catch let e as BadGateway { said = e.text }
        #expect(said == "The test took longer than 1 seconds; it was stopped.")
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aBodyThatIsNoObjectIsABadRequest() throws {
        let p = try InProcess()
        defer { p.stop() }
        let r = p.server.post("/api/language-model", .array([]))
        #expect(r.status == 400 && (r.error ?? "").hasPrefix("bad request"))
    }
}

/// What the provider routes answer for an error (batch 3 deferred: an unexpected failure of a Test button is the
/// service's 502 with why, never the key, not the server's 500).
@Suite struct ProviderErrorAnswerTests {
    struct Unexpected: Error, CustomStringConvertible {
        var description: String { "the FLAC encoder failed for https://api.example.test/v1/x?key=sk-test-0123456789abcdef with secret-given" }
    }

    @Test func anUnexpectedErrorOfATestButtonIsA502WithoutTheKey() {
        let body = JSONValue.object([("provider", .string("assemblyai")), ("key", .string("secret-given"))])
        for action in ["test", "test-transcription"] {
            let e = Providers.answered(Unexpected(), action: action, body: body, timeout: 5)
            let text = (e as? BadGateway)?.description ?? ""
            #expect(e is BadGateway && text.contains("the FLAC encoder failed") && text.contains("https://api.example.test/v1/x?…"))
            #expect(!text.contains("sk-test") && !text.contains("secret-given") && !text.contains("key="))
        }
        // Elsewhere it stays the server's error; the known kinds keep their answers.
        #expect(Providers.answered(Unexpected(), action: "set-key", body: body, timeout: 5) is Unexpected)
        #expect(Providers.answered(BadRequest("no"), action: "test", body: body, timeout: 5) is BadRequest)
        #expect(Providers.answered(SettingRefused("x secret-given"), action: "test", body: body, timeout: 5) is Refused)
    }

    @Test func aWorkerLogLineOfAnUnexpectedErrorHasNoKey() {
        let text = HTTPClient.redactedDescription(Unexpected(), key: "secret-given")
        #expect(text == "the FLAC encoder failed for https://api.example.test/v1/x?… with …")
        let url = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://h.test/v1?key=abc123"])
        #expect(!HTTPClient.redactedDescription(url, key: nil).contains("abc123"))
    }
}
