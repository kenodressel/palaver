import Foundation
import PalaverCore
import Testing
@testable import PalaverCapture

// tests/test_audio_health.py, ported: thresholds and incidents of the recorder's health monitor.

private let tone: [Float] = (0..<480).map { Float(0.2 * sin(Double($0) / 5)) }
private let zeros = [Float](repeating: 0, count: 480)
private let wall0 = ISO8601DateFormatter().date(from: "2026-10-29T12:06:00+01:00")!
private let cet = TimeZone(secondsFromGMT: 3600)!

private func health(started: Double = 0, wall: @escaping () -> Date = { wall0 }) -> AudioHealth {
    AudioHealth(started: started, wall: wall, timeZone: cet)
}

@discardableResult
private func check(_ h: AudioHealth, _ now: Double, written: [CaptureTrack: Double] = [:], startPts: Double? = nil,
                   access: [CaptureTrack: String] = [:], stalled: Bool = false, systemStalled: Bool = false,
                   dropped: [CaptureTrack: Int] = [:], writeFailures: [CaptureTrack: String] = [:])
    -> (opened: [AudioIncident], closed: [AudioIncident]) {
    h.check(now, written: written, startPts: startPts, access: access, stalled: stalled, systemStalled: systemStalled,
            dropped: dropped, writeFailures: writeFailures)
}

/// Chunks of `n` samples declared at `declared` Hz, arriving every 10 ms of the clock from `t0` to `t1`;
/// their stamps advance `stampRate` times as fast as the samples say.
private func deliver(_ h: AudioHealth, _ track: CaptureTrack, _ t0: Double, _ t1: Double, stampRate: Double = 1,
                     declared: Double = 48_000, n: Int = 480, samples: [Float]? = nil) {
    var k = 0
    while t0 + Double(k) * 0.01 < t1 {
        let t = t0 + Double(k) * 0.01
        let pts = t0 + Double(k) * (Double(n) / declared) * stampRate
        h.chunk(track, now: t, pts: pts, samples: samples ?? Array(tone[..<n]), rate: declared)
        k += 1
    }
}

private func label(_ p: [AudioIncident]) -> [String] { p.map { "\($0.kind)/\($0.track)" } }

/// numpy.random.default_rng stand-in (SplitMix64).
private struct Rng {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

@Suite struct AudioHealthTests {
    @Test func steadyDeliveryAtTheDeclaredRateIsHealthy() {
        let h = health()
        deliver(h, .system, 100, 130)
        let (opened, closed) = check(h, 130)
        #expect(opened.isEmpty && closed.isEmpty)
    }

    @Test func stampsTwiceAsFastAsTheSamplesIsAWrongSpeedThatEndsOnceFixed() {
        // The 2026-10-29 bug: AirPods at 24 kHz read as 48 kHz.
        let h = health()
        deliver(h, .system, 100, 110)
        deliver(h, .system, 110, 117, stampRate: 2, n: 240)
        var opened: [AudioIncident] = []
        for second in 111..<118 { opened += check(h, Double(second)).opened }
        #expect(label(opened) == ["speed/system"])
        #expect(opened[0].start == 110.0)  // dated from its first bad second
        // Fixed at 117: the warning goes once the last seconds are clean, and it ended when the speed was right again.
        var closed: [AudioIncident] = []
        for second in 117..<130 {
            deliver(h, .system, Double(second), Double(second) + 1)
            closed += check(h, Double(second) + 1).closed
        }
        #expect(closed.map(\.kind) == ["speed"])
        #expect(closed[0].end == 117.0)
        #expect(h.openProblems().isEmpty)
    }

    @Test func aSecondOrTwoOfWrongSpeedAfterASwitchIsNotAWarning() {
        // AirPods switching to HFP: until the route watcher reads the new rate (up to a second) the
        // stamps run fast. That alone is no incident.
        let h = health()
        for second in 100..<140 {
            if second == 120 {
                deliver(h, .system, 120, 121.5, stampRate: 2, n: 240)
                deliver(h, .system, 121.5, 122)
            } else if second != 121 {
                deliver(h, .system, Double(second), Double(second) + 1)
            }
            #expect(check(h, Double(second) + 1).opened.isEmpty)
        }
    }

