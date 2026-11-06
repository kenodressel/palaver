import Darwin
import Foundation
import Testing
@testable import PalaverDaemon
import PalaverCore

// Unix socket paths are limited to 104 bytes: a short directory under /tmp.

private func tempSock() -> String {
    let dir = "/tmp/pv\(getpid())-\(UInt32.random(in: 0..<999_999))"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/app.sock"
}

/// A client: connects, sends `bytes`, reads to the newline or EOF. nil: no answer (closed or timed out).
private func rawCall(_ path: String, _ bytes: Data, timeout: Int = 30, closeWrite: Bool = false) -> [String: Any]? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let c = Array(path.utf8CString)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in c.enumerated() { raw[i] = UInt8(bitPattern: b) } }
    let rc = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { return nil }
    var tv = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    bytes.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count { let w = write(fd, raw.baseAddress! + off, raw.count - off); if w <= 0 { break }; off += w }
    }
    if closeWrite { shutdown(fd, SHUT_WR) }
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while !data.contains(0x0A) {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        data.append(contentsOf: buf[0..<n])
    }
    guard !data.isEmpty else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func call(_ path: String, _ name: String, _ args: [String: Any] = [:]) -> [String: Any]? {
    let body = try! JSONSerialization.data(withJSONObject: ["call": name, "args": args])
    return rawCall(path, body + Data("\n".utf8))
}

private func serve(_ handlers: [String: AppHandler], readTimeout: TimeInterval = 30, at path: String? = nil) -> AppSocket {
    let s = AppSocket(path: path ?? tempSock(), handlers: handlers, readTimeout: readTimeout)
    #expect(s.start())
    return s
}

