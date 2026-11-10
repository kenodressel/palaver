// Adding Palaver's MCP server to Claude Code and Claude Desktop, and moving the entries older versions left
// (mcp_access.py `install`, `install_desktop`, `migrate`; mcp_server.py `server_args`, `install_command`; phase 4
// batch 6). Claude starts the Swift server: `<Palaver.app>/Contents/Resources/bin/palaver [--config X] mcp`.
//
// Claude Code is added through its own command (`claude mcp add --scope user meetings -- …`), as Python did. Entries
// that start Palaver's Python (the bundle's `bin/python`, `palaver-python`, a runtime's python3, the old installer's
// venv) are rewritten in place at every start of the app (`migrate`), in `~/.claude.json` (user and project entries)
// and in Claude Desktop's config, their options and other keys kept; nothing else in those files changes. A file
// changed by Claude while it is rewritten is read again (`rewrite`), so Claude's own change is never lost.
import Darwin
import Foundation
import PalaverCore

public struct McpSetup: @unchecked Sendable {
    /// `RuntimeError`: what the window shows after "Not added to …" (a 500 with this text).
    public struct Failed: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// What a command printed and how it ended.
    public struct Ran: Sendable {
        public let status: Int32
        public let out: String
        public let err: String
        public init(status: Int32, out: String = "", err: String = "") { self.status = status; self.out = out; self.err = err }
    }

    /// The server's name in Claude's configs.
    public static let NAME = "meetings"
    /// `_run`'s `timeout=60`: each `claude mcp …` call.
    public static let RUN_TIMEOUT = 60.0
    /// The `palaver` command as SwiftPM builds it (`.build/<configuration>/palaver-cli`); the bundle names it
    /// `Contents/Resources/bin/palaver`.
    public static let CLI_BUILD_NAME = "palaver-cli"
    /// Where the command sits in Palaver.app.
    public static let CLI_IN_BUNDLE = "Contents/Resources/bin/palaver"

    public let stores: StorePaths
    /// The program Claude starts (`bin/palaver`).
    public let executable: String
    /// The app's global options (`--config X`) Claude starts it with.
    public let options: [String]
    /// The Claude Code command; nil: not on this Mac.
    public var findClaude: () -> String?
    /// Runs a command (argv) to its end.
    public var run: ([String]) throws -> Ran

    /// `env`: the environment `claude` is looked up in and runs with (its HOME is always `stores.home`, so it writes
    /// the config this setup reads). In a test process of a debug build no `claude` is found unless a test gives one:
    /// a test never reaches the real Claude Code.
    public init(stores: StorePaths, executable: String, options: [String] = [],
                env: [String: String] = ProcessInfo.processInfo.environment,
                findClaude: (() -> String?)? = nil, run: (([String]) throws -> Ran)? = nil) {
        self.stores = stores
        self.executable = executable
        self.options = options
        var childEnv = env
        childEnv["HOME"] = stores.home.path
        self.findClaude = findClaude ?? {
            #if DEBUG
            if TestIsolation.isTestProcess { return nil }
            #endif
            return ClaudeCLI.find(configured: nil, env: env, home: stores.home)
        }
        self.run = run ?? { argv in try McpSetup.runCommand(argv, env: childEnv, timeout: McpSetup.RUN_TIMEOUT) }
    }

    // MARK: - the command Claude starts

    /// `server_args`: the arguments to `bin/palaver` that serve the meetings, with the app's `options`.
    public static func serverArgs(options: [String]) -> [String] { options + ["mcp"] }

    /// `install_command`: `claude mcp add` for Claude Code, user-wide.
    public func installCommand(claude: String = "claude") -> [String] {
        [claude, "mcp", "add", "--scope", "user", Self.NAME, "--", executable] + Self.serverArgs(options: options)
    }

