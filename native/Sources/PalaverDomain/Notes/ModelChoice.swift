// Which language model runs a feature, the read side (palaver/llm.py:35-157 `LOCAL_MODELS`, `default_choice`,
// `choice_for`, `local_model`, `provider_defaults`, `memory_gb`; palaver/notes.py `MODEL_MEMORY_GB`,
// `NOTES_MEMORY_GB`, `notes_memory_gb`; palaver/providers.py:29-106 the registry, :184-208 `settings_of`,
// :311-321 `choice`). Local is the default; a cloud provider only once the user chose it in Settings; a meeting kept
// on this Mac stays local. API keys are not here: they are in the Keychain (PalaverCloud: KeyStore, ProviderSettings).
import Foundation
import PalaverCore

public enum ModelChoice {
    public static let LANGUAGE_MODEL = "language_model"
    public static let TRANSCRIPTION = "transcription"
    public static let LOCAL = "local"
    /// A language-model feature waiting for a cloud model the user has not set up yet (#55): nothing runs until then.
    public static let PENDING = "pending"
    public static let REGIONS = ["eu", "us"]
    public static let MAX_MODEL_CHARS = 200
    public static let CONTEXT_RANGE = (1_000, 10_000_000)
    /// cloud_llm.AUTH_HEADERS.
    public static let AUTH_HEADERS = ["auto", "bearer", "api-key"]

    /// A cloud provider (providers.Provider), without what only its Settings card says.
    public struct Provider: Sendable {
        public let id: String
        public let label: String
        public let uses: [String]
        /// "required", "optional" (only a gateway on this Mac may do without) or "none".
        public let key: String
        /// The default; nil: the provider has no endpoint to set.
        public let endpoint: String?
        /// The default; "" when the user has to name one.
        public let model: String
        /// The default context window (0: not a language model).
        public let contextTokens: Int
    }

    public static let providers: [Provider] = [
        Provider(id: "anthropic", label: "Anthropic API", uses: [LANGUAGE_MODEL], key: "required",
                 endpoint: "https://api.anthropic.com", model: "claude-opus-5-5", contextTokens: 1_000_000),
        Provider(id: "openai", label: "OpenAI-compatible", uses: [LANGUAGE_MODEL], key: "optional",
                 endpoint: "https://api.openai.com/v1", model: "", contextTokens: 128_000),
        Provider(id: "claude-cli", label: "Claude Code CLI", uses: [LANGUAGE_MODEL], key: "none", endpoint: nil,
                 model: "sonnet", contextTokens: 200_000),
        Provider(id: "assemblyai", label: "AssemblyAI", uses: [TRANSCRIPTION], key: "required", endpoint: nil,
                 model: "universal-3-5-pro", contextTokens: 0),
        Provider(id: "soniox", label: "Soniox", uses: [TRANSCRIPTION], key: "required", endpoint: nil,
                 model: "stt-async-v5", contextTokens: 0),
        Provider(id: "mistral", label: "Mistral Voxtral", uses: [TRANSCRIPTION], key: "required", endpoint: nil,
                 model: "voxtral-mini-latest", contextTokens: 0),
        Provider(id: "openai-transcribe", label: "OpenAI-compatible transcription", uses: [TRANSCRIPTION], key: "optional",
                 endpoint: "https://api.openai.com/v1", model: "whisper-1", contextTokens: 0),
    ]

    /// A feature that uses a model (providers.FEATURES), without what it sends.
    public struct Feature: Sendable {
        public let id: String
        public let label: String
        public let uses: String
        /// Chosen on its own: local until the user picks a model for it, never config.toml's [notes].engine.
        public let own: Bool
    }

    public static let features: [Feature] = [
        Feature(id: "notes", label: "Notes", uses: LANGUAGE_MODEL, own: false),
        Feature(id: "projects", label: "Projects", uses: LANGUAGE_MODEL, own: false),
        Feature(id: "coach", label: "Best next question", uses: LANGUAGE_MODEL, own: true),
        Feature(id: "transcription", label: "Transcription", uses: TRANSCRIPTION, own: false),
    ]

    /// A local model offered in Settings: what it needs while writing and how much it reads at once.
    public struct LocalModel: Sendable {
        public let label: String
        public let memoryGB: Double
        public let contextTokens: Int
        public let runningGB: Int
        public let note: String
    }

