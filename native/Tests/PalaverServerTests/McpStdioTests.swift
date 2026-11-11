// `palaver mcp` as Claude starts it: the built `palaver-cli` over stdio (initialize, the tool list, each of the seven
// tools on a temporary recordings folder), its heartbeat while it runs, and how it ends (stdin closed, SIGTERM). And
// the one-release `bin/python` shim that forwards Claude's old entries to it. Temporary folders as home and config:
// never the real ones.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

/// native/.build/debug/palaver-cli (built with the tests).
private let cliBinary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/debug/palaver-cli").path
/// native/Bundle/bin/python: the shim Palaver.app carries for one release.
private let shim = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Bundle/bin/python").path

private let MEETING = "2026-10-27T16-03-07"

/// A `palaver mcp` process with its own home, config and recordings (one meeting, in project "Hiring").
private final class McpProcess {
    let dir = tempFolder("mcp-stdio")
    let stores: StorePaths
    let process: PalaverCore.Process
    private(set) var input: Int32
    let output: Int32
    private var buffer = Data()

    init(args: [String]? = nil, more: [String: String] = [:]) throws {
        let meetings = dir.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                            home: dir.appendingPathComponent("home", isDirectory: true))
        try pageMeeting(meetings, MEETING)
        let app = ServerApp(outputDir: meetings, userName: "Timo", stores: stores, probe: FakeProbe())
        _ = try PeopleAPI.nameSpeaker(app, id: MEETING, label: "SPEAKER_00", name: "Rico")
        try ProjectsAPI.setMeetingProject(app, id: MEETING, name: "Hiring")
        let config = dir.appendingPathComponent("config.toml")
        try Data("[user]\nname = \"Timo\"\n[recording]\noutput_dir = \"\(meetings.path)\"\n[calendar]\nenabled = false\n".utf8).write(to: config)
        let env = ["XDG_CONFIG_HOME": dir.appendingPathComponent("config").path, "PALAVER_HOME": stores.home.path,
                   "HOME": stores.home.path, "PATH": "/usr/bin:/bin"].merging(more) { $1 }
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0]
        precondition(pipe(&inPipe) == 0 && pipe(&outPipe) == 0)
        let errors = open(dir.appendingPathComponent("stderr.txt").path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        defer { close(errors) }
        process = try spawnChild([cliBinary] + (args ?? ["--config", config.path, "mcp"]), env: env, stdin: inPipe[0],
                                 output: outPipe[1], errors: errors)
        close(inPipe[0])
        close(outPipe[1])
        input = inPipe[1]
        output = outPipe[0]
    }

    deinit {
        closeInput()
        if process.exitCode == nil { process.kill() }
        close(output)
        try? FileManager.default.removeItem(at: dir)
    }

    /// What it wrote to stderr.
    var errors: String { (try? String(contentsOf: dir.appendingPathComponent("stderr.txt"), encoding: .utf8)) ?? "" }

    var heartbeat: URL { stores.mcpDir.appendingPathComponent("\(process.pid).json") }

    func send(_ message: JSONValue) {
        let bytes = Array((PythonJSON.dumps(message, ensureAscii: false) + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(input, $0.baseAddress, $0.count) }
    }

    /// The next line it answered (10 s at most).
    func receive() throws -> JSONValue {
        let deadline = Date().addingTimeInterval(10)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                return try PythonJSON.parse(line)
            }
            var fds = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
            let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard left > 0, poll(&fds, 1, left) > 0 else { throw McpToolError("no answer from `palaver mcp`") }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(output, &chunk, chunk.count)
            guard n > 0 else { throw McpToolError("palaver mcp closed its output") }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    func request(_ id: Int, _ method: String, _ params: JSONValue = .object([])) throws -> JSONValue {
        send(.object([("jsonrpc", .string("2.0")), ("id", .int(id)), ("method", .string(method)), ("params", params)]))
        let answer = try receive()
        #expect(answer["id"] == .int(id))
        return answer["result"] ?? answer
    }

    func closeInput() {
        guard input >= 0 else { return }
        close(input)
        input = -1
    }

    /// Its exit status once it ended (5 s at most), nil while it runs.
    func exitStatus(within seconds: Double = 5) -> Int32? { process.waitUntilExit(timeout: seconds) }
}

