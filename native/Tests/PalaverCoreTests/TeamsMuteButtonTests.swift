import Foundation
import Testing
@testable import PalaverCore

/// The mic button as the test sets it.
private final class FakeButton: MuteButtonReader, @unchecked Sendable {
    var reading: MuteButtonReading = .missing
    func read() -> MuteButtonReading { reading }
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

private func ns(_ s: Double) -> Int64 { 1_000_000_000_000 + Int64((s * 1e9).rounded()) }

private struct Rig {
    let button = FakeButton()
    let c = Clock()
    let said = Said()
    let dir: URL
    let log: URL
    let timeline: MuteTimeline
    let follower: TeamsMuteFollower

    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-button-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log = dir.appendingPathComponent("MSTeamsNM_SlimCore_2026-03-04_09-00-00.log")
        FileManager.default.createFile(atPath: log.path, contents: Data("2026-03-04T08:59:00.000000+01:00 0x1 <INFO> start\n".utf8))
        let (c, said, dir) = (c, said, dir)
        timeline = MuteTimeline(app: .teams, delay: CallMute.delay(.teams), host: { c.host }, wall: { c.wall },
                                timeZone: TimeZone(secondsFromGMT: 3600)!, log: { said.add($0) })
        let timeline = timeline
        follower = TeamsMuteFollower(
            button: button, timeline: timeline,
            watcher: { sink in
                TeamsMuteWatcher(directory: dir, timeline: timeline, callStart: 1_000_000_000_000, host: { c.host },
                                 wall: { c.wall }, poll: nil, sink: sink, log: { said.add($0) })
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
        r.button.reading = .missing  // the window is rebuilt
        r.follower.check()
        #expect(r.follower.followingButton && r.timeline.delay == TeamsMuteFollower.buttonDelay)
        r.c.at(3)
        r.follower.check()  // screen sharing's compact bar: no button
        #expect(r.follower.followingLog && r.timeline.delay == TeamsMuteFollower.logDelay)
        r.logged(4, muted: false)
        r.c.at(6)
        r.follower.refresh()
        #expect(r.timeline.mutedRanges(from: ns(0), to: ns(6)) == [ns(0)..<ns(4)])
        r.c.at(7)
        r.button.reading = .label("Unmute mic")
        r.follower.check()
        #expect(r.follower.followingButton && r.timeline.muted(at: ns(7)))
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
}
