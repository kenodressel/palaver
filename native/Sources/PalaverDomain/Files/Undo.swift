// Undo for the Meetings window (undo.py:1-319): a snapshot taken before a change, and the way back.
//
// `take` copies what a change is about to touch (a meeting without its audio, or only its per-speaker files, or a
// store file or folder like the project list) into `.trash/.undo/<token>/`. The change tells `moved` and `created` what
// it moved or made, and `sealed` once it is done. `restore` puts everything back; what it replaces goes to `.trash`,
// nothing is deleted (only the audio of what an audio snapshot replaces: that is the undone change's own audio, made
// again by doing the change again). A restore is refused (`UndoChanged`) if a meeting, a store or a folder the change
// made changed again after the change (its files differ from what `sealed` saw; the same content written again, as a
// later change's undo does, is no change), or if a meeting the change left in place has gone to the trash since.
//
// A snapshot is a file format either server reads (`manifest.json` written as `json.dumps(indent=2)`, the
// fingerprints, the folder layout), so Swift restores the snapshots the Python server took and the other way round.
// One whose manifest Swift cannot read (missing, no JSON, another shape) is `UndoGone`: "can't undo this any more".
//
// Paths are handled as Python's `Path` spells them (`str(path)`: no "//", no "." parts, no trailing "/"); names are
// compared and sorted by code points, and read from the folder as they are stored (NFC and NFD stay apart).
//
// Locks (Python's restore takes none): a restore puts back a meeting's files under its `.speakers.lock`, and a store
// under that store's lock (`<store>.lock`; a meeting's speaker file under the meeting's, its own notes under
// `.my-notes.lock`), one at a time. Call it holding no store lock. `take` and `sealed` take none, as in Python.
import CryptoKit
import Darwin
import Foundation
import PalaverCore

/// No such snapshot (never taken, pruned, already used, or its manifest unreadable). Python's `undo.Gone(token)`.
public struct UndoGone: Error, CustomStringConvertible {
    public let token: String
    public init(_ token: String) { self.token = token }
    public var description: String { token }
}

/// A meeting, store or made folder changed after the change; restoring would lose that. `what` is the meeting id, the
/// store's path or the made folder's id (Python's `undo.Changed(what)`).
public struct UndoChanged: Error, CustomStringConvertible {
    public let what: String
    public init(_ what: String) { self.what = what }
    public var description: String { what }
}

public enum Undo {
    static let SPEAKER_FILES = "speakers*.json"
    /// Caches made from a meeting's files in the background (the search index), the locks my notes and the speaker
    /// files are written under, and the temporary files of a write in progress: never snapshot or compared.
    static let DERIVED = ["search-index.*", ".my-notes.lock", ".speakers.lock", "*.tmp"]
    /// A snapshot without a manifest this young (seconds) is still being taken.
    public static let UNFINISHED = 3600.0
    /// What `prune` keeps: the newest 20, none older than 24 hours.
    public static let KEEP = 20
    public static let MAX_AGE = 24.0 * 3600

    // MARK: - The snapshot and its manifest

    static func root(_ outputDir: URL) -> String { pyPath(outputDir.path) + "/" + Cutting.TRASH + "/.undo" }

    /// `_dir`: a token is 32 lowercase hex digits, else there is no such snapshot.
    static func dir(_ outputDir: URL, _ token: String) throws -> String {
        let hex = "0123456789abcdef".unicodeScalars
        guard token.unicodeScalars.count == 32, token.unicodeScalars.allSatisfy(hex.contains) else { throw UndoGone(token) }
        return root(outputDir) + "/" + token
    }

    /// `_load`: the snapshot's folder and its manifest; `UndoGone` when the manifest is missing, no JSON or no object.
    static func load(_ outputDir: URL, _ token: String) throws -> (String, PyDict<JSONValue>) {
        let snap = try dir(outputDir, token)
        guard let data = FileManager.default.contents(atPath: snap + "/manifest.json"),
              let value = try? PythonJSON.parse(data), let manifest = PyDict<JSONValue>(value) else { throw UndoGone(token) }
        return (snap, manifest)
    }

