// `palaver-server` as the app runs it (webapp/process.py serve, cli.py webapp-serve): the key from
// the environment, the ready line, SIGTERM and the app going away (stdin's EOF). Ports the server
// process tests of tests/test_web_process.py. The binary from this build, temporary folders as its
// home and config: never the real ones, never the real app's socket or port.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

/// native/.build/debug/palaver-server (built with the tests; `make parity-helper` builds it too).
private let serverBinary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/debug/palaver-server").path

/// A server process with its own folders; stdout and stderr into a pipe.
private final class ServerProcess {
    let dir: URL
    let process: PalaverCore.Process
    /// The app's end of the server's stdin; -1 once closed (a closed number soon belongs to someone else).
    private(set) var stdinWrite: Int32
    let output: Int32
    var log: String {
        (try? String(contentsOf: dir.appendingPathComponent("home/Library/Logs/palaver/daemon.log"), encoding: .utf8)) ?? ""
    }

    init(_ args: [String], key: String?, inherit: [Int32] = [], more: [String: String] = [:]) throws {
        dir = tempFolder("serve")
        let meetings = dir.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("config/palaver"), withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("config.toml")
        try Data("[recording]\noutput_dir = \"\(meetings.path)\"\n[calendar]\nenabled = false\n".utf8).write(to: config)
        var env = ["XDG_CONFIG_HOME": dir.appendingPathComponent("config").path, "PALAVER_HOME": dir.appendingPathComponent("home").path,
                   "HOME": dir.appendingPathComponent("home").path, "PATH": "/usr/bin:/bin"]
        if let key { env[ServeMain.KEY_ENV] = key }
        env.merge(more) { $1 }
        var stdinPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0]
        precondition(pipe(&stdinPipe) == 0 && pipe(&outPipe) == 0)
        process = try spawnChild([serverBinary, "--config", config.path, "--no-notify"] + args, env: env, stdin: stdinPipe[0],
                                 inherit: inherit, output: outPipe[1])
        close(stdinPipe[0])
        close(outPipe[1])
        stdinWrite = stdinPipe[1]
        output = outPipe[0]
    }

    /// The first line it printed.
    func firstLine() -> String {
        var line = Data()
        var byte: UInt8 = 0
        while read(output, &byte, 1) == 1 && byte != 0x0A { line.append(byte) }
        return String(decoding: line, as: UTF8.self)
    }

    /// The app lets go: the server's stdin reaches its end.
    func closeStdin() {
        guard stdinWrite >= 0 else { return }
        close(stdinWrite)
        stdinWrite = -1
    }

    /// Moves the app's end of stdin to number `fd` (free, far above what any test opens: no other thread's open
    /// takes it while this test looks at it).
    func moveStdin(to fd: Int32) {
        precondition(dup2(stdinWrite, fd) == fd && fcntl(fd, F_SETFD, FD_CLOEXEC) == 0)
        close(stdinWrite)
        stdinWrite = fd
    }

    func stop() {
        _ = process.signal(SIGKILL)
        _ = process.waitUntilExit(timeout: 10)
        closeStdin()
        close(output)
        try? FileManager.default.removeItem(at: dir)
    }
}

/// A listening socket and a ready pipe, as the app hands them over.
private func handedOver() throws -> (listen: Int32, port: Int, readyRead: Int32, readyWrite: Int32) {
    let fd = try HTTPServer.listen(port: 0)
    var ready: [Int32] = [0, 0]
    precondition(pipe(&ready) == 0)
    return (fd, try HTTPServer.localPort(fd), ready[0], ready[1])
}

/// A descriptor number near the soft limit (raised to 4096 when the hard limit allows): free, and far above the
/// lowest free numbers every open in this process takes.
private func highFreeDescriptor() -> Int32 {
    var limit = rlimit()
    getrlimit(RLIMIT_NOFILE, &limit)
    if limit.rlim_cur < 4096 {
        var raised = limit
        raised.rlim_cur = min(4096, limit.rlim_max)
        if setrlimit(RLIMIT_NOFILE, &raised) == 0 { limit = raised }
    }
    var fd = Int32(min(limit.rlim_cur, 4096)) - 1
    while fd > 64, fcntl(fd, F_GETFD) != -1 { fd -= 1 }
    return fd
}

private func readAll(_ fd: Int32) -> String {
    var out = Data()
    var buffer = [UInt8](repeating: 0, count: 256)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        out.append(contentsOf: buffer[0..<n])
    }
    return String(decoding: out, as: UTF8.self)
}

