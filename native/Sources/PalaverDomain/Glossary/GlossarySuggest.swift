// The glossary's suggestions (palaver/glossary.py:283-517): rare words, and ordinary ones the transcriber was
// unsure of, offered as a known name's variant, as a cluster of alike-sounding spellings, or as a new term; and
// what they are made from: the recordings' readable lines, their unsure words and the names spelled right.
// Words are Unicode scalars as Python's str; strings from the meetings compare by code points.
import Foundation
import PalaverCore

public enum GlossarySuggest {
    /// A known word this common is too ordinary to have variants ("Lead").
    public static let knownMaxZipf = 4.5
    /// Spelling similarity (0-100) for a variant of a known name, higher for a lower-case one (more likely an
    /// ordinary word misheard); a sound-alike needs `soundAlikeSimilarity`; a cluster's spellings `clusterSimilarity`.
    public static let variantSimilarity = 82.0
    public static let lowercaseVariantSimilarity = 88.0
    public static let soundAlikeSimilarity = 70.0
    public static let clusterSimilarity = 60.0
    public static let examples = 3

    /// `unsure` for words doubted every time they were said (Python passes a set: `math.inf` each).
    public static func everyTime(_ words: [String]) -> PyDict<Int> { PyDict(words.map { ($0, Int.max) }) }

    /// Where a word occurs.
    public struct Occurrences {
        public internal(set) var count = 0
        /// Each meeting once (by code points), in the order met; Python keeps a set and sorts it when shown.
        public internal(set) var meetings: [String] = []
        /// Up to `examples` lines, one per meeting: {"meeting", "start", "text"}.
        public internal(set) var examples: [JSONValue] = []
        /// False: an ordinary word, here only because it was heard unsure.
        public internal(set) var rare = true
        private var seen = Set<ScalarKey>()

        /// `times` occurrences in `meeting`, the first at `start` in `text`.
        mutating func add(_ meeting: String, _ start: Double, _ text: String, times: Int = 1) {
            count += times
            if seen.insert(ScalarKey(meeting)).inserted { meetings.append(meeting) }
            if examples.count < GlossarySuggest.examples,
               !examples.contains(where: { Py.same($0["meeting"]?.stringValue ?? "", meeting) }) {
                examples.append(.object([("meeting", .string(meeting)), ("start", .double(start)), ("text", .string(text))]))
            }
        }
    }

    /// Python's `defaultdict(Occurrences)` keyed by the word as written, in insertion order, changed in place.
    private struct Found {
        private(set) var words: [String] = []
        private(set) var items: [Occurrences] = []
        private var index: [ScalarKey: Int] = [:]

        init() {}
        init(_ pairs: [(String, Occurrences)]) { for (w, o) in pairs { update(w) { $0 = o } } }

        subscript(word: String) -> Occurrences? { index[ScalarKey(word)].map { items[$0] } }

        mutating func update(_ word: String, _ change: (inout Occurrences) -> Void) {
            let key = ScalarKey(word)
            if let i = index[key] { change(&items[i]); return }
            index[key] = items.count
            words.append(word)
            items.append(Occurrences())
            change(&items[items.count - 1])
        }

        var dict: PyDict<Occurrences> { PyDict(Array(zip(words, items))) }
    }

    // MARK: - words

    /// `[^\W\d_]`: a letter of `_WORD` (`\w` without decimal digits and "_").
    private static func isLetter(_ u: Unicode.Scalar) -> Bool { Py.isWordScalar(u) && !Py.isDecimal(u) && u != "_" }

    /// `_WORD.findall(text)` for `[^\W\d_](?:[\w'-]*[^\W\d_])?`: from a letter over the run of `\w`, `'` and `-`
    /// to its last letter.
    static func words(_ text: String) -> [String] {
        let s = Array(text.unicodeScalars)
        var out: [String] = []
        var i = 0
        while i < s.count {
            guard isLetter(s[i]) else { i += 1; continue }
            var last = i, k = i + 1
            while k < s.count, Py.isWordScalar(s[k]) || s[k] == "'" || s[k] == "-" {
                if isLetter(s[k]) { last = k }
                k += 1
            }
            out.append(String(String.UnicodeScalarView(s[i...last])))
            i = last + 1
        }
        return out
    }

