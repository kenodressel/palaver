// `palaver-worker`: the pipeline's commands, the port of `palaver process|run|sync|live|stream|coach|index`,
// `palaver calendar attach`, `palaver app query` and `palaver onboarding analyze` (`test-analyze`) (cli.py), with the
// speech engine in this process.
//
//   palaver-worker [--config F] [--dictionary F] [--no-notify] <cmd> …
//
// Exit codes as the Python commands': 0 done, 1 an error, 2 usage or not a recording folder, 3 the folder is still
// being recorded or processed live, 4 the speech models are missing (the meeting waits for the download).
import Darwin
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain
import PalaverEngine

public struct WorkerError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum WorkerMain {
    public static let EXIT_ERROR: Int32 = 1
    public static let EXIT_USAGE: Int32 = 2
    public static let EXIT_BUSY: Int32 = 3
    public static let EXIT_MODELS: Int32 = ProcessState.exitModels

    public static let usage = """
        usage: palaver-worker [--config F] [--dictionary F] [--no-notify] <cmd> …
          process <folder> [--no-notes] | run <folder> | sync <folder> | live <folder> | stream <folder> | coach <folder>
          index [folder…]
          calendar-attach [--since H] | query <what> [arg] --json | engine-serve [--version V] [--models DIR]
          test-analyze <mic|-> [--system WAV] [--mode JSON]
        """

    public struct Options: Equatable {
        public var config: String?
        public var dictionary: String?
        public var noNotify = false
        public var command = ""
        public var args: [String] = []
    }

    struct UsageError: Error, CustomStringConvertible {
        let description: String
    }

    static let commands: Set<String> = ["process", "run", "sync", "live", "stream", "coach", "index", "calendar-attach", "query",
                                        "engine-serve", "test-analyze"]

