// test_daemon.py: a restart never cuts a call (issue #47), crash recovery and the recordings left
// behind (review of #47), the single instance (review round 3).
import Foundation
import Testing
import PalaverCore
@testable import PalaverDaemon

/// A daemon recording a call that quits `at` (SIGTERM → shutdown).
func quitDuringACall(_ dir: URL, _ activity: @escaping (Double) -> CallApp?, at: Double = 400) async throws -> (Sessions, Harness) {
    let h = try Harness(dir, activity: activity)
    await h.run { $0 > at }
    h.daemon.shutdown()
    return (h.sessions, h)
}

func parts(_ head: URL) -> [String] { Continuation.parts(head).map(\.path) }

/// daemon.json as a daemon left it that died (SIGKILL, OOM) while recording.
func crashedState(_ dir: URL, folder: URL, continues: [URL] = [], trigger: String = "teams", since: Double = 14,
                  updated: Double = 500, manual: Bool = false, pid: Int? = nil) {
    for f in [folder] + continues { mkdir(f) }
    var state: [String: Any] = [
        "state": "recording", "manual": manual, "folder": folder.path, "continues": continues.map(\.path),
        "why": ["trigger": trigger, "since": wall(since)], "cut": NSNull(), "queued": [String](), "updated": wall(updated),
    ]
    if let pid { state["pid"] = pid }
    writeJSON(dir.appendingPathComponent("state.json"), state)
}

extension DaemonTicks {
    @Suite struct ContinuationTests {
        @Test func aRestartDuringACallContinuesTheRecordingAndJoinsItAfter() async throws {
            let dir = tempDir()
            let call = teams { 10 <= $0 && $0 < 1000 }
            let (sessions, first) = try await quitDuringACall(dir, call)
            let rec0 = first.rec(0)
            #expect(sessions[0].stopReason == "restart")
            #expect(first.launched.isEmpty)  // held back: not processed on its own
            let cut = first.state()["cut"]
            #expect(cut?["folders"] == .strings([rec0.path]) && cut?["trigger"] == .string("teams"))
            #expect(cut?["at"] == .string(wall(402)))

            let h = try Harness(dir, activity: call, sessions: sessions, start: 430)  // started again 28 s later
            await h.run { $0 > 500 }
            #expect(sessions.count == 2 && sessions[1].trigger == "teams")
            #expect(parts(rec0) == [h.rec(1).path])
            let status = h.status()
            #expect(status["continues"] == .strings([rec0.path]) && status["cut"] == .null)
            #expect(status["why"]?["since"] == .string(WallTime.iso(WALL0.addingTimeInterval(14), TZ, seconds: true)))  // the meeting's start
            #expect(status["why"]?["restarts"] == .int(1))
            #expect(h.titles.contains("Recording continued"))
            await h.run { $0 > 1100 }
            #expect(sessions[1].stopReason == "call_ended")
            #expect(p(h.launched) == [rec0.path])  // one meeting, processed once
            #expect(h.status()["continues"] == .array([]))
        }

        @Test func twoRestartsInOneCallMakeOneMeeting() async throws {
            let dir = tempDir()
            let call = teams { 10 <= $0 && $0 < 3000 }
            let (sessions, _) = try await quitDuringACall(dir, call, at: 400)
            let second = try Harness(dir, activity: call, sessions: sessions, start: 430)
            await second.run { $0 > 1300 }
            second.daemon.shutdown()
            #expect(second.state()["cut"]?["folders"] == .strings([second.rec(0).path, second.rec(1).path]))
            let h = try Harness(dir, activity: call, sessions: sessions, start: 1320)
            await h.run { $0 > 3100 }
            #expect(sessions.count == 3)
            #expect(parts(h.rec(0)) == [h.rec(1).path, h.rec(2).path])
            #expect(p(h.launched) == [h.rec(0).path])
        }

        @Test func aCutRecordingIsProcessedAloneOnceFiveMinutesPass() async throws {
            let dir = tempDir()
            let (sessions, _) = try await quitDuringACall(dir, teams { 10 <= $0 && $0 < 410 })
            let h = try Harness(dir, activity: noCall, sessions: sessions, start: 430)
            await h.run { $0 > 690 }
            #expect(h.launched.isEmpty)  // quit at 402: waits until 702
            await h.run { $0 > 710 }
            #expect(p(h.launched) == [h.rec(0).path] && h.status()["cut"] == .null)
            #expect(sessions.count == 1)
        }

