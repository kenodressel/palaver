// test_daemon.py's build_daemon / launch_run tests: the worker commands, their QoS and the
// forwarded options; run vs process + notes; the Python facts asked in the background; app.sock's
// actions over the daemon. Nothing is spawned (the launcher records), no capture device is opened.
import Foundation
import Testing
import PalaverCapture
import PalaverCore
@testable import PalaverDaemon

final class Spawned: @unchecked Sendable {
    var calls: [(args: [String], qos: QoS)] = []
    var nextPid: Int32 = 700
}

func recordingLauncher(_ spawned: Spawned, options: [String] = ["--config", "/w.toml", "--no-notify"]) -> WorkerLauncher {
    WorkerLauncher(python: "/Applications/Palaver.app/Contents/MacOS/palaver-python", cliOptions: options,
                   log: URL(fileURLWithPath: "/tmp/daemon.log"), env: ["PALAVER_APP": "/Applications/Palaver.app"],
                   spawn: { args, qos in
                       spawned.calls.append((args, qos))
                       spawned.nextPid += 1
                       return FakeWorker(pid: spawned.nextPid)
                   })
}

struct Built {
    let daemon: Daemon
    let spawned: Spawned
    let home: URL
}

func build(autoSync: Bool = false, notes: Bool = true, answer: AutoSyncAnswer? = nil, settings: [String: Any] = [:], options: [String] = ["--config", "/w.toml", "--no-notify"],
           sources: ((Daemon?) -> CaptureSources)? = nil, configure: (inout Config) -> Void = { _ in }) throws -> Built {
    let home = tempDir()
    let paths = Paths(home: home)
    var config = Config()
    config.outputDir = home.appendingPathComponent("Meetings/Recordings", isDirectory: true)
    configure(&config)
    try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
    writeJSON(paths.settingsJson, settings)
    let spawned = Spawned()
    let facts = PythonFacts(query: { _ in [:] })
    let detector = CallDetector(lister: FakeLister { [] })
    let d = try DaemonFactory.build(config: config, settings: Settings(url: paths.settingsJson, defaults: config), paths: paths,
                                    launcher: recordingLauncher(spawned, options: options), facts: facts,
                                    notion: answer ?? AutoSyncAnswer(autoSync: autoSync, notes: notes), detector: detector, version: "0.4.0", notify: { _, _, _ in }, log: { _, _ in },
                                    sources: sources)
    return Built(daemon: d, spawned: spawned, home: home)
}

@Suite struct LaunchTests {
    let rec = URL(fileURLWithPath: "/m/rec", isDirectory: true)
    let python = "/Applications/Palaver.app/Contents/MacOS/palaver-python"

    @Test func launchRunForwardsCliOptions() async throws {
        let spawned = Spawned()
        _ = try recordingLauncher(spawned).launch("run", rec)
        #expect(spawned.calls[0].args == [python, "-m", "palaver", "--config", "/w.toml", "--no-notify", "run", "/m/rec"])
        #expect(WorkerLauncher.forwardedOptions(config: "/w.toml", dictionary: nil, noNotify: true) == ["--config", "/w.toml", "--no-notify"])
        #expect(WorkerLauncher.forwardedOptions(config: nil, dictionary: nil, noNotify: false).isEmpty)
    }

    @Test func buildDaemonProcessesLocallyWithoutAutoSyncAndLeavesTheNotesForLater() async throws {
        let b = try build(autoSync: false)
        _ = try b.daemon.deps.launchProcessing(rec)
        let notes = try #require(b.daemon.deps.launchNotes)
        _ = try notes(rec)
        #expect(b.spawned.calls.map { Array($0.args.suffix(3)) } == [["process", "/m/rec", "--no-notes"], ["--no-notify", "notes", "/m/rec"]])
        #expect(b.spawned.calls.map(\.qos) == [.utility, .utility])
        #expect(b.daemon.deps.doneMarker() == "transcript.md" && b.daemon.deps.notesWanted())
    }

