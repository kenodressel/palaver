// The `palaver` command (cli.py), in Swift: Palaver.app's `Contents/Resources/bin/palaver`, which install.sh links to
// `~/.local/bin/palaver` (SwiftPM builds it as `palaver-cli`).
//
//   palaver [--config FILE] [--dictionary FILE] [--no-notify] <command> …
//
// The pipeline's commands start the app's own programs in this process's place with the same options: `process`,
// `run`, `index` and `sync` palaver-worker, `notes` and `projects` palaver-lm. The others run here, on the domain the
// window's server uses: `list`, `export`, `import`, `voices`, `prune`, `doctor`, `report create`, `daemon status`,
// `app …`, `mcp`. What talks to the running app goes through app.sock and daemon.json, as cli.py did.
//
// The commands of earlier versions that the app or the window does now (`record`, `rename`, `daemon` (run), `menubar`,
// `live`, …) print one line saying what replaces them and exit 2, as a usage error does.
import Darwin
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

public enum CLIMain {
    /// What a run reads, writes and starts; the real ones by default, fakes in the tests.
    public struct Context {
        public var env: [String: String]
        public var stores: StorePaths
        /// This program (where the bundle or the checkout is, and so palaver-worker and palaver-lm).
        public var executable: URL
        public var cwd: URL
        /// A line on stdout, a line on stderr.
        public var out: (String) -> Void = { print($0) }
        public var err: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        /// Whether a person typed this (stdin is a terminal): the usage log's `by`, and whether a question is asked.
        public var interactive: Bool = isatty(0) != 0
        /// A yes-or-no question on the terminal (`_ask`); no without one.
        public var ask: ((String) -> Bool)?
        public var readInput: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }
        /// Starts `argv` in this process's place (execv); returns only when it could not (the exit code then).
        public var exec: ([String]) -> Int32 = CLIMain.execReplacing
        /// Runs `argv` with this terminal (make, ditto), in `dir` when given; its exit status.
        public var run: ([String], URL?) -> Int32 = CLIMain.runAttached
        /// The app's socket (app.sock).
        public var appSocket: URL
        public var doctorProbe: () -> DoctorProbe
        public var reportProbe: () -> ReportProbe
        /// Shows a report zip in Finder.
        public var reveal: (URL) -> Void = SwiftReport.showInFinder
        /// Quits the app of this name (`osascript … to quit`).
        public var quitApp: (String) -> Void = CLIMain.quitWithAppleScript
        public var keys: () -> KeyStore

        public init(env: [String: String], stores: StorePaths, executable: URL, cwd: URL) {
            self.env = env
            self.stores = stores
            self.executable = executable
            self.cwd = cwd
            appSocket = stores.appSock
            let keys = { KeyStores.make(env: env) }
            self.keys = keys
            let doctor = { MacDoctorProbe(stores: stores, env: env, keychain: { (try? keys().read(Tokens.NOTION)) ?? nil }) as DoctorProbe }
            doctorProbe = doctor
            reportProbe = { MacReportProbe(stores: stores, env: env, doctorProbe: doctor()) }
            ask = { question in
                guard isatty(0) != 0 else { return false }
                FileHandle.standardOutput.write(Data("\(question) [y/N] ".utf8))
                let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                return ["y", "yes", "j", "ja"].contains(answer)
            }
        }

        /// This process: its environment, the stores it names, its executable and working folder.
        public static func current(env: [String: String] = ProcessInfo.processInfo.environment) -> Context {
            var ctx = Context(env: env, stores: StorePaths.current(env: env),
                              executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                              cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            #if DEBUG
            // The tests' Finder: each zip shown is a line in this file (as the window's server's).
            if let file = env[ServeMain.TEST_REVEALED], !file.isEmpty { ctx.reveal = { ServerApp.appendLine(file, $0.path) } }
            // The tests' Mac: the report and the doctor ask this Mac nothing.
            if let quiet = env[TEST_QUIET_MAC], !quiet.isEmpty {
                ctx.reportProbe = { QuietReportProbe() }
                ctx.doctorProbe = { QuietDoctorProbe() }
            }
            #endif
            return ctx
        }
    }

    #if DEBUG
    /// `PALAVER_TEST_QUIET_MAC` (debug builds only): set and not empty, `report` and `doctor` ask this Mac nothing.
    public static let TEST_QUIET_MAC = "PALAVER_TEST_QUIET_MAC"
    #endif

    public static let USAGE = "usage: palaver [--config FILE] [--dictionary FILE] [--no-notify] <command> …"

    /// The global options (cli.py's), as given; forwarded to palaver-worker and palaver-lm.
    public struct Globals: Equatable {
        public var config: String?
        public var dictionary: String?
        public var noNotify = false

