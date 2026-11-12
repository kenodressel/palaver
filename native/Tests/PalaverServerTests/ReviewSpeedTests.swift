// Review opens without reading every transcript again (#29): its glossary suggestions and Needs you are made from
// each meeting's share, kept per meeting while that meeting's files stay as they were. A change to one meeting, the
// projects or the glossary reads that meeting alone, or none; the answers stay those of a server that starts afresh.
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETINGS = 30
private let LINES = 240  // a 30 to 40 minute meeting

private func write(_ value: JSONValue, to url: URL) throws { try Data(PythonJSON.dumps(value).utf8).write(to: url) }

/// A file's modification time set by hand, so a test never depends on the clock moving between two writes.
private func touch(_ url: URL, _ seconds: Int) throws {
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(seconds))], ofItemAtPath: url.path)
}

/// `MEETINGS` finished meetings of `LINES` lines, with named and unnamed voices, notes, a calendar event; the newest
/// five not reviewed yet. "Quellbach" recurs in all of them (a glossary suggestion).
private final class Corpus {
    let dir = tempFolder("review-speed")
    var out: URL { dir.appendingPathComponent("Meetings", isDirectory: true) }
    var stores: StorePaths {
        StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true), home: dir.appendingPathComponent("home", isDirectory: true))
    }
    private(set) var ids: [String] = []

    init() throws {
        try FileManager.default.createDirectory(at: stores.configDir, withIntermediateDirectories: true)
        let words = "we should look at the budget for the next release and the roadmap with Quellbach tomorrow".split(separator: " ")
        for i in 0..<MEETINGS {
            let id = String(format: "2026-10-%02dT09-00-00", i + 1)
            ids.append(id)
            let paths = RecordingPaths(out.appendingPathComponent(id, isDirectory: true))
            try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
            let start = String(format: "2026-10-%02dT09:00:00+01:00", i + 1)
            try write(.object([("start_time", .string(start)), ("duration_seconds", .int(LINES * 9))]), to: paths.meta)
            var lines: [Utterance] = [], turns: [JSONValue] = []
            for k in 0..<LINES {
                let who = k % 4 == 0 ? "Timo" : "SPEAKER_0\(k % 3)"
                let text = (0..<12).map { String(words[(k * 7 + $0 * 3 + i) % words.count]) }.joined(separator: " ") + ", äh, okay."
                let t = Double(k * 9)
                lines.append(Utterance(speaker: who, start: t, end: t + 8, text: text))
                if who != "Timo" {
                    turns.append(.object([("speaker", .string(who)), ("start", .double(t)), ("end", .double(t + 8))]))
                }
            }
            try write(.array(lines.map(\.json)), to: paths.transcriptJson)
            try write(.array(turns), to: paths.systemTurns)
            try write(.object([("SPEAKER_00", .string("Anna"))]), to: paths.speakers)
            try write(.object([("title", .string("Weekly \(i)")), ("start", .string(start)), ("end", .string(start)),
                               ("attendees", .array([])), ("all_day", .bool(false)), ("source", .string("")),
                               ("uid", .string("weekly")), ("series", .bool(true)), ("location", .string(""))]), to: paths.calendar)
            try NotesFile.save(paths, .object([
                ("title", .string("Weekly \(i)")), ("summary", .string("SPEAKER_01 asked about the budget.")),
                ("sections", .array([])), ("next_steps", .array([])), ("decisions", .array([])),
                ("speaker_names", .array([.object([("label", .string("SPEAKER_01")), ("name", .string("Bob")),
                                                   ("evidence", .string("thanks Bob"))])])),
                ("transcript_hash", .string(Notes.transcriptHash(lines))),
            ]))
            if i < MEETINGS - 5 { try write(.object([("reviewed", .string(start)), ("seen", .array([]))]), to: paths.review) }
        }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func app() -> ServerApp { ServerApp(outputDir: out, userName: "Timo", stores: stores) }
    func paths(_ i: Int) -> RecordingPaths { RecordingPaths(out.appendingPathComponent(ids[i], isDirectory: true)) }
}

@Suite struct ReviewSpeedTests {
    /// What the review shows: its queue and Needs you.
    private func review(_ app: ServerApp) throws -> JSONValue {
        .object([("review", .array(try ReviewAPI.queue(app, userName: "Timo"))), ("needs", try ReviewAPI.needs(app))])
    }

    @Test func reviewReadsOnlyWhatChanged() throws {
        let corpus = try Corpus()
        let app = corpus.app()
        let suggestions = app.glossarySuggestions, needs = app.reviewCaches.needs
        let first = try review(app)
        #expect(first["review"]?.arrayValue?.count == 5)
        #expect(first["review"]?[0]?["open"]?["glossary"]?.arrayValue?.contains { $0["term"] == .string("Quellbach") } == true)
        #expect(suggestions.meetingsRead == MEETINGS && needs.misses == MEETINGS)

        // Again: nothing is read.
        #expect(try review(app) == first)
        #expect(suggestions.meetingsRead == MEETINGS && needs.misses == MEETINGS && suggestions.computed == 1)

        // A voice named in one meeting: that meeting is read again, no other.
        let named = corpus.paths(MEETINGS - 1)
        try write(.object([("SPEAKER_00", .string("Anna")), ("SPEAKER_01", .string("Bob"))]), to: named.speakers)
        try touch(named.speakers, 2_000_000_000)
        let afterName = try review(app)
        #expect(suggestions.meetingsRead == MEETINGS + 1 && needs.misses == MEETINGS + 1)
        #expect(afterName == (try review(corpus.app())))

        // A project assigned: no transcript is read.
        let store = ProjectStore(path: corpus.stores.projects)
        _ = try store.assign(corpus.ids[0], try store.create("Quellbach rollout"))
        try store.save()
        _ = try review(app)
        #expect(suggestions.meetingsRead == MEETINGS + 1)

        // A suggestion accepted (the glossary changed): it is gone, and no transcript is cleaned again. All the same
        // as a server that starts now.
        let glossary = Glossary(path: corpus.stores.glossary)
        _ = try glossary.add(term: "Quellbach")
        try glossary.save()
        let afterGlossary = try review(app)
        #expect(suggestions.meetingsRead == MEETINGS + 1)
        #expect(afterGlossary["review"]?[0]?["open"]?["glossary"]?.arrayValue?.contains { $0["term"] == .string("Quellbach") } == false)
        #expect(afterGlossary == (try review(corpus.app())))
    }

    /// The warm-up after a start makes what Review asks for: the first visit finds it made.
    @Test func theWarmUpPreparesTheReview() throws {
        let corpus = try Corpus()
        let app = corpus.app()
        app.background.warmUp()
        let read = app.glossarySuggestions.meetingsRead, made = app.reviewCaches.needs.misses
        #expect(read == MEETINGS && made == MEETINGS)
        _ = try review(app)
        #expect(app.glossarySuggestions.meetingsRead == read && app.reviewCaches.needs.misses == made)
    }
}

private extension JSONValue {
    subscript(i: Int) -> JSONValue? { arrayValue.flatMap { $0.indices.contains(i) ? $0[i] : nil } }
}
