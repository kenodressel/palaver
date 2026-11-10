// FLAC through AudioToolbox's ExtAudioFile: an exchange's audio at the rates Opus does not take (exchange.py
// `_encode_audio`: `format="FLAC", subtype="PCM_16"`), and the reader of an import's audio in any format AudioToolbox
// reads that is not Ogg (libsndfile reads its own set; see the ledger). 16-bit samples go in, floats come out; files
// are written and read in 10 s blocks, never whole. An untrusted file that AudioToolbox refuses throws `AudioError`.
import AudioToolbox
import Foundation

public enum Flac {
    /// `wav` (16-bit PCM) as 16-bit FLAC at `out`, at its own rate and channels, block by block.
    public static func encode(wav: URL, to out: URL) throws {
        let info = try Wav16.info(wav)
        var client = pcm16(rate: info.rate, channels: info.channels)
        var flac = AudioStreamBasicDescription(
            mSampleRate: Double(info.rate), mFormatID: kAudioFormatFLAC, mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData,
            mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(info.channels),
            mBitsPerChannel: 0, mReserved: 0)
        var file: ExtAudioFileRef?
        try check(ExtAudioFileCreateWithURL(out as CFURL, kAudioFileFLACType, &flac, nil, AudioFileFlags.eraseFile.rawValue, &file),
                  "\(out.path): FLAC can't be written")
        guard let file else { throw AudioError("\(out.path): FLAC can't be written") }
        var disposed = false
        defer { if !disposed { ExtAudioFileDispose(file) } }
        try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client),
                  "\(out.path): FLAC takes no such audio")
        let step = info.rate * OggOpus.BLOCK_SECONDS
        var at = 0
        while at < info.frames {
            var samples = try Wav16.read(wav, start: at, frames: min(step, info.frames - at))
            let frames = samples.count / info.channels
            if frames == 0 { break }
            try samples.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(info.channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                try check(ExtAudioFileWrite(file, UInt32(frames), &list), "\(out.path): FLAC can't be written")
            }
            at += frames
        }
        disposed = true
        try check(ExtAudioFileDispose(file), "\(out.path): FLAC can't be finished")
        // AudioToolbox's FLAC encoder writes no audio at all for under about 4600 frames (a 0.1 to 0.4 s track),
        // without an error: such a file is refused here rather than sent empty.
        let written = try Reader(out)
        defer { written.close() }
        guard written.frames == info.frames else {
            throw AudioError("\(out.path): AudioToolbox wrote \(written.frames) of \(info.frames) frames as FLAC")
        }
    }

    /// All of `url` decoded: its rate and its samples, interleaved.
    public static func decode(_ url: URL) throws -> (rate: Int, samples: [Float]) {
        let reader = try Reader(url)
        defer { reader.close() }
        var out: [Float] = []
        while true {
            let block = try reader.read(maxFrames: reader.rate * OggOpus.BLOCK_SECONDS)
            if block.isEmpty { break }
            out += block
        }
        return (reader.rate, out)
    }

    static func pcm16(rate: Int, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
    }

    static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw AudioError("\(what) (OSStatus \(status))") }
    }

    /// A file AudioToolbox reads (FLAC among them), decoded to interleaved floats block by block.
    public final class Reader: AudioSource {
        public let rate: Int
        public let channels: Int
        public let frames: Int
        private let file: ExtAudioFileRef
        private var closed = false
        private var given = 0

        public init(_ url: URL) throws {
            var opened: ExtAudioFileRef?
            try check(ExtAudioFileOpenURL(url as CFURL, &opened), "\(url.lastPathComponent) is no audio AudioToolbox reads")
            guard let opened else { throw AudioError("\(url.lastPathComponent) is no audio AudioToolbox reads") }
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var length: Int64 = 0
            var lengthSize = UInt32(MemoryLayout<Int64>.size)
            let a = ExtAudioFileGetProperty(opened, kExtAudioFileProperty_FileDataFormat, &size, &format)
            let b = ExtAudioFileGetProperty(opened, kExtAudioFileProperty_FileLengthFrames, &lengthSize, &length)
            let rateOK = format.mSampleRate.isFinite && format.mSampleRate >= 1 && format.mSampleRate <= 1e7
                && format.mSampleRate == format.mSampleRate.rounded()
            guard a == noErr, b == noErr, rateOK, (1...64).contains(format.mChannelsPerFrame), length >= 0 else {
                ExtAudioFileDispose(opened)
                throw AudioError("\(url.lastPathComponent) is no audio AudioToolbox reads")
            }
            rate = Int(format.mSampleRate)
            channels = Int(format.mChannelsPerFrame)
            frames = Int(length)
            var client = AudioStreamBasicDescription(
                mSampleRate: format.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
            let c = ExtAudioFileSetProperty(opened, kExtAudioFileProperty_ClientDataFormat,
                                            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
            guard c == noErr else {
                ExtAudioFileDispose(opened)
                throw AudioError("\(url.lastPathComponent) can't be decoded (OSStatus \(c))")
            }
            file = opened
        }

        deinit { close() }

        public func close() {
            guard !closed else { return }
            closed = true
            ExtAudioFileDispose(file)
        }

        public func read(maxFrames: Int) throws -> [Float] {
            guard !closed else { throw AudioError("read after close") }
            let want = max(0, min(maxFrames, frames - given))
            var out = [Float](repeating: 0, count: want * channels)
            var done = 0
            while done < want {
                var count = UInt32(want - done)
                let status = out.withUnsafeMutableBufferPointer { buf -> OSStatus in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels), mDataByteSize: count * UInt32(4 * channels),
                        mData: UnsafeMutableRawPointer(buf.baseAddress! + done * channels)))
                    return ExtAudioFileRead(file, &count, &list)
                }
                try check(status, "the audio can't be decoded")
                if count == 0 { break }
                done += Int(count)
            }
            given += done
            return done == want ? out : Array(out[0..<(done * channels)])
        }
    }
}
