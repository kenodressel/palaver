// The window's HTTP server on SwiftNIO (webapp/server.py `_handler`, `make_server`): on 127.0.0.1,
// one request per connection (`HTTP/1.0`, closed after the answer). The event loop only parses and
// checks: the Host header, the sign-in and the key, a POST's type and size (refused from its
// Content-Length before a byte of the body is read, or as soon as a body without one grows past the
// limit). Every route runs on a thread of its own, so a slow one never holds up the others; a page
// that lets go meanwhile is no error.
import Darwin
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import PalaverCore
import PalaverDomain

public final class HTTPServer: @unchecked Sendable {
    public let app: ServerApp
    let router: Router
    let log: SessionLog?
    private let key: String?
    private let lock = NSLock()
    private var channel: Channel?
    private var gate: Gate

    /// `key` nil: everyone on this Mac may (tests); otherwise only the window, which signs in with it.
    public init(app: ServerApp, key: String?, router: Router? = nil, log: SessionLog? = nil) {
        self.app = app
        self.key = key
        self.router = router ?? Router.palaver(app: app)
        self.log = log
        if app.log == nil { app.log = log }
        gate = Gate(port: 0, key: key)
    }

    /// The port it serves on (0 before a start).
    public var port: Int { lock.withLock { gate.port } }

    /// Serves on a socket already listening, handed over by the menu bar app (#57); returns its port.
    @discardableResult
    public func start(listenFD: Int32) throws -> Int {
        let port = try HTTPServer.localPort(listenFD)
        lock.withLock { gate = Gate(port: port, key: key) }
        let ch = try bootstrap().withBoundSocket(listenFD).wait()
        lock.withLock { channel = ch }
        return port
    }

    /// Binds 127.0.0.1:`port` itself (0: any free one); returns the port.
    @discardableResult
    public func start(port: Int) throws -> Int {
        try start(listenFD: HTTPServer.listen(port: port))
    }

    /// No new connections from now on (`server.shutdown()`, `server_close()`): requests still queued
    /// in the socket wait there for the next server; answers being made still go out.
    public func shutdown() {
        let ch = lock.withLock { () -> Channel? in defer { channel = nil }; return channel }
        try? ch?.close().wait()
    }

    /// True once no change (POST) is being made; false after `timeout` seconds.
    @discardableResult
    public func waitIdle(timeout: Double) -> Bool { app.inflight.waitIdle(timeout: timeout) }

