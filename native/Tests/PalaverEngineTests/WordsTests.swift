import AVFoundation
import FluidAudio
import Foundation
import Testing
@testable import PalaverEngine

private func tok(_ t: String, _ s: Double, _ e: Double, _ c: Float) -> TokenTiming {
    TokenTiming(token: t, tokenId: 0, startTime: s, endTime: e, confidence: c)
}

/// A token list from (text, start, end) triples; all with confidence 1.
private func toks(_ items: [(String, Double, Double)]) -> [TokenTiming] {
    items.map { tok($0.0, $0.1, $0.2, 1) }
}

@Test func piecesJoinIntoWords() {
    let ws = words(from: [tok("▁Ti", 0, 0.2, 0.9), tok("mo", 0.2, 0.4, 0.6),
                          tok("▁sagt", 0.5, 0.8, 0.99), tok(",", 0.8, 0.9, 0.95)])
    #expect(ws.map(\.text) == ["Timo", "sagt,"])
    #expect(ws.map(\.confidence) == [0.6, 0.95])
    #expect(ws[0].start == 0 && ws[0].end == 0.4)
}

@Test func confidenceRoundsHalfToEven() {
    // 0.0625 and 0.1875 are exact in Float; x1000 is exactly 62.5 and 187.5.
    let ws = words(from: [tok(" a", 0, 1, 0.0625), tok(" b", 1, 2, 0.1875)])
    #expect(ws.map(\.confidence) == [0.062, 0.188])
}

@Test func pauseSplitsSentence() {
    // FluidAudio's real format: word starts carry a leading space.
    func segs(gap: Double) -> Int {
        sentences(toks([(" a", 0, 1), (" b", 1 + gap, 2 + gap)])).count
    }
    #expect(segs(gap: 1.1) == 2)
    #expect(segs(gap: 0.9) == 1)
    #expect(segs(gap: 1.0) == 2)  // a gap of exactly 1.0 s splits (>=)
}

@Test func punctuationSplitsSentence() {
    let split = sentences(toks([(" Hallo", 0, 0.5), (".", 0.5, 0.6), (" Welt", 0.7, 1.0)]))
    #expect(split.map(\.text) == ["Hallo.", "Welt"])
    // "3.5" inside a word: the "." is followed by a piece without a space.
    let inside = sentences(toks([(" ist", 0, 0.3), (" 3", 0.3, 0.5), (".", 0.5, 0.6), ("5", 0.6, 0.8), (" gut", 0.8, 1.0)]))
    #expect(inside.count == 1)
    #expect(inside[0].words.map(\.text) == ["ist", "3.5", "gut"])
    // "?" and "!" close a sentence wherever they sit.
    #expect(sentences(toks([(" Was?", 0, 0.5), (" Ja", 0.5, 1)])).count == 2)
    // "▁" marks a word start like a space does.
    #expect(sentences(toks([("▁Hallo", 0, 0.5), (".", 0.5, 0.6), ("▁Welt", 0.7, 1.0)])).count == 2)
}

@Test func longSentenceCapped() {
    // Close AFTER the token that reaches 15 s, so a sentence may run past it.
    let ts = (0..<40).map { tok(" w\($0)", Double($0) * 0.7, Double($0 + 1) * 0.7, 1) }
    let segs = sentences(ts)
    #expect(segs[0].words.count == 22)  // token 21 ends at 15.4 >= 15.0
    #expect(segs[0].end > 15.0 && segs[0].end < 15.5)
    #expect(segs.flatMap(\.words).count == 40)
    #expect(segs.allSatisfy { $0.end - $0.start < 15.0 + 0.7 })
}

@Test func orphanPunctuationAttaches() {
    // A pause splits the "." off as a sentence of its own; it rejoins "Hallo".
    let segs = sentences(toks([(" Hallo", 0, 1), (" .", 5, 5.2), (" Neu", 9, 10)]))
    #expect(segs.map(\.text) == ["Hallo.", "Neu"])
    #expect(segs[0].words.map(\.text) == ["Hallo."])
    #expect(segs[0].end == 1)  // the previous end is unchanged
}

/// Records how many samples it was given; answers with fixed tokens.
private final class Spy: Recognizer, @unchecked Sendable {
    var counts: [Int] = []
    func recognize(_ samples: [Float]) async throws -> [TokenTiming] {
        counts.append(samples.count)
        return [tok(" Hi", 0, 0.05, 0.9), tok(" du", 0.05, 0.1, 0.8)]
    }
}

private struct Boom: Recognizer {
    func recognize(_ samples: [Float]) async throws -> [TokenTiming] { throw EngineError("model was called") }
}

