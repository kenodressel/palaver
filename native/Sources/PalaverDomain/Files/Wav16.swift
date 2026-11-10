// 16-bit PCM WAV files as Python's soundfile (libsndfile) reads and writes them: our own RIFF reader and writer, so
// a read never comes back short (AVAudioFile may) and a written file is byte for byte what `sf.write(...,
// subtype="PCM_16")` writes: the canonical 44-byte header (RIFF, a 16-byte `fmt ` chunk, `data`), then the samples.
// Samples go in and out interleaved, little-endian; files are read and written in chunks, never whole.
import Darwin
import Foundation

public struct WavError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct Wav16 {
    /// What `sf.info` says of a file, and where its samples are.
    public struct Info: Equatable, Sendable {
        public let rate: Int
        public let channels: Int
        /// Whole frames in the data chunk: its size, or what the file holds when the header says more (a file cut
        /// short) or 0 (a `.part` file whose header is patched only at the end).
        public let frames: Int
        /// The first sample's byte offset.
        public let dataOffset: Int

        public var duration: Double { Double(frames) / Double(rate) }
        var blockAlign: Int { 2 * channels }
    }

    /// Bytes per read or write.
    static let CHUNK_BYTES = 1 << 20

    // MARK: - Reading

    /// The file's format and length. Throws for a file that is no 16-bit PCM WAV (RIFF, little-endian).
    public static func info(_ url: URL) throws -> Info {
        let file = try File(url, write: false)
        defer { file.close() }
        return try parse(file)
    }

    private static func parse(_ file: File) throws -> Info {
        let size = try file.size()
        let head = try file.read(at: 0, count: 12)
        guard head.count == 12, Array(head[0..<4]) == Array("RIFF".utf8), Array(head[8..<12]) == Array("WAVE".utf8) else {
            throw WavError("\(file.path): not a RIFF WAVE file")
        }
        var at = 12
        var format: (tag: Int, channels: Int, rate: Int, bits: Int)?
        while at + 8 <= size {
            let h = try file.read(at: at, count: 8)
            guard h.count == 8 else { break }
            let id = String(decoding: h[0..<4], as: UTF8.self), length = Int(le32(h, 4))
            if id == "fmt " {
                let f = try file.read(at: at + 8, count: min(length, 40))
                guard f.count >= 16 else { throw WavError("\(file.path): a short fmt chunk") }
                var tag = Int(le16(f, 0))
                if tag == 0xFFFE, f.count >= 26 { tag = Int(le16(f, 24)) }  // WAVE_FORMAT_EXTENSIBLE: its subformat
                format = (tag, Int(le16(f, 2)), Int(le32(f, 4)), Int(le16(f, 14)))
            } else if id == "data" {
                guard let format else { throw WavError("\(file.path): data before the fmt chunk") }
                guard format.tag == 1, format.bits == 16, format.channels > 0, format.rate > 0 else {
                    throw WavError("\(file.path): not 16-bit PCM (format \(format.tag), \(format.bits) bits)")
                }
                let offset = at + 8, held = max(0, size - offset)
                let bytes = length == 0 || length > held ? held : length
                return Info(rate: format.rate, channels: format.channels, frames: bytes / (2 * format.channels), dataOffset: offset)
            }
            at += 8 + length + (length % 2)  // chunks are padded to an even size
        }
        throw WavError("\(file.path): no data chunk")
    }

    /// `sf.read(path, start=start, stop=start + frames, dtype="int16")`, interleaved: `frames` from `start` (all
    /// to the end without), fewer where the file ends. A negative `start` or `frames` throws `WavError`.
    public static func read(_ url: URL, start: Int = 0, frames: Int? = nil) throws -> [Int16] {
        let file = try File(url, write: false)
        defer { file.close() }
        let info = try parse(file)
        return try samples(file, info, start: start, frames: frames)
    }