    private static func length(_ s: String) -> Int { s.unicodeScalars.count }

    /// `word[0].isupper()`.
    private static func capitalized(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first else { return false }
        return Py.strIsUpper(String(first))
    }

    /// `_similar`: rapidfuzz's ratio of the casefolded spellings.
    private static func similar(_ a: String, _ b: String) -> Double { Fuzz.ratio(Py.casefold(a), Py.casefold(b)) }

    // MARK: - occurrences

    /// Rare words, and ordinary ones the transcriber was unsure of (`unsure`: casefolded word → how often; nil: none):
    /// meeting id → [(start, line)] in, word → where it occurs out. An ordinary word counts only capitalized and
    /// doubted at least half the times it was said: "Teil", said everywhere and doubted now and then, is no misheard
    /// "Theil".
    public static func occurrences(_ transcripts: PyDict<[(Double, String)]>, unsure: PyDict<Int>? = nil) -> PyDict<Occurrences> {
        found(byMeeting(transcripts), unsure ?? PyDict()).dict
    }

    /// What one meeting's lines give the suggestions, counted once per meeting: a meeting that did not change is not
    /// counted again when another one did (#29). The words are as `found` and the two-word names as `suggest` meet
    /// them, in the order of the lines.
    public struct MeetingWords: Sendable {
        /// A word of 3+ letters that is rare, or capitalized (an ordinary one counts when it was heard unsure).
        struct Word: Sendable {
            let word: String
            let rare: Bool
            var count: Int
            let start: Double
            let text: String
        }
        /// Two words in a row, the first capitalized: maybe a known name heard as two ("Data Bricks").
        struct Pair: Sendable {
            let joined: String  // casefolded, without the space
            let pair: String
            let start: Double
            let text: String
        }
        var words: [Word] = []
        /// Every word casefolded → how often it was said.
        var said: [ScalarKey: Int] = [:]
        var pairs: [Pair] = []

        /// `lines`: the meeting's readable lines, (start, text).
        public init(_ lines: [(Double, String)]) {
            var at: [ScalarKey: Int] = [:]  // the word's place in `words`; -1: neither rare nor capitalized
            for (start, text) in lines {
                let ws = GlossarySuggest.words(text)
                for word in ws {
                    said[ScalarKey(Py.casefold(word)), default: 0] += 1
                    guard GlossarySuggest.length(word) >= 3 else { continue }
                    let key = ScalarKey(word)
                    if let i = at[key] {
                        if i >= 0 { words[i].count += 1 }
                        continue
                    }
                    let rare = Zipf.isRare(word)
                    if !rare && !GlossarySuggest.capitalized(word) {
                        at[key] = -1
                        continue
                    }
                    at[key] = words.count
                    words.append(Word(word: word, rare: rare, count: 1, start: start, text: text))
                }
                for (first, second) in zip(ws, ws.dropFirst()) where GlossarySuggest.capitalized(first) {
                    pairs.append(Pair(joined: Py.casefold(first + second), pair: first + " " + second, start: start, text: text))
                }
            }
        }
    }

    /// The meetings' words, in the transcripts' order.
    private static func byMeeting(_ transcripts: PyDict<[(Double, String)]>) -> [(String, MeetingWords)] {
        transcripts.map { ($0.key, MeetingWords($0.value)) }
    }

