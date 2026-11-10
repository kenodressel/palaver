// `palaver mcp` (cli.py `_cmd_mcp`, mcp_server.py `serve`): serves the meetings to one MCP client over stdio, or adds
// the server to Claude Code (`--install`) or Claude Desktop (`--install --desktop`).
//
//   palaver [--config F] [--dictionary F] [--no-notify] mcp [--install [--desktop]]
//
// While it serves, a heartbeat file says it runs (McpSession). It ends when the client closes stdin, when the client
// is gone (its parent changed: checked every 5 s), or on SIGTERM/SIGHUP (exit 128 + the signal); the heartbeat goes
// each time. The protocol writes to its own copy of stdout; fd 1 is stderr while it serves. The `palaver` command of phase 4 batch 8 runs this as its `mcp` subcommand.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

public enum McpMain {
    public static let usage = "usage: palaver [--config F] [--dictionary F] [--no-notify] mcp [--install [--desktop]]"

    public struct Options: Equatable {
        public var config: String?
        public var dictionary: String?
        public var noNotify = false
        public var install = false
        public var desktop = false
    }

    public struct UsageError: Error, CustomStringConvertible {
        public let description: String
    }

    /// The global options, then `mcp` and its own.
    public static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var i = 0
        var command = false
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw UsageError(description: "\(flag) needs a value") }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--config" where !command: o.config = try value(a)
            case "--dictionary" where !command: o.dictionary = try value(a)
            case "--no-notify" where !command: o.noNotify = true
            case _ where !command && a.hasPrefix("--config="): o.config = String(a.dropFirst("--config=".count))
            case _ where !command && a.hasPrefix("--dictionary="): o.dictionary = String(a.dropFirst("--dictionary=".count))
            case "mcp" where !command: command = true
            case "--install" where command: o.install = true
            case "--desktop" where command: o.desktop = true
            default: throw UsageError(description: command ? "unknown argument: \(a)" : "no command \(a) in this build (only mcp)")
            }
            i += 1
        }
        guard command else { throw UsageError(description: "no command given") }
        if o.desktop && !o.install { throw UsageError(description: "--desktop goes with --install") }
        return o
    }

    /// `forwarded_cli_options`: the options Claude starts the server with, the config's path made absolute.
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

    /// The tools over the recordings and stores of `o` and `env` (the server's domain, no HTTP, no calendar).
    public static func makeTools(_ o: Options, env: [String: String]) -> McpTools {
        let stores = StorePaths.current(env: env)
        let configURL = o.config.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? stores.configToml
        let config = Config.load(configURL, environment: env)
        let app = ServerApp(outputDir: config.outputDir, userName: config.userName, config: config, stores: stores,
                            cliOptions: forwarded(o), calendar: nil, openURL: { _ in })
        return McpTools(app: app, userName: config.userName)
    }

    /// The whole command; the exit code.
    public static func run(_ args: [String], env: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        let o: Options
        do {
            o = try parse(args)
        } catch {
            FileHandle.standardError.write(Data("\(usage)\npalaver: \(error)\n".utf8))
            return 2
        }
        signal(SIGPIPE, SIG_IGN)  // a client gone mid-answer: the write fails instead
        if o.install { return install(o, env: env) }
        return serve(o, env: env)
    }

    static func install(_ o: Options, env: [String: String]) -> Int32 {
        let stores = StorePaths.current(env: env)
        let setup = McpSetup(stores: stores, executable: McpSetup.executable(), options: forwarded(o), env: env)
        do {
            if o.desktop {
                try setup.installDesktop()
                print("Added \"meetings\" to \(stores.claudeDesktopConfig.path) (the previous file is kept as .bak).\n"
                      + "Quit and reopen Claude Desktop to use it.")
            } else {
                print(setup.installCommand().joined(separator: " "))
                try setup.install()
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Not added to \(o.desktop ? "Claude Desktop" : "Claude Code"): \(error)\n".utf8))
            return 1
        }
    }

    /// `PALAVER_TEST_STRAY_PRINT` (debug builds only): prints a line to stdout once serving, as a library might.
    public static let TEST_STRAY_PRINT = "PALAVER_TEST_STRAY_PRINT"

    /// The protocol's own copy of stdout; fd 1 then points at stderr, so a stray print (of a library, or ours) can never
    /// put a line into the JSON-RPC stream. -1 when it can't be made (the protocol then stays on fd 1).
    static func takeStdout() -> Int32 {
        let proto = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 3)
        guard proto >= 0 else { return STDOUT_FILENO }
        fflush(stdout)
        guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            close(proto)
            return STDOUT_FILENO
        }
        return proto
    }

    /// `serve`: one client over stdio until it lets go.
    static func serve(_ o: Options, env: [String: String]) -> Int32 {
        let output = takeStdout()
        let tools = makeTools(o, env: env)
        let session = McpSession(stores: tools.app.stores)
        let version = AppLocation(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).version()
        let server = McpServer(tools: tools, session: session, version: version == "?" ? "" : version)
        session.start()
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                session.stop()
                _exit(128 + sig)
            }
            source.resume()
            sources.append(source)
        }
        session.watchParent()
        #if DEBUG
        if let stray = env[TEST_STRAY_PRINT], !stray.isEmpty {
            print(stray)
            fflush(stdout)
        }
        #endif
        server.serve(output: output)
        session.stop()
        withExtendedLifetime(sources) {}
        return 0
    }
}
