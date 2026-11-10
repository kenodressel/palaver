// The live coach's nudges (tests/test_live_coach.py, #41): at most one every 3 minutes, each kind can be switched
// off, thresholds from the user's own baseline.
import Foundation
import PalaverCore
@testable import PalaverDomain
@testable import PalaverWorker
import Testing

let ALL_KINDS = ["talk_share": true, "monologue": true, "quiet_invitee": true, "pace": true, "fillers": true]

/// VoiceActivity's snapshot as the nudges read it.
func talk(until: Double = 900, share: Double? = 0.5, window: Double = 600, me: Double = 200,
          monologue: Double = 0) -> JSONValue {
    .object([("until", .double(until)), ("share", .num(share)), ("window", .double(window)), ("me", .double(me)),
             ("others", .double(200)), ("monologue", .double(monologue)), ("speaking", .null)])
}

final class TestClock: @unchecked Sendable {
    var now = 0.0
    func callAsFunction() -> Double { now }
}

private func parse(_ text: String) -> JSONValue { try! PythonJSON.parse(Data(text.utf8)) }

private func speech(wpm: Int, fillers: Double, top: String? = "halt", language: String = "de") -> Speech {
    Speech(seconds: 120, wpm: wpm, fillersPerMinute: fillers, top: top, language: language)
}

private func mine(_ text: String, _ n: Int, seconds: Double = 10, start: Double = 600) -> [VoiceMonitor.Sentence] {
    (0..<n).map { i in
        VoiceMonitor.Sentence(start: start + Double(i) * seconds, end: start + Double(i + 1) * seconds - 0.5, text: text)
    }
}

private func at(_ iso: String) -> PyDateTime { try! PyDateTime.parse(iso) }

private func durations(_ pairs: [(String, Double)]) -> PyDict<Double> { PyDict(pairs) }

@Suite struct LiveCoachTests {
    @Test func test_talk_share_nudge() {
        let n = Nudges(clock: TestClock().callAsFunction)
        #expect(n.update(talk(share: 0.55)) == nil)
        let nudge = n.update(talk(share: 0.72))
        #expect(nudge?.kind == "talk_share")
        #expect(nudge?.text == "You've talked 72 % of the last 10 min")
    }

    @Test func test_no_talk_share_nudge_in_the_first_minutes() {
        let n = Nudges(clock: TestClock().callAsFunction)
        #expect(n.update(talk(until: 200, share: 0.9, window: 200, me: 150)) == nil)
    }

    @Test func test_monologue_nudge() {
        let n = Nudges(clock: TestClock().callAsFunction)
        #expect(n.update(talk(monologue: 170)) == nil)
        #expect(n.update(talk(monologue: 245))?.text == "4-min monologue")
    }

    @Test func test_a_shared_microphone_leaves_out_talk_share_monologue_and_quiet_invitees() {
        let n = Nudges(shared: true, clock: TestClock().callAsFunction)
        #expect(n.update(talk(share: 0.9, monologue: 400), quiet: ["Valerie"], enabled: ALL_KINDS) == nil)
    }

    @Test func test_a_series_remembered_as_one_microphone_says_so_in_the_context() throws {
        let t = Temp(); defer { t.remove() }
        let stores = StorePaths(configDir: t.file("config"), home: t.file("home"))
        let start = at("2026-10-30T10:00:00+01:00")
        let event = CalendarEvent(title: "All Hands", start: start, end: start,
                                  attendees: [Attendee(name: "Valerie", response: "accepted")], uid: "s1", series: true)
        #expect(!Nudges.meetingContext(event, userName: "Timo", baseline: nil, stores: stores).shared)
        try SharedMic.remember(event, true, stores: stores)
        #expect(Nudges.meetingContext(event, userName: "Timo", baseline: nil, stores: stores).shared)
    }

    @Test func test_one_nudge_every_three_minutes() {
        let clock = TestClock()
        let n = Nudges(clock: clock.callAsFunction)
        #expect(n.update(talk(share: 0.8))?.kind == "talk_share")
        clock.now = 60
        #expect(n.update(talk(share: 0.8, monologue: 200))?.kind == "talk_share")  // still the one shown
        clock.now = Nudges.NUDGE_EVERY + 1
        #expect(n.update(talk(share: 0.8, monologue: 200))?.kind == "monologue")
    }

    @Test func test_a_nudge_is_shown_for_two_minutes_then_gone() {
        let clock = TestClock()
        let n = Nudges(clock: clock.callAsFunction)
        n.update(talk(monologue: 200))
        clock.now = 119
        #expect(n.update(talk())?.kind == "monologue")
        clock.now = 121
        #expect(n.update(talk()) == nil)
    }

    @Test func test_the_same_nudge_waits_until_it_stopped_being_true() {
        let clock = TestClock()
        let n = Nudges(clock: clock.callAsFunction)
        #expect(n.update(talk(monologue: 200)) != nil)
        clock.now = 400
        #expect(n.update(talk(monologue: 500)) == nil)  // the same monologue
        clock.now = 410
        n.update(talk(monologue: 0))
        clock.now = 800
        #expect(n.update(talk(monologue: 190))?.kind == "monologue")  // a new one
    }

