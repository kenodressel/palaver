// Reading a search (#46), as palaver/search.py: what the user typed, as filters and words. "Anna and Tom last month"
// is two people who both took part and a date range; "what did we decide about the test phase" looks in decisions for
// "test phase"; "where did Mara talk about pricing" looks in the lines Mara said. Known people, projects and
// organizations become filters when their name is typed; a name in quotes stays a word. Filters can be written out
// too: person: project: org: since: until: in: by: is:reviewed has:steps.
//
// Rules, not a language model: every filter knows the part of the text it came from (a span of Unicode scalar offsets,
// Python's string indices), so the page shows it as a chip the user can take out again. Words compare as Python does:
// casefolded (ß is ss) and by code points (NFC and NFD spellings stay apart).
import Foundation
import PalaverCore

/// What a typed name can be: people (named speakers, invitees, the voice bank), projects (id → name, in the store's
/// order) and organizations.
public struct Vocabulary {
    public var people: [String]
    public var projects: PyDict<String>
    public var orgs: [String]

    public init(people: [String] = [], projects: PyDict<String> = PyDict(), orgs: [String] = []) {
        self.people = people
        self.projects = projects
        self.orgs = orgs
    }
}

/// One filter: `kind` is person, org, project, since, until, in, said, is or has.
public struct SearchFilter {
    public let kind: String
    /// nil only for a project nobody has.
    public let value: String?
    public let label: String
    /// `(start, end)` in the text, as Unicode scalar offsets.
    public let span: Range<Int>
    /// person:… rather than a name in the text.
    public internal(set) var written: Bool = false

    init(_ kind: String, _ value: String?, _ label: String, _ span: Range<Int>) {
        self.kind = kind
        self.value = value
        self.label = label
        self.span = span
    }

    /// The dataclass's `==`: every field, strings by code points.
    func same(_ o: SearchFilter) -> Bool {
        kind == o.kind && label.unicodeScalars.elementsEqual(o.label.unicodeScalars) && span == o.span && written == o.written
            && (value == nil ? o.value == nil : o.value.map { Py.same($0, value!) } ?? false)
    }

    /// `{"kind", "value", "label", "span", "written"}`.
    public var json: JSONValue {
        .object([("kind", .string(kind)), ("value", .str(value)), ("label", .string(label)),
                 ("span", .array([.int(span.lowerBound), .int(span.upperBound)])), ("written", .bool(written))])
    }
}

public struct SearchQuery {
    public let text: String
    public let words: [String]
    public let filters: [SearchFilter]
    /// "Anna or Tom": either of them took part, not both.
    public let anyPerson: Bool

    private func values(_ kind: String) -> [String?] { filters.filter { $0.kind == kind }.map(\.value) }

    public var people: [String] { values("person").compactMap { $0 } }
    public var orgs: [String] { values("org").compactMap { $0 } }
    /// nil for a written-out project nobody has (it finds nothing).
    public var projects: [String?] { values("project") }
    /// The latest `since`.
    public var since: PyDate? { values("since").compactMap { $0.flatMap(PyDate.init(iso:)) }.max() }
    /// The earliest `until`.
    public var until: PyDate? { values("until").compactMap { $0.flatMap(PyDate.init(iso:)) }.min() }
    public var scope: String? { values("in").first ?? nil }
    public var saidBy: String? { values("said").first ?? nil }
    /// is:reviewed (true) or is:unreviewed (false), the last one written; nil when neither is.
    public var reviewed: Bool? { values("is").last.map { $0 == "reviewed" } }
    public var hasSteps: Bool { values("has").contains("steps") }
    public var empty: Bool { words.isEmpty && filters.isEmpty }

    /// `text[start:end]`, by Unicode scalar offsets.
    public static func slice(_ text: String, _ span: Range<Int>) -> String {
        let u = text.unicodeScalars
        let start = u.index(u.startIndex, offsetBy: span.lowerBound), end = u.index(u.startIndex, offsetBy: span.upperBound)
        return String(u[start..<end])
    }

