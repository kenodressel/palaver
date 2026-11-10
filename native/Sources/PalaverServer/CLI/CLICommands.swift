// The `palaver` command's commands (cli.py's `_cmd_*`): those of the pipeline start palaver-worker or palaver-lm in
// this process's place; the rest run here.
import Darwin
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

struct CLICommand {
    let name: String
    /// The command's arguments as given (after its name).
    let args: [String]
    let parsed: CLIParsed
    let globals: CLIMain.Globals
    let ctx: CLIMain.Context

    func run() -> Int32 {
        switch name {
        case "process":
            return forward("palaver-worker", ["process", parsed.one("folder")!] + (parsed.flag("--no-notes") ? ["--no-notes"] : []))
        case "run": return forward("palaver-worker", ["run", parsed.one("folder")!])
        case "index": return forward("palaver-worker", ["index"] + parsed.all("folders"))
        case "sync": return forward("palaver-worker", ["sync", parsed.one("folder")!])
        case "notes": return forward("palaver-lm", ["notes", parsed.one("folder")!] + (parsed.flag("--force") ? ["--force"] : []))
        case "projects":
            return forward("palaver-lm", ["projects"] + (parsed.flag("--no-wait") ? ["--no-wait"] : []) + [parsed.one("action")!]
                           + (parsed.one("target").map { [$0] } ?? []))
        case "list": return list()
        case "export": return export()
        case "import": return importMeeting()
        case "voices": return voices()
        case "prune": return prune()
        case "doctor": return doctor()
        case "report": return report()
        case "daemon": return daemonStatus()
        case "app": return app()
        case "mcp": return McpMain.run(globals.forwarded + ["mcp"] + args, env: ctx.env)
        default: return 2  // the table has no other
        }
    }

    // MARK: - what the commands share

    var say: (String) -> Void { ctx.out }

