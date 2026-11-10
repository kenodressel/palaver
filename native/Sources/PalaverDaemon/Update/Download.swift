// Downloads of release assets (downloader.py, #60): the manifest, and an asset into a .part file checked against
// the manifest's size and sha256 before anything uses it. Plain HTTPS GETs of public release files: no account, no
// token, nothing sent about the Mac. GitHub redirects release downloads to its storage over HTTPS; a redirect
// anywhere else is refused. `PALAVER_MANIFEST_URL` points at another manifest (a file:// one tests an update without
// a release; file:// assets are allowed only then). Every call blocks: never on the main thread.
import CryptoKit
import Darwin
import Foundation

public struct DownloadError: Error, CustomStringConvertible, Equatable, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct ReleaseDownloads: Sendable {
    /// Seconds without a byte before a request gives up (urllib's timeout in downloader.py).
    public static let timeout = 30.0
    static let chunk = 1 << 20

    public let manifestURL: String

    public init(manifestURL: String) { self.manifestURL = manifestURL }

    /// `PALAVER_MANIFEST_URL` when set, else the latest release's manifest.
    public static func manifestURL(environment: [String: String]) -> String {
        if let given = environment["PALAVER_MANIFEST_URL"], !given.isEmpty { return given }
        return ReleaseManifest.latestURL
    }

    /// https only; file:// only while testing with a local manifest.
    public func allowed(_ url: String) -> Bool {
        url.hasPrefix("https://") || (url.hasPrefix("file://") && manifestURL.hasPrefix("file://"))
    }

    /// The latest release's manifest. Throws DownloadError or ManifestError.
    public func fetchManifest() throws -> ReleaseManifest {
        guard allowed(manifestURL), let url = URL(string: manifestURL) else {
            throw DownloadError("only https downloads are allowed, not \(manifestURL)")
        }
        var body = Data()
        do {
            try get(url) { piece in
                body.append(piece)
                return body.count <= Self.chunk  // the manifest is small: never more than 1 MB of it
            }
        } catch let e as DownloadError {
            throw DownloadError("can't reach \(manifestURL): \(e.description)")
        }
        return try ReleaseManifest.parse(body.prefix(Self.chunk))
    }

    /// `asset` into `dest`, its size and sha256 checked; a wrong or short file is deleted and throws. It stops as soon
    /// as more bytes arrive than the asset's size.
    @discardableResult
    public func download(_ asset: ReleaseAsset, to dest: URL, progress: (Int) -> Void = { _ in }) throws -> URL {
        guard allowed(asset.url), let url = URL(string: asset.url) else {
            throw DownloadError("only https downloads are allowed, not \(asset.url)")
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(dest.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw DownloadError("download of \(asset.name) failed: \(String(cString: strerror(errno)))") }
        var hasher = SHA256()
        var got = 0
        do {
            defer { close(fd) }
            try get(url) { piece in
                // More than the release says is a wrong file: stop before it fills the disk.
                guard got + piece.count <= asset.size else { throw DownloadError("more than the \(asset.size) bytes the release names") }
                try piece.withUnsafeBytes { raw in
                    var done = 0
                    while done < raw.count {
                        let n = Darwin.write(fd, raw.baseAddress! + done, raw.count - done)
                        if n < 0 && errno == EINTR { continue }
                        if n <= 0 { throw DownloadError("could not write \(dest.lastPathComponent): \(String(cString: strerror(errno)))") }
                        done += n
                    }
                }
                hasher.update(data: piece)
                got += piece.count
                progress(got)
                return true
            }
        } catch let e as DownloadError {
            unlink(dest.path)
            throw DownloadError("download of \(asset.name) failed: \(e.description)")
        }
        let sha = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard got == asset.size, sha == asset.sha256 else {
            unlink(dest.path)
            throw DownloadError("\(asset.name) arrived damaged (checksum mismatch); nothing was changed")
        }
        return dest
    }

    /// GETs `url` and hands each piece to `take` as it arrives (false: enough, stop). Throws DownloadError.
    private func get(_ url: URL, take: (Data) throws -> Bool) throws {
        if url.isFileURL {
            guard let h = FileHandle(forReadingAtPath: url.path) else {
                throw DownloadError("[Errno 2] No such file or directory: '\(url.path)'")
            }
            defer { try? h.close() }
            while true {
                let piece = h.readData(ofLength: Self.chunk)
                if piece.isEmpty { return }
                if try !take(piece) { return }
            }
        }
        let transfer = Transfer()
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.setValue("Palaver", forHTTPHeaderField: "User-Agent")
        try transfer.run(request, take: take)
    }
}

/// One GET, streamed: the pieces go to the caller's thread through a small queue, so a slow disk slows the
/// download instead of filling memory. Redirects only to https.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSCondition()
    private var pieces: [Data] = []
    private var finished = false
    private var failure: DownloadError?
    private var stopped = false

    func run(_ request: URLRequest, take: (Data) throws -> Bool) throws {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = ReleaseDownloads.timeout
        c.timeoutIntervalForResource = 24 * 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: c, delegate: self, delegateQueue: queue)
        defer {
            // A delegate call waiting for room is let go before the session ends.
            lock.lock(); stopped = true; lock.broadcast(); lock.unlock()
            session.invalidateAndCancel()
        }
        let task = session.dataTask(with: request)
        task.resume()
        while true {
            lock.lock()
            while pieces.isEmpty && !finished { lock.wait() }
            let batch = pieces
            pieces = []
            let done = finished, error = failure
            lock.signal()
            lock.unlock()
            for piece in batch {
                if try !take(piece) { return }  // enough: the defer ends the transfer
            }
            if done {
                if let error { throw error }
                return
            }
        }
    }

    private func finish(_ error: DownloadError?) {
        lock.lock()
        if !finished { finished = true; failure = error }
        lock.broadcast()
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let next = request.url, next.scheme == "https" else {
            finish(DownloadError("refused a redirect away from https: \(request.url?.absoluteString ?? "?")"))
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(DownloadError("HTTP Error \(http.statusCode): \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))"))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        // At most a few MB waiting: the caller writes them to disk.
        while pieces.reduce(0, { $0 + $1.count }) > 8 << 20 && !stopped { lock.wait() }
        if !stopped { pieces.append(data) }
        lock.broadcast()
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let reason = (error as? URLError)?.localizedDescription ?? error.localizedDescription
            finish(DownloadError(reason))
        } else {
            finish(nil)
        }
    }
}
