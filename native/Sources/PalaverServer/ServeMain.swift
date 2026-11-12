// `palaver-server`, the port of `palaver webapp-serve` (cli.py:193-204, webapp/process.py:338-409):
// the window's server until SIGTERM or until the app is gone (its stdin, a pipe from the app, closes).
//
//   palaver-server [--config F] [--dictionary F] [--no-notify] (--listen-fd N --ready-fd M | --port P)
//                  [--app-socket P] [--static DIR]
//
// The key is $PALAVER_WEB_KEY (the app's), else a new one (debug builds: none with $PALAVER_TEST_NO_KEY).
// --app-socket names the app's socket (else Application Support's app.sock). With --port it binds 127.0.0.1:P itself
// (0: any free port) and prints `Open http://127.0.0.1:PORT/?key=…` first. With --ready-fd it writes
// `ready\n` there once it serves, then closes it. On the way out it lets the changes being made
// finish (DRAIN_SECONDS).
import Darwin
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

public enum ServeMain {
    /// `process.KEY_ENV`.
    public static let KEY_ENV = "PALAVER_WEB_KEY"
    /// `process.DRAIN_SECONDS`: how long a stopping server lets the changes being made finish.
    public static let DRAIN_SECONDS = 60.0

    public struct Options: Equatable {
        public var config: String?
        public var dictionary: String?
        public var noNotify = false
        public var listenFD: Int32?
        public var readyFD: Int32?
        public var port: Int?
        public var appSocket: String?
        public var staticDir: String?
    }

    public struct UsageError: Error, CustomStringConvertible {
        public let description: String
    }

    public static let usage = "usage: palaver-server [--config F] [--dictionary F] [--no-notify] "
        + "(--listen-fd N --ready-fd M | --port P) [--app-socket P] [--static DIR]"

