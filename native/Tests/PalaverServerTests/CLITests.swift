// The `palaver` command (CLIMain) in this process, on temporary homes, config dirs and recordings, with a fake app
// socket, a fake Finder and fakes for palaver-worker and palaver-lm (what they were started with): its arguments per
// command, the commands that run here, the pointers of the commands of earlier versions, and the tests of
// tests/test_cli.py and tests/test_report_cli.py that define the command's behaviour, under their names. Never the
// real home, app or socket; synthetic people only (Timo, Valerie, Rico).
import Darwin
import Foundation
import Testing
import PalaverCloud
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"

/// One temporary world for the command: home, config dir, recordings, config.toml (pointing at them), and what the
/// command said, asked and started.
private final class CLI {
    let dir = shortFolder()
    let stores: StorePaths
    let recordings: URL
    let config: URL
    var ctx: CLIMain.Context
    var out: [String] = []
    var err: [String] = []
    var started: [[String]] = []
    var startedExit: Int32 = 0
    var answers: [Bool] = []
    var asked: [String] = []
    var revealed: [URL] = []
    var quit: [String] = []
    var input = Data()

    init(configText: String? = nil, env more: [String: String] = [:]) {
        stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                            home: dir.appendingPathComponent("home", isDirectory: true))
        recordings = dir.appendingPathComponent("home/Meetings/Recordings", isDirectory: true)
        config = dir.appendingPathComponent("config.toml")
        try! Data((configText ?? "[user]\nname = \"Timo\"\n[recording]\noutput_dir = \"\(recordings.path)\"\n[calendar]\nenabled = false\n").utf8)
            .write(to: config)
        let env = ["PALAVER_HOME": stores.home.path, "XDG_CONFIG_HOME": dir.appendingPathComponent("config").path,
                   "HOME": stores.home.path, KeyStores.TEST_ENV: dir.appendingPathComponent("keys.json").path].merging(more) { $1 }
        ctx = CLIMain.Context(env: env, stores: stores, executable: dir.appendingPathComponent("bin/palaver-cli"),
                              cwd: dir.appendingPathComponent("here", isDirectory: true))
        try! FileManager.default.createDirectory(at: ctx.cwd, withIntermediateDirectories: true)
        ctx.appSocket = dir.appendingPathComponent("app.sock")
        ctx.interactive = false
        ctx.out = { [unowned self] in out.append(contentsOf: $0.components(separatedBy: "\n")) }
        ctx.err = { [unowned self] in err.append(contentsOf: $0.components(separatedBy: "\n")) }
        ctx.exec = { [unowned self] in started.append($0); return startedExit }
        ctx.ask = { [unowned self] in asked.append($0); return answers.isEmpty ? false : answers.removeFirst() }
        ctx.reveal = { [unowned self] in revealed.append($0) }
        ctx.quitApp = { [unowned self] in quit.append($0) }
        ctx.readInput = { [unowned self] in input }
        ctx.doctorProbe = { QuietDoctorProbe() }
        ctx.reportProbe = { QuietReportProbe() }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    /// `palaver --config <its config.toml> <args>`; `config: false` without it.
    @discardableResult
    func run(_ args: [String], config withConfig: Bool = true) -> Int32 {
        out = []
        err = []
        return CLIMain.run((withConfig ? ["--config", config.path] : []) + args, ctx)
    }