    public static let DEFAULT_LOCAL_MODEL = ModelCatalog.GEMMA
    /// Free memory a local model needs to write notes, in GB; a model not listed gets the most (`NOTES_MEMORY_GB`).
    public static let MODEL_MEMORY_GB: [(String, Double)] = [
        ("mlx-community/gemma-4-12B-it-OptiQ-4bit", 14.0),
        ("mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit", 20.0),
    ]
    public static let NOTES_MEMORY_GB = 20.0

    public static let LOCAL_MODELS: [(String, LocalModel)] = [
        ("mlx-community/gemma-4-12B-it-OptiQ-4bit",
         LocalModel(label: "Gemma 4 12B", memoryGB: 14.0, contextTokens: 131_072, runningGB: 10,
                    note: "The default: the most accurate on German meetings.")),
    ]
    /// A local model not listed.
    public static let LOCAL_CONTEXT_TOKENS = 131_072

    /// Settings only some providers have, with their defaults (`_EXTRA`).
    private static let extra: [(String, [(String, JSONValue)])] = [
        ("openai", [("auth", .string("auto"))]), ("openai-transcribe", [("auth", .string("auto"))]),
        ("assemblyai", [("region", .string("eu"))]), ("soniox", [("region", .string("eu"))]),
    ]

    // MARK: - The registry

    public static func provider(_ pid: String) -> Provider? { providers.first { Py.same($0.id, pid) } }
    public static func feature(_ id: String) -> Feature? { features.first { Py.same($0.id, id) } }
    public static func localModelInfo(_ repo: String) -> LocalModel? { LOCAL_MODELS.first { Py.same($0.0, repo) }?.1 }

    /// Every provider's label by id, in the registry's order.
    public static var providerLabels: PyDict<String> { PyDict(providers.map { ($0.id, $0.label) }) }

    /// The provider's label for a choice; nil for "local", "pending" or no provider.
    public static func label(choice: String) -> String? { provider(choice)?.label }

    /// The providers `feature` can use: language models or transcription services (a feature not known: language models).
    public static func forFeature(_ feature: String) -> [String] {
        let uses = self.feature(feature)?.uses ?? LANGUAGE_MODEL
        return providers.filter { $0.uses.contains(uses) }.map(\.id)
    }

    // MARK: - Choices

    /// config.toml's choice, for a feature never chosen in Settings; local for a feature chosen on its own.
    public static func defaultChoice(feature: String?, config: Config) -> String {
        if let feature, self.feature(feature)?.own == true { return LOCAL }
        return config.notesEngine == "claude" ? "claude-cli" : LOCAL
    }

    /// `providers.choice`: "local" or the provider the user chose for `feature`; `default` when they never chose. A saved
    /// value that is no choice means local: never a cloud nobody picked.
    public static func choice(feature: String, default fallback: String, stores: StorePaths = .current()) -> String {
        guard case .object(let engines)? = SettingsFile.readRaw(stores: stores)["engines"],
              let value = engines.last(where: { Py.same($0.0, feature) })?.1 else { return fallback }
        guard case .string(let chosen) = value else { return LOCAL }
        if Py.same(chosen, PENDING) && self.feature(feature)?.uses == LANGUAGE_MODEL { return PENDING }
        return Py.same(chosen, LOCAL) || forFeature(feature).contains(where: { Py.same($0, chosen) }) ? chosen : LOCAL
    }

    /// The choice for `feature` and the meetings it is about: pending stays pending; a meeting kept on this Mac makes a
    /// cloud choice local.
    public static func choiceFor(feature: String, folders: [URL] = [], config: Config,
                                 stores: StorePaths = .current()) -> String {
        let chosen = choice(feature: feature, default: defaultChoice(feature: feature, config: config), stores: stores)
        if Py.same(chosen, PENDING) { return chosen }
        if !Py.same(chosen, LOCAL) && folders.contains(where: LocalOnly.isLocalOnly) { return LOCAL }
        return chosen
    }

    /// The local model: the one saved in Settings when it is still offered, else config.toml's.
    public static func localModel(config: Config, stores: StorePaths = .current()) -> String {
        if case .string(let saved)? = SettingsFile.readRaw(stores: stores)["local_model"], localModelInfo(saved) != nil {
            return saved
        }
        return config.notesLocalModel
    }

