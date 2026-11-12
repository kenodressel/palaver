import Foundation
import Testing
@testable import PalaverCore

/// The mic button as the test sets it.
private final class FakeButton: MuteButtonReader, @unchecked Sendable {
    var reading: MuteButtonReading = .missing
    /// Teams shown: not hidden, a window not minimized.
    var shown = true
    func read() -> MuteButtonReading { reading }
    func windowShown() -> Bool { shown }
}

private final class Clock: @unchecked Sendable {
    var host: Int64 = 1_000_000_000_000
    func at(_ s: Double) { host = 1_000_000_000_000 + Int64((s * 1e9).rounded()) }
    /// 2026-03-04T10:00:00+01:00 at host 1000 s.
    var wall: Date { Date(timeIntervalSince1970: 1_772_614_800).addingTimeInterval(Double(host - 1_000_000_000_000) / 1e9) }
}

private final class Said: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.withLock { lines.append(s) } }
    var all: [String] { lock.withLock { lines } }
}

/// Each access to Teams' log folder.
private final class Accesses: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

extension TeamsLogFiles {
    /// The real files, each access counted.
    fileprivate static func counted(_ accesses: Accesses) -> TeamsLogFiles {
        let real = TeamsLogFiles.system
        return TeamsLogFiles(list: { accesses.add(); return try real.list($0) },
                             modified: { accesses.add(); return real.modified($0) },
                             size: { accesses.add(); return real.size($0) },
                             open: { accesses.add(); return real.open($0) })
    }
}

private func ns(_ s: Double) -> Int64 { 1_000_000_000_000 + Int64((s * 1e9).rounded()) }

private struct Rig {
    let button = FakeButton()
    let c = Clock()
    let said = Said()
    let accesses = Accesses()
    let call = TeamsCallState()
    let dir: URL
    let log: URL
    let timeline: MuteTimeline
    let follower: TeamsMuteFollower

    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-button-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log = dir.appendingPathComponent("MSTeamsNM_SlimCore_2026-03-04_09-00-00.log")
        FileManager.default.createFile(atPath: log.path, contents: Data("2026-03-04T08:59:00.000000+01:00 0x1 <INFO> start\n".utf8))
        let (c, said, dir, accesses) = (c, said, dir, accesses)
        timeline = MuteTimeline(app: .teams, delay: CallMute.delay(.teams), host: { c.host }, wall: { c.wall },
                                timeZone: TimeZone(secondsFromGMT: 3600)!, log: { said.add($0) })
        let timeline = timeline
        follower = TeamsMuteFollower(
            button: button, timeline: timeline, state: call,
            watcher: { sink in
                TeamsMuteWatcher(directory: dir, timeline: timeline, callStart: 1_000_000_000_000, host: { c.host },
                                 wall: { c.wall }, poll: nil, sink: sink, files: .counted(accesses),
                                 log: { said.add($0) })
            },
            host: { c.host }, poll: nil, log: { said.add($0) })
    }

    /// A line of Teams' log at `seconds` after 10:00:00 local (its digits UTC).
    func logged(_ seconds: Double, muted: Bool) {
        let stamp = String(format: "2026-03-04T09:00:%09.6f+01:00", seconds)
        let h = try! FileHandle(forWritingTo: log)
        h.seekToEndOfFile()
        h.write(Data("\(stamp) 0x1 <INFO> AirPodsService: Input mute event received: \(muted ? "mute" : "unmute")\n".utf8))
        try! h.close()
    }
}

@Suite struct TeamsMuteButtonTests {
    @Test func onlyTheLabelsTeamsShowsInEnglishCount() {
        #expect(MuteButtonLabels.muted("Unmute mic") == true)
        #expect(MuteButtonLabels.muted("Mute mic") == false)
        #expect(MuteButtonLabels.muted(" unmute  MIC ") == true)
        for other in ["Mic muted", "Microphone", "Stummschalten", "Mute", "Unmute microphone", ""] {
            #expect(MuteButtonLabels.muted(other) == nil)
        }
    }

