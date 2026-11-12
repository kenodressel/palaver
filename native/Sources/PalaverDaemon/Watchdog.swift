// The memory watchdog (palaver/memory.py, issue #49): what the daemon's workers cost, measured as
// macOS counts it (phys_footprint, Activity Monitor's "Memory"), and what is decided when one
// costs too much. `Watchdog` only samples and judges; the daemon acts on the `MemoryAction`s.
//
// live, stream (they run during calls): over budget for OVER_SECONDS and OVER_SAMPLES samples →
// restarted (MAX_RESTARTS per meeting, then stopped). notes, process, index: over budget → told
// once; they finish. Only when the Mac runs low on memory (under PRESSURE_GB free, sustained the
// same way) while one is over budget is it stopped and queued again; the third time it is given
// up with a notification that says what to do. Never silently.
import Darwin
import Foundation
import PalaverCore

// `MemoryRules` and `MemoryBudgets` are in PalaverCore (MemoryBudgets.swift): `palaver doctor` and the problem report
// read them too.

/// The budgets that depend on the meeting (`budget_hook`): the notes' follows the models their run
/// loads for it (the notes', then the projects sort's: `notes-memory`); `notes_gb` raises it, never
/// below that need, as palaver-lm's own watchdog does (LocalModel.limits). With the Notion upload
/// on, `run` writes the notes too, so its budget is at least their need. `need`: free memory the
/// meeting's notes run needs (0: cloud models only; nil: not known yet, the default budget stands).
public func memoryBudgetHook(config: [String: Double], notesInRun: @escaping () -> Bool,
                             need: @escaping (String) -> Double?) -> (String, String) -> Double? {
    let process = config["process_gb"].flatMap { $0 > 0 ? $0 : nil } ?? MemoryRules.defaultProcessGB
    let notesGB = config["notes_gb"].flatMap { $0 > 0 ? $0 : nil }
    return { kind, folder in
        if kind == "notes" || kind == "question" {
            guard let n = need(folder) else { return nil }
            if let notesGB { return max(notesGB, n) }
            return n > 0 ? n : MemoryRules.cloudNotesGB
        }
        if kind == "process" && notesInRun() {
            guard let n = need(folder) else { return nil }
            return max(process, n)
        }
        return nil
    }
}

// MARK: - measuring

public enum MemoryMeasure {
    /// The phys_footprint of `pid` in bytes; nil when it is gone (or not ours to read).
    @Sendable public static func footprint(_ pid: Int32) -> Int? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? Int(info.ri_phys_footprint) : nil
    }

    /// `pid` and everything it started (a worker's helpers count as the worker); nil when `pid` is gone.
    public static func tree(_ pid: Int32, sample: (Int32) -> Int? = footprint,
                            children: (Int32) -> [Int32] = childPids) -> Int? {
        guard let own = sample(pid) else { return nil }
        return own + children(pid).reduce(0) { $0 + (tree($1, sample: sample, children: children) ?? 0) }
    }

    /// Bytes of `own`'s children that are not known workers (the Meetings window's server process
    /// and its notes helper, a bench). A known worker further down is counted as that worker.
    public static func otherChildren(_ known: Set<Int32>, own: Int32 = getpid(),
                                     sample: (Int32) -> Int? = footprint,
                                     children: (Int32) -> [Int32] = childPids) -> Int {
        func subtree(_ pid: Int32) -> Int {
            guard let used = sample(pid) else { return 0 }
            return used + children(pid).filter { !known.contains($0) }.reduce(0) { $0 + subtree($1) }
        }
        return children(own).filter { !known.contains($0) }.reduce(0) { $0 + subtree($1) }
    }

    /// "5.4 GB", "12 GB", "317 MB", "—".
    public static func sizeText(_ used: Double?) -> String { MemoryRules.sizeText(used) }

    /// "Palaver 5.4 GB", for the recording status line.
    public static func costText(total: Int?) -> String? { total.map { "Palaver \(sizeText(Double($0)))" } }
}

