import Darwin
import Foundation
import Testing
@testable import PalaverCapture

/// Deterministic randomness (SplitMix64), so a failing run can be replayed.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A simulated recording, streamed chunk by chunk into a `TrackAligner` (nothing long is held in memory).
/// Clicks (0.9 for 10 ms) are "played" at the same host times on both tracks over a quiet noise floor;
/// afterwards each click must sit where its host time says, relative to the aligner's start_pts.
struct Simulation {
    struct MicSegment { var start: Double; var rate: Double; var chunk: Int }

    var seconds: Double
    var marks: [Double]
    /// The mic's devices over time; a later segment starting later than the previous one ends is a switch gap.
    var mic: [MicSegment] = [MicSegment(start: 0, rate: 48_000, chunk: 512)]
    var systemRate = 48_000.0
    var systemChunk = 480
    /// The tap's clock against host time: positive = its samples take longer (130 ppm measured on hardware).
    var systemDrift = 0.0
    var systemLoss = 0.0
    /// Nothing delivered for the last minute of every 5 (a tap that went quiet).
    var systemSilentMinutes = false
    /// PTS stamps off by up to ± this (seconds), uniformly, on both tracks.
    var jitter = 0.0
    var seed: UInt64 = 1

    static let t0 = 1_000.0  // host seconds at the start

    struct Result {
        var micErrors: [Double]  // seconds, found − expected, per click
        var systemErrors: [Double]
        var micFrames = 0, systemFrames = 0
        var reanchors: [CaptureTrack: Int] = [:]
        var peakRSSMB = 0.0, rssGrowthMB = 0.0
        var wallSeconds = 0.0
    }

    private static let noise: [Float] = {
        var g = SplitMix(state: 42)
        return (0..<4_096).map { _ in Float.random(in: -0.02...0.02, using: &g) }
    }()

    /// `n` samples from host time `t` on, `step` host seconds apart: noise with the clicks in.
    private func samples(_ k: Int, _ n: Int, t: Double, step: Double) -> [Float] {
        var x = [Float](repeating: 0, count: n)
        Self.noise.withUnsafeBufferPointer { noise in
            for i in 0..<n { x[i] = noise[(k + i) & 4_095] }
        }
        let end = t + Double(n) * step
        for m in marks where m + 0.01 > t && m < end {
            let lo = max(0, Int(((m - t) / step).rounded(.up)))
            let hi = min(n, Int(((m + 0.01 - t) / step).rounded(.up)))
            for i in lo..<max(lo, hi) { x[i] = 0.9 }
        }
        return x
    }

    func run(in dir: URL) throws -> Result {
        let started = Date()
        let rss0 = Self.rssMB()
        var result = Result(micErrors: [], systemErrors: [])
        let aligner = try TrackAligner(
            mic: TrackWriter(finalURL: dir.appendingPathComponent("mic_raw.wav")),
            system: TrackWriter(finalURL: dir.appendingPathComponent("system.wav")),
            onReanchor: { track, _ in result.reanchors[track, default: 0] += 1; return true })
        var g = SplitMix(state: seed)
        func stamp(_ host: Double) -> Int64 {
            ns(Self.t0 + host + (jitter > 0 ? Double.random(in: -jitter...jitter, using: &g) : 0))
        }
        let systemStep = (1 + systemDrift) / systemRate
        var systemK = 0
        var peak = rss0
        var chunks = 0
        for (s, segment) in mic.enumerated() {
            let end = s + 1 < mic.count ? min(mic[s + 1].start, seconds) : seconds
            let step = 1 / segment.rate
            var k = 0
            while segment.start + Double(k) * step < end {
                let host = segment.start + Double(k) * step
                let n = min(segment.chunk, Int(((end - host) / step).rounded(.up)))
                try aligner.handle(TimedChunk(pts: stamp(host), samples: samples(k, n, t: host, step: step),
                                              rate: segment.rate), track: .mic)
                k += n
                let micNow = segment.start + Double(k) * step
                // The system track catches up to the same host time.
                while Double(systemK) * systemStep < micNow {
                    let host = Double(systemK) * systemStep
                    let silent = systemSilentMinutes && Int(host) % 300 >= 240
                    let lost = systemLoss > 0 && Double.random(in: 0..<1, using: &g) < systemLoss
                    if !silent && !lost {
                        try aligner.handle(TimedChunk(pts: stamp(host),
                                                      samples: samples(systemK, systemChunk, t: host, step: systemStep),
                                                      rate: systemRate), track: .system)
                    }
                    systemK += systemChunk
                }
                chunks += 1
                if chunks % 20_000 == 0 { peak = max(peak, Self.rssMB()) }
            }
        }
        let lengths = try aligner.finish()
        result.micFrames = lengths.mic
        result.systemFrames = lengths.system
        peak = max(peak, Self.rssMB())
        result.peakRSSMB = peak
        result.rssGrowthMB = peak - rss0
        let start = aligner.startPts!
        let expected = marks.map { (Double(ns(Self.t0 + $0) - start) / 62_500) }
        result.micErrors = try Self.clicks(dir.appendingPathComponent("mic_raw.wav"), expected)
        result.systemErrors = try Self.clicks(dir.appendingPathComponent("system.wav"), expected)
        result.wallSeconds = Date().timeIntervalSince(started)
        return result
    }

