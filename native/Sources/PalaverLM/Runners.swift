// The runners behind `LanguageModel`: the cloud APIs and the Claude Code CLI (PalaverCloud's runners, which the
// Settings page's Test button uses too), and a fake with canned answers for tests. The local model (MLX) comes with
// PalaverMLX; until it is built in, a local engine says so instead of running.
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

/// The Anthropic Messages API or an OpenAI-compatible endpoint (cloud_llm.py's runners): one request per ask, a broken
/// answer asked for once more.
public struct CloudModel: LanguageModel {
    public enum API {
        case anthropic(AnthropicRunner)
        case openAI(OpenAIRunner)
    }

    public let api: API

    public init(_ api: API) { self.api = api }

    public func generate(prompt: String, schema: JSONValue, parse: @escaping AnswerParser) async throws -> JSONValue {
        switch api {
        case .anthropic(let runner): return try await runner.run(prompt, schema: schema, parse: parse)
        case .openAI(let runner): return try await runner.run(prompt, schema: schema, parse: parse)
        }
    }
}

/// Claude through the Claude Code CLI (notes.py `claude_runner`): the CLI checks the answer against the schema; the
/// feature's parser then shapes it as for every other model, and a broken one is asked for once more.
public struct ClaudeCLIModel: LanguageModel {
    public var runner: ClaudeCLIRunner

    public init(claude: String, model: String, timeout: Double = 600) {
        runner = ClaudeCLIRunner(claude: claude, model: model)
        runner.timeout = timeout
    }

    public func generate(prompt: String, schema: JSONValue, parse: @escaping AnswerParser) async throws -> JSONValue {
        try await Asking.parsed(parse: parse, fail: { LMError("Claude Code CLI did not return a valid answer: \($0)") }) {
            PythonJSON.dumps(try runner.run(prompt, schema: schema), ensureAscii: false)
        }
    }
}

/// The local model on this Mac. It runs through MLX (PalaverMLX); a build without it says so plainly.
public enum LocalModels {
    public typealias Factory = (_ repo: String) throws -> LanguageModel

    public static let NOT_BUILT = "The local model can't run in this build of Palaver yet; choose a cloud model in "
        + "Settings → Language model."

    /// A build without the local runner.
    public static let unavailable: Factory = { _ in throw EngineUnavailable(NOT_BUILT) }
}

/// A model with canned answers, for tests: each ask takes the next answer (the last one is kept for every ask after
/// it); an `Error` is thrown instead of answered. Every prompt it was asked is kept.
public final class FakeModel: LanguageModel, @unchecked Sendable {
    public enum Answer {
        case text(String)
        case json(JSONValue)
        case failure(Error)
    }

    public struct Asked {
        public let prompt: String
        public let schema: JSONValue
        public let system: String
    }

    private let lock = NSLock()
    private var answers: [Answer]
    private var given = 0
    private var _asked: [Asked] = []
    public let name: String

    public init(_ answers: [Answer], name: String = "The fake model") {
        precondition(!answers.isEmpty, "a fake model needs an answer")
        self.answers = answers
        self.name = name
    }

    public convenience init(json answers: JSONValue..., name: String = "The fake model") {
        self.init(answers.map { .json($0) }, name: name)
    }

    public var asked: [Asked] { lock.withLock { _asked } }

    private func next(_ prompt: String, _ schema: JSONValue) -> Answer {
        lock.withLock {
            _asked.append(Asked(prompt: prompt, schema: schema, system: Asking.system(schema)))
            let answer = answers[min(given, answers.count - 1)]
            given += 1
            return answer
        }
    }

    public func generate(prompt: String, schema: JSONValue, parse: @escaping AnswerParser) async throws -> JSONValue {
        try await Asking.parsed(parse: parse, fail: { LMError("\(self.name) did not return a valid answer: \($0)") }) {
            switch next(prompt, schema) {
            case .text(let text): return text
            case .json(let value): return PythonJSON.dumps(value, ensureAscii: false)
            case .failure(let error): throw error
            }
        }
    }
}
