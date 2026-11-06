import Foundation
import Testing
@testable import PalaverCapture

private func run(_ r: TrackResampler, _ chunks: [TimedChunk]) -> [TimedChunk] {
    chunks.flatMap { r.push($0) } + r.flush()
}

/// The output as one timeline: each output chunk at its PTS (relative to `t0`), in frames.
private func timeline(_ out: [TimedChunk], t0: Int64) -> [Float] {
    var x: [Float] = []
    for c in out {
        let at = Int((Double(c.pts - t0) / 62_500).rounded())
        if at > x.count { x += [Float](repeating: 0, count: at - x.count) }
        x.removeLast(x.count - at)
        x += c.samples
    }
    return x
}

/// Exponential sweep 20 Hz → 7 kHz (below the 8 kHz Nyquist of the output).
private func sweep(_ n: Int, rate: Double, seconds: Double) -> [Float] {
    let f0 = 20.0, f1 = 7_000.0, k = log(f1 / f0)
    return (0..<n).map { i in
        Float(0.5 * sin(2 * .pi * f0 * seconds / k * (exp(Double(i) / rate / seconds * k) - 1)))
    }
}

private func snr(_ y: [Float], _ ref: [Float], margin: Int) -> Double {
    var s = 0.0, e = 0.0
    for i in margin..<(min(y.count, ref.count) - margin) {
        s += Double(ref[i]) * Double(ref[i])
        let d = Double(y[i]) - Double(ref[i])
        e += d * d
    }
    return 10 * log10(s / e)
}

/// Decimates by 3 and fails on the given calls (counted across streams).
private final class FakeConverter: RateConverter {
    final class Counter {
        var calls = 0
        let failing: Set<Int>
        init(failing: Set<Int>) { self.failing = failing }
    }
    let counter: Counter
    init(_ counter: Counter) { self.counter = counter }
    func process(_ samples: [Float], last: Bool) throws -> [Float] {
        defer { counter.calls += 1 }
        if counter.failing.contains(counter.calls) { throw ConverterError(message: "boom \(counter.calls)") }
        return stride(from: 0, to: samples.count, by: 3).map { samples[$0] }
    }
}

@Suite struct ResamplerTests {
    @Test func sixteenKilohertzPassesThrough() {
        let r = TrackResampler(label: "t")
        let c = TimedChunk(pts: ns(5), samples: sine(320))
        #expect(r.push(c) == [c])
        #expect(r.flush().isEmpty)
    }

    @Test(arguments: [48_000.0, 44_100.0, 24_000.0, 32_000.0])
    func outputIsZeroLatencyAndExactLength(rate: Double) {
        // An impulse at 1 s comes out at sample 16 000; 2 s in are 32 000 out; PTS follow the output count.
        var x = [Float](repeating: 0, count: Int(rate) * 2)
        x[Int(rate)] = 1
        let out = run(TrackResampler(label: "t"), chunked(x, 100, 480, rate: rate))
        let total = out.reduce(0) { $0 + $1.samples.count }
        #expect(abs(total - 32_000) <= 1)
        #expect(out.first?.pts == ns(100))
        var expectedPts = ns(100)
        for c in out {
            #expect(c.pts == expectedPts)
            expectedPts += Int64(c.samples.count) * 62_500
        }
        let y = out.flatMap(\.samples)
        let peak = y.indices.max { abs(y[$0]) < abs(y[$1]) }!
        #expect(abs(peak - 16_000) <= 1, "peak at \(peak)")
    }

    @Test func sweepQuality() {
        // SNR of the resampled sweep against the analytic 16 kHz sweep; the numbers go to the report.
        let ref = sweep(160_000, rate: 16_000, seconds: 10)
        for rate in [48_000.0, 44_100.0, 24_000.0] {
            let x = sweep(Int(rate * 10), rate: rate, seconds: 10)
            let y = run(TrackResampler(label: "t"), chunked(x, 0, 480, rate: rate)).flatMap(\.samples)
            let db = snr(y, ref, margin: 1_600)
            print("sweep \(Int(rate)) Hz → 16 kHz: SNR \(String(format: "%.1f", db)) dB")
            #expect(y.count == 160_000)
            #expect(db > 120)
        }
    }

