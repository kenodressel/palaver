// tests/test_daemon.py, the daemon's part, with the same timings and texts: a fake clock (2 s a
// tick), fake sessions and fake workers. The trigger and detector tests are in PalaverCoreTests.
import Foundation
import Testing
import PalaverCore
@testable import PalaverDaemon

func p(_ urls: [URL]) -> [String] { urls.map(\.path) }

extension DaemonTicks {
    @Suite struct DaemonRecordingTests {
        @Test func daemonRecordsAMeetingAndQueuesProcessing() async throws {
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 700 })
            await h.run { $0 > 760 }
            #expect(h.sessions.count == 1 && h.sessions[0].started && h.sessions[0].stopped)
            #expect(p(h.launched) == [h.rec(0).path])
            // #23: said plainly, for when the menu bar icon is out of sight; a click opens the meeting.
            #expect(h.titles == ["Recording the Teams call", "Meeting recorded"])
            #expect(h.notifications.map { [$0.message, $0.open ?? ""] }
                    == [["Palaver records until the call ends.", "rec0"], ["10 min — transcribing in the background", "rec0"]])
            #expect(h.state()["state"]?.stringValue == "idle")
        }

        @Test func daemonSkipsProcessingVeryShortSessions() async throws {
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 40 }, duration: 30)
            await h.run { $0 > 80 }
            #expect(h.sessions.count == 1 && h.launched.isEmpty)
        }

        struct Restarting: Error {}

        @Test func daemonSurvivesDetectorErrors() async throws {
            let h = try Harness(tempDir(), activity: { now in
                if 20 <= now && now < 26 { throw Restarting() }
                return 10 <= now && now < 300 ? .teams : nil
            })
            await h.run { $0 > 360 }
            #expect(h.sessions.count == 1)  // errors are treated as "no change", not as release
        }

        @Test func daemonStopsRecordingOnShutdown() async throws {
            let h = try Harness(tempDir(), activity: teams { $0 >= 10 })
            await h.run { $0 > 100 }
            h.daemon.shutdown()
            #expect(h.sessions[0].stopped)
            // Held back for the next start to continue (issue #47), not processed yet.
            #expect(h.launched.isEmpty && h.state()["cut"]?["folders"] == .strings([h.rec(0).path]))
        }

        @Test func stateFileReportsRecording() async throws {
            let h = try Harness(tempDir(), activity: teams { $0 >= 10 })
            await h.run { $0 > 30 }
            #expect(h.state()["state"]?.stringValue == "recording")
            #expect(h.state()["folder"]?.stringValue == h.rec(0).path)
            h.daemon.shutdown()
        }

        @Test func pausedDaemonIgnoresTeamsAndStopsRunningAutoSession() async throws {
            let h = try Harness(tempDir(), activity: teams { $0 >= 10 })
            await h.run { $0 > 30 }
            #expect(h.status()["state"]?.stringValue == "recording")
            h.daemon.setAuto(false)
            #expect(h.sessions[0].stopped && p(h.launched) == [h.rec(0).path])
            await h.run { $0 > 100 }
            #expect(h.sessions.count == 1)
            #expect(h.status()["state"]?.stringValue == "paused")
            h.daemon.setAuto(true)
            await h.run { $0 > 120 }
            #expect(h.sessions.count == 2)  // Teams still in a call → records again
        }

        @Test func manualSessionIsNotStoppedByTeamsTrigger() async throws {
            let h = try Harness(tempDir(), activity: noCall)
            h.daemon.startManual()
            await h.run { $0 > 120 }
            #expect(!h.sessions[0].stopped)
            h.daemon.stopManual()
            #expect(h.sessions[0].stopped && p(h.launched) == [h.rec(0).path])
        }

        @Test func manualStartWhileAutoRecordingIsANoop() async throws {
            let h = try Harness(tempDir(), activity: teams { $0 >= 10 })
            await h.run { $0 > 30 }
            #expect(!h.daemon.startManual())
            #expect(h.sessions.count == 1)
            h.daemon.shutdown()
        }

        @Test func statusSnapshot() async throws {
            let h = try Harness(tempDir(), activity: noCall)
            let s = h.status()
            #expect(s["state"]?.stringValue == "idle" && s["auto"] == .bool(true) && s["folder"] == .null)
        }

        @Test func sessionsKnowHowTheyWereStarted() async throws {
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 100 })
            await h.run { $0 > 150 }
            h.daemon.startManual()
            h.daemon.stopManual()
            #expect(h.sessions.items.map { $0!.trigger } == ["teams", "manual"])
        }

        @Test func daemonWarnsWhenATrackIsMissing() async throws {
            let h = try Harness(tempDir(), activity: teams { $0 >= 10 })
            h.newSession = { [unowned h] trigger in
                h.newSession = nil
                let s = h.makeSession(trigger)
                s.missing = ["microphone"]
                return s
            }
            await h.run { $0 > 30 }
            #expect(h.titles.contains("Recording without the microphone"))
            #expect(h.status()["missing"] == .strings(["microphone"]))
            h.daemon.shutdown()
        }

        @Test func switchingFromTeamsToSlackRecordsTwoMeetings() async throws {
            let h = try Harness(tempDir(), activity: { now in 10 <= now && now < 300 ? .teams : 300 <= now && now < 700 ? .slack : nil })
            await h.run { $0 > 760 }
            #expect(h.sessions.items.map { $0!.trigger } == ["teams", "slack"])
            #expect(h.sessions.items.allSatisfy { $0!.started && $0!.stopped })
            #expect(p(h.launched) == [h.rec(0).path, h.rec(1).path])
        }

        @Test func aSlackCallDuringARecordedTeamsCallDoesNotCutIt() async throws {
            // The tester's report: Slack takes the mic (a call answered, or ringing) while Teams is in its call.
            let r = try HeldRig(tempDir(), slack: [(300, 1500)], teams: [(10, 1000)], heard: [(10, 1500)])
            let h = r.h
            await h.run { $0 > 900 }
            #expect(h.sessions.items.map { $0!.trigger } == ["teams"])
            #expect(!h.sessions[0].stopped)
            await h.run { $0 > 1100 }  // Teams hung up; the Slack call goes on: its own meeting, as before
            #expect(h.sessions.items.map { $0!.trigger } == ["teams", "slack"])
            #expect(h.sessions[0].stopped && h.sessions[0].stopReason == "call_ended")
            await h.run { $0 > 1600 }
            #expect(h.sessions[1].stopped && p(h.launched) == [h.rec(0).path, h.rec(1).path])
        }

        @Test func aSlackRingtoneDuringARecordedTeamsCallDoesNotCutIt() async throws {
            let r = try HeldRig(tempDir(), teams: [(10, 1000)], slackSpeaker: [(300, 330)], heard: [(10, 1000)])
            await r.h.run { $0 > 900 }
            #expect(r.h.sessions.count == 1 && !r.h.sessions[0].stopped)
        }

        @Test func aTeamsCallDuringARecordedMutedHuddleDoesNotCutIt() async throws {
            let r = try HeldRig(tempDir(), slack: [(10, 100)], teams: [(300, 400)], slackSpeaker: [(100, 1000)],
                                heard: [(10, 1000)])
            let h = r.h
            await h.run { $0 > 900 }
            #expect(h.sessions.items.map { $0!.trigger } == ["slack"])
            #expect(!h.sessions[0].stopped)
            await h.run { $0 > 1100 }
            #expect(h.sessions.count == 1 && h.sessions[0].stopReason == "call_ended")
        }

        /// The default grace (config.toml's grace_period_seconds left out), as the app's trigger has it.
        static let grace = Double(Config().gracePeriodSeconds)

        @Test func theRecordingStopsWithinSecondsOfTheCallsEnd() async throws {
            let r = try HeldRig(tempDir(), teams: [(10, 500)], heard: [(10, 500)], grace: Self.grace)
            await r.h.run { $0 > 506 }  // Teams let go at 500
            #expect(r.h.sessions.count == 1 && r.h.sessions[0].stopped && r.h.sessions[0].stopReason == "call_ended")
        }

        @Test func aDeviceSwitchReleasingTheMicBrieflySplitsNothing() async throws {
            let r = try HeldRig(tempDir(), teams: [(10, 300), (303, 600)], heard: [(10, 600)], grace: Self.grace)
            await r.h.run { $0 > 500 }
            #expect(r.h.sessions.count == 1 && !r.h.sessions[0].stopped)
        }

        @Test func meetingAfterMeetingRecordsTwo() async throws {
            // Leave one Teams meeting, join the next 10 s later: two meetings, not one running on.
            let r = try HeldRig(tempDir(), teams: [(10, 300), (310, 600)], heard: [(10, 600)], grace: Self.grace)
            await r.h.run { $0 > 400 }
            #expect(r.h.sessions.count == 2 && r.h.sessions[0].stopped && !r.h.sessions[1].stopped)
        }

        // Keno's daemon.log, 2026-11-10 (t = 0 at 15:59:00 for the first meeting, at 16:05:00 for the second).
        static let helper = "com.microsoft.teams2.helper", module = "com.microsoft.teams2.modulehost"
        /// Spans of (from, to, helper plays, modulehost's mic, modulehost's speaker).
        static func teamsAudio(_ spans: [(Double, Double, Bool, Bool, Bool)]) -> @Sendable (Double) -> [AudioProcess] {
            { now in
                guard let s = spans.first(where: { $0.0 <= now && now < $0.1 }) else { return [] }
                var out: [AudioProcess] = []
                if s.2 { out.append(AudioProcess(bundleId: helper, runningInput: false, runningOutput: true)) }
                if s.3 || s.4 { out.append(AudioProcess(bundleId: module, runningInput: s.3, runningOutput: s.4)) }
                return out
            }
        }

        @Test func aTeamsHangUpStopsAboutFiveSecondsLaterThoughTeamsKeepsTheMic() async throws {
            // 15:59:57 helper speaker + modulehost mic+speaker; 16:00:00 the speaker goes (the hang-up);
            // 16:00:08 modulehost mic alone; 16:00:09 none. Before: stopped at 16:00:19.
            let audio = Self.teamsAudio([(10, 60, true, true, true), (60, 68, true, true, false), (68, 69, false, true, false)])
            let r = try HeldRig(tempDir(), heard: [(10, 60)], grace: Self.grace, audio: audio)
            await r.h.run { $0 > 64 }
            #expect(r.h.sessions.count == 1 && !r.h.sessions[0].stopped)
            await r.h.run { $0 > 66 }  // 2 s ticks here; the app's 1 s tick stops at 16:00:05
            #expect(r.h.sessions[0].stopped && r.h.sessions[0].stopReason == "call_ended")
            await r.h.run { $0 > 200 }
            #expect(r.h.sessions.count == 1)  // the mic Teams kept starts nothing
        }

        @Test func teamsEndingWithOnlyTheHelperPlayingStopsAfterTheGrace() async throws {
            // ...16:05:11 modulehost mic+speaker; 16:22:47 only teams2.helper's speaker. Before: 16:22:57.
            let audio = Self.teamsAudio([(10, 1067, true, true, true), (1067, 1100, true, false, false)])
            let r = try HeldRig(tempDir(), heard: [(10, 1067)], grace: Self.grace, audio: audio)
            await r.h.run { $0 > 1072 }
            #expect(!r.h.sessions[0].stopped)
            await r.h.run { $0 > 1074 }  // first seen at the 1068 tick: 5-6 s after it, as the hang-up
            #expect(r.h.sessions.count == 1 && r.h.sessions[0].stopped && r.h.sessions[0].stopReason == "call_ended")
        }

        @Test func teamsFlickeringToMicOnlyMidCallStopsNothing() async throws {
            // 16:04:20 modulehost mic, 16:04:21 modulehost speaker, 16:04:22 mic+speaker; 16:05:10 mic,
            // 16:05:11 mic+speaker. Here each 2 s (the ticks), and once 4 s of mic only.
            let audio = Self.teamsAudio([(10, 300, true, true, true), (300, 302, true, true, false), (302, 304, true, false, true),
                                         (304, 400, true, true, true), (400, 402, true, true, false), (402, 500, true, true, true),
                                         (500, 504, true, true, false), (504, 900, true, true, true)])
            let r = try HeldRig(tempDir(), heard: [(10, 900)], grace: Self.grace, audio: audio)
            await r.h.run { $0 > 800 }
            #expect(r.h.sessions.count == 1 && !r.h.sessions[0].stopped)
        }

        @Test func theNextTeamsMeetingWhileTeamsStillHeldTheMicIsItsOwn() async throws {
            let audio = Self.teamsAudio([(10, 60, true, true, true), (60, 100, true, true, false), (100, 600, true, true, true)])
            let r = try HeldRig(tempDir(), heard: [(10, 60), (100, 600)], grace: Self.grace, audio: audio)
            await r.h.run { $0 > 200 }
            #expect(r.h.sessions.count == 2 && r.h.sessions[0].stopped && !r.h.sessions[1].stopped)
        }

        @Test func aSlackHuddleIsRecordedAsOne() async throws {
            let h = try Harness(tempDir(), activity: slack { 10 <= $0 && $0 < 700 })
            await h.run { $0 > 760 }
            #expect(h.sessions.items.map { $0!.trigger } == ["slack"])
        }

        @Test func daemonStartsStreamOnlyWhenRealtime() async throws {
            var on = true
            var streams: [URL] = []
            let h = try Harness(tempDir(), activity: teams { (10 <= $0 && $0 < 100) || (200 <= $0 && $0 < 300) }) { deps, _ in
                deps.launchStream = { streams.append($0); return FakeWorker(done: { true }) }
                deps.realtime = { on }
            }
            await h.run { $0 > 150 }
            on = false
            await h.run { $0 > 400 }
            #expect(h.sessions.count == 2)
            #expect(p(streams) == [h.rec(0).path])
        }

        @Test func daemonSkipsLiveProcessingWhenSwitchedOff() async throws {
            for wanted in [true, false] {
                var live: [URL] = []
                let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 700 }) { deps, _ in
                    deps.launchLive = { live.append($0); return FakeWorker(done: { true }) }
                    deps.live = { wanted }
                }
                await h.run { $0 > 740 }
                #expect(p(live) == (wanted ? [h.rec(0).path] : []))
            }
        }

        @Test func daemonLetsATestRecordingGoBeforeAMeeting() async throws {
            var order: [String] = []
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 700 }) { deps, _ in
                deps.beforeRecord = { start in
                    order.append("test stopped")
                    defer { order.append("gate open") }
                    return try start()
                }
            }
            h.newSession = { [unowned h] trigger in
                h.newSession = nil
                let s = h.makeSession(trigger)
                s.onStart = { order.append("start") }
                return s
            }
            await h.run { $0 > 40 }
            #expect(Array(order.prefix(3)) == ["test stopped", "start", "gate open"])
        }

        @Test func aStartThatFailsNotifiesAndWaitsForTheRelease() async throws {
            struct NoMic: Error, CustomStringConvertible { var description: String { "neither the microphone nor system audio can be recorded" } }
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 100 }) { deps, _ in
                deps.newSession = { _ in FailingSession() }
            }
            await h.run { $0 > 60 }
            #expect(h.sent.contains { $0 == ("Meeting recording failed", "neither the microphone nor system audio can be recorded") })
            #expect(h.titles.filter { $0 == "Meeting recording failed" }.count == 1)  // not every tick: blocked until released
            #expect(h.status()["state"]?.stringValue == "idle")
        }

        @Test func exitedLiveWorkersAreReapedOnEveryTick() async throws {
            var polled: [Double] = []
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 50 })
            h.daemon.deps.launchLive = { [unowned h] _ in
                let w = FakeWorker(done: { true })
                w.onPoll = { polled.append(h.clock) }
                return w
            }
            await h.run { $0 > 20 }  // recording: not queued, nothing waits for it
            #expect(!polled.isEmpty && h.daemon.workers().isEmpty)
        }

        @Test func aRecordSwitchTurnedOffStopsItsCallNow() async throws {
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 900 })
            await h.run { $0 > 50 }
            h.daemon.switchedOff("slack")  // another app: the Teams call goes on
            #expect(h.status()["state"]?.stringValue == "recording")
            h.daemon.switchedOff("teams")
            #expect(h.sessions[0].stopReason == "auto_off")
            #expect(h.status()["state"]?.stringValue != "recording")
        }

        @Test func eachRecordingKnowsWhyItStopped() async throws {
            let h = try Harness(tempDir(), activity: teams { (10 <= $0 && $0 < 100) || (200 <= $0 && $0 < 900) })
            await h.run { $0 > 150 }
            #expect(h.sessions[0].stopReason == "call_ended")
            #expect(h.status()["last_stop"] == .object([("folder", .string(h.rec(0).path)), ("reason", .string("call_ended")),
                                                         ("text", .string("Teams call ended")), ("at", .string(wall(110)))]))
            await h.run { $0 > 300 }
            h.daemon.setAuto(false)
            #expect(h.sessions[1].stopReason == "auto_off")
            await h.run { $0 > 310 }
            h.daemon.startManual()
            h.daemon.stopManual()
            #expect(h.sessions[2].stopReason == "by_you")
            let x = try Harness(tempDir(), activity: teams { _ in true }, trigger: Trigger(startAfter: 0, grace: 10, maxSession: 100))
            await x.run { $0 > 110 }
            #expect(x.sessions[0].stopReason == "max_length")
        }

        @Test func theStatusSaysWhyItRecordsAndWithWhichMic() async throws {
            let h = try Harness(tempDir(), activity: teams { $0 >= 10 })
            h.newSession = { [unowned h] trigger in
                h.newSession = nil
                let s = h.makeSession(trigger)
                s.micDevice = "AirPods"; s.micRate = 24000; s.micSource = "avcapture"
                s.systemRate = 48000; s.systemSource = "process-tap"
                return s
            }
            await h.run { $0 > 30 }
            let why = h.status()["why"]
            #expect(why == .object([("trigger", .string("teams")), ("since", .string(WallTime.iso(WALL0.addingTimeInterval(14), TZ, seconds: true))),
                                    ("restarts", .int(0)),
                                    ("mic", .object([("device", .string("AirPods")), ("rate", .double(24000)), ("source", .string("avcapture"))])),
                                    ("system", .object([("rate", .double(48000)), ("source", .string("process-tap"))]))]))
            #expect(h.status()["why_text"] == .string("Recording · Teams call since 12:06 · mic AirPods (24 kHz)"))
            #expect(h.state()["why_text"] == h.status()["why_text"])
            h.daemon.shutdown()
            #expect(h.status()["why"] == .null)
        }

        @Test func anAudioProblemShowsInTheStatusAndNotifiesOnce() async throws {
            let h = try Harness(tempDir(), activity: teams { $0 >= 10 })
            h.newSession = { [unowned h] trigger in
                h.newSession = nil
                let s = h.makeSession(trigger)
                s.systemDevice = "AirPods Pro"; s.systemRate = 24000; s.systemSource = "process-tap"
                return s
            }
            await h.run { $0 > 20 }
            #expect(h.status()["warnings"] == .array([]) && h.status()["why"]?["problems"] == nil)
            #expect(h.status()["why"]?["system"]?["device"] == .string("AirPods Pro"))

            let s = h.sessions[0]
            let speed = "System audio is playing at the wrong speed; Palaver is correcting it"
            s.problems = [RecordingProblem(id: 1, kind: "speed", track: "system", start: 6)]
            await h.run { $0 > 40 }
            #expect(h.status()["warnings"] == .strings([speed]))
            #expect(h.status()["why"]?["problems"] == .array([.object([("kind", .string("speed")), ("track", .string("system")),
                                                                      ("start", .double(6))])]))
            #expect(h.state()["warnings"] == h.status()["warnings"])
            func alerts() -> [String] { h.notifications.filter { $0.title == "Audio problem while recording" }.map(\.message) }
            #expect(alerts() == [speed])

            // The same cause: what opens within 30 s of it is no new notification.
            s.problems.append(RecordingProblem(id: 2, kind: "length", track: "system", start: 20))
            await h.run { $0 > 50 }
            #expect(h.status()["warnings"]?.arrayValue?.count == 2 && alerts() == [speed])

            // Later, something else: one more.
            s.problems[0].end = 50; s.problems[1].end = 50
            s.problems.append(RecordingProblem(id: 3, kind: "stalled", track: "mic", start: 70))
            await h.run { $0 > 60 }
            #expect(h.status()["warnings"] == .strings(["No microphone audio is arriving"]))
            #expect(alerts() == [speed, "No microphone audio is arriving"])
            h.daemon.shutdown()
            #expect(h.status()["warnings"] == .array([]))
        }

        @Test func aSilentMicIsASoftHintWithoutANotification() async throws {
            let h = try Harness(tempDir(), activity: teams { $0 >= 10 })
            await h.run { $0 > 20 }
            h.sessions[0].hints = [(kind: "silent", track: "mic")]
            await h.run { $0 > 30 }
            let status = h.status()
            #expect(status["hints"] == .strings(["Your mic sends nothing — muted?"]) && status["warnings"] == .array([]))
            #expect(status["why"]?["hints"] == .array([.object([("kind", .string("silent")), ("track", .string("mic"))])]))
            #expect(!h.titles.contains("Audio problem while recording"))
            h.daemon.shutdown()
            #expect(h.status()["hints"] == .array([]))
        }

        @Test func busyReasonSaysWhatKeepsPalaverFromRestarting() async throws {
            #expect(busyReason(.object([("state", .string("recording"))])) == "recording")
            #expect(busyReason(.object([("state", .string("idle")), ("teams_active", .bool(true))])) == "a call")
            #expect(busyReason(.object([("transcribing", .bool(false)), ("queued", .strings(["/m/a"]))])) == "transcribing")
            #expect(busyReason(.object([("writing_notes", .string("/m/a"))])) == "writing notes")
            #expect(busyReason(.object([("notes_queued", .strings(["/m/a"]))])) == "writing notes")
            #expect(busyReason(.object([("state", .string("idle")), ("indexing", .bool(true)), ("queued", .array([]))])) == nil)
            let h = try Harness(tempDir(), activity: teams { $0 >= 10 })
            #expect(busyReason(h.status()) == nil)
            await h.run { $0 > 12 }
            #expect(busyReason(h.status()) == "a call")
            await h.run { $0 > 20 }
            #expect(busyReason(h.status()) == "recording")
            h.daemon.shutdown()
        }
    }
}

