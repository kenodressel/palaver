// `palaver-lm`, the language model's worker (cli.py `notes`, `projects`, `next-question` and their glue):
//
//   palaver-lm [--config F] [--dictionary F] [--no-notify] notes <folder> [--force]
//   palaver-lm … projects [--no-wait] suggest [folder] | describe [project id]
//   palaver-lm … next-question <folder>        (the inputs as JSON on stdin, the answer as JSON on stdout)
//
// Exit codes as Python's: 0; 1 with an "error: …" line (or `{"error"}` for next-question); 2 for a meeting without a
// transcript or an unknown project; 75 when the model is busy and the run would not wait (`--no-wait`, next-question).
// One model at a time across processes (notes.lock). A command that fails says so in a notification, unless
// `--no-notify`; the usage log counts the command.
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

public enum LMMain {
    public static let usage = "usage: palaver-lm [--config F] [--dictionary F] [--no-notify] "
        + "(notes <folder> [--force] | projects [--no-wait] (suggest [folder] | describe [id]) | next-question <folder>)"

    public struct Options: Equatable {
        public var config: String?
        public var dictionary: String?
        public var noNotify = false
        public var command = ""
        public var folder: String?
        public var force = false
        public var noWait = false
        public var action: String?
        public var target: String?
    }

    public struct UsageError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var rest: [String] = []
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw UsageError(description: "\(flag) needs a value") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--config": o.config = try value("--config")
            case "--dictionary": o.dictionary = try value("--dictionary")
            case "--no-notify": o.noNotify = true
            case "--force": o.force = true
            case "--no-wait": o.noWait = true
            default: rest.append(args[i])
            }
            i += 1
        }
        guard let command = rest.first else { throw UsageError(description: "no command") }
        o.command = command
        let operands = Array(rest.dropFirst())
        switch command {
        case "notes", "next-question":
            guard operands.count == 1 else { throw UsageError(description: "\(command) takes one meeting folder") }
            guard command == "notes" || !o.force else { throw UsageError(description: "--force is for notes") }
            o.folder = operands[0]
        case "projects":
            guard let action = operands.first, ["suggest", "describe"].contains(action), operands.count <= 2 else {
                throw UsageError(description: "projects takes suggest [folder] or describe [id]")
            }
            o.action = action
            o.target = operands.count == 2 ? operands[1] : nil
        default:
            throw UsageError(description: "unknown command: \(command)")
        }
        if o.noWait && command != "projects" { throw UsageError(description: "--no-wait is for projects") }
        if o.force && command != "notes" { throw UsageError(description: "--force is for notes") }
        return o
    }

    /// What a run works with. `fake` (tests): the model that answers instead of the chosen one, by what is asked
    /// ("notes", "projects", "model") and its details; `local` makes the local runner.
    public struct Context {
        public var config: Config
        public var stores: StorePaths
        public var settings: ProviderSettings
        public var userName: String
        public var http = HTTPClient()
        public var local: LocalModels.Factory = LocalModels.unavailable
        public var fake: ((_ kind: String, _ details: [(String, JSONValue)], _ fallback: JSONValue) -> LanguageModel)?
        public var say: (String) -> Void = { print($0); fflush(stdout) }
        public var readInput: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }

        public init(config: Config, stores: StorePaths, settings: ProviderSettings, userName: String) {
            self.config = config; self.stores = stores; self.settings = settings; self.userName = userName
        }

        public func engine(feature: String, kind: String, meetings: [URL] = [], details: [(String, JSONValue)] = [],
                           fallback: @autoclosure () -> JSONValue = .object([])) throws -> LMEngine {
            try LMEngine.make(feature: feature, meetings: meetings, settings: settings, http: http, local: local,
                              fake: fake.map { $0(kind, details, fallback()) })
        }
    }

    /// The context of `o`: config.toml (`--config`, else the user's), the stores, the provider settings with the
    /// Keychain, the user's name; in a debug build, `$PALAVER_TEST_LM` answers as the end-to-end tests' model.
    public static func context(_ o: Options, env: [String: String]) -> Context {
        let stores = StorePaths.current(env: env)
        let configURL = o.config.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? stores.configToml
        let config = Config.load(configURL, environment: env)
        let settings = ProviderSettings(config: config, stores: stores, keys: KeyStores.make(env: env), env: env)
        var ctx = Context(config: config, stores: stores, settings: settings,
                          userName: SettingsFile.currentUserName(default: config.userName, stores: stores))
        #if DEBUG
        if let folder = env[ControlModel.ENV], !folder.isEmpty {
            ctx.fake = { ControlModel(folder: URL(fileURLWithPath: folder), kind: $0, details: $1, fallback: $2) }
        }
        #endif
        return ctx
    }

    /// The whole run; the exit code. `local` makes the local model's runner (palaver-lm's MLX runner); `--version`
    /// says which Palaver this is and runs nothing.
    public static func run(_ args: [String], env: [String: String] = ProcessInfo.processInfo.environment,
                           local: ((StorePaths, Config) -> LocalModels.Factory)? = nil) async -> Int32 {
        if args == ["--version"] {
            print("palaver-lm \(RunLog.version())")
            return 0
        }
        let o: Options
        do {
            o = try parse(args)
        } catch {
            FileHandle.standardError.write(Data("\(usage)\npalaver-lm: error: \(error)\n".utf8))
            return 2
        }
        Notify.muted = o.noNotify
        var ctx = context(o, env: env)
        if let local { ctx.local = local(ctx.stores, ctx.config) }
        Usage.record("cli", o.command, fields: [("by", .string(isatty(0) != 0 ? "user" : "app")),
                                                 ("action", o.action.map { .string($0) } ?? .null)], path: ctx.stores.usage)
        let rc = await run(o, ctx)
        fflush(stdout)
        if rc != 0 { Notify.send(title: "palaver \(o.command) failed", message: "exit code \(rc); see terminal") }
        return rc
    }

    public static func run(_ o: Options, _ ctx: Context) async -> Int32 {
        switch o.command {
        case "notes": return await NotesRun.command(o, ctx)
        case "projects": return await ProjectsRun.command(o, ctx)
        default: return await NextQuestionRun.command(o, ctx)
        }
    }
}

