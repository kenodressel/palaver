// The search (api.py:1655-1951, :1957-2042; #46): a query's filters (people who took part, an organization, projects,
// dates, reviewed, next steps) and every word of it in the part searched (title, notes, transcript; decisions only,
// next steps only, or one person's lines), and the search by meaning within the same filters. What a search reads of
// each meeting (its names, notes and readable lines) is kept while the meeting's files are unchanged, so only the first
// search after a change reads it; the Background warms it at the start.
import Foundation
import PalaverCore
import PalaverDomain

/// What the search keeps per meeting (api.py `_SEARCH_CACHE`, `_PARTICIPANTS_CACHE`, `_ORG_INDEX`).
public final class SearchCaches: @unchecked Sendable {
    /// id → names and notes; the lines are made on the first search that needs them.
    let meetings = SignatureCache<SearchAPI.MeetingText>()
    /// id + the user's name → who spoke and who was invited.
    let participants = SignatureCache<SearchAPI.Participants>()
    private let lock = NSLock()
    private var orgKey: [Int]?
    private var orgIndex = PyDict<JSONValue>()
    private var made = 0

    public init() {}

    /// How many times a meeting's lines were made readable (Python's tests count `api.readable`'s calls).
    public var linesMade: Int { lock.withLock { made } }

    func countLines() { lock.withLock { made += 1 } }

    /// `_org_index`: everyone the calendars invited (`Orgs.peopleIndex`), read again only when a calendar file changed:
    /// the times of `*/calendar.json` (no hidden folder), in path order.
    func orgIndex(_ outputDir: URL) -> PyDict<JSONValue> {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        let files = Py.stableSorted(names, by: Py.less).map { outputDir.appendingPathComponent($0).appendingPathComponent("calendar.json") }
            .filter { MeetingsAPI.exists($0) }
        let key = SignatureCache<Int>.signature(files)
        if let key, let kept: PyDict<JSONValue> = lock.withLock({ orgKey == key ? orgIndex : nil }) { return kept }
        let index = Orgs.peopleIndex(outputDir: outputDir)
        lock.withLock {
            orgKey = key
            orgIndex = index
        }
        return index
    }
}

public enum SearchAPI {
    public static let SEARCH_HITS_PER_MEETING = 5
    public static let SEARCH_MAX_MEETINGS = 50
    public static let SEARCH_NOTES_HITS = 3
    public static let SEARCH_MEANING_MEETINGS = 6