    @Test func test_kinds_switched_off() {
        let n = Nudges(clock: TestClock().callAsFunction)
        var off = ALL_KINDS
        off["monologue"] = false
        off["talk_share"] = false
        #expect(n.update(talk(share: 0.9, monologue: 300), enabled: off) == nil)
    }

    @Test func test_the_threshold_follows_the_baseline() {
        #expect(Nudges.shareThreshold(nil, nil) == 0.7)
        let base = parse(#"{"share_1on1": 0.55, "share_group": 0.25}"#)
        #expect(abs(Nudges.shareThreshold(base, "1:1") - 0.75) < 1e-9)
        #expect(abs(Nudges.shareThreshold(base, "group") - 0.6) < 1e-9)
        #expect(Nudges.shareThreshold(parse(#"{"share_1on1": 0.8, "share_group": null}"#), "1:1") == 0.85)
        let n = Nudges(baseline: base, kind: "group", clock: TestClock().callAsFunction)
        #expect(n.update(talk(share: 0.62))?.text == "You've talked 62 % of the last 10 min")
    }

    @Test func test_quiet_invitee_nudge() {
        var n = Nudges(clock: TestClock().callAsFunction)
        #expect(n.update(talk(), quiet: ["Timo Strauß"])?.text == "Timo Strauß hasn't said anything yet")
        n = Nudges(clock: TestClock().callAsFunction)
        #expect(n.update(talk(), quiet: ["Valerie", "Carla"])?.text == "Valerie and Carla haven't said anything yet")
    }

    // MARK: pace and fillers, from the stream's text

    @Test func test_pace_and_fillers_over_the_last_minutes() throws {
        let words = String(repeating: "wir haben das halt quasi so gemacht und das ist eigentlich gut gelaufen ", count: 2)  // 26 words
        let stats = try #require(Nudges.paceAndFillers(mine(words, 12), until: 720))
        #expect(abs(stats.seconds - 114) <= 1)
        #expect(abs(Double(stats.wpm) - 26.0 * 12 / 114 * 60) <= 2)
        #expect(abs(stats.fillersPerMinute - 6.0 * 12 / 114 * 60) <= 0.5)
        #expect(stats.top == "halt")
        #expect(stats.language == "de")
    }

    @Test func test_too_little_speech_for_pace() {
        #expect(Nudges.paceAndFillers(mine("hello there", 3), until: 630) == nil)
    }

    @Test func test_pace_nudge_only_clearly_above_the_baseline() {
        let base = parse(#"{"meetings": 6, "wpm": 140.0, "fillers_per_minute": {"de": 1.5, "en": null}}"#)
        let n = Nudges(baseline: base, clock: TestClock().callAsFunction)
        #expect(n.update(talk(), speech: speech(wpm: 160, fillers: 1.6)) == nil)
        #expect(n.update(talk(), speech: speech(wpm: 190, fillers: 1.6))?.text
                == "You're speaking fast: 190 words a minute (usual 140)")
    }

    @Test func test_filler_nudge_against_the_baseline_in_the_same_language() {
        let base = parse(#"{"meetings": 6, "wpm": 140.0, "fillers_per_minute": {"de": 1.5, "en": null}}"#)
        let n = Nudges(baseline: base, clock: TestClock().callAsFunction)
        #expect(n.update(talk(), speech: speech(wpm: 140, fillers: 4.0, language: "en")) == nil)  // no English baseline
        #expect(n.update(talk(), speech: speech(wpm: 140, fillers: 4.0))?.text
                == "More filler words than usual: 4.0 a minute (usual 1.5), mostly “halt”")
    }

    @Test func test_no_pace_or_filler_nudge_without_a_baseline() {
        let n = Nudges(baseline: parse(#"{"meetings": 1, "wpm": 100.0, "fillers_per_minute": {"de": 0.5}}"#),
                       clock: TestClock().callAsFunction)
        #expect(n.update(talk(), speech: speech(wpm: 200, fillers: 6.0)) == nil)
    }

    // MARK: who hasn't spoken

    @Test func test_an_invitee_not_among_the_named_voices_is_quiet() {
        let byVoice = durations([("SPEAKER_00", 300), ("SPEAKER_01", 120), ("SPEAKER_02", 4)])
        let names = PyDict([("SPEAKER_00", "Timo Strauß"), ("SPEAKER_01", "Anna")])
        #expect(Nudges.quietInvitees(["Valerie", "Timo Strauß"], talk: byVoice, names: names, elapsed: 700) == ["Valerie"])
    }

    @Test func test_unsure_when_a_voice_has_no_name() {
        let byVoice = durations([("SPEAKER_00", 300), ("SPEAKER_01", 120)])
        #expect(Nudges.quietInvitees(["Valerie"], talk: byVoice, names: PyDict([("SPEAKER_00", "Timo Strauß")]),
                                     elapsed: 700).isEmpty)
    }

