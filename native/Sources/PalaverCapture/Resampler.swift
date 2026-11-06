// Native rate → 16 kHz per track, keeping PTS exact (capture_recorder.py:230-303, `_TrackResampler`).
//
// Python streams through soxr. Here it is AVAudioConverter (a converter, not a
// capture API: no permission, no device): the Mastering algorithm at .high
// quality, prime method .normal. Measured on a 20 Hz-7 kHz sweep against the
// analytic 16 kHz sweep: 144-148 dB SNR from 48, 44.1 and 24 kHz (soxr's
// default: 135 dB from 48 kHz, 86 dB from 44.1 kHz), a 7.6 kHz tone passes at
// 0.0 dB, 9 and 12 kHz tones are down by more than 149 dB; ~330x real time
// per 48 kHz track. Prime method .normal makes the stream zero-latency: an
// impulse at input time t comes out at output sample t × 16000, and the
// output length is input length × ratio once flushed. That is what lets the
// output PTS be derived from the output sample count alone.
import AVFoundation
import Foundation

/// One continuous resampling stream (from one anchor to the next flush); tests inject fakes.
protocol RateConverter: AnyObject {
    /// Feeds `samples` and returns what is ready; `last` flushes the tail. Throws when the converter fails.
    func process(_ samples: [Float], last: Bool) throws -> [Float]
}

struct ConverterError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private final class ConverterStream: RateConverter {
    private let converter: AVAudioConverter
    private let inFormat: AVAudioFormat
    private let outBuffer: AVAudioPCMBuffer
    private var pending: [Float] = []
    private var position = 0
    private var ended = false
    private var allocationFailed = false

    init?(rate: Double) {
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1,
                                           interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: Double(captureSampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 4096)
        else { return nil }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        converter.primeMethod = .normal
        self.converter = converter
        self.inFormat = inFormat
        self.outBuffer = outBuffer
    }

    func process(_ samples: [Float], last: Bool) throws -> [Float] {
        // The converter autoreleases; the capture's writer thread has no pool of its own.
        try autoreleasepool { try convert(samples, last: last) }
    }

    private func convert(_ samples: [Float], last: Bool) throws -> [Float] {
        pending = samples
        position = 0
        ended = last
        var out: [Float] = []
        out.reserveCapacity(Int(Double(samples.count) * Double(captureSampleRate) / inFormat.sampleRate) + 64)
        while true {
            outBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { [self] wanted, status in
                let left = pending.count - position
                guard left > 0 else {
                    status.pointee = ended ? .endOfStream : .noDataNow
                    return nil
                }
                let n = min(Int(wanted), left)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(n)) else {
                    allocationFailed = true
                    status.pointee = .noDataNow
                    return nil
                }
                buffer.frameLength = AVAudioFrameCount(n)
                pending.withUnsafeBufferPointer { src in
                    buffer.floatChannelData![0].update(from: src.baseAddress! + position, count: n)
                }
                position += n
                status.pointee = .haveData
                return buffer
            }
            if status == .error {
                pending = []
                throw ConverterError(message: error.map { "\($0.domain) \($0.code)" } ?? "AVAudioConverter error")
            }
            out.append(contentsOf: UnsafeBufferPointer(start: outBuffer.floatChannelData![0],
                                                       count: Int(outBuffer.frameLength)))
            if status != .haveData { break }
        }
        pending = []
        if allocationFailed {
            allocationFailed = false
            throw ConverterError(message: "no input buffer")
        }
        return out
    }
}

/// Streams one track's native-rate chunks to 16 kHz and keeps PTS exact.
///
/// The converter emits in bursts, so output PTS is the stream's anchor plus
/// its own output sample count (62 500 ns per frame, exact), never the PTS of
/// whichever input chunk triggered a burst. The stream is flushed and
/// restarted (re-anchored) when the input rate changes, or when an input PTS
/// departs from the anchor plus the *accumulated* input count by more than
/// `ptsToleranceFrames` — so lost IO cycles and clock drift cannot add up.
/// A drift re-anchor is reported to `onReanchor` (drift in seconds), which
/// returns true to keep it out of the log; a rate change is logged only.
/// The first output chunk of each stream is marked `isAnchor` (so is a 16 kHz
/// chunk after a rate change); `TrackAligner` places those at their PTS.
/// 16 kHz input passes through untouched. Not thread-safe: one writer thread.
public final class TrackResampler {
    public let label: String
    private let onReanchor: ((Double) -> Bool)?
    private let log: (String) -> Void
    private var stream: RateConverter?
    private let makeConverter: (Double) -> RateConverter?
    private var converterFailing = false
    private var inRate: Double?
    private var anchorPts: Int64 = 0
    private var inSamples = 0
    private var outSamples: Int64 = 0
    private var unsupportedRate: Double?

