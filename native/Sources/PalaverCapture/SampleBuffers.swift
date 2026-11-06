// CMSampleBuffer → (PTS, stream format, bytes) for the capture delegates
// (`_stream_description`, `_cmsample_pts_seconds` and the block-buffer read of
// `_cmsample_to_mono`, capture_recorder.py:137-218). Decoding happens later, on
// the writer thread (`PCM.mono`).
import CoreAudio
import CoreMedia
import Foundation

/// Hands one sample buffer's bytes to a ring without decoding them.
///
/// Called on AVFoundation's / ScreenCaptureKit's delegate queues (not
/// realtime threads). A contiguous block buffer is pushed straight from its
/// own memory; a non-contiguous one is copied into `scratch` first, which
/// grows once to the largest buffer seen and is then reused.
final class SampleBufferForwarder: @unchecked Sendable {
    private var scratch: UnsafeMutableRawPointer?
    private var scratchSize = 0

    deinit { scratch?.deallocate() }

    /// Pushes the buffer's bytes into `ring`; false when it was dropped.
    @discardableResult
    func forward(_ sampleBuffer: CMSampleBuffer, to ring: CaptureRing) -> Bool {
        var pushed = false
        read(sampleBuffer) { pushed = ring.push(pts: $0, format: $1, bytes: $2) }
        return pushed
    }

    /// Calls `body(pts, format, bytes)` with the buffer's bytes, valid during the call. Returns false
    /// (without calling it) for a buffer that is not linear PCM with a valid stamp and some bytes:
    /// dropped, as Python's decoder returned None for it.
    @discardableResult
    func read(_ sampleBuffer: CMSampleBuffer, _ body: (Int64, PCMFormat, UnsafeRawBufferPointer) -> Void) -> Bool {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return false }
        let format = PCMFormat(sampleRate: asbd.mSampleRate, formatID: asbd.mFormatID,
                               formatFlags: asbd.mFormatFlags, channels: Int(asbd.mChannelsPerFrame),
                               bitsPerChannel: Int(asbd.mBitsPerChannel))
        guard format.formatID == PCMFormat.linearPCM, format.sampleRate > 0, format.channels >= 1 else { return false }
        let stamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard stamp.isValid, stamp.isNumeric else { return false }
        // Host-clock CMTime → host-time nanoseconds (the tap's AudioConvertHostTimeToNanos scale).
        let pts = CMTimeConvertScale(stamp, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return false }
        let total = CMBlockBufferGetDataLength(block)
        guard total > 0 else { return false }
        var atOffset = 0
        var pointer: UnsafeMutablePointer<CChar>?
        if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &atOffset, totalLengthOut: nil,
                                       dataPointerOut: &pointer) == kCMBlockBufferNoErr,
           atOffset == total, let pointer {
            body(pts, format, UnsafeRawBufferPointer(start: pointer, count: total))
            return true
        }
        if scratchSize < total {
            scratch?.deallocate()
            scratch = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: 16)
            scratchSize = total
        }
        guard let scratch,
              CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: scratch) == kCMBlockBufferNoErr
        else { return false }
        body(pts, format, UnsafeRawBufferPointer(start: scratch, count: total))
        return true
    }
}
