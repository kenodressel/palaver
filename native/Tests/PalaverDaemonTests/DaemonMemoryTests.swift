// tests/test_daemon_memory.py: the workers the daemon started keep to their budgets, and the
// recording never stops because of them. Fake workers, fake samples, fake free memory.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDaemon

private let GB = MemoryRules.gb

/// A worker with a pid: it exits on SIGTERM unless `stubborn`; signals arrive as group signals.
final class MemWorker: WorkerProcess {
    let pid: Int32
    let stubborn: Bool
    var rc: Int32?
    var folder = ""
    var terminated = false
    var killed = false
    var groupSignals: [Int32] = []

    init(_ pid: Int32, stubborn: Bool = false) { self.pid = pid; self.stubborn = stubborn }
    func poll() -> Int32? { rc }
    func terminate() { terminated = true; if !stubborn { rc = -15 } }
    func kill() { killed = true; rc = -9 }
    func signalGroup(_ sig: Int32) {
        groupSignals.append(sig)
        if sig == SIGKILL { killed = true; rc = -9 } else if !stubborn { rc = -15 }
    }
}

final class MemRig {
    let h: Harness
    var used: [Int32: Double] = [:]
    var free: Double
    var workers: [String: [MemWorker]] = ["live": [], "stream": [], "process": [], "notes": [], "index": []]
    private var nextPid: Int32 = 100
    var launchers: [String: (URL) -> WorkerProcess] = [:]
    var notesMemory: Double?
    var indexWanted = false
    var lowWhileIndexing = false
    var dog: Watchdog!

    func starter(_ kind: String, _ gb: Double = 1.0, stubborn: Bool = false) -> (URL) -> WorkerProcess {
        { [unowned self] folder in
            let w = MemWorker(nextPid, stubborn: stubborn)
            nextPid += 1
            w.folder = folder.path
            workers[kind]!.append(w)
            used[w.pid] = gb
            return w
        }
    }

    init(_ dir: URL, activity: @escaping (Double) -> CallApp? = teams { 10 <= $0 && $0 < 700 },
         budgets: MemoryBudgets = MemoryBudgets(), free: Double = 30, notesMemory: Double? = nil,
         notesQueued: [String] = [], queued: [String] = [], indexWanted: Bool = false) throws {
        self.free = free
        self.notesMemory = notesMemory
        self.indexWanted = indexWanted
        writeJSON(dir.appendingPathComponent("state.json"), ["state": "idle", "queued": queued, "notes_queued": notesQueued])
        var me: MemRig?
        h = try Harness(dir, activity: activity) { deps, h in
            deps.memoryFreeGB = { me!.currentFree }
            if let n = notesMemory { deps.notesMemoryGB = { _ in n } }
            deps.realtime = { true }
            deps.launchNotes = { me!.launchers["notes"]!($0) }
            deps.launchLive = { me!.launchers["live"]!($0) }
            deps.launchStream = { me!.launchers["stream"]!($0) }
            if indexWanted {
                deps.launchIndex = { me!.launchers["index"]!(dir) }
                deps.indexWanted = { true }
            }
            deps.liveRunning = { folder in me!.workers["live"]!.contains { $0.folder == folder.path && $0.rc == nil } }
            deps.watchdog = Watchdog(
                budgets, sample: { pid in me!.used[pid].map { Int($0 * GB) } },
                own: { Int(0.25 * GB) }, others: { _ in 0 }, freeGB: { me!.currentFree })
        }
        me = self
        dog = h.daemon.deps.watchdog as? Watchdog
        launchers["live"] = starter("live", 1.2)
        launchers["stream"] = starter("stream", 1.0)
        launchers["notes"] = starter("notes", 1.0)
        launchers["index"] = starter("index", 1.0)
        h.launchProcessing = { [unowned self] in launchers["process"]!($0) }
        launchers["process"] = starter("process", 1.0)
    }

    var currentFree: Double {
        lowWhileIndexing ? (workers["index"]!.contains { $0.rc == nil } ? 1.0 : 30.0) : free
    }

    func run(until t: Double) async { await h.run { $0 > t } }
    var sentTitles: [String] { h.titles }
}

private let OVER = MemoryRules.overSeconds

private func folder(_ dir: URL, _ name: String = "m1") -> URL {
    let f = dir.appendingPathComponent(name, isDirectory: true)
    mkdir(f)
    return f
}