    @Test func withAutoSyncRunUploadsAndWritesTheNotesItself() async throws {
        let b = try build(autoSync: true)
        _ = try b.daemon.deps.launchProcessing(rec)
        #expect(b.spawned.calls[0].args.suffix(2) == ["run", "/m/rec"])
        #expect(!b.daemon.deps.notesWanted())
        #expect(b.daemon.deps.doneMarker() == "notion.json")
        let off = try build(autoSync: false, notes: false)
        #expect(!off.daemon.deps.notesWanted())  // [notes].enabled = false
    }

    @Test func theNotionAnswerIsReadWhenAWorkerStartsNotWhenTheAppStarts() async throws {
        // The app starts with the last answer (or config.toml's) and asks Python in the background.
        let answer = AutoSyncAnswer(autoSync: false, notes: true)
        let b = try build(answer: answer)
        _ = try b.daemon.deps.launchProcessing(rec)
        #expect(b.daemon.deps.doneMarker() == "transcript.md" && b.daemon.deps.notesWanted())
        answer.set(.init(autoSync: true, notes: true))
        _ = try b.daemon.deps.launchProcessing(rec)
        #expect(b.spawned.calls.map { Array($0.args.suffix(2)) } == [["/m/rec", "--no-notes"], ["run", "/m/rec"]])
        #expect(b.daemon.deps.doneMarker() == "notion.json" && !b.daemon.deps.notesWanted())
    }

    @Test func backgroundWorkRunsAtLowPriority() async throws {
        let b = try build(autoSync: false, options: [])
        _ = try b.daemon.deps.launchLive!(rec)
        _ = try b.daemon.deps.launchStream!(rec)
        _ = try b.daemon.deps.launchIndex!()
        #expect(b.spawned.calls.map(\.qos) == [.background, .utility, .background])
        #expect(b.spawned.calls.map(\.args) == [[python, "-m", "palaver", "live", "/m/rec"], [python, "-m", "palaver", "stream", "/m/rec"],
                                                [python, "-m", "palaver", "index"]])
    }

    @Test func theSwitchesAreReadFromTheSettingsFile() async throws {
        // config.toml's [processing].live is the default; settings.json wins, read at each recording's start.
        let b = try build(autoSync: false, settings: ["realtime": false]) { $0.processingLive = false }
        #expect(b.daemon.deps.realtime() == false && b.daemon.deps.live() == false)
        let paths = Paths(home: b.home)
        writeJSON(paths.settingsJson, ["realtime": true, "live_processing": true])
        let later = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: paths.settingsJson.path)
        #expect(b.daemon.deps.realtime() == true && b.daemon.deps.live() == true)
    }

    @Test func buildDaemonKeepsItsStateAtTheAppSupportPath() async throws {
        let b = try build(autoSync: false)
        #expect(b.daemon.deps.statePath == Paths(home: b.home).daemonJson)
        #expect(b.daemon.trigger.grace == 10 && b.daemon.trigger.maxSession == 4 * 3600 && b.daemon.trigger.startAfter == 4)
        let custom = try build(autoSync: false) { $0.gracePeriodSeconds = 20; $0.maxSessionHours = 2 }
        #expect(custom.daemon.trigger.grace == 20 && custom.daemon.trigger.maxSession == 2 * 3600)
    }

    @Test func theTapLeavesOutTheAppAndItsWorkers() async throws {
        // Asked when the tap starts: the app's own pid and the workers it runs.
        var excluded: [pid_t] = []
        let b = try build(autoSync: false, settings: ["realtime": false], sources: { daemon in
            CaptureSources(systemTap: { _ in excluded = daemon?.excludedPIDs() ?? []; return NullSource() },
                           mic: { _ in NullSource() }, screenCapture: { _, _ in NoScreenCapture() })
        })
        let queued = b.daemon.deps.outputDir!.appendingPathComponent("2026-11-04T08-00-00")
        mkdir(queued)
        #expect(b.daemon.transcribeAgain(queued))
        b.daemon.pumpProcessing()  // `process` runs: pid 701
        #expect(b.daemon.startManual())
        #expect(excluded == [getpid(), 701])
        let folder = try #require(b.daemon.state.folder)
        #expect(b.spawned.calls.contains { $0.args.suffix(2) == ["live", folder] })
        // The recording's own live worker starts after the tap (harmless: it plays no audio); later taps leave it out.
        #expect(b.daemon.excludedPIDs() == [getpid(), 702, 701])
        b.daemon.stopManual()
        #expect(exists(URL(fileURLWithPath: folder).appendingPathComponent("meta.json")))
        let usage = rows(Paths(home: b.home).support.appendingPathComponent("usage.jsonl"))
        #expect(usage.map { $0["kind"] as? String } == ["recording_start", "recording_stop"])
    }
}