    private static func found(_ meetings: [(String, MeetingWords)], _ doubted: PyDict<Int>) -> Found {
        var found = Found()
        for (meeting, m) in meetings {
            for w in m.words {
                if !w.rare && doubted[Py.casefold(w.word)] == nil { continue }
                found.update(w.word) { o in
                    o.rare = w.rare
                    o.add(meeting, w.start, w.text, times: w.count)
                }
            }
        }
        // All spellings of a word share its doubts ("Teil" and "teil" alike).
        var said: [ScalarKey: Int] = [:]
        for (folded, _) in doubted {
            let key = ScalarKey(folded)
            said[key] = meetings.reduce(0) { $0 + ($1.1.said[key] ?? 0) }
        }
        return Found(zip(found.words, found.items).filter { word, o in
            if o.rare { return true }
            let folded = Py.casefold(word)
            let d = doubted[folded] ?? 0, n = said[ScalarKey(folded)] ?? 0
            return d >= n - d  // 2 * doubted >= said, without overflowing a word doubted every time
        })
    }

    // MARK: - suggest

    /// `_known_words`: casefolded word → spelling (the first met), from known names and terms; not ordinary words
    /// ("Lead", "Spain"), whose look-alikes are mostly other words.
    private static func knownWords(_ known: [String]) -> PyDict<String> {
        var out = PyDict<String>()
        for name in known {
            for word in words(name) where length(word) >= 3 {
                let key = Py.casefold(word)
                if out[key] == nil && Zipf.zipf(word) < knownMaxZipf { out[key] = word }
            }
        }
        return out
    }

    private struct Suggestion {
        let kind: String
        let key: String
        let term: String
        let variants: [String]
        let count: Int
        let meetings: [String]
        let examples: [JSONValue]
        let unsure: Bool?

        var weight: Int { kind == "variant" ? 3 : kind == "cluster" ? 2 : 1 }

        var json: JSONValue {
            var fields: [(String, JSONValue)] = [
                ("kind", .string(kind)), ("key", .string(key)), ("term", .string(term)), ("variants", .strings(variants)),
                ("count", .int(count)), ("meetings", .strings(meetings)), ("examples", .array(examples)),
            ]
            if let unsure { fields.append(("unsure", .bool(unsure))) }
            return .object(fields)
        }
    }

    /// `sorted(set(words))`: each once by code points, in code point order.
    private static func sortedUnique(_ words: [String]) -> [String] {
        var seen = Set<ScalarKey>()
        return Py.stableSorted(words.filter { seen.insert(ScalarKey($0)).inserted }, by: Py.less)
    }

    /// Glossary suggestions, most worthwhile first: {"kind", "key", "term", "variants", "count", "meetings",
    /// "examples"} (and "unsure" for a variant). `known`: names and terms spelled right (calendar, people, projects),
    /// in the order their spellings take precedence. `unsure`: casefolded words the transcriber was unsure of, with
    /// how often; an ordinary one ("Cloud") may then be a known name misheard ("KLOUD"), though never a new term.
    public static func suggest(_ transcripts: PyDict<[(Double, String)]>, known: [String], glossary: Glossary,
                               unsure: PyDict<Int>? = nil) -> [JSONValue] {
        suggest(meetings: byMeeting(transcripts), known: known, glossary: glossary, unsure: unsure)
    }

