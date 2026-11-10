// The model's runs in a meeting's session.log (session_log.py `event`, `stage`): `notes_start` (stamped with which
// Palaver wrote it), `notes_done` with `seconds`, `notes_skipped`, `notes_failed`, and the same for `projects`, which the
// app's progress display and the window's pipeline view read. And one model at a time across processes, Swift and
// Python alike: a flock on notes.lock (cli.py `_one_model_at_a_time`).
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

public struct RunLog {
    /// session_log.py `STAMPED` among the events written here.
    static let STAMPED: Set<String> = ["notes_start"]

    public let log: SessionLog?

    public init(_ log: SessionLog?) { self.log = log }

    /// The version of the Palaver this program belongs to (its bundle's, else its checkout's).
    static func version() -> String {
        AppLocation(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).version()
    }

    /// runlog.py `stamp`: who writes.
    static func stamp() -> [(String, JSONValue)] {
        return [("version", .string(version())), ("commit", .null), ("dirty", .null), ("pid", .int(Int(getpid()))),
                ("argv", .strings(Array(CommandLine.arguments.dropFirst()))), ("swift", .bool(true))]
    }

    public func event(_ name: String, _ fields: [(String, JSONValue)] = []) {
        guard let log else { return }
        var row = PyDict<JSONValue>()
        if Self.STAMPED.contains(name) { for (k, v) in Self.stamp() { row[k] = v } }
        for (k, v) in fields { row[k] = v }
        log.event(name, logger: "palaver", row.map { ($0.key, $0.value as Any) })
    }

    /// `<name>_start`, the body, `<name>_done` with `seconds`; a body that throws writes no `_done`.
    public func stage<T>(_ name: String, _ fields: [(String, JSONValue)], _ body: () async throws -> T) async rethrows -> T {
        event("\(name)_start", fields)
        let started = Date()
        let result = try await body()
        event("\(name)_done", [("seconds", .double(Py.round(Date().timeIntervalSince(started), 1)))] + fields)
        return result
    }
}

/// The language model is in use by another run and this one would not wait (`EXIT_MODEL_BUSY`).
public struct ModelBusyError: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "the language model is busy" }
}

/// One language model at a time across processes: the notes, a sort with the model, the best next question each load a
/// large local model. A run that waits says so once.
public enum ModelLock {
    /// cli.py `EXIT_MODEL_BUSY`.
    public static let EXIT_MODEL_BUSY: Int32 = 75

    /// `body` while holding notes.lock. `wait: false` throws `ModelBusyError` when another process holds it.
    public static func with<T>(stores: StorePaths, wait: Bool, say: (String) -> Void = { print($0) },
                               _ body: () async throws -> T) async throws -> T {
        let url = stores.notesLock
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        if !lock(fd, LOCK_EX | LOCK_NB) {
            guard wait else { throw ModelBusyError() }
            say("Waiting for the language model: another run is using it…")
            guard lock(fd, LOCK_EX) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(fd, LOCK_UN) }
        return try await body()
    }

    private static func lock(_ fd: Int32, _ how: Int32) -> Bool {
        while flock(fd, how) != 0 {
            if errno == EINTR { continue }
            return false
        }
        return true
    }
}
