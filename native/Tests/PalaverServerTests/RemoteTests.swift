// The window's server asks the recording process what it needs (tests/test_webapp_remote.py, #57): the
// running recording from daemon.json, actions through app.sock. When the recording process does not
// answer, the page still shows, without the live bits. Fakes only: a daemon.json and a socket in a
// temporary folder (a Swift fake, or Python's own appctl.serve through uv), never the real app's.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"
private let FOLDER = "/m/\(MEETING)"
/// 2026-10-30T09:00:00+01:00
private let NOW = Date(timeIntervalSince1970: 1_793_347_200)

private let STATUS: JSONValue = .object([
    ("state", .string("recording")), ("manual", .bool(true)), ("folder", .string(FOLDER)), ("transcribing", .bool(false)),
    ("indexing", .bool(true)), ("index_downloading", .bool(false)),
    ("stop_question", .object([("meeting", .string(MEETING)), ("reason", .string("silence")), ("minutes", .int(10)),
                               ("message", .string("Silent for 10 min"))])),
    ("why_text", .string("Recording · manual since 08:02 · mic MacBook (48 kHz)")),
    ("warnings", .strings(["The mic was silent for 2 min"])), ("hints", .strings(["Wear headphones? never"])),
    ("memory", .object([("app", .int(300)), ("workers", .array([]))])),
    ("talk", .object([("speaking", .string("me")), ("share", .double(0.4))])), ("talk_text", .string("You 40 %")),
    ("nudge", .null), ("quiet", .strings(["Rico"])),
    ("pid", .int(Int(getpid()))), ("updated", .string("2026-10-30T09:00:00+01:00")),
])

private func with(_ status: JSONValue, _ changes: [(String, JSONValue)]) -> JSONValue {
    guard case .object(var fields) = status else { return status }
    for (k, v) in changes {
        if let i = fields.firstIndex(where: { $0.0 == k }) { fields[i].1 = v } else { fields.append((k, v)) }
    }
    return .object(fields)
}

/// A folder for daemon.json and app.sock, short enough for a socket's path.
final class AppFolder {
    let dir = shortFolder()
    var state: URL { dir.appendingPathComponent("daemon.json") }
    var socket: URL { dir.appendingPathComponent("app.sock") }
    deinit { try? FileManager.default.removeItem(at: dir) }

    /// The server's remote on this folder; `status` written as daemon.json first (nil: none).
    func remote(_ status: JSONValue? = STATUS, now: Date = NOW, alive: @escaping (JSONValue?) -> Bool = { _ in true },
                localCalendar: @escaping () -> JSONValue = { .object([("state", .string("unknown"))]) }) -> Remote {
        if let status { try! Data(PythonJSON.dumps(status).utf8).write(to: state) }
        return Remote(statePath: state, socketPath: socket, now: { now }, alive: alive, localCalendar: localCalendar)
    }

    func serve(_ answer: @escaping (String, JSONValue) -> FakeAppSocket.Answer) -> FakeAppSocket {
        FakeAppSocket(socket, answer: answer)
    }
}

private func expectRefused(_ text: String, _ body: () throws -> Any) {
    do {
        _ = try body()
        Issue.record("not refused")
    } catch let e as Refused {
        #expect(e.text.contains(text), "\(e.text)")
    } catch {
        Issue.record("\(error)")
    }
}

