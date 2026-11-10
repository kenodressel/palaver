// The cloud language models over HTTP and the Claude Code CLI, as much as the Settings page's Test button needs
// (cloud_llm.py's runners, notes.claude_runner, llm.test): a prompt and a JSON schema in, the answer's JSON object out.
// The notes, projects and next-question features build on these in palaver-lm (phase 4, batch 4).
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

public enum CloudLLM {
    public static let ANTHROPIC_VERSION = "2026-10-21"
    /// One request: adaptive thinking plus the notes of a long meeting.
    public static let TIMEOUT_SECONDS = 600.0
    /// Room for the model's thinking and long German notes; without streaming, 32k keeps one answer inside the timeout.
    public static let MAX_OUTPUT_TOKENS = 32_000

    /// `endpoint` with its path ending in `/v1/messages` (a path ending in `/v1` gains `/messages`).
    public static func anthropicURL(_ endpoint: String) -> URL? {
        withPath(endpoint) { path in
            path.hasSuffix("/messages") ? path : path + (path.hasSuffix("/v1") ? "/messages" : "/v1/messages")
        }
    }

    /// `…/chat/completions` under the endpoint, keeping its query (Azure's `?api-version=`).
    public static func chatURL(_ endpoint: String) -> URL? {
        withPath(endpoint) { $0.hasSuffix("/chat/completions") ? $0 : $0 + "/chat/completions" }
    }

    private static func withPath(_ endpoint: String, _ change: (String) -> String) -> URL? {
        guard var c = URLComponents(string: Py.strip(endpoint)) else { return nil }
        var path = c.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        c.percentEncodedPath = change(path)
        return c.url
    }

    /// `schema` with every object closed (`additionalProperties: false`), as Anthropic's structured outputs want it.
    public static func closed(_ schema: JSONValue) -> JSONValue {
        switch schema {
        case .array(let items): return .array(items.map(closed))
        case .object(let fields):
            var out = PyDict(fields.map { ($0.0, closed($0.1)) })
            if out["type"] == .string("object") { out["additionalProperties"] = .bool(false) }
            return out.json
        default: return schema
        }
    }

    /// The system prompt (the schema's description — the notes' language — said first) and the schema without it.
    public static func system(_ schema: JSONValue, withSchema: Bool) -> (String, JSONValue) {
        var fields = PyDict<JSONValue>(schema)
        let description = fields?.removeValue(forKey: "description")
        let plain = fields?.json ?? schema
        var system = "Answer with a single JSON object that follows the given JSON schema, and nothing else."
        if withSchema {
            system = "Answer with a single JSON object that follows this JSON schema, and nothing else:\n" + PythonJSON.dumps(plain)
        }
        if let description, description.truthy { return ("\(Py.str(description))\n\n\(system)", plain) }
        return (system, plain)
    }

    public struct NoJSON: Error, CustomStringConvertible {
        public let description: String
    }

    /// The JSON object in `text`: from its first `{` to its last `}`.
    public static func jsonObject(_ text: String) throws -> JSONValue {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else {
            throw NoJSON(description: "no JSON object in the answer")
        }
        guard let out = try? PythonJSON.parse(Data(text[start...end].utf8)) else {
            throw NoJSON(description: "the answer is not valid JSON")
        }
        guard case .object = out else { throw NoJSON(description: "the answer is not a JSON object") }
        return out
    }

    /// Parse the answer; ask once more when it doesn't parse.
    static func parsed(name: String, parse: (String) throws -> JSONValue, ask: () async throws -> String) async throws -> JSONValue {
        var problem: Error?
        for _ in 0..<2 {
            let text = try await ask()
            do { return try parse(text) } catch { problem = error }
        }
        throw CloudError("\(name) did not return a valid answer: \(HTTPClient.redact(String(describing: problem!), key: nil))")
    }

    static func post(_ url: URL, headers: [(String, String)], body: JSONValue, timeout: Double) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = "POST"
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = Data(PythonJSON.dumps(body).utf8)
        return r
    }
}

/// The Anthropic Messages API with structured output (`output_config.format`).
public struct AnthropicRunner {
    public let endpoint: String
    public let model: String
    let apiKey: String?
    public var name = "Anthropic API"
    public var http = HTTPClient()
    public var timeout = CloudLLM.TIMEOUT_SECONDS
    public var maxTokens = CloudLLM.MAX_OUTPUT_TOKENS

    public init(endpoint: String, model: String, apiKey: String?) {
        self.endpoint = endpoint; self.model = model; self.apiKey = apiKey
    }

