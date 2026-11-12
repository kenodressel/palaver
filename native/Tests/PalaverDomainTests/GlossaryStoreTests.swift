// The glossary store and applying (glossary.py, test_glossary.py). Suggestions are not ported here.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct GlossaryStoreTests {
    private func folder() -> TempFolder { TempFolder("glossary") }
    private func glossary(_ t: TempFolder, _ name: String = "glossary.json") -> Glossary { Glossary(path: t.url.appendingPathComponent(name)) }
    private func marks(_ text: String, _ marks: [(start: Int, end: Int, heard: String)]) -> [[String]] {
        let s = Array(text.unicodeScalars)
        return marks.map { [String(String.UnicodeScalarView(s[$0.start..<$0.end])), $0.heard] }
    }

    @Test func test_variants_are_written_as_their_term() throws {
        let t = folder(); defer { t.remove() }
        let g = glossary(t)
        try g.add(term: "Attakring", variants: ["Atterkring"])
        try g.add(term: "Unit 214", variants: ["Unit zu14"])
        try g.add(term: "Unit", variants: ["Junit"])
        #expect(g.apply("Im Atterkring-Raum? Nein, atterkring. Merger von Unit zu14, Junit.")
                == "Im Attakring-Raum? Nein, Attakring. Merger von Unit 214, Unit.")
    }

    /// A meeting's lines respelled at once (#29) read as each line respelled alone: at a line's start and end, in two
    /// words, in none, and a line with a break in it.
    @Test func manyLinesAtOnceAreRespelledAsEachAlone() throws {
        let t = folder(); defer { t.remove() }
        let g = glossary(t)
        try g.add(term: "Attakring", variants: ["Atterkring"])
        try g.add(term: "Databricks", variants: ["Data Bricks"])
        let lines = ["Atterkring", "nothing here", "", "in Data Bricks", "data bricks and ATTERKRING.", "Atterkringer",
                     "Raum Atterkring", "two\nAtterkring lines", "Zoë in Atterkring-Raum"]
        #expect(g.apply(lines: lines) == lines.map(g.apply))
        #expect(g.apply(lines: lines)[0] == "Attakring" && g.apply(lines: lines)[5] == "Atterkringer")
        #expect(glossary(t, "empty.json").apply(lines: lines) == lines)
    }

    @Test func test_a_variant_belongs_to_one_term() throws {
        let t = folder(); defer { t.remove() }
        let g = glossary(t)
        let a = try g.add(term: "Karel", variants: ["CAREL"])
        let b = try g.add(term: "Carelle", variants: ["carel"])  // moves it
        #expect(g.terms[a]?["variants"]?.arrayValue?.isEmpty == true)
        #expect(g.terms[b]?["variants"] == .strings(["carel"]))
        try g.add(term: "Carel")  // the right spelling after all: no longer a variant of anything
        #expect(g.terms[b]?["variants"]?.arrayValue?.isEmpty == true)
        try g.save()
        #expect(glossary(t).find("karel") == a)
        #expect(throws: GlossaryValueError.self) { try g.update(a, term: "Carelle") }
    }

    @Test func test_the_user_glossary_applies_to_readable_transcripts() throws {
        let t = folder(); defer { t.remove() }
        let stores = StorePaths(configDir: t.url.appendingPathComponent("palaver"), home: t.url)
        let mine = Glossary.current(stores: stores)  // the user's (not there yet)
        try mine.add(term: "Databricks", variants: ["Data Bricks"])
        try mine.save()
        let u = Utterance(speaker: "SPEAKER_00", start: 0, end: 1, text: "Wir nutzen äh Data Bricks.")
        #expect(Readable.readable([u], glossary: Glossary.current(stores: stores)).map(\.text) == ["Wir nutzen Databricks."])
        #expect(Readable.readable([Utterance(speaker: "S", start: 0, end: 1, text: "Data Bricks")], glossary: glossary(t, "none.json"))[0].text
                == "Data Bricks")
    }

    @Test func test_the_glossary_applies_to_notes_too() throws {
        let t = folder(); defer { t.remove() }
        let g = glossary(t)
        try g.add(term: "Attakring", variants: ["Atterkring"])
        let notes: JSONValue = .object([
            ("summary", .string("Meeting in Atterkring.")),
            ("next_steps", .array([.object([("owner", .string("Anna")), ("task", .string("Book Atterkring"))])])),
            ("n", .int(3)),
        ])
        let want: JSONValue = .object([
            ("summary", .string("Meeting in Attakring.")),
            ("next_steps", .array([.object([("owner", .string("Anna")), ("task", .string("Book Attakring"))])])),
            ("n", .int(3)),
        ])
        #expect(PythonJSON.dumps(g.applyTo(notes)) == PythonJSON.dumps(want))
    }

    @Test func test_the_glossary_says_where_it_respelled() throws {
        let t = folder(); defer { t.remove() }
        let g = glossary(t)
        try g.add(term: "Zini", variants: ["Tini", "Genie"])
        try g.add(term: "KLOUD", variants: ["Cloud"])
        let (text, found) = g.applyMarked("Wir lösen Tini ab, sagt Cloud, mit Genie.")
        #expect(text == "Wir lösen Zini ab, sagt KLOUD, mit Zini.")
        #expect(marks(text, found) == [["Zini", "Tini"], ["KLOUD", "Cloud"], ["Zini", "Genie"]])
        let none = g.applyMarked("nichts davon")
        #expect(none.0 == "nichts davon" && none.1.isEmpty)
    }

    @Test func idsAreEightLowercaseHexAndNew() throws {
        let t = folder(); defer { t.remove() }
        let g = glossary(t)
        var ids: Set<String> = []
        for i in 0..<50 { ids.insert(try g.add(term: "Term \(i)")) }
        #expect(ids.count == 50)
        for id in ids { #expect(id.count == 8 && id.allSatisfy { "0123456789abcdef".contains($0) }) }
        #expect(try g.add(term: "term 7") == g.find("Term 7"))  // an existing term keeps its id
        g.makeId = { "aaaaaaaa" }
        let first = try g.add(term: "Fixed")
        #expect(first == "aaaaaaaa")
        let counter = Counter()
        g.makeId = { counter.next() }  // a taken id is not handed out again
        #expect(try g.add(term: "Other") == "bbbbbbbb")
    }
    private final class Counter: @unchecked Sendable {
        var n = 0
        func next() -> String { n += 1; return n == 1 ? "aaaaaaaa" : "bbbbbbbb" }
    }

    @Test func removeVariantComparesByCasefoldAndANonexistentIdThrows() throws {
        let t = folder(); defer { t.remove() }
        let g = glossary(t)
        let id = try g.add(term: "Straße", variants: ["Cloud", "Wolke", "KLOUD"])
        try g.removeVariant(id, "cloud")
        #expect(g.terms[id]?["variants"] == .strings(["Wolke", "KLOUD"]))
        try g.removeVariant(id, " Wolke")  // not stripped: nothing goes
        #expect(g.terms[id]?["variants"] == .strings(["Wolke", "KLOUD"]))
        #expect(throws: GlossaryLookupError.self) { try g.removeVariant("nope", "x") }
        #expect(throws: GlossaryLookupError.self) { try g.update("nope", note: "x") }
        #expect(throws: GlossaryLookupError.self) { try g.delete("nope") }
        #expect(throws: GlossaryValueError.self) { try g.add(term: "  ") }
    }

    @Test func currentIsReadAgainWhenTheFileChangesAndSaveClearsIt() throws {
        let t = folder(); defer { t.remove() }
        let stores = StorePaths(configDir: t.url.appendingPathComponent("palaver"), home: t.url)
        let first = Glossary.current(stores: stores)
        #expect(Glossary.current(stores: stores) === first)
        try first.add(term: "Northwind", variants: ["Nordwind"])
        try first.save()
        let second = Glossary.current(stores: stores)
        #expect(second !== first && second.apply("Nordwind") == "Northwind")
        #expect(Glossary.current(stores: stores) === second)
    }

    @Test func aBrokenOrOddFileReadsAsEmptyAndOtherKeysKeepTheirPlace() throws {
        let t = folder(); defer { t.remove() }
        t.write("glossary.json", "not json")
        #expect(glossary(t).terms.isEmpty)
        t.write("glossary.json", #"{"z": 1, "terms": {}}"#)
        let g = glossary(t)
        try g.add(term: "Valerie")
        try g.save()
        let text = try #require(t.text("glossary.json"))
        #expect(text.hasPrefix("{\n  \"z\": 1,\n  \"terms\": {") && text.contains("\"rejected\": []") && !text.hasSuffix("\n"))
    }
}