@Suite(.serialized) struct McpStdioTests {
    @Test func theBuiltServerAnswersClaudeOverStdioAndEndsWhenStdinCloses() throws {
        let p = try McpProcess()
        let hello = try p.request(1, "initialize", .object([
            ("protocolVersion", .string("2025-06-18")), ("capabilities", .object([])),
            ("clientInfo", .object([("name", .string("claude-code")), ("version", .string("2.1.3"))]))]))
        #expect(hello["serverInfo"]?["name"] == .string("meetings") && hello["instructions"]?.truthy == true)
        p.send(.object([("jsonrpc", .string("2.0")), ("method", .string("notifications/initialized"))]))
        let tools = try p.request(2, "tools/list")["tools"]?.arrayValue ?? []
        #expect(tools.count == 7)
        #expect(until(5) { FileManager.default.fileExists(atPath: p.heartbeat.path) })
        #expect(McpLog.clients(stores: p.stores).first?["client"]?["name"] == .string("claude-code"))

        func call(_ id: Int, _ name: String, _ args: [(String, JSONValue)] = []) throws -> JSONValue {
            let r = try p.request(id, "tools/call", .object([("name", .string(name)), ("arguments", .object(args))]))
            #expect(r["isError"] == .bool(false), "\(name): \(r)")
            return r["structuredContent"] ?? .null
        }
        #expect(try call(3, "list_meetings")["result"]?.arrayValue?.first?["id"] == .string(MEETING))
        let search = try call(4, "search_meetings", [("query", .string("salary")), ("person", .string("Rico"))])
        #expect(search["understood"] == .strings(["Rico"]) && search["meetings"]?.arrayValue?.count == 1, "\(search)")
        let meeting = try call(5, "get_meeting", [("meeting_id", .string(MEETING)), ("from_minute", .int(0)), ("to_minute", .double(0.01))])
        #expect(meeting["transcript"] == .strings(["[0:00] Timo: Hi Rico welcome."]) && meeting["notes"]?["summary"] == .string("Rico ran the debrief."))
        #expect(try call(6, "list_projects")["result"]?.arrayValue?.first?["name"] == .string("Hiring"))
        #expect(try call(7, "get_project", [("project", .string("hiring"))])["next_steps"]?.arrayValue?.first?["task"] == .string("Send the offer"))
        #expect(try call(8, "list_people")["result"]?.arrayValue?.first?["name"] == .string("Rico"))
        #expect(try call(9, "open_next_steps", [("owner", .string("speaker 2"))])["result"]?.arrayValue?.count == 1)

        let log = try McpLog.read(stores: p.stores)
        #expect(log.map { $0["tool"]?.stringValue ?? "" } == ["open_next_steps", "list_people", "get_project", "list_projects",
                                                               "get_meeting", "search_meetings", "list_meetings"])
        #expect(log.allSatisfy { $0["pid"] == .int(Int(p.process.pid)) && $0["client"]?["version"] == .string("2.1.3") })
        #expect(McpLog.clients(stores: p.stores).first?["calls"] == .int(7))

        p.closeInput()  // Claude quits
        #expect(p.exitStatus() == 0)
        #expect(!FileManager.default.fileExists(atPath: p.heartbeat.path))
    }

    @Test func aStrayPrintNeverReachesTheProtocolStream() throws {
        // A library that prints to stdout while the server runs: the line goes to stderr, the answers stay JSON-RPC.
        let p = try McpProcess(more: [McpMain.TEST_STRAY_PRINT: "a stray line from some library"])
        let hello = try p.request(1, "initialize", .object([("protocolVersion", .string("2025-06-18"))]))
        #expect(hello["serverInfo"]?["name"] == .string("meetings"))
        #expect(try p.request(2, "ping") == .object([]))
        p.closeInput()
        #expect(p.exitStatus() == 0)
        #expect(p.errors.contains("a stray line from some library"))  // where it went instead
    }

    @Test func sigtermEndsItAndTakesTheHeartbeatAlong() throws {
        let p = try McpProcess()
        _ = try p.request(1, "ping")
        #expect(until(5) { FileManager.default.fileExists(atPath: p.heartbeat.path) })
        kill(p.process.pid, SIGTERM)
        #expect(p.exitStatus() == 128 + SIGTERM)
        #expect(!FileManager.default.fileExists(atPath: p.heartbeat.path))
    }

    @Test func aCommandOfEarlierVersionsServesNothingAndExits2() throws {
        let p = try McpProcess(args: ["record"])  // what replaces it is said on stderr (CLITests)
        #expect(p.exitStatus() == 2)
        #expect(p.errors.hasPrefix("palaver record is gone"))
    }

    // MARK: - the bin/python shim (Keno's answer 2: one release)

    /// The shim beside a fake `palaver` that prints what it was started with.
    private func shimFolder() throws -> URL {
        let dir = tempFolder("mcp-shim").appendingPathComponent("Palaver.app/Contents/Resources/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: shim, toPath: dir.appendingPathComponent("python").path)
        let fake = dir.appendingPathComponent("palaver")
        try Data("#!/bin/sh\nfor a in \"$@\"; do printf '[%s]' \"$a\"; done\necho\n".utf8).write(to: fake)
        chmod(fake.path, 0o755)
        return dir
    }

    private func run(_ argv: [String]) throws -> (status: Int32, out: String, err: String) {
        let ran = try McpSetup.runCommand(argv, env: ["PATH": "/usr/bin:/bin"], timeout: 10)
        return (ran.status, ran.out, ran.err)
    }

    @Test func theShimStartsTheSwiftServerForAnOldClaudeEntry() throws {
        let dir = try shimFolder()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let python = dir.appendingPathComponent("python").path
        #expect(try run([python, "-m", "palaver", "mcp"]).out == "[mcp]\n")
        #expect(try run([python, "-m", "palaver", "--config", "/Users/x/my config.toml", "mcp"]).out == "[--config][/Users/x/my config.toml][mcp]\n")
        #expect(try run([python, "-m", "palaver", "--no-notify", "--config=/c.toml", "mcp"]).out == "[--no-notify][--config=/c.toml][mcp]\n")
        // Through a link (Claude may name the bundle through one): still the palaver beside the real file.
        let link = dir.deletingLastPathComponent().appendingPathComponent("python-link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: python)
        #expect(try run([link, "-m", "palaver", "mcp"]).out == "[mcp]\n")
    }

    @Test func theShimRefusesEverythingElseClearly() throws {
        let dir = try shimFolder()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let python = dir.appendingPathComponent("python").path
        for argv in [[python], [python, "-c", "print(1)"], [python, "-m", "palaver", "list"], [python, "-m", "palaver", "mcp", "--install"],
                     [python, "-m", "palaver", "--config"], [python, "-m", "other", "mcp"], [python, "-I", "-m", "palaver", "mcp"]] {
            let r = try run(argv)
            #expect(r.status == 2 && r.out.isEmpty, "\(argv)")
            #expect(r.err.contains("Palaver no longer includes Python") && r.err.contains("/bin/palaver instead"), "\(argv)")
        }
    }
}