// MARK: - the watchdog

/// What the daemon is to do with a worker. `what`: "restart" (live, stream), "stop" (live, stream:
/// no more restarts; also a question helper), "requeue" (notes, process, index: the Mac is low on
/// memory), "drop" (the same, the last time) or "warn" (over budget with memory to spare).
/// `title`: the notification, empty when it was already given for the meeting.
public struct MemoryAction {
    public let what: String
    public let kind: String
    /// The meeting's folder (a path), or `MemoryRules.indexFolder`.
    public let folder: String
    public let process: WorkerProcess
    public let used: Int
    public let limit: Double
    public let title: String
    public let message: String
}

private final class Sustained {
    var since: Double?
    var samples = 0

    func update(_ holds: Bool, _ now: Double) -> Bool {
        guard holds else { since = nil; samples = 0; return false }
        if since == nil { since = now }
        samples += 1
        return samples >= MemoryRules.overSamples && now - since! >= MemoryRules.overSeconds
    }
}

private final class Seen {
    let kind: String, folder: String, pid: Int32
    var used = 0
    let over = Sustained(), pressure = Sustained()
    var acted: String?
    var warned = false
    init(kind: String, folder: String, pid: Int32) { self.kind = kind; self.folder = folder; self.pid = pid }
}

/// Samples the workers the daemon started and decides what to do with the ones over budget. Pure
/// apart from `sample` (bytes of a pid's tree, nil when gone), `own` (the app process's bytes),
/// `others` (bytes of the app's other children, given the workers' pids), `freeGB` (asked only
/// while a notes, process or index worker is over budget) and `budgetFor` (a budget that depends
/// on the meeting, or nil).
public final class Watchdog: MemoryWatching, @unchecked Sendable {
    private let fixedBudgets: MemoryBudgets
    private let budgetsNow: (() -> MemoryBudgets)?
    /// The budgets now: `budgetsNow` (the notes' follows the model's need once known), else fixed.
    public var budgets: MemoryBudgets { budgetsNow?() ?? fixedBudgets }
    private let sample: (Int32) -> Int?
    private let own: () -> Int?
    private let others: (Set<Int32>) -> Int
    private let freeGB: () -> Double
    private let budgetFor: ((String, String) -> Double?)?
    private let log: (String, String) -> Void
    private let lock = NSLock()
    private var seen: [Seen] = []
    private var restarts: [String: Int] = [:]
    private var requeues: [String: Int] = [:]
    private var notified: Set<String> = []
    private var app: Int?
    private var other = 0
    private var free: Double?  // asked once per check, when needed

    public init(_ budgets: MemoryBudgets = MemoryBudgets(), budgetsNow: (() -> MemoryBudgets)? = nil,
                sample: @escaping (Int32) -> Int? = { MemoryMeasure.tree($0) },
                own: @escaping () -> Int? = { MemoryMeasure.footprint(getpid()) },
                others: @escaping (Set<Int32>) -> Int = { MemoryMeasure.otherChildren($0) },
                freeGB: @escaping () -> Double = { .infinity },
                budgetFor: ((String, String) -> Double?)? = nil,
                log: @escaping (String, String) -> Void = { _, _ in }) {
        self.fixedBudgets = budgets
        self.budgetsNow = budgetsNow
        self.sample = sample
        self.own = own
        self.others = others
        self.freeGB = freeGB
        self.budgetFor = budgetFor
        self.log = log
    }

    public func budget(_ kind: String, _ folder: String) -> Double {
        budgetFor?(kind, folder) ?? budgets.of(kind)
    }

