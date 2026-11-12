// Model downloads (HubDownloader, HFCache) against a stub hub on this Mac: a tiny repo whose small files the hub serves
// itself and whose LFS file its "CDN" (a second server, another origin) serves after a redirect, as Hugging Face does.
// Nothing here reaches the network.
import CryptoKit
import Darwin
import Foundation
import PalaverCore
import PalaverDomain
@testable import PalaverCloud
import Testing

private let TOKEN = "hf_StubTokenAbcdefghijklmnop"
private let COMMIT = "0123456789abcdef0123456789abcdef01234567"
private let REPO = "contoso/tiny-model"

private func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

/// git's blob id, the ETag of a small file.
private func gitOID(_ d: Data) -> String {
    var h = Insecure.SHA1()
    h.update(data: Data("blob \(d.count)\0".utf8))
    h.update(data: d)
    return h.finalize().map { String(format: "%02x", $0) }.joined()
}

/// The stub hub: `/api/models/<repo>/revision/<rev>`, `HEAD|GET /<repo>/resolve/<commit>/<file>`; the LFS file answers
/// HEAD with a 302 to the CDN (X-Linked-Etag = its sha256, X-Linked-Size), which serves it with Range support.
final class StubHub: @unchecked Sendable {
    var files: [(String, Data)] = [
        ("config.json", Data(#"{"model_type": "tiny"}"#.utf8)),
        ("tokenizer.json", Data(#"{"vocab": ["a", "b"]}"#.utf8)),
        ("sub/extra.json", Data(#"{"nested": true}"#.utf8)),
        ("README.md", Data("# not needed".utf8)),
        ("model.safetensors", Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })),
    ]
    var lfs: Set<String> = ["model.safetensors"]
    let lock = NSLock()
    /// The next GETs of a file send only this many bytes each (then close): a connection cut short.
    var cuts: [String: [Int]] = [:]
    /// A GET of this file sends `stallAt` bytes, then waits for `stall` (a download to cancel).
    var stallFile: String?
    var stallAt = 0
    let stall = DispatchSemaphore(value: 0)
    /// Files whose content differs from the sha256 the hub announces.
    var damaged: Set<String> = []
    /// Answers to the listing (401, 404 …) instead of the list.
    var listingStatus = 200
    /// Each HEAD of an LFS file signs its CDN URL anew (`sig=<n>`); with `strictSignatures` the CDN takes only the
    /// newest one (the older ones expired, 403).
    var signatures: [String: Int] = [:]
    var strictSignatures = false
    /// The CDN refuses these GETs of a file (403, by their number from 0) whatever their signature: a link that
    /// expires mid-download.
    var refuseGETs: [String: Set<Int>] = [:]
    private var cdnGETs: [String: Int] = [:]

    private(set) var hub: StubServer!
    private(set) var cdn: StubServer!

    init() throws {
        cdn = try StubServer { [unowned self] got in self.answerCDN(got) }
        hub = try StubServer { [unowned self] got in self.answerHub(got) }
    }

    deinit {
        stall.signal()
        hub.stop()
        cdn.stop()
    }

    var endpoint: URL { URL(string: hub.url)! }

    func content(_ name: String) -> Data { lock.withLock { files.first { $0.0 == name }!.1 } }

    func etag(_ name: String) -> String {
        let d = content(name)
        return lfs.contains(name) ? sha256(damaged.contains(name) ? d + Data([0]) : d) : gitOID(d)
    }

    private func answerHub(_ got: Got) -> StubServer.Answer {
        let path = got.path.removingPercentEncoding ?? got.path
        if path.hasPrefix("/api/models/\(REPO)/revision/") {
            let rev = String(path.dropFirst("/api/models/\(REPO)/revision/".count))
            guard listingStatus == 200 else { return .json(.object([("error", .string("no"))]), status: listingStatus) }
            guard rev == COMMIT || rev == "main" else { return .json(.object([("error", .string("Revision not found"))]), status: 404) }
            let siblings = lock.withLock { files.map { JSONValue.object([("rfilename", .string($0.0))]) } }
            return .json(.object([("id", .string(REPO)), ("sha", .string(COMMIT)), ("siblings", .array(siblings))]))
        }
        let prefix = "/\(REPO)/resolve/\(COMMIT)/"
        guard path.hasPrefix(prefix) else { return StubServer.Answer(status: 404) }
        let name = String(path.dropFirst(prefix.count))
        guard lock.withLock({ files.contains { $0.0 == name } }) else {
            return StubServer.Answer(status: 404, headers: [("X-Repo-Commit", COMMIT)])
        }
        let d = content(name)
        if lfs.contains(name) {
            let sig: Int = lock.withLock {
                signatures[name, default: 0] += 1
                return signatures[name]!
            }
            return StubServer.Answer(status: 302, headers: [
                ("Location", cdn.url + "/blobs/\(name)?X-Signature=secret-signature&sig=\(sig)"), ("X-Repo-Commit", COMMIT),
                ("X-Linked-Etag", "\"\(etag(name))\""), ("X-Linked-Size", "\(d.count)"), ("ETag", "W/\"abc\""),
            ])
        }
        return ranged(got, name, d, headers: [("ETag", "\"\(etag(name))\""), ("X-Repo-Commit", COMMIT)])
    }

    private func answerCDN(_ got: Got) -> StubServer.Answer {
        let path = String((got.path.split(separator: "?").first ?? ""))
        guard path.hasPrefix("/blobs/") else { return StubServer.Answer(status: 404) }
        let name = String(path.dropFirst("/blobs/".count))
        let refused: Bool = lock.withLock {
            let n = cdnGETs[name, default: 0]
            cdnGETs[name] = n + 1
            return refuseGETs[name]?.contains(n) == true || (strictSignatures && !got.path.hasSuffix("&sig=\(signatures[name] ?? 0)"))
        }
        if refused { return StubServer.Answer(status: 403, body: Data("<Error>AccessDenied: Request has expired</Error>".utf8)) }
        return ranged(got, name, content(name), headers: [])
    }

    /// The bytes from the Range's start on (206), all of them (200), cut or stalled as the test set.
    private func ranged(_ got: Got, _ name: String, _ d: Data, headers: [(String, String)]) -> StubServer.Answer {
        var a = StubServer.Answer(status: 200, headers: headers, body: d)
        if got.method == "GET", let range = got.headers["range"], range.hasPrefix("bytes="),
           let start = Int(range.dropFirst(6).split(separator: "-").first ?? "") {
            guard start < d.count else { return StubServer.Answer(status: 416) }
            a = StubServer.Answer(status: 206, headers: headers + [("Content-Range", "bytes \(start)-\(d.count - 1)/\(d.count)")],
                                  body: d.subdata(in: start..<d.count))
        }
        guard got.method == "GET" else { return a }
        lock.withLock {
            if var c = cuts[name], !c.isEmpty {
                a.sendOnly = c.removeFirst()
                cuts[name] = c
            } else if stallFile == name {
                stallFile = nil
                a.sendOnly = stallAt
                a.stall = stall
            }
        }
        return a
    }

    /// The downloader for this hub (the CDN server trusted in place of Hugging Face's), into `cache`.
    func downloader(_ cache: HFCache, trustCDN: Bool = true, free: Int64? = nil) -> HubDownloader {
        let cdnPort = cdn.port
        return HubDownloader(cache: cache, endpoint: endpoint, isTrustedCDN: { trustCDN && $0.port == cdnPort },
                             sleep: { _ in }, freeBytes: { _ in free ?? 1 << 40 }, idleTimeout: 5)
    }

    func hubRequests(_ method: String? = nil) -> [Got] { hub.requests.filter { method == nil || $0.method == method } }
    var cdnRequests: [Got] { cdn.requests }
}

private let PATTERNS = ["*.json", "model*.safetensors", "tokenizer.model"]

private func cache() -> HFCache { HFCache(root: tempFolder("hub").appendingPathComponent("hub", isDirectory: true)) }

private func readlink(_ url: URL) -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) }

private func files(_ dir: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? [] }

@Suite(.serialized) struct HubDownloaderTests {
    @Test func aSnapshotIsLaidOutAsHuggingFaceHubLaysItOut() async throws {
        let stub = try StubHub()
        let c = cache()
        let snap = try await stub.downloader(c).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil)
        #expect(snap.path == c.repoDir(REPO).path + "/snapshots/\(COMMIT)")
        #expect(c.repoDir(REPO).lastPathComponent == "models--contoso--tiny-model")
        // One blob per content, named by its ETag; nothing partial left.
        let wanted = ["config.json", "tokenizer.json", "sub/extra.json", "model.safetensors"]
        #expect(files(c.blobsDir(REPO)) == wanted.map { stub.etag($0) }.sorted())
        for name in wanted {
            #expect(try Data(contentsOf: c.blob(REPO, etag: stub.etag(name))) == stub.content(name))
            #expect(try Data(contentsOf: snap.appendingPathComponent(name)) == stub.content(name))
        }
        // Relative links, as _create_symlink makes them.
        #expect(readlink(snap.appendingPathComponent("config.json")) == "../../blobs/\(stub.etag("config.json"))")
        #expect(readlink(snap.appendingPathComponent("sub/extra.json")) == "../../../blobs/\(stub.etag("sub/extra.json"))")
        #expect(readlink(snap.appendingPathComponent("model.safetensors")) == "../../blobs/\(stub.etag("model.safetensors"))")
        // The allow patterns: README.md is never asked for. A commit revision writes no ref.
        #expect(!stub.hub.requests.contains { $0.path.contains("README") } && !files(snap).contains("README.md"))
        #expect(!FileManager.default.fileExists(atPath: c.repoDir(REPO).appendingPathComponent("refs").path))
        #expect(FileManager.default.fileExists(atPath: c.root.appendingPathComponent("CACHEDIR.TAG").path))
        #expect(FileManager.default.fileExists(atPath: c.lockFile(REPO, etag: stub.etag("model.safetensors")).path))
        // Complete for the cache's readers: this one, and the scan the app has used (huggingface_hub's rules).
        #expect(c.isComplete(repo: REPO, revision: COMMIT, patterns: PATTERNS))
        #expect(ModelCatalog.complete(REPO, stores: StorePaths(configDir: c.root, home: c.root, hubCache: c.root)))
        #expect(c.bytes(repo: REPO) == Int64(wanted.map { stub.content($0).count }.reduce(0, +)))
        // Again: nothing is fetched, only listed.
        let before = stub.hub.requests.count
        try await stub.downloader(c).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil)
        #expect(stub.hub.requests.count == before + 1 && stub.cdnRequests.count == 1)
    }