    /// `_save`: `json.dumps(manifest, indent=2)` into `manifest.json.tmp`, renamed over the manifest (a reader never
    /// sees half of it).
    static func save(_ snap: String, _ manifest: PyDict<JSONValue>) throws {
        try PythonJSON.write(manifest.json, to: URL(fileURLWithPath: snap + "/manifest.json"), indent: 2, ensureAscii: true,
                             via: "manifest.json.tmp")
    }

    /// Snapshot what a change is about to touch: `meetings` whole (without their audio unless `audio`), with
    /// `speakerFilesOfAll` the speaker files of every other meeting, and `stores` (files or folders). Returns the token.
    @discardableResult
    public static func take(_ outputDir: URL, _ label: String, meetings: [String] = [], audio: Bool = false,
                            speakerFilesOfAll: Bool = false, stores: [URL] = []) throws -> String {
        let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let out = pyPath(outputDir.path)
        let snap = try dir(outputDir, token)
        var entries = PyDict<JSONValue>()
        let skip: (String) -> Bool = { name in derived(name) || (!audio && matches(name, "*.wav")) }
        for id in meetings where isDir(out + "/" + id) {
            try copytree(out + "/" + id, snap + "/meetings/" + id, ignore: skip)
            entries[id] = .object([("partial", .bool(false)), ("audio", .bool(audio))])
        }
        if speakerFilesOfAll {
            for name in Py.stableSorted(try listdir(out), by: Py.less) {
                let folder = out + "/" + name
                guard entries[name] == nil, isDir(folder), RecordingPaths.isRecordingFolderName(name) else { continue }
                let copy = snap + "/meetings/" + name
                try makedirs(copy)
                for f in try speakerFiles(folder) { try copy2(folder + "/" + f, copy + "/" + f) }
                entries[name] = .object([("partial", .bool(true)), ("audio", .bool(false))])
            }
        }
        var saved: [JSONValue] = []
        for (i, url) in stores.enumerated() {
            let store = pyPath(url.path)
            saved.append(.object([("path", .string(store)), ("index", .int(i)), ("existed", .bool(exists(store))),
                                  ("dir", .bool(isDir(store)))]))
            let copy = snap + "/stores/\(i)"
            if isDir(store) {
                try copytree(store, copy + "/" + basename(store))
            } else if exists(store) {
                try makedirs(copy)
                try copy2(store, copy + "/" + basename(store))
            }
        }
        try fingerprints(out, &entries, token)
        try makedirs(snap)
        try save(snap, PyDict([("label", .string(label)), ("time", .string(Py.isoNow())), ("meetings", entries.json),
                               ("stores", .array(saved)), ("moves", .array([])), ("created", .array([]))]))
        return token
    }

    /// What the change knows about itself and its undo needs besides the files (e.g. the paragraphs a notes change
    /// took out).
    public static func note(_ outputDir: URL, _ token: String, _ extra: PyDict<JSONValue>) throws {
        var (snap, manifest) = try load(outputDir, token)
        manifest["extra"] = extra.json
        try save(snap, manifest)
    }

    /// What `note` kept (`{}` when nothing).
    public static func extra(_ outputDir: URL, _ token: String) throws -> PyDict<JSONValue> {
        let value = try load(outputDir, token).1["extra"] ?? .null
        if !value.truthy { return PyDict() }
        guard let extra = PyDict<JSONValue>(value) else { throw UndoGone(token) }
        return extra
    }

    /// What the change was ("trash", "my-notes clear", …): Python's `str()` of the manifest's label, "" without one.
    public static func label(_ outputDir: URL, _ token: String) throws -> String {
        try load(outputDir, token).1["label"].map(pyStr) ?? ""
    }

    /// The store files and folders the snapshot would put back.
    public static func stores(_ outputDir: URL, _ token: String) throws -> [URL] {
        try parse(load(outputDir, token).1, token).stores.map { URL(fileURLWithPath: $0.path) }
    }