    public convenience init(label: String, onReanchor: ((Double) -> Bool)? = nil,
                            log: @escaping (String) -> Void = { _ in }) {
        self.init(label: label, onReanchor: onReanchor, log: log, makeConverter: { ConverterStream(rate: $0) })
    }

    init(label: String, onReanchor: ((Double) -> Bool)? = nil, log: @escaping (String) -> Void,
         makeConverter: @escaping (Double) -> RateConverter?) {
        self.label = label
        self.onReanchor = onReanchor
        self.log = log
        self.makeConverter = makeConverter
    }

    public func push(_ chunk: TimedChunk) -> [TimedChunk] {
        var out: [TimedChunk] = []
        if let inRate, chunk.rate != inRate {
            log("\(label): input rate changed \(Self.hz(inRate)) Hz → \(Self.hz(chunk.rate)) Hz")
        }
        if stream != nil, let inRate {
            let expected = Double(anchorPts) + Double(inSamples) / inRate * 1e9
            let drift = (Double(chunk.pts) - expected) / 1e9
            if chunk.rate != inRate || abs(drift) * Double(captureSampleRate) > Double(ptsToleranceFrames) {
                if chunk.rate == inRate {
                    let quiet = onReanchor?(drift) ?? false
                    if !quiet {
                        log("\(label): re-anchored resampler after \(String(format: "%+.1f", drift * 1000)) ms PTS drift")
                    }
                }
                out += flush()
            }
        }
        let rateChanged = inRate != nil && inRate != chunk.rate
        inRate = chunk.rate

        if chunk.rate == Double(captureSampleRate) {
            var passed = chunk
            passed.isAnchor = rateChanged  // a new device: placed at its own PTS
            out.append(passed)
            return out
        }
        if stream == nil {
            guard let created = makeConverter(chunk.rate) else {
                if unsupportedRate != chunk.rate {  // once per rate, not per chunk
                    log("\(label): cannot resample from \(Self.hz(chunk.rate)) Hz; its audio is dropped")
                }
                unsupportedRate = chunk.rate
                return out
            }
            unsupportedRate = nil
            stream = created
            anchorPts = chunk.pts
            inSamples = 0
            outSamples = 0
        }
        inSamples += chunk.samples.count
        out += run(chunk.samples, last: false)
        return out
    }

    /// Ends the current stream and returns its tail.
    public func flush() -> [TimedChunk] {
        guard stream != nil else { return [] }
        let tail = run([], last: true)
        stream = nil
        return tail
    }

    /// Converts through the current stream. A converter error loses this chunk's audio but not the
    /// timeline: the stream is dropped, so the next chunk anchors a new one at its own PTS. Logged
    /// once until the converter works again.
    private func run(_ samples: [Float], last: Bool) -> [TimedChunk] {
        guard let current = stream else { return [] }
        do {
            let out = try current.process(samples, last: last)
            if converterFailing, !last {
                converterFailing = false
                log("\(label): converter works again")
            }
            return emit(out)
        } catch {
            stream = nil
            if !converterFailing {
                converterFailing = true
                log("\(label): converter failed (\(error)); audio is lost until it works again")
            }
            return []
        }
    }

    private func emit(_ samples: [Float]) -> [TimedChunk] {
        guard !samples.isEmpty else { return [] }
        let chunk = TimedChunk(pts: anchorPts + outSamples * nanosPerFrame, samples: samples, isAnchor: outSamples == 0)
        outSamples += Int64(samples.count)
        return [chunk]
    }

    private static func hz(_ rate: Double) -> String {
        rate == rate.rounded() ? String(Int(rate)) : String(rate)
    }
}
