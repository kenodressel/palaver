// Silence out, offsets kept (transcription.py `speech_spans`, `Timeline`): long silences are cut out of the system
// track before the upload (fewer billed minutes), and the way back to the recording's clock is kept, so the words a
// service hears land where they were said.
import Foundation
import PalaverCore
import PalaverDomain

public enum Trim {
    public static let FRAME_SECONDS = 0.1
    /// No 100 ms frame louder than the system track's near-silence gate (Cleanup.SYSTEM_MIN_PEAK_DBFS) for this long.
    public static let SILENCE_DBFS = -50.0
    public static let MIN_SILENCE_SECONDS = 2.0
    /// Each side of a cut silence keeps this much of it.
    public static let KEEP_PAD_SECONDS = 0.5
    /// Frames read at a time.
    static let BLOCK_FRAMES = 600

    /// The RMS of each 100 ms frame of `wav` (16-bit PCM, channels averaged), read a block at a time; and its length in
    /// seconds.
    public static func frameLevels(_ wav: URL) throws -> (levels: [Float], seconds: Double) {
        let info = try Wav16.info(wav)
        guard info.rate > 0, info.frames > 0 else { return ([], 0) }
        let frame = max(1, Int((FRAME_SECONDS * Double(info.rate)).rounded(.toNearestOrEven)))
        var levels: [Float] = []
        levels.reserveCapacity(info.frames / frame + 1)
        var at = 0
        while at < info.frames {
            let count = min(frame * BLOCK_FRAMES, info.frames - at)
            let samples = try Wav16.read(wav, start: at, frames: count)
            let mono = mix(samples, channels: info.channels)
            var i = 0
            while i < mono.count {
                let n = min(frame, mono.count - i)
                var sum: Float = 0
                for k in i..<(i + n) { sum += mono[k] * mono[k] }
                levels.append((sum / Float(n)).squareRoot())
                i += n
            }
            at += count
        }
        return (levels, Double(info.frames) / Double(info.rate))
    }

    /// Interleaved 16-bit samples as mono floats (each / 32768, the channels averaged).
    static func mix(_ samples: [Int16], channels: Int) -> [Float] {
        if channels <= 1 { return samples.map { Float($0) / 32768 } }
        let n = samples.count / channels
        var out = [Float](repeating: 0, count: n)
        for f in 0..<n {
            var sum: Float = 0
            for c in 0..<channels { sum += Float(samples[f * channels + c]) / 32768 }
            out[f] = sum / Float(channels)
        }
        return out
    }

    /// The parts of `wav` to send, in seconds: all of it but silences of MIN_SILENCE_SECONDS or more, of which
    /// KEEP_PAD_SECONDS stay next to the speech (and none before the first word or after the last). Empty when nothing
    /// is louder than silence.
    public static func speechSpans(_ wav: URL) throws -> [(Double, Double)] {
        let (levels, total) = try frameLevels(wav)
        return speechSpans(levels: levels, total: total)
    }

    public static func speechSpans(levels: [Float], total: Double) -> [(Double, Double)] {
        let gate = Float(pow(10, SILENCE_DBFS / 20))
        let loud = levels.map { $0 >= gate }
        guard loud.contains(true) else { return [] }
        let n = loud.count
        let pad = Int((KEEP_PAD_SECONDS / FRAME_SECONDS).rounded(.toNearestOrEven))
        let shortest = Int((MIN_SILENCE_SECONDS / FRAME_SECONDS).rounded(.toNearestOrEven))
        var cuts: [(Int, Int)] = []
        var i = 0
        while i < n {
            if loud[i] { i += 1; continue }
            var j = i
            while j < n && !loud[j] { j += 1 }
            if j - i >= shortest {
                let a = i + (i > 0 ? pad : 0), b = j - (j < n ? pad : 0)
                if b > a { cuts.append((a, b)) }
            }
            i = j
        }
        func at(_ k: Int) -> Double { Py.round(k >= n ? total : Double(k) * FRAME_SECONDS, 3) }
        var spans: [(Double, Double)] = []
        var start = 0
        for (a, b) in cuts {
            if a > start { spans.append((at(start), at(a))) }
            start = b
        }
        if start < n { spans.append((at(start), at(n))) }
        return spans
    }
}

/// The trimmed audio's clock, and the way back to the recording's.
public struct Timeline: Sendable {
    public let spans: [(Double, Double)]
    public let offsets: [Double]
    public let seconds: Double

    public init(_ spans: [(Double, Double)]) {
        self.spans = spans
        var offsets: [Double] = []
        var t = 0.0
        for (a, b) in spans {
            offsets.append(t)
            t += b - a
        }
        self.offsets = offsets
        seconds = t
    }

    /// The span that holds `t` on the trimmed clock (`bisect_right(offsets, t) - 1`, clamped).
    func index(_ t: Double) -> Int {
        var lo = 0, hi = offsets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if t < offsets[mid] { hi = mid } else { lo = mid + 1 }
        }
        return max(0, min(spans.count - 1, lo - 1))
    }

    public func toSource(_ t: Double) -> Double {
        let i = index(t)
        let (a, b) = spans[i]
        return a + min(max(t - offsets[i], 0), b - a)
    }

    /// A word that runs over a cut ends where its part of the recording ends.
    public func wordToSource(_ w: Word) -> Word {
        let i = index(w.start)
        let (a, b) = spans[i]
        let start = a + min(max(w.start - offsets[i], 0), b - a)
        let end = a + min(max(w.end - offsets[i], 0), b - a)
        return Word(text: w.text, start: Py.round(start, 3), end: Py.round(max(start, end), 3), confidence: w.confidence)
    }

    /// The parts of the recording that make up `start`–`end` of the trimmed audio.
    public func pieces(_ start: Double, _ end: Double) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for ((a, b), off) in zip(spans, offsets) {
            let lo = max(start, off), hi = min(end, off + (b - a))
            if hi > lo { out.append((a + lo - off, a + hi - off)) }
        }
        return out
    }
}