final class FailingSession: RecordingSessionLike {
    struct NoMic: Error, CustomStringConvertible { var description: String { "neither the microphone nor system audio can be recorded" } }
    func start() throws -> URL { throw NoMic() }
    func stop(reason: String?) throws -> Double { 0 }
}

extension DaemonTicks {
    @Suite struct DaemonQueueTests {
        @Test func queueSurvivesRestart() async throws {
            // Quitting while one recording transcribes and another is queued must not lose the queued one.
            let dir = tempDir()
            let done = dir.appendingPathComponent("done"), pending = dir.appendingPathComponent("pending")
            mkdir(done); touch(done.appendingPathComponent("notion.json"), "{}")
            mkdir(pending)
            writeJSON(dir.appendingPathComponent("state.json"),
                      ["state": "stopped", "queued": [done.path, pending.path, dir.appendingPathComponent("deleted").path]])
            let h = try Harness(dir, activity: noCall)
            await h.run { $0 > 4 }
            #expect(p(h.launched) == [pending.path])
        }

        @Test func queueWithoutAutoSyncIsDoneOnceTranscribed() async throws {
            let dir = tempDir()
            let done = dir.appendingPathComponent("done"), pending = dir.appendingPathComponent("pending")
            mkdir(done); touch(done.appendingPathComponent("transcript.md"))
            mkdir(pending)
            writeJSON(dir.appendingPathComponent("state.json"), ["state": "stopped", "queued": [done.path, pending.path]])
            let h = try Harness(dir, activity: noCall) { deps, _ in deps.doneMarker = { "transcript.md" } }
            await h.run { $0 > 4 }
            #expect(p(h.launched) == [pending.path])
        }