    @Test func aBranchRevisionIsWrittenToRefs() async throws {
        let stub = try StubHub()
        let c = cache()
        let snap = try await stub.downloader(c).fetch(repo: REPO, revision: "main", patterns: ["config.json"], token: nil)
        #expect(snap.lastPathComponent == COMMIT)
        #expect(try String(contentsOf: c.repoDir(REPO).appendingPathComponent("refs/main"), encoding: .utf8) == COMMIT)
        #expect(files(snap) == ["config.json"])
        #expect(c.commit(repo: REPO, revision: "main") == COMMIT && c.commit(repo: REPO, revision: "v2") == "v2")
    }

    @Test func theTokenGoesToTheHubOnlyNeverToTheCDN() async throws {
        let stub = try StubHub()
        let c = cache()
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var done: [Int64] = []
            var totals: Set<Int64> = []
        }
        let seen = Seen()
        try await stub.downloader(c).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: TOKEN) { done, total in
            seen.lock.withLock {
                seen.done.append(done)
                seen.totals.insert(total)
            }
        }
        let reported = seen.done
        #expect(seen.totals == [c.bytes(repo: REPO)])
        #expect(!stub.hubRequests().isEmpty && stub.hubRequests().allSatisfy { $0.headers["authorization"] == "Bearer \(TOKEN)" })
        #expect(stub.cdnRequests.count == 1 && stub.cdnRequests[0].headers["authorization"] == nil)
        #expect(stub.hubRequests("HEAD").allSatisfy { $0.headers["accept-encoding"] == "identity" })
        #expect(reported.last == c.bytes(repo: REPO) && reported == reported.sorted())
        // No token: no Authorization anywhere.
        let stub2 = try StubHub()
        try await stub2.downloader(cache()).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil)
        #expect((stub2.hubRequests() + stub2.cdnRequests).allSatisfy { $0.headers["authorization"] == nil })
    }

    @Test func aRedirectToAHostThatIsNotHuggingFacesIsRefused() async throws {
        let stub = try StubHub()
        let c = cache()
        let error = await thrown { try await stub.downloader(c, trustCDN: false).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: TOKEN) }
        #expect("\(error!)" == "Hugging Face sent the download of model.safetensors to 127.0.0.1, which is not one of its "
                + "servers; nothing was downloaded from there")
        #expect(stub.cdnRequests.isEmpty)
        #expect(!"\(error!)".contains("signature") && !"\(error!)".contains(TOKEN))
        #expect(!c.isComplete(repo: REPO, revision: COMMIT, patterns: PATTERNS))
        // Only Hugging Face's own hosts over https count as its CDN.
        for (url, ok) in [("https://cdn-lfs.huggingface.co/x", true), ("https://cas-bridge.xethub.hf.co/x", true),
                          ("https://hf.co/x", true), ("http://cdn-lfs.huggingface.co/x", false),
                          ("https://evilhuggingface.co/x", false), ("https://huggingface.co.example.com/x", false),
                          ("https://s3.amazonaws.com/x", false)] {
            #expect(HubDownloader.huggingFaceCDN(URL(string: url)!) == ok, "\(url)")
        }
    }

    @Test func aCutConnectionIsResumedWithARange() async throws {
        let stub = try StubHub()
        stub.cuts["model.safetensors"] = [100_000, 50_000]
        let c = cache()
        let snap = try await stub.downloader(c).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil)
        #expect(try Data(contentsOf: snap.appendingPathComponent("model.safetensors")) == stub.content("model.safetensors"))
        // Each try goes on where the file ends (URLSession may drop the last piece before a cut, so not always exactly
        // at 100 000 and 150 000; on a very busy Mac nothing of a cut answer arrives, and a try starts at 0 again): no
        // Range first, then growing ones. aPartLeftByAnEarlierRunIsResumed checks a Range without the timing.
        let ranges = stub.cdnRequests.map { $0.headers["range"] }
        let starts = ranges.dropFirst().compactMap { $0.flatMap { Int($0.dropFirst(6).dropLast()) } }
        #expect(ranges.count == 3 && ranges[0] == nil, "\(ranges)")
        #expect(starts == starts.sorted() && starts.allSatisfy { $0 > 0 && $0 <= 150_000 }, "\(ranges)")
        #expect(!files(c.blobsDir(REPO)).contains { $0.hasSuffix(".incomplete") })
    }

    @Test func aPartLeftByAnEarlierRunIsResumed() async throws {
        // The server was quit mid-download: its .incomplete is there, hashed and continued, not fetched again.
        let stub = try StubHub()
        let c = cache()
        let etag = stub.etag("model.safetensors")
        try FileManager.default.createDirectory(at: c.blobsDir(REPO), withIntermediateDirectories: true)
        try stub.content("model.safetensors").prefix(123_456).write(to: c.incomplete(REPO, etag: etag))
        #expect(c.bytes(repo: REPO) == 123_456)  // the page's progress counts it
        #expect(!ModelCatalog.complete(REPO, stores: StorePaths(configDir: c.root, home: c.root, hubCache: c.root)))
        try await stub.downloader(c).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil)
        #expect(stub.cdnRequests.map { $0.headers["range"] } == ["bytes=123456-"])
        #expect(try Data(contentsOf: c.blob(REPO, etag: etag)) == stub.content("model.safetensors"))
    }

    @Test func eachFileIsLocatedAgainRightBeforeItDownloads() async throws {
        // The CDN URLs of the up-front HEADs (for the disk check) may expire while earlier files download: each file
        // asks for a new one when its turn comes, and only the newest is used.
        let stub = try StubHub()
        stub.files.append(("model-00002-of-00002.safetensors", Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })))
        stub.lfs.insert("model-00002-of-00002.safetensors")
        stub.strictSignatures = true
        let c = cache()
        try await stub.downloader(c).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil)
        #expect(stub.cdnRequests.count == 2 && stub.cdnRequests.allSatisfy { $0.path.hasSuffix("&sig=2") })
        for name in ["model.safetensors", "model-00002-of-00002.safetensors"] {
            #expect(try Data(contentsOf: c.blob(REPO, etag: stub.etag(name))) == stub.content(name))
        }
    }

    @Test func aLinkThatExpiresMidDownloadIsAskedForAgain() async throws {
        // Cut; the resume then finds the link expired (403): a new HEAD, and the download goes on from where it was.
        let stub = try StubHub()
        stub.cuts["model.safetensors"] = [100_000]
        stub.refuseGETs["model.safetensors"] = [1]
        let c = cache()
        try await stub.downloader(c).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: TOKEN)
        let gets = stub.cdnRequests
        #expect(gets.count == 3, "\(gets.map(\.path))")
        #expect(gets[0].path.hasSuffix("&sig=2") && gets[1].path.hasSuffix("&sig=2") && gets[2].path.hasSuffix("&sig=3"))
        // The resume after the new link asks for what the refused one asked for (no Range when the cut came before
        // the first byte, as it may on a busy Mac).
        #expect(gets[2].headers["range"] == gets[1].headers["range"])
        #expect(gets.allSatisfy { $0.headers["authorization"] == nil })
        #expect(try Data(contentsOf: c.blob(REPO, etag: stub.etag("model.safetensors"))) == stub.content("model.safetensors"))
        // A CDN that keeps refusing: one new link, then one line that does not blame a gated repo.
        let stub2 = try StubHub()
        stub2.refuseGETs["model.safetensors"] = Set(0..<99)
        let error = await thrown { try await stub2.downloader(cache()).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil) }
        #expect("\(error!)" == "127.0.0.1 refused the download of model.safetensors (HTTP 403), also with a new link from "
                + "Hugging Face; try again later")
        #expect(stub2.cdnRequests.count == 2)
        #expect(stub2.hubRequests("HEAD").filter { $0.path.hasSuffix("/model.safetensors") }.count == 3)
    }

    @Test func aDamagedFileIsRefusedAndNotKept() async throws {
        let stub = try StubHub()
        stub.damaged = ["model.safetensors"]
        let c = cache()
        let error = await thrown { try await stub.downloader(c).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil) }
        #expect("\(error!)" == "model.safetensors arrived damaged (its checksum does not match); it was deleted, try again")
        let etag = stub.etag("model.safetensors")
        #expect(!FileManager.default.fileExists(atPath: c.blob(REPO, etag: etag).path))
        #expect(!FileManager.default.fileExists(atPath: c.incomplete(REPO, etag: etag).path))
        #expect(readlink(c.pointer(repo: REPO, revision: COMMIT, file: "model.safetensors")) == nil)
        #expect(!c.isComplete(repo: REPO, revision: COMMIT, patterns: PATTERNS))
    }

    @Test func cancellingStopsTheTransferAndKeepsItsPart() async throws {
        let stub = try StubHub()
        stub.stallFile = "model.safetensors"
        stub.stallAt = 70_000
        let c = cache()
        let etag = stub.etag("model.safetensors")
        let part = c.incomplete(REPO, etag: etag)
        let hub = stub.downloader(c)
        let task = Task { try await hub.fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil) }
        let deadline = Date().addingTimeInterval(10)
        while (HFCache.statOf(part.path)?.st_size ?? 0) < 70_000 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        task.cancel()
        let error = await thrown { try await task.value }
        #expect(error is CancellationError)
        #expect(HFCache.statOf(part.path)?.st_size == 70_000)
        stub.stall.signal()
        // The next fetch goes on from there.
        try await stub.downloader(c).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil)
        #expect(stub.cdnRequests.last?.headers["range"] == "bytes=70000-")
        #expect(try Data(contentsOf: c.blob(REPO, etag: etag)) == stub.content("model.safetensors"))
    }

    @Test func notEnoughDiskStopsBeforeAnythingIsDownloaded() async throws {
        let stub = try StubHub()
        let c = cache()
        let error = await thrown { try await stub.downloader(c, free: 1000).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil) }
        #expect("\(error!)".hasPrefix("not enough free disk space for \(REPO): it needs "))
        #expect(stub.cdnRequests.isEmpty && stub.hubRequests("GET").count == 1)  // the listing only
        #expect(HubDownloader.gb(8_912_000_000) == "8.3 GB")
    }

    @Test func withoutTheHubACompleteSnapshotIsUsedAsItIs() async throws {
        let stub = try StubHub()
        let c = cache()
        let snap = try await stub.downloader(c).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil)
        stub.hub.stop()
        #expect(try await stub.downloader(c).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil) == snap)
        // Nothing here yet: the error says the hub can't be reached, in one line.
        let error = await thrown { try await stub.downloader(cache()).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil) }
        #expect("\(error!)".hasPrefix("could not reach 127.0.0.1: ") && !"\(error!)".contains("\n"))
    }

    @Test func theHubsRefusalsAreOneLineWithoutTheToken() async throws {
        let stub = try StubHub()
        stub.listingStatus = 401
        let e401 = await thrown { try await stub.downloader(cache()).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: TOKEN) }
        #expect("\(e401!)" == "Hugging Face refused \(REPO) at revision 0123456789ab (HTTP 401): it may be gated or private "
                + "and need a Hugging Face token")
        stub.listingStatus = 200
        let e404 = await thrown { try await stub.downloader(cache()).fetch(repo: REPO, revision: "nope", patterns: PATTERNS, token: TOKEN) }
        #expect("\(e404!)" == "Hugging Face has no \(REPO) at revision nope (HTTP 404)")
        let none = await thrown { try await stub.downloader(cache()).fetch(repo: REPO, revision: COMMIT, patterns: ["*.gguf"], token: nil) }
        #expect("\(none!)" == "\(REPO) has none of the files a model needs")
        let bad = await thrown { try await stub.downloader(cache()).fetch(repo: "../etc", revision: COMMIT, patterns: PATTERNS, token: nil) }
        #expect("\(bad!)" == "\"../etc\" is not a Hugging Face model name")
        // A refusal with the model complete on disk (a token gone, a repo gated later): the copy here is used.
        let c = cache()
        let snap = try await stub.downloader(c).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil)
        stub.listingStatus = 403
        #expect(try await stub.downloader(c).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil) == snap)
    }

    @Test func aFileNameThatWouldLeaveTheSnapshotIsRefused() async throws {
        let stub = try StubHub()
        stub.files.append(("../../escape.json", Data("{}".utf8)))
        let c = cache()
        let error = await thrown { try await stub.downloader(c).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil) }
        #expect("\(error!)".hasPrefix("\(REPO) lists a file Palaver does not write"))
        #expect(!FileManager.default.fileExists(atPath: c.repoDir(REPO).appendingPathComponent("escape.json").path))
        for (name, ok) in [("a/b.json", true), ("/etc/x", false), ("a/../b", false), ("a//b", false), ("./a", false), ("a\\b", false)] {
            #expect(HubDownloader.isSafe(name) == ok, "\(name)")
        }
    }

    @Test func twoFetchesAtOnceDownloadEachBlobOnce() async throws {
        let stub = try StubHub()
        stub.stallFile = "model.safetensors"  // the first transfer waits until the second fetch waits for its lock
        stub.stallAt = 0
        let c = cache()
        let one = Task { try await stub.downloader(c).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil) }
        let deadline = Date().addingTimeInterval(10)
        while stub.cdnRequests.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let two = Task { try await stub.downloader(c).fetch(repo: REPO, revision: COMMIT, patterns: PATTERNS, token: nil) }
        try await Task.sleep(nanoseconds: 300_000_000)
        stub.stall.signal()  // the cut transfer resumes; the second fetch then finds the blob there
        _ = try await (one.value, two.value)
        #expect(stub.cdnRequests.count == 2 && stub.cdnRequests[1].headers["range"] == nil)  // stalled at 0: from the start
        #expect(try Data(contentsOf: c.blob(REPO, etag: stub.etag("model.safetensors"))) == stub.content("model.safetensors"))
    }
}

