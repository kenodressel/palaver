// Echo cancellation through the linked WebRTC library (tests/test_aec.py under its names): synthetic tracks only.
import Accelerate
import Foundation
import PalaverDomain
@testable import PalaverWorker
import Testing

/// Seeded normal numbers (SplitMix64 and Box–Muller): the tests' noise, the same on every run.
private struct Noise {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func uniform() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
    mutating func normal() -> Double {
        let u = max(uniform(), 1e-300), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

private func clip(_ x: Double) -> Int16 { Int16(max(-32768, min(32767, x.rounded(.towardZero)))) }

private func sine(_ freq: Double, _ seconds: Double, amp: Double = 8000) -> [Int16] {
    (0..<Int(seconds * 16_000)).map { clip(amp * sin(2 * .pi * freq * Double($0) / 16_000)) }
}

private func rms(_ s: ArraySlice<Int16>) -> Double {
    s.isEmpty ? 0 : (s.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(s.count)).squareRoot()
}

/// Broadband bursts with pauses: what the far end sends, roughly (test_aec.py `_speechlike`).
private func speechlike(_ seconds: Double, seed: UInt64 = 0) -> [Int16] {
    var noise = Noise(seed)
    let n = Int(seconds * 16_000)
    let talking = (0..<(n / 1600 + 1)).map { _ in noise.uniform() > 0.3 }
    let raw = (0..<n).map { _ in noise.normal() }
    let window = (0..<8).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / 7) }  // np.hanning(8)
    return (0..<n).map { i in
        var acc = 0.0
        for (j, w) in window.enumerated() {
            let k = i + 3 - j  // np.convolve(..., "same")
            if k >= 0 && k < n { acc += raw[k] * w }
        }
        return clip(acc * (talking[i / 1600] ? 4000 : 0))
    }
}

/// The far end through a room (direct path and two reflections), heard `delayMs` later; a negative delay is heard
/// before its reference.
private func echo(_ far: [Int16], delayMs: Double) -> [Int16] {
    let taps: [(Int, Double)] = [(0, 0.5), (40, -0.2), (120, 0.1)]
    let n = far.count
    var wet = [Double](repeating: 0, count: n)
    for i in 0..<n { for (lag, g) in taps where i - lag >= 0 { wet[i] += g * Double(far[i - lag]) } }
    let d = Int(delayMs * 16)
    return (0..<n).map { i in
        let k = i - d
        return k >= 0 && k < n ? clip(wet[k]) : 0
    }
}

private func reductionDB(_ mic: [Int16], _ out: [Int16], skip: Int = 6 * 16_000) -> Double {
    20 * log10(rms(mic[skip...]) / max(rms(out[skip...]), 1e-3))
}

@Suite struct AecTests {
    private func run(mic: [Int16], system: [Int16]) throws -> (out: [Int16], rate: Int) {
        let t = Temp("aec"); defer { t.remove() }
        try Wav16.write(mic, rate: 16_000, to: t.file("mic_raw.wav"))
        try Wav16.write(system, rate: 16_000, to: t.file("system.wav"))
        try Aec.process(micRaw: t.file("mic_raw.wav"), system: t.file("system.wav"), out: t.file("mic.wav"))
        return (try Wav16.read(t.file("mic.wav")), try Wav16.info(t.file("mic.wav")).rate)
    }

    @Test func test_silent_mic_with_audible_system_yields_silent_output() throws {
        let system = sine(440, 3)
        let mic = system.map { clip(Double($0) * 0.5) }  // attenuated bleed, no near-end speech
        let (out, rate) = try run(mic: mic, system: system)
        #expect(rate == 16_000)
        #expect(rms(out[8000...]) < 0.2 * rms(mic[8000...]))
    }

    @Test func test_silent_system_preserves_near_end_speech() throws {
        let mic = sine(220, 3)
        let (out, _) = try run(mic: mic, system: [Int16](repeating: 0, count: mic.count))
        #expect(rms(out[8000...]) > 0.3 * rms(mic[8000...]))
    }

    @Test func test_output_length_matches_input() throws {
        let silence = [Int16](repeating: 0, count: 40_000)
        let (out, rate) = try run(mic: silence, system: silence)
        #expect(rate == 16_000)
        #expect(abs(out.count - silence.count) < 160)
    }

    @Test func test_mic_longer_than_system_preserves_post_overlap_tail() throws {
        let mic = sine(440, 2, amp: 4000) + sine(880, 3, amp: 8000)
        let system = sine(220, 2, amp: 8000)
        let (out, _) = try run(mic: mic, system: system)
        #expect(abs(out.count - mic.count) < 160)
        #expect(Array(out[32_000...]) == Array(mic[32_000...]))
        #expect(rms(out[..<32_000]) > 100)
    }

    @Test func test_a_system_track_that_got_nothing_passes_the_mic_through() throws {
        let mic = sine(440, 2, amp: 4000)
        let (out, _) = try run(mic: mic, system: [])
        #expect(out == mic)
    }

