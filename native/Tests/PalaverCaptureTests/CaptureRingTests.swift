import Foundation
import Testing
@testable import PalaverCapture

@Suite struct CaptureRingTests {
    private let float = PCMFormat(sampleRate: 48_000, formatFlags: PCMFormat.flagIsFloat, channels: 2, bitsPerChannel: 32)

    @Test func keepsOrderFormatAndStampAcrossTheWrap() {
        // A small ring, so records wrap around its end many times.
        let ring = CaptureRing(capacity: 1_000)
        var buffer: [UInt8] = []
        for k in 0..<500 {
            let bytes = (0..<(k % 7 + 1) * 12).map { UInt8(truncatingIfNeeded: $0 &+ k) }
            let format = k % 2 == 0 ? float : PCMFormat(sampleRate: 24_000, formatFlags: 0xC, channels: 1, bitsPerChannel: 16)
            #expect(bytes.withUnsafeBytes { ring.push(pts: Int64(k) * 1_000, format: format, bytes: $0) })
            let got = ring.pop(into: &buffer)
            #expect(got?.pts == Int64(k) * 1_000 && got?.format == format && buffer == bytes)
        }
        #expect(ring.isEmpty && ring.pop(into: &buffer) == nil && ring.takeDropped() == 0)
    }

    @Test func aFullRingDropsAndCounts() {
        let ring = CaptureRing(capacity: 256)
        let bytes = [UInt8](repeating: 7, count: 80)  // 40-byte header + 80 = 120 bytes a record
        var pushed = 0
        for _ in 0..<5 where bytes.withUnsafeBytes({ ring.push(pts: 1, format: float, bytes: $0) }) { pushed += 1 }
        #expect(pushed == 2 && ring.takeDropped() == 3 && ring.takeDropped() == 0)
        let tooBig = [UInt8](repeating: 1, count: 300)
        #expect(!tooBig.withUnsafeBytes { ring.push(pts: 1, format: float, bytes: $0) })
        #expect(![UInt8]().withUnsafeBytes { ring.push(pts: 1, format: float, bytes: $0) })  // empty: ignored, not counted
        #expect(ring.takeDropped() == 1)
        var buffer: [UInt8] = []
        #expect(ring.pop(into: &buffer) != nil && ring.pop(into: &buffer) != nil && ring.pop(into: &buffer) == nil)
        #expect(bytes.withUnsafeBytes { ring.push(pts: 2, format: float, bytes: $0) })  // room again
    }

    @Test func producersAndTheConsumerOnDifferentThreads() async {
        // Two producers (a late ScreenCaptureKit start overlapping the new one) and one consumer.
        let ring = CaptureRing(capacity: 4_096)
        let perProducer = 20_000
        let consumed = Locked<[Int64: Int]>([:])
        let done = Locked(0)
        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<2 {
                group.addTask {
                    var k = 0
                    while k < perProducer {
                        let value = Int64(producer * perProducer + k)
                        let ok = withUnsafeBytes(of: value) { ring.push(pts: value, format: self.float, bytes: $0) }
                        if ok { k += 1 } else { await Task.yield() }
                    }
                    done.with { $0 += 1 }
                }
            }
            group.addTask {
                var buffer: [UInt8] = []
                while true {
                    if let (pts, _) = ring.pop(into: &buffer) {
                        let payload = buffer.withUnsafeBytes { $0.load(as: Int64.self) }
                        #expect(payload == pts)
                        consumed.with { $0[pts / Int64(perProducer), default: 0] += 1 }
                    } else if done.get == 2, ring.isEmpty {
                        break
                    } else {
                        await Task.yield()
                    }
                }
            }
        }
        #expect(consumed.get == [0: perProducer, 1: perProducer])
    }
}