    /// The change is done: what the meetings, the stores and the folders it made look like now is what `restore`
    /// expects to find.
    public static func sealed(_ outputDir: URL, _ token: String) throws {
        var (snap, manifest) = try load(outputDir, token)
        let out = pyPath(outputDir.path)
        guard let found = manifest["meetings"], var meetings = PyDict<JSONValue>(found) else { throw UndoGone(token) }
        try fingerprints(out, &meetings, token)
        manifest["meetings"] = meetings.json
        guard case .array(var stores)? = manifest["stores"] else { throw UndoGone(token) }
        for i in stores.indices {
            guard var store = PyDict<JSONValue>(stores[i]), case .string(let path)? = store["path"] else { throw UndoGone(token) }
            store["fingerprint"] = .string(try storeFingerprint(path))
            stores[i] = store.json
        }
        manifest["stores"] = .array(stores)
        var prints = PyDict<JSONValue>()
        for id in try strings(manifest["created"], token) { prints[id] = .string(try fingerprint(out + "/" + id, false)) }
        manifest["created_fingerprints"] = prints.json
        try save(snap, manifest)
    }

    /// The change moved `src` to `dst`; restore moves it back.
    public static func moved(_ outputDir: URL, _ token: String, src: URL, dst: URL) throws {
        var (snap, manifest) = try load(outputDir, token)
        guard case .array(var moves)? = manifest["moves"] else { throw UndoGone(token) }
        moves.append(.strings([pyPath(src.path), pyPath(dst.path)]))
        manifest["moves"] = .array(moves)
        try save(snap, manifest)
    }

    /// The change made these meeting folders; restore trashes them.
    public static func created(_ outputDir: URL, _ token: String, _ meetingIds: [String]) throws {
        var (snap, manifest) = try load(outputDir, token)
        guard case .array(let made)? = manifest["created"] else { throw UndoGone(token) }
        manifest["created"] = .array(made + meetingIds.map(JSONValue.string))
        try save(snap, manifest)
    }

    /// The meeting folders the change made.
    public static func createdIds(_ outputDir: URL, _ token: String) throws -> [String] {
        try strings(load(outputDir, token).1["created"], token)
    }

    // MARK: - Fingerprints

    /// `_fingerprint`: what a meeting folder (or, `partial`, just its per-speaker files) holds: every file's name and
    /// size, and the content of all but the audio (sha256 over `"<name>\0<size>\0"` and, for a file not named `.wav`,
    /// its content's digest, by relative path in code point order). Derived files are left out. A file rewritten with
    /// the same content keeps it; any real edit changes it. "" when there is no such folder.
    public static func fingerprint(_ folder: URL, partial: Bool) throws -> String { try fingerprint(pyPath(folder.path), partial) }

    /// `_store_fingerprint`: `"file:"` and the content's sha256, `"dir:"` and the folder's fingerprint, "" when missing.
    public static func storeFingerprint(_ store: URL) throws -> String { try storeFingerprint(pyPath(store.path)) }

    static func fingerprint(_ folder: String, _ partial: Bool) throws -> String {
        guard isDir(folder) else { return "" }
        var files: [(rel: String, path: String, size: Int64)] = []
        if partial {
            for name in try speakerFiles(folder) {
                if let st = statOf(folder + "/" + name), isRegular(st) { files.append((name, folder + "/" + name, Int64(st.st_size))) }
            }
        } else {
            walk(folder, "") { rel, path, name, l in
                guard !isDirectory(l), !derived(name), let st = statOf(path), isRegular(st) else { return }
                files.append((rel, path, Int64(st.st_size)))
            }
        }
        var digest = SHA256()
        for f in Py.stableSorted(files, by: { Py.less($0.rel, $1.rel) }) {
            digest.update(data: Data("\(f.rel)\u{0}\(f.size)\u{0}".utf8))
            if Py.strLower(suffix(basename(f.rel))) != ".wav" { digest.update(data: Data(try sha256(f.path))) }
        }
        return hex(digest.finalize())
    }

    static func storeFingerprint(_ path: String) throws -> String {
        if isDir(path) { return "dir:" + (try fingerprint(path, false)) }
        if let st = statOf(path), isRegular(st) { return "file:" + hex(try sha256(path)) }
        return ""
    }