@Suite struct HFCacheTests {
    /// A snapshot written by hand, as huggingface_hub leaves one.
    private func snapshot(_ c: HFCache, _ repo: String, _ files: [String: String], linked: Bool = true) throws -> URL {
        let snap = c.snapshotDir(repo: repo, revision: COMMIT)
        try FileManager.default.createDirectory(at: c.blobsDir(repo), withIntermediateDirectories: true)
        for (name, text) in files {
            let etag = sha256(Data(text.utf8))
            try Data(text.utf8).write(to: c.blob(repo, etag: etag))
            try c.link(repo: repo, revision: COMMIT, file: name, etag: etag)
        }
        return snap
    }

    @Test func anIncompleteSnapshotIsNotComplete() throws {
        let c = cache()
        let index = #"{"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors"}}"#
        let snap = try snapshot(c, REPO, ["config.json": "{}", "model.safetensors.index.json": index,
                                          "model-00001-of-00002.safetensors": "one"])
        #expect(!c.isComplete(repo: REPO, revision: COMMIT, patterns: HubModels.MLX_FILES))  // a shard is missing
        _ = try snapshot(c, REPO, ["model-00002-of-00002.safetensors": "two"])
        #expect(c.isComplete(repo: REPO, revision: COMMIT, patterns: HubModels.MLX_FILES))
        // A link whose blob is gone.
        try FileManager.default.removeItem(at: c.blob(REPO, etag: sha256(Data("two".utf8))))
        #expect(!c.isComplete(repo: REPO, revision: COMMIT, patterns: HubModels.MLX_FILES))
        // No config.json.
        let e5 = try snapshot(c, E5Encoder.model, ["model.safetensors": "w", "sentencepiece.bpe.model": "s"])
        #expect(!c.isComplete(repo: E5Encoder.model, revision: COMMIT, patterns: E5Encoder.modelFiles))
        _ = try snapshot(c, E5Encoder.model, ["config.json": "{}"])
        #expect(c.isComplete(repo: E5Encoder.model, revision: COMMIT, patterns: E5Encoder.modelFiles))
        // A file the patterns name is missing.
        try FileManager.default.removeItem(at: e5.appendingPathComponent("sentencepiece.bpe.model"))
        #expect(!c.isComplete(repo: E5Encoder.model, revision: COMMIT, patterns: E5Encoder.modelFiles))
        #expect(!c.isComplete(repo: "contoso/none", revision: COMMIT, patterns: E5Encoder.modelFiles))
        _ = snap
    }