    @Test func test_stream_in_blocks_matches_one_pass() throws {
        var noise = Noise(0)
        let system = (0..<48_000).map { _ in clip(noise.normal() * 3000) }
        let mic = (0..<system.count).map { i in clip(Double(system[(i - 400 + system.count) % system.count] / 4) + noise.normal() * 500) }
        let one = try AecStream()
        let whole = try one.process(mic: mic, system: system)
        one.close()
        let blocks = try AecStream()
        let cuts = [0, 1234, 5000, 5001, 31_337, mic.count]
        var parts: [Int16] = []
        for (a, b) in zip(cuts, cuts.dropFirst()) {
            parts += try blocks.process(mic: Array(mic[a..<b]), system: Array(system[a..<b]))
        }
        #expect(blocks.pending == Aec.LEAD_SAMPLES + mic.count % Aec.FRAME_SAMPLES)  // the lead and a partial frame
        blocks.close()
        #expect(parts == whole)
        #expect(throws: WorkerError.self) { try blocks.process(mic: [1], system: [1]) }  // closed
        #expect(throws: WorkerError.self) { try AecStream().process(mic: [1, 2], system: [1]) }
    }

    @Test func aWholeFileLongerThanABlockComesOutAsOnePassWould() throws {
        // Aec.process feeds the tracks in blocks (no whole-track copies): the same output as one pass, partial last
        // frame silenced, the tail after the system track verbatim.
        var noise = Noise(7)
        let n = Aec.BLOCK_SAMPLES * 2 + 1234
        let system = (0..<n).map { _ in clip(noise.normal() * 3000) }
        let mic = (0..<(n + 800)).map { i in i < n ? clip(Double(system[(i + n - 300) % n] / 4) + noise.normal() * 500) : 77 }
        let one = try AecStream()
        var expected = try one.process(mic: Array(mic[..<n]), system: system)
        one.close()
        expected += [Int16](repeating: 0, count: n - expected.count) + mic[n...]
        let (out, _) = try run(mic: mic, system: system)
        #expect(out == expected)
    }

    @Test func test_a_kill_while_writing_leaves_no_mic_wav_a_retry_would_trust() throws {
        let t = Temp("aec"); defer { t.remove() }
        try Wav16.write(sine(440, 1), rate: 16_000, to: t.file("mic_raw.wav"))
        try Wav16.write(sine(440, 1), rate: 16_000, to: t.file("system.wav"))
        // The write aside fails half-way (here: its file can't be made): no mic.wav for a retry to trust.
        try FileManager.default.createDirectory(at: t.file("mic.wav.tmp"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try Aec.process(micRaw: t.file("mic_raw.wav"), system: t.file("system.wav"), out: t.file("mic.wav"))
        }
        #expect(!FileManager.default.fileExists(atPath: t.file("mic.wav").path))
        try FileManager.default.removeItem(at: t.file("mic.wav.tmp"))
        try Aec.process(micRaw: t.file("mic_raw.wav"), system: t.file("system.wav"), out: t.file("mic.wav"))
        #expect(try Wav16.info(t.file("mic.wav")).frames == 16_000)
        let left = try FileManager.default.contentsOfDirectory(atPath: t.url.path).filter { $0.hasPrefix("mic.wav") }
        #expect(left == ["mic.wav"])
    }

    @Test(arguments: [-5.0, 0, 3, 30])
    func test_echo_is_cancelled_even_when_it_reaches_the_mic_with_its_reference(delayMs: Double) throws {
        let far = speechlike(12)
        let mic = echo(far, delayMs: delayMs)
        let stream = try AecStream()
        let out = try stream.process(mic: mic, system: far)
        stream.close()
        #expect(reductionDB(Array(mic[..<out.count]), out) > 35)
    }

    @Test func test_looking_at_the_mic_late_does_not_delay_what_comes_out() throws {
        let near = speechlike(4, seed: 1)
        let stream = try AecStream()
        let out = try stream.process(mic: near, system: [Int16](repeating: 0, count: near.count))
        stream.close()
        let a = near[..<out.count].map(Double.init), b = out.map(Double.init)
        let n = b.count - 800
        var best = (lag: 0, score: -Double.infinity)
        for k in -400...400 {
            var score = 0.0
            a.withUnsafeBufferPointer { pa in
                b.withUnsafeBufferPointer { pb in vDSP_dotprD(pa.baseAddress! + 400, 1, pb.baseAddress! + 400 + k, 1, &score, vDSP_Length(n)) }
            }
            if score > best.score { best = (k, score) }
        }
        #expect(best.lag == 208)
    }

    @Test func aRateOtherThan16kIsRefused() throws {
        let t = Temp("aec"); defer { t.remove() }
        try Wav16.write([0, 0], rate: 48_000, to: t.file("mic_raw.wav"))
        try Wav16.write([0, 0], rate: 16_000, to: t.file("system.wav"))
        #expect(throws: WorkerError.self) {
            try Aec.process(micRaw: t.file("mic_raw.wav"), system: t.file("system.wav"), out: t.file("mic.wav"))
        }
    }
}
