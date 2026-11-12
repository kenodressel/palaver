// WAV files (Wav16): partial reads, files cut short or still being recorded, files that are no 16-bit PCM, long files.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct Wav16Tests {
    private static func bytes(_ hex: String) -> Data {
        var out = Data()
        var it = hex.makeIterator()
        while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
        return out
    }

    private func file(_ temp: TempFolder, _ name: String, _ data: Data) -> URL {
        let url = temp.url.appendingPathComponent(name)
        try! data.write(to: url)
        return url
    }

    private static func ints(_ v: JSONValue?) -> [Int16] { (v?.arrayValue ?? []).map { Int16(try! Goldens.int($0)) } }

    @Test func aPartFileWhoseHeaderSaysNothingYetIsReadToItsEnd() throws {
        // The recorder's .part: a header with data size 0, patched only when the recording stops.
        let temp = TempFolder("wav"); defer { temp.remove() }
        var data = Data(Wav16.header(dataBytes: 0, rate: 16_000, channels: 1))
        for v: Int16 in [5, -6, 7] { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(0x01)  // half a sample, still being written
        let url = file(temp, "system.wav.part", data)
        #expect(try Wav16.info(url).frames == 3)
        #expect(try Wav16.read(url) == [5, -6, 7])
    }

    @Test func aFileThatIsNo16BitPcmWavIsRefused() throws {
        let temp = TempFolder("wav"); defer { temp.remove() }
        #expect(throws: WavError.self) { try Wav16.info(file(temp, "a.wav", Data("not a wav".utf8))) }
        var float = Data(Wav16.header(dataBytes: 8, rate: 16_000, channels: 1))
        float[20] = 3  // WAVE_FORMAT_IEEE_FLOAT
        float[34] = 32
        float.append(Data(count: 8))
        #expect(throws: WavError.self) { try Wav16.read(file(temp, "f.wav", float)) }
        #expect(throws: (any Error).self) { try Wav16.info(temp.url.appendingPathComponent("missing.wav")) }
    }

    @Test func aNegativeStartOrLengthIsAnErrorNotATrap() throws {
        let temp = TempFolder("wav"); defer { temp.remove() }
        let url = temp.url.appendingPathComponent("a.wav")
        try Wav16.write([1, 2, 3], rate: 16_000, to: url)
        #expect(throws: WavError.self) { try Wav16.read(url, start: -1) }
        #expect(throws: WavError.self) { try Wav16.read(url, start: 0, frames: -2) }
        #expect(throws: WavError.self) { try Wav16.readFloat(url, start: -3, frames: 1) }
        #expect(try Wav16.read(url, start: 1, frames: 0) == [])
    }

    @Test func aLongFileIsWrittenAndReadInChunks() throws {
        let temp = TempFolder("wav"); defer { temp.remove() }
        let samples = (0..<(Wav16.CHUNK_BYTES + 12_345)).map { Int16(truncatingIfNeeded: $0 &* 7) }
        let src = temp.url.appendingPathComponent("src.wav"), url = temp.url.appendingPathComponent("long.wav")
        try Wav16.write(samples, rate: 16_000, to: src)
        #expect(try Wav16.read(src) == samples)
        let w = try Wav16.Writer(url, rate: 16_000)
        try w.append(Array(samples[0..<1000]))
        try w.appendZeros(Wav16.CHUNK_BYTES / 2 + 3)
        try w.append(from: src, start: 10, frames: Wav16.CHUNK_BYTES)
        try w.finish()
        w.close()
        let back = try Wav16.read(url)
        #expect(back.count == 1000 + Wav16.CHUNK_BYTES / 2 + 3 + Wav16.CHUNK_BYTES)
        #expect(Array(back[0..<1000]) == Array(samples[0..<1000]))
        #expect(back[1000..<(1000 + Wav16.CHUNK_BYTES / 2 + 3)].allSatisfy { $0 == 0 })
        #expect(Array(back.suffix(Wav16.CHUNK_BYTES)) == Array(samples[10..<(10 + Wav16.CHUNK_BYTES)]))
        #expect(try Wav16.read(url, start: back.count - 2, frames: 10) == Array(back.suffix(2)))
    }
}