        @Test func daemonProcessesLiveAndWaitsForItBeforeRun() async throws {
            // `run` after the live worker has written the transcript: it only merges.
            var live: [URL] = [], stopped: [URL] = []
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 700 })
            h.daemon.deps.launchLive = { live.append($0); return FakeWorker(done: { true }) }
            h.daemon.deps.liveRunning = { [unowned h] _ in h.clock < 760 }
            h.daemon.deps.stopLive = { stopped.append($0) }
            await h.run { $0 > 740 }
            #expect(p(live) == [h.rec(0).path])  // started with the recording
            #expect(h.launched.isEmpty)  // recording stopped at ~710, worker still finishing
            await h.run { $0 > 780 }
            #expect(p(h.launched) == [h.rec(0).path] && stopped.isEmpty)
        }

        @Test func daemonStopsAStuckLiveWorker() async throws {
            var stopped: [URL] = []
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 700 })
            h.daemon.deps.liveRunning = { _ in true }
            h.daemon.deps.stopLive = { stopped.append($0) }
            await h.run { $0 > 710 + 15 * 60 + 10 }
            #expect(p(stopped) == [h.rec(0).path])
            #expect(h.launched.isEmpty)  // waits for it to exit first
            await h.run { $0 > 710 + 15 * 60 + 80 }
            #expect(p(stopped) == [h.rec(0).path])  // asked once
            #expect(p(h.launched) == [h.rec(0).path])  // it would not go: `process` decides (and is retried)
        }

        @Test func aWorkerThatExitsAfterBeingStoppedIsWaitedFor() async throws {
            var stopped: [Double] = []
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 700 })
            h.daemon.deps.liveRunning = { [unowned h] _ in stopped.isEmpty || h.clock < stopped[0] + 20 }
            h.daemon.deps.stopLive = { [unowned h] _ in stopped.append(h.clock) }
            await h.run { $0 > 710 + 15 * 60 + 4 }
            #expect(stopped.count == 1 && h.launched.isEmpty)
            await h.run { $0 > stopped[0] + 24 }
            #expect(p(h.launched) == [h.rec(0).path])
        }

        @Test func processingThatRefusesIsTriedAgainLater() async throws {
            // `process` exits 3 while a live worker (or a part) is still busy: tried again, never dropped.
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 700 })
            var answers: [Int32] = [3, 0]
            h.launchProcessing = { _ in FakeWorker(done: { true }, rc: answers.removeFirst()) }
            await h.run { $0 > 720 }
            #expect(p(h.launched) == [h.rec(0).path])
            #expect(h.status()["queued"] == .strings([h.rec(0).path]))
            await h.run { $0 > 720 + 70 }
            #expect(p(h.launched) == [h.rec(0).path, h.rec(0).path])
            #expect(h.status()["queued"] == .array([]))
        }

        @Test func aFailedTranscriptionIsReportedAndNotRetried() async throws {
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 700 })
            h.launchProcessing = { _ in FakeWorker(done: { true }, rc: 1) }
            await h.run { $0 > 2000 }
            #expect(p(h.launched) == [h.rec(0).path] && h.status()["queued"] == .array([]))
            #expect(h.sent.contains { $0 == ("Transcription failed", "rec0: open it to see why and to transcribe it again") })
        }

        @Test func transcribeAgainQueuesAFailedMeetingFirst() async throws {
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 700 })
            var rcs: [Int32] = [1, 0]
            h.launchProcessing = { _ in FakeWorker(done: { true }, rc: rcs.removeFirst()) }
            await h.run { $0 > 800 }
            let rec0 = h.rec(0)
            ProcessState.mark(rec0, ProcessState.error, error: "boom")  // as `process` leaves it
            #expect(h.daemon.transcribeAgain(rec0))
            #expect(ProcessState.read(rec0) == nil)  // the window shows it transcribing
            await h.run { $0 > 810 }
            #expect(p(h.launched) == [rec0.path, rec0.path] && h.status()["queued"] == .array([]))
        }

        /// Killed, or crashed before `process` could write failed.json: the window offers Transcribe Again.
        @Test func failedRunMarksExit() async throws {
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 700 })
            h.launchProcessing = { _ in FakeWorker(done: { true }, rc: -SIGKILL) }  // poll() is Popen's returncode
            await h.run { $0 > 800 }
            let state = try #require(ProcessState.read(h.rec(0)))
            #expect(state["reason"]?.stringValue == ProcessState.error)
            #expect(state["error"]?.stringValue == "it stopped unexpectedly, exit -9")
            // One `process` wrote itself is kept.
            let x = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 700 })
            x.launchProcessing = { [unowned x] folder in
                ProcessState.mark(folder, ProcessState.error, error: "no speech found")
                return FakeWorker(done: { x.clock > 0 }, rc: 1)
            }
            await x.run { $0 > 800 }
            #expect(ProcessState.read(x.rec(0))?["error"]?.stringValue == "no speech found")
        }

        @Test func shortRecordingMarkedNotTranscribed() async throws {
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 40 }, duration: 30)
            await h.run { $0 > 80 }
            #expect(h.launched.isEmpty)
            #expect(ProcessState.read(h.rec(0))?["error"]?.stringValue == "shorter than a minute")
            #expect(h.sent.last! == ("Meeting recorded", "rec0: under a minute, not transcribed"))
        }

        @Test func aMeetingRecordedBeforeItsModelsWaitsAndIsTranscribedOnceTheyAreHere() async throws {
            var ready = false
            let dir = tempDir()
            let h = try Harness(dir, activity: teams { 10 <= $0 && $0 < 700 }) { deps, _ in deps.modelsReady = { _ in ready } }
            let rec0 = h.rec(0)
            h.launchProcessing = { folder in
                ProcessState.mark(folder, ProcessState.models, missing: ["Parakeet"])
                return FakeWorker(done: { true }, rc: DaemonTiming.exitModels)
            }
            await h.run { $0 > 2000 }
            #expect(p(h.launched) == [rec0.path] && h.status()["queued"] == .strings([rec0.path]))  // not again while missing
            #expect(h.sent.contains { $0 == ("Meeting recorded", "rec0: transcribed once the models are downloaded") })
            #expect(!h.titles.contains("Transcription failed"))

            let again = try Harness(dir, activity: noCall, sessions: Sessions([nil]), start: 2000) { deps, _ in
                deps.modelsReady = { _ in ready }
            }  // the app restarted
            await again.run { $0 > 2100 }
            #expect(again.launched.isEmpty)  // still waiting: the mark says so, no run to find out
            ready = true
            await again.run { $0 > 2200 }
            #expect(p(again.launched) == [rec0.path])
        }

        @Test func modelsNotKnownYetWaitWithoutLaunching() async throws {
            // The answer comes from `palaver app query` in the background: until it is there, nothing runs.
            var answer: Bool? = nil
            let dir = tempDir()
            let rec = dir.appendingPathComponent("2026-11-02T09-00-00")
            mkdir(rec)
            ProcessState.mark(rec, ProcessState.models, missing: ["Parakeet"])
            writeJSON(dir.appendingPathComponent("state.json"), ["state": "stopped", "queued": [rec.path]])
            let h = try Harness(dir, activity: noCall) { deps, _ in deps.modelsReady = { _ in answer } }
            await h.run { $0 > 10 }
            #expect(h.launched.isEmpty)
            answer = true
            await h.run { $0 > 14 }
            #expect(p(h.launched) == [rec.path])
        }

        @Test func aLaunchThatFailsIsRetriedLater() async throws {
            struct NoPython: Error {}
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 700 })
            var fail = true
            h.launchProcessing = { _ in if fail { throw NoPython() }; return FakeWorker(done: { true }) }
            await h.run { $0 > 720 }
            #expect(h.status()["queued"] == .strings([h.rec(0).path]))
            fail = false
            await h.run { $0 > 800 }
            #expect(h.launched.count == 2 && h.status()["queued"] == .array([]))
        }
    }
}

