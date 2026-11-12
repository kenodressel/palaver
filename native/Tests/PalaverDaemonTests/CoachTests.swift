// Task 13: the coach worker's side in the daemon (test_daemon_coach.py): started with call
// recordings only, stopped with them, its coach.json read into the status keys; and the test
// recording (onboarding.TestRecording): aborted by a meeting, refused while one records, its
// status shape and the analyze step. Nothing is spawned, nothing records.
import Foundation
import Testing
import PalaverCapture
import PalaverCore
@testable import PalaverDaemon

extension DaemonTicksD {
@Suite struct CoachTests {
    let status: [String: Any] = ["talk": ["share": 0.7, "speaking": "me"], "talk_text": "You 70 % of the last 10 min",
                                 "nudge": ["kind": "talk_share", "text": "4-min monologue", "at": 640.0], "quiet": ["Timo Strauß"]]

    @Test func theCoachRunsWithCallRecordingsOnly() async throws {
        for (activity, started) in [(teams { 10 <= $0 && $0 < 100 }, 1), (slack { 10 <= $0 && $0 < 100 }, 1), (noCall, 0)] {
            var coaches: [(URL, FakeWorker)] = []
            let h = try Harness(tempDir(), activity: activity) { deps, _ in
                deps.launchCoach = { let w = FakeWorker(); coaches.append(($0, w)); return w }
            }
            await h.run { $0 > 150 }
            #expect(coaches.count == started)
            if started == 1 {
                #expect(coaches[0].0 == h.rec(0))
                #expect(coaches[0].1.terminated)  // stopped with the recording
            }
        }
    }

    @Test func aRecordingStartedByHandGetsNoCoach() async throws {
        var coaches = 0
        let h = try Harness(tempDir(), activity: noCall) { deps, _ in
            deps.launchCoach = { _ in coaches += 1; return FakeWorker() }
        }
        #expect(h.daemon.startManual())
        h.daemon.tick()
        #expect(coaches == 0)
    }

    @Test func aCoachThatFailsToStartDoesNotStopTheRecording() async throws {
        struct No: Error {}
        let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 100 }) { deps, _ in
            deps.launchCoach = { _ in throw No() }
        }
        await h.run { $0 > 30 }
        #expect(h.status()["state"]?.stringValue == "recording")
        #expect(h.status()["talk_text"] == .null)
    }

    @Test func coachJsonReachesTheStatusAndDaemonJson() async throws {
        let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 100 }) { deps, _ in
            deps.launchCoach = { _ in FakeWorker() }
        }
        await h.run { $0 > 30 }
        writeJSON(h.rec(0).appendingPathComponent("coach.json"), status)
        h.daemon.tick()
        let s = h.state()
        #expect(s["talk_text"]?.stringValue == "You 70 % of the last 10 min")
        #expect(s["nudge"]?["text"]?.stringValue == "4-min monologue")
        #expect(s["talk"]?["speaking"]?.stringValue == "me")
        #expect(s["quiet"] == .strings(["Timo Strauß"]))
        await h.run { $0 > 150 }
        #expect(h.state()["talk_text"] == .null && h.state()["nudge"] == .null && h.state()["quiet"] == .array([]))
    }

    @Test func aMissingOrStaleOrBrokenFileIsNulls() async throws {
        let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 100 }) { deps, _ in
            deps.launchCoach = { _ in FakeWorker() }
        }
        await h.run { $0 > 30 }
        let file = h.rec(0).appendingPathComponent("coach.json")
        let nulls = { (h.status()["talk"] == .null, h.status()["talk_text"] == .null, h.status()["nudge"] == .null,
                       h.status()["quiet"] == .array([])) }
        #expect(nulls() == (true, true, true, true))  // missing
        touch(file, "{ not json")
        #expect(nulls() == (true, true, true, true))  // broken
        writeJSON(file, status)
        #expect(h.status()["talk_text"]?.stringValue != nil)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: file.path)
        #expect(nulls() == (true, true, true, true))  // stale: the worker died
    }

    @Test func theCoachIsNotInTheMemoryWatchdogsList() async throws {
        // memory.py watches live, stream, notes, process, the index and the question helper: no coach.
        let w = FakeWorker()
        let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 100 }) { deps, _ in
            deps.launchCoach = { _ in w }
        }
        await h.run { $0 > 30 }
        #expect(h.daemon.workers().isEmpty)
    }

    @Test func aCoachThatExitedIsNotStartedAgain() async throws {
        var n = 0
        let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 100 }) { deps, _ in
            deps.launchCoach = { _ in n += 1; return FakeWorker(done: { true }) }
        }
        await h.run { $0 > 60 }
        #expect(n == 1)
    }

    @Test func buildDaemonLaunchesThePythonCoachInTheBackground() throws {
        let b = try build(autoSync: false, options: [])
        _ = try b.daemon.deps.launchCoach!(URL(fileURLWithPath: "/m/rec", isDirectory: true))
        #expect(b.spawned.calls.map(\.qos) == [.background])
        #expect(b.spawned.calls[0].args.suffix(3) == ["-m", "palaver", "coach"] || b.spawned.calls[0].args.suffix(2) == ["coach", "/m/rec"])
    }
}
}