    /// `suggest` over each meeting's words (`MeetingWords` of its readable lines), in meeting order.
    public static func suggest(meetings: [(String, MeetingWords)], known: [String], glossary: Glossary,
                               unsure: PyDict<Int>? = nil) -> [JSONValue] {
        var found = found(meetings, unsure ?? PyDict())
        let entries = glossary.terms.values
        let termTexts = entries.compactMap { $0["term"]?.stringValue }
        let knownWords = knownWords(known + termTexts)
        let mapped = Set(entries.flatMap { ($0["variants"]?.arrayValue ?? []).compactMap(\.stringValue) }.map { ScalarKey(Py.casefold($0)) })
        let inGlossary = Set(termTexts.map { ScalarKey(Py.casefold($0)) })
        let rejected = Set(glossary.rejected().map(ScalarKey.init))
        var out: [Suggestion] = []
        var placed = Set<ScalarKey>()
        var cologne: [ScalarKey: String] = [:]
        func code(_ word: String) -> String {
            if let c = cologne[ScalarKey(word)] { return c }
            let c = Cologne.code(word)
            cologne[ScalarKey(word)] = c
            return c
        }
        func isKnown(_ folded: String) -> Bool { knownWords[folded] != nil }

        func merge(_ words: [String]) -> (count: Int, meetings: [String], examples: [JSONValue]) {
            let all = words.compactMap { found[$0] }
            return (all.reduce(0) { $0 + $1.count }, sortedUnique(all.flatMap(\.meetings)),
                    Array(all.flatMap(\.examples).prefix(GlossarySuggest.examples)))
        }

        // 1. Variants of a known spelling.
        let knownList = zip(knownWords.keys, knownWords.values).map { k, spelling in
            (folded: Py.casefold(k), length: length(k), spelling: spelling)
        }
        var byTerm = PyDict<[String]>()
        for word in found.words {
            let key = Py.casefold(word)
            if isKnown(key) || mapped.contains(ScalarKey(key)) || inGlossary.contains(ScalarKey(key)) { continue }
            let folded = Py.casefold(key), keyLength = length(key)
            var best: String?, score = 0.0
            let needed = capitalized(word) ? variantSimilarity : lowercaseVariantSimilarity
            for k in knownList where abs(k.length - keyLength) <= 3 {
                var s = Fuzz.ratio(folded, k.folded)
                if s >= soundAlikeSimilarity && Py.same(code(word), code(k.spelling)) { s = max(s, needed) }
                if s >= needed && s > score { (best, score) = (k.spelling, s) }
            }
            if let best { byTerm[best] = (byTerm[best] ?? []) + [word] }
        }
        // A name heard as two words: "Data Bricks", "Zabek Hollmer".
        var joinedKnown = PyDict<String>()
        for (k, spelling) in knownWords {
            joinedKnown[String(String.UnicodeScalarView(k.unicodeScalars.filter { $0 != "-" }))] = spelling
        }
        // Capitalized, as names are: "hand over" is a verb, not "Handover" (MeetingWords keeps only those).
        for (meeting, m) in meetings {
            for p in m.pairs {
                guard let term = joinedKnown[p.joined], length(term) >= 6, !mapped.contains(ScalarKey(Py.casefold(p.pair)))
                else { continue }
                found.update(p.pair) { $0.add(meeting, p.start, p.text) }
                let listed = byTerm[term] ?? []
                if !listed.contains(where: { Py.same($0, p.pair) }) { byTerm[term] = listed + [p.pair] }
            }
        }
        for (term, words) in byTerm {
            let folded = Py.casefold(term)
            let words = words.filter { !rejected.contains(ScalarKey("variant:\(Py.casefold($0)):\(folded)")) }
            guard let first = words.first else { continue }
            for w in words { placed.insert(ScalarKey(w)) }
            let m = merge(words)
            out.append(Suggestion(kind: "variant", key: "variant:\(Py.casefold(first)):\(folded)", term: term,
                                  variants: sortedUnique(words), count: m.count, meetings: m.meetings, examples: m.examples,
                                  unsure: words.contains { found[$0]?.rare == false }))
        }

        // 2. Clusters: rare capitalized spellings that sound alike, none known.
        let candidates = zip(found.words, found.items).compactMap { w, o -> String? in
            let folded = Py.casefold(w)
            guard !placed.contains(ScalarKey(w)), o.rare, capitalized(w), !mapped.contains(ScalarKey(folded)),
                  !inGlossary.contains(ScalarKey(folded)), !isKnown(folded) else { return nil }
            return w
        }
        var groups = PyDict<[String]>()
        for w in candidates { groups[code(w)] = (groups[code(w)] ?? []) + [w] }
        for (code, group) in groups {
            let spellings = Set(group.map { ScalarKey(Py.casefold($0)) })
            if spellings.count < 2 || length(code) < 2 { continue }
            var words = Py.stableSorted(group) { (found[$0]?.count ?? 0) > (found[$1]?.count ?? 0) }
            let head = words[0]
            if words.dropFirst().contains(where: { similar(head, $0) < clusterSimilarity }) {
                words = [head] + words.dropFirst().filter { similar(head, $0) >= clusterSimilarity }
                if Set(words.map { ScalarKey(Py.casefold($0)) }).count < 2 { continue }
            }
            let key = "cluster:" + sortedUnique(words.map(Py.casefold)).joined(separator: ",")
            if rejected.contains(ScalarKey(key)) { continue }
            for w in words { placed.insert(ScalarKey(w)) }
            let m = merge(words)
            out.append(Suggestion(kind: "cluster", key: key, term: head, variants: words, count: m.count,
                                  meetings: m.meetings, examples: m.examples, unsure: nil))
        }

        // 3. New terms: rare capitalized words that recur across meetings. A plural ("Sidequests") counts as its
        // singular.
        for w in candidates {
            if placed.contains(ScalarKey(w)) { continue }
            let scalars = w.unicodeScalars
            if scalars.last == "s", found[String(String.UnicodeScalarView(scalars.dropLast()))] != nil { continue }
            guard let o = found[w] else { continue }
            let plural = found[w + "s"]
            var meetings = Set(o.meetings.map(ScalarKey.init))
            for m in plural?.meetings ?? [] { meetings.insert(ScalarKey(m)) }
            if meetings.count < 2 && o.count < 5 { continue }
            let key = "term:\(Py.casefold(w))"
            if rejected.contains(ScalarKey(key)) { continue }
            let m = merge(plural != nil ? [w, w + "s"] : [w])
            out.append(Suggestion(kind: "term", key: key, term: w, variants: [], count: m.count, meetings: m.meetings,
                                  examples: m.examples, unsure: nil))
        }

        let sorted = Py.stableSorted(out) { a, b in
            let x = -a.weight * (a.count + 3 * a.meetings.count), y = -b.weight * (b.count + 3 * b.meetings.count)
            return x != y ? x < y : Py.less(Py.casefold(a.term), Py.casefold(b.term))
        }
        return sorted.map(\.json)
    }

