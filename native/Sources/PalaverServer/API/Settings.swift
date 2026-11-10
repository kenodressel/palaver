// The Settings page's switches and its Storage section (api.py `get_settings`, `switches_turned_off`, `set_settings`,
// `storage_status`, `set_storage`; server.py's GET branches, `_settings_post` and `count_setting`). The switches are
// settings.json's (SettingsFile): only the keys the user changed are written, so a switch never touched keeps
// following config.toml (`app.settingsDefaults`).
import Foundation
import PalaverCore
import PalaverDomain

public enum SettingsAPI {
    /// The Settings page's changes: counted by key in the usage log (#59), never with a secret (server.py).
    public static let SETTINGS_PATHS = ["/api/settings", "/api/language-model", "/api/language-model/key",
                                        "/api/transcription", "/api/transcription/key"]
    /// appctl.SWITCH_APP: the record switches and the app each one is for, in its order.
    public static let SWITCH_APP: [(key: String, app: String)] = [("record_teams", "teams"), ("record_slack", "slack")]

    // MARK: - the switches

    /// `get_settings(defaults)`: every switch, settings.json's value or the default's.
    public static func get(defaults: SettingsValues, stores: StorePaths) -> JSONValue {
        SettingsFile.load(defaults: defaults, stores: stores).json
    }

    /// `set_settings(body, defaults)`: saves the known keys of `body`; anything but a boolean is a ValueError (400).
    /// Only those keys are written.
    public static func set(_ body: JSONValue, defaults: SettingsValues, stores: StorePaths) throws -> JSONValue {
        guard case .object(let fields) = body else {
            throw PyBody.TypeError(description: "'\(PyBody.typeName(body))' object has no attribute 'items'")
        }
        guard case .object(let known) = SettingsValues().json else { return get(defaults: defaults, stores: stores) }
        let changes = fields.filter { k, _ in known.contains { Py.same($0.0, k) } }
        for (key, value) in changes {
            guard case .bool = value else { throw BadRequest("\(key) must be true or false") }
        }
        try SettingsFile.update(changes, stores: stores)
        return get(defaults: defaults, stores: stores)
    }

    /// `switches_turned_off`: a record switch turned off on the Settings page stops that app's automatic recording
    /// now, as the menu's switch does; the app told (nobody outside it).
    static func switchesTurnedOff(_ recording: RecordingRemote?, _ body: JSONValue) {
        for (key, app) in SWITCH_APP where body[key] == .bool(false) { recording?.switchedOff(app: app) }
    }

    // MARK: - storage (#9)

    /// `storage_status`.
    public static func storage(_ app: ServerApp) -> JSONValue {
        Storage.summary(outputDir: app.outputDir, config: app.config, stores: app.stores)
    }

    /// `set_storage`: {"audio_days"}: how long a transcribed meeting keeps its audio; with "now", the audio older than
    /// that goes now. {"delete_model"}: a notes model not in use. The summary as it is then, with what was dropped.
    public static func setStorage(_ app: ServerApp, _ body: JSONValue) throws -> JSONValue {
        var dropped: JSONValue = .null
        try ChangesAPI.python {
            if try has(body, "delete_model") {
                _ = try Storage.deleteModel(Py.str(PyBody.required(body, "delete_model")), config: app.config, stores: app.stores)
            }
            if try has(body, "audio_days") {
                try Storage.setAudioDays(PyBody.required(body, "audio_days"), stores: app.stores)
                if try PyBody.get(body, "now")?.truthy ?? false {
                    let (n, freed) = try Storage.dropOldAudio(app.outputDir, days: Storage.audioDays(stores: app.stores))
                    dropped = .object([("meetings", .int(n)), ("bytes", .int(freed))])
                }
            }
        }
        guard case .object(var fields) = storage(app) else { return storage(app) }
        fields.append(("dropped", dropped))
        return .object(fields)
    }

    /// `key in body`: an object's key, a list's item, a text's part; anything else is a TypeError (500).
    static func has(_ body: JSONValue, _ key: String) throws -> Bool {
        switch body {
        case .object(let fields): return fields.contains { Py.same($0.0, key) }
        case .array(let items): return items.contains { if case .string(let s) = $0 { return Py.same(s, key) }; return false }
        case .string(let s):
            let text = Array(s.unicodeScalars), part = Array(key.unicodeScalars)
            return text.count >= part.count && (0...(text.count - part.count)).contains { Array(text[$0..<$0 + part.count]) == part }
        default: throw PyBody.TypeError(description: "argument of type '\(PyBody.typeName(body))' is not iterable")
        }
    }
}

extension Router {
    static func addSettingsRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/settings") { _, _ in .json(SettingsAPI.get(defaults: app.settingsDefaults, stores: app.stores)) }
        r.get("/api/storage") { _, _ in .json(SettingsAPI.storage(app)) }
        r.post("/api/storage") { req, _ in .json(try SettingsAPI.setStorage(app, req.json)) }
        r.post("/api/settings") { req, _ in
            let answer = try SettingsAPI.set(req.json, defaults: app.settingsDefaults, stores: app.stores)
            SettingsAPI.switchesTurnedOff(app.recording, req.json)
            ProvidersAPI.countSetting(app, path: req.target, body: req.json)
            return .json(answer)
        }
    }
}