        public var forwarded: [String] {
            (config.map { ["--config", $0] } ?? []) + (dictionary.map { ["--dictionary", $0] } ?? []) + (noNotify ? ["--no-notify"] : [])
        }
    }

    /// The whole command; the exit code.
    public static func run(_ args: [String], env: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        return run(args, Context.current(env: env))
    }

    public static func run(_ args: [String], _ ctx: Context) -> Int32 {
        var globals = Globals()
        var i = 0
        func usageError(_ message: String) -> Int32 {
            ctx.err(USAGE)
            ctx.err("palaver: error: \(message)")
            return 2
        }
        while i < args.count, args[i].hasPrefix("-") {
            let a = args[i]
            i += 1
            switch a {
            case "-h", "--help":
                ctx.out(help)
                return 0
            case "--config", "--dictionary":
                guard i < args.count else { return usageError("argument \(a): expected one argument") }
                if a == "--config" { globals.config = args[i] } else { globals.dictionary = args[i] }
                i += 1
            case "--no-notify": globals.noNotify = true
            case _ where a.hasPrefix("--config="): globals.config = String(a.dropFirst("--config=".count))
            case _ where a.hasPrefix("--dictionary="): globals.dictionary = String(a.dropFirst("--dictionary=".count))
            default: return usageError("unrecognized arguments: \(a)")
            }
        }
        guard i < args.count else { return usageError("the following arguments are required: command") }
        let name = args[i]
        let rest = Array(args[(i + 1)...])
        if let pointer = replaced(name, rest) {
            ctx.err(pointer)
            return 2
        }
        guard let spec = commands.first(where: { $0.name == name }) else {
            return usageError("unknown command '\(name)' (palaver --help lists them)")
        }
        let parsed: CLIParsed
        do {
            parsed = try spec.parse(rest)
        } catch is CLIHelpAsked {
            ctx.out(spec.help)
            return 0
        } catch {
            ctx.err(spec.usage)
            ctx.err("palaver \(name): error: \(error)")
            return 2
        }
        let command = CLICommand(name: name, args: rest, parsed: parsed, globals: globals, ctx: ctx)
        if !forwardedCommands.contains(name) {  // palaver-worker and palaver-lm count their own
            Usage.record("cli", name, fields: [("by", .string(ctx.interactive ? "user" : "app")),
                                               ("action", (parsed.one("action") ?? defaultActions[name]).map { .string($0) } ?? .null)],
                         path: ctx.stores.usage)
        }
        return command.run()
    }

    // MARK: - the commands

