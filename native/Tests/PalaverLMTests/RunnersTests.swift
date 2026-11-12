// The cloud runners and the Claude Code CLI behind a feature, against stub servers on this Mac and a fake `claude`
// script: the requests, the provider errors as the user reads them, the context check before anything is sent, and the
// access log (never the key).
import Foundation
import Testing
import PalaverCloud
import PalaverCore
import PalaverDomain
@testable import PalaverLM

private func anthropic(_ answer: JSONValue, stop: String = "end_turn") -> StubServer.Answer {
    .json(.object([("content", .array([.object([("type", .string("text")), ("text", .string(PythonJSON.dumps(answer)))])])),
                   ("stop_reason", .string(stop))]))
}

private func openai(_ content: String, finish: String = "stop") -> StubServer.Answer {
    .json(.object([("choices", .array([.object([("message", .object([("content", .string(content))])),
                                                ("finish_reason", .string(finish))])]))]))
}

@Suite(.serialized) struct RunnersTests {
    func anthropicHome(_ server: StubServer, feature: String = "notes") throws -> Home {
        let home = Home()
        try home.keys.write("anthropic.api_key", KEY)
        _ = try home.settings.configure("anthropic", [("endpoint", .string(server.url))])
        try home.settings.choose(feature, .string("anthropic"))
        return home
    }

