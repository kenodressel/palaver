// What the local model needs besides MLX itself (PalaverMLX runs it): where its files are, how it is asked (notes.py
// `local_runner`: the chat template with thinking off, temperature 0.2, at most 4096 tokens), and the memory it may use.
// Nothing here downloads: a model that is not in the Hugging Face cache says so (the setup assistant downloads it).
//
// Memory (the Mac once ran out of memory on a model run that had none): MLX's buffer cache is held to 1 GB and MLX's
// memory limit (a scheduling guideline, it never fails an allocation) is set at the notes budget (PalaverMLX).
// `FootprintWatchdog` follows the daemon's rule for notes (memory.py): over its budget a run finishes, unless the Mac
// itself runs low on memory (under 1.5 GB free, sustained) — then it stops with exit code 74 and the daemon writes the
// notes again later. A hard ceiling above the budget (exit 73) is the safety net for a run that grows without bound.
// The daemon's own watchdog and free-memory gate stay as they are.
import Darwin
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

public enum LocalModel {
    /// notes.py `LOCAL_MAX_TOKENS`.
    public static let MAX_TOKENS = 4096
    /// notes.py `make_sampler(temp=0.2)`: temperature only (no top-p, top-k or penalties).
    public static let TEMPERATURE: Float = 0.2
    /// mlx_lm's `generate_step` prefill step: the prompt goes through the model 2048 tokens at a time.
    public static let PREFILL_STEP = 2048
    /// MLX's buffer cache (memory kept for reuse) at most this many bytes.
    public static let CACHE_LIMIT_BYTES = 1 << 30
    /// The chat template's variables besides the messages: models that think out loud by default would spend every
    /// token on it (notes.py passes `enable_thinking=False`).
    public static let TEMPLATE_CONTEXT: [String: Bool] = ["enable_thinking": false]
    /// `$PALAVER_LM_MEMORY_GB`: a lower budget and ceiling (the opt-in smoke test under memcap); never higher ones.
    public static let BUDGET_ENV = "PALAVER_LM_MEMORY_GB"
    /// The ceiling over the budget: a run is stopped above budget × (1 + this) whatever the Mac has free.
    public static let CEILING_MARGIN = 0.5

    /// The system text and the user's message, as notes.py `local_runner` gives them to the chat template.
    public static func messages(prompt: String, schema: JSONValue) -> [[String: String]] {
        [["role": "system", "content": Asking.system(schema)], ["role": "user", "content": prompt]]
    }

    /// The memory a local run of `repo` may use, in bytes.
    public struct Limits: Equatable, Sendable {
        /// The notes budget (the daemon's): over it a run is stopped only when the Mac runs low on memory.
        public let budget: Int
        /// Over it the run is stopped at once.
        public let ceiling: Int

        public init(budget: Int, ceiling: Int) { self.budget = budget; self.ceiling = ceiling }
    }

    /// The budget is the larger of the model's need (`notesMemoryGB`: 14 GB for Gemma, 20 GB for a model not listed) and
    /// config.toml's `[memory] notes_gb`; the ceiling is `CEILING_MARGIN` above it. `$PALAVER_LM_MEMORY_GB` lowers both.
    public static func limits(_ repo: String, notesGB: Double? = nil,
                              env: [String: String] = ProcessInfo.processInfo.environment) -> Limits {
        var budget = max(ModelChoice.notesMemoryGB(repo), notesGB ?? 0)
        var ceiling = budget * (1 + CEILING_MARGIN)
        if let text = env[BUDGET_ENV], let lower = Double(text), lower > 0 {
            budget = min(budget, lower)
            ceiling = min(ceiling, lower)
        }
        return Limits(budget: Int(budget * MemoryRules.gb), ceiling: Int(ceiling * MemoryRules.gb))
    }

    // MARK: - The model's files

