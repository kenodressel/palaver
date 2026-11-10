// What the window asks for every few seconds, kept while the files it is made of stay as they were
// (api.py `_LIST_CACHE`, `_signature`): an entry is good while each of its files has the
// `st_mtime_ns` it had (0 for a missing file). Requests come from several threads at once.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

public final class SignatureCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    /// Keyed by code points (a folder's name is data: "Zoë" as one letter and as e + diaeresis stay two keys).
    private var entries: [ScalarKey: (signature: [Int], value: Value)] = [:]
    private var hitCount = 0
    private var missCount = 0

    public init() {}

    /// Answers served from the cache.
    public var hits: Int { lock.withLock { hitCount } }
    /// Answers made (`make` ran).
    public var misses: Int { lock.withLock { missCount } }

    /// `files`' modification times in nanoseconds, 0 for one that is missing (links followed, as `Path.exists` and
    /// `stat`); nil when a time does not fit an Int (`FileTimes.mtimeNs`): such an entry is never served from the cache.
    public static func signature(_ files: [URL]) -> [Int]? {
        var out: [Int] = []
        out.reserveCapacity(files.count)
        for file in files {
            var st = stat()
            guard stat(file.path, &st) == 0 else {
                out.append(0)
                continue
            }
            guard let ns = FileTimes.mtimeNs(st) else { return nil }
            out.append(ns)
        }
        return out
    }

    /// The value kept for `key` while `files` have not changed since it was made; else `make()`'s, kept for next time.
    /// `make` runs outside the lock: two requests that miss at once both make it, the later one is kept.
    public func get(key: String, files: [URL], make: () throws -> Value) rethrows -> Value {
        let k = ScalarKey(key)
        let signature = Self.signature(files)
        if let signature {
            let kept: Value? = lock.withLock {
                guard let e = entries[k], e.signature == signature else { return nil }
                hitCount += 1
                return e.value
            }
            if let kept { return kept }
        }
        let value = try make()
        lock.withLock {
            missCount += 1
            if let signature { entries[k] = (signature, value) } else { entries[k] = nil }
        }
        return value
    }
}