@Suite(.serialized) struct ServeTests {
    @Test func portModeTakesTheKeyFromTheEnvironment() throws {
        let p = try ServerProcess(["--port", "0"], key: "Valerie-k3y")
        defer { p.stop() }
        let line = p.firstLine()
        let m = try #require(try PyRegex(#"Open http://127\.0\.0\.1:(\d+)/\?key=Valerie-k3y"#).fullMatch(line), "\(line.count) chars")
        let port = Int(m.group(1)!)!
        let host = ("Host", "127.0.0.1:\(port)")
        #expect(Wire.send(port: port, Wire.request("GET", "/api/ping", headers: [host])).status == 403)
        let signed = ("Cookie", "\(Auth.cookieName(port: port))=Valerie-k3y")
        let ping = Wire.send(port: port, Wire.request("GET", "/api/ping", headers: [host, signed]))
        #expect(ping.status == 200 && ping.text == #"{"ok": true}"#)
        _ = p.process.signal(SIGTERM)
        #expect(p.process.waitUntilExit(timeout: 10) == 0)
        #expect(p.log.contains(#""event": "webapp_start""#) && p.log.contains(#""logger": "palaver.webapp""#))
        #expect(!p.log.contains("Valerie-k3y"))
    }

    @Test func withoutAKeyItMakesItsOwn() throws {
        let p = try ServerProcess(["--port", "0"], key: nil)
        defer { p.stop() }
        let line = p.firstLine()
        #expect(try PyRegex(#"Open http://127\.0\.0\.1:\d+/\?key=[A-Za-z0-9_-]{43}"#).fullMatch(line) != nil, "\(line.count) chars")
    }

    @Test func theEndToEndTestsServerAsksForNoKey() throws {
        let p = try ServerProcess(["--port", "0"], key: "Valerie-k3y", more: [ServeMain.TEST_NO_KEY: "1"])
        defer { p.stop() }
        let line = p.firstLine()
        let m = try #require(try PyRegex(#"Open http://127\.0\.0\.1:(\d+)/"#).fullMatch(line), "\(line.count) chars")
        let port = Int(m.group(1)!)!
        let ping = Wire.send(port: port, Wire.request("GET", "/api/ping", headers: [("Host", "127.0.0.1:\(port)")]))
        #expect(ping.status == 200 && ping.text == #"{"ok": true}"#)
        #expect(ServeMain.serverKey([ServeMain.TEST_NO_KEY: ""]) != nil)  // empty: not set
    }

