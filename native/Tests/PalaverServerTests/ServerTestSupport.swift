// What the server tests share: a server in this process on a free port with its own temporary
// folders, and a client that speaks HTTP over a plain socket (every header as written, the Host
// header too, which URLSession would set itself).
import CKeychainACL
import Darwin
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain
@testable import PalaverServer
import Security

func tempFolder(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-\(name)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.resolvingSymlinksInPath()
}

struct Reply {
    let status: Int
    let headers: [(String, String)]
    let body: Data
    /// Nothing came back: the connection was closed without an answer.
    var empty: Bool { status == 0 }

    func header(_ name: String) -> String? { headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1 }
    var text: String { String(decoding: body, as: UTF8.self) }
    var json: JSONValue? { try? PythonJSON.parse(body) }
    var error: String? { json?["error"]?.stringValue }
}

enum Wire {
    /// Connects to 127.0.0.1:`port`, sends `request` (stops sending when the server closed), reads until it closes.
    static func send(port: Int, _ request: Data, timeout: Double = 10) -> Reply {
        let c = RawClient(port: port, timeout: timeout)
        c.send(request)
        return c.reply()
    }

    static func readAll(_ fd: Int32) -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        return out
    }

    static func parse(_ data: Data) -> Reply {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return Reply(status: 0, headers: [], body: data) }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let status = Int(head[0].split(separator: " ")[1]) ?? -1
        let headers = head.dropFirst().compactMap { line -> (String, String)? in
            guard let c = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<c]), line[line.index(after: c)...].trimmingCharacters(in: .whitespaces))
        }
        return Reply(status: status, headers: headers, body: Data(data[end.upperBound...]))
    }

    /// A request as text: the request line, `headers` in order, the body.
    static func request(_ method: String, _ target: String, headers: [(String, String)], body: Data? = nil) -> Data {
        var text = "\(method) \(target) HTTP/1.1\r\n"
        for (k, v) in headers { text += "\(k): \(v)\r\n" }
        if let body { text += "Content-Length: \(body.count)\r\n" }
        var out = Data((text + "\r\n").utf8)
        if let body { out.append(body) }
        return out
    }
}

/// One connection, written to piece by piece.
final class RawClient {
    let fd: Int32

    init(port: Int, timeout: Double = 10) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        precondition(rc == 0, "connect: \(String(cString: strerror(errno)))")
    }

    deinit { close(fd) }

    /// Sends what it can (stops when the server closed).
    func send(_ data: Data) {
        data.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + done, raw.count - done, 0)
                if n <= 0 { break }
                done += n
            }
        }
    }

    /// Everything until the server closes.
    func reply() -> Reply { Wire.parse(Wire.readAll(fd)) }

    /// Gone without waiting for an answer.
    func hangUp() { shutdown(fd, SHUT_RDWR) }
}

/// A server in this process on a free port, with fake collaborators and temporary folders.
final class TestServer {
    let dir: URL
    let app: ServerApp
    let server: HTTPServer
    let port: Int
    let logFile: URL
    private let owned: Bool

    /// `dir`: a folder an earlier server used (its Meetings, stores and log), kept by `stop()`; else a new one.
    init(key: String? = nil, userName: String = "Timo Strauß", staticDir: URL? = nil, helpers: HelperRunner = StubHelperRunner(),
         recording: RecordingRemote? = nil, probe: SetupProbe = FakeProbe(), speechHere: @escaping () -> Bool = { true },
         openURL: @escaping (String) -> Void = { _ in }, notifyState: String? = nil, accessibilityState: String? = nil,
         calendar: CalendarProvider? = nil,
         notesEnabled: Bool? = nil, nextQuestion: NextQuestionAsker = StubNextQuestionAsker(),
         provider: ProviderHelper = StubProviderHelper(), report: ReportMaker = StubReportMaker(),
         settingsDefaults: SettingsValues? = nil,
         freeMemoryGB: @escaping () -> Double = { .infinity }, dir: URL? = nil,
         meetings: (URL) throws -> Void = { _ in }, routes: (Router, ServerApp) -> Void = { _, _ in }) throws {
        owned = dir == nil
        self.dir = dir ?? tempFolder("server")
        let dir = self.dir
        let stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                                home: dir.appendingPathComponent("home", isDirectory: true))
        let out = dir.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try meetings(out)
        app = ServerApp(outputDir: out, userName: userName, stores: stores, staticDir: staticDir ?? ServerApp.defaultStaticDir,
                        settingsDefaults: settingsDefaults, notesEnabled: notesEnabled, freeMemoryGB: freeMemoryGB, recording: recording, calendar: calendar,
                        probe: probe, helpers: helpers, nextQuestion: nextQuestion, provider: provider, report: report, speechHere: speechHere, openURL: openURL,
                        notifyState: notifyState, accessibilityState: accessibilityState)
        let router = Router.palaver(app: app)
        routes(router, app)
        logFile = dir.appendingPathComponent("daemon.log")
        server = HTTPServer(app: app, key: key, router: router, log: SessionLog(url: logFile, logger: "palaver.webapp"))
        port = try server.start(port: 0)
    }

    var host: (String, String) { ("Host", "127.0.0.1:\(port)") }
    var log: String { (try? String(contentsOf: logFile, encoding: .utf8)) ?? "" }

    func get(_ target: String, headers: [(String, String)] = [], method: String = "GET") -> Reply {
        Wire.send(port: port, Wire.request(method, target, headers: [host] + headers))
    }

    func post(_ target: String, _ body: JSONValue = .object([]), headers: [(String, String)] = []) -> Reply {
        Wire.send(port: port, Wire.request("POST", target, headers: [host, ("Content-Type", "application/json")] + headers,
                                           body: Data(PythonJSON.dumps(body).utf8)))
    }

    func stop() {
        server.shutdown()
        if owned { try? FileManager.default.removeItem(at: dir) }
    }
}