    // MARK: - from the recordings

    /// The recording folders under `outputDir`, by name in code point order (Python: `iterdir`, or `sorted` of it).
    private static func recordingFolders(_ outputDir: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: outputDir.path, isDirectory: &isDir), isDir.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: outputDir.path) else { return [] }
        return Py.stableSorted(names.filter(RecordingPaths.isRecordingFolderName), by: Py.less)
            .map { outputDir.appendingPathComponent($0) }
    }

    /// `w.strip(".,?!:;")`.
    private static func stripPunctuation(_ w: String) -> String {
        let marks: Set<Unicode.Scalar> = [".", ",", "?", "!", ":", ";"]
        let scalars = w.unicodeScalars
        guard let first = scalars.firstIndex(where: { !marks.contains($0) }),
              let last = scalars.lastIndex(where: { !marks.contains($0) }) else { return "" }
        return String(scalars[first...last])
    }

    /// Words the transcriber was unsure of in any recording (casefolded, without the punctuation around them), with
    /// how often, except in lines the user rewrote. A transcript.json that is no JSON is left out.
    public static func unsureWords(outputDir: URL) -> PyDict<Int> {
        var out = PyDict<Int>()
        for folder in recordingFolders(outputDir) {
            for (word, n) in unsureWords(RecordingPaths(folder)) ?? PyDict() { out[word] = (out[word] ?? 0) + n }
        }
        return out
    }

    /// One meeting's share of `unsureWords`; nil: its transcript.json is missing or no JSON.
    public static func unsureWords(_ paths: RecordingPaths) -> PyDict<Int>? {
        guard let lines = PythonJSON.read(paths.transcriptJson)?.arrayValue else { return nil }
        var out = PyDict<Int>()
        for line in lines {
            guard case .object(let fields) = line, !fields.contains(where: { Py.same($0.0, "heard") }) else { continue }
            for w in (line["unsure"]?.arrayValue ?? []).compactMap(\.stringValue) {
                let word = Py.casefold(stripPunctuation(w))
                out[word] = (out[word] ?? 0) + 1
            }
        }
        return out
    }

    /// Every processed meeting's readable lines (the glossary of `stores` applied, removed voices left out):
    /// id → [(start rounded to 2 digits, text)], in folder name order. A transcript that can't be read is left out.
    public static func corpus(outputDir: URL, stores: StorePaths = .current()) -> PyDict<[(Double, String)]> {
        var out = PyDict<[(Double, String)]>()
        let glossary = Glossary.current(stores: stores)
        for folder in recordingFolders(outputDir) {
            guard let cleaned = cleanedLines(RecordingPaths(folder)) else { continue }
            out[folder.lastPathComponent] = readableLines(cleaned, glossary: glossary)
        }
        return out
    }

    /// A meeting's lines as `Readable` cleans them (fillers out; removed voices left out), before the glossary:
    /// (start, text). The slow part of `corpus`, and the same whatever the glossary says. nil: no transcript that
    /// can be read.
    public static func cleanedLines(_ paths: RecordingPaths) -> [(Double, String)]? {
        guard FileManager.default.fileExists(atPath: paths.transcriptJson.path),
              let items = PythonJSON.read(paths.transcriptJson)?.arrayValue,
              let utterances = try? items.map({ try Utterance(json: $0) }),
              let corrected = try? Speakers.withoutIgnored(paths, utterances) else { return nil }
        return corrected.map { ($0.start, $0.heard != nil ? $0.text : Readable.cleanText($0.text)) }
    }

    /// `cleanedLines` as `corpus` has them (`Readable.readable`): the glossary applied, lines left without a word
    /// dropped, starts rounded to 2 digits.
    public static func readableLines(_ cleaned: [(Double, String)], glossary: Glossary) -> [(Double, String)] {
        // `Readable.core(shown).isEmpty`, without making it: a line has a core when it has a word letter.
        zip(cleaned, glossary.apply(lines: cleaned.map(\.1))).compactMap { line, shown in
            shown.unicodeScalars.contains(where: Py.isWordScalar) ? (Py.round(line.0, 2), shown) : nil
        }
    }

    /// Names spelled right: the user's, calendar titles and attendees (rooms too: their names are places people
    /// mention), people of the voice bank, projects, the speakers' names in effect. Each once by code points, in
    /// `knownOrder` (Python returns a set; its order, which decides ties in `suggest`, changes from run to run).
    public static func knownSpellings(outputDir: URL, userName: String, stores: StorePaths = .current()) throws -> [String] {
        try knownSpellings(userName: userName, stores: stores,
                           meetings: recordingFolders(outputDir).map { try knownSpellings(RecordingPaths($0)) })
    }

    /// `knownSpellings` with each meeting's share (`knownSpellings(paths)`) given, in folder name order.
    public static func knownSpellings(userName: String, stores: StorePaths, meetings: [[String]]) throws -> [String] {
        var known: [String] = userName.isEmpty ? [] : [userName]
        known += try VoiceBank(directory: stores.voices).names().keys
        known += ProjectStore(path: stores.projects).projects.values.compactMap { $0["name"]?.stringValue }
        for names in meetings { known += names }
        var seen = Set<ScalarKey>()
        return Py.stableSorted(known.filter { !$0.isEmpty && seen.insert(ScalarKey($0)).inserted }, by: knownOrder)
    }

    /// One meeting's names spelled right: its calendar event's title and attendees, its speakers' names in effect.
    public static func knownSpellings(_ paths: RecordingPaths) throws -> [String] {
        var known: [String] = []
        if let event = CalendarEvents.load(paths) {
            known.append(event.title)
            known += event.attendees.map(\.name)
        }
        known += try Speakers.namesInEffect(paths).values
        return known
    }

    /// The order of the known spellings, which decides `suggest`'s ties (the spelling a casefolded word keeps, the
    /// known name a variant goes to): a name not all in capitals first ("Karel" before "KAREL"), then by code points.
    /// tools/parity/ops.py sorts Python's set with the same key, `(s.isupper(), s)`.
    public static func knownOrder(_ a: String, _ b: String) -> Bool {
        let x = Py.strIsUpper(a), y = Py.strIsUpper(b)
        return x != y ? !x : Py.less(a, b)
    }
}