// MARK: - the test recording

private final class FakeTestCapture: @unchecked Sendable {
    let lock = NSLock()
    var started: [URL] = []
    var stopped = 0
    var failStart = false
    var analyzed: [(URL?, URL?, [String: Any])] = []
    var analyzeResult: Result<[[String: Any]], Error> = .success([["name": "Microphone", "status": "ok", "detail": "heard you", "fix": ""]])

    func capture(_ folder: URL) throws -> TestRecorder.Stop {
        if failStart { throw CaptureError("no microphone") }
        lock.withLock { started.append(folder) }
        return { [self] in
            lock.withLock { stopped += 1 }
            let mic = folder.appendingPathComponent("mic_raw.wav")
            touch(mic, "RIFF")
            return (mic, nil)
        }
    }

    func analyze(_ mic: URL?, _ system: URL?, _ mode: [String: Any]) throws -> [[String: Any]] {
        lock.withLock { analyzed.append((mic, system, mode)) }
        return try analyzeResult.get()
    }

    func recorder(maxSeconds: Double = 20, tempRoot: URL = FileManager.default.temporaryDirectory, ownerPid: Int32 = getpid(),
                  alive: @escaping @Sendable (Int32) -> Bool = TestRecorder.processAlive) -> TestRecorder {
        TestRecorder(maxSeconds: maxSeconds, tempRoot: tempRoot, ownerPid: ownerPid, processAlive: alive, capture: { try self.capture($0) }, analyze: { try self.analyze($0, $1, $2) })
    }
}

func waitFor(_ timeout: Double = 30, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return cond()
}

@Suite struct TestRecordingTests {
    @Test func staleTestFoldersAreSweptAtStartAndOnlyThose() throws {
        let root = tempDir()
        let stale = root.appendingPathComponent("palaver-test-recording-deadbeef", isDirectory: true)
        mkdir(stale); touch(stale.appendingPathComponent("mic_raw.wav"), "RIFF")
        let other = root.appendingPathComponent("somebody-elses", isDirectory: true)
        mkdir(other)
        let lookalike = root.appendingPathComponent("palaver-test-recording-file")
        touch(lookalike)  // a file, not a folder: left alone
        let cap = FakeTestCapture()
        let running = cap.recorder(tempRoot: root)  // sweeps `stale`
        #expect(!exists(stale) && exists(other) && exists(lookalike))
        _ = try running.start(busy: { false }, mode: [:])
        let folder = try #require(cap.started.first)
        #expect(folder.deletingLastPathComponent().resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
        mkdir(root.appendingPathComponent("palaver-test-recording-stale2", isDirectory: true))
        _ = cap.recorder(tempRoot: root)  // the app starts again (another recorder): the running test's folder stays
        #expect(exists(folder) && !exists(root.appendingPathComponent("palaver-test-recording-stale2")))
        running.abort()  // the app quits
        #expect(!exists(folder) && running.status()["state"] as? String == "aborted")
        #expect(cap.stopped == 1 && cap.analyzed.isEmpty)
    }

