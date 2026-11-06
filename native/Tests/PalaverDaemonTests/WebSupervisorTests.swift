// The Meetings window's server in its own process (#57; webapp/process.py): the app binds the
// port, starts the server with the listening socket and a ready pipe, restarts it when it crashes
// (with backoff) or when asked, and stops it when it quits. Ports tests/test_web_process.py's
// supervisor tests. Fake children (a Python stand-in from the worktree's venv) and, in the
// contract test, the real `palaver webapp-serve`: no mic, no sound, no window.
import Darwin
import Foundation
import Testing
@testable import PalaverDaemon
import PalaverCore

private let worktree = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
/// The worktree's venv (`uv sync`, as `make test` and CI have it).
let venvPython = worktree.appendingPathComponent(".venv/bin/python").path
let haveVenv = FileManager.default.isExecutableFile(atPath: venvPython)

// A stand-in server: answers every request with its pid. MODE: "serve"; "crash" (exits 1 after a
// moment); "crash-once" (crashes on its first run, counted in COUNT, then serves); "stubborn"
// (serves, ignores SIGTERM); "key" (answers with the key it was given instead of its pid);
// "hang"/"hang-once" (never says it serves); "slow-ready"; "stdin-eof" (serves, writes COUNT.eof
// and exits when its stdin, the app, closes).
private let fakeChild = #"""
import os, signal, socket, sys, threading, time
mode, count, listen_fd, ready_fd = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
runs = int(open(count).read() or 0) if os.path.exists(count) else 0
open(count, "w").write(str(runs + 1))
if mode == "stubborn":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
if mode == "hang" or (mode == "hang-once" and runs == 0):
    time.sleep(60)  # never says it serves
if mode == "slow-ready":
    time.sleep(0.3)
if mode == "crash" or (mode == "crash-once" and runs == 0):
    os.write(ready_fd, b"ready\n")
    time.sleep(0.1)
    sys.exit(1)
if mode == "stdin-eof":
    def watch():
        while os.read(0, 4096):
            pass
        open(count + ".eof", "w").write("eof")
        os._exit(0)
    threading.Thread(target=watch, daemon=True).start()
sock = socket.socket(fileno=listen_fd)
os.write(ready_fd, b"ready\n")
os.close(ready_fd)
while True:
    conn, _ = sock.accept()
    conn.recv(65536)
    body = (os.environ.get("PALAVER_WEB_KEY", "") if mode == "key" else str(os.getpid())).encode()
    conn.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: %d\r\n\r\n%s" % (len(body), body))
    conn.close()
