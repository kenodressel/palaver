// tests/test_session.py and test_recorder.py: one recording's folder, meta.json and session.log;
// the real capture wired with fake sources (no device is opened); the live levels.
import Foundation
import Testing
import PalaverCapture
import PalaverCore
import PalaverDomain
@testable import PalaverDaemon

final class FakeCapture: SessionCapture {
    var started = false, stopped = false
    var failStart = false, failStop = false
    var missing: [String] = []
    var systemSource: String? = "process-tap"
    var micSource: String? = "avcapture"
    var micDevice: String? = "AirPods"
    var micRate: Double? = 24000
    var systemDevice: String?
    var systemRate: Double?
    var problems: [RecordingProblem] = []
    var hints: [(kind: String, track: String)] = []
    var onStop: () -> Void = {}
    struct Boom: Error, CustomStringConvertible { var description: String { "the tap is gone" } }

    func start() throws { if failStart { throw Boom() }; started = true }
    func stop() throws { if failStop { throw Boom() }; stopped = true; onStop() }
}

/// A finished 16 kHz mono PCM16 WAV of `seconds`.
func writeWav(_ url: URL, seconds: Double) {
    let bytes = Int(seconds * 16000) * 2
    var d = Data(TrackWriter.wavHeader(dataBytes: bytes))
    d.append(Data(count: bytes))
    try? d.write(to: url)
}

final class NullSource: CaptureSource {
    var problem: String? { nil }
    var deviceName: String? { "Test Device" }
    func start() throws {}
    func stop() {}
}

final class NoScreenCapture: ScreenCaptureFallback {
    func start(captureMic: Bool, captureSystem: Bool) throws { throw CaptureError("no screen capture in tests") }
    func stop() {}
}

/// The keys of a JSON file's top object, in the file's order (json.dumps(indent=2)).
func topKeys(_ url: URL) -> [String] {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
        guard line.hasPrefix("  \""), !line.hasPrefix("   ") else { return nil }
        return String(line.dropFirst(3).prefix { $0 != "\"" })
    }
}

func rows(_ url: URL) -> [[String: Any]] {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n")
        .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
}

@Suite struct SessionTests {
    func session(_ out: URL, capture: FakeCapture, clock: @escaping () -> Double, usage: UsageLog? = nil) -> RecordingSession {
        RecordingSession(outputDir: out, trigger: "teams", capture: { _, _ in capture },
                         wall: { WALL0.addingTimeInterval(clock()) }, timeZone: TZ,
                         stamp: [("version", "0.4.0"), ("pid", 4242)], usage: usage)
    }