    @Test func theButtonIsTheStateAMuteFromTheLookBefore() {
        let r = Rig()
        r.button.reading = .label("Mute mic")
        r.follower.start()
        #expect(r.timeline.delay == TeamsMuteFollower.buttonDelay && r.follower.followingButton)
        r.c.at(3)
        r.follower.check()
        r.c.at(3.25)
        r.button.reading = .label("Unmute mic")
        r.follower.check()  // muted somewhere after the look at 3 s: from then
        r.c.at(5.5)
        r.button.reading = .label("Mute mic")
        r.follower.check()  // unmuted somewhere before this look: from now
        // The log tells the same, late and in its own words: it changes nothing.
        r.logged(3.1, muted: true)
        r.logged(5.4, muted: false)
        r.c.at(9)
        r.follower.refresh()
        #expect(r.timeline.mutedRanges(from: ns(0), to: ns(9)) == [ns(3)..<ns(5.5)])
        #expect(r.said.all.contains("following Teams' mic button"))
        // While the button works, Teams' log is never touched (macOS would ask the user about it).
        #expect(r.accesses.count == 0 && !r.follower.readingLog && !r.follower.tellsLate)
        r.follower.stop()
        #expect(r.accesses.count == 0)
    }

    @Test func whileTheButtonIsLookedForTheHoldIsShortAndTheLogUnread() {
        let r = Rig()
        r.follower.start()  // no call window yet
        #expect(r.timeline.delay == TeamsMuteFollower.buttonDelay && !r.follower.followingButton)
        for t in stride(from: 0.25, through: 4.75, by: 0.25) {
            r.c.at(t)
            r.follower.check()
            r.follower.refresh()
        }
        #expect(r.accesses.count == 0 && !r.follower.readingLog && !r.follower.followingLog)
        #expect(r.timeline.delay == TeamsMuteFollower.buttonDelay && !r.timeline.muted(at: ns(4.75)))  // unknown: recorded
        r.c.at(4.9)
        r.button.reading = .label("Unmute mic")  // found in time
        r.follower.check()
        #expect(r.follower.followingButton && r.timeline.muted(at: ns(4.9)))
        r.c.at(30)
        r.follower.check()
        #expect(r.accesses.count == 0)
    }

    @Test func noButtonWithinTheFirstSecondsIsTheLog() {
        let r = Rig()
        r.follower.start()
        r.logged(2, muted: true)  // muted before the button would have been found: the log has it
        r.c.at(4.9)
        r.follower.check()
        #expect(r.accesses.count == 0 && r.timeline.delay == TeamsMuteFollower.buttonDelay)
        r.c.at(5)
        r.follower.check()
        #expect(r.follower.followingLog && r.follower.tellsLate && r.timeline.delay == TeamsMuteFollower.logDelay)
        #expect(r.accesses.count > 0)
        #expect(r.said.all.contains("Teams' mic button isn't found; following Teams' log"))
        #expect(r.timeline.mutedRanges(from: ns(0), to: ns(6)) == [ns(2)..<ns(6)])  // the capture silences it late
        #expect(!r.follower.unfollowed)
    }

    @Test func withoutTheButtonTheLogIsFollowedWithALongHold() {
        let r = Rig()
        r.button.reading = .notTrusted
        r.follower.start()
        r.c.at(1)
        r.follower.check()
        #expect(r.timeline.delay == TeamsMuteFollower.logDelay && r.follower.followingLog)
        #expect(r.said.all.filter { $0.contains("may not use Accessibility") }.count == 1)
        r.logged(2, muted: true)
        r.c.at(20)  // the log comes 18 s late
        r.follower.refresh()
        #expect(r.timeline.mutedRanges(from: ns(0), to: ns(20)) == [ns(2)..<ns(20)])
    }

    @Test func theButtonGoneForAMomentIsNoChangeButGoneLongerIsTheLog() {
        let r = Rig()
        r.button.reading = .label("Unmute mic")
        r.follower.start()
        r.c.at(1)
        r.button.reading = .missing  // the window is rebuilt; then screen sharing's compact bar: no button
        r.follower.check()
        r.c.at(9.9)
        r.follower.check()
        #expect(r.follower.followingButton && r.timeline.delay == TeamsMuteFollower.buttonDelay && r.accesses.count == 0)
        r.logged(4, muted: false)
        r.c.at(10)
        r.follower.check()
        #expect(r.follower.followingLog && r.timeline.delay == TeamsMuteFollower.logDelay)
        #expect(r.said.all.contains("Teams' mic button can't be read; following Teams' log"))
        r.c.at(11)
        r.follower.refresh()
        #expect(r.timeline.mutedRanges(from: ns(0), to: ns(11)) == [ns(0)..<ns(4)])
        r.c.at(12)
        r.button.reading = .label("Unmute mic")
        r.follower.check()
        #expect(r.follower.followingButton && !r.follower.tellsLate && r.timeline.delay == TeamsMuteFollower.buttonDelay)
        #expect(r.timeline.muted(at: ns(12)))
    }