    /// The commands it has, in the order `palaver --help` lists them.
    static let commands: [CLISpec] = [
        CLISpec(name: "list", summary: "Show all recording folders with status"),
        CLISpec(name: "process", summary: "Transcribe + diarize + merge an existing folder",
                args: [CLIArg(name: "folder", help: "the recording folder")],
                opts: [CLIOpt(names: ["--no-notes"], help: "Leave the notes for later (the app writes them when no call is recorded)")]),
        CLISpec(name: "run", summary: "process + sync", args: [CLIArg(name: "folder", help: "the recording folder")]),
        CLISpec(name: "notes", summary: "Write the meeting notes (summary, next steps, decisions) with the language model",
                args: [CLIArg(name: "folder", help: "the recording folder")],
                opts: [CLIOpt(names: ["--force"], help: "Rewrite even if up to date")]),
        CLISpec(name: "projects", summary: "Sort meetings into projects, or describe a project, with the notes model",
                args: [CLIArg(name: "action", help: "suggest or describe", choices: ["suggest", "describe"]),
                       CLIArg(name: "target", help: "suggest: one recording folder (default: all in no project); describe: a "
                              + "project id (default: all without a description)", count: .optional)],
                opts: [CLIOpt(names: ["--no-wait"], help: "Exit 75 at once when another run is using the model")]),
        CLISpec(name: "index", summary: "Index meetings for search by meaning",
                args: [CLIArg(name: "folders", help: "Only these recordings (default: all without a current index)", count: .many)]),
        CLISpec(name: "sync", summary: "Upload transcript to Notion", args: [CLIArg(name: "folder", help: "the recording folder")]),
        CLISpec(name: "export", summary: "Save a meeting as a .zip to send to a colleague",
                args: [CLIArg(name: "meeting", help: "the meeting's id (its folder name) or folder")],
                opts: [CLIOpt(names: ["--notes"], help: "Include the notes (default: yes)", negatable: true),
                       CLIOpt(names: ["--voices"], help: "Include the voices of the people named (biometric data; default: no)"),
                       CLIOpt(names: ["--audio"], help: "Include the audio (default: no)"),
                       CLIOpt(names: ["-o", "--output"], value: "FILE", help: "The file to write (default: '<date> <title>.zip' here)"),
                       CLIOpt(names: ["--yes"], help: "Export a meeting kept on this Mac without asking")]),
        CLISpec(name: "import", summary: "Import a meeting a colleague exported (its .zip)",
                args: [CLIArg(name: "file", help: "the .zip")],
                opts: [CLIOpt(names: ["--separate"], help: "When the meeting is here already, import it beside it without asking")]),
        CLISpec(name: "voices", summary: "List stored voices used for speaker recognition, or forget one",
                args: [CLIArg(name: "action", help: "list (the default) or forget", count: .optional, choices: ["list", "forget"]),
                       CLIArg(name: "name", help: "forget: whose voice", count: .optional)]),
        CLISpec(name: "prune", summary: "Delete synced recordings older than [recording].retention_days",
                opts: [CLIOpt(names: ["--dry-run"], help: "Only show what would be deleted"),
                       CLIOpt(names: ["--include-unsynced"], help: "Also delete old recordings that were never uploaded to Notion")]),
        CLISpec(name: "doctor", summary: "Check setup and permissions, say what to fix",
                opts: [CLIOpt(names: ["--offline"], help: "Skip the Notion API check")]),
        CLISpec(name: "report", summary: "Report a problem: one zip on the Desktop with everything to analyse it",
                args: [CLIArg(name: "action", help: "create", choices: ["create"])],
                opts: [CLIOpt(names: ["--meeting"], value: "ID", help: "The meeting it is about (default: the latest; \"none\": no meeting)"),
                       CLIOpt(names: ["--audio"], help: "Include that meeting's audio (large)"),
                       CLIOpt(names: ["-m", "--message"], value: "TEXT", help: "What happened"),
                       CLIOpt(names: ["--wish"], help: "A wish, not a bug"),
                       CLIOpt(names: ["--json"], help: "The window's report: the form as JSON on stdin, one JSON line out (the only output)")],
                description: "Writes the report zip to the Desktop and shows it in Finder."),
        CLISpec(name: "daemon", summary: "Show what the app does: records, transcribes or waits for a call",
                args: [CLIArg(name: "action", help: "status", choices: ["status"])]),
        CLISpec(name: "app", summary: "Install Palaver.app in ~/Applications; restart-web: restart only the window's server; "
                + "ping: whether the running app answers",
                args: [CLIArg(name: "action", help: "install (the default), uninstall, autostart, restart-web or ping", count: .optional,
                              choices: ["install", "uninstall", "autostart", "restart-web", "ping"]),
                       CLIArg(name: "state", help: "on|off for autostart", count: .optional)],
                opts: [CLIOpt(names: ["--login"], help: "Start the app at login"),
                       CLIOpt(names: ["--store-tokens"], help: "Copy NOTION_TOKEN/HF_TOKEN from this shell into the login Keychain")],
                description: "From a checkout, install builds the app with the Makefile (make app) and puts it in ~/Applications."),
        CLISpec(name: "mcp", summary: "Serve meetings, notes, projects and people to Claude (MCP, stdio)",
                opts: [CLIOpt(names: ["--install"], help: "Add this server to Claude Code (claude mcp add)"),
                       CLIOpt(names: ["--desktop"], help: "With --install: add it to Claude Desktop (claude_desktop_config.json) instead")]),
    ]

    /// The action a command does without one (argparse's defaults), as the usage log names it.
    static let defaultActions = ["app": "install", "voices": "list"]

    /// The commands that start palaver-worker or palaver-lm.
    static let forwardedCommands: Set<String> = ["process", "run", "index", "sync", "notes", "projects"]

    /// The commands' names (the usage catalog's "cli" kind: `Usage.CLI_COMMANDS`).
    public static var commandNames: [String] { commands.map(\.name).sorted() }

    /// `palaver --help`.
    static var help: String {
        let width = commands.map { $0.name.count }.max()! + 2
        var lines = [USAGE, "", "Palaver from a terminal: the app's recordings, notes and setup.", "", "commands:"]
        for c in commands { lines.append("  " + c.name.padding(toLength: width, withPad: " ", startingAt: 0) + c.summary) }
        lines += ["", "options:",
                  "  -h, --help           show this help and exit",
                  "  --config FILE        Path to config.toml (defaults to ~/.config/palaver/config.toml)",
                  "  --dictionary FILE    Path to a dictionary.toml for this run, e.g. a meeting-type vocabulary "
                      + "(defaults to ~/.config/palaver/dictionary.toml)",
                  "  --no-notify          Don't show macOS notifications when a transcript is ready or a step fails",
                  "",
                  "`palaver <command> --help` describes one. The commands of earlier versions that the app does now",
                  "(record, rename, daemon without status, menubar, …) say what replaces them."]
        return lines.joined(separator: "\n")
    }

    // MARK: - what replaces the commands of earlier versions

