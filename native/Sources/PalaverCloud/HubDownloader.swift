// Model downloads from Hugging Face in this process (palaver/onboarding.py `_fetch` and `download`, embeddings.py's
// download, huggingface_hub's snapshot_download / hf_hub_download): the file list of one pinned revision, filtered by
// the allow patterns mlx_lm uses, each file fetched into the Hugging Face cache (HFCache) exactly where
// huggingface_hub puts it, so nothing is downloaded twice and the Python fallback reads the same files.
//
// For each file: a HEAD of `resolve/<commit>/<file>` gives its ETag (the sha256 of an LFS file, else its git oid), size
// and, for an LFS file, a redirect to Hugging Face's CDN. The bytes go to `blobs/<etag>.incomplete` (an interrupted
// download is resumed from its length with a Range request), are checked (size; sha256 when the ETag is one), renamed
// into place and linked into `snapshots/<commit>/`. A blob is flock'd while it downloads (the lock file
// huggingface_hub's filelock uses), so two downloads of it never write the same file.
//
// The token goes in the Authorization header only to the hub itself (`HF_ENDPOINT`, huggingface.co, hf.co). A redirect
// is followed only to the same hub or to Hugging Face's CDN hosts (https, *.huggingface.co / *.hf.co), and the CDN never
// gets the Authorization header. Nothing here logs a token or puts one in an error; errors name hosts, never URLs
// (a CDN URL carries a signature).
import CryptoKit
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

/// A download failed; the message is one line, safe to show and to log.
public struct HubError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// The revision and the files of each model Palaver downloads, as 0.5.0rc6 pinned them (notes.py `MODEL_REVISIONS`,
/// `MODEL_FILES`; embeddings.py `MODEL`, `REVISION`, `MODEL_FILES`). HubModelsTests keeps it equal to the Python
/// constants.
public enum HubModels {
    /// The files mlx_lm reads (its DEFAULT_ALLOW_PATTERNS): not a repo's README or extra weights (Gemma's vision sidecar).
    public static let MLX_FILES = ["*.json", "model*.safetensors", "*.py", "tokenizer.model", "*.tiktoken", "tiktoken.model",
                                   "*.txt", "*.jsonl", "*.jinja"]

    public struct Pin: Sendable, Equatable {
        public let repo: String
        public let revision: String
        public let patterns: [String]
    }

    public static let pins: [Pin] = [
        Pin(repo: ModelCatalog.GEMMA, revision: "de9e183868050b34bf6b4272518500ffcebf15b3", patterns: MLX_FILES),
        Pin(repo: ModelCatalog.QWEN, revision: "e9675aa3ca5f900ccef55267914466d55ab325fa", patterns: MLX_FILES),
        Pin(repo: E5Encoder.model, revision: E5Encoder.revision, patterns: E5Encoder.modelFiles),
    ]

    /// `repo`'s pin; a repo not in the table: its "main" with mlx_lm's files (onboarding `download`).
    public static func pin(_ repo: String) -> Pin {
        pins.first { $0.repo == repo } ?? Pin(repo: repo, revision: "main", patterns: MLX_FILES)
    }
}

public final class HubDownloader: @unchecked Sendable {
    public static let DEFAULT_ENDPOINT = "https://huggingface.co"
    /// Tries of one request or one file's transfer (each transfer resumes where the last one stopped).
    public static let ATTEMPTS = 5
    public static let BACKOFF_SECONDS = [1.0, 2.0, 4.0, 8.0]
    static let RETRY_STATUS: Set<Int> = [408, 429, 500, 502, 503, 504]
    /// The hub's own origins: the token may go there (huggingface_hub's `_HUB_ORIGINS`).
    static let HUB_ORIGINS = ["https://huggingface.co", "https://hf.co"].map { Origin(URL(string: $0)!) }
    /// Hugging Face's download hosts (cdn-lfs.huggingface.co, cdn-lfs-us-1.hf.co, cas-bridge.xethub.hf.co, …).
    public static let CDN_DOMAINS = ["huggingface.co", "hf.co"]