@Suite struct RemoteTests {
    @Test func test_the_running_recording_comes_from_daemon_json() {
        let f = AppFolder()
        let r = f.remote()
        #expect(r.question() == STATUS["stop_question"])
        #expect(r.recording() == .object([("meeting", .string(MEETING)), ("text", STATUS["why_text"]!),
                                          ("warnings", STATUS["warnings"]!), ("hints", STATUS["hints"]!)]))
        #expect(r.coach().map { PythonJSON.dumps($0) } == PythonJSON.dumps(.object([
            ("meeting", .string(MEETING)), ("talk", STATUS["talk"]!), ("text", .string("You 40 %")), ("nudge", .null),
            ("quiet", .strings(["Rico"]))])))
        #expect(r.memory() == .object([("app", .int(300)), ("workers", .array([]))]))
        #expect(r.indexing() == .object([("indexing", .bool(true)), ("downloading", .bool(false))]))
        #expect(r.busy())
    }

    @Test func test_idle_has_nothing_live() {
        let f = AppFolder()
        let idle = with(STATUS, [("state", .string("idle")), ("folder", .null), ("why_text", .null), ("stop_question", .null),
                                 ("talk", .null), ("indexing", .bool(false))])
        let r = f.remote(idle)
        #expect(r.question() == nil && r.recording() == nil && r.coach() == nil)
        #expect(!r.busy())
        #expect(f.remote(with(idle, [("transcribing", .bool(true))])).busy())
    }

    @Test(arguments: ["missing", "broken", "stopped", "dead", "stale"])
    func test_without_a_recording_process_the_live_bits_are_left_out(_ c: String) throws {
        let f = AppFolder()
        var status: JSONValue? = STATUS
        var alive: (JSONValue?) -> Bool = { _ in true }
        var now = NOW
        switch c {
        case "missing": status = nil
        case "stopped": status = with(STATUS, [("state", .string("stopped"))])
        case "dead": alive = { _ in false }
        case "stale": now = NOW.addingTimeInterval(5 * 60)
        default: break
        }
        let r = f.remote(status, now: now, alive: alive)
        if c == "broken" { try Data("{not json".utf8).write(to: f.state) }
        #expect(r.question() == nil && r.recording() == nil && r.coach() == nil && r.memory() == nil)
        #expect(r.indexing() == .object([("indexing", .bool(false)), ("downloading", .bool(false))]))
        // Background work waits while it is not known whether a call is recorded.
        #expect(r.busy() == (c == "stale"))
    }

    @Test func test_answer_goes_to_the_recording_process() throws {
        let f = AppFolder()
        let app = f.serve { _, _ in .ok(.bool(true)) }
        defer { app.stop() }
        #expect(try f.remote().answer(choice: "stop", meeting: MEETING))
        #expect(app.calls.map(\.0) == ["answer"])
        #expect(app.calls.first?.1 == .object([("choice", .string("stop")), ("meeting", .string(MEETING))]))
    }

    @Test func test_answer_without_a_recording_process_is_refused_with_a_reason() {
        let f = AppFolder()
        expectRefused("did not answer") { try f.remote().answer(choice: "stop", meeting: MEETING) }
    }

    @Test func test_record_goes_to_the_recording_process() throws {
        let f = AppFolder()
        let app = f.serve { _, args in
            args["action"] == .string("stop") ? .refused("This recording is no longer running.") : .ok(.object([("meeting", .string(MEETING))]))
        }
        #expect(try f.remote().record(action: "start", meeting: nil) == .object([("meeting", .string(MEETING))]))
        expectRefused("no longer running") { try f.remote().record(action: "stop", meeting: MEETING) }
        #expect(app.calls.map { PythonJSON.dumps($0.1) } == [#"{"action": "start", "meeting": null}"#,
                                                             #"{"action": "stop", "meeting": "2026-10-27T16-03-07"}"#])
        app.stop()
        expectRefused("did not answer") { try f.remote().record(action: "start", meeting: nil) }
    }

    @Test func test_watch_and_switched_off_go_to_the_recording_process() {
        let f = AppFolder()
        let app = f.serve { _, _ in .ok(.null) }
        defer { app.stop() }
        let r = f.remote()
        r.watch(folder: URL(fileURLWithPath: FOLDER), pid: 4242)
        r.switchedOff(app: "slack")
        #expect(app.calls.map { "\($0.0) \(PythonJSON.dumps($0.1))" } == [
            #"watch {"folder": "/m/2026-10-27T16-03-07", "pid": 4242}"#, #"switched_off {"app": "slack"}"#])
    }

    @Test func test_watch_and_switched_off_without_a_recording_process_change_nothing() {
        let f = AppFolder()
        var logged: [String] = []
        let r = Remote(statePath: f.state, socketPath: f.socket, log: { logged.append($0) })
        r.watch(folder: URL(fileURLWithPath: FOLDER), pid: 4242)  // no error: the helper runs unwatched
        r.switchedOff(app: "teams")
        #expect(logged == ["the helper 4242 runs without the memory watchdog: the app did not answer",
                           "the app did not answer the record switch teams"])
    }

    @Test func test_the_setup_test_recording_goes_to_the_recording_process() throws {
        let f = AppFolder()
        let app = f.serve { _, args in .ok(.object([("state", .string(args["action"] == .string("start") ? "recording" : "idle"))])) }
        defer { app.stop() }
        let t = RemoteTest(f.remote())
        #expect(try t.start(busy: { false }, mode: .object([("transcribe", .string("local"))])) == .object([("state", .string("recording"))]))
        #expect(t.status() == .object([("state", .string("idle"))]))
        #expect(PythonJSON.dumps(app.calls[0].1) == #"{"action": "start", "mode": {"transcribe": "local"}}"#)
        expectRefused("meeting is being recorded") { try t.start(busy: { true }) }
    }

    @Test func test_the_calendar_is_asked_for_by_the_recording_process() throws {
        let f = AppFolder()
        let app = f.serve { _, args in .ok(.object([("state", .string(args.truthy ? "granted" : "not_asked"))])) }
        defer { app.stop() }
        let r = f.remote()
        #expect(r.calendarStatus() == .object([("state", .string("not_asked"))]))
        #expect(try r.calendarConnect() == .object([("state", .string("granted"))]))
        #expect(app.calls.map { PythonJSON.dumps($0.1) } == ["{}", #"{"action": "connect"}"#])
    }

    @Test func test_the_calendar_without_a_recording_process() {
        let f = AppFolder()
        let r = f.remote(localCalendar: { .object([("state", .string("granted")), ("detail", .string("here"))]) })
        #expect(r.calendarStatus()["state"] == .string("granted"))  // the page still shows what this process sees
        expectRefused("did not answer") { try r.calendarConnect() }
    }

    @Test func test_the_setup_test_without_a_recording_process() {
        let t = RemoteTest(AppFolder().remote())
        #expect(t.status()["state"] == .string("idle"))  // the setup page still shows
        #expect(t.status()["max_seconds"] == .double(20.0))
        expectRefused("did not answer") { try t.start(busy: { false }) }
        #expect(t.stop()["state"] == .string("idle"))
    }

    @Test func test_start_helper_goes_to_the_app() throws {
        let f = AppFolder()
        let app = f.serve { _, _ in .ok(.object([("pid", .int(42))])) }
        #expect(try f.remote().startHelper(kind: "notes", key: MEETING, args: ["/m", "--force"]) == 42)
        #expect(PythonJSON.dumps(app.calls[0].1) == #"{"kind": "notes", "key": "2026-10-27T16-03-07", "args": ["/m", "--force"]}"#)
        app.stop()
        #expect(throws: AppCtlClient.CallFailed.self) { try f.remote().startHelper(kind: "notes", key: MEETING, args: []) }
    }

    @Test func test_a_daemon_json_the_swift_app_wrote_reads_the_same() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/fixtures/swift_daemon/daemon.json")
        let status = try PythonJSON.parse(Data(contentsOf: fixture))
        let updated = try PyDateTime.parse(status["updated"]!.stringValue!).date
        let f = AppFolder()
        let r = f.remote(status, now: updated.addingTimeInterval(1))
        #expect(r.question() == status["stop_question"] && r.question()?["reason"] == .string("silence"))
        #expect(r.recording() == .object([("meeting", .string("2026-11-04T09-00-00")), ("text", status["why_text"]!),
                                          ("warnings", .strings(["No system audio is arriving"])), ("hints", .array([]))]))
        #expect(r.memory() == status["memory"] && r.busy())
        #expect(r.indexing() == .object([("indexing", .bool(false)), ("downloading", .bool(false))]))
    }

    // MARK: - beyond the Python tests

    /// The bytes on the wire are json.dumps's: `{"call": …, "args": …}`, ASCII-escaped, one line.
    @Test func theRequestIsAppctlsLine() throws {
        let f = AppFolder()
        let app = f.serve { _, _ in .ok(.bool(true)) }
        defer { app.stop() }
        _ = try f.remote().answer(choice: "keep", meeting: "Straße")
        _ = try AppCtlClient.call("ping", nil, path: f.socket)
        #expect(app.lines == [#"{"call": "answer", "args": {"choice": "keep", "meeting": "Stra\u00dfe"}}"# + "\n",
                              #"{"call": "ping", "args": {}}"# + "\n"])
    }

    @Test func theAnswersAsAppctlReadsThem() throws {
        let f = AppFolder()
        let app = f.serve { name, _ in
            switch name {
            case "ok": return .ok(.array([.int(1)]))
            case "null": return .ok(.null)
            case "refused": return .refused("no")
            case "refused-empty": return .raw(#"{"error": "", "refused": true}"#)
            case "failed": return .failed("boom")
            case "none": return .raw(#"{"refused": false}"#)
            case "junk": return .raw("not json")
            default: return .raw("[1]")
            }
        }
        defer { app.stop() }
        func call(_ n: String) throws -> JSONValue { try AppCtlClient.call(n, path: f.socket) }
        #expect(try call("ok") == .array([.int(1)]))
        #expect(try call("null") == .null)
        #expect(throws: AppCtlClient.CallRefused.self) { try call("refused") }
        do { _ = try call("refused-empty") } catch let e as AppCtlClient.CallRefused { #expect(e.message == "refused") }
        do { _ = try call("failed") } catch let e as AppCtlClient.CallFailed { #expect(e.message == "failed: boom") }
        do { _ = try call("none") } catch let e as AppCtlClient.CallFailed { #expect(e.message == "none: None") }
        do { _ = try call("junk") } catch let e as AppCtlClient.CallFailed { #expect(e.message == "junk: no answer") }
        #expect(throws: AppCtlClient.CallFailed.self) { try call("list") }
    }

    @Test func noSocketOrAHungAppIsCallFailed() throws {
        let f = AppFolder()
        do {
            _ = try AppCtlClient.call("ping", path: f.socket)
            Issue.record("answered")
        } catch let e as AppCtlClient.CallFailed {
            #expect(e.message == "ping: [Errno 2] No such file or directory")
        }
        let long = URL(fileURLWithPath: f.dir.path + "/" + String(repeating: "x", count: 120))
        do { _ = try AppCtlClient.call("ping", path: long) } catch let e as AppCtlClient.CallFailed {
            #expect(e.message == "ping: AF_UNIX path too long")
        }
        let app = f.serve { _, _ in .silent }
        defer { app.stop() }
        let started = Date()
        do { _ = try AppCtlClient.call("ping", path: f.socket, timeout: 0.3) } catch let e as AppCtlClient.CallFailed {
            #expect(e.message == "ping: timed out")
        }
        #expect(Date().timeIntervalSince(started) >= 0.3)  // it waited for the answer
    }

    @Test func thePidOfDaemonJsonIsReadAsPythonsIntDoes() {
        let me = Int(getpid())
        #expect(Remote.pidAlive(.int(me)))
        #expect(Remote.pidAlive(.string(" \(me) ")))
        #expect(Remote.pidAlive(.double(Double(me) + 0.7)))
        #expect(Remote.pidAlive(.int(1)))  // launchd: not ours, but alive
        #expect(!Remote.pidAlive(nil) && !Remote.pidAlive(.null) && !Remote.pidAlive(.string("abc")))
        #expect(!Remote.pidAlive(.double(.nan)) && !Remote.pidAlive(.int(1 << 40)) && !Remote.pidAlive(.array([])))
    }

    @Test func aTimeWithoutAnOffsetOrAFutureOneReadsAsPythonsSubtraction() {
        let f = AppFolder()
        // Naive: `aware - naive` is a TypeError, so not known; it counts as busy.
        let naive = f.remote(with(STATUS, [("updated", .string("2026-10-30T09:00:00"))]))
        #expect(naive.question() == nil && naive.busy())
        // Written a little ahead of this clock: live.
        #expect(f.remote(with(STATUS, [("updated", .string("2026-10-30T09:00:10+01:00"))])).question() != nil)
        #expect(f.remote(STATUS, now: NOW.addingTimeInterval(30)).question() != nil)  // 30 s is not stale yet
        #expect(f.remote(STATUS, now: NOW.addingTimeInterval(30.001)).question() == nil)
    }

    /// The real app's paths come from the home of `stores`, never anything else.
    @Test func theAppOfAHomeIsInItsApplicationSupport() {
        let home = tempFolder("remote-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let stores = StorePaths(configDir: home.appendingPathComponent("config/palaver"), home: home)
        let r = Remote(stores: stores)
        #expect(r.statePath.path == home.path + "/Library/Application Support/palaver/daemon.json")
        #expect(r.socketPath.path == home.path + "/Library/Application Support/palaver/app.sock")
    }

    // MARK: - against Python's own appctl.serve

    /// `uv run python` with appctl.serve on a socket in a temporary folder (no uv: skipped).
    @Test(.enabled(if: PythonAppSocket.uv != nil)) func pythonsAppctlServeUnderstandsTheClient() throws {
        let f = AppFolder()
        let py = try PythonAppSocket(f.socket)
        let r = f.remote()
        #expect(try r.record(action: "start", meeting: nil) == .object([("meeting", .string(MEETING))]))
        expectRefused("This recording is no longer running.") { try r.record(action: "stop", meeting: "Straße") }
        do { _ = try AppCtlClient.call("boom", path: f.socket) } catch let e as AppCtlClient.CallFailed {
            #expect(e.message == "boom: boom")
        }
        do { _ = try AppCtlClient.call("nope", path: f.socket) } catch let e as AppCtlClient.CallRefused {
            #expect(e.message == "unknown call 'nope'")
        }
        #expect(try AppCtlClient.call("echo", .object([("ä", .array([.double(1.5), .null]))]), path: f.socket)
                == .object([("ä", .array([.double(1.5), .null]))]))
        #expect(py.finish() == #"[{"action": "start", "meeting": null}, {"action": "stop", "meeting": "Stra\u00dfe"}]"#)
    }
}

/// Python's appctl.serve in a child (`uv run python`), with a `record` that refuses to stop, a `boom` that fails and an
/// `echo`; what `record` was asked comes out on `finish()`.
final class PythonAppSocket {
    static let uv: String? = {
        let env = ProcessInfo.processInfo.environment
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", (env["HOME"] ?? "") + "/.local/bin", (env["HOME"] ?? "") + "/.cargo/bin"]
        return dirs.map { $0 + "/uv" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()
    static let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static let script = """
    import json, pathlib, sys
    from palaver import appctl
    got = []
    def record(args):
        got.append(args)
        if args.get("action") == "stop":
            raise appctl.CallRefused("This recording is no longer running.")
        return {"meeting": "2026-10-27T16-03-07"}
    def boom(args):
        raise RuntimeError("boom")
    srv = appctl.serve(pathlib.Path(sys.argv[1]), {"record": record, "boom": boom, "echo": lambda args: args})
    print("ready", flush=True)
    sys.stdin.read()
    print(json.dumps(got), flush=True)
    srv.close()
    """

    let process = Foundation.Process()
    let input = Pipe()
    let output = Pipe()
    let scratch = tempFolder("appctl-py")

    init(_ socket: URL) throws {
        process.executableURL = URL(fileURLWithPath: Self.uv!)
        process.arguments = ["run", "--quiet", "python", "-c", Self.script, socket.path]
        process.currentDirectoryURL = Self.checkout
        var env = ProcessInfo.processInfo.environment
        env["PALAVER_HOME"] = scratch.appendingPathComponent("home").path
        env["XDG_CONFIG_HOME"] = scratch.appendingPathComponent("config").path
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let line = readLine()
        guard line == "ready" else {  // e.g. palaver does not import: this test fails, the others run on
            process.terminate()
            throw NotStarted(line: line)
        }
    }

    struct NotStarted: Error, CustomStringConvertible {
        let line: String
        var description: String { "appctl.serve did not start: \(line)" }
    }

    deinit {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: scratch)
    }

    private func readLine() -> String {
        var bytes: [UInt8] = []
        let handle = output.fileHandleForReading
        while true {
            let d = handle.readData(ofLength: 1)
            if d.isEmpty || d.first == 0x0A { break }
            bytes.append(d.first!)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Closes its stdin: it prints what `record` got and stops.
    func finish() -> String {
        try? input.fileHandleForWriting.close()
        let line = readLine()
        process.waitUntilExit()
        return line
    }
}
