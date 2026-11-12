import Foundation
import Testing
@testable import PalaverCore

// Fictional log lines in the shape new Teams writes (MSTeamsNM_SlimCore_<date>.log): the digits are UTC,
// whatever offset follows (09:00 "+01:00" is 10:00 at +01:00).
private func teamsLine(_ time: String, _ text: String) -> String { "\(time) 0x00000001a0b0c0d0 <INFO> \(text)" }
private func muteLines(_ time: String, muted: Bool) -> String {
    teamsLine(time, "AirPodsService: Input mute event received: \(muted ? "mute" : "unmute")") + "\n"
        + teamsLine(time, "AirPodsService: AirPodsService InputMuteStateChangeNotification received with value: \(muted)") + "\n"
}

private let zone = TimeZone(secondsFromGMT: 3600)!
/// 2026-03-04T10:00:00+01:00 is host time 1000 s.
private let base = WallTime.parse("2026-03-04T10:00:00+01:00")!
private func s(_ x: Double) -> Int64 { Int64((x * 1e9).rounded()) }

/// Host and wall clock moving together.
private final class Clocks: @unchecked Sendable {
    var host = s(1000)
    func at(_ seconds: Double) { host = s(1000 + seconds) }
    var wall: Date { base.addingTimeInterval(Double(host - s(1000)) / 1e9) }
}

private final class Lines: @unchecked Sendable {
    var all: [String] = []
    let lock = NSLock()
    func add(_ l: String) { lock.withLock { all.append(l) } }
    var list: [String] { lock.withLock { all } }
}

private func timeline(_ c: Clocks, _ lines: Lines, app: CallApp = .teams) -> MuteTimeline {
    MuteTimeline(app: app, delay: 1, host: { c.host }, wall: { c.wall }, timeZone: zone, log: { lines.add($0) })
}

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-mute-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func append(_ url: URL, _ text: String) {
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    let h = try! FileHandle(forWritingTo: url)
    h.seekToEndOfFile()
    h.write(Data(text.utf8))
    try! h.close()
}