    public func run(_ prompt: String, schema: JSONValue, parse: (String) throws -> JSONValue = CloudLLM.jsonObject) async throws -> JSONValue {
        guard let url = CloudLLM.anthropicURL(endpoint) else { throw CloudError("\(name): the endpoint is not a URL") }
        let (system, plain) = CloudLLM.system(schema, withSchema: false)
        let body = JSONValue.object([
            ("model", .string(model)), ("max_tokens", .int(maxTokens)), ("system", .string(system)),
            ("messages", .array([.object([("role", .string("user")), ("content", .string(prompt))])])),
            ("output_config", .object([("format", .object([("type", .string("json_schema")), ("schema", CloudLLM.closed(plain))]))])),
        ])
        let request = CloudLLM.post(url, headers: [("content-type", "application/json"), ("x-api-key", apiKey ?? ""),
                                                   ("anthropic-version", CloudLLM.ANTHROPIC_VERSION)],
                                    body: body, timeout: timeout)
        return try await CloudLLM.parsed(name: name, parse: parse) {
            let data = try await http.sendJSON(request, name: name, key: apiKey)
            switch data["stop_reason"]?.stringValue {
            case "max_tokens":
                throw CloudError("\(name): the answer was cut off at \(ContextCheck.grouped(maxTokens)) tokens (thinking "
                                 + "included); nothing was saved. Try again, or choose another model in Settings.")
            case "refusal": throw CloudError("\(name) declined to answer")
            default: break
            }
            return (data["content"]?.arrayValue ?? []).filter { $0["type"]?.stringValue == "text" }
                .compactMap { $0["text"]?.stringValue }.joined()
        }
    }
}

/// Chat Completions on an OpenAI-compatible endpoint (OpenAI, Azure OpenAI, a gateway). The schema goes in the system
/// prompt too, for gateways that ignore `response_format`; one that rejects it is asked again without it.
public struct OpenAIRunner {
    public let endpoint: String
    public let model: String
    let apiKey: String?
    /// The key in an `api-key` header (Azure), as `Authorization: Bearer`, or "auto" by the host.
    public var auth = "auto"
    public var name = "OpenAI-compatible endpoint"
    public var http = HTTPClient()
    public var timeout = CloudLLM.TIMEOUT_SECONDS

    public init(endpoint: String, model: String, apiKey: String?, auth: String = "auto") {
        self.endpoint = endpoint; self.model = model; self.apiKey = apiKey; self.auth = auth
    }

    /// The header the key goes in, and its value; nil without a key.
    func keyHeader(_ url: URL) -> (String, String)? {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        let asAPIKey = auth == "api-key" || (auth == "auto" && ProviderSettings.isAzure(url.absoluteString))
        return asAPIKey ? ("api-key", apiKey) : ("authorization", "Bearer \(apiKey)")
    }

    /// A 400 saying the endpoint can't do `response_format` / JSON schema.
    static func structuredUnsupported(_ message: String) -> Bool {
        let m = Py.casefold(message)
        if m.contains("response_format") || m.contains("json_schema") { return true }
        return (m.contains("structured") || m.contains("schema"))
            && ["not supported", "unsupported", "does not support", "not support"].contains { m.contains($0) }
    }

    public func run(_ prompt: String, schema: JSONValue, parse: (String) throws -> JSONValue = CloudLLM.jsonObject) async throws -> JSONValue {
        guard ModelChoice.AUTH_HEADERS.contains(auth) else { throw CloudError("\(name): the key header setting is not one") }
        guard let url = CloudLLM.chatURL(endpoint) else { throw CloudError("\(name): the endpoint is not a URL") }
        let headers = [("content-type", "application/json")] + (keyHeader(url).map { [$0] } ?? [])
        let (system, plain) = CloudLLM.system(schema, withSchema: true)
        let messages = JSONValue.array([.object([("role", .string("system")), ("content", .string(system))]),
                                        .object([("role", .string("user")), ("content", .string(prompt))])])
        let format = JSONValue.object([("type", .string("json_schema")),
                                       ("json_schema", .object([("name", .string("answer")), ("schema", plain), ("strict", .bool(false))]))])
        var withFormat = true
        func ask() async throws -> String {
            var body: [(String, JSONValue)] = [("model", .string(model)), ("messages", messages)]
            if withFormat { body.append(("response_format", format)) }
            let data: JSONValue
            do {
                data = try await http.sendJSON(CloudLLM.post(url, headers: headers, body: .object(body), timeout: timeout),
                                               name: name, key: apiKey)
            } catch let e as CloudError where e.status == 400 && withFormat && Self.structuredUnsupported(e.providerMessage ?? "") {
                withFormat = false
                return try await ask()
            }
            let choice = data["choices"]?.arrayValue?.first ?? .object([])
            switch choice["finish_reason"]?.stringValue {
            case "length": throw CloudError("\(name): the answer was cut off")
            case "content_filter": throw CloudError("\(name) declined to answer (content filter)")
            default: break
            }
            return choice["message"]?["content"].map { $0.isNull ? "" : Py.str($0) } ?? ""
        }
        return try await CloudLLM.parsed(name: name, parse: parse, ask: ask)
    }
}

