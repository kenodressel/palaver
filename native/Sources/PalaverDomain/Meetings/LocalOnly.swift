// Meetings the user keeps on this Mac (palaver/llm.py `set_local_only`, `is_local_only`,
// `local_only_meetings`, #53): never sent to a cloud model, never shown to Claude through MCP.
import Foundation
import PalaverCore

public enum LocalOnly {
    public static func isLocalOnly(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: RecordingPaths(folder).localOnly.path)
    }

    /// The ids of the meetings kept on this Mac: the folders of `outputDir` with the marker.
    public static func meetings(outputDir: URL) -> Set<String> {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: outputDir.path, isDirectory: &isDir), isDir.boolValue,
              let names = try? fm.contentsOfDirectory(atPath: outputDir.path) else { return [] }
        return Set(names.filter { name in
            let folder = outputDir.appendingPathComponent(name)
            var dir: ObjCBool = false
            return fm.fileExists(atPath: folder.path, isDirectory: &dir) && dir.boolValue && isLocalOnly(folder)
        })
    }

    /// On: `{"since": <iso seconds>}`, no indent, written in place; off: the marker is removed.
    public static func set(_ folder: URL, on: Bool, now: Date = Date(), timeZone: TimeZone = .current) throws {
        let marker = RecordingPaths(folder).localOnly
        if on {
            let since = JSONValue.object([("since", .string(Py.isoNow(timespec: "seconds", now: now, timeZone: timeZone)))])
            try PythonJSON.write(since, to: marker, indent: nil, ensureAscii: true)
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
    }
}
