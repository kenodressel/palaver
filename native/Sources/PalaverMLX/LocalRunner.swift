// The local model on this Mac (notes.py `local_runner`): the model the user chose (Gemma 4 12B by default) read in place
// from the Hugging Face cache, run through MLX (mlx-swift-lm), asked as Python's mlx_lm path asked it: the repo's chat
// template with thinking off, the schema in the system text, temperature 0.2, at most 4096 tokens, one more ask when the
// answer doesn't parse. The model is loaded once per process (notes, then projects) and leaves with it.
//
// Before anything is loaded: MLX's cache limit (1 GB), MLX's memory limit at the notes budget, and the footprint
// watchdog (the daemon's rule: low free memory while over the budget, or the ceiling; LocalModel.swift).
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import PalaverCloud
import PalaverCore
import PalaverDomain
import PalaverLM
import Tokenizers

public enum MLXLocal {
    /// The factory palaver-lm gives its features: the snapshot is looked up at once (a model that is not here says so
    /// and nothing runs); the model loads at its first ask, under the model lock.
    /// `notesGB`: config.toml's `[memory] notes_gb`, which raises the budget (LocalModel.limits).
    public static func factory(stores: StorePaths, notesGB: Double? = nil,
                               env: [String: String] = ProcessInfo.processInfo.environment) -> LocalModels.Factory {
        { repo in
            guard let folder = LocalModel.snapshot(repo, cache: HFCache(stores: stores)) else {
                throw EngineUnavailable(LocalModel.notDownloaded(repo))
            }
            return MLXModel(repo: repo, folder: folder, limits: LocalModel.limits(repo, notesGB: notesGB, env: env))
        }
    }

    /// `$PALAVER_MLX_METALLIB`: MLX's shaders to use (a `swift build` of palaver-lm has none of its own).
    public static let METALLIB_ENV = "PALAVER_MLX_METALLIB"

    /// MLX's Metal shaders for this palaver-lm: `$PALAVER_MLX_METALLIB`, else a release bundle's
    /// Contents/Resources/mlx.metallib, else what xcodebuild leaves beside the program (mlx.metallib or
    /// mlx-swift_Cmlx.bundle). nil: none (a `swift build`), and the local model can't run.
    static func metallib(executable: URL? = Bundle.main.executableURL,
                         env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fm = FileManager.default
        if let given = env[METALLIB_ENV], !given.isEmpty { return URL(fileURLWithPath: given) }
        guard let dir = executable?.resolvingSymlinksInPath().deletingLastPathComponent() else { return nil }
        return [dir.deletingLastPathComponent().appendingPathComponent("Resources/mlx.metallib"),
                dir.appendingPathComponent("mlx.metallib"),
                dir.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")]
            .first { fm.fileExists(atPath: $0.path) }
    }

    /// Points MLX at the shaders before anything runs on the GPU; without them MLX would stop the process, so this
    /// says what to do instead.
    static func useMetallib(executable: URL? = Bundle.main.executableURL,
                            env: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let lib = metallib(executable: executable, env: env) else {
            throw LMError("this palaver-lm was built without MLX's Metal shaders, so the local model can't run: "
                          + "build it with `make lm`, or set \(METALLIB_ENV)")
        }
        GPU.metallib = lib
    }
}

/// What the last generation did (the smoke test reports it).
public struct LocalGenerationInfo: Sendable {
    public let promptTokens: Int
    public let generatedTokens: Int
    public let tokensPerSecond: Double
    public let promptSeconds: Double
}

/// One local model; its weights are shared by every `MLXModel` of the same snapshot in this process.
public final class MLXModel: PalaverLM.LanguageModel, @unchecked Sendable {
    public let repo: String
    public let folder: URL
    public let limits: LocalModel.Limits
    public var maxTokens = LocalModel.MAX_TOKENS
    private let lock = NSLock()
    private var _last: LocalGenerationInfo?