    /// `read` as `sf.read(dtype="float32")` gives it: each sample / 32768.
    public static func readFloat(_ url: URL, start: Int = 0, frames: Int? = nil) throws -> [Float] {
        try read(url, start: start, frames: frames).map { Float($0) / 32768 }
    }

    private static func samples(_ file: File, _ info: Info, start: Int, frames: Int?) throws -> [Int16] {
        guard start >= 0, (frames ?? 0) >= 0 else { throw WavError("\(file.path): a negative start or length (\(start), \(frames ?? 0))") }
        let first = min(start, info.frames)
        let count = min(frames ?? info.frames, info.frames - first)
        var out = [Int16](repeating: 0, count: count * info.channels)
        try out.withUnsafeMutableBytes { buf in
            var done = 0
            while done < buf.count {
                let n = min(CHUNK_BYTES, buf.count - done)
                let got = try file.read(into: buf.baseAddress! + done, count: n, at: info.dataOffset + first * info.blockAlign + done)
                guard got == n else { throw WavError("\(file.path): the file got shorter while it was read") }
                done += n
            }
        }
        #if _endian(big)
        return out.map { Int16(littleEndian: $0) }
        #else
        return out
        #endif
    }

    // MARK: - Writing

    /// `sf.write(path, samples, rate, subtype="PCM_16")` (interleaved `samples` of `channels`): created 0666 less
    /// the umask, an existing file truncated (its inode kept).
    public static func write(_ samples: [Int16], rate: Int, channels: Int = 1, to url: URL) throws {
        let w = try Writer(url, rate: rate, channels: channels)
        defer { w.close() }
        try w.append(samples)
        try w.finish()
    }

