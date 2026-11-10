// Detect, don't trust (issue #50): the recorder's health monitor, ported from palaver/audio_health.py
// (thresholds, windows and wording exactly), plus two incident kinds Python has no counterpart for.
//
// The recorder feeds this monitor what it sees, and the monitor opens an *incident* when a threshold
// is crossed:
//
// - `speed`: a track's stamps disagree with its sample count (see `speed(_:_:)`): in 5 of the last 10
//   seconds the two differ by more than 4 %, judged per 1 s bucket of consecutive chunk pairs. A pair
//   whose stamps jump further than max(2.5 d, d + 20 ms) is left out; a jump of exactly k chunks
//   (k >= 2) is k - 1 lost IO cycles unless most pairs of that second jump so (a misread rate, e.g.
//   AirPods at 24 kHz read as 48). It ends once most of the last seconds are clean, dated when they
//   became clean.
// - `length`: a delivering track's written length disagrees with the clock by more than 3 s (closed
//   after 5 s fine).
// - `stalled`: no microphone buffers for 30 s (or none from the tap, system only).
// - `access` / `device`: a capture source reports a denied permission or an unusable device; opened
//   once it lasted 4 s (AirPods switching make devices disappear for a moment).
// - Soft hint `silent`: the mic sends digital silence for 60 s while the system side was heard
//   (peak >= 0.01). Shown once per recording; kept as a problem only when it lasted to the end.
//
// New in Swift (Task 6 review carry-forwards; Python's kinds are unchanged):
// - `dropped`: the capture ring was full and buffers were thrown away (the writer fell behind by
//   seconds). Python's queues were unbounded and never lost a buffer, so it has no precedent; audio
//   is missing from the file, so it is an incident like a lost cycle that matters. It opens at once
//   when the dropped count grew since the previous check and ends after 5 s without a new drop.
// - `write`: a track's last write failed (disk full, I/O error). Python's writer thread died silently
//   on it. Opens at once, ends at once when a write succeeds again.
//
// Times: `start`/`end` are seconds from the recording's start on the recorder's clock (where the audio
// is); `at` is the wall-clock time it began (ISO 8601, local offset), taken when it was seen.
import Foundation
import PalaverCore

public enum HealthThreshold {
    public static let speedTolerance = 0.04
    public static let speedWindow = 10  // seconds looked at
    public static let speedBadSeconds = 5  // of them off by more than the tolerance
    public static let speedMinAudio = 0.25  // seconds of audio a second needs to be judged
    public static let jumpSeconds = 0.02  // with 2.5 chunks: a stamp jump beyond both is a discontinuity
    public static let wholeCycles = 0.0005  // a jump within this of k chunks (k >= 2) is k - 1 lost cycles
    public static let lengthTolerance = 3.0
    public static let recentSeconds = 1.0  // a track that delivered this recently is measured for its length
    public static let silentSeconds = 60.0
    public static let digitalSilence: Float = 1.0 / 32_768  // below one 16-bit step
    public static let audible: Float = 0.01  // about -40 dBFS: the other side is heard
    public static let reanchorWindow = 60.0
    /// Seconds a condition must last before it is an incident (others: at once).
    public static func openAfter(_ kind: String) -> Double { kind == "access" || kind == "device" ? 4.0 : 0.0 }
    /// Seconds it must be fine before the incident ends (others: at once).
    public static func closeAfter(_ kind: String) -> Double { kind == "length" || kind == "dropped" ? 5.0 : 0.0 }
}

/// One audio incident: `{id, kind, track, start, end, at}` (`end` nil while it lasts).
public struct AudioIncident: Sendable, Equatable {
    public var id: Int
    public var kind: String
    public var track: String
    public var start: Double
    public var end: Double?
    public var at: String

    /// The shape of `audio_problems.json` (without `id`) and `meta.json`'s `audio_problems`.
    var jsonFields: [(String, Any)] {
        [("kind", kind), ("track", track), ("start", start), ("end", end as Any), ("at", at)]
    }
}

/// Thread-safe: fed by the recorder's writer thread, read by the daemon's status.
public final class AudioHealth: @unchecked Sendable {
    private struct Key: Hashable {
        var kind: String
        var track: CaptureTrack
    }

    /// One second of consecutive chunk pairs: continuous ones, then whole-cycle jumps.
    private struct Bucket {
        var second: Int
        var advance = 0.0, duration = 0.0, n = 0
        var jumps = 0.0, jumped = 0.0, nJumps = 0
    }