    @Test func aRecordingWritesMetaAndSessionLog() async throws {
        let out = tempDir().appendingPathComponent("Recordings")
        var now = 0.0
        let capture = FakeCapture()
        let usage = UsageLog(url: out.deletingLastPathComponent().appendingPathComponent("usage.jsonl"))
        let s = session(out, capture: capture, clock: { now }, usage: usage)
        let folder = try s.start()
        #expect(folder.lastPathComponent == "2026-10-29T12-06-00")
        #expect(capture.started && s.recording)
        writeWav(folder.appendingPathComponent("mic_raw.wav"), seconds: 2.5)
        writeWav(folder.appendingPathComponent("system.wav"), seconds: 2.45)
        touch(folder.appendingPathComponent("audio_problems.json"), "[]")
        capture.problems = [RecordingProblem(id: 1, kind: "speed", track: "system", start: 20, end: 60, at: "2026-10-29T12:06:20+01:00")]
        now = 180.5
        let seconds = try s.stop(reason: "call_ended")
        #expect(seconds == 180.5 && capture.stopped && !s.recording)
        let meta = try #require(JSONValue.parse(try Data(contentsOf: folder.appendingPathComponent("meta.json"))))
        #expect(meta == .object([
            ("start_time", .string("2026-10-29T12:06:00+01:00")), ("end_time", .string("2026-10-29T12:09:00.500000+01:00")),
            ("duration_seconds", .double(180.5)), ("trigger", .string("teams")), ("stop_reason", .string("call_ended")),
            ("audio_problems", .array([.object([("kind", .string("speed")), ("track", .string("system")), ("start", .double(20)),
                                                ("end", .double(60)), ("at", .string("2026-10-29T12:06:20+01:00"))])])),
        ]))
        #expect(topKeys(folder.appendingPathComponent("meta.json"))
                == ["start_time", "end_time", "duration_seconds", "trigger", "stop_reason", "audio_problems"])
        #expect(!exists(folder.appendingPathComponent("audio_problems.json")))  // folded in
        let log = rows(folder.appendingPathComponent("session.log"))
        #expect(log.map { $0["event"] as? String } == ["record_start", "record_stop"])
        #expect(log[0]["logger"] as? String == "palaver")
        #expect(log[0]["system_source"] as? String == "process-tap" && log[0]["mic_source"] as? String == "avcapture")
        #expect(log[0]["trigger"] as? String == "teams" && (log[0]["missing"] as? [Any])?.isEmpty == true)
        #expect(log[0]["version"] as? String == "0.4.0" && log[0]["pid"] as? Int == 4242)
        #expect(log[1]["reason"] as? String == "call_ended")
        #expect(log[1]["mic_seconds"] as? Double == 2.5 && log[1]["system_seconds"] as? Double == 2.5)
        let used = rows(usage.url)
        #expect(used.map { $0["kind"] as? String } == ["recording_start", "recording_stop"])
        #expect(used[1]["seconds"] as? Double == 180.5 && used[1]["problems"] as? Int == 1)
    }

    @Test func noReasonNoProblemsAndATrackThatCannotBeRead() async throws {
        let out = tempDir()
        let capture = FakeCapture()
        let s = session(out, capture: capture, clock: { 0 })
        let folder = try s.start()
        _ = try s.stop(reason: nil)
        #expect(topKeys(folder.appendingPathComponent("meta.json")) == ["start_time", "end_time", "duration_seconds", "trigger"])
        let stop = rows(folder.appendingPathComponent("session.log"))[1]
        #expect(stop["reason"] is NSNull && stop["mic_seconds"] == nil)
    }

    @Test func aStartThatFailsThrowsAndAStopThatFailsWritesNoMeta() async throws {
        let out = tempDir()
        let failing = FakeCapture()
        failing.failStart = true
        #expect(throws: FakeCapture.Boom.self) { try session(out, capture: failing, clock: { 0 }).start() }
        let capture = FakeCapture()
        capture.failStop = true
        let s = session(out, capture: capture, clock: { 1 })
        let folder = try s.start()
        #expect(folder.lastPathComponent == "2026-10-29T12-06-01")
        #expect(throws: FakeCapture.Boom.self) { try s.stop(reason: "by_you") }
        #expect(!exists(folder.appendingPathComponent("meta.json")))  // `process` rebuilds it from the audio
    }

    @Test func folderNamesNeverCollide() async throws {
        let out = tempDir()
        let at = WALL0
        let a = try RecordingFolders.new(in: out, at: at, timeZone: TZ)
        let b = try RecordingFolders.new(in: out, at: at, timeZone: TZ)
        let c = try RecordingFolders.new(in: out, at: at, timeZone: TZ)
        #expect([a, b, c].map(\.lastPathComponent) == ["2026-10-29T12-06-00", "2026-10-29T12-06-00-2", "2026-10-29T12-06-00-3"])
        #expect([a, b, c].allSatisfy { RecordingFolders.isRecordingName($0.lastPathComponent) })
        #expect(!RecordingFolders.isRecordingName("Notes") && !RecordingFolders.isRecordingName("2026-10-29T12-06-00-x"))
    }

    @Test func theRealCaptureWritesItsTracksAndItsWarningsIntoSessionLog() async throws {
        let out = tempDir()
        let sources = CaptureSources(systemTap: { _ in NullSource() }, mic: { _ in NullSource() },
                                     screenCapture: { _, _ in NoScreenCapture() })
        let s = RecordingSession(outputDir: out, trigger: "manual",
                                 capture: { folder, log in LiveCapture(folder: folder, log: log, sources: sources) })
        let folder = try s.start()
        #expect(exists(folder.appendingPathComponent("mic_raw.wav.part")) && exists(folder.appendingPathComponent("system.wav.part")))
        #expect(s.systemSource == "process-tap" && s.micSource == "avcapture" && s.micDevice == "Test Device")
        _ = try s.stop(reason: "by_you")
        #expect(exists(folder.appendingPathComponent("mic_raw.wav")) && exists(folder.appendingPathComponent("system.wav")))
        #expect(!exists(folder.appendingPathComponent("mic_raw.wav.part")))
        let log = rows(folder.appendingPathComponent("session.log"))
        #expect(log.first?["event"] as? String == "record_start" && log.first?["mic_source"] as? String == "avcapture")
        #expect(log.last?["event"] as? String == "record_stop" && log.last?["mic_seconds"] as? Double == 0.0)
        let meta = try #require(JSONValue.parse(try Data(contentsOf: folder.appendingPathComponent("meta.json"))))
        #expect(meta["trigger"] == .string("manual") && meta["stop_reason"] == .string("by_you"))
    }

    @Test func aCallsMuteSourceRunsWithTheCaptureAndItsIntervalsGoToSessionLog() async throws {
        let out = tempDir()
        let sources = CaptureSources(systemTap: { _ in NullSource() }, mic: { _ in NullSource() },
                                     screenCapture: { _, _ in NoScreenCapture() })
        let source = FakeMuteSource()
        var timeline: MuteTimeline?
        let s = RecordingSession(outputDir: out, trigger: "teams", capture: { folder, log in
            LiveCapture(folder: folder, log: log, sources: sources, mute: { log in
                timeline = MuteTimeline(app: .teams, delay: 0.01, log: log)
                return (timeline!, source)
            })
        })
        let folder = try s.start()
        #expect(source.calls == ["start"] && s.mutedIn == nil)
        timeline!.set(true, at: hostNanos() - 2_000_000_000)
        #expect(s.mutedIn == "teams" && s.muteUnfollowed == nil)
        source.unfollowed = true  // no Accessibility, no readable log
        #expect(s.muteUnfollowed == "teams")
        _ = try s.stop(reason: "call_ended")
        #expect(source.calls == ["start", "refresh", "stop"] && s.mutedIn == nil)
        let log = rows(folder.appendingPathComponent("session.log"))
        let muted = log.filter { ($0["message"] as? String)?.hasPrefix("muted in Teams ") == true }
        #expect(muted.count == 1 && muted[0]["logger"] as? String == "palaver.call_mute")
        #expect((muted[0]["message"] as? String)?.hasSuffix(" to the end: microphone not kept") == true)
    }

    @Test func aHuddleFollowedOnlyForItsEndKeepsTheMic() async throws {
        // respect_call_mute off: a Slack huddle's follower still runs (its end), the mic is not gated.
        let out = tempDir()
        let sources = CaptureSources(systemTap: { _ in NullSource() }, mic: { _ in NullSource() },
                                     screenCapture: { _, _ in NoScreenCapture() })
        let source = FakeMuteSource()
        var timeline: MuteTimeline?
        let s = RecordingSession(outputDir: out, trigger: "slack", capture: { folder, log in
            LiveCapture(folder: folder, log: log, sources: sources, mute: { log in
                timeline = MuteTimeline(app: .slack, delay: 1, log: log)
                return (timeline!, source)
            }, gatesMic: false)
        })
        let folder = try s.start()
        timeline!.set(true, at: hostNanos() - 3_000_000_000)
        timeline!.set(false, at: hostNanos() - 1_000_000_000)
        #expect(s.mutedIn == nil && source.calls == ["start"])
        source.unfollowed = true
        #expect(s.muteUnfollowed == nil)  // the mic is kept anyway
        _ = try s.stop(reason: "call_ended")
        #expect(source.calls == ["start", "refresh", "stop"])
        let log = rows(folder.appendingPathComponent("session.log"))
        #expect(!log.contains { ($0["message"] as? String)?.hasPrefix("muted in") == true })
        #expect(MicMuted.read(folder) == nil)
    }

    @Test func aSourceThatTellsLateIsFollowedAfterTheStopAndProcessingWaits() async throws {
        let out = tempDir()
        let sources = CaptureSources(systemTap: { _ in NullSource() }, mic: { _ in NullSource() },
                                     screenCapture: { _, _ in NoScreenCapture() })
        let source = FakeMuteSource()
        source.tellsLate = true
        var capture: LiveCapture?
        let s = RecordingSession(outputDir: out, trigger: "teams", capture: { folder, log in
            let c = LiveCapture(folder: folder, log: log, sources: sources, mute: { log in
                (MuteTimeline(app: .teams, delay: 30, log: log), source)
            })
            c.afterStopPoll = 0.02
            c.afterStopWait = 0.3
            capture = c
            return c
        })
        let folder = try s.start()
        _ = try s.stop(reason: "call_ended")
        #expect(capture != nil)
        #expect(MicMuted.read(folder)?.pending == true)  // processing waits for what Teams' log still tells
        let settled = MicMuted.settled(folder)
        #expect(settled == MicMuted.State(pending: false, late: []))
        for _ in 0..<200 where source.calls.last != "stop" { Thread.sleep(forTimeInterval: 0.01) }
        #expect(source.calls.filter { $0 == "refresh" }.count >= 3 && source.calls.last == "stop")
    }

    @Test func theLevelsOfTheRunningRecordingFeedTheSilence() async throws {
        let folder = tempDir()
        let mic = folder.appendingPathComponent("mic_raw.wav.part"), system = folder.appendingPathComponent("system.wav.part")
        try Data(TrackWriter.wavHeader(dataBytes: 0)).write(to: mic)
        try Data(TrackWriter.wavHeader(dataBytes: 0)).write(to: system)
        var now = 0.0
        let levels = RecordingLevels(makeTracker: { f in
            LevelTracker(tracks: [("mic", f.appendingPathComponent("mic_raw.wav.part")), ("system", f.appendingPathComponent("system.wav.part"))],
                         clock: { now })
        })
        #expect(levels.quietFor == nil)
        levels.update(recording: folder.path)
        func append(_ url: URL, loud: Bool) throws {
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            let samples = (0..<1600).map { i in Int16(loud ? (i % 2 == 0 ? 12000 : -12000) : 0) }
            try h.write(contentsOf: samples.withUnsafeBytes { Data($0) })
            try h.close()
        }
        now = 30
        try append(mic, loud: true)
        try append(system, loud: false)
        levels.update(recording: folder.path)
        #expect(levels.quietFor == 0)  // the user talks
        #expect(levels.othersQuietFor == 30)  // nothing of the others since the start
        #expect(levels.readings.map(\.label) == ["mic", "system"])
        levels.update(recording: nil)
        #expect(levels.quietFor == nil && levels.othersQuietFor == nil && levels.readings.isEmpty)
    }

    @Test func theDaemonReadsTheLevelsAfterEachTick() async throws {
        let h = try Harness(tempDir(), activity: teams { $0 >= 10 })
        var seen: [String?] = []
        let levels = RecordingLevels(makeTracker: { f in seen.append(f.path); return LevelTracker(tracks: [], clock: { 0 }) })
        h.daemon.levels = levels
        await h.run { $0 > 30 }
        #expect(seen == [h.rec(0).path])  // one tracker for the recording
        #expect(levels.quietFor == 0)
        h.daemon.shutdown()
    }
}

final class FakeMuteSource: CallMuteSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    var tellsLate = false
    var unfollowed = false
    var onRefresh: () -> Void = {}
    func start() { lock.withLock { _calls.append("start") } }
    func refresh() { lock.withLock { _calls.append("refresh") }; onRefresh() }
    func stop() { lock.withLock { _calls.append("stop") } }
}
