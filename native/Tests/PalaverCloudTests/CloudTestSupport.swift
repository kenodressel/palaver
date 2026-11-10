// Test support: temporary stores, fake key stores and a tiny HTTP server on 127.0.0.1 that answers what a test says.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain
@testable import PalaverCloud

let KEY = "sk-ant-api03-SECRET-abcdefghijklmnop"

func tempFolder(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-\(name)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.resolvingSymlinksInPath()
}

/// A config dir and a home of their own, a file key store, and the settings over them.
final class Home {
    let dir = tempFolder("cloud")
    lazy var stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                                 home: dir.appendingPathComponent("home", isDirectory: true))
    lazy var keys = FileKeyStore(dir.appendingPathComponent("keychain.json"))
    var config = Config()
    /// No `claude` anywhere: PATH is empty and config.toml names one that is not there.
    var env: [String: String] = ["PATH": ""]

    init() { config.claudePath = dir.appendingPathComponent("no-claude").path }

    var settings: ProviderSettings { ProviderSettings(config: config, stores: stores, keys: keys, env: env) }

    var saved: JSONValue { PythonJSON.read(stores.settings) ?? .object([]) }
    var keychain: [String: String] {
        guard case .object(let f)? = PythonJSON.read(dir.appendingPathComponent("keychain.json")) else { return [:] }
        return Dictionary(uniqueKeysWithValues: f.compactMap { k, v in v.stringValue.map { (k, $0) } })
    }

    deinit { try? FileManager.default.removeItem(at: dir) }
}

/// A key store that fails every call, and whose own messages would quote the value (keychain.py's leaky backend).
final class BrokenKeyStore: KeyStore, @unchecked Sendable {
    struct Leaky: Error, CustomStringConvertible { let description: String }
    var reads = 0
    func has(_ account: String) -> Bool { false }
    func read(_ account: String) throws -> String? { reads += 1; throw Leaky(description: "keychain locked") }
    func write(_ account: String, _ value: String) throws { throw KeychainError("could not save \(account) in the Keychain") }
    func delete(_ account: String) throws { throw KeychainError("could not remove \(account) from the Keychain") }
}

/// A key store that counts what is asked of it: a presence check must never read a secret.
final class CountingKeyStore: KeyStore, @unchecked Sendable {
    var values: [String: String]
    var reads: [String] = []
    init(_ values: [String: String] = [:]) { self.values = values }
    func has(_ account: String) -> Bool { values[account] != nil }
    func read(_ account: String) throws -> String? { reads.append(account); return values[account] }
    func write(_ account: String, _ value: String) throws { values[account] = value }
    func delete(_ account: String) throws { values[account] = nil }
}

/// A request the stub server got.
struct Got {
    let method: String
    let path: String
    let headers: [String: String]  // lower-case names
    let body: Data
    var json: JSONValue? { try? PythonJSON.parse(body) }
}

/// An HTTP/1.1 server on 127.0.0.1 (a port of its own): each request is kept and answered by `answer`.
final class StubServer: @unchecked Sendable {
    struct Answer {
        var status = 200
        var headers: [(String, String)] = []
        var body = Data()
        /// Seconds to wait before answering (a timeout test).
        var delay = 0.0
        /// Only this many bytes of the body are sent (Content-Length still says all), then the connection closes: a
        /// download cut short. With `stall`, the server waits for it (10 s at most) before closing.
        var sendOnly: Int? = nil
        var stall: DispatchSemaphore? = nil

        static func json(_ v: JSONValue, status: Int = 200, headers: [(String, String)] = []) -> Answer {
            Answer(status: status, headers: [("Content-Type", "application/json")] + headers, body: Data(PythonJSON.dumps(v).utf8))
        }
    }

    private let fd: Int32
    let port: Int
    private let lock = NSLock()
    private var kept: [Got] = []
    var answer: (Got) -> Answer

    init(_ answer: @escaping (Got) -> Answer = { _ in Answer() }) throws {
        self.answer = answer
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.fd = fd
        port = Int(UInt16(bigEndian: got.sin_port))
        let t = Thread { [self] in serve() }
        t.start()
    }

    var url: String { "http://127.0.0.1:\(port)" }
    var requests: [Got] { lock.withLock { kept } }

    func stop() { shutdown(fd, SHUT_RDWR); close(fd) }

    private func serve() {
        while true {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            // A client that gave up (a timeout) closed its end: writing to it must be an error, not SIGPIPE, which ends
            // the whole test process (it does not ignore SIGPIPE).
            var noSigpipe: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            Thread { [self] in handle(c) }.start()
        }
    }

    private func handle(_ c: Int32) {
        defer { close(c) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            let n = read(c, &buffer, buffer.count)
            guard n > 0 else { return }
            data.append(contentsOf: buffer[0..<n])
            headEnd = data.range(of: Data("\r\n\r\n".utf8))
        }
        let head = String(decoding: data[..<headEnd!.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = head[0].split(separator: " ")
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(data[headEnd!.upperBound...])
        let length = Int(headers["content-length"] ?? "0") ?? 0
        while body.count < length {
            let n = read(c, &buffer, buffer.count)
            guard n > 0 else { break }
            body.append(contentsOf: buffer[0..<n])
        }
        let got = Got(method: String(first[0]), path: String(first[1]), headers: headers, body: body)
        lock.withLock { kept.append(got) }
        let a = answer(got)
        if a.delay > 0 { Thread.sleep(forTimeInterval: a.delay) }
        var text = "HTTP/1.1 \(a.status) X\r\nContent-Length: \(a.body.count)\r\nConnection: close\r\n"
        for (k, v) in a.headers { text += "\(k): \(v)\r\n" }
        var out = Data((text + "\r\n").utf8)
        if got.method != "HEAD" { out.append(a.body.prefix(a.sendOnly ?? a.body.count)) }  // a HEAD's answer has no body
        _ = out.withUnsafeBytes { write(c, $0.baseAddress!, out.count) }
        if let stall = a.stall { _ = stall.wait(timeout: .now() + 10) }
        // A graceful close: what was written arrives before the end (an abrupt one may reset it away).
        shutdown(c, SHUT_WR)
        var wait = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        while read(c, &buffer, buffer.count) > 0 {}
    }
}

/// A fake transport: answers each request with the next of `answers` (a status, headers and body, or an error to throw);
/// keeps the requests and the waits.
final class FakeTransport: @unchecked Sendable {
    enum Step {
        case answer(Int, [String: String], String)
        case fail(Error)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []
    private(set) var waits: [Double] = []

    init(_ steps: Step...) { self.steps = steps }

    var client: HTTPClient {
        HTTPClient(transport: { [self] request in try next(request) }, sleep: { [self] s in lock.withLock { waits.append(s) } })
    }

    private func next(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let step: Step = lock.withLock {
            requests.append(request)
            return steps.removeFirst()
        }
        switch step {
        case .fail(let e): throw e
        case .answer(let status, let headers, let body):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
    }

    func body(_ i: Int = 0) -> JSONValue? { requests[i].httpBody.flatMap { try? PythonJSON.parse($0) } }
}

func errorBody(_ message: String) -> String { PythonJSON.dumps(.object([("error", .object([("message", .string(message))]))])) }

/// The error `work` throws, nil when it throws none.
func thrown<T>(_ work: () async throws -> T) async -> Error? {
    do { _ = try await work(); return nil } catch { return error }
}

func thrown<T>(_ work: () throws -> T) -> Error? {
    do { _ = try work(); return nil } catch { return error }
}