    @Test func pausesAndLostCyclesAreNotAWrongSpeed() {
        // The tap is quiet while nothing plays; Bluetooth stalls for 30-80 ms; an IO cycle gets lost now and then.
        let h = health()
        var rng = Rng(state: 1)
        var t = 100.0, pts = 100.0
        while t < 160 {
            if rng.next() < 0.005 {
                pts += 0.01  // a lost cycle
            } else if rng.next() < 0.01 {
                pts += rng.uniform(0.03, 0.08)  // a stall
            } else if rng.next() < 0.002 {
                pts += 3.0  // nothing played for a while
            }
            h.chunk(.system, now: t, pts: pts + rng.uniform(-0.005, 0.005), samples: tone, rate: 48_000)
            t += 0.01
            pts += 0.01
            if abs(t - t.rounded()) < 0.005 { #expect(check(h, t).opened.isEmpty, "at \(t)") }
        }
    }

    @Test func accessAndDeviceProblemsOpenOnlyOnceTheyLast() {
        let h = health(started: 1000)
        var r = check(h, 1010, access: [.mic: "device"])
        #expect(r.opened.isEmpty && r.closed.isEmpty)
        r = check(h, 1011, access: [:])  // a blip while AirPods switch
        #expect(r.opened.isEmpty && r.closed.isEmpty)
        check(h, 1020, access: [.mic: "access", .system: "device"])
        let opened = check(h, 1024.5, access: [.mic: "access", .system: "device"]).opened
        #expect(opened.map { "\($0.id)/\($0.kind)/\($0.track)/\($0.start)" } == ["1/access/mic/20.0", "2/device/system/20.0"])
        // Wall-clock time of when it began, not of when it was believed.
        #expect(opened[0].at == "2026-10-29T12:05:55+01:00")  // 12:06:00 minus 4.5 s, seconds truncated
        let closed = check(h, 1030, access: [:]).closed
        #expect(closed.map { "\($0.kind)/\($0.end!)" } == ["access/30.0", "device/30.0"])
    }

    @Test func closeAllEndsWhatIsOpen() {
        let h = health(started: 1000)
        check(h, 1040, stalled: true)
        h.closeAll(1050)
        #expect(h.problems().map { "\($0.kind)/\($0.start)/\($0.end!)" } == ["stalled/40.0/50.0"])
    }

    @Test func trackLengthAgainstTheClock() {
        let h = health()
        h.chunk(.mic, now: 100.004, pts: 100.0, samples: tone, rate: 48_000)  // arrives 4 ms after its stamp
        for (now, written) in [(130.0, 29.99), (140.0, 39.9)] {
            h.chunk(.mic, now: now, pts: now - 0.004, samples: tone, rate: 48_000)
            #expect(check(h, now, written: [.mic: written], startPts: 100).opened.isEmpty)
        }
        h.chunk(.mic, now: 150, pts: 150 - 0.004, samples: tone, rate: 48_000)
        let opened = check(h, 150, written: [.mic: 50 - HealthThreshold.lengthTolerance - 0.5], startPts: 100).opened
        #expect(label(opened) == ["length/mic"])
    }

    @Test func aTrackThatIsNotDeliveringIsNotMeasured() {
        // System audio is quiet while nothing plays; its file catches up when sound comes back.
        let h = health()
        h.chunk(.system, now: 100, pts: 100, samples: tone, rate: 48_000)
        #expect(check(h, 200, written: [.system: 0.01], startPts: 100).opened.isEmpty)
    }

    @Test func aSilentMicIsASoftHintShownOnceAndAnIncidentOnlyWhenItLastsToTheEnd() {
        let h = health()
        for t in 0..<200 { h.chunk(.mic, now: Double(t), pts: Double(t), samples: zeros, rate: 48_000) }  // nobody plays anything
        let r = check(h, 200)
        #expect(r.opened.isEmpty && r.closed.isEmpty && h.hints().isEmpty)
        for t in 200..<262 {
            h.chunk(.mic, now: Double(t), pts: Double(t), samples: zeros, rate: 48_000)
            h.chunk(.system, now: Double(t), pts: Double(t), samples: tone, rate: 48_000)
        }
        let during = check(h, 261)
        #expect(during.opened.isEmpty && during.closed.isEmpty)  // never an incident while it lasts
        #expect(h.hints().map { "\($0.kind)/\($0.track)" } == ["silent/mic"])
        h.chunk(.mic, now: 262, pts: 262, samples: tone, rate: 48_000)  // unmuted
        check(h, 262)
        #expect(h.hints().isEmpty && h.problems().isEmpty)
        for t in 263..<400 {  // muted again: no second hint
            h.chunk(.mic, now: Double(t), pts: Double(t), samples: zeros, rate: 48_000)
            h.chunk(.system, now: Double(t), pts: Double(t), samples: tone, rate: 48_000)
        }
        check(h, 399)
        #expect(h.hints().isEmpty)
        h.closeAll(400)  // silent to the end: that is a problem worth keeping
        #expect(h.problems().map { "\($0.kind)/\($0.track)/\($0.start)/\($0.end!)" } == ["silent/mic/263.0/400.0"])
    }

    @Test func aStalledMicrophoneIsAnIncidentThatEndsWhenItResumes() {
        let h = health()
        #expect(label(check(h, 40, stalled: true).opened) == ["stalled/mic"])
        #expect(check(h, 41, stalled: false).closed.map { "\($0.kind)/\($0.end!)" } == ["stalled/41.0"])
    }

    @Test func systemAudioThatNeverArrivesIsAStalledIncident() {
        // The tap delivered nothing for a whole call and nothing warned.
        let h = health()
        #expect(label(check(h, 31, systemStalled: true).opened) == ["stalled/system"])
        deliver(h, .system, 31, 32)
        #expect(check(h, 32).closed.map { "\($0.kind)/\($0.track)/\($0.end!)" } == ["stalled/system/32.0"])
    }

    @Test func wallClockTimeIsTakenWhenAnIncidentOpens() {
        let wall = Locked(wall0)
        let h = health(wall: { wall.get })
        wall.with { $0 = wall0.addingTimeInterval(8 * 60) }  // e.g. after a sleep the monotonic clock did not see
        let opened = check(h, 60, stalled: true).opened
        #expect(opened[0].at == "2026-10-29T12:14:00+01:00")
    }

    @Test func aShortStretchOfWrongSpeedStartsWhereItBeganAndEndsAfterIt() {
        // 5 s of audio 10 % fast: dated from its first bad second, and never ends before it starts.
        let h = health()
        for second in 100..<130 {
            let fast = (105..<110).contains(second)
            deliver(h, .system, Double(second), Double(second) + 1, stampRate: fast ? 1 / 1.1 : 1)
            check(h, Double(second) + 1)
        }
        let problems = h.problems()
        #expect(problems.map { "\($0.kind)/\($0.start)/\($0.end!)" } == ["speed/105.0/110.0"])
        #expect(problems.allSatisfy { $0.end! >= $0.start })
    }

    @Test func exactWholeCycleJumpsAreLostCyclesUnlessTheyAreTheRule() {
        let h = health()
        var rng = Rng(state: 3)
        var pts = 100.0
        for k in 0..<3000 {  // 30 s, 5 % lost cycles, exact stamps
            if rng.next() < 0.05 { pts += 0.01 }
            h.chunk(.system, now: 100 + Double(k) * 0.01, pts: pts, samples: tone, rate: 48_000)
            pts += 0.01
            if k % 100 == 99 { #expect(check(h, 100 + Double(k + 1) * 0.01).opened.isEmpty) }
        }
    }

    // MARK: new in Swift: lost buffers and write failures

    @Test func droppedBuffersAreAnIncidentThatEndsAfterFiveQuietSeconds() {
        let h = health(started: 1000)
        #expect(check(h, 1001, dropped: [.mic: 0]).opened.isEmpty)
        #expect(label(check(h, 1002, dropped: [.mic: 3]).opened) == ["dropped/mic"])
        #expect(check(h, 1003, dropped: [.mic: 3]).closed.isEmpty)  // quiet again, but not for 5 s yet
        #expect(check(h, 1004, dropped: [.mic: 5]).closed.isEmpty)  // more were lost: still open
        #expect(h.problems().count == 1)
        #expect(check(h, 1005, dropped: [.mic: 5]).closed.isEmpty)
        let closed = check(h, 1010, dropped: [.mic: 5]).closed
        #expect(closed.map { "\($0.kind)/\($0.start)/\($0.end!)" } == ["dropped/2.0/5.0"])
    }

    @Test func aFailingWriteIsAnIncidentThatEndsWhenWritingWorksAgain() {
        let h = health(started: 1000)
        let opened = check(h, 1005, writeFailures: [.system: "No space left on device"]).opened
        #expect(label(opened) == ["write/system"] && opened[0].start == 5.0)
        #expect(check(h, 1006, writeFailures: [.system: "No space left on device"]).opened.isEmpty)
        #expect(check(h, 1008, writeFailures: [:]).closed.map { "\($0.kind)/\($0.end!)" } == ["write/8.0"])
    }

    @Test func wordsForEveryKind() {
        #expect(ProblemWords.warning(kind: "speed", track: "system") == "System audio is playing at the wrong speed; Palaver is correcting it")
        #expect(ProblemWords.warning(kind: "length", track: "mic") == "Microphone is out of step with the clock")
        #expect(ProblemWords.warning(kind: "stalled", track: "mic") == "No microphone audio is arriving")
        #expect(ProblemWords.warning(kind: "access", track: "mic") == "Microphone access was turned off — allow it in System Settings → Privacy & Security")
        #expect(ProblemWords.warning(kind: "device", track: "system") == "System audio couldn't be rebuilt; Palaver keeps trying")
        #expect(ProblemWords.happened(kind: "silent", track: "mic") == "microphone sent nothing — muted?")
        #expect(ProblemWords.happened(kind: "write", track: "system") == "system audio could not be written to disk")
        #expect(ProblemWords.warning(kind: "dropped", track: "system") == "System audio is losing audio: the recorder cannot keep up")
        #expect(ProblemWords.happened(kind: "dropped", track: "mic") == "microphone lost audio")
        #expect(ProblemWords.warning(kind: "nonsense", track: "mic") == "Audio problem")
        #expect(ProblemWords.happened(kind: "nonsense", track: "mic") == nil)
    }
}