    /// `_newest`: the latest change in a meeting folder (or its per-speaker files), for snapshots from before
    /// fingerprints.
    static func newest(_ folder: String, _ partial: Bool) -> Double {
        guard isDir(folder) else { return 0 }
        var items: [String] = []
        if partial {
            items = ((try? listdir(folder)) ?? []).filter { matches($0, SPEAKER_FILES) }.map { folder + "/" + $0 }
        } else {
            items = [folder]
            walk(folder, "") { _, path, name, _ in if !derived(name) { items.append(path) } }
        }
        return items.compactMap(statOf).map { Double($0.st_mtimespec.tv_sec) + Double($0.st_mtimespec.tv_nsec) * 1e-9 }.max() ?? 0
    }

    /// `_fingerprints`: each meeting entry's fingerprint now (an old snapshot's `mtime` dropped).
    private static func fingerprints(_ out: String, _ entries: inout PyDict<JSONValue>, _ token: String) throws {
        for id in entries.keys {
            guard var entry = PyDict<JSONValue>(entries[id]!), let partial = entry["partial"] else { throw UndoGone(token) }
            entry["mtime"] = nil
            entry["fingerprint"] = .string(try fingerprint(out + "/" + id, partial.truthy))
            entries[id] = entry.json
        }
    }

    // MARK: - Restore

    /// The manifest as `restore` reads it; any other shape is `UndoGone`.
    struct Manifest {
        struct Meeting {
            let id: String
            let partial: Bool
            let audio: Bool
            /// The fingerprint `sealed` saw; nil in a snapshot from before fingerprints, which has `mtime` instead.
            let fingerprint: JSONValue?
            let mtime: Double
        }
        struct Store {
            /// As the manifest has it (what `UndoChanged` names).
            let path: String
            let index: String
            let existed: Bool
            let dir: Bool
            let fingerprint: JSONValue?
        }
        var meetings: [Meeting] = []
        var stores: [Store] = []
        var moves: [(src: String, dst: String)] = []
        var created: [String] = []
        var createdPrints: [(String, JSONValue)] = []
    }

    static func parse(_ raw: PyDict<JSONValue>, _ token: String) throws -> Manifest {
        var m = Manifest()
        guard let meetings = raw["meetings"].flatMap(PyDict<JSONValue>.init), case .array(let stores)? = raw["stores"],
              case .array(let moves)? = raw["moves"] else { throw UndoGone(token) }
        for (id, value) in meetings {
            guard let entry = PyDict<JSONValue>(value), let partial = entry["partial"], let audio = entry["audio"] else {
                throw UndoGone(token)
            }
            var mtime = 0.0
            if entry["fingerprint"] == nil {
                switch entry["mtime"] {
                case .int(let i)?: mtime = Double(i)
                case .double(let d)?: mtime = d
                default: throw UndoGone(token)
                }
            }
            m.meetings.append(.init(id: id, partial: partial.truthy, audio: audio.truthy,
                                    fingerprint: entry["fingerprint"], mtime: mtime))
        }
        for value in stores {
            guard let store = PyDict<JSONValue>(value), case .string(let path)? = store["path"], let index = store["index"],
                  let existed = store["existed"], let dir = store["dir"] else { throw UndoGone(token) }
            m.stores.append(.init(path: path, index: pyStr(index), existed: existed.truthy, dir: dir.truthy,
                                  fingerprint: store["fingerprint"]))
        }
        for value in moves {
            guard case .array(let pair) = value, pair.count == 2, case .string(let src) = pair[0], case .string(let dst) = pair[1]
            else { throw UndoGone(token) }
            m.moves.append((src, dst))
        }
        m.created = try strings(raw["created"], token)
        if let prints = raw["created_fingerprints"] {
            guard let dict = PyDict<JSONValue>(prints) else { throw UndoGone(token) }
            m.createdPrints = dict.map { ($0.key, $0.value) }
        }
        return m
    }

    /// `_changed`: a meeting differs from what `sealed` saw.
    private static func changed(_ folder: String, _ entry: Manifest.Meeting) throws -> Bool {
        guard isDir(folder) else {
            // A whole meeting that was there when the change was done and is gone now went to the trash since: copying
            // it back would make a second, audio-less meeting. A partial one (speaker files) is skipped.
            return !entry.partial && (entry.fingerprint?.truthy ?? false)
        }
        guard let print = entry.fingerprint else { return newest(folder, entry.partial) > entry.mtime }
        return !same(print, try fingerprint(folder, entry.partial))
    }

