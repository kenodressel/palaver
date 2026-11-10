// Adding Palaver's MCP server to Claude, and moving the entries of older versions to the Swift `bin/palaver mcp`
// (McpSetup; mcp_access.py `install`, `install_desktop`, `migrate`), plus the window's install route over it. Claude
// Code's and Claude Desktop's configs are fixtures in the test's own home and `claude` is a fake that records its
// calls: never the real ~/.claude.json, Claude Desktop's real config or the real Claude Code.
import Darwin
import Foundation
import Testing
import PalaverCore
@testable import PalaverDomain
@testable import PalaverServer

private let APP = "/Applications/Palaver.app"
private let BIN = APP + "/Contents/Resources/bin/palaver"

private func parse(_ s: String) -> JSONValue { try! PythonJSON.parse(Data(s.utf8)) }
private func dumps(_ v: JSONValue?) -> String { v.map { PythonJSON.dumps($0, ensureAscii: false) } ?? "nil" }

private func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func read(_ url: URL) -> JSONValue? { PythonJSON.read(url) }

/// A home of its own, with a fake `claude` whose calls are kept.
private final class Home {
    let dir = tempFolder("mcp-setup")
    let stores: StorePaths
    private let lock = NSLock()
    private var ran: [[String]] = []
    var answer: ([String]) -> McpSetup.Ran = { _ in McpSetup.Ran(status: 0) }
    var hasClaude = true

    init() {
        stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                            home: dir.appendingPathComponent("home", isDirectory: true))
    }
    deinit { try? FileManager.default.removeItem(at: dir) }

    var calls: [[String]] { lock.withLock { ran } }
    var code: URL { stores.claudeConfig }
    var desktop: URL { stores.claudeDesktopConfig }

    func setup(executable: String = BIN, options: [String] = []) -> McpSetup {
        McpSetup(stores: stores, executable: executable, options: options,
                 findClaude: { [unowned self] in hasClaude ? "/fake/claude" : nil },
                 run: { [unowned self] argv in
                     lock.withLock { ran.append(argv) }
                     return answer(argv)
                 })
    }
}

/// An entry as Claude Code keeps one.
private func entry(_ command: String, _ args: [String], extra: String = "") -> String {
    #"{"type": "stdio", "command": "\#(command)", "args": \#(dumps(.strings(args)))\#(extra), "env": {}}"#
}

@Suite struct McpSetupTests {
    // MARK: - migrate