        @Test func aCutPartWaitsAcrossAQuitWhileIdle() async throws {
            let dir = tempDir()
            let call = teams { (10 <= $0 && $0 < 410) || (600 <= $0 && $0 < 900) }
            let (sessions, _) = try await quitDuringACall(dir, call)
            let idle = try Harness(dir, activity: call, sessions: sessions, start: 430)
            await idle.run { $0 > 450 }
            idle.daemon.shutdown()  // quit again before the call came back
            #expect(idle.state()["cut"]?["folders"] == .strings([idle.rec(0).path]))
            let h = try Harness(dir, activity: call, sessions: sessions, start: 460)
            await h.run { $0 > 1000 }
            #expect(parts(h.rec(0)) == [h.rec(1).path])
            #expect(p(h.launched) == [h.rec(0).path])
        }

        @Test func anotherCallAppAfterTheRestartIsAMeetingOfItsOwn() async throws {
            let dir = tempDir()
            let (sessions, _) = try await quitDuringACall(dir, teams { 10 <= $0 && $0 < 1000 })
            let h = try Harness(dir, activity: slack { 440 <= $0 && $0 < 1000 }, sessions: sessions, start: 430)
            await h.run { $0 > 1100 }
            #expect(sessions.items.map { $0!.trigger } == ["teams", "slack"])
            #expect(parts(h.rec(0)).isEmpty)
            #expect(p(h.launched).sorted() == [h.rec(0).path, h.rec(1).path])  // each alone; rec0 after 5 min
        }

        @Test func aManualRecordingCutByAQuitIsProcessedAtOnce() async throws {
            // Only automatic recordings are continued; a manual one is queued (ruling, #47 review).
            let dir = tempDir()
            let first = try Harness(dir, activity: noCall)
            first.daemon.startManual()
            await first.run { $0 > 400 }
            first.daemon.shutdown()
            #expect(first.sessions[0].stopReason == "restart")
            #expect(first.state()["cut"] == .null && p(first.launched) == [first.rec(0).path])
            let h = try Harness(dir, activity: teams { 440 <= $0 && $0 < 1000 }, sessions: first.sessions, start: 430)
            await h.run { $0 > 500 }
            #expect(first.sessions[1].trigger == "teams" && parts(h.rec(0)).isEmpty)
            h.daemon.shutdown()
        }

        @Test func anAutomaticRecordingIsNotContinuedByAManualOne() async throws {
            let dir = tempDir()
            let (sessions, _) = try await quitDuringACall(dir, teams { 10 <= $0 && $0 < 410 })
            let h = try Harness(dir, activity: noCall, sessions: sessions, start: 430)
            h.daemon.startManual()
            #expect(sessions[1].trigger == "manual" && parts(h.rec(0)).isEmpty)
            h.daemon.shutdown()
        }

        @Test func aManualRecordingStartedAgainAfterARestartIsAMeetingOfItsOwn() async throws {
            let dir = tempDir()
            let first = try Harness(dir, activity: noCall)
            first.daemon.startManual()
            await first.run { $0 > 400 }
            first.daemon.shutdown()
            let h = try Harness(dir, activity: noCall, sessions: first.sessions, start: 430)
            h.daemon.startManual()
            #expect(parts(h.rec(0)).isEmpty)
            h.daemon.stopManual()
            #expect(p(h.launched) == [h.rec(1).path])
        }

        @Test func aNewCutLetsTheOlderOneGo() async throws {
            let dir = tempDir()
            let (sessions, _) = try await quitDuringACall(dir, teams { 10 <= $0 && $0 < 1000 })
            let h = try Harness(dir, activity: slack { 440 <= $0 && $0 < 1000 }, sessions: sessions, start: 430)
            await h.run { $0 > 500 }
            h.daemon.shutdown()  // the Slack huddle is cut now: the Teams part can't be continued any more
            #expect(h.state()["cut"]?["folders"] == .strings([h.rec(1).path]))
            #expect(p(h.launched) == [h.rec(0).path])
        }