    /// `_what_changed`: the first meeting, store or made folder that differs from what `sealed` saw, or nil.
    static func whatChanged(_ out: String, _ m: Manifest) throws -> String? {
        let movedBack = Set(m.moves.filter { exists($0.dst) && !exists($0.src) }.map { ScalarKey(pyPath($0.src)) })
        for entry in m.meetings {
            let folder = pyPath(out + "/" + entry.id)
            if movedBack.contains(ScalarKey(folder)) { continue }  // the change moved it away; restore moves it back first
            if try changed(folder, entry) { return entry.id }
        }
        for store in m.stores {
            if let print = store.fingerprint, !same(print, try storeFingerprint(pyPath(store.path))) { return store.path }
        }
        for (id, print) in m.createdPrints {
            let folder = out + "/" + id
            if isDir(folder), !same(print, try fingerprint(folder, false)) { return id }  // gone (trashed) is no loss
        }
        return nil
    }

    /// Put back what `take` copied; returns the meeting ids touched. `check: false` skips the refusal when something
    /// changed since (for rolling back a change that failed half-way).
    @discardableResult
    public static func restore(_ outputDir: URL, _ token: String, check: Bool = true) throws -> [String] {
        let (snap, raw) = try load(outputDir, token)
        let m = try parse(raw, token)
        let out = pyPath(outputDir.path)
        if check, let what = try whatChanged(out, m) { throw UndoChanged(what) }
        let bin = out + "/" + Cutting.TRASH
        if mkdir(bin, 0o777) != 0 && !(errno == EEXIST && isDir(bin)) { throw posixError(bin) }  // `mkdir(exist_ok=True)`
        let prefix = String(token.prefix(8))
        let aside = bin + "/undone-" + prefix  // what a restore replaces, for files that are not meeting folders
        var ids: [String] = []
        func touched(_ id: String) { if !ids.contains(where: { Py.same($0, id) }) { ids.append(id) } }
        for move in m.moves.reversed() where exists(move.dst) && !exists(move.src) {
            let src = pyPath(move.src)
            try shutilMove(move.dst, src)
            if Py.same(dirname(src), out) { touched(basename(src)) }
        }
        for id in m.created where isDir(out + "/" + id) {
            try Cutting.trash(RecordingPaths(URL(fileURLWithPath: out + "/" + id, isDirectory: true)))
        }
        for entry in m.meetings {
            let folder = pyPath(out + "/" + entry.id), saved = snap + "/meetings/" + entry.id
            if entry.partial {
                guard isDir(folder) else { continue }  // trashed since: nothing to put back there
                try meetingLocked(folder) {
                    for f in try speakerFiles(folder, all: true) {
                        try makedirs(aside + "/" + entry.id)
                        try shutilMove(folder + "/" + f, aside + "/" + entry.id + "/" + f)
                    }
                    for f in (try? speakerFiles(saved, all: true)) ?? [] { try copy2(saved + "/" + f, folder + "/" + f) }
                }
            } else {
                let putBack: () throws -> Void = {
                    var old: String?
                    if exists(folder) {
                        old = try shutilMove(folder, bin + "/" + entry.id + ".undone-" + prefix)
                    }
                    try copytree(saved, folder)
                    guard let old else { return }
                    if !entry.audio {  // the snapshot has no audio: keep the current (moved, not a second copy)
                        for wav in try listdir(old) where matches(wav, "*.wav") && !exists(folder + "/" + wav) {
                            try shutilMove(old + "/" + wav, folder + "/" + wav)
                        }
                    } else {  // the audio of the undone change (a cut): doing the change again makes it again
                        var wavs: [String] = []
                        walk(old, "") { _, path, name, l in if matches(name, "*.wav") && !isDirectory(l) { wavs.append(path) } }
                        for wav in wavs where Darwin.unlink(wav) != 0 { throw posixError(wav) }
                    }
                }
                if isDir(folder) { try meetingLocked(folder, putBack) } else { try putBack() }
            }
            touched(entry.id)
        }
        for store in m.stores {
            let path = pyPath(store.path), name = basename(path)
            let saved = snap + "/stores/" + store.index + "/" + name
            try storeLocked(path, out) {
                if exists(path) {
                    try makedirs(aside + "/stores/" + store.index)
                    try shutilMove(path, aside + "/stores/" + store.index + "/" + name)
                }
                if store.dir {
                    try copytree(saved, path)
                } else if store.existed {
                    try makedirs(dirname(path))  // e.g. an image of notes cleared since
                    try copy2(saved, path)
                }
            }
        }
        try FileManager.default.removeItem(atPath: snap)
        return ids
    }

