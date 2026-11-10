// A track the recorder may still be writing (live.py:122-168): 16 kHz mono PCM_16 in `<name>.part`, whose header is
// patched only at the end, or the finished `<name>`. Read as raw bytes past the 44-byte header, never by parsing the
// header of a file still being written; reads past the written end are silence. And `quietestCut`, where a block of
// audio is cut so no sentence is split.
import Darwin
import Foundation

public final class GrowingTrack {
    public static let HEADER_BYTES = 44

    private let final: URL
    private let part: URL

    /// The track that ends up at `final` (`<final>.part` while it is recorded).
    public init(final: URL) {
        self.final = final
        part = URL(fileURLWithPath: final.path + ".part")
    }

    /// Samples written so far: the `.part` file's while it exists, else the final file's; 0 when neither does.
    public func available() -> Int {
        for url in [part, final] {  // a .part renamed to the final name in between: the final one
            var st = stat()
            if stat(url.path, &st) == 0 { return max(0, (Int(st.st_size) - Self.HEADER_BYTES) / 2) }
        }
        return 0
    }

    /// Samples `start..<end` as written (little-endian int16): zeros past the written end, and where neither file
    /// exists. A half-written last sample is not read. A negative `start` throws `WavError` (as numpy's seek would).
    public func readInt16(_ start: Int, _ end: Int) throws -> [Int16] {
        guard start >= 0 else { throw WavError("\(final.path): a negative start (\(start))") }
        var out = [Int16](repeating: 0, count: max(0, end - start))
        for url in [part, final] {
            let fd = open(url.path, O_RDONLY | O_CLOEXEC)
            if fd < 0 { continue }  // not there (any more): the other one
            defer { close(fd) }
            out.withUnsafeMutableBytes { buf in
                var done = 0
                while done < buf.count {
                    let n = pread(fd, buf.baseAddress! + done, buf.count - done, off_t(Self.HEADER_BYTES + 2 * start + done))
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    done += n
                }
                if done % 2 == 1 { buf[done - 1] = 0 }  // half a sample
            }
            break
        }
        #if _endian(big)
        return out.map { Int16(littleEndian: $0) }
        #else
        return out
        #endif
    }

    /// `readInt16` as the engines take it: each sample / 32768.
    public func read(_ start: Int, _ end: Int) throws -> [Float] { try readInt16(start, end).map { Float($0) / 32768 } }

    /// `quietest_cut`: the index in [earliest, latest] at the centre of the quietest `frame` (50 ms at 16 kHz):
    /// `latest` when there is less than a frame. Energy as numpy computes it on float32 (squares, pairwise sums,
    /// / frame), the first of equal ones. `samples` may be int16 values or / 32768: the same cut.
    public static func quietestCut(_ samples: [Float], earliest: Int, latest: Int, frame: Int = 800) -> Int {
        if latest - earliest < frame { return latest }
        let lo = min(max(earliest, 0), samples.count), hi = min(max(latest, lo), samples.count)
        let frames = (hi - lo) / frame
        guard frames > 0 else { return latest }  // numpy: argmin of nothing raises
        var best = 0
        var least = Float.infinity
        samples.withUnsafeBufferPointer { s in
            for k in 0..<frames {
                let energy = NumpyReduce.sumOfSquares(s, from: lo + k * frame, count: frame) / Float(frame)
                if energy < least { least = energy; best = k }
            }
        }
        return earliest + best * frame + frame / 2
    }
}