    var text: String { out.joined(separator: "\n") }
    var usage: [JSONValue] {
        ((try? String(contentsOf: stores.usage, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? PythonJSON.parse(Data($0.utf8)) }
    }

    /// A finished meeting in its recordings (MeetingsTests' `pageMeeting`), Rico named by hand with his voice.
    @discardableResult
    func meeting(_ name: String = MEETING) throws -> RecordingPaths {
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let paths = try pageMeeting(recordings, name)
        try PythonJSON.write(.object([("SPEAKER_00", .string("Rico"))]), to: paths.speakers, indent: nil, ensureAscii: true)
        try PythonJSON.write(.object([("SPEAKER_00", .array((0..<64).map { .double(sin(Double($0))) }))]),
                             to: paths.speakerEmbeddings, indent: nil, ensureAscii: true)
        // Its calendar event: an import of it again is found by the event.
        func attendee(_ name: String, _ email: String) -> JSONValue {
            .object([("name", .string(name)), ("email", .string(email)), ("response", .string("accepted"))])
        }
        try PythonJSON.write(.object([
            ("title", .string("Hiring debrief")), ("start", .string("2026-10-27T16:00:00+01:00")),
            ("end", .string("2026-10-27T16:30:00+01:00")), ("uid", .string("UID-\(name)")), ("series", .bool(false)),
            ("attendees", .array([attendee("Timo", "timo@contoso.example"), attendee("Rico", "rico@northwind.example")])),
            ("link", .object([("source", .string("calendar")), ("confidence", .double(0.9)), ("reason", .string("time match"))])),
        ]), to: paths.calendar, indent: nil, ensureAscii: true)
        return paths
    }
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func writeJSON(_ v: JSONValue, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PythonJSON.write(v, to: url, indent: nil, ensureAscii: true)
}

/// An executable script at `url`.
private func script(_ url: URL, _ body: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    chmod(url.path, 0o755)
}

@Suite(.serialized) struct CLITests {
    // MARK: - help and usage

    @Test func test_help_exits_cleanly() {
        let c = CLI()
        #expect(c.run(["--help"], config: false) == 0)
        for spec in CLIMain.commands { #expect(c.out.contains { $0.hasPrefix("  \(spec.name) ") }, "\(spec.name)") }
        // The commands of earlier versions are not offered, only said to say what replaces them.
        for gone in ["record", "rename", "bench", "menubar", "live", "webapp-serve"] {
            #expect(!c.out.contains { $0.hasPrefix("  \(gone) ") }, "\(gone)")
        }
        #expect(c.text.contains("--config FILE") && c.text.contains("--dictionary FILE") && c.text.contains("--no-notify"))
        #expect(c.run(["-h"], config: false) == 0 && c.out.first?.hasPrefix("usage: palaver") == true)
    }

    @Test func eachCommandHasItsOwnHelpWithItsArgumentsAndOptions() {
        let c = CLI()
        #expect(c.run(["export", "--help"]) == 0)
        #expect(c.out.first == "usage: palaver export [--notes | --no-notes] [--voices] [--audio] [-o FILE] [--yes] meeting")
        #expect(c.text.contains("-o, --output FILE") && c.text.contains("--notes, --no-notes"))
        #expect(c.run(["projects", "-h"]) == 0 && c.out.first == "usage: palaver projects [--no-wait] {suggest,describe} [target]")
        #expect(c.run(["app", "--help"]) == 0 && c.text.contains("--store-tokens") && c.text.contains("make app"))
        #expect(c.run(["report", "--help"]) == 0 && c.text.contains("-m, --message TEXT"))
        #expect(c.usage.isEmpty)  // help is no use of a command
    }

    @Test func aUsageErrorSaysWhatIsWrongOnStderrAndExits2() {
        let c = CLI()
        let cases: [([String], String)] = [
            ([], "the following arguments are required: command"),
            (["nope"], "unknown command 'nope'"),
            (["export"], "the following arguments are required: meeting"),
            (["list", "--bogus"], "unrecognized arguments: --bogus"),
            (["list", "extra"], "unrecognized arguments: extra"),
            (["voices", "drop"], "argument action: invalid choice: 'drop' (choose from 'list', 'forget')"),
            (["projects", "sort"], "invalid choice: 'sort'"),
            (["export", MEETING, "-o"], "argument -o/--output: expected one argument"),
            (["export", MEETING, "--yes=no"], "ignored explicit argument 'no'"),
            (["app", "autostart", "on", "now"], "unrecognized arguments: now"),
        ]
        for (args, message) in cases {
            #expect(c.run(args) == 2, "\(args)")
            #expect(c.out.isEmpty && c.err.first?.hasPrefix("usage: palaver") == true, "\(args): \(c.err)")
            #expect(c.err.last?.contains(message) == true, "\(args): \(c.err)")
        }
        #expect(c.run(["--config"], config: false) == 2 && c.err.last == "palaver: error: argument --config: expected one argument")
        #expect(c.run(["--verbose", "list"], config: false) == 2)
        #expect(c.usage.isEmpty)
    }

    @Test func theCommandsOfEarlierVersionsSayWhatReplacesThemInOneLineAndExit2() {
        let c = CLI()
        let gone: [[String]] = [["record"], ["record", "--run"], ["rename", MEETING, "--no-audio"], ["bench", "dir"],
                                ["bench-live", "f", "--out", "o"], ["live", "f"], ["stream", "f"], ["coach", "f"],
                                ["cloud-transcribe", "f"], ["next-question", "f"], ["menubar"], ["webapp-serve", "--port", "0"],
                                ["onboarding", "analyze", "-"], ["provider", "list", "--json"], ["calendar", "attach"],
                                ["daemon"], ["daemon", "run"], ["app", "query", "status", "--json"], ["app", "housekeeping", "--hourly"],
                                ["app", "update", "check"], ["app", "uninstall-start", "--models"], ["report", "open", "r.zip"],
                                ["report", "usage", "a.zip", "b.zip"]]
        for args in gone {
            #expect(c.run(args) == 2, "\(args)")
            #expect(c.out.isEmpty && c.err.count == 1, "\(args): \(c.err)")
            let line = c.err.first ?? ""
            #expect(line.hasPrefix("palaver \(args[0])") && (line.contains(" is gone: ") || line.contains("developer tool")), "\(line)")
        }
        #expect(c.run(["record"]) == 2 && c.err == ["palaver record is gone: Palaver.app records (its menu: Start recording now; calls on their own)."])
        #expect(c.run(["rename", "x"]) == 2 && c.err.first?.contains("Meetings window") == true)
        #expect(c.usage.isEmpty)
    }

    // MARK: - the pipeline: palaver-worker and palaver-lm

    @Test func thePipelinesCommandsStartTheWorkerAndTheLanguageModelWithTheSameOptions() throws {
        let c = CLI(env: ["PALAVER_WORKER_BIN": "/x/palaver-worker", "PALAVER_LM_BIN": "/x/palaver-lm"])
        let cfg = c.config.path
        let cases: [([String], [String])] = [
            (["process", "f"], ["/x/palaver-worker", "--config", cfg, "process", "f"]),
            (["process", "--no-notes", "f"], ["/x/palaver-worker", "--config", cfg, "process", "f", "--no-notes"]),
            (["run", "f"], ["/x/palaver-worker", "--config", cfg, "run", "f"]),
            (["index"], ["/x/palaver-worker", "--config", cfg, "index"]),
            (["index", "a", "b"], ["/x/palaver-worker", "--config", cfg, "index", "a", "b"]),
            (["sync", "f"], ["/x/palaver-worker", "--config", cfg, "sync", "f"]),
            (["notes", "f"], ["/x/palaver-lm", "--config", cfg, "notes", "f"]),
            (["notes", "f", "--force"], ["/x/palaver-lm", "--config", cfg, "notes", "f", "--force"]),
            (["projects", "suggest"], ["/x/palaver-lm", "--config", cfg, "projects", "suggest"]),
            (["projects", "suggest", "f", "--no-wait"], ["/x/palaver-lm", "--config", cfg, "projects", "--no-wait", "suggest", "f"]),
            (["projects", "describe", "p1"], ["/x/palaver-lm", "--config", cfg, "projects", "describe", "p1"]),
        ]
        for (args, argv) in cases {
            c.started = []
            #expect(c.run(args) == 0, "\(args)")
            #expect(c.started == [argv], "\(args)")
        }
        // Their exit code is the command's (75: the model is busy; 4: waiting for the speech models).
        c.startedExit = 75
        #expect(c.run(["projects", "--no-wait", "suggest"]) == 75)
        // They count their own use (palaver-worker, palaver-lm); the command adds nothing.
        #expect(c.usage.isEmpty)
    }

    @Test func test_dictionary_flag_is_parsed_before_subcommand() {
        let c = CLI(env: ["PALAVER_WORKER_BIN": "/x/palaver-worker"])
        #expect(c.run(["--dictionary", "~/vocab/legal.toml", "--no-notify", "run", "f"]) == 0)
        #expect(c.started == [["/x/palaver-worker", "--config", c.config.path, "--dictionary", "~/vocab/legal.toml", "--no-notify", "run", "f"]])
        c.started = []
        #expect(c.run(["--dictionary=d.toml", "process", "f"], config: false) == 0)
        #expect(c.started == [["/x/palaver-worker", "--dictionary", "d.toml", "process", "f"]])
    }

    @Test func theWorkerIsTheBundlesAlsoThroughTheLinkInLocalBinElseBesideThisProgram() throws {
        let c = CLI()
        let app = c.dir.appendingPathComponent("Palaver.app", isDirectory: true)
        let cli = app.appendingPathComponent("Contents/Resources/bin/palaver")
        try script(cli, "exit 0")
        try script(app.appendingPathComponent("Contents/MacOS/palaver-worker"), "exit 0")
        try script(app.appendingPathComponent("Contents/MacOS/palaver-lm"), "exit 0")
        let link = c.dir.appendingPathComponent("home/.local/bin/palaver")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)
        let macos = app.resolvingSymlinksInPath().appendingPathComponent("Contents/MacOS").path
        #expect(CLICommand.find("palaver-worker", executable: link, env: [:]) == macos + "/palaver-worker")
        #expect(CLICommand.find("palaver-lm", executable: cli, env: [:]) == macos + "/palaver-lm")
        #expect(CLICommand.find("palaver-lm", executable: cli, env: ["PALAVER_LM_BIN": "/dev/lm"]) == "/dev/lm")
        // A build folder: the one beside it.
        let build = c.dir.appendingPathComponent("build", isDirectory: true)
        try script(build.appendingPathComponent("palaver-worker"), "exit 0")
        #expect(CLICommand.find("palaver-worker", executable: build.appendingPathComponent("palaver-cli"), env: [:])
                == build.resolvingSymlinksInPath().appendingPathComponent("palaver-worker").path)
        #expect(CLICommand.find("palaver-lm", executable: build.appendingPathComponent("palaver-cli"), env: [:]) == nil)

        c.ctx.executable = link
        #expect(c.run(["notes", "f"]) == 0 && c.started == [[macos + "/palaver-lm", "--config", c.config.path, "notes", "f"]])
        // Missing: said, exit 1, nothing started.
        c.started = []
        c.ctx.executable = build.appendingPathComponent("palaver-cli")
        #expect(c.run(["notes", "f"]) == 1 && c.started.isEmpty)
        #expect(c.err.first?.contains("palaver-lm is missing") == true)
    }

    // MARK: - list, daemon status

    @Test func test_list_empty_output_dir() throws {
        let c = CLI()
        #expect(c.run(["list"]) == 0 && c.out == ["(no recordings yet)"])
        try c.meeting()
        try FileManager.default.createDirectory(at: c.recordings.appendingPathComponent("2026-10-20T09-00-00"), withIntermediateDirectories: true)
        try Data().write(to: c.recordings.appendingPathComponent("notes.txt"))  // a file: not listed
        try writeJSON(.object([]), c.recordings.appendingPathComponent("2026-10-28T10-00-00/notion.json"))
        #expect(c.run(["list"]) == 0)
        #expect(c.out == ["2026-10-20T09-00-00  incomplete", "\(MEETING)  processed", "2026-10-28T10-00-00  synced"])
    }

    @Test func listWithoutAnOutputDirInConfigTomlLooksInTheStoresHome() throws {
        let c = CLI(configText: "[user]\nname = \"Timo\"\n")
        try c.meeting()
        #expect(c.run(["list"]) == 0 && c.out == ["\(MEETING)  processed"])
    }

    @Test func daemonStatusIsDaemonJsonInOneLine() throws {
        let c = CLI()
        #expect(c.run(["daemon", "status"]) == 0 && c.out == ["daemon has never run"])
        try writeJSON(.object([("pid", .int(Int(getpid()))), ("state", .string("recording")), ("since", .string("2026-11-08T10:00:00+01:00")),
                               ("folder", .string("/r/2026-11-08T10-00-00")), ("transcribing", .bool(true)),
                               ("queued", .strings(["a", "b"])), ("updated", .string("2026-11-08T10:05:00+01:00"))]),
                      c.stores.daemonJson)
        #expect(c.run(["daemon", "status"]) == 0)
        #expect(c.out == ["daemon running (pid \(getpid())): recording since 2026-11-08T10:00:00+01:00 → /r/2026-11-08T10-00-00; "
                          + "transcribing, 2 queued"])
        try writeJSON(.object([("pid", .int(Int(getpid()))), ("state", .string("stopped")), ("updated", .string("2026-11-08T11:00:00+01:00"))]),
                      c.stores.daemonJson)
        #expect(c.run(["daemon", "status"]) == 0 && c.out == ["daemon not running (last update 2026-11-08T11:00:00+01:00)"])
        #expect(c.usage.last?["id"] == .string("daemon") && c.usage.last?["action"] == .string("status"))
    }

