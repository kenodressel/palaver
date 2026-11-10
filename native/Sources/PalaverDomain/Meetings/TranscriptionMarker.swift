// transcription.json (palaver/transcription.py `read_marker`, `write_marker`, `wants_cloud`, #54):
// who transcribed each track: this Mac, the live worker or a cloud service.
import Foundation
import PalaverCore

public enum TranscriptionMarker {
    /// The file's object; an empty one when it is missing, broken or not an object.
    public static func read(_ paths: RecordingPaths) -> JSONValue {
        if let data = PythonJSON.read(paths.transcription), case .object = data { return data }
        return .object([])
    }

    /// `data[track] = {**info, "at": now}`, the file written whole or not at all (`transcription.json.tmp`,
    /// `indent=2`, `ensure_ascii=False`). A track already there keeps its place.
    public static func write(_ paths: RecordingPaths, track: String, info: [(String, JSONValue)],
                             now: Date = Date(), timeZone: TimeZone = .current) throws {
        var data = PyDict<JSONValue>(read(paths)) ?? PyDict()
        var entry = PyDict<JSONValue>(info)
        entry["at"] = .string(Py.isoNow(timespec: "seconds", now: now, timeZone: timeZone))
        data[track] = entry.json
        try PythonJSON.write(data.json, to: paths.transcription, indent: 2, ensureAscii: false,
                             via: paths.transcription.lastPathComponent + ".tmp")
    }

    /// Whether the system track still needs the service: not transcribed yet, transcribed by the live
    /// worker during the call, or by this Mac after the service failed. A meeting transcribed before
    /// any of this (no transcription.json) is left as it is.
    public static func wantsCloud(_ paths: RecordingPaths) -> Bool {
        if !FileManager.default.fileExists(atPath: paths.systemSegments.path) { return true }
        guard let system = read(paths)["system"] else { return false }
        return system["engine"]?.stringValue == "live" || system["fallback_from"]?.truthy == true
    }
}