    @Test func anIndexNamingAFileNeverDownloadedIsCompleteWhenTheModelsShardsAreHere() throws {
        // rc6's Gemma: its index also names optiq_vision.safetensors, which MLX_FILES leaves out.
        let c = cache()
        let index = #"{"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors", "v": "optiq_vision.safetensors"}}"#
        _ = try snapshot(c, REPO, ["config.json": "{}", "model.safetensors.index.json": index,
                                   "model-00001-of-00002.safetensors": "one"])
        #expect(!c.isComplete(repo: REPO, revision: COMMIT, patterns: HubModels.MLX_FILES))  // a shard of the model is missing
        _ = try snapshot(c, REPO, ["model-00002-of-00002.safetensors": "two"])
        #expect(c.isComplete(repo: REPO, revision: COMMIT, patterns: HubModels.MLX_FILES))
    }

    @Test func aLinkIsReplacedInOneStep() throws {
        let c = cache()
        let snap = try snapshot(c, REPO, ["config.json": "{}"])
        try c.link(repo: REPO, revision: COMMIT, file: "config.json", etag: "abc")  // over the old link: renamed, not unlinked
        #expect(readlink(snap.appendingPathComponent("config.json")) == "../../blobs/abc")
        #expect(files(snap) == ["config.json"])  // no temporary link left
        #expect(HFCache.freeBytes(c.root.appendingPathComponent("not/there/yet")).map { $0 > 0 } == true)
    }

