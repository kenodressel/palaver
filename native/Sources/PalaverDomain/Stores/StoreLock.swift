// The cross-process lock every store writer takes (Python: fcntl.flock on the same files).
// `<store>.lock` beside a store (`voices.lock` beside `voices/`), `<folder>/.speakers.lock` per meeting.
// A writer holds one store's lock only around reload, change, save, never two at once, and never
// during a model run.
import Foundation

public enum StoreLock {
    private static let heldKey = "palaver.storeLock.held"

    /// Blocks until `target + ".lock"` is ours (`flock(LOCK_EX)`), runs `body`, unlocks. The lock file
    /// is created 0644 (its folder too, if missing) and never deleted. An open or flock failure throws (the body never runs unlocked). Taking a lock this thread
    /// already holds runs `body` at once.
    public static func with<T>(_ target: URL, _ body: () throws -> T) throws -> T {
        try hold(target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".lock"), body)
    }

    /// The meeting's own lock: `<folder>/.speakers.lock`.
    public static func meeting<T>(_ paths: RecordingPaths, _ body: () throws -> T) throws -> T {
        try hold(paths.folder.appendingPathComponent(".speakers.lock"), body)
    }

    /// The pair in lock order: by the lock files' folder paths, compared by Unicode code points as Python's
    /// `sorted([a, b], key=str)` on the folders does (`my_notes._both`), so Swift and Python writers agree.
    static func pairOrder(_ a: URL, _ b: URL) -> (URL, URL) {
        func key(_ u: URL) -> [UInt32] { u.deletingLastPathComponent().path.unicodeScalars.map(\.value) }
        return key(a).lexicographicallyPrecedes(key(b)) || key(a) == key(b) ? (a, b) : (b, a)
    }

    /// Two stores' locks at once, in `pairOrder`, so two threads or processes taking the same pair cannot
    /// deadlock. The only place a thread holds two. Pass lock targets in the two folders (`<folder>/.my-notes`).
    public static func both<T>(_ a: URL, _ b: URL, _ body: () throws -> T) throws -> T {
        let (first, second) = pairOrder(a, b)
        return try with(first) { try hold(lockFile(second), nested: true, body) }
    }

    private static func lockFile(_ target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".lock")
    }

    /// One spelling per lock, the thread's key for it: `realpath(3)` of the lock's folder (made before this is
    /// asked), so `/var/…` and `/private/var/…` are one lock whether or not the folder existed before.
    /// (`resolvingSymlinksInPath` is not: it drops `/private` only for a path that exists.) A folder that is gone
    /// again (deleted while its lock is held) resolves through its nearest existing ancestor, so a nested take of
    /// the same lock still finds it held.
    static func canonicalPath(_ lock: URL) -> String {
        var folder = lock.deletingLastPathComponent().standardizedFileURL.path
        var rest = [lock.lastPathComponent]
        while true {
            if let resolved = Darwin.realpath(folder, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return (base == "/" ? "" : base) + "/" + rest.reversed().joined(separator: "/")
            }
            let parent = (folder as NSString).deletingLastPathComponent
            if parent == folder || parent.isEmpty { return folder + "/" + rest.reversed().joined(separator: "/") }
            rest.append((folder as NSString).lastPathComponent)
            folder = parent
        }
    }

    private static func hold<T>(_ lock: URL, nested: Bool = false, _ body: () throws -> T) throws -> T {
        try? FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let key = canonicalPath(lock)
        let dict = Thread.current.threadDictionary
        var held = dict[heldKey] as? Set<String> ?? []
        if held.contains(key) { return try body() }
        // A writer never holds two stores' locks at once (no deadlocks); checked in debug builds.
        assert(nested ? held.count <= 1 : held.isEmpty, "StoreLock: \(key) taken while this thread holds \(held)")
        let fd = open(lock.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            throw POSIXError(code)
        }
        held.insert(key)
        dict[heldKey] = held
        defer {
            held.remove(key)
            dict[heldKey] = held
            flock(fd, LOCK_UN)
            close(fd)
        }
        return try body()
    }
}