extension DaemonTicks {
    @Suite struct DaemonNotesTests {
        @Test func notesWaitWhileACallIsRecorded() async throws {
            // Back-to-back calls: the notes model (~10–18 GB) must not run during the next call.
            let r = try NotesRig(tempDir(), activity: teams { (10 <= $0 && $0 < 700) || (720 <= $0 && $0 < 1500) }, processingUntil: 800)
            await r.h.run { $0 > 1400 }
            #expect(p(r.h.launched) == [r.h.rec(0).path])
            #expect(r.notes.isEmpty)  // the transcript is done, the second call still records
            await r.h.run { $0 > 1560 }
            #expect(p(r.notedFolders) == [r.h.rec(0).path])
        }

        @Test func whetherNotesFollowIsDecidedAsProcessingStarts() async throws {
            // notion-auto-sync answered late: a recording processed with `run` writes its notes itself.
            let wanted = Box(false)
            let r = try NotesRig(tempDir(), activity: teams { 10 <= $0 && $0 < 700 }) { deps, _ in deps.notesWanted = { wanted.value } }
            await r.h.run { $0 > 800 }
            #expect(p(r.h.launched) == [r.h.rec(0).path] && r.notes.isEmpty)
            wanted.value = true  // too late for that one
            await r.h.run { $0 > 820 }
            #expect(r.notes.isEmpty)
        }

