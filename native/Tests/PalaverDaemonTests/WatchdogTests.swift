// tests/test_memory.py: the budgets, what a process costs, and what the watchdog decides over
// fake samples, fake free memory and a fake clock. Not ported: parse_budgets' refusals (Config drops
// unknown keys and values <= 0, ConfigTests) and PeakTracker (the soak test's tool, not shipped).
import Darwin
import Foundation
import PalaverCore
import PalaverDomain
import Testing
@testable import PalaverDaemon

private let GB = MemoryRules.gb

final class Proc: WorkerProcess {
    let pid: Int32
    init(_ pid: Int32) { self.pid = pid }
    func poll() -> Int32? { nil }
    func terminate() {}
    func kill() {}
}

private func worker(_ kind: String, _ folder: String?, _ pid: Int32) -> DaemonWorker {
    DaemonWorker(kind: kind, folder: folder, process: Proc(pid))
}

/// A watchdog over fake samples, fake free memory and a fake clock.
private final class Watch {
    var used: [Int32: Double] = [:]  // pid -> GB
    var free = 30.0
    var now = 0.0
    var logs: [String] = []
    var last: [MemoryAction] = []
    var asked = 0
    var dog: Watchdog!

    init(_ budgets: MemoryBudgets = MemoryBudgets(config: ["live_gb": 5]),
         budgetFor: ((String, String) -> Double?)? = nil) {
        dog = Watchdog(budgets, sample: { [unowned self] pid in self.used[pid].map { Int($0 * GB) } },
                       own: { Int(0.3 * GB) }, others: { _ in 0 },
                       freeGB: { [unowned self] in self.asked += 1; return self.free },
                       budgetFor: budgetFor, log: { [unowned self] in self.logs.append($1) })
    }

    private func summary(_ actions: [MemoryAction]) -> [String] {
        actions.map { "\($0.what)|\($0.kind)|\(($0.folder as NSString).lastPathComponent)" }
    }

    @discardableResult
    func run(_ workers: [DaemonWorker], after: Double = 0) -> [String] {
        now += after
        last = dog.check(workers, now: now)
        return summary(last)
    }

    @discardableResult
    func check(_ workers: DaemonWorker..., after: Double = 0) -> [String] { run(workers, after: after) }

    /// OVER_SAMPLES samples over OVER_SECONDS: the actions of the last.
    func sustain(_ workers: DaemonWorker...) -> [String] {
        let step = MemoryRules.overSeconds / Double(MemoryRules.overSamples - 1)
        var out = run(workers)
        for _ in 0..<(MemoryRules.overSamples - 1) { out = run(workers, after: step) }
        return out
    }
}

private func fakeTaskpolicy() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-wd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("taskpolicy")
    try "#!/bin/sh\nshift 2\nexec \"$@\"\n".write(to: f, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
    return f.path
}

@Suite struct MemoryMeasureTests {
    @Test func footprintOfThisProcessIsItsPhysFootprint() {
        let used = MemoryMeasure.footprint(getpid())
        #expect(used != nil && used! > 1 << 20)
        #expect(MemoryMeasure.footprint(Int32(1 << 22) + 12345) == nil)  // no such process
    }

    @Test func treeFootprintAddsTheChildren() {
        let sizes: [Int32: Int] = [1: 100, 2: 20, 3: 3, 4: 4000]
        let kids: [Int32: [Int32]] = [1: [2], 2: [3], 3: [], 4: []]
        #expect(MemoryMeasure.tree(1, sample: { sizes[$0] }, children: { kids[$0] ?? [] }) == 123)
        #expect(MemoryMeasure.tree(9, sample: { sizes[$0] }, children: { kids[$0] ?? [] }) == nil)
        // A child that exited in between counts nothing.
        #expect(MemoryMeasure.tree(1, sample: { $0 == 2 ? nil : sizes[$0] }, children: { kids[$0] ?? [] }) == 100)
    }

    @Test func childrenOfThisProcessListAStartedChild() throws {
        let child = Foundation.Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        #expect(childPids(getpid()).contains(child.processIdentifier))
    }