/// Writes a 16-bit WAV. `tone` (Hz) gives a sine on every channel; nil a sawtooth.
func writeWav(frames: Int, rate: Double = 16_000, channels: Int = 1, tone: Double? = nil, to url: URL) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: false)
    var done = 0
    while done < frames {
        let n = min(frames - done, 500_000)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for c in 0..<channels {
            let p = buf.int16ChannelData![c]
            for i in 0..<n {
                if let f = tone {
                    p[i] = Int16(10_000 * sin(2 * Double.pi * f * Double(done + i) / rate))
                } else {
                    p[i] = Int16(truncatingIfNeeded: (i % 200) * 50)
                }
            }
        }
        try file.write(from: buf)
        done += n
    }
}

private func tmpWav(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("palaver-\(UUID().uuidString)-\(name).wav")
}

@Test func emptyAudioGivesNoSegments() async throws {
    let url = tmpWav("short")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeWav(frames: 799, to: url)
    let segs = try await transcribeFile(url, start: nil, end: nil, with: Boom())
    #expect(segs.isEmpty)
}

@Test func wavReadsEveryFrame() throws {
    let url = tmpWav("long")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeWav(frames: 3_000_000, to: url)
    #expect(try readWav(url).count == 3_000_000)
    #expect(try readWav(url, start: 1_000_000, end: 2_500_000).count == 1_500_000)
    #expect(try readWav(url, start: 2_999_000, end: 9_000_000).count == 1_000)
}

private struct Fixed: Recognizer {
    func recognize(_ samples: [Float]) async throws -> [TokenTiming] {
        [tok("▁Hi", 0, 0.5, 0.9), tok("▁du", 0.5, 1, 0.8)]
    }
}

private func run(_ lines: [String], modelsDir: URL, recognizer: (() async throws -> Recognizer)? = nil) async throws -> [[String: Any]] {
    let inPipe = Pipe(), outPipe = Pipe()
    inPipe.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    try inPipe.fileHandleForWriting.close()
    await serve(input: inPipe.fileHandleForReading, output: outPipe.fileHandleForWriting,
                handler: engineHandler(version: "t", modelsDir: modelsDir, recognizer: recognizer))
    try outPipe.fileHandleForWriting.close()
    return try String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
}

@Test func commandsWithoutModelsSaysModelsMissing() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-empty-\(UUID().uuidString)")
    let url = tmpWav("m")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeWav(frames: 16_000, to: url)
    let r = try await run([
        #"{"id":1,"cmd":"transcribe","wav":"\#(url.path)"}"#,
        #"{"id":2,"cmd":"transcribe_window","pcm":"\#(Data(count: 4 * 4_000).base64EncodedString())"}"#,
        #"{"id":3,"cmd":"hello"}"#,
    ], modelsDir: dir)
    #expect(r[0]["ok"] as? Bool == false)
    #expect((r[0]["error"] as? String)?.hasPrefix("models missing") == true)
    #expect((r[1]["error"] as? String)?.hasPrefix("models missing") == true)
    #expect((r[2]["models"] as? [String: Bool]) == ["asr": false, "diarizer": false])
    #expect(!FileManager.default.fileExists(atPath: dir.path))  // nothing was downloaded or created
}

@Test func transcribeAndWindowReplyShapes() async throws {
    let url = tmpWav("t")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeWav(frames: 32_000, to: url)
    let floats = [Float](repeating: 0.1, count: 4_000)
    let pcm = floats.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
    let r = try await run([
        #"{"id":1,"cmd":"transcribe","wav":"\#(url.path)","start":1000,"end":30000}"#,
        #"{"id":2,"cmd":"transcribe_window","pcm":"\#(pcm)"}"#,
        #"{"id":3,"cmd":"transcribe_window","pcm":"AAAAAA=="}"#,
        #"{"id":4,"cmd":"transcribe_window","pcm":"abc"}"#,
    ], modelsDir: FileManager.default.temporaryDirectory, recognizer: { Fixed() })
    #expect(r[0]["ok"] as? Bool == true, "\(r[0])")
    let segs = r[0]["segments"] as? [[String: Any]] ?? []
    #expect(segs.count == 1 && segs[0]["text"] as? String == "Hi du")
    let words0 = segs.first?["words"] as? [[String: Any]] ?? []
    #expect(words0.count == 2 && words0[0]["confidence"] as? Double == 0.9)
    #expect((r[1]["words"] as? [[String: Any]])?.count == 2, "\(r[1])")
    #expect((r[2]["words"] as? [Any])?.isEmpty == true, "\(r[2])")
    #expect(r[3]["ok"] as? Bool == false)
}

