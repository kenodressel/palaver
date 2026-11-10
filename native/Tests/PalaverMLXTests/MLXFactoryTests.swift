// The MLX runner without a model: what the factory does with a model that is or is not in the cache (it never loads one
// here). And the opt-in smoke test with the real Gemma, which never runs in `make test` (tools/lm_smoke.sh runs it under
// tools/memcap.sh with xcodebuild's metallib, then palaver-lm's notes of a fictional meeting).
import Foundation
import MLX
import PalaverCloud
import PalaverCore
import PalaverDomain
import PalaverLM
@testable import PalaverMLX
import Testing

func hubFolder() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-mlx-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.resolvingSymlinksInPath()
}

@Suite struct MLXFactoryTests {
    @Test func aModelThatIsNotInTheCacheSaysHowToGetIt() throws {
        let hub = hubFolder()
        let stores = StorePaths(configDir: hub.appendingPathComponent("config"), home: hub.appendingPathComponent("home"),
                                hubCache: hub)
        do {
            _ = try MLXLocal.factory(stores: stores, env: [:])(ModelCatalog.GEMMA)
            Issue.record("no error")
        } catch let error as EngineUnavailable {
            #expect(String(describing: error) == LocalModel.notDownloaded(ModelCatalog.GEMMA))
        }
    }

    @Test func aModelInTheCacheIsReadInPlaceWithItsBudgetAndNotLoadedYet() throws {
        let hub = hubFolder()
        let snap = HFCache(root: hub).snapshotDir(repo: ModelCatalog.GEMMA, revision: "de9e183868050b34bf6b4272518500ffcebf15b3")
        try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snap.appendingPathComponent("config.json"))
        try Data("w".utf8).write(to: snap.appendingPathComponent("model.safetensors"))
        let stores = StorePaths(configDir: hub.appendingPathComponent("config"), home: hub.appendingPathComponent("home"),
                                hubCache: hub)
        let made = try MLXLocal.factory(stores: stores, env: [LocalModel.BUDGET_ENV: "12"])(ModelCatalog.GEMMA)
        let model = try #require(made as? MLXModel)
        #expect(model.folder.path == snap.path && model.repo == ModelCatalog.GEMMA)
        #expect(model.limits == .init(budget: 12 << 30, ceiling: 12 << 30) && model.maxTokens == 4096)
        #expect(model.lastGeneration == nil)
    }

    @Test func mlxsShadersAreFoundInTheBundleBesideTheProgramOrWhereTheEnvironmentSays() throws {
        let app = hubFolder().appendingPathComponent("Palaver.app/Contents", isDirectory: true)
        let macos = app.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let exe = macos.appendingPathComponent("palaver-lm")
        // A swift build: none, and the run says how to get them (MLX would stop the process).
        #expect(MLXLocal.metallib(executable: exe, env: [:]) == nil)
        #expect(throws: LMError.self) { try MLXLocal.useMetallib(executable: exe, env: [:]) }
        // xcodebuild's folder: its SwiftPM bundle beside the program.
        let built = macos.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
        try FileManager.default.createDirectory(at: built.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("lib".utf8).write(to: built)
        #expect(MLXLocal.metallib(executable: exe, env: [:])?.path == built.path)
        // The release bundle: Contents/Resources/mlx.metallib comes first.
        let bundled = app.appendingPathComponent("Resources/mlx.metallib")
        try Data("lib".utf8).write(to: bundled)
        #expect(MLXLocal.metallib(executable: exe, env: [:])?.path == bundled.path)
        // The environment wins.
        #expect(MLXLocal.metallib(executable: exe, env: [MLXLocal.METALLIB_ENV: "/x/y.metallib"])?.path == "/x/y.metallib")
    }
}

