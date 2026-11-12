// The voice-activity tier of the live pipeline (tests/test_voice_activity.py, #42): who talks now, from levels alone,
// with and without headphones. Synthetic tracks only: speech is noise shaped like syllables; with speakers, the
// system track reaches the mic as a delayed, quieter copy (the echo). Nothing is played or recorded.
import Accelerate
import Darwin
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

private let SR = 16_000

/// Seeded normal noise (SplitMix64, Box–Muller): the same tracks every run.
private final class Noise {
    private var state: UInt64
    private var spare: Double?
    init(_ seed: UInt64) { state = seed }

    private func uniform() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return (Double(z >> 11) + 0.5) / Double(1 << 53)
    }

    func normal() -> Double {
        if let s = spare { spare = nil; return s }
        let r = sqrt(-2 * log(uniform())), a = 2 * Double.pi * uniform()
        spare = r * sin(a)
        return r * cos(a)
    }
}

/// The synthetic tracks of one test, from its own seeded noise (tests run in parallel; each is the same every run).
private final class Gen {
    private let rng = Noise(7)

    /// Noise with a 4 Hz syllable rhythm and a 0.3 s pause every 2.5 s (between phrases), at `dbfs` while it sounds.
    func speech(_ seconds: Double, dbfs: Double = -24) -> [Double] {
        let n = Int(seconds * Double(SR))
        var x = [Double](repeating: 0, count: n)
        var power = 0.0, sounding = 0
        for i in 0..<n {
            let t = Double(i) / Double(SR)
            let envelope = (0.55 + 0.45 * sin(2 * Double.pi * 4 * t)) * (t.truncatingRemainder(dividingBy: 2.8) < 2.5 ? 1 : 0)
            x[i] = rng.normal() * envelope
            if envelope > 0 { power += x[i] * x[i]; sounding += 1 }
        }
        guard sounding > 0 else { return x }
        let scale = pow(10, dbfs / 20) * 32768 / sqrt(power / Double(sounding))
        return x.map { $0 * scale }
    }

    /// A quiet room's noise on the mic.
    func room(_ n: Int, dbfs: Double = -62) -> [Double] {
        let scale = pow(10, dbfs / 20) * 32768
        return (0..<n).map { _ in rng.normal() * scale }
    }

    func normal() -> Double { rng.normal() }

    /// (mic, system) as int16. `echoDb`: how loud the others come back on the mic, relative to the system track (nil:
    /// headphones, no echo).
    func tracks(_ me: [[Double]], _ others: [[Double]], echoDb: Double?, delay: Double = 0.08) -> (mic: [Int16], system: [Int16]) {
        var system = Array(others.joined()), mine = Array(me.joined())
        let n = max(system.count, mine.count)
        system += [Double](repeating: 0, count: n - system.count)
        mine += [Double](repeating: 0, count: n - mine.count)
        var mic = zip(mine, room(n)).map(+)
        if let echoDb {
            let shift = Int(delay * Double(SR)), gain = pow(10, echoDb / 20)
            for i in shift..<n { mic[i] += system[i - shift] * gain }
        }
        return (clip(mic), clip(system))
    }
}

private func quiet(_ seconds: Double) -> [Double] { [Double](repeating: 0, count: Int(seconds * Double(SR))) }

private func clip(_ x: [Double]) -> [Int16] { x.map { Int16(max(-32768, min(32767, $0.rounded(.toNearestOrEven)))) } }

private func feed(_ va: VoiceActivity, _ mic: [Int16], _ system: [Int16], chunk: Double = 0.25) {
    let step = Int(chunk * Double(SR))
    for i in stride(from: 0, to: mic.count, by: step) {
        va.add(mic: Array(mic[i..<min(i + step, mic.count)]), system: Array(system[min(i, system.count)..<min(i + step, system.count)]))
    }
}

private func number(_ v: JSONValue?) -> Double { v?.doubleValue ?? .nan }