@Suite struct TeamsMuteLogTests {
    @Test func readsTheMuteLinesTeamsWrites() {
        let t = WallTime.parse("2026-03-04T10:00:05.250000+01:00")!, stated = WallTime.parse("2026-03-04T09:00:05.250000+01:00")!
        #expect(TeamsMuteLog.parse(teamsLine("2026-03-04T09:00:05.250000+01:00",
            "AirPodsService: Input mute event received: mute")) == .event(.init(time: t, stated: stated, muted: true)))
        #expect(TeamsMuteLog.parse(teamsLine("2026-03-04T09:00:05.250000+01:00",
            "AirPodsService: Input mute event received: unmute")) == .event(.init(time: t, stated: stated, muted: false)))
        #expect(TeamsMuteLog.parse(teamsLine("2026-03-04T09:00:05.250000+01:00",
            "AirPodsService: AirPodsService InputMuteStateChangeNotification received with value: true"))
                == .event(.init(time: t, stated: stated, muted: true)))
        #expect(TeamsMuteLog.parse(teamsLine("2026-03-04T09:00:05.250000+01:00",
            "AirPodsService: AirPodsService InputMuteStateChangeNotification received with value: false\r"))
                == .event(.init(time: t, stated: stated, muted: false)))
        #expect(abs(t.timeIntervalSince(base) - 5.25) < 1e-6)
    }

    @Test func theDigitsAreUTCUnlessThatLiesAhead() {
        // As Teams writes it: digits UTC, a local offset after them. Read 2 s later.
        guard case .event(let e)? = TeamsMuteLog.parse(teamsLine("2026-03-04T09:00:05.000000+01:00",
                                                                 "AirPodsService: Input mute event received: mute")) else {
            Issue.record("no event"); return
        }
        #expect(e.moment(now: base.addingTimeInterval(7)) == base.addingTimeInterval(5))
        // A Teams that writes local digits with their offset: read as UTC that would be an hour ahead.
        guard case .event(let f)? = TeamsMuteLog.parse(teamsLine("2026-03-04T10:00:05.000000+01:00",
                                                                 "AirPodsService: Input mute event received: mute")) else {
            Issue.record("no event"); return
        }
        #expect(f.moment(now: base.addingTimeInterval(7)) == base.addingTimeInterval(5))
        // West of UTC: "-05:00" after UTC digits.
        guard case .event(let g)? = TeamsMuteLog.parse(teamsLine("2026-03-04T09:00:05.000000-05:00",
                                                                 "AirPodsService: Input mute event received: mute")) else {
            Issue.record("no event"); return
        }
        #expect(g.moment(now: base.addingTimeInterval(7)) == base.addingTimeInterval(5))
    }

    @Test func otherLinesAndGarbageAreNoMuteLine() {
        for line in ["", "garbage", "\u{0}\u{1}binary", teamsLine("2026-03-04T09:00:05.250000+01:00", "CallingService: call joined"),
                     teamsLine("2026-03-04T09:00:05.250000+01:00", "AudioService: speaker muted by policy")] {
            #expect(TeamsMuteLog.parse(line) == nil)
        }
    }

    @Test func aChangedFormatIsToldApart() {
        // A mute line whose time or value Palaver does not know: Teams changed its log.
        #expect(TeamsMuteLog.parse("04/03/2026 10:00:05 AirPodsService: Input mute event received: mute") == .unreadable)
        #expect(TeamsMuteLog.parse(teamsLine("2026-03-04T09:00:05.250000+01:00",
                                             "AirPodsService: Input mute event received: muted")) == .unreadable)
        #expect(TeamsMuteLog.parse(teamsLine("2026-03-04T09:00:05+01:00",
            "InputMuteStateChangeNotification received with value: 1")) == .unreadable)
    }

    @Test func theCurrentLogIsTheNewestByName() throws {
        let dir = tempDir()
        #expect(try TeamsMuteLog.current(in: dir) == nil)
        for name in ["MSTeamsNM_SlimCore_2026-03-03_09-00-00.log", "MSTeamsNM_SlimCore_2026-03-04_08-00-00.log",
                     "MSTeamsNM_Other_2026-03-05.log", "MSTeamsNM_SlimCore_2026-03-05.txt"] {
            append(dir.appendingPathComponent(name), "x\n")
        }
        #expect(try TeamsMuteLog.current(in: dir)?.lastPathComponent == "MSTeamsNM_SlimCore_2026-03-04_08-00-00.log")
        #expect(throws: (any Error).self) { try TeamsMuteLog.current(in: dir.appendingPathComponent("missing")) }
    }
}

@Suite struct MuteTimelineTests {
    @Test func unknownIsNotMutedAndChangesCountFromTheirMoment() {
        let c = Clocks(), lines = Lines()
        let t = timeline(c, lines)
        #expect(!t.muted(at: s(1001)) && t.mutedRanges(from: s(1000), to: s(1010)).isEmpty)
        t.set(true, at: s(1002))
        t.set(true, at: s(1002.5))  // the same change told again
        t.set(false, at: s(1004))
        t.set(true, at: s(1006))
        #expect(!t.muted(at: s(1001.999)) && t.muted(at: s(1002)) && t.muted(at: s(1003.9)) && !t.muted(at: s(1004)))
        #expect(t.mutedRanges(from: s(1000), to: s(1010)) == [s(1002)..<s(1004), s(1006)..<s(1010)])
        #expect(t.mutedRanges(from: s(1003), to: s(1007)) == [s(1003)..<s(1004), s(1006)..<s(1007)])
        #expect(t.mutedRanges(from: s(1004), to: s(1006)).isEmpty)
    }