    /// config.toml's model for the Claude Code CLI (`[notes].model`); nil for every other provider.
    public static func providerDefaults(config: Config, pid: String) -> PyDict<JSONValue>? {
        Py.same(pid, "claude-cli") ? PyDict([("model", .string(config.notesModel))]) : nil
    }

    /// `notes.notes_memory_gb(repo)`: the local model's need while writing.
    public static func notesMemoryGB(_ repo: String) -> Double {
        MODEL_MEMORY_GB.first { Py.same($0.0, repo) }?.1 ?? NOTES_MEMORY_GB
    }

    /// Free memory `feature` needs for `folder`: the local model's (the notes' gate), none for a cloud model.
    public static func memoryGB(feature: String, folder: URL? = nil, config: Config, stores: StorePaths = .current()) -> Double {
        guard Py.same(choiceFor(feature: feature, folders: folder.map { [$0] } ?? [], config: config, stores: stores), LOCAL)
        else { return 0.0 }
        return notesMemoryGB(localModel(config: config, stores: stores))
    }

    // MARK: - A provider's settings

    public struct NoProvider: Error, CustomStringConvertible {
        public let description: String
    }

    /// The provider's endpoint, model and context window (and auth or region): as saved in settings.json when the value
    /// passes the checks, else `defaults`, else the provider's own. Keys are never read.
    public static func settingsOf(_ pid: String, defaults: PyDict<JSONValue>? = nil,
                                  stores: StorePaths = .current()) throws -> PyDict<JSONValue> {
        guard let p = provider(pid) else { throw NoProvider(description: "no provider \(MyNotes.pyRepr(.string(pid)))") }
        var out = PyDict<JSONValue>([("model", .string(p.model)), ("context_tokens", .int(p.contextTokens))]
                                    + (extra.first { Py.same($0.0, pid) }?.1 ?? []))
        if let endpoint = p.endpoint { out["endpoint"] = .string(endpoint) }
        for (k, v) in defaults ?? PyDict() where out[k] != nil { out[k] = v }
        for (k, v) in stored(pid, stores: stores) where out[k] != nil { out[k] = v }
        return out
    }

    /// What the user saved for `pid`, the values that pass the checks (`_stored`).
    public static func stored(_ pid: String, stores: StorePaths) -> PyDict<JSONValue> {
        var out = PyDict<JSONValue>()
        guard case .object(let every)? = SettingsFile.readRaw(stores: stores)["providers"],
              case .object(let mine)? = every.last(where: { Py.same($0.0, pid) })?.1 else { return out }
        for (name, value) in PyDict(mine) {  // a duplicate key: the last value at the first place
            let checked: JSONValue?
            switch name {
            case "endpoint": checked = checkEndpoint(value).map { .string($0) }
            case "model": checked = checkModel(value).map { .string($0) }
            case "context_tokens": checked = checkContext(value).map { .int($0) }
            case "auth": checked = value.stringValue.flatMap { v in AUTH_HEADERS.contains { Py.same($0, v) } ? value : nil }
            case "region": checked = value.stringValue.flatMap { v in REGIONS.contains { Py.same($0, v) } ? value : nil }
            default: continue
            }
            if let checked { out[name] = checked }
        }
        return out
    }

    /// `_check_model`: one line of text, at most 200 characters once stripped; nil where Python raises.
    public static func checkModel(_ value: JSONValue) -> String? {
        guard case .string(let s) = value else { return nil }
        let stripped = Py.strip(s)
        guard !stripped.isEmpty, stripped.unicodeScalars.count <= MAX_MODEL_CHARS,
              !s.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else { return nil }
        return stripped
    }

    /// `_check_context`: an int (not a bool) in CONTEXT_RANGE.
    public static func checkContext(_ value: JSONValue) -> Int? {
        guard case .int(let n) = value, n >= CONTEXT_RANGE.0, n <= CONTEXT_RANGE.1 else { return nil }
        return n
    }