    @Test func anotherProcessesLiveTestIsNeverSwept() throws {
        let root = tempDir()
        let cap = FakeTestCapture()
        let a = cap.recorder(tempRoot: root, ownerPid: 111)  // "process" 111
        _ = try a.start(busy: { false }, mode: [:])
        let folder = try #require(cap.started.first)
        #expect(try String(contentsOf: folder.appendingPathComponent("owner.pid"), encoding: .utf8) == "111")
        _ = cap.recorder(tempRoot: root, ownerPid: 222, alive: { $0 == 111 })  // "process" 222 starts: 111 lives
        #expect(exists(folder))
        _ = cap.recorder(tempRoot: root, ownerPid: 333, alive: { _ in false })  // 111 died without cleaning up
        #expect(!exists(folder))
    }

    @Test func theMarkerIsThereBeforeTheCaptureStarts() throws {
        let root = tempDir()
        var seen: String?
        let t = TestRecorder(tempRoot: root, ownerPid: 5, capture: { folder in
            seen = try? String(contentsOf: folder.appendingPathComponent("owner.pid"), encoding: .utf8)
            return { (nil, nil) }
        }, analyze: { _, _, _ in [] })
        _ = try t.start(busy: { false }, mode: [:])
        #expect(seen == "5")
        t.abort()
    }

    @Test func aSweepDuringCheckingLeavesTheFolder() async throws {
        let root = tempDir()
        let release = DispatchSemaphore(value: 0)
        let inAnalyze = DispatchSemaphore(value: 0)
        let t = TestRecorder(tempRoot: root, capture: { folder in { (folder.appendingPathComponent("mic_raw.wav"), nil) } },
                             analyze: { _, _, _ in inAnalyze.signal(); release.wait(); return [] })
        _ = try t.start(busy: { false }, mode: [:])
        let folder = try #require(try FileManager.default.contentsOfDirectory(atPath: root.path).first)
        _ = t.stop()
        #expect(inAnalyze.wait(timeout: .now() + 30) == .success)
        #expect(t.status()["state"] as? String == "checking")
        _ = TestRecorder(tempRoot: root, ownerPid: 999, capture: { _ in { (nil, nil) } }, analyze: { _, _, _ in [] })  // another start sweeps
        #expect(exists(root.appendingPathComponent(folder)))
        release.signal()
        #expect(await waitFor { t.status()["state"] as? String == "done" })
        #expect(!exists(root.appendingPathComponent(folder)))
    }

    @Test func idleStatusShape() {
        let s = FakeTestCapture().recorder().status()
        #expect(s["state"] as? String == "idle" && s["max_seconds"] as? Double == 20.0 && s.count == 2)
    }

    @Test func startStopAnalyzeGivesTheChecksAndKeepsNothing() async throws {
        let cap = FakeTestCapture()
        let t = cap.recorder()
        let s = try t.start(busy: { false }, mode: ["transcribe": "cloud", "service": "Soniox"])
        #expect(s["state"] as? String == "recording" && s["max_seconds"] as? Double == 20.0 && s["seconds"] is Double)
        let folder = try #require(cap.started.first)
        #expect(folder.lastPathComponent.hasPrefix("palaver-test-recording-"))
        #expect(t.stop()["state"] as? String == "checking")
        #expect(await waitFor { t.status()["state"] as? String == "done" })
        let done = t.status()
        let checks = try #require(done["checks"] as? [[String: Any]])
        #expect(checks[0]["name"] as? String == "Microphone" && done["error"] == nil)
        #expect(cap.analyzed.count == 1 && cap.analyzed[0].2["service"] as? String == "Soniox")
        #expect(cap.analyzed[0].0?.lastPathComponent == "mic_raw.wav")
        #expect(!FileManager.default.fileExists(atPath: folder.path))  // the test's audio is never kept
    }