    /// The 44-byte header libsndfile writes for `dataBytes` of 16-bit PCM.
    public static func header(dataBytes: Int, rate: Int, channels: Int) -> [UInt8] {
        var h: [UInt8] = []
        func put32(_ v: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { h += $0 } }
        func put16(_ v: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).littleEndian) { h += $0 } }
        h += Array("RIFF".utf8); put32(36 + dataBytes); h += Array("WAVEfmt ".utf8)
        put32(16); put16(1); put16(channels); put32(rate); put32(rate * 2 * channels); put16(2 * channels); put16(16)
        h += Array("data".utf8); put32(dataBytes)
        return h
    }

    /// A file written front to back: the header, then samples appended (in chunks), then the header again with
    /// the length.
    public final class Writer {
        private let file: File
        private let rate: Int, channels: Int
        private var bytes = 0

        public init(_ url: URL, rate: Int, channels: Int = 1) throws {
            file = try File(url, write: true)
            self.rate = rate
            self.channels = channels
            do { try file.write(Wav16.header(dataBytes: 0, rate: rate, channels: channels), at: 0) } catch { file.close(); throw error }
        }

        public func append(_ samples: [Int16]) throws {
            #if _endian(big)
            let samples = samples.map { $0.littleEndian }
            #endif
            try samples.withUnsafeBytes { try file.write($0, at: 44 + bytes) }
            bytes += 2 * samples.count
        }

        /// `count` samples of silence.
        func appendZeros(_ count: Int) throws {
            var left = count
            let zeros = [Int16](repeating: 0, count: min(count, CHUNK_BYTES / 2))
            while left > 0 {
                let n = min(left, zeros.count)
                try append(n == zeros.count ? zeros : Array(zeros[0..<n]))
                left -= n
            }
        }

        /// Frames `start..<start + frames` of `url`, in chunks.
        func append(from url: URL, start: Int = 0, frames: Int? = nil) throws {
            let src = try File(url, write: false)
            defer { src.close() }
            let info = try Wav16.parse(src)
            let first = min(start, info.frames)
            let total = min(frames ?? info.frames, info.frames - first)
            let step = max(1, CHUNK_BYTES / info.blockAlign)
            var at = first
            while at < first + total {
                let n = min(step, first + total - at)
                try append(Wav16.samples(src, info, start: at, frames: n))
                at += n
            }
        }

        public func finish() throws { try file.write(Wav16.header(dataBytes: bytes, rate: rate, channels: channels), at: 0) }

        public func close() { file.close() }
    }

    /// `sf.write(path, audio[:frames], rate)` over the file `audio` was read from: its first `frames` kept as a
    /// canonical file, in place (moved to offset 44, front to back: the data never starts before 44), the rest cut.
    static func keepFront(_ url: URL, frames: Int) throws {
        let file = try File(url, write: true, truncate: false)
        defer { file.close() }
        let info = try parse(file)
        let bytes = min(frames, info.frames) * info.blockAlign
        var buffer = [UInt8](repeating: 0, count: CHUNK_BYTES)
        var done = 0
        if info.dataOffset != 44 {
            while done < bytes {
                let n = min(CHUNK_BYTES, bytes - done)
                let got = try buffer.withUnsafeMutableBytes { try file.read(into: $0.baseAddress!, count: n, at: info.dataOffset + done) }
                guard got == n else { throw WavError("\(file.path): the file got shorter while it was read") }
                try buffer.withUnsafeBytes { try file.write(UnsafeRawBufferPointer(rebasing: $0[0..<n]), at: 44 + done) }
                done += n
            }
        }
        try file.write(header(dataBytes: bytes, rate: info.rate, channels: info.channels), at: 0)
        try file.truncate(44 + bytes)
    }

    // MARK: - Bytes

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    /// A file descriptor with positioned reads and writes that retry until done (EINTR, short counts).
    final class File {
        let path: String
        private var fd: Int32

        init(_ url: URL, write: Bool, truncate: Bool = true) throws {
            path = url.path
            let flags = write ? O_WRONLY | O_CREAT | (truncate ? O_TRUNC : 0) | O_CLOEXEC : O_RDONLY | O_CLOEXEC
            fd = write && !truncate ? Darwin.open(path, O_RDWR | O_CLOEXEC) : Darwin.open(path, flags, 0o666)
            guard fd >= 0 else { throw File.error(path) }
        }

        func close() {
            if fd >= 0 { Darwin.close(fd) }
            fd = -1
        }

        func size() throws -> Int {
            var st = stat()
            guard fstat(fd, &st) == 0 else { throw File.error(path) }
            return Int(st.st_size)
        }

        /// Up to `count` bytes at `offset`: fewer only at the end of the file.
        func read(into p: UnsafeMutableRawPointer, count: Int, at offset: Int) throws -> Int {
            var done = 0
            while done < count {
                let n = pread(fd, p + done, count - done, off_t(offset + done))
                if n < 0 { if errno == EINTR { continue }; throw File.error(path) }
                if n == 0 { break }
                done += n
            }
            return done
        }

        func read(at offset: Int, count: Int) throws -> [UInt8] {
            var out = [UInt8](repeating: 0, count: count)
            let got = try out.withUnsafeMutableBytes { try read(into: $0.baseAddress!, count: count, at: offset) }
            return Array(out[0..<got])
        }

        func write(_ bytes: UnsafeRawBufferPointer, at offset: Int) throws {
            var done = 0
            while done < bytes.count {
                let n = pwrite(fd, bytes.baseAddress! + done, bytes.count - done, off_t(offset + done))
                if n < 0 { if errno == EINTR { continue }; throw File.error(path) }
                done += n
            }
        }

        func write(_ bytes: [UInt8], at offset: Int) throws { try bytes.withUnsafeBytes { try write($0, at: offset) } }

        func truncate(_ length: Int) throws {
            guard ftruncate(fd, off_t(length)) == 0 else { throw File.error(path) }
        }

        private static func error(_ path: String) -> Error {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            return NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue),
                           userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: "\(String(cString: strerror(code.rawValue))): '\(path)'"])
        }
    }
}
