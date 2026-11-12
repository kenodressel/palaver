// The cloud providers the user can choose and which one each feature uses, the write side and readiness
// (palaver/providers.py): what the Settings page says of each provider, its settings saved in settings.json
// ("providers"), its API key in the Keychain (account "<provider>.api_key"), and the choice per feature ("engines"),
// which only `choose` writes. The read side (the registry, `settings_of`, `choice`) is PalaverDomain's ModelChoice.
//
// Local stays the default for everything: a feature uses a provider only after the user chose it, and only a
// provider that is set up (`problem` is nil). Nothing here sends anything.
import Foundation
import PalaverCore
import PalaverDomain

/// A setting or choice that is refused (providers.py's ValueError), said to the user.
public struct SettingRefused: Error, CustomStringConvertible {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var description: String { text }
}

/// What only the Settings card says of a provider and of a feature (providers.PROVIDERS, FEATURES).
public enum ProviderRegistry {
    public struct Info: Sendable {
        /// Who gets the data, said plainly.
        public let sendsTo: String
        /// How long it is kept there and whether it is trained on.
        public let privacy: String
        /// A transcription service's list price per hour of audio.
        public let usdPerHour: Double?
    }

    static let gateway = "the endpoint you set: OpenAI, your Azure OpenAI tenant or your gateway"

    /// By provider id (ASCII ids, as ModelChoice.providers has them).
    public static let info: [String: Info] = [
        "anthropic": Info(sendsTo: "Anthropic", privacy: "", usdPerHour: nil),
        "openai": Info(sendsTo: gateway, privacy: "", usdPerHour: nil),
        "claude-cli": Info(sendsTo: "Anthropic, through your Claude Code login", privacy: "", usdPerHour: nil),
        "assemblyai": Info(
            sendsTo: "AssemblyAI, on its servers in the region you choose",
            privacy: "Palaver deletes the transcript there, and the audio with it, as soon as it has it (a job still "
                + "running is deleted on the next try). Audio that never became a transcript AssemblyAI deletes "
                + "within 48 hours. On the EU servers AssemblyAI never trains on it; on the US servers only if you "
                + "opted out.",
            usdPerHour: 0.28),
        "soniox": Info(
            sendsTo: "Soniox, on its servers in the region you choose",
            privacy: "Soniox never trains on it. Palaver deletes the audio and the transcript there as soon as it has "
                + "the transcript, or on the next try if Soniox refuses then (else Soniox keeps them 30 days). "
                + "The EU region needs an EU project at Soniox: request it in the Soniox Console and use that "
                + "project's key.",
            usdPerHour: 0.10),
        "mistral": Info(
            sendsTo: "Mistral AI, in the EU",
            privacy: "Mistral hosts it in the EU and does not train on API data; it keeps it as your Mistral account "
                + "says (zero retention on request). Not measured on German meetings yet.",
            usdPerHour: 0.21),
        "openai-transcribe": Info(
            sendsTo: gateway,
            privacy: "As the endpoint's terms say. OpenAI's API does not train on it unless you opt in.",
            usdPerHour: nil),
    ]

    /// What each feature sends to a cloud provider, by feature id.
    public static let sends: [String: String] = [
        "notes": "the meeting's transcript with speaker names, and its calendar title and invitees",
        "projects": "the titles, summaries, people and email domains of the meetings to sort, and your project names "
            + "and descriptions",
        "coach": "the last minutes of the live transcript with speaker names, the meeting's calendar title and invitees, "
            + "the last meeting's summary and open next steps, and your own notes on the meeting; only when you ask",
        "transcription": "the call's system track (what the others said), with long silences cut out, and the meeting's "
            + "keyterms (glossary terms and invitees' names)",
    ]

    public static func languageModels() -> [String] {
        ModelChoice.providers.filter { $0.uses.contains(ModelChoice.LANGUAGE_MODEL) }.map(\.id)
    }

    public static func transcribers() -> [String] {
        ModelChoice.providers.filter { $0.uses.contains(ModelChoice.TRANSCRIPTION) }.map(\.id)
    }

    /// The feature as the Settings page lists it: `{id, label, uses, [own], sends}`.
    public static func featureJSON(_ f: ModelChoice.Feature) -> [(String, JSONValue)] {
        [("id", .string(f.id)), ("label", .string(f.label)), ("uses", .string(f.uses))]
            + (f.own ? [("own", .bool(true))] : []) + [("sends", .string(sends[f.id] ?? ""))]
    }
}

