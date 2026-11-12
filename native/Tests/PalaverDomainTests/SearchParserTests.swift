// SearchParser against palaver/search.py: tests/test_search.py one by one (fictional names in place of the Python
// test's), the casefold extra, and the goldens section `search_parse` (every query, its filters, properties and chips).
import Foundation
import PalaverCore
import PalaverDomain
import Testing

@Suite struct SearchParserTests {
    static let today = PyDate(2026, 10, 29)!  // a Thursday
    static let vocab = Vocabulary(
        people: ["Anna Berger", "Anna Schmidt", "Tom", "Timo Strauß", "Mara", "Will Northwind"],
        projects: PyDict([("p1", "ÖNW"), ("p2", "Software Foundry")]),
        orgs: ["ACB", "KLOUD"])

    func parse(_ text: String, _ vocab: Vocabulary = vocab) -> SearchQuery {
        SearchParser.parse(text, vocab: vocab, today: Self.today)
    }

    /// `kinds(q)`: each filter as "kind value" ("project nil" for a project nobody has).
    func kinds(_ q: SearchQuery) -> [String] {
        q.filters.map { "\($0.kind) \($0.value ?? "nil")" }
    }

    func day(_ y: Int, _ m: Int, _ d: Int) -> PyDate { PyDate(y, m, d)! }

    @Test func test_plain_words_stay_words() {
        let q = parse("nothing like this")
        #expect(q.words == ["nothing", "like", "this"] && q.filters.isEmpty)
        #expect(parse("pelican").words == ["pelican"])
        #expect(parse("   ").words == [])
    }

    @Test func test_two_people_must_both_have_taken_part() {
        let q = parse("Anna and Tom")
        #expect(kinds(q) == ["person Anna", "person Tom"])
        #expect(q.words == [] && !q.anyPerson)
        #expect(parse("anna or tom").anyPerson)  // either of them
    }

    @Test func test_a_full_name_is_one_person_and_a_unique_first_name_becomes_the_full_name() {
        #expect(kinds(parse("anna berger")) == ["person Anna Berger"])
        #expect(kinds(parse("timo")) == ["person Timo Strauß"])
        #expect(kinds(parse("Strauß")) == ["person Timo Strauß"])
    }

    @Test func test_a_person_and_a_topic() {
        var q = parse("with Timo about the software foundry")
        #expect(kinds(q) == ["person Timo Strauß", "project p2"])
        #expect(q.words == [])
        let other = Vocabulary(people: Self.vocab.people, projects: PyDict(), orgs: [])
        q = parse("with Timo about the software foundry", other)
        #expect(kinds(q) == ["person Timo Strauß"])
        #expect(q.words == ["software", "foundry"])  // the little words go once something was understood
    }

    @Test func test_a_project_and_a_time_range() {
        let q = parse("ÖNW last month")
        #expect(kinds(q) == ["project p1", "since 2026-09-01", "until 2026-09-30"])
        #expect(q.since == day(2026, 9, 1) && q.until == day(2026, 9, 30))
        #expect(q.filters.map(\.label) == ["ÖNW", "Last month", "Last month"])
    }

    @Test func test_dates_in_english_and_german() {
        func span(_ text: String) -> [String] {
            let q = parse(text)
            return [q.since?.iso ?? "nil", q.until?.iso ?? "nil"]
        }
        #expect(span("today") == ["2026-10-29", "2026-10-29"])
        #expect(span("gestern") == ["2026-10-28", "2026-10-28"])
        #expect(span("this week") == ["2026-10-26", "2026-10-29"])
        #expect(span("letzte Woche") == ["2026-10-19", "2026-10-25"])
        #expect(span("diesen Monat") == ["2026-10-01", "2026-10-29"])
        #expect(span("oktober") == ["2026-10-01", "2026-10-31"])
        #expect(span("december") == ["2025-12-01", "2025-12-31"])  // the last one, not one to come
        #expect(span("march 2026") == ["2026-03-01", "2026-03-31"])
        #expect(span("2026-10-21") == ["2026-10-21", "2026-10-21"])
        #expect(span("2026-02") == ["2026-02-01", "2026-02-28"])
        #expect(span("since 2026-10-01") == ["2026-10-01", "nil"])
        #expect(span("before october") == ["nil", "2026-09-30"])
        #expect(span("after 2026-10-20") == ["2026-10-21", "nil"])
        #expect(span("seit september") == ["2026-09-01", "nil"])
    }