    /// The snapshot folder of `repo` to load (notes.py `model_revision`), from the cache only: the pinned revision once
    /// it is complete, else the newest complete other snapshot (an older download still works offline); a repo not
    /// pinned: the one its `main` ref names when complete, else the newest complete snapshot. nil: not here. Complete is
    /// `HFCache.isComplete` (the weights by mlx_lm's rule, `HFCache.weightsHere`).
    public static func snapshot(_ repo: String, cache: HFCache) -> URL? {
        let pin = HubModels.pin(repo)
        var preferred: String? = pin.revision
        if pin.revision == "main" {
            let ref = cache.repoDir(repo).appendingPathComponent("refs/main")
            preferred = (try? String(contentsOf: ref, encoding: .utf8)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if let preferred, !preferred.isEmpty, cache.isComplete(repo: repo, revision: preferred, patterns: pin.patterns) {
            return cache.snapshotDir(repo: repo, revision: preferred)
        }
        let snapshots = cache.repoDir(repo).appendingPathComponent("snapshots", isDirectory: true)
        let others = ((try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? [])
            .filter { $0 != preferred && !$0.hasPrefix(".") }
            .map { name -> (String, Date) in
                let mtime = (try? FileManager.default.attributesOfItem(atPath: snapshots.appendingPathComponent(name).path))?[.modificationDate] as? Date
                return (name, mtime ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
        guard let found = others.first(where: { cache.isComplete(repo: repo, revision: $0.0, patterns: pin.patterns) }) else {
            return nil
        }
        return cache.snapshotDir(repo: repo, revision: found.0)
    }

    /// What a run says when `repo` is not on this Mac: Palaver never downloads a model while it writes notes.
    public static func notDownloaded(_ repo: String) -> String {
        if let label = ModelChoice.localModelInfo(repo)?.label {
            return "\(label) is not on this Mac yet: download it in the setup assistant (Settings → Language model), "
                + "or choose a cloud model there."
        }
        return "\(repo) is not in the Hugging Face cache on this Mac (Palaver downloads only the models Settings offers): "
            + "download it with `hf download \(repo)`, or choose another model in Settings → Language model."
    }
}

// MARK: - The memory watchdog

/// This process's memory as macOS counts it against the Mac (Activity Monitor's "Memory"): `phys_footprint`, which
/// includes MLX's Metal buffers. nil when it can't be read.
public func physFootprint() -> Int? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : nil
}

/// Watches this process's footprint as the daemon's watchdog watches a notes run (memory.py `Watchdog._judge`): over
/// the budget it goes on, unless the Mac has less than `MemoryRules.pressureGB` free over `overSamples` samples and
/// `overSeconds` — then it stops (`EXIT_LOW_MEMORY`, the daemon queues the notes again). Above the ceiling it stops at
/// once (`EXIT_OVER_CEILING`). The generation can't be interrupted inside MLX quickly enough, so the process ends (its
/// model lock with it) after saying why.
public final class FootprintWatchdog: @unchecked Sendable {
    /// Stopped because the Mac ran low on memory while over the budget: the daemon writes the notes again later.
    public static let EXIT_LOW_MEMORY: Int32 = MemoryRules.lowMemoryExit
    /// Stopped above the ceiling: not tried again by itself.
    public static let EXIT_OVER_CEILING: Int32 = 73

    public enum Stop: Equatable {
        case lowMemory(freeGB: Double)
        case overCeiling
    }

    /// What runs before the process ends, after the "error:" line on stdout (the job's log, whose last "error:" line the
    /// window shows): notes write `notes_failed` into the meeting's session.log, the next question its `{"error"}`
    /// answer (its last line). `addLastWords` gives the token that `removeLastWords` takes.
    private static let wordsLock = NSLock()
    nonisolated(unsafe) private static var words: [UUID: (String) -> Void] = [:]

    public static func addLastWords(_ say: @escaping (String) -> Void) -> UUID {
        let token = UUID()
        wordsLock.withLock { words[token] = say }
        return token
    }

    public static func removeLastWords(_ token: UUID) { _ = wordsLock.withLock { words.removeValue(forKey: token) } }

    static var lastWordsCount: Int { wordsLock.withLock { words.count } }

    public let limits: LocalModel.Limits
    public let interval: Double
    private let read: () -> Int?
    private let freeGB: () -> Double
    private let clock: () -> Double
    private let stopped: (Stop, Int) -> Void
    private let lock = NSLock()
    private var _peak = 0
    private var timer: DispatchSourceTimer?
    private var fired = false
    private var pressedSince: Double?
    private var pressedSamples = 0

    /// `stopped` (why, the footprint): what happens, once; by default `stop`.
    public init(limits: LocalModel.Limits, interval: Double = 1, read: @escaping () -> Int? = physFootprint,
                freeGB: @escaping () -> Double = FreeMemory.availableGB,
                clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
                stopped: ((Stop, Int) -> Void)? = nil) {
        self.limits = limits
        self.interval = interval
        self.read = read
        self.freeGB = freeGB
        self.clock = clock
        self.stopped = stopped ?? { FootprintWatchdog.stop($0, footprint: $1, limits: limits) }
    }

    /// The highest footprint seen so far.
    public var peak: Int { lock.withLock { _peak } }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "palaver-lm.memory", qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.check() }
        lock.withLock { timer = t }
        t.resume()
    }

    public func cancel() { lock.withLock { timer?.cancel(); timer = nil } }

    /// One look (the timer's tick). Free memory is asked only while over the budget, as the daemon does.
    public func check() {
        guard let used = read() else { return }
        let now = clock()
        let over = used > limits.budget
        let free = over ? freeGB() : .infinity
        let stop: Stop? = lock.withLock {
            _peak = max(_peak, used)
            guard !fired else { return nil }
            if used > limits.ceiling { fired = true; return .overCeiling }
            if over && free < MemoryRules.pressureGB {
                if pressedSince == nil { pressedSince = now }
                pressedSamples += 1
            } else {
                pressedSince = nil; pressedSamples = 0
            }
            guard pressedSamples >= MemoryRules.overSamples, let since = pressedSince,
                  now - since >= MemoryRules.overSeconds else { return nil }
            fired = true
            return .lowMemory(freeGB: free)
        }
        if let stop { stopped(stop, used) }
    }

    public static func message(_ stop: Stop, footprint: Int, limits: LocalModel.Limits) -> String {
        let size = { (n: Int) in MemoryRules.sizeText(Double(n)) }
        switch stop {
        case .lowMemory(let free):
            return "the Mac ran low on memory (only \(MemoryRules.sizeText(free * MemoryRules.gb)) free) while the local "
                + "model used \(size(footprint)) (budget \(size(limits.budget))): stopped so the Mac stays responsive"
        case .overCeiling:
            return "the local model used \(size(footprint)) of memory, more than its limit of \(size(limits.ceiling)) "
                + "(budget \(size(limits.budget))), and was stopped so this Mac stays responsive; close other apps and "
                + "try again, or choose a cloud model in Settings → Language model."
        }
    }

    public static func exitCode(_ stop: Stop) -> Int32 {
        if case .overCeiling = stop { return EXIT_OVER_CEILING }
        return EXIT_LOW_MEMORY
    }

    /// Says why, passes the end on to the helpers, and exits (no cleanup that could wait on MLX).
    public static func stop(_ stop: Stop, footprint: Int, limits: LocalModel.Limits) -> Never {
        let text = message(stop, footprint: footprint, limits: limits)
        print("error: \(text)")
        for say in wordsLock.withLock({ Array(words.values) }) { say(text) }
        fflush(stdout)
        FileHandle.standardError.write(Data("palaver-lm: \(text)\n".utf8))
        LiveHelpers.terminateAll()
        _exit(exitCode(stop))
    }
}