        @Test func theJoinedMeetingWaitsForTheLiveWorkersOfAllParts() async throws {
            let dir = tempDir()
            let call = teams { 10 <= $0 && $0 < 1000 }
            let (sessions, _) = try await quitDuringACall(dir, call)
            let h = try Harness(dir, activity: call, sessions: sessions, start: 430)
            h.daemon.deps.liveRunning = { [unowned h] folder in folder.path == h.rec(1).path && h.clock < 1200 }
            await h.run { $0 > 1100 }
            #expect(h.launched.isEmpty)  // the call ended at 1010; rec1's worker still finishes
            await h.run { $0 > 1210 }
            #expect(p(h.launched) == [h.rec(0).path])
        }

        @Test func aDifferentCalendarEventAfterTheRestartIsANewMeeting() async throws {
            // Back-to-back calls: the next event's call is not the cut one going on.
            let dir = tempDir()
            let (sessions, _) = try await quitDuringACall(dir, teams { 10 <= $0 && $0 < 410 })
            let h = try Harness(dir, activity: teams { 600 <= $0 && $0 < 900 }, sessions: sessions, start: 430) { deps, _ in
                deps.eventKeyAt = { .known($0 < WALL0.addingTimeInterval(600) ? "standup" : "1:1") }
            }
            await h.run { $0 > 650 }
            #expect(sessions.count == 2 && parts(h.rec(0)).isEmpty)
            let x = tempDir()
            let (xs, _) = try await quitDuringACall(x, teams { 10 <= $0 && $0 < 900 })
            let same = try Harness(x, activity: teams { 10 <= $0 && $0 < 900 }, sessions: xs, start: 430) { deps, _ in
                deps.eventKeyAt = { _ in .known("standup") }
            }
            await same.run { $0 > 500 }
            #expect(parts(same.rec(0)) == [same.rec(1).path])
        }

        @Test func aCutWhoseFirstPartIsGoneGoesOnFromTheNext() async throws {
            let dir = tempDir()
            let rec0 = dir.appendingPathComponent("rec0"), rec1 = dir.appendingPathComponent("rec1"), rec2 = dir.appendingPathComponent("rec2")
            mkdir(rec1); mkdir(rec2)
            writeJSON(dir.appendingPathComponent("state.json"), [
                "state": "stopped", "queued": [String](),
                "cut": ["folders": [rec0.path, rec1.path, rec2.path], "trigger": "teams", "seconds": 900.0,
                        "at": wall(400), "since": wall(0)] as [String: Any],
            ])
            let h = try Harness(dir, activity: noCall, sessions: Sessions([nil, nil, nil]), start: 800)
            await h.run { $0 > 804 }
            #expect(p(h.launched) == [rec1.path] && parts(rec1) == [rec2.path])
        }

        @Test func whenMarkingTheContinuationFailsBothPartsAreProcessed() async throws {
            struct DiskFull: Error {}
            let dir = tempDir()
            let call = teams { 10 <= $0 && $0 < 1000 }
            let (sessions, _) = try await quitDuringACall(dir, call)
            let h = try Harness(dir, activity: call, sessions: sessions, start: 430) { deps, _ in
                deps.addPart = { _, _ in throw DiskFull() }
            }
            await h.run { $0 > 500 }
            #expect(h.status()["continues"] == .array([]) && p(h.launched) == [h.rec(0).path])  // rec0 on its own, now
            await h.run { $0 > 1100 }
            #expect(p(h.launched) == [h.rec(0).path, h.rec(1).path])
        }

        @Test func theMaximumLengthCountsTheWholeMeeting() async throws {
            let dir = tempDir()
            let call = teams { $0 >= 10 }
            let (sessions, _) = try await quitDuringACall(dir, call, at: 2000)
            let h = try Harness(dir, activity: call, sessions: sessions, start: 2030)
            await h.run { $0 > 3700 }
            #expect(sessions[1].stopReason == "max_length")  // 3600 s after the meeting began at 14, not after 2034
        }
    }
}