    @Test func aChangeToldLateTakesItsPlace() {
        let c = Clocks(), lines = Lines()
        let t = timeline(c, lines)
        t.set(true, at: s(1005))
        t.set(true, at: s(1003))  // the same mute, an earlier line
        #expect(t.mutedRanges(from: s(1000), to: s(1010)) == [s(1003)..<s(1010)])
        t.set(false, at: s(1008))
        t.set(false, at: s(1007))
        #expect(t.mutedRanges(from: s(1000), to: s(1010)) == [s(1003)..<s(1007)])
    }

    @Test func sessionLogGetsTheIntervalsAsTimesOnly() {
        let c = Clocks(), lines = Lines()
        let t = timeline(c, lines)
        c.at(20)
        t.set(true, at: s(1002))
        t.set(false, at: s(1065))
        t.set(true, at: s(1070))
        t.close()
        t.set(false, at: s(1080))  // after the stop: nothing
        #expect(lines.list == ["muted in Teams 10:00:02–10:01:05: microphone not kept",
                               "muted in Teams 10:01:10 to the end: microphone not kept"])
        #expect(t.muted(at: s(1090)))
    }
}

@Suite struct TeamsMuteWatcherTests {
    private func rig(_ callStart: Double = 0) -> (dir: URL, log: URL, c: Clocks, lines: Lines, t: MuteTimeline, w: TeamsMuteWatcher) {
        let dir = tempDir(), c = Clocks(), lines = Lines()
        let t = timeline(c, lines)
        let w = TeamsMuteWatcher(directory: dir, timeline: t, callStart: s(1000 + callStart), host: { c.host }, wall: { c.wall },
                                 poll: nil, log: { lines.add($0) })
        return (dir, dir.appendingPathComponent("MSTeamsNM_SlimCore_2026-03-04_09-00-00.log"), c, lines, t, w)
    }

    @Test func followsTheLogByEachLinesOwnTime() {
        let r = rig()
        append(r.log, teamsLine("2026-03-04T08:59:00.000000+01:00", "CallingService: something else") + "\n")
        r.c.at(1)
        r.w.start()
        r.c.at(6)
        append(r.log, muteLines("2026-03-04T09:00:05.250000+01:00", muted: true))
        r.w.refresh()
        #expect(r.t.mutedRanges(from: s(1000), to: s(1006)) == [s(1005.25)..<s(1006)])
        r.c.at(9)
        append(r.log, muteLines("2026-03-04T09:00:08.500000+01:00", muted: false))
        append(r.log, teamsLine("2026-03-04T09:00:08.600000+01:00", "AirPodsService: Input mute event rec"))  // half a line
        r.w.refresh()
        #expect(r.t.mutedRanges(from: s(1000), to: s(1009)) == [s(1005.25)..<s(1008.5)])
        append(r.log, "eived: mute\n")
        r.w.refresh()
        #expect(r.t.muted(at: s(1008.6)))
        #expect(r.lines.list == ["muted in Teams 10:00:05–10:00:08: microphone not kept"])
    }

    @Test func aMuteFromBeforeTheCallDoesNotSilenceIt() {
        // Muted at the end of an earlier call; this call took the mic at 10:01:00.
        let r = rig(60)
        append(r.log, muteLines("2026-03-04T08:55:00.000000+01:00", muted: true))
        append(r.log, muteLines("2026-03-04T09:00:30.000000+01:00", muted: true))
        r.c.at(65)
        r.w.start()
        #expect(!r.t.muted(at: s(1064)))
        // Joining muted, logged as the mic opened (within the slack), counts.
        append(r.log, muteLines("2026-03-04T09:00:59.000000+01:00", muted: true))
        r.w.refresh()
        #expect(r.t.muted(at: s(1064)))
        #expect(r.t.mutedRanges(from: s(1000), to: s(1065)) == [s(1059)..<s(1065)])
    }

    @Test func theCallsEarlierMuteIsFoundAtTheStart() {
        // Palaver starts recording 5 s into a call that was muted at 10:00:02.
        let r = rig(0)
        append(r.log, muteLines("2026-03-04T09:00:02.000000+01:00", muted: true))
        r.c.at(5)
        r.w.start()
        #expect(r.t.mutedRanges(from: s(1000), to: s(1005)) == [s(1002)..<s(1005)])
    }

