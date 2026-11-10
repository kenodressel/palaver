// notes.py's `load` and `save`: what notes.json holds, or nil when there is none or it is not JSON; and writing it.
import Foundation
import PalaverCore

public enum NotesFile {
    public static func load(_ paths: RecordingPaths) -> JSONValue? { PythonJSON.read(paths.notes) }

    /// `notes.save` (notes.py:570): `json.dumps(notes, indent=2, ensure_ascii=False)` through `notes.json.tmp`.
    public static func save(_ paths: RecordingPaths, _ notes: JSONValue) throws {
        try PythonJSON.write(notes, to: paths.notes, indent: 2, ensureAscii: false, via: "notes.json.tmp")
    }
}