extension DaemonTicks {
    @Suite struct CrashRecoveryTests {
        @Test func aCrashWhileAContinuedPartRecordsCanStillBeContinued() async throws {
            let dir = tempDir()
            let rec0 = dir.appendingPathComponent("rec0"), rec1 = dir.appendingPathComponent("rec1")
            crashedState(dir, folder: rec1, continues: [rec0])
            let h = try Harness(dir, activity: teams { $0 < 900 }, sessions: Sessions([nil, nil]), start: 520)
            #expect(h.status()["cut"]?["folders"] == .strings([rec0.path, rec1.path]))
            await h.run { $0 > 1000 }
            #expect(parts(rec0) == [rec1.path, h.rec(2).path])
            #expect(p(h.launched) == [rec0.path])
        }

        @Test func aCrashWhileAContinuedPartRecordsIsProcessedOnceTheWindowPassed() async throws {
            let dir = tempDir()
            let rec0 = dir.appendingPathComponent("rec0"), rec1 = dir.appendingPathComponent("rec1")
            crashedState(dir, folder: rec1, continues: [rec0])
            let h = try Harness(dir, activity: noCall, sessions: Sessions([nil, nil]), start: 900)
            await h.run { $0 > 904 }
            #expect(p(h.launched) == [rec0.path] && parts(rec0) == [rec1.path])  // `process` joins (and recovers) rec1
        }

        /// Review focus 1: the app killed during a call's recording; it comes back as a `cut`.
        @Test func crashRecoveryCutsCall() async throws {
            let dir = tempDir()
            let rec0 = dir.appendingPathComponent("rec0")
            crashedState(dir, folder: rec0, since: 14, updated: 500)
            let h = try Harness(dir, activity: noCall, sessions: Sessions([nil]), start: 510)
            #expect(h.status()["cut"] == Cut(folders: [rec0.path], trigger: "teams", at: wall(500), since: wall(14), seconds: 486).json)
            #expect(h.logs.contains { $0.level == "WARNING" && $0.message.contains("the last run ended while recording rec0") })
            await h.run { $0 > 520 }
            #expect(h.launched.isEmpty)  // held back for a call to continue
            await h.run { $0 > 810 }
            #expect(p(h.launched) == [rec0.path])  // not continued within 5 min: on its own
        }

        @Test func aCrashDuringAPlainRecordingIsRecovered() async throws {
            let dir = tempDir()
            let rec0 = dir.appendingPathComponent("rec0")
            crashedState(dir, folder: rec0, updated: 500)
            let h = try Harness(dir, activity: noCall, sessions: Sessions([nil]), start: 1000)
            await h.run { $0 > 1004 }
            #expect(p(h.launched) == [rec0.path])  // `process` promotes the .part files and rebuilds meta.json
        }

        /// Review focus 1: the app killed during a manual recording; it is queued at once.
        @Test func crashRecoveryQueuesManual() async throws {
            let dir = tempDir()
            let rec0 = dir.appendingPathComponent("rec0")
            crashedState(dir, folder: rec0, trigger: "manual", manual: true)
            let h = try Harness(dir, activity: noCall, sessions: Sessions([nil]), start: 520)
            #expect(h.daemon.queue == [rec0.path])
            await h.run { $0 > 524 }
            #expect(p(h.launched) == [rec0.path] && h.status()["cut"] == .null)
        }

