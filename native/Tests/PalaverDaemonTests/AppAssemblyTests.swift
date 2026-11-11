// The app's assembly without AppKit: the window's helpers (test_model_jobs.py's helper_argv and
// launch), one test recorder shared by the daemon and app.sock, the tick's order, and the quit's.
import Foundation
import Testing
import PalaverCapture
import PalaverCore
@testable import PalaverDaemon

@Suite struct HelperJobsTests {
    let lm = "/A/Contents/MacOS/palaver-lm"

    func jobs(_ out: URL, spawn: HelperJobs.Spawn? = nil, alive: @escaping (Int32) -> Bool = { _ in false }) -> HelperJobs {
        HelperJobs(outputDir: { out }, lm: lm, cliOptions: ["--config", "/c.toml"], taskpolicy: "/usr/sbin/taskpolicy",
                   spawn: spawn, now: { 1000 }, alive: alive)
    }

    @Test func onlyNotesAndProjectsHelpersRun() throws {
        let out = tempDir()
        let folder = out.appendingPathComponent("2026-10-30T08-02-13")
        let j = jobs(out)
        #expect(try j.argv(kind: "notes", args: [folder.path, "--force"])
                == ["/usr/sbin/taskpolicy", "-c", "utility", lm, "--config", "/c.toml", "--no-notify", "notes", folder.path, "--force"])
        #expect(try j.argv(kind: "projects", args: ["--no-wait", "suggest"])
                == ["/usr/sbin/taskpolicy", "-c", "utility", lm, "--config", "/c.toml", "--no-notify", "projects", "--no-wait", "suggest"])
        #expect(Array(try j.argv(kind: "projects", args: ["--no-wait", "suggest"]).suffix(3)) == ["projects", "--no-wait", "suggest"])
        #expect(Array(try j.argv(kind: "projects", args: ["--no-wait", "describe", "ab12"]).suffix(2)) == ["describe", "ab12"])
        for (kind, args) in [("notes", ["/etc", "--force"]), ("notes", [out.path + "/x/../../etc", "--force"]),
                             ("notes", [out.path + "/not-a-meeting", "--force"]), ("notes", [folder.path]),
                             ("projects", ["--no-wait", "rm"]), ("run", [folder.path]),
                             ("projects", ["--no-wait", "describe", "../x"]), ("projects", ["--no-wait", "describe", "ab12\n"]),
                             ("notes", [folder.path + "\n", "--force"])] {
            #expect(throws: CallRefused.self, "\(kind) \(args)") { try j.argv(kind: kind, args: args) }
        }
        for bad in ["../x", "a/b", ".hidden", String(repeating: "a", count: 81), "abc\n", ""] {
            #expect(throws: CallRefused.self, "\(bad)") { try j.launch(kind: "projects", key: bad, args: ["--no-wait", "suggest"]) }
        }
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent(".jobs").path))
    }

    @Test func aLaunchedHelperIsRecordedUntilItEndsWithItsExitCodeAndItsOutputKept() throws {
        let out = tempDir()
        let j = HelperJobs(outputDir: { out }, lm: "/bin/sh", cliOptions: [], taskpolicy: nil,
                           spawn: { argv, fd in
                               // The real spawn with the command swapped: prints, then exits 3.
                               try spawnChild(["/bin/sh", "-c", "echo 'error: the model is not downloaded'; sleep 0.3; exit 3"],
                                              env: ProcessInfo.processInfo.environment, output: fd)
                           })
        let pid = try j.launch(kind: "projects", key: "projects", args: ["--no-wait", "suggest"])
        let record = out.appendingPathComponent(".jobs/projects-projects.json")
        let running = try #require(j.read(record))
        #expect(running["state"] as? String == "running" && (running["pid"] as? NSNumber)?.int32Value == pid)
        #expect(running["kind"] as? String == "projects" && running["key"] as? String == "projects" && running["started"] != nil)
        let end = Date().addingTimeInterval(10)
        while j.read(record)?["state"] as? String != "done" && Date() < end { usleep(20_000) }
        let done = try #require(j.read(record))
        #expect(done["state"] as? String == "done" && done["returncode"] as? Int == 3 && done["stale"] as? Bool == false)
        #expect(done["ended"] != nil && done["pid"] as? Int == Int(pid))
        let log = try String(contentsOf: out.appendingPathComponent(".jobs/projects-projects.log"), encoding: .utf8)
        #expect(log == "error: the model is not downloaded\n")
    }

    @Test func aSecondLaunchWhileOneRunsIsTheSameJob() throws {
        let out = tempDir()
        var spawned = 0
        let j = jobs(out, spawn: { _, _ in spawned += 1; return FakeWorker(pid: 4242) }, alive: { $0 == 4242 })
        #expect(try j.launch(kind: "projects", key: "projects", args: ["--no-wait", "suggest"]) == 4242)
        #expect(try j.launch(kind: "projects", key: "projects", args: ["--no-wait", "suggest"]) == 4242)
        #expect(spawned == 1)
        // A record whose pid is gone (the app quit) is stale: a new run starts.
        let stale = jobs(out, spawn: { _, _ in spawned += 1; return FakeWorker(pid: 5000) }, alive: { _ in false })
        #expect(try stale.launch(kind: "projects", key: "projects", args: ["--no-wait", "suggest"]) == 5000)
        #expect(spawned == 2)
    }
}

@Suite struct AppAssemblyTests {
    final class Calls: @unchecked Sendable {
        var list: [String] = []
        func add(_ s: String) { list.append(s) }
    }