    /// `_search_words`: each word, matched where a word starts ("rtv" finds "RTV" and "RTV-Projekt", not
    /// "Wortvorrat"); a quoted phrase is one word.
    static func words(_ words: [String]) throws -> [PyRegex] {
        try words.map { try PyRegex(#"(?<!\w)"# + PyRegex.escape($0), ignoreCase: true) }
    }

    static func hasAll(_ words: [PyRegex], _ text: String) -> Bool {
        words.allSatisfy { $0.firstMatch(in: text) != nil }
    }

    // MARK: - who took part

    struct Participants {
        let spoke: [String]
        let invited: [String]
    }

    /// `_participants`: who spoke (named speakers, and the user when they said something) and who was invited.
    static func participants(_ app: ServerApp, _ paths: RecordingPaths, userName: String) throws -> Participants {
        try app.searchCaches.participants.get(key: paths.folder.path + "\n" + userName,
                                              files: MeetingsAPI.signatureFiles(paths, app)) {
            let ignored = Set(Speakers.loadIgnored(paths).map(ScalarKey.init))
            var spoke = try Speakers.namesInEffect(paths).filter { !ignored.contains(ScalarKey($0.key)) }.map(\.value)
            if !userName.isEmpty, try MeetingsAPI.utterances(paths).contains(where: { Py.same($0.speaker, userName) }) {
                spoke.append(userName)
            }
            let invited = CalendarEvents.load(paths).map { CalendarEvents.candidates($0, userName: "").map(\.name) } ?? []
            return Participants(spoke: unique(spoke), invited: invited)
        }
    }

    /// `list(dict.fromkeys(items))`, by code points.
    static func unique(_ items: [String]) -> [String] {
        var seen = Set<ScalarKey>()
        return items.filter { seen.insert(ScalarKey($0)).inserted }
    }

    private static let wordRun = try! PyRegex(#"\w+"#)

    static func nameWords(_ name: String) -> [String] { wordRun.matches(in: Py.casefold(name)).map { $0.group()! } }

    /// `is_person`: whether `name` (a speaker or invitee) is `wanted` — every word of it ("Anna" is Anna Berger), or the
    /// same first name when `name` is only a first name (a speaker called "Anna" is Anna Berger).
    public static func isPerson(_ wanted: String, _ name: String) -> Bool {
        let want = nameWords(wanted), have = nameWords(name)
        if want.isEmpty || have.isEmpty { return false }
        return want.allSatisfy { w in have.contains { Py.same($0, w) } } || (have.count == 1 && Py.same(have[0], want[0]))
    }

    /// `_took_part`: 2 spoke, 1 was invited, 0 neither.
    static func tookPart(_ person: String, _ who: Participants) -> Int {
        if who.spoke.contains(where: { isPerson(person, $0) }) { return 2 }
        return who.invited.contains(where: { isPerson(person, $0) }) ? 1 : 0
    }

    /// `search_vocabulary`: the names a search knows — people who spoke or were invited, the voice bank, projects and
    /// organizations.
    static func vocabulary(_ app: ServerApp, _ meetings: [JSONValue], userName: String,
                           hideProjects: Set<ScalarKey> = []) throws -> Vocabulary {
        var found = PyDict<String>()
        func add(_ name: String) { if found[Py.casefold(name)] == nil { found[Py.casefold(name)] = name } }
        add(userName)
        try VoiceBank(directory: app.stores.voices).names().keys.forEach(add)
        for m in meetings {
            let who = try participants(app, paths(app, m), userName: userName)
            (who.spoke + who.invited).forEach(add)
        }
        let store = ProjectStore(path: app.stores.projects)
        var projects = PyDict<String>()
        for (pid, p) in store.projects where !hideProjects.contains(ScalarKey(pid)) {
            projects[pid] = p["name"]?.stringValue ?? Py.str(p["name"] ?? .null)
        }
        let index = app.searchCaches.orgIndex(app.outputDir)
        let orgs = index.isEmpty ? [] : Orgs.summary(index, Organizations(path: app.stores.organizations))
            .compactMap { $0["name"]?.stringValue }
        return Vocabulary(people: Py.stableSorted(found.values.filter { !$0.isEmpty }, by: Py.less), projects: projects, orgs: orgs)
    }

    static func paths(_ app: ServerApp, _ m: JSONValue) -> RecordingPaths {
        RecordingPaths(app.outputDir.appendingPathComponent(m["id"]?.stringValue ?? "", isDirectory: true))
    }

    /// `_start_day`: the day of the meeting's start as written (its own offset); nil without one.
    static func startDay(_ m: JSONValue) -> PyDate? {
        guard let start = m["start"]?.stringValue, !start.isEmpty, Py.fromIso(start) != nil else { return nil }
        return PyDate(iso: String(String.UnicodeScalarView(start.unicodeScalars.prefix(10))))
    }

    // MARK: - what a meeting is searched in

    struct Line {
        let start: Double
        let speaker: String
        let text: String
    }

    /// A meeting's names and notes as the search reads them, and its readable lines once a search needed them
    /// (`_SEARCH_CACHE`'s entry).
    final class MeetingText: @unchecked Sendable {
        let names: PyDict<String>
        let notes: JSONValue?
        private let lock = NSLock()
        private var made: [Line]?

        init(names: PyDict<String>, notes: JSONValue?) {
            self.names = names
            self.notes = notes
        }

        /// The transcript as read (without removed voices, names put in, rooms shown, made readable), once.
        func lines(_ app: ServerApp, _ paths: RecordingPaths) throws -> [Line] {
            if let made = lock.withLock({ made }) { return made }
            let raw = try Speakers.withoutIgnored(paths, try MeetingsAPI.utterances(paths))
            let shown = SharedMic.shown(paths, Speakers.applySpeakerNames(raw, names))
            app.searchCaches.countLines()
            let lines = Readable.readable(shown, glossary: Glossary.current(stores: app.stores))
                .map { Line(start: $0.start, speaker: $0.speaker, text: $0.text) }
            lock.withLock { made = lines }
            return lines
        }
    }

    /// `_Found`: a meeting that passed the filters, with what the words may be found in.
    struct Found {
        let m: JSONValue
        /// How the people took part: speakers before invitees.
        let score: Int
        let paths: RecordingPaths
        let text: MeetingText
        var names: PyDict<String> { text.names }
        var notes: JSONValue? { text.notes }

        init(_ app: ServerApp, _ m: JSONValue, score: Int) throws {
            self.m = m
            self.score = score
            paths = SearchAPI.paths(app, m)
            let paths = paths
            text = try app.searchCaches.meetings.get(key: paths.folder.path, files: MeetingsAPI.signatureFiles(paths, app)) {
                let names = try MeetingsAPI.displayNames(paths)
                let raw = Notes.load(paths)
                return MeetingText(names: names, notes: raw.map {
                    Glossary.current(stores: app.stores).applyTo(Notes.withNames($0, names))
                })
            }
        }

        func lines(_ app: ServerApp) throws -> [Line] { try text.lines(app, paths) }

        /// The notes, piece by piece: decisions, next steps, points, summary.
        func items() -> [JSONValue] {
            let n = notes.flatMap { $0.isObject ? $0 : nil } ?? .object([])
            func list(_ v: JSONValue?) -> [JSONValue] { v.flatMap { $0.truthy ? $0.arrayValue : nil } ?? [] }
            func text(_ v: JSONValue?) -> String { v.flatMap { $0.truthy ? $0.stringValue : nil } ?? "" }
            var out: [JSONValue] = list(n["decisions"]).compactMap { d in
                d.stringValue.map { .object([("kind", .string("decision")), ("text", .string($0))]) }
            }
            out += list(n["next_steps"]).filter(\.isObject).map { s in
                .object([("kind", .string("step")), ("text", .string(text(s["task"]))), ("owner", .string(text(s["owner"])))])
            }
            for section in list(n["sections"]) {
                for point in list(section["points"]) {
                    let parts = [text(point["text"])] + list(point["details"]).map { $0.stringValue ?? "" }
                    out.append(.object([("kind", .string("point")), ("text", .string(Py.strip(parts.joined(separator: " ")))),
                                        ("heading", .string(text(section["heading"])))]))
                }
            }
            if let summary = n["summary"], summary.truthy {
                out.append(.object([("kind", .string("summary")), ("text", summary)]))
            }
            return out
        }
    }

    /// `_item_text`: the owner, heading and text of a notes piece.
    static func itemText(_ item: JSONValue) -> String {
        ["owner", "heading", "text"].compactMap { item[$0].flatMap { $0.truthy ? $0.stringValue : nil } }.joined(separator: " ")
    }

    /// `_filtered`: the meetings that pass the query's filters, newest first.
    static func filtered(_ app: ServerApp, _ q: SearchQuery, userName: String, exclude: Set<ScalarKey> = []) throws -> [Found] {
        let meetings = try MeetingsAPI.listMeetings(app: app).filter { !exclude.contains(ScalarKey($0["id"]?.stringValue ?? "")) }
        let wantOrgs = Set(q.orgs.map { ScalarKey(Py.casefold($0)) })
        let index = wantOrgs.isEmpty ? PyDict() : app.searchCaches.orgIndex(app.outputDir)
        let orgNames = wantOrgs.isEmpty ? nil : Organizations(path: app.stores.organizations)
        var out: [Found] = []
        for m in meetings {
            let day = startDay(m)
            if let since = q.since, day.map({ $0 < since }) ?? true { continue }
            if let until = q.until, day.map({ $0 > until }) ?? true { continue }
            let projects = m["projects"]?.arrayValue ?? []
            if !q.projects.allSatisfy({ pid in projects.contains { p in pid.map { Py.same(p["id"]?.stringValue ?? "", $0) } ?? false } }) {
                continue
            }
            let paths = paths(app, m)
            if let reviewed = q.reviewed, MeetingsAPI.exists(paths.review) != reviewed { continue }
            let who = try participants(app, paths, userName: userName)
            let took = q.people.map { tookPart($0, who) }
            if !took.isEmpty && !(q.anyPerson ? took.contains { $0 != 0 } : took.allSatisfy { $0 != 0 }) { continue }
            if let orgNames {
                let theirs = Set((who.spoke + who.invited).map { ScalarKey(Py.casefold(Orgs.orgOf($0, index, orgNames) ?? "")) })
                    .subtracting([ScalarKey("")])
                if !wantOrgs.isSubset(of: theirs) { continue }
            }
            let found = try Found(app, m, score: took.reduce(0, +))
            if q.hasSteps && !(found.notes?["next_steps"]?.truthy ?? false) { continue }
            out.append(found)
        }
        return out
    }

    /// `_SCOPE_KINDS`: the notes pieces each scope searches.
    static func scopeKinds(_ scope: String?) -> Set<String> {
        switch scope {
        case "decisions": return ["decision"]
        case "steps": return ["step"]
        case "title", "transcript": return []
        default: return ["decision", "step", "point", "summary"]
        }
    }

    /// `_line`.
    static func line(_ u: Line) -> JSONValue {
        .object([("start", .double(Py.round(u.start, 2))), ("speaker", .string(u.speaker)), ("text", .string(u.text))])
    }

    /// The order results are ranked by (`_rank`): in the title, a decision or next step, in the notes, how many lines,
    /// how the people took part.
    struct Rank: Comparable {
        let inTitle: Bool, decided: Bool, inNotes: Bool, lines: Int, score: Int

        private var tuple: (Int, Int, Int, Int, Int) { (inTitle ? 1 : 0, decided ? 1 : 0, inNotes ? 1 : 0, lines, score) }
        static func < (a: Rank, b: Rank) -> Bool { a.tuple < b.tuple }
        static func == (a: Rank, b: Rank) -> Bool { a.tuple == b.tuple }
    }

    /// `_matched`: the meeting as a result — the notes pieces and transcript lines the words are in; nil when they are not
    /// all in the part searched.
    static func matched(_ app: ServerApp, _ f: Found, _ q: SearchQuery) throws -> (PyDict<JSONValue>, Rank)? {
        let words = try words(q.words)
        let scope = q.saidBy == nil ? q.scope : "transcript"
        let title = f.m["title"].flatMap { $0.truthy ? $0.stringValue : nil } ?? ""
        let kinds = scopeKinds(scope)
        let items = f.items().filter { kinds.contains($0["kind"]?.stringValue ?? "") }
        var lines: [Line] = []
        if scope == nil || scope == "transcript" {
            lines = try f.lines(app).filter { u in q.saidBy.map { isPerson($0, u.speaker) } ?? true }
        }
        var texts = (scope == nil || scope == "title" ? [title] : []) + items.map(itemText)
        texts += q.saidBy == nil ? lines.map { "\($0.speaker) \($0.text)" } : lines.map(\.text)
        var noteHits: [JSONValue], lineHits: [Line]
        var inTitle = false, inNotes = false
        if words.isEmpty {
            if (scope == "decisions" || scope == "steps") && items.isEmpty { return nil }
            if q.saidBy != nil && lines.isEmpty { return nil }
            noteHits = scope == "decisions" || scope == "steps" ? items : []
            lineHits = q.saidBy != nil ? lines : []
        } else {
            if !hasAll(words, texts.joined(separator: " ")) { return nil }
            noteHits = items.filter { hasAll(words, itemText($0)) }
            lineHits = lines.filter { hasAll(words, q.saidBy != nil ? $0.text : "\($0.speaker) \($0.text)") }
            inTitle = (scope == nil || scope == "title") && hasAll(words, title)
            inNotes = hasAll(words, ([title] + items.map(itemText)).joined(separator: " "))
        }
        let order = ["decision": 0, "step": 1, "point": 2, "summary": 3]
        noteHits = Py.stableSorted(noteHits) { order[$0["kind"]?.stringValue ?? ""]! < order[$1["kind"]?.stringValue ?? ""]! }
        var r = PyDict<JSONValue>(f.m) ?? PyDict()
        r["in_title"] = .bool(inTitle)
        r["in_notes"] = .bool(inNotes)
        r["notes_hits"] = .array(Array(noteHits.prefix(SEARCH_NOTES_HITS)))
        r["hits"] = .array(lineHits.prefix(SEARCH_HITS_PER_MEETING).map(line))
        r["hit_count"] = .int(lineHits.count)
        let decided = noteHits.contains { ["decision", "step"].contains($0["kind"]?.stringValue ?? "") }
        return (r, Rank(inTitle: inTitle, decided: decided, inNotes: inNotes, lines: lineHits.count, score: f.score))
    }

    // MARK: - the search

    /// `run_search`: the query as understood and its results, best first (stable: newest first among equals).
    static func run(_ app: ServerApp, _ text: String, userName: String, exclude: Set<ScalarKey> = [],
                    hideProjects: Set<ScalarKey> = [], today: PyDate? = nil) throws -> (SearchQuery, [JSONValue]) {
        let meetings = try MeetingsAPI.listMeetings(app: app).filter { !exclude.contains(ScalarKey($0["id"]?.stringValue ?? "")) }
        let q = SearchParser.parse(text, vocab: try vocabulary(app, meetings, userName: userName, hideProjects: hideProjects),
                                   today: today)
        if q.empty { return (q, []) }
        let results = try filtered(app, q, userName: userName, exclude: exclude).compactMap { try matched(app, $0, q) }
        let ranked = Py.stableSorted(results) { $0.1 > $1.1 }
        return (q, ranked.prefix(SEARCH_MAX_MEETINGS).map { $0.0.json })
    }

    /// api.search: meetings for a search, ranked (the title, then a decision or next step, then the notes, then the most
    /// transcript lines, then how the people took part, then the newest).
    public static func search(_ app: ServerApp, _ query: String, userName: String, today: PyDate? = nil) throws -> [JSONValue] {
        try run(app, query, userName: userName, today: today).1
    }

    /// `search_page`: the results, the filters understood (as chips), the words, and whether search by meaning can add to
    /// them ("ready") or not ("off").
    public static func page(_ app: ServerApp, _ query: String, userName: String, today: PyDate? = nil) throws -> JSONValue {
        let (q, results) = try run(app, query, userName: userName, today: today)
        let ready = !q.words.isEmpty && SearchIndex.ready(outputDir: app.outputDir, stores: app.stores,
                                                          modelFolder: { app.background.modelFolder(app) })
        return .object([("query", .string(query)), ("understood", .array(q.chips())), ("words", .strings(q.words)),
                        ("results", .array(results)), ("meaning", .string(ready ? "ready" : "off"))])
    }

    /// `_MEANING_KINDS`: the pieces each scope finds by meaning (nil: all).
    static func meaningKinds(_ scope: String?) -> [String]? {
        switch scope {
        case "decisions": return ["decision"]
        case "steps": return ["step"]
        case "notes": return ["summary", "decision", "step", "point"]
        case "transcript": return ["line"]
        default: return nil
        }
    }

    /// `search_meaning`: meetings about the query's words by meaning, within its filters, best first, each with its best
    /// pieces (`meaning`): notes pieces, or lines with who said them and when. Empty when it is switched off, or nothing
    /// is indexed.
    public static func meaning(_ app: ServerApp, _ query: String, userName: String, searcher: Searcher? = nil,
                               exclude: Set<ScalarKey> = [], hideProjects: Set<ScalarKey> = [],
                               today: PyDate? = nil) throws -> [JSONValue] {
        guard SearchIndex.enabled(stores: app.stores) else { return [] }
        let meetings = try MeetingsAPI.listMeetings(app: app).filter { !exclude.contains(ScalarKey($0["id"]?.stringValue ?? "")) }
        let q = SearchParser.parse(query, vocab: try vocabulary(app, meetings, userName: userName, hideProjects: hideProjects),
                                   today: today)
        if q.words.isEmpty || q.scope == "title" { return [] }
        var found = PyDict<Found>()
        for f in try filtered(app, q, userName: userName, exclude: exclude) { found[f.paths.folder.lastPathComponent] = f }
        if found.isEmpty { return [] }
        let kinds = q.saidBy != nil ? ["line"] : meaningKinds(q.scope)
        var who: ((RecordingPaths, String) -> Bool)?
        if let saidBy = q.saidBy {
            who = { paths, label in isPerson(saidBy, found[paths.folder.lastPathComponent]?.names[label] ?? label) }
        }
        let hits = try (searcher ?? app.background.searcher()).search(q.words.joined(separator: " "), in: found.values.map(\.paths),
                                                                      kinds: kinds, speaker: who)
        let glossary = Glossary.current(stores: app.stores)
        var out: [(PyDict<JSONValue>, Double)] = []
        for (mid, pieces) in hits {
            guard let f = found[mid] else { continue }
            let shown: [JSONValue] = pieces.map { piece in
                var p = PyDict<JSONValue>(glossary.applyTo(Notes.withNames(piece, f.names))) ?? PyDict()
                if p["kind"]?.stringValue == "line", let label = p["speaker"]?.stringValue {
                    p["speaker"] = .string(f.names[label] ?? label)
                }
                return p.json
            }
            var r = PyDict<JSONValue>(f.m) ?? PyDict()
            r["meaning"] = .array(shown)
            out.append((r, pieces.first?["score"]?.doubleValue ?? 0))
        }
        return Py.stableSorted(out) { $0.1 > $1.1 }.prefix(SEARCH_MEANING_MEETINGS).map { $0.0.json }
    }
}

extension Router {
    /// The search (server.py's GET branches): `q` is the first value of the query's `q`, blank when there is none.
    static func addSearchRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/search") { req, _ in
            .json(try SearchAPI.page(app, req.queryValue("q") ?? "", userName: app.userName))
        }
        r.get("/api/search/meaning") { req, _ in
            .json(.array(try SearchAPI.meaning(app, req.queryValue("q") ?? "", userName: app.userName)))
        }
    }
}