@Suite struct PythonFactsTests {
    final class Asked: @unchecked Sendable {
        let lock = NSLock()
        var whats: [[String]] = []
        func add(_ w: [String]) { lock.withLock { whats.append(w) } }
        var count: Int { lock.withLock { whats.count } }
    }

    func waitFor(_ timeout: Double = 30, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if ok() { return true }; usleep(5000) }
        return ok()
    }

    @Test func anAnswerIsAskedInTheBackgroundOnceAndKept() async throws {
        let asked = Asked()
        let clock = Clock(0)
        let facts = PythonFacts(query: { what in
            asked.add(what)
            if what[0] == "notes-memory" { return ["gb": 14.0] }
            if what[0] == "missing-models" { return ["missing": what[1] == "/m/a" ? ["Speech models"] : []] }
            return ["stale": ["/m/a"], "model_ready": false]
        }, clock: { clock.now })
        #expect(facts.notesMemoryGB(URL(fileURLWithPath: "/m/a")) == nil)  // being asked
        #expect(facts.notesMemoryGB(URL(fileURLWithPath: "/m/a")) == nil)
        #expect(waitFor { facts.notesMemoryGB(URL(fileURLWithPath: "/m/a")) == 14 })
        #expect(asked.count == 1)  // one question at a time, then kept
        clock.now = 61
        _ = facts.notesMemoryGB(URL(fileURLWithPath: "/m/a"))  // a minute later: asked again
        #expect(waitFor { asked.count == 2 })
        _ = facts.modelsReady(URL(fileURLWithPath: "/m/a")); _ = facts.modelsReady(URL(fileURLWithPath: "/m/b"))
        #expect(waitFor { facts.modelsReady(URL(fileURLWithPath: "/m/a")) == false && facts.modelsReady(URL(fileURLWithPath: "/m/b")) == true })
        #expect(asked.whats.contains(["missing-models", "/m/a"]))
        _ = facts.indexWanted()
        #expect(waitFor { facts.indexWanted() == true })
        #expect(facts.indexModelReady() == false)
    }

    @Test func notesMemoryKeepsServingTheLastAnswerWhileItRefreshes() async throws {
        let asked = Asked()
        let clock = Clock(0)
        let gate = DispatchSemaphore(value: 0)
        let fail = Asked()
        let facts = PythonFacts(query: { what in
            asked.add(what)
            if asked.count == 2 { gate.wait() }  // the refresh takes a while
            if fail.count > 0 { throw NSError(domain: "down", code: 1) }
            return ["gb": 12.0]
        }, clock: { clock.now })
        let a = URL(fileURLWithPath: "/m/a")
        #expect(facts.notesMemoryGB(a) == nil)  // never answered: not known yet
        #expect(waitFor { facts.notesMemoryGB(a) == 12 })
        clock.now = 61
        #expect(facts.notesMemoryGB(a) == 12)  // expired: still served, a refresh starts
        #expect(waitFor { asked.count == 2 })
        #expect(facts.notesMemoryGB(a) == 12)  // and while it runs
        fail.add(["x"])
        gate.signal()
        try await Task.sleep(nanoseconds: 300_000_000)  // the failed refresh is over
        clock.now = 130
        #expect(waitFor { _ = facts.notesMemoryGB(a); return asked.count >= 3 })
        #expect(facts.notesMemoryGB(a) == 12)  // a failed refresh keeps the last answer
    }

    @Test func aFailingQueryFallsBackAndAWrongSettingAsksNothing() async throws {
        let asked = Asked()
        struct Down: Error {}
        let facts = PythonFacts(query: { what in asked.add(what); throw Down() })
        _ = facts.notesMemoryGB(URL(fileURLWithPath: "/m/a"))
        #expect(waitFor { facts.notesMemoryGB(URL(fileURLWithPath: "/m/a")) == 20 })  // NOTES_MEMORY_GB
        _ = facts.modelsReady(URL(fileURLWithPath: "/m/a"))
        #expect(waitFor { facts.modelsReady(URL(fileURLWithPath: "/m/a")) == true })  // `process` finds out
        facts.searchMeaning = { false }
        facts.calendarEnabled = { false }
        let before = asked.count
        #expect(facts.indexWanted() == false && facts.eventKey(at: WALL0) == .known(nil))
        #expect(asked.count == before)
    }

    @Test func theEventKeyIsAskedWithoutBlocking() async throws {
        let facts = PythonFacts(query: { what in ["key": "u|2026-10-29", "asked": what] })
        _ = facts.eventKey(at: WALL0)
        #expect(waitFor { facts.eventKey(at: WALL0) == .known("u|2026-10-29") })
        let slow = PythonFacts(query: { _ in Thread.sleep(forTimeInterval: 2); return ["key": "late"] })
        let asked = Date()
        #expect(slow.eventKey(at: WALL0) == .pending)
        #expect(Date().timeIntervalSince(asked) < 0.5)  // never waits for Python
        #expect(waitFor { slow.eventKey(at: WALL0) == .known("late") })
        let none = PythonFacts(query: { _ in [:] })
        _ = none.eventKey(at: WALL0)
        #expect(waitFor { none.eventKey(at: WALL0) == .known(nil) })  // no event then
    }

    @Test func notionAutoSyncIsAskedOfPython() async throws {
        let dir = tempDir()
        let py = dir.appendingPathComponent("python")
        try "#!/bin/sh\necho \"{\\\"auto_sync\\\": true, \\\"notes\\\": false, \\\"args\\\": \\\"$*\\\"}\"\n"
            .write(to: py, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: py.path)
        let answer = try await PythonFacts.notionAutoSync(python: py.path, cliOptions: ["--config", "/c.toml"])
        #expect(answer.autoSync && !answer.notes)
    }
}

