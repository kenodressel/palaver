// A tiny Hugging Face hub on 127.0.0.1 for the model-download tests: one repo at one revision, its files served by the
// hub itself with their sha256 as ETag (HEAD and GET, no CDN). PalaverCloudTests' StubHub covers redirects and resumes.
import CryptoKit
import Darwin
import Foundation

final class TinyHub: @unchecked Sendable {
    let repo: String
    let revision: String
    let files: [String: Data]
    /// The revision when it is a commit (a pin), else a commit of its own (a branch).
    let commit: String
    private let fd: Int32
    let port: Int
    private let lock = NSLock()
    private var seen: [(path: String, authorization: String?)] = []

    init(repo: String, revision: String, files: [String: String]) throws {
        self.repo = repo
        self.revision = revision
        commit = revision.count == 40 ? revision : "fedcba9876543210fedcba9876543210fedcba98"
        self.files = files.mapValues { Data($0.utf8) }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.fd = fd
        port = Int(UInt16(bigEndian: got.sin_port))
        Thread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { return }
                // A client that gave up (a timeout) closed its end: writing to it must be an error, not SIGPIPE, which ends
                // the whole test process (it does not ignore SIGPIPE).
                var noSigpipe: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
                Thread { [self] in handle(c) }.start()
            }
        }.start()
    }

    var url: String { "http://127.0.0.1:\(port)" }
    var paths: [String] { lock.withLock { seen.map(\.path) } }
    /// The Authorization headers the hub got, once each.
    var authorizations: [String] { lock.withLock { Array(Set(seen.compactMap(\.authorization))).sorted() } }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private func handle(_ c: Int32) {
        defer { close(c) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = read(c, &buffer, buffer.count)
            guard n > 0 else { return }
            data.append(contentsOf: buffer[0..<n])
        }
        let head = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        let first = head[0].split(separator: " ").map(String.init)
        let method = first[0], path = first[1].removingPercentEncoding ?? first[1]
        let auth = head.first { $0.lowercased().hasPrefix("authorization:") }.map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) }
        lock.withLock { seen.append((path, auth)) }
        var status = 404, headers: [(String, String)] = [], body = Data()
        if path == "/api/models/\(repo)/revision/\(revision)" {
            let siblings = files.keys.sorted().map { "{\"rfilename\": \"\($0)\"}" }.joined(separator: ", ")
            (status, body) = (200, Data("{\"sha\": \"\(commit)\", \"siblings\": [\(siblings)]}".utf8))
        } else if path.hasPrefix("/\(repo)/resolve/\(commit)/"), let file = files[String(path.dropFirst("/\(repo)/resolve/\(commit)/".count))] {
            (status, body) = (200, file)
            headers = [("ETag", "\"\(Self.sha256(file))\""), ("X-Repo-Commit", commit)]
        }
        var text = "HTTP/1.1 \(status) X\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in headers { text += "\(k): \(v)\r\n" }
        var out = Data((text + "\r\n").utf8)
        if method != "HEAD" { out.append(body) }
        _ = out.withUnsafeBytes { write(c, $0.baseAddress!, out.count) }
        shutdown(c, SHUT_WR)  // a graceful close: the answer arrives whole
        var wait = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        while read(c, &buffer, buffer.count) > 0 {}
    }
}