    public static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw UsageError(description: "\(flag) needs a value") }
            return args[i]
        }
        func number(_ flag: String) throws -> Int {
            let v = try value(flag)
            guard let n = Int(v), n >= 0 else { throw UsageError(description: "\(flag): not a number: \(v)") }
            return n
        }
        while i < args.count {
            switch args[i] {
            case "--config": o.config = try value("--config")
            case "--dictionary": o.dictionary = try value("--dictionary")
            case "--no-notify": o.noNotify = true
            case "--listen-fd": o.listenFD = Int32(try number("--listen-fd"))
            case "--ready-fd": o.readyFD = Int32(try number("--ready-fd"))
            case "--port": o.port = try number("--port")
            case "--app-socket": o.appSocket = try value("--app-socket")
            case "--static": o.staticDir = try value("--static")
            default: throw UsageError(description: "unknown argument: \(args[i])")
            }
            i += 1
        }
        if (o.listenFD == nil) == (o.port == nil) { throw UsageError(description: "either --listen-fd or --port") }
        if o.listenFD != nil && o.readyFD == nil { throw UsageError(description: "--listen-fd goes with --ready-fd") }
        if o.port.map({ $0 > 65535 }) ?? false { throw UsageError(description: "--port: not a port") }
        return o
    }

    /// `forwarded_cli_options`: the global options for what the server starts, paths made absolute.
    static func forwarded(_ o: Options) -> [String] {
        func absolute(_ p: String) -> String {
            URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        }
        var out: [String] = []
        if let c = o.config { out += ["--config", absolute(c)] }
        if let d = o.dictionary { out += ["--dictionary", absolute(d)] }
        if o.noNotify { out.append("--no-notify") }
        return out
    }

    /// `secrets.token_urlsafe(32)`: 32 random bytes, base64url without padding.
    static func newKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The server's app for `options` (webapp/__init__.py `build_app`).
    static func makeApp(_ o: Options, env: [String: String], log: SessionLog? = nil) -> ServerApp {
        let stores = StorePaths.current(env: env)
        let configURL = o.config.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? stores.configToml
        let config = Config.load(configURL, environment: env)
        var calendar: CalendarProvider?
        if config.calendarEnabled {
            calendar = { start, end in
                let kit = EventKitCalendar()
                return kit.hasAccess() ? try kit.eventsBetween(start, end) : []
            }
        }
        #if DEBUG
        // The parity harness's fake calendar (its side's events.json) instead of this Mac's: the events that overlap
        // the window asked for, as EventKit answers.
        if let file = env["PALAVER_TEST_CALENDAR"] {
            let events = (PythonJSON.read(URL(fileURLWithPath: file))?.arrayValue ?? []).compactMap { try? CalendarEvent(json: $0) }
            calendar = { start, end in events.filter { $0.start.date < end && $0.end.date > start } }
        }
        #endif
        let remoteLog: (String) -> Void = { log?.message($0, logger: "palaver.webapp.remote") }
        // The app's socket: `--app-socket` (the end-to-end tests' fake app), else the one in Application Support.
        let recording = o.appSocket.map {
            Remote(statePath: stores.daemonJson, socketPath: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath),
                   log: remoteLog)
        } ?? Remote(stores: stores, log: remoteLog)
        // The language model's helpers (`write_notes`, `run_projects`, `ask_model`); the routes answer 503 without
        // `[notes].enabled`.
        // palaver-lm: $PALAVER_LM_BIN, else the one beside this program.
        let lm = AppLocation.languageModelWorker(beside: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                                                 environment: env)
        let helpers = AppHelperRunner(outputDir: config.outputDir, recording: recording, cliOptions: forwarded(o), lm: lm) {
            log?.message($1, level: $0, logger: "palaver.webapp")
        }
        let nextQuestion = LMNextQuestion(outputDir: config.outputDir, lm: lm, cliOptions: forwarded(o), recording: recording)
        // The provider actions, all in this process.
        let keys = KeyStores.make(env: env)
        let provider = Providers(configURL: configURL, stores: stores, keys: keys, env: env)
        var probe: SetupProbe = MacProbe(stores: stores, outputDir: config.outputDir, config: config,
                                         recording: recording, calendar: calendar, notifyState: env["PALAVER_NOTIFY_STATE"], env: env,
                                         hfToken: { Tokens.huggingFace(configToml: configURL, env: env, keys: keys, home: stores.home) })
        // Report a Problem: the zip written here, in this process (report.py's work, in Swift). Its doctor finds a
        // Notion token only the Keychain holds, and every secret the Keychain holds is scrubbed from the zip.
        var reportProbe: () -> ReportProbe = {
            MacReportProbe(stores: stores, env: env, doctorProbe: doctorProbe(stores: stores, env: env, keys: keys))
        }
        var reveal = SwiftReport.showInFinder
        #if DEBUG
        // The end-to-end tests' Mac (hardware, permissions, downloads, events) instead of this one; their report asks
        // this Mac nothing and shows the zip only in `$PALAVER_TEST_REVEALED`.
        if let test = TestProbe.fromEnvironment(env, stores: stores, keys: keys) {
            probe = test
            reportProbe = { QuietReportProbe() }
        }
        if let file = env[TEST_REVEALED], !file.isEmpty { reveal = { ServerApp.appendLine(file, $0.path) } }
        #endif
        let report = SwiftReport(place: Report.Place(stores: stores, configURL: configURL, outputDir: config.outputDir, env: env,
                                                     keychainSecrets: { ReportSecrets.keychain(keys) }),
                                 probe: reportProbe, reveal: reveal)
        let app = ServerApp(outputDir: config.outputDir,
                            userName: SettingsFile.currentUserName(default: config.userName, stores: stores),
                            config: config, stores: stores, cliOptions: forwarded(o),
                            staticDir: o.staticDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ServerApp.defaultStaticDir,
                            freeMemoryGB: ServerApp.freeMemory(env: env), recording: recording, calendar: calendar, probe: probe,
                            helpers: helpers, nextQuestion: nextQuestion, provider: provider, report: report,
                            openURL: ServerApp.opener(env: env), notifyState: env["PALAVER_NOTIFY_STATE"],
                            accessibilityState: env["PALAVER_AX_STATE"])
        // Claude's MCP entries start `bin/palaver` with these options; `claude` is looked up in this environment.
        app.mcpSetup = McpSetup(stores: stores, executable: McpSetup.executable(), options: forwarded(o), env: env)
        #if DEBUG
        // The end-to-end tests' Claude Desktop (a folder of their own) instead of this Mac's /Applications/Claude.app.
        if let desktop = env[TEST_CLAUDE_DESKTOP], !desktop.isEmpty { app.claudeDesktopApp = URL(fileURLWithPath: desktop, isDirectory: true) }
        #endif
        return app
    }

    /// The doctor's Mac with the server's key store: a Notion token only the Keychain holds counts, after
    /// $NOTION_TOKEN and config.toml's (config.py `_token`'s order; `Doctor.notionToken`), read only when it is needed.
    static func doctorProbe(stores: StorePaths, env: [String: String], keys: KeyStore) -> MacDoctorProbe {
        MacDoctorProbe(stores: stores, env: env, keychain: { (try? keys.read(Tokens.NOTION)) ?? nil })
    }

    /// `PALAVER_TEST_CLAUDE_DESKTOP` (debug builds only): where Claude Desktop counts as installed.
    public static let TEST_CLAUDE_DESKTOP = "PALAVER_TEST_CLAUDE_DESKTOP"

    /// `PALAVER_TEST_REVEALED` (debug builds only): the file each report zip shown in Finder is written to instead.
    public static let TEST_REVEALED = "PALAVER_TEST_REVEALED"

    /// `PALAVER_TEST_NO_KEY` (debug builds only): set and not empty, the server asks for no key, as the end-to-end
    /// tests' Python server did (`make_server(app, key=None)`); `$PALAVER_WEB_KEY` is ignored then.
    public static let TEST_NO_KEY = "PALAVER_TEST_NO_KEY"

    /// The key the window signs in with: `$PALAVER_WEB_KEY` (the app's), else a new one; nil (no key asked) only for
    /// `PALAVER_TEST_NO_KEY` in a debug build.
    static func serverKey(_ env: [String: String]) -> String? {
        #if DEBUG
        if let none = env[TEST_NO_KEY], !none.isEmpty { return nil }
        #endif
        return env[KEY_ENV].flatMap { $0.isEmpty ? nil : $0 } ?? newKey()
    }

    /// The whole run; the exit code.
    public static func run(_ args: [String], env: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        let o: Options
        do {
            o = try parse(args)
        } catch {
            FileHandle.standardError.write(Data("\(usage)\npalaver-server: \(error)\n".utf8))
            return 2
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        signal(SIGPIPE, SIG_IGN)  // as in Python: a write to a closed pipe (the ready fd, stdout) fails instead
        let stores = StorePaths.current(env: env)
        try? FileManager.default.createDirectory(at: stores.logs, withIntermediateDirectories: true)
        let log = SessionLog(url: stores.logs.appendingPathComponent("daemon.log"), logger: "palaver.webapp")
        log.event("webapp_start")

        let app = makeApp(o, env: env, log: log)
        let key = serverKey(env)
        let server = HTTPServer(app: app, key: key, log: log)
        let port: Int
        do {
            port = try o.listenFD.map { try server.start(listenFD: $0) } ?? server.start(port: o.port ?? 0)
        } catch {
            log.message("the window's server could not start: \(error)", level: "ERROR")
            FileHandle.standardError.write(Data("palaver-server: \(error)\n".utf8))
            return 1
        }

        let stopped = DispatchSemaphore(value: 0)
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        term.setEventHandler { stopped.signal() }
        term.resume()
        if o.listenFD != nil && isatty(0) == 0 {
            watchParent { stopped.signal() }  // the app is gone: finish the changes, then go
        }
        started(app, log: log, port: port, url: o.listenFD == nil ? Auth.withKey("http://127.0.0.1:\(port)/", key: key) : nil,
                readyFD: o.readyFD)

        stopped.wait()
        server.shutdown()  // no new requests; the queued ones wait for the next server
        if !server.waitIdle(timeout: DRAIN_SECONDS) {
            log.message("the window's server stops with \(app.inflight.count) change(s) unfinished", level: "WARNING")
        }
        return 0
    }

    /// Once the server listens (process.py `serve`): the search warming starts (so its thread exists when the app reads
    /// the ready line), the log line, the address for a server started by hand, the ready line, then the sweep, the
    /// glossary's warm-up and a missing speech model's download (after it: they never delay it). `warmClock`: how the
    /// warming waits.
    static func started(_ app: ServerApp, log: SessionLog?, port: Int, url: String?, readyFD: Int32?,
                        warmClock: @escaping (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        // The first search after a start reads every meeting: do that before it is asked, a little later and never
        // during a recording (#46).
        app.background.startWarming(clock: warmClock)
        log?.message("the window's server (pid \(getpid())) serves on port \(port)")
        if let url { print("Open \(url)") }
        if let fd = readyFD {
            let ready = Array("ready\n".utf8)
            _ = ready.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            close(fd)
        }
        app.background.afterReady()
        let speech = Thread { fetchSpeech(app) }
        speech.name = "speech-models"
        speech.start()
    }

    /// `exit_when_parent_gone`: `stop` once stdin (a pipe from the menu bar app) closes.
    @discardableResult
    static func watchParent(fd: Int32 = 0, _ stop: @escaping () -> Void) -> Thread {
        let t = Thread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
            }
            stop()
        }
        t.name = "parent-watch"
        t.start()
        return t
    }
}