    @Test func theCacheIsWhereHuggingFaceHubLooks() {
        let home = URL(fileURLWithPath: "/Users/timo", isDirectory: true)
        func root(_ env: [String: String]) -> String {
            var e = env
            e["PALAVER_HOME"] = home.path
            e["XDG_CONFIG_HOME"] = "/tmp/xdg"
            return HFCache(stores: StorePaths.current(env: e)).root.path
        }
        #expect(root([:]) == "/Users/timo/.cache/huggingface/hub")
        #expect(root(["HF_HOME": "/Volumes/X/hf"]) == "/Volumes/X/hf/hub")
        #expect(root(["HF_HOME": "/Volumes/X/hf", "HF_HUB_CACHE": "/Volumes/Y/hub"]) == "/Volumes/Y/hub")
        #expect(HFCache.folderName("mlx-community/gemma-4-12B-it-OptiQ-4bit") == "models--mlx-community--gemma-4-12B-it-OptiQ-4bit")
        #expect(HubDownloader.endpoint(env: ["HF_ENDPOINT": "http://127.0.0.1:9/"])?.absoluteString == "http://127.0.0.1:9")
        #expect(HubDownloader.endpoint(env: [:]) == nil)
        // The e2e tests' stub CDN is trusted only when named (debug builds), and then only that origin.
        let dir = tempFolder("hubenv")
        let stores = StorePaths(configDir: dir.appendingPathComponent("config"), home: dir.appendingPathComponent("home"))
        let plain = HubDownloader(stores: stores, env: ["HF_ENDPOINT": "http://127.0.0.1:9"])
        let stubbed = HubDownloader(stores: stores, env: ["HF_ENDPOINT": "http://127.0.0.1:9", "PALAVER_TEST_HF_CDN": "http://127.0.0.1:7"])
        #expect(plain.endpoint.absoluteString == "http://127.0.0.1:9" && plain.cache.root.path == stores.hubCache.path)
        #expect(!plain.isTrustedCDN(URL(string: "http://127.0.0.1:7/x")!) && plain.isTrustedCDN(URL(string: "https://cdn-lfs.hf.co/x")!))
        #expect(stubbed.isTrustedCDN(URL(string: "http://127.0.0.1:7/x")!) && !stubbed.isTrustedCDN(URL(string: "https://cdn-lfs.hf.co/x")!))
    }