@Test func progressLinesComeBeforeTheReply() async throws {
    let inPipe = Pipe(), outPipe = Pipe()
    inPipe.fileHandleForWriting.write(Data(#"{"id":7,"cmd":"x"}"#.utf8 + [0x0A]))
    try inPipe.fileHandleForWriting.close()
    await serve(input: inPipe.fileHandleForReading, output: outPipe.fileHandleForWriting) { _, emit in
        emit.progress(0.5, phase: "downloading")
        emit.progress(1, phase: "loading")
        return ["done": true]
    }
    try outPipe.fileHandleForWriting.close()
    let lines = try String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    #expect(lines.count == 3)
    #expect(lines[0]["id"] as? Int == 7 && lines[0]["progress"] as? Double == 0.5 && lines[0]["phase"] as? String == "downloading")
    #expect(lines[1]["phase"] as? String == "loading")
    #expect(lines[2]["ok"] as? Bool == true && lines[2]["progress"] == nil)
}

@Test func shortAudioIsPaddedToWhatTheModelAccepts() async throws {
    let url = tmpWav("pad")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeWav(frames: 1_000, to: url)
    let spy = Spy()
    let segs = try await transcribeFile(url, start: nil, end: nil, with: spy)
    #expect(spy.counts == [4_800])
    #expect(segs.count == 1 && segs[0].words.map(\.end) == [0.05, 0.1])  // padding adds silence at the end only
    // exactly at the cut-off: 800 samples are padded, 799 are not recognized at all
    try writeWav(frames: 800, to: url)
    _ = try await transcribeFile(url, start: nil, end: nil, with: spy)
    #expect(spy.counts == [4_800, 4_800])
    // a slice of a long file is padded too
    try writeWav(frames: 100_000, to: url)
    _ = try await transcribeFile(url, start: 10_000, end: 12_000, with: spy)
    #expect(spy.counts.last == 4_800)
    // long enough audio is left alone
    _ = try await transcribeFile(url, start: 0, end: 6_000, with: spy)
    #expect(spy.counts.last == 6_000)
}

@Test func windowIsPaddedToo() async throws {
    let spy = Spy()
    let pcm = [Float](repeating: 0.1, count: 2_000).withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
    let tiny = [Float](repeating: 0.1, count: 799).withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
    let r = try await run([#"{"id":1,"cmd":"transcribe_window","pcm":"\#(pcm)"}"#,
                           #"{"id":2,"cmd":"transcribe_window","pcm":"\#(tiny)"}"#],
                          modelsDir: FileManager.default.temporaryDirectory, recognizer: { spy })
    #expect(spy.counts == [4_800])
    #expect((r[0]["words"] as? [[String: Any]])?.map { $0["end"] as? Double } == [0.05, 0.1])
    #expect((r[1]["words"] as? [Any])?.isEmpty == true)
}

/// Zero crossings of `samples` per second of 16 kHz audio.
private func crossingsPerSecond(_ samples: [Float]) -> Double {
    var n = 0
    for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) { n += 1 }
    return Double(n) / (Double(samples.count) / 16_000)
}

@Test(arguments: [(48_000.0, 1, 1_000.0), (8_000.0, 1, 500.0), (44_100.0, 2, 1_000.0)])
func resamplesAnyRateTo16k(rate: Double, channels: Int, tone: Double) throws {
    let url = tmpWav("rs")
    defer { try? FileManager.default.removeItem(at: url) }
    let seconds = 3
    try writeWav(frames: Int(rate) * seconds, rate: rate, channels: channels, tone: tone, to: url)
    let out = try readWav(url)
    #expect(abs(out.count - 16_000 * seconds) <= 1_024)
    // A pure tone keeps its frequency (2 zero crossings per period).
    #expect(abs(crossingsPerSecond(out) - 2 * tone) < 2 * tone * 0.05)
    // start/end are in 16 kHz units.
    let slice = try readWav(url, start: 16_000, end: 32_000)
    #expect(abs(slice.count - 16_000) <= 1)
}

@Test func resamplesLongFilesInChunks() throws {
    let url = tmpWav("rs-long")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeWav(frames: 3_300_000, rate: 48_000, tone: 440, to: url)  // 68.75 s, more than 3 read chunks
    let out = try readWav(url)
    #expect(abs(out.count - 1_100_000) <= 1_024)
}

@Test func badArgumentsAreErrors() async throws {
    let url = tmpWav("args")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeWav(frames: 16_000, to: url)
    let dir = FileManager.default.temporaryDirectory
    let r = try await run([
        #"{"id":1,"cmd":"transcribe","wav":"\#(url.path)","start":1.5}"#,
        #"{"id":2,"cmd":"transcribe","wav":"\#(url.path)","start":"3"}"#,
        #"{"id":3,"cmd":"transcribe","wav":"\#(url.path)","start":9000,"end":100}"#,
        #"{"id":4,"cmd":"prepare","models":"asr"}"#,
        #"{"id":5,"cmd":"prepare","models":[1]}"#,
        #"{"id":6,"cmd":"transcribe","wav":"\#(url.path)","start":0,"end":16000}"#,
    ], modelsDir: dir, recognizer: { Fixed() })
    for i in 0..<5 { #expect(r[i]["ok"] as? Bool == false, "request \(i + 1): \(r[i])") }
    #expect(r[5]["ok"] as? Bool == true)
}
