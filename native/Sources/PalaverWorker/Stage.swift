// Pipeline events and timed stages in a recording's session.log (palaver/session_log.py `event`, `stage`;
// runlog.py `stamp`): `<name>_start` and `<name>_done` with `seconds` (rounded to 0.1) and what the stage
// added, which the app's progress display and the window's pipeline view read. The start of a process is
// stamped with which Palaver wrote it.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

public enum Stage {
    /// session_log.py `STAMPED`: the start of a process or a recording.
    public static let STAMPED: Set<String> = ["process_start", "record_start", "live_start", "stream_start", "notes_start",
                                              "notion_upload_start", "daemon_start", "app_start", "webapp_start"]

    /// What a stage adds to its `_done` line while it runs (`info.update(...)`): a key set again keeps its place.
    public final class Info {
        public private(set) var fields: PyDict<JSONValue>
        init(_ fields: [(String, JSONValue)]) { self.fields = PyDict(fields) }
        public subscript(key: String) -> JSONValue? {
            get { fields[key] }
            set { fields[key] = newValue }
        }
    }

    /// The version and commit of this build, worked out once: a checkout's git (a release has none).
    private static let build: (version: String, commit: JSONValue, dirty: JSONValue) = {
        let location = AppLocation(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        guard let checkout = location.checkout,
              FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git").path) else {
            return (location.version(), .null, .null)
        }
        func git(_ args: String...) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", checkout.path] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let commit = git("rev-parse", "HEAD"), let status = git("status", "--porcelain", "--untracked-files=no") else {
            return (location.version(), .null, .null)
        }
        return (location.version(), .string(commit), .bool(!status.isEmpty))
    }()

    /// runlog.py `stamp`: who writes — the version and commit, the process and its command; `"swift": true`
    /// where Python writes its own version.
    public static func stamp() -> [(String, JSONValue)] {
        [("version", .string(build.version)), ("commit", build.commit), ("dirty", build.dirty), ("pid", .int(Int(getpid()))),
         ("argv", .strings(Array(CommandLine.arguments.dropFirst()))), ("swift", .bool(true))]
    }

    /// A structured pipeline event; a STAMPED one starts with the stamp (the caller's fields win, as in Python).
    public static func event(_ name: String, log: SessionLog?, _ fields: [(String, JSONValue)] = []) {
        guard let log else { return }
        var row = PyDict<JSONValue>()
        if STAMPED.contains(name) { for (k, v) in stamp() { row[k] = v } }
        for (k, v) in fields { row[k] = v }
        log.event(name, logger: "palaver", row.map { ($0.key, $0.value as Any) })
    }

    /// A timed stage: `<name>_start` with `fields`, the body, then `<name>_done` with `seconds` and the fields plus
    /// what the body added. A body that throws writes no `_done` (the session's "command failed" says why).
    public static func with<T>(_ name: String, log: SessionLog?, fields: [(String, JSONValue)] = [],
                               _ body: (Info) throws -> T) rethrows -> T {
        let info = Info(fields)
        event("\(name)_start", log: log, fields)
        let started = DispatchTime.now()
        let result = try body(info)
        done(name, log: log, started: started, info: info)
        return result
    }

    /// `with` for a body that awaits (the engine's calls).
    public static func with<T>(_ name: String, log: SessionLog?, fields: [(String, JSONValue)] = [],
                               _ body: (Info) async throws -> T) async rethrows -> T {
        let info = Info(fields)
        event("\(name)_start", log: log, fields)
        let started = DispatchTime.now()
        let result = try await body(info)
        done(name, log: log, started: started, info: info)
        return result
    }

    private static func done(_ name: String, log: SessionLog?, started: DispatchTime, info: Info) {
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
        event("\(name)_done", log: log, [("seconds", .double(Py.round(seconds, 1)))] + info.fields.map { ($0.key, $0.value) })
    }
}