    private let started: Double
    private let wall: () -> Date
    private let timeZone: TimeZone
    private let lock = NSLock()
    private var incidents: [AudioIncident] = []
    private var open: [Key: Int] = [:]  // index into `incidents`
    private var badSince: [Key: Double] = [:]
    private var fineSince: [Key: Double] = [:]
    private var prev: [CaptureTrack: (pts: Double, duration: Double)] = [:]
    private var buckets: [CaptureTrack: [Bucket]] = [.mic: [], .system: []]
    private var reanchors: [CaptureTrack: [Double]] = [.mic: [], .system: []]
    private var firstOffset: [CaptureTrack: Double] = [:]  // arrival clock minus stamp, at a track's first chunk
    private var lastArrival: [CaptureTrack: Double] = [:]
    private var micZeroSince: Double?
    private var systemHeard: Double?
    private var hintShown = false  // the silent-mic hint, once per recording
    private var hintOn = false
    private var lastDropped: [CaptureTrack: Int] = [:]

    public init(started: Double, wall: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.started = started
        self.wall = wall
        self.timeZone = timeZone
    }

    // MARK: fed by the recorder

    /// A chunk arrived (before resampling), declared at `rate`; `pts` in seconds.
    public func chunk(_ track: CaptureTrack, now: Double, pts: Double, samples: [Float], rate: Double) {
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        let duration = rate > 0 ? Double(samples.count) / rate : 0
        lock.lock(); defer { lock.unlock() }
        if firstOffset[track] == nil { firstOffset[track] = now - pts }
        lastArrival[track] = now
        let before = prev[track]
        prev[track] = (pts, duration)
        if let before, before.duration > 0 {
            let advance = pts - before.pts, d = before.duration
            if advance > 0, advance <= max(2.5 * d, d + HealthThreshold.jumpSeconds) {
                let second = Int(now.rounded(.down))
                var list = buckets[track]!
                if list.last?.second != second {
                    list.append(Bucket(second: second))
                    while list[0].second < second - HealthThreshold.speedWindow { list.removeFirst() }
                }
                let k = (advance / d).rounded()
                let whole = k >= 2 && abs(advance - k * d) <= HealthThreshold.wholeCycles
                if whole {
                    list[list.count - 1].jumps += advance
                    list[list.count - 1].jumped += d
                    list[list.count - 1].nJumps += 1
                } else {
                    list[list.count - 1].advance += advance
                    list[list.count - 1].duration += d
                    list[list.count - 1].n += 1
                }
                buckets[track] = list
            }
        }
        if track == .mic {
            if peak > HealthThreshold.digitalSilence { micZeroSince = nil } else if micZeroSince == nil { micZeroSince = now }
        } else if peak >= HealthThreshold.audible {
            systemHeard = now
        }
    }

    /// The resampler re-anchored (for the log: re-anchors a minute).
    public func reanchor(_ track: CaptureTrack, now: Double, drift: Double) {
        lock.lock(); defer { lock.unlock() }
        reanchors[track]!.append(now)
        reanchors[track]!.removeAll { $0 < now - HealthThreshold.reanchorWindow }
    }

    public func reanchorsPerMinute(_ track: CaptureTrack) -> Int {
        lock.lock(); defer { lock.unlock() }
        return reanchors[track]!.count
    }

    /// Evaluates every threshold. `written`: seconds on disk per track since `startPts` (nil until the
    /// tracks are aligned); `access`: "access" or "device" per capture source that reports a problem;
    /// `stalled` / `systemStalled`: a track stopped delivering; `dropped`: buffers lost so far per
    /// track (cumulative); `writeFailures`: tracks whose last write failed. Returns the incidents
    /// opened and those that ended, as copies.
    public func check(_ now: Double, written: [CaptureTrack: Double], startPts: Double?,
                      access: [CaptureTrack: String], stalled: Bool, systemStalled: Bool = false,
                      dropped: [CaptureTrack: Int] = [:],
                      writeFailures: [CaptureTrack: String] = [:]) -> (opened: [AudioIncident], closed: [AudioIncident]) {
        lock.lock(); defer { lock.unlock() }
        var conditions: [(Key, Bool)] = []
        var endedAt: [Key: Double] = [:]
        var beganAt: [Key: Double] = [:]
        for track in CaptureTrack.allCases {
            let (bad, first, last) = speed(track, now)
            conditions.append((Key(kind: "speed", track: track), bad))
            if let first { beganAt[Key(kind: "speed", track: track)] = first; endedAt[Key(kind: "speed", track: track)] = last! + 1 }
        }
        if let startPts {
            for track in CaptureTrack.allCases {
                guard let length = written[track] else { continue }
                guard let last = lastArrival[track], now - last <= HealthThreshold.recentSeconds else { continue }
                let expected = now - firstOffset[track]! - startPts
                conditions.append((Key(kind: "length", track: track), abs(expected - length) > HealthThreshold.lengthTolerance))
            }
        }
        conditions.append((Key(kind: "stalled", track: .mic), stalled))
        conditions.append((Key(kind: "stalled", track: .system), systemStalled))
        for track in CaptureTrack.allCases {
            for kind in ["access", "device"] { conditions.append((Key(kind: kind, track: track), access[track] == kind)) }
        }
        for track in CaptureTrack.allCases {
            let total = dropped[track, default: 0]
            let grew = total > lastDropped[track, default: 0]
            lastDropped[track] = total
            conditions.append((Key(kind: "dropped", track: track), grew))
        }
        for track in CaptureTrack.allCases {
            conditions.append((Key(kind: "write", track: track), writeFailures[track] != nil))
        }
        let silent = isSilent(now)
        if silent && !hintShown { hintShown = true; hintOn = true } else if !silent && hintOn { hintOn = false }
        return apply(now, conditions, endedAt, beganAt)
    }