private func near(_ v: JSONValue?, _ expected: Double, _ tolerance: Double) -> Bool { abs(number(v) - expected) <= tolerance }

/// The recorder's `<track>.part`: a placeholder header, chunks written at their offset (a gap before one is silence).
private final class PartTrack {
    private let url: URL
    private(set) var framesWritten = 0
    init(_ final: URL) {
        url = URL(fileURLWithPath: final.path + ".part")
        FileManager.default.createFile(atPath: url.path, contents: Data(Wav16.header(dataBytes: 0, rate: SR, channels: 1)))
    }
    func write(at offset: Int, _ samples: [Int16]) {
        guard offset >= framesWritten else { return }
        let h = try! FileHandle(forWritingTo: url)
        defer { try! h.close() }
        h.seekToEndOfFile()
        h.write(Data(count: 2 * (offset - framesWritten)))
        h.write(samples.withUnsafeBytes { Data($0) })
        framesWritten = offset + samples.count
    }
}

private final class Recording {
    let paths: RecordingPaths
    let mic: PartTrack, system: PartTrack
    init(_ folder: URL) {
        paths = RecordingPaths(folder)
        mic = PartTrack(paths.micRawWav)
        system = PartTrack(paths.systemWav)
    }
    /// The next chunk of both tracks. The Process Tap writes nothing while nothing plays; the gap is filled with zeros
    /// when it plays again.
    func write(_ micChunk: [Int16], _ systemChunk: [Int16], systemSilent: Bool = false) {
        let at = mic.framesWritten
        mic.write(at: at, micChunk)
        if !systemSilent { system.write(at: at, systemChunk) }
    }
}

private final class Clock: @unchecked Sendable {
    var now = 0.0
}

@Suite struct VoiceActivityTests {
    // MARK: who talks

    @Test(arguments: [nil, -20.0, -10.0, -3.0] as [Double?])
    func test_the_others_echo_on_the_mic_is_not_me(_ echoDb: Double?) {
        let g = Gen()
        // Speakers: the others come back on the mic, as loud as the system track at worst. That is never the user.
        let (mic, system) = g.tracks([quiet(90)], [g.speech(30), quiet(2), g.speech(58)], echoDb: echoDb)
        let va = VoiceActivity()
        feed(va, mic, system)
        let s = va.snapshot()
        #expect(number(s["me"]) < 1.0)
        #expect(number(s["others"]) > 80)
        #expect(s["share"] == .double(0))
    }

    @Test(arguments: [nil, -12.0] as [Double?])
    func test_turns_give_the_talk_share(_ echoDb: Double?) {
        let g = Gen()
        let (mic, system) = g.tracks([g.speech(30), quiet(20), g.speech(10), quiet(40)], [quiet(30), g.speech(20), quiet(10), g.speech(40)],
                                   echoDb: echoDb)
        let va = VoiceActivity()
        feed(va, mic, system)
        let s = va.snapshot()
        #expect(near(s["me"], 40, 2))
        #expect(near(s["others"], 60, 2))
        #expect(near(s["share"], 0.4, 0.03))
    }

    @Test func test_who_speaks_now() {
        let g = Gen()
        let va = VoiceActivity()
        var (mic, system) = g.tracks([quiet(5)], [g.speech(5)], echoDb: -12)
        feed(va, mic, system)
        #expect(va.snapshot()["speaking"] == .string("others"))
        (mic, system) = g.tracks([g.speech(3)], [quiet(3)], echoDb: -12)
        feed(va, mic, system)
        #expect(va.snapshot()["speaking"] == .string("me"))
        (mic, system) = g.tracks([quiet(2)], [quiet(2)], echoDb: -12)
        feed(va, mic, system)
        #expect(va.snapshot()["speaking"] == .null)
    }

    @Test func test_talking_over_the_others_counts_with_headphones() {
        let g = Gen()
        // Double talk: without echo the mic is the user's alone.
        let (mic, system) = g.tracks([quiet(10), g.speech(10)], [g.speech(12), quiet(8)], echoDb: nil)
        let va = VoiceActivity()
        feed(va, mic, system)
        let s = va.snapshot()
        #expect(s["interruptions"] == .object([("by_me", .int(1)), ("of_me", .int(0))]))
        #expect(near(s["me"], 10, 1))
    }