    @Test func test_unsure_early_or_with_little_call_audio() {
        let names = PyDict([("SPEAKER_00", "Timo Strauß")])
        #expect(Nudges.quietInvitees(["Valerie"], talk: durations([("SPEAKER_00", 300)]), names: names, elapsed: 300).isEmpty)
        #expect(Nudges.quietInvitees(["Valerie"], talk: durations([("SPEAKER_00", 30)]), names: names, elapsed: 900).isEmpty)
    }

    @Test func test_invitees_matched_by_first_name() {
        #expect(Nudges.quietInvitees(["Timo Strauß"], talk: durations([("SPEAKER_00", 300)]),
                                     names: PyDict([("SPEAKER_00", "Timo")]), elapsed: 900).isEmpty)
    }

    @Test func test_speech_kind() {
        #expect(Nudges.speechKind(1) == "1:1")
        #expect(Nudges.speechKind(4) == "group")
        #expect(Nudges.speechKind(0) == nil)
    }

    @Test func test_the_meeting_context_from_the_calendar() {
        let t = Temp(); defer { t.remove() }
        let stores = StorePaths(configDir: t.file("config"), home: t.file("home"))
        let start = at("2026-10-30T10:00:00+01:00")
        // The calendar gives responses (Carla declined): only who accepted is watched.
        let event = CalendarEvent(title: "Weekly", start: start, end: start, attendees: [
            Attendee(name: "Timo Strauß", isSelf: true), Attendee(name: "Valerie"), Attendee(name: "Room 4", isRoom: true),
            Attendee(name: "Carla", response: "declined")])
        let base = parse(#"{"meetings": 4}"#)
        #expect(Nudges.meetingContext(event, userName: "Timo", baseline: base, stores: stores)
                == CoachContext(invitees: [], kind: "1:1", baseline: base))
        let accepted = CalendarEvent(title: "Weekly", start: start, end: start, attendees: [
            Attendee(name: "Valerie", response: "accepted"), Attendee(name: "Anna", response: "tentative"),
            Attendee(name: "Carla", response: "declined")])
        #expect(Nudges.meetingContext(accepted, userName: "Timo", baseline: nil, stores: stores).invitees == ["Valerie"])
        // No responses: only invitees whose voice is known.
        let unknown = CalendarEvent(title: "Weekly", start: start, end: start,
                                    attendees: [Attendee(name: "Valerie Vogt"), Attendee(name: "Anna")])
        let ctx = Nudges.meetingContext(unknown, userName: "Timo", baseline: nil, voices: ["Valerie"], stores: stores)
        #expect(ctx.invitees == ["Valerie Vogt"] && ctx.kind == "group")
        #expect(Nudges.meetingContext(unknown, userName: "Timo", baseline: nil, stores: stores).invitees.isEmpty)
        #expect(Nudges.meetingContext(nil, userName: "Timo", baseline: nil, stores: stores) == CoachContext())
    }

    @Test func test_the_kinds_switched_on_in_settings() {
        // Pace and fillers are off until they are calibrated against replays (bench-live).
        var expected = ALL_KINDS
        expected["pace"] = false
        expected["fillers"] = false
        #expect(Nudges.enabledKinds(SettingsValues()) == expected)
        var s = SettingsValues()
        s.nudgePace = true
        s.nudgeQuietInvitee = false
        expected = ALL_KINDS
        expected["fillers"] = false
        expected["quiet_invitee"] = false
        #expect(Nudges.enabledKinds(s) == expected)
    }

    @Test func test_unsure_when_two_voices_have_the_same_name() {
        let byVoice = durations([("SPEAKER_00", 300), ("SPEAKER_01", 120)])
        let names = PyDict([("SPEAKER_00", "Timo Strauß"), ("SPEAKER_01", "Timo Strauß")])
        #expect(Nudges.quietInvitees(["Valerie"], talk: byVoice, names: names, elapsed: 700).isEmpty)
    }

    @Test func test_pace_and_filler_nudges_come_back_only_well_below_the_threshold() {
        let base = parse(#"{"meetings": 6, "wpm": 140.0, "fillers_per_minute": {"de": 1.5, "en": null}}"#)
        let clock = TestClock()
        let n = Nudges(baseline: base, clock: clock.callAsFunction)
        let fast = speech(wpm: 190, fillers: 1.0)
        #expect(n.update(talk(), speech: fast)?.kind == "pace")
        clock.now = 400
        n.update(talk(), speech: speech(wpm: 165, fillers: 1.0))  // just under the threshold (168): not re-armed
        clock.now = 800
        #expect(n.update(talk(), speech: fast) == nil)
        n.update(talk(), speech: speech(wpm: 150, fillers: 1.0))  // well under it
        clock.now = 1200
        #expect(n.update(talk(), speech: fast)?.kind == "pace")
    }

    // tests/test_coach_notifications.py, the nudges' part.

    @Test func test_a_new_nudge_is_fresh_once() {
        let clock = TestClock()
        let n = Nudges(clock: clock.callAsFunction)
        n.update(talk(monologue: 200))
        #expect(n.fresh == Nudge(kind: "monologue", text: "3-min monologue", at: 900))
        clock.now = 60
        #expect(n.update(talk(monologue: 260))?.kind == "monologue")  // still shown ...
        #expect(n.fresh == nil)  // ... but not new
    }
}