"""#

final class ReadyEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Bool] = []
    func add(_ restarted: Bool) { lock.withLock { items.append(restarted) } }
    var list: [Bool] { lock.withLock { items } }
}

final class Waits: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Double] = []
    func add(_ d: Double) { lock.withLock { items.append(d) } }
    var list: [Double] { lock.withLock { items } }
}

/// A fake server's supervisor, its ready events and its run counter.
final class FakeWeb {
    let sup: WebSupervisor
    let events = ReadyEvents()
    let dir: URL
    var count: URL { dir.appendingPathComponent("count") }
    var runs: Int { (try? String(contentsOf: count, encoding: .utf8)).flatMap { Int($0) } ?? 0 }

    init(_ mode: String = "serve", backoff: [Double] = [0.05, 0.2, 0.4], readyTimeout: Double = WebSupervisor.readyTimeout,
         stopTimeout: Double = WebSupervisor.stopTimeout) throws {
        dir = tempDir()
        let script = dir.appendingPathComponent("fake_child.py")
        try fakeChild.write(to: script, atomically: true, encoding: .utf8)
        let count = dir.appendingPathComponent("count").path
        let events = self.events
        sup = WebSupervisor(command: { listenFD, readyFD in [venvPython, script.path, mode, count, "\(listenFD)", "\(readyFD)"] },
                            listener: try WebListener.listen(), onReady: { events.add($0) },
                            backoff: backoff, readyTimeout: readyTimeout, stopTimeout: stopTimeout)
    }

    func close() {
        sup.stop()
        sup.listener.close()
    }
}

func until(_ timeout: Double = 30, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(20_000)
    }
    return condition()
}

func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno != ESRCH }

struct HTTPAnswer {
    var status: Int
    var headers: [String: String]
    var body: String
}

/// One HTTP/1.0 GET to 127.0.0.1:`port`, with the Host header the server accepts. nil: no answer.
func httpGet(_ port: Int, _ target: String = "/", headers: [String: String] = [:], timeout: Int = 30) -> HTTPAnswer? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var tv = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard rc == 0 else { return nil }
    var request = "GET \(target) HTTP/1.0\r\nHost: 127.0.0.1:\(port)\r\n"
    for (k, v) in headers { request += "\(k): \(v)\r\n" }
    request += "\r\n"
    let sent = request.withCString { send(fd, $0, strlen($0), 0) }
    guard sent > 0 else { return nil }
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = recv(fd, &buf, buf.count, 0)
        if n <= 0 { break }
        data.append(contentsOf: buf[0..<n])
    }
    let text = String(decoding: data, as: UTF8.self)
    guard let split = text.range(of: "\r\n\r\n") else { return nil }
    let lines = text[..<split.lowerBound].components(separatedBy: "\r\n")
    guard let statusLine = lines.first, let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") else { return nil }
    var fields: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        fields[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return HTTPAnswer(status: status, headers: fields, body: String(text[split.upperBound...]))
}

@Suite(.enabled(if: haveVenv, "needs the worktree's venv (uv sync)"))
struct WebSupervisorTests {
    @Test func theServerRunsAsAChildOnTheAppsPort() throws {
        let f = try FakeWeb()
        defer { f.close() }
        f.sup.start()
        #expect(until { f.events.list == [false] })
        #expect(f.sup.url() == "http://127.0.0.1:\(f.sup.port)/")
        #expect(f.sup.url("2026-10-30T08-02-13") == "http://127.0.0.1:\(f.sup.port)/#/2026-10-30T08-02-13")
        let pid = try #require(f.sup.pid)
        #expect(httpGet(f.sup.port)?.body == "\(pid)" && pid != getpid())
    }

    @Test func everyServerGetsTheAppsKeyAndTheKeyStaysAcrossRestarts() throws {
        let f = try FakeWeb("key")
        defer { f.close() }
        f.sup.start()
        #expect(until { f.events.list == [false] })
        #expect(f.sup.key.count >= 32 && httpGet(f.sup.port)?.body == f.sup.key)
        #expect(f.sup.restart() != nil)
        #expect(httpGet(f.sup.port)?.body == f.sup.key)  // the window's cookie still fits
        let other = WebSupervisor(command: { _, _ in [] }, listener: f.sup.listener)
        #expect(other.key != f.sup.key)  // each app start its own
    }

    @Test func aCrashedServerIsStartedAgainOnTheSamePort() throws {
        let f = try FakeWeb("crash-once")
        defer { f.close() }
        f.sup.start()
        #expect(until { f.events.list == [false, true] })
        let pid = try #require(f.sup.pid)
        #expect(httpGet(f.sup.port)?.body == "\(pid)")
        #expect(f.runs == 2)
    }

    @Test func aServerThatKeepsCrashingWaitsLongerEachTime() throws {
        let f = try FakeWeb("crash", backoff: [0.05, 0.1, 0.2])
        defer { f.close() }
        let waits = Waits()
        f.sup.onBackoff = { waits.add($0) }
        f.sup.start()
        #expect(until { waits.list.count >= 4 })
        f.sup.stop()
        #expect(Array(waits.list.prefix(4)) == [0.05, 0.1, 0.2, 0.2])
    }

    @Test func restartStartsANewServerAtOnceAndTheWindowReloads() throws {
        let f = try FakeWeb(backoff: [30])  // a restart never waits out the backoff
        defer { f.close() }
        f.sup.start()
        #expect(until { f.events.list == [false] })
        let first = try #require(f.sup.pid)
        let started = Date()
        let new = f.sup.restart()
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(new != nil && new == f.sup.pid && new != first)
        #expect(!until(0.5) { alive(first) })
        #expect(f.events.list == [false, true])
        #expect(httpGet(f.sup.port)?.body == new.map { "\($0)" })
    }

    @Test func stopEndsTheServerAndStartsNoOther() throws {
        let f = try FakeWeb()
        defer { f.close() }
        f.sup.start()
        #expect(until { f.events.list == [false] })
        let pid = try #require(f.sup.pid)
        f.sup.stop()
        #expect(!alive(pid))
        usleep(300_000)
        #expect(f.runs == 1 && f.sup.pid == nil)
        #expect(f.sup.restart() == nil)  // stopped: no restart either
    }

    @Test func stopKillsAServerThatIgnoresSigterm() throws {
        let f = try FakeWeb("stubborn", stopTimeout: 0.5)
        defer { f.close() }
        f.sup.start()
        #expect(until { f.events.list == [false] })
        let pid = try #require(f.sup.pid)
        let started = Date()
        f.sup.stop()
        #expect(!alive(pid) && Date().timeIntervalSince(started) < 3)
    }

    /// Quitting never waits for a server finishing its last change.
    @Test func stopInTheBackgroundReturnsAtOnce() throws {
        let f = try FakeWeb("stubborn", stopTimeout: 1)
        defer { f.close() }
        f.sup.start()
        #expect(until { f.events.list == [false] })
        let pid = try #require(f.sup.pid)
        let started = Date()
        let t = f.sup.stopInBackground()
        #expect(Date().timeIntervalSince(started) < 0.2)
        #expect(alive(pid))
        #expect(until(5) { t.isFinished && !alive(pid) })
    }

    @Test func aServerThatNeverSaysReadyIsEndedAndStartedAgain() throws {
        let f = try FakeWeb("hang-once", backoff: [0.05], readyTimeout: 0.5)
        defer { f.close() }
        f.sup.start()
        #expect(until { f.events.list == [true] }, "the hanging server was not replaced")
        #expect(f.runs == 2)
        let pid = try #require(f.sup.pid)
        #expect(httpGet(f.sup.port)?.body == "\(pid)")
    }

    /// The old server saying ready while a restart ends it is not the new one.
    @Test func restartReturnsTheNewServerEvenWhenTheOldOneComesUpMeanwhile() throws {
        let f = try FakeWeb("slow-ready")
        defer { f.close() }
        f.sup.start()
        #expect(until { f.sup.pid != nil })  // started, not yet serving (it says so after 0.3 s)
        let firstBox = Waits()
        let events = f.events
        f.sup.beforeEnd = { pid in  // the old server comes up just before the restart ends it
            firstBox.add(Double(pid))
            _ = until(5) { !events.list.isEmpty }
        }
        let new = f.sup.restart()
        #expect(new != nil && new == f.sup.pid)
        #expect(firstBox.list.first.map { Int32($0) } != new)
        #expect(until { f.events.list == [false, true] })
    }

    /// The server's stdin is a pipe from the app: open while the app lives, at its end when the app
    /// is gone (the kernel closes the app's end), and then the server exits by itself.
    @Test func theServersStdinClosesWhenTheAppIsGone() throws {
        let f = try FakeWeb("stdin-eof", backoff: [30])
        defer { f.close() }
        f.sup.start()
        #expect(until { f.events.list == [false] })
        let pid = try #require(f.sup.pid)
        let eof = f.dir.appendingPathComponent("count.eof")
        usleep(300_000)
        #expect(!FileManager.default.fileExists(atPath: eof.path))  // not /dev/null: no end while the app lives
        f.sup.closeStdinAsIfTheAppWereGone()
        #expect(until { FileManager.default.fileExists(atPath: eof.path) })
        #expect(until { !alive(pid) })
    }
}

@Suite struct WebSupervisorPartsTests {
    @Test func aServerThatRanAWhileBeforeCrashingStartsOverAtTheShortestWait() {
        var delays = BackoffDelays([1, 5, 30], stableAfter: 60)
        #expect(delays.next(ranFor: 0.5) == 1)
        #expect(delays.next(ranFor: 0.5) == 5)
        #expect(delays.next(ranFor: 0.5) == 30)
        #expect(delays.next(ranFor: 0.5) == 30)
        #expect(delays.next(ranFor: 120) == 1)
        delays.reset()
        #expect(delays.next(ranFor: 0.5) == 1)
    }

    @Test func theTimesAreProcessPys() {
        #expect(WebSupervisor.backoff == [1, 2, 5, 15, 30] && WebSupervisor.stableAfter == 60)
        #expect(WebSupervisor.readyTimeout <= 20 && WebSupervisor.readyTimeout == 20)
        #expect(WebSupervisor.drainSeconds == 60 && WebSupervisor.stopTimeout == 65)
        #expect(WebSupervisor.stopTimeout > WebSupervisor.drainSeconds)  // a requested restart lets the drain finish
        #expect(WebSupervisor.windowPorts == Array(47815...47824))
        #expect(WebSupervisor.keyEnv == "PALAVER_WEB_KEY")
    }

    @Test func theKeyIsAFreshUrlsafeTokenOf32Bytes() {
        let a = WebSupervisor.newKey(), b = WebSupervisor.newKey()
        #expect(a != b && a.count == 43)  // secrets.token_urlsafe(32): 32 bytes, base64url, no padding
        #expect(a.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    }

    @Test func theServerGetsTheNotificationSocketButNotTheLaunchersClicks() {
        let env = WebSupervisor.childEnv(["PALAVER_NOTIFY": "/tmp/n.sock", "PALAVER_LAUNCHER_FD": "3", "HOME": "/Users/x"])
        #expect(env == ["PALAVER_NOTIFY": "/tmp/n.sock", "HOME": "/Users/x"])
    }

    @Test func theChildCommand() {
        let argv = WebSupervisor.childArgv(python: "/b/palaver-python", cliOptions: ["--config", "/c.toml"], listenFD: 5, readyFD: 6,
                                           appSocket: URL(fileURLWithPath: "/s/app.sock"))
        #expect(argv == ["/b/palaver-python", "-m", "palaver", "--config", "/c.toml", "webapp-serve", "--listen-fd", "5",
                         "--ready-fd", "6", "--app-socket", "/s/app.sock"])
    }

    @Test func theWindowGetsTheSamePortAtEveryStartUnlessItIsTaken() throws {
        let ports = try freePorts(3)
        let first = try WebListener.forWindow(ports: ports)
        #expect(first.port == ports[0])
        let second = try WebListener.forWindow(ports: ports)  // e.g. a second Palaver, or another program on it
        #expect(second.port == ports[1])
        second.close()
        first.close()
        let again = try WebListener.forWindow(ports: ports)  // the next start: the same port, the page keeps what it remembers
        #expect(again.port == ports[0])
        again.close()
    }

    @Test func withAllWindowPortsTakenAnyFreeOneWillDo() throws {
        let ports = try freePorts(1)
        let taken = try WebListener.listen(port: ports[0])
        defer { taken.close() }
        let sock = try WebListener.forWindow(ports: ports)
        #expect(sock.port != 0 && sock.port != ports[0])
        sock.close()
    }

    @Test func theListenerIsCloseOnExecAndOnLoopbackOnly() throws {
        let l = try WebListener.listen()
        defer { l.close() }
        #expect(fcntl(l.fd, F_GETFD) & FD_CLOEXEC != 0)  // only the server gets it, by name
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(l.fd, $0, &len) } }
        #expect(addr.sin_addr.s_addr == inet_addr("127.0.0.1"))
    }

    /// n ports nothing listens on: a run of n in a row, as windowPorts is.
    private func freePorts(_ n: Int) throws -> [Int] {
        for _ in 0..<50 {
            let probe = try WebListener.listen()
            let start = probe.port
            probe.close()
            var socks: [WebListener] = []
            for p in start..<(start + n) {
                guard let s = try? WebListener.listen(port: p) else { break }
                socks.append(s)
            }
            socks.forEach { $0.close() }
            if socks.count == n { return Array(start..<(start + n)) }
        }
        throw WebServerError("no free ports")
    }
}

/// app.sock's `restart_web` (appctl.app_calls): the supervisor's restart, `{"pid": new}` once the
/// new server is up, `{"pid": null}` when none came up (or the app is quitting).
@Suite(.enabled(if: haveVenv, "needs the worktree's venv (uv sync)"))
struct RestartWebCallTests {
    @Test func restartWebAnswersTheNewServersPid() async throws {
        let f = try FakeWeb(backoff: [30])
        defer { f.close() }
        let h = try Harness(tempDir(), activity: noCall)
        let sup = f.sup
        let actions = DaemonActions(daemon: h.daemon, restartWeb: { sup.restart() })
        let calls = AppCalls.make(actions: actions, main: MainRunner(timeout: 120, schedule: { DispatchQueue(label: "m").async(execute: $0) }))
        sup.start()
        #expect(until { f.events.list == [false] })
        let first = try #require(sup.pid)
        let answer = try await calls["restart_web"]!([:]) as? [String: Any]
        let pid = try #require(answer?["pid"] as? Int)
        #expect(pid != Int(first) && Int32(pid) == sup.pid)
        sup.stop()
        let none = try await calls["restart_web"]!([:]) as? [String: Any]
        #expect(none?["pid"] is NSNull)
    }
}

/// Contract: the Swift supervisor runs the REAL `palaver webapp-serve` (the worktree's Python) on
/// the socket it bound, and the window's sign-in works: `/?key=…` sets the key cookie and drops the
/// key from the address, the page answers with the cookie only, and after a restart the new server
/// (a new pid) answers the same cookie. A throwaway HOME: never the real ~/Meetings or ~/.config.
@Suite(.enabled(if: haveVenv, "needs the worktree's venv (uv sync)"))
struct RealWebServerContractTests {
    @Test func theRealServerSignsTheWindowInAndAnswersAgainAfterARestart() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pv\(getpid())-\(UInt32.random(in: 0..<999_999))")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Meetings"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("config.toml")
        try """
        [notion]
        token = "fake"
        parent_page_id = "fake"
        [hf]
        token = "fake"
        [recording]
        output_dir = "\(home.appendingPathComponent("Meetings").path)"

        """.write(to: config, atomically: true, encoding: .utf8)
        var env = WebSupervisor.childEnv(ProcessInfo.processInfo.environment)
        env["HOME"] = home.path
        env["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        env["PALAVER_NOTIFY"] = nil
        let events = ReadyEvents()
        let appSocket = home.appendingPathComponent("app.sock")
        let sup = WebSupervisor.forApp(python: venvPython, cliOptions: ["--config", config.path, "--no-notify"],
                                       appSocket: appSocket, listener: try WebListener.listen(), env: env,
                                       onReady: { events.add($0) })
        defer { sup.stop(); sup.listener.close() }
        sup.start()
        #expect(until(60) { events.list == [false] }, "the server process did not start")
        let port = sup.port
        let cookieName = "palaver_key_\(port)"

        #expect(httpGet(port)?.status == 403)  // no key, no meetings
        #expect(httpGet(port, "/?key=wrong")?.status == 403)
        let signIn = try #require(httpGet(port, "/?key=\(sup.key)"))
        #expect(signIn.status == 302)
        #expect(signIn.headers["location"] == "/")  // the key leaves the address
        #expect(signIn.headers["set-cookie"] == "\(cookieName)=\(sup.key); Path=/; HttpOnly; SameSite=Strict")
        let cookie = ["Cookie": "\(cookieName)=\(sup.key)"]
        let page = try #require(httpGet(port, headers: cookie))
        #expect(page.status == 200 && page.body.lowercased().contains("<html"))
        #expect(httpGet(port, "/api/ping", headers: cookie)?.body.contains("\"ok\": true") == true)

        let first = try #require(sup.pid)
        let new = sup.restart(timeout: 60)
        #expect(new != nil && new != first && new == sup.pid)
        #expect(!until(1) { alive(first) })
        #expect(events.list == [false, true])
        let again = try #require(httpGet(port, headers: cookie))  // the window's cookie fits the new server
        #expect(again.status == 200 && again.body.lowercased().contains("<html"))
    }
}