        @Test func aCleanStopIsNotTakenForACrash() async throws {
            let dir = tempDir()
            let rec0 = dir.appendingPathComponent("rec0")
            crashedState(dir, folder: rec0)
            var state = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("state.json"))) as! [String: Any]
            state["state"] = "stopped"; state["folder"] = NSNull()
            writeJSON(dir.appendingPathComponent("state.json"), state)
            let h = try Harness(dir, activity: noCall, sessions: Sessions([nil]), start: 520)
            await h.run { $0 > 1000 }
            #expect(h.launched.isEmpty)
        }

        @Test func aSecondDaemonLeavesARunningOnesRecordingAlone() async throws {
            let dir = tempDir()
            let rec0 = dir.appendingPathComponent("rec0")
            crashedState(dir, folder: rec0, pid: 4242)
            let before = try Data(contentsOf: dir.appendingPathComponent("state.json"))
            #expect(throws: DaemonRunning.self) {
                try Harness(dir, activity: noCall, sessions: Sessions([nil]), start: 900) { deps, _ in deps.palaverAlive = { $0 == 4242 } }
            }
            do {
                _ = try Harness(dir, activity: noCall) { deps, _ in deps.palaverAlive = { $0 == 4242 } }
            } catch let e as DaemonRunning {
                #expect(e.description.contains("4242"))
            }
            #expect(try Data(contentsOf: dir.appendingPathComponent("state.json")) == before)  // untouched
        }

        @Test func aDeadPidInTheStateIsACrash() async throws {
            let dir = tempDir()
            let rec0 = dir.appendingPathComponent("rec0")
            let gone = try spawnWorker(["/usr/bin/true"], qos: .utility, log: dir.appendingPathComponent("w.log"))
            gone.waitUntilExit()
            crashedState(dir, folder: rec0, updated: 500, pid: Int(gone.pid))
            let h = try Harness(dir, activity: noCall, sessions: Sessions([nil]), start: 1000) { deps, _ in
                deps.palaverAlive = { Processes.palaverAlive($0) }
            }
            await h.run { $0 > 1004 }
            #expect(p(h.launched) == [rec0.path])
        }

        @Test func onlyTheAppOrTheDaemonCountAsARunningPalaver() async throws {
            let me = getpid()
            for (command, alive) in [("/usr/bin/python3 -c pass palaver menubar", true), ("/x/python -m palaver daemon", true),
                                     ("/Applications/Palaver.app/Contents/MacOS/Palaver", true),
                                     ("/x/native/.build/release/Palaver", true), ("/x/native/.build/arm64-apple-macosx/debug/Palaver", true),
                                     ("/Applications/Palaver.app/Contents/MacOS/palaver-engine", false),
                                     ("/x/python -m palaver mcp", false), ("/x/python -m palaver process x", false),
                                     ("/Applications/Palaver.app/Contents/MacOS/palaver-python -m palaver live /m/a", false),
                                     // 0.3.14 and before: Contents/MacOS/Palaver was the Python host running the workers.
                                     ("/Applications/Palaver.app/Contents/MacOS/Palaver -m palaver process /m/a", false),
                                     ("/Applications/Palaver.app/Contents/MacOS/Palaver -m palaver menubar", true)] {
                #expect(Processes.palaverAlive(me, commandLine: { _ in command }) == alive, "\(command)")
            }
            #expect(Processes.palaverAlive(me, commandLine: { _ in nil }))  // alive, and nothing says it is not Palaver
            #expect(!Processes.palaverAlive(nil) && !Processes.palaverAlive(0))
            // This process's own command line can be read.
            #expect(Processes.commandLine(me)?.isEmpty == false)
        }
    }
}

@Suite struct LeftBehindTests {
    func recorded(_ folder: URL, _ files: String...) -> URL {
        mkdir(folder)
        for n in ["mic.wav", "system.wav"] + files { touch(folder.appendingPathComponent(n)) }
        return folder
    }

    /// Failed before failed.json existed, or its `process` died with the Mac: each said not
    /// transcribed when Palaver starts. Not the queued ones, a part of another, one a `process`
    /// still runs on, or one that waits for its models.
    @Test func recordingsNothingTranscribesAreMarkedAtStart() async throws {
        let dir = tempDir()
        let out = dir.appendingPathComponent("Recordings")
        mkdir(out)
        let old = recorded(out.appendingPathComponent("2026-11-02T09-00-00"))
        let done = recorded(out.appendingPathComponent("2026-11-02T10-00-00"), "transcript.json")
        let queued = recorded(out.appendingPathComponent("2026-11-02T11-00-00"))
        let head = recorded(out.appendingPathComponent("2026-11-02T12-00-00"))
        let part = recorded(out.appendingPathComponent("2026-11-02T12-30-00"))
        try Continuation.addPart(head, part)
        let running = recorded(out.appendingPathComponent("2026-11-02T13-00-00"))
        let waiting = recorded(out.appendingPathComponent("2026-11-02T14-00-00"))
        let live = recorded(out.appendingPathComponent("2026-11-02T15-00-00"))
        let notMeeting = recorded(out.appendingPathComponent("Notes"))
        ProcessState.mark(waiting, ProcessState.models, missing: ["Parakeet"])
        writeJSON(dir.appendingPathComponent("state.json"), ["state": "stopped", "queued": [queued.path, head.path]])
        _ = try Harness(dir, activity: noCall) { deps, _ in
            deps.outputDir = out
            deps.processes = { ["/Applications/Palaver.app/python -m palaver process \(running.path)"] }
            deps.liveRunning = { $0.path == live.path }
        }
        func reason(_ f: URL) -> String? { ProcessState.read(f)?["reason"]?.stringValue }
        #expect(reason(old) == ProcessState.error)
        #expect([done, queued, head, part, running, live, notMeeting].map(reason) == [String?](repeating: nil, count: 7))
        #expect(reason(waiting) == ProcessState.models)
    }
}