/// Waits up to `timeout` seconds for `condition`.
func until(_ timeout: Double = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(10_000)
    }
    return condition()
}

/// Something a test opens once from another thread.
final class Latch: @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var isOpen = false
    func open() { lock.withLock { isOpen = true }; sem.signal() }
    func wait(_ timeout: Double = 5) { _ = sem.wait(timeout: .now() + timeout) }
    var opened: Bool { lock.withLock { isOpen } }
}

/// A folder with a short path (a Unix socket's path holds 104 bytes at most), removed by the caller.
func shortFolder() -> URL {
    var template = Array((FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/pvXXXXXX").utf8CString)
    let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }
    precondition(made != nil, "mkdtemp")
    return URL(fileURLWithPath: String(cString: made!), isDirectory: true)
}

/// The menu bar app's side of app.sock, faked: one JSON line in, one out, as appctl.serve answers. `answer(name, args)`
/// gives the answer; every request line is kept as it came (`lines`), so tests see the bytes the client sent.
final class FakeAppSocket: @unchecked Sendable {
    enum Answer {
        case ok(JSONValue)
        case refused(String)
        case failed(String)
        /// Reads the request and never answers (a hung app).
        case silent
        /// Answers with these bytes as they are.
        case raw(String)
    }

    let path: URL
    private let fd: Int32
    private let lock = NSLock()
    private var requests: [String] = []
    private var stopped = false
    private let answer: (String, JSONValue) -> Answer

    init(_ path: URL, answer: @escaping (String, JSONValue) -> Answer) {
        self.path = path
        self.answer = answer
        unlink(path.path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8)
        precondition(bytes.count < MemoryLayout.size(ofValue: addr.sun_path), "socket path too long: \(path.path)")
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = b } }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        precondition(rc == 0 && listen(fd, 8) == 0, "bind: \(String(cString: strerror(errno)))")
        let t = Thread { [self] in serve() }
        t.start()
    }

    /// The request lines as sent, newline included.
    var lines: [String] { lock.withLock { requests } }
    /// The requests as `(call, args)`.
    var calls: [(String, JSONValue)] {
        lines.compactMap { line in
            guard let v = try? PythonJSON.parse(Data(line.utf8)), let name = v["call"]?.stringValue else { return nil }
            return (name, v["args"] ?? .null)
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path.path)
    }

    private func serve() {
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 { if lock.withLock({ stopped }) { return } else { continue } }
            Thread { [self] in handle(conn) }.start()
        }
    }

    private func handle(_ conn: Int32) {
        defer { close(conn) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0A) {
            let n = read(conn, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        let line = String(decoding: data, as: UTF8.self)
        lock.withLock { requests.append(line) }
        let request = (try? PythonJSON.parse(data)) ?? .object([])
        let reply: String
        switch answer(request["call"]?.stringValue ?? "", request["args"] ?? .object([])) {
        case .ok(let v): reply = PythonJSON.dumps(.object([("ok", v)]))
        case .refused(let text): reply = PythonJSON.dumps(.object([("error", .string(text)), ("refused", .bool(true))]))
        case .failed(let text): reply = PythonJSON.dumps(.object([("error", .string(text)), ("refused", .bool(false))]))
        case .silent:
            _ = read(conn, &buffer, buffer.count)  // until the client gives up
            return
        case .raw(let text): reply = text
        }
        let out = Array((reply + "\n").utf8)
        _ = out.withUnsafeBytes { write(conn, $0.baseAddress, $0.count) }
    }
}

/// A value shared with a closure on another thread.
final class Shared<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var held: T
    init(_ value: T) { held = value }
    var value: T {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
}

/// A keychain file of the test's own (never the user's), holding one key as the Python app saved it: a plain item
/// under `pythonService`. `store` is a real KeychainStore over that file with a service of its own.
final class PythonKeychain {
    let dir = tempFolder("keychain")
    let keychain: CFTypeRef
    let service = "palaver-test-\(UUID().uuidString)", pythonService = "palaver-py-test-\(UUID().uuidString)"

    init(account: String, value: String) throws {
        var status: OSStatus = 0
        let made = palaver_keychain_create(dir.appendingPathComponent("test.keychain-db").path, UUID().uuidString, &status)
        guard status == errSecSuccess, let out = made else { throw KeychainError("could not create a test keychain (\(status))") }
        keychain = out
        status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: pythonService, kSecAttrAccount: account,
                             kSecValueData: Data(value.utf8), kSecUseKeychain: keychain] as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError("could not add the Python item (\(status))") }
    }

    deinit {
        _ = palaver_keychain_delete(keychain)
        try? FileManager.default.removeItem(at: dir)
    }

    var store: KeychainStore { KeychainStore(service: service, legacyServices: [pythonService], keychain: keychain, trusted: []) }

    /// The copy in the store's own service is there.
    func copied(_ account: String) -> Bool {
        SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                             kSecMatchSearchList: [keychain] as CFArray] as CFDictionary, nil) == errSecSuccess
    }
}