    /// The recording stopped: what is still open ends now. A mic that stayed silent to the end is kept.
    public func closeAll(_ now: Double) {
        lock.lock(); defer { lock.unlock() }
        for index in open.values { incidents[index].end = at(now) }
        open.removeAll()
        badSince.removeAll()
        fineSince.removeAll()
        if isSilent(now), let zero = micZeroSince {
            incidents.append(makeIncident("silent", .mic, began: zero, now: now, end: now))
        }
        hintOn = false
    }

    // MARK: read by the status

    public func isOpen(_ kind: String, _ track: CaptureTrack) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return open[Key(kind: kind, track: track)] != nil
    }

    /// Every incident so far (`end` nil while open).
    public func problems() -> [AudioIncident] {
        lock.lock(); defer { lock.unlock() }
        return incidents
    }

    public func openProblems() -> [AudioIncident] { problems().filter { $0.end == nil } }

    /// Soft hints to show now: `[("silent", "mic")]`.
    public func hints() -> [(kind: String, track: String)] {
        lock.lock(); defer { lock.unlock() }
        return hintOn ? [("silent", "mic")] : []
    }

    // MARK: internals

    private func at(_ now: Double) -> Double { ((now - started) * 100).rounded() / 100 }

    private func makeIncident(_ kind: String, _ track: CaptureTrack, began: Double, now: Double, end: Double? = nil) -> AudioIncident {
        let when = wall().addingTimeInterval(-max(0, now - began))
        return AudioIncident(id: incidents.count + 1, kind: kind, track: track.rawValue, start: at(began),
                             end: end.map(at), at: isoSeconds(when, timeZone))
    }

    /// Whether the track runs at the wrong speed, and the first and last second of the window it did.
    private func speed(_ track: CaptureTrack, _ now: Double) -> (Bool, Double?, Double?) {
        let current = Int(now.rounded(.down))
        var bad = 0
        var first: Double?, last: Double?
        for b in buckets[track]! {
            guard current - HealthThreshold.speedWindow <= b.second, b.second < current else { continue }
            var advance = b.advance, duration = b.duration
            if b.nJumps > b.n {  // whole-cycle jumps are the rule: a misread rate
                advance += b.jumps
                duration += b.jumped
            }
            if duration < HealthThreshold.speedMinAudio { continue }
            if abs(advance / duration - 1) > HealthThreshold.speedTolerance {
                bad += 1
                if first == nil { first = Double(b.second) }
                last = Double(b.second)
            }
        }
        return (bad >= HealthThreshold.speedBadSeconds, first, last)
    }

    private func isSilent(_ now: Double) -> Bool {
        guard let zero = micZeroSince, now - zero >= HealthThreshold.silentSeconds, let heard = systemHeard else { return false }
        return heard >= zero
    }

    /// `beganAt`: when a condition really began, if known better than when it was first seen (speed: its
    /// first bad second); `endedAt`: when it really ended (speed: after its last bad second).
    private func apply(_ now: Double, _ conditions: [(Key, Bool)], _ endedAt: [Key: Double],
                       _ beganAt: [Key: Double]) -> ([AudioIncident], [AudioIncident]) {
        var opened: [AudioIncident] = [], closed: [AudioIncident] = []
        for (key, bad) in conditions {
            if bad {
                fineSince[key] = nil
                if badSince[key] == nil { badSince[key] = now }
                let since = badSince[key]!
                if open[key] == nil, now - since >= HealthThreshold.openAfter(key.kind) {
                    let incident = makeIncident(key.kind, key.track, began: min(since, beganAt[key] ?? since), now: now)
                    incidents.append(incident)
                    open[key] = incidents.count - 1
                    opened.append(incident)
                }
                continue
            }
            badSince[key] = nil
            guard let index = open[key] else { continue }
            if fineSince[key] == nil { fineSince[key] = now }
            let fine = fineSince[key]!
            if now - fine >= HealthThreshold.closeAfter(key.kind) {
                open[key] = nil
                incidents[index].end = max(incidents[index].start, at(min(endedAt[key] ?? fine, fine)))
                fineSince[key] = nil
                closed.append(incidents[index])
            }
        }
        return (opened, closed)
    }
}

/// `datetime.isoformat(timespec="seconds")` with the local offset: "2026-10-29T12:06:00+01:00".
func isoSeconds(_ date: Date, _ timeZone: TimeZone) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = timeZone
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
    return f.string(from: date)
}
