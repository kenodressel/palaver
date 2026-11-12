// The local model's side that needs no MLX: which snapshot loads (offline, never a download), what a missing model
// says, the memory budget and its watchdog, how the model is asked, and the notes run with a local engine.
import Darwin
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain
@testable import PalaverLM
import Testing

let GEMMA_PIN = "de9e183868050b34bf6b4272518500ffcebf15b3"

/// A Hugging Face cache with snapshots made of plain files: `complete` ones have config.json and a weights file.
struct FakeHub {
    let cache = HFCache(root: tempFolder("hub"))

    @discardableResult
    func snapshot(_ repo: String, _ revision: String, complete: Bool = true, age: Double = 0) -> URL {
        let dir = cache.snapshotDir(repo: repo, revision: revision)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        if complete { try! Data("weights".utf8).write(to: dir.appendingPathComponent("model.safetensors")) }
        let when = Date().addingTimeInterval(-age)
        try! FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: dir.path)
        return dir
    }

    func ref(_ repo: String, main revision: String) {
        let refs = cache.repoDir(repo).appendingPathComponent("refs", isDirectory: true)
        try! FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try! Data(revision.utf8).write(to: refs.appendingPathComponent("main"))
    }
}

@Suite struct LocalModelTests {
    @Test func thePinnedSnapshotLoadsWhenItIsComplete() {
        let hub = FakeHub()
        hub.snapshot(ModelCatalog.GEMMA, "older", age: 10)
        let pinned = hub.snapshot(ModelCatalog.GEMMA, GEMMA_PIN, age: 100)
        #expect(LocalModel.snapshot(ModelCatalog.GEMMA, cache: hub.cache)?.path == pinned.path)
    }

    @Test func aCompleteOlderSnapshotLoadsWhenThePinIsCutShort() {
        let hub = FakeHub()
        hub.snapshot(ModelCatalog.GEMMA, GEMMA_PIN, complete: false)
        hub.snapshot(ModelCatalog.GEMMA, "oldest", age: 300)
        let newer = hub.snapshot(ModelCatalog.GEMMA, "newer", age: 100)
        hub.snapshot(ModelCatalog.GEMMA, "newest-but-broken", complete: false, age: 1)
        #expect(LocalModel.snapshot(ModelCatalog.GEMMA, cache: hub.cache)?.path == newer.path)
    }

