// The engine a feature runs on (llm.py `engine`, `_cloud`, `_checked`): the model the user chose for it in Settings,
// local unless a cloud provider was chosen, local whenever a meeting it is about is kept on this Mac. A prompt that
// would not fit the model's context window is refused before anything is sent. Every cloud call is written to the
// access log, without the key; a log that can't be written never costs the answer.
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

public struct LMEngine {
    /// "local" or the provider id.
    public let choice: String
    /// What the user reads: "Gemma 4 12B on this Mac", "Anthropic API".
    public let label: String
    public let model: String
    /// The meeting's content leaves this Mac.
    public let cloud: Bool
    public let contextTokens: Int
    /// The room kept for the answer in the context window.
    public let reserve: Int
    let shortLabel: String
    let runner: LanguageModel
    /// Writes one access-log line for a cloud call: (ok, error, seconds, chars).
    let logged: ((Bool, String?, Double, Int) -> Void)?

    /// The answer to `prompt`; `ContextTooLong` before anything is sent when it would not fit.
    public func run(_ prompt: String, schema: JSONValue, parse: @escaping AnswerParser) async throws -> JSONValue {
        let chars = prompt.unicodeScalars.count + PythonJSON.dumps(schema).unicodeScalars.count
        try ContextCheck.fits(chars: chars, label: shortLabel, model: model, context: contextTokens, reserve: reserve)
        let started = Date()
        do {
            let out = try await runner.generate(prompt: prompt, schema: schema, parse: parse)
            logged?(true, nil, Date().timeIntervalSince(started), chars)
            return out
        } catch {
            logged?(false, Asking.message(error), Date().timeIntervalSince(started), chars)
            throw error
        }
    }

    /// The engine for `feature` and the `meetings` it is about. `EngineUnavailable` says why the chosen model can't
    /// run (it never falls back to another one). `local` makes the local runner; `fake` (tests) answers instead of
    /// whichever model was chosen, which is still named and checked as the user chose it.
    public static func make(feature: String, meetings: [URL] = [], settings: ProviderSettings,
                            http: HTTPClient = HTTPClient(), local: LocalModels.Factory = LocalModels.unavailable,
                            fake: LanguageModel? = nil) throws -> LMEngine {
        let choice = EngineChoice.for(feature: feature, meetings: meetings, settings: settings)
        switch choice {
        case .unavailable(let why):
            throw EngineUnavailable(why)
        case .local(let repo):
            let info = ModelChoice.localModelInfo(repo)
            let label = info?.label ?? repo
            return LMEngine(choice: ModelChoice.LOCAL, label: "\(label) on this Mac", model: repo, cloud: false,
                            contextTokens: info?.contextTokens ?? ModelChoice.LOCAL_CONTEXT_TOKENS,
                            reserve: ContextCheck.LOCAL_RESERVE, shortLabel: label,
                            runner: try fake ?? local(repo), logged: nil)
        case .cloud, .claudeCLI:
            return try cloud(choice.choice!, feature: feature, meetings: meetings.map(\.lastPathComponent),
                             settings: settings, http: http, fake: fake)
        }
    }

    /// A cloud provider's engine (llm.py `_cloud`), the Claude Code CLI's too.
    static func cloud(_ pid: String, feature: String, meetings: [String], settings: ProviderSettings, http: HTTPClient,
                      fake: LanguageModel?) throws -> LMEngine {
        guard let p = ModelChoice.provider(pid) else { throw EngineUnavailable("no provider \(Py.repr(.string(pid)))") }
        let s = try settings.settingsOf(p.id, defaults: settings.defaults(p.id))
        let model = s["model"].map { Py.str($0) } ?? p.model
        let context: Int
        if case .int(let n)? = s["context_tokens"] { context = n } else { context = p.contextTokens }
        let endpoint = s["endpoint"]?.stringValue ?? ""
        var key: String?
        let host: String
        let runner: LanguageModel
        switch p.id {
        case "claude-cli":
            guard let claude = settings.claude() else {
                throw EngineUnavailable("\(p.label): Claude Code CLI (`claude`) not found on this Mac. \(EngineChoice.SETTINGS_HINT)")
            }
            host = "claude CLI"
            runner = ClaudeCLIModel(claude: claude, model: model)
        case "anthropic":
            key = settings.apiKey(p.id)
            host = ModelChoice.hostname(endpoint) ?? endpoint
            var r = AnthropicRunner(endpoint: endpoint, model: model, apiKey: key)
            r.name = p.label
            r.http = http
            runner = CloudModel(.anthropic(r))
        case "openai":
            key = settings.apiKey(p.id)
            host = ModelChoice.hostname(endpoint) ?? endpoint
            var r = OpenAIRunner(endpoint: endpoint, model: model, apiKey: key, auth: s["auth"]?.stringValue ?? "auto")
            r.name = p.label
            r.http = http
            runner = CloudModel(.openAI(r))
        default:  // a provider for something else (transcription)
            throw EngineUnavailable("\(p.label) is not a language model")
        }
        let stores = settings.stores, secret = key
        let log: (Bool, String?, Double, Int) -> Void = { ok, error, seconds, chars in
            let entry = AccessLog.Entry(provider: p.id, host: host, model: model, feature: feature, meetings: meetings,
                                        chars: chars, ok: ok, seconds: seconds,
                                        error: error.map { HTTPClient.redact($0, key: secret) })
            do {
                try AccessLog.record(entry, stores: stores)
            } catch {
                FileHandle.standardError.write(Data("warning: could not write the access log (\(p.id) \(feature)): \(type(of: error))\n".utf8))
            }
        }
        return LMEngine(choice: p.id, label: p.label, model: model, cloud: true, contextTokens: context,
                        reserve: p.id == "claude-cli" ? ContextCheck.CLI_RESERVE : ContextCheck.CLOUD_RESERVE,
                        shortLabel: p.label, runner: fake ?? runner, logged: log)
    }
}
