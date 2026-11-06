// The `.part` writer (capture_recorder.py:306-411, `_IncrementalTrackWriter`).
import Darwin
import Foundation

public enum TrackWriterError: Error, Equatable, CustomStringConvertible {
    case io(String, Int32)

    public var description: String {
        switch self {
        case let .io(what, code): return "\(what): \(String(cString: strerror(code)))"
        }
    }
}

/// Streams 16 kHz mono PCM16 to `<final>.part`.
///
/// - Opening writes a 44-byte WAV header with data size 0, so the file is a
///   WAV from the first byte.
/// - `write(_:atOffset:)` appends, zero-padding a gap up to the offset. An
///   offset before the end (negative or out of order) is dropped.
/// - `finalize(toFrames:)` truncates (or zero-extends) to that length,
///   patches the header and renames `.part` → final.
/// - `abort()` patches the header to what was written, in place, without the
///   rename (crash forensics). After a SIGKILL the header stays at 0.
///
/// Writes go straight to the file descriptor (no user-space buffer), so a
/// reader of the `.part` (the level tracker) sees each chunk at once. They
/// are positional (`pwrite` at 44 + frames × 2): a write that fails partway
/// (ENOSPC) throws, is not counted, and the file is cut back to what is
/// counted, so `framesWritten` always equals the valid frames on disk and a
/// later chunk still lands at its true position. A finalize that fails leaves
/// the `.part` with a header stating what it holds (the counted frames, or the
/// cut length once the cut is done), never data size 0.
/// All calls are serialised by a lock; `framesWritten` can be read from any thread.
public final class TrackWriter: @unchecked Sendable {
    public static let headerSize = 44
    public static let sampleRate = captureSampleRate

    /// The two file calls that can fail on a full disk; tests inject failing ones.
    struct FileIO {
        var pwrite: (Int32, UnsafeRawPointer, Int, off_t) -> Int
        var ftruncate: (Int32, off_t) -> Int32
        static let system = FileIO(pwrite: { Darwin.pwrite($0, $1, $2, $3) }, ftruncate: { Darwin.ftruncate($0, $1) })
    }

    public let finalURL: URL
    public let partURL: URL
    private var fd: Int32
    private var frames = 0
    private var closed = false
    private let lock = NSLock()
    private let io: FileIO

    public convenience init(finalURL: URL) throws {
        try self.init(finalURL: finalURL, io: .system)
    }

    init(finalURL: URL, io: FileIO) throws {
        self.finalURL = finalURL
        self.io = io
        partURL = URL(fileURLWithPath: finalURL.path + ".part")
        fd = open(partURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw TrackWriterError.io("cannot open \(partURL.path)", errno) }
        do { try writeHeader(dataBytes: 0) } catch { close(fd); throw error }
    }

    deinit {
        if !closed { close(fd) }
    }

    public var framesWritten: Int { lock.withLock { frames } }

    /// A 44-byte PCM16 mono WAV header (`_wav_header`, `struct.pack("<4sI4s4sIHHIIHH4sI", …)`).
    public static func wavHeader(dataBytes: Int, sampleRate: Int = captureSampleRate) -> [UInt8] {
        var h: [UInt8] = []
        h.reserveCapacity(headerSize)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        let channels = 1, bits = 16
        h.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(truncatingIfNeeded: 36 + dataBytes))
        h.append(contentsOf: Array("WAVE".utf8)); h.append(contentsOf: Array("fmt ".utf8))
        u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * bits / 8)); u16(UInt16(channels * bits / 8)); u16(UInt16(bits))
        h.append(contentsOf: Array("data".utf8)); u32(UInt32(truncatingIfNeeded: dataBytes))
        return h
    }

    /// Writes `samples` at frame `offset` (`write_chunk_at_offset`).
    public func write(_ samples: [Int16], atOffset offset: Int) throws {
        try lock.withLock {
            guard !closed, !samples.isEmpty, offset >= 0, offset >= frames else { return }
            do {
                if offset > frames { try writeZeros(frames: offset - frames, at: frames) }
                try samples.withUnsafeBytes { try writeAll($0, atFrame: offset) }
            } catch {
                // Nothing of this call counts: cut the file back to the counted frames.
                _ = io.ftruncate(fd, off_t(Self.headerSize + frames * 2))
                throw error
            }
            frames = offset + samples.count
        }
    }

    /// Truncates to `total` frames, patches the header and renames to the final path.
    public func finalize(toFrames total: Int) throws {
        try lock.withLock {
            guard !closed else { return }
            closed = true
            defer { close(fd) }
            var cut = false
            do {
                guard io.ftruncate(fd, off_t(Self.headerSize + total * 2)) == 0 else {
                    let code = errno
                    throw TrackWriterError.io("cannot truncate \(partURL.path)", code)
                }
                cut = true
                try writeHeader(dataBytes: total * 2)
            } catch {
                // Best effort: a header that states what the .part holds. Before the cut that is the
                // counted frames; after it, the length on disk (never zeros brought back over the cut).
                if cut {
                    var st = stat()
                    let onDisk = fstat(fd, &st) == 0 ? max(0, Int(st.st_size) - Self.headerSize) : total * 2
                    try? writeHeader(dataBytes: onDisk)
                } else {
                    _ = io.ftruncate(fd, off_t(Self.headerSize + frames * 2))
                    try? writeHeader(dataBytes: frames * 2)
                }
                throw error
            }
            guard rename(partURL.path, finalURL.path) == 0 else {
                throw TrackWriterError.io("cannot rename \(partURL.path)", errno)
            }
        }
    }

    /// Closes without renaming; the `.part`'s header states what was written.
    public func abort() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            try? writeHeader(dataBytes: frames * 2)
            close(fd)
        }
    }

    // MARK: - private (under the lock)

    private func writeHeader(dataBytes: Int) throws {
        try Self.wavHeader(dataBytes: dataBytes).withUnsafeBytes { try write($0, at: 0) }
    }

    private func writeAll(_ raw: UnsafeRawBufferPointer, atFrame frame: Int) throws {
        try write(raw, at: Self.headerSize + frame * 2)
    }

    /// Every byte of `raw` at byte `position`, or a throw.
    private func write(_ raw: UnsafeRawBufferPointer, at position: Int) throws {
        var done = 0
        while done < raw.count {
            let n = io.pwrite(fd, raw.baseAddress! + done, raw.count - done, off_t(position + done))
            if n < 0 {
                let code = errno
                if code == EINTR { continue }
                throw TrackWriterError.io("cannot write \(partURL.path)", code)
            }
            if n == 0 { throw TrackWriterError.io("cannot write \(partURL.path)", EIO) }
            done += n
        }
    }

    private static let zeroBlock = [UInt8](repeating: 0, count: 64 * 1024)

    private func writeZeros(frames gap: Int, at frame: Int) throws {
        var position = Self.headerSize + frame * 2
        var left = gap * 2
        try Self.zeroBlock.withUnsafeBytes { block in
            while left > 0 {
                let n = min(left, block.count)
                try write(UnsafeRawBufferPointer(rebasing: block[0..<n]), at: position)
                position += n
                left -= n
            }
        }
    }
}
