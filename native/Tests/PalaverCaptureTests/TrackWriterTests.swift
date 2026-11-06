import Foundation
import Testing
@testable import PalaverCapture

private func size(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
}

private let tone = [Int16](repeating: Int16(0.3 * 32_767), count: 8_000)

/// File I/O that fails on demand: `failAt(call)` decides per pwrite call (0-based) whether to write
/// only part of the bytes (`.partial`), fail with ENOSPC (`.fail`) or go through.
private final class FlakyIO {
    enum Outcome { case ok, partial, fail }
    var calls = 0
    var plan: (Int, Int, off_t) -> Outcome = { _, _, _ in .ok }  // (call, bytes, offset)
    var truncateFails = false

    var io: TrackWriter.FileIO {
        TrackWriter.FileIO(
            pwrite: { [self] fd, buf, n, off in
                defer { calls += 1 }
                switch plan(calls, n, off) {
                case .ok: return Darwin.pwrite(fd, buf, n, off)
                case .partial: return Darwin.pwrite(fd, buf, n / 2, off)
                case .fail: errno = ENOSPC; return -1
                }
            },
            ftruncate: { [self] fd, size in
                if truncateFails { errno = EIO; return -1 }
                return Darwin.ftruncate(fd, size)
            })
    }
}

@Suite struct TrackWriterTests {
    @Test func partialWriteFailureLeavesFramesAndFileConsistent() throws {
        // ENOSPC halfway through a chunk: the write throws, nothing of it counts, and the next chunk
        // lands exactly where it belongs (a shifted fd offset would break sample-0 alignment).
        let flaky = FlakyIO()
        let out = tempDir().appendingPathComponent("track.wav")
        let w = try TrackWriter(finalURL: out, io: flaky.io)
        let a = [Int16](repeating: 1_000, count: 4_000), b = [Int16](repeating: 2_000, count: 4_000)
        let c = [Int16](repeating: 3_000, count: 4_000)
        try w.write(a, atOffset: 0)
        let failing = flaky.calls
        flaky.plan = { call, _, _ in call == failing ? .partial : (call == failing + 1 ? .fail : .ok) }
        #expect(throws: TrackWriterError.self) { try w.write(b, atOffset: 4_000) }
        #expect(w.framesWritten == 4_000)
        #expect(size(w.partURL) == 44 + 8_000)
        try w.write(c, atOffset: 4_000)
        try w.finalize(toFrames: w.framesWritten)
        #expect(try readWav(out).samples == a + c)
    }

    @Test func failingGapPaddingRollsBack() throws {
        // The zero padding of a long gap fails after its first block: the gap is not counted either.
        let flaky = FlakyIO()
        let out = tempDir().appendingPathComponent("track.wav")
        let w = try TrackWriter(finalURL: out, io: flaky.io)
        let a = [Int16](repeating: 1_000, count: 1_000), b = [Int16](repeating: 2_000, count: 1_000)
        try w.write(a, atOffset: 0)
        let first = flaky.calls
        flaky.plan = { call, _, _ in call > first ? .fail : .ok }
        #expect(throws: TrackWriterError.self) { try w.write(b, atOffset: 101_000) }  // 200 KB of zeros first
        #expect(w.framesWritten == 1_000)
        #expect(size(w.partURL) == 44 + 2_000)
        flaky.plan = { _, _, _ in .ok }
        try w.write(b, atOffset: 101_000)
        try w.finalize(toFrames: w.framesWritten)
        let x = try readWav(out).samples
        #expect(x.count == 102_000 && Array(x[0..<1_000]) == a && Array(x[101_000...]) == b)
        #expect(maxAbs(x[1_000..<101_000]) == 0)
    }

    @Test func failedTruncateStillPatchesTheHeader() throws {
        // finalize fails: the .part is kept, and its header states what was written, never data size 0.
        let flaky = FlakyIO()
        let out = tempDir().appendingPathComponent("track.wav")
        let w = try TrackWriter(finalURL: out, io: flaky.io)
        try w.write(tone, atOffset: 0)
        flaky.truncateFails = true
        #expect(throws: TrackWriterError.self) { try w.finalize(toFrames: 8_000) }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        let wav = try readWav(w.partURL)
        #expect(wav.dataSize == 16_000 && wav.samples.count == 8_000)
    }