@Suite struct DaemonActionsTests {
    @Test func appSocketCallsReachTheDaemon() async throws {
        let h = try Harness(tempDir(), activity: noCall)
        var refreshed = 0
        let actions = DaemonActions(daemon: h.daemon, refresh: { refreshed += 1 })
        // A main thread of its own; a long wait: the whole suite runs in parallel.
        let mainQueue = DispatchQueue(label: "test-main")
        let main = MainRunner(timeout: 120, schedule: { work in mainQueue.async(execute: work) })
        let calls = AppCalls.make(actions: actions, main: main)
        let started = try await calls["record"]!(["action": "start"]) as? [String: Any]
        #expect(started?["meeting"] as? String == "rec0")
        #expect(h.daemon.state.state == "recording" && refreshed == 1)
        await #expect(throws: CallRefused("Palaver is recording already.")) { _ = try await calls["record"]!(["action": "start"]) }
        await #expect(throws: CallRefused("This recording is no longer running.")) {
            _ = try await calls["record"]!(["action": "stop", "meeting": "rec9"])
        }
        let stopped = try await calls["record"]!(["action": "stop", "meeting": "rec0"]) as? [String: Any]
        #expect(stopped?["stopped"] as? String == "rec0" && h.sessions[0].stopReason == "by_you")
        // A double click: refused with the log's reason.
        await #expect(throws: CallRefused("The recording did not start; the log says why.")) {
            _ = try await calls["record"]!(["action": "start"])
        }
        #expect(try await calls["answer"]!(["choice": "keep"]) as? Bool == false)
        #expect(try await calls["transcribe"]!(["folder": h.rec(0).path]) as? Bool == false)  // being transcribed
    }

    @Test func aHelperIsWatchedWithTheWorkers() async throws {
        let h = try Harness(tempDir(), activity: noCall)
        let actions = DaemonActions(daemon: h.daemon)
        actions.watchHelper(folder: "/m/a", process: PidProcess(getpid()))
        #expect(h.daemon.workers().map(\.kind) == ["question"])
        let watchdog = FakeWatchdog()
        h.daemon.deps.watchdog = watchdog
        await h.run { $0 > 2 }
        #expect(watchdog.seen.last?.map(\.kind) == ["question"])
        #expect(throws: CallRefused.self) { try actions.launchHelper(kind: "x", key: "k", args: []) }
    }
}

