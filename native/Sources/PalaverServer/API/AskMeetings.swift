// Ask your meetings (#42): one question across the whole archive, on the Ask page. The search finds the passages that
// matter first — transcript lines with the lines around them, the notes' decisions, next steps, points and summaries,
// the user's own notes; by meaning too when search by meaning is on — and only those go to the model, never whole
// transcripts. People, projects, series and dates the question names (or the page's filters) narrow the meetings
// searched, as in the search box. The model cites the passages by number; the answer comes back with each cited
// passage's meeting and time, so a click plays the moment.
//
// It runs on the notes' model (palaver-lm `ask`, `app.askMeetings`). A meeting kept on this Mac never goes to a cloud
// model: with a cloud model its passages are left out and the answer says how many meetings that was; "Ask on this
// Mac" (`include_local`) keeps them and runs the local model instead. The local model runs only with the free memory
// the notes need and, during a call, only after a second click (`confirm` in the answer, then `confirmed`). Nothing is
// kept on disk: the page keeps the last questions for the session.
import Foundation
import PalaverCore
import PalaverDomain

public enum AskMeetingsAPI {
    /// The model it runs on: the notes' (palaver-lm's AskMeetings.FEATURE).
    public static let FEATURE = "notes"
    public static let MAX_QUESTION_CHARS = 500
    /// The passages given to the model, at most: all of them, per meeting, and their text in all.
    public static let MAX_PASSAGES = 24
    public static let PER_MEETING = 4
    public static let MAX_CHARS = 14_000
    /// A line found comes with this many lines before and after it; one passage spans at most `MAX_WINDOW` lines.
    public static let CONTEXT_LINES = 1
    public static let MAX_WINDOW = 6
    /// A line's text in a passage, at most.
    public static let MAX_LINE_CHARS = 400
    /// Without words to look for (a question of filters only, "what happened with Anna last week"): the summaries of
    /// this many of the newest meetings that pass the filters.
    public static let SUMMARY_MEETINGS = 8
    static let PENDING = "No model yet: choose one for Notes in Settings → Language model."
    static let NO_QUESTION = "Type a question first."

    /// Words of a question that say how it is asked, not what about: never looked for (the search's own little words
    /// are dropped by its parser already).
    static let ASKING: Set<ScalarKey> = Set([
        "happen", "happened", "happens", "discuss", "discussed", "discussion", "talked", "said", "say", "tell", "told",
        "know", "think", "thought", "last", "latest", "recent", "recently", "first", "ever", "again", "also", "still",
        "please", "summary", "summarize", "summarise", "overview", "status", "update", "much", "many", "often", "time",
        "times", "something", "anything", "everything", "thing", "things", "not", "no", "yes", "if", "so", "then",
        "than", "into", "out", "up", "down", "over", "just", "very", "really", "already", "yet", "now", "today",
        "agree", "agreed", "agreement", "agreements", "promise", "promised", "plan", "planned",
        "passiert", "besprochen", "gesprochen", "geredet", "erzählt", "zuletzt", "letzte", "letzten", "letztes",
        "zusammenfassung", "stand", "nochmal", "schon", "bisher", "jetzt", "heute", "nicht", "kein", "keine", "wenn",
        "dann", "denn", "aber", "vereinbart", "abgemacht", "geeinigt", "einig", "zugesagt", "versprochen", "geplant",
    ].map(ScalarKey.init))

    /// Words that ask what was agreed: decisions and next steps weigh more.
    static let AGREED: Set<ScalarKey> = Set([
        "agree", "agreed", "agreement", "agreements", "promise", "promised", "vereinbart", "abgemacht", "geeinigt",
        "einig", "zugesagt", "versprochen", "commit", "committed",
    ].map(ScalarKey.init))

    /// One passage found: where it is, what it says, and how well it matches.
    struct Passage {
        let meeting: String
        let title: String
        /// The meeting's start as written (ISO), "" when unknown.
        let start: String
        /// line, decision, step, point, summary or my_notes.
        let kind: String
        /// Seconds into the meeting, for lines and the user's notes written during it.
        let time: Double?
        /// Who said the line found (a step's owner).
        let speaker: String
        /// What the page quotes: the line found, or the notes piece.
        let quote: String
        /// What the model reads: the line with the lines around it ("Anna: … / Tom: …"), or the piece.
        let text: String
        var score: Double
        let localOnly: Bool