    public let cache: HFCache
    public let endpoint: URL
    let transport: HTTPClient.Transport
    let isTrustedCDN: @Sendable (URL) -> Bool
    let sleep: @Sendable (Double) async -> Void
    let freeBytes: @Sendable (URL) -> Int64?
    /// Seconds a transfer may go without a byte before it counts as cut (and is resumed).
    let idleTimeout: Double

    /// `endpoint`: `HF_ENDPOINT` (tests' stub hub), else huggingface.co. `transport`: requests that never follow a
    /// redirect (batch 1's URLSession). `isTrustedCDN`: where a download may be redirected to besides the hub.
    public init(cache: HFCache, endpoint: URL? = nil, transport: HTTPClient.Transport? = nil,
                isTrustedCDN: @escaping @Sendable (URL) -> Bool = HubDownloader.huggingFaceCDN,
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
                freeBytes: @escaping @Sendable (URL) -> Int64? = { HFCache.freeBytes($0) }, idleTimeout: Double = 60) {
        self.cache = cache
        self.endpoint = endpoint ?? URL(string: Self.DEFAULT_ENDPOINT)!
        self.transport = transport ?? HTTPClient.urlSession
        self.isTrustedCDN = isTrustedCDN
        self.sleep = sleep
        self.freeBytes = freeBytes
        self.idleTimeout = idleTimeout
    }

    /// The downloader of `stores`' cache, with `HF_ENDPOINT` from `env` when it is set (and, in a debug build,
    /// `PALAVER_TEST_HF_CDN`: the one origin trusted as the CDN).
    public convenience init(stores: StorePaths, env: [String: String]) {
        var trusted = Self.huggingFaceCDN
        #if DEBUG
        // The e2e tests' stub CDN (another origin than their stub hub), in place of Hugging Face's.
        if let cdn = env["PALAVER_TEST_HF_CDN"].flatMap({ URL(string: $0) }) {
            let origin = Origin(cdn)
            trusted = { Origin($0) == origin }
        }
        #endif
        self.init(cache: HFCache(stores: stores), endpoint: Self.endpoint(env: env), isTrustedCDN: trusted)
    }

    /// `HF_ENDPOINT` without its trailing "/", nil when it is not set (or not a URL).
    public static func endpoint(env: [String: String]) -> URL? {
        guard var text = env["HF_ENDPOINT"].map({ $0.trimmingCharacters(in: .whitespaces) }), !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme == "https" || url.scheme == "http", url.host != nil else { return nil }
        return url
    }

    /// https, on huggingface.co or hf.co or a host below them.
    public static let huggingFaceCDN: @Sendable (URL) -> Bool = { url in
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return CDN_DOMAINS.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: - Origins

    struct Origin: Equatable, Sendable {
        let scheme: String
        let host: String
        let port: Int

        init(_ url: URL) {
            scheme = url.scheme?.lowercased() ?? ""
            host = url.host?.lowercased() ?? ""
            port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 0)
        }
    }

    /// Whether `url` is the hub itself: the token may go there.
    func isHub(_ url: URL) -> Bool {
        let o = Origin(url)
        return o == Origin(endpoint) || Self.HUB_ORIGINS.contains(o)
    }

    private var hubHost: String { endpoint.host ?? endpoint.absoluteString }

    // MARK: - Fetching a snapshot

    struct Listing {
        let commit: String
        let files: [String]
    }

    struct Pending {
        let name: String
        let etag: String
        let size: Int64?
        /// Where the bytes are: for an LFS file a presigned CDN URL that expires (about an hour), so it is asked for
        /// again right before the file downloads and whenever the CDN refuses it.
        var location: URL
    }

    /// The network failed (after its tries): `error` says so.
    struct Unreachable: Error {
        let error: HubError
    }