extension DaemonTicks {
    @Suite struct DaemonMemoryTests {
        @Test func aLiveWorkerOverBudgetIsRestartedAndTheRecordingGoesOn() async throws {
            let r = try MemRig(tempDir())
            await r.run(until: 30)
            let first = try #require(r.workers["live"]!.first)
            r.used[first.pid] = 3.0  // over its 2 GB
            await r.run(until: 30 + OVER + 10)
            #expect(first.groupSignals.first == SIGTERM)
            #expect(r.workers["live"]!.count == 2 && r.workers["live"]![1].folder == r.h.sessions[0].folder.path)
            #expect(!r.h.sessions[0].stopped)  // capture runs in the recorder, not in the worker
            #expect(r.h.status()["state"]?.stringValue == "recording")
            #expect(r.sentTitles.filter { $0 == "Live transcription restarted" }.count == 1)
            #expect(r.workers["stream"]!.count == 1)  // the other worker is left alone
            r.h.daemon.shutdown()
        }

        @Test func aStreamOverBudgetIsRestarted() async throws {
            let r = try MemRig(tempDir())
            await r.run(until: 30)
            r.used[r.workers["stream"]![0].pid] = 4.0  // over its 1.5 GB
            await r.run(until: 30 + OVER + 10)
            #expect(r.workers["stream"]![0].groupSignals.first == SIGTERM && r.workers["stream"]!.count == 2)
            #expect(r.sentTitles.contains("Realtime transcription restarted"))
            r.h.daemon.shutdown()
        }

        @Test func aWorkerThatIgnoresSigtermIsKilledThenRestarted() async throws {
            let r = try MemRig(tempDir())
            r.launchers["live"] = r.starter("live", 1.2, stubborn: true)
            await r.run(until: 30)
            let first = r.workers["live"]![0]
            r.used[first.pid] = 3.0
            await r.run(until: 30 + OVER + 4)
            #expect(first.groupSignals == [SIGTERM] && !first.killed && r.workers["live"]!.count == 1)  // given time to exit
            await r.run(until: 30 + OVER + 30)
            #expect(first.killed && first.groupSignals == [SIGTERM, SIGKILL] && r.workers["live"]!.count == 2)
            r.h.daemon.shutdown()
        }

        @Test func aWorkerIsNotRestartedOnceTheRecordingStopped() async throws {
            // After the stop, `process` does what a live worker did not; nobody is told of a restart that did not happen.
            let r = try MemRig(tempDir(), activity: teams { 10 <= $0 && $0 < 40 })
            r.launchers["live"] = r.starter("live", 1.2, stubborn: true)
            await r.run(until: 30)
            r.used[r.workers["live"]![0].pid] = 3.0
            await r.run(until: 120)
            #expect(r.h.sessions[0].stopped && r.workers["live"]![0].killed)
            #expect(r.workers["live"]!.count == 1)
            #expect(!r.sentTitles.contains("Live transcription restarted"))
        }

        @Test func workersAreSignalledAsAProcessGroup() async throws {
            // Workers start in their own session: their helpers go with them.
            let r = try MemRig(tempDir())
            await r.run(until: 30)
            let first = r.workers["live"]![0]
            r.used[first.pid] = 3.0
            await r.run(until: 30 + OVER + 4)
            #expect(first.groupSignals.contains(SIGTERM) && !first.terminated)
            r.h.daemon.shutdown()
        }

        @Test func notesOverBudgetWithMemoryToSpareFinish() async throws {
            let dir = tempDir()
            let f = folder(dir)
            let r = try MemRig(dir, activity: { _ in nil }, notesMemory: 14, notesQueued: [f.path])
            r.launchers["notes"] = r.starter("notes", 16.0)  // over the model's 14 GB
            await r.run(until: 60)
            #expect(r.workers["notes"]!.count == 1 && r.workers["notes"]![0].groupSignals.isEmpty)
            #expect(r.sentTitles.filter { $0 == "Notes use more memory than planned" }.count == 1)
        }

        @Test func notesOverBudgetWhileTheMacRunsLowWaitInTheQueue() async throws {
            let dir = tempDir()
            let f = folder(dir)
            let r = try MemRig(dir, activity: { _ in nil }, notesMemory: 14, notesQueued: [f.path])
            r.launchers["notes"] = r.starter("notes", 9.0)
            await r.run(until: 10)
            let notes = try #require(r.workers["notes"]!.first)
            r.used[notes.pid] = 16.0
            r.free = 1.0  // the Mac is out of memory
            await r.run(until: 10 + OVER + 10)
            #expect(notes.groupSignals.first == SIGTERM)
            #expect(r.h.status()["notes_queued"] == .strings([f.path]))
            #expect(r.sentTitles.contains("Notes paused: the Mac is low on memory"))
            await r.run(until: 10 + OVER + 90)  // past the backoff; still low
            #expect(r.workers["notes"]!.count == 1)
            let rows = r.h.status()["memory"]?["workers"]?.arrayValue ?? []
            #expect(rows.contains { $0["kind"]?.stringValue == "notes" && $0["state"]?.stringValue == "waiting for memory" })
            r.free = 30.0  // memory came back: the normal gate lets them run
            await r.run(until: 10 + OVER + 100)
            #expect(r.workers["notes"]!.count == 2 && r.workers["notes"]![1].folder == f.path)
        }