        @Test func notesWaitForEnoughFreeMemory() async throws {
            let r = try NotesRig(tempDir(), activity: teams { 10 <= $0 && $0 < 700 }, free: 5)
            await r.h.run { $0 > 800 }
            #expect(r.notes.isEmpty)
            #expect(r.h.status()["memory"] == .null)  // no watchdog: no memory status
            r.free = 30
            await r.h.run { $0 > 820 }
            #expect(p(r.notedFolders) == [r.h.rec(0).path])
        }

        @Test func notesWaitForTheMemoryTheirModelNeeds() async throws {
            var need = 20.0
            let r = try NotesRig(tempDir(), activity: teams { 10 <= $0 && $0 < 700 }, free: 15, notesMemory: { _ in need })
            await r.h.run { $0 > 800 }
            #expect(r.notes.isEmpty)  // a large model: 15 GB free is not enough
            need = 12
            await r.h.run { $0 > 820 }
            #expect(p(r.notedFolders) == [r.h.rec(0).path])
        }

        @Test func cloudNotesNeverWaitForMemory() async throws {
            let r = try NotesRig(tempDir(), activity: teams { 10 <= $0 && $0 < 700 }, free: 0.5, notesMemory: { _ in 0 })
            await r.h.run { $0 > 800 }
            #expect(p(r.notedFolders) == [r.h.rec(0).path])
        }