    @Test func test_what_was_decided() {
        var q = parse("what did we decide about the test phase")
        #expect(q.scope == "decisions" && q.words == ["test", "phase"])
        #expect(kinds(q) == ["in decisions"])
        #expect(parse("was wurde zur Testphase beschlossen").scope == "decisions")
        q = parse("next steps for ÖNW")
        #expect(q.scope == "steps" && kinds(q) == ["in steps", "project p1"] && q.words == [])
    }

    @Test func test_lines_a_person_said() {
        let q = parse("where did Mara talk about pricing")
        #expect(kinds(q) == ["person Mara", "said Mara"])
        #expect(q.saidBy == "Mara" && q.words == ["pricing"])
        #expect(parse("was hat Mara zu den Kosten gesagt").saidBy == "Mara")
    }

    @Test func test_an_organization() {
        let q = parse("meetings with ACB people")
        #expect(kinds(q) == ["org ACB"] && q.words == [])
    }

    @Test func test_quotes_keep_a_name_a_word() {
        var q = parse("\"Anna\" budget")
        #expect(q.filters.isEmpty && q.words == ["Anna", "budget"])
        q = parse("\"software foundry\" Tom")
        #expect(q.words == ["software foundry"] && kinds(q) == ["person Tom"])
    }

    @Test func test_little_words_are_never_names() {
        let q = parse("what will Anna do")
        #expect(kinds(q) == ["person Anna"])
        #expect(q.words == [])  // a question: "what will … do" are little words
        #expect(kinds(parse("will northwind")) == ["person Will Northwind"])  // the full name is
    }