/// Claude through `claude -p`: no tools, no settings or CLAUDE.md from the user's projects, structured output validated
/// against the schema, in an empty folder of its own.
public struct ClaudeCLIRunner {
    public let claude: String
    public let model: String
    public var timeout = 600.0

    public init(claude: String, model: String) { self.claude = claude; self.model = model }

    public func run(_ prompt: String, schema: JSONValue) throws -> JSONValue {
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        let argv = [claude, "-p", "--model", model, "--tools", "", "--setting-sources", "", "--no-session-persistence",
                    "--output-format", "json", "--json-schema", PythonJSON.dumps(schema)]
        // In this process's group (not a session of its own): the window's Cancel, the daemon's killpg and the memory
        // watchdog stop it with palaver-lm; a SIGTERM to palaver-lm alone is passed on (LiveHelpers).
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1], errors: [Int32] = [-1, -1]
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&errors) == 0 else {
            for fd in input + output + errors where fd >= 0 { close(fd) }
            throw CloudError("cannot start the Claude Code CLI: \(String(cString: strerror(errno)))")
        }
        let child: PalaverCore.Process
        do {
            child = try spawnChild(argv, env: ProcessInfo.processInfo.environment, stdin: input[0], output: output[1],
                                   errors: errors[1], newSession: false, cwd: cwd.path)
        } catch {
            for fd in input + output + errors { close(fd) }
            throw CloudError("cannot start the Claude Code CLI: \(error)")
        }
        close(input[0]); close(output[1]); close(errors[1])
        LiveHelpers.add(child)
        defer { LiveHelpers.remove(child) }
        final class Bytes: @unchecked Sendable { var out = Data(), err = Data() }
        let bytes = Bytes()
        let readers = DispatchGroup()
        let outFD = output[0], errFD = errors[0]
        DispatchQueue.global().async(group: readers) {
            bytes.out = FileHandle(fileDescriptor: outFD, closeOnDealloc: true).readDataToEndOfFile()
        }
        DispatchQueue.global().async(group: readers) {
            bytes.err = FileHandle(fileDescriptor: errFD, closeOnDealloc: true).readDataToEndOfFile()
        }
        // The prompt goes in on a thread of its own, so the time limit counts from the start: a CLI that never reads a
        // prompt larger than the pipe holds would otherwise block this run (and the model lock) for good.
        final class Unread: @unchecked Sendable { var value = false }
        let unread = Unread()
        let inFD = input[1], prompt = Data(prompt.utf8)
        DispatchQueue.global().async(group: readers) {
            unread.value = Self.write(prompt, to: inFD)  // a CLI that quit first: EPIPE, never SIGPIPE
            close(inFD)
        }
        guard let status = child.waitUntilExit(timeout: timeout) else {
            child.terminate()
            if child.waitUntilExit(timeout: 5) == nil { child.kill(); child.waitUntilExit() }
            readers.wait()  // its end of the pipes is closed now: the writer gets EPIPE, the readers EOF
            throw CloudError("Claude Code CLI gave no answer within \(Int(timeout)) seconds")
        }
        readers.wait()
        let stdout = String(decoding: bytes.out, as: UTF8.self), stderr = String(decoding: bytes.err, as: UTF8.self)
        guard let out = try? PythonJSON.parse(bytes.out), case .object = out else {
            let said = String(Py.strip(stderr.isEmpty ? stdout : stderr).prefix(500))
            let how = child.terminationSignal.map { "was ended by signal \($0)" } ?? "exited \(status)"
            if unread.value {
                throw CloudError("the Claude Code CLI \(how) before it read the prompt" + (said.isEmpty ? "" : ": \(said)"))
            }
            throw CloudError(said.isEmpty ? "claude \(how)" : said)
        }
        guard out["is_error"]?.truthy != true, let structured = out["structured_output"], case .object = structured else {
            let said = out["result"].flatMap { $0.truthy ? Py.str($0) : nil } ?? "no structured output"
            throw CloudError(String(said.prefix(500)))
        }
        return structured
    }

    /// Writes all of `data` to `fd`; true when the reader went away before it was all read. The pipe never raises
    /// SIGPIPE (F_SETNOSIGPIPE), whatever this process does with the signal.
    static func write(_ data: Data, to fd: Int32) -> Bool {
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        return data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return false }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    return true
                }
                p += n
                left -= n
            }
            return false
        }
    }
}