    @Test func theAppSocketIsTheOneGiven() throws {
        let dir = tempFolder("serve-socket")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.toml")
        try Data("[recording]\noutput_dir = \"\(dir.appendingPathComponent("Meetings").path)\"\n[calendar]\nenabled = false\n".utf8)
            .write(to: config)
        let env = ["XDG_CONFIG_HOME": dir.appendingPathComponent("config").path, "PALAVER_HOME": dir.appendingPathComponent("home").path,
                   TestProbe.ENV: dir.appendingPathComponent("probe.json").path]
        let socket = dir.appendingPathComponent("app.sock").path
        let given = try #require(ServeMain.makeApp(try ServeMain.parse(["--config", config.path, "--port", "0", "--app-socket", socket]),
                                                   env: env).recording as? Remote)
        #expect(given.socketPath.path == socket)
        #expect(given.statePath == StorePaths.current(env: env).daemonJson)
        let own = try #require(ServeMain.makeApp(try ServeMain.parse(["--config", config.path, "--port", "0"]), env: env).recording as? Remote)
        #expect(own.socketPath == StorePaths.current(env: env).appSock)
    }

    @Test func theTestFreeMemoryIsReadAtEveryRequest() throws {
        let dir = tempFolder("serve-free")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("free-gb")
        let free = ServerApp.freeMemory(env: [ServerApp.TEST_FREE_GB: file.path])
        try Data("64.0\n".utf8).write(to: file)
        #expect(free() == 64.0)
        try Data("4".utf8).write(to: file)
        #expect(free() == 4.0)
        try FileManager.default.removeItem(at: file)
        #expect(free() > 0)  // this Mac's
    }

    @Test func theEndToEndTestsOpenNothingAndRecordWhatWouldOpen() throws {
        let dir = tempFolder("serve-opened")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("opened")
        let open = ServerApp.opener(env: [ServerApp.TEST_OPENED: file.path])
        open(AppAPI.SETTINGS_URL)
        open("x-apple.systempreferences:other")
        #expect(try String(contentsOf: file, encoding: .utf8) == AppAPI.SETTINGS_URL + "\nx-apple.systempreferences:other\n")
        let config = dir.appendingPathComponent("config.toml")
        try Data("[recording]\noutput_dir = \"\(dir.appendingPathComponent("Meetings").path)\"\n[calendar]\nenabled = false\n".utf8)
            .write(to: config)
        let env = ["XDG_CONFIG_HOME": dir.appendingPathComponent("config").path, "PALAVER_HOME": dir.appendingPathComponent("home").path,
                   ServerApp.TEST_OPENED: file.path]
        let app = ServeMain.makeApp(try ServeMain.parse(["--config", config.path, "--port", "0"]), env: env)
        app.openURL("x-apple.systempreferences:third")
        #expect(try String(contentsOf: file, encoding: .utf8).hasSuffix("other\nx-apple.systempreferences:third\n"))
    }

    @Test func test_the_child_exits_when_the_app_is_gone() throws {
        // The watch: its stop once stdin's other end closes.
        var fds: [Int32] = [0, 0]
        precondition(pipe(&fds) == 0)
        let stopped = Latch()
        let t = ServeMain.watchParent(fd: fds[0]) { stopped.open() }
        usleep(50_000)
        #expect(!stopped.opened)
        close(fds[1])
        stopped.wait(5)
        #expect(stopped.opened && until { t.isFinished })
        close(fds[0])

        // The process: the app's end of stdin closes, the server finishes and exits 0.
        let h = try handedOver()
        let p = try ServerProcess(["--listen-fd", "\(h.listen)", "--ready-fd", "\(h.readyWrite)"], key: "k", inherit: [h.listen, h.readyWrite])
        defer { p.stop() }
        close(h.listen)
        close(h.readyWrite)
        #expect(readAll(h.readyRead) == "ready\n")  // written once it serves, then closed
        close(h.readyRead)
        p.closeStdin()
        #expect(p.process.waitUntilExit(timeout: 10) == 0)
    }

    @Test func stoppingAfterTheAppLetGoClosesNothingElse() throws {
        // A closed descriptor's number goes to the next open: closing it a second time closed someone
        // else's (a connection the server had just accepted: NIO's getpeername then failed with EBADF).
        let h = try handedOver()
        let p = try ServerProcess(["--listen-fd", "\(h.listen)", "--ready-fd", "\(h.readyWrite)"], key: "k", inherit: [h.listen, h.readyWrite])
        close(h.listen)
        close(h.readyWrite)
        #expect(readAll(h.readyRead) == "ready\n")
        close(h.readyRead)
        // The number is one only this test uses: in the parallel run, another suite's open could take a low one
        // between the close and the reuse below.
        let number = highFreeDescriptor()
        p.moveStdin(to: number)
        p.closeStdin()
        #expect(p.process.waitUntilExit(timeout: 10) == 0)
        // Someone else opens a file and gets that number.
        let devNull = open("/dev/null", O_RDONLY | O_CLOEXEC)
        try #require(devNull >= 0)
        defer { close(number) }
        try #require(dup2(devNull, number) == number)
        close(devNull)
        p.stop()
        #expect(fcntl(number, F_GETFD) != -1, "stop() closed fd \(number), which was no longer its own")
    }

    @Test func test_a_server_that_stops_while_the_app_lives_exits_cleanly() throws {
        let h = try handedOver()
        let p = try ServerProcess(["--listen-fd", "\(h.listen)", "--ready-fd", "\(h.readyWrite)"], key: "k", inherit: [h.listen, h.readyWrite])
        defer { p.stop() }
        close(h.readyWrite)
        #expect(readAll(h.readyRead) == "ready\n")
        close(h.readyRead)
        let signed = [("Host", "127.0.0.1:\(h.port)"), ("Cookie", "\(Auth.cookieName(port: h.port))=k")]
        #expect(Wire.send(port: h.port, Wire.request("GET", "/api/ping", headers: signed)).status == 200)
        _ = p.process.signal(SIGTERM)  // a restart; the app (stdin) is still there
        #expect(p.process.waitUntilExit(timeout: 10) == 0)
        #expect(p.log.contains("serves on port \(h.port)"))
        close(h.listen)
    }

    @Test func withoutStaticThePageIsFoundFromTheExecutable() throws {
        // A release finds the page in its bundle or checkout from where it runs, never from where it was built.
        let app = URL(fileURLWithPath: "/Applications/Palaver.app/Contents/MacOS/palaver-server")
        #expect(ServerApp.staticDir(executable: app).path
                == "/Applications/Palaver.app/Contents/Resources/web")
        let checkout = URL(fileURLWithPath: serverBinary).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        #expect(ServerApp.staticDir(executable: URL(fileURLWithPath: serverBinary)).standardizedFileURL.path
                == checkout.appendingPathComponent("palaver/webapp/static").standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: ServerApp.defaultStaticDir.appendingPathComponent("index.html").path))
    }

    @Test func theArgumentsAreTheOnesTheAppPasses() throws {
        let o = try ServeMain.parse(["--config", "/c.toml", "--no-notify", "--listen-fd", "5", "--ready-fd", "6",
                                     "--app-socket", "/s/app.sock", "--static", "/st"])
        #expect(o.listenFD == 5 && o.readyFD == 6 && o.port == nil && o.appSocket == "/s/app.sock" && o.staticDir == "/st")
        #expect(ServeMain.forwarded(o) == ["--config", "/c.toml", "--no-notify"])
        #expect(try ServeMain.parse(["--port", "0"]).port == 0)
        for bad in [[], ["--port", "1", "--listen-fd", "3", "--ready-fd", "4"], ["--listen-fd", "3"], ["--port", "x"], ["--nope"], ["--port", "0", "--python", "/p"]] {
            #expect(throws: ServeMain.UsageError.self) { try ServeMain.parse(bad) }
        }
    }
}