    // MARK: - app: ping, restart-web, autostart, uninstall, install

    @Test func test_app_restart_web_restarts_only_the_server() {
        let c = CLI()
        let app = FakeAppSocket(c.ctx.appSocket) { name, _ in name == "restart_web" ? .ok(.object([("pid", .int(4321))])) : .failed("no") }
        defer { app.stop() }
        #expect(c.run(["app", "restart-web"]) == 0)
        #expect(app.calls.map(\.0) == ["restart_web"])
        #expect(c.out == ["Restarted the window's server (pid 4321); the window reloads where it was."])
    }

    @Test func test_app_restart_web_without_a_running_app() {
        let c = CLI()
        #expect(c.run(["app", "restart-web"]) == 1 && c.text.contains("not running"))
        let refusing = FakeAppSocket(c.ctx.appSocket) { _, _ in .refused("a test recording runs") }
        #expect(c.run(["app", "restart-web"]) == 1 && c.out == ["Palaver did not restart the window's server: a test recording runs"])
        refusing.stop()
        let notUp = FakeAppSocket(c.ctx.appSocket) { _, _ in .ok(.object([("pid", .null)])) }
        defer { notUp.stop() }
        #expect(c.run(["app", "restart-web"]) == 1 && c.out == ["Palaver restarted the window's server, but it is not up yet; see the log."])
    }

