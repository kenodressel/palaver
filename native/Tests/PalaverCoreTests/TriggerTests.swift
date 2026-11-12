import Testing
@testable import PalaverCore

private func run(_ t: inout Trigger, _ timeline: [(Double, Bool)]) -> [String] {
    var out: [String] = []
    for (now, active) in timeline {
        for a in t.update(now: now, active: active) { out.append("\(now) \(a.rawValue)") }
    }
    return out
}

private func runApps(_ t: inout Trigger, _ timeline: [(Double, CallApp?)]) -> [String] {
    var out: [String] = []
    for (now, app) in timeline {
        for a in t.update(now: now, active: app != nil, app: app) { out.append("\(now) \(a.rawValue)") }
    }
    return out
}

@Test func triggerStartsAfterDebounceAndStopsAfterGrace() {
    var t = Trigger(startAfter: 4, grace: 10, maxSession: 4 * 3600)
    #expect(run(&t, [(0, true), (2, true), (4, true), (6, true), (8, false), (16, false), (18, false)])
            == ["4.0 start", "18.0 stop"])
}

@Test func briefMicUseDoesNotStart() {
    var t = Trigger(startAfter: 4, grace: 10, maxSession: 3600)
    #expect(run(&t, [(0, true), (2, true), (3, false), (5, true), (7, false)]).isEmpty)
}

@Test func shortReleaseWithinGraceKeepsRecording() {
    var t = Trigger(startAfter: 4, grace: 10, maxSession: 3600)
    #expect(run(&t, [(0, true), (4, true), (10, false), (14, false), (16, true), (30, true)]) == ["4.0 start"])
}

@Test func maxDurationStopsAndWaitsForRelease() {
    var t = Trigger(startAfter: 0, grace: 10, maxSession: 100)
    #expect(run(&t, [(0, true), (50, true), (100, true), (150, true), (160, false), (170, true)])
            == ["0.0 start", "100.0 stop", "170.0 start"])
}

@Test func maxDurationBlocksWhileActiveAndIdlesWhenReleased() {
    var t = Trigger(startAfter: 0, grace: 10, maxSession: 100)
    _ = run(&t, [(0, true), (100, true)])
    #expect(t.state == .blocked && t.stoppedBecause == .maxLength)
    _ = run(&t, [(110, false)])
    #expect(t.state == .idle)
}

@Test func aCallInAnotherAppEndsTheMeetingAndStartsItsOwn() {
    var t = Trigger(startAfter: 4, grace: 10, maxSession: 3600)
    let r = runApps(&t, [(0, .teams), (4, .teams), (100, .teams), (102, .slack), (104, .slack), (106, .slack),
                         (200, .slack), (202, nil), (212, nil)])
    #expect(r == ["4.0 start", "106.0 stop", "106.0 start", "212.0 stop"])
    #expect(t.state == .idle)
}

@Test func aMomentOfAnotherAppInsideACallSplitsNothing() {
    var t = Trigger(startAfter: 4, grace: 10, maxSession: 3600)
    #expect(runApps(&t, [(0, .teams), (4, .teams), (50, .slack), (52, .teams), (54, .slack), (56, .teams), (300, .teams)])
            == ["4.0 start"])
}

@Test func aSwitchIsACallEndedForTheMeetingBefore() {
    var t = Trigger(startAfter: 4, grace: 10, maxSession: 3600)
    _ = runApps(&t, [(0, .teams), (4, .teams), (10, .slack)])
    #expect(runApps(&t, [(14, .slack)]) == ["14.0 stop", "14.0 start"])
    #expect(t.stoppedBecause == .callEnded && t.app == .slack && t.state == .recording)
}

@Test func blockedUntilReleasedAndStartedAtAndReset() {
    var t = Trigger(startAfter: 4, grace: 10, maxSession: 100)
    t.blockUntilReleased()
    #expect(run(&t, [(0, true), (10, true)]).isEmpty && t.state == .blocked)
    _ = run(&t, [(11, false)])
    #expect(t.state == .idle)
    // a session continued after a restart counts from its first part
    _ = run(&t, [(20, true), (24, true)])
    t.startedAt(-30)
    #expect(run(&t, [(60, true)]).isEmpty)
    #expect(run(&t, [(70, true)]) == ["70.0 stop"])
    t.reset()
    #expect(t.state == .idle && t.app == nil)
}

@Test func aCallTheAppSaysWasLeftStopsWithoutTheGrace() {
    var t = Trigger(startAfter: 4, grace: 5, maxSession: 3600)
    _ = run(&t, [(0, true), (4, true)])
    #expect(t.update(now: 10, active: false, ended: false).isEmpty)
    #expect(t.update(now: 11, active: false, ended: true) == [.stop] && t.stoppedBecause == .callEnded)
    var u = Trigger(startAfter: 4, grace: 5, maxSession: 3600)
    _ = run(&u, [(0, true), (4, true)])
    #expect(u.update(now: 10, active: true, ended: true).isEmpty)  // still in the call: no stop
}