/// Fix round 1: app.sock's `test` call asks whether a recording runs from its connection's thread.
@Suite struct DaemonSnapshotTests {
    @Test func theStateIsReadFromASnapshotOnAnyThread() async throws {
        let h = try Harness(tempDir(), activity: teams { $0 >= 10 })
        let actions = DaemonActions(daemon: h.daemon, testRecording: { _, _, busy in busy() })
        let calls = AppCalls.make(actions: actions, main: MainRunner(timeout: 120, schedule: { DispatchQueue(label: "m").async(execute: $0) }))
        #expect(try await calls["test"]!(["action": "status"]) as? Bool == false)
        // Ticking on one thread while other threads read: a snapshot under a lock, written with daemon.json.
        let reader = Thread {
            for _ in 0..<2000 { _ = actions.status() }
        }
        reader.start()
        await h.run { $0 > 30 }
        #expect(actions.status().state == "recording" && actions.status().folder == h.rec(0).path)
        #expect(try await calls["test"]!(["action": "status"]) as? Bool == true)
        h.daemon.shutdown()
        #expect(actions.status().state == "stopped")
    }
}

@Suite struct AutoSyncAnswerTests {
    @Test func theAppStartsWithTheLastAnswerElseConfigTomlsView() throws {
        let cache = tempDir().appendingPathComponent("notion-auto-sync.json")
        let first = AutoSyncAnswer(cache: cache, fallback: .init(autoSync: false, notes: true))
        #expect(first.value == .init(autoSync: false, notes: true))  // nothing cached: config.toml's view
        first.set(.init(autoSync: true, notes: false))  // Python's answer (a Keychain token)
        let next = AutoSyncAnswer(cache: cache, fallback: .init(autoSync: false, notes: true))
        #expect(next.value == .init(autoSync: true, notes: false) && next.autoSync && !next.notes)
        touch(cache, "not json")
        #expect(AutoSyncAnswer(cache: cache, fallback: .init(autoSync: false, notes: false)).value == .init(autoSync: false, notes: false))
    }

    @Test func pythonIsAskedAgainAfterAFailureAndItsAnswerKept() {
        let cache = tempDir().appendingPathComponent("notion-auto-sync.json")
        let answer = AutoSyncAnswer(cache: cache, fallback: .init(autoSync: false, notes: true))
        var asks = 0
        var slept: [Double] = []
        answer.askUntilAnswered(ask: {
            asks += 1
            return asks < 3 ? nil : .init(autoSync: true, notes: true)
        }, sleep: { slept.append($0) })
        #expect(asks == 3 && slept == [5, 10] && answer.answered)
        #expect(answer.value == .init(autoSync: true, notes: true))
        #expect(AutoSyncAnswer(cache: cache, fallback: .init(autoSync: false, notes: false)).autoSync)
    }
}