        var json: JSONValue {
            .object([("meeting", .string(meeting)), ("title", .string(title)), ("start", .string(start)),
                     ("kind", .string(kind)), ("time", time.map { .double(Py.round($0, 2)) } ?? .null),
                     ("speaker", .string(speaker)), ("text", .string(quote))])
        }
    }

    // MARK: - the model

    /// Which model answers and where ("Gemma, on this Mac", "Claude Opus 5.5, cloud"), whether it can (`reason` when
    /// not), and the local model's place, for "Ask on this Mac".
    public static func info(_ app: ServerApp) throws -> JSONValue {
        let local = try localPlace(app)
        let base: [(String, JSONValue)] = [("local_model", .string(local.short))]
        guard app.notesEnabled else {
            return .object([("ready", .bool(false)), ("reason", .string(NextQuestionAPI.OFF)), ("model", .null),
                            ("local", .bool(false))] + base)
        }
        let choice = ModelChoice.choiceFor(feature: FEATURE, config: app.config, stores: app.stores)
        if Py.same(choice, ModelChoice.PENDING) {
            return .object([("ready", .bool(false)), ("reason", .string(PENDING)), ("model", .null), ("local", .bool(false))] + base)
        }
        if Py.same(choice, ModelChoice.LOCAL) {
            return .object([("ready", .bool(true)), ("reason", .null), ("model", .string("\(local.short), on this Mac")),
                            ("local", .bool(true))] + base)
        }
        let settings = try ModelChoice.settingsOf(choice, defaults: ModelChoice.providerDefaults(config: app.config, pid: choice),
                                                  stores: app.stores)
        let model = settings["model"].flatMap { $0.truthy ? Py.str($0) : nil } ?? ModelChoice.provider(choice)?.label ?? choice
        return .object([("ready", .bool(true)), ("reason", .null), ("model", .string("\(NextQuestionAPI.modelName(model)), cloud")),
                        ("local", .bool(false))] + base)
    }

    /// The local model's short name ("Gemma") and what it takes while it runs, in GB.
    static func localPlace(_ app: ServerApp) throws -> (short: String, runningGB: String) {
        let repo = ModelChoice.localModel(config: app.config, stores: app.stores)
        let info = ModelChoice.localModelInfo(repo)
        let label = info?.label ?? String(String.UnicodeScalarView(repo.unicodeScalars.split(separator: "/",
            omittingEmptySubsequences: false).last ?? []))
        return (Py.split(label).first ?? repo, "\(info?.runningGB ?? 10)")
    }

    // MARK: - finding the passages