    @Test func test_talking_over_the_others_counts_with_speakers_when_clearly_louder_than_the_echo() {
        let g = Gen()
        let (mic, system) = g.tracks([quiet(20), g.speech(10, dbfs: -20)], [g.speech(22), quiet(8)], echoDb: -24)
        let va = VoiceActivity()
        feed(va, mic, system)
        #expect(va.snapshot()["interruptions"]?["by_me"] == .int(1))
    }

    @Test func test_being_interrupted() {
        let g = Gen()
        // With speakers, once the echo's level is learned (the others talked first), the user's voice over theirs
        // still counts.
        let (mic, system) = g.tracks([quiet(10.5), g.speech(10), quiet(5)], [g.speech(10), quiet(8), g.speech(7.5)], echoDb: -15)
        let va = VoiceActivity()
        feed(va, mic, system)
        #expect(va.snapshot()["interruptions"] == .object([("by_me", .int(0)), ("of_me", .int(1))]))
    }

    @Test func test_a_short_overlap_is_no_interruption() {
        let g = Gen()
        let (mic, system) = g.tracks([g.speech(10), quiet(10)], [quiet(9.8), g.speech(10)], echoDb: nil)  // starts as I stop
        let va = VoiceActivity()
        feed(va, mic, system)
        #expect(va.snapshot()["interruptions"] == .object([("by_me", .int(0)), ("of_me", .int(0))]))
    }

    @Test func test_a_bluetooth_delay_still_reads_as_echo() {
        let g = Gen()
        let (mic, system) = g.tracks([quiet(40)], [g.speech(40)], echoDb: -8, delay: 0.3)
        let va = VoiceActivity()
        feed(va, mic, system)
        #expect(number(va.snapshot()["me"]) < 1.0)
    }

    @Test func test_a_noisy_mic_is_not_speech() {
        let g = Gen()
        // A fan or a loud room: the floor follows it.
        let n = 60 * SR
        let va = VoiceActivity()
        feed(va, clip(g.room(n, dbfs: -40)), [Int16](repeating: 0, count: n))
        #expect(number(va.snapshot()["me"]) < 3.0)
    }

    // MARK: monologues, the window

    @Test func test_the_current_monologue_runs_across_pauses() {
        let g = Gen()
        var parts: [[Double]] = []
        for _ in 0..<12 { parts += [g.speech(9), quiet(1.5)] }  // breathing pauses
        let (mic, system) = g.tracks(parts, [quiet(Double(parts.joined().count) / Double(SR))], echoDb: -12)
        let va = VoiceActivity()
        feed(va, mic, system)
        let s = va.snapshot()
        #expect(near(s["monologue"], 124.5, 3))
        #expect(number(s["longest"]) >= number(s["monologue"]))
    }

    @Test func test_someone_else_talking_ends_the_monologue_but_a_backchannel_does_not() {
        let g = Gen()
        let (mic, system) = g.tracks([g.speech(60), quiet(0.8), g.speech(30), quiet(5), g.speech(20)],
                                   [quiet(60), g.speech(0.6), quiet(30.2), g.speech(4), quiet(21)], echoDb: -12)
        let va = VoiceActivity()
        feed(va, mic, system)
        let s = va.snapshot()
        #expect(near(s["longest"], 90.8, 2))
        #expect(near(s["monologue"], 20, 2))
    }

    @Test func test_the_monologue_ends_after_a_long_pause() {
        let g = Gen()
        let (mic, system) = g.tracks([g.speech(30), quiet(10)], [quiet(40)], echoDb: nil)
        let va = VoiceActivity()
        feed(va, mic, system)
        #expect(va.snapshot()["monologue"] == .int(0))
    }