/// The providers' settings, keys and choices for one config.toml and one settings.json.
public struct ProviderSettings {
    public static let ON_THIS_MAC = ["localhost", "127.0.0.1", "::1"]
    /// cloud_llm.AZURE_SUFFIXES.
    public static let AZURE_SUFFIXES = [".openai.azure.com", ".cognitiveservices.azure.com", ".services.ai.azure.com"]

    public let config: Config
    public let stores: StorePaths
    public let keys: KeyStore
    public let env: [String: String]

    public init(config: Config, stores: StorePaths, keys: KeyStore, env: [String: String] = ProcessInfo.processInfo.environment) {
        self.config = config
        self.stores = stores
        self.keys = keys
        self.env = env
    }

    // MARK: - The registry

    func provider(_ pid: String) throws -> ModelChoice.Provider {
        guard let p = ModelChoice.provider(pid) else { throw SettingRefused("no provider \(Py.repr(.string(pid)))") }
        return p
    }

    /// config.toml's defaults for `pid` (the Claude Code CLI's model).
    public func defaults(_ pid: String) -> PyDict<JSONValue>? { ModelChoice.providerDefaults(config: config, pid: pid) }

    /// `settings_of`: as saved, else `defaults`, else the provider's own.
    public func settingsOf(_ pid: String, defaults: PyDict<JSONValue>? = nil) throws -> PyDict<JSONValue> {
        do {
            return try ModelChoice.settingsOf(pid, defaults: defaults, stores: stores)
        } catch let e as ModelChoice.NoProvider {
            throw SettingRefused(e.description)
        }
    }

    /// Settings only some providers have (`_EXTRA`).
    static func extra(_ pid: String) -> [String] {
        switch pid {
        case "openai", "openai-transcribe": return ["auth"]
        case "assemblyai", "soniox": return ["region"]
        default: return []
        }
    }

    static let CHECKED = ["endpoint", "model", "context_tokens", "auth", "region"]

    /// One setting's value as it is saved, or the refusal (`_CHECKS`).
    static func check(_ name: String, _ value: JSONValue) throws -> JSONValue {
        switch name {
        case "endpoint":
            if let problem = ModelChoice.endpointProblem(value) { throw SettingRefused(problem) }
            return .string(Py.strip(value.stringValue ?? ""))
        case "model":
            guard let m = ModelChoice.checkModel(value) else { throw SettingRefused("the model name must be one line of text") }
            return .string(m)
        case "context_tokens":
            guard let n = ModelChoice.checkContext(value) else {
                throw SettingRefused("the context window must be between 1,000 and 10,000,000 tokens")
            }
            return .int(n)
        case "auth":
            guard let v = value.stringValue, ModelChoice.AUTH_HEADERS.contains(where: { Py.same($0, v) }) else {
                throw SettingRefused("the key header must be one of \(ModelChoice.AUTH_HEADERS.joined(separator: ", "))")
            }
            return value
        default:
            guard let v = value.stringValue, ModelChoice.REGIONS.contains(where: { Py.same($0, v) }) else {
                throw SettingRefused("the region must be one of \(ModelChoice.REGIONS.joined(separator: ", "))")
            }
            return value
        }
    }

    /// `configure`: saves the provider's endpoint, model, context window, key header or region; a value that is not
    /// one is refused and nothing is saved. Other saved fields stay as they are.
    @discardableResult
    public func configure(_ pid: String, _ changes: [(String, JSONValue)]) throws -> PyDict<JSONValue> {
        let p = try provider(pid)
        var checked = PyDict<JSONValue>()
        for (name, value) in changes {
            let known = Self.CHECKED.contains(name)
            if !known || (name == "endpoint" && p.endpoint == nil)
                || ((name == "auth" || name == "region") && !Self.extra(p.id).contains(name))
                || (name == "context_tokens" && p.contextTokens == 0) {
                throw SettingRefused("\(p.label) has no setting \(Py.repr(.string(name)))")
            }
            checked[name] = try Self.check(name, value)
        }
        var every = PyDict<JSONValue>()
        if case .object(let fields)? = SettingsFile.readRaw(stores: stores)["providers"] { every = PyDict(fields) }
        var mine = PyDict<JSONValue>()
        if case .object(let fields)? = every[p.id] { mine = PyDict(fields) }
        for (k, v) in checked { mine[k] = v }
        every[p.id] = mine.json
        try SettingsFile.update([("providers", every.json)], stores: stores)
        return try settingsOf(p.id)
    }

