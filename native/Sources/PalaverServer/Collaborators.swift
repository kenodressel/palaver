// What the server asks of other processes: the menu bar app (app.sock), the language model's
// helpers, the provider helper, the setup probe. One protocol each with its real implementation
// (ServeMain.makeApp wires them all); the internal `Stub*` ones answer 503 for tests that leave
// one out. The menu bar app's is `Remote` (Remote.swift).
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

/// The menu bar app as the window's server reaches it (webapp/remote.py's `RemoteRecording`,
/// `RemoteCalendar`, `RemoteTest`, and api.py's update and uninstall calls): what it knows from
/// daemon.json, what it does through app.sock. `ServerApp.recording` is nil outside the app (Python's
/// `recording=None`). `Remote` is the real one; tests have fakes.
public protocol RecordingRemote: AnyObject {
    /// The open question about the running recording (daemon.json `stop_question`), or nil.
    func question() -> JSONValue?
    /// Why the running recording records and what is wrong with its audio: `{meeting, text, warnings, hints}`, or nil.
    func recording() -> JSONValue?
    /// Who talks in the running recording and the coach's nudge: `{meeting, talk, text, nudge, quiet}`, or nil.
    func coach() -> JSONValue?
    /// What Palaver costs in memory now (daemon.json `memory`), or nil.
    func memory() -> JSONValue?
    /// `{"indexing": bool, "downloading": bool}`.
    func indexing() -> JSONValue
    /// A recording or its processing runs (or it is not known): background work waits.
    func busy() -> Bool
    /// "stop" or "keep" the manual recording `meeting`; false when it no longer runs. Throws `Refused`.
    func answer(choice: String, meeting: String) throws -> Bool
    /// A helper this server started: the app watches its memory. Never throws.
    func watch(folder: URL, pid: Int32)
    /// Has the app start a language model's helper; its pid. Throws `AppCtlClient.CallFailed`/`CallRefused`.
    func startHelper(kind: String, key: String, args: [String]) throws -> Int32
    /// Transcribe Again: the app queues `folder` first; false while it is transcribed already. Throws `Refused`.
    func transcribe(folder: URL) throws -> Bool
    /// "start" or "stop" a recording: the app's answer, `{"meeting"}` or `{"stopped"}`. Throws `Refused`.
    func record(action: String, meeting: String?) throws -> JSONValue
    /// A record switch turned off in Settings: that app's call stops now. Never throws.
    func switchedOff(app: String)
    /// The calendar permission as the app has it, else as this process sees it.
    func calendarStatus() -> JSONValue
    /// Asks for the calendar permission in the app. Throws `Refused`.
    func calendarConnect() throws -> JSONValue
    /// The setup assistant's test recording (`RemoteTest._call`): the app's answer to `test` with `args`.
    /// Throws `AppCtlClient.CallFailed`/`CallRefused`.
    func test(_ args: JSONValue, timeout: Double) throws -> JSONValue
    /// Look for a release now (#60). Throws `Refused` (`APP_GONE` when the app does not answer).
    func updateCheck() throws -> JSONValue
    /// Download the release and install it at the next idle moment. Throws `Refused`.
    func updateInstall() throws -> JSONValue
    /// `{"models", "recordings"}`: the app quits and removes itself. Throws `Refused`.
    func uninstall(_ args: JSONValue) throws -> JSONValue
}

/// `palaver-lm notes` / `projects` through the app, or from here (webapp/__init__.py `helper`; Task 43):
/// the helper's exit code, nil when it never ran.
public protocol HelperRunner: AnyObject {
    func run(kind: String, key: String, args: [String]) throws -> Int32?
}

/// `palaver-lm next-question` (webapp/__init__.py `ask_model`; Task 43).
public protocol NextQuestionAsker: AnyObject {
    func ask(meetingId: String, inputs: JSONValue) throws -> JSONValue
}

/// The provider actions (Task 46; phase 4: `Providers`, in this process): one call with its JSON body.
public protocol ProviderHelper: AnyObject {
    func call(_ action: String, body: JSONValue, timeout: Double) throws -> JSONValue
}

