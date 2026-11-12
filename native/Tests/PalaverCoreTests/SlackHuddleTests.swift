import Foundation
import Testing
@testable import PalaverCore

/// Slack's windows as the test sets them.
private final class FakeHuddleUI: HuddleUIReader, @unchecked Sendable {
    var reading: HuddleReading = .ui(HuddleUI(inHuddle: true, micLabel: "Mute microphone"))
    func read() -> HuddleReading { reading }
    func set(inHuddle: Bool, mic: String? = nil, windows: Int = 1, hidden: Bool = false) {
        reading = .ui(HuddleUI(inHuddle: inHuddle, micLabel: mic, windows: windows, hidden: hidden))
    }
}

private final class HostClock: @unchecked Sendable {
    var now: Int64 = 1_000_000_000_000
    func at(_ s: Double) { now = 1_000_000_000_000 + Int64((s * 1e9).rounded()) }
}

private func t(_ s: Double) -> Int64 { 1_000_000_000_000 + Int64((s * 1e9).rounded()) }

private final class Said: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.withLock { lines.append(s) } }
    var all: [String] { lock.withLock { lines } }
}

private struct Rig {
    let ui = FakeHuddleUI()
    let lister = FakeLister()
    let c = HostClock()
    let said = Said()
    let state = SlackHuddleState()
    let timeline: MuteTimeline
    let follower: SlackHuddleFollower

    init() {
        let (c, said, lister) = (c, said, lister)
        lister.list = [proc(slackId, true, out: true)]
        timeline = MuteTimeline(app: .slack, delay: 1, host: { c.now }, log: { said.add($0) })
        let timeline = timeline
        follower = SlackHuddleFollower(
            reader: ui, timeline: timeline, state: state,
            audio: { sink in
                SlackMuteWatcher(lister: lister, events: nil, timeline: timeline, host: { c.now }, poll: nil, sink: sink,
                                 log: { said.add($0) })
            },
            host: { c.now }, poll: nil, log: { said.add($0) })
    }

    /// Slack's mic: held or let go.
    func mic(_ held: Bool) { lister.list = [proc(slackId, held, out: true)] }

    func look(_ s: Double) {
        c.at(s)
        follower.refresh()
    }
}

@Suite struct SlackHuddleTests {
    @Test func theMicButtonIsTheMuteStateFromTheLookBefore() {
        let r = Rig()
        r.follower.start()
        #expect(r.follower.followingButton && !r.timeline.mutedNow)
        r.look(2)
        r.ui.set(inHuddle: true, mic: "Unmute microphone")
        r.mic(false)  // Slack lets go of the mic too
        r.look(2.5)
        r.ui.set(inHuddle: true, mic: "Mute microphone")
        r.mic(true)
        r.look(6)
        #expect(r.timeline.mutedRanges(from: t(0), to: t(7)) == [t(2)..<t(6)])
        #expect(!r.state.left)
    }

    @Test func withoutTheButtonSlacksMicIsTheMuteState() {
        let r = Rig()
        r.ui.reading = .notTrusted
        r.follower.start()
        r.mic(false)
        r.look(3)
        r.mic(true)
        r.look(4)
        #expect(!r.follower.followingButton)
        #expect(r.timeline.mutedRanges(from: t(0), to: t(5)) == [t(3)..<t(4)])
        #expect(r.said.all.filter { $0.contains("may not use Accessibility") }.count == 1)
        // A label Palaver doesn't know: Slack's mic too.
        let u = Rig()
        u.ui.set(inHuddle: true, mic: "Micro désactivé")
        u.follower.start()
        u.mic(false)
        u.look(1)
        #expect(!u.follower.followingButton && u.timeline.muted(at: t(1)))
    }

    @Test func theControlsGoneForASecondWithTheMicLetGoIsLeaving() {
        let r = Rig()
        r.follower.start()
        r.look(10)
        r.ui.set(inHuddle: false)  // left at 10.2: the controls are gone, Slack lets go of the mic
        r.mic(false)
        r.look(10.5)
        #expect(!r.state.left)  // once is no proof
        r.look(11)
        #expect(!r.state.left)
        r.look(11.5)
        #expect(r.state.left && r.said.all.contains("left the Slack huddle: its controls are gone and Slack holds no mic"))
        r.follower.stop()
        #expect(!r.state.left)  // the recording is over: nothing left to say
    }

    @Test func nothingElseCountsAsLeaving() {
        // Slack still holding the mic.
        let a = Rig()
        a.follower.start()
        a.ui.set(inHuddle: false)
        for s in stride(from: 1.0, through: 5, by: 0.5) { a.look(s) }
        #expect(!a.state.left)
        // Every Slack window closed: nothing can be told.
        let b = Rig()
        b.follower.start()
        b.ui.set(inHuddle: false, windows: 0)
        b.mic(false)
        for s in stride(from: 1.0, through: 5, by: 0.5) { b.look(s) }
        #expect(!b.state.left)
        // A muted user minimizes Slack (no window left shown), or hides it: its controls aren't shown, nothing told.
        for (windows, hidden) in [(0, false), (1, true)] {
            let m = Rig()
            m.follower.start()
            m.mic(false)
            m.look(0.5)
            m.ui.set(inHuddle: false, windows: windows, hidden: hidden)
            for s in stride(from: 1.0, through: 5, by: 0.5) { m.look(s) }
            #expect(!m.state.left)
            // Hidden or minimized during the confirmation: it starts again once Slack is shown.
            m.ui.set(inHuddle: false)
            m.look(5.5)
            #expect(!m.state.left)
            m.ui.set(inHuddle: false, windows: windows, hidden: hidden)
            m.look(6)
            m.ui.set(inHuddle: false)
            m.look(6.5)
            #expect(!m.state.left)
            m.look(7.5)
            #expect(m.state.left)  // shown, the controls gone for a second: left
        }
        // Controls never seen in this recording (another window shown, a huddle the UI doesn't show).
        let c = Rig()
        c.ui.set(inHuddle: false)
        c.follower.start()
        c.mic(false)
        for s in stride(from: 1.0, through: 5, by: 0.5) { c.look(s) }
        #expect(!c.state.left)
        // Accessibility gone or Slack quit in between: the audio rules, nothing more.
        let d = Rig()
        d.follower.start()
        d.mic(false)
        d.ui.reading = .noApp
        for s in stride(from: 1.0, through: 5, by: 0.5) { d.look(s) }
        #expect(!d.state.left)
    }

    @Test func comingBackBeforeTheStopIsInTheHuddleAgain() {
        let r = Rig()
        r.follower.start()
        r.ui.set(inHuddle: false)
        r.mic(false)
        r.look(1); r.look(2.5)
        #expect(r.state.left)
        r.ui.set(inHuddle: true, mic: "Mute microphone")
        r.mic(true)
        r.look(3)
        #expect(!r.state.left && r.said.all.contains("back in the Slack huddle"))
    }
}
