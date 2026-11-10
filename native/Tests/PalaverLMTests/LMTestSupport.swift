// Test support: a meeting folder of its own, the stores and settings over temporary folders, a run's context with a
// fake model, and a tiny HTTP server on 127.0.0.1 for the cloud runners.
import Darwin
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain
@testable import PalaverLM

let KEY = "sk-ant-api03-SECRET-abcdefghijklmnop"
let MEETING = "2026-10-21T16-29-29"

func tempFolder(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-lm-\(name)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.resolvingSymlinksInPath()
}

func utterance(_ speaker: String, _ start: Double, _ text: String, label: String? = nil) -> Utterance {
    Utterance(speaker: speaker, start: start, end: start + 4, text: text, label: label)
}

/// German small talk with unnamed voices (as transcript.json keeps them: the label as the speaker, no "label" until
/// one is named), one of which introduces itself: Timo Strauß records, SPEAKER_01 is Valerie.
let GERMAN: [Utterance] = [
    utterance("Timo Strauß", 3, "Hallo zusammen, wir fangen mit dem Projekt für Contoso an."),
    utterance("SPEAKER_01", 9, "Hallo, ich bin Valerie und ich mache das Angebot für Contoso."),
    utterance("Timo Strauß", 15, "Gut, dann schickst du mir das Angebot bis Freitag?"),
    utterance("SPEAKER_01", 21, "Ja, das mache ich, das Angebot kommt bis Freitag."),
    utterance("SPEAKER_02", 3700, "Und wir sprechen nächste Woche noch einmal über den Preis."),
]

/// A config dir, a home and recordings of their own, a file key store, and the settings and a run's context over them.
final class Home {
    let dir = tempFolder("home")
    lazy var stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                                 home: dir.appendingPathComponent("home", isDirectory: true))
    lazy var keys = FileKeyStore(dir.appendingPathComponent("keychain.json"))
    lazy var outputDir = dir.appendingPathComponent("Recordings", isDirectory: true)
    var config = Config()
    /// No `claude` anywhere: PATH is empty and config.toml names one that is not there.
    var env: [String: String] = ["PATH": ""]
    var said: [String] = []

    init() {
        config.claudePath = dir.appendingPathComponent("no-claude").path
        config.userName = "Timo Strauß"
        config.outputDir = outputDir
        for folder in [outputDir, stores.configDir, stores.home] {
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    var settings: ProviderSettings { ProviderSettings(config: config, stores: stores, keys: keys, env: env) }

    /// The context of a run whose model is `fake` (whatever was chosen), saying its lines into `said`.
    func context(_ fake: LanguageModel? = nil, http: HTTPClient = HTTPClient()) -> LMMain.Context {
        var ctx = LMMain.Context(config: config, stores: stores, settings: settings, userName: config.userName)
        ctx.http = http
        if let fake { ctx.fake = { _, _, _ in fake } }
        ctx.say = { [unowned self] in said.append($0) }
        return ctx
    }

    /// A processed meeting: transcript.json and meta.json.
    @discardableResult
    func meeting(_ id: String = MEETING, _ utterances: [Utterance] = GERMAN, start: String = "2026-10-21T16:29:29+02:00") -> RecordingPaths {
        let folder = outputDir.appendingPathComponent(id, isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paths = RecordingPaths(folder)
        try! PythonJSON.write(.array(utterances.map(\.json)), to: paths.transcriptJson, indent: 2, ensureAscii: false)
        try! PythonJSON.write(.object([("start_time", .string(start))]), to: paths.meta, indent: 2, ensureAscii: false)
        return paths
    }

    /// The session.log events of `paths`, in order.
    func events(_ paths: RecordingPaths) -> [JSONValue] {
        guard let text = try? String(contentsOf: paths.sessionLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? PythonJSON.parse(Data($0.utf8)) }.filter { $0["event"] != nil }
    }

    func usage() -> [JSONValue] { Usage.read(stores.usage).map(\.json) }

    deinit { try? FileManager.default.removeItem(at: dir) }
}

/// A valid notes answer.
let NOTES_ANSWER = JSONValue.object([
    ("title", .string("Angebot für Contoso")), ("summary", .string("Valerie schickt das Angebot bis Freitag.")),
    ("sections", .array([.object([("heading", .string("Angebot")),
                                  ("points", .array([.object([("text", .string("Angebot bis Freitag")),
                                                              ("details", .strings(["SPEAKER_01: das mache ich"]))])]))])])),
    ("next_steps", .array([.object([("owner", .string("SPEAKER_01")), ("task", .string("Angebot schicken bis Freitag"))])])),
    ("decisions", .strings(["Das Angebot kommt bis Freitag"])),
    ("speaker_names", .array([.object([("label", .string("SPEAKER_01")), ("name", .string("Valerie")),
                                       ("evidence", .string("ich bin Valerie"))]),
                              .object([("label", .string("SPEAKER_07")), ("name", .string("Erfunden")),
                                       ("evidence", .string(""))])])),
])

func run(_ args: [String], _ ctx: LMMain.Context) async throws -> Int32 {
    await LMMain.run(try LMMain.parse(args), ctx)
}

/// The error `work` throws, nil when it throws none.
func thrown<T>(_ work: () async throws -> T) async -> Error? {
    do { _ = try await work(); return nil } catch { return error }
}

func thrown<T>(_ work: () throws -> T) -> Error? {
    do { _ = try work(); return nil } catch { return error }
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