    @Test func whatTheLogToldWhileTheButtonWasReadCountsOnceItIsLost() {
        let r = Rig()
        r.button.reading = .notTrusted
        r.follower.start()  // the log is started
        #expect(r.follower.followingLog)
        r.c.at(1)
        r.button.reading = .label("Mute mic")  // allowed meanwhile
        r.follower.check()
        #expect(r.follower.followingButton && r.follower.readingLog && !r.follower.tellsLate)
        r.logged(0.5, muted: true)  // before the button's reading: the button's to say
        r.c.at(1.5)
        r.button.reading = .missing
        r.follower.check()
        r.logged(2, muted: true)  // after it, while the button is gone
        r.c.at(3)
        r.follower.refresh()
        #expect(!r.timeline.muted(at: ns(3)))  // the button is still the source
        r.c.at(11)
        r.follower.check()
        #expect(r.follower.followingLog)
        #expect(r.timeline.mutedRanges(from: ns(0), to: ns(12)) == [ns(2)..<ns(12)])
    }

    @Test func neitherButtonNorLogIsSaid() throws {
        let r = Rig()
        try FileManager.default.removeItem(at: r.dir)
        r.button.reading = .notTrusted
        r.follower.start()
        #expect(r.follower.unfollowed)
        #expect(r.said.all.contains { $0.contains("can't read Teams' log") })
        r.button.reading = .label("Mute mic")
        r.c.at(1)
        r.follower.check()
        #expect(!r.follower.unfollowed)
    }

    @Test func anUnknownLabelLeavesTheButtonUnreadAndTheLogFollowed() {
        let r = Rig()
        r.button.reading = .label("Activer le micro")
        r.follower.start()
        r.c.at(2)
        r.follower.check()
        #expect(r.follower.followingLog && r.timeline.delay == TeamsMuteFollower.logDelay)
        #expect(r.said.all.filter { $0.contains("“Activer le micro”, which Palaver doesn't know") }.count == 1)
        r.logged(1.5, muted: true)
        r.c.at(8)
        r.follower.refresh()
        #expect(r.timeline.mutedRanges(from: ns(0), to: ns(8)) == [ns(1.5)..<ns(8)])
    }

    // MARK: - hung up: the call window closed

    /// Read at 0 to 3 s, gone from 3.25 s.
    private func hangUp(_ r: Rig) {
        r.button.reading = .label("Mute mic")
        r.follower.start()
        r.c.at(3)
        r.follower.check()
        r.button.reading = .missing
    }

    @Test func theButtonGoneASecondWithTeamsShownIsTheCallWindowClosed() {
        let r = Rig()
        hangUp(r)
        r.c.at(3.75)
        r.follower.check()
        #expect(!r.call.left)  // a moment: the window rebuilt
        r.c.at(4)
        r.follower.check()
        #expect(r.call.left)
        #expect(r.said.all.contains("Teams' call window is gone: hung up, once Teams lets go of the call's audio"))
        r.c.at(12.9)
        r.follower.check()
        #expect(r.call.left && r.accesses.count == 0)  // an ended call never reads the log
        r.c.at(13.25)
        r.follower.check()
        #expect(!r.call.left)  // gone this long: screen sharing's compact bar, not a hang-up
    }

    @Test func theButtonBackIsTheCallGoingOn() {
        let r = Rig()
        hangUp(r)
        r.c.at(4.5)
        r.follower.check()
        #expect(r.call.left)
        r.c.at(4.75)
        r.button.reading = .label("Mute mic")
        r.follower.check()
        #expect(!r.call.left)
    }

    @Test func teamsHiddenOrMinimizedTellsNothing() {
        let r = Rig()
        hangUp(r)
        r.button.shown = false
        for t in stride(from: 3.25, through: 8, by: 0.25) {
            r.c.at(t)
            r.follower.check()
        }
        #expect(!r.call.left)
    }

    @Test func aButtonNeverReadTellsNoHangUp() {
        let r = Rig()
        r.follower.start()
        for t in stride(from: 0.25, through: 4.75, by: 0.25) {
            r.c.at(t)
            r.follower.check()
        }
        #expect(!r.call.left)
        let blind = Rig()
        blind.button.reading = .notTrusted
        blind.follower.start()
        blind.c.at(3)
        blind.follower.check()
        #expect(!blind.call.left)
    }

    @Test func theStopForgetsIt() {
        let r = Rig()
        hangUp(r)
        r.c.at(5)
        r.follower.check()
        #expect(r.call.left)
        r.follower.stop()
        #expect(!r.call.left)
    }
}
