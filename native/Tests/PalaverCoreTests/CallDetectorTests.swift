import Testing
@testable import PalaverCore

final class FakeLister: ProcessLister, @unchecked Sendable {
    var list: [AudioProcess] = []
    var fail = false
    var provider: (() -> [AudioProcess])?
    struct Boom: Error {}
    func processes() throws -> [AudioProcess] {
        if fail { throw Boom() }
        return provider?() ?? list
    }
}

final class Cell<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}

func proc(_ b: String, _ inp: Bool, out: Bool = false) -> AudioProcess {
    AudioProcess(bundleId: b, runningInput: inp, runningOutput: out)
}

let slackId = "com.tinyspeck.slackmacgap.helper"
let teamsId = "com.microsoft.teams2.helper"

@Test func callDetectorTellsTeamsAndSlackApartAndKeepsAMutedHuddle() {
    let l = FakeLister()
    let d = CallDetector(lister: l)
    l.list = [proc("com.tinyspeck.slackmacgap", false, out: true)]
    #expect(d() == nil)  // a notification sound starts nothing
    l.list = [proc(slackId, true, out: true)]
    #expect(d() == .slack)
    l.list = [proc(slackId, false, out: true)]
    #expect(d() == .slack)  // muted in the huddle: the others still play
    l.list = [proc(slackId, false)]
    #expect(d() == nil)
    l.list = [proc(slackId, false, out: true)]
    #expect(d() == nil)  // the huddle ended: sound alone again
    l.list = [proc(teamsId, true), proc("com.tinyspeck.slackmacgap", true)]
    #expect(d() == .teams)
    let off = FakeLister(); off.list = [proc("com.tinyspeck.slackmacgap", true)]
    #expect(CallDetector(lister: off, slack: { false })() == nil)
}

@Test func teamsCountsOnlyInputAndOnlyTeams() {
    let l = FakeLister()
    l.list = [proc("com.microsoft.teams2.helper", false)]
    #expect(CallDetector(lister: l)() == nil)
    l.list = [proc("com.apple.replayd", true)]  // our own recorder's mic
    #expect(CallDetector(lister: l)() == nil)
    l.list = [proc("COM.Microsoft.Teams2.Helper", true)]
    #expect(CallDetector(lister: l)() == .teams)
}

@Test func theDetectorLogsEachChangeOfACallAppsAudio() {
    let lines = Cell<[String]>([])
    let l = FakeLister()
    l.list = [proc(teamsId, true, out: true)]
    let d = CallDetector(lister: l, log: { lines.value.append($0) })
    _ = d(); _ = d()  // no change: no line
    l.list = [proc(teamsId, true)]; _ = d()
    l.list = []; _ = d()
    #expect(lines.value == ["call apps' audio: com.microsoft.teams2.helper mic+speaker",
                            "call apps' audio: com.microsoft.teams2.helper mic",
                            "call apps' audio: none"])
}

@Test func detectorSkipsDisabledApps() {
    let teams = [proc(teamsId, true)], slack = [proc("com.tinyspeck.slackmacgap", true)]
    func det(_ p: [AudioProcess], t: Bool = true, s: Bool = true) -> CallApp? {
        let l = FakeLister(); l.list = p
        return CallDetector(lister: l, teams: { t }, slack: { s })()
    }
    #expect(det(teams, t: false) == nil)
    #expect(det(slack, s: false) == nil)
    #expect(det(teams + slack, t: false) == .slack)
    #expect(det(teams) == .teams)
}

@Test func theSwitchesAreAskedOnEveryCall() {
    let on = Cell(true)
    let l = FakeLister(); l.list = [proc(teamsId, true)]
    let d = CallDetector(lister: l, teams: { on.value })
    #expect(d() == .teams)
    on.value = false
    #expect(d() == nil)
}

@Test func theAppThatTookTheMicLastIsTheCall() {
    let l = FakeLister()
    let clock = Cell(0.0)
    let d = CallDetector(lister: l, clock: { clock.value })
    let teams = proc(teamsId, true), huddle = proc(slackId, true)
    l.list = [teams]
    #expect(d() == .teams)
    clock.value = 60; l.list = [teams, huddle]
    #expect(d() == .slack)
    clock.value = 70; l.list = [huddle, teams]
    #expect(d() == .slack)  // the same two holders later: still the huddle
    clock.value = 80; l.list = [huddle]
    #expect(d() == .slack)
    clock.value = 90; l.list = [huddle, teams]
    #expect(d() == .teams)
}

@Test func bothTakingTheMicAtOnceGoToTeams() {
    let l = FakeLister(); l.list = [proc(slackId, true), proc(teamsId, true)]
    #expect(CallDetector(lister: l, clock: { 5 })() == .teams)
}

private func apps(slack: [(Double, Double)] = [], teams: [(Double, Double)] = []) -> (CallDetector, Cell<Double>) {
    let clock = Cell(0.0)
    let l = FakeLister()
    l.provider = {
        let now = clock.value
        var out: [AudioProcess] = []
        if slack.contains(where: { $0.0 <= now && now < $0.1 }) { out.append(proc(slackId, true, out: true)) }
        if teams.contains(where: { $0.0 <= now && now < $0.1 }) { out.append(proc("com.microsoft.teams2.modulehost", true, out: true)) }
        return out
    }
    return (CallDetector(lister: l, clock: { clock.value }), clock)
}

@Test func theDetectorIgnoresAnAppsHoldUntilItLetsGo() {
    let (d, clock) = apps(slack: [(0, 100), (102, 130), (200, 300)], teams: [(50, 80)])
    #expect(d() == .slack)
    d.ignore(.slack)
    #expect(d() == nil)
    clock.value = 60
    #expect(d() == .teams)  // another app's call
    clock.value = 101
    #expect(d() == nil)
    clock.value = 103
    #expect(d() == nil && d.ignored == [.slack])  // let go for a moment only
    clock.value = 140
    #expect(d() == nil)
    clock.value = 150
    #expect(d() == nil && d.ignored.isEmpty)  // let go for 10 s
    clock.value = 250
    #expect(d() == .slack)
    d.ignore(named: "zoom")
    #expect(d.ignored.isEmpty)
}

@Test func aFailingListKeepsTheLastStateAndLogsOnceEachWay() {
    let lines = Cell<[String]>([])
    let l = FakeLister(); l.list = [proc(teamsId, true)]
    let d = CallDetector(lister: l, log: { lines.value.append($0) })
    #expect(d() == .teams)
    l.fail = true
    #expect(d() == .teams); #expect(d() == .teams)
    l.fail = false
    #expect(d() == .teams)
    let failures = lines.value.filter { $0.hasPrefix("call detection failed") }
    #expect(failures.count == 1)
    #expect(lines.value.filter { $0 == "call detection works again" }.count == 1)
}

@Test func theRealListerReadsWithoutThrowing() throws {
    // Read-only; no permission, no audio.
    _ = try CoreAudioProcessLister().processes()
}