    @Test func aSecondStartWhileRecordingJustReportsStatus() throws {
        let cap = FakeTestCapture()
        let t = cap.recorder()
        _ = try t.start(busy: { false }, mode: [:])
        let s = try t.start(busy: { false }, mode: [:])
        #expect(s["state"] as? String == "recording" && cap.started.count == 1)
        _ = t.stop()
    }

    @Test func itStopsByItselfAfterTheMaximum() async throws {
        let cap = FakeTestCapture()
        let t = cap.recorder(maxSeconds: 0.1)
        _ = try t.start(busy: { false }, mode: [:])
        #expect(await waitFor { t.status()["state"] as? String == "done" }, "\(t.status())")
        #expect(cap.stopped == 1 && cap.analyzed.count == 1)
    }

    @Test func notWhileAMeetingIsRecorded() throws {
        let cap = FakeTestCapture()
        let t = cap.recorder()
        #expect(throws: CallRefused("a meeting is being recorded; try the test after it")) { try t.start(busy: { true }, mode: [:]) }
        #expect(cap.started.isEmpty)
    }

    @Test func aMeetingStartingAbortsARunningTest() throws {
        let cap = FakeTestCapture()
        let t = cap.recorder()
        _ = try t.start(busy: { false }, mode: [:])
        let folder = try #require(cap.started.first)
        try t.meetingStarting {
            #expect(cap.stopped == 1)  // let go before the meeting's capture starts
            #expect(t.status()["state"] as? String == "aborted")
            #expect(throws: CallRefused("a meeting is being recorded; try the test after it")) { try t.start(busy: { false }, mode: [:]) }
        }
        #expect(cap.analyzed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect((t.status()["error"] as? String)?.contains("call started") == true)
    }

    @Test func aFailingCaptureIsFailedWithTheReason() throws {
        let cap = FakeTestCapture()
        cap.failStart = true
        let t = cap.recorder()
        let s = try t.start(busy: { false }, mode: [:])
        #expect(s["state"] as? String == "failed" && s["error"] as? String == "could not start recording: no microphone")
    }

    @Test func aFailingAnalyzeIsFailed() async throws {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        let cap = FakeTestCapture()
        cap.analyzeResult = .failure(Boom())
        let t = cap.recorder()
        _ = try t.start(busy: { false }, mode: [:])
        _ = t.stop()
        #expect(await waitFor { t.status()["state"] as? String == "failed" })
        #expect(t.status()["error"] as? String == "the test failed: boom")
    }

    @Test func theAppSocketCallDrivesIt() async throws {
        let cap = FakeTestCapture()
        let t = cap.recorder()
        #expect(try t.testRecording(action: "start", mode: [:], busy: { false }) is [String: Any])
        #expect((try t.testRecording(action: "stop", mode: [:], busy: { false }) as? [String: Any])?["state"] as? String == "checking")
        #expect(await waitFor { (try? t.testRecording(action: nil, mode: [:], busy: { false }) as? [String: Any])?["state"] as? String == "done" })
    }

    @Test func theDaemonStartsAMeetingThroughTheGate() async throws {
        let cap = FakeTestCapture()
        let t = cap.recorder()
        _ = try t.start(busy: { false }, mode: [:])
        let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 100 }) { deps, _ in
            deps.beforeRecord = { start in try t.meetingStarting(start) }
        }
        h.daemon.tick(); h.clock = 12; h.daemon.tick(); h.clock = 20; h.daemon.tick()
        #expect(t.status()["state"] as? String == "aborted" && cap.stopped == 1)
    }
}
