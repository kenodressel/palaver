// Claude access (#45): the MCP access log, the heartbeat files of running `palaver mcp` processes, Claude's config
// files as read for the setup, and the window's routes (`GET /api/mcp`, `POST /api/mcp/clear|restore|install`). Ports
// the tests of tests/test_mcp_access.py that pin what McpLog and the routes do; here the log and the heartbeats are
// written as the MCP server writes them (McpServerTests runs the Swift one). Every file is under the test's own home: never the
// real Application Support or Claude's real config.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"

private func parse(_ s: String) -> JSONValue { try! PythonJSON.parse(Data(s.utf8)) }
private func dumps(_ v: JSONValue?) -> String { v.map { PythonJSON.dumps($0, ensureAscii: false) } ?? "nil" }

private func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func setMtime(_ url: URL, _ seconds: Double) {
    var times = [timespec(tv_sec: Int(seconds), tv_nsec: 0), timespec(tv_sec: Int(seconds), tv_nsec: 0)]
    _ = utimensat(AT_FDCWD, url.path, &times, 0)
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// A pid that is gone: a child that ended.
private func deadPid() throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try p.run()
    p.waitUntilExit()
    return p.processIdentifier
}

/// A home of its own (the root conftest's `mcp_files_in_tmp`).
private final class Home {
    let dir = tempFolder("mcp")
    let stores: StorePaths
    init() {
        stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                            home: dir.appendingPathComponent("home", isDirectory: true))
    }
    deinit { try? FileManager.default.removeItem(at: dir) }

    var log: URL { stores.mcpAccess }
    var support: URL { stores.support }
    func append(_ entry: String) { McpLog.append(parse(entry), stores: stores) }
    func ns() throws -> [Int] { try McpLog.read(stores: stores).compactMap { if case .int(let n)? = $0["n"] { return n }; return nil } }
    func cleared() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []).filter { $0.contains("cleared") }
            .map { support.appendingPathComponent($0) }
    }
}

@Suite struct McpRoutesTests {
    // MARK: - the log