// MARK: - notes

public enum NotesRun {
    /// `palaver notes <folder> [--force]`: 0 when the notes are written or up to date, 1 when they were not, 2 without a
    /// transcript.
    public static func command(_ o: LMMain.Options, _ ctx: LMMain.Context) async -> Int32 {
        let folder = URL(fileURLWithPath: (o.folder! as NSString).expandingTildeInPath, isDirectory: true)
        let paths = RecordingPaths(folder)
        guard FileManager.default.fileExists(atPath: paths.transcriptJson.path) else {
            ctx.say("error: \(paths.folder.path) has no transcript yet — run `process` first.")
            return 2
        }
        let log = SessionLog(url: paths.sessionLog, logger: "palaver")
        do {
            return try await write(paths, force: o.force, ctx, log: RunLog(log)) ? 0 : 1
        } catch {
            log.message("command failed: \(error)", level: "ERROR", logger: "palaver")
            ctx.say("error: \(error)")
            return 1
        }
    }

    static func utterances(_ paths: RecordingPaths) throws -> [Utterance] {
        guard let items = PythonJSON.read(paths.transcriptJson)?.arrayValue else {
            throw LMError("\(paths.transcriptJson.lastPathComponent) is not a transcript")
        }
        return try items.map { try Utterance(json: $0) }
    }

    /// `write_notes_for` / `_write_notes`: notes.json for the transcript, unless it is up to date (also once the run
    /// this one waited for wrote it). A failure only warns: the transcript is there either way, and notes can be
    /// retried.
    public static func write(_ paths: RecordingPaths, force: Bool, _ ctx: LMMain.Context, log: RunLog) async throws -> Bool {
        let all = try utterances(paths)
        guard let start = PythonJSON.read(paths.meta)?["start_time"]?.stringValue else {
            throw LMError("\(paths.meta.lastPathComponent) has no start_time")
        }
        let shown: [Utterance]  // voices removed as noise say nothing
        do {
            shown = try Speakers.withoutIgnored(paths, all)
        } catch {
            ctx.say("warning: the voices removed as noise could not be read (\(error)); writing notes with every voice")
            log.log?.message("could not read the ignored voices: \(error)", level: "WARNING", logger: "palaver")
            shown = all
        }
        if !force && !Notes.isStale(paths, shown) {
            ctx.say("Notes are up to date")
            return true
        }
        return try await ModelLock.with(stores: ctx.stores, wait: true, say: ctx.say) {
            if !force && !Notes.isStale(paths, shown) {  // written by the run this one waited for
                ctx.say("Notes are up to date")
                return true
            }
            return await writeNow(paths, shown, start: NotesPrompt.start(start), ctx, log: log)
        }
    }

