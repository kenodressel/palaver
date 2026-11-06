// PTS alignment of the two tracks (capture_recorder.py:1039-1133 and `_finalize_writers`, :696-727).
import Foundation

public enum CaptureTrack: String, Sendable, CaseIterable {
    case mic
    case system
}

/// Places both tracks' chunks in their `.part` files so that sample 0 of
/// each is the same host-time instant, the contract echo cancellation
/// depends on (mic and system within 20 ms).
///
/// - Every chunk passes its track's `TrackResampler` first.
/// - Phase A: until both tracks have a first PTS, or one track has run
///   alone for `phaseAMaxSeconds`, resampled chunks are held in memory.
///   Then `startPts` = the earlier first PTS (no captured audio is dropped;
///   the later track is zero-padded at the front) and the held chunks are
///   written in PTS order.
/// - Phase B: each chunk goes to offset round((pts − startPts) × 16000).
///   Within ±`ptsToleranceFrames` of the track's end it is written
///   contiguously (jitter); an overlap is trimmed; a gap is zero-padded.
/// - Deviation from Python: the first chunk of each resampler stream (an
///   anchor: a track's first, after a rate change, after a drift re-anchor)
///   is placed at its own PTS, gap or overlap, instead of being appended when
///   within the tolerance. In Python the writer absorbed each re-anchor's
///   jump (up to 20 ms) as jitter, so the writer's error and the resampler's
///   drift added up: with ±5 ms stamp jitter and a 130 ppm tap clock a
///   30-minute run put clicks 28 ms off (Python, same scenario). Within a
///   stream PTS follow the sample count exactly, so nothing else changes.
/// - `finish()` flushes the resamplers and finalizes each track to its own length.
///
/// Not thread-safe: the capture recorder calls it from its one writer thread.
public final class TrackAligner {
    public static let phaseAMaxSeconds = 2.0

    public let mic: TrackWriter
    public let system: TrackWriter
    public private(set) var startPts: Int64?
    public private(set) var micFirstPts: Int64?
    public private(set) var systemFirstPts: Int64?
    /// The native rate each track last arrived at (e.g. 24 kHz from AirPods).
    public private(set) var micRate: Double?
    public private(set) var systemRate: Double?
    public private(set) var finished = false

    private let micResampler: TrackResampler
    private let systemResampler: TrackResampler
    private var phaseAMic: [TimedChunk] = []
    private var phaseASystem: [TimedChunk] = []
    /// An anchor that was dropped whole (all of it already on disk): its stream's next chunk anchors instead.
    private var anchorPending: Set<CaptureTrack> = []

    /// `onReanchor(track, drift seconds)` is the health sink for drift
    /// re-anchors; it returns true to keep one out of the log.
    public init(mic: TrackWriter, system: TrackWriter,
                onReanchor: ((CaptureTrack, Double) -> Bool)? = nil,
                log: @escaping (String) -> Void = { _ in }) {
        self.mic = mic
        self.system = system
        micResampler = TrackResampler(label: "mic", onReanchor: onReanchor.map { f in { f(.mic, $0) } }, log: log)
        systemResampler = TrackResampler(label: "system", onReanchor: onReanchor.map { f in { f(.system, $0) } },
                                         log: log)
    }

    public func writer(_ track: CaptureTrack) -> TrackWriter { track == .mic ? mic : system }

    /// One captured chunk (`_handle_chunk`, minus the health and stall bookkeeping).
    public func handle(_ chunk: TimedChunk, track: CaptureTrack) throws {
        guard !finished else { return }
        switch track {
        case .mic:
            micRate = chunk.rate
            if micFirstPts == nil { micFirstPts = chunk.pts }
        case .system:
            systemRate = chunk.rate
            if systemFirstPts == nil { systemFirstPts = chunk.pts }
        }
        for out in resampler(track).push(chunk) { try place(out, track) }
        if startPts == nil, phaseADone(latestPts: chunk.pts) { try enterPhaseB() }
    }

    /// Flushes the resamplers and Phase A, then finalizes each track to its own length.
    @discardableResult
    public func finish() throws -> (mic: Int, system: Int) {
        guard !finished else { return (mic.framesWritten, system.framesWritten) }
        for track in CaptureTrack.allCases {
            for out in resampler(track).flush() { try place(out, track) }
        }
        if startPts == nil, micFirstPts != nil || systemFirstPts != nil { try enterPhaseB() }
        finished = true
        let lengths = (mic: mic.framesWritten, system: system.framesWritten)
        var failure: Error?
        for (writer, frames) in [(mic, lengths.mic), (system, lengths.system)] {
            do { try writer.finalize(toFrames: frames) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
        return lengths
    }

    /// Stops without finalizing: both `.part` files keep a header that states what was written.
    public func abort() {
        finished = true
        mic.abort()
        system.abort()
    }

    // MARK: - private

    private func resampler(_ track: CaptureTrack) -> TrackResampler {
        track == .mic ? micResampler : systemResampler
    }

    private func phaseADone(latestPts: Int64) -> Bool {
        let firsts = [micFirstPts, systemFirstPts].compactMap { $0 }
        if firsts.count == 2 { return true }
        guard let first = firsts.first else { return false }
        return Double(latestPts - first) >= Self.phaseAMaxSeconds * 1e9
    }

    private func place(_ chunk: TimedChunk, _ track: CaptureTrack) throws {
        guard startPts != nil else {
            if track == .mic { phaseAMic.append(chunk) } else { phaseASystem.append(chunk) }
            return
        }
        try write(chunk, track)
    }

    private func enterPhaseB() throws {
        startPts = [micFirstPts, systemFirstPts].compactMap { $0 }.min()
        let held: [(CaptureTrack, [TimedChunk])] = [(.mic, phaseAMic), (.system, phaseASystem)]
        phaseAMic = []
        phaseASystem = []
        for (track, chunks) in held {
            // Stable, like Python's sorted().
            let ordered = chunks.enumerated().sorted { ($0.element.pts, $0.offset) < ($1.element.pts, $1.offset) }
            for (_, chunk) in ordered { try write(chunk, track) }
        }
    }

    private func write(_ chunk: TimedChunk, _ track: CaptureTrack) throws {
        guard let startPts else { return }
        let writer = writer(track)
        var offset = Self.frameOffset(chunk.pts - startPts)
        var samples = chunk.samples[...]
        let written = writer.framesWritten
        let drift = offset - written
        let anchor = chunk.isAnchor || anchorPending.contains(track)
        anchorPending.remove(track)
        if anchor {
            // A fresh stamp: placed at its PTS (a gap is zero-padded by the writer, an overlap trimmed).
            if drift < 0 {
                if -drift >= samples.count { anchorPending.insert(track); return }
                samples = samples.dropFirst(-drift)
                offset = written
            }
        } else if abs(drift) <= ptsToleranceFrames {
            offset = written  // jitter: continue contiguously
        } else if drift < 0 {
            // A real overlap (or pre-roll before startPts): drop what is already on disk.
            if -drift >= samples.count { return }
            samples = samples.dropFirst(-drift)
            offset = written
        }
        // A positive drift beyond the tolerance is a real gap: the writer zero-pads.
        try writer.write(PCM.int16(samples), atOffset: offset)
    }

    /// round((pts − startPts) × 16000), Python's round (half to even).
    static func frameOffset(_ nanos: Int64) -> Int {
        Int((Double(nanos) / Double(nanosPerFrame)).rounded(.toNearestOrEven))
    }
}