/// The Settings page's Test button (llm.test): a tiny prompt with no meeting content to a language-model provider, its
/// answer and how long it took. The call is in the access log like every other.
public enum ProviderTest {
    public static let PROMPT = #"Say hello in at most five words. Answer as {"reply": "..."}."#
    public static let SCHEMA = JSONValue.object([
        ("type", .string("object")), ("properties", .object([("reply", .object([("type", .string("string"))]))])),
        ("required", .array([.string("reply")])),
    ])

    /// `{answer, seconds, model}`; `SettingRefused` for what is no language model, `EngineUnavailable` for one not set
    /// up, `CloudError` / `ContextTooLong` for a call that failed (every message safe to show).
    public static func run(_ pid: String, settings: ProviderSettings, http: HTTPClient = HTTPClient()) async throws -> JSONValue {
        guard ProviderRegistry.languageModels().contains(where: { Py.same($0, pid) }) else {
            throw SettingRefused("no language model \(Py.repr(.string(pid)))")
        }
        let engine = EngineChoice.provider(pid, settings: settings)
        if case .unavailable(let why) = engine { throw EngineUnavailable(why) }
        let p = ModelChoice.provider(pid)!
        let s = try settings.settingsOf(p.id, defaults: settings.defaults(p.id))
        let model = s["model"].map { Py.str($0) } ?? p.model
        let endpoint = s["endpoint"]?.stringValue ?? ""
        let schemaText = PythonJSON.dumps(SCHEMA)
        let chars = PROMPT.unicodeScalars.count + schemaText.unicodeScalars.count
        let started = Date()
        try ContextCheck.fits(chars: chars, engine: engine, settings: settings)  // refused before anything is sent
        var key: String?
        let host: String
        let ask: () async throws -> JSONValue
        switch engine {
        case .claudeCLI:
            guard let claude = settings.claude() else {
                throw EngineUnavailable("\(p.label): Claude Code CLI (`claude`) not found on this Mac. \(EngineChoice.SETTINGS_HINT)")
            }
            host = "claude CLI"
            ask = { try ClaudeCLIRunner(claude: claude, model: model).run(PROMPT, schema: SCHEMA) }
        default:
            key = settings.apiKey(p.id)
            host = ModelChoice.hostname(endpoint) ?? endpoint
            let apiKey = key
            if p.id == "anthropic" {
                var runner = AnthropicRunner(endpoint: endpoint, model: model, apiKey: apiKey)
                runner.name = p.label
                runner.http = http
                ask = { try await runner.run(PROMPT, schema: SCHEMA) }
            } else {
                var runner = OpenAIRunner(endpoint: endpoint, model: model, apiKey: apiKey, auth: s["auth"]?.stringValue ?? "auto")
                runner.name = p.label
                runner.http = http
                ask = { try await runner.run(PROMPT, schema: SCHEMA) }
            }
        }
        var entry = AccessLog.Entry(provider: p.id, host: host, model: model, feature: "test", meetings: [], chars: chars,
                                    ok: true, seconds: 0)
        let out: JSONValue
        do {
            out = try await ask()
        } catch {
            entry.ok = false
            entry.error = HTTPClient.redact(error is CloudError ? String(describing: error) : String(describing: type(of: error)), key: key)
            entry.seconds = Date().timeIntervalSince(started)
            try? AccessLog.record(entry, stores: settings.stores)  // a log that can't be written never costs the answer
            throw error
        }
        entry.seconds = Date().timeIntervalSince(started)
        try? AccessLog.record(entry, stores: settings.stores)
        let reply = out["reply"]?.stringValue ?? PythonJSON.dumps(out, ensureAscii: false)
        return .object([("answer", .string(String(String.UnicodeScalarView(reply.unicodeScalars.prefix(200))))),
                        ("seconds", .double(AccessLog.round1(Date().timeIntervalSince(started)))), ("model", .string(model))])
    }
}