    @Test(arguments: [(5.44, "5.4 GB"), (0.31, "317 MB"), (12.0, "12 GB")])
    func sizeText(_ gb: Double, _ text: String) {
        #expect(MemoryMeasure.sizeText(gb * GB) == text)
    }

    @Test func sizeTextOfNothing() { #expect(MemoryMeasure.sizeText(nil) == "\u{2014}") }

    @Test func costTextIsTheStatusLinePart() {
        #expect(MemoryMeasure.costText(total: Int(5.4 * GB)) == "Palaver 5.4 GB")
        #expect(MemoryMeasure.costText(total: nil) == nil)
    }

    @Test func otherChildrenCountTheWindowServerWithoutItsKnownHelpers() {
        // 10: the server, 11: its helper (a known worker), 12: another of its children, 20: a known worker of the app.
        let sizes: [Int32: Int] = [10: 100, 11: 1000, 12: 5, 20: 7]
        let kids: [Int32: [Int32]] = [1: [10, 20], 10: [11, 12], 20: []]
        #expect(MemoryMeasure.otherChildren([11, 20], own: 1, sample: { sizes[$0] }, children: { kids[$0] ?? [] }) == 105)
    }

    @Test func signalGroupStopsAWorkerAndWhatItStarted() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-wd-\(UUID().uuidString)/daemon.log")
        let p = try spawnWorker(["/bin/sh", "-c", "sleep 30 & echo $!; wait"], qos: .utility, log: log,
                                taskpolicy: try fakeTaskpolicy())
        var helper: Int32?
        for _ in 0..<100 where helper == nil {
            helper = (try? String(contentsOf: log, encoding: .utf8)).flatMap { Int32($0.split(separator: "\n").last ?? "") }
            if helper == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        let pid = try #require(helper)
        #expect(MemoryMeasure.footprint(pid) != nil)
        p.signalGroup(SIGTERM)
        #expect(p.waitUntilExit() != 0)
        for _ in 0..<100 where MemoryMeasure.footprint(pid) != nil { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(MemoryMeasure.footprint(pid) == nil)  // the helper went with it
    }

    @Test func signalGroupFallsBackToTheProcessItself() {
        final class Fake: WorkerProcess {
            let pid: Int32 = 0
            var calls: [String] = []
            func poll() -> Int32? { nil }
            func terminate() { calls.append("term") }
            func kill() { calls.append("kill") }
        }
        let f = Fake()
        f.signalGroup(SIGTERM)
        f.signalGroup(SIGKILL)
        #expect(f.calls == ["term", "kill"])
    }
}

@Suite struct MemoryBudgetTests {
    @Test func theSpeechBudgetsAreTheEngines() {
        let b = MemoryBudgets()
        #expect((b.live, b.stream, b.process) == (2.0, 1.5, 4.0))
    }

    @Test func budgetsFromConfigWithDefaultsAndOverrides() {
        let b = MemoryBudgets(config: ["live_gb": 4, "process_gb": 9], notes: 20)
        #expect((b.live, b.stream, b.process) == (4.0, 1.5, 9.0))
        #expect(b.notes == 20.0)  // an unknown notes model gets the most
        #expect(MemoryBudgets(config: [:]).notes == 14.0)
        #expect(MemoryBudgets(config: [:], notes: 0).notes == 2.0)  // the model runs elsewhere
        #expect(MemoryBudgets(config: ["notes_gb": 9], notes: 20).notes == 9.0)  // set explicitly: wins
    }

    @Test func notesBudgetFollowsTheModelOfEachMeeting() {
        let needs: [String: Double] = ["/r/a": 14, "/r/b": 0]
        let hook = memoryBudgetHook(config: [:], notesInRun: { false }, need: { needs[$0] })
        #expect(hook("notes", "/r/a") == 14.0)
        #expect(hook("notes", "/r/b") == 2.0)  // a cloud model: the process only waits for it
        #expect(hook("question", "/r/a") == 14.0)
        #expect(hook("live", "/r/a") == nil)
        #expect(hook("process", "/r/a") == nil)
        #expect(hook("notes", "/r/unknown") == nil)  // not known yet: the default stands
        // An explicit notes_gb raises the budget, never below the local model's need (palaver-lm's LocalModel.limits).
        #expect(memoryBudgetHook(config: ["notes_gb": 9], notesInRun: { false }, need: { _ in 14 })("notes", "/r/a") == 14.0)
        #expect(memoryBudgetHook(config: ["notes_gb": 18], notesInRun: { false }, need: { _ in 14 })("notes", "/r/a") == 18.0)
        #expect(memoryBudgetHook(config: ["notes_gb": 9], notesInRun: { false }, need: { _ in 0 })("notes", "/r/a") == 9.0)
        #expect(memoryBudgetHook(config: ["notes_gb": 9], notesInRun: { false }, need: { _ in nil })("notes", "/r/a") == nil)
    }

    @Test func runWithNotesGetsTheNotesModelsNeed() {
        var need = 14.0
        let hook = memoryBudgetHook(config: [:], notesInRun: { true }, need: { _ in need })
        #expect(hook("process", "/r/a") == 14.0)
        need = 0
        #expect(hook("process", "/r/a") == MemoryRules.defaultProcessGB)
    }
}

@Suite struct WatchdogTests {
    @Test func aWorkerUnderBudgetIsLeftAloneAndShown() {
        let w = Watch()
        w.used[11] = 3.6
        #expect(w.check(worker("live", "/r/m1", 11)) == [])
        let status = w.dog.status()!
        #expect(status["total"] == .int(Int(0.3 * GB) + Int(3.6 * GB)))
        #expect(status["app"] == .int(Int(0.3 * GB)))
        #expect(status["workers"] == .array([.object([
            ("kind", .string("live")), ("label", .string("Live transcription")), ("meeting", .string("m1")), ("pid", .int(11)),
            ("used", .int(Int(3.6 * GB))), ("budget", .double(5.0)), ("state", .string("running"))])]))
        #expect(status["budgets"] == .object([("live", .double(5.0)), ("stream", .double(1.5)), ("process", .double(4.0)),
                                              ("notes", .double(14.0)), ("index", .double(1.0))]))
        #expect(w.dog.costText() == "Palaver 3.9 GB")
    }

    @Test(arguments: [(0.0, 2.0), (9.0, 9.0), (20.0, 20.0)])
    func theStatusShowsTheNotesModelsNeedAsItsBudget(need: Double, shown: Double) {
        let dog = Watchdog(budgetsNow: { MemoryBudgets(config: [:], notes: need) }, sample: { _ in 1 }, own: { 1 })
        _ = dog.check([], now: 0)
        #expect(dog.status()!["budgets"]?["notes"] == .double(shown))
    }

    @Test func nothingIsMeasuredBeforeTheFirstCheck() {
        let w = Watch()
        #expect(w.dog.costText() == nil)
        #expect(w.dog.status()!["total"] == .null)
    }

    @Test func liveOverBudgetForAWhileIsRestartedOnceNotifiedOnce() {
        let w = Watch()
        w.used[11] = 5.5
        let live = worker("live", "/r/m1", 11)
        #expect(w.check(live) == [])  // a short spike passes
        #expect(w.dog.status()!["workers"]?.arrayValue?[0]["state"] == .string("over budget"))
        #expect(w.check(live, after: 5) == [])
        w.used[11] = 4.0
        #expect(w.check(live, after: 5) == [])  // back under: the count starts again
        w.used[11] = 5.5
        #expect(w.check(live, after: 5) == [])
        #expect(w.check(live, after: MemoryRules.overSeconds) == [])  // 10 s, but only two samples
        #expect(w.check(live, after: 1) == ["restart|live|m1"])
        #expect(w.check(live, after: 5) == [])  // asked once; it is on its way out
        #expect(w.logs.joined().contains("over its 5 GB budget"))
        // The new worker goes over too: restarted again, without a second notification.
        let new = worker("live", "/r/m1", 12)
        w.used[12] = 5.5
        #expect(w.sustain(new) == ["restart|live|m1"])
        #expect(w.last[0].title == "")
        #expect(w.check(new) == [])
    }

    @Test func manySamplesInAMomentAreNotEnough() {
        let w = Watch()
        w.used[11] = 5.5
        for _ in 0..<10 { #expect(w.check(worker("live", "/r/m1", 11), after: 0.5) == []) }
    }

    @Test func firstActionCarriesTheNotificationText() {
        let w = Watch()
        w.used[11] = 5.5
        let live = worker("live", "/r/m1", 11)
        w.check(live)
        w.now += MemoryRules.overSeconds
        w.check(live)
        let actions = w.dog.check([live], now: w.now)
        #expect(actions.count == 1 && actions[0].title == "Live transcription restarted")
        #expect(actions[0].message == "It used 5.5 GB, over its 5 GB budget. The recording goes on.")
    }

    @Test func liveThatKeepsPassingItsBudgetIsStoppedForGood() {
        let w = Watch()
        var whats: [String] = []
        for pid in Int32(20)..<Int32(20 + MemoryRules.maxRestarts + 1) {
            w.used[pid] = 6.0
            whats += w.sustain(worker("live", "/r/m1", pid))
        }
        #expect(whats == ["restart|live|m1", "restart|live|m1", "stop|live|m1"])
        #expect(w.last[0].title == "Live transcription stopped")
        #expect(w.last[0].message == "It used 6 GB, over its 5 GB budget. It kept passing its budget; the recording goes on. The transcript is written after the call.")
    }

    @Test func restartsCountPerMeeting() {
        let w = Watch()
        for (n, folder) in ["/r/a", "/r/b"].enumerated() {
            w.used[Int32(30 + n)] = 4.0
            #expect(w.sustain(worker("stream", folder, Int32(30 + n))) == ["restart|stream|\(folder.suffix(1))"])
        }
    }

    @Test func processOverBudgetIsLeftToFinishAndSaidOnce() {
        let w = Watch()
        w.used[40] = 13.0  // budget 4; plenty free
        let proc = worker("process", "/r/m1", 40)
        #expect(w.check(proc) == [])  // one sample is no reason
        #expect(w.sustain(proc) == ["warn|process|m1"])
        #expect(w.last[0].title == "Transcription uses more memory than planned")
        #expect(w.sustain(proc) == [])  // said once
        #expect(w.dog.status()!["workers"]?.arrayValue?[0]["state"] == .string("over budget"))
    }

    @Test(arguments: ["process", "notes"])
    func overBudgetUnderMemoryPressureIsStoppedAndTriedAgainThenGivenUp(kind: String) {
        let w = Watch()
        w.free = 1.0  // below PRESSURE_GB
        var whats: [String] = []
        for pid in Int32(50)..<Int32(50 + MemoryRules.maxRequeues + 1) {
            w.used[pid] = 20.0
            whats += w.sustain(worker(kind, "/r/m1", pid)).filter { !$0.hasPrefix("warn") }
        }
        #expect(whats == Array(repeating: "requeue|\(kind)|m1", count: MemoryRules.maxRequeues) + ["drop|\(kind)|m1"])
    }

    @Test func lowMemoryWithoutAWorkerOverBudgetStopsNothing() {
        let w = Watch()
        w.free = 0.5
        w.used[60] = 3.0
        #expect(w.sustain(worker("notes", "/r/m1", 60)) == [])
    }

    @Test func pressureMustLastToo() {
        let w = Watch()
        let notes = worker("notes", "/r/m1", 61)
        w.used[61] = 20.0
        _ = w.sustain(notes)  // over budget, plenty free: said
        w.free = 1.0
        #expect(w.check(notes, after: 1) == [])
        w.free = 8.0
        #expect(w.check(notes, after: 20) == [])  // the pressure passed
        w.free = 1.0
        #expect(w.sustain(notes) == ["requeue|notes|m1"])
    }

    @Test func freeMemoryIsOnlyAskedWhenAWorkerIsOverBudget() {
        let w = Watch()
        w.used[62] = 1.5
        _ = w.sustain(worker("process", "/r/m1", 62))
        #expect(w.asked == 0)
    }

    @Test func droppingSaysWhatToDo() {
        let w = Watch()
        w.free = 1.0
        var drops: [MemoryAction] = []
        for pid in Int32(70)..<Int32(70 + MemoryRules.maxRequeues + 1) {
            w.used[pid] = 20.0
            _ = w.sustain(worker("process", "/r/m1", pid))
            drops += w.last.filter { $0.what == "drop" }
        }
        #expect(drops.count == 1)
        #expect(drops[0].title == "Transcription stopped: the Mac kept running low on memory")
        #expect(drops[0].message == "m1: stopped 3 times. Close other apps, then run `palaver process` on it.")
    }

    @Test func requeueTextsSayWhatWasFree() {
        let w = Watch()
        w.free = 1.0
        w.used[75] = 20.0
        _ = w.sustain(worker("notes", "/r/m1", 75))
        #expect(w.last[0].title == "Notes paused: the Mac is low on memory")
        #expect(w.last[0].message == "It used 20 GB (budget 14 GB) while only 1 GB were free. They are written again later.")
    }

    @Test func aPerMeetingBudgetHookDecides() {
        let w = Watch(budgetFor: { kind, _ in kind == "notes" ? 20.0 : nil })
        w.used[80] = 16.0
        #expect(w.sustain(worker("notes", "/r/m1", 80)) == [])
        #expect(w.dog.status()!["workers"]?.arrayValue?[0]["budget"] == .double(20.0))
    }

    /// #26: notes by the Claude Code CLI, then the projects sort on Gemma in the same worker (10-11 GB), budgeted as
    /// the daemon does it (`notes-memory` of the meeting, and of the Recordings folder for the default): no warning,
    /// no notification. Settings in a temporary folder.
    @Test(arguments: [[("notes", "claude-cli"), ("projects", "local")], []])
    func aNotesRunOnTheLocalModelIsNotOverBudget(engines: [(String, String)]) throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let stores = StorePaths(configDir: dir.appendingPathComponent("config"), home: dir.appendingPathComponent("home"))
        try SettingsFile.update([("engines", .object(engines.map { ($0.0, .string($0.1)) }))], stores: stores)
        var config = Config()
        config.outputDir = dir.appendingPathComponent("Recordings", isDirectory: true)
        let meeting = config.outputDir.appendingPathComponent("2026-11-10T15-00-41", isDirectory: true)
        mkdir(meeting)
        let need: (URL) -> Double? = { Queries.notesMemory(folder: $0, config: config, stores: stores)["gb"]?.doubleValue }
        var logs: [String] = []
        var used = 10.0
        let dog = Watchdog(MemoryBudgets(config: config.memory),
                           budgetsNow: { MemoryBudgets(config: config.memory, notes: need(config.outputDir)) },
                           sample: { _ in Int(used * GB) }, own: { 0 }, others: { _ in 0 }, freeGB: { 20 },
                           budgetFor: memoryBudgetHook(config: config.memory, notesInRun: { false },
                                                       need: { need(URL(fileURLWithPath: $0, isDirectory: true)) }),
                           log: { logs.append($1) })
        let notes = worker("notes", meeting.path, 60)
        var actions: [MemoryAction] = []
        for (n, gb) in [10.0, 10.5, 11.0, 11.0, 10.0].enumerated() {
            used = gb
            actions += dog.check([notes], now: Double(n) * MemoryRules.overSeconds)
        }
        #expect(actions.isEmpty)
        #expect(logs.isEmpty)
        #expect(dog.status()!["workers"]?.arrayValue?[0]["budget"] == .double(14.0))
        #expect(dog.budgets.notes == 14.0)
    }

    @Test func aWorkerGoneIsSkipped() {
        let w = Watch()
        #expect(w.check(worker("stream", "/r/m1", 99)) == [])
        #expect(w.dog.status()!["workers"] == .array([]))
    }

    @Test func statusForgetsWorkersThatAreGone() {
        let w = Watch()
        w.used[11] = 1.0
        w.check(worker("live", "/r/m1", 11))
        w.check()
        #expect(w.dog.status()!["workers"] == .array([]))
    }

    @Test func watchdogCountsPalaverWorkerAsTheWorkerKind() throws {
        // The daemon starts `process` as palaver-worker: what it watches is the kind it launched, judged by that kind's
        // budget, whatever program runs it; and its command line is still one of Palaver's processes (a `process` from
        // before a restart is found by it).
        let b = try build(autoSync: false, worker: WORKER)
        let rec = URL(fileURLWithPath: "/r/m1", isDirectory: true)
        let started = try b.daemon.deps.launchProcessing(rec)
        let argv = b.spawned.calls[0].args
        #expect(argv[0] == WORKER && argv.contains("process"))
        #expect(Processes.matches(Processes.palaverWord, argv.joined(separator: " ")))
        let w = Watch()
        w.used[started.pid] = 5.0  // over the 4 GB `process` budget
        #expect(w.sustain(DaemonWorker(kind: "process", folder: rec.path, process: started)) == ["warn|process|m1"])
        #expect(w.last[0].limit == MemoryRules.defaultProcessGB)
    }

    @Test func aHelperChildCountsInTheProcessBudget() {
        // palaver-worker process (pid 60) runs a helper (pid 61, in the worker's process group; the notes helper until
        // phase 4 batch 5): each alone is under the 4 GB budget, together they are over it.
        let sizes: [Int32: Double] = [60: 2.5, 61: 2.0]
        let kids: [Int32: [Int32]] = [60: [61], 61: []]
        let tree: (Int32) -> Int? = { pid in
            MemoryMeasure.tree(pid, sample: { sizes[$0].map { Int($0 * GB) } }, children: { kids[$0] ?? [] })
        }
        #expect(tree(60) == Int(2.5 * GB) + Int(2.0 * GB))
        var actions: [MemoryAction] = []
        let dog = Watchdog(MemoryBudgets(), sample: tree, own: { 0 }, others: { _ in 0 }, freeGB: { 30 })
        let proc = DaemonWorker(kind: "process", folder: "/r/m1", process: Proc(60))
        let step = MemoryRules.overSeconds / Double(MemoryRules.overSamples - 1)
        for n in 0..<MemoryRules.overSamples { actions = dog.check([proc], now: Double(n) * step) }
        #expect(actions.map(\.what) == ["warn"] && actions[0].used == tree(60)!)
        #expect(Double(actions[0].used) / GB > dog.budget("process", "/r/m1"))
        #expect(dog.status()?["workers"]?.arrayValue?.count == 1)  // the helper is no worker of its own
    }

    @Test func theSearchIndexHasASmallBudgetEnforcedOnlyWhenTheMacRunsLow() {
        let b = MemoryBudgets(config: ["index_gb": 2])
        #expect(MemoryBudgets().index == 1.0 && b.index == 2.0)
        let w = Watch()
        w.used[90] = 1.5
        let index = worker("index", nil, 90)
        #expect(w.sustain(index) == ["warn|index|search index"])
        #expect(w.last[0].title == "The search index uses more memory than planned")
        w.free = 1.0
        #expect(w.sustain(index) == ["requeue|index|search index"])
        var whats: [String] = []
        for pid in [Int32(91), 92] {
            w.used[pid] = 1.5
            whats += w.sustain(worker("index", nil, pid)).filter { !$0.hasPrefix("warn") }.map { String($0.split(separator: "|")[0]) }
        }
        #expect(whats == ["requeue", "drop"])
        #expect(w.last[0].title == "Search index paused: the Mac kept running low on memory")
        #expect(w.last[0].message == "Stopped 3 times. It is built again when Palaver starts next; search by words works meanwhile.")
    }

    @Test func aQuestionHelperIsStoppedQuietlyAndCountedAgainstNothing() {
        let w = Watch()
        w.free = 1.0
        w.used[95] = 20.0
        #expect(w.sustain(worker("question", "/r/m1", 95)) == ["stop|question|m1"])
        #expect(w.last[0].title == "" && w.last[0].message == "")
        #expect(w.dog.requeueCount("notes", "/r/m1") == 0)
        #expect(w.dog.budget("question", "/r/m1") == w.dog.budget("notes", "/r/m1"))
    }
}
