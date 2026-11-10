// The Settings page's Language model (#53) and Transcription (#54) sections: which model or service each feature
// uses, the providers, their API keys and Test buttons (api.py `language_model`, `set_language_model`,
// `set_provider_key`, `test_provider`, `transcription`, `set_transcription`, `set_transcription_key`,
// `test_transcription`; server.py's GET branches, `_settings_post`, `_model_test` and `count_setting`).
//
// Every answer comes from `app.provider` (`Providers`, in this process; the pages' answers are built below). A
// request's body, which may hold a key, goes there as it came and nowhere else: never into the log, the usage log
// (`Usage.settingEvents` records whether a key was set, never the key) or an error text.
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

public enum ProvidersAPI {
    /// How many access-log entries a page shows (transcription's uploads too: one log of what left the Mac).
    static let LOG_ENTRIES = 20

    static func labels() -> JSONValue { .object(ModelChoice.providers.map { ($0.id, .string($0.label)) }) }

    /// `api.language_model`: which model each feature uses and what it sends, the providers (never a key, only whether
    /// one is set), the local models and the access log.
    static func languageModel(_ s: ProviderSettings) throws -> JSONValue {
        let local = ModelChoice.localModel(config: s.config, stores: s.stores)
        var models: [JSONValue] = ModelChoice.LOCAL_MODELS.map { repo, m in
            .object([("repo", .string(repo)), ("label", .string(m.label)), ("memory_gb", .double(m.memoryGB)),
                     ("context_tokens", .int(m.contextTokens)), ("running_gb", .int(m.runningGB)), ("note", .string(m.note))])
        }
        if ModelChoice.localModelInfo(local) == nil {  // a model set in config.toml
            models.append(.object([("repo", .string(local)), ("label", .string(local)),
                                   ("memory_gb", .double(ModelChoice.notesMemoryGB(local))),
                                   ("context_tokens", .int(ModelChoice.LOCAL_CONTEXT_TOKENS)), ("note", .string("Set in config.toml."))]))
        }
        let features: [JSONValue] = ModelChoice.features.filter { $0.uses == ModelChoice.LANGUAGE_MODEL }.map { f in
            let fallback = s.defaultChoice(f.id)
            return .object(ProviderRegistry.featureJSON(f) + [("choice", .string(s.choice(f.id, default: fallback))),
                                                              ("default", .string(fallback))])
        }
        return .object([
            ("features", .array(features)),
            ("providers", .array(try ProviderRegistry.languageModels().map { .object(try s.publicView($0, defaults: s.defaults($0))) })),
            ("local", .object([("model", .string(local)), ("models", .array(models))])),
            ("log", .array(AccessLog.recent(LOG_ENTRIES, stores: s.stores))),
            ("labels", labels()),
        ])
    }

    /// `api.set_language_model`: `{"use": {feature: "local" | provider}}`, `{"provider": id, "endpoint", "model",
    /// "context_tokens", "auth"}` or `{"local_model": repo}`; the page's answer after.
    static func setLanguageModel(_ s: ProviderSettings, _ body: JSONValue) throws -> JSONValue {
        if let use = body["use"], use.truthy {
            guard case .object(let choices) = use else { throw BadRequest("use must be an object") }
            for (feature, value) in PyDict(choices) { try s.choose(feature, value) }
        }
        if let provider = body["provider"] {
            let changes = ["endpoint", "model", "context_tokens", "auth"].compactMap { k in body[k].map { (k, $0) } }
            try s.configure(Py.str(provider), changes)
        }
        if let repo = body["local_model"].map(Py.str) {
            guard ModelChoice.localModelInfo(repo) != nil else { throw SettingRefused("no local model \(Py.repr(.string(repo)))") }
            try SettingsFile.update([("local_model", .string(repo))], stores: s.stores)
        }
        return try languageModel(s)
    }

