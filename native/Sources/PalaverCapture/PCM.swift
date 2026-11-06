// Linear PCM decoding (capture_recorder.py:113-218), without CoreMedia: the
// capture sources (Task 6) hand over the bytes and their stream description.
import Foundation

/// The 16 kHz mono PCM16 that both tracks are written as.
public let captureSampleRate = 16_000

/// PTS disagreements up to 20 ms are jitter: written contiguously. Larger ones
/// are real gaps (zero-padded) or overlaps (trimmed) — and the resampler re-anchors.
public let ptsToleranceFrames = captureSampleRate / 50

/// One 16 kHz frame in host-time nanoseconds (exact: 1e9 / 16000).
let nanosPerFrame: Int64 = 62_500

/// The fields of an AudioStreamBasicDescription the decoder needs.
public struct PCMFormat: Sendable, Equatable {
    public static let linearPCM: UInt32 = 0x6C70_636D  // 'lpcm'
    public static let flagIsFloat: UInt32 = 0x1
    public static let flagIsNonInterleaved: UInt32 = 0x20

    public var sampleRate: Double
    public var formatID: UInt32
    public var formatFlags: UInt32
    public var channels: Int
    public var bitsPerChannel: Int

    public init(sampleRate: Double, formatID: UInt32 = PCMFormat.linearPCM, formatFlags: UInt32,
                channels: Int, bitsPerChannel: Int) {
        self.sampleRate = sampleRate
        self.formatID = formatID
        self.formatFlags = formatFlags
        self.channels = channels
        self.bitsPerChannel = bitsPerChannel
    }

    public var isFloat: Bool { formatFlags & Self.flagIsFloat != 0 }
    public var nonInterleaved: Bool { formatFlags & Self.flagIsNonInterleaved != 0 }
}

/// A chunk of mono samples tagged with the host time of its first sample.
public struct TimedChunk: Sendable, Equatable {
    /// Host time of the first sample, in nanoseconds (`AudioConvertHostTimeToNanos`, or a CMTime's nanoseconds).
    public var pts: Int64
    public var samples: [Float]
    /// The native rate of `samples`.
    public var rate: Double
    /// Set by the resampler on the first chunk after a (re-)anchor: its PTS is
    /// a fresh device stamp, so it is placed at that PTS, not appended (see `TrackAligner`).
    public var isAnchor: Bool

    public init(pts: Int64, samples: [Float], rate: Double = Double(captureSampleRate), isAnchor: Bool = false) {
        self.pts = pts
        self.samples = samples
        self.rate = rate
        self.isAnchor = isAnchor
    }
}

public enum PCM {
    /// Linear PCM bytes → Float mono, averaging the channels (`_decode_pcm`).
    /// Float32/64 as they are, int16/int32 divided by 2^15 / 2^31. Planar
    /// (non-interleaved) buffers hold one block per channel. nil for a
    /// layout Python rejects too (other bit depths, a size that is not a
    /// whole number of samples).
    public static func decodeMono(_ bytes: UnsafeRawBufferPointer, channels: Int, bits: Int,
                                  isFloat: Bool, nonInterleaved: Bool) -> [Float]? {
        guard channels >= 1 else { return nil }
        var flat: [Float]
        switch (isFloat, bits) {
        case (true, 32): guard let v = load(bytes, Float.self) else { return nil }; flat = v
        case (true, 64): guard let v = load(bytes, Double.self) else { return nil }; flat = v.map { Float($0) }
        case (false, 16):
            guard let v = load(bytes, Int16.self) else { return nil }
            flat = v.map { Float($0) / 32_768 }
        case (false, 32):
            guard let v = load(bytes, Int32.self) else { return nil }
            flat = v.map { Float($0) / 2_147_483_648 }
        default: return nil
        }
        guard channels > 1 else { return flat }
        let frames = flat.count / channels
        let n = Float(channels)
        var out = [Float](repeating: 0, count: frames)
        flat.withUnsafeBufferPointer { src in
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels {
                    sum += nonInterleaved ? src[c * frames + i] : src[i * channels + c]
                }
                out[i] = sum / n
            }
        }
        return out
    }

    public static func decodeMono(_ data: Data, channels: Int, bits: Int, isFloat: Bool,
                                  nonInterleaved: Bool) -> [Float]? {
        data.withUnsafeBytes { decodeMono($0, channels: channels, bits: bits, isFloat: isFloat,
                                          nonInterleaved: nonInterleaved) }
    }

    /// A capture buffer → (mono samples, native rate) (`_cmsample_to_mono`):
    /// nil unless it is linear PCM with a rate, a channel and some samples.
    public static func mono(_ bytes: UnsafeRawBufferPointer, format: PCMFormat) -> (samples: [Float], rate: Double)? {
        guard format.formatID == PCMFormat.linearPCM, format.sampleRate > 0, format.channels >= 1,
              bytes.count > 0,
              let samples = decodeMono(bytes, channels: format.channels, bits: format.bitsPerChannel,
                                       isFloat: format.isFloat, nonInterleaved: format.nonInterleaved),
              !samples.isEmpty
        else { return nil }
        return (samples, format.sampleRate)
    }

    public static func mono(_ data: Data, format: PCMFormat) -> (samples: [Float], rate: Double)? {
        data.withUnsafeBytes { mono($0, format: format) }
    }

    /// Float → PCM16 exactly as `np.clip(samples * 32_767.0, -32_768, 32_767).astype(np.int16)`:
    /// the product in Float32, clipped, truncated toward zero. NaN becomes 0.
    public static func int16(_ samples: ArraySlice<Float>) -> [Int16] {
        samples.map { s in
            let v = s * 32_767.0
            if v.isNaN { return 0 }
            return Int16(min(max(v, -32_768), 32_767))
        }
    }

    private static func load<T>(_ bytes: UnsafeRawBufferPointer, _: T.Type) -> [T]? {
        let size = MemoryLayout<T>.size
        guard bytes.count % size == 0 else { return nil }
        let count = bytes.count / size
        return [T](unsafeUninitializedCapacity: count) { buf, initialized in
            if count > 0 { UnsafeMutableRawBufferPointer(buf).copyMemory(from: bytes) }
            initialized = count
        }
    }
}