    /// `_check_endpoint`: an https:// URL (http:// only for a gateway on this Mac or the local network:
    /// `isLocalNetwork`), no user or password, no fragment, stripped; nil where Python raises (urllib.parse.urlsplit's
    /// own ValueErrors included).
    public static func checkEndpoint(_ value: JSONValue) -> String? {
        guard case .string(let raw) = value, endpointProblem(value) == nil else { return nil }
        return Py.strip(raw)
    }

    /// `_check_endpoint`'s refusal; nil for an endpoint that passes.
    public static func endpointProblem(_ value: JSONValue) -> String? {
        guard case .string(let raw) = value else { return "the endpoint must be a URL" }
        let notHTTPS = "the endpoint must be an https:// URL (http:// only for a gateway on this Mac or your local network)"
        guard let parts = URLSplit(Py.strip(raw)) else { return notHTTPS }
        guard let host = parts.hostname, !host.isEmpty, parts.scheme == "https" || parts.scheme == "http",
              parts.scheme != "http" || isLocalNetwork(host) else { return notHTTPS }
        if parts.username?.isEmpty == false || parts.password?.isEmpty == false {
            return "put the key in the key field, not in the endpoint"
        }
        if !parts.fragment.isEmpty { return "the endpoint must not have a #fragment" }
        return nil
    }

    /// Names that only a local network resolves (a gateway on the LAN: `gpu-box.local`, `llm.lan`, `nas.home.arpa`).
    public static let LOCAL_SUFFIXES = [".local", ".lan", ".home.arpa"]

    /// A host plain http:// may go to (Python allowed only this Mac's): this Mac (`localhost`, 127.0.0.0/8, ::1), a
    /// local-network name (`LOCAL_SUFFIXES`) or a private address (10/8, 172.16/12, 192.168/16, fc00::/7, fe80::/10).
    /// `host` is urlsplit's hostname (lowered, no brackets). Every other host is https only.
    public static func isLocalNetwork(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" { return true }
        if LOCAL_SUFFIXES.contains(where: { name.hasSuffix($0) && name.count > $0.count }) { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, name, &v4) == 1 {
            let a = UInt32(bigEndian: v4.s_addr)
            return a >> 24 == 127 || a >> 24 == 10 || a >> 20 == 0xAC1 || a >> 16 == 0xC0A8
        }
        let address = name.split(separator: "%", maxSplits: 1).first.map(String.init) ?? name  // fe80::1%en0
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        return loopback || bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80)
    }

    /// `urlsplit(url).hostname`: lowered; nil when there is none (or the URL does not split).
    public static func hostname(_ url: String) -> String? { URLSplit(url)?.hostname }
}

/// `urllib.parse.urlsplit` of Python 3.13 (allow_fragments, no default scheme) and the result's username, password and
/// hostname; nil where it raises ValueError. Strings are handled by code points.
struct URLSplit {
    let scheme: String
    let netloc: String
    let fragment: String