        @Test func notesWaitForTheMemoryOfTheMeetingNextInLine() async throws {
            let r = try NotesRig(tempDir(), activity: teams { 10 <= $0 && $0 < 700 }, free: 0.5,
                                 notesMemory: { $0.lastPathComponent == "rec0" ? 0 : 20 })
            await r.h.run { $0 > 800 }
            #expect(p(r.notedFolders) == [r.h.rec(0).path])
        }

        @Test func notesNotKnownYetWait() async throws {
            var answer: Double? = nil
            let r = try NotesRig(tempDir(), activity: teams { 10 <= $0 && $0 < 700 }, free: 30, notesMemory: { _ in answer })
            await r.h.run { $0 > 800 }
            #expect(r.notes.isEmpty)
            answer = 14
            await r.h.run { $0 > 804 }
            #expect(p(r.notedFolders) == [r.h.rec(0).path])
        }

        @Test func aCallStartingPausesTheNotesAndTheyResumeAfter() async throws {
            let r = try NotesRig(tempDir(), activity: teams { (10 <= $0 && $0 < 700) || (900 <= $0 && $0 < 1500) })
            await r.h.run { $0 > 800 }
            let first = r.notes[0].process
            await r.h.run { $0 > 1000 }
            #expect(first.terminated)
            #expect(r.notes.count == 1)  // not again while the second call records
            await r.h.run { $0 > 1560 }
            #expect(p(r.notedFolders) == [r.h.rec(0).path, r.h.rec(0).path])
        }

        @Test func failedProcessingLeavesNoNotesToWrite() async throws {
            let r = try NotesRig(tempDir(), activity: teams { 10 <= $0 && $0 < 700 })
            r.h.launchProcessing = { _ in FakeWorker(done: { true }, rc: 1) }
            await r.h.run { $0 > 800 }
            #expect(r.notes.isEmpty)
        }

        @Test func notesStillToWriteSurviveARestart() async throws {
            let dir = tempDir()
            let rec = dir.appendingPathComponent("rec")
            mkdir(rec); touch(rec.appendingPathComponent("transcript.md"))
            writeJSON(dir.appendingPathComponent("state.json"), ["state": "idle", "queued": [String](), "notes_queued": [rec.path]])
            let r = try NotesRig(dir, activity: noCall)
            await r.h.run { $0 > 4 }
            #expect(p(r.notedFolders) == [rec.path])
        }

        @Test func availableMemoryReadsVmStat() async {
            let out = "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:  1000.\n"
                + "Pages active:  5000.\nPages inactive:  500.\nPages speculative:  12.\nPages purgeable:  20.\n"
            #expect(FreeMemory.fromVMStat(out) == Double(1000 + 500 + 12 + 20) * 16384 / 1_073_741_824)
            #expect(FreeMemory.fromVMStat("nonsense") == nil)
            // The kernel's counters (no vm_stat process) say about what vm_stat says.
            let mine = FreeMemory.availableGB()
            #expect(mine > 0 && mine.isFinite)
        }
    }
}

