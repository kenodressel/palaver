// The Claude Code CLI as a child of the program that asks it: in that program's process group (a killpg of palaver-lm's
// group, the window's Cancel and the memory watchdog end it too), passed a SIGTERM that reaches only its parent
// (LiveHelpers), and a CLI that quits without reading its prompt is an error with what it said, never SIGPIPE.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain
@testable import PalaverCloud
import Testing

let TINY_SCHEMA = JSONValue.object([("type", .string("object"))])

func fakeClaude(_ dir: URL, _ body: String) -> String {
    let script = dir.appendingPathComponent("claude")
    try! ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
    chmod(script.path, 0o755)
    return script.path
}

func waitFor(_ file: URL, seconds: Double = 10) -> String? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let text = try? String(contentsOf: file, encoding: .utf8), text.hasSuffix("\n") { return text }
        usleep(20_000)
    }
    return nil
}

@Suite(.serialized) struct ClaudeCLIProcessTests {
    @Test func theCLIRunsInTheAskersProcessGroupAndEndsWithIt() throws {
        let dir = tempFolder("claude-group")
        let seen = dir.appendingPathComponent("seen")
        // Its pid and process group, then it waits (as a long answer would) until it is ended.
        let claude = fakeClaude(dir, "cat > /dev/null\necho \"$$ $(ps -o pgid= -p $$ | tr -d ' ')\" > \(seen.path)\nexec sleep 60\n")
        let started = Date()
        // The runner blocks its caller: on a thread of its own (as palaver-lm's), not a Task, which in the busy parallel
        // test run may wait for a cooperative thread longer than this test waits for the CLI.
        final class Outcome: @unchecked Sendable { var error: Error? }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            do { _ = try ClaudeCLIRunner(claude: claude, model: "sonnet").run("hello", schema: TINY_SCHEMA) }
            catch { outcome.error = error }
            done.signal()
        }
        let line = try #require(waitFor(seen))
        let parts = line.split(separator: " ").compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        #expect(parts.count == 2)
        let pid = parts[0]
        #expect(parts[1] == getpgrp())  // not a session or group of its own
        #expect(LiveHelpers.pids.contains(pid))
        // Ended from outside (palaver-lm's group killed: tests/PalaverLMTests/LMProcessTests do that to the real program;
        // here only this CLI, since other tests' helpers run in this process too).
        kill(pid, SIGTERM)
        #expect(done.wait(timeout: .now() + 30) == .success)
        #expect(outcome.error != nil && Date().timeIntervalSince(started) < 30)
        #expect(kill(pid, 0) != 0)  // gone (and reaped)
        #expect(!LiveHelpers.pids.contains(pid))
    }

    @Test func aCLIThatQuitsWithoutReadingThePromptIsAnErrorWithWhatItSaid() throws {
        let dir = tempFolder("claude-quits")
        let claude = fakeClaude(dir, "echo 'Invalid API key · Please run /login' >&2\nexit 1\n")
        let prompt = String(repeating: "Contoso und Northwind sprechen über das Angebot. ", count: 4000)  // ~200 KB
        #expect(prompt.utf8.count > 64 * 1024)
        do {
            _ = try ClaudeCLIRunner(claude: claude, model: "sonnet").run(prompt, schema: TINY_SCHEMA)
            Issue.record("no error")
        } catch let error as CloudError {
            // This test process does not ignore SIGPIPE: getting here at all shows the write never raised it.
            #expect(error.description.contains("Invalid API key · Please run /login"))
            #expect(error.description.contains("exited 1"))
        }
    }

    @Test func aCLIThatNeverReadsALongPromptRunsIntoTheTimeLimit() throws {
        let dir = tempFolder("claude-stalls")
        let seen = dir.appendingPathComponent("seen")
        let claude = fakeClaude(dir, "echo $$ > \(seen.path)\nexec sleep 60\n")  // never reads stdin, never exits
        let prompt = String(repeating: "Northwind und Contoso besprechen den Zeitplan. ", count: 4000)  // ~190 KB
        var runner = ClaudeCLIRunner(claude: claude, model: "sonnet")
        runner.timeout = 1
        let started = Date()
        do {
            _ = try runner.run(prompt, schema: TINY_SCHEMA)
            Issue.record("no error")
        } catch let error as CloudError {
            #expect(error.description == "Claude Code CLI gave no answer within 1 seconds")
        }
        #expect(Date().timeIntervalSince(started) < 10)
        // On a busy Mac the second may run out before the shell got to its first line: then nothing is left to end.
        // One that started (now or still about to) must be ended and reaped.
        if let pid = waitFor(seen, seconds: 2).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            #expect(kill(pid, 0) != 0)
        }
    }

    @Test func theCLIStartsInAnEmptyFolderOfItsOwnAndAnswers() throws {
        let dir = tempFolder("claude-answers")
        let cwd = dir.appendingPathComponent("cwd")
        let claude = fakeClaude(dir, "cat > /dev/null\npwd > \(cwd.path)\necho '{\"is_error\": false, \"structured_output\": {\"reply\": \"Hallo\"}}'\n")
        let out = try ClaudeCLIRunner(claude: claude, model: "sonnet").run("hello", schema: TINY_SCHEMA)
        #expect(out["reply"] == .string("Hallo"))
        let folder = try String(contentsOf: cwd, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(folder.contains("palaver-claude-") && !FileManager.default.fileExists(atPath: folder))
    }
}