    @Test func test_talk_share_is_over_the_last_window() {
        let g = Gen()
        // The window is 10 minutes; a one-minute one says the same with a tenth of the audio.
        let (mic, system) = g.tracks([g.speech(30), quiet(60)], [quiet(30), g.speech(60)], echoDb: -12)
        let va = VoiceActivity(window: 60, keep: 90)
        feed(va, mic, system, chunk: 1.0)
        let s = va.snapshot()
        #expect(near(s["window"], 60, 1))
        #expect(near(s["me"], 0, 1))
        #expect(near(s["share"], 0, 0.01))
    }

    @Test func test_no_share_before_anyone_said_much() {
        let g = Gen()
        let (mic, system) = g.tracks([g.speech(5)], [quiet(5)], echoDb: nil)
        let va = VoiceActivity()
        feed(va, mic, system)
        #expect(va.snapshot()["share"] == .null)
    }

    // MARK: wait time after my question

    @Test func test_wait_time_after_my_question() {
        let g = Gen()
        let (mic, system) = g.tracks([g.speech(8), quiet(12)], [quiet(11), g.speech(9)], echoDb: -12)
        let va = VoiceActivity()
        feed(va, mic, system)
        va.questions([7.9])
        let q = va.snapshot()["question"]
        #expect(q?["at"] == .double(7.9))
        #expect(near(q?["wait"], 3.1, 0.3))
        #expect(q?["answered"] == .bool(true) && q?["kept_talking"] == .bool(false))
    }

    @Test func test_still_waiting_for_an_answer() {
        let g = Gen()
        let (mic, system) = g.tracks([g.speech(8), quiet(5)], [quiet(13)], echoDb: -12)
        let va = VoiceActivity()
        feed(va, mic, system)
        va.questions([8.0])
        let q = va.snapshot()["question"]
        #expect(q?["answered"] == .bool(false))
        #expect(near(q?["wait"], 5, 0.3))
    }

    @Test func test_answering_my_own_question() {
        let g = Gen()
        let (mic, system) = g.tracks([g.speech(8), quiet(1), g.speech(5), quiet(3)], [quiet(15), g.speech(2)], echoDb: -12)
        let va = VoiceActivity()
        feed(va, mic, system)
        va.questions([8.0])
        let q = va.snapshot()["question"]
        #expect(q?["kept_talking"] == .bool(true))
        #expect(near(q?["wait"], 1.0, 0.3))
    }

    // MARK: what the status says

