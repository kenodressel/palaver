// Why a recording has no transcript yet (palaver/process_state.py): `palaver process` failed on it, or
// it waits for models still being downloaded (a call recorded right after installing). Kept as
// failed.json in its folder until a run succeeds; the window shows it, with Transcribe Again, and the
// menu bar app transcribes the waiting ones once their models are here.
import Foundation
import PalaverCore

public enum ProcessState {
    public static let file = "failed.json"
    /// Waits for its models: tried again once they are downloaded.
    public static let models = "models"
    /// Failed: tried again only when the user asks.
    public static let error = "error"
    /// `palaver process` exits with this while its models are missing.
    public static let exitModels: Int32 = 4
    /// onboarding.MODELS["speech"].label: palaver-engine's models, one download.
    public static let speechModelsLabel = "Speech models"

    private static func url(_ paths: RecordingPaths) -> URL { paths.folder.appendingPathComponent(file) }

    /// {"reason", "at", "missing" (model labels), "error"}; nil when the last run did not fail (or none ran yet).
    public static func read(_ paths: RecordingPaths) -> JSONValue? {
        guard let data = PythonJSON.read(url(paths)), case .object = data,
              let reason = data["reason"]?.stringValue, reason == models || reason == error else { return nil }
        return data
    }

    /// `failed.json`, via `failed.json.tmp`, `indent=2`.
    public static func mark(_ paths: RecordingPaths, reason: String, missing: [String] = [], error: String? = nil,
                            now: Date = Date(), timeZone: TimeZone = .current) throws {
        let data = JSONValue.object([("reason", .string(reason)),
                                     ("at", .string(Py.isoNow(timespec: "seconds", now: now, timeZone: timeZone))),
                                     ("missing", .strings(missing)), ("error", .str(error))])
        try PythonJSON.write(data, to: url(paths), indent: 2, ensureAscii: true, via: file + ".tmp")
    }

    public static func clear(_ paths: RecordingPaths) {
        try? FileManager.default.removeItem(at: url(paths))
    }

    /// The labels of the models `process` still needs for `paths` that are not on this Mac: the speech
    /// models (palaver-engine's: Parakeet for a track not transcribed yet, the microphone's always runs
    /// here, and the diarizer to tell the speakers apart; one download). `speechModelsHere` is asked
    /// only when something is left to do.
    public static func missingModels(transcriber: String, paths: RecordingPaths, speechModelsHere: () -> Bool) -> [String] {
        let fm = FileManager.default
        let transcribed = fm.fileExists(atPath: paths.micSegments.path) && fm.fileExists(atPath: paths.systemSegments.path)
        let needsAsr = (transcriber == "parakeet" || transcriber == "parakeet-mlx") && !transcribed
        let needsSpeakers = !(fm.fileExists(atPath: paths.systemTurns.path) && fm.fileExists(atPath: paths.speakerEmbeddings.path))
        if !(needsAsr || needsSpeakers) || speechModelsHere() { return [] }
        return [speechModelsLabel]
    }
}