    /// The filters as the page shows them, a date range as one chip: kind, label, title, span, text, written.
    public func chips() -> [JSONValue] {
        var out: [JSONValue] = []
        var last: (kind: String, span: Range<Int>)?
        for f in filters {
            let dated = f.kind == "since" || f.kind == "until"
            if dated, let last, last.kind == "date", last.span == f.span { continue }
            let kind = dated ? "date" : f.kind
            out.append(.object([("kind", .string(kind)), ("label", .string(f.label)),
                                ("title", .string(dated ? range(f.span) : title(f))),
                                ("span", .array([.int(f.span.lowerBound), .int(f.span.upperBound)])),
                                ("text", .string(Self.slice(text, f.span))), ("written", .bool(f.written))]))
            last = (kind, f.span)
        }
        return out
    }

    private func range(_ span: Range<Int>) -> String {
        let since = filters.first { $0.kind == "since" && $0.span == span }?.value ?? nil
        let until = filters.first { $0.kind == "until" && $0.span == span }?.value ?? nil
        if let since, !since.isEmpty, let until, !until.isEmpty { return "\(since) to \(until)" }
        if let since, !since.isEmpty { return "From \(since)" }
        return "Until \(until ?? "None")"
    }

    private func title(_ f: SearchFilter) -> String {
        let value = f.value ?? "None"
        switch f.kind {
        case "person": return anyPerson ? "Took part, any of them: named speaker or invited" : "Took part: named speaker or invited"
        case "said": return "Only lines \(value) said"
        case "project": return f.value?.isEmpty == false ? "Project" : "No project has this name"
        case "org": return "Someone from \(value) took part"
        case "in": return SearchParser.scopeLabels[value]!.1
        case "is": return value == "reviewed" ? "Marked as reviewed" : "Not marked as reviewed yet"
        default: return "The notes have next steps"
        }
    }

    /// The query as the goldens and the parity op answer it (tools/parity/goldens.py `search_query_json`): the fields,
    /// every property and the chips.
    public var json: JSONValue {
        .object([
            ("text", .string(text)), ("words", .strings(words)), ("filters", .array(filters.map(\.json))),
            ("any_person", .bool(anyPerson)), ("people", .strings(people)), ("orgs", .strings(orgs)),
            ("projects", .array(projects.map(JSONValue.str))), ("since", .str(since?.iso)), ("until", .str(until?.iso)),
            ("scope", .str(scope)), ("said_by", .str(saidBy)), ("reviewed", reviewed.map(JSONValue.bool) ?? .null),
            ("has_steps", .bool(hasSteps)), ("empty", .bool(empty)), ("chips", .array(chips())),
        ])
    }
}

public enum SearchParser {
    // MARK: - Words (search.py:23-85, verbatim)

    private typealias Words = Set<ScalarKey>
    private static func words(_ list: [String]) -> Words { Set(list.map(ScalarKey.init)) }