        @Test func notesStoppedThreeTimesAreGivenUpWithWhatToDo() async throws {
            let dir = tempDir()
            let f = folder(dir)
            let r = try MemRig(dir, activity: { _ in nil }, free: 1.0, notesMemory: 0, notesQueued: [f.path])
            r.launchers["notes"] = r.starter("notes", 20.0)
            await r.run(until: 3600)
            #expect(r.workers["notes"]!.count == 3)
            #expect(r.h.status()["notes_queued"] == .strings([]))
            let given = r.h.notifications.filter { $0.title.hasPrefix("Notes not written") }
            #expect(given.count == 1)
            #expect(given[0].message.contains("Write notes") && given[0].message.contains("3 times"))
        }

        @Test func processOverBudgetWithMemoryToSpareFinishes() async throws {
            let dir = tempDir()
            let f = folder(dir)
            let r = try MemRig(dir, activity: { _ in nil }, queued: [f.path])
            r.launchers["process"] = r.starter("process", 13.0)
            await r.run(until: 60)
            #expect(r.workers["process"]!.count == 1 && r.workers["process"]![0].groupSignals.isEmpty)
            #expect(r.sentTitles.filter { $0 == "Transcription uses more memory than planned" }.count == 1)
        }

        @Test func processOverBudgetWhileTheMacRunsLowIsStoppedAndTriedAgain() async throws {
            let dir = tempDir()
            let f = folder(dir)
            let r = try MemRig(dir, activity: { _ in nil }, free: 1.0, queued: [f.path])
            r.launchers["process"] = r.starter("process", 13.0, stubborn: true)
            await r.run(until: 14)
            let first = try #require(r.workers["process"]!.first)
            #expect(first.groupSignals.first == SIGTERM && r.h.status()["queued"] == .strings([f.path]))
            await r.run(until: 40)
            #expect(first.killed && r.workers["process"]!.count == 1)  // one at a time, then a backoff
            #expect(!r.sentTitles.contains("Transcription failed"))
            r.free = 30.0
            r.launchers["process"] = r.starter("process", 2.0)
            await r.run(until: 120)
            #expect(r.workers["process"]!.count == 2 && r.workers["process"]![1].folder == f.path)
        }

        @Test func processStoppedThreeTimesIsGivenUpWithWhatToDo() async throws {
            let dir = tempDir()
            let f = folder(dir)
            let r = try MemRig(dir, activity: { _ in nil }, free: 1.0, queued: [f.path])
            r.launchers["process"] = r.starter("process", 13.0)
            await r.run(until: 3600)
            #expect(r.workers["process"]!.count == 3)
            #expect(r.h.status()["queued"] == .strings([]))
            #expect(r.sentTitles.contains("Transcription stopped: the Mac kept running low on memory"))
            #expect(!r.sentTitles.contains("Transcription failed"))
            let failed = ProcessState.read(f)  // the window offers to try again
            #expect(failed?["reason"]?.stringValue == ProcessState.error)
            #expect(failed?["error"]?.stringValue == "stopped too often: the Mac was low on memory")
        }

        @Test func statusShowsWhatPalaverCosts() async throws {
            let r = try MemRig(tempDir())
            await r.run(until: 30)
            let status = r.h.status()
            let mem = try #require(status["memory"])
            #expect(mem["total"] == .int(Int(0.25 * GB) + Int(1.2 * GB) + Int(1.0 * GB)))
            let states = mem["workers"]?.arrayValue?.map { "\($0["kind"]!.stringValue!)=\($0["state"]!.stringValue!)" }
            #expect(states == ["live=running", "stream=running"])
            #expect(status["why_text"]?.stringValue?.hasSuffix(" \u{00B7} Palaver 2.4 GB") == true)
            r.h.daemon.shutdown()
        }