    @Test func failedHeaderWriteIsRetriedBeforeClosing() throws {
        let flaky = FlakyIO()
        let out = tempDir().appendingPathComponent("track.wav")
        let w = try TrackWriter(finalURL: out, io: flaky.io)
        try w.write(tone, atOffset: 0)
        var failed = false
        flaky.plan = { _, _, off in
            if off == 0 && !failed { failed = true; return .fail }
            return .ok
        }
        #expect(throws: TrackWriterError.self) { try w.finalize(toFrames: 8_000) }
        #expect(failed)
        #expect(try readWav(w.partURL).dataSize == 16_000)
    }

    @Test func aFailedHeaderAfterTheCutDoesNotBringZerosBack() throws {
        // finalize cuts 8000 frames to 4000, then every header write fails: the .part must not be
        // re-extended with zeros over the cut data.
        let flaky = FlakyIO()
        let out = tempDir().appendingPathComponent("track.wav")
        let w = try TrackWriter(finalURL: out, io: flaky.io)
        try w.write(tone, atOffset: 0)
        flaky.plan = { _, _, off in off == 0 ? .fail : .ok }
        #expect(throws: TrackWriterError.self) { try w.finalize(toFrames: 4_000) }
        #expect(size(w.partURL) == 44 + 8_000)
    }

    @Test func aFailedFirstHeaderAfterTheCutIsPatchedToTheLengthOnDisk() throws {
        let flaky = FlakyIO()
        let out = tempDir().appendingPathComponent("track.wav")
        let w = try TrackWriter(finalURL: out, io: flaky.io)
        try w.write(tone, atOffset: 0)
        var failed = false
        flaky.plan = { _, _, off in
            if off == 0 && !failed { failed = true; return .fail }
            return .ok
        }
        #expect(throws: TrackWriterError.self) { try w.finalize(toFrames: 4_000) }
        #expect(size(w.partURL) == 44 + 8_000)
        let wav = try readWav(w.partURL)
        #expect(wav.dataSize == 8_000 && wav.samples == Array(tone.prefix(4_000)))
    }

    @Test func headerIsPythonsLayout() {
        // struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + n, b"WAVE", b"fmt ", 16, 1, 1, 16000, 32000, 2, 16, b"data", n)
        let expected: [UInt8] = [0x52, 0x49, 0x46, 0x46, 0x2C, 0x00, 0x01, 0x00, 0x57, 0x41, 0x56, 0x45,
                                 0x66, 0x6D, 0x74, 0x20, 0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
                                 0x80, 0x3E, 0x00, 0x00, 0x00, 0x7D, 0x00, 0x00, 0x02, 0x00, 0x10, 0x00,
                                 0x64, 0x61, 0x74, 0x61, 0x08, 0x00, 0x01, 0x00]
        #expect(TrackWriter.wavHeader(dataBytes: 65_544) == expected)
        #expect(TrackWriter.wavHeader(dataBytes: 0).count == 44)
    }

    @Test func partFileGrowsDuringWrites() throws {
        let out = tempDir().appendingPathComponent("track.wav")
        let w = try TrackWriter(finalURL: out)
        #expect(size(w.partURL) == 44)
        #expect(try readWav(w.partURL).dataSize == 0)  // placeholder header
        let second = [Int16](repeating: 3_276, count: 16_000)
        try w.write(second, atOffset: 0)
        #expect(size(w.partURL) == 44 + 32_000)  // visible at once, no user-space buffer
        try w.write(second, atOffset: 16_000)
        #expect(size(w.partURL) == 44 + 64_000)
        try w.finalize(toFrames: 32_000)
        #expect(!FileManager.default.fileExists(atPath: w.partURL.path))
        let wav = try readWav(out)
        #expect(wav.samples.count == 32_000 && wav.dataSize == 64_000 && wav.riffSize == 64_036 && wav.sampleRate == 16_000)
    }

    @Test func gapIsZeroPadded() throws {
        let out = tempDir().appendingPathComponent("track.wav")
        let w = try TrackWriter(finalURL: out)
        let s = [Int16](repeating: 16_383, count: 1_600)
        try w.write(s, atOffset: 0)
        try w.write(s, atOffset: 9_600)  // 0.5 s gap
        try w.finalize(toFrames: 11_200)
        let x = try readWav(out).samples
        #expect(x.count == 11_200)
        #expect(meanAbs(x[0..<1_600]) > 1_000)
        #expect(maxAbs(x[1_600..<9_600]) == 0)
        #expect(meanAbs(x[9_600..<11_200]) > 1_000)
    }