    private func bootstrap() -> ServerBootstrap {
        ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { [self] ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)))
                    try ch.pipeline.syncOperations.addHandler(Connection(server: self))
                }
            }
    }

    // MARK: - what Connection asks

    var currentGate: Gate { lock.withLock { gate } }

    /// The route's answer on a thread of its own. `ticket`: a POST's count in the drain (`do_POST`'s
    /// `change()`, taken when its head was accepted), the route's own until the answer is out.
    /// `body`: a JSON route's body, parsed there (`json.loads(body or b"{}")`); `cleanup` runs before the answer goes out.
    func dispatch(_ request: Request, body: Data? = nil, on channel: Channel, ticket: Inflight.Ticket? = nil,
                  cleanup: (() -> Void)? = nil) {
        let thread = Thread { [self] in
            let work = { () -> Response? in
                do {
                    var request = request
                    if let body {
                        do {
                            let json = try PythonJSON.parse(body.isEmpty ? Data("{}".utf8) : body)
                            request = Request(method: request.method, target: request.target, headers: request.headers, json: json)
                        } catch {
                            throw BadRequest(String(describing: error))
                        }
                    }
                    return try self.router.answer(request, staticDir: self.app.staticDir)
                } catch {
                    if ErrorTable.isFailure(error) {
                        self.log?.message("\(request.method) \(HTTPServer.shown(request.target)) failed: \(error)", level: "ERROR",
                                          logger: HTTPServer.logger)
                    }
                    return Response.from(error)
                }
            }
            let response = ticket.map { self.app.inflight.adopt($0, work) } ?? work()
            cleanup?()
            self.send(response, for: request, on: channel, then: { ticket?.leave() })
        }
        thread.name = "palaver-request"
        thread.stackSize = 8 << 20
        thread.start()
    }

    /// The answer, then the connection closed, then `then`; nil: closed without one. A page that let go is no error.
    func send(_ response: Response?, for request: Request, on channel: Channel, then: (() -> Void)? = nil) {
        guard let response else {
            channel.close().whenComplete { _ in then?() }
            return
        }
        logRequest(request, status: response.status)
        let bytes = response.encoded(head: request.method == "HEAD")
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        channel.writeAndFlush(buffer).whenComplete { _ in channel.close().whenComplete { _ in then?() } }
    }

    static let logger = "palaver.webapp"

    /// `log_request`: changes (POSTs) and failed requests into the log (#59); the page's polling
    /// (GETs every few seconds) and its usage counts not.
    private func logRequest(_ request: Request, status: Int) {
        guard let log else { return }
        let line = "\(request.method) \(HTTPServer.shown(request.target)) → \(status)"
        if status >= 400 {
            log.message(line, level: "WARNING", logger: HTTPServer.logger)
        } else if request.method == "POST" && request.target != "/api/usage" {
            log.message(line, level: "INFO", logger: HTTPServer.logger)
        }
    }

    /// A target as it goes into the log: a `key` in its query never does.
    static func shown(_ target: String) -> String {
        guard let q = target.firstIndex(of: "?") else { return target }
        let pairs = target[target.index(after: q)...].split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            let name = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return PyURL.unquotePlus(name) == "key" ? "key=…" : String(pair)
        }
        return String(target[...q]) + pairs.joined(separator: "&")
    }

    // MARK: - sockets

    /// `process.listen(port)`: a listening socket on 127.0.0.1, close-on-exec.
    static func listen(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError("socket: \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 128) == 0 else {
            let error = String(cString: strerror(errno))
            Darwin.close(fd)
            throw ServerError("cannot listen on 127.0.0.1:\(port): \(error)")
        }
        return fd
    }

    static func localPort(_ fd: Int32) throws -> Int {
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &got) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard rc == 0 else { throw ServerError("not a socket: fd \(fd)") }
        return Int(UInt16(bigEndian: got.sin_port))
    }
}