/// test_continuation.py's listing (the join stays in Python's `process`).
@Suite struct PartsFileTests {
    @Test func partsAreListedOnTheFirstPartInOrder() async throws {
        let dir = tempDir()
        let head = dir.appendingPathComponent("2026-11-02T12-00-00"), a = dir.appendingPathComponent("2026-11-02T12-30-00"),
            b = dir.appendingPathComponent("2026-11-02T12-45-00")
        for f in [head, a, b] { mkdir(f) }
        #expect(Continuation.parts(head).isEmpty)
        try Continuation.addPart(head, a)
        try Continuation.addPart(head, b)
        try Continuation.addPart(head, a)  // once
        #expect(parts(head) == [a.path, b.path])
        let text = try String(contentsOf: head.appendingPathComponent("parts.json"), encoding: .utf8)
        #expect(text == "{\n  \"parts\": [\n    \"2026-11-02T12-30-00\",\n    \"2026-11-02T12-45-00\"\n  ]\n}")
        // What `process` keeps there stays.
        touch(head.appendingPathComponent("parts.json"), #"{"complete": false, "parts": ["2026-11-02T12-30-00"]}"#)
        try Continuation.addPart(head, b)
        let kept = try #require(JSONValue.parse(try Data(contentsOf: head.appendingPathComponent("parts.json"))))
        #expect(kept["complete"] == .bool(false) && kept["parts"] == .strings(["2026-11-02T12-30-00", "2026-11-02T12-45-00"]))
        #expect(throws: (any Error).self) { try Continuation.addPart(dir.appendingPathComponent("gone"), a) }
    }
}

/// Fix round 1: the calendar never holds a recording's start back. Its lookups (`palaver app query
/// event-key`) answer later; the recording starts at once and the continuation is decided when
/// they are in, with Python's rule: another calendar event is a meeting of its own.
final class SlowCalendar {
    var asked: [Date] = []
    var readyAt: Double
    let key: (Date) -> String?
    let clock: () -> Double
    init(readyAt: Double, clock: @escaping () -> Double, key: @escaping (Date) -> String?) {
        self.readyAt = readyAt; self.clock = clock; self.key = key
    }
    func lookup(_ when: Date) -> EventLookup {
        asked.append(when)
        return clock() >= readyAt ? .known(key(when)) : .pending
    }
}

extension DaemonTicks {
    @Suite struct SlowCalendarTests {
        /// A call cut at 402 and still on after the restart at 430; the trigger starts at 434, the
        /// calendar answers ~3 s later.
        func restart(_ dir: URL, key: @escaping (Date) -> String?) async throws -> (Harness, SlowCalendar) {
            let call = teams { 10 <= $0 && $0 < 1000 }
            let (sessions, _) = try await quitDuringACall(dir, call)
            var cal: SlowCalendar!
            let h = try Harness(dir, activity: call, sessions: sessions, start: 430) { deps, h in
                cal = SlowCalendar(readyAt: 437, clock: { h.clock }, key: key)
                deps.eventKeyAt = { cal.lookup($0) }
            }
            #expect(cal.asked == [WALL0.addingTimeInterval(402)])  // the cut's key, asked ahead when it was restored
            return (h, cal)
        }

        @Test func theSameEventContinuesOnceTheCalendarAnswers() async throws {
            let dir = tempDir()
            let (h, _) = try await restart(dir) { _ in "standup" }
            await h.run { $0 > 434 }
            #expect(h.sessions.count == 2 && h.sessions[1].started && h.sessions[1].t0 == 434)  // at once
            #expect(h.status()["continues"] == .array([]) && h.status()["cut"]?["folders"] == .strings([h.rec(0).path]))
            #expect(!h.titles.contains("Recording continued") && !h.titles.contains("Recording meeting"))
            await h.run { $0 > 440 }
            #expect(parts(h.rec(0)) == [h.rec(1).path])
            #expect(h.status()["continues"] == .strings([h.rec(0).path]) && h.status()["cut"] == .null)
            #expect(h.status()["why"]?["since"] == .string(WallTime.iso(WALL0.addingTimeInterval(14), TZ, seconds: true)))
            #expect(h.titles.filter { $0 == "Recording continued" }.count == 1 && !h.titles.contains("Recording meeting"))
            await h.run { $0 > 1100 }
            #expect(p(h.launched) == [h.rec(0).path])  // one meeting
        }