    /// `_write_notes_now`: the model writes them, then the meeting is sorted into its projects.
    static func writeNow(_ paths: RecordingPaths, _ utterances: [Utterance], start: String, _ ctx: LMMain.Context,
                         log: RunLog) async -> Bool {
        let engine: LMEngine
        do {
            engine = try ctx.engine(feature: "notes", kind: "notes", meetings: [paths.folder],
                                    details: [("meeting", .string(paths.folder.lastPathComponent))],
                                    fallback: ControlFallback.notes(paths))
        } catch {  // never another model instead: the user chose this one
            ctx.say("Skipping notes: \(error)")
            log.event("notes_skipped", [("reason", .string(String(describing: error)))])
            return false
        }
        ctx.say("Writing notes with \(engine.label)…")
        let started = Date()
        func counted(_ ok: Bool) -> Bool {
            Usage.record("notes", fields: [("engine", .string(engine.choice)), ("model", .string(engine.model)),
                                           ("seconds", .double(Date().timeIntervalSince(started))), ("ok", .bool(ok))],
                         path: ctx.stores.usage)
            return ok
        }
        // The local model's memory watchdog ends the process: the meeting's log and the usage log say so first.
        let lastWords = FootprintWatchdog.addLastWords { why in
            log.event("notes_failed", [("error", .string(why))])
            _ = counted(false)
        }
        defer { FootprintWatchdog.removeLastWords(lastWords) }
        let notes: JSONValue
        do {
            notes = try await log.stage("notes", [("engine", .string(engine.choice)), ("model", .string(engine.model))]) {
                // The user's own notes: images not read yet (the app quit first) are read now. A model gets the text
                // read from an image, never the image.
                MyNotes.readAll(paths.folder)
                return try await NotesPrompt.generate(
                    utterances, userName: ctx.userName, start: start, event: CalendarEvents.load(paths),
                    myNotes: MyNotes.promptText(paths.folder), shared: SharedMic.display(paths),
                    mic: SharedMic.micDisplay(paths), title: Titles.load(paths) ?? "",
                    glossary: Glossary.current(stores: ctx.stores)) {
                    try await engine.run($0, schema: $1, parse: NotesAnswer.parse)
                }
            }
        } catch {
            ctx.say("warning: notes failed: \(error)")
            log.event("notes_failed", [("error", .string(String(describing: error)))])
            return counted(false)
        }
        do {
            try NotesFile.save(paths, notes)
        } catch {
            ctx.say("warning: notes failed: \(error)")
            log.event("notes_failed", [("error", .string(String(describing: error)))])
            return counted(false)
        }
        ctx.say("Wrote \(paths.notes.path) — \(notes["title"].map { Py.str($0) } ?? "")")
        _ = counted(true)
        FootprintWatchdog.removeLastWords(lastWords)  // the notes are written; a stop now is the sort's
        await sortIntoProjects(paths, ctx, log: log)
        return true
    }

