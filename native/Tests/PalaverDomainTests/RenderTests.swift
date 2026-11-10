// transcript.md (render.py, test_render.py).
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct RenderTests {
    private static let plus2 = TimeZone(secondsFromGMT: 7200)!
    private func start(_ iso: String = "2026-04-17T14:30:00+02:00") -> Date { WallTime.parse(iso)! }

    private func render(_ utterances: [Utterance], at iso: String = "2026-04-17T14:30:00+02:00", duration: Double,
                        gaps: [JSONValue]? = nil) -> String {
        let t = TempFolder("render"); defer { t.remove() }
        let none = Glossary(path: t.url.appendingPathComponent("none.json"))
        return try! Render.markdown(utterances, start: start(iso), duration: duration, gaps: gaps,
                               timeZone: Lifecycle.offsetZone(iso) ?? Self.plus2, glossary: none)
    }

    private func u(_ speaker: String, _ start: Double, _ end: Double, _ text: String) -> Utterance {
        Utterance(speaker: speaker, start: start, end: end, text: text)
    }

    @Test func test_renders_header_with_metadata() {
        let md = render([u("Timo", 0, 2, "hallo")], duration: 120)
        #expect(md.contains("2026-04-17 14:30") && md.contains("2 min") && md.contains("1 speaker"))
    }

    @Test func test_renders_plural_speakers() {
        let md = render([u("Timo", 0, 1, "hi"), u("SPEAKER_00", 1, 2, "hello"), u("SPEAKER_01", 2, 3, "hey")], duration: 60)
        #expect(md.contains("3 speakers"))
    }

    @Test func test_renders_utterances_sorted_by_start() throws {
        let md = render([u("Timo", 90, 95, "dritte zeile"), u("SPEAKER_00", 30, 40, "zweite zeile"), u("Timo", 0, 10, "erste zeile")],
                        duration: 100)
        let a = try #require(md.range(of: "erste zeile")), b = try #require(md.range(of: "zweite zeile")),
            c = try #require(md.range(of: "dritte zeile"))
        #expect(a.lowerBound < b.lowerBound && b.lowerBound < c.lowerBound)
        #expect(md.contains("**Timo**") && md.contains("**SPEAKER_00**"))
    }

    @Test func test_timestamp_format_relative() {
        #expect(render([u("Timo", 125, 130, "hallo")], duration: 200).contains("[14:32:05]"))
    }

    @Test func test_renders_empty_utterance_list() {
        let md = render([], duration: 60)
        #expect(md.contains("2026-04-17 14:30") && md.contains("0 speakers") && md.hasSuffix("\n"))
        #expect(md == "# 2026-04-17 14:30 — Meeting (1 min, 0 speakers)\n")
    }

    @Test func test_format_duration() {
        let cases: [(Double, String)] = [(0, "0 min"), (59, "0 min"), (60, "1 min"), (119, "1 min"), (3599, "59 min"),
                                         (3600, "1h 0min"), (3660, "1h 1min"), (7260, "2h 1min"),
                                         (29.5, "0 min"), (30.5, "0 min"), (90.5, "1 min"), (59.5, "1 min"), (3599.5, "1h 0min"), (-30, "-1h 59min"),
                                         (-3700, "-2h 58min"), (10_000_000, "2777h 46min")]
        for (seconds, want) in cases { #expect(try! Render.formatDuration(seconds) == want, "\(seconds)") }
    }

    /// Numbers only a hand-edited file has: an error to report, never a trap.
    @Test func brokenNumbersThrowInsteadOfTrapping() {
        for seconds in [Double.nan, .infinity, -.infinity, 1e300] {
            #expect(throws: Py.IntError.self) { try Render.formatDuration(seconds) }
            #expect(throws: Py.IntError.self) { try Render.markdown([u("A", seconds, 1, "Hi.")], start: start(), duration: 60, timeZone: Self.plus2) }
            let gap: JSONValue = .object([("start", .double(seconds)), ("end", .double(2))])
            #expect(throws: Py.IntError.self) { try Render.markdown([], start: start(), duration: 60, gaps: [gap], timeZone: Self.plus2) }
        }
        #expect(throws: Py.IntError.self) { try Render.markdown([u("A", 1e12, 1e12 + 1, "Hi.")], start: start(), duration: 60, timeZone: Self.plus2) }
    }

    @Test func test_build_meeting_title_is_shared_by_markdown_header() {
        let s = start("2026-10-20T14:35:00+02:00")
        #expect(try! Render.buildMeetingTitle(s, 1446.7, 4, timeZone: Self.plus2) == "2026-10-20 14:35 — Meeting (24 min, 4 speakers)")
        #expect(try! Render.buildMeetingTitle(s, 3900, 1, timeZone: Self.plus2) == "2026-10-20 14:35 — Meeting (1h 5min, 1 speaker)")
        let md = render([u("Timo", 0, 1, "Hi")], at: "2026-10-20T14:35:00+02:00", duration: 60)
        #expect(md.split(separator: "\n").first.map(String.init) == "# " + (try! Render.buildMeetingTitle(s, 60, 1, timeZone: Self.plus2)))
    }

    @Test func test_markdown_is_clean_verbatim() {
        let md = render([u("Anna", 0, 2, "Um, so we, uh, need a plan."), u("Timo", 2, 2.5, "Mm-hmm.")], duration: 60)
        #expect(md.contains("So we need a plan.") && !md.contains("Mm-hmm") && md.contains("1 speaker"))
        #expect(md.contains("**Anna** [14:30:00]  So we need a plan.\n"))
    }

    @Test func test_a_pause_in_the_recording_shows_where_it_was() throws {
        let gap: JSONValue = .object([("start", .double(415)), ("end", .double(424)), ("why", .string("restart"))])
        let md = render([u("Timo", 400, 410, "vor dem neustart"), u("Anna", 430, 440, "danach")],
                        at: "2026-10-29T12:06:10+01:00", duration: 600, gaps: [gap])
        let before = try #require(md.range(of: "vor dem neustart")), after = try #require(md.range(of: "danach"))
        let pause = try #require(md.range(of: "*Recording paused 12:13:05–12:13:14 (Palaver restarted)*"))
        #expect(before.lowerBound < pause.lowerBound && pause.lowerBound < after.lowerBound)
    }

    @Test func aPauseAfterTheLastTurnComesLastAndGapsAreSorted() {
        let late: JSONValue = .object([("start", .double(900)), ("end", .double(910))])
        let early: JSONValue = .object([("start", .double(5)), ("end", .double(8))])
        let md = render([u("Timo", 10, 12, "eins")], duration: 1000, gaps: [late, early])
        let lines = md.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines == ["# 2026-04-17 14:30 — Meeting (16 min, 1 speaker)", "*Recording paused 14:30:05–14:30:08*",
                          "**Timo** [14:30:10]  eins", "*Recording paused 14:45:00–14:45:10*"])
        #expect(md.hasSuffix("14:45:10*\n") && !md.hasSuffix("\n\n"))
    }
}