    @Test func everyEntryStartingPalaversPythonNowStartsTheSwiftServer() throws {
        let h = Home()
        let old = "/Applications/Palaver.app/Contents/Resources/bin/python"
        let host = "/Users/x/Applications/Palaver.app/Contents/MacOS/palaver-python"
        let runtime = "/Users/x/Library/Application Support/palaver/runtime/3.12.7-1/bin/python3"
        let venv = "/Users/x/Library/Application Support/palaver/venv/bin/python"
        try write(h.code, """
            {"numStartups": 41, "mcpServers": {"meetings": \(entry(old, ["-m", "palaver", "mcp"])), \
            "other": \(entry("npx", ["-y", "server-palaver-mcp"])), \
            "notes": \(entry(host, ["-m", "palaver", "--config", "/Users/x/c.toml", "mcp"], extra: #", "timeout": 30"#))}, \
            "projects": {"/Users/x/work": {"allowedTools": [], "mcpServers": {"meetings": \(entry(runtime, ["-m", "palaver", "mcp"])), \
            "venv": \(entry(venv, ["-m", "palaver", "mcp"]))}}, \
            "/Users/x/dev/palaver": {"mcpServers": {"dev": \(entry("/Users/x/dev/palaver/.venv/bin/python", ["-m", "palaver", "mcp"]))}}, \
            "/Users/x/other": {"mcpServers": {"done": \(entry(BIN, ["mcp"]))}}}, "userID": "abc"}
            """)
        chmod(h.code.path, 0o600)
        #expect(h.setup().migrate() == ["code"])

        let c = try #require(read(h.code))
        if case .object(let top) = c { #expect(top.map(\.0) == ["numStartups", "mcpServers", "projects", "userID"]) }  // order kept
        #expect(c["numStartups"] == .int(41) && c["userID"] == .string("abc"))
        #expect(dumps(c["mcpServers"]?["meetings"]) == dumps(parse(entry(BIN, ["mcp"]))))
        #expect(dumps(c["mcpServers"]?["notes"]) == dumps(parse(entry(BIN, ["--config", "/Users/x/c.toml", "mcp"], extra: #", "timeout": 30"#))))
        #expect(dumps(c["mcpServers"]?["other"]) == dumps(parse(entry("npx", ["-y", "server-palaver-mcp"]))))  // not Palaver's
        let work = c["projects"]?["/Users/x/work"]
        #expect(work?["mcpServers"]?["meetings"]?["command"] == .string(BIN) && work?["mcpServers"]?["venv"]?["command"] == .string(BIN))
        #expect(work?["allowedTools"] == .array([]))
        // A checkout's own venv is the developer's, and a moved entry stays as it is.
        #expect(c["projects"]?["/Users/x/dev/palaver"]?["mcpServers"]?["dev"]?["command"] == .string("/Users/x/dev/palaver/.venv/bin/python"))
        #expect(dumps(c["projects"]?["/Users/x/other"]?["mcpServers"]?["done"]) == dumps(parse(entry(BIN, ["mcp"]))))
        var st = stat()
        #expect(stat(h.code.path, &st) == 0 && st.st_mode & 0o777 == 0o600)  // still the user's own
        #expect(!FileManager.default.fileExists(atPath: h.code.path + ".bak"))
        #expect((try FileManager.default.contentsOfDirectory(atPath: h.code.deletingLastPathComponent().path)).allSatisfy { !$0.hasSuffix(".tmp") })

        let before = try Data(contentsOf: h.code)
        #expect(h.setup().migrate() == [])  // once is enough
        #expect(try Data(contentsOf: h.code) == before)
        #expect(try McpLog.registered(stores: h.stores)["registered"] == .bool(true))
    }

    @Test func claudeDesktopsEntryMovesWithTheOldFileKeptAsBak() throws {
        let h = Home()
        let text = """
            {"globalShortcut": "", "mcpServers": {"meetings": {"command": "/Applications/Palaver.app/Contents/Resources/bin/python", \
            "args": ["-m", "palaver", "--config", "/c/config.toml", "mcp"], "env": {"A": "1"}}, "fs": {"command": "npx", "args": ["fs"]}}}
            """
        try write(h.desktop, text)
        #expect(h.setup().migrate() == ["desktop"])
        let d = try #require(read(h.desktop))
        #expect(dumps(d["mcpServers"]?["meetings"]) == #"{"command": "\#(BIN)", "args": ["--config", "/c/config.toml", "mcp"], "env": {"A": "1"}}"#)
        #expect(dumps(d["mcpServers"]?["fs"]) == #"{"command": "npx", "args": ["fs"]}"#)
        #expect(try String(contentsOf: URL(fileURLWithPath: h.desktop.path + ".bak"), encoding: .utf8) == text)
        #expect(h.setup().migrate() == [])
    }

    @Test func missingBrokenOrForeignConfigsAreLeftAlone() throws {
        let h = Home()
        #expect(h.setup().migrate() == [])  // neither config is there
        #expect(!FileManager.default.fileExists(atPath: h.code.path) && !FileManager.default.fileExists(atPath: h.desktop.path))
        try write(h.code, "{not json")
        try write(h.desktop, #"{"mcpServers": {"x": {"command": "uvx", "args": ["mcp"]}}}"#)
        #expect(h.setup().migrate() == [])
        #expect(try String(contentsOf: h.code, encoding: .utf8) == "{not json")
        #expect(!FileManager.default.fileExists(atPath: h.desktop.path + ".bak"))
    }

    @Test func fromACheckoutATranslocatedOrANotInstalledBundleNothingIsMoved() throws {
        let h = Home()
        let old = #"{"mcpServers": {"meetings": \#(entry("/Applications/Palaver.app/Contents/Resources/bin/python", ["-m", "palaver", "mcp"]))}}"#
        try write(h.code, old)
        let installed = h.stores.applications.appendingPathComponent("Palaver.app")  // ~/Applications of the test's home
        let yes: (String) -> Bool = { _ in true }
        #expect(McpSetup.migrateAtStart(bundle: nil, stores: h.stores, isExecutable: yes) == [])
        for elsewhere in ["/private/var/folders/x/T/AppTranslocation/1234/d/Palaver.app", "/Users/x/dev/palaver/dist/Palaver.app"] {
            #expect(McpSetup.migrateAtStart(bundle: URL(fileURLWithPath: elsewhere), stores: h.stores, isExecutable: yes) == [])
        }
        #expect(McpSetup.migrateAtStart(bundle: installed, stores: h.stores, isExecutable: { _ in false }) == [])  // no bin/palaver
        #expect(try String(contentsOf: h.code, encoding: .utf8) == old)
        var said: [String] = []
        #expect(McpSetup.migrateAtStart(bundle: installed, stores: h.stores, log: { said.append($0) }, isExecutable: yes) == ["code"])
        #expect(read(h.code)?["mcpServers"]?["meetings"]?["command"]
                == .string(installed.resolvingSymlinksInPath().appendingPathComponent("Contents/Resources/bin/palaver").path))
        #expect(said == ["Claude's MCP entries now start the Swift server (code)"])
        #expect(McpSetup.isInstalled(bundle: URL(fileURLWithPath: "/Applications/Palaver.app"), applications: h.stores.applications,
                                     isExecutable: yes))
    }

    @Test func anEntryOfAnAppThatIsGoneIsRepairedAndOneThatIsThereStays() throws {
        let h = Home()
        let there = h.dir.appendingPathComponent("Other.app/Contents/Resources/bin/palaver")
        try write(there, "#!/bin/sh\n")
        try write(h.desktop, #"{"mcpServers": {"gone": {"command": "/Volumes/Old/Palaver.app/Contents/Resources/bin/palaver", "args": ["--config", "/c.toml", "mcp"]}, "there": {"command": "\#(there.path)", "args": ["mcp"]}, "fine": {"command": "\#(BIN)", "args": ["mcp"]}}}"#)
        #expect(h.setup().migrate() == ["desktop"])
        let d = try #require(read(h.desktop))
        #expect(dumps(d["mcpServers"]?["gone"]) == #"{"command": "\#(BIN)", "args": ["--config", "/c.toml", "mcp"]}"#)
        #expect(d["mcpServers"]?["there"]?["command"] == .string(there.path) && d["mcpServers"]?["fine"]?["command"] == .string(BIN))
    }

    @Test func aSymlinkedConfigStaysALinkAndItsFileIsRewrittenWithItsMode() throws {
        let h = Home()
        let dotfiles = h.dir.appendingPathComponent("dotfiles/claude.json")
        try write(dotfiles, #"{"mcpServers": {"meetings": \#(entry("/Applications/Palaver.app/Contents/Resources/bin/python", ["-m", "palaver", "mcp"]))}}"#)
        chmod(dotfiles.path, 0o600)
        try FileManager.default.createDirectory(at: h.code.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: h.code.path, withDestinationPath: dotfiles.path)
        #expect(h.setup().migrate() == ["code"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: h.code.path) == dotfiles.path)  // still the link
        #expect(read(dotfiles)?["mcpServers"]?["meetings"]?["command"] == .string(BIN))
        var st = stat()
        #expect(stat(dotfiles.path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        #expect((try FileManager.default.contentsOfDirectory(atPath: dotfiles.deletingLastPathComponent().path)) == ["claude.json"])
        // A link to a file that is gone is not replaced by a file.
        try FileManager.default.removeItem(at: dotfiles)
        var said: [String] = []
        #expect(h.setup().migrate(log: { said.append($0) }) == [] && said.first?.contains("link to a file that is not there") == true)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: h.code.path) == dotfiles.path)
        try FileManager.default.removeItem(at: h.code)
        try FileManager.default.createSymbolicLink(atPath: h.code.path, withDestinationPath: dotfiles.path)
        #expect(throws: McpSetup.Failed.self) { _ = try h.setup().rewrite(h.code.path, backup: false, missingIsEmpty: true) { _ in true } }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: h.code.path) == dotfiles.path)
    }

    @Test func aConfigWithALoneSurrogateIsLeftAloneAndTheOtherStillMoves() throws {
        let h = Home()
        // Claude Code's history can hold half of an emoji (JavaScript writes it as a lone `\udXXX`); a pair is fine.
        let code = #"{"history": ["cut \ud83d", "whole 😀", "\\ud800 is text"], "mcpServers": {"meetings": \#(entry("/Applications/Palaver.app/Contents/Resources/bin/python", ["-m", "palaver", "mcp"]))}}"#
        try write(h.code, code)
        try write(h.desktop, #"{"mcpServers": {"meetings": {"command": "/Applications/Palaver.app/Contents/Resources/bin/python", "args": ["-m", "palaver", "mcp"]}}}"#)
        chmod(h.desktop.path, 0o600)
        var said: [String] = []
        #expect(h.setup().migrate(log: { said.append($0) }) == ["desktop"])  // one failing never keeps the other
        #expect(try String(contentsOf: h.code, encoding: .utf8) == code)  // byte for byte
        #expect(said.count == 1 && said[0].contains("Claude Code's MCP entries were not moved") && said[0].contains("lone UTF-16 surrogate"))
        var st = stat()
        #expect(stat(h.desktop.path + ".bak", &st) == 0 && st.st_mode & 0o777 == 0o600)  // the .bak keeps the mode
        #expect(stat(h.desktop.path, &st) == 0 && st.st_mode & 0o777 == 0o600)

        #expect(!McpSetup.hasLoneSurrogate(Data(#"["😀", "\\udc00", "é"]"#.utf8)))
        #expect(McpSetup.hasLoneSurrogate(Data(#"["\udc00"]"#.utf8)) && McpSetup.hasLoneSurrogate(Data(#"["\ud83d x"]"#.utf8)))
        try write(h.code, code.replacingOccurrences(of: "cut \\ud83d", with: "cut"))
        #expect(h.setup().migrate() == ["code"])  // without the lone half it moves, the pair kept as its emoji
        #expect(read(h.code)?["history"]?.arrayValue?[1] == .string("whole 😀"))
    }

    @Test func aConfigThatNeverNamesPalaverIsNotEvenParsed() throws {
        let h = Home()
        let foreign = #"{"history": ["\udc00"], "mcpServers": {"x": {"command": "uvx", "args": ["mcp"]}}}"#
        try write(h.code, foreign)
        var said: [String] = []
        #expect(h.setup().migrate(log: { said.append($0) }) == [] && said.isEmpty)  // the lone surrogate is never looked at
        #expect(try String(contentsOf: h.code, encoding: .utf8) == foreign)
    }

    @Test func aConfigClaudeWritesMeanwhileIsReadAgainSoItsChangeStays() throws {
        let h = Home()
        try write(h.code, #"{"n": 1}"#)
        var tries = 0
        let written = try h.setup().rewrite(h.code.path, backup: false) { (config: inout JSONValue) in
            tries += 1
            if tries == 1 { try write(h.code, #"{"n": 2, "claude": true}"#) }  // Claude Code saved while we changed it
            guard case .object(var fields) = config else { return false }
            fields.append(("ours", .bool(true)))
            config = .object(fields)
            return true
        }
        #expect(written && tries == 2)
        #expect(dumps(read(h.code)) == #"{"n": 2, "claude": true, "ours": true}"#)
    }

    // MARK: - install

    @Test func installRunsClaudeMcpAddWithTheAppsOptions() throws {
        let h = Home()
        try h.setup(options: ["--config", "/c/config.toml"]).install()
        #expect(h.calls == [["/fake/claude", "mcp", "add", "--scope", "user", "meetings", "--", BIN, "--config", "/c/config.toml", "mcp"]])
    }

    @Test func installRemovesTheOldInstallersStaleEntryFirstAndSaysWhatFailed() throws {
        let h = Home()
        try write(h.code, #"{"mcpServers": {"meetings": \#(entry("/Users/x/Library/Application Support/palaver/venv/bin/python", ["-m", "palaver", "mcp"]))}}"#)
        h.answer = { argv in argv[2] == "add" ? McpSetup.Ran(status: 1, out: "", err: "MCP server meetings already exists\n") : McpSetup.Ran(status: 0) }
        #expect(throws: McpSetup.Failed.self) { try h.setup().install() }
        #expect(h.calls.map { $0[2] } == ["remove", "add"] && h.calls[0] == ["/fake/claude", "mcp", "remove", "meetings", "--scope", "user"])
        do { try h.setup().install() } catch { #expect("\(error)" == "MCP server meetings already exists") }
        h.answer = { _ in McpSetup.Ran(status: 3) }
        do { try h.setup().install() } catch { #expect("\(error)" == "claude mcp add failed (3)") }
        h.hasClaude = false
        do { try h.setup().install() } catch { #expect("\(error)" == "Claude Code (the claude command) was not found") }
    }

    @Test func noClaudeIsEverFoundInATestUnlessOneIsGiven() throws {
        let h = Home()
        let setup = McpSetup(stores: h.stores, executable: BIN, env: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"])
        #expect(setup.findClaude() == nil)
        #expect(throws: McpSetup.Failed.self) { try setup.install() }
    }

    @Test func installDesktopMergesTheEntryKeepsEverythingElseAndTheOldFile() throws {
        let h = Home()
        try h.setup().installDesktop()  // no config yet: a new one
        #expect(dumps(read(h.desktop)) == #"{"mcpServers": {"meetings": {"command": "\#(BIN)", "args": ["mcp"]}}}"#)
        #expect(!FileManager.default.fileExists(atPath: h.desktop.path + ".bak"))
        let before = #"{"theme": "dark", "mcpServers": {"fs": {"command": "npx"}, "meetings": {"command": "/old", "args": [], "env": {"X": "1"}}}}"#
        try write(h.desktop, before)
        try h.setup(options: ["--config", "/c.toml"]).installDesktop()
        #expect(dumps(read(h.desktop)) == #"{"theme": "dark", "mcpServers": {"fs": {"command": "npx"}, "meetings": {"command": "\#(BIN)", "args": ["--config", "/c.toml", "mcp"], "env": {"X": "1"}}}}"#)
        #expect(try String(contentsOf: URL(fileURLWithPath: h.desktop.path + ".bak"), encoding: .utf8) == before)
        #expect(try String(contentsOf: h.desktop, encoding: .utf8).hasSuffix("}\n"))
        for broken in ["{not json", "[]", #"{"mcpServers": []}"#] {
            try write(h.desktop, broken)
            #expect(throws: McpSetup.Failed.self) { try h.setup().installDesktop() }
            #expect(try String(contentsOf: h.desktop, encoding: .utf8) == broken)  // left alone
        }
    }

    @Test func theCommandClaudeStartsIsTheBundlesBinPalaverOrTheBuiltOneBesideIt() {
        #expect(McpSetup.executable(running: URL(fileURLWithPath: "/Applications/Palaver.app/Contents/MacOS/palaver-server")) == BIN)
        #expect(McpSetup.executable(running: URL(fileURLWithPath: "/Applications/Palaver.app/Contents/Resources/bin/palaver")) == BIN)
        #expect(McpSetup.executable(running: URL(fileURLWithPath: "/x/native/.build/debug/palaver-server")) == "/x/native/.build/debug/palaver-cli")
        #expect(McpSetup.isPalaverPython("/Applications/Palaver.app/Contents/Resources/bin/python"))
        #expect(!McpSetup.isPalaverPython("/usr/bin/python3") && !McpSetup.isPalaverPython(BIN))
    }

    // MARK: - the window's install (POST /api/mcp/install)

    @Test func theWindowAddsPalaverToClaudeCodeAndDesktopInItsOwnProcess() throws {
        let h = Home()
        let s = try TestServer()
        defer { s.stop() }
        s.app.claudeDesktopApp = s.dir.appendingPathComponent("Applications/Claude.app", isDirectory: true)
        try FileManager.default.createDirectory(at: s.app.claudeDesktopApp, withIntermediateDirectories: true)
        let stores = s.app.stores
        h.answer = { argv in
            try? write(stores.claudeConfig, #"{"mcpServers": {"meetings": {"command": "\#(argv[7])", "args": ["mcp"]}}}"#)
            return McpSetup.Ran(status: 0)
        }
        s.app.mcpSetup = McpSetup(stores: stores, executable: BIN, options: ["--config", "/c/config.toml"],
                                  findClaude: { "/fake/claude" }, run: h.setup().run)
        var r = s.post("/api/mcp/install")
        #expect(r.status == 200 && dumps(r.json?["registered"]) == #"{"registered": true, "name": "meetings", "scope": "user"}"#)
        #expect(h.calls.first?.suffix(4) == [BIN, "--config", "/c/config.toml", "mcp"])
        r = s.post("/api/mcp/install", .object([("target", .string("desktop"))]))
        #expect(r.status == 200 && dumps(r.json?["desktop"]) == #"{"installed": true, "registered": true, "name": "meetings"}"#)
        #expect(read(stores.claudeDesktopConfig)?["mcpServers"]?["meetings"]?["args"] == .strings(["--config", "/c/config.toml", "mcp"]))
        #expect(h.calls.count == 1)  // Claude Desktop needs no command

        s.app.mcpSetup = McpSetup(stores: stores, executable: BIN, findClaude: { nil })
        r = s.post("/api/mcp/install")
        #expect(r.status == 500 && r.error == "Claude Code (the claude command) was not found")
        try write(stores.claudeDesktopConfig, "{not json")
        r = s.post("/api/mcp/install", .object([("target", .string("desktop"))]))
        #expect(r.status == 500 && r.error == "\(stores.claudeDesktopConfig.path) is not valid JSON; not changed")
    }

    @Test func theServerStartsClaudesEntriesWithItsOwnOptions() throws {
        let s = try TestServer()
        defer { s.stop() }
        let config = s.dir.appendingPathComponent("config.toml")
        try write(config, "[recording]\noutput_dir = \"\(s.app.outputDir.path)\"\n[calendar]\nenabled = false\n")
        let env = ["PALAVER_HOME": s.dir.appendingPathComponent("home").path, "XDG_CONFIG_HOME": s.dir.appendingPathComponent("config").path,
                   ServeMain.TEST_CLAUDE_DESKTOP: s.dir.appendingPathComponent("Claude.app").path]
        let made = ServeMain.makeApp(try ServeMain.parse(["--config", config.path, "--port", "0"]), env: env)
        #expect(made.mcpSetup.options == ["--config", config.path])
        #expect(made.mcpSetup.executable.hasSuffix("/palaver-cli") || made.mcpSetup.executable.hasSuffix("/bin/palaver"))
        #expect(made.claudeDesktopApp.path == s.dir.appendingPathComponent("Claude.app").path)
        #expect(made.mcpSetup.findClaude() == nil)  // a test process never finds the real one
    }
}