    @Test func aModelThatIsNotHereIsNeverDownloaded() {
        let hub = FakeHub()
        #expect(LocalModel.snapshot(ModelCatalog.GEMMA, cache: hub.cache) == nil)
        hub.snapshot(ModelCatalog.GEMMA, GEMMA_PIN, complete: false)
        #expect(LocalModel.snapshot(ModelCatalog.GEMMA, cache: hub.cache) == nil)
        #expect(LocalModel.notDownloaded(ModelCatalog.GEMMA)
                == "Gemma 4 12B is not on this Mac yet: download it in the setup assistant (Settings → Language model), "
                + "or choose a cloud model there.")
        #expect(LocalModel.notDownloaded("acme/tiny-4bit").contains("`hf download acme/tiny-4bit`"))
        #expect(FileManager.default.fileExists(atPath: hub.cache.root.path))
    }

    @Test func anIndexNamingAShardPalaverNeverDownloadsStillLoads() throws {
        // Gemma's index also names optiq_vision.safetensors (its vision sidecar), which MLX_FILES leaves out.
        let hub = FakeHub()
        let snap = hub.snapshot(ModelCatalog.GEMMA, GEMMA_PIN, complete: false)
        let index = #"{"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors", "v": "optiq_vision.safetensors"}}"#
        try Data(index.utf8).write(to: snap.appendingPathComponent("model.safetensors.index.json"))
        try Data("w".utf8).write(to: snap.appendingPathComponent("model-00001-of-00002.safetensors"))
        #expect(LocalModel.snapshot(ModelCatalog.GEMMA, cache: hub.cache) == nil)  // a shard of the model is missing
        try Data("w".utf8).write(to: snap.appendingPathComponent("model-00002-of-00002.safetensors"))
        #expect(LocalModel.snapshot(ModelCatalog.GEMMA, cache: hub.cache)?.path == snap.path)
        // A link whose blob is gone: not loadable.
        try FileManager.default.createSymbolicLink(atPath: snap.appendingPathComponent("tokenizer.json").path,
                                                   withDestinationPath: "../../blobs/gone")
        #expect(LocalModel.snapshot(ModelCatalog.GEMMA, cache: hub.cache) == nil)
    }

    @Test func aModelNotListedLoadsWhatItsMainRefNames() {
        let hub = FakeHub()
        let repo = "acme/tiny-4bit"
        let main = hub.snapshot(repo, "abc123", age: 100)
        hub.snapshot(repo, "def456", age: 1)
        hub.ref(repo, main: "abc123\n")
        #expect(LocalModel.snapshot(repo, cache: hub.cache)?.path == main.path)
        hub.ref(repo, main: "gone")  // the main ref's snapshot is not here: the newest complete one
        #expect(LocalModel.snapshot(repo, cache: hub.cache)?.lastPathComponent == "def456")
    }

    @Test func theBudgetIsTheLargerOfTheModelsNeedAndNotesGBWithACeilingAbove() {
        let gib = 1 << 30
        #expect(LocalModel.limits(ModelCatalog.GEMMA, env: [:]) == .init(budget: 14 * gib, ceiling: 21 * gib))
        #expect(LocalModel.limits("acme/tiny-4bit", env: [:]) == .init(budget: 20 * gib, ceiling: 30 * gib))
        // [memory] notes_gb raises the budget (never lowers it below the model's need).
        #expect(LocalModel.limits(ModelCatalog.GEMMA, notesGB: 18, env: [:]) == .init(budget: 18 * gib, ceiling: 27 * gib))
        #expect(LocalModel.limits(ModelCatalog.GEMMA, notesGB: 8, env: [:]) == .init(budget: 14 * gib, ceiling: 21 * gib))
        // $PALAVER_LM_MEMORY_GB only lowers.
        #expect(LocalModel.limits(ModelCatalog.GEMMA, env: [LocalModel.BUDGET_ENV: "12"]) == .init(budget: 12 * gib, ceiling: 12 * gib))
        #expect(LocalModel.limits(ModelCatalog.GEMMA, env: [LocalModel.BUDGET_ENV: "16"]) == .init(budget: 14 * gib, ceiling: 16 * gib))
        #expect(LocalModel.limits(ModelCatalog.GEMMA, env: [LocalModel.BUDGET_ENV: "30"]) == .init(budget: 14 * gib, ceiling: 21 * gib))
        #expect(LocalModel.limits(ModelCatalog.GEMMA, env: [LocalModel.BUDGET_ENV: "lots"]) == .init(budget: 14 * gib, ceiling: 21 * gib))
    }

    /// A watchdog over scripted footprints (GB), free memory (GB) and a clock that ticks `step` seconds a look.
    final class Script: @unchecked Sendable {
        var used: [Double]
        var free: Double
        var now = 0.0
        let step: Double
        var freeAsked = 0
        var stops: [(FootprintWatchdog.Stop, Int)] = []
        init(_ used: [Double], free: Double, step: Double = 1) { self.used = used; self.free = free; self.step = step }

        func dog(budget: Double = 14, ceiling: Double = 21) -> FootprintWatchdog {
            FootprintWatchdog(limits: .init(budget: Int(budget * MemoryRules.gb), ceiling: Int(ceiling * MemoryRules.gb)),
                              read: { [self] in used.isEmpty ? nil : Int(used.removeFirst() * MemoryRules.gb) },
                              freeGB: { [self] in freeAsked += 1; return free },
                              clock: { [self] in now += step; return now },
                              stopped: { [self] in stops.append(($0, $1)) })
        }
    }

    @Test func overTheBudgetWithMemoryToSpareTheRunGoesOn() {
        let s = Script(Array(repeating: 16, count: 30), free: 20)
        let dog = s.dog()
        for _ in 0..<30 { dog.check() }
        #expect(s.stops.isEmpty && dog.peak == Int(16 * MemoryRules.gb))
        let under = Script(Array(repeating: 9, count: 5), free: 0.5)  // under the budget: free memory is not even asked
        let quiet = under.dog()
        for _ in 0..<5 { quiet.check() }
        #expect(under.stops.isEmpty && under.freeAsked == 0)
    }

    @Test func overTheBudgetWhileTheMacRunsLowItStopsOnceAfterTheSustainedTime() {
        // 1 s a look: 3 samples are not enough, 10 s are needed (MemoryRules.overSamples, overSeconds).
        let s = Script(Array(repeating: 16, count: 30), free: 1.0)
        let dog = s.dog()
        for _ in 0..<10 { dog.check() }
        #expect(s.stops.isEmpty)
        for _ in 0..<20 { dog.check() }
        #expect(s.stops.count == 1 && s.stops[0].0 == .lowMemory(freeGB: 1.0))
        #expect(FootprintWatchdog.exitCode(s.stops[0].0) == 74 && FootprintWatchdog.EXIT_LOW_MEMORY == MemoryRules.lowMemoryExit)
        // A dip back over 1.5 GB free starts the count again.
        let dip = Script(Array(repeating: 16, count: 30), free: 1.0)
        let d = dip.dog()
        for i in 0..<30 { dip.free = i % 8 == 7 ? 4 : 1; d.check() }
        #expect(dip.stops.isEmpty)
    }

    @Test func aboveTheCeilingItStopsAtOnceWhateverIsFree() {
        let s = Script([12, 22, 25], free: 30)
        let dog = s.dog()
        for _ in 0..<3 { dog.check() }
        #expect(s.stops.count == 1 && s.stops[0].0 == .overCeiling && s.stops[0].1 == Int(22 * MemoryRules.gb))
        #expect(FootprintWatchdog.exitCode(.overCeiling) == 73 && dog.peak == Int(25 * MemoryRules.gb))
        let limits = LocalModel.Limits(budget: 14 << 30, ceiling: 21 << 30)
        #expect(FootprintWatchdog.message(.overCeiling, footprint: 22 << 30, limits: limits).hasPrefix(
            "the local model used 22 GB of memory, more than its limit of 21 GB (budget 14 GB), and was stopped"))
        #expect(FootprintWatchdog.message(.lowMemory(freeGB: 1.2), footprint: 16 << 30, limits: limits)
                == "the Mac ran low on memory (only 1.2 GB free) while the local model used 16 GB (budget 14 GB): "
                + "stopped so the Mac stays responsive")
    }

    @Test func theWatchdogWatchesThisProcessOnItsOwn() async throws {
        #expect((physFootprint() ?? 0) > 1 << 20)
        final class Fired: @unchecked Sendable { var stop: FootprintWatchdog.Stop?; var at = 0 }
        let fired = Fired()
        let dog = FootprintWatchdog(limits: .init(budget: 1 << 19, ceiling: 1 << 20), interval: 0.05,
                                    stopped: { fired.stop = $0; fired.at = $1 })  // 1 MB: over at once
        dog.start()
        defer { dog.cancel() }
        for _ in 0..<40 where fired.stop == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(fired.stop == .overCeiling && fired.at > 1 << 20 && dog.peak >= fired.at)
    }

    @Test func aLocalModelThatIsNotHereSkipsTheNotesAndSaysHow() async throws {
        let home = Home()
        let paths = home.meeting()
        var ctx = home.context()
        ctx.local = { throw EngineUnavailable(LocalModel.notDownloaded($0)) }
        #expect(try await run(["notes", paths.folder.path], ctx) == 1)
        #expect(home.said.last == "Skipping notes: " + LocalModel.notDownloaded(ModelCatalog.GEMMA))
        #expect(home.events(paths).last?["event"] == .string("notes_skipped"))
        #expect(Notes.load(paths) == nil)
    }

    @Test func theLocalModelWritesTheNotesAndTheWatchdogsLastWordsReachTheLog() async throws {
        let home = Home()
        let paths = home.meeting()
        var ctx = home.context()
        let model = FakeModel(json: NOTES_ANSWER)
        final class Asked: @unchecked Sendable { var repo: String?; var hook = false }
        let asked = Asked()
        ctx.local = { repo in
            asked.repo = repo
            return Probe(model) { asked.hook = FootprintWatchdog.lastWordsCount > 0 }
        }
        #expect(try await run(["notes", paths.folder.path], ctx) == 0)
        #expect(asked.repo == ModelCatalog.GEMMA)
        #expect(asked.hook)  // the run's last words are registered while the model writes
        #expect(home.said.contains("Writing notes with Gemma 4 12B on this Mac…"))
        #expect(Notes.load(paths)?["title"] == .string("Angebot für Contoso"))
    }

    @Test func versionSaysWhichPalaverThisIs() async {
        #expect(await LMMain.run(["--version"], env: [:]) == 0)
    }
}

/// A model that runs `during` while it is asked, then answers as `model`.
struct Probe: LanguageModel {
    let model: LanguageModel
    let during: () -> Void

    init(_ model: LanguageModel, during: @escaping () -> Void) { self.model = model; self.during = during }

    func generate(prompt: String, schema: JSONValue, parse: @escaping AnswerParser) async throws -> JSONValue {
        during()
        return try await model.generate(prompt: prompt, schema: schema, parse: parse)
    }
}