    @Test func notesWithTheAnthropicAPI() async throws {
        let server = try StubServer { got in
            got.json?["output_config"]?["format"]?["schema"]?["properties"]?["title"] != nil
                ? anthropic(NOTES_ANSWER) : anthropic(ControlFallback.suggest)
        }
        defer { server.stop() }
        let home = try anthropicHome(server)
        let paths = home.meeting()
        #expect(try await run(["notes", paths.folder.path], home.context()) == 0)
        #expect(Notes.load(paths)?["title"] == .string("Angebot für Contoso"))
        let got = try #require(server.requests.first)
        #expect(got.path == "/v1/messages" && got.headers["x-api-key"] == KEY)
        let body = try #require(got.json)
        #expect(body["max_tokens"] == .int(32_000) && body["model"] == .string("claude-opus-5-5"))
        #expect(body["system"]?.stringValue?.hasPrefix(NotesPrompt.LANGUAGE_RULES["de"]! + "\n\n") == true)  // the language first
        let schema = body["output_config"]?["format"]?["schema"]
        #expect(schema?["additionalProperties"] == .bool(false) && schema?["description"] == nil)
        #expect(schema?["properties"]?["sections"]?["items"]?["additionalProperties"] == .bool(false))
        #expect(body["messages"]?.arrayValue?.first?["content"]?.stringValue?.contains("Transcript:\n[00:03] Timo Strauß:") == true)
        let log = AccessLog.recent(stores: home.stores)
        #expect(log.contains { $0["feature"] == .string("notes") && $0["meetings"] == .strings([MEETING]) && $0["ok"] == .bool(true)
                    && $0["provider"] == .string("anthropic") && $0["host"] == .string("127.0.0.1") })
        #expect(!(try String(contentsOf: home.stores.accessLog, encoding: .utf8)).contains(KEY))
        #expect(home.said.contains("Writing notes with Anthropic API…"))
    }

    @Test func providerErrorsReachTheUserAsTheySay() async throws {
        let cases: [(StubServer.Answer, String)] = [
            (anthropic(NOTES_ANSWER, stop: "max_tokens"),
             "Anthropic API: the answer was cut off at 32,000 tokens (thinking included); nothing was saved. Try again, or choose another model in Settings."),
            (anthropic(NOTES_ANSWER, stop: "refusal"), "Anthropic API declined to answer"),
            (.json(.object([("error", .object([("message", .string("bad"))]))]), status: 401),
             "Anthropic API refused the API key (HTTP 401); check or replace it in Settings"),
            (.json(.object([("error", .object([("message", .string("model: not found \(KEY)"))]))]), status: 404),
             "HTTP 404: model: not found …"),
        ]
        for (answer, said) in cases {
            let server = try StubServer { _ in answer }
            defer { server.stop() }
            let home = try anthropicHome(server)
            let paths = home.meeting()
            #expect(try await run(["notes", paths.folder.path], home.context()) == 1)
            #expect(home.said.last == "warning: notes failed: \(said)")
            #expect(home.events(paths).first { $0["event"] == .string("notes_failed") }?["error"] == .string(said))
            let log = AccessLog.recent(stores: home.stores)
            #expect(log.first?["ok"] == .bool(false) && log.first?["error"] == .string(said))
        }
    }

    @Test func aBrokenCloudAnswerIsAskedForOnceMore() async throws {
        var calls = 0
        let server = try StubServer { _ in
            calls += 1
            return calls == 1 ? .json(.object([("content", .array([.object([("type", .string("text")), ("text", .string("{\"title\": 1}"))])])),
                                               ("stop_reason", .string("end_turn"))]))
                : anthropic(NOTES_ANSWER)
        }
        defer { server.stop() }
        let home = try anthropicHome(server)
        let paths = home.meeting()
        let ctx = home.context()
        let engine = try ctx.engine(feature: "notes", kind: "notes", meetings: [paths.folder])
        let notes = try await engine.run("p", schema: NotesPrompt.SCHEMA, parse: NotesAnswer.parse)
        #expect(notes["title"] == .string("Angebot für Contoso") && server.requests.count == 2)
    }

    @Test func whatWouldNotFitIsRefusedBeforeAnythingIsSent() async throws {
        let server = try StubServer { _ in anthropic(NOTES_ANSWER) }
        defer { server.stop() }
        let home = try anthropicHome(server)
        _ = try home.settings.configure("anthropic", [("context_tokens", .int(33_000))])
        let paths = home.meeting()
        #expect(try await run(["notes", paths.folder.path], home.context()) == 1)
        #expect(server.requests.isEmpty && AccessLog.recent(stores: home.stores).isEmpty)
        #expect(home.said.last?.hasPrefix("warning: notes failed: This is about ") == true)
        #expect(home.said.last?.contains("and Anthropic API (claude-opus-5-5) reads at most 33,000 with room for its answer.") == true)
    }

    @Test func anOpenAICompatibleGatewayRetriedWithoutResponseFormat() async throws {
        var calls = 0
        let server = try StubServer { _ in
            calls += 1
            if calls == 1 { return .json(.object([("error", .object([("message", .string("response_format is not supported"))]))]), status: 400) }
            return openai(#"{"questions": [{"question": "Q?", "why": "w"}]}"#)
        }
        defer { server.stop() }
        let home = Home()
        _ = try home.settings.configure("openai", [("endpoint", .string(server.url + "/v1?api-version=1")), ("model", .string("llama"))])
        try home.settings.choose(NextQuestion.FEATURE, .string("openai"))
        let paths = home.meeting()
        var ctx = home.context()
        ctx.readInput = { Data(#"{"lines": [{"speaker": "V", "start": 1, "text": "Hallo"}]}"#.utf8) }
        #expect(try await run(["next-question", paths.folder.path], ctx) == 0)
        #expect(home.said.last == #"{"questions": [{"question": "Q?", "why": "w"}], "engine": "OpenAI-compatible"}"#)
        #expect(server.requests.map(\.path) == ["/v1/chat/completions?api-version=1", "/v1/chat/completions?api-version=1"])
        #expect(server.requests[0].json?["response_format"] != nil && server.requests[1].json?["response_format"] == nil)
        let system = server.requests[1].json?["messages"]?.arrayValue?.first?["content"]?.stringValue
        #expect(system?.contains(#""questions""#) == true)  // the schema in the system text too
        // A cut-off answer is an error.
        calls = 1
        server.answer = { _ in openai("{", finish: "length") }
        #expect(try await run(["next-question", paths.folder.path], ctx) == 1)
        #expect(home.said.last == #"{"error": "OpenAI-compatible: the answer was cut off"}"#)
    }

    @Test func theClaudeCodeCLI() async throws {
        let home = Home()
        let calls = home.dir.appendingPathComponent("claude-calls")
        let script = home.dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" > \(calls.path).args
        pwd > \(calls.path).cwd
        # The notes' prompt is the first call's; the projects sort (following the notes' model) comes after.
        if [ -e \(calls.path).stdin ]; then cat >> \(calls.path).later; else cat > \(calls.path).stdin; fi
        echo '{"is_error": false, "structured_output": \(PythonJSON.dumps(NOTES_ANSWER).replacingOccurrences(of: "'", with: ""))}'
        """.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        home.config.claudePath = script.path
        try home.settings.choose("notes", .string("claude-cli"))
        let paths = home.meeting()
        #expect(try await run(["notes", paths.folder.path], home.context()) == 0)
        #expect(Notes.load(paths)?["title"] == .string("Angebot für Contoso"))
        let args = try String(contentsOf: URL(fileURLWithPath: calls.path + ".args"), encoding: .utf8)
        #expect(args.hasPrefix("-p --model sonnet --tools  --setting-sources  --no-session-persistence --output-format json --json-schema {"))
        #expect(try String(contentsOf: URL(fileURLWithPath: calls.path + ".stdin"), encoding: .utf8).hasPrefix("You write the notes"))
        let cwd = try String(contentsOf: URL(fileURLWithPath: calls.path + ".cwd"), encoding: .utf8)
        #expect(cwd.contains("palaver-claude-") && !FileManager.default.fileExists(atPath: Py.strip(cwd)))  // its own, removed
        #expect(home.said.contains("Writing notes with Claude Code CLI…"))
        // Not found: skipped, never another model.
        home.config.claudePath = home.dir.appendingPathComponent("gone").path
        #expect(try await run(["notes", paths.folder.path, "--force"], home.context()) == 1)
        #expect(home.said.last?.hasPrefix("Skipping notes: Claude Code CLI:") == true)
    }
}