    /// The onset of each click (first frame above 0.8 full scale, clicks > 1000 frames apart), minus where it belongs.
    private static func clicks(_ url: URL, _ expected: [Double]) throws -> [Double] {
        var onsets: [Int] = []
        var last = -10_000
        try scanWav(url) { start, block in
            for (i, v) in block.enumerated() where Double(v) > 0.8 * 32_767 {
                if start + i - last > 1_000 { onsets.append(start + i) }
                last = start + i
            }
        }
        guard onsets.count == expected.count else {
            Issue.record("\(url.lastPathComponent): \(onsets.count) clicks found, \(expected.count) played")
            return []
        }
        return zip(onsets, expected).map { (Double($0) - $1) / 16_000 }
    }

    static func rssMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
}

private func summary(_ name: String, _ r: Simulation.Result) -> String {
    func ms(_ e: [Double]) -> String {
        let worst = e.map(abs).max() ?? .nan
        let mean = e.isEmpty ? .nan : e.reduce(0, +) / Double(e.count)
        return String(format: "max |err| %.2f ms, mean %+.2f ms", worst * 1000, mean * 1000)
    }
    return "\(name): mic \(r.micFrames) frames (\(ms(r.micErrors))), system \(r.systemFrames) frames "
        + "(\(ms(r.systemErrors))), re-anchors mic \(r.reanchors[.mic] ?? 0) / system \(r.reanchors[.system] ?? 0), "
        + String(format: "RSS peak %.0f MB (+%.0f MB), %.0f s", r.peakRSSMB, r.rssGrowthMB, r.wallSeconds)
}

private let longTests = ProcessInfo.processInfo.environment["PALAVER_LONG_TESTS"] == "1"

@Suite(.serialized) struct LongAlignmentTests {
    @Test(arguments: [false, true])
    func tapDriftLossesAndSilenceStayAligned(full: Bool) throws {
        // test_long_recording_with_tap_drift_losses_and_silence_stays_aligned: tap clock 130 ppm fast,
        // 0.2 % lost IO cycles, a minute of tap silence every 5 min; clicks within 20 ms on both tracks.
        // Python's 20 minutes take ~20 s in a debug build: 5 minutes by default, 20 with PALAVER_LONG_TESTS=1.
        guard !full || longTests else { return }
        let marks: [Double] = full ? [100, 610, 1_130] : [100, 200]
        let sim = Simulation(seconds: full ? 1_200 : 300, marks: marks, systemDrift: 130e-6, systemLoss: 0.002,
                             systemSilentMinutes: true)
        let r = try sim.run(in: tempDir())
        print(summary(full ? "20 min" : "5 min", r))
        #expect(r.micErrors.count == marks.count && r.systemErrors.count == marks.count)
        for (m, s) in zip(r.micErrors, r.systemErrors) { #expect(abs(s - m) <= 0.020) }
        #expect((r.micErrors + r.systemErrors).allSatisfy { abs($0) <= 0.020 })
    }

    @Test func fortyFourKilohertzOutputCountDoesNotDrift() throws {
        // 44.1 kHz → 16 kHz is the one ratio (160/441) that does not divide: 3 minutes with a click every
        // 10 s on both tracks, no jitter or loss. Every click within 1 ms: the output count keeps step.
        let sim = Simulation(seconds: 180, marks: stride(from: 5.0, to: 180, by: 10).map { $0 },
                             mic: [.init(start: 0, rate: 44_100, chunk: 441)], systemRate: 44_100, systemChunk: 441)
        let r = try sim.run(in: tempDir())
        print(summary("3 min at 44.1 kHz", r))
        #expect(r.micErrors.count == 18 && r.systemErrors.count == 18)
        #expect((r.micErrors + r.systemErrors).allSatisfy { abs($0) <= 0.001 })
        #expect(r.reanchors.isEmpty)
        #expect(abs(r.micFrames - 180 * 16_000) <= 1 && abs(r.systemFrames - 180 * 16_000) <= 1)
    }

    @Test(.enabled(if: longTests, "PALAVER_LONG_TESTS=1: 60 minutes of synthetic audio, about a minute"))
    func sixtyMinutesWithJitterAndARateChangeStayWithin20ms() throws {
        // 48 kHz on both tracks, ±5 ms PTS jitter, the mic switching to 24 kHz (AirPods) after 30 min
        // with a 250 ms switch gap, the tap's clock 130 ppm fast with 0.2 % lost cycles. A click every minute.
        let sim = Simulation(seconds: 3_600, marks: stride(from: 30.0, to: 3_600, by: 60).map { $0 },
                             mic: [.init(start: 0, rate: 48_000, chunk: 480), .init(start: 1_800.25, rate: 24_000, chunk: 240)],
                             systemDrift: 130e-6, systemLoss: 0.002, jitter: 0.005, seed: 7)
        let r = try sim.run(in: tempDir())
        print(summary("60 min", r))
        #expect(r.micErrors.count == 60 && r.systemErrors.count == 60)
        #expect((r.micErrors + r.systemErrors).allSatisfy { abs($0) <= 0.020 })
        #expect(abs(Double(r.micFrames) / 16_000 - 3_600) <= 0.05)
        #expect(abs(Double(r.systemFrames) / 16_000 - 3_600) <= 0.05)
        // RSS is the whole process's: alone this run adds nothing (+0 MB), but on CI every bundle's tests share the
        // process and their allocations showed as +109 MB once. What the bound is for: an aligner that kept the hour
        // would add 230 MB (its 16 kHz output) to 1.4 GB (the input).
        #expect(r.rssGrowthMB < 200)
    }
}
