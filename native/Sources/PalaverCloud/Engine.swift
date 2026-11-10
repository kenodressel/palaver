// Which language model runs a feature, and whether a prompt fits it (palaver/llm.py `engine`, `_cloud`, `_fits`).
//
// - Local is the default; config.toml's `[notes].engine = "claude"` keeps meaning the Claude Code CLI.
// - A meeting kept on this Mac never goes to a cloud model: every feature that touches it runs locally.
// - When the chosen provider can't run (no key, no model name, no CLI) the answer is `unavailable` with the reason. It
//   never falls back to another model, and certainly not to a cloud one.
// - Each engine has a context window; a prompt that would not fit is refused before it is sent, never cut short.
import Foundation
import PalaverCore
import PalaverDomain

/// The chosen model can't run (`llm.Unavailable`); the message says why.
public struct EngineUnavailable: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// The prompt would not fit the model's context window (`llm.ContextTooLong`).
public struct ContextTooLong: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum EngineChoice: Equatable, Sendable {
    case local(model: String)
    case cloud(provider: String)
    case claudeCLI
    case unavailable(String)

    public static let SETTINGS_HINT = "Change it in Settings → Language model."
    public static let PENDING_TEXT = "No model yet: set up a cloud model in Settings → Language model "
        + "(this Mac is too small for the local one)."

    /// The engine for `feature` and the `meetings` it is about.
    public static func `for`(feature: String, meetings: [URL] = [], settings: ProviderSettings) -> EngineChoice {
        let chosen = ModelChoice.choiceFor(feature: feature, folders: meetings, config: settings.config, stores: settings.stores)
        if chosen == ModelChoice.PENDING { return .unavailable(PENDING_TEXT) }
        if chosen == ModelChoice.LOCAL {
            return .local(model: ModelChoice.localModel(config: settings.config, stores: settings.stores))
        }
        return provider(chosen, settings: settings)
    }

    /// The cloud provider `pid` (or the Claude Code CLI) when it can run now.
    public static func provider(_ pid: String, settings: ProviderSettings) -> EngineChoice {
        guard let p = ModelChoice.provider(pid) else { return .unavailable("no provider \(Py.repr(.string(pid)))") }
        do {
            if let trouble = try settings.problem(p.id, defaults: settings.defaults(p.id)) {
                return .unavailable("\(p.label): \(trouble). \(SETTINGS_HINT)")
            }
        } catch {
            return .unavailable(String(describing: error))
        }
        guard p.uses.contains(ModelChoice.LANGUAGE_MODEL) else { return .unavailable("\(p.label) is not a language model") }
        return p.id == "claude-cli" ? .claudeCLI : .cloud(provider: p.id)
    }

    /// "local" or the provider id.
    public var choice: String? {
        switch self {
        case .local: return ModelChoice.LOCAL
        case .cloud(let pid): return pid
        case .claudeCLI: return "claude-cli"
        case .unavailable: return nil
        }
    }

    /// The label, model and context window as the refusal names them.
    public func window(settings: ProviderSettings) -> (label: String, model: String, context: Int)? {
        switch self {
        case .local(let repo):
            let info = ModelChoice.localModelInfo(repo)
            return (info?.label ?? repo, repo, info?.contextTokens ?? ModelChoice.LOCAL_CONTEXT_TOKENS)
        case .cloud, .claudeCLI:
            guard let pid = choice, let p = ModelChoice.provider(pid),
                  let s = try? settings.settingsOf(pid, defaults: settings.defaults(pid)) else { return nil }
            let model = s["model"].map { Py.str($0) } ?? p.model
            return (p.label, model, s["context_tokens"].flatMap { if case .int(let n) = $0 { return n } else { return nil } }
                ?? p.contextTokens)
        case .unavailable:
            return nil
        }
    }
}

public enum ContextCheck {
    /// Characters per token, on the low side: German, names and timestamps take more tokens than English prose.
    /// Overestimating refuses a borderline meeting; underestimating would let it be cut off.
    public static let CHARS_PER_TOKEN = 3.0
    /// Room kept for the answer: the local model's (notes.LOCAL_MAX_TOKENS), a cloud model's (MAX_OUTPUT_TOKENS), none
    /// for the Claude Code CLI.
    public static let LOCAL_RESERVE = 4096
    public static let CLOUD_RESERVE = 32_000
    public static let CLI_RESERVE = 0

    public static func estimateTokens(chars: Int) -> Int { Int((Double(chars) / CHARS_PER_TOKEN).rounded(.up)) }

    public static func reserve(_ engine: EngineChoice) -> Int {
        switch engine {
        case .local: return LOCAL_RESERVE
        case .claudeCLI: return CLI_RESERVE
        default: return CLOUD_RESERVE
        }
    }

    /// Refuses (`ContextTooLong`) what would not fit `engine` with room for its answer; an unavailable engine says so.
    public static func fits(chars: Int, engine: EngineChoice, settings: ProviderSettings) throws {
        if case .unavailable(let why) = engine { throw EngineUnavailable(why) }
        guard let w = engine.window(settings: settings) else { return }
        try fits(chars: chars, label: w.label, model: w.model, context: w.context, reserve: reserve(engine))
    }

    public static func fits(chars: Int, label: String, model: String, context: Int, reserve: Int) throws {
        let tokens = estimateTokens(chars: chars)
        guard tokens + reserve > context else { return }
        throw ContextTooLong("This is about \(grouped(tokens)) tokens, and \(label) (\(model)) reads at most "
                             + "\(grouped(context)) with room for its answer. Choose a model with a larger context window. "
                             + EngineChoice.SETTINGS_HINT)
    }

    /// `f"{n:,}"`.
    static func grouped(_ n: Int) -> String {
        let digits = String(n.magnitude)
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return (n < 0 ? "-" : "") + out
    }
}