    /// Downloads the files of `repo` at `revision` that match `patterns` (fnmatch, as huggingface_hub filters) into the
    /// cache and returns the snapshot's folder. Files already there are not fetched again. When the hub can't be reached
    /// or refuses the listing, a snapshot already complete on disk (`HFCache.isComplete`) is returned as it is.
    /// `progress(done, total)`: bytes.
    /// Cancelling the task stops the transfer; its partial file stays and is resumed by the next fetch.
    @discardableResult
    public func fetch(repo: String, revision: String, patterns: [String], token: String?,
                      progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
        try Self.checkRepo(repo)
        #if DEBUG
        if TestIsolation.isTestProcess && !["127.0.0.1", "localhost", "::1"].contains(endpoint.host ?? "") {
            throw HubError("no real model download in a test (\(hubHost))")
        }
        #endif
        let token = token.flatMap { $0.isEmpty ? nil : $0 }
        let listing: Listing
        do {
            listing = try await list(repo: repo, revision: revision, token: token)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Offline, or the hub refuses (huggingface_hub then uses the cache too): a complete snapshot is enough.
            let commit = cache.commit(repo: repo, revision: revision)
            if cache.isComplete(repo: repo, revision: commit, patterns: patterns) {
                return cache.snapshotDir(repo: repo, revision: commit)
            }
            throw (error as? Unreachable)?.error ?? error
        }
        let wanted = listing.files.filter { name in patterns.contains { FNMatch.matches(name, $0) } }
        guard !wanted.isEmpty else { throw HubError("\(repo) has none of the files a model needs") }
        for name in wanted where !Self.isSafe(name) {
            throw HubError("\(repo) lists a file Palaver does not write: \(name.debugDescription)")
        }

        // What is not linked yet, with its ETag and size (for the disk check; where its bytes are is asked again later).
        var pending: [Pending] = []
        var done: Int64 = 0, total: Int64 = 0
        for name in wanted {
            let pointer = cache.pointer(repo: repo, revision: listing.commit, file: name)
            if let st = HFCache.statOf(pointer.path) {
                done += Int64(st.st_size)
                total += Int64(st.st_size)
                continue
            }
            let p = try await head(repo: repo, commit: listing.commit, file: name, token: token)
            pending.append(p)
            total += p.size ?? 0
        }
        guard !pending.isEmpty else {
            try cache.writeRef(repo: repo, revision: revision, commit: listing.commit)
            return cache.snapshotDir(repo: repo, revision: listing.commit)
        }
        try checkDisk(repo: repo, pending)
        try HFCache.makeDirs(cache.blobsDir(repo).path)
        cache.tag()
        try cache.writeRef(repo: repo, revision: revision, commit: listing.commit)
        progress?(done, total)

        let all = total
        for p in pending {
            let before = done
            try await locked(cache.lockFile(repo, etag: p.etag)) {
                if HFCache.statOf(cache.blob(repo, etag: p.etag).path) == nil {
                    // A fresh HEAD: the CDN URL from the HEADs above may have expired while earlier files downloaded.
                    let relocate = { [self] in try await head(repo: repo, commit: listing.commit, file: p.name, token: token).location }
                    var now = p
                    now.location = try await relocate()
                    try await download(repo: repo, now, token: token, relocate: relocate) { progress?(before + $0, all) }
                }
                try cache.link(repo: repo, revision: listing.commit, file: p.name, etag: p.etag)
            }
            done += HFCache.statOf(cache.blob(repo, etag: p.etag).path).map { Int64($0.st_size) } ?? 0
            progress?(done, total)
        }
        return cache.snapshotDir(repo: repo, revision: listing.commit)
    }

    /// `repo` at its pin (HubModels: the revision and the files), from synchronous code (a download thread).
    @discardableResult
    public func fetchPinned(_ repo: String, token: String?) throws -> URL {
        let pin = HubModels.pin(repo)
        return try runBlocking { try await self.fetch(repo: repo, revision: pin.revision, patterns: pin.patterns, token: token) }
    }