    /// The words a passage is looked for by: the question's words as the search reads them (its filters and little words
    /// taken out), without the ones that only say how it is asked; each once, matched where a word starts.
    static func keywords(_ q: SearchQuery) throws -> [(word: String, regex: PyRegex)] {
        var seen = Set<ScalarKey>()
        var out: [(String, PyRegex)] = []
        for w in q.words {
            let key = ScalarKey(Py.casefold(w))
            if ASKING.contains(key) || w.unicodeScalars.count < 2 || !seen.insert(key).inserted { continue }
            out.append((w, try PyRegex(#"(?<!\w)"# + PyRegex.escape(w), ignoreCase: true)))
        }
        return out
    }

    /// How much a piece of each kind weighs against a line that matches as well.
    static func weight(_ kind: String, scope: String?, agreed: Bool) -> Double {
        switch kind {
        case "decision": return scope == "decisions" || agreed ? 2.4 : 1.6
        case "step": return scope == "steps" || agreed ? 2.2 : 1.4
        case "summary", "point": return 1.2
        case "my_notes": return 1.3
        default: return 1.0
        }
    }

    static func clip(_ text: String, _ n: Int = MAX_LINE_CHARS) -> String {
        let t = Py.strip(text)
        return t.unicodeScalars.count <= n ? t : String(String.UnicodeScalarView(t.unicodeScalars.prefix(n))) + "…"
    }

    /// A meeting's pieces as they are searched: notes pieces, the user's own notes, and its lines (the lines apart, so a
    /// line found brings its neighbours).
    struct Pieces {
        let f: SearchAPI.Found
        let notes: [(kind: String, text: String, speaker: String, time: Double?)]
        let lines: [SearchAPI.Line]
    }

    static func pieces(_ app: ServerApp, _ f: SearchAPI.Found) throws -> Pieces {
        var notes: [(String, String, String, Double?)] = f.items().map { item in
            let kind = item["kind"]?.stringValue ?? "point"
            let owner = item["owner"]?.stringValue ?? ""
            let text = kind == "point" ? SearchAPI.itemText(item) : (item["text"].map(Py.str) ?? "")
            return (kind, text, owner, nil)
        }
        for p in MyNotes.load(f.paths.folder) {
            let text = Py.strip(p.text)
            if !text.isEmpty { notes.append(("my_notes", text, "", p.at)) }
        }
        return Pieces(f: f, notes: notes.filter { !Py.strip($0.1).isEmpty }, lines: try f.lines(app))
    }

    static func passage(_ f: SearchAPI.Found, kind: String, time: Double?, speaker: String, quote: String, text: String,
                        score: Double) -> Passage {
        let title = f.m["title"].flatMap { $0.truthy ? $0.stringValue : nil } ?? f.paths.folder.lastPathComponent
        return Passage(meeting: f.paths.folder.lastPathComponent, title: title, start: f.m["start"]?.stringValue ?? "",
                       kind: kind, time: time, speaker: speaker, quote: clip(quote), text: text, score: score,
                       localOnly: LocalOnly.isLocalOnly(f.paths.folder))
    }

    /// The lines `range` of a meeting as the model reads them: "Anna: … / Tom: …".
    static func window(_ lines: [SearchAPI.Line], _ range: ClosedRange<Int>) -> String {
        range.map { i in
            let l = lines[i]
            return l.speaker.isEmpty ? clip(l.text) : "\(l.speaker): \(clip(l.text))"
        }.joined(separator: " / ")
    }

    /// The passages that match the question's words, best first: each word weighs more the fewer pieces have it, a
    /// decision or next step more than a line, a meeting whose title has the word a little more. Lines found close
    /// together are one passage.
    static func byWords(_ app: ServerApp, _ found: [SearchAPI.Found], _ q: SearchQuery,
                        _ words: [(word: String, regex: PyRegex)]) throws -> [Passage] {
        if words.isEmpty { return [] }
        let agreed = q.words.contains { AGREED.contains(ScalarKey(Py.casefold($0))) }
        // Which words each matching piece has, and in how many pieces each word is (its rarity).
        var total = 0
        var count = [Int](repeating: 0, count: words.count)
        var matched: [(Pieces, [Int: [Int]], [Int: [Int]], [Int])] = []  // notes i → words, lines i → words, title words
        for f in found {
            let p = try pieces(app, f)
            total += p.notes.count + p.lines.count
            let title = f.m["title"]?.stringValue ?? ""
            let all = ([title] + p.notes.map(\.text) + p.lines.map { "\($0.speaker) \($0.text)" }).joined(separator: "\n")
            let present = words.indices.filter { words[$0].regex.firstMatch(in: all) != nil }
            if present.isEmpty { continue }
            func has(_ text: String) -> [Int] { present.filter { words[$0].regex.firstMatch(in: text) != nil } }
            var notes: [Int: [Int]] = [:], lines: [Int: [Int]] = [:]
            for (i, n) in p.notes.enumerated() {
                let w = has(n.speaker.isEmpty ? n.text : "\(n.speaker) \(n.text)")
                if !w.isEmpty { notes[i] = w; w.forEach { count[$0] += 1 } }
            }
            for (i, l) in p.lines.enumerated() {
                if let said = q.saidBy, !SearchAPI.isPerson(said, l.speaker) { continue }
                let w = has(q.saidBy == nil ? "\(l.speaker) \(l.text)" : l.text)
                if !w.isEmpty { lines[i] = w; w.forEach { count[$0] += 1 } }
            }
            matched.append((p, notes, lines, has(title)))
        }
        let rarity = count.map { log(1 + Double(max(total, 1)) / Double(1 + $0)) }
        func score(_ w: [Int], _ title: [Int]) -> Double {
            w.reduce(0) { $0 + rarity[$1] } + 0.25 * title.reduce(0) { $0 + rarity[$1] }
        }
        var out: [Passage] = []
        for (p, notes, lines, title) in matched {
            for (i, w) in notes.sorted(by: { $0.key < $1.key }) {
                let n = p.notes[i]
                out.append(passage(p.f, kind: n.kind, time: n.time, speaker: n.speaker, quote: n.text, text: clip(n.text, 1200),
                                   score: score(w, title) * weight(n.kind, scope: q.scope, agreed: agreed)))
            }
            // Lines close together are one passage: the best line is the one quoted and played.
            var runs: [(range: ClosedRange<Int>, best: Int, score: Double)] = []
            for (i, w) in lines.sorted(by: { $0.key < $1.key }) {
                let s = score(w, title)
                let range = max(0, i - CONTEXT_LINES)...min(p.lines.count - 1, i + CONTEXT_LINES)
                if let last = runs.last, range.lowerBound <= last.range.upperBound + 1,
                   range.upperBound - last.range.lowerBound < MAX_WINDOW {
                    let better = s > last.score
                    runs[runs.count - 1] = (last.range.lowerBound...range.upperBound, better ? i : last.best,
                                            max(s, last.score) + 0.25 * min(s, last.score))
                } else {
                    runs.append((range, i, s))
                }
            }
            for r in runs {
                let l = p.lines[r.best]
                out.append(passage(p.f, kind: "line", time: l.start, speaker: l.speaker, quote: l.text,
                                   text: window(p.lines, r.range), score: r.score))
            }
        }
        return Py.stableSorted(out) { $0.score > $1.score }
    }

    /// The passages search by meaning finds for the question (when it is on and the meetings are indexed), best first.
    static func byMeaning(_ app: ServerApp, _ found: [SearchAPI.Found], _ q: SearchQuery, searcher: Searcher?) -> [Passage] {
        guard SearchIndex.enabled(stores: app.stores), !q.words.isEmpty, !found.isEmpty else { return [] }
        var byId = PyDict<SearchAPI.Found>()
        for f in found { byId[f.paths.folder.lastPathComponent] = f }
        var who: ((RecordingPaths, String) -> Bool)?
        if let saidBy = q.saidBy {
            who = { paths, label in SearchAPI.isPerson(saidBy, byId[paths.folder.lastPathComponent]?.names[label] ?? label) }
        }
        let hits: PyDict<[JSONValue]>
        do {
            hits = try (searcher ?? app.background.searcher()).search(q.words.joined(separator: " "),
                                                                      in: found.map(\.paths), kinds: nil, speaker: who)
        } catch {
            app.log?.message("ask: search by meaning failed: \(error)", level: "WARNING", logger: "palaver.webapp.api")
            return []
        }
        let glossary = Glossary.current(stores: app.stores)
        var out: [Passage] = []
        for (mid, pieces) in hits {
            guard let f = byId[mid] else { continue }
            for piece in pieces {
                let p = glossary.applyTo(Notes.withNames(piece, f.names))
                let kind = p["kind"]?.stringValue ?? "point"
                let text = p["text"].map(Py.str) ?? ""
                if Py.strip(text).isEmpty { continue }
                let label = p["speaker"]?.stringValue ?? p["owner"]?.stringValue ?? ""
                let speaker = kind == "line" ? f.names[label] ?? label : label
                let time = kind == "line" ? p["start"]?.doubleValue : nil
                out.append(passage(f, kind: kind, time: time, speaker: speaker, quote: text,
                                   text: kind == "line" && !speaker.isEmpty ? "\(speaker): \(clip(text, 1200))" : clip(text, 1200),
                                   score: piece["score"]?.doubleValue ?? 0))
            }
        }
        return Py.stableSorted(out) { $0.score > $1.score }
    }

    /// Without words to look for: the summaries and decisions of the newest meetings that pass the filters.
    static func summaries(_ found: [SearchAPI.Found]) -> [Passage] {
        var out: [Passage] = []
        for (rank, f) in found.prefix(SUMMARY_MEETINGS).enumerated() {
            let items = f.items()
            let score = Double(SUMMARY_MEETINGS - rank)
            for item in items where item["kind"]?.stringValue == "summary" {
                let text = item["text"].map(Py.str) ?? ""
                out.append(passage(f, kind: "summary", time: nil, speaker: "", quote: text, text: clip(text, 1500), score: score))
            }
            for item in items.filter({ $0["kind"]?.stringValue == "decision" }).prefix(3) {
                let text = item["text"].map(Py.str) ?? ""
                out.append(passage(f, kind: "decision", time: nil, speaker: "", quote: text, text: clip(text, 600), score: score - 0.5))
            }
        }
        return out
    }

    /// Two lines apart by less than this are the same moment.
    static let SAME_MOMENT = 20.0

    /// Two ranked lists as one: by turns, the first's best first; a passage already in (a line of the same moment, or
    /// the same notes text) is left out.
    static func interleave(_ a: [Passage], _ b: [Passage]) -> [Passage] {
        var out: [Passage] = []
        func known(_ p: Passage) -> Bool {
            out.contains { o in
                guard o.meeting == p.meeting else { return false }
                if p.kind == "line" && o.kind == "line", let t = p.time, let u = o.time { return abs(t - u) < SAME_MOMENT }
                return Py.same(Py.strip(o.quote), Py.strip(p.quote))
            }
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count { if !known(a[i]) { out.append(a[i]) }; i += 1 }
            if j < b.count { if !known(b[j]) { out.append(b[j]) }; j += 1 }
        }
        return out
    }

    /// The question as the search reads it (with the page's filters written out after it) and every passage found for
    /// it, best first.
    static func find(_ app: ServerApp, question: String, filters: [String], today: PyDate? = nil,
                     searcher: Searcher? = nil) throws -> (SearchQuery, [Passage]) {
        let meetings = try MeetingsAPI.listMeetings(app: app)
        let text = ([question] + filters).joined(separator: " ")
        let q = SearchParser.parse(text, vocab: try SearchAPI.vocabulary(app, meetings, userName: app.userName), today: today)
        let found = try SearchAPI.filtered(app, q, userName: app.userName)
        let words = try keywords(q)
        if words.isEmpty { return (q, summaries(found)) }
        let ranked = interleave(try byWords(app, found, q, words), byMeaning(app, found, q, searcher: searcher))
        // Words that are nowhere, with filters that narrow the meetings ("Anna last week, anything new?"): their
        // summaries.
        if ranked.isEmpty && q.filters.contains(where: { $0.kind != "in" && $0.kind != "said" }) { return (q, summaries(found)) }
        return (q, ranked)
    }

    /// The passages the model gets, best first: `MAX_PASSAGES` at most, `PER_MEETING` of a meeting, `MAX_CHARS` of
    /// text; none of a meeting kept on this Mac unless `local` allows them.
    static func pick(_ ranked: [Passage], local: Bool) -> [Passage] {
        var out: [Passage] = []
        var per: [String: Int] = [:]
        var chars = 0
        for p in ranked {
            if out.count >= MAX_PASSAGES { break }
            if p.localOnly && !local { continue }
            if per[p.meeting, default: 0] >= PER_MEETING { continue }
            let n = p.text.unicodeScalars.count
            if chars + n > MAX_CHARS { continue }
            out.append(p)
            per[p.meeting, default: 0] += 1
            chars += n
        }
        return out
    }

    /// In the prompt: the meetings in time order, and in each its notes first, then its lines in order.
    static func ordered(_ passages: [Passage]) -> [Passage] {
        let first = Dictionary(passages.map { ($0.meeting, $0.start) }, uniquingKeysWith: { a, _ in a })
        return passages.sorted { a, b in
            if a.meeting != b.meeting {
                let (x, y) = (first[a.meeting] ?? "", first[b.meeting] ?? "")
                return x != y ? x < y : a.meeting < b.meeting
            }
            let (x, y) = (a.time ?? -1, b.time ?? -1)
            return x != y ? x < y : a.score > b.score
        }
    }

    // MARK: - the ask

    /// One question, on the user's click: `{"question", "person", "project", "since", "include_local", "confirmed"}`.
    /// The answer with its sources; `{"confirm": warning}` when the local model would run during a call and the click
    /// was not confirmed yet; no model at all when nothing matches.
    public static func ask(_ app: ServerApp, body: JSONValue, today: PyDate? = nil, searcher: Searcher? = nil) throws -> JSONValue {
        let question = String(String.UnicodeScalarView(Py.strip((try PyBody.get(body, "question"))?.stringValue ?? "")
            .unicodeScalars.prefix(MAX_QUESTION_CHARS)))
        if question.isEmpty { throw Refused(NO_QUESTION) }
        func flag(_ key: String) throws -> Bool { if case .bool(true)? = try PyBody.get(body, key) { return true }; return false }
        let includeLocal = try flag("include_local"), confirmed = try flag("confirmed")
        // The page's filters, written out as the search box takes them.
        var filters: [String] = []
        for (key, filter) in [("person", "person"), ("project", "project"), ("since", "since")] {
            if let v = (try PyBody.get(body, key))?.stringValue.map(Py.strip), !v.isEmpty {
                filters.append("\(filter):\"\(v.replacingOccurrences(of: "\"", with: ""))\"")
            }
        }

        let info = try info(app)
        let reason = info["reason"].map(Py.str) ?? ""
        guard app.notesEnabled else { throw Unavailable(reason) }
        guard info["ready"]?.truthy ?? false else { throw Refused(reason) }
        let cloud = !(info["local"]?.truthy ?? false)

        let (q, ranked) = try find(app, question: question, filters: filters, today: today, searcher: searcher)
        let passages = ordered(pick(ranked, local: !cloud || includeLocal))
        let leftOut = cloud && !includeLocal
            ? Set(pick(ranked, local: true).filter(\.localOnly).map(\.meeting)).count : 0
        var answer: [(String, JSONValue)] = [
            ("question", .string(question)), ("asked_at", .string(Py.isoNow(timespec: "seconds"))),
            ("understood", .array(q.chips())), ("left_out", .int(leftOut)), ("passages", .int(passages.count)),
            ("meetings", .int(Set(passages.map(\.meeting)).count)),
        ]
        if passages.isEmpty {  // before a model starts
            return .object(answer + [("answer", .null), ("sources", .array([])), ("engine", .null)])
        }

        // The local model: this ask's when the notes' model is local, or when a meeting kept on this Mac is in it.
        let local = !cloud || passages.contains(where: \.localOnly)
        let place = try localPlace(app)
        let recording = try MeetingsAPI.listMeetings(app: app).contains { app.meetingStatus(SearchAPI.paths(app, $0)) == "recording" }
        if local {
            let need = ModelChoice.notesMemoryGB(ModelChoice.localModel(config: app.config, stores: app.stores))
            if let problem = NextQuestionAPI.memoryProblem(local: true, freeGB: app.freeMemoryGB(), needGB: need,
                                                            recording: recording) { throw Refused(problem) }
            if recording && !confirmed {
                return .object(answer + [("confirm", .string(
                    "Runs \(place.short) on this Mac during the call (about \(place.runningGB) GB, may slow the call)"))])
            }
        }
        let inputs = JSONValue.object([
            ("question", .string(question)), ("user", .string(app.userName)), ("today", .string((today ?? PyDate.today()).iso)),
            ("passages", .array(passages.enumerated().map { i, p in
                .object([("n", .int(i + 1)), ("meeting", .string(p.meeting)), ("title", .string(p.title)),
                         ("date", .string(String(String.UnicodeScalarView(p.start.unicodeScalars.prefix(10))))),
                         ("time", p.time.map { .double(Py.round($0, 2)) } ?? .null), ("speaker", .string(p.speaker)),
                         ("kind", .string(p.kind)), ("text", .string(p.text))])
            })),
        ])
        // The meeting the app watches the helper's memory for: one kept on this Mac when there is one (its budget is
        // the local model's), else the first.
        let watching = app.outputDir.appendingPathComponent(
            (passages.first(where: \.localOnly) ?? passages[0]).meeting, isDirectory: true)
        if local {
            guard app.notesLock.try() else { throw ModelBusy() }
        }
        defer { if local { app.notesLock.unlock() } }
        let out = try app.askMeetings.ask(inputs: inputs, watching: watching)
        let cited: [JSONValue] = (out["sources"]?.arrayValue ?? []).compactMap { v in
            guard case .int(let n) = v, n >= 1, n <= passages.count else { return nil }
            var s = PyDict<JSONValue>(passages[n - 1].json) ?? PyDict()
            s["n"] = .int(n)
            return s.json
        }
        answer += [("answer", .string(out["answer"].map(Py.str) ?? "")), ("sources", .array(cited)),
                   ("engine", out["engine"] ?? .null)]
        return .object(answer)
    }
}

extension Router {
    /// Ask your meetings (#42): which model answers, and one question.
    static func addAskMeetingsRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/ask") { _, _ in .json(try AskMeetingsAPI.info(app)) }
        r.post("/api/ask") { req, _ in .json(try AskMeetingsAPI.ask(app, body: req.json)) }
    }
}