    // Built once: a \w class costs milliseconds to compile.
    private static let token = try! PyRegex(
        #"(?P<key>[A-Za-z]+):(?:"(?P<keyq>[^"]*)"?|(?P<keyv>[^\s"]+))"#
        + #"|"(?P<quoted>[^"]*)"?"#
        + #"|(?P<word>\w+(?:[-.']\w+)*)"#)
    private static let word = try! PyRegex(#"\w+(?:[-.']\w+)*"#)
    private static let yearPattern = try! PyRegex(#"(19|20)\d\d"#)
    private static let isoPattern = try! PyRegex(#"(\d{4})-(\d\d)(?:-(\d\d))?"#)

    private static let question = words([
        "what", "where", "when", "who", "which", "how", "why", "did", "do", "does", "show", "find", "list",
        "was", "wo", "wann", "wer", "welche", "welcher", "welches", "wie", "warum", "zeig", "zeige", "finde", "gab",
    ])
    private static let decide = words([
        "decide", "decided", "decides", "deciding", "decision", "decisions", "beschlossen", "beschließen",
        "entschieden", "entscheiden", "entscheidung", "entscheidungen", "beschluss", "beschlüsse",
    ])
    /// STEPS, longest first (two phrases of one length never both match).
    private static let steps: [[ScalarKey]] = [
        ["next", "steps"], ["next", "step"], ["action", "items"], ["action", "item"], ["nächste", "schritte"],
        ["next", "actions"], ["todo"], ["todos"], ["to-dos"], ["to-do"], ["aufgaben"],
    ].map { $0.map(ScalarKey.init) }
    private static let said = words([
        "said", "say", "says", "saying", "talk", "talked", "talks", "talking", "speak", "spoke", "speaks",
        "mention", "mentioned", "mentions", "sagte", "sagt", "gesagt", "sprach", "gesprochen", "erwähnt",
        "erwähnte", "meinte", "gemeint", "redet", "geredet", "redete",
    ])
    /// Little words: dropped once something was understood, or in a question.
    private static let little = question.union(said).union(words([
        "a", "an", "the", "and", "or", "with", "about", "of", "in", "on", "at", "for", "to", "from", "by", "done",
        "we", "i", "you", "he", "she", "they", "it", "is", "are", "were", "be", "been", "will", "would", "shall",
        "should", "can", "could", "may", "might", "that", "this", "these", "those", "there", "here", "me", "my",
        "our", "us", "your", "their", "his", "her", "its", "any", "all", "some", "had", "has", "have", "get", "got",
        "meeting", "meetings", "call", "calls", "people", "person", "someone", "somebody", "anyone", "team",
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "und", "oder", "mit",
        "über", "von", "vom", "zu", "zum", "zur", "im", "am", "an", "auf", "für", "bei", "wir", "ich", "du", "er",
        "sie", "es", "ihr", "hat", "haben", "hatte", "hatten", "wurde", "wurden", "wird", "ist", "sind", "war",
        "waren", "mal", "noch", "auch", "nur", "ob", "dass", "leute", "besprechung", "besprechungen", "termin",
        "termine", "jemand", "uns",
    ]))
    private static let any = words(["or", "oder"])
    /// A first or last name alone is a person from this many letters ("Tom" of Tom Kraus stays a word; a person
    /// called just "Tom" is one).
    static let minPart = 4

    private static let months: [ScalarKey: Int] = {
        var out: [ScalarKey: Int] = [:]
        let names: [[String]] = [
            ["january", "januar", "jänner"], ["february", "februar", "feber"], ["march", "märz"], ["april"],
            ["may", "mai"], ["june", "juni"], ["july", "juli"], ["august"], ["september"], ["october", "oktober"],
            ["november"], ["december", "dezember"]]
        for (i, list) in names.enumerated() { for name in list { out[ScalarKey(name)] = i + 1 } }
        return out
    }()
    /// Words too: a month only with a year after them.
    private static let needsYear = words(["may", "march", "august"])
    private static let this = words(["this", "diese", "dieser", "diesen", "dieses"])
    private static let lastWords = words(["last", "previous", "letzte", "letzten", "letzter", "letztes", "vorige", "vorigen", "voriger"])
    private static let units: [ScalarKey: String] = [
        ScalarKey("week"): "week", ScalarKey("woche"): "week", ScalarKey("month"): "month", ScalarKey("monat"): "month",
        ScalarKey("year"): "year", ScalarKey("jahr"): "year"]
    private static let sinceWords = words(["since", "seit", "ab"]), afterWords = words(["after", "nach"])
    private static let beforeWords = words(["before"]), untilWords = words(["until", "till", "bis"])

    private static let scopes: [ScalarKey: String] = [
        "decisions": "decisions", "decision": "decisions", "steps": "steps", "step": "steps", "next-steps": "steps",
        "todos": "steps", "notes": "notes", "title": "title", "titles": "title", "transcript": "transcript",
        "lines": "transcript",
    ].reduce(into: [:]) { $0[ScalarKey($1.key)] = $1.value }
    static let scopeLabels: [String: (String, String)] = [
        "decisions": ("In decisions", "Only decisions in the notes"),
        "steps": ("In next steps", "Only next steps in the notes"),
        "notes": ("In notes", "Only the notes"), "title": ("In titles", "Only titles"),
        "transcript": ("In transcripts", "Only the transcript")]
    private static let keys: [ScalarKey: String] = [
        "person": "person", "with": "person", "org": "org", "organization": "org", "company": "org",
        "project": "project", "proj": "project", "since": "since", "after": "after", "from": "since",
        "until": "until", "before": "before", "date": "date", "on": "date", "in": "in", "by": "said",
        "said": "said", "is": "is", "has": "has",
    ].reduce(into: [:]) { $0[ScalarKey($1.key)] = $1.value }

    // MARK: - Tokens

    fileprivate struct Token {
        let text: String
        let start: Int
        let end: Int
        let quoted: Bool
        let key: ScalarKey
        let keyText: String

        init(_ text: String, _ start: Int, _ end: Int, quoted: Bool = false) {
            self.text = text
            self.start = start
            self.end = end
            self.quoted = quoted
            keyText = Py.casefold(text)
            key = ScalarKey(keyText)
        }
    }

    /// `_words`: the casefolded words of a text.
    private static func casefoldedWords(_ text: String) -> [ScalarKey] {
        word.matches(in: text).map { ScalarKey(Py.casefold($0.group()!)) }
    }

    /// `_tokens`: words and quoted phrases; and written-out `key:value` filters.
    private static func tokens(_ text: String) -> ([Token], [(key: String, value: String, span: Range<Int>)]) {
        var tokens: [Token] = [], keyed: [(key: String, value: String, span: Range<Int>)] = []
        for m in token.matches(in: text) {
            if let typedKey = m.group("key") {
                let value = m.group("keyq") ?? m.group("keyv") ?? ""
                if let key = keys[ScalarKey(Py.casefold(typedKey))] {
                    keyed.append((key, value, m.range))
                    continue
                }
                for w in word.matches(in: m.group()!) {
                    tokens.append(Token(w.group()!, m.range.lowerBound + w.range.lowerBound, m.range.lowerBound + w.range.upperBound))
                }
            } else if let quoted = m.group("quoted") {
                let stripped = Py.strip(quoted)
                if !stripped.isEmpty { tokens.append(Token(stripped, m.range.lowerBound, m.range.upperBound, quoted: true)) }
            } else {
                tokens.append(Token(m.group("word")!, m.range.lowerBound, m.range.upperBound))
            }
        }
        return (tokens, keyed)
    }

    // MARK: - Dates

    private static func monthRange(_ year: Int, _ month: Int) -> (PyDate, PyDate)? {
        guard let first = PyDate(year, month, 1) else { return nil }
        return (first, PyDate(year, month, PyDate.daysIn(year, month))!)
    }

    /// `int(s)` of a string of decimal digits (any script's, as `\d` and `int` take them).
    private static func decimal(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { n, u in
            let lo = UnicodeTables.digitRanges.first { $0.0 <= u.value && u.value <= $0.1 }!.0
            return n * 10 + Int((u.value - lo) % 10)  // decimal digits come in runs of ten from zero
        }
    }

    /// `_date_at`: a date phrase starting at `tokens[i]`: how many tokens, first and last day. A date Python's
    /// `date` could not hold (before year 1, after 9999) is no date phrase here (Python raises).
    private static func dateAt(_ tokens: [Token], _ i: Int, _ today: PyDate) -> (Int, PyDate, PyDate)? {
        let word = tokens[i].key
        let next: Token? = i + 1 < tokens.count && !tokens[i + 1].quoted ? tokens[i + 1] : nil
        if word == ScalarKey("today") || word == ScalarKey("heute") { return (1, today, today) }
        if word == ScalarKey("yesterday") || word == ScalarKey("gestern") {
            guard let yesterday = today.adding(days: -1) else { return nil }
            return (1, yesterday, yesterday)
        }
        if this.contains(word) || lastWords.contains(word), let next, let unit = units[next.key] {
            let back = lastWords.contains(word)
            switch unit {
            case "week":
                guard let monday = today.adding(days: -today.weekday) else { return nil }
                if !back { return (2, monday, today) }
                guard let first = monday.adding(days: -7), let last = monday.adding(days: -1) else { return nil }
                return (2, first, last)
            case "month":
                let first = PyDate(today.year, today.month, 1)!
                if !back { return (2, first, today) }
                guard let last = first.adding(days: -1), let range = monthRange(last.year, last.month) else { return nil }
                return (2, range.0, range.1)
            default:
                if !back { return (2, PyDate(today.year, 1, 1)!, today) }
                guard let first = PyDate(today.year - 1, 1, 1), let last = PyDate(today.year - 1, 12, 31) else { return nil }
                return (2, first, last)
            }
        }
        if let month = months[word] {
            if let next, yearPattern.fullMatch(next.keyText) != nil {
                guard let range = monthRange(decimal(next.keyText), month) else { return nil }
                return (2, range.0, range.1)
            }
            if needsYear.contains(word) { return nil }
            let year = month <= today.month ? today.year : today.year - 1
            guard let range = monthRange(year, month) else { return nil }
            return (1, range.0, range.1)
        }
        if let m = isoPattern.fullMatch(tokens[i].keyText) {
            let year = decimal(m.group(1)!), month = decimal(m.group(2)!)
            if let d = m.group(3) {
                guard let day = PyDate(year, month, decimal(d)) else { return nil }
                return (1, day, day)
            }
            guard let range = monthRange(year, month) else { return nil }
            return (1, range.0, range.1)
        }
        return nil
    }

    /// `_ranged`: since, after, before, until or a range (both ends). A day before 0001-01-01 or after 9999-12-31 makes
    /// no filter (Python raises OverflowError).
    private static func ranged(_ how: String, _ first: PyDate, _ last: PyDate, _ label: String, _ span: Range<Int>) -> [SearchFilter] {
        switch how {
        case "since": return [SearchFilter("since", first.iso, label, span)]
        case "after": return last.adding(days: 1).map { [SearchFilter("since", $0.iso, label, span)] } ?? []
        case "before": return first.adding(days: -1).map { [SearchFilter("until", $0.iso, label, span)] } ?? []
        case "until": return [SearchFilter("until", last.iso, label, span)]
        default: return [SearchFilter("since", first.iso, label, span), SearchFilter("until", last.iso, label, span)]
        }
    }

    // MARK: - Names

    /// `_Names`: phrases (casefolded word lists) → (kind, value), longest first.
    private struct Names {
        var phrases: [[ScalarKey]: (kind: String, value: String)] = [:]
        var longest = 0

        init(_ vocab: Vocabulary) {
            var parts: [ScalarKey: [String]] = [:]  // a set of names, by code points
            for name in vocab.people {
                let words = casefoldedWords(name)
                if words.count == 1 && little.contains(words[0]) { continue }
                phrases[words] = ("person", name)
                guard words.count > 1 else { continue }
                for w in words where w.scalars.count >= minPart && !little.contains(w) {
                    if !(parts[w] ?? []).contains(where: { Py.same($0, name) }) { parts[w, default: []].append(name) }
                }
            }
            for (w, names) in parts where phrases[[w]] == nil {
                if names.count == 1 {
                    phrases[[w]] = ("person", names[0])
                } else {  // "Anna" for every Anna
                    let first = Py.stableSorted(names, by: Py.less).first { casefoldedWords($0).contains(w) }!
                    let spelled = word.matches(in: first).map { $0.group()! }
                    phrases[[w]] = ("person", spelled[casefoldedWords(first).firstIndex(of: w)!])
                }
            }
            // A project's or an organization's name wins over a person's.
            let named = vocab.orgs.map { ("org", $0, $0) } + vocab.projects.map { ("project", $0.key, $0.value) }
            for (kind, value, name) in named {
                let words = casefoldedWords(name)
                if !words.isEmpty && !(words.count == 1 && little.contains(words[0])) { phrases[words] = (kind, value) }
            }
            longest = phrases.keys.map(\.count).max() ?? 0
        }

        func at(_ tokens: [Token], _ i: Int) -> (n: Int, kind: String, value: String)? {
            var n = min(longest, tokens.count - i)
            while n > 0 {
                defer { n -= 1 }
                let run = tokens[i..<(i + n)]
                if run.contains(where: \.quoted) { continue }
                if let hit = phrases[run.map(\.key)] { return (n, hit.kind, hit.value) }
            }
            return nil
        }

        func person(_ typed: String) -> String {
            if let hit = phrases[casefoldedWords(typed)], hit.kind == "person" { return hit.value }
            return Py.strip(typed)
        }
    }

    // MARK: - Parsing

    private static func label(_ text: String) -> String {
        guard let first = text.unicodeScalars.first else { return "" }
        return Py.strUpper(String(first)) + String(text.unicodeScalars.dropFirst())
    }

    /// `_written`: the filters of a written-out `key:value`.
    private static func written(_ key: String, _ value: String, _ span: Range<Int>, _ vocab: Vocabulary, _ names: Names,
                                _ today: PyDate) -> [SearchFilter] {
        let value = Py.strip(value)
        let folded = Py.casefold(value)
        switch key {
        case "person", "said":
            let person = names.person(value)
            return [SearchFilter("person", person, person, span)] + (key == "said" ? [SearchFilter("said", person, "Said by \(person)", span)] : [])
        case "project":
            let pid = vocab.projects.first { Py.same(Py.casefold($0.value), folded) }?.key
            return [SearchFilter("project", pid, pid.flatMap { vocab.projects[$0] } ?? value, span)]
        case "org":
            let org = vocab.orgs.first { Py.same(Py.casefold($0), folded) } ?? value
            return [SearchFilter("org", org, org, span)]
        case "in":
            guard let scope = scopes[ScalarKey(folded)] else { return [] }
            return [SearchFilter("in", scope, scopeLabels[scope]!.0, span)]
        case "is":
            guard ["reviewed", "unreviewed", "not-reviewed"].contains(where: { Py.same($0, folded) }) else { return [] }
            let done = Py.same(folded, "reviewed")
            return [SearchFilter("is", done ? "reviewed" : "unreviewed", done ? "Reviewed" : "Not reviewed", span)]
        case "has":
            return Py.same(folded, "steps") || Py.same(folded, "next-steps") ? [SearchFilter("has", "steps", "Has next steps", span)] : []
        default:
            let words = word.matches(in: value).map { Token($0.group()!, 0, 0) }
            guard !words.isEmpty, case let (_, first, last)? = dateAt(words, 0, today) else { return [] }
            return ranged(key, first, last, key != "date" ? "\(label(key)) \(value)" : value, span)
        }
    }

    /// `search.parse(text, vocab, today=today)`; `today` nil is today's local date.
    public static func parse(_ text: String, vocab: Vocabulary, today: PyDate? = nil) -> SearchQuery {
        let today = today ?? PyDate.today()
        let names = Names(vocab)
        let (tokens, keyed) = tokens(text)
        var filters: [SearchFilter] = []
        for (key, value, span) in keyed {
            for var f in written(key, value, span, vocab, names, today) {
                f.written = true
                filters.append(f)
            }
        }

        var used = [Bool](repeating: false, count: tokens.count)
        var persons: [(at: Int, filter: SearchFilter)] = []
        var oneWordProjects: [(filter: SearchFilter, at: Int)] = []
        var saidAt: [Int] = []
        var anyPerson = false
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.quoted {
                i += 1
                continue
            }
            let how: String? = sinceWords.contains(t.key) ? "since" : afterWords.contains(t.key) ? "after"
                : beforeWords.contains(t.key) ? "before" : untilWords.contains(t.key) ? "until" : nil
            if let how, i + 1 < tokens.count, !tokens[i + 1].quoted, case let (n, first, last)? = dateAt(tokens, i + 1, today) {
                let span = t.start..<tokens[i + n].end
                filters += ranged(how, first, last, label(SearchQuery.slice(text, span)), span)
                for j in i...(i + n) { used[j] = true }
                i += n + 1
                continue
            }
            if case let (n, first, last)? = dateAt(tokens, i, today) {
                let span = t.start..<tokens[i + n - 1].end
                filters += ranged("range", first, last, label(SearchQuery.slice(text, span)), span)
                for j in i..<(i + n) { used[j] = true }
                i += n
                continue
            }
            let step = steps.first { p in
                tokens[i..<min(i + p.count, tokens.count)].filter { !$0.quoted }.map(\.key) == p
            }?.count ?? 0
            if step > 0 || decide.contains(t.key) {
                let n = max(step, 1)
                let scope = step > 0 ? "steps" : "decisions"
                if !filters.contains(where: { $0.kind == "in" }) {
                    filters.append(SearchFilter("in", scope, scopeLabels[scope]!.0, t.start..<tokens[i + n - 1].end))
                }
                for j in i..<(i + n) { used[j] = true }
                i += n
                continue
            }
            if let hit = names.at(tokens, i) {
                let span = t.start..<tokens[i + hit.n - 1].end
                let shown = hit.kind == "project" ? vocab.projects[hit.value] ?? hit.value : hit.value
                let f = SearchFilter(hit.kind, hit.value, shown, span)
                filters.append(f)
                if hit.kind == "project" && hit.n == 1 { oneWordProjects.append((f, i)) }
                if hit.kind == "person" {
                    if let previous = persons.last, tokens[(previous.at + 1)..<max(previous.at + 1, i)].contains(where: { any.contains($0.key) }) {
                        anyPerson = true
                    }
                    persons.append((i, f))
                }
                for j in i..<(i + hit.n) { used[j] = true }
                i += hit.n
                continue
            }
            if said.contains(t.key) { saidAt.append(i) }
            i += 1
        }

        if let at = saidAt.first, !persons.isEmpty, !filters.contains(where: { $0.kind == "said" }) {
            let who = (persons.last { $0.at < at } ?? persons[0]).filter
            let t = tokens[at]
            filters.append(SearchFilter("said", who.value, "Said by \(who.value ?? "None")", t.start..<t.end))
        }

        func wordsLeft() -> [String] {
            let understood = !filters.isEmpty || (!tokens.isEmpty && !tokens[0].quoted && question.contains(tokens[0].key))
            return zip(tokens, used).compactMap { t, u in
                !u && (t.quoted || !(understood && little.contains(t.key))) ? t.text : nil
            }
        }

        var words = wordsLeft()
        if !words.isEmpty && !oneWordProjects.isEmpty {
            // "search ranking" is no search in the project "Search": a one-word project name is a filter only when
            // nothing else is searched for.
            for (f, at) in oneWordProjects {
                if let k = filters.firstIndex(where: { $0.same(f) }) { filters.remove(at: k) }
                used[at] = false
            }
            words = wordsLeft()
        }
        filters = Py.stableSorted(filters) { $0.span.lowerBound < $1.span.lowerBound }
        return SearchQuery(text: text, words: words, filters: filters, anyPerson: anyPerson)
    }
}
