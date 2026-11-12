// The microphone while muted in the call (PalaverCore's CallMute): held `timeline.delay` seconds
// after it was captured, then each sample that falls in a muted stretch is written as silence. The
// hold lets a change that reaches Palaver late still cut at its own moment; the track's timeline
// stays as it was (silence, not a gap).
import Foundation
import PalaverCore

/// Not thread-safe: the recorder's writer thread pushes and releases.
final class MicMuteGate {
    let timeline: MuteTimeline
    private var held: [TimedChunk] = []

    init(timeline: MuteTimeline) {
        self.timeline = timeline
    }

    var isEmpty: Bool { held.isEmpty }

    /// Host time just after the last sample released: what lies before is written.
    private(set) var releasedUntil: Int64?

    /// Seconds of audio held.
    var heldSeconds: Double { held.reduce(0) { $0 + Double($1.samples.count) / $1.rate } }

    func push(_ chunk: TimedChunk) { held.append(chunk) }

    /// The chunks whose end is `delay` behind `now` (host ns), or all of them (`all`: the recording
    /// stops), in the order they came, with their muted samples silenced.
    /// The hold is the timeline's as it is now: it may shrink or grow while the recording runs (a shorter one
    /// lets more go at once, in order).
    func release(now: Int64, all: Bool = false) -> [TimedChunk] {
        let delayNs = Int64((timeline.delay * 1e9).rounded())
        var ready = 0
        while ready < held.count, all || Self.end(held[ready]) + delayNs <= now { ready += 1 }
        guard ready > 0 else { return [] }
        let out = held[0..<ready].map { silence($0) }
        releasedUntil = Self.end(held[ready - 1])
        held.removeFirst(ready)
        return out
    }

    /// Host time just after the chunk's last sample.
    static func end(_ c: TimedChunk) -> Int64 {
        c.pts + Int64((Double(c.samples.count) / c.rate * 1e9).rounded())
    }

    /// The chunk with every sample whose moment lies in a muted stretch set to 0. Sample i is at
    /// pts + i / rate; a stretch [a, b) silences the samples at a and after, up to before b.
    func silence(_ chunk: TimedChunk) -> TimedChunk {
        let ranges = timeline.mutedRanges(from: chunk.pts, to: Self.end(chunk))
        guard !ranges.isEmpty else { return chunk }
        var out = chunk
        let n = chunk.samples.count
        func index(_ t: Int64) -> Int {
            // A stamp rounded to the nanosecond is a sample's own moment, not the next one's.
            let i = (Double(t - chunk.pts) * chunk.rate / 1e9 - 0.001).rounded(.up)
            return Swift.min(n, Swift.max(0, Int(i)))
        }
        out.samples.withUnsafeMutableBufferPointer { s in
            for r in ranges {
                let (a, b) = (index(r.lowerBound), index(r.upperBound))
                if a < b { s[a..<b].update(repeating: 0) }
            }
        }
        return out
    }
}
