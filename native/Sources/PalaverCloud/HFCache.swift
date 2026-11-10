// The Hugging Face cache, laid out exactly as huggingface_hub lays it out, so a model downloaded by either side is
// found by the other (palaver/onboarding.py `_hub_cache`, `_cache_dir`, `cached_bytes`, `snapshot_complete`;
// huggingface_hub's file_download.py):
//
//   <hub>/models--<org>--<name>/blobs/<etag>                    one file per content: sha256 (LFS) or git oid
//   <hub>/models--<org>--<name>/blobs/<etag>.incomplete         a download under way (resumed from its length)
//   <hub>/models--<org>--<name>/snapshots/<commit>/<file>       a relative symlink into ../../blobs/<etag>
//   <hub>/models--<org>--<name>/refs/<branch>                   the commit a branch named (never for a commit)
//   <hub>/.locks/models--<org>--<name>/<etag>.lock              flock'd while a blob downloads (filelock's way)
//
// `<hub>` is `$HF_HUB_CACHE`, else `$HF_HOME/hub`, else `~/.cache/huggingface/hub` (StorePaths.hubCache).
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

public struct HFCache: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// The cache `stores` names (its `hubCache`: `HF_HUB_CACHE` / `HF_HOME` / the home's).
    public init(stores: StorePaths) { root = stores.hubCache }

    /// `models--<org>--<name>`.
    public static func folderName(_ repo: String) -> String { "models--" + repo.replacingOccurrences(of: "/", with: "--") }

    public func repoDir(_ repo: String) -> URL { root.appendingPathComponent(Self.folderName(repo), isDirectory: true) }

    public func blobsDir(_ repo: String) -> URL { repoDir(repo).appendingPathComponent("blobs", isDirectory: true) }

    public func blob(_ repo: String, etag: String) -> URL { blobsDir(repo).appendingPathComponent(etag) }

    /// The partial download of a blob (resumed from its length).
    public func incomplete(_ repo: String, etag: String) -> URL { blobsDir(repo).appendingPathComponent(etag + ".incomplete") }

    public func snapshotDir(repo: String, revision: String) -> URL {
        repoDir(repo).appendingPathComponent("snapshots", isDirectory: true).appendingPathComponent(revision, isDirectory: true)
    }

    /// Where the file `name` ("a/b.json") of a snapshot is linked.
    public func pointer(repo: String, revision: String, file name: String) -> URL {
        snapshotDir(repo: repo, revision: revision).appendingPathComponent(name)
    }

    public func lockFile(_ repo: String, etag: String) -> URL {
        root.appendingPathComponent(".locks", isDirectory: true).appendingPathComponent(Self.folderName(repo), isDirectory: true)
            .appendingPathComponent(etag + ".lock")
    }

    /// What of `repo` is here, partial downloads included: the regular files of `blobs` (`cached_bytes`). 0 when the
    /// folder can't be read.
    public func bytes(repo: String) -> Int64 {
        let dir = blobsDir(repo).path
        guard let names = Self.listdir(dir) else { return 0 }
        var total: Int64 = 0
        for name in names {
            guard let st = Self.statOf(dir + "/" + name), st.st_mode & S_IFMT == S_IFREG else { continue }
            total += Int64(st.st_size)
        }
        return total
    }

    /// Whether the snapshot of `repo` at `revision` has what a model needs, read from disk only (offline;
    /// `snapshot_complete`): config.json, no link whose blob is gone, every weights shard its index names (or one
    /// `model*.safetensors` without an index), and, when `patterns` is a list of exact names (e5's, no wildcard), each of
    /// them; an allow list with wildcards (mlx_lm's) names files a repo may not have. A download cut short leaves a
    /// snapshot without them: a file is linked into it only once it is complete.
    public func isComplete(repo: String, revision: String, patterns: [String]) -> Bool {
        let snap = snapshotDir(repo: repo, revision: revision).path
        guard Self.isFile(snap + "/config.json") else { return false }
        var broken = false
        Self.walk(snap) { path, l in
            if l.st_mode & S_IFMT == S_IFLNK && Self.statOf(path) == nil { broken = true }
        }
        if broken { return false }
        guard Self.weightsHere(snap) else { return false }
        if patterns.contains(where: FNMatch.hasWildcard) { return true }
        return patterns.allSatisfy { Self.isFile(snap + "/" + $0) }
    }

    /// Whether the weights a model loads are in the snapshot folder `snap`: `ModelCatalog.weightsHere`, the one rule
    /// setup, the downloader and palaver-lm share.
    public static func weightsHere(_ snap: String) -> Bool { ModelCatalog.weightsHere(snap) }

    /// The commit `revision` names: what `refs/<revision>` holds (a branch downloaded before), else `revision` itself.
    public func commit(repo: String, revision: String) -> String {
        let ref = repoDir(repo).appendingPathComponent("refs", isDirectory: true).appendingPathComponent(revision)
        guard let data = FileManager.default.contents(atPath: ref.path) else { return revision }
        let commit = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return HubDownloader.isCommit(commit) ? commit : revision
    }

    // MARK: - Writing (HubDownloader)

    /// Links `file` of the snapshot to the blob `etag` with a relative symlink, as huggingface_hub's `_create_symlink`
    /// does (`../../blobs/<etag>` for a file at the snapshot's top); a link already there is replaced atomically (a new
    /// link renamed over it), so a reader never finds the file missing.
    func link(repo: String, revision: String, file name: String, etag: String) throws {
        let pointer = self.pointer(repo: repo, revision: revision, file: name)
        try Self.makeDirs(pointer.deletingLastPathComponent().path)
        let depth = name.split(separator: "/").count + 1  // up from the file's folder to the repo's
        let target = String(repeating: "../", count: depth) + "blobs/" + etag
        let tmp = pointer.path + ".\(UUID().uuidString.prefix(8).lowercased()).tmp"
        guard symlink(target, tmp) == 0, rename(tmp, pointer.path) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(tmp)
            throw HubError("could not link \(name) into the model's folder: \(why)")
        }
    }

    /// `refs/<revision>` = `commit`, written atomically, when `revision` is a branch or tag (not the commit itself).
    func writeRef(repo: String, revision: String, commit: String) throws {
        guard revision != commit else { return }
        let ref = repoDir(repo).appendingPathComponent("refs", isDirectory: true).appendingPathComponent(revision)
        if let data = FileManager.default.contents(atPath: ref.path), String(decoding: data, as: UTF8.self) == commit { return }
        try Self.makeDirs(ref.deletingLastPathComponent().path)
        let tmp = ref.path + ".\(UUID().uuidString.prefix(8).lowercased()).tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: Data(commit.utf8)), rename(tmp, ref.path) == 0 else {
            unlink(tmp)
            throw HubError("could not write the model's revision: \(String(cString: strerror(errno)))")
        }
    }

    static let CACHEDIR_TAG = "Signature: 8a477f597d28d172789f06886806bc55\n"
        + "# This file is a cache directory tag created by huggingface_hub.\n"
        + "# For information about cache directory tags, see:\n"
        + "#\thttps://bford.info/cachedir/\n"

    /// `CACHEDIR.TAG` in the cache (backup tools skip it), as huggingface_hub writes it; best effort.
    func tag() {
        let tag = root.appendingPathComponent("CACHEDIR.TAG").path
        if Self.statOf(tag) == nil { _ = FileManager.default.createFile(atPath: tag, contents: Data(Self.CACHEDIR_TAG.utf8)) }
    }

    // MARK: - Darwin helpers (names from the hub are written as they are, never normalized by Foundation)

    static func statOf(_ path: String) -> Darwin.stat? {
        var st = Darwin.stat()
        return stat(path, &st) == 0 ? st : nil
    }

    static func isFile(_ path: String) -> Bool { statOf(path).map { $0.st_mode & S_IFMT == S_IFREG } ?? false }

    static func listdir(_ dir: String) -> [String]? {
        guard let d = opendir(dir) else { return nil }
        defer { closedir(d) }
        var out: [String] = []
        while let e = readdir(d) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(e.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { out.append(name) }
        }
        return out
    }

    /// Every entry below `dir` with its lstat; linked folders are not entered.
    static func walk(_ dir: String, _ visit: (String, Darwin.stat) -> Void) {
        for name in listdir(dir) ?? [] {
            let path = dir + "/" + name
            var l = Darwin.stat()
            guard lstat(path, &l) == 0 else { continue }
            visit(path, l)
            if l.st_mode & S_IFMT == S_IFDIR { walk(path, visit) }
        }
    }

    /// `mkdir -p` with Darwin's mkdir.
    static func makeDirs(_ path: String) throws {
        if statOf(path).map({ $0.st_mode & S_IFMT == S_IFDIR }) == true { return }
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty && parent != path { try makeDirs(parent) }
        if mkdir(path, 0o755) != 0 && errno != EEXIST {
            throw HubError("could not create \(path): \(String(cString: strerror(errno)))")
        }
    }

    /// The free bytes of the volume `url` is on (its nearest existing folder): what macOS would make room for
    /// (`volumeAvailableCapacityForImportantUsage`, purgeable space included), else statvfs; nil when it can't be told.
    public static func freeBytes(_ url: URL) -> Int64? {
        var path = url.path
        while statOf(path) == nil {
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { return nil }
            path = parent
        }
        let values = try? URL(fileURLWithPath: path, isDirectory: true)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        var st = statvfs()
        guard statvfs(path, &st) == 0 else { return nil }
        return Int64(st.f_bavail) * Int64(st.f_frsize)
    }
}