    @Test func test_written_out_filters() {
        let q = parse("person:\"Anna Berger\" project:önw org:acb since:2026-10-01 until:2026-10-15 "
                      + "in:steps is:reviewed has:steps by:Tom budget")
        #expect(kinds(q) == ["person Anna Berger", "project p1", "org ACB", "since 2026-10-01", "until 2026-10-15",
                             "in steps", "is reviewed", "has steps", "person Tom", "said Tom"])
        #expect(q.words == ["budget"] && q.reviewed == true && q.hasSteps)
        #expect(parse("is:unreviewed").reviewed == false)
        let unknown = parse("project:nope")
        #expect(kinds(unknown) == ["project nil"] && unknown.filters[0].label == "nope")  // finds nothing
    }

    @Test func test_each_filter_knows_where_it_is_in_the_text() {
        let text = "Anna and Tom last month"
        let q = parse(text)
        #expect(q.filters.map { SearchQuery.slice(text, $0.span) } == ["Anna", "Tom", "last month", "last month"])
    }

    @Test func test_the_chips_the_page_shows() {
        let chips = parse("Anna and Tom last month in:decisions").chips()
        let want = """
            [{"kind": "person", "label": "Anna", "title": "Took part: named speaker or invited", "span": [0, 4], \
            "text": "Anna", "written": false}, {"kind": "person", "label": "Tom", "title": "Took part: named speaker or \
            invited", "span": [9, 12], "text": "Tom", "written": false}, {"kind": "date", "label": "Last month", "title": \
            "2026-09-01 to 2026-09-30", "span": [13, 23], "text": "last month", "written": false}, {"kind": "in", "label": \
            "In decisions", "title": "Only decisions in the notes", "span": [24, 36], "text": "in:decisions", "written": true}]
            """
        #expect(PythonJSON.dumps(.array(chips), ensureAscii: false) == want)
        #expect(parse("anna or tom").chips()[0]["title"]?.stringValue == "Took part, any of them: named speaker or invited")
    }

    @Test func test_a_one_word_project_is_a_filter_only_when_nothing_else_is_searched() {
        let vocab = Vocabulary(people: ["Mara"], projects: PyDict([("p1", "Search"), ("p2", "Software Foundry")]), orgs: [])
        var q = parse("search ranking", vocab)
        #expect(q.filters.isEmpty && q.words == ["search", "ranking"])  // not the project "Search"
        #expect(kinds(parse("Search last month", vocab)).first == "project p1")
        #expect(kinds(parse("project:search ranking", vocab)) == ["project p1"])
        q = parse("software foundry pricing", vocab)
        #expect(kinds(q) == ["project p2"] && q.words == ["pricing"])  // a whole longer name is
    }

    @Test func test_short_parts_of_names_stay_words() {
        let vocab = Vocabulary(people: ["Tom Kraus", "Eli", "Thomas Berg"], projects: PyDict(), orgs: [])
        #expect(parse("tom", vocab).filters.isEmpty)  // "Tom" of Tom Kraus: under four letters
        #expect(kinds(parse("Kraus", vocab)) == ["person Tom Kraus"])
        #expect(kinds(parse("tom kraus", vocab)) == ["person Tom Kraus"])
        #expect(kinds(parse("eli", vocab)) == ["person Eli"])  // a whole name
        #expect(kinds(parse("thomas", vocab)) == ["person Thomas Berg"])
    }

    @Test func test_a_chip_knows_its_text_and_whether_it_was_written_out() {
        let chips = parse("Anna project:ÖNW").chips()
        #expect(chips.map { "\($0["text"]?.stringValue ?? "") \($0["written"]?.boolValue ?? false)" }
                == ["Anna false", "project:ÖNW true"])
    }

    // Extra: casefold, not lower(): ß is ss.
    @Test func test_casefold_matches_strauss() {
        let vocab = Vocabulary(people: ["Timo Strauß", "Valerie"], projects: PyDict([("x", "Straße")]), orgs: [])
        #expect(kinds(parse("timo strauss", vocab)) == ["person Timo Strauß"])
        #expect(kinds(parse("STRAUSS budget", vocab)) == ["person Timo Strauß"])
        #expect(kinds(parse("project:STRASSE", vocab)) == ["project x"])
        #expect(kinds(parse("person:timo strauss", vocab)) == ["person Timo Strauß", "person Timo Strauß"])
        #expect(kinds(parse("person:\"TIMO STRAUSS\"", vocab)) == ["person Timo Strauß"])
    }

    // MARK: - Goldens

    static func vocabulary(_ v: JSONValue?) throws -> Vocabulary {
        let v = try #require(v)
        let given = try #require(v["projects"])
        let projects = try #require(PyDict(given))
        return Vocabulary(people: v["people"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                          projects: PyDict(projects.map { ($0.key, $0.value.stringValue ?? "") }),
                          orgs: v["orgs"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    @Test func aNameTypedTwiceAndAFilterRemovedKeepTheirPlaces() {
        // filters.remove(f) removes that one project filter; the rest keep Python's order.
        let vocab = Vocabulary(people: ["Mara"], projects: PyDict([("p1", "Search")]), orgs: [])
        let q = parse("Mara search search ranking", vocab)
        #expect(kinds(q) == ["person Mara"] && q.words == ["search", "search", "ranking"])
    }

    @Test func nfdAndNfcStayApart() {
        let vocab = Vocabulary(people: ["J\u{fc}rgen \u{d6}lberg"], projects: PyDict(), orgs: [])
        #expect(kinds(parse("j\u{fc}rgen", vocab)) == ["person J\u{fc}rgen \u{d6}lberg"])
        let nfd = parse("ju\u{308}rgen", vocab)  // U+0308 is no \w: Python reads "ju" and "rgen"
        #expect(nfd.filters.isEmpty && nfd.words == ["ju", "rgen"])
    }
}