        @Test func withoutAWatchdogNothingIsMeasured() async throws {
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 700 })
            await h.run { $0 > 30 }
            #expect(h.status()["memory"] == .null)
            #expect(h.status()["why_text"]?.stringValue?.contains("Palaver") == false)
            h.daemon.shutdown()
        }

        @Test func theSearchIndexOverBudgetFinishesWhileMemoryIsFree() async throws {
            let r = try MemRig(tempDir(), activity: { _ in nil }, indexWanted: true)
            r.launchers["index"] = r.starter("index", 1.6)  // over its 1 GB
            r.h.daemon.indexCheckSeconds = 5
            await r.run(until: 60)
            #expect(r.workers["index"]!.count == 1 && r.workers["index"]![0].groupSignals.isEmpty)
            #expect(r.h.status()["indexing"] == .bool(true))
            #expect(r.h.status()["memory"]?["workers"]?.arrayValue?.contains { $0["kind"]?.stringValue == "index" } == true)
        }

        @Test func theSearchIndexIsPausedWhenTheMacRunsLowThenGivenUp() async throws {
            // Low on memory only while it runs: it starts again after its backoff.
            let r = try MemRig(tempDir(), activity: { _ in nil }, indexWanted: true)
            r.lowWhileIndexing = true
            r.launchers["index"] = r.starter("index", 1.6)
            r.h.daemon.indexCheckSeconds = 5
            await r.run(until: 40)
            #expect(r.workers["index"]![0].groupSignals.first == SIGTERM && r.h.status()["indexing"] == .bool(false))
            #expect(r.workers["index"]!.count == 1)  // backoff
            await r.run(until: 3600)
            #expect(r.workers["index"]!.count == 3)  // then it is given up for this run of Palaver
            #expect(r.sentTitles.contains("Search index paused: the Mac kept running low on memory"))
        }

        @Test func theBestNextQuestionHelperHasTheNotesBudget() async throws {
            let r = try MemRig(tempDir(), notesMemory: 14)
            await r.run(until: 20)
            let helper = MemWorker(4242)
            r.used[helper.pid] = 9.0
            let sessionFolder = r.h.sessions[0].folder.path
            r.h.daemon.watchHelper(folder: sessionFolder, process: helper)
            #expect(r.h.daemon.workers().contains { $0.kind == "question" && $0.folder == sessionFolder && $0.process === helper })
            await r.run(until: 30)
            #expect(helper.groupSignals.isEmpty)
            r.used[helper.pid] = 16.0
            r.free = 1.0
            await r.run(until: 30 + OVER + 10)
            #expect(helper.groupSignals.first == SIGTERM)
            #expect(r.h.status()["notes_queued"] == .strings([]))  // a question is not notes to write later
            #expect(!r.sentTitles.contains { $0.hasPrefix("Notes") })
            await r.run(until: 30 + OVER + 30)
            #expect(!r.h.daemon.workers().contains { $0.process === helper })  // gone once it exited
            #expect(!r.h.sessions[0].stopped)
            r.h.daemon.shutdown()
        }

        @Test func aStoppedQuestionNeverCountsAgainstTheMeetingsNotes() async throws {
            // Two helpers stopped for low memory leave that meeting's notes their own three tries.
            let dir = tempDir()
            let f = folder(dir)
            let r = try MemRig(dir, activity: { _ in nil }, free: 1.0, notesMemory: 0)
            #expect(r.dog.budget("question", f.path) == r.dog.budget("notes", f.path))
            for pid in [Int32(5001), 5002] {
                let helper = MemWorker(pid)
                r.used[pid] = 20.0
                r.h.daemon.watchHelper(folder: f.path, process: helper)
                let start = r.h.clock
                await r.run(until: start + OVER + 10)
                #expect(helper.groupSignals.first == SIGTERM)
            }
            #expect(r.dog.requeueCount("notes", f.path) == 0)
            #expect(!r.sentTitles.contains { $0.hasPrefix("Notes") })
        }

        @Test func notesRunNormallyAfterStoppedQuestions() async throws {
            let dir = tempDir()
            let f = folder(dir)
            let r = try MemRig(dir, activity: { _ in nil }, free: 1.0, notesMemory: 0, notesQueued: [f.path])
            // The queued notes would start at once; hold them back while the helpers are stopped.
            r.launchers["notes"] = r.starter("notes", 9.0)
            for pid in [Int32(6001), 6002] {
                let helper = MemWorker(pid)
                r.used[pid] = 20.0
                r.h.daemon.watchHelper(folder: f.path, process: helper)
                let start = r.h.clock
                await r.run(until: start + OVER + 10)
            }
            r.free = 30.0  // memory came back
            let start = r.h.clock
            await r.run(until: start + 60)
            let notes = try #require(r.workers["notes"]!.last)
            #expect(notes.folder == f.path && notes.groupSignals.isEmpty)
        }
    }
}