    /// Samples `workers` and returns what to do with the ones over budget.
    public func check(_ workers: [DaemonWorker], now: Double) -> [MemoryAction] {
        lock.lock(); defer { lock.unlock() }
        var current: [Seen] = []
        var actions: [MemoryAction] = []
        free = nil
        for w in workers {
            let folder = w.folder ?? MemoryRules.indexFolder
            let pid = w.process.pid
            guard let used = sample(pid) else { continue }
            var s = seen.first { $0.pid == pid }
            if s == nil || s!.kind != w.kind || s!.folder != folder { s = Seen(kind: w.kind, folder: folder, pid: pid) }
            s!.used = used
            current.append(s!)
            if let action = judge(s!, w.process, now) { actions.append(action) }
        }
        seen = current
        app = own()
        other = others(Set(current.map(\.pid)))
        return actions
    }

    public func watch(_ workers: [DaemonWorker], now: Double) -> [MemoryAction] { check(workers, now: now) }

    private func freeNow() -> Double {
        if free == nil { free = freeGB() }
        return free!
    }

    private func judge(_ s: Seen, _ process: WorkerProcess, _ now: Double) -> MemoryAction? {
        let limit = budget(s.kind, s.folder)
        let over = s.over.update(Double(s.used) / MemoryRules.gb > limit, now)
        if s.acted != nil { return nil }
        if s.kind == "live" || s.kind == "stream" {
            guard over else { return nil }
            return act(s, process, count(&restarts, s, MemoryRules.maxRestarts) ? "restart" : "stop", limit)
        }
        // Notes, `process` and the index are only stopped when the Mac itself runs low on memory
        // while they are over budget; else they finish.
        let pressed = s.pressure.update(s.over.samples > 0 && freeNow() < MemoryRules.pressureGB, now)
        if s.kind == "question" {
            // The user's click, not queued work: stopped when the Mac runs low, counted against
            // nothing (never the meeting's notes), told in the window.
            return over && pressed ? act(s, process, "stop", limit, quiet: true) : nil
        }
        if over && pressed {
            return act(s, process, count(&requeues, s, MemoryRules.maxRequeues) ? "requeue" : "drop", limit)
        }
        if over && !s.warned {
            s.warned = true
            return act(s, process, "warn", limit)
        }
        return nil
    }

    /// Counts one more; whether it is still within `most`.
    private func count(_ counts: inout [String: Int], _ s: Seen, _ most: Int) -> Bool {
        let key = s.kind + "\u{0}" + s.folder
        counts[key, default: 0] += 1
        return counts[key]! <= most
    }

    /// How many times `kind` of `folder` was stopped for low memory (tests).
    func requeueCount(_ kind: String, _ folder: String) -> Int { lock.withLock { requeues[kind + "\u{0}" + folder] ?? 0 } }

    private static let logged = [
        "restart": "restarting it", "stop": "stopping it for this meeting",
        "requeue": "the Mac is low on memory: stopping it, tried again later",
        "drop": "the Mac is low on memory again: stopping it for good", "warn": "letting it finish"]

    private func act(_ s: Seen, _ process: WorkerProcess, _ what: String, _ limit: Double,
                     quiet: Bool = false) -> MemoryAction {
        if what != "warn" { s.acted = what }
        let freeValue = free.flatMap { $0.isFinite ? $0 : nil }
        let meeting = (s.folder as NSString).lastPathComponent
        var (title, message) = quiet ? ("", "")
            : MemoryTexts.texts(kind: s.kind, what: what, used: s.used, limit: limit, meeting: meeting, free: freeValue)
        let freeText = freeValue != nil && (what == "requeue" || what == "drop")
            ? ", \(MemoryMeasure.sizeText(freeValue! * MemoryRules.gb)) free" : ""
        log("WARNING", "\(MemoryRules.labels[s.kind]!.lowercased()) of \(meeting) uses "
            + "\(MemoryMeasure.sizeText(Double(s.used))), over its "
            + "\(MemoryMeasure.sizeText(limit * MemoryRules.gb)) budget\(freeText); \(Self.logged[what]!)")
        // Each kind of news once per meeting; giving up is always said.
        let key = [s.kind, s.folder, what == "requeue" || what == "drop" ? "stopped" : what].joined(separator: "\u{0}")
        if notified.contains(key) && what != "stop" && what != "drop" { title = ""; message = "" }
        notified.insert(key)
        return MemoryAction(what: what, kind: s.kind, folder: s.folder, process: process, used: s.used,
                            limit: limit, title: title, message: message)
    }