    @Test func aNewLogAfterTeamsRestartedIsFollowed() {
        let r = rig()
        append(r.log, muteLines("2026-03-04T09:00:01.000000+01:00", muted: true))
        r.c.at(2)
        r.w.start()
        #expect(r.t.muted(at: s(1002)))
        r.c.at(10)
        let newer = r.dir.appendingPathComponent("MSTeamsNM_SlimCore_2026-03-04_10-00-09.log")
        append(newer, teamsLine("2026-03-04T09:00:09.000000+01:00", "Teams started") + "\n")
        append(newer, muteLines("2026-03-04T09:00:09.500000+01:00", muted: false))
        r.w.refresh()
        #expect(r.t.mutedRanges(from: s(1000), to: s(1010)) == [s(1001)..<s(1009.5)])
        r.c.at(11)
        append(r.log, muteLines("2026-03-04T09:00:10.500000+01:00", muted: true))  // the old file: left
        append(newer, muteLines("2026-03-04T09:00:10.750000+01:00", muted: true))
        r.w.refresh()
        #expect(!r.t.muted(at: s(1010.6)) && r.t.muted(at: s(1010.75)))
        #expect(r.lines.list.contains("Teams started a new log: following MSTeamsNM_SlimCore_2026-03-04_10-00-09.log"))
    }

    @Test func runningItReadsOnItsOwnQueue() {
        let dir = tempDir(), c = Clocks(), lines = Lines()
        let t = timeline(c, lines)
        let log = dir.appendingPathComponent("MSTeamsNM_SlimCore_2026-03-04_09-00-00.log")
        append(log, muteLines("2026-03-04T09:00:01.000000+01:00", muted: true))
        c.at(2)
        let w = TeamsMuteWatcher(directory: dir, timeline: t, callStart: s(1000), host: { c.host }, wall: { c.wall },
                                 poll: 0.01, log: { lines.add($0) })
        w.start()
        defer { w.stop() }
        let deadline = Date().addingTimeInterval(10)
        while !t.muted(at: s(1002)) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(t.mutedRanges(from: s(1000), to: s(1002)) == [s(1001)..<s(1002)])
    }

    @Test func aChangeLoggedLaterThanTheHoldIsTold() {
        let r = rig()
        append(r.log, teamsLine("2026-03-04T08:59:00.000000+01:00", "Teams started") + "\n")
        r.w.start()
        r.c.at(9)
        append(r.log, muteLines("2026-03-04T09:00:05.000000+01:00", muted: true))  // 4 s late, the hold is 1 s
        r.w.refresh()
        r.c.at(9.5)
        append(r.log, muteLines("2026-03-04T09:00:09.250000+01:00", muted: false))
        r.w.refresh()
        #expect(r.lines.list.filter { $0.hasPrefix("Teams logged") } == ["Teams logged a mute 4.0 s late"])
        #expect(r.t.mutedRanges(from: s(1000), to: s(1010)) == [s(1005)..<s(1009.25)])
    }

    @Test func aLogCutBackIsReadAgain() {
        let r = rig()
        append(r.log, String(repeating: teamsLine("2026-03-04T09:00:00.100000+01:00", "filler") + "\n", count: 20))
        r.c.at(1)
        r.w.start()
        try! Data(muteLines("2026-03-04T09:00:01.500000+01:00", muted: true).utf8).write(to: r.log)
        r.c.at(2)
        r.w.refresh()
        #expect(r.t.muted(at: s(1001.5)))
    }

    @Test func anUnreadableLogIsToldOnceAndNothingIsMuted() {
        let r = rig()
        try? FileManager.default.removeItem(at: r.dir)
        r.w.start()
        r.c.at(3)
        r.w.refresh()
        r.c.at(6)
        r.w.refresh()
        #expect(r.lines.list.count == 1)
        #expect(r.lines.list[0].hasPrefix("⚠ can't read Teams' log") && r.lines.list[0].hasSuffix("recorded while muted in Teams"))
        #expect(!r.t.muted(at: s(1006)))
    }