extension DaemonTicks {
    @Suite struct DaemonIndexTests {
        @Test func meetingsAreIndexedAfterTheirNotesAndNeverDuringACall() async throws {
            let r = try IndexRig(tempDir(), activity: teams { (10 <= $0 && $0 < 700) || (900 <= $0 && $0 < 1500) })
            let h = r.h
            await h.run { $0 > 690 }
            #expect(r.runs.count == 1 && r.runs[0].terminated)  // it ran while idle; the call stopped it
            await h.run { $0 > 720 }
            #expect(p(r.rig.notedFolders) == [h.rec(0).path] && r.runs.count == 1)  // the notes come first
            r.rig.notes[0].process.done = { true }
            await h.run { $0 > 740 }
            #expect(r.runs.count == 2 && h.status()["indexing"] == .bool(true))
            await h.run { $0 > 920 }  // a call starts
            #expect(r.runs[1].terminated && h.status()["indexing"] == .bool(false))
            await h.run { $0 > 1490 }
            #expect(r.runs.count == 2)
            await h.run { $0 > 1600 }  // the second call's notes are written, then the index again
            #expect(r.runs.count == 2)
            r.rig.notes.last!.process.done = { true }
            await h.run { $0 > 1620 }
            #expect(r.runs.count == 3)
        }

        @Test func theIndexWaitsForFreeMemoryAndForSomethingToIndex() async throws {
            var stale = false
            let r = try IndexRig(tempDir(), activity: noCall, free: 0.5)
            r.wanted = { stale }
            r.h.daemon.indexCheckSeconds = 60
            await r.h.run { $0 > 10 }
            #expect(r.runs.isEmpty)
            r.rig.free = 8
            await r.h.run { $0 > 80 }
            #expect(r.runs.isEmpty)  // nothing stale
            stale = true
            await r.h.run { $0 > 100 }
            #expect(r.runs.isEmpty)  // asked again only after a minute
            await r.h.run { $0 > 150 }
            #expect(r.runs.count == 1)
        }

        @Test func anIndexAnswerNotKnownYetIsAskedAgainSoon() async throws {
            var answer: Bool? = nil
            let r = try IndexRig(tempDir(), activity: noCall)
            r.wanted = { answer }
            await r.h.run { $0 > 10 }
            #expect(r.runs.isEmpty)
            answer = true
            await r.h.run { $0 > 14 }
            #expect(r.runs.count == 1)
        }

        @Test func aFailingIndexIsTriedAgainMuchLater() async throws {
            let r = try IndexRig(tempDir(), activity: noCall)
            r.h.daemon.indexCheckSeconds = 60
            await r.h.run { $0 > 4 }
            r.runs[0].rc = 1
            r.runs[0].done = { true }
            await r.h.run { $0 > 600 }
            #expect(r.runs.count == 1)  // offline, say: not every minute
        }

        @Test func theStatusSaysWhenTheIndexFirstDownloadsItsModel() async throws {
            var have = false
            let r = try IndexRig(tempDir(), activity: noCall)
            r.modelReady = { have }
            r.h.daemon.indexCheckSeconds = 60
            await r.h.run { $0 > 4 }
            #expect(r.h.status()["indexing"] == .bool(true) && r.h.status()["index_downloading"] == .bool(true))
            r.runs[0].done = { true }
            have = true
            await r.h.run { $0 > 80 }
            #expect(r.runs.count == 2 && r.h.status()["indexing"] == .bool(true) && r.h.status()["index_downloading"] == .bool(false))
        }

        @Test func quittingStopsTheSearchIndexSoNoOldProcessOutlivesAnUpdate() async throws {
            let r = try IndexRig(tempDir(), activity: noCall)
            await r.h.run { $0 > 30 }
            #expect(r.runs.count == 1 && !r.runs[0].terminated)
            r.h.daemon.shutdown()
            #expect(r.runs[0].terminated && r.h.status()["indexing"] == .bool(false))
        }
    }
}

extension DaemonTicks {
    @Suite struct DaemonManualTests {
        @Test func manualRecordingAsksOnceWhenItsCallEndsAndNeverStopsItself() async throws {
            let h = try Harness(tempDir(), activity: teams { 20 <= $0 && $0 < 300 })
            h.daemon.startManual()
            await h.run { $0 > 4 * 3600 }
            #expect(!h.sessions[0].stopped && h.launched.isEmpty)
            let asks = h.notifications.filter { $0.message.contains("Stop recording?") }
            #expect(asks.count == 1)
            #expect(asks.first.map { [$0.title, $0.message, $0.open ?? ""] } == [
                "Call ended — still recording",
                "You started this recording yourself, and your Teams call just ended. Stop recording?", "rec0"])
            let q = h.status()["stop_question"]
            #expect(q?["meeting"] == .string("rec0") && q?["reason"] == .string("teams") && q?["message"] == .string(asks[0].message))
            #expect(h.state()["stop_question"]?["reason"] == .string("teams"))
        }

        @Test func answeringStopStopsTheRecording() async throws {
            let h = try Harness(tempDir(), activity: slack { 20 <= $0 && $0 < 300 })
            h.daemon.startManual()
            await h.run { $0 > 400 }
            #expect(h.status()["stop_question"]?["reason"] == .string("slack"))
            #expect(!h.daemon.answerStopQuestion("stop", meeting: "rec9"))  // not this recording
            #expect(h.daemon.answerStopQuestion("stop", meeting: "rec0"))
            #expect(h.sessions[0].stopped && p(h.launched) == [h.rec(0).path])
            #expect(h.status()["stop_question"] == .null && h.status()["state"]?.stringValue == "idle")
        }

        @Test func answeringKeepClosesTheQuestion() async throws {
            let h = try Harness(tempDir(), activity: teams { (20 <= $0 && $0 < 300) || (2000 <= $0 && $0 < 2100) })
            h.daemon.startManual()
            await h.run { $0 > 400 }
            #expect(h.daemon.answerStopQuestion("keep"))
            #expect(h.status()["stop_question"] == .null && !h.sessions[0].stopped)
            await h.run { $0 > 1900 }
            #expect(h.status()["stop_question"] == .null)
            await h.run { $0 > 2200 }  // the next call ended
            #expect(h.status()["stop_question"]?["reason"] == .string("teams"))
            #expect(!h.daemon.answerStopQuestion("maybe"))
            h.daemon.shutdown()
        }

        @Test func manualRecordingAsksAfterTenSilentMinutes() async throws {
            let h = try Harness(tempDir(), activity: noCall)
            h.daemon.deps.silence = { [unowned h] in h.clock }  // silent since the start
            h.daemon.startManual()
            await h.run { $0 > 590 }
            #expect(h.status()["stop_question"] == .null)
            await h.run { $0 > 610 }
            #expect(h.status()["stop_question"]?["reason"] == .string("silence"))
            #expect(h.sent.contains { $0 == ("Silent for 10 min — still recording", stopQuestionText("silence", minutes: 10)) })
            h.daemon.shutdown()
        }

        @Test func anAutomaticRecordingWithSoundIsNeverAskedAbout() async throws {
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 3000 })
            h.daemon.deps.silence = { 5 }  // someone talks
            await h.run { $0 > 3060 }
            #expect(h.status()["stop_question"] == .null)
            #expect(!h.notifications.contains { $0.message.contains("Stop recording?") })
        }

        @Test func aStartRightAfterAStopIsIgnoredAsADoubleClick() async throws {
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 100 })
            await h.run { $0 > 111 }  // the call's recording stopped at 110 (grace 10)
            #expect(h.status()["state"]?.stringValue == "idle" && h.sessions.count == 1)
            #expect(!h.daemon.startManual())  // 2 s after the automatic stop
            #expect(h.sessions.count == 1 && h.status()["state"]?.stringValue == "idle")
            #expect(h.logText.contains("double click"))
            await h.run { $0 > 114 }
            #expect(h.daemon.startManual())
            #expect(h.status()["state"]?.stringValue == "recording")
            h.daemon.stopManual()
            #expect(!h.daemon.startManual())  // also right after a manual stop
            #expect(h.sessions.count == 2)
        }

        @Test func theQuitMenuItemIsADeliberateStop() async throws {
            let h = try Harness(tempDir(), activity: teams { 10 <= $0 && $0 < 1000 })
            await h.run { $0 > 400 }
            h.daemon.shutdown("by_you")
            #expect(h.sessions[0].stopReason == "by_you")
            #expect(p(h.launched) == [h.rec(0).path] && h.state()["cut"] == .null)
            #expect(h.state()["state"]?.stringValue == "stopped")
        }
    }
}