// Serialized: these tests block threads of the cooperative pool while the handlers need it.
@Suite(.serialized) struct AppSocketTests {
@Test func aCallAnswersWithItsResult() {
    let s = serve(["ping": { args in ["pid": 7, "echo": args] }])
    defer { s.stop() }
    let r = call(s.path, "ping", ["x": 1])
    #expect((r?["ok"] as? [String: Any])?["pid"] as? Int == 7)
    #expect(((r?["ok"] as? [String: Any])?["echo"] as? [String: Int]) == ["x": 1])
}

@Test func nilResultIsNull() {
    let s = serve(["a": { _ in nil }])
    defer { s.stop() }
    let r = call(s.path, "a")
    #expect(r?.keys.contains("ok") == true && r?["ok"] is NSNull)
}

@Test func onlyThisUserCanReachTheSocket() throws {
    let s = serve(["ping": { _ in nil }])
    defer { s.stop() }
    let mode = try FileManager.default.attributesOfItem(atPath: s.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

@Test func aRefusedCallSaysWhy() {
    let s = serve(["answer": { _ in throw CallRefused("not now") }])
    defer { s.stop() }
    let r = call(s.path, "answer")
    #expect(r?["error"] as? String == "not now" && r?["refused"] as? Bool == true)
}

@Test func anUnknownCallIsRefusedWithPythonsText() {
    let s = serve([:])
    defer { s.stop() }
    let r = call(s.path, "nope")
    #expect(r?["error"] as? String == "unknown call 'nope'" && r?["refused"] as? Bool == true)
    let q = call(s.path, "it's")
    #expect(q?["error"] as? String == "unknown call \"it's\"")
    let none = rawCall(s.path, Data("{}\n".utf8))
    #expect(none?["error"] as? String == "unknown call None")
}

struct Boom: Error {}
struct Described: LocalizedError { var errorDescription: String? { "division by zero" } }

@Test func aFailingCallIsAnErrorNotAHang() {
    let s = serve(["boom": { _ in throw Described() }, "bare": { _ in throw Boom() }])
    defer { s.stop() }
    let r = call(s.path, "boom")
    #expect(r?["error"] as? String == "division by zero" && r?["refused"] as? Bool == false)
    #expect(call(s.path, "bare")?["refused"] as? Bool == false)
}

@Test func aStaleSocketFileIsReplaced() throws {
    let path = tempSock()
    try "left over from a crash".write(toFile: path, atomically: true, encoding: .utf8)
    let s = serve(["ping": { _ in "pong" }], at: path)
    defer { s.stop() }
    #expect(call(path, "ping")?["ok"] as? String == "pong")
}

@Test func stoppingRemovesTheSocket() {
    let s = serve([:])
    s.stop()
    #expect(!FileManager.default.fileExists(atPath: s.path))
}

@Test func anOversizeRequestIsAnErrorNotAHang() {
    let s = serve(["ping": { _ in "pong" }])
    defer { s.stop() }
    // 100 KiB with no newline: only the first 64 KiB are read, which is no JSON.
    var big = Data("{\"call\": \"ping\", \"args\": {\"pad\": \"".utf8)
    big.append(Data(repeating: 0x61, count: 100 * 1024))
    big.append(Data("\"}}\n".utf8))
    let r = rawCall(s.path, big)
    #expect(r?["refused"] as? Bool == false)
    #expect(r?["ok"] == nil)
}

private final class Flag: @unchecked Sendable { var set = false }

@Test func aClientThatSendsNothingTimesOutAndOthersAreNotBlocked() async {
    let s = serve(["ping": { _ in "pong" }], readTimeout: 2.0)
    defer { s.stop() }
    // A half-open client: connects, sends nothing.
    let started = Date(), done = Flag()
    async let silent: [String: Any]? = Task.detached { let r = rawCall(s.path, Data(), timeout: 6); done.set = true; return r }.value
    try? await Task.sleep(nanoseconds: 100_000_000)
    // Meanwhile, another client is answered; the silent one is still waiting (not a timing bound).
    #expect(call(s.path, "ping")?["ok"] as? String == "pong")
    #expect(!done.set)
    #expect(await silent == nil)  // closed without an answer after the read timeout
    #expect(Date().timeIntervalSince(started) >= 1.9)
}

private final class Gauge: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private(set) var peak = 0
    func enter() { lock.lock(); now += 1; peak = max(peak, now); lock.unlock() }
    func leave() { lock.lock(); now -= 1; lock.unlock() }
}

@Test func slowHandlersRunConcurrently() async {
    let gauge = Gauge()
    let s = serve(["slow": { _ in gauge.enter(); defer { gauge.leave() }; try await Task.sleep(nanoseconds: 500_000_000); return "done" }])
    defer { s.stop() }
    async let a = Task.detached { call(s.path, "slow") }.value
    async let b = Task.detached { call(s.path, "slow") }.value
    let (ra, rb) = await (a, b)
    #expect(ra?["ok"] as? String == "done" && rb?["ok"] as? String == "done")
    #expect(gauge.peak == 2)
}

// MARK: on the main thread

@Test func mainRunnerRunsWorkAndReturnsItsResult() async throws {
    let main = MainRunner(schedule: { work in DispatchQueue.global().async(execute: work) })
    #expect(try await main.run { 41 + 1 } == 42)
    await #expect(throws: Described.self) { try await main.run { throw Described() } }
}

@Test func aBusyMainThreadIsRefusedFalseWithPythonsText() async throws {
    let main = MainRunner(timeout: 0.3, schedule: { _ in })  // a main queue that never runs
    let started = Date()
    await #expect(throws: MainThreadBusy.self) { try await main.run { 1 } }
    #expect(Date().timeIntervalSince(started) < 5)
    #expect(MainRunner.defaultTimeout == 10)

    let s = serve(["answer": { _ in try await main.run { true } }])
    defer { s.stop() }
    let r = call(s.path, "answer")
    #expect(r?["error"] as? String == "the menu bar app is busy" && r?["refused"] as? Bool == false)
}

// MARK: the calls

private final class FakeActions: AppActions, @unchecked Sendable {
    var answers: [(String, String?)] = [], off: [String] = [], helpers: [(String, Int32)] = []
    var transcribing: [String] = [], refreshed = 0, started = false, fails = false
    var recording = false, folder: String?
    var mainOnly = true
    func answerStopQuestion(choice: String, meeting: String?) -> Bool { answers.append((choice, meeting)); return meeting == "2026-10-30T08-02-13" }
    func switchedOff(app: String) { off.append(app) }
    func transcribeAgain(folder: String) -> Bool { transcribing.append(folder); return true }
    func status() -> (state: String, folder: String?) { (recording ? "recording" : "idle", folder) }
    func stopManual() { recording = false; folder = nil }
    func startManual() -> Bool { if fails { return false }; recording = true; folder = "/m/2026-11-03T14-00-00"; return true }
    func refresh() { refreshed += 1 }
    func watchHelper(folder: String, process: PidProcess) { helpers.append((folder, process.pid)) }
    func launchHelper(kind: String, key: String, args: [String]) throws -> Int32 {
        if kind == "run" { throw CallRefused("not a helper: run") }
        return 777
    }
    func restartWeb() -> Int32? { 4321 }
    func testRecording(action: String?, mode: [String: Any], busy: () -> Bool) throws -> Any? {
        if action == "start" {
            if busy() { throw CallRefused("a meeting is being recorded; try the test after it") }
            return ["state": "recording"]
        }
        return action == "stop" ? ["state": "checking"] : ["state": "idle", "max_seconds": 20.0]
    }
}

private func callsServer(_ a: FakeActions, children: @escaping @Sendable (Int32) -> [Int32] = childPids) -> AppSocket {
    let main = MainRunner(schedule: { work in DispatchQueue.global().async(execute: work) })
    return serve(AppCalls.make(actions: a, main: main, children: children))
}

@Test func answerRunsOnMainThenRefreshes() {
    let a = FakeActions(); let s = callsServer(a); defer { s.stop() }
    #expect(call(s.path, "answer", ["choice": "stop", "meeting": "2026-10-30T08-02-13"])?["ok"] as? Bool == true)
    #expect(call(s.path, "answer", ["choice": "keep", "meeting": "other"])?["ok"] as? Bool == false)
    #expect(a.answers.map { "\($0.0)/\($0.1 ?? "")" } == ["stop/2026-10-30T08-02-13", "keep/other"] && a.refreshed == 2)
}

@Test func switchedOffRefusesUnknownApps() {
    let a = FakeActions(); let s = callsServer(a); defer { s.stop() }
    #expect(call(s.path, "switched_off", ["app": "teams"])?["ok"] is NSNull)
    #expect(a.off == ["teams"])
    let r = call(s.path, "switched_off", ["app": "zoom"])
    #expect(r?["error"] as? String == "no record switch for 'zoom'" && r?["refused"] as? Bool == true)
}

@Test func recordStartsAndStops() {
    let a = FakeActions(); let s = callsServer(a); defer { s.stop() }
    #expect((call(s.path, "record", ["action": "start"])?["ok"] as? [String: Any])?["meeting"] as? String == "2026-11-03T14-00-00")
    #expect(call(s.path, "record", ["action": "start"])?["error"] as? String == "Palaver is recording already.")
    let wrong = call(s.path, "record", ["action": "stop", "meeting": "2026-11-03T09-00-00"])
    #expect(wrong?["error"] as? String == "This recording is no longer running." && wrong?["refused"] as? Bool == true)
    #expect((call(s.path, "record", ["action": "stop", "meeting": "2026-11-03T14-00-00"])?["ok"] as? [String: Any])?["stopped"] as? String == "2026-11-03T14-00-00")
    #expect(call(s.path, "record", ["action": "stop"])?["error"] as? String == "This recording is no longer running.")
    #expect(call(s.path, "record", ["action": "pause"])?["error"] as? String == "no recording action 'pause'")
    a.fails = true
    #expect(call(s.path, "record", ["action": "start"])?["error"] as? String == "The recording did not start; the log says why.")
}

@Test func transcribeNeedsAFolder() throws {
    let a = FakeActions(); let s = callsServer(a); defer { s.stop() }
    let dir = URL(fileURLWithPath: tempSock()).deletingLastPathComponent().path
    #expect(call(s.path, "transcribe", ["folder": dir])?["ok"] as? Bool == true)
    #expect(a.transcribing == [dir])
    let r = call(s.path, "transcribe", ["folder": dir + "/gone"])
    #expect(r?["error"] as? String == "no recording at \(dir)/gone" && r?["refused"] as? Bool == true)
}

@Test func startHelperAndTestAndRestartWebAndPing() {
    let a = FakeActions(); let s = callsServer(a); defer { s.stop() }
    #expect((call(s.path, "start_helper", ["kind": "notes", "key": "k", "args": ["x"]])?["ok"] as? [String: Any])?["pid"] as? Int == 777)
    #expect(call(s.path, "start_helper", ["kind": "run", "key": "k"])?["refused"] as? Bool == true)
    #expect(call(s.path, "test", ["action": "start"])?["ok"] != nil)
    a.recording = true
    #expect((call(s.path, "test", ["action": "start"])?["error"] as? String)?.contains("meeting is being recorded") == true)
    #expect((call(s.path, "restart_web")?["ok"] as? [String: Any])?["pid"] as? Int == 4321)
    #expect((call(s.path, "ping")?["ok"] as? [String: Any])?["pid"] as? Int == Int(getpid()))
}

// MARK: watch and the descendant check

@Test func watchTakesOnlyADescendantOfTheApp() throws {
    let a = FakeActions(); let s = callsServer(a); defer { s.stop() }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
    try child.run()
    defer { child.terminate(); child.waitUntilExit() }
    for pid in [0, 1, -5, Int(getpid()), Int(getppid())] {
        let r = call(s.path, "watch", ["folder": "/m/x", "pid": pid])
        #expect(r?["refused"] as? Bool == true)
        #expect((r?["error"] as? String)?.hasSuffix("is not a process Palaver started") == true)
    }
    #expect(a.helpers.isEmpty)
    #expect(call(s.path, "watch", ["folder": "/m/x", "pid": Int(child.processIdentifier)])?["ok"] is NSNull)
    #expect(a.helpers.map { $0.1 } == [child.processIdentifier])
}

@Test func aDescendantFurtherDownCounts() {
    let tree: [Int32: [Int32]] = [100: [200], 200: [300, 301], 301: [400]]
    let kids: (Int32) -> [Int32] = { tree[$0] ?? [] }
    #expect(descendant(400, root: 100, children: kids))
    #expect(descendant(200, root: 100, children: kids))
    #expect(!descendant(100, root: 100, children: kids))
    #expect(!descendant(999, root: 100, children: kids))
    #expect(!descendant(1, root: 100, children: kids))
    #expect(!descendant(0, root: 100, children: kids))
    // a cycle terminates
    #expect(!descendant(9, root: 1, children: { _ in [2, 1, 2] }))
}

@Test func theRealChildListSeesGrandchildren() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", "sleep 30 & wait"]
    try p.run()
    defer { p.terminate(); p.waitUntilExit() }
    Thread.sleep(forTimeInterval: 0.3)
    let kids = childPids(p.processIdentifier)
    #expect(!kids.isEmpty)
    #expect(descendant(kids[0]))
    #expect(descendant(p.processIdentifier))
    for k in kids { Darwin.kill(k, SIGKILL) }
}

@Test func pidProcessSeesItsProcessGoAndStopsIt() throws {
    let gone = Process()
    gone.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try gone.run(); gone.waitUntilExit()
    #expect(PidProcess(gone.processIdentifier).poll() != nil)
    PidProcess(gone.processIdentifier).terminate()  // nothing to stop: no error

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", "trap '' TERM; sleep 30"]
    try p.run()
    defer { p.terminate(); p.waitUntilExit() }
    Thread.sleep(forTimeInterval: 0.2)
    let pp = PidProcess(p.processIdentifier)
    #expect(pp.poll() == nil)
    pp.kill()
    p.waitUntilExit()
    #expect(p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGKILL)
    #expect(pp.poll() != nil)
}

// MARK: fix round 1

@Test func aLeftoverStagingFolderFromACrashDoesNotBlockStart() throws {
    let path = tempSock()
    try FileManager.default.createDirectory(atPath: path + ".d", withIntermediateDirectories: true)
    try "stale".write(toFile: path + ".d/s", atomically: true, encoding: .utf8)
    let s = serve(["ping": { _ in "pong" }], at: path)
    defer { s.stop() }
    #expect(call(path, "ping")?["ok"] as? String == "pong")
    #expect(!FileManager.default.fileExists(atPath: path + ".d"))
}

@Test func aFailedStartLeavesNoSocketFile() {
    let path = tempSock()
    let s = AppSocket(path: path, handlers: [:])
    s.listenOverride = { _, _ in -1 }
    #expect(!s.start())
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(!FileManager.default.fileExists(atPath: path + ".d"))
}

@Test func stopLeavesASocketThatAnotherServerBoundAfterwards() {
    let path = tempSock()
    let old = AppSocket(path: path, handlers: ["who": { _ in "old" }])
    #expect(old.start())
    let new = AppSocket(path: path, handlers: ["who": { _ in "new" }])
    #expect(new.start())  // replaces the file, as a restart does
    defer { new.stop() }
    old.stop()
    #expect(call(path, "who")?["ok"] as? String == "new")
}

@Test func watchRefusesPidsOutOfRange() {
    let a = FakeActions(); let s = callsServer(a); defer { s.stop() }
    for pid: Any in [-1, 0, 4_294_967_297, 9_999_999_999_999, 1.5, "12", true] {
        let r = call(s.path, "watch", ["folder": "/m/x", "pid": pid])
        #expect(r?["refused"] as? Bool == true)
    }
    #expect(a.helpers.isEmpty)
}

@Test func acceptedConnectionsAreCloseOnExec() {
    let s = serve(["ping": { _ in "pong" }])
    defer { s.stop() }
    #expect(s.lastAcceptedFlags == nil)
    _ = call(s.path, "ping")
    #expect((s.lastAcceptedFlags ?? 0) & FD_CLOEXEC != 0)
}

@Test func aPersistentAcceptErrorBacksOffAndLogsOnce() async {
    final class Lines: @unchecked Sendable { let l = NSLock(); var n: [String] = []; func add(_ s: String) { l.lock(); n.append(s); l.unlock() } }
    let lines = Lines(), calls = Gauge()
    let s = AppSocket(path: tempSock(), handlers: [:], log: { lines.add($0) })
    s.acceptOverride = { _ in calls.enter(); errno = EMFILE; return -1 }
    #expect(s.start())
    defer { s.stop() }
    // poll() sees nothing readable on an idle socket: connect once so the accept is attempted.
    _ = rawCall(s.path, Data(), timeout: 1)
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    #expect(calls.peak >= 1 && calls.peak <= 30)  // backed off (~10 per second): not thousands of attempts
    #expect(lines.n.count == 1)
}

}
