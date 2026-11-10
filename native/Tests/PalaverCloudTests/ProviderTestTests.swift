// The Settings page's Test button (llm.test) and the requests behind it: Anthropic and an OpenAI-compatible endpoint on
// stub servers on this Mac, the Claude Code CLI as a fake script. Every call lands in the access log, never the key.
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverCloud

private func anthropicOK(_ payload: String = #"{"reply": "Hello there"}"#, stop: String = "end_turn") -> StubServer.Answer {
    .json(.object([("content", .array([.object([("type", .string("thinking")), ("thinking", .string(""))]),
                                       .object([("type", .string("text")), ("text", .string(payload))])])),
                   ("stop_reason", .string(stop))]))
}

private func openaiOK(_ payload: String = #"{"reply": "Hi"}"#, finish: String = "stop") -> StubServer.Answer {
    .json(.object([("choices", .array([.object([("message", .object([("role", .string("assistant")), ("content", .string(payload))])),
                                                ("finish_reason", .string(finish))])]))]))
}

@Suite(.serialized) struct ProviderTestTests {
    @Test func anthropicAnswersAndTheCallIsLoggedWithoutTheKey() async throws {
        let server = try StubServer { _ in anthropicOK() }
        defer { server.stop() }
        let home = Home()
        try home.keys.write("anthropic.api_key", KEY)
        try home.settings.configure("anthropic", [("endpoint", .string("http://127.0.0.1:\(server.port)"))])
        let answer = try await ProviderTest.run("anthropic", settings: home.settings)
        #expect(answer["answer"] == .string("Hello there") && answer["model"] == .string("claude-opus-5-5"))
        #expect(answer["seconds"]?.doubleValue ?? -1 >= 0)
        let got = try #require(server.requests.first)
        #expect(got.path == "/v1/messages" && got.headers["x-api-key"] == KEY && got.headers["anthropic-version"] == CloudLLM.ANTHROPIC_VERSION)
        let body = try #require(got.json)
        #expect(body["model"] == .string("claude-opus-5-5") && body["max_tokens"] == .int(CloudLLM.MAX_OUTPUT_TOKENS))
        #expect(body["messages"]?.arrayValue?.first?["content"] == .string(ProviderTest.PROMPT))
        #expect(body["output_config"]?["format"]?["schema"]?["additionalProperties"] == .bool(false))  // closed, as Anthropic wants
        let log = AccessLog.recent(stores: home.stores)
        #expect(log.count == 1 && log[0]["feature"] == .string("test") && log[0]["ok"] == .bool(true)
                && log[0]["host"] == .string("127.0.0.1") && log[0]["meetings"] == .array([]))
        #expect(!(try String(contentsOf: home.stores.accessLog, encoding: .utf8)).contains(KEY))
    }

    @Test func anOpenAICompatibleGatewayOnThisMacNeedsNoKey() async throws {
        let server = try StubServer { _ in openaiOK() }
        defer { server.stop() }
        let home = Home()
        try home.settings.configure("openai", [("endpoint", .string("http://localhost:\(server.port)/v1")), ("model", .string("llama"))])
        let answer = try await ProviderTest.run("openai", settings: home.settings)
        #expect(answer["answer"] == .string("Hi") && answer["model"] == .string("llama"))
        let got = try #require(server.requests.first)
        #expect(got.path == "/v1/chat/completions" && got.headers["authorization"] == nil && got.headers["api-key"] == nil)
        #expect(got.json?["response_format"]?["type"] == .string("json_schema"))
        #expect(got.json?["messages"]?.arrayValue?.first?["content"]?.stringValue?.contains(#""reply""#) == true)  // the schema too
    }

    @Test func theKeyGoesInOneHeaderChosenByTheHostOrTheSetting() async throws {
        let runner = OpenAIRunner(endpoint: "https://acme.openai.azure.com/openai/v1", model: "m", apiKey: KEY)
        let url = try #require(CloudLLM.chatURL(runner.endpoint))
        #expect(runner.keyHeader(url)! == ("api-key", KEY))
        var bearer = runner
        bearer.auth = "bearer"
        #expect(bearer.keyHeader(url)! == ("authorization", "Bearer \(KEY)"))
        let gateway = OpenAIRunner(endpoint: "https://gw.example.com/v1", model: "m", apiKey: KEY, auth: "api-key")
        #expect(gateway.keyHeader(try #require(CloudLLM.chatURL(gateway.endpoint)))! == ("api-key", KEY))
        #expect(CloudLLM.chatURL("https://acme.openai.azure.com/openai/deployments/gpt/?api-version=2024-10-21")?.absoluteString
                == "https://acme.openai.azure.com/openai/deployments/gpt/chat/completions?api-version=2024-10-21")
        #expect(CloudLLM.anthropicURL("https://gateway.example.com/anthropic/v1")?.absoluteString
                == "https://gateway.example.com/anthropic/v1/messages")
        #expect(CloudLLM.anthropicURL("https://api.anthropic.com/")?.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test func aGatewayThatRejectsResponseFormatIsAskedAgainWithoutIt() async throws {
        var calls = 0
        let server = try StubServer { _ in
            calls += 1
            return calls == 1 ? .json(.object([("error", .object([("message", .string("Unrecognized request argument: response_format"))]))]),
                                      status: 400) : openaiOK()
        }
        defer { server.stop() }
        let home = Home()
        try home.settings.configure("openai", [("endpoint", .string("http://127.0.0.1:\(server.port)/v1")), ("model", .string("m"))])
        _ = try await ProviderTest.run("openai", settings: home.settings)
        #expect(server.requests.count == 2 && server.requests[0].json?["response_format"] != nil
                && server.requests[1].json?["response_format"] == nil)
    }

    @Test func aRefusedKeyFailsAndIsLoggedWithoutIt() async throws {
        let server = try StubServer { _ in .json(.object([("error", .object([("message", .string("invalid x-api-key \(KEY)"))]))]), status: 401) }
        defer { server.stop() }
        let home = Home()
        try home.keys.write("anthropic.api_key", KEY)
        try home.settings.configure("anthropic", [("endpoint", .string("http://127.0.0.1:\(server.port)"))])
        let e = await thrown { try await ProviderTest.run("anthropic", settings: home.settings) } as? CloudError
        #expect(e?.message == "Anthropic API refused the API key (HTTP 401); check or replace it in Settings")
        let log = AccessLog.recent(stores: home.stores)
        #expect(log.first?["ok"] == .bool(false) && log.first?["error"]?.stringValue?.contains("refused the API key") == true)
        #expect(!(try String(contentsOf: home.stores.accessLog, encoding: .utf8)).contains(KEY))
    }

    @Test(arguments: [("max_tokens", "cut off"), ("refusal", "declined")])
    func cutOffOrDeclinedAnswersAreSaidSo(stop: String, said: String) async throws {
        let server = try StubServer { _ in anthropicOK(stop: stop) }
        defer { server.stop() }
        let home = Home()
        try home.keys.write("anthropic.api_key", KEY)
        try home.settings.configure("anthropic", [("endpoint", .string("http://127.0.0.1:\(server.port)"))])
        let e = await thrown { try await ProviderTest.run("anthropic", settings: home.settings) } as? CloudError
        #expect(e?.message.contains(said) == true && server.requests.count == 1)
    }

    @Test func aBrokenAnswerIsAskedOnceMore() async throws {
        let server = try StubServer { _ in anthropicOK("no json here") }
        defer { server.stop() }
        let home = Home()
        try home.keys.write("anthropic.api_key", KEY)
        try home.settings.configure("anthropic", [("endpoint", .string("http://127.0.0.1:\(server.port)"))])
        let e = await thrown { try await ProviderTest.run("anthropic", settings: home.settings) } as? CloudError
        #expect(e?.message.hasPrefix("Anthropic API did not return a valid answer") == true && server.requests.count == 2)
    }

    @Test func theTestNeedsAReadyLanguageModel() async throws {
        let home = Home()
        var e = await thrown { try await ProviderTest.run("anthropic", settings: home.settings) }
        #expect((e as? EngineUnavailable)?.message == "Anthropic API: Add the API key. Change it in Settings → Language model.")
        e = await thrown { try await ProviderTest.run("soniox", settings: home.settings) }
        #expect((e as? SettingRefused)?.text == "no language model 'soniox'")
        #expect(AccessLog.recent(stores: home.stores).isEmpty)  // nothing was sent
    }

    @Test func theClaudeCodeCLIIsAskedWithItsFlags() async throws {
        let home = Home()
        let claude = home.dir.appendingPathComponent("claude")
        let args = home.dir.appendingPathComponent("args"), input = home.dir.appendingPathComponent("stdin")
        try """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(args.path)"
            pwd >> "\(args.path)"
            cat > "\(input.path)"
            echo '{"is_error": false, "structured_output": {"reply": "Hello from Claude"}}'

            """.write(to: claude, atomically: true, encoding: .utf8)
        chmod(claude.path, 0o755)
        home.config.claudePath = claude.path
        home.config.notesModel = "opus"
        let answer = try await ProviderTest.run("claude-cli", settings: home.settings)
        #expect(answer["answer"] == .string("Hello from Claude") && answer["model"] == .string("opus"))
        let argv = try String(contentsOf: args, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(Array(argv.prefix(11)) == ["-p", "--model", "opus", "--tools", "", "--setting-sources", "", "--no-session-persistence",
                                           "--output-format", "json", "--json-schema"])
        #expect(argv.count > 12 && argv[12].contains("palaver-claude-"))  // in an empty folder of its own
        #expect(try String(contentsOf: input, encoding: .utf8) == ProviderTest.PROMPT)
        #expect(AccessLog.recent(stores: home.stores).first?["host"] == .string("claude CLI"))
    }
}