    /// The global options, then the command and its arguments.
    static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw UsageError(description: "\(flag) needs a value") }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--config": o.config = try value(a)
            case "--dictionary": o.dictionary = try value(a)
            case "--no-notify": o.noNotify = true
            default:
                guard commands.contains(a) else { throw UsageError(description: "unknown command or option: \(a)") }
                o.command = a
                o.args = Array(args[(i + 1)...])
                return o
            }
            i += 1
        }
        throw UsageError(description: "a command is needed")
    }

    /// A folder argument (the command's first that is no option).
    static func folderArgument(_ o: Options) throws -> URL {
        guard let first = o.args.first(where: { !$0.hasPrefix("--") }) else {
            throw UsageError(description: "\(o.command) needs a recording folder")
        }
        return URL(fileURLWithPath: (first as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// `--flag VALUE` among a command's arguments.
    static func flag(_ name: String, in args: [String]) throws -> String? {
        guard let i = args.firstIndex(of: name) else { return nil }
        guard i + 1 < args.count else { throw UsageError(description: "\(name) needs a value") }
        return args[i + 1]
    }

    // MARK: - the run

    public static func run(_ args: [String], env: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        let o: Options
        do {
            o = try parse(args)
        } catch {
            FileHandle.standardError.write(Data("\(usage)\npalaver-worker: \(error)\n".utf8))
            return EXIT_USAGE
        }
        signal(SIGPIPE, SIG_IGN)
        Notify.muted = o.noNotify
        do {
            switch o.command {
            case "query": return query(o, env: env)
            case "calendar-attach": return try calendarAttach(o, env: env)
            case "engine-serve": return try await engineServe(o, env: env)
            case "test-analyze": return try await testAnalyze(o, env: env)
            case "process", "run": return try await failureNotified(o, env: env) { try await process(o, env: env) }
            case "sync": return try await failureNotified(o, env: env) { try await sync(o, env: env) }
            case "index": return try await failureNotified(o, env: env) { await index(o, env: env) }
            case "live": return try await counted(o, env: env) { try await live(o, env: env) }
            case "stream": return try await counted(o, env: env) { try await stream(o, env: env) }
            case "coach": return try await counted(o, env: env) { try coach(o, env: env) }
            default: throw UsageError(description: "unknown command: \(o.command)")  // parse() admits only `commands`
            }
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("\(usage)\npalaver-worker: \(error)\n".utf8))
            return EXIT_USAGE
        } catch {
            FileHandle.standardError.write(Data("palaver-worker: \(error)\n".utf8))
            return EXIT_ERROR
        }
    }

    // MARK: - what the commands share

    static func stores(_ env: [String: String]) -> StorePaths { StorePaths.current(env: env) }

    static func configURL(_ o: Options, env: [String: String]) -> URL {
        o.config.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? stores(env).configToml
    }

    static func loadConfig(_ o: Options, env: [String: String]) -> Config {
        Config.load(configURL(o, env: env), environment: env)
    }

    /// The transcriber's dictionary: `--dictionary`, else the one beside config.toml.
    static func dictionary(_ o: Options, env: [String: String]) -> TranscriberDictionary {
        TranscriberDictionary.load(o.dictionary.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? stores(env).dictionary)
    }

    /// The calendar: whether it is on, and the events (nil when it is off or not allowed; never asks).
    static func calendar(_ config: Config, env: [String: String]) -> (enabled: Bool, provider: CalendarProvider?) {
        #if DEBUG
        // The parity and end-to-end runs' fake calendar (a JSON list of events) instead of this Mac's.
        if let file = env["PALAVER_TEST_CALENDAR"] {
            let events = (PythonJSON.read(URL(fileURLWithPath: file))?.arrayValue ?? []).compactMap { try? CalendarEvent(json: $0) }
            return (true, { start, end in events.filter { $0.start.date < end && $0.end.date > start } })
        }
        #endif
        guard config.calendarEnabled else { return (false, nil) }
        let kit = EventKitCalendar()
        guard kit.hasAccess() else { return (true, nil) }
        return (true, { try kit.eventsBetween($0, $1) })
    }

    /// The speech engine `process`, `live` and `stream` use: in this process (debug builds: `PALAVER_TEST_ENGINE`'s
    /// answers). Whisper is not part of the worker: a config that names `mlx-whisper` or `parakeet-mlx` gets the
    /// engine's Parakeet, said once in the log.
    public static func makeEngine(config: Config, dictionary: TranscriberDictionary, env: [String: String],
                                  log: SessionLog?) -> EngineCalls {
        if let note = transcriberNote(config.transcriber) { log?.message(note, logger: "palaver.worker") }
        #if DEBUG
        if let fake = FakeEngine.fromEnvironment(env, dictionary: dictionary) { return fake }
        #endif
        let version = AppLocation(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).version()
        return InProcessEngine(version: version, modelsDir: modelsDir(env), dictionary: dictionary)
    }

    /// The log line for a transcriber the worker answers with the engine instead.
    public static func transcriberNote(_ transcriber: String) -> String? {
        guard ["mlx-whisper", "parakeet-mlx"].contains(transcriber) else { return nil }
        return "transcriber \(transcriber) runs on the speech engine (Parakeet, palaver-worker)"
    }

    static func modelsDir(_ env: [String: String]) -> URL {
        stores(env).modelsDir.appendingPathComponent(ModelCatalog.SPEECH_FOLDER, isDirectory: true)
    }

    /// Runs `body` with stdout pointing at stderr, then writes `line` alone on stdout: nothing a library prints can
    /// mix into the one JSON line the caller reads (app_query.py `run`).
    static func answerAlone(_ body: () -> (line: String, code: Int32)) -> Int32 {
        fflush(stdout)
        let saved = dup(1)
        dup2(2, 1)
        let (line, code) = body()
        fflush(stdout)
        if saved >= 0 {
            dup2(saved, 1)
            close(saved)
        }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
        return code
    }

    // MARK: - query, calendar-attach, engine-serve

    static func query(_ o: Options, env: [String: String]) -> Int32 {
        let rest = o.args.filter { $0 != "--json" }
        return answerAlone {
            Queries.run(rest.first, args: Array(rest.dropFirst()), config: { loadConfig(o, env: env) },
                        calendar: { calendar($0, env: env).provider })
        }
    }

    static func calendarAttach(_ o: Options, env: [String: String]) throws -> Int32 {
        var since: Double?
        if let text = try flag("--since", in: o.args) {
            guard let hours = Double(text) else { throw UsageError(description: "--since: not a number: \(text)") }
            since = hours
        }
        return answerAlone {
            do {
                let config = loadConfig(o, env: env)
                let (enabled, provider) = calendar(config, env: env)
                let answer = try CalendarAttach.answer(config: config, enabled: enabled, provider: provider, since: since,
                                                       stores: stores(env))
                return (answer.encoded(indent: nil), 0)
            } catch {
                return (JSONValue.object([("error", .string("\(error)"))]).encoded(indent: nil), EXIT_ERROR)
            }
        }
    }

    static func engineServe(_ o: Options, env: [String: String]) async throws -> Int32 {
        let version = try flag("--version", in: o.args) ?? "dev"
        let models = try flag("--models", in: o.args).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? modelsDir(env)
        await EngineServe.run(engine: InProcessEngine(version: version, modelsDir: models))
        return 0
    }

    // MARK: - process

    /// Why `folder` can't be processed now, with its exit code; nil when it can (cli.py `_cmd_process`'s checks).
    static func refusal(_ folder: URL, _ o: Options, config: Config, stores: StorePaths = .current(),
                        speechModelsHere: () -> Bool) -> (String, Int32)? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            return ("error: \(folder.path) is not a recording folder.", EXIT_USAGE)
        }
        if let d = o.dictionary {
            let file = URL(fileURLWithPath: (d as NSString).expandingTildeInPath)
            var dir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: file.path, isDirectory: &dir) || dir.boolValue {
                return ("error: dictionary \(file.path) not found.", EXIT_USAGE)
            }
        }
        if let recording = Recording.stillRecording(folder, stores: stores).first {
            return ("error: \(recording.lastPathComponent) is still being recorded; "
                    + "\(folder.lastPathComponent) is processed once the recording stops.", EXIT_BUSY)
        }
        if let busy = Recording.liveBusy(folder).first {
            return ("error: \(busy.lastPathComponent) is still being processed live; try again in a minute.", EXIT_BUSY)
        }
        let paths = RecordingPaths(folder)
        let missing = ProcessState.missingModels(transcriber: config.transcriber, paths: paths, speechModelsHere: speechModelsHere)
        if !missing.isEmpty {  // recorded before the setup's downloads finished: the app transcribes it once they did
            try? ProcessState.mark(paths, reason: ProcessState.models, missing: missing)
            return ("error: waiting for \(missing.joined(separator: " and ")), not downloaded yet; "
                    + "\(folder.lastPathComponent) is transcribed once it is.", EXIT_MODELS)
        }
        return nil
    }

    static func process(_ o: Options, env: [String: String]) async throws -> Int32 {
        let folder = try folderArgument(o)
        let config = loadConfig(o, env: env)
        var here: () -> Bool = { ModelCatalog.speechFilesHere(stores: stores(env)) }
        #if DEBUG
        if let fake = FakeEngine.fromEnvironment(env, dictionary: TranscriberDictionary()) { here = fake.modelsReady }
        #endif
        if let (message, code) = refusal(folder, o, config: config, stores: stores(env), speechModelsHere: here) {
            print(message)
            fflush(stdout)
            return code
        }
        let setup = pipelineSetup(o, config: config, folder: folder, env: env)
        let notes = !o.args.contains("--no-notes")
        if o.command == "run" { return try await Run.run(folder, setup) }
        return try await Pipeline.process(folder, setup, notes: notes)
    }

    /// `sync <folder>` (cli.py `_cmd_sync`, the `palaver sync` command): the transcript of a processed recording to
    /// Notion (`Run.sync`). A folder without a transcript is exit 2, as `palaver notes` says it.
    static func sync(_ o: Options, env: [String: String]) async throws -> Int32 {
        let folder = try folderArgument(o)
        let paths = RecordingPaths(folder)
        guard FileManager.default.fileExists(atPath: paths.transcriptJson.path) else {
            print("error: \(folder.path) has no transcript yet — run `process` first.")
            fflush(stdout)
            return EXIT_USAGE
        }
        let config = loadConfig(o, env: env)
        return try await Run.sync(paths, pipelineSetup(o, config: config, folder: folder, env: env))
    }

    /// What `process` and `run` work with: the user's name, the dictionary, the engine, the calendar, the keys and the
    /// transport of the cloud steps, the notes helper with the options this worker got.
    static func pipelineSetup(_ o: Options, config: Config, folder: URL, env: [String: String]) -> Pipeline.Setup {
        let stores = stores(env)
        let dictionary = dictionary(o, env: env)
        let engine = makeEngine(config: config, dictionary: dictionary, env: env,
                                log: SessionLog(url: RecordingPaths(folder).sessionLog, logger: "palaver"))
        var cloud = CloudServices(keys: KeyStores.make(env: env), configToml: configURL(o, env: env), env: env)
        #if DEBUG
        cloud.heard = FakeEngine.cloudHeard(env)
        #endif
        var setup = Pipeline.Setup(config: config, userName: SettingsFile.currentUserName(default: config.userName, stores: stores),
                                   dictionary: dictionary, dictionaryPath: o.dictionary.map { ($0 as NSString).expandingTildeInPath },
                                   engine: engine, python: helper(o, env: env), calendar: calendar(config, env: env),
                                   stores: stores, cloud: cloud)
        setup.lm = AppLocation.languageModelWorker(beside: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                                                   environment: env)
        return setup
    }

    /// The helper this worker starts (palaver-lm, beside it), with the options this worker got.
    static func helper(_ o: Options, env: [String: String]) -> PythonHelper {
        let lm = AppLocation.languageModelWorker(beside: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                                                 environment: env)
        var options: [String] = []
        if let c = o.config { options += ["--config", c] }
        if let d = o.dictionary { options += ["--dictionary", d] }
        if o.noNotify { options.append("--no-notify") }
        return PythonHelper(python: lm, options: options, env: env)
    }

    /// cli.py `main`: a command the app ran that failed says so in a notification, with the short reason; the usage
    /// log counts the command.
    static func failureNotified(_ o: Options, env: [String: String], _ body: () async throws -> Int32) async throws -> Int32 {
        recordUsage(o, env: env)
        do {
            let rc = try await body()
            fflush(stdout)
            if rc != 0 { Notify.send(title: "palaver \(o.command) failed", message: "exit code \(rc); see terminal") }
            return rc
        } catch {
            fflush(stdout)
            Notify.send(title: "palaver \(o.command) failed", message: Pipeline.failureReason(error))
            throw error
        }
    }

    /// cli.py `main` for its quiet commands (live, stream, coach): counted in the usage log, never a notification.
    static func counted(_ o: Options, env: [String: String], _ body: () async throws -> Int32) async throws -> Int32 {
        recordUsage(o, env: env)
        let rc = try await body()
        fflush(stdout)
        return rc
    }

    /// A command a person typed is a feature used; the app's own (live, process …) is not (#59).
    static func recordUsage(_ o: Options, env: [String: String]) {
        Usage.record("cli", o.command, fields: [("by", .string(isatty(0) != 0 ? "user" : "app")), ("action", .null)], path: stores(env).usage)
    }
}