    /// `_sort_into_projects`: a meeting with fresh notes goes into its projects, by rules when it resembles a project's
    /// meetings, else as the model suggests. Never fails the notes.
    static func sortIntoProjects(_ paths: RecordingPaths, _ ctx: LMMain.Context, log: RunLog) async {
        let meeting = paths.folder.lastPathComponent, outputDir = paths.folder.deletingLastPathComponent()
        var added: [(String, String)] = []
        let store: ProjectStore
        do {
            let ruled = try ProjectRules.assignByRules(outputDir: outputDir, userName: ctx.userName, meetings: [meeting],
                                                       stores: ctx.stores)
            store = ruled.store
            added = ruled.added
            if added.isEmpty && store.ofMeeting(meeting).isEmpty {
                var engine: LMEngine?
                do {
                    engine = try ctx.engine(feature: "projects", kind: "projects", meetings: [paths.folder],
                                            details: [("args", .strings(["suggest", paths.folder.path]))],
                                            fallback: ControlFallback.suggest)
                } catch {
                    ctx.say("Not sorting into projects with a model: \(error)")
                }
                if let engine {
                    let lastWords = FootprintWatchdog.addLastWords { why in
                        log.event("projects_failed", [("error", .string(why))])
                    }
                    defer { FootprintWatchdog.removeLastWords(lastWords) }
                    added = try await log.stage("projects", [("engine", .string(engine.choice)), ("model", .string(engine.model))]) {
                        try await ProjectsModel.suggest(outputDir: outputDir, userName: ctx.userName, meetings: [meeting],
                                                        private: engine.cloud ? LocalOnly.meetings(outputDir: outputDir) : [],
                                                        stores: ctx.stores) {
                            try await engine.run($0, schema: $1, parse: ProjectsPrompt.parseAnswer)
                        }
                    }
                    store.reload()
                }
            }
        } catch {  // projects are extra; the notes are written
            ctx.say("warning: sorting into projects failed: \(error)")
            log.event("projects_failed", [("error", .string(String(describing: error)))])
            return
        }
        for (_, pid) in added { ctx.say("Project: \(store.projects[pid]?["name"].map { Py.str($0) } ?? pid)") }
    }
}

// MARK: - projects

public enum ProjectsRun {
    /// `palaver projects [--no-wait] suggest [folder] | describe [id]`, with the model held throughout (and the store read
    /// once it is free).
    public static func command(_ o: LMMain.Options, _ ctx: LMMain.Context) async -> Int32 {
        do {
            return try await ModelLock.with(stores: ctx.stores, wait: !o.noWait, say: ctx.say) {
                o.action == "describe" ? try await describe(o.target, ctx) : try await suggest(o.target, ctx)
            }
        } catch is ModelBusyError {
            ctx.say("the language model is busy")
            return ModelLock.EXIT_MODEL_BUSY
        } catch {
            ctx.say("error: \(error)")
            return 1
        }
    }

    static func describe(_ target: String?, _ ctx: LMMain.Context) async throws -> Int32 {
        let store = ProjectStore(path: ctx.stores.projects)
        if let target, store.projects[target] == nil {
            ctx.say("error: no project \(target)")
            return 2
        }
        // One project, or every project without a description.
        let targets = target.map { [$0] } ?? store.projects.filter { !($0.value["description"]?.truthy ?? false) }.map(\.key)
        let engine: LMEngine
        do {
            engine = try ctx.engine(feature: "projects", kind: "projects", details: [("args", .strings(["describe"] + targets))],
                                    fallback: ControlFallback.describe(store, targets))
        } catch {
            ctx.say("error: \(error)")
            return 1
        }
        let hidden = engine.cloud ? LocalOnly.meetings(outputDir: ctx.config.outputDir) : []
        for pid in targets {
            let text = try await ProjectsModel.describe(outputDir: ctx.config.outputDir, pid: pid, userName: ctx.userName,
                                                        private: hidden, stores: ctx.stores) {
                try await engine.run($0, schema: $1, parse: ProjectsPrompt.parseDescription)
            }
            store.reload()
            ctx.say("\(store.projects[pid]?["name"].map { Py.str($0) } ?? pid): \(text)")
        }
        return 0
    }