/// Gemma itself: opt-in only (PALAVER_LM_SMOKE=1), under tools/memcap.sh, with xcodebuild's metallib.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PALAVER_LM_SMOKE"] == "1")) struct LocalModelSmokeTests {
    /// The repo's chat template through swift-transformers, with thinking off, gives what transformers'
    /// `apply_chat_template(..., enable_thinking=False)` gives for Gemma 4 (an empty thought channel). No weights load.
    @Test func gemmasChatTemplateRendersWithThinkingOff() async throws {
        let env = ProcessInfo.processInfo.environment
        let hub = URL(fileURLWithPath: env["PALAVER_LM_SMOKE_HUB"] ?? NSHomeDirectory() + "/.cache/huggingface/hub")
        let folder = try #require(LocalModel.snapshot(ModelCatalog.GEMMA, cache: HFCache(root: hub)))
        let tokenizer = try await TransformersTokenizerLoader().load(from: folder)
        let messages: [[String: any Sendable]] = [
            ["role": "system", "content": "Write the notes in German.\n\nAnswer with JSON."],
            ["role": "user", "content": "Valerie von Contoso: Hallo Timo."],
        ]
        let ids = try tokenizer.applyChatTemplate(messages: messages, tools: nil,
                                                  additionalContext: LocalModel.TEMPLATE_CONTEXT as [String: any Sendable])
        print("TEMPLATE ids (\(ids.count)): \(ids)")
        #expect(tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)
                == "<bos><|turn>system\nWrite the notes in German.\n\nAnswer with JSON.<turn|>\n<|turn>user\n"
                + "Valerie von Contoso: Hallo Timo.<turn|>\n<|turn>model\n<|channel>thought\n<channel|>")
        #expect(ids.count == 38 && Array(ids.prefix(4)) == [2, 105, 9731, 107])
    }

    @Test func gemmaAnswersAShortPromptWithinItsBudget() async throws {
        let env = ProcessInfo.processInfo.environment
        let metallib = try #require(env["PALAVER_MLX_METALLIB"], "PALAVER_MLX_METALLIB: xcodebuild's default.metallib")
        GPU.metallib = URL(fileURLWithPath: metallib)
        // Read in place from the user's cache (never copied, never downloaded).
        let hub = URL(fileURLWithPath: env["PALAVER_LM_SMOKE_HUB"] ?? NSHomeDirectory() + "/.cache/huggingface/hub")
        let folder = try #require(LocalModel.snapshot(ModelCatalog.GEMMA, cache: HFCache(root: hub)), "Gemma is not in \(hub.path)")
        let limits = LocalModel.limits(ModelCatalog.GEMMA, env: env)
        let budget = limits.budget
        let model = MLXModel(repo: ModelCatalog.GEMMA, folder: folder, limits: limits)
        model.maxTokens = 64
        let schema = JSONValue.object([
            ("type", .string("object")), ("description", .string("Answer in German.")),
            ("properties", .object([("greeting", .object([("type", .string("string"))]))])),
            ("required", .array([.string("greeting")])),
        ])
        let started = Date()
        let answer = try await model.generate(prompt: "Valerie from Contoso joins the call. Greet her in one short sentence.",
                                              schema: schema) { text in
            guard let object = try? Answer.object(text) else { throw BrokenAnswer("not JSON: \(text.prefix(200))") }
            return object
        }
        let info = try #require(model.lastGeneration)
        let peak = await localModelPeakFootprint()
        print("SMOKE answer: \(PythonJSON.dumps(answer, ensureAscii: false))")
        print(String(format: "SMOKE peak footprint %.2f GB (budget %.1f GB), %d prompt tokens, %d generated, %.1f tokens/s, "
                     + "prompt %.2f s, total %.1f s", Double(peak) / Double(1 << 30), Double(budget) / Double(1 << 30),
                     info.promptTokens, info.generatedTokens, info.tokensPerSecond, info.promptSeconds,
                     Date().timeIntervalSince(started)))
        #expect(answer["greeting"]?.stringValue?.isEmpty == false)
        #expect(info.generatedTokens <= 64)
        #expect(peak < budget)
        #expect(Memory.cacheLimit == LocalModel.CACHE_LIMIT_BYTES && Memory.memoryLimit == budget)
    }
}