    /// `org/name`, letters, digits, ".", "_", "-" (huggingface_hub's `validate_repo_id`: no "--" or "..").
    static func checkRepo(_ repo: String) throws {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        let ok = parts.count == 2 && parts.allSatisfy { p in
            !p.isEmpty && p.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
                && !p.hasPrefix("-") && !p.hasPrefix(".")
        } && !repo.contains("--") && !repo.contains("..")
        if !ok { throw HubError("\(repo.debugDescription) is not a Hugging Face model name") }
    }

    /// A relative path inside the snapshot: no "..", no empty or "." part, no leading "/", no backslash or NUL.
    static func isSafe(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { $0 != "" && $0 != "." && $0 != ".." }
    }

    // MARK: - The listing and the files' metadata

    /// `GET /api/models/<repo>/revision/<rev>`: the commit and every file of it.
    func list(repo: String, revision: String, token: String?) async throws -> Listing {
        let url = URL(string: endpoint.absoluteString + "/api/models/\(repo)/revision/\(Self.quote(revision, safe: ""))")!
        let (data, response, _) = try await request(url, method: "GET", token: token)
        let what = "\(repo) at revision \(revision.prefix(12))"
        guard response.statusCode == 200 else { throw statusError(response.statusCode, what) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = json["sha"] as? String, Self.isCommit(sha),
              let siblings = json["siblings"] as? [[String: Any]] else {
            throw HubError("\(hubHost) answered with something that is not a model's file list (\(what))")
        }
        return Listing(commit: sha, files: siblings.compactMap { $0["rfilename"] as? String })
    }

    static func isCommit(_ s: String) -> Bool {
        s.utf8.count == 40 && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// `HEAD resolve/<commit>/<file>` (huggingface_hub's `get_hf_file_metadata`): the ETag (X-Linked-Etag first), the
    /// size (X-Linked-Size, or Content-Length when not redirected) and where the bytes are (a redirect's Location).
    func head(repo: String, commit: String, file name: String, token: String?) async throws -> Pending {
        let url = URL(string: endpoint.absoluteString + "/\(repo)/resolve/\(commit)/\(Self.quote(name, safe: "/"))")!
        let (_, response, final) = try await request(url, method: "HEAD", token: token)
        let status = response.statusCode
        let what = "\(name) of \(repo)"
        guard (200..<400).contains(status) else { throw statusError(status, what) }
        let redirected = (300..<400).contains(status)
        guard let etag = Self.normalizeETag(response.value(forHTTPHeaderField: "X-Linked-Etag")
                                            ?? response.value(forHTTPHeaderField: "ETag")), Self.isSafeETag(etag) else {
            throw HubError("\(hubHost) gave no usable ETag for \(what)")
        }
        let size = (response.value(forHTTPHeaderField: "X-Linked-Size")
                    ?? (redirected ? nil : response.value(forHTTPHeaderField: "Content-Length"))).flatMap { Int64($0) }
        var location = final
        if redirected {
            guard let target = response.value(forHTTPHeaderField: "Location").flatMap({ URL(string: $0, relativeTo: final)?.absoluteURL })
            else { throw HubError("\(hubHost) redirected \(what) without saying where") }
            location = target
        }
        return Pending(name: name, etag: etag, size: size, location: location)
    }

    /// `W/"abc"` → `abc` (`_normalize_etag`).
    static func normalizeETag(_ etag: String?) -> String? {
        guard var e = etag else { return nil }
        if e.hasPrefix("W/") { e.removeFirst(2) }
        e = e.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return e.isEmpty ? nil : e
    }

    /// An ETag that is safe as a file name in blobs/.
    static func isSafeETag(_ e: String) -> Bool {
        !e.hasPrefix(".") && e.utf8.count <= 128
            && e.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// A 64-hex ETag is the file's sha256 (an LFS file's); a 40-hex one a git oid.
    static func isSHA256(_ e: String) -> Bool {
        e.utf8.count == 64 && e.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// One request to the hub (the token only there), redirects within the same origin followed (a renamed repo), any
    /// other redirect answered as it is. 429, 5xx and network errors are tried again; the network failing every time
    /// throws `Unreachable`.
    func request(_ start: URL, method: String, token: String?) async throws -> (Data, HTTPURLResponse, URL) {
        var url = start
        var hops = 0
        while true {
            var request = URLRequest(url: url, timeoutInterval: idleTimeout)
            request.httpMethod = method
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            if let token, isHub(url) { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            var answer: (Data, HTTPURLResponse)?
            var problem = ""
            for attempt in 0..<Self.ATTEMPTS {
                if attempt > 0 { await sleep(Self.backoff(attempt - 1)) }
                try Task.checkCancellation()
                do {
                    let got = try await transport(request)
                    if Self.RETRY_STATUS.contains(got.1.statusCode) && attempt + 1 < Self.ATTEMPTS {
                        problem = "HTTP \(got.1.statusCode)"
                        continue
                    }
                    answer = got
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch let e as URLError where e.code == .cancelled {
                    throw CancellationError()
                } catch {
                    problem = Self.networkProblem(error)
                }
            }
            guard let (data, response) = answer else {
                throw Unreachable(error: HubError("could not reach \(url.host ?? hubHost): \(problem)"))
            }
            if (300..<400).contains(response.statusCode), hops < 5,
               let target = response.value(forHTTPHeaderField: "Location").flatMap({ URL(string: $0, relativeTo: url)?.absoluteURL }),
               Origin(target) == Origin(url) {
                url = target
                hops += 1
                continue
            }
            return (data, response, url)
        }
    }

    static let userAgent = "palaver/\(Exchange.palaverVersion)"

    static func backoff(_ i: Int) -> Double { BACKOFF_SECONDS[min(i, BACKOFF_SECONDS.count - 1)] }

    static func networkProblem(_ error: Error) -> String {
        let text = (error as NSError).localizedDescription
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    func statusError(_ status: Int, _ what: String) -> HubError {
        switch status {
        case 401, 403:
            return HubError("Hugging Face refused \(what) (HTTP \(status)): it may be gated or private and need a Hugging Face token")
        case 404:
            return HubError("Hugging Face has no \(what) (HTTP 404)")
        default:
            return HubError("Hugging Face answered HTTP \(status) for \(what)")
        }
    }

    /// Percent-encodes all but letters, digits, "_.-~" and `safe` (urllib's `quote`).
    static func quote(_ s: String, safe: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-~")
        allowed.insert(charactersIn: safe)
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - Disk

    /// The bytes still to come must fit on the cache's volume (a partial file counts as what it has).
    func checkDisk(repo: String, _ pending: [Pending]) throws {
        var needed: Int64 = 0
        for p in pending {
            let have = HFCache.statOf(cache.incomplete(repo, etag: p.etag).path).map { Int64($0.st_size) } ?? 0
            needed += max(0, (p.size ?? 0) - have)
        }
        guard needed > 0, let free = freeBytes(cache.root), needed > free else { return }
        throw HubError("not enough free disk space for \(repo): it needs \(Self.gb(needed)) more, \(Self.gb(free)) are free")
    }

    /// GiB with one decimal, as the page counts them ("8.3 GB").
    static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0) }

    // MARK: - The lock

    /// `body` with the blob's lock file flock'd (huggingface_hub's filelock takes the same lock), waiting for another
    /// download of the same blob to end first.
    func locked<T>(_ file: URL, _ body: () async throws -> T) async throws -> T {
        try HFCache.makeDirs(file.deletingLastPathComponent().path)
        let fd = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw HubError("could not lock the model's download: \(String(cString: strerror(errno)))") }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw HubError("could not lock the model's download: \(String(cString: strerror(errno)))")
            }
            try await Task.sleep(nanoseconds: 200_000_000)  // throws when cancelled
        }
        return try await body()
    }

    // MARK: - One file

    /// The bytes and the sha256 of a blob's partial file so far.
    final class Part: @unchecked Sendable {
        var length: Int64
        var hasher: SHA256?
        let check: Bool

        init(path: String, check: Bool) throws {
            self.check = check
            length = 0
            hasher = check ? SHA256() : nil
            guard let st = HFCache.statOf(path) else { return }
            length = Int64(st.st_size)
            guard check else { return }
            // What an earlier download left: hashed in pieces, never read whole.
            let fd = open(path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw HubError("could not read \(path): \(String(cString: strerror(errno)))") }
            defer { close(fd) }
            var buffer = [UInt8](repeating: 0, count: 1 << 22)
            var seen: Int64 = 0
            while true {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                buffer.withUnsafeBytes { hasher!.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(n))) }
                seen += Int64(n)
            }
            length = seen
        }

        func add(_ bytes: UnsafeRawBufferPointer) {
            hasher?.update(bufferPointer: bytes)
            length += Int64(bytes.count)
        }

        func reset() {
            length = 0
            hasher = check ? SHA256() : nil
        }

        var sha256: String? { hasher.map { $0.finalize().map { String(format: "%02x", $0) }.joined() } }
    }

    /// A transfer cut short (the connection, a timeout, a 5xx): tried again, resumed.
    struct Cut: Error {
        let error: HubError
    }

    /// The CDN refused its presigned URL (401/403/410): it expired; a new one is asked for.
    struct Expired: Error {
        let host: String
        let status: Int
    }

    /// Downloads one blob to `<etag>.incomplete`, resuming what is there, checks it and renames it into place.
    /// `relocate()` asks the hub again where the bytes are (a fresh presigned URL): done when the CDN refuses the one in
    /// hand (401/403/410, it expired), once per point the download stands at.
    func download(repo: String, _ start: Pending, token: String?, relocate: () async throws -> URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        var p = start
        let partPath = cache.incomplete(repo, etag: p.etag).path
        let part = try Part(path: partPath, check: Self.isSHA256(p.etag))
        var attempt = 0
        var relocatedAt: Int64?
        while true {
            try Task.checkCancellation()
            do {
                try await transfer(repo: repo, p, to: partPath, part: part, token: token, progress: progress)
                break
            } catch let cut as Cut {
                attempt += 1
                if attempt >= Self.ATTEMPTS { throw cut.error }
                await sleep(Self.backoff(attempt - 1))
            } catch let expired as Expired {
                if relocatedAt == part.length {
                    throw HubError("\(expired.host) refused the download of \(p.name) (HTTP \(expired.status)), also with a new "
                                   + "link from Hugging Face; try again later")
                }
                relocatedAt = part.length
                p.location = try await relocate()
            }
        }
        if let want = p.size, part.length != want {
            unlink(partPath)
            throw HubError("\(p.name) arrived with \(part.length) bytes instead of \(want); it was deleted, try again")
        }
        if let got = part.sha256, got != p.etag {
            unlink(partPath)
            throw HubError("\(p.name) arrived damaged (its checksum does not match); it was deleted, try again")
        }
        guard rename(partPath, cache.blob(repo, etag: p.etag).path) == 0 else {
            throw HubError("could not finish \(p.name): \(String(cString: strerror(errno)))")
        }
    }

    /// One GET of the blob's bytes from where they are, from `part.length` on.
    func transfer(repo: String, _ p: Pending, to partPath: String, part: Part, token: String?,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        if let size = p.size {
            if part.length == size { return }  // all there: only the checks are left
            if part.length > size {
                truncate(partPath, 0)
                part.reset()
            }
        }
        guard let first = nextRequest(to: p.location, token: token, from: part.length) else {
            throw redirectRefused(p.name, p.location)
        }
        let fd = open(partPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw HubError("could not write \(p.name): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        if part.length == 0 { ftruncate(fd, 0) }
        let offset = part.length
        let t = Transfer(fd: fd, part: part, offset: offset, progress: progress) { [self] next in
            next.url.flatMap { nextRequest(to: $0, token: token, from: offset) }
        }
        var thrown: Error?
        do {
            try await t.run(first, idleTimeout: idleTimeout)
        } catch {
            thrown = error
        }
        if Task.isCancelled { throw CancellationError() }
        if let target = t.refused { throw redirectRefused(p.name, target) }
        if let failure = t.failure { throw failure }
        let host = p.location.host ?? hubHost
        if t.restart {  // the server sent another part than asked for: from the start
            truncate(partPath, 0)
            part.reset()
            throw Cut(error: HubError("\(host) sent the wrong part of \(p.name)"))
        }
        switch t.status {
        case 0, 200, 206:
            break
        case 416 where offset > 0:
            truncate(partPath, 0)
            part.reset()
            throw Cut(error: HubError("\(host) would not resume \(p.name)"))
        case let s where Self.RETRY_STATUS.contains(s):
            throw Cut(error: HubError("Hugging Face answered HTTP \(s) for \(p.name) of \(repo)"))
        case let s where [401, 403, 410].contains(s) && !isHub(p.location):
            throw Expired(host: host, status: s)
        case let s:
            throw statusError(s, "\(p.name) of \(repo)")
        }
        if let thrown {
            throw Cut(error: HubError("the download of \(p.name) from \(host) broke off: \(Self.networkProblem(thrown))"))
        }
        if let size = p.size, part.length < size {
            throw Cut(error: HubError("the download of \(p.name) from \(host) broke off at \(part.length) of \(size) bytes"))
        }
    }

    /// The request for `url`: the token only if it is the hub; a CDN host gets none; any other host is refused (nil).
    func nextRequest(to url: URL, token: String?, from offset: Int64) -> URLRequest? {
        let hub = isHub(url)
        guard hub || isTrustedCDN(url) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: idleTimeout)
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if offset > 0 { r.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        if hub, let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    func redirectRefused(_ name: String, _ target: URL) -> HubError {
        HubError("Hugging Face sent the download of \(name) to \(target.host ?? "an unknown host"), which is not one of its "
                 + "servers; nothing was downloaded from there")
    }
}

/// One GET streamed into a file: each piece written as it arrives (never the whole file in memory) and hashed; redirects
/// go through `redirect` (nil: refused, the 3xx ends the transfer).
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let fd: Int32
    let part: HubDownloader.Part
    let offset: Int64
    let progress: @Sendable (Int64) -> Void
    let redirect: (URLRequest) -> URLRequest?
    // Touched on the session's serial queue only, read after the transfer ended.
    var status = 0
    var refused: URL?
    var restart = false
    var failure: HubError?
    private var continuation: CheckedContinuation<Void, Error>?

    init(fd: Int32, part: HubDownloader.Part, offset: Int64, progress: @escaping @Sendable (Int64) -> Void,
         redirect: @escaping (URLRequest) -> URLRequest?) {
        self.fd = fd
        self.part = part
        self.offset = offset
        self.progress = progress
        self.redirect = redirect
    }

    func run(_ request: URLRequest, idleTimeout: Double) async throws {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = idleTimeout
        c.timeoutIntervalForResource = 7 * 24 * 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: c, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                queue.addOperation {
                    self.continuation = c
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let next = redirect(request) {
            completionHandler(next)
        } else {
            refused = request.url
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        status = http.statusCode
        switch status {
        case 206:
            // "bytes <first>-<last>/<size>": it must go on where the file ends.
            let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            let first = range.split(separator: " ").last?.split(separator: "-").first.flatMap { Int64($0) }
            if first != part.length {
                restart = true
                completionHandler(.cancel)
                return
            }
        case 200:
            if part.length > 0 {  // the Range was ignored: from the start
                ftruncate(fd, 0)
                part.reset()
            }
        default:
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        data.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + done, raw.count - done)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 {
                    failure = HubError("could not write the download: \(String(cString: strerror(errno)))")
                    break
                }
                done += n
            }
            part.add(UnsafeRawBufferPointer(rebasing: raw.prefix(done)))
        }
        if failure != nil {
            dataTask.cancel()
            return
        }
        progress(part.length)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = continuation
        continuation = nil
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }
}