    @Test func oneTestRecorderServesAppSockAndTheDaemonsMeetingStart() throws {
        let home = tempDir()
        let paths = testPaths(home)
        var config = Config()
        config.outputDir = home.appendingPathComponent("Meetings/Recordings", isDirectory: true)
        let calls = Calls()
        let recorder = TestRecorder(tempRoot: home, capture: { _ in
            calls.add("capture")
            return { calls.add("stop"); return (nil, nil) }
        }, analyze: { _, _, _ in [] })
        let spawned = Spawned()
        let core = try AppCore.build(config: config, settings: Settings(url: paths.settingsJson, defaults: config), paths: paths,
                                     launcher: recordingLauncher(spawned), facts: PythonFacts(query: { _ in [:] }),
                                     notion: AutoSyncAnswer(autoSync: false, notes: true), detector: CallDetector(lister: FakeLister { [] }),
                                     version: "0.5.0", notify: { _, _, _ in }, log: { _, _ in },
                                     testRecorder: recorder, helpers: nil)
        #expect(core.testRecorder === recorder)
        // The setup assistant starts the test over app.sock …
        let started = try core.actions.testRecording(action: "start", mode: [:], busy: { false }) as? [String: Any]
        #expect(started?["state"] as? String == "recording")
        // … and a meeting starting stops that same test before its capture starts.
        let folder = try core.daemon.deps.beforeRecord { calls.add("meeting"); return home }
        #expect(folder == home)
        #expect(calls.list == ["capture", "stop", "meeting"])
        #expect(recorder.status()["state"] as? String == "aborted")
        // The window's helpers are refused without a HelperJobs (a test build), as Python's ValueError.
        #expect(throws: CallRefused.self) { _ = try core.actions.launchHelper(kind: "notes", key: "k", args: []) }
    }

    @Test func theTickRunsInPythonsOrderAndWritesStartedOkUntilItIsDone() {
        let calls = Calls()
        var startedDone = false, quit = false
        let ticker = AppTicker(.init(
            daemonTick: { calls.add("daemon") },
            started: { calls.add("started") },
            startedDone: { startedDone },
            refresh: { calls.add("refresh") },
            calendarRetry: { calls.add("calendar") },
            housekeeping: { calls.add("housekeeping") },
            updates: { calls.add("updates"); return quit },
            quit: { calls.add("quit") }))
        ticker.tick()
        #expect(calls.list == ["daemon", "started", "refresh", "calendar", "housekeeping", "updates"])
        calls.list = []
        startedDone = true
        ticker.tick()
        #expect(calls.list == ["daemon", "refresh", "calendar", "housekeeping", "updates"])
        calls.list = []
        quit = true  // an update is swapped in: the app quits, and ticks no more
        ticker.tick()
        ticker.tick()
        #expect(calls.list == ["daemon", "refresh", "calendar", "housekeeping", "updates", "quit"])
        #expect(ticker.stopped)
    }

    @Test func aPartTheAppCanDoWithoutDoesNotStopItsStart() {
        // The window's server (no free port, say): no window, but the menu and recording go on.
        struct NoPort: Error, CustomStringConvertible { var description: String { "no port to listen on" } }
        let calls = Calls()
        let none: Int? = AppPart.optional("the window's server", log: { calls.add($0) }) { () throws -> Int in throw NoPort() }
        #expect(none == nil)
        #expect(calls.list == ["the window's server did not start (no port to listen on); Palaver runs without its window"])
        #expect(AppPart.optional("x", log: { calls.add($0) }) { 7 } == 7)
        #expect(calls.list.count == 1)
    }

    @Test func aReplacedBundleQuitsTheAppBeforeAnythingElseRuns() {
        // The swap put the version before back (or removed this one): this process runs a replaced app.
        let calls = Calls()
        var replaced = false
        let ticker = AppTicker(.init(
            daemonTick: { calls.add("daemon") }, started: { calls.add("started") }, startedDone: { true },
            refresh: { calls.add("refresh") }, calendarRetry: { calls.add("calendar") },
            housekeeping: { calls.add("housekeeping") }, updates: { calls.add("updates"); return false },
            quit: { calls.add("quit") }, bundleReplaced: { calls.add("bundle"); return replaced }))
        ticker.tick()
        #expect(calls.list == ["bundle", "daemon", "refresh", "calendar", "housekeeping", "updates"])
        calls.list = []
        replaced = true
        ticker.tick()
        ticker.tick()
        #expect(calls.list == ["bundle", "quit"] && ticker.stopped)
    }

    @Test func theQuitFinishesEverythingOnceInFinalizesOrderWithItsReason() {
        let calls = Calls()
        func quit() -> AppQuit {
            AppQuit(.init(stopTick: { calls.add("tick") }, abortTest: { calls.add("test") },
                          shutdown: { calls.add("shutdown \($0)") }, stopWeb: { calls.add("web") },
                          closeSocket: { calls.add("app.sock") }, stopNotifications: { calls.add("notify") }))
        }
        let outside = quit()  // SIGTERM, logout, an update
        #expect(outside.finalize())
        #expect(!outside.finalize())  // once
        #expect(calls.list == ["tick", "test", "shutdown restart", "web", "app.sock", "notify"])
        calls.list = []
        let mine = quit()  // the menu's Quit, ⌘Q in the window
        mine.byUser()
        mine.finalize()
        #expect(calls.list == ["tick", "test", "shutdown by_you", "web", "app.sock", "notify"])
    }
}