    @Test func patternsMatchAsFnmatchcase() {
        let cases: [(String, String, Bool)] = [
            ("config.json", "*.json", true), ("sub/extra.json", "*.json", true), ("README.md", "*.json", false),
            ("model-00001-of-00002.safetensors", "model*.safetensors", true), ("vision.safetensors", "model*.safetensors", false),
            ("tokenizer.model", "tokenizer.model", true), ("Tokenizer.model", "tokenizer.model", false),
            ("a.txt", "?.txt", true), ("ab.txt", "?.txt", false), ("abc", "[!x]bc", true), ("xbc", "[!x]bc", false),
            ("b1", "[a-c][0-9]", true), ("d1", "[a-c][0-9]", false), ("[x", "[x", true), ("]a", "[]]a", true),
            ("onnx/model.onnx", "onnx/", true), ("onnx", "onnx/", false), ("a/b", "a\\b", true),
        ]
        for (name, pattern, want) in cases { #expect(FNMatch.matches(name, pattern) == want, "\(name) ~ \(pattern)") }
    }
}

@Suite struct HubModelsTests {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// The pins the releases before 0.6 shipped (their notes.py MODEL_REVISIONS and MODEL_FILES, embeddings.py's
    /// e5 model): a model they downloaded is found in the cache, not fetched again.
    @Test func thePinsAreTheOnesTheAppHasShipped() throws {
        let revisions = [("mlx-community/gemma-4-12B-it-OptiQ-4bit", "de9e183868050b34bf6b4272518500ffcebf15b3"),
                         ("mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit", "e9675aa3ca5f900ccef55267914466d55ab325fa")]
        for (repo, rev) in revisions {
            #expect(HubModels.pin(repo) == HubModels.Pin(repo: repo, revision: rev, patterns: HubModels.MLX_FILES))
        }
        #expect(HubModels.MLX_FILES == ["*.json", "model*.safetensors", "*.py", "tokenizer.model", "*.tiktoken", "tiktoken.model",
                                        "*.txt", "*.jsonl", "*.jinja"])
        let e5 = HubModels.pin("intfloat/multilingual-e5-small")
        #expect(e5.revision == "614241f622f53c4eeff9890bdc4f31cfecc418b3")
        #expect(e5.patterns == ["config.json", "sentencepiece.bpe.model", "model.safetensors"])
        #expect(HubModels.pins.count == revisions.count + 1)
        #expect(HubModels.pin(ModelCatalog.GEMMA).revision == "de9e183868050b34bf6b4272518500ffcebf15b3")
        #expect(HubModels.pin("contoso/other") == HubModels.Pin(repo: "contoso/other", revision: "main", patterns: HubModels.MLX_FILES))
    }

    @Test func theTokenComesFromSettingsThenFromHuggingFaceLogin() throws {
        let h = Home()
        let toml = h.dir.appendingPathComponent("config.toml")
        let keys = CountingKeyStore()
        let home = h.dir.appendingPathComponent("home", isDirectory: true)
        #expect(Tokens.huggingFace(configToml: toml, env: [:], keys: keys, home: home) == nil)
        let saved = home.appendingPathComponent(".cache/huggingface/token")
        try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hf_FromLogin\n".utf8).write(to: saved)
        #expect(Tokens.huggingFace(configToml: toml, env: [:], keys: keys, home: home) == "hf_FromLogin")
        keys.values[Tokens.HF] = "hf_FromKeychain"
        #expect(Tokens.huggingFace(configToml: toml, env: [:], keys: keys, home: home) == "hf_FromKeychain")
        try Data("[hf]\ntoken = \"hf_FromToml\"\n".utf8).write(to: toml)
        #expect(Tokens.huggingFace(configToml: toml, env: [:], keys: keys, home: home) == "hf_FromToml")
        #expect(Tokens.huggingFace(configToml: toml, env: ["HF_TOKEN": "hf_FromEnv"], keys: keys, home: home) == "hf_FromEnv")
    }
}
