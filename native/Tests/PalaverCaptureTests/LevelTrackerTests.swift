import Foundation
import Testing
@testable import PalaverCapture

// tests/test_meter.py, the tracker's part: the live level of the `.part` files.

private let header = Data(repeating: 0, count: 44)

private func append(_ url: URL, _ samples: [Double]) throws {
    var data = Data()
    for s in samples { withUnsafeBytes(of: Int16(max(-32_768, min(32_767, s.rounded()))).littleEndian) { data.append(contentsOf: $0) } }
    let h = try FileHandle(forWritingTo: url)
    defer { try? h.close() }
    try h.seekToEnd()
    try h.write(contentsOf: data)
}

private func toneSamples(_ seconds: Double, _ amp: Double) -> [Double] {
    (0..<Int(seconds * 16_000)).map { amp * 32_767 * sin(2 * .pi * 220 * Double($0) / 16_000) }
}

private func part(_ name: String) throws -> URL {
    let url = tempDir().appendingPathComponent(name)
    try header.write(to: url)
    return url
}

@Suite struct LevelTrackerTests {
    @Test func levelOfAFullScaleSineIsAboutMinus3() {
        var data = Data()
        for s in toneSamples(0.5, 1) { withUnsafeBytes(of: Int16(s.rounded()).littleEndian) { data.append(contentsOf: $0) } }
        #expect(abs(levelDbfs(data)! + 3) < 0.2)
    }

    @Test func digitalSilenceAndNothingAreNil() {
        #expect(levelDbfs(Data(repeating: 0, count: 1600)) == nil)
        #expect(levelDbfs(Data()) == nil)
    }

    @Test func theBarFillsWithTheLevel() {
        #expect(levelBar(nil) == "        ")
        #expect(levelBar(-70) == "        ")
        #expect(levelBar(0) == "████████")
        #expect(levelBar(-30) == "████    ")
        #expect(levelBar(-30).count == 8)
    }

    @Test func reportsLevelsAndSilenceWithoutPrinting() throws {
        let mic = try part("mic.part")
        let now = Locked(0.0)
        let tracker = LevelTracker(tracks: [("mic", mic)], clock: { now.get })
        try append(mic, toneSamples(1, 0.1))
        now.with { $0 = 1 }
        var r = tracker.read()
        #expect(r.count == 1 && r[0].label == "mic" && Int(r[0].db!.rounded()) == -23 && r[0].silentFor == 0)
        now.with { $0 = 4 }
        r = tracker.read()
        #expect(r[0].db == nil && r[0].silentFor == 3)
    }

    @Test func onlyNewlyWrittenAudioIsMeasured() throws {
        // The process tap stops writing during silence; re-reading the file tail would show stale audio.
        let mic = try part("mic.part"), system = try part("system.part")
        let now = Locked(0.0)
        let tracker = LevelTracker(tracks: [("mic", mic), ("system", system)], clock: { now.get })
        try append(mic, toneSamples(1, 0.1))
        try append(system, toneSamples(1, 0.5))
        now.with { $0 = 1 }
        var r = tracker.read()
        #expect(Int(r[0].db!.rounded()) == -23 && Int(r[1].db!.rounded()) == -9)
        try append(mic, toneSamples(1, 0.1))  // system stops growing
        now.with { $0 = 6 }
        r = tracker.read()
        #expect(Int(r[0].db!.rounded()) == -23 && r[1].db == nil && r[1].silentFor == 5)
    }

    @Test func readsAtMostTheLast16000BytesPerTick() throws {
        let mic = try part("mic.part")
        // 1 s of loud tone, then 0.5 s of silence appended before the first read: only the silent tail counts.
        try append(mic, toneSamples(1, 0.5))
        try append(mic, [Double](repeating: 0, count: 8_000))
        let tracker = LevelTracker(tracks: [("mic", mic)], clock: { 1 })
        #expect(tracker.read()[0].db == nil)
    }

    @Test func toleratesMissingFiles() {
        let tracker = LevelTracker(tracks: [("mic", tempDir().appendingPathComponent("nope.part"))], clock: { 3 })
        let r = tracker.read()
        #expect(r[0].db == nil && r[0].silentFor == 0)
    }

    @Test func saysHowLongEveryTrackWasQuiet() throws {
        // Room noise on the mic is not sound; speech on either track is.
        let mic = try part("mic.part"), system = try part("system.part")
        let now = Locked(0.0)
        let tracker = LevelTracker(tracks: [("mic", mic), ("system", system)], clock: { now.get })
        #expect(tracker.quietFor() == 0)
        for t in 1...5 {
            try append(mic, toneSamples(0.5, 0.001))  // about -63 dB: a quiet room
            now.with { $0 = Double(t) }
            _ = tracker.read()
        }
        #expect(tracker.quietFor() == 5)
        try append(system, toneSamples(0.5, 0.1))  // someone speaks
        now.with { $0 = 6 }
        _ = tracker.read()
        #expect(tracker.quietFor() == 0)
        now.with { $0 = 9 }
        _ = tracker.read()
        #expect(tracker.quietFor() == 3)
    }

    @Test func saysHowLongTheOthersWereQuiet() throws {
        // #7: the user talking on the mic is no sound of the others.
        let mic = try part("mic.part"), system = try part("system.part")
        let now = Locked(0.0)
        let tracker = LevelTracker(tracks: [("mic", mic), ("system", system)], clock: { now.get })
        for t in 1...5 {
            try append(mic, toneSamples(0.5, 0.1))  // the user talks
            now.with { $0 = Double(t) }
            _ = tracker.read()
        }
        #expect(tracker.quietFor() == 0 && tracker.quietFor("system") == 5)
        try append(system, toneSamples(0.5, 0.1))
        now.with { $0 = 6 }
        _ = tracker.read()
        #expect(tracker.quietFor("system") == 0)
    }

    @Test func readsThroughAnInjectedFileSystem() {
        // 100 bytes after the header, offered by a fake: the tracker asks for the tail only.
        let asked = Locked<[(Int, Int)]>([])
        let files = LevelFiles(size: { _ in 144 }, read: { _, offset, count in
            asked.with { $0.append((offset, count)) }
            return Data(repeating: 1, count: count)
        })
        let tracker = LevelTracker(tracks: [("mic", URL(fileURLWithPath: "/fake.part"))], clock: { 1 }, files: files)
        #expect(tracker.read()[0].db != nil)
        #expect(asked.get.first?.0 == 44 && asked.get.first?.1 == 100)
        #expect(tracker.read()[0].db == nil)  // nothing new
    }
}