        @Test func anotherEventIsAMeetingOfItsOwnOnceTheCalendarAnswers() async throws {
            let dir = tempDir()
            let (h, _) = try await restart(dir) { $0 < WALL0.addingTimeInterval(420) ? "standup" : "1:1" }
            await h.run { $0 > 434 }
            #expect(h.sessions[1].started && h.sessions[1].t0 == 434)
            await h.run { $0 > 440 }
            #expect(parts(h.rec(0)).isEmpty && h.status()["continues"] == .array([]))
            #expect(h.notifications.last.map { [$0.title, $0.open ?? ""] } == ["Recording meeting", "rec1"])
            #expect(h.status()["cut"]?["folders"] == .strings([h.rec(0).path]))  // held until its window passes
            await h.run { $0 > 710 }
            #expect(p(h.launched) == [h.rec(0).path])  // on its own after 5 min
        }

        @Test func aCutWithoutAnEventNeedsNoSecondLookup() async throws {
            let dir = tempDir()
            let (h, cal) = try await restart(dir) { _ in nil }
            cal.readyAt = 0
            await h.run { $0 > 434 }
            #expect(parts(h.rec(0)) == [h.rec(1).path])
            #expect(cal.asked.allSatisfy { $0 == WALL0.addingTimeInterval(402) })  // never "now"
        }

        @Test func aCalendarThatNeverAnswersContinuesAsPythonDidWithoutAKey() async throws {
            let dir = tempDir()
            let (h, cal) = try await restart(dir) { _ in "standup" }
            cal.readyAt = .infinity
            await h.run { $0 > 434 }
            #expect(parts(h.rec(0)).isEmpty)
            await h.run { $0 > 434 + 16 }  // gives up waiting: no key known is no other event
            #expect(parts(h.rec(0)) == [h.rec(1).path] && h.titles.contains("Recording continued"))
        }

        @Test func aStopBeforeTheCalendarAnswersStillDecides() async throws {
            let dir = tempDir()
            let (h, cal) = try await restart(dir) { _ in "standup" }
            cal.readyAt = .infinity
            await h.run { $0 > 434 }
            h.daemon.shutdown()  // quit again at once
            #expect(h.state()["cut"]?["folders"] == .strings([h.rec(0).path, h.rec(1).path]))
        }

        @Test func aNewCutsKeyIsAskedAheadToo() async throws {
            let dir = tempDir()
            var asked: [Date] = []
            let h = try Harness(dir, activity: teams { $0 >= 10 }) { deps, _ in
                deps.eventKeyAt = { asked.append($0); return .pending }
            }
            await h.run { $0 > 100 }
            h.daemon.shutdown()
            #expect(asked == [WALL0.addingTimeInterval(102)])
        }

        @Test func aCutIsReadInTheDaemonsTimeZone() async throws {
            let dir = tempDir()
            mkdir(dir.appendingPathComponent("rec0"))
            // Naive times (no offset): local time, the daemon's.
            writeJSON(dir.appendingPathComponent("state.json"), ["state": "stopped", "cut": [
                "folders": [dir.appendingPathComponent("rec0").path], "trigger": "teams", "seconds": 400.0,
                "at": "2026-10-29T12:12:42", "since": "2026-10-29T12:06:14"] as [String: Any]])
            let h = try Harness(dir, activity: noCall, start: 400)
            await h.run { $0 > 404 }
            #expect(h.launched.isEmpty)  // 12:12:42+01:00 is 2 s ago, not an hour
            #expect(Cut(.object([("folders", .strings(["/m/a"])), ("at", .string("2026-10-29T12:12:42")),
                                 ("since", .string("2026-10-29T12:06:14"))]), timeZone: TZ) != nil)
        }
    }
}