    @Test func aChangedFormatIsToldOnce() {
        let r = rig()
        append(r.log, teamsLine("2026-03-04T08:59:00.000000+01:00", "Teams started") + "\n")
        r.w.start()
        r.c.at(3)
        append(r.log, "04/03/2026 10:00:02 AirPodsService: Input mute event received: mute\n")
        append(r.log, "04/03/2026 10:00:02 AirPodsService: Input mute event received: unmute\n")
        r.w.refresh()
        #expect(r.lines.list.count == 1 && r.lines.list[0].hasPrefix("⚠ Teams' log has a mute line Palaver can't read"))
        #expect(!r.t.muted(at: s(1003)))
    }
}

/// Tells the watcher of a change when the test says so (Core Audio's listener in the app).
private final class FakeEvents: AudioProcessEvents, @unchecked Sendable {
    var changed: (@Sendable () -> Void)?
    var stopped = false
    func start(_ changed: @escaping @Sendable () -> Void) throws { self.changed = changed }
    func stop() { stopped = true }
}

@Suite struct SlackMuteWatcherTests {
    @Test func slackLettingGoOfTheMicIsMutedFromThatMoment() {
        let c = Clocks(), lines = Lines(), l = FakeLister(), events = FakeEvents()
        let t = timeline(c, lines, app: .slack)
        let w = SlackMuteWatcher(lister: l, events: events, timeline: t, host: { c.host }, poll: nil, log: { lines.add($0) })
        // The detector's huddle: Slack's helper holds mic and speaker.
        l.list = [proc(slackId, true, out: true), proc("com.tinyspeck.slackmacgap", false)]
        let d = CallDetector(lister: l)
        #expect(d() == .slack)
        w.start()
        #expect(!t.mutedNow)
        c.at(4.125)
        l.list = [proc(slackId, false, out: true), proc("com.tinyspeck.slackmacgap", false)]  // muted: the others still play
        #expect(d.detect(recording: .slack) == .slack)
        events.changed!()
        c.at(7.5)
        l.list = [proc(slackId, true, out: true)]
        events.changed!()
        c.at(9)
        w.refresh()
        #expect(t.mutedRanges(from: s(1000), to: s(1009)) == [s(1004.125)..<s(1007.5)])
        // Another app's mic is not Slack's.
        l.list = [proc(slackId, false, out: true), proc(teamsId, true)]
        c.at(10)
        events.changed!()
        #expect(t.muted(at: s(1010)))
        w.stop()
        #expect(events.stopped)
    }

    @Test func aListThatCannotBeReadIsNotMuted() {
        let c = Clocks(), lines = Lines(), l = FakeLister()
        let t = timeline(c, lines, app: .slack)
        let w = SlackMuteWatcher(lister: l, events: nil, timeline: t, host: { c.host }, poll: nil, log: { lines.add($0) })
        l.list = [proc(slackId, false, out: true)]
        w.start()
        #expect(t.mutedNow)
        c.at(2)
        l.fail = true
        w.check()
        c.at(3)
        w.check()
        #expect(!t.mutedNow && t.mutedRanges(from: s(1000), to: s(1003)) == [s(1000)..<s(1002)])
        #expect(lines.list.filter { $0.hasPrefix("⚠ can't read whether Slack holds the mic") }.count == 1)
    }

    @Test func theDetectorSaysSinceWhenTheCallsAppHeldTheMic() {
        let l = FakeLister(), now = Cell(500.0)
        let d = CallDetector(lister: l, clock: { now.value })
        #expect(d.callSince(.teams) == nil)
        l.list = [proc(teamsId, true, out: true)]
        _ = d()
        now.value = 530
        _ = d()
        #expect(d.callSince(.teams) == s(500))
    }
}