    @Test func test_the_log_is_never_rotated_and_an_old_rotated_file_is_still_read() throws {
        let h = Home()
        try write(h.support.appendingPathComponent("mcp-access.1.jsonl"), (0..<5).map { "{\"n\": \($0)}\n" }.joined())
        for n in 5..<60 { h.append(#"{"tool": "list_meetings", "n": \#(n), "pad": "\#(String(repeating: "x", count: 50))"}"#) }
        let names = try FileManager.default.contentsOfDirectory(atPath: h.support.path).filter { $0.hasSuffix(".jsonl") }.sorted()
        #expect(names == ["mcp-access.1.jsonl", "mcp-access.jsonl"])
        let f = try FileHandle(forWritingTo: h.log)
        f.seekToEndOfFile()
        f.write(Data("not json\n".utf8))  // a torn line is skipped
        try f.close()
        #expect(try h.ns() == Array((0...59).reversed()))  // newest first, none missing
        #expect(try McpLog.read(limit: 3, stores: h.stores).map { $0["n"] } == [.int(59), .int(58), .int(57)])
    }

    @Test func test_a_held_lock_drops_the_line_instead_of_blocking_the_call() throws {
        let h = Home()
        h.append(#"{"n": 1}"#)
        let fd = open(h.support.appendingPathComponent("mcp-access.lock").path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        #expect(fd >= 0 && flock(fd, LOCK_EX) == 0)  // another process stuck while writing
        h.append(#"{"n": 2}"#)  // would wait for ever if it waited
        flock(fd, LOCK_UN)
        close(fd)
        h.append(#"{"n": 3}"#)
        #expect(try h.ns() == [3, 1])
    }

    @Test func test_reads_of_one_meeting() throws {
        let h = Home()
        h.append(#"{"tool": "get_meeting", "meetings": ["\#(MEETING)"], "n": 1}"#)
        h.append(#"{"tool": "list_people", "n": 2}"#)
        h.append(#"{"tool": "search_meetings", "meetings": ["2026-10-26T09-00-00", "\#(MEETING)"], "n": 3}"#)
        #expect(try McpLog.read(meeting: MEETING, stores: h.stores).map { $0["n"] } == [.int(3), .int(1)])
    }

    @Test func test_clearing_the_log_can_be_undone() throws {
        let h = Home()
        h.append(#"{"n": 1}"#)
        h.append(#"{"n": 2}"#)
        let token = try McpLog.clear(stores: h.stores)
        #expect(token != nil && token?.count == 12)
        #expect(try h.ns() == [] && !exists(h.log))
        h.append(#"{"n": 3}"#)  // a call while the toast shows
        #expect(try McpLog.restore(token!, stores: h.stores))
        #expect(try h.ns() == [3, 2, 1])
        #expect(try !McpLog.restore(token!, stores: h.stores))  // once
        #expect(try McpLog.clear(stores: h.stores) != nil)
        #expect(try McpLog.clear(stores: h.stores) == nil)  // nothing left to clear
    }

    @Test func test_a_cleared_log_is_gone_for_good_after_a_while() throws {
        let h = Home()
        h.append(#"{"n": 1}"#)
        let token = try #require(try McpLog.clear(stores: h.stores))
        let aside = try #require(h.cleared().first)
        setMtime(aside, Date().timeIntervalSince1970 - McpLog.CLEARED_KEEP_SECONDS - 5)
        #expect(try McpLog.read(stores: h.stores).isEmpty)
        #expect(!exists(aside))
        #expect(try !McpLog.restore(token, stores: h.stores))
    }

    @Test func test_a_cleared_log_is_deleted_when_the_undo_window_ends_even_if_nobody_looks() throws {
        let h = Home()
        h.append(#"{"n": 1}"#)
        var token = try #require(try McpLog.clear(stores: h.stores, keep: 0.3))
        #expect(try McpLog.restore(token, stores: h.stores))  // within the window
        token = try #require(try McpLog.clear(stores: h.stores, keep: 0.3))
        #expect(!h.cleared().isEmpty)
        #expect(until(3) { h.cleared().isEmpty })  // no read meanwhile
    }

    @Test func test_any_log_write_deletes_an_expired_cleared_log() throws {
        let h = Home()
        h.append(#"{"n": 1}"#)
        _ = try McpLog.clear(stores: h.stores)
        let aside = try #require(h.cleared().first)
        setMtime(aside, Date().timeIntervalSince1970 - McpLog.CLEARED_KEEP_SECONDS - 5)  // the window went away meanwhile
        h.append(#"{"n": 2}"#)  // a `palaver mcp` process writing
        #expect(!exists(aside))
    }

    @Test func test_the_lines_of_a_meeting_and_of_other_writers_are_read_as_python_reads_them() throws {
        let h = Home()
        // A cut-short last line, an entry that is no object, "meetings" as text (Python's `in` is a substring test) and
        // as an object (its keys); a number there is a TypeError, as in Python.
        try write(h.log, """
            {"n": 1, "meetings": "x\(MEETING)y"}
            ["\(MEETING)"]
            {"n": 2, "meetings": {"\(MEETING)": 1}}
            {"n": 3, "meetings": ["\(MEETING)
            """)
        #expect(try McpLog.read(meeting: MEETING, stores: h.stores).map { $0["n"] } == [.int(2), .int(1)])
        #expect(try h.ns() == [2, 1])
        try write(h.log, "{\"n\": 4, \"meetings\": 7, \"id\": \"\(MEETING)\"}\n")
        #expect(throws: McpLog.TypeError.self) { try McpLog.read(meeting: MEETING, stores: h.stores) }
    }

    // MARK: - running servers

    @Test func test_heartbeat_files_show_the_live_clients_and_dead_ones_are_pruned() throws {
        let h = Home()
        let folder = h.stores.mcpDir
        let me = getpid()
        // What a running `palaver mcp` keeps (Session._write), as a heartbeat of this process.
        try write(folder.appendingPathComponent("\(me).json"), """
            {"pid": \(me), "started": "2026-10-27T16:03:07+01:00", "client": {"name": "claude-code", "version": "2.1.3"}, \
            "calls": 1, "last_call": "2026-10-27T16:04:00+01:00", "last_tool": "get_meeting"}
            """)
        let dead = folder.appendingPathComponent("\(try deadPid()).json")
        try write(dead, "{\"pid\": 1}")
        let quiet = folder.appendingPathComponent("\(getppid()).json")  // alive, but no heartbeat for 10 min: not shown, kept
        try write(quiet, "{\"pid\": \(getppid())}")
        setMtime(quiet, Date().timeIntervalSince1970 - 600)

        let clients = McpLog.clients(stores: h.stores)
        #expect(clients.count == 1)
        let client = try #require(clients.first)
        #expect(client["pid"] == .int(Int(me)) && dumps(client["client"]) == #"{"name": "claude-code", "version": "2.1.3"}"#)
        #expect(client["calls"] == .int(1) && client["last_tool"] == .string("get_meeting"))
        #expect(client["last_call"]?.truthy == true && client["started"]?.truthy == true)
        #expect(!exists(dead) && exists(quiet))

        setMtime(quiet, Date().timeIntervalSince1970 - 7200)  // a pid that lives on that long without a beat is someone else's now
        _ = McpLog.clients(stores: h.stores)
        #expect(!exists(quiet))

        try FileManager.default.removeItem(at: folder.appendingPathComponent("\(me).json"))  // Session.stop
        #expect(McpLog.clients(stores: h.stores).isEmpty)
    }

    @Test func test_clients_are_oldest_first_with_their_own_pid_and_odd_files_kept() throws {
        let h = Home()
        let folder = h.stores.mcpDir
        try write(folder.appendingPathComponent("\(getpid()).json"), #"{"started": "2026-10-27T10:00:00+01:00", "pid": 1}"#)
        try write(folder.appendingPathComponent("\(getppid()).json"), #"{"started": "2026-10-27T09:00:00+01:00"}"#)
        try write(folder.appendingPathComponent("notes.json"), "{}")  // no pid: kept, not shown
        try write(folder.appendingPathComponent("1.json"), "[1]")  // launchd's pid; no object: not shown
        let clients = McpLog.clients(stores: h.stores)
        #expect(clients.map(dumps) == [
            #"{"started": "2026-10-27T09:00:00+01:00", "pid": \#(getppid())}"#,
            #"{"started": "2026-10-27T10:00:00+01:00", "pid": \#(getpid())}"#,
        ])
        #expect(exists(folder.appendingPathComponent("notes.json")))
    }

    // MARK: - setup

    @Test func test_registered_reads_the_claude_code_config() throws {
        let h = Home()
        func registered() throws -> String { dumps(try McpLog.registered(stores: h.stores)) }
        #expect(try registered() == #"{"registered": false}"#)  // no Claude Code config at all
        let config = h.stores.claudeConfig
        try write(config, #"{"mcpServers": {"other": {"type": "stdio", "command": "npx", "args": ["x"]}, "#
            + #""meetings": {"type": "stdio", "command": "/v/bin/python3", "args": ["-m", "palaver", "mcp"]}}}"#)
        #expect(try registered() == #"{"registered": true, "name": "meetings", "scope": "user"}"#)
        try write(config, #"{"projects": {"/x": {"mcpServers": {"notes": {"command": "/v/bin/palaver", "args": ["mcp"]}}}}}"#)
        #expect(try registered() == #"{"registered": true, "name": "notes", "scope": "project"}"#)
        try write(config, #"{"mcpServers": {}}"#)
        #expect(try registered() == #"{"registered": false}"#)
        try write(config, "{not json")
        #expect(try registered() == #"{"registered": null}"#)
    }

    @Test func test_registered_reads_the_claude_desktop_config() throws {
        let h = Home()
        let app = h.dir.appendingPathComponent("Applications/Claude.app", isDirectory: true)
        func registered() throws -> String { dumps(try McpLog.desktopRegistered(stores: h.stores, app: app)) }
        #expect(try registered() == #"{"installed": false, "registered": false}"#)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(try registered() == #"{"installed": true, "registered": false}"#)
        let config = h.stores.claudeDesktopConfig
        try write(config, #"{"mcpServers": {"meetings": {"command": "/v/bin/python3", "args": ["-m", "palaver", "mcp"]}}}"#)
        #expect(try registered() == #"{"installed": true, "registered": true, "name": "meetings"}"#)
        try write(config, "{not json")
        #expect(try registered() == #"{"installed": true, "registered": null}"#)
    }

    @Test func test_an_entry_into_the_old_installers_venv_counts_as_not_working() throws {
        let h = Home()
        let old = "/Users/someone/Library/Application Support/palaver/venv/bin/python"
        try write(h.stores.claudeConfig, #"{"mcpServers": {"meetings": {"command": "\#(old)", "args": ["-m", "palaver", "mcp"]}}}"#)
        #expect(dumps(try McpLog.registered(stores: h.stores))
                == #"{"registered": false, "stale": true, "name": "meetings", "scope": "user"}"#)
        let app = h.dir.appendingPathComponent("Applications/Claude.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try write(h.stores.claudeDesktopConfig, #"{"mcpServers": {"meetings": {"command": "\#(old)", "args": ["-m", "palaver", "mcp"]}}}"#)
        #expect(dumps(try McpLog.desktopRegistered(stores: h.stores, app: app))
                == #"{"installed": true, "registered": false, "stale": true, "name": "meetings"}"#)
    }

    @Test func test_the_config_files_are_read_as_python_reads_them() throws {
        let h = Home()
        func registered() throws -> String { dumps(try McpLog.registered(stores: h.stores)) }
        // args as text are its characters, so "mcp" is no word of it; a list of the config's own types counts by str().
        try write(h.stores.claudeConfig, #"{"mcpServers": {"a": {"command": "palaver", "args": "mcp"}, "#
            + #""b": {"command": ["palaver"], "args": ["mcp"]}}}"#)
        #expect(try registered() == #"{"registered": true, "name": "b", "scope": "user"}"#)
        try write(h.stores.claudeConfig, #"{"projects": ["/x"]}"#)  // no object: can't be told
        #expect(try registered() == #"{"registered": null}"#)
        try write(h.stores.claudeConfig, "[]")
        #expect(try registered() == #"{"registered": null}"#)
        try write(h.stores.claudeConfig, #"{"mcpServers": {"a": {"command": "palaver", "args": 3}}}"#)  // a TypeError
        #expect(throws: McpLog.TypeError.self) { try McpLog.registered(stores: h.stores) }
    }

    // MARK: - the window's API

    @Test func test_http_mcp_shows_clients_log_and_setup() throws {
        let s = try TestServer()
        defer { s.stop() }
        s.app.claudeDesktopApp = s.dir.appendingPathComponent("Applications/Claude.app", isDirectory: true)  // not installed
        let stores = s.app.stores
        let me = getpid()
        try write(stores.mcpDir.appendingPathComponent("\(me).json"),
                  #"{"pid": \#(me), "started": "2026-10-27T16:03:07+01:00", "client": {"name": "claude-code", "version": "2.1.3"}, "calls": 0, "last_call": null, "last_tool": null}"#)
        McpLog.append(parse(#"{"tool": "get_meeting", "meetings": ["\#(MEETING)"], "args": {"meeting_id": "\#(MEETING)"}}"#), stores: stores)
        McpLog.append(parse(#"{"tool": "list_people"}"#), stores: stores)

        var r = s.get("/api/mcp")
        let d = try #require(r.json)
        #expect(r.status == 200 && d["clients"]?.arrayValue?.map { $0["pid"] } == [.int(Int(me))])
        #expect(d["log"]?.arrayValue?.map { $0["tool"] } == [.string("list_people"), .string("get_meeting")])
        #expect(dumps(d["registered"]) == #"{"registered": false}"#)
        #expect(dumps(d["desktop"]) == #"{"installed": false, "registered": false}"#)
        #expect(d.description.hasPrefix(#"{"clients": "#))

        r = s.get("/api/mcp?meeting=\(MEETING)")
        #expect(r.status == 200 && r.json?["reads"]?.arrayValue?.map { $0["tool"] } == [.string("get_meeting")])

        r = s.post("/api/mcp/clear")
        let answer = try #require(r.json)
        #expect(r.status == 200 && answer["log"] == .array([]) && answer["undo"]?.truthy == true && answer["cleared"] == .int(2))
        r = s.post("/api/mcp/restore", .object([("token", answer["undo"]!)]))
        #expect(r.status == 200 && r.json?["log"]?.arrayValue?.map { $0["tool"] } == [.string("list_people"), .string("get_meeting")])
        r = s.post("/api/mcp/restore", .object([("token", answer["undo"]!)]))
        #expect(r.status == 404)
    }

    @Test func test_the_routes_answer_what_python_answers_for_odd_requests() throws {
        let s = try TestServer()
        defer { s.stop() }
        var r = s.post("/api/mcp/clear")  // nothing to clear
        #expect(r.status == 200 && r.json?["cleared"] == .int(0) && r.json?["undo"] == .null)
        r = s.post("/api/mcp/restore")
        #expect(r.status == 400 && r.error == "bad request: 'token'")
        r = s.post("/api/mcp/restore", .object([("token", .string("../x"))]))  // no token: nothing read
        #expect(r.status == 404 && r.error == "can't undo this any more")
        r = s.post("/api/mcp/restore", .array([]))
        #expect(r.status == 500 && r.error == "list indices must be integers or slices, not str")
        r = s.post("/api/mcp/install", .string("code"))
        #expect(r.status == 500 && r.error == "'str' object has no attribute 'get'")
    }

    @Test func test_http_mcp_install_adds_palaver_to_claude_code() throws {
        // In the server's own process (McpSetup), with a fake `claude` that writes Claude Code's config as it would.
        let s = try TestServer()
        defer { s.stop() }
        let stores = s.app.stores
        s.app.mcpSetup = McpSetup(stores: stores, executable: "/A/Contents/Resources/bin/palaver", findClaude: { nil })
        var r = s.post("/api/mcp/install")
        #expect(r.status == 500 && r.error?.contains("Claude Code") == true)  // no claude CLI

        let calls = NSLock()
        var made: [[String]] = []
        s.app.mcpSetup = McpSetup(stores: stores, executable: "/A/Contents/Resources/bin/palaver", findClaude: { "/fake/claude" }) { argv in
            calls.withLock { made.append(argv) }
            try write(stores.claudeConfig, #"{"mcpServers": {"meetings": {"command": "/A/Contents/Resources/bin/palaver", "args": ["mcp"]}}}"#)
            return McpSetup.Ran(status: 0)
        }
        r = s.post("/api/mcp/install")
        #expect(r.status == 200 && dumps(r.json?["registered"]) == #"{"registered": true, "name": "meetings", "scope": "user"}"#)
        #expect(calls.withLock { made } == [["/fake/claude", "mcp", "add", "--scope", "user", "meetings", "--",
                                             "/A/Contents/Resources/bin/palaver", "mcp"]])
    }

    @Test func test_http_mcp_install_passes_the_apps_cli_options() throws {
        // Claude Desktop's entry starts `bin/palaver` with the options the server was started with (`--config`).
        let s = try TestServer()
        defer { s.stop() }
        s.app.claudeDesktopApp = s.dir.appendingPathComponent("Applications/Claude.app", isDirectory: true)
        s.app.mcpSetup = McpSetup(stores: s.app.stores, executable: "/A/bin/palaver", options: ["--config", "/c/config.toml"],
                                  findClaude: { nil })
        let r = s.post("/api/mcp/install", .object([("target", .string("desktop"))]))
        #expect(r.status == 200 && r.json?["desktop"]?["registered"] == .bool(true))
        #expect(dumps(PythonJSON.read(s.app.stores.claudeDesktopConfig)?["mcpServers"]?["meetings"])
                == #"{"command": "/A/bin/palaver", "args": ["--config", "/c/config.toml", "mcp"]}"#)
        // The server's own setup gets the options it was started with.
        let config = s.dir.appendingPathComponent("config.toml")
        try write(config, "[recording]\noutput_dir = \"\(s.app.outputDir.path)\"\n[calendar]\nenabled = false\n")
        let env = ["PALAVER_HOME": s.dir.appendingPathComponent("home").path, "XDG_CONFIG_HOME": s.dir.appendingPathComponent("config").path]
        let made = ServeMain.makeApp(try ServeMain.parse(["--config", config.path, "--port", "0"]), env: env)
        #expect(made.mcpSetup.options == ["--config", config.path])
    }
}
