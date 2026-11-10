// What goes out, a piece at a time (transcription.py `plan_chunks`, `_audio`): a recording longer than the service
// takes at once goes in chunks that overlap; each chunk is the trimmed system track as FLAC, 16 kHz mono 16-bit,
// encoded from the WAV block by block into a temporary file, so the hour is never in memory as samples, and its bytes
// are mapped from that file for the upload.
import AudioToolbox
import Foundation
import PalaverCore
import PalaverDomain

public enum Chunks {
    public static let SAMPLE_RATE = 16_000
    /// 16-bit mono: FLAC is never larger.
    public static let RAW_BYTES_PER_SECOND = Double(SAMPLE_RATE * 2)
    /// Chunks overlap this much; they are stitched in the middle of the overlap, far from where a chunk cuts a word.
    public static let OVERLAP_SECONDS = 10.0
    /// WAV frames read at a time.
    static let READ_FRAMES = 1 << 18

    /// Pieces of at most `maxSeconds` covering 0–`total`, each overlapping the next by `overlap`.
    public static func plan(total: Double, maxSeconds: Double, overlap: Double = OVERLAP_SECONDS) -> [(Double, Double)] {
        if total <= maxSeconds { return [(0, total)] }
        let overlap = min(overlap, maxSeconds / 4)
        let step = maxSeconds - overlap
        var out: [(Double, Double)] = []
        var start = 0.0
        while true {
            let end = min(start + maxSeconds, total)
            out.append((start, end))
            if end >= total { return out }
            start += step
        }
    }

    /// One encoded chunk: its FLAC bytes (mapped from a file already unlinked) and how many seconds it holds.
    public struct Encoded {
        public let flac: Data
        public let seconds: Double
    }

    /// `start`–`end` of the trimmed track `line` of `wav`, as FLAC 16 kHz mono.
    public static func flac(_ wav: URL, line: Timeline, start: Double, end: Double) throws -> Encoded {
        let info = try Wav16.info(wav)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-chunk-\(UUID().uuidString).flac")
        defer { unlink(file.path) }
        let writer = try FlacWriter(file)
        var written = 0
        do {
            for (a, b) in line.pieces(start, end) {
                let first = min(Int((a * Double(info.rate)).rounded(.toNearestOrEven)), info.frames)
                let count = min(Int(((b - a) * Double(info.rate)).rounded(.toNearestOrEven)), info.frames - first)
                // Each piece on its own, as soxr.resample took them.
                let resampler = info.rate == SAMPLE_RATE ? nil : try ExchangeAudio.Resampler(from: info.rate, to: SAMPLE_RATE)
                var at = 0
                repeat {
                    let n = min(READ_FRAMES, count - at)
                    let mono = n > 0 ? Trim.mix(try Wav16.read(wav, start: first + at, frames: n), channels: info.channels) : []
                    at += n
                    let samples = try resampler?.process(mono, last: at >= count) ?? mono
                    try writer.write(samples)
                    written += samples.count
                } while at < count
            }
            try writer.close()
        } catch {
            try? writer.close()
            throw error
        }
        let data = try Data(contentsOf: file, options: .alwaysMapped)
        return Encoded(flac: data, seconds: Double(written) / Double(SAMPLE_RATE))
    }

    /// Floats as 16-bit PCM, as libsndfile writes them: `lrintf(x * 0x7FFF)`, clipped.
    static func pcm16(_ x: Float) -> Int16 {
        let v = (x * Float(0x7FFF)).rounded(.toNearestOrEven)
        return Int16(max(-32768, min(32767, v)))
    }

    /// A FLAC file of 16-bit, 16 kHz mono (Core Audio's FLAC encoder, through ExtAudioFile).
    final class FlacWriter {
        private var ref: ExtAudioFileRef?

        init(_ url: URL) throws {
            var format = AudioStreamBasicDescription(
                mSampleRate: Double(SAMPLE_RATE), mFormatID: kAudioFormatFLAC,
                mFormatFlags: 1 /* kAppleLosslessFormatFlag_16BitSourceData */, mBytesPerPacket: 0, mFramesPerPacket: 0,
                mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
            var status = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileFLACType, &format, nil,
                                                   AudioFileFlags.eraseFile.rawValue, &ref)
            guard status == noErr, let ref else { throw AudioError("FLAC encoding is not available (\(status))") }
            var client = AudioStreamBasicDescription(
                mSampleRate: Double(SAMPLE_RATE), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1,
                mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            status = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                             UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
            guard status == noErr else {
                ExtAudioFileDispose(ref)
                self.ref = nil
                throw AudioError("FLAC encoding is not available (\(status))")
            }
        }

        func write(_ samples: [Float]) throws {
            guard let ref, !samples.isEmpty else { return }
            var pcm = samples.map(Chunks.pcm16)
            let status = pcm.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return ExtAudioFileWrite(ref, UInt32(samples.count), &list)
            }
            guard status == noErr else { throw AudioError("the FLAC encoder failed (\(status))") }
        }

        func close() throws {
            guard let ref else { return }
            self.ref = nil
            let status = ExtAudioFileDispose(ref)
            guard status == noErr else { throw AudioError("the FLAC file could not be finished (\(status))") }
        }
    }

    /// A tone, `seconds` of 440 Hz at 0.2 (the Test button's audio, no meeting) as FLAC.
    public static func tone(seconds: Double) throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-tone-\(UUID().uuidString).flac")
        defer { unlink(file.path) }
        let writer = try FlacWriter(file)
        let n = Int(seconds * Double(SAMPLE_RATE))
        try writer.write((0..<n).map { Float(0.2 * sin(2 * Double.pi * 440 * Double($0) / Double(SAMPLE_RATE))) })
        try writer.close()
        return try Data(contentsOf: file)
    }
}