/// The setup assistant's look at this Mac (onboarding.Probe). Read-only: it never asks for a permission; its downloads run
/// only when the user (or a meeting waiting for its models) starts them. `MacProbe` is the real one (Setup/Probe.swift),
/// `TestProbe` the end-to-end tests' (DEBUG).
public protocol SetupProbe: AnyObject {
    /// The chip, the memory and the free disk.
    func hardware() -> Hardware
    /// Teams, Slack, Claude Code, Claude Desktop.
    func installed() -> Installed
    /// permission key → `{state, detail[, fix]}`: microphone, calendar, system_audio, notifications.
    func permissions() -> PyDict<JSONValue>
    /// The models (`ModelCatalog.models` ids) whose every file is on this Mac, in their order.
    func downloaded() -> [String]
    /// The user's full name as macOS has it; "" when it can't say.
    func fullName() -> String
    /// Palaver starts at login.
    func autostart() -> Bool
    func setAutostart(_ on: Bool) throws
    /// The calendar's events between `start` and `end` (none when the calendar is off).
    func calendarEvents(_ start: Date, _ end: Date) throws -> [CalendarEvent]
    /// Whether the speech models are ready (onboarding.speech_here).
    func speechHere() -> Bool
    var downloads: SetupDownloads { get }
}

/// Report a Problem (#59, Task 47): the report zip on the Desktop, shown in Finder; the window's answer for `body`, the
/// report form as the page posts it.
public protocol ReportMaker: AnyObject {
    func create(_ body: JSONValue) throws -> JSONValue
}

let notWired = "not wired"

/// For tests that leave it out: 503.
final class StubHelperRunner: HelperRunner {
    init() {}
    func run(kind: String, key: String, args: [String]) throws -> Int32? { throw Unavailable(notWired) }
}

/// `build_app`'s `helper`: `palaver notes` / `projects`, started by the menu bar app (#57), so the memory watchdog
/// counts it during calls and it outlives a restart of this server, which waits for it through its record
/// (ModelJobs). Run from here when the app does not answer. Its exit code once it ended (nil: the app refused to start
/// it, or nothing is known of its end); `ModelBusy` for `EXIT_MODEL_BUSY` (`projects --no-wait` found the model taken).
public final class AppHelperRunner: HelperRunner, @unchecked Sendable {
    /// cli.py `EXIT_MODEL_BUSY`.
    public static let EXIT_MODEL_BUSY: Int32 = 75

    public typealias Argv = (_ kind: String, _ args: [String]) throws -> [String]

    let jobs: URL
    let recording: RecordingRemote?
    let argv: Argv
    let spawn: ModelJobs.Spawn
    let poll: Double
    let log: (String, String) -> Void

    /// `argv(kind, args)`: the helper's command when this server starts it (`ModelJobs.helperArgv` with the server's
    /// options); `spawn` starts it; `poll`: how often its record is read while it runs; `log(level, line)`: daemon.log.
    public init(outputDir: URL, recording: RecordingRemote?, argv: @escaping Argv, spawn: @escaping ModelJobs.Spawn = ModelJobs.spawnHelper,
                poll: Double = ModelJobs.POLL_SECONDS, log: @escaping (String, String) -> Void = { _, _ in }) {
        jobs = ModelJobs.root(outputDir)
        self.recording = recording
        self.argv = argv
        self.spawn = spawn
        self.poll = poll
        self.log = log
    }

    /// The server's own: `ModelJobs.helperArgv` with `cliOptions` and palaver-lm.
    public convenience init(outputDir: URL, recording: RecordingRemote?, cliOptions: [String], lm: String,
                            log: @escaping (String, String) -> Void = { _, _ in }) {
        self.init(outputDir: outputDir, recording: recording, argv: { kind, args in
            try ModelJobs.helperArgv(kind: kind, args: args, cliOptions: cliOptions, lm: lm, outputDir: outputDir)
        }, log: log)
    }