    @Test func test_talk_text() throws {
        func parse(_ text: String) throws -> JSONValue { try PythonJSON.parse(Data(text.utf8)) }
        #expect(VoiceActivity.talkText(try parse(#"{"speaking": "me", "share": 0.62, "window": 600, "monologue": 130, "me": 300, "others": 180, "interruptions": {"by_me": 0, "of_me": 0}, "question": null}"#))
                == "You 62 % of the last 10 min · talking for 2:10")
        #expect(VoiceActivity.talkText(try parse(#"{"speaking": "others", "share": 0.3, "window": 240, "monologue": 0, "me": 60, "others": 140, "interruptions": {"by_me": 2, "of_me": 0}, "question": {"at": 200, "wait": 2.5, "answered": true, "kept_talking": false}}"#))
                == "You 30 % of the last 4 min · 2 interruptions by you · answered 3 s after your question")
        #expect(VoiceActivity.talkText(try parse(#"{"speaking": null, "share": null, "window": 20, "monologue": 0, "me": 3, "others": 0, "interruptions": {"by_me": 0, "of_me": 0}, "question": {"at": 15, "wait": 4.2, "answered": false, "kept_talking": false}}"#))
                == "Quiet for 4 s since your question")
        #expect(VoiceActivity.talkText(nil) == nil)
    }

    // MARK: replaying a recording as it is written

    @Test func test_replay_at_simulated_speed() {
        let g = Gen()
        // Chunk by chunk as the recorder writes them: the monitor reads only what is new and keeps up within a second.
        let t = TempFolder("voice"); defer { t.remove() }
        let rec = Recording(t.url)
        let (mic, system) = g.tracks([g.speech(20), quiet(25)], [quiet(25), g.speech(20)], echoDb: -10)
        let clock = Clock()
        let monitor = VoiceMonitor(folder: t.url, clock: { clock.now })
        let step = Int(0.1 * Double(SR))
        var lags: [Double] = []
        for i in stride(from: 0, to: mic.count, by: step) {
            let chunk = i..<min(i + step, mic.count)
            rec.write(Array(mic[chunk]), Array(system[chunk]), systemSilent: !system[chunk].contains { $0 != 0 })
            clock.now += 0.1
            if i % (step * 5) == 0 {  // polled every half second
                _ = monitor.poll()
                lags.append(Double(chunk.upperBound) / Double(SR) - number(monitor.snapshot()?["until"]))
            }
        }
        _ = monitor.poll()
        let s = monitor.snapshot()
        #expect((lags.max() ?? 99) < 1.0)
        #expect(near(s?["me"], 20, 1.5))
        #expect(near(s?["others"], 20, 1.5))
        #expect(s?["speaking"] == .string("others"))
    }

    @Test func test_the_monitor_takes_my_questions_from_the_stream() throws {
        let g = Gen()
        let t = TempFolder("voice"); defer { t.remove() }
        let rec = Recording(t.url)
        let (mic, system) = g.tracks([g.speech(8), quiet(12)], [quiet(11), g.speech(9)], echoDb: -12)
        rec.write(mic, system)
        t.write("stream.json", #"{"mic": [{"start": 0.2, "end": 3.0, "text": "So that's the plan."}, {"start": 4.0, "end": 7.9, "text": "When can you send the numbers?"}]}"#)
        let monitor = VoiceMonitor(folder: t.url)
        _ = monitor.poll()
        let q = monitor.snapshot()?["question"]
        #expect(q?["at"] == .double(7.9) && q?["answered"] == .bool(true))
        #expect(near(q?["wait"], 3.1, 0.3))
        #expect(monitor.mine.map(\.text) == ["So that's the plan.", "When can you send the numbers?"])
    }

    @Test func test_a_monitor_started_late_reads_only_the_last_ten_minutes() {
        let t = TempFolder("voice"); defer { t.remove() }
        let rec = Recording(t.url)
        let n = 15 * 60 * SR
        rec.write([Int16](repeating: 0, count: n), [Int16](repeating: 0, count: n))
        let monitor = VoiceMonitor(folder: t.url)
        _ = monitor.poll()
        #expect(near(monitor.snapshot()?["until"], 15 * 60, 1))
        #expect(monitor.readSamples <= 10 * 60 * SR + SR)
    }

    @Test func test_a_room_echo_with_reverb_is_not_me() {
        let g = Gen()
        // Speakers in a room: the echo is smeared by a 300 ms reverb tail, not a clean copy.
        let system = g.speech(40) + quiet(1)
        let taps = Int(0.3 * Double(SR))
        var ir = (0..<taps).map { g.normal() * exp(-Double($0) / (0.06 * Double(SR))) }
        let norm = pow(10, -6.0 / 20) / sqrt(ir.reduce(0) { $0 + $1 * $1 })
        ir = ir.map { $0 * norm }
        // np.convolve(system, ir)[:len(system)], through Accelerate.
        let padded = [Double](repeating: 0, count: taps - 1) + system
        var echo = [Double](repeating: 0, count: system.count)
        padded.withUnsafeBufferPointer { a in
            ir.withUnsafeBufferPointer { f in
                vDSP_convD(a.baseAddress!, 1, f.baseAddress! + taps - 1, -1, &echo, 1, vDSP_Length(system.count), vDSP_Length(taps))
            }
        }
        let shift = Int(0.04 * Double(SR))
        let mic = zip([Double](repeating: 0, count: shift) + echo.dropLast(shift), g.room(system.count)).map(+)
        let va = VoiceActivity()
        feed(va, clip(mic), clip(system))
        #expect(number(va.snapshot()["me"]) < 1.0)
    }

    @Test func test_with_speakers_my_turns_between_theirs_still_count() {
        let g = Gen()
        // The usual call without headphones: turns, each side's voice on the mic.
        var me: [[Double]] = [], others: [[Double]] = []
        for _ in 0..<6 {
            me += [g.speech(8), quiet(6)]
            others += [quiet(8.3), g.speech(5.4), quiet(0.3)]
        }
        let (mic, system) = g.tracks(me, others, echoDb: -6)
        let va = VoiceActivity()
        feed(va, mic, system)
        let s = va.snapshot()
        #expect(near(s["me"], 48, 4))
        #expect(near(s["others"], 32.4, 3))
        #expect(s["interruptions"] == .object([("by_me", .int(0)), ("of_me", .int(0))]))
    }

    // MARK: review fixes

    @Test func test_a_track_flushed_late_is_not_read_as_silence() {
        let g = Gen()
        // The monitor reads only up to what the older track has written (less a margin), unless that track has
        // written nothing for over a second.
        let t = TempFolder("voice"); defer { t.remove() }
        let rec = Recording(t.url)
        let (mic, system) = g.tracks([quiet(10)], [g.speech(10)], echoDb: nil)
        rec.mic.write(at: 0, Array(mic[..<(5 * SR)]))
        rec.system.write(at: 0, Array(system[..<Int(4.5 * Double(SR))]))  // flushed half a second behind
        let monitor = VoiceMonitor(folder: t.url)
        _ = monitor.poll()
        #expect(number(monitor.snapshot()?["until"]) <= 4.5)
        rec.system.write(at: Int(4.5 * Double(SR)), Array(system[Int(4.5 * Double(SR))..<(5 * SR)]))
        _ = monitor.poll()
        #expect(near(monitor.snapshot()?["others"], 5, 0.5))
        rec.mic.write(at: 5 * SR, Array(mic[(5 * SR)...]))  // the call went quiet: the tap writes nothing
        _ = monitor.poll()
        #expect(near(monitor.snapshot()?["until"], 10 - VoiceMonitor.STALE_SECONDS, 0.2))
    }

    @Test func test_answered_questions_keep_their_wait_as_the_minutes_go_by() {
        let g = Gen()
        // Turns are kept 15 minutes; 90 seconds here, so two minutes later they are pruned.
        let va = VoiceActivity(window: 60, keep: 90)
        var (mic, system) = g.tracks([g.speech(8), quiet(12)], [quiet(11), g.speech(9)], echoDb: nil)
        feed(va, mic, system)
        va.questions([7.9])
        let first = va.snapshot()
        #expect(near(first["median_wait"], 3.1, 0.3))
        (mic, system) = g.tracks([g.speech(60), quiet(60)], [quiet(60), g.speech(60)], echoDb: nil)
        feed(va, mic, system, chunk: 1.0)  // two minutes later: the old turns are pruned
        va.questions([7.9])  // the stream lists it again
        let later = va.snapshot()
        #expect(later["median_wait"] == first["median_wait"] && later["questions"] == .int(1))
        #expect(va.waitingQuestions.isEmpty)
    }

    @Test func theMonitorThreadPollsUntilStopped() async throws {
        let g = Gen()
        let t = TempFolder("voice"); defer { t.remove() }
        let rec = Recording(t.url)
        let (mic, system) = g.tracks([g.speech(3)], [quiet(3)], echoDb: nil)
        rec.write(mic, system)
        let polled = Clock()
        let monitor = VoiceMonitor(folder: t.url, onPoll: { _ in polled.now += 1 })
        monitor.start(interval: 0.01)
        for _ in 0..<500 where monitor.snapshot() == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        monitor.stop(wait: 2)
        #expect(monitor.snapshot()?["speaking"] == .string("me"))
        let after = polled.now
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(polled.now == after && after >= 1)  // no polls once stopped
    }
}