    @Test func abortPatchesHeader() throws {
        // A crash: no rename, but the .part's header states what was written.
        let out = tempDir().appendingPathComponent("track.wav")
        let w = try TrackWriter(finalURL: out)
        try w.write(tone, atOffset: 0)
        w.abort()
        #expect(FileManager.default.fileExists(atPath: w.partURL.path))
        #expect(!FileManager.default.fileExists(atPath: out.path))
        let wav = try readWav(w.partURL)
        #expect(wav.dataSize == 16_000 && wav.riffSize == 16_036 && wav.samples.count == 8_000)
        #expect(meanAbs(wav.samples[...]) > 1_000)
        // Closed: later calls do nothing.
        try w.write(tone, atOffset: 8_000)
        try w.finalize(toFrames: 1)
        #expect(size(w.partURL) == 44 + 16_000)
    }

    @Test func negativeAndOutOfOrderOffsetsAreDropped() throws {
        let out = tempDir().appendingPathComponent("track.wav")
        let w = try TrackWriter(finalURL: out)
        let s = [Int16](repeating: 6_553, count: 1_000)
        try w.write(s, atOffset: -100)
        #expect(w.framesWritten == 0)
        try w.write(s, atOffset: 0)
        try w.write(s, atOffset: 500)
        try w.write([], atOffset: 2_000)
        #expect(w.framesWritten == 1_000)
        try w.finalize(toFrames: 1_000)
        #expect(try readWav(out).samples.count == 1_000)
    }

    @Test func finalizeTruncatesOrExtendsAndReplaces() throws {
        let dir = tempDir()
        let out = dir.appendingPathComponent("track.wav")
        try Data("old".utf8).write(to: out)
        let w = try TrackWriter(finalURL: out)
        try w.write(tone, atOffset: 0)
        try w.finalize(toFrames: 5_000)
        #expect(try readWav(out).samples.count == 5_000)
        let w2 = try TrackWriter(finalURL: out)
        try w2.write(tone, atOffset: 0)
        try w2.finalize(toFrames: 9_000)
        let x = try readWav(out)
        #expect(x.samples.count == 9_000 && x.dataSize == 18_000 && maxAbs(x.samples[8_000...]) == 0)
    }

    @Test func emptyTrackIsAnEmptyWav() throws {
        let out = tempDir().appendingPathComponent("track.wav")
        try TrackWriter(finalURL: out).finalize(toFrames: 0)
        let wav = try readWav(out)
        #expect(wav.samples.isEmpty && wav.dataSize == 0 && wav.header == TrackWriter.wavHeader(dataBytes: 0))
    }

    @Test(.enabled(if: hasPython, "needs the repo's .venv"))
    func bytesMatchPythonsWriter() throws {
        // The same writes through Python's _IncrementalTrackWriter and this one: finalized and aborted.
        let writes: [(Int, [Int16])] = [(0, [1, -1, 32_767, -32_768, 0, 12_345]), (3, [7, 7]), (-5, [9]),
                                         (100, (0..<300).map { Int16($0 * 97 % 65_536 - 32_768) }), (420, [5])]
        for finalize in [Int?.none, 300, 450] {
            let dir = tempDir()
            let spec: [String: Any] = ["writes": writes.map { [$0.0, $0.1.map(Int.init)] },
                                       "finalize": finalize.map { $0 as Any } ?? NSNull()]
            let specURL = dir.appendingPathComponent("spec.json")
            try JSONSerialization.data(withJSONObject: spec).write(to: specURL)
            let py = dir.appendingPathComponent("py.wav"), sw = dir.appendingPathComponent("swift.wav")
            _ = try runPython(pythonWriter, [specURL.path, py.path])
            let w = try TrackWriter(finalURL: sw)
            for (offset, samples) in writes { try w.write(samples, atOffset: offset) }
            if let finalize { try w.finalize(toFrames: finalize) } else { w.abort() }
            let suffix = finalize == nil ? ".part" : ""
            let pyBytes = try Data(contentsOf: URL(fileURLWithPath: py.path + suffix))
            let swBytes = try Data(contentsOf: URL(fileURLWithPath: sw.path + suffix))
            #expect(pyBytes.count > 44)
            #expect(pyBytes == swBytes, "finalize \(String(describing: finalize))")
        }
    }
}