    static let byTheApp = "the app runs it itself now (palaver-worker)"
    /// The developer tools of the Python app, removed with it in 0.6.0 (they stay in the repository's history).
    static let removedTool = "is gone: it was a developer tool of the Python app, removed in 0.6.0"

    /// The one line for a command (or `app`/`daemon`/`report`/`calendar` action) of earlier versions; nil for one it has.
    static func replaced(_ name: String, _ rest: [String]) -> String? {
        let action = rest.first { !$0.hasPrefix("-") }
        switch name {
        case "record": return "palaver record is gone: Palaver.app records (its menu: Start recording now; calls on their own)."
        case "rename": return "palaver rename is gone: name the speakers in the Meetings window (click a speaker's name)."
        case "bench", "bench-live":
            return "palaver \(name) \(removedTool)."
        case "next-question": return "palaver next-question is gone: the Meetings window asks for the next question (palaver-lm)."
        case "live", "stream", "coach", "cloud-transcribe": return "palaver \(name) is gone: \(byTheApp)."
        case "menubar": return "palaver menubar is gone: Palaver.app is the menu bar app (open it, or `palaver app install` from a checkout)."
        case "webapp-serve":
            return "palaver webapp-serve is gone: the app starts the window's server (palaver-server); `palaver app restart-web` restarts it."
        case "onboarding": return "palaver onboarding is gone: the setup assistant in the Meetings window does it."
        case "provider": return "palaver provider is gone: Settings → Language Model and Transcription in the Meetings window do it."
        case "calendar": return "palaver calendar is gone: the app gives recordings their calendar events itself."
        case "daemon" where action == nil || action == "run":
            return "palaver daemon (run) is gone: Palaver.app watches for calls; `palaver daemon status` says what it does."
        case "app":
            switch action {
            case "query": return "palaver app query is gone: \(byTheApp)."
            case "housekeeping": return "palaver app housekeeping is gone: the app does its housekeeping itself."
            case "update": return "palaver app update is gone: the app updates itself (its menu: Check for Updates…)."
            case "uninstall-start": return "palaver app uninstall-start is gone: Settings → Updates → Uninstall Palaver… does it."
            default: return nil
            }
        case "report" where action == "open" || action == "usage":
            return "palaver report \(action!) \(removedTool)."
        default: return nil
        }
    }

    // MARK: - the real ones

    /// execv in this process's place; returns only when that failed.
    public static let execReplacing: ([String]) -> Int32 = { argv in
        fflush(stdout)
        fflush(stderr)
        signal(SIGPIPE, SIG_DFL)  // an ignored signal stays ignored across exec: the program starts as on its own
        var cargs = argv.map { strdup($0) } + [nil]
        execv(argv[0], &cargs)
        let reason = String(cString: strerror(errno))
        for p in cargs { free(p) }
        FileHandle.standardError.write(Data("palaver: error: cannot start \(argv[0]): \(reason)\n".utf8))
        return 1
    }

    /// Runs `argv` with this terminal's stdin, stdout and stderr; its exit status (127 when it cannot start).
    public static let runAttached: ([String], URL?) -> Int32 = { argv, dir in
        fflush(stdout)
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        if let dir { p.currentDirectoryURL = dir }
        do { try p.run() } catch { return 127 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// `osascript -e 'tell application "<name>" to quit'` (app_bundle `_quit_and_remove`).
    public static let quitWithAppleScript: (String) -> Void = { name in
        _ = runAttachedQuietly(["/usr/bin/osascript", "-e", "tell application \"\(name)\" to quit"])
    }

    static func runAttachedQuietly(_ argv: [String]) -> Int32 {
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return 127 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

#if DEBUG
/// The doctor's Mac in the tests of the built command (`PALAVER_TEST_QUIET_MAC`): fixed answers, nothing asked of this
/// Mac or the network.
struct QuietDoctorProbe: DoctorProbe {
    func macOSVersion() -> String { "15.1" }
    func httpStatus(_ url: String, headers: [String: String]) throws -> Int { throw URLError(.notConnectedToInternet) }
    func keychainNotionToken() -> String? { nil }
    func engineHello() throws -> JSONValue? { .object([("models", .object([("asr", .bool(true)), ("diarizer", .bool(true))]))]) }
    func speechFilesHere() -> Bool { true }
    var inBundle: Bool { true }
    func microphoneStatus() -> Int { 3 }
    func defaultDevices() throws -> (input: (String, Double)?, output: (String, Double)?) {
        (("Test Mic", 48000), ("Test Speakers", 48000))
    }
    func audioProcesses() throws -> [AudioProcess] { [] }
    func teamsInstalled() -> Bool { true }
    func freeBytes(_ url: URL) -> Int { 100 << 30 }
    func ramGB() -> Double { 16 }
    func runningMemory() -> JSONValue? { nil }
}
#endif