    @Test func appPingSaysWhetherTheRunningAppAnswersOnItsSocket() {
        let c = CLI()
        #expect(c.run(["app", "ping"]) == 1)
        #expect(c.out.first?.hasPrefix("Palaver does not answer on \(c.ctx.appSocket.path): ping: [Errno ") == true)
        let app = FakeAppSocket(c.ctx.appSocket) { _, _ in .ok(.object([("pid", .int(77))])) }
        defer { app.stop() }
        #expect(c.run(["app", "ping"]) == 0 && c.out == ["Palaver answers on \(c.ctx.appSocket.path) (pid 77)."])
        #expect(c.usage.last?["id"] == .string("app") && c.usage.last?["action"] == .string("ping"))
    }

    @Test func appAutostartWritesOrRemovesTheLoginItem() throws {
        let c = CLI()
        #expect(c.run(["app", "autostart"]) == 0 && c.out == ["Palaver starts at login."])
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: c.stores.launchAgent), format: nil) as? [String: Any]
        #expect(plist?["ProgramArguments"] as? [String] == ["/usr/bin/open", "-g", "-a", c.stores.applications.appendingPathComponent("Palaver.app").path])
        #expect(c.run(["app", "autostart", "off"]) == 0 && c.out == ["Autostart removed."] && !exists(c.stores.launchAgent))
        #expect(c.run(["app", "autostart", "maybe"]) == 1 && c.err == ["palaver app autostart: expected on or off"])
    }

    @Test func appUninstallQuitsAndRemovesTheAppAndItsLoginItem() throws {
        let c = CLI()
        let apps = c.stores.applications
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Palaver.app/Contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Meeting Transcribe.app"), withIntermediateDirectories: true)
        try Autostart.set(true, stores: c.stores)
        #expect(c.run(["app", "uninstall"]) == 0)
        #expect(c.out == ["Removed \(c.stores.launchAgent.path)", "Removed \(apps.appendingPathComponent("Palaver.app").path)",
                          "Removed \(apps.appendingPathComponent("Meeting Transcribe.app").path)"])
        #expect(c.quit == ["Palaver", "Meeting Transcribe"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: apps.path).isEmpty)
        #expect(c.run(["app", "uninstall"]) == 0 && c.out == ["Nothing installed."] && c.quit.count == 2)
    }

    @Test func appInstallFromAnInstalledAppKeepsItAndSetsTheLoginItemAndTokens() throws {
        let c = CLI(env: ["NOTION_TOKEN": "secret_notion_test"])
        let app = c.dir.appendingPathComponent("home/Applications/Palaver.app", isDirectory: true)
        c.ctx.executable = app.appendingPathComponent("Contents/Resources/bin/palaver")
        #expect(c.run(["app", "install", "--login", "--store-tokens"]) == 0)
        #expect(c.out == ["Stored NOTION_TOKEN in the login Keychain.",
                          "\(app.resolvingSymlinksInPath().path) is installed (install.sh installs and updates it); it starts at login."])
        #expect(try c.ctx.keys().read(Tokens.NOTION) == "secret_notion_test")
        #expect(exists(c.stores.launchAgent))
        // Plain `palaver app` is install.
        #expect(c.run(["app"]) == 0 && c.out.first?.hasSuffix("is installed (install.sh installs and updates it).") == true)
    }

    @Test func appInstallFromACheckoutBuildsWithTheMakefileAndReplacesTheAppInApplications() throws {
        let c = CLI()
        c.ctx.run = CLIMain.runAttached
        // A checkout whose `make app` leaves dist/palaver-app-<version>.zip (a Palaver.app with one file that says which).
        let repo = c.dir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("palaver"), withIntermediateDirectories: true)
        try Data("__version__ = \"9.9.9\"\n".utf8).write(to: repo.appendingPathComponent("palaver/__init__.py"))
        try Data("""
            app:
            \t@mkdir -p build/Palaver.app/Contents dist
            \t@echo new > build/Palaver.app/Contents/which
            \t@cd build && /usr/bin/ditto -ck --keepParent Palaver.app ../dist/palaver-app-9.9.9.zip

            """.utf8).write(to: repo.appendingPathComponent("Makefile"))
        c.ctx.executable = repo.appendingPathComponent("native/.build/debug/palaver-cli")
        let installed = c.stores.applications.appendingPathComponent("Palaver.app", isDirectory: true)
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appendingPathComponent("Contents/stale"))
        try Data().write(to: c.stores.permissionsMarker.creatingFolder())

        // Not while the app records: an update of the bundle would end it.
        try writeJSON(.object([("pid", .int(Int(getpid()))), ("state", .string("recording"))]), c.stores.daemonJson)
        #expect(c.run(["app", "install"]) == 1 && c.text.contains("Palaver is recording now"))
        #expect(exists(installed.appendingPathComponent("Contents/stale")))

        try writeJSON(.object([("pid", .int(Int(getpid()))), ("state", .string("idle"))]), c.stores.daemonJson)
        #expect(c.run(["app", "install", "--login"]) == 0, "\(c.out)")
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/which"), encoding: .utf8) == "new\n")
        #expect(!exists(installed.appendingPathComponent("Contents/stale")))
        #expect(!exists(c.stores.permissionsMarker) && exists(c.stores.launchAgent))
        #expect(c.out.contains("Installed \(installed.path) (starts at login)"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: c.stores.applications.path) == ["Palaver.app"])  // no leftovers
    }

    @Test func appInstallLooksAgainAfterTheBuildAndKeepsTheAppWhenTheAppStartedRecordingMeanwhile() throws {
        let c = CLI()
        let repo = c.dir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("palaver"), withIntermediateDirectories: true)
        try Data("__version__ = \"9.9.9\"\n".utf8).write(to: repo.appendingPathComponent("palaver/__init__.py"))
        try Data("app:\n\t@mkdir -p build/Palaver.app/Contents dist\n\t@cd build && /usr/bin/ditto -ck --keepParent Palaver.app ../dist/palaver-app-9.9.9.zip\n".utf8)
            .write(to: repo.appendingPathComponent("Makefile"))
        c.ctx.executable = repo.appendingPathComponent("native/.build/debug/palaver-cli")
        let daemon = c.stores.daemonJson
        // A call starts while `make app` builds.
        c.ctx.run = { argv, dir in
            let rc = CLIMain.runAttached(argv, dir)
            if argv[0] == "/usr/bin/make" {
                try? writeJSON(.object([("pid", .int(Int(getpid()))), ("state", .string("recording"))]), daemon)
            }
            return rc
        }
        let installed = c.stores.applications.appendingPathComponent("Palaver.app/Contents/stale")
        try Data("old".utf8).write(to: installed.creatingFolder())
        #expect(c.run(["app", "install"]) == 1 && c.text.contains("Palaver is recording now"))
        #expect(exists(installed))
        #expect(try FileManager.default.contentsOfDirectory(atPath: c.stores.applications.path) == ["Palaver.app"])
    }

    @Test func aSwapThatFailsPutsTheOldAppBack() throws {
        let c = CLI()
        let apps = c.stores.applications
        let app = apps.appendingPathComponent("Palaver.app", isDirectory: true)
        let staging = apps.appendingPathComponent(".palaver-install-test", isDirectory: true)
        try Data("old".utf8).write(to: app.appendingPathComponent("Contents/which").creatingFolder())
        try Data("new".utf8).write(to: staging.appendingPathComponent("Palaver.app/Contents/which").creatingFolder())
        struct Refused: Error {}
        var moves = 0
        #expect(throws: Refused.self) {
            try CLICommand.swap(staging.appendingPathComponent("Palaver.app"), into: app, staging: staging) { from, to in
                moves += 1
                if moves == 2 { throw Refused() }
                try FileManager.default.moveItem(at: from, to: to)
            }
        }
        #expect(try String(contentsOf: app.appendingPathComponent("Contents/which"), encoding: .utf8) == "old")
        #expect(!exists(staging))
        // And when it works: the new one, nothing left over.
        try Data("new".utf8).write(to: staging.appendingPathComponent("Palaver.app/Contents/which").creatingFolder())
        try CLICommand.swap(staging.appendingPathComponent("Palaver.app"), into: app, staging: staging)
        #expect(try String(contentsOf: app.appendingPathComponent("Contents/which"), encoding: .utf8) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: apps.path) == ["Palaver.app"])
    }

    // MARK: - doctor, report

    @Test func doctorPrintsTheChecksOfTheServersLibraryAndTheirExitCode() throws {
        let c = CLI(configText: "[recording]\noutput_dir = \"/nonexistent-\(UUID())\"\n[notion]\ntoken = \"secret_x\"\nparent_page_id = \"p\"\n")
        let checks = Doctor.run(configURL: c.config, stores: c.stores, env: c.ctx.env, probe: QuietDoctorProbe())
        #expect(c.run(["doctor"]) == Doctor.exitCode(checks) && c.text == Doctor.text(checks))
        // The quiet Mac's network is down: the Notion check says so; --offline asks nothing of Notion.
        #expect(c.out.contains { $0.hasPrefix("! Notion: not reachable") })
        #expect(c.run(["doctor", "--offline"]) == Doctor.exitCode(checks) && !c.text.contains("Notion"))
        // A config.toml that can't be read must be fixed: exit 1.
        try Data([0xFF, 0xFE, 0x00]).write(to: c.config)
        #expect(c.run(["doctor", "--offline"]) == 1 && c.out.contains { $0.hasPrefix("✗ Config") })
        #expect(c.out.last?.hasSuffix("problem(s) to fix.") == true)
    }

    /// Without config.toml the doctor looks only in the stores' home: the recordings it checks (system audio, last
    /// recording, disk) are `<PALAVER_HOME>/Meetings/Recordings`, never the account's.
    @Test func doctorWithATempHomeAndNoConfigTomlLooksOnlyInIt() throws {
        let c = CLI()
        try FileManager.default.removeItem(at: c.config)
        try FileManager.default.createDirectory(at: c.recordings, withIntermediateDirectories: true)
        final class Asked: @unchecked Sendable { var places: [String] = [] }
        let asked = Asked()
        struct Recording: DoctorProbe {
            let asked: Asked
            let quiet = QuietDoctorProbe()
            func macOSVersion() -> String { quiet.macOSVersion() }
            func httpStatus(_ url: String, headers: [String: String]) throws -> Int { try quiet.httpStatus(url, headers: headers) }
            func keychainNotionToken() -> String? { nil }
            func engineHello() throws -> JSONValue? { try quiet.engineHello() }
            func speechFilesHere() -> Bool { true }
            var inBundle: Bool { true }
            func microphoneStatus() -> Int { 3 }
            func defaultDevices() throws -> (input: (String, Double)?, output: (String, Double)?) { try quiet.defaultDevices() }
            func audioProcesses() throws -> [AudioProcess] { [] }
            func teamsInstalled() -> Bool { true }
            func freeBytes(_ url: URL) -> Int { asked.places.append(url.path); return quiet.freeBytes(url) }
            func ramGB() -> Double { 16 }
            func runningMemory() -> JSONValue? { nil }
        }
        c.ctx.doctorProbe = { Recording(asked: asked) }
        c.run(["doctor", "--offline"], config: false)
        #expect(asked.places == [c.recordings.path])
        #expect(c.out.contains("✓ Config: none: the defaults"))
    }

    @Test func test_report_create_writes_the_zip_about_the_latest_meeting_and_shows_it() throws {
        let c = CLI()
        try c.meeting("2026-10-29T10-00-00")
        try c.meeting("2026-10-30T09-00-00")
        #expect(c.run(["report", "create", "-m", "Notes never came", "--wish"]) == 0)
        let desktop = c.stores.home.appendingPathComponent("Desktop")
        let zips = try FileManager.default.contentsOfDirectory(atPath: desktop.path).filter { $0.hasPrefix("Palaver report ") }
        #expect(zips.count == 1)
        let zip = desktop.appendingPathComponent(zips[0])
        #expect(c.revealed == [zip])
        let reader = try ZipReader(url: zip, maxDirectoryBytes: 1 << 24)
        let report = try PythonJSON.parse(try reader.data(reader.entries.first { $0.name == "report.json" }!, limit: 1 << 24))
        #expect(report["form"] == .object([("kind", .string("wish")), ("text", .string("Notes never came")),
                                          ("meeting", .string("2026-10-30T09-00-00")), ("audio", .bool(false))]))
        #expect(report["via"] == .string("cli"))
        #expect(reader.entries.contains { $0.name == "meetings/2026-10-30T09-00-00/meta.json" })
        #expect(c.out.first == "Collecting logs, settings and this Mac's setup…")
        #expect(c.text.contains(zip.path) && c.text.contains("about 2026-10-30T09-00-00"))
    }

    @Test func test_report_create_without_a_meeting_and_with_an_unknown_one() throws {
        let c = CLI()
        try c.meeting()
        #expect(c.run(["report", "create", "--meeting", "none"]) == 0 && !c.text.contains("about"))
        #expect(c.run(["report", "create", "--meeting", "2020-01-01T00-00-00"]) == 2)
        #expect(c.out.last == "error: no meeting 2020-01-01T00-00-00")
    }

    @Test func test_report_create_json_takes_the_windows_form_and_answers_one_line() throws {
        let c = CLI(configText: nil)
        try c.meeting("2026-10-29T10-00-00")
        c.input = Data(#"{"kind": "bug", "text": "Speakers mixed up", "meeting": "2026-10-29T10-00-00", "audio": false}"#.utf8)
        #expect(c.run(["report", "create", "--json"]) == 0)
        #expect(c.out.count == 1)
        let answer = try PythonJSON.parse(Data(c.out[0].utf8))
        let path = try #require(answer["path"]?.stringValue)
        #expect(c.revealed.map(\.path) == [path] && answer["name"]?.stringValue == (path as NSString).lastPathComponent)
        #expect(answer["shown"]?.stringValue == "~" + path.dropFirst(c.stores.home.path.count))
        #expect(answer["size_text"]?.stringValue?.hasSuffix("KB") == true || answer["size_text"]?.stringValue?.hasSuffix("MB") == true)
        for (bad, error) in [(#"{"kind": "rant"}"#, "kind is bug or wish"), (#"{"meeting": "../secrets"}"#, "no meeting ../secrets")] {
            c.input = Data(bad.utf8)
            #expect(c.run(["report", "create", "--json"]) == 1)
            #expect(try PythonJSON.parse(Data(c.out[0].utf8)) == .object([("error", .string(error)), ("status", .int(400))]))
        }
        c.input = Data("{not json".utf8)
        #expect(c.run(["report", "create", "--json"]) == 1)
        #expect(try PythonJSON.parse(Data(c.out[0].utf8))["status"] == .int(400))
    }

    // MARK: - usage

    @Test func test_every_command_is_counted_as_typed_or_started_by_the_app() throws {
        let c = CLI()
        c.run(["list"])
        #expect(c.usage.last?["kind"] == .string("cli") && c.usage.last?["id"] == .string("list") && c.usage.last?["by"] == .string("app"))
        c.ctx.interactive = true
        c.run(["voices", "list"])
        #expect(c.usage.last?["id"] == .string("voices") && c.usage.last?["by"] == .string("user") && c.usage.last?["action"] == .string("list"))
        c.run(["app", "--help"])  // help is not counted
        c.run(["voices"])  // argparse's default action is named
        #expect(c.usage.count == 3 && c.usage.last?["action"] == .string("list"))
    }

    @Test func test_the_cli_catalog_has_every_command() {
        #expect(Usage.CLI_COMMANDS == CLIMain.commandNames)
        #expect(Set(["report", "doctor", "process", "mcp"]).isSubset(of: Set(CLIMain.commandNames)))
    }

    // MARK: - export, import

    @Test func exportAndImportCarryAMeetingToAColleaguesMac() throws {
        let sender = CLI(configText: nil)
        try sender.meeting()
        #expect(sender.run(["export", MEETING, "--voices"]) == 0)
        let zips = try FileManager.default.contentsOfDirectory(atPath: sender.ctx.cwd.path)
        #expect(zips.count == 1 && zips[0].hasSuffix(".zip"))
        let zip = sender.ctx.cwd.appendingPathComponent(zips[0])
        #expect(sender.out == ["Exported transcript and names, notes, voices to \(zip.path)"])
        // Again: a new name beside it, never over it.
        #expect(sender.run(["export", sender.recordings.appendingPathComponent(MEETING).path, "--no-notes", "-o", "mine"]) == 0)
        #expect(sender.out == ["Exported transcript and names to \(sender.ctx.cwd.appendingPathComponent("mine.zip").path)"])

        let receiver = CLI()
        receiver.answers = [false]  // the voices: not now
        #expect(receiver.run(["import", zip.path]) == 0, "\(receiver.out)")
        #expect(receiver.out.first == "Imported \(MEETING) from Timo.")
        #expect(receiver.asked.count == 1 && receiver.asked[0].contains("voices of Rico"))
        #expect(receiver.out.last == "Voices not added; the window asks again on the meeting.")
        #expect(exists(receiver.recordings.appendingPathComponent("\(MEETING)/transcript.json")))
        // The same meeting again: kept, unless the user says beside it (or --separate).
        receiver.answers = []
        #expect(receiver.run(["import", zip.path]) == 1)
        #expect(receiver.out == ["This meeting is here already: \(MEETING) (an earlier import).",
                             "Kept yours; nothing imported (--separate imports it beside it)."])
        receiver.answers = [true]
        #expect(receiver.run(["import", "--separate", zip.path]) == 0 && receiver.out.first?.contains(", beside \(MEETING).") == true)
        let added = try VoiceBank(directory: receiver.stores.voices).names()
        #expect(added["Rico"] == 1 && receiver.out.last == "Added the voices of Rico to your voice bank.")
        // Not a meeting's zip.
        let junk = receiver.dir.appendingPathComponent("junk.zip")
        try Data("no zip".utf8).write(to: junk)
        #expect(receiver.run(["import", junk.path]) == 1 && receiver.out.first?.hasPrefix("Not imported: ") == true)
    }

    @Test func exportAsksBeforeAMeetingKeptOnThisMacAndKnowsNoUnknownOne() throws {
        let c = CLI()
        let paths = try c.meeting()
        #expect(c.run(["export", "2020-01-01T00-00-00"]) == 2 && c.out == ["error: no meeting 2020-01-01T00-00-00 in \(c.recordings.path)"])
        try LocalOnly.set(paths.folder, on: true)
        #expect(c.run(["export", MEETING]) == 1)
        #expect(c.asked == ["This meeting is kept on this Mac. Export it anyway?"])
        #expect(c.out == ["Not exported: the meeting is kept on this Mac (--yes exports it anyway)."])
        #expect(c.run(["export", MEETING, "--yes", "-o", "x.zip"]) == 0 && c.asked.count == 1)
        #expect(exists(c.ctx.cwd.appendingPathComponent("x.zip")))
        // A meeting not transcribed yet.
        try FileManager.default.createDirectory(at: c.recordings.appendingPathComponent("2026-10-30T09-00-00"), withIntermediateDirectories: true)
        try writeJSON(.object([("start_time", .string("2026-10-30T09:00:00+01:00"))]), c.recordings.appendingPathComponent("2026-10-30T09-00-00/meta.json"))
        #expect(c.run(["export", "2026-10-30T09-00-00"]) == 2 && c.out == ["error: Only a finished, transcribed meeting can be exported."])
    }

    // MARK: - voices, prune

    @Test func voicesListsAndForgets() throws {
        let c = CLI()
        #expect(c.run(["voices"]) == 0 && c.out == ["No voices stored. Name speakers in the Meetings window to add them."])
        let bank = VoiceBank(directory: c.stores.voices)
        try bank.add("Rico", [1, 0, 0], source: "\(MEETING):SPEAKER_00")
        try bank.add("Valerie", [0, 1, 0], source: "\(MEETING):SPEAKER_01")
        try bank.add("Valerie", [0, 0.9, 0.1], source: "2026-10-28T10-00-00:SPEAKER_00")
        #expect(c.run(["voices", "list"]) == 0 && c.out == ["Rico  (1 sample)", "Valerie  (2 samples)"])
        #expect(c.run(["voices", "forget", "rico"]) == 0 && c.out == ["Forgot rico's voice."])
        #expect(c.run(["voices", "forget", "Rico"]) == 1 && c.out == ["No stored voice for Rico."])
        #expect(c.run(["voices", "forget"]) == 2 && c.out == ["usage: palaver voices forget <name>"])
    }

    @Test func pruneDeletesOldSyncedRecordingsAfterADryRun() throws {
        let d = CLI()  // retention_days: the default 14
        let old = d.recordings.appendingPathComponent("2020-01-01T10-00-00", isDirectory: true)
        try writeJSON(.object([]), old.appendingPathComponent("notion.json"))
        try Data(count: 2_000_000).write(to: old.appendingPathComponent("mic_raw.wav"))
        let unsynced = d.recordings.appendingPathComponent("2020-01-02T10-00-00", isDirectory: true)
        try writeJSON(.object([("start_time", .string("2020-01-02T10:00:00+01:00"))]), unsynced.appendingPathComponent("meta.json"))
        #expect(d.run(["prune", "--dry-run"]) == 0)
        #expect(d.out == ["would delete 2020-01-01T10-00-00 (2 MB)",
                          "kept 2020-01-02T10-00-00: older than 14 days but not synced (use --include-unsynced to delete)",
                          "would delete 1 recording(s), 2 MB"])
        #expect(exists(old))
        #expect(d.run(["prune", "--include-unsynced"]) == 0 && d.out.last == "deleted 2 recording(s), 2 MB")
        #expect(!exists(old) && !exists(unsynced))
        #expect(d.run(["prune"]) == 0 && d.out == ["nothing older than 14 days to delete"])
    }

    // MARK: - mcp

    @Test func mcpIsBatchSixsServerWithItsOwnOptions() {
        let c = CLI()
        #expect(c.run(["mcp", "--help"]) == 0 && c.text.contains("--install") && c.text.contains("--desktop"))
        #expect(c.run(["mcp", "--bogus"]) == 2)
        // --desktop alone is McpMain's usage error (exit 2), before anything is served or installed.
        #expect(c.run(["mcp", "--desktop"]) == 2)
    }
}

private extension URL {
    /// This file's URL once its folder is there.
    func creatingFolder() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