    static func suggest(_ target: String?, _ ctx: LMMain.Context) async throws -> Int32 {
        let outputDir = ctx.config.outputDir
        let meetings = target.map { [URL(fileURLWithPath: $0).lastPathComponent] }
        var (store, added) = try ProjectRules.assignByRules(outputDir: outputDir, userName: ctx.userName, meetings: meetings,
                                                            stores: ctx.stores)
        var unavailable: Error?
        var engine: LMEngine?
        do {
            engine = try ctx.engine(feature: "projects", kind: "projects",
                                    meetings: (meetings ?? []).map { outputDir.appendingPathComponent($0, isDirectory: true) },
                                    details: [("args", .strings(["suggest"] + (target.map { [$0] } ?? [])))],
                                    fallback: ControlFallback.suggest)
        } catch {
            unavailable = error
        }
        if let engine {
            ctx.say("Asking \(engine.label)…")
            added += try await ProjectsModel.suggest(outputDir: outputDir, userName: ctx.userName, meetings: meetings,
                                                     private: engine.cloud ? LocalOnly.meetings(outputDir: outputDir) : [],
                                                     stores: ctx.stores) {
                try await engine.run($0, schema: $1, parse: ProjectsPrompt.parseAnswer)
            }
            store = ProjectStore(path: ctx.stores.projects)
        }
        for (meeting, pid) in added { ctx.say("\(meeting): \(store.projects[pid]?["name"].map { Py.str($0) } ?? pid)") }
        if let unavailable {
            ctx.say("error: \(unavailable)")
            return 1
        }
        return 0
    }
}

// MARK: - next question

public enum NextQuestionRun {
    /// `palaver next-question <folder>`: `{"questions", "engine"}` on stdout, or `{"error"}` with exit 1 (75 while a
    /// local model is in use).
    public static func command(_ o: LMMain.Options, _ ctx: LMMain.Context) async -> Int32 {
        let folder = URL(fileURLWithPath: (o.folder! as NSString).expandingTildeInPath, isDirectory: true)
        func answer(_ fields: [(String, JSONValue)], _ code: Int32) -> Int32 {
            ctx.say(PythonJSON.dumps(.object(fields), ensureAscii: false))
            return code
        }
        do {
            guard var inputs = PyDict<JSONValue>((try? PythonJSON.parse(ctx.readInput())) ?? .null) else {
                throw LMError("the inputs are not a JSON object")
            }
            // The current meeting decides the model ("Keep on This Mac" keeps it local). A cloud model gets no earlier
            // meeting kept on this Mac; the access log names every meeting whose content is sent.
            var others = (inputs["meetings"]?.arrayValue ?? []).compactMap(\.stringValue)
                .filter { !Py.same($0, folder.lastPathComponent) }
                .map { ctx.config.outputDir.appendingPathComponent($0, isDirectory: true) }
            let choice = ModelChoice.choiceFor(feature: NextQuestion.FEATURE, folders: [folder], config: ctx.config,
                                               stores: ctx.stores)
            if choice != ModelChoice.LOCAL && choice != ModelChoice.PENDING {
                others = others.filter { !LocalOnly.isLocalOnly($0) }
                let kept = Set(others.map { ScalarKey($0.lastPathComponent) })
                inputs["last_time"] = .array((inputs["last_time"]?.arrayValue ?? []).filter { m in
                    m["id"]?.stringValue.map { kept.contains(ScalarKey($0)) } ?? false
                })
            }
            let engine = try ctx.engine(feature: NextQuestion.FEATURE, kind: "model", meetings: [folder] + others,
                                        details: [("meeting", .string(folder.lastPathComponent))],
                                        fallback: .object([("questions", .array([]))]))
            // A memory stop of the local model ends palaver-lm: its answer (the last line, which the window reads) says why.
            let lastWords = FootprintWatchdog.addLastWords { why in
                ctx.say(PythonJSON.dumps(.object([("error", .string(why))]), ensureAscii: false))
            }
            defer { FootprintWatchdog.removeLastWords(lastWords) }
            let ask = { try await NextQuestion.ask(inputs.json) { try await engine.run($0, schema: $1, parse: NextQuestion.parse) } }
            let out = engine.cloud ? try await ask() : try await ModelLock.with(stores: ctx.stores, wait: false, say: { _ in }, ask)
            return answer((out["questions"].map { [("questions", $0)] } ?? []) + [("engine", .string(engine.label))], 0)
        } catch is ModelBusyError {
            return answer([("error", .string(NextQuestion.BUSY))], ModelLock.EXIT_MODEL_BUSY)
        } catch {
            return answer([("error", .string(String(describing: error)))], 1)
        }
    }
}
