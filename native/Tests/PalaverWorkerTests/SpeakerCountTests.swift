// #21: a two-person call comes out as two speakers, one on each track. `palaver-worker process` with the engine in
// its own process (`InProcessEngine`, the real merge of voices and labels) over a diarizer that stands in for
// FluidAudio's: it splits the one remote voice the way the tester's call was split, unless told the count. The text of
// both tracks is there already (as the live worker leaves it); no model, no network, no real calendar.
import FluidAudio
import Foundation
import PalaverCore
@testable import PalaverDomain
@testable import PalaverEngine
@testable import PalaverWorker
import Testing

/// A unit vector `similarity` alike to the voice along axis 0, turned toward axis `toward`.
private func voice(_ similarity: Double, toward: Int) -> [Float] {
    var v = [Float](repeating: 0, count: 8)
    v[0] = Float(similarity)
    if toward != 0 { v[toward] = Float((1 - similarity * similarity).squareRoot()) }
    return v
}

/// FluidAudio's diarizer as these calls need it: `split` without a count, `bounded` with one; remembers what it was
/// asked.
private final class StandIn: Diarizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [Int?] = []
    var asked: [Int?] { lock.withLock { _asked } }
    let split: DiarizerOutput
    let bounded: DiarizerOutput?

    init(split: DiarizerOutput, bounded: DiarizerOutput? = nil) { self.split = split; self.bounded = bounded }

    func diarize(_ url: URL, maxSpeakers: Int?) async throws -> DiarizerOutput {
        lock.withLock { _asked.append(maxSpeakers) }
        return maxSpeakers == nil ? split : bounded ?? split
    }
    func embed(_ url: URL, spans: [Range<Double>]) async throws -> [[Float]] { [] }
}

/// Valerie on the other side: four stretches; Timo on the microphone: two.
private let VALERIE: [(Double, Double)] = [(2.5, 5), (5.5, 8), (11, 14), (15, 18)]
private let TIMO: [(Double, Double)] = [(0.5, 2), (9, 10.5)]

private func segments(_ spans: [(Double, Double)], _ who: String) -> JSONValue {
    .array(spans.enumerated().map { i, span in
        let words = (0..<3).map { k -> JSONValue in
            let at = span.0 + Double(k) * (span.1 - span.0) / 3
            return .object([("text", .string("\(who)\(i)w\(k)")), ("start", .double(at)), ("end", .double(at + (span.1 - span.0) / 3))])
        }
        return .object([("start", .double(span.0)), ("end", .double(span.1)), ("text", .string("\(who) says \(i)")),
                        ("speaker", .null), ("words", .array(words))])
    })
}

/// A 20 s call of Timo and Valerie, both tracks transcribed; `turns`: what a live worker diarized, if anything.
private func call(_ h: Harness, turns: [(String, Double, Double)]? = nil) throws -> RecordingPaths {
    let paths = try h.meeting(mic: track(20, loud: TIMO), system: track(20, loud: VALERIE, seed: 2), seconds: 20)
    var mic = segments(TIMO, "Timo")
    if case .array(let items) = mic {
        mic = .array(items.map { item in
            guard case .object(var f) = item else { return item }
            f = f.map { $0.0 == "speaker" ? ("speaker", .string("Timo")) : $0 }
            return .object(f)
        })
    }
    try PythonJSON.write(mic, to: paths.micSegments, indent: 2, ensureAscii: true)
    try PythonJSON.write(segments(VALERIE, "Valerie"), to: paths.systemSegments, indent: 2, ensureAscii: true)
    if let turns {
        let labels = Set(turns.map(\.0)).sorted()
        try PythonJSON.write(.array(turns.map { SpeakerTurn(speaker: $0.0, start: $0.1, end: $0.2).json }), to: paths.systemTurns,
                             indent: 2, ensureAscii: true)
        try PythonJSON.write(.object(labels.enumerated().map { i, l in (l, .array(voice(i == 0 ? 1 : 0.6, toward: i).map { .double(Double($0)) })) }),
                             to: paths.speakerEmbeddings, indent: nil, ensureAscii: true)
    }
    return paths
}

/// The speakers of the transcript, in order of their first line.
private func speakers(_ paths: RecordingPaths) -> [String] {
    var out: [String] = []
    for line in readJSON(paths.transcriptJson)?.arrayValue ?? [] {
        if let s = line["speaker"]?.stringValue, !out.contains(s) { out.append(s) }
    }
    return out
}

private func event(_ others: [String]) throws -> CalendarEvent {
    CalendarEvent(title: "Northwind sync", start: try PyDateTime.parse("2026-10-20T14:30:00+02:00"),
                  end: try PyDateTime.parse("2026-10-20T15:00:00+02:00"),
                  attendees: [Attendee(name: "Timo Strauß", email: "timo@contoso.com", isSelf: true)]
                    + others.map { Attendee(name: $0, email: "\($0.lowercased())@northwind.com") },
                  uid: "northwind-sync")
}

/// The diarizer's speakers as the tester's call had them: Valerie in four parts.
private func splitValerie(_ alike: [Double]) -> DiarizerOutput {
    DiarizerOutput(segments: [("S0", 2.5, 5), ("S1", 5.5, 8), ("S0", 11, 14), ("S2", 15, 18)],
                   embeddings: ["S0": voice(1, toward: 0), "S1": voice(alike[0], toward: 1), "S2": voice(alike[1], toward: 2)])
}

private let ONE_VALERIE = DiarizerOutput(segments: VALERIE.map { ("S0", $0.0, $0.1) }, embeddings: ["S0": voice(1, toward: 0)])