    /// `api.set_provider_key` / `set_transcription_key`: `{"provider", "key"}` stores the key in the Keychain, `{"provider",
    /// "remove": true}` removes it; `transcriptionOnly`: the transcription route, which takes only those services.
    static func setKey(_ s: ProviderSettings, _ body: JSONValue, transcriptionOnly: Bool) throws {
        let pid = body["provider"].map(Py.str) ?? "None"
        if transcriptionOnly && !ProviderRegistry.transcribers().contains(where: { Py.same($0, pid) }) {
            throw SettingRefused("no transcription service \(Py.repr(.string(pid)))")
        }
        if body["remove"]?.truthy == true {
            try s.removeKey(pid)
        } else {
            try s.setKey(pid, body["key"])
        }
    }

    /// `api.transcription`: local or which service, what it sends, the services (never a key), what was sent this month.
    static func transcription(_ s: ProviderSettings) throws -> JSONValue {
        let f = ModelChoice.feature(ModelChoice.TRANSCRIPTION)!
        return .object([
            ("feature", .object(ProviderRegistry.featureJSON(f) + [("choice", .string(s.choice(f.id, default: ModelChoice.LOCAL)))])),
            ("providers", .array(try ProviderRegistry.transcribers().map { .object(try s.publicView($0)) })),
            ("month", AccessLog.month(stores: s.stores)),
            ("log", .array(AccessLog.recent(LOG_ENTRIES, stores: s.stores))),
            ("labels", labels()),
        ])
    }

    /// `api.set_transcription`: `{"use": "local" | provider}` or `{"provider": id, "model", "region", "endpoint", "auth"}`.
    static func setTranscription(_ s: ProviderSettings, _ body: JSONValue) throws -> JSONValue {
        if let use = body["use"] { try s.choose(ModelChoice.TRANSCRIPTION, use) }
        if let provider = body["provider"] {
            let pid = Py.str(provider)
            guard ProviderRegistry.transcribers().contains(where: { Py.same($0, pid) }) else {
                throw SettingRefused("no transcription service \(Py.repr(.string(pid)))")
            }
            try s.configure(pid, ["endpoint", "model", "region", "auth"].compactMap { k in body[k].map { (k, $0) } })
        }
        return try transcription(s)
    }

    /// `api.count_setting(self.path, body)`: a setting changed in the window, counted by key in the usage log (#59).
    static func countSetting(_ app: ServerApp, path: String, body: JSONValue) {
        for event in Usage.settingEvents(path: path, body: body) {
            guard case .object(let fields) = event else { continue }
            let id = event["id"]?.stringValue
            Usage.record("setting", id, fields: fields.filter { !Py.same($0.0, "id") }, path: app.stores.usage)
        }
    }

    /// A settings change (`_settings_post`): the helper's answer, then the change counted.
    static func change(_ app: ServerApp, _ req: Request, _ action: String) throws -> Response {
        let answer = try app.provider.call(action, body: req.json, timeout: Providers.TIMEOUT)
        countSetting(app, path: req.target, body: req.json)
        return .json(answer)
    }
}

extension Router {
    static func addProviderRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/language-model") { _, _ in
            .json(try app.provider.call("language-model", body: .object([]), timeout: Providers.TIMEOUT))
        }
        r.get("/api/transcription") { _, _ in
            .json(try app.provider.call("transcription", body: .object([]), timeout: Providers.TIMEOUT))
        }
        r.post("/api/language-model") { req, _ in try ProvidersAPI.change(app, req, "set-language-model") }
        r.post("/api/language-model/key") { req, _ in try ProvidersAPI.change(app, req, "set-key") }
        r.post("/api/transcription") { req, _ in try ProvidersAPI.change(app, req, "set-transcription") }
        r.post("/api/transcription/key") { req, _ in try ProvidersAPI.change(app, req, "set-transcription-key") }
        // The Test buttons: the provider's answer, or why it failed (502).
        r.post("/api/language-model/test") { req, _ in
            .json(try app.provider.call("test", body: req.json, timeout: Providers.TEST_TIMEOUT))
        }
        r.post("/api/transcription/test") { req, _ in
            .json(try app.provider.call("test-transcription", body: req.json, timeout: Providers.TEST_TIMEOUT))
        }
    }
}