    /// The meeting's own lock around putting back its files (`StoreLock.meeting`); only for a folder that is there, so
    /// the lock never makes one.
    private static func meetingLocked(_ folder: String, _ body: () throws -> Void) throws {
        try StoreLock.meeting(RecordingPaths(URL(fileURLWithPath: folder, isDirectory: true)), body)
    }

    /// The lock a store's writers take: a meeting's speaker file the meeting's lock, its own notes (`my-notes.json`,
    /// `my-notes/`) `.my-notes.lock`, any other file of a meeting none (nothing locks it); a store outside the meetings
    /// `<store>.lock` beside it (`voices.lock` beside `voices/`).
    private static func storeLocked(_ path: String, _ out: String, _ body: () throws -> Void) throws {
        let under = Array((out + "/").unicodeScalars), scalars = Array(path.unicodeScalars)
        if scalars.starts(with: under) {
            let rest = scalars[under.count...].split(separator: "/").map { String(String.UnicodeScalarView($0)) }
            if rest.count >= 2, RecordingPaths.isRecordingFolderName(rest[0]) {
                let folder = out + "/" + rest[0]
                guard isDir(folder) else { return try body() }
                if rest.count == 2, matches(rest[1], SPEAKER_FILES) { return try meetingLocked(folder, body) }
                if Py.same(rest[1], MyNotes.fileName) || Py.same(rest[1], MyNotes.imagesFolder) {
                    return try MyNotes.locked(URL(fileURLWithPath: folder, isDirectory: true), body)
                }
                return try body()
            }
        }
        try StoreLock.with(URL(fileURLWithPath: path), body)
    }

    // MARK: - Prune