@Suite(.serialized) struct SpeakerCountTests {
    @Test func aTwoPersonCallIsTwoSpeakersWhenTheVoicesSayItIsOnePersonAcross() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)  // no calendar
        let paths = try call(h)
        // Valerie's parts, a little off (a pause, the codec): as alike as one person's voice in one call.
        let diarizer = StandIn(split: splitValerie([0.9, 0.86]))
        let engine = InProcessEngine(version: "t", modelsDir: t.file("models"), diarizer: { diarizer })
        #expect(try await Pipeline.process(paths.folder, h.setup(engine), notes: false) == 0)
        #expect(diarizer.asked == [nil])  // no calendar: no count
        #expect(speakers(paths) == ["Timo", "SPEAKER_00"])
        #expect(Set(readJSON(paths.systemTurns)?.arrayValue?.compactMap { $0["speaker"]?.stringValue } ?? []) == ["SPEAKER_00"])
        guard case .object(let voices)? = readJSON(paths.speakerEmbeddings) else { Issue.record("no voices"); return }
        #expect(voices.map(\.0) == ["SPEAKER_00"])
        #expect(!FileManager.default.fileExists(atPath: paths.speakersMerged.path))  // nothing the user did
        #expect(try String(contentsOf: paths.transcriptMd, encoding: .utf8).contains("2 speakers"))
    }

    @Test func aOneToOneInviteTellsTheDiarizerThereIsOneVoiceOnTheOtherSide() async throws {
        let t = Temp(); defer { t.remove() }
        var h = Harness(t)
        h.config.calendarEnabled = true
        let paths = try call(h)
        // Parts too far apart for the voices alone (0.6: a codec change mid-call), one speaker when told.
        let diarizer = StandIn(split: splitValerie([0.6, 0.6]), bounded: ONE_VALERIE)
        let engine = InProcessEngine(version: "t", modelsDir: t.file("models"), diarizer: { diarizer })
        let invite = try event(["Valerie"])
        #expect(try await Pipeline.process(paths.folder, h.setup(engine, calendar: { _, _ in [invite] }), notes: false) == 0)
        #expect(diarizer.asked == [1])
        #expect(speakers(paths) == ["Timo", "SPEAKER_00"] || speakers(paths) == ["Timo", "Valerie"])
        #expect(h.said.contains("Diarizing system track (at most 1 speaker, as invited)…"))
        #expect(events(paths).contains("diarize_done"))
    }

    @Test func theLiveWorkersSpeakersAreDiarizedAgainWhenTheyAreMoreThanInvitedButNeverOnceNamed() async throws {
        let t = Temp(); defer { t.remove() }
        var h = Harness(t)
        h.config.calendarEnabled = true
        let invite = try event(["Valerie"])
        // The live worker diarized without the calendar: three speakers for Valerie.
        let live: [(String, Double, Double)] = [("SPEAKER_00", 2.5, 5), ("SPEAKER_01", 5.5, 8), ("SPEAKER_00", 11, 14), ("SPEAKER_02", 15, 18)]
        let paths = try call(h, turns: live)
        let diarizer = StandIn(split: splitValerie([0.6, 0.6]), bounded: ONE_VALERIE)
        let engine = InProcessEngine(version: "t", modelsDir: t.file("models"), diarizer: { diarizer })
        #expect(try await Pipeline.process(paths.folder, h.setup(engine, calendar: { _, _ in [invite] }), notes: false) == 0)
        #expect(diarizer.asked == [1])
        #expect(h.said.contains("Diarizing system track again: 3 speakers, but the calendar invited 1 besides you…"))
        #expect(speakers(paths).count == 2)

        // A meeting processed before (its labels may be named): its speakers stay as they are.
        let t2 = Temp(); defer { t2.remove() }
        var h2 = Harness(t2)
        h2.config.calendarEnabled = true
        let processed = try call(h2, turns: live)
        try PythonJSON.write(.object([("SPEAKER_01", .string("Kim"))]), to: processed.speakers, indent: 2, ensureAscii: false)
        let untouched = StandIn(split: ONE_VALERIE)
        let engine2 = InProcessEngine(version: "t", modelsDir: t2.file("models"), diarizer: { untouched })
        #expect(try await Pipeline.process(processed.folder, h2.setup(engine2, calendar: { _, _ in [invite] }), notes: false) == 0)
        #expect(untouched.asked.isEmpty)
        #expect(h2.said.contains("Skipping diarization (already done)"))
        #expect(speakers(processed).count == 4)
    }

    @Test func twoDifferentPeopleOnTheOtherSideStayTwoWithoutAHint() async throws {
        let t = Temp(); defer { t.remove() }
        var h = Harness(t)
        h.config.calendarEnabled = true
        let paths = try call(h)
        // Valerie and Kim (as alike as different people get: 0.76); five invited besides Timo: no count.
        let diarizer = StandIn(split: DiarizerOutput(
            segments: [("S0", 2.5, 5), ("S1", 5.5, 8), ("S0", 11, 14), ("S1", 15, 18)],
            embeddings: ["S0": voice(1, toward: 0), "S1": voice(0.76, toward: 1)]))
        let engine = InProcessEngine(version: "t", modelsDir: t.file("models"), diarizer: { diarizer })
        let big = try event(["Valerie", "Kim", "Anna", "Carla", "Contoso Team"])
        #expect(try await Pipeline.process(paths.folder, h.setup(engine, calendar: { _, _ in [big] }), notes: false) == 0)
        #expect(diarizer.asked == [nil])
        #expect(speakers(paths) == ["Timo", "SPEAKER_00", "SPEAKER_01"])
    }
}