    public func run(kind: String, key: String, args: [String]) throws -> Int32? {
        var started = false
        if let recording {
            do {
                _ = try recording.startHelper(kind: kind, key: key, args: args)
                started = true
            } catch is AppCtlClient.CallFailed {
                log("INFO", "the app did not answer: \(kind) runs from the window's server")
            } catch let e as AppCtlClient.CallRefused {
                log("WARNING", "the app did not start \(kind): \(e)")
                return nil
            }
        }
        if !started {
            _ = try ModelJobs.launch(root: jobs, kind: kind, key: key, argv: try argv(kind, args), spawn: spawn)
        }
        let job = try ModelJobs.wait(jobs, kind: kind, key: key, poll: poll)
        try ModelJobs.clear(jobs, kind: kind, key: key)
        let code: Int32?
        switch job["returncode"] {
        case .int(let i)?: code = Int32(exactly: i)
        case .double(let d)?: code = Int32(exactly: d)
        case .bool(let b)?: code = b ? 1 : 0
        default: code = nil
        }
        if code == Self.EXIT_MODEL_BUSY { throw ModelBusy() }
        return code
    }
}

/// For tests that leave it out: 503.
final class StubNextQuestionAsker: NextQuestionAsker {
    init() {}
    func ask(meetingId: String, inputs: JSONValue) throws -> JSONValue { throw Unavailable(notWired) }
}

/// `build_app`'s `ask_model`: the best next question (#41) from `[taskpolicy -c utility] palaver-lm <options> --no-notify
/// next-question <folder>`, in a session of its own so the memory watchdog (#49) can stop it and its children; the app
/// watches it with the notes' budget for the meeting. stdin is the inputs, the last line it prints the answer. Its
/// errors are `BadGateway`s, safe to show.
public final class LMNextQuestion: NextQuestionAsker, @unchecked Sendable {
    static let NO_ANSWER = "The language model gave no answer; see the log."
    static let TOO_LONG = "The language model took more than 10 minutes; it was stopped."
    static let STOPPED = "The local model was stopped: the Mac ran low on memory."
    /// `communicate(timeout=600)`.
    public static let TIMEOUT = 600.0

    let outputDir: URL
    let lm: String
    let cliOptions: [String]
    let recording: RecordingRemote?
    let taskpolicy: String
    let timeout: Double
    let env: [String: String]

    public init(outputDir: URL, lm: String, cliOptions: [String], recording: RecordingRemote?,
                taskpolicy: String = ModelJobs.TASKPOLICY, timeout: Double = LMNextQuestion.TIMEOUT,
                env: [String: String] = ProcessInfo.processInfo.environment) {
        self.outputDir = outputDir
        self.lm = lm
        self.cliOptions = cliOptions
        self.recording = recording
        self.taskpolicy = taskpolicy
        self.timeout = timeout
        self.env = env
    }

    public func ask(meetingId: String, inputs: JSONValue) throws -> JSONValue {
        let folder = try MeetingsAPI.meetingPaths(outputDir: outputDir, id: meetingId).folder
        var argv = [lm] + cliOptions + ["--no-notify", "next-question", folder.path]
        if FileManager.default.fileExists(atPath: taskpolicy) { argv = [taskpolicy, "-c", "utility"] + argv }
        let done: HelperChild.Finished
        do {
            done = try HelperChild.run(argv, env: env, input: Data(PythonJSON.dumps(inputs, ensureAscii: false).utf8),
                                       timeout: timeout) { recording?.watch(folder: folder, pid: $0) }
        } catch is HelperChild.TimedOut {
            throw BadGateway(Self.TOO_LONG)
        } catch {
            throw BadGateway(Self.NO_ANSWER)
        }
        if done.code < 0 { throw BadGateway(Self.STOPPED) }
        let lines = ModelJobs.splitlines(Py.strip(String(decoding: done.stdout, as: UTF8.self)))
        guard let answer = try? PythonJSON.parse(Data((lines.last ?? "{}").utf8)) else { throw BadGateway(Self.NO_ANSWER) }
        guard case .object = answer, answer["error"] == nil, answer["questions"] != nil else {
            // `str((out or {}).get("error") or NO_ANSWER)`
            if answer.truthy, !answer.isObject {
                throw PyBody.TypeError(description: "'\(PyBody.typeName(answer))' object has no attribute 'get'")
            }
            throw BadGateway(answer["error"].flatMap { $0.truthy ? Py.str($0) : nil } ?? Self.NO_ANSWER)
        }
        return answer
    }
}