    @Test func aliasesAreRejected() {
        for (f, limit) in [(7_600.0, -0.5), (9_000.0, -120.0), (12_000.0, -120.0)] {
            let x = sine(96_000, freq: f, sr: 48_000, amp: 0.5)
            let y = run(TrackResampler(label: "t"), chunked(x, 0, 480, rate: 48_000)).flatMap(\.samples)
            let mid = y[4_000..<(y.count - 4_000)]
            let rms = sqrt(mid.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(mid.count))
            let db = 20 * log10(rms / (0.5 / 2.0.squareRoot()))
            print("tone \(Int(f)) Hz from 48 kHz: \(String(format: "%.1f", db)) dB")
            if f < 8_000 { #expect(db > limit) } else { #expect(db < limit) }
        }
    }

    @Test func rateChangeReanchors() {
        // AirPods join: 48 kHz → 24 kHz at 101 s. The old stream is flushed (its tail keeps its PTS),
        // the new one starts at the new chunk's PTS. A rate change is not a drift: health is not told.
        var reported: [Double] = []
        var lines: [String] = []
        let r = TrackResampler(label: "mic", onReanchor: { reported.append($0); return false }, log: { lines.append($0) })
        let first = chunked(sine(48_000, sr: 48_000), 100, 512, rate: 48_000)
        let second = chunked(sine(24_000, sr: 24_000), 101, 240, rate: 24_000)
        var out: [TimedChunk] = []
        for c in first { out += r.push(c) }
        let beforeSwitch = out.reduce(0) { $0 + $1.samples.count }
        let atSwitch = r.push(second[0])
        let flushedTail = atSwitch.filter { $0.pts < ns(101) }
        #expect(!flushedTail.isEmpty)
        #expect(beforeSwitch + flushedTail.reduce(0) { $0 + $1.samples.count } == 16_000)
        out += atSwitch
        for c in second.dropFirst() { out += r.push(c) }
        out += r.flush()
        let newStream = out.filter { $0.pts >= ns(101) }
        #expect(newStream.first?.pts == ns(101))
        #expect(abs(newStream.reduce(0) { $0 + $1.samples.count } - 16_000) <= 1)
        #expect(reported.isEmpty)
        #expect(lines == ["mic: input rate changed 48000 Hz → 24000 Hz"])
    }

    @Test func driftAboveToleranceReanchorsAndIsReported() {
        // Every 10th 10 ms cycle lost: the accumulated drift passes 20 ms after the 3rd loss.
        var reported: [Double] = []
        var lines: [String] = []
        let r = TrackResampler(label: "system", onReanchor: { reported.append($0); return reported.count > 1 },
                               log: { lines.append($0) })
        let chunks = chunked(sine(480_000, sr: 48_000), 100, 480, rate: 48_000)
        let kept = chunks.enumerated().filter { $0.offset % 10 != 9 }.map(\.element)
        let out = run(r, kept)
        // 100 lost cycles = 1 s; re-anchors happen whenever 3 losses have added up (30 ms > 20 ms).
        #expect(reported.count == 33)
        #expect(reported.allSatisfy { abs($0 - 0.03) < 1e-6 })
        #expect(lines == ["system: re-anchored resampler after +30.0 ms PTS drift"])  // the rest were quiet
        // After each re-anchor the output is back on the input's clock.
        let y = timeline(out, t0: ns(100))
        #expect(abs(y.count - 160_000) <= 4_800)
        for c in out { #expect((c.pts - ns(100)) % 62_500 == 0) }
    }

    @Test func anchorsAreMarked() {
        // The first output of each stream, and a 16 kHz chunk after a rate change, carry isAnchor.
        let r = TrackResampler(label: "t")
        var out: [TimedChunk] = []
        for c in chunked(sine(4_800, sr: 48_000), 100, 480, rate: 48_000) { out += r.push(c) }
        for c in chunked(sine(4_800, sr: 48_000), 100.13, 480, rate: 48_000) { out += r.push(c) }  // 30 ms lost
        out += r.push(TimedChunk(pts: ns(100.3), samples: sine(320)))
        out += r.push(TimedChunk(pts: ns(100.32), samples: sine(320)))
        #expect(out.filter(\.isAnchor).map(\.pts) == [ns(100), ns(100.13), ns(100.3)])
    }

    @Test func converterErrorIsLoggedOnceAndTheNextChunkAnchors() {
        // A failing converter loses that chunk's audio, never the timeline: the stream is dropped, the
        // next chunk starts a new one at its own PTS (an anchor), and the log says so once, not per chunk.
        let counter = FakeConverter.Counter(failing: [3, 4, 5])
        var lines: [String] = []
        let r = TrackResampler(label: "mic", log: { lines.append($0) }, makeConverter: { _ in FakeConverter(counter) })
        let chunks = chunked(sine(4_800, sr: 48_000), 100, 480, rate: 48_000)
        var out: [TimedChunk] = []
        for c in chunks { out += r.push(c) }
        out += r.flush()
        #expect(lines.filter { $0.contains("converter failed") } == ["mic: converter failed (boom 3); audio is lost until it works again"])
        #expect(lines.filter { $0.contains("works again") && !$0.contains("failed") } == ["mic: converter works again"])
        // Chunks 3, 4, 5 are lost; chunk 6 anchors at its own PTS.
        #expect(out.filter(\.isAnchor).map(\.pts) == [chunks[0].pts, chunks[6].pts])
        #expect(out.reduce(0) { $0 + $1.samples.count } == (10 - 3) * 160)
    }

    @Test func jitterWithinToleranceDoesNotReanchor() {
        var reported = 0
        let r = TrackResampler(label: "mic", onReanchor: { _ in reported += 1; return false })
        var chunks = chunked(sine(96_000, sr: 48_000), 100, 480, rate: 48_000)
        var g = SystemRandomNumberGenerator()
        for i in chunks.indices.dropFirst() { chunks[i].pts += Int64.random(in: -19_000_000...19_000_000, using: &g) }
        let out = run(r, chunks)
        #expect(reported == 0)
        #expect(out.reduce(0) { $0 + $1.samples.count } == 32_000)
    }

    @Test func pastDriftsDoNotAccumulate() {
        // Small (10 ms) losses each below the tolerance are judged against the anchor plus the
        // accumulated input count, so they cannot add up beyond 20 ms.
        var drifts: [Double] = []
        let r = TrackResampler(label: "t", onReanchor: { drifts.append($0); return true })
        let chunks = chunked(sine(480_000, sr: 48_000), 0, 480, rate: 48_000)
        _ = run(r, chunks.enumerated().filter { $0.offset % 10 != 9 }.map(\.element))
        #expect(drifts.allSatisfy { $0 <= 0.0301 })
    }
}
