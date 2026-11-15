// The index worker's first step (#35): the waiting meetings' corrected lines taught to the voice bank by the engine
// (a fake one here), each meeting taken off the list once done.
import Foundation
import PalaverCore
@testable import PalaverDomain
import PalaverEngine
@testable import PalaverWorker
import Testing

private let M = "2026-10-29T14-00-00"

/// A meeting whose Speaker 2 said two lines (4 s) that were Timo Strauß's.
private func corrected(_ out: URL) throws -> RecordingPaths {
    let paths = RecordingPaths(out.appendingPathComponent(M, isDirectory: true))
    try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
    let lines = [
        Utterance(speaker: "Kim", start: 0.0, end: 1.0, text: "Hi."),
        Utterance(speaker: "SPEAKER_01", start: 13.0, end: 15.0, text: "The Northwind numbers are in."),
        Utterance(speaker: "SPEAKER_01", start: 16.0, end: 18.0, text: "I disagree with those numbers."),
    ]
    try PythonJSON.write(.array(lines.map(\.json)), to: paths.transcriptJson, indent: 2, ensureAscii: true)
    try PythonJSON.write(.array([13.0, 16.0].map { start in
        .object([("start", .double(start)), ("end", .double(start + 2)), ("from", .string("SPEAKER_01")), ("name", .string("Timo Strauß"))])
    }), to: paths.speakersLines, indent: 2, ensureAscii: false)
    return paths
}

@Suite struct LineVoicesWorkerTests {
    @Test func theWaitingMeetingsTeachTheBankAndLeaveTheList() async throws {
        let t = Temp("line-voices")
        defer { t.remove() }
        let stores = StorePaths(configDir: t.file("config"), home: t.file("home"))
        let out = t.file("Meetings")
        _ = try corrected(out)
        try LineVoices.mark(stores, M)
        try LineVoices.mark(stores, "2026-10-30T09-00-00")  // deleted since: just leaves the list
        let engine = FakeEngine(spec: .object([("embed", .object([("system.wav", .object([("Timo Strauß", .array([.double(1), .double(0)]))]))]))]))
        var said: [String] = []
        let rc = await Index.lineVoices(outputDir: out, stores: stores, engine: { engine }, shouldStop: { false }, say: { said.append($0) })
        #expect(rc == 0)
        #expect(engine.calls == ["embed system.wav", "release"])
        #expect(engine.embedded.first?["Timo Strauß"] == [13.0..<15.0, 16.0..<18.0])
        #expect(try VoiceBank(directory: stores.voices).owner(LineVoices.source(M, "Timo Strauß")) == "Timo Strauß")
        #expect(LineVoices.pending(stores).isEmpty)
        #expect(said == ["Voices of corrected lines in \(M): Timo Strauß."])
    }

    @Test func aRecordingStartingStopsItAndTheMeetingStaysOnTheList() async throws {
        let t = Temp("line-voices-stop")
        defer { t.remove() }
        let stores = StorePaths(configDir: t.file("config"), home: t.file("home"))
        _ = try corrected(t.file("Meetings"))
        try LineVoices.mark(stores, M)
        var made = false
        let rc = await Index.lineVoices(outputDir: t.file("Meetings"), stores: stores,
                                        engine: { made = true; return FakeEngine(spec: .object([])) }, shouldStop: { true }, say: { _ in })
        #expect(rc == 0 && !made)
        #expect(LineVoices.pending(stores) == [M])
    }

    @Test func modelsNotHereYetKeepTheMeetingWaiting() async throws {
        let t = Temp("line-voices-models")
        defer { t.remove() }
        let stores = StorePaths(configDir: t.file("config"), home: t.file("home"))
        _ = try corrected(t.file("Meetings"))
        try LineVoices.mark(stores, M)
        let engine = FakeEngine(spec: .object([("fail", .object([("embed", .string("models missing: diarizer"))]))]))
        let rc = await Index.lineVoices(outputDir: t.file("Meetings"), stores: stores, engine: { engine }, shouldStop: { false }, say: { _ in })
        #expect(rc == 1)
        #expect(LineVoices.pending(stores) == [M])
    }

    @Test func theEngineGivesEachPersonTheMeanOfTheirSpansVoices() async throws {
        let t = Temp("line-voices-engine")
        defer { t.remove() }
        struct Spans: Diarizing {
            func diarize(_ url: URL) async throws -> DiarizerOutput { DiarizerOutput(segments: [], embeddings: [:]) }
            func embed(_ url: URL, spans: [Range<Double>]) async throws -> [[Float]] {
                spans.map { [Float($0.lowerBound), 1] }  // the span's start, to see which spans went where
            }
        }
        let wav = t.file("system.wav")
        try Wav16.write([Int16](repeating: 0, count: 16_000), rate: 16_000, to: wav)
        let engine = InProcessEngine(version: "t", modelsDir: t.file("models"), diarizer: { Spans() })
        let voices = try await engine.embed(wav: wav, spans: PyDict([("Timo Strauß", [13.0..<15.0, 17.0..<18.0]), ("Valerie", [1.0..<3.0])]))
        #expect(voices.keys == ["Timo Strauß", "Valerie"])
        #expect(voices["Timo Strauß"] == [15.0, 1.0])
        #expect(voices["Valerie"] == [1.0, 1.0])
        #expect(try await engine.embed(wav: wav, spans: PyDict()).isEmpty)
    }
}