    // MARK: - Keys

    public static func keyAccount(_ pid: String) -> String { "\(pid).api_key" }

    /// A key is saved for `pid` (attributes only: never a prompt).
    public func hasKey(_ pid: String) -> Bool {
        guard let p = ModelChoice.provider(pid), p.key != "none" else { return false }
        return keys.has(Self.keyAccount(p.id))
    }

    /// The key itself, for the request only: never shown, logged or returned to the page. nil when there is none or the
    /// Keychain would not give it.
    public func apiKey(_ pid: String) -> String? {
        guard let p = ModelChoice.provider(pid), p.key != "none" else { return nil }
        return (try? keys.read(Self.keyAccount(p.id))) ?? nil
    }

    /// `set_key`: the key checked (APIKey.checked) and saved; refusals never quote it.
    public func setKey(_ pid: String, _ key: JSONValue?) throws {
        let p = try provider(pid)
        if p.key == "none" { throw SettingRefused("\(p.label) takes no API key") }
        guard case .string(let given)? = key else { throw SettingRefused("that is not an API key") }
        let value: String
        do { value = try APIKey.checked(given) } catch let e as KeyRefused { throw SettingRefused(e.text) }
        do { try keys.write(Self.keyAccount(p.id), value) } catch let e as KeychainError { throw SettingRefused(e.text) }
    }

    public func removeKey(_ pid: String) throws {
        let p = try provider(pid)
        do { try keys.delete(Self.keyAccount(p.id)) } catch let e as KeychainError { throw SettingRefused(e.text) }
    }

    // MARK: - Readiness

    /// The Claude Code CLI as config.toml names it, else found on PATH or where it is usually installed.
    public func claude() -> String? { ClaudeCLI.find(configured: config.claudePath, env: env, home: stores.home) }

    /// `problem`: what keeps the provider from being used, said to the user; nil when it is ready.
    public func problem(_ pid: String, defaults: PyDict<JSONValue>? = nil) throws -> String? {
        let p = try provider(pid)
        if p.id == "claude-cli" { return claude() == nil ? "Claude Code CLI (`claude`) not found on this Mac" : nil }
        if !(try settingsOf(p.id, defaults: defaults)["model"]?.truthy ?? false) { return "Set the model name" }
        if p.key == "optional" { return gatewayProblem(p.id) }
        if p.key == "required" && !hasKey(p.id) { return "Add the API key" }
        return nil
    }

    public static func isAzure(_ url: String) -> Bool {
        let host = ModelChoice.hostname(url) ?? ""
        return AZURE_SUFFIXES.contains { host.hasSuffix($0) }
    }

    /// `<resource>.openai.azure.com` (or another Azure AI host), with a resource name.
    static func azureTenant(_ host: String) -> Bool {
        AZURE_SUFFIXES.contains { host.hasSuffix($0) && host.count > $0.count && !host.hasPrefix(".") }
    }

    /// An OpenAI-compatible endpoint sends nothing until it is set up for real: the endpoint saved by the user (the
    /// default is no choice), a key unless the endpoint is on this Mac, and for Azure (by host, or the api-key header
    /// picked) the tenant's own endpoint.
    func gatewayProblem(_ pid: String) -> String? {
        let stored = ModelChoice.stored(pid, stores: stores)
        let endpoint = stored["endpoint"]?.stringValue ?? ""
        let host = ModelChoice.hostname(endpoint) ?? ""  // lowered
        if stored["auth"]?.stringValue == "api-key" || Self.isAzure(endpoint) || host.hasSuffix(".azure.com") {
            if !Self.azureTenant(host) { return "Set your Azure OpenAI endpoint (https://<resource>.openai.azure.com/…)" }
        }
        if endpoint.isEmpty { return "Save the endpoint" }
        if !Self.ON_THIS_MAC.contains(host) && !hasKey(pid) { return "Add the API key" }
        return nil
    }