// MARK: - index

extension WorkerMain {
    /// `index [folder…]`: the search-by-meaning index (cli.py `_cmd_index`).
    static func index(_ o: Options, env: [String: String]) async -> Int32 {
        let config = loadConfig(o, env: env)
        let stores = stores(env)
        let folders = o.args.filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        var modelFolder: () -> URL? = { E5Encoder.modelFolder(stores: stores) }
        var freeGB: () -> Double = FreeMemory.availableGB
        #if DEBUG
        // Tests: the e5 model's folder (there or not) and the free memory, in place of this Mac's.
        if let folder = env["PALAVER_TEST_E5_FOLDER"], !folder.isEmpty {
            modelFolder = { FileManager.default.fileExists(atPath: folder) ? URL(fileURLWithPath: folder, isDirectory: true) : nil }
        }
        if let file = env["PALAVER_TEST_FREE_GB"], !file.isEmpty {
            freeGB = { (try? String(contentsOfFile: file, encoding: .utf8)).flatMap { Double(Py.strip($0)) } ?? FreeMemory.availableGB() }
        }
        #endif
        let configToml = o.config.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? stores.configToml
        let download = {
            try Index.downloadE5(hub: HubDownloader(stores: stores, env: env)) {
                Tokens.huggingFace(configToml: configToml, env: env, keys: KeyStores.make(env: env), home: stores.home)
            }
        }
        let rc = await Index.run(outputDir: config.outputDir, only: folders.isEmpty ? nil : folders, stores: stores,
                                 download: download, modelFolder: modelFolder, encoder: { try E5Encoder(folder: $0) },
                                 shouldStop: Index.shouldStop(stores: stores, freeGB: freeGB))
        fflush(stdout)
        return rc
    }
}

/// Whether a meeting (its first part and the parts that continue it) is still being recorded or processed live
/// (continuation.py `still_recording`, live.py `worker_running`).
enum Recording {
    static func stillRecording(_ head: URL, stores: StorePaths) -> [URL] { Continuation.stillRecording(head, stores: stores) }

    static func liveBusy(_ head: URL) -> [URL] { ([head] + Continuation.parts(head)).filter(WorkerPids.liveRunning) }
}