public struct ServerError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// One connection: its one request, read and checked on the event loop.
final class Connection: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart

    private enum State {
        case waiting
        /// A JSON body up to `limit` bytes.
        case collecting(Request, ByteBuffer, limit: Int)
        /// A file route's body, into a temporary file.
        case spooling(Request, Spool)
        /// Answered or handed to a route: whatever else comes is not read.
        case done
    }

    private let server: HTTPServer
    private var state = State.waiting
    /// A POST's count in the drain, from its accepted head until a route thread takes it or the
    /// connection ends without one.
    private var ticket: Inflight.Ticket?

    init(server: HTTPServer) { self.server = server }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch (unwrapInboundIn(data), state) {
        case (.head(let head), .waiting): received(head, context: context)
        case (.body(let chunk), .collecting(let request, var buffer, let limit)):
            if buffer.readableBytes + chunk.readableBytes > limit {  // a body without (or past) its Content-Length
                answer(.error(413, "too large"), for: request, context: context)
                return
            }
            state = .done  // no copy of the buffer while it grows
            buffer.writeImmutableBuffer(chunk)
            state = .collecting(request, buffer, limit: limit)
        case (.body(let chunk), .spooling(_, let spool)): spool.write(chunk, context: context)
        case (.end, .collecting(let request, let buffer, _)):
            state = .done
            stopReading(context)
            let body = Data(buffer.readableBytesView)
            let ch = context.channel
            server.dispatch(request, body: body, on: ch, ticket: handOff())
        case (.end, .spooling(let request, let spool)):
            state = .done
            stopReading(context)
            let ch = context.channel
            let ticket = handOff()
            spool.finish { [server] file in
                guard let file else {  // the disk would not take it: nobody to tell but the log
                    server.log?.message("POST \(HTTPServer.shown(request.target)) failed: could not keep its body",
                                        level: "ERROR", logger: HTTPServer.logger)
                    ch.close().whenComplete { _ in ticket?.leave() }
                    return
                }
                let withFile = Request(method: request.method, target: request.target, headers: request.headers,
                                       json: .null, bodyFile: file)
                server.dispatch(withFile, on: ch, ticket: ticket, cleanup: { spool.removeNow() })
            }
        default: break
        }
    }

    private func received(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        let headers = head.headers.map { ($0.name, $0.value) }
        let request = Request(method: head.method.rawValue, target: head.uri, headers: headers, json: .null)
        let gate = server.currentGate
        switch request.method {
        case "GET", "HEAD":
            state = .done
            stopReading(context)
            guard gate.hostOK(request.header("Host")) else { return answer(.error(403, "wrong host"), for: request, context: context) }
            if let given = request.queryValue("key") { return answer(gate.signIn(request, given: given), for: request, context: context) }
            guard gate.keyOK(cookieHeader: request.header("Cookie")) else {
                return answer(.error(403, "open Palaver from its menu bar icon"), for: request, context: context)
            }
            server.dispatch(request, on: context.channel)
        case "POST":
            ticket = server.app.inflight.enter()  // counted from here, its body's arrival included
            guard gate.hostOK(request.header("Host")) else { return answer(.error(403, "wrong host"), for: request, context: context) }
            guard gate.keyOK(cookieHeader: request.header("Cookie")) else {
                return answer(.error(403, "open Palaver from its menu bar icon"), for: request, context: context)
            }
            let type = (request.header("Content-Type") ?? "").split(separator: ";", omittingEmptySubsequences: false).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let length = request.header("Content-Length").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
            if let file = server.router.fileBody(forPost: request.target) {
                guard type == file.contentType else { return answer(.error(415, file.wrongType), for: request, context: context) }
                guard length > 0, length <= file.limit else {
                    return answer(length > 0 ? .error(413, file.tooLarge) : .error(400, file.missing), for: request, context: context)
                }
                do {
                    state = .spooling(request, try Spool(channel: context.channel))
                } catch {
                    server.log?.message("POST \(HTTPServer.shown(request.target)) failed: \(error)", level: "ERROR",
                                        logger: HTTPServer.logger)
                    state = .done
                    close(context)
                }
                return
            }
            guard type == "application/json" else { return answer(.error(415, "JSON only"), for: request, context: context) }
            let limit = Router.bodyLimit(request.target)
            guard length <= limit else { return answer(.error(413, "too large"), for: request, context: context) }  // refused unread
            state = .collecting(request, context.channel.allocator.buffer(capacity: min(length, limit)), limit: limit)
        default:
            state = .done
            answer(.unsupportedMethod(request.method), for: request, context: context)
        }
    }

    /// An answer from the event loop; the rest of the request is never read.
    private func answer(_ response: Response, for request: Request, context: ChannelHandlerContext) {
        state = .done
        stopReading(context)
        let ticket = handOff()
        server.send(response, for: request, on: context.channel, then: { ticket?.leave() })
    }

    /// The request is complete or answered: nothing more is read from the page.
    private func stopReading(_ context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in }
    }

    /// The ticket, now the caller's to leave.
    private func handOff() -> Inflight.Ticket? {
        defer { ticket = nil }
        return ticket
    }

    /// Closed without an answer: the request is no longer a change being made.
    private func close(_ context: ChannelHandlerContext) {
        let ticket = handOff()
        context.close().whenComplete { _ in ticket?.leave() }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // The page stopped sending: a request it never finished gets no answer.
        if case ChannelEvent.inputClosed = event {
            switch state {
            case .waiting, .collecting: state = .done; close(context)
            case .spooling(_, let spool):
                state = .done
                let ticket = handOff()
                spool.remove { ticket?.leave() }
                context.close(promise: nil)
            case .done: break
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        let ticket = handOff()
        if case .spooling(_, let spool) = state {
            spool.remove { ticket?.leave() }  // counted until its file is gone
        } else {
            ticket?.leave()
        }
        state = .done
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Not HTTP (a broken request line, bad headers): 400 if nothing was answered yet. A reset is no error.
        if case .waiting = state, error is HTTPParserError {
            state = .done
            let ticket = handOff()
            server.send(.error(400, "bad request"), for: Request(method: "-", target: "-"), on: context.channel,
                        then: { ticket?.leave() })
            return
        }
        if case .spooling(_, let spool) = state {
            state = .done
            let ticket = handOff()
            let ch = context.channel
            spool.remove { ch.close().whenComplete { _ in ticket?.leave() } }
            return
        }
        state = .done
        close(context)
    }
}

/// A file route's body on its way to a temporary file (`palaver-import-*/import.zip`), written on
/// a queue of its own; while more than `highWater` bytes wait for the disk, the socket is not read.
final class Spool: @unchecked Sendable {
    static let highWater = 4 << 20

    let dir: URL
    let file: URL
    private let fd: Int32
    private let queue = DispatchQueue(label: "palaver.spool")
    private let channel: Channel
    /// On the event loop.
    private var pending = 0
    private var paused = false
    /// The whole body arrived: reading stays off.
    private var ended = false
    /// On the queue.
    private var failed = false
    private var closed = false

    init(channel: Channel) throws {
        var template = Array((FileManager.default.temporaryDirectory.path + "/palaver-import-XXXXXX").utf8CString)
        guard let made = mkdtemp(&template) else { throw ServerError("no temporary folder: \(String(cString: strerror(errno)))") }
        dir = URL(fileURLWithPath: String(cString: made), isDirectory: true)
        file = dir.appendingPathComponent("import.zip")
        fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(at: dir)
            throw ServerError("no temporary file: \(String(cString: strerror(errno)))")
        }
        self.channel = channel
    }

    func write(_ chunk: ByteBuffer, context: ChannelHandlerContext) {
        let bytes = Data(chunk.readableBytesView)
        pending += bytes.count
        if pending > Spool.highWater && !paused {
            paused = true
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in }
        }
        let loop = context.eventLoop
        queue.async { [self] in
            if !failed {
                failed = !bytes.withUnsafeBytes { raw in
                    var done = 0
                    while done < raw.count {
                        let n = Darwin.write(fd, raw.baseAddress! + done, raw.count - done)
                        if n < 0 && errno == EINTR { continue }
                        if n <= 0 { return false }
                        done += n
                    }
                    return true
                }
            }
            loop.execute { [self] in
                pending -= bytes.count
                if paused && !ended && pending <= Spool.highWater / 2 {
                    paused = false
                    channel.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in }
                }
            }
        }
    }

    /// Once everything is on disk: the file, or nil when the disk refused some of it. On the event loop.
    func finish(_ done: @escaping (URL?) -> Void) {
        ended = true
        queue.async { [self] in
            let closedOK = closeFile()
            let ok = !failed && closedOK
            if !ok { try? FileManager.default.removeItem(at: dir) }
            done(ok ? file : nil)
        }
    }

    /// The folder and the file gone, then `then`.
    func remove(then: (() -> Void)? = nil) {
        queue.async { [self] in
            discard()
            then?()
        }
    }

    /// The same, before returning (never on the event loop: it waits for the writes queued before).
    func removeNow() { queue.sync { discard() } }

    /// On the queue.
    private func discard() {
        failed = true
        _ = closeFile()
        try? FileManager.default.removeItem(at: dir)
    }

    /// On the queue: closes the file once, whatever happened before.
    private func closeFile() -> Bool {
        guard !closed else { return true }
        closed = true
        return close(fd) == 0
    }
}