/// Python's `fnmatch.fnmatchcase`, as huggingface_hub's `filter_repo_objects` uses it: `*` matches anything, "/"
/// included; `?` one character; `[abc]`, `[a-z]`, `[!abc]` a set; a `[` without its `]` is itself. A pattern ending in
/// "/" matches everything below that folder; backslashes count as "/".
public enum FNMatch {
    private enum Token {
        case char(Unicode.Scalar)
        case any
        case star
        case set(negated: Bool, ranges: [ClosedRange<Unicode.Scalar>])
    }

    public static func hasWildcard(_ pattern: String) -> Bool {
        pattern.unicodeScalars.contains { $0 == "*" || $0 == "?" || $0 == "[" }
    }

    public static func matches(_ name: String, _ pattern: String) -> Bool {
        var p = pattern.replacingOccurrences(of: "\\", with: "/")
        if p.hasSuffix("/") { p += "*" }
        let tokens = tokenize(Array(p.unicodeScalars))
        let s = Array(name.replacingOccurrences(of: "\\", with: "/").unicodeScalars)
        var ti = 0, si = 0
        var star: Int? = nil, starS = 0
        while si < s.count {
            if ti < tokens.count, case .star = tokens[ti] {
                star = ti
                starS = si
                ti += 1
                continue
            }
            if ti < tokens.count, one(tokens[ti], s[si]) {
                ti += 1
                si += 1
                continue
            }
            guard let at = star else { return false }
            ti = at + 1
            starS += 1
            si = starS
        }
        while ti < tokens.count, case .star = tokens[ti] { ti += 1 }
        return ti == tokens.count
    }