    /// The `palaver` command for the program at `running`: Palaver.app's `bin/palaver` when it runs from a bundle
    /// (Contents/MacOS or Contents/Resources/bin), else the `palaver-cli` built beside it (a checkout's
    /// `native/.build/<configuration>/`).
    public static func executable(running: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])) -> String {
        let exe = running.resolvingSymlinksInPath().standardizedFileURL
        if let bundle = bundle(of: exe) { return bundle.appendingPathComponent(CLI_IN_BUNDLE).path }
        return exe.deletingLastPathComponent().appendingPathComponent(CLI_BUILD_NAME).path
    }

    /// The `….app` whose `Contents` holds `url`.
    public static func bundle(of url: URL) -> URL? {
        var dir = url.deletingLastPathComponent()
        while dir.path != "/" && !dir.path.isEmpty {
            if dir.lastPathComponent == "Contents", dir.deletingLastPathComponent().pathExtension == "app" {
                return dir.deletingLastPathComponent()
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - adding

    /// `install`: adds the server to Claude Code (`claude mcp add --scope user`); an entry of the old installer that
    /// starts a python that is gone is removed first (`mcp add` refuses a taken name). `Failed` when that fails.
    public func install() throws {
        guard let claude = findClaude() else { throw Failed("Claude Code (the claude command) was not found") }
        let old = try McpLog.registered(stores: stores)
        if old["stale"]?.truthy == true, let name = old["name"]?.stringValue, let scope = old["scope"]?.stringValue {
            _ = try? run([claude, "mcp", "remove", name, "--scope", scope])
        }
        let ran = try run(installCommand(claude: claude))
        guard ran.status == 0 else {
            let said = Py.strip(ran.err.isEmpty ? ran.out : ran.err)
            throw Failed(said.isEmpty ? "claude mcp add failed (\(ran.status))" : said)
        }
    }

    /// `install_desktop`: adds the server to Claude Desktop as "meetings", merged into its config file: every other key
    /// and server kept, and the entry's own other keys (env); written atomically, the previous file kept as `.bak`.
    /// Claude Desktop reads it when it starts. `Failed` when the file is there but no JSON object (left alone then).
    public func installDesktop() throws {
        let path = stores.claudeDesktopConfig.path
        _ = try rewrite(path, backup: true, missingIsEmpty: true) { (config: inout JSONValue) in
            guard case .object(var top) = config else { throw Failed("\(path) is not a Claude Desktop config; not changed") }
            var servers: [(String, JSONValue)] = []
            if let i = top.firstIndex(where: { Py.same($0.0, "mcpServers") }) {
                guard case .object(let given) = top[i].1 else { throw Failed("\(path) is not a Claude Desktop config; not changed") }
                servers = given
            }
            var entry: [(String, JSONValue)] = []
            if let old = servers.first(where: { Py.same($0.0, Self.NAME) })?.1, case .object(let fields) = old { entry = fields }
            Self.set(&entry, "command", .string(executable))
            Self.set(&entry, "args", .strings(Self.serverArgs(options: options)))
            Self.set(&servers, Self.NAME, .object(entry))
            Self.set(&top, "mcpServers", .object(servers))
            config = .object(top)
            return true
        }
    }

    // MARK: - moving old entries

    /// Whether `command` is Palaver's Python: an app's `bin/python` (the one-release shim) or `palaver-python`, a
    /// runtime's python3 in Application Support, or the old installer's venv. A checkout's venv is the developer's own
    /// and stays.
    public static func isPalaverPython(_ command: String) -> Bool {
        let c = command.unicodeScalars
        func ends(_ s: String) -> Bool { c.count >= s.unicodeScalars.count && c.suffix(s.unicodeScalars.count).elementsEqual(s.unicodeScalars) }
        return ends("/Contents/Resources/bin/python") || ends("/Contents/MacOS/palaver-python")
            || McpLog.contains(command, "/Library/Application Support/palaver/runtime/")
            || McpLog.OLD_VENVS.contains { McpLog.contains(command, $0) }
    }

    /// An entry that starts Palaver's MCP server with Palaver's Python (`McpLog.isPalaver` and `isPalaverPython`).
    public static func startsPython(_ server: JSONValue) -> Bool {
        guard (try? McpLog.isPalaver(server)) == true, let command = server["command"]?.stringValue else { return false }
        return isPalaverPython(command)
    }

    /// The entry starting `executable` instead: `-m palaver` dropped from its args, its options and other keys kept.
    public func moved(_ server: JSONValue) -> JSONValue {
        guard case .object(var fields) = server else { return server }
        var args = server["args"]?.arrayValue ?? []
        if args.count >= 2, args[0].stringValue == "-m", args[1].stringValue == "palaver" { args.removeFirst(2) }
        if args.isEmpty { args = [.string("mcp")] }
        Self.set(&fields, "command", .string(executable))
        Self.set(&fields, "args", .array(args))
        return .object(fields)
    }

    /// Whether `server` is to be moved: it starts Palaver's Python, or it starts an app's `bin/palaver` that is gone (an
    /// app moved or deleted since) and is not `executable`.
    func needsMove(_ server: JSONValue) -> Bool {
        if Self.startsPython(server) { return true }
        guard (try? McpLog.isPalaver(server)) == true, let command = server["command"]?.stringValue,
              command.hasSuffix("/" + Self.CLI_IN_BUNDLE), !Py.same(command, executable) else { return false }
        return !Undo.exists(command)
    }

    /// The servers of one `mcpServers` object with every entry to move moved; nil when none was.
    func movedServers(_ servers: JSONValue?) -> JSONValue? {
        guard case .object(let fields)? = servers else { return nil }
        var changed = false
        let out: [(String, JSONValue)] = fields.map { name, server in
            guard needsMove(server) else { return (name, server) }
            changed = true
            return (name, moved(server))
        }
        return changed ? .object(out) : nil
    }

    /// Every entry that starts Palaver's Python (or an app's `bin/palaver` that is gone), in Claude Code's config (user
    /// and project servers) and Claude Desktop's, rewritten to start `executable`; nothing else is touched, and an entry
    /// already moved stays as it is. The two configs are moved independently: one that fails (`log` says why) never
    /// keeps the other from moving. Which configs changed ("code", "desktop"). A config that is missing, no JSON object,
    /// or never names Palaver is left alone (not even parsed).
    @discardableResult
    public func migrate(log: (String) -> Void = { _ in }) -> [String] {
        var moved: [String] = []
        do {
            if try rewrite(stores.claudeConfig.path, backup: false, onlyIfMentions: "palaver", change: { config in
                guard case .object(var top) = config else { return false }
                var changed = false
                if let i = top.firstIndex(where: { Py.same($0.0, "mcpServers") }), let servers = movedServers(top[i].1) {
                    top[i].1 = servers
                    changed = true
                }
                if let i = top.firstIndex(where: { Py.same($0.0, "projects") }), case .object(var projects) = top[i].1 {
                    for j in projects.indices {
                        guard case .object(var project) = projects[j].1,
                              let k = project.firstIndex(where: { Py.same($0.0, "mcpServers") }),
                              let servers = movedServers(project[k].1) else { continue }
                        project[k].1 = servers
                        projects[j].1 = .object(project)
                        changed = true
                    }
                    top[i].1 = .object(projects)
                }
                config = .object(top)
                return changed
            }) { moved.append("code") }
        } catch {
            log("Claude Code's MCP entries were not moved: \(error)")
        }
        do {
            if try rewrite(stores.claudeDesktopConfig.path, backup: true, onlyIfMentions: "palaver", change: { config in
                guard case .object(var top) = config, let i = top.firstIndex(where: { Py.same($0.0, "mcpServers") }),
                      let servers = movedServers(top[i].1) else { return false }
                top[i].1 = servers
                config = .object(top)
                return true
            }) { moved.append("desktop") }
        } catch {
            log("Claude Desktop's MCP entries were not moved: \(error)")
        }
        return moved
    }

    /// Whether `bundle` is an installed Palaver.app that Claude can start for good: in /Applications or ~/Applications
    /// (`applications`), not a copy macOS runs from a randomized place (App Translocation, a quarantined app opened where
    /// it was downloaded), and with its `bin/palaver`. A development bundle elsewhere is the developer's.
    public static func isInstalled(bundle: URL, applications: URL,
                                   isExecutable: (String) -> Bool = { access($0, X_OK) == 0 }) -> Bool {
        let path = bundle.resolvingSymlinksInPath().standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return false }
        let parent = (path as NSString).deletingLastPathComponent
        let homes = ["/Applications", applications.resolvingSymlinksInPath().standardizedFileURL.path]
        guard homes.contains(parent) else { return false }
        return isExecutable(path + "/" + CLI_IN_BUNDLE)
    }

    /// Housekeeping's part at every start: the entries moved to `bundle`'s `bin/palaver`. From a checkout (no bundle), a
    /// translocated or not installed bundle nothing is moved: Claude would start a path that goes away.
    @discardableResult
    public static func migrateAtStart(bundle: URL?, stores: StorePaths = .current(), log: (String) -> Void = { _ in },
                                      isExecutable: (String) -> Bool = { access($0, X_OK) == 0 }) -> [String] {
        guard let bundle, isInstalled(bundle: bundle, applications: stores.applications, isExecutable: isExecutable) else { return [] }
        let installed = bundle.resolvingSymlinksInPath().standardizedFileURL
        let moved = McpSetup(stores: stores, executable: installed.appendingPathComponent(CLI_IN_BUNDLE).path).migrate(log: log)
        if !moved.isEmpty {
            log("Claude's MCP entries now start the Swift server (\(moved.joined(separator: ", ")))")
        }
        return moved
    }

    // MARK: - the files

    /// How often a config Claude changed while it was rewritten is read again.
    static let REWRITE_TRIES = 5
    /// A new config file's mode (`open(…, "w")` under the usual umask).
    static let NEW_FILE_MODE: mode_t = 0o644

    /// Reads the JSON file at `path`, lets `change` change it (true: changed) and writes it back atomically: a temporary
    /// file beside the real file (a link such as a dotfiles' `~/.claude.json` is followed and stays a link), with the
    /// file's mode from the start, flushed to the disk, then renamed over it; `backup`: the previous file kept as
    /// `<name>.bak` with its mode. When the file changed in the meantime (Claude writes its config often), it starts
    /// over, so no change of Claude's is lost.
    ///
    /// Left alone: a missing file (`missingIsEmpty`: an empty object is changed and written), a file that is no JSON, one
    /// whose bytes don't hold `onlyIfMentions` (not even parsed), and one holding a lone UTF-16 surrogate escape (JSON
    /// that JavaScript writes, which a Swift string can't keep: rewriting it would change Claude's other text).
    /// `missingIsEmpty` raises `Failed` for a file that is no JSON or can't be kept, as `install_desktop` does; without
    /// it, a file that can't be kept is `Failed` too (migrate logs it), the rest returns false. Whether it was written.
    func rewrite(_ path: String, backup: Bool, missingIsEmpty: Bool = false, onlyIfMentions: String? = nil,
                 change: (inout JSONValue) throws -> Bool) throws -> Bool {
        let target = try Self.realTarget(path)
        for _ in 0..<Self.REWRITE_TRIES {
            let before = Self.stamp(target)
            let data = try McpLog.readFile(target)
            var config: JSONValue
            if let data {
                if let word = onlyIfMentions, data.range(of: Data(word.utf8)) == nil { return false }
                guard let text = String(validatingUTF8Data: data) else {
                    if missingIsEmpty { throw Failed("\(path) is not valid JSON; not changed") }
                    return false
                }
                if Self.hasLoneSurrogate(data) {
                    throw Failed("\(path) holds text Palaver can't keep exactly (a lone UTF-16 surrogate); not changed")
                }
                guard let parsed = try? PythonJSON.parse(Data(text.utf8)) else {
                    if missingIsEmpty { throw Failed("\(path) is not valid JSON; not changed") }
                    return false
                }
                config = parsed
            } else {
                guard missingIsEmpty else { return false }
                config = .object([])
            }
            guard try change(&config) else { return false }
            let dir = (target as NSString).deletingLastPathComponent
            try Undo.makedirs(dir)
            let name = (target as NSString).lastPathComponent
            let mode = before?.mode ?? Self.NEW_FILE_MODE
            let tmp = dir + "/.\(name).\(getpid()).tmp"
            defer { _ = unlink(tmp) }
            try Self.writeDurably(tmp, Array((PythonJSON.dumps(config, indent: 2, ensureAscii: false) + "\n").utf8), mode: mode)
            guard Self.stamp(target) == before else { continue }  // Claude wrote it meanwhile: read it again
            if backup, let data {
                let bak = dir + "/\(name).bak"
                let bakTmp = dir + "/.\(name).bak.\(getpid()).tmp"
                defer { _ = unlink(bakTmp) }
                try Self.writeDurably(bakTmp, Array(data), mode: mode)
                guard Darwin.rename(bakTmp, bak) == 0 else { throw Failed("\(bak): \(String(cString: strerror(errno)))") }
            }
            guard Darwin.rename(tmp, target) == 0 else { throw Failed("\(path): \(String(cString: strerror(errno)))") }
            return true
        }
        throw Failed("\(path) kept changing; not changed")
    }

    /// The file `path` names, links followed (`realpath`); `path` itself when nothing is there. A link to a file that
    /// is gone is refused: writing would replace the link.
    static func realTarget(_ path: String) throws -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        var st = stat()
        if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
            throw Failed("\(path) is a link to a file that is not there; not changed")
        }
        return path
    }

    /// `bytes` into a new file `path` created with `mode` (fchmod: the umask can't widen or narrow it), flushed to the
    /// disk (F_FULLFSYNC) before it is renamed into place.
    static func writeDurably(_ path: String, _ bytes: [UInt8], mode: mode_t) throws {
        _ = unlink(path)  // a temporary file of a run that died with this pid
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw Failed("\(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard fchmod(fd, mode) == 0 else { throw Failed("\(path): \(String(cString: strerror(errno)))") }
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + done, bytes.count - done) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw Failed("\(path): \(String(cString: strerror(errno)))") }
            done += n
        }
        if fcntl(fd, F_FULLFSYNC) != 0 { _ = fsync(fd) }  // F_FULLFSYNC is refused by some file systems
    }

    /// Whether the JSON text holds a `\uD800`–`\uDFFF` escape that is not half of a high-low pair. (Escapes appear only
    /// inside strings; `\\` is skipped as one escape, so `\\ud800` is the text it shows.)
    static func hasLoneSurrogate(_ data: Data) -> Bool {
        let b = [UInt8](data)
        func unit(at i: Int) -> UInt32? {  // the code unit of `\uXXXX` at i
            guard i + 5 < b.count, b[i] == 0x5C, b[i + 1] == 0x75 else { return nil }
            return UInt32(String(decoding: b[(i + 2)...(i + 5)], as: UTF8.self), radix: 16)
        }
        var i = 0
        while i < b.count {
            guard b[i] == 0x5C, i + 1 < b.count else { i += 1; continue }
            guard b[i + 1] == 0x75, let u = unit(at: i) else { i += 2; continue }
            if (0xDC00...0xDFFF).contains(u) { return true }  // a low half alone
            if (0xD800...0xDBFF).contains(u) {
                guard let low = unit(at: i + 6), (0xDC00...0xDFFF).contains(low) else { return true }
                i += 12
                continue
            }
            i += 6
        }
        return false
    }

    struct Stamp: Equatable {
        let mtime: timespec
        let size: off_t
        let inode: ino_t
        let mode: mode_t
        static func == (a: Stamp, b: Stamp) -> Bool {
            a.mtime.tv_sec == b.mtime.tv_sec && a.mtime.tv_nsec == b.mtime.tv_nsec && a.size == b.size && a.inode == b.inode
        }
    }

    static func stamp(_ path: String) -> Stamp? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Stamp(mtime: st.st_mtimespec, size: st.st_size, inode: st.st_ino, mode: st.st_mode & 0o7777)
    }

    /// `fields[key] = value`, keeping its place (a new key goes last), by code points.
    public static func set(_ fields: inout [(String, JSONValue)], _ key: String, _ value: JSONValue) {
        if let i = fields.firstIndex(where: { Py.same($0.0, key) }) { fields[i].1 = value } else { fields.append((key, value)) }
    }

    // MARK: - running claude

    /// Runs `argv` to its end with `env`; `Failed` when it can't start or takes longer than `timeout` s (it is killed).
    public static func runCommand(_ argv: [String], env: [String: String], timeout: Double) throws -> Ran {
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw Failed("cannot start \(argv[0]): \(error.localizedDescription)") }
        let group = DispatchGroup()
        var outData = Data(), errData = Data()
        DispatchQueue.global().async(group: group) { outData = out.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: group) { errData = err.fileHandleForReading.readDataToEndOfFile() }
        let ended = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in ended.signal() }
        if ended.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = ended.wait(timeout: .now() + 5)
            throw Failed("\((argv[0] as NSString).lastPathComponent) \(argv.dropFirst().prefix(2).joined(separator: " ")) "
                         + "took longer than \(Int(timeout)) s")
        }
        group.wait()
        return Ran(status: p.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                   err: String(decoding: errData, as: UTF8.self))
    }
}

/// The Claude Code command (notes.find_claude).
public enum ClaudeCLI {
    /// The configured one if it runs; else `claude` on PATH; else the usual install locations (apps started from
    /// Finder get a minimal PATH).
    public static func find(configured: String?, env: [String: String], home: URL) -> String? {
        if let configured, !configured.isEmpty { return access(configured, X_OK) == 0 ? configured : nil }
        let path = env["PATH"] ?? "/bin:/usr/bin"  // os.defpath
        for dir in path.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = (dir.isEmpty ? "." : String(dir)) + "/claude"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue,
               access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        for candidate in [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        where access(candidate, X_OK) == 0 {
            return candidate
        }
        return nil
    }
}