    /// Drop snapshots older than `maxAge` seconds, and all but the newest `keep`. A snapshot without a readable
    /// manifest is left alone while it is younger than `UNFINISHED` (a take still copying), else dropped.
    public static func prune(_ outputDir: URL, keep: Int = KEEP, maxAge: Double = MAX_AGE, now: Date = Date()) {
        let root = root(outputDir)
        guard isDir(root), let names = try? listdir(root) else { return }
        let nowMicros = Int64((now.timeIntervalSince1970 * 1_000_000).rounded(.down))
        // Infinite or NaN is no trap: Python's `now - when > max_age` is never true for either, so all are kept.
        let maxMicros: Int64 = abs(maxAge) < 8.64e9 ? Int64((maxAge * 1_000_000).rounded()) : maxAge < 0 ? Int64.min : Int64.max
        var live: [(when: Int64, snap: String)] = []
        for name in names {
            let snap = root + "/" + name
            let when = manifestTime(snap)
            if when == nil {
                guard let st = statOf(snap) else { continue }  // gone meanwhile
                let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) * 1e-9
                if now.timeIntervalSince1970 - mtime < UNFINISHED { continue }  // a take still copying
            }
            if let when, nowMicros - when <= maxMicros { live.append((when, snap)) } else { removeTree(snap) }
        }
        let newestFirst = Py.stableSorted(live) { $0.when > $1.when }
        let start = keep >= 0 ? min(keep, newestFirst.count) : max(newestFirst.count + keep, 0)  // Python's `[keep:]`
        for item in newestFirst[start...] { removeTree(item.snap) }
    }

    /// The manifest's "time" in microseconds since the epoch; nil when it cannot be read or has no UTC offset.
    private static func manifestTime(_ snap: String) -> Int64? {
        guard let data = FileManager.default.contents(atPath: snap + "/manifest.json"),
              let value = try? PythonJSON.parse(data), case .string(let text)? = value["time"],
              let when = try? PyDateTime.parse(text), when.offset != nil else { return nil }
        return when.micros
    }

    /// `shutil.rmtree(ignore_errors=True)`: a real folder only (it refuses a symlink and fails on a file).
    private static func removeTree(_ path: String) {
        var st = stat()
        guard lstat(path, &st) == 0, isDirectory(st) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Files as Python's shutil and pathlib see them

    /// `str(Path(s))`: no empty or "." parts, no trailing "/" ("//" at the start stays, as POSIX allows).
    static func pyPath(_ s: String) -> String {
        let scalars = s.unicodeScalars
        let parts = scalars.split(separator: "/").map { String(String.UnicodeScalarView($0)) }.filter { $0 != "." }
        var root = ""
        if scalars.first == "/" { root = scalars.starts(with: "//".unicodeScalars) && !scalars.starts(with: "///".unicodeScalars) ? "//" : "/" }
        let joined = root + parts.joined(separator: "/")
        return joined.isEmpty ? "." : joined
    }

    static func basename(_ path: String) -> String {
        guard let i = path.unicodeScalars.lastIndex(of: "/") else { return path }
        return String(path.unicodeScalars[path.unicodeScalars.index(after: i)...])
    }

    static func dirname(_ path: String) -> String {
        guard let i = path.unicodeScalars.lastIndex(of: "/") else { return "." }
        let head = String(path.unicodeScalars[..<i])
        return head.isEmpty ? "/" : head
    }

    /// `PurePath.suffix`: from the last "." of the name, unless it is the first or the last character.
    static func suffix(_ name: String) -> String {
        let s = Array(name.unicodeScalars)
        guard let i = s.lastIndex(of: "."), i > 0, i < s.count - 1 else { return "" }
        return String(String.UnicodeScalarView(s[i...]))
    }

    /// `fnmatch` of a name on a pattern of literal characters and `*`, by code points (case-sensitive, as on POSIX).
    static func matches(_ name: String, _ pattern: String) -> Bool {
        let n = Array(name.unicodeScalars), p = Array(pattern.unicodeScalars)
        var i = 0, j = 0, star = -1, mark = 0
        while i < n.count {
            if j < p.count, p[j] != "*", p[j] == n[i] {
                i += 1; j += 1
            } else if j < p.count, p[j] == "*" {
                star = j; mark = i; j += 1
            } else if star >= 0 {
                j = star + 1; mark += 1; i = mark
            } else {
                return false
            }
        }
        while j < p.count, p[j] == "*" { j += 1 }
        return j == p.count
    }

    static func derived(_ name: String) -> Bool { DERIVED.contains { matches(name, $0) } }

    /// `folder.glob("speakers*.json")`: files only (`all`: anything of that name, as `shutil.move` takes it).
    private static func speakerFiles(_ folder: String, all: Bool = false) throws -> [String] {
        try listdir(folder).filter { name in
            guard matches(name, SPEAKER_FILES) else { return false }
            if all { return true }
            return statOf(folder + "/" + name).map(isRegular) ?? false
        }
    }

    /// The names in a folder, as stored (readdir order, no "." and "..").
    static func listdir(_ dir: String) throws -> [String] {
        guard let d = opendir(dir) else { throw posixError(dir) }
        defer { closedir(d) }
        var names: [String] = []
        while let e = readdir(d) {
            let length = Int(e.pointee.d_namlen)
            let name = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// `rglob("*")`: every entry below `dir` with its relative path, its name and its `lstat`; folders are entered,
    /// symlinked ones not. Unreadable folders are skipped.
    private static func walk(_ dir: String, _ rel: String, _ visit: (String, String, String, stat) throws -> Void) rethrows {
        for name in (try? listdir(dir)) ?? [] {
            let path = dir + "/" + name, r = rel.isEmpty ? name : rel + "/" + name
            var l = stat()
            guard lstat(path, &l) == 0 else { continue }  // gone meanwhile
            try visit(r, path, name, l)
            if isDirectory(l) { try walk(path, r, visit) }
        }
    }

    /// `os.makedirs(path, exist_ok=True)` with Darwin's `mkdir`, so a name is stored as given (Foundation's file APIs
    /// store it decomposed, NFD, which would make a copied "Zoë" another name than the original).
    static func makedirs(_ path: String) throws {
        if isDir(path) { return }
        let parent = dirname(path)
        if parent != path && !isDir(parent) { try makedirs(parent) }
        if mkdir(path, 0o777) != 0 && !(errno == EEXIST && isDir(path)) { throw posixError(path) }
    }

    static func statOf(_ path: String) -> stat? {
        var st = stat()
        return stat(path, &st) == 0 ? st : nil
    }

    private static func isDirectory(_ st: stat) -> Bool { st.st_mode & S_IFMT == S_IFDIR }
    private static func isRegular(_ st: stat) -> Bool { st.st_mode & S_IFMT == S_IFREG }
    /// `Path.is_dir()` (symlinks followed).
    static func isDir(_ path: String) -> Bool { statOf(path).map(isDirectory) ?? false }
    /// `Path.exists()` (symlinks followed).
    static func exists(_ path: String) -> Bool { statOf(path) != nil }

    /// Python's `!=` of a manifest's fingerprint and one computed now: equal only for that very string.
    private static func same(_ stored: JSONValue, _ now: String) -> Bool {
        if case .string(let s) = stored { return Py.same(s, now) }
        return false
    }

    private static func strings(_ value: JSONValue?, _ token: String) throws -> [String] {
        guard case .array(let items)? = value else { throw UndoGone(token) }
        return try items.map { item in
            guard case .string(let s) = item else { throw UndoGone(token) }
            return s
        }
    }

    /// `shutil.copytree(src, dst, ignore=...)` (symlinks followed): `dst` and its missing parents made (an existing
    /// `dst` is an error), every entry copied that `ignore` does not name, then the folder's mode, flags and times.
    /// A failure leaves the rest copied and throws at the end, as shutil does.
    static func copytree(_ src: String, _ dst: String, ignore: (String) -> Bool = { _ in false }) throws {
        let names = try listdir(src)
        var l = stat()
        if lstat(dst, &l) == 0 { throw posixError(dst, EEXIST) }
        try makedirs(dst)
        var failure: Error?
        for name in names where !ignore(name) {
            let s = src + "/" + name, d = dst + "/" + name
            do {
                if isDir(s) { try copytree(s, d, ignore: ignore) } else { try copy2(s, d) }
            } catch {
                failure = failure ?? error
            }
        }
        if let st = statOf(src) {
            var times = [st.st_atimespec, st.st_mtimespec]
            _ = utimensat(AT_FDCWD, dst, &times, 0)
            _ = chmod(dst, st.st_mode & 0o7777)
            _ = chflags(dst, st.st_flags)
        }
        if let failure { throw failure }
    }

    /// `shutil.copy2`: the data, then mode, times and flags (an existing target overwritten).
    static func copy2(_ src: String, _ dst: String) throws {
        if copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_ALL)) != 0 { throw posixError(src) }
    }

    /// `shutil.move`: into `dst` when it is a folder (an error when the name is taken there), else renamed to it;
    /// across volumes copied (as `copytree` and `copy2` copy), then removed. Returns where it went.
    @discardableResult
    static func shutilMove(_ src: String, _ dst: String) throws -> String {
        var target = dst
        if isDir(dst) {
            target = dst + "/" + basename(pyPath(src))
            if exists(target) { throw posixError(target, EEXIST) }
        }
        if Darwin.rename(src, target) != 0 {
            guard errno == EXDEV else { throw posixError(src) }
            var l = stat()
            if lstat(src, &l) == 0 && isDirectory(l) {
                try copytree(src, target)
                try FileManager.default.removeItem(atPath: src)
            } else {
                try copy2(src, target)
                if Darwin.unlink(src) != 0 { throw posixError(src) }
            }
        }
        return target
    }

    private static func sha256(_ path: String) throws -> SHA256.Digest {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError(path) }
        defer { close(fd) }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw posixError(path) }
            if n == 0 { break }
            buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(n))) }
        }
        return hash.finalize()
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        for b in bytes { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 0xF)]) }
        return String(decoding: out, as: UTF8.self)
    }

    private static func posixError(_ path: String, _ code: Int32 = errno) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: "[Errno \(code)] \(String(cString: strerror(code))): '\(path)'"])
    }
}