    private static func one(_ t: Token, _ c: Unicode.Scalar) -> Bool {
        switch t {
        case .char(let x): return x == c
        case .any: return true
        case .star: return false
        case .set(let negated, let ranges): return ranges.contains { $0.contains(c) } != negated
        }
    }

    private static func tokenize(_ p: [Unicode.Scalar]) -> [Token] {
        var out: [Token] = []
        var i = 0
        while i < p.count {
            let c = p[i]
            i += 1
            switch c {
            case "*":
                if case .star? = out.last { continue }
                out.append(.star)
            case "?":
                out.append(.any)
            case "[":
                var j = i
                if j < p.count && p[j] == "!" { j += 1 }
                if j < p.count && p[j] == "]" { j += 1 }
                while j < p.count && p[j] != "]" { j += 1 }
                guard j < p.count else {
                    out.append(.char("["))
                    continue
                }
                var k = i
                var negated = false
                if p[k] == "!" {
                    negated = true
                    k += 1
                }
                var ranges: [ClosedRange<Unicode.Scalar>] = []
                while k < j {  // a "]" first in the set is itself
                    let lo = p[k]
                    if k + 2 < j && p[k + 1] == "-" {
                        if lo <= p[k + 2] { ranges.append(lo...p[k + 2]) }
                        k += 3
                    } else {
                        ranges.append(lo...lo)
                        k += 1
                    }
                }
                out.append(.set(negated: negated, ranges: ranges))
                i = j + 1
            default:
                out.append(.char(c))
            }
        }
        return out
    }
}
