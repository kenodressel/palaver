// The window server's side of app.sock (palaver/appctl.py `call`): one JSON line
// `{"call": name, "args": {...}}` per connection, one JSON line back, `{"ok": result}` or
// `{"error": message, "refused": bool}`. The app's side is PalaverDaemon's AppSocket (and Python's
// `appctl.serve`); the bytes sent are `json.dumps`'s, ensure_ascii and ", "/": " separators included.
//
// Timeouts are per operation, as a Python socket's `settimeout` is (connect, each send, each recv).
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

public enum AppCtlClient {
    /// `appctl.TIMEOUT`: the window polls; an app that does not answer this fast is left out.
    public static let TIMEOUT = 1.0
    /// `appctl.MAIN_THREAD_TIMEOUT`: what runs on the menu bar's main thread waits for it this long at most.
    public static let MAIN_THREAD_TIMEOUT = 10.0

    /// The recording process is not there or did not answer in time (`appctl.CallFailed`).
    public struct CallFailed: Error, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    /// The recording process answered no; the message says why, for the page (`appctl.CallRefused`).
    public struct CallRefused: Error, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    /// Asks the recording process on the socket `path`: its `ok` answer, or `CallFailed` (not there, too slow, no
    /// answer) or `CallRefused` (it said no, and why). `args` nil or an empty object sends `{}` (`args or {}`).
    public static func call(_ name: String, _ args: JSONValue? = nil, path: URL, timeout: Double = TIMEOUT) throws -> JSONValue {
        #if DEBUG
        TestIsolation.checkOutsideHome(path, "the app socket")
        #endif
        var sendArgs = args ?? .object([])
        if !sendArgs.truthy { sendArgs = .object([]) }
        let request = PythonJSON.dumps(.object([("call", .string(name)), ("args", sendArgs)])) + "\n"
        let data: Data
        do {
            data = try exchange(Data(request.utf8), path: path.path, timeout: timeout)
        } catch let e as SocketError {
            throw CallFailed("\(name): \(e.text)")
        }
        guard let answer = try? PythonJSON.parse(data), case .object = answer else {
            throw CallFailed("\(name): no answer")
        }
        if let ok = answer["ok"] { return ok }
        if answer["refused"]?.truthy == true {
            let error = answer["error"]
            throw CallRefused(error.map { $0.truthy ? Py.str($0) : "refused" } ?? "refused")
        }
        throw CallFailed("\(name): \(Py.str(answer["error"] ?? .null))")
    }

    /// An OSError's text as Python prints it: `[Errno N] message`, `timed out`, `AF_UNIX path too long`.
    struct SocketError: Error {
        let text: String
        static func errno(_ code: Int32) -> SocketError { SocketError(text: "[Errno \(code)] \(String(cString: strerror(code)))") }
        static let timedOut = SocketError(text: "timed out")
    }

    /// Connects, sends `request`, reads until the answer ends with a newline or the app closes.
    static func exchange(_ request: Data, path: String, timeout: Double) throws -> Data {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw SocketError(text: "AF_UNIX path too long") }
        guard !bytes.contains(0) else { throw SocketError(text: "embedded null character") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.errno(errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let millis = Int32(max(0, min(timeout * 1000, Double(Int32.max))).rounded(.up))

        // Connect without blocking past the timeout.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let e = errno
            guard e == EINPROGRESS || e == EAGAIN else { throw SocketError.errno(e) }
            try wait(fd, events: Int16(POLLOUT), millis: millis)
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 { throw SocketError.errno(err) }
        }

        try request.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = send(fd, raw.baseAddress! + off, raw.count - off, 0)
                if n > 0 { off += n; continue }
                let e = errno
                if n < 0, e == EAGAIN || e == EINTR {
                    if e == EAGAIN { try wait(fd, events: Int16(POLLOUT), millis: millis) }
                    continue
                }
                throw SocketError.errno(e)
            }
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.last != 0x0A {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 { data.append(contentsOf: buffer[0..<n]); continue }
            if n == 0 { break }  // the app closed
            let e = errno
            if e == EINTR { continue }
            guard e == EAGAIN else { throw SocketError.errno(e) }
            try wait(fd, events: Int16(POLLIN), millis: millis)
        }
        return data
    }

    /// Waits up to `millis` for `events` on `fd`: `timed out` when nothing came.
    private static func wait(_ fd: Int32, events: Int16, millis: Int32) throws {
        var p = pollfd(fd: fd, events: events, revents: 0)
        while true {
            let n = poll(&p, 1, millis)
            if n > 0 { return }
            if n == 0 { throw SocketError.timedOut }
            if errno != EINTR { throw SocketError.errno(errno) }
        }
    }
}
