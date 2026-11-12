// A track still being recorded (live.py's GrowingTrack and quietest_cut, test_live.py).
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct GrowingTrackTests {
    private static let SR = 16_000

    /// What the recorder does: placeholder header, then appended samples.
    private func append(_ url: URL, _ samples: [Int16]) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data(Wav16.header(dataBytes: 0, rate: Self.SR, channels: 1)).write(to: url)
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        var data = Data()
        for s in samples { withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) } }
        try h.write(contentsOf: data)
    }

    private func finalize(_ final: URL) throws {
        let part = URL(fileURLWithPath: final.path + ".part")
        let data = try Data(contentsOf: part).dropFirst(44)
        try (Data(Wav16.header(dataBytes: data.count, rate: Self.SR, channels: 1)) + data).write(to: final)
        try FileManager.default.removeItem(at: part)
    }

    @Test func test_growing_track_reads_part_then_final_and_pads_with_silence() throws {
        let temp = TempFolder("live"); defer { temp.remove() }
        let final = temp.url.appendingPathComponent("system.wav")
        let track = GrowingTrack(final: final)
        #expect(track.available() == 0)
        try append(URL(fileURLWithPath: final.path + ".part"), (1...100).map { Int16($0) })
        #expect(track.available() == 100)
        #expect(try track.readInt16(98, 103) == [99, 100, 0, 0, 0])
        try finalize(final)
        #expect(try track.available() == 100 && track.readInt16(0, 3) == [1, 2, 3])
        #expect(try track.read(0, 2) == [1 / 32768, 2 / 32768])
    }

    @Test func aHalfWrittenSampleAndAMissingTrackReadAsSilence() throws {
        let temp = TempFolder("live"); defer { temp.remove() }
        let final = temp.url.appendingPathComponent("mic_raw.wav")
        #expect(try GrowingTrack(final: final).readInt16(0, 4) == [0, 0, 0, 0])
        try append(URL(fileURLWithPath: final.path + ".part"), [7, 8])
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: final.path + ".part"))
        try h.seekToEnd(); try h.write(contentsOf: Data([0x09])); try h.close()
        #expect(try GrowingTrack(final: final).readInt16(0, 4) == [7, 8, 0, 0])
        #expect(try GrowingTrack(final: final).readInt16(3, 3).isEmpty)
    }

    @Test func aNegativeStartIsAnErrorNotATrap() throws {
        let temp = TempFolder("live"); defer { temp.remove() }
        let track = GrowingTrack(final: temp.url.appendingPathComponent("system.wav"))
        #expect(throws: WavError.self) { try track.readInt16(-1, 4) }
        #expect(throws: WavError.self) { try track.read(-5, 0) }
    }

    @Test func test_quietest_cut_lands_in_the_pause() {
        var audio = [Float](repeating: 3000, count: 10 * Self.SR)
        for i in (7 * Self.SR)..<(7 * Self.SR + 4000) { audio[i] = 0 }
        let cut = GrowingTrack.quietestCut(audio, earliest: 5 * Self.SR, latest: 10 * Self.SR)
        #expect(7 * Self.SR <= cut && cut < 7 * Self.SR + 4000)
    }

}
