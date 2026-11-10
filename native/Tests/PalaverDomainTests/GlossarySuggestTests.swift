// The glossary's suggestions (glossary.py:283-517, test_glossary.py): variants, clusters, terms, and what they
// are made from (the recordings' readable lines, unsure words, known spellings).
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct GlossarySuggestTests {
    private func glossary(_ t: TempFolder) -> Glossary { Glossary(path: t.url.appendingPathComponent("glossary.json")) }

    /// `_transcripts(**meetings)`: each line starts at its index.
    private func transcripts(_ meetings: [(String, [String])]) -> PyDict<[(Double, String)]> {
        PyDict(meetings.map { m, lines in (m, lines.enumerated().map { (Double($0.offset), $0.element) }) })
    }

    private func strings(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap(\.stringValue) }
    private func kind(_ s: JSONValue) -> String { s["kind"]?.stringValue ?? "" }
    private func term(_ s: JSONValue) -> String { s["term"]?.stringValue ?? "" }

    @Test func test_suggestions_from_known_names_sound_alikes_and_recurring_terms() throws {
        let t = TempFolder("glossary-suggest"); defer { t.remove() }
        let tr = transcripts([
            ("m1", ["Wir sind im Atterkring-Raum.", "Das macht Wasti.", "Databricks läuft.", "Wir müssen schedulen."]),
            ("m2", ["Vasti meint, Databricks ist teuer.", "Wasti sagt ja.", "Die Kita ist zu."]),
            ("m3", ["Databricks again, said CAREL."]),
        ])
        let s = GlossarySuggest.suggest(tr, known: ["Attakring", "Karel Kralek", "Lead Engineer"], glossary: glossary(t))
        func by(_ k: String, _ name: String) throws -> JSONValue { try #require(s.first { kind($0) == k && term($0) == name }) }

        #expect(strings(try by("variant", "Karel")["variants"]) == ["CAREL"])
        #expect(strings(try by("cluster", "Wasti")["variants"]) == ["Wasti", "Vasti"])
        let found = try by("term", "Databricks")
        #expect(found["count"] == .int(3) && strings(found["meetings"]) == ["m1", "m2", "m3"])
        let example = try #require(found["examples"]?.arrayValue?.first)
        #expect(PythonJSON.dumps(example) == PythonJSON.dumps(.object([
            ("meeting", .string("m1")), ("start", .double(2.0)), ("text", .string("Databricks läuft."))])))
        let words = Set(s.flatMap { [term($0)] + strings($0["variants"]) })
        #expect(words.isDisjoint(with: ["schedulen", "Kita", "Lead"]))  // ordinary words, lower case, too common
    }

    @Test func test_accepted_and_rejected_suggestions_are_not_suggested_again() throws {
        let t = TempFolder("glossary-suggest"); defer { t.remove() }
        let g = glossary(t)
        let tr = transcripts([("m1", ["Databricks", "Wasti"]), ("m2", ["Databricks", "Vasti"])])
        let first = GlossarySuggest.suggest(tr, known: [], glossary: g)
        let cluster = try #require(first.first { kind($0) == "cluster" })
        try g.add(term: "Databricks")
        g.reject(try #require(cluster["key"]?.stringValue))
        #expect(GlossarySuggest.suggest(tr, known: [], glossary: g).isEmpty)
    }

    @Test func test_a_name_heard_as_two_words_is_a_variant() throws {
        let t = TempFolder("glossary-suggest"); defer { t.remove() }
        let g = glossary(t)
        try g.add(term: "Databricks")
        let tr = transcripts([("m1", ["Wir laden das in Data Bricks hoch."]), ("m2", ["Data Bricks ist teuer, sagt Zabek Hollmer."])])
        let variants = GlossarySuggest.suggest(tr, known: ["Sebastian Zabek-Hollmer"], glossary: g).filter { kind($0) == "variant" }
        let databricks = try #require(variants.first { term($0) == "Databricks" })
        #expect(strings(databricks["variants"]) == ["Data Bricks"] && databricks["count"] == .int(2))
        #expect(strings(try #require(variants.first { term($0) == "Zabek-Hollmer" })["variants"]) == ["Zabek Hollmer"])
        try g.add(term: "Databricks", variants: ["Data Bricks"])
        #expect(g.apply("in Data Bricks hoch") == "in Databricks hoch")
    }

    /// "Cloud" is ordinary English, so it never counted as a name; heard unsure and sounding like KLOUD, it is
    /// suggested as KLOUD's variant.
    @Test func test_an_ordinary_word_heard_unsure_can_be_a_known_name() throws {
        let t = TempFolder("glossary-suggest"); defer { t.remove() }
        let g = glossary(t)
        let tr = PyDict<[(Double, String)]>([("m1", [(1.0, "Willkommen bei Cloud, wir machen das Projekt.")]),
                                             ("m2", [(2.0, "Bei Cloud arbeiten wir anders.")])])
        #expect(!GlossarySuggest.suggest(tr, known: ["KLOUD"], glossary: g).contains { strings($0["variants"]).contains("Cloud") })
        let found = GlossarySuggest.suggest(tr, known: ["KLOUD"], glossary: g, unsure: GlossarySuggest.everyTime(["cloud", "projekt"]))
        let variants = found.filter { kind($0) == "variant" }
        #expect(variants.count == 1)
        let variant = try #require(variants.first)
        #expect(term(variant) == "KLOUD" && strings(variant["variants"]) == ["Cloud"] && variant["count"] == .int(2))
        #expect(variant["unsure"] == .bool(true))  // the card says why an ordinary word is suggested
        #expect(!found.contains { ([term($0)] + strings($0["variants"])).contains("Projekt") })  // ordinary, no known name near
    }

    /// "Teil" is said everywhere; the transcriber doubting it once does not make it a mishearing of Theil, nor does
    /// a lower-case "teile" ever.
    @Test func test_an_ordinary_word_heard_unsure_only_now_and_then_is_no_name() throws {
        let t = TempFolder("glossary-suggest"); defer { t.remove() }
        let g = glossary(t)
        let tr = PyDict<[(Double, String)]>((0..<5).map { ("m\($0)", [(1.0, "Ein Teil davon ist fertig."), (2.0, "Das teile ich gerne.")]) })
        var found = GlossarySuggest.suggest(tr, known: ["Anna Theil"], glossary: g, unsure: PyDict([("teil", 1), ("teile", 5)]))
        #expect(!found.contains { kind($0) == "variant" })
        // Doubted most of the times it was said, a capitalized one still is.
        found = GlossarySuggest.suggest(tr, known: ["Anna Theil"], glossary: g, unsure: PyDict([("teil", 4)]))
        let variants = found.filter { kind($0) == "variant" }
        #expect(variants.count == 1 && strings(variants.first?["variants"]) == ["Teil"])
    }

    @Test func test_unsure_words_of_the_recordings() throws {
        let t = TempFolder("glossary-unsure"); defer { t.remove() }
        let folder = t.url.appendingPathComponent("2026-10-27T16-03-07")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"""
        [{"speaker": "A", "start": 0, "end": 1, "text": "bei Cloud", "unsure": ["Cloud"]}, {"speaker": "B", "start": 1, "end": 2, "text": "ja", "heard": "jo", "unsure": ["jo"]}]
        """#.write(to: folder.appendingPathComponent("transcript.json"), atomically: false, encoding: .utf8)
        #expect(GlossarySuggest.unsureWords(outputDir: t.url) == PyDict([("cloud", 1)]))
    }

    // MARK: - beyond the Python tests

    @Test func unsureWordsStripPunctuationAndSkipFoldersThatAreNoRecordings() throws {
        let t = TempFolder("glossary-unsure"); defer { t.remove() }
        for (name, json) in [("2026-10-27T16-03-07", #"[{"text": "a", "unsure": ["Cloud,", "cloud?", "...", "KLOUD"]}]"#),
                             ("2026-10-28T09-00-00", "not json"),
                             ("notes", #"[{"text": "a", "unsure": ["Cloud"]}]"#)] {
            let folder = t.url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try json.write(to: folder.appendingPathComponent("transcript.json"), atomically: false, encoding: .utf8)
        }
        #expect(GlossarySuggest.unsureWords(outputDir: t.url) == PyDict([("cloud", 2), ("", 1), ("kloud", 1)]))
        #expect(GlossarySuggest.unsureWords(outputDir: t.url.appendingPathComponent("missing")).isEmpty)
    }

    @Test func occurrencesCountRareWordsWithAnExamplePerMeeting() {
        let tr = PyDict<[(Double, String)]>([
            ("m1", [(0.5, "Databricks und Databricks."), (1.5, "Ab 2026 im Databricks-Team, x2y z.")]),
            ("m2", [(3.0, "databricks")]), ("m3", [(4.0, "Databricks")]), ("m4", [(5.0, "Databricks")]),
        ])
        let found = GlossarySuggest.occurrences(tr, unsure: nil)
        #expect(found.keys == ["Databricks", "Databricks-Team", "x2y", "databricks"])
        let o = found["Databricks"]!
        #expect(o.count == 4 && o.meetings == ["m1", "m3", "m4"] && o.rare)
        #expect(o.examples.map { $0["meeting"]?.stringValue } == ["m1", "m3", "m4"])
        #expect(o.examples.first?["start"] == .double(0.5))
    }

    @Test func aRejectedKeyIsComparedByCodePoints() throws {
        let t = TempFolder("glossary-suggest"); defer { t.remove() }
        let g = glossary(t)
        let tr = transcripts([("m1", ["Brüxelt und Brüxelt"]), ("m2", ["Brüxelt"])])  // "ü" as one letter
        let key = try #require(GlossarySuggest.suggest(tr, known: [], glossary: g).first?["key"]?.stringValue)
        #expect(Array(key.unicodeScalars) == Array("term:br\u{FC}xelt".unicodeScalars))
        g.reject("term:bru\u{308}xelt")  // u + diaeresis: the same letters to Swift's ==, another key to Python
        #expect(g.rejected().map { Array($0.unicodeScalars) } == [Array("term:bru\u{308}xelt".unicodeScalars)] && !g.isRejected(key))
        #expect(GlossarySuggest.suggest(tr, known: [], glossary: g).count == 1)
        g.reject(key)
        g.reject(key)
        #expect(g.rejected().count == 2)
        #expect(GlossarySuggest.suggest(tr, known: [], glossary: g).isEmpty)
    }

    @Test func knownSpellingsGatherTheUserCalendarPeopleProjectsAndSpeakers() throws {
        let t = TempFolder("glossary-known"); defer { t.remove() }
        let config = t.url.appendingPathComponent("config/palaver")
        let stores = StorePaths(configDir: config, home: t.url.appendingPathComponent("home"))
        try FileManager.default.createDirectory(at: stores.voices, withIntermediateDirectories: true)
        try #"{"name": "Valerie", "samples": []}"#.write(to: stores.voices.appendingPathComponent("valerie.json"), atomically: false, encoding: .utf8)
        try #"{"projects": {"p1": {"name": "Northwind rollout"}}, "meetings": {}}"#.write(to: stores.projects, atomically: false, encoding: .utf8)
        let out = t.url.appendingPathComponent("Recordings")
        let folder = out.appendingPathComponent("2026-10-27T16-03-07")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"""
        {"title": "Contoso kickoff", "start": "2026-10-27T16:00:00+01:00", "end": "2026-10-27T17:00:00+01:00", "attendees": [{"name": "Timo Strauß"}, {"name": "Raum 3.12", "is_room": true}, {"name": ""}]}
        """#.write(to: folder.appendingPathComponent("calendar.json"), atomically: false, encoding: .utf8)
        try #"{"SPEAKER_00": "Carla"}"#.write(to: folder.appendingPathComponent("speakers.json"), atomically: false, encoding: .utf8)
        let known = try GlossarySuggest.knownSpellings(outputDir: out, userName: "Timo", stores: stores)
        #expect(known == ["Carla", "Contoso kickoff", "Northwind rollout", "Raum 3.12", "Timo", "Timo Strauß", "Valerie"])
        #expect(try GlossarySuggest.knownSpellings(outputDir: t.url.appendingPathComponent("none"), userName: "KAREL", stores: stores)
                == ["Northwind rollout", "Valerie", "KAREL"])  // all capitals last: "Karel" would win a tie
        #expect(Py.stableSorted(["KAREL", "Karel", "Anna", "ANNA", "anna"], by: GlossarySuggest.knownOrder)
                == ["Anna", "Karel", "anna", "ANNA", "KAREL"])
    }

    @Test func theCorpusIsEveryMeetingsReadableLinesSpelledByTheGlossary() throws {
        let t = TempFolder("glossary-corpus"); defer { t.remove() }
        let stores = StorePaths(configDir: t.url.appendingPathComponent("config/palaver"), home: t.url.appendingPathComponent("home"))
        let g = Glossary(path: stores.glossary)
        try g.add(term: "Databricks", variants: ["Data Bricks"])
        try g.save()
        let out = t.url.appendingPathComponent("Recordings")
        for (name, json) in [
            ("2026-10-28T09-00-00", #"[{"speaker": "A", "start": 1.236, "end": 2, "text": "Äh, wir nutzen Data Bricks."}, {"speaker": "B", "start": 3, "end": 4, "text": "Mm-hmm."}]"#),
            ("2026-10-27T16-03-07", #"[{"speaker": "A", "start": 0, "end": 1, "text": "Hallo."}]"#),
            ("2026-10-29T09-00-00", #"[{"speaker": "A", "start": "x", "end": 1, "text": "Hallo."}]"#),  // ValueError: left out
        ] {
            let folder = out.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try json.write(to: folder.appendingPathComponent("transcript.json"), atomically: false, encoding: .utf8)
        }
        let corpus = GlossarySuggest.corpus(outputDir: out, stores: stores)
        #expect(corpus.keys == ["2026-10-27T16-03-07", "2026-10-28T09-00-00"])
        let lines = corpus["2026-10-28T09-00-00"] ?? []
        #expect(lines.count == 1 && lines.first?.0 == 1.24 && lines.first?.1 == "Wir nutzen Databricks.")
    }
}
