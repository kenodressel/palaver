// test_daemon.py: a manual recording whose call has ended (issue #52) and a call taken on another
// device (#7), the pure parts.
import Testing
@testable import PalaverDaemon

/// `timeline`: (time, call app or nil, seconds both tracks were silent or nil).
private func ask(_ q: inout StopQuestion, _ timeline: [(Double, String?, Double?)]) -> [(Double, String)] {
    var out: [(Double, String)] = []
    for (now, call, silent) in timeline {
        if let reason = q.update(now, call: call, silentFor: silent) { out.append((now, reason)) }
    }
    return out
}

private func eq(_ a: [(Double, String)], _ b: [(Double, String)]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
}

@Suite struct StopQuestionTests {
    @Test func stopQuestionAsksOnceWhenTheCallHasBeenReleasedForTheGrace() {
        var q = StopQuestion(grace: 10)
        let timeline: [(Double, String?, Double?)] = [(0, nil, nil), (5, "teams", nil), (100, "teams", nil),
                                                       (102, nil, nil), (110, nil, nil), (112, nil, nil), (200, nil, nil), (900, nil, nil)]
        #expect(eq(ask(&q, timeline), [(112, "teams")]))
        #expect(q.open == "teams")
    }

    @Test func stopQuestionIgnoresABriefReleaseAndNamesSlack() {
        var q = StopQuestion(grace: 10)
        #expect(eq(ask(&q, [(0, "slack", nil), (20, nil, nil), (25, "slack", nil), (40, nil, nil), (50, nil, nil)]), [(50, "slack")]))
    }

    @Test func stopQuestionClosesWhenTheCallComesBack() {
        var q = StopQuestion(grace: 10)
        _ = ask(&q, [(0, "teams", nil), (10, nil, nil), (20, nil, nil)])
        #expect(q.open == "teams")
        _ = ask(&q, [(30, "teams", nil)])
        #expect(q.open == nil)
        #expect(eq(ask(&q, [(40, nil, nil), (50, nil, nil)]), [(50, "teams")]))  // asks again after this call
    }

    @Test func stopQuestionAsksAfterTenSilentMinutesOnlyWithoutACall() {
        var q = StopQuestion(grace: 10)
        #expect(eq(ask(&q, [(0, nil, 0), (599, nil, 599), (600, nil, 600), (700, nil, 700)]), [(600, "silence")]))
        #expect(q.minutes == 10)
        var seen = StopQuestion(grace: 10)
        // A muted Teams call is silent too; once a call was seen, its end is the question.
        #expect(ask(&seen, [(0, "teams", 0), (300, "teams", 300), (700, "teams", 700)]).isEmpty)
        var unknown = StopQuestion(grace: 10)
        #expect(ask(&unknown, [(0, nil, nil), (900, nil, nil)]).isEmpty)  // no level known
    }

    @Test func keepRecordingIsQuietUntilTheNextCallEnds() {
        var q = StopQuestion(grace: 10)
        _ = ask(&q, [(0, "teams", 0), (100, nil, 0), (110, nil, 10)])
        q.keep(120)
        #expect(q.open == nil)
        #expect(ask(&q, [(130, nil, 20), (600, nil, 500), (1000, nil, 900)]).isEmpty)
        #expect(eq(ask(&q, [(1100, "slack", 0), (1200, nil, 0), (1210, nil, 10)]), [(1210, "slack")]))
    }

    @Test func keepRecordingIsQuietForThirtySilentMinutes() {
        var q = StopQuestion(grace: 10)
        #expect(eq(ask(&q, [(0, nil, 0), (600, nil, 600)]), [(600, "silence")]))
        q.keep(610)
        // Silent all along: 30 min counted from the answer, not from when it went quiet.
        #expect(ask(&q, [(1000, nil, 1000), (610 + 1799, nil, 2409)]).isEmpty)
        #expect(eq(ask(&q, [(610 + 1800, nil, 2410)]), [(2410, "silence")]))
        #expect(q.minutes == 30)
        q.keep(2420)
        #expect(ask(&q, [(3000, nil, 5), (2420 + 1800, nil, 1795)]).isEmpty)  // someone spoke meanwhile
    }

    @Test func stopQuestionTextNamesTheCall() {
        #expect(stopQuestionText("teams", minutes: 10)
                == "You started this recording yourself, and your Teams call just ended. Stop recording?")
        #expect(stopQuestionText("slack", minutes: 10).contains("your Slack huddle just ended"))
        #expect(stopQuestionText("silence", minutes: 10)
                == "You started this recording yourself, and it has been silent for 10 minutes. Stop recording?")
        #expect(stopQuestionText("silent_call", minutes: 10, app: "slack")
                == "Nothing has been heard from the others in your Slack huddle on this Mac for 10 minutes. Taken on another device? Stop recording?")
        #expect(stopQuestionTitle("teams", minutes: 10) == "Call ended — still recording")
        #expect(stopQuestionTitle("silence", minutes: 30) == "Silent for 30 min — still recording")
    }

    @Test func silentCallAsksWithoutTheOthersAndStopsOnlyWhenAllIsSilent() {
        var q = SilentCall(askAfter: 600, stopAfter: 1800)
        #expect(q.update(0, othersSilent: 0, allSilent: 0) == nil && q.update(100, othersSilent: nil, allSilent: nil) == nil)
        #expect(q.update(600, othersSilent: 600, allSilent: 5) == .ask && q.open == "silent_call" && q.minutes == 10)  // the user talks
        #expect(q.update(700, othersSilent: 700, allSilent: 5) == nil)  // asked once
        #expect(q.update(2000, othersSilent: 2000, allSilent: 30) == nil)  // the user still talks: never stopped by itself
        #expect(q.update(2100, othersSilent: 3, allSilent: 3) == nil && q.open == nil)  // the others are heard: the question goes
        #expect(q.update(2800, othersSilent: 703, allSilent: 703) == .ask)
        #expect(q.update(4000, othersSilent: 1903, allSilent: 1903) == .stop)
    }

    @Test func silentCallKeptNeverStopsAndAsksAgainAfterAQuietWhile() {
        var q = SilentCall(askAfter: 600, stopAfter: 1800, quietAfterKeep: 1800)
        #expect(q.update(600, othersSilent: 600, allSilent: 600) == .ask)
        q.keep(650)
        #expect(q.update(2000, othersSilent: 2000, allSilent: 2000) == nil && q.open == nil)  // 1350 s since the answer
        #expect(q.update(2450, othersSilent: 2450, allSilent: 2450) == .ask)
        #expect(q.update(9000, othersSilent: 9000, allSilent: 9000) == nil)  // kept: it never stops by itself
    }
}