    private static let acting = ["restart": "restarting", "stop": "stopping", "requeue": "stopping", "drop": "stopping"]

    /// What Palaver costs now: `total` bytes (the app, its workers and its other children), `app`,
    /// each worker's state and the budgets (daemon.json's `memory`). nil before the first check.
    public func status() -> JSONValue? {
        lock.lock(); defer { lock.unlock() }
        var rows: [JSONValue] = []
        var sum = 0
        for s in seen {
            let limit = budget(s.kind, s.folder)
            let state = s.acted.flatMap { Self.acting[$0] } ?? (Double(s.used) / MemoryRules.gb > limit ? "over budget" : "running")
            rows.append(.object([("kind", .string(s.kind)), ("label", .string(MemoryRules.labels[s.kind]!)),
                                 ("meeting", .string((s.folder as NSString).lastPathComponent)), ("pid", .int(Int(s.pid))),
                                 ("used", .int(s.used)), ("budget", .double(limit)), ("state", .string(state))]))
            sum += s.used
        }
        let total: JSONValue = app.map { .int($0 + sum + other) } ?? .null
        return .object([("total", total), ("app", app.map { .int($0) } ?? .null), ("workers", .array(rows)),
                        ("budgets", budgets.json)])
    }

    public func costText() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let app else { return nil }
        return MemoryMeasure.costText(total: app + seen.reduce(0) { $0 + $1.used } + other)
    }
}

// MARK: - texts (memory.py _texts, verbatim)

enum MemoryTexts {
    static func texts(kind: String, what: String, used: Int, limit: Double, meeting: String,
                      free: Double?) -> (String, String) {
        let size = MemoryMeasure.sizeText
        let over = "It used \(size(Double(used))), over its \(size(limit * MemoryRules.gb)) budget."
        let low = "It used \(size(Double(used))) (budget \(size(limit * MemoryRules.gb)))"
            + (free.map { " while only \(size($0 * MemoryRules.gb)) were free." } ?? " while the Mac ran low on memory.")
        let tries = MemoryRules.tries
        if kind == "live" || kind == "stream" {
            let label = MemoryRules.labels[kind]!
            if what == "restart" { return ("\(label) restarted", "\(over) The recording goes on.") }
            let later = kind == "live" ? "The transcript is written after the call." : "The transcript comes after the call."
            return ("\(label) stopped", "\(over) It kept passing its budget; the recording goes on. \(later)")
        }
        if kind == "notes" {
            if what == "warn" { return ("Notes use more memory than planned", "\(over) They finish unless the Mac runs low on memory.") }
            if what == "requeue" { return ("Notes paused: the Mac is low on memory", "\(low) They are written again later.") }
            return ("Notes not written: the Mac kept running low on memory",
                    "\(meeting): stopped \(tries) times. Close other apps, then use Write notes on the meeting in the Meetings window.")
        }
        if kind == "index" {
            if what == "warn" { return ("The search index uses more memory than planned", "\(over) It finishes unless the Mac runs low on memory.") }
            if what == "requeue" { return ("Search index paused: the Mac is low on memory", "\(low) It goes on later.") }
            return ("Search index paused: the Mac kept running low on memory",
                    "Stopped \(tries) times. It is built again when Palaver starts next; search by words works meanwhile.")
        }
        if what == "warn" { return ("Transcription uses more memory than planned", "\(over) It finishes unless the Mac runs low on memory.") }
        if what == "requeue" { return ("Transcription paused: the Mac is low on memory", "\(low) Palaver tries again in a few minutes.") }
        return ("Transcription stopped: the Mac kept running low on memory",
                "\(meeting): stopped \(tries) times. Close other apps, then run `palaver process` on it.")
    }
}