extension DaemonTicks {
    @Suite struct DaemonSilentCallTests {
        @Test func aHuddleTakenOnThePhoneIsAskedAboutThenStopped() async throws {
            let r = try HeldRig(tempDir(), slack: [(10, 1e6)])
            let h = r.h
            await h.run { $0 > 640 }
            let q = h.status()["stop_question"]
            #expect(q?["reason"] == .string("silent_call") && q?["message"]?.stringValue?.contains("Slack huddle") == true)
            #expect(!h.sessions[0].stopped)
            #expect(h.notifications.contains { $0.title == "Silent for 10 min — still recording" && $0.message == q?["message"]?.stringValue && $0.open == "rec0" })
            await h.run { $0 > 1900 }
            #expect(h.sessions[0].stopped && h.sessions[0].stopReason == "silence" && p(h.launched) == [h.rec(0).path])
            #expect(h.titles.contains("Recording stopped: nothing heard"))
            #expect(h.sent.contains { $0.1 == "Your Slack huddle was silent on this Mac for 30 minutes. Palaver records Slack huddles again once the app lets go of the microphone; other calls as always." })
            await h.run { $0 > 4000 }
            #expect(h.sessions.count == 1)  // Slack still holds the mic: not a call
            #expect(h.state()["ignored"] == .strings(["slack"]))
        }

        @Test func theUserTalkingNextToTheMacIsAskedButNeverStopped() async throws {
            let r = try HeldRig(tempDir(), slack: [(10, 1e6)], talking: true)
            await r.h.run { $0 > 640 }
            #expect(r.h.status()["stop_question"]?["reason"] == .string("silent_call"))
            await r.h.run { $0 > 3600 }
            #expect(!r.h.sessions[0].stopped)
        }

        @Test func aTeamsCallAfterAPhoneHuddle() async throws {
            let r = try HeldRig(tempDir(), slack: [(10, 1e6)], teams: [(2100, 2900)], heard: [(2100, 2900)])
            await r.h.run { $0 > 1900 }
            #expect(r.h.sessions[0].stopReason == "silence")
            await r.h.run { $0 > 4000 }
            #expect(r.h.sessions.count == 2 && r.h.sessions[1].stopReason == "call_ended")
        }

        @Test func stopFromTheSilentCallQuestion() async throws {
            let r = try HeldRig(tempDir(), slack: [(10, 1e6)], teams: [(1000, 1500)], heard: [(1000, 1500)], talking: true)
            await r.h.run { $0 > 640 }
            #expect(r.h.daemon.answerStopQuestion("stop", meeting: "rec0"))
            #expect(r.h.sessions[0].stopped && r.h.sessions[0].stopReason == "by_you")
            await r.h.run { $0 > 900 }
            #expect(r.h.sessions.count == 1)  // Slack's hold: not again
            await r.h.run { $0 > 1600 }
            #expect(r.h.sessions.count == 2)  // a Teams call records as always
        }

        @Test func keepASilentCall() async throws {
            let r = try HeldRig(tempDir(), slack: [(10, 1e6)])
            #expect(!r.h.daemon.answerStopQuestion("keep"))  // nothing asked yet
            await r.h.run { $0 > 640 }
            #expect(r.h.daemon.answerStopQuestion("keep"))
            await r.h.run { $0 > 3 * 3600 }
            #expect(!r.h.sessions[0].stopped)
        }

        @Test func anIgnoredHoldSurvivesARestartUntilTheAppLetsGo() async throws {
            let dir = tempDir()
            let sessions = Sessions()
            let first = try HeldRig(dir, slack: [(10, 3000), (3100, 1e6)], sessions: sessions)
            await first.h.run { $0 > 1900 }
            #expect(sessions[0].stopReason == "silence")
            first.h.daemon.shutdown()
            let again = try HeldRig(dir, slack: [(10, 3000), (3100, 1e6)], heard: [(3100, 1e6)], sessions: sessions, start: 2000)
            #expect(again.detector.ignored == [.slack])
            await again.h.run { $0 > 2900 }
            #expect(sessions.count == 1)  // the restarted app doesn't record the same stale hold
            await again.h.run { $0 > 3200 }
            #expect(sessions.count == 2 && again.detector.ignored.isEmpty)  // let go, then a huddle again: recorded
        }
    }
}
