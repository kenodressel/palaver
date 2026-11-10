// The setup assistant's test recording, looked at (`palaver-worker test-analyze`, onboarding.py `level_db`, `_analyze`
// and `test_verdict`): verdicts on synthetic WAVs, the engine faked. Nothing is recorded or played.
import AVFoundation
import Foundation
import PalaverCore
@testable import PalaverDomain
@testable import PalaverWorker
import Testing

private func silence(_ url: URL, seconds: Double = 1) throws {
    try Wav16.write([Int16](repeating: 0, count: Int(seconds * 16_000)), rate: 16_000, to: url)
}

/// A 48 kHz stereo float file of a full-scale-half sine (RMS 0.5/√2: -9.0 dBFS), as the capture may write one.
private func floatSine(_ url: URL) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let n = 48_000
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buffer.frameLength = AVAudioFrameCount(n)
    for c in 0..<2 {
        for i in 0..<n { buffer.floatChannelData![c][i] = Float(0.5 * sin(2 * Double.pi * 440 * Double(i) / 48_000)) }
    }
    try file.write(from: buffer)
}

private final class Words: @unchecked Sendable {
    var asked: [URL] = []
    var answer: String? = "hello there"
}

private func run(mic: URL?, system: URL?, mode: JSONValue = .object([]), here: Bool = true, words: Words = Words()) async -> JSONValue {
    TestAnalysis.withChecks(await TestAnalysis.analyze(mic: mic, system: system, mode: mode, speechHere: { here },
                                                       transcribe: { words.asked.append($0); return words.answer }))
}

private func checks(_ result: JSONValue) -> [(String, String, String)] {
    (result["checks"]?.arrayValue ?? []).map { ($0["name"]!.stringValue!, $0["status"]!.stringValue!, $0["detail"]!.stringValue!) }
}

@Suite struct TestAnalyzeTests {
    @Test func test_analyze_reports_levels() throws {
        let t = Temp("test-analyze"); defer { t.remove() }
        try writeTone(t.file("tone.wav"), seconds: 1)
        try silence(t.file("quiet.wav"))
        try floatSine(t.file("sine.wav"))
        let tone = try #require(TestAnalysis.levelDb(t.file("tone.wav")))
        #expect(abs(tone - -23.8) <= 0.2)
        #expect(TestAnalysis.levelDb(t.file("quiet.wav")) == -120.0)
        #expect(TestAnalysis.levelDb(t.file("sine.wav")) == -9.0)
        #expect(TestAnalysis.levelDb(t.file("missing.wav")) == nil && TestAnalysis.levelDb(nil) == nil)
        t.write("broken.wav", "not audio")
        #expect(TestAnalysis.levelDb(t.file("broken.wav")) == nil)
    }

    @Test func aMicThatHeardSomeoneIsTranscribedAndQuietSystemAudioIsFine() async throws {
        let t = Temp("test-analyze"); defer { t.remove() }
        try writeTone(t.file("mic_raw.wav"), seconds: 1)
        try silence(t.file("system.wav"))
        let words = Words()
        let result = await run(mic: t.file("mic_raw.wav"), system: t.file("system.wav"), words: words)
        #expect(words.asked == [t.file("mic_raw.wav")])
        #expect(result["mic"]?["text"] == .string("hello there") && result["mic"]?["transcript"] == .string("done"))
        #expect(result["system"]?["recorded"] == .bool(true) && result["system"]?["level_db"] == .double(-120.0))
        #expect(checks(result).map(\.1) == ["ok", "ok"])
        #expect(checks(result)[0].2 == "heard you: “hello there”")
        #expect(checks(result)[1].2 == "recorded; quiet, as nothing played")
    }

    @Test func soundFromOtherAppsIsSaidAndAFailedTranscriptionStillHeardYou() async throws {
        let t = Temp("test-analyze"); defer { t.remove() }
        try writeTone(t.file("mic.wav"), seconds: 1)
        try floatSine(t.file("system.wav"))
        let words = Words()
        words.answer = nil
        let result = await run(mic: t.file("mic.wav"), system: t.file("system.wav"), words: words)
        #expect(result["mic"]?["transcript"] == .string("failed"))
        #expect(checks(result).map(\.2) == ["heard you", "recorded, with sound from other apps"])
    }

    @Test func test_analyze_never_downloads() async throws {
        let t = Temp("test-analyze"); defer { t.remove() }
        try writeTone(t.file("mic.wav"), seconds: 1)
        let words = Words()
        let result = await run(mic: t.file("mic.wav"), system: nil, here: false, words: words)
        #expect(words.asked.isEmpty && result["mic"]?["transcript"] == .string("not_downloaded"))
        #expect(checks(result)[0].2.hasPrefix("heard you (levels only: the speech models are not downloaded yet"))
        #expect(checks(result)[1].1 == "fail")  // no system track was written
    }

    @Test func aCloudServiceMeansLevelsOnly_theTestSendsNothing() async throws {
        let t = Temp("test-analyze"); defer { t.remove() }
        try writeTone(t.file("mic.wav"), seconds: 1)
        let words = Words()
        let result = await run(mic: t.file("mic.wav"), system: nil,
                               mode: .object([("transcribe", .string("cloud")), ("service", .string("Contoso Speech"))]), words: words)
        #expect(words.asked.isEmpty && result["mic"]?["transcript"] == .string("cloud"))
        #expect(checks(result)[0].2 == "heard you (levels only: Contoso Speech transcribes your calls, and transcription is skipped in the test)")
    }

    @Test func aSilentMicIsAWarningAndNoMicTrackAFailure() async throws {
        let t = Temp("test-analyze"); defer { t.remove() }
        try silence(t.file("mic.wav"))
        let words = Words()
        let quiet = await run(mic: t.file("mic.wav"), system: nil, words: words)
        #expect(words.asked.isEmpty && checks(quiet)[0].1 == "warn" && checks(quiet)[0].2 == "the microphone track is silent")
        let none = await run(mic: nil, system: nil, words: words)
        #expect(none["mic"]?["recorded"] == .bool(false) && checks(none)[0].1 == "fail")
        #expect(checks(none)[0].2 == "nothing was recorded")
    }

    @Test func test_the_test_recording_is_transcribed_by_the_engine() async throws {
        let t = Temp("test-analyze"); defer { t.remove() }
        try writeTone(t.file("mic.wav"), seconds: 1)
        let spec = #"{"transcribe": {"*": [{"start": 0, "end": 0.5, "text": " The cloud is up. "}, {"start": 0.5, "end": 1, "text": "Yes."}]}}"#
        let good = FakeEngine(spec: try PythonJSON.parse(Data(spec.utf8)), dictionary: TranscriberDictionary())
        #expect(await TestAnalysis.words(t.file("mic.wav"), engine: good) == "The cloud is up. Yes.")
        let crash = FakeEngine(spec: try PythonJSON.parse(Data(#"{"fail": {"transcribe": "the engine crashed"}}"#.utf8)),
                               dictionary: TranscriberDictionary())
        #expect(await TestAnalysis.words(t.file("mic.wav"), engine: crash) == nil)  // the test goes on without words
    }

    @Test func theCommandIsKnown() throws {
        let o = try WorkerMain.parse(["--config", "/c.toml", "test-analyze", "-", "--system", "/s.wav"])
        #expect(o.command == "test-analyze" && o.args == ["-", "--system", "/s.wav"])
    }
}