    public init(repo: String, folder: URL, limits: LocalModel.Limits) {
        self.repo = repo
        self.folder = folder
        self.limits = limits
    }

    public var lastGeneration: LocalGenerationInfo? { lock.withLock { _last } }

    public func generate(prompt: String, schema: PalaverCore.JSONValue, parse: @escaping AnswerParser) async throws -> PalaverCore.JSONValue {
        let container = try await Loaded.shared.container(repo: repo, folder: folder, limits: limits)
        let messages = LocalModel.messages(prompt: prompt, schema: schema)
        return try await Asking.parsed(parse: parse, fail: { LMError("the local model did not return a valid answer: \($0)") }) {
            try await self.ask(container, messages)
        }
    }

    /// One answer: the chat template's tokens through the model, the text it wrote.
    func ask(_ container: ModelContainer, _ messages: [[String: String]]) async throws -> String {
        var parameters = GenerateParameters(maxTokens: maxTokens, temperature: LocalModel.TEMPERATURE)
        parameters.prefill = PrefillParameters(stepSize: LocalModel.PREFILL_STEP)
        let template = LocalModel.TEMPLATE_CONTEXT as [String: any Sendable]
        let stream: AsyncStream<Generation> = try await container.perform { context in
            let tokens = try context.tokenizer.applyChatTemplate(
                messages: messages.map { $0 as [String: any Sendable] }, tools: nil, additionalContext: template)
            return try MLXLMCommon.generate(input: LMInput(tokens: MLXArray(tokens)), parameters: parameters, context: context)
        }
        var text = ""
        for await piece in stream {
            switch piece {
            case .chunk(let chunk): text += chunk
            case .info(let info):
                lock.withLock {
                    _last = LocalGenerationInfo(promptTokens: info.promptTokenCount, generatedTokens: info.generationTokenCount,
                                                tokensPerSecond: info.generateTime > 0 ? Double(info.generationTokenCount) / info.generateTime : 0,
                                                promptSeconds: info.promptTime)
                }
            default: break
            }
        }
        return text
    }
}

/// The models this process loaded (one in practice): loaded at the first ask with the memory caps in place.
actor Loaded {
    static let shared = Loaded()
    private var containers: [String: ModelContainer] = [:]
    private var watchdog: FootprintWatchdog?

    func container(repo: String, folder: URL, limits: LocalModel.Limits) async throws -> ModelContainer {
        if let found = containers[folder.path] { return found }
        try MLXLocal.useMetallib()
        limitMemory(limits)
        let container: ModelContainer
        do {
            container = try await withError { _ in
                try await LLMModelFactory.shared.loadContainer(from: folder, using: TransformersTokenizerLoader())
            }
        } catch {
            throw LMError("\(repo) can't be loaded by this Palaver's local runner (\(error)). "
                          + "Choose another model in Settings → Language model.")
        }
        containers[folder.path] = container
        return container
    }

    /// MLX's cache limit and memory limit, and the watchdog over the whole process (started once, at the first load).
    private func limitMemory(_ limits: LocalModel.Limits) {
        Memory.cacheLimit = LocalModel.CACHE_LIMIT_BYTES
        Memory.memoryLimit = limits.budget
        if watchdog == nil {
            let w = FootprintWatchdog(limits: limits)
            w.start()
            watchdog = w
        }
    }

    /// The highest footprint the watchdog saw (the smoke test reports it).
    var peakFootprint: Int { watchdog?.peak ?? physFootprint() ?? 0 }
}

/// The peak footprint of this process while the local model ran.
public func localModelPeakFootprint() async -> Int { await Loaded.shared.peakFootprint }

// MARK: - The tokenizer (swift-transformers), as mlx-swift-lm reads it

/// tokenizer.json, tokenizer_config.json and chat_template.jinja of the snapshot, through swift-transformers.
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    /// The repo's chat template with the generation prompt; a model without one is refused (never a plain-text
    /// stand-in: the notes would be worse without anyone knowing).
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw LMError("the local model has no chat template")
        }
    }
}
