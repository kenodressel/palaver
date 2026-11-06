// tests/test_lifecycle.py: why Palaver records, why it stopped, where it paused, what went wrong with the audio.
import Foundation
import Testing
@testable import PalaverDaemon

private let start = "2026-10-29T12:06:10+01:00"
private let tz = TimeZone(secondsFromGMT: 3600)!
private let startDate = WallTime.parse(start)!

private func obj(_ fields: [(String, JSONValue)]) -> JSONValue { .object(fields) }

@Suite struct LifecycleTests {
    @Test func recordingTextSaysWhyAndWithWhichMic() {
        let why = obj([("trigger", .string("teams")), ("since", .string(start)),
                       ("mic", obj([("device", .string("AirPods")), ("rate", .int(24000))]))])
        #expect(Lifecycle.recordingText(why, timeZone: tz) == "Recording · Teams call since 12:06 · mic AirPods (24 kHz)")
        #expect(Lifecycle.recordingText(obj([("trigger", .string("slack")), ("since", .string(start))]), timeZone: tz)
                == "Recording · Slack huddle since 12:06")
        #expect(Lifecycle.recordingText(obj([("trigger", .string("manual")), ("since", .string(start)),
                                             ("mic", obj([("rate", .int(44100))]))]), timeZone: tz)
                == "Recording · started by you at 12:06 · mic 44.1 kHz")
        #expect(Lifecycle.recordingText(obj([("trigger", .string("teams")), ("since", .string(start)), ("restarts", .int(1)),
                                             ("mic", obj([("device", .string("MacBook Pro Mic"))]))]), timeZone: tz)
                == "Recording · Teams call since 12:06, continued after a Palaver restart · mic MacBook Pro Mic")
    }

    @Test func stoppedTextNamesTheReason() {
        #expect(Lifecycle.stoppedText(trigger: "teams", reason: "call_ended") == "Teams call ended")
        #expect(Lifecycle.stoppedText(trigger: "slack", reason: "call_ended") == "Slack huddle ended")
        #expect(Lifecycle.stoppedText(trigger: "manual", reason: "by_you") == "Stopped by you")
        #expect(Lifecycle.stoppedText(trigger: "teams", reason: "restart") == "Palaver restarted")
        #expect(Lifecycle.stoppedText(trigger: "teams", reason: "auto_off") == "Automatic recording turned off")
        #expect(Lifecycle.stoppedText(trigger: "teams", reason: "max_length") == "Reached the maximum length")
        #expect(Lifecycle.stoppedText(trigger: "teams", reason: nil) == nil)
    }

    @Test func gapTextGivesTheWallClock() {
        #expect(Lifecycle.gapText(obj([("start", .double(415.0)), ("end", .double(424.4)), ("why", .string("restart"))]), start: startDate, timeZone: tz)
                == "Recording paused 12:13:05–12:13:14 (Palaver restarted)")
        #expect(Lifecycle.gapText(obj([("start", .double(415.0)), ("end", .double(424.0))]), start: startDate, timeZone: tz)
                == "Recording paused 12:13:05–12:13:14")
    }

    @Test func recordedTextTellsHowARecordingStartedAndStopped() {
        let gap = obj([("start", .double(415.0)), ("end", .double(424.0)), ("why", .string("restart"))])
        let meta = obj([("start_time", .string(start)), ("end_time", .string("2026-10-29T13:02:00+01:00")), ("trigger", .string("teams")),
                        ("stop_reason", .string("call_ended")), ("gaps", .array([gap]))])
        #expect(Lifecycle.recordedText(meta, timeZone: tz) == "Teams call detected 12:06 · Teams call ended 13:02 · Palaver restarted — continued")
        let two = obj([("start_time", .string(start)), ("end_time", .string("2026-10-29T13:02:00+01:00")), ("trigger", .string("teams")),
                       ("stop_reason", .string("call_ended")), ("gaps", .array([gap, gap]))])
        #expect(Lifecycle.recordedText(two, timeZone: tz)!.hasSuffix("Palaver restarted twice — continued"))
        let three = obj([("start_time", .string(start)), ("trigger", .string("teams")), ("stop_reason", .string("call_ended")),
                         ("gaps", .array([gap, gap, gap]))])
        #expect(Lifecycle.recordedText(three, timeZone: tz)!.hasSuffix("Palaver restarted 3 times — continued"))
        let manual = obj([("start_time", .string(start)), ("end_time", .string("2026-10-29T12:40:00+01:00")),
                          ("trigger", .string("manual")), ("stop_reason", .string("by_you"))])
        #expect(Lifecycle.recordedText(manual, timeZone: tz) == "Started by you 12:06 · Stopped by you 12:40")
        let cut = obj([("start_time", .string(start)), ("end_time", .string("2026-10-29T12:13:05+01:00")),
                       ("trigger", .string("teams")), ("stop_reason", .string("restart"))])
        #expect(Lifecycle.recordedText(cut, timeZone: tz) == "Teams call detected 12:06 · Palaver restarted 12:13")
        #expect(Lifecycle.recordedText(cut, continued: true, timeZone: tz) == "Teams call detected 12:06 · Palaver restarted 12:13 — continued")
        #expect(Lifecycle.recordedText(obj([("start_time", .string(start)), ("duration_seconds", .int(60))]), timeZone: tz) == nil)  // before #47
    }

    // --- audio problems (issue #50) ---

    @Test func recordingTextNamesTheOutputDeviceWhenKnown() {
        let why = obj([("trigger", .string("teams")), ("since", .string(start)),
                       ("mic", obj([("device", .string("AirPods Pro")), ("rate", .int(24000))])),
                       ("system", obj([("device", .string("AirPods Pro")), ("rate", .int(24000)), ("source", .string("process-tap"))]))])
        #expect(Lifecycle.recordingText(why, timeZone: tz)
                == "Recording · Teams call since 12:06 · mic AirPods Pro (24 kHz) · output AirPods Pro (24 kHz)")
    }

    @Test func problemWarningSaysWhatIsWrongInPlainWords() {
        #expect(Lifecycle.problemWarning(kind: "speed", track: "system") == "System audio is playing at the wrong speed; Palaver is correcting it")
        #expect(Lifecycle.problemWarning(kind: "speed", track: "mic") == "Microphone is recording at the wrong speed; Palaver is correcting it")
        #expect(Lifecycle.problemWarning(kind: "length", track: "mic") == "Microphone is out of step with the clock")
        #expect(Lifecycle.problemWarning(kind: "stalled", track: "mic") == "No microphone audio is arriving")
        #expect(Lifecycle.problemWarning(kind: "stalled", track: "system") == "No system audio is arriving")
        #expect(Lifecycle.problemWarning(kind: "access", track: "mic")
                == "Microphone access was turned off — allow it in System Settings → Privacy & Security")
        #expect(Lifecycle.problemWarning(kind: "device", track: "system") == "System audio couldn't be rebuilt; Palaver keeps trying")
        #expect(Lifecycle.problemWarning(kind: "device", track: "mic") == "Microphone is unavailable; Palaver keeps trying")
    }

    @Test func recordingWarningsAreTheOpenProblemsAndHintsAreApart() {
        let why = obj([("trigger", .string("teams")), ("since", .string(start)),
                       ("problems", .array([obj([("kind", .string("speed")), ("track", .string("system")), ("start", .double(480))])])),
                       ("hints", .array([obj([("kind", .string("silent")), ("track", .string("mic"))])]))])
        #expect(Lifecycle.recordingWarnings(why) == ["System audio is playing at the wrong speed; Palaver is correcting it"])
        #expect(Lifecycle.recordingHints(why) == ["Your mic sends nothing — muted?"])
        #expect(Lifecycle.recordingWarnings(obj([("trigger", .string("teams")), ("since", .string(start))])) == [])
        #expect(Lifecycle.recordingWarnings(nil) == [] && Lifecycle.recordingHints(nil) == [])
    }

    @Test func problemTextGivesTheWallClockAndWhatWentWrong() {
        func p(_ f: [(String, JSONValue)]) -> JSONValue { obj(f) }
        #expect(Lifecycle.problemText(p([("kind", .string("speed")), ("track", .string("system")), ("start", .double(480)), ("end", .double(600))]),
                                      start: startDate, timeZone: tz) == "Audio problem at 12:14 (system audio played at the wrong speed)")
        #expect(Lifecycle.problemText(p([("kind", .string("length")), ("track", .string("mic")), ("start", .int(0)), ("end", .null)]),
                                      start: startDate, timeZone: tz) == "Audio problem at 12:06 (microphone drifted from the clock)")
        #expect(Lifecycle.problemText(p([("kind", .string("silent")), ("track", .string("mic")), ("start", .int(60))]),
                                      start: startDate, timeZone: tz) == "Audio problem at 12:07 (microphone sent nothing — muted?)")
        #expect(Lifecycle.problemText(p([("kind", .string("unknown-kind")), ("track", .string("mic")), ("start", .int(60))]),
                                      start: startDate, timeZone: tz) == "Audio problem at 12:07")
        // The wall clock taken when it happened wins: a sleep shifts the offset, not this.
        let late = p([("kind", .string("device")), ("track", .string("system")), ("start", .int(60)), ("at", .string("2026-10-29T12:31:40+01:00"))])
        #expect(Lifecycle.problemText(late, start: startDate, timeZone: tz) == "Audio problem at 12:31 (system audio couldn't be rebuilt)")
    }
}