/// A helper process as `subprocess.run(argv, input=…, capture_output=True, timeout=…, start_new_session=True)` runs it:
/// in a session of its own, its stdin written and its stdout and stderr read at the same time (either may fill its
/// pipe), the one budget covering the reads and the exit. When the budget runs out the helper's whole group is killed,
/// so a grandchild that keeps stdout open cannot hold the reads, and the helper is reaped. stderr is read and its last
/// `STDERR_TAIL` bytes kept in `Finished.stderr` (a 6 h download writes progress all along); only a caller that says
/// so shows any of it (a model download's last line).
enum HelperChild {
    /// The end of stderr kept, from the start of a line.
    static let STDERR_TAIL = 64 * 1024

    struct Finished {
        let stdout: Data
        let stderr: Data
        /// The exit code; below 0 the signal that ended it (`Popen.returncode`).
        let code: Int32
    }

    /// It never started (the pipes, the spawn).
    struct NotStarted: Error {}
    /// The budget ran out: it was killed with its group.
    struct TimedOut: Error {}

    /// `started(pid)` runs once it is spawned, before its input is written.
    static func run(_ argv: [String], env: [String: String], input: Data, timeout: Double,
                    started: (Int32) -> Void = { _ in }) throws -> Finished {
        var stdin: [Int32] = [0, 0], output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&stdin) == 0 else { throw NotStarted() }
        guard pipe(&output) == 0 else { close(stdin[0]); close(stdin[1]); throw NotStarted() }
        guard pipe(&errors) == 0 else {
            for fd in stdin + output { close(fd) }
            throw NotStarted()
        }
        for fd in stdin + output + errors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }  // the child gets its dups only
        _ = fcntl(stdin[1], F_SETNOSIGPIPE, 1)  // a helper that stops reading is no reason to die
        let process: PalaverCore.Process
        do {
            process = try spawnChild(argv, env: env, stdin: stdin[0], output: output[1], errors: errors[1])
        } catch {
            for fd in stdin + output + errors { close(fd) }
            throw NotStarted()
        }
        close(stdin[0])
        close(output[1])
        close(errors[1])
        started(process.pid)

        let writer = Thread {
            input.withUnsafeBytes { raw in
                var done = 0
                while done < raw.count {
                    let n = Darwin.write(stdin[1], raw.baseAddress! + done, raw.count - done)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }  // it stopped reading
                    done += n
                }
            }
            close(stdin[1])
        }
        writer.start()
        let read = DispatchGroup()
        final class Box: @unchecked Sendable { var data = Data() }
        let out = Box(), err = Box()
        for (fd, box, tail) in [(output[0], out, nil), (errors[0], err, STDERR_TAIL)] {
            read.enter()
            Thread {
                box.data = readAll(fd, keepingTail: tail)
                close(fd)
                read.leave()
            }.start()
        }
        let deadline = Date().addingTimeInterval(timeout)
        func killGroup() {
            process.signalGroup(SIGKILL)  // not to a pid already reaped
            if process.poll() != nil { killpg(process.pid, SIGKILL) }  // the leader is gone, its children may not be
        }
        if read.wait(timeout: .now() + timeout) == .timedOut {
            killGroup()
            read.wait()
            process.waitUntilExit()
            throw TimedOut()
        }
        guard let status = process.waitUntilExit(timeout: max(0, deadline.timeIntervalSinceNow)) else {
            killGroup()
            process.waitUntilExit()
            throw TimedOut()
        }
        return Finished(stdout: out.data, stderr: err.data, code: process.poll() ?? status)
    }

    /// Everything up to EOF; with `keepingTail`, only its last bytes from the first whole line in them.
    static func readAll(_ fd: Int32, keepingTail limit: Int? = nil) -> Data {
        var out = Data()
        var cut = false
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
            if let limit, out.count > 2 * limit {  // dropped now and then, not at every read
                out = out.suffix(limit)
                cut = true
            }
        }
        guard let limit else { return out }
        if out.count > limit { out = out.suffix(limit); cut = true }
        if cut, let newline = out.firstIndex(of: UInt8(ascii: "\n")) { out = out[(newline + 1)...] }
        return Data(out)
    }
}

/// For tests that leave it out: 503.
final class StubProviderHelper: ProviderHelper {
    init() {}
    func call(_ action: String, body: JSONValue, timeout: Double) throws -> JSONValue { throw Unavailable(notWired) }
}

/// For tests that leave it out: 503.
final class StubReportMaker: ReportMaker {
    init() {}
    func create(_ body: JSONValue) throws -> JSONValue { throw Unavailable(notWired) }
}