    init?(_ text: String) {
        var url = Array(text.unicodeScalars)
        while let first = url.first, first.value <= 0x20 { url.removeFirst() }  // _WHATWG_C0_CONTROL_OR_SPACE
        url.removeAll { $0 == "\t" || $0 == "\r" || $0 == "\n" }
        var scheme: [Unicode.Scalar] = [], netloc: [Unicode.Scalar] = [], fragment: [Unicode.Scalar] = []
        if let i = url.firstIndex(of: ":"), i > 0, url[0].isASCII, url[0].properties.isAlphabetic,
           url[..<i].allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "+-.".unicodeScalars.contains($0)) }) {
            scheme = Array(Py.strLower(String(String.UnicodeScalarView(url[..<i]))).unicodeScalars)
            url = Array(url[(i + 1)...])
        }
        if url.starts(with: "//".unicodeScalars) {
            let rest = url[2...]
            let end = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? url.endIndex
            netloc = Array(url[2..<end])
            url = Array(url[end...])
            let open = netloc.contains("["), close = netloc.contains("]")
            if open != close { return nil }
            if open && close && !URLSplit.bracketedNetlocOK(netloc) { return nil }
        }
        if let h = url.firstIndex(of: "#") { fragment = Array(url[(h + 1)...]) }
        guard URLSplit.netlocOK(netloc) else { return nil }
        self.scheme = String(String.UnicodeScalarView(scheme))
        self.netloc = String(String.UnicodeScalarView(netloc))
        self.fragment = String(String.UnicodeScalarView(fragment))
    }

    private static func s(_ a: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(a)) }

    /// `str.rpartition(sep)` / `partition(sep)` on one scalar: (head, found, tail).
    private static func rpartition(_ a: [Unicode.Scalar], _ sep: Unicode.Scalar) -> ([Unicode.Scalar], Bool, [Unicode.Scalar]) {
        guard let i = a.lastIndex(of: sep) else { return ([], false, a) }
        return (Array(a[..<i]), true, Array(a[(i + 1)...]))
    }

    private static func partition(_ a: [Unicode.Scalar], _ sep: Unicode.Scalar) -> ([Unicode.Scalar], Bool, [Unicode.Scalar]) {
        guard let i = a.firstIndex(of: sep) else { return (a, false, []) }
        return (Array(a[..<i]), true, Array(a[(i + 1)...]))
    }

    /// `_check_bracketed_netloc`.
    private static func bracketedNetlocOK(_ netloc: [Unicode.Scalar]) -> Bool {
        let hostAndPort = rpartition(netloc, "@").2
        let (before, open, bracketed) = partition(hostAndPort, "[")
        var host: [Unicode.Scalar]
        if open {
            if !before.isEmpty { return false }
            let (h, _, port) = partition(bracketed, "]")
            if !port.isEmpty && port.first != ":" { return false }
            host = h
        } else {
            host = partition(hostAndPort, ":").0
        }
        return bracketedHostOK(host)
    }

    /// `_check_bracketed_host`: an IPvFuture (`v<hex>.<anything>`) or an IPv6 address (with a zone).
    private static func bracketedHostOK(_ host: [Unicode.Scalar]) -> Bool {
        if host.first == "v" {
            guard let dot = host.firstIndex(of: "."), dot > 1, dot + 1 < host.count else { return false }
            return host[1..<dot].allSatisfy { $0.isASCII && $0.properties.isASCIIHexDigit }
                && !host[(dot + 1)...].contains("\n")  // `.+` before `\Z`: no newline
        }
        let (address, scoped, zone) = partition(host, "%")
        if scoped && (zone.isEmpty || zone.contains("%")) { return false }
        guard address.allSatisfy(\.isASCII) else { return false }
        var out = in6_addr()
        return inet_pton(AF_INET6, String(String.UnicodeScalarView(address)), &out) == 1
    }

    /// `_checknetloc`: a netloc that is not ASCII must not gain "/", "?", "#", "@" or ":" under NFKC.
    private static func netlocOK(_ netloc: [Unicode.Scalar]) -> Bool {
        if netloc.isEmpty || netloc.allSatisfy(\.isASCII) { return true }
        let n = String(String.UnicodeScalarView(netloc.filter { !"@:#?".unicodeScalars.contains($0) }))
        let normalized = n.precomposedStringWithCompatibilityMapping
        if normalized.unicodeScalars.elementsEqual(n.unicodeScalars) { return true }
        return !normalized.unicodeScalars.contains { "/?#@:".unicodeScalars.contains($0) }
    }

    /// `_userinfo`.
    var username: String? {
        let (info, has, _) = URLSplit.rpartition(Array(netloc.unicodeScalars), "@")
        return has ? URLSplit.s(URLSplit.partition(info, ":").0[...]) : nil
    }

    var password: String? {
        let (info, has, _) = URLSplit.rpartition(Array(netloc.unicodeScalars), "@")
        guard has else { return nil }
        let (_, hasPassword, password) = URLSplit.partition(info, ":")
        return hasPassword ? URLSplit.s(password[...]) : nil
    }

    /// `hostname`: lowered (a zone after "%" kept as is); nil when empty.
    var hostname: String? {
        let hostinfo = URLSplit.rpartition(Array(netloc.unicodeScalars), "@").2
        let (_, open, bracketed) = URLSplit.partition(hostinfo, "[")
        let host = open ? URLSplit.partition(bracketed, "]").0 : URLSplit.partition(hostinfo, ":").0
        guard !host.isEmpty else { return nil }
        let (name, percent, zone) = URLSplit.partition(host, "%")
        return Py.strLower(URLSplit.s(name[...])) + (percent ? "%" + URLSplit.s(zone[...]) : "")
    }
}