    /// A path as given: `~` expanded, a relative one under the working folder.
    func path(_ given: String, isDirectory: Bool = false) -> URL {
        let expanded = (given as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded, isDirectory: isDirectory) }
        return ctx.cwd.appendingPathComponent(expanded, isDirectory: isDirectory)
    }

    var configURL: URL { globals.config.map { path($0) } ?? ctx.stores.configToml }
    /// config.toml, its `~` the stores' home (`Paths.home(environment:)`: PALAVER_HOME, else $HOME): the one way every
    /// command, the doctor's checks too, finds the recordings.
    var config: Config { Config.load(configURL, environment: ctx.env) }
    func userName(_ config: Config) -> String { SettingsFile.currentUserName(default: config.userName, stores: ctx.stores) }

    func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    /// A yes-or-no question; no when nobody can answer it.
    func ask(_ question: String) -> Bool { ctx.ask?(question) ?? false }

    // MARK: - the pipeline: palaver-worker and palaver-lm

    /// The app's program `program`: `PALAVER_WORKER_BIN` / `PALAVER_LM_BIN`; else the bundle's Contents/MacOS (also from
    /// Contents/Resources/bin), a checkout's native/.build, or the one beside this program.
    static func find(_ program: String, executable: URL, env: [String: String]) -> String? {
        let key = ["palaver-worker": "PALAVER_WORKER_BIN", "palaver-lm": "PALAVER_LM_BIN"][program]
        if let key, let given = env[key], !given.isEmpty { return given }
        let isExecutable = { FileManager.default.isExecutableFile(atPath: $0) }
        if let found = AppLocation(executable: executable).binary(program, environment: [:], fileExists: isExecutable) { return found }
        let beside = executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(program).path
        return isExecutable(beside) ? beside : nil
    }

    /// Starts `program` with the global options and `rest`, in this process's place: its output, exit code and
    /// notifications are the command's.
    func forward(_ program: String, _ rest: [String]) -> Int32 {
        guard let found = Self.find(program, executable: ctx.executable, env: ctx.env) else {
            let fix = AppLocation(executable: ctx.executable).bundle != nil ? "reinstall Palaver" : "build it (make parity-helper)"
            ctx.err("error: \(program) is missing beside \(ctx.executable.resolvingSymlinksInPath().path): \(fix)")
            return 1
        }
        return ctx.exec([found] + globals.forwarded + rest)
    }

    // MARK: - list, daemon status

    /// `_cmd_list`: every folder of the recordings folder and its state.
    func list() -> Int32 {
        let out = config.outputDir
        guard FileManager.default.fileExists(atPath: out.path) else {
            say("(no recordings yet)")
            return 0
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        for name in names.sorted(by: { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }) {
            let folder = out.appendingPathComponent(name, isDirectory: true)
            guard isDirectory(folder) else { continue }
            say("\(name)  \(MeetingStatus.status(RecordingPaths(folder)))")
        }
        return 0
    }

    /// `daemon status`: daemon.json in one line (daemon.py `read_status`).
    func daemonStatus() -> Int32 {
        say(DaemonFile.status(ctx.stores.daemonJson))
        return 0
    }

    // MARK: - doctor, report

    /// `_cmd_doctor`: the checks, what to fix, exit 1 when something must be.
    func doctor() -> Int32 {
        let checks = Doctor.run(configURL: configURL, stores: ctx.stores, env: ctx.env, offline: parsed.flag("--offline"),
                                probe: ctx.doctorProbe())
        say(Doctor.text(checks))
        return Doctor.exitCode(checks)
    }

    /// `_cmd_report` (`create`): the zip on the Desktop, shown in Finder; with `--json` the window's form on stdin and
    /// one JSON line out.
    func report() -> Int32 {
        let place = Report.Place(stores: ctx.stores, configURL: configURL, outputDir: config.outputDir, env: ctx.env,
                                 keychainSecrets: { [keys = ctx.keys] in ReportSecrets.keychain(keys()) })
        if parsed.flag("--json") { return reportJSON(place) }
        let meeting: String?
        switch parsed.value("--meeting") {
        case "none": meeting = nil
        case let given?: meeting = given
        case nil: meeting = Self.latestMeeting(place.outputDir)
        }
        let form = Report.Form(kind: parsed.flag("--wish") ? "wish" : "bug", text: parsed.value("--message") ?? "",
                               meeting: meeting, audio: parsed.flag("--audio"))
        say("Collecting logs, settings and this Mac's setup…")
        fflush(stdout)
        let written: Report.Written
        do {
            written = try Report.create(form, place: place, via: "cli", probe: ctx.reportProbe())
        } catch let e as BadRequest {
            say("error: \(e.text)")
            return 2
        } catch {
            say("error: \(error)")
            return 1
        }
        ctx.reveal(written.path)
        say("Saved \(written.path.path) (\(Report.sizeText(written.size)), \(written.files) files"
            + (meeting.map { ", about \($0)" } ?? "") + ").\nSend it to the maintainer, e.g. in Slack or Mail.")
        return 0
    }

    /// `_report_json`: `{path, name, size, files, size_text, shown}`, or `{"error", "status"}` (400 for a bad form,
    /// else 500) and exit 1.
    func reportJSON(_ place: Report.Place) -> Int32 {
        let maker = SwiftReport(place: place, probe: ctx.reportProbe, reveal: ctx.reveal)
        do {
            let input = ctx.readInput()
            let body = input.isEmpty ? JSONValue.object([]) : try PythonJSON.parse(input)
            say(PythonJSON.dumps(try maker.create(body)))
            return 0
        } catch let e as BadRequest {
            say(PythonJSON.dumps(.object([("error", .string(e.text)), ("status", .int(400))])))
        } catch let e as PythonJSON.ParseError {
            say(PythonJSON.dumps(.object([("error", .string("\(e)")), ("status", .int(400))])))
        } catch {
            say(PythonJSON.dumps(.object([("error", .string("\(error)")), ("status", .int(500))])))
        }
        return 1
    }

    /// report.py `latest_meeting`: the newest recording folder's name.
    static func latestMeeting(_ outputDir: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
        return names.filter { name in
            var dir: ObjCBool = false
            return RecordingPaths.isRecordingFolderName(name)
                && FileManager.default.fileExists(atPath: outputDir.appendingPathComponent(name).path, isDirectory: &dir) && dir.boolValue
        }.max { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    // MARK: - export, import

    /// `_cmd_export`: the meeting as a .zip here (or `-o`), never over a file; a meeting kept on this Mac only after a yes.
    func export() -> Int32 {
        let config = config
        let given = parsed.one("meeting")!
        let asFolder = path(given, isDirectory: true)
        let folder = isDirectory(asFolder) ? asFolder : config.outputDir.appendingPathComponent(given, isDirectory: true)
        let paths = RecordingPaths(folder)
        guard FileManager.default.fileExists(atPath: paths.meta.path) else {
            say("error: no meeting \(given) in \(config.outputDir.path)")
            return 2
        }
        var dest = parsed.value("--output").map { path($0) }
            ?? Exchange.freeName(ctx.cwd, Exchange.fileName(paths, stores: ctx.stores))
        if "." + (dest.lastPathComponent as NSString).pathExtension != Exchange.SUFFIX {  // `dest.suffix != ".zip"`
            dest = dest.deletingLastPathComponent().appendingPathComponent(dest.lastPathComponent + Exchange.SUFFIX)
        }
        let notes = parsed.toggles["--notes"] ?? true, voices = parsed.flag("--voices"), audio = parsed.flag("--audio")
        func write(confirmed: Bool) throws {
            try Exchange.exportMeeting(paths, dest: dest, userName: userName(config), notes: notes, voices: voices, audio: audio,
                                       confirmLocal: confirmed,
                                       projects: Exchange.confirmedProjects(folder.lastPathComponent, stores: ctx.stores),
                                       stores: ctx.stores)
        }
        do {
            do {
                try write(confirmed: parsed.flag("--yes"))
            } catch is Exchange.KeptOnThisMac {
                guard ask("This meeting is kept on this Mac. Export it anyway?") else {
                    say("Not exported: the meeting is kept on this Mac (--yes exports it anyway).")
                    return 1
                }
                try write(confirmed: true)
            }
        } catch let e as Exchange.NotReady {
            say("error: \(e.description)")
            return 2
        } catch {
            say("error: \(error)")
            return 1
        }
        let parts = ["transcript and names"] + [("notes", notes), ("voices", voices), ("audio", audio)].filter(\.1).map(\.0)
        say("Exported \(parts.joined(separator: ", ")) to \(dest.path)")
        return 0
    }

    /// `_cmd_import`: a colleague's meeting as one of this Mac's; the same meeting here already only beside it after a
    /// yes (or `--separate`); voices it came with join the voice bank only after a yes.
    func importMeeting() -> Int32 {
        let config = config
        let user = userName(config)
        let out = config.outputDir
        let file = path(parsed.one("file")!)
        do {
            let package = try Exchange.readPackage(file)
            var separate = parsed.flag("--separate")
            if !separate, let match = try Exchange.findMatch(out, package) {
                say("This meeting is here already: \(match.id) (\(match.own ? "your own recording" : "an earlier import")).")
                guard ask("Import it as a separate meeting beside it?") else {
                    say("Kept yours; nothing imported (--separate imports it beside it).")
                    return 1
                }
                separate = true
            }
            var calendar: CalendarProvider?
            if config.calendarEnabled {  // no calendar: the event in the file is linked
                let kit = EventKitCalendar()
                if kit.hasAccess() { calendar = { try kit.eventsBetween($0, $1) } }
            }
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let result = try Exchange.importPackage(out, file, userName: user, separate: separate, calendar: calendar,
                                                    package: package, after: { id in
                                                        try Exchange.settle(out, id, userName: user, stores: ctx.stores)
                                                    }, stores: ctx.stores)
            say("Imported \(result.id) from \(result.sender)" + (result.matched.map { ", beside \($0.id)" } ?? "") + ".")
            for warning in result.warnings { say("  \(warning)") }
            for (label, name) in result.names.sorted(by: { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) }) {
                say("  \(label): \(name) (named by \(result.sender); confirm it in the window)")
            }
            if !result.voices.isEmpty {
                let names = result.voices.compactMap { $0["name"]?.stringValue }.joined(separator: ", ")
                if ask("It came with the voices of \(names). Add them to your voice bank?") {
                    let learned = try Exchange.decideVoices(RecordingPaths(out.appendingPathComponent(result.id, isDirectory: true)),
                                                            add: true, userName: user, stores: ctx.stores)
                    say("Added the voices of \(learned.isEmpty ? "nobody" : learned.joined(separator: ", ")) to your voice bank.")
                } else {
                    say("Voices not added; the window asks again on the meeting.")
                }
            }
            return 0
        } catch let e as ExchangeRejected {
            say("Not imported: \(e.message)")
            return 1
        } catch {
            say("error: \(error)")
            return 1
        }
    }

    // MARK: - voices, prune

    /// `_cmd_voices`: the stored voices, or `forget <name>`.
    func voices() -> Int32 {
        let bank = VoiceBank(directory: ctx.stores.voices)
        do {
            if parsed.one("action") == "forget" {
                guard let name = parsed.one("name") else {
                    say("usage: palaver voices forget <name>")
                    return 2
                }
                guard try bank.forget(name) else {
                    say("No stored voice for \(name).")
                    return 1
                }
                say("Forgot \(name)'s voice.")
                return 0
            }
            let people = try bank.names()
            if people.isEmpty { say("No voices stored. Name speakers in the Meetings window to add them.") }
            for (name, samples) in people.sorted(by: { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) }) {
                say("\(name)  (\(samples) sample\(samples != 1 ? "s" : ""))")
            }
            return 0
        } catch {
            say("error: \(error)")
            return 1
        }
    }

    /// `_cmd_prune`: recordings older than `[recording].retention_days` (synced ones, unless `--include-unsynced`).
    func prune() -> Int32 {
        let config = config
        do {
            try Prune.run(config.outputDir, retentionDays: config.retentionDays, dryRun: parsed.flag("--dry-run"),
                          includeUnsynced: parsed.flag("--include-unsynced"), say: say)
            return 0
        } catch {
            say("error: \(error)")
            return 1
        }
    }
}