    /// `public`: the provider as the Settings page shows it, never the key, only whether one is set.
    public func publicView(_ pid: String, defaults: PyDict<JSONValue>? = nil) throws -> [(String, JSONValue)] {
        let p = try provider(pid)
        let trouble = try problem(p.id, defaults: defaults)
        let info = ProviderRegistry.info[p.id]
        let view: [(String, JSONValue)] = [
            ("id", .string(p.id)), ("label", .string(p.label)), ("sends_to", .string(info?.sendsTo ?? "")),
            ("key", .string(p.key)), ("key_set", .bool(hasKey(p.id))), ("ready", .bool(trouble == nil)),
            ("problem", .str(trouble)), ("has_endpoint", .bool(p.endpoint != nil)), ("privacy", .string(info?.privacy ?? "")),
            ("usd_per_hour", .num(info?.usdPerHour)),
        ]
        return view + Array(try settingsOf(p.id, defaults: defaults).map { ($0.key, $0.value) })
    }

    // MARK: - Choices

    /// config.toml's choice for a feature never chosen in Settings (`llm.default_choice`).
    public func defaultChoice(_ feature: String) -> String {
        ModelChoice.defaultChoice(feature: feature, config: config, stores: stores)
    }

    /// `choice`: "local", "pending" or the provider the user chose for `feature`; `fallback` when never chosen.
    public func choice(_ feature: String, default fallback: String) -> String {
        ModelChoice.choice(feature: feature, default: fallback, stores: stores)
    }

    /// `choose`: "local" (or "pending" for a language-model feature) or a provider that is set up, for `feature`. This
    /// is the user's consent: nothing else writes `engines`.
    public func choose(_ feature: String, _ value: JSONValue) throws {
        guard let f = ModelChoice.feature(feature) else { throw SettingRefused("no feature \(Py.repr(.string(feature)))") }
        let chosen = value.stringValue
        if chosen == ModelChoice.PENDING && f.uses == ModelChoice.LANGUAGE_MODEL {
            // off until a cloud model is set up: nothing to check
        } else if chosen != ModelChoice.LOCAL {
            guard let pid = chosen, ModelChoice.forFeature(f.id).contains(where: { Py.same($0, pid) }),
                  let p = ModelChoice.provider(pid) else {
                let kind = f.uses == ModelChoice.TRANSCRIPTION ? "transcription service" : "language model"
                throw SettingRefused("no \(kind) \(Py.repr(value))")
            }
            if let trouble = try problem(p.id, defaults: defaults(p.id)) { throw SettingRefused("\(p.label): \(trouble)") }
        }
        var engines = PyDict<JSONValue>()
        if case .object(let fields)? = SettingsFile.readRaw(stores: stores)["engines"] { engines = PyDict(fields) }
        engines[f.id] = value
        try SettingsFile.update([("engines", engines.json)], stores: stores)
    }

    /// Every provider as the Settings page shows it with what it is for (`uses`), and each feature with its kind of
    /// provider, its choice (`default`: config.toml's, or local) and whether that choice can be used now (`ready`)
    /// (provider_helper.registry, the setup assistant's view).
    public func registry() throws -> JSONValue {
        var shown = PyDict<[(String, JSONValue)]>()
        var ready = [String: Bool]()
        for p in ModelChoice.providers {
            let view = try publicView(p.id, defaults: defaults(p.id))
            shown[p.id] = view + [("uses", .strings(p.uses.sorted()))]
            ready[p.id] = view.first { $0.0 == "ready" }?.1.boolValue ?? false
        }
        let features: [JSONValue] = ModelChoice.features.map { f in
            let fallback = f.uses == ModelChoice.LANGUAGE_MODEL ? defaultChoice(f.id) : ModelChoice.LOCAL
            let chosen = choice(f.id, default: fallback)
            let isReady = chosen == ModelChoice.LOCAL || (ready[chosen] ?? false)
            let listed = ProviderRegistry.featureJSON(f).filter { $0.0 != "own" }
            return .object(listed + [("own", .bool(f.own)), ("choice", .string(chosen)), ("default", .string(fallback)),
                                     ("ready", .bool(isReady))])
        }
        return .object([("features", .array(features)), ("providers", .array(shown.values.map { .object($0) }))])
    }
}
