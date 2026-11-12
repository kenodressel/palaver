// The Glossary page and its changes (api.py:2108-2268, :3440-3456; server.py `_glossary_post`): the terms, the
// suggestions (computed again only when a transcript, the calendar, the speakers, the projects or the glossary change),
// and each change with what it did to the meetings — how many words are shown differently, in which meetings — their
// transcript.md rendered again. Every change but accepting a suggestion can be undone.
import Foundation
import PalaverCore
import PalaverDomain

/// api.py `_SUGGESTIONS`: the suggestions of one recordings folder while the files they are made of are unchanged.
public final class GlossarySuggestions: @unchecked Sendable {
    private let lock = NSLock()
    /// Held while the suggestions are made: a request that comes meanwhile (the warm-up after a start, Review and
    /// Needs you at once) waits for them instead of making them a second time.
    private let making = NSLock()
    private var kept: (signature: [Int], value: [JSONValue])?
    private var made = 0

    /// Each meeting's share, kept per meeting while its files stay as they were (#29): when a meeting, the glossary or
    /// the projects change, only what changed is read again, not every transcript. `shares`: its lines without fillers
    /// (the slow part), its unsure words, its names spelled right; `counted`: those lines with the glossary applied,
    /// and their words.
    let shares = SignatureCache<MeetingShare>()
    private var counted: [ScalarKey: (signature: [Int], lines: [(Double, String)], words: GlossarySuggest.MeetingWords)] = [:]

    struct MeetingShare {
        let lines: [(Double, String)]?
        let unsure: PyDict<Int>?
        let known: [String]
    }

    public init() {}

    /// How many times the suggestions were computed.
    public var computed: Int { lock.withLock { made } }
    /// How many times a meeting's transcript was read for them (once per meeting, again when its files change).
    public var meetingsRead: Int { shares.misses }

    func get(_ signature: [Int]?, make: () throws -> [JSONValue]) rethrows -> [JSONValue] {
        func current() -> [JSONValue]? {
            guard let signature, let kept = lock.withLock({ kept }), kept.signature == signature else { return nil }
            return kept.value
        }
        if let value = current() { return value }
        return try making.withLock {
            if let value = current() { return value }  // made while this request waited
            let value = try make()
            lock.withLock {
                made += 1
                kept = signature.map { ($0, value) }
            }
            return value
        }
    }

    /// Meeting `key`'s readable lines counted, kept while `signature` (its share's files and the glossary) stays as it
    /// was. When it changed but the lines read as before (a glossary change elsewhere), the words counted before.
    func words(_ key: String, signature: [Int]?, lines: () -> [(Double, String)]) -> GlossarySuggest.MeetingWords {
        let k = ScalarKey(key)
        let before = lock.withLock { counted[k] }
        if let signature, let before, before.signature == signature { return before.words }
        let shown = lines()
        let same = before.map { $0.lines.count == shown.count && zip($0.lines, shown).allSatisfy { $0.0 == $1.0 && Py.same($0.1, $1.1) } }
        let words = same == true ? before!.words : GlossarySuggest.MeetingWords(shown)
        lock.withLock { counted[k] = signature.map { ($0, shown, words) } }
        return words
    }
}

public enum GlossaryAPI {
    public static let GLOSSARY_SUGGESTIONS = 20
    public static let REVIEW_SUGGESTIONS = 3

    /// The recording folders' names in `outputDir` (`iterdir` + `is_recording_folder_name`, files too), by code points.
    static func recordingNames(_ outputDir: URL) -> [String] {
        guard MeetingsAPI.isDirectory(outputDir) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
        return Py.stableSorted(names.filter(RecordingPaths.isRecordingFolderName), by: Py.less)
    }

    /// `_suggestions`: every glossary suggestion, computed again when a transcript, the calendar, the speakers, the
    /// projects or the glossary change.
    static func suggestions(_ app: ServerApp, userName: String) throws -> [JSONValue] {
        var files = [app.stores.glossary, app.stores.projects]
        for name in recordingNames(app.outputDir) {
            files += shareFiles(RecordingPaths(app.outputDir.appendingPathComponent(name, isDirectory: true)))
        }
        return try app.glossarySuggestions.get(SignatureCache<Int>.signature(files)) {
            // GlossarySuggest.corpus, knownSpellings and unsureWords, from each meeting's share.
            let glossarySignature = SignatureCache<Int>.signature([app.stores.glossary])  // before it is read
            let cache = app.glossarySuggestions, glossary = Glossary.current(stores: app.stores)
            var meetings: [(String, GlossarySuggest.MeetingWords)] = [], known: [[String]] = [], unsure = PyDict<Int>()
            for name in recordingNames(app.outputDir) {
                let paths = RecordingPaths(app.outputDir.appendingPathComponent(name, isDirectory: true))
                let read = SignatureCache<Int>.signature(shareFiles(paths))
                let share = try cache.shares.get(key: paths.folder.path, signature: read) {
                    GlossarySuggestions.MeetingShare(lines: GlossarySuggest.cleanedLines(paths), unsure: GlossarySuggest.unsureWords(paths),
                                                     known: try GlossarySuggest.knownSpellings(paths))
                }
                known.append(share.known)
                for (word, n) in share.unsure ?? PyDict() { unsure[word] = (unsure[word] ?? 0) + n }
                guard let lines = share.lines else { continue }
                let made = read.flatMap { r in glossarySignature.map { r + $0 } }  // the share and the glossary
                meetings.append((name, cache.words(paths.folder.path, signature: made) {
                    GlossarySuggest.readableLines(lines, glossary: glossary)
                }))
            }
            return GlossarySuggest.suggest(meetings: meetings,
                                           known: try GlossarySuggest.knownSpellings(userName: userName, stores: app.stores, meetings: known),
                                           glossary: Glossary(path: app.stores.glossary), unsure: unsure)
        }
    }

    /// The files of a meeting its share of the suggestions is made of: the transcript, the calendar event, the speakers.
    static func shareFiles(_ paths: RecordingPaths) -> [URL] {
        [paths.transcriptJson, paths.calendar, paths.speakers, paths.speakersAuto, paths.speakersMerged, paths.speakersIgnored,
         paths.speakersInferred, paths.speakersRejected, paths.speakersShared, paths.speakersUnknown, paths.speakersLines,
         paths.systemTurns]
    }

    /// `_with_titles`: each example with its meeting's title.
    static func withTitles(_ suggestions: [JSONValue], _ titles: PyDict<JSONValue>) -> [JSONValue] {
        suggestions.map { s in
            var out = PyDict<JSONValue>(s) ?? PyDict()
            out["examples"] = .array((s["examples"]?.arrayValue ?? []).map { e in
                var example = PyDict<JSONValue>(e) ?? PyDict()
                example["title"] = e["meeting"]?.stringValue.flatMap { titles[$0] } ?? .null
                return example.json
            })
            return out.json
        }
    }

    /// The titles of the listed meetings by id (`{m["id"]: m["title"] for m in ...}`).
    static func titles(_ meetings: [JSONValue]) -> PyDict<JSONValue> {
        var out = PyDict<JSONValue>()
        for m in meetings { if let id = m["id"]?.stringValue { out[id] = m["title"] ?? .null } }
        return out
    }

    /// The terms, each with its id first, by term casefolded.
    static func terms(_ g: Glossary) -> [JSONValue] {
        let rows: [JSONValue] = g.terms.map { tid, t in
            var row = PyDict<JSONValue>([("id", .string(tid))])
            for (k, v) in PyDict<JSONValue>(t) ?? PyDict() { row[k] = v }
            return row.json
        }
        return Py.stableSorted(rows) { Py.less(Py.casefold($0["term"]?.stringValue ?? ""), Py.casefold($1["term"]?.stringValue ?? "")) }
    }

    /// `glossary_page`: the terms and the first suggestions.
    public static func page(_ app: ServerApp, userName: String) throws -> JSONValue {
        let titles = titles(try MeetingsAPI.listMeetings(app: app))
        return .object([
            ("terms", .array(terms(Glossary(path: app.stores.glossary)))),
            ("suggestions", .array(withTitles(Array(try suggestions(app, userName: userName).prefix(GLOSSARY_SUGGESTIONS)), titles))),
        ])
    }

    // MARK: - what a change did

    /// `_raw_texts`: each meeting's lines as heard, cleaned (fillers out), before the glossary.
    static func rawTexts(_ app: ServerApp) throws -> PyDict<[String]> {
        var out = PyDict<[String]>()
        for name in recordingNames(app.outputDir) {
            let paths = RecordingPaths(app.outputDir.appendingPathComponent(name, isDirectory: true))
            out[name] = try MeetingsAPI.utterances(paths).map { Readable.cleanText($0.text) }
        }
        return out
    }

    /// `_respelled`: how many words of `text` are shown differently after a glossary change.
    static func respelled(_ before: Glossary, _ after: Glossary, _ text: String) -> Int {
        let a = Py.split(before.apply(text)), b = Py.split(after.apply(text))
        if a.count == b.count && zip(a, b).allSatisfy({ Py.same($0, $1) }) { return 0 }
        return SequenceMatcher(a, b).opcodes().filter { $0.tag != "equal" }.reduce(0) { $0 + max($1.i2 - $1.i1, $1.j2 - $1.j1) }
    }

    /// The store's ValueError ("a term is needed", "… is already in the glossary") is the request's: 400.
    static func python<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as GlossaryValueError { throw BadRequest(e.description) }
    }

    /// `change_glossary`: `change(glossary)` saved (under `app.glossaryLock`), and what it did to the meetings: how many
    /// words are shown differently, in which meetings; their transcript.md rendered again.
    static func change(_ app: ServerApp, _ change: (Glossary) throws -> Void) throws -> JSONValue {
        let (before, after): (Glossary, Glossary) = try app.glossaryLock.withLock {
            let g = Glossary(path: app.stores.glossary)
            let before = Glossary(path: g.path)
            try python { try change(g) }
            try g.save()
            return (before, g)
        }
        let texts = try rawTexts(app)
        var words = PyDict<Int>(), inNotes = PyDict<Int>()
        for (m, lines) in texts {
            words[m] = lines.reduce(0) { $0 + respelled(before, after, $1) }
            if let n = Notes.load(RecordingPaths(app.outputDir.appendingPathComponent(m, isDirectory: true))), n.truthy {
                inNotes[m] = respelled(before, after, PythonJSON.dumps(n, ensureAscii: false))
            }
        }
        let changed = Py.stableSorted(texts.keys.filter { words[$0]! != 0 || (inNotes[$0] ?? 0) != 0 }, by: Py.less)
        try ChangesAPI.rerender(app, changed)
        return .object([("meetings", .strings(changed)), ("replacements", .int(changed.reduce(0) { $0 + words[$1]! })),
                        ("in_notes", .int(changed.reduce(0) { $0 + (inNotes[$1] ?? 0) }))])
    }

    /// The term `tid` with its id first (`{"id": tid, **terms[tid]}`).
    static func term(_ app: ServerApp, _ tid: String?) throws -> JSONValue {
        let g = Glossary(path: app.stores.glossary)
        guard let tid, let t = g.terms[tid] else { throw GlossaryLookupError(id: tid ?? "None") }
        var row = PyDict<JSONValue>([("id", .string(tid))])
        for (k, v) in PyDict<JSONValue>(t) ?? PyDict() { row[k] = v }
        return row.json
    }

    // MARK: - the changes

    /// `accept_suggestion`: `term` is the right spelling, `variants` the ones to respell.
    public static func accept(_ app: ServerApp, term: String, variants: [String], note: String = "") throws -> JSONValue {
        if Py.strip(term).isEmpty { throw BadRequest("a term is needed") }
        return try change(app) { try $0.add(term: term, variants: variants, note: note) }
    }

    /// `respell`: words as a meeting shows them, and how they are really spelled. `heard` becomes a variant of `term`;
    /// when it is a term already (a meeting shows terms, not their variants), that term is respelled, or joins `term`
    /// with all its variants.
    public static func respell(_ app: ServerApp, heard: String, term: String) throws -> JSONValue {
        let heard = Py.strip(heard), term = Py.strip(term)
        if heard.isEmpty || term.isEmpty { throw BadRequest("the words and their spelling are needed") }
        let done = try ChangesAPI.undoable(app, label: "respell", stores: ChangesAPI.storePaths(app, "glossary")) { _ in
            try change(app) { g in
                let tid = g.find(heard), other = g.find(term)
                guard let tid else {
                    try g.add(term: term, variants: [heard])
                    return
                }
                let variants = g.terms[tid]?["variants"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if let other, other != tid { try g.delete(tid) } else { try g.update(tid, term: term) }
                try g.add(term: term, variants: [heard] + variants)
            }
        }
        let tid = Glossary(path: app.stores.glossary).find(term)
        return .object([("changed", done.removing("undo")), ("term", try self.term(app, tid)), ("undo", done["undo"] ?? .null)])
    }

    /// `unrespell`: “dem” is not “Demo” — the glossary stops respelling `heard`, from a meeting where it shows. Only that
    /// mapping goes; the term and its other spellings stay.
    public static func unrespell(_ app: ServerApp, heard: String) throws -> JSONValue {
        let heard = Py.strip(heard)
        guard let tid = Glossary(path: app.stores.glossary).owner(heard) else {
            throw Refused("“\(heard)” is not respelled by the glossary.")
        }
        let done = try ChangesAPI.undoable(app, label: "not respelled", stores: ChangesAPI.storePaths(app, "glossary")) { _ in
            try change(app) { try $0.removeVariant(tid, heard) }
        }
        return .object([("changed", done.removing("undo")), ("term", try term(app, tid)), ("undo", done["undo"] ?? .null)])
    }

    /// `reject_suggestion`: "Not this" — the suggestion (or one spelling of it: each spelling of a known name has its own
    /// key) is not made again. The undo token.
    public static func reject(_ app: ServerApp, keys: [String]) throws -> String {
        try ChangesAPI.undoToken(app, label: "not this", stores: ChangesAPI.storePaths(app, "glossary")) { _ in
            try app.glossaryLock.withLock {
                let g = Glossary(path: app.stores.glossary)
                keys.forEach(g.reject)
                try g.save()
            }
        }
    }

    /// `update_term`: a term renamed, its note, a variant removed or added, or the term deleted; what changed, with
    /// `"undo"`.
    public static func updateTerm(_ app: ServerApp, tid: String, term: String? = nil, note: String? = nil,
                                  removeVariant: String? = nil, addVariants: [String] = [], delete: Bool = false) throws -> JSONValue {
        guard Glossary(path: app.stores.glossary).terms[tid] != nil else { throw NotFound(tid) }
        return try ChangesAPI.undoable(app, label: delete ? "delete term" : "term", stores: ChangesAPI.storePaths(app, "glossary")) { _ in
            try change(app) { g in
                if delete { return try g.delete(tid) }
                try g.update(tid, term: term, note: note)
                if let removeVariant, !removeVariant.isEmpty { try g.removeVariant(tid, removeVariant) }
                if !addVariants.isEmpty { try g.add(term: g.terms[tid]?["term"]?.stringValue ?? "", variants: addVariants) }
            }
        }
    }

    /// `seed_glossary` (`POST /api/setup/glossary`, #55): the calendar's names the user ticked, added, undoable.
    public static func seed(_ app: ServerApp, _ body: JSONValue) throws -> JSONValue {
        let given = try PyBody.get(body, "terms").flatMap { $0.truthy ? $0 : nil } ?? .array([])
        let terms = try MeetingsAPI.iterate(given).compactMap { $0.stringValue }.map(Py.strip).filter { !$0.isEmpty }
        if terms.isEmpty { return .object([("added", .int(0)), ("undo", .null)]) }
        try FileManager.default.createDirectory(at: app.outputDir, withIntermediateDirectories: true)
        let before = Set(Glossary(path: app.stores.glossary).terms.keys.map(ScalarKey.init))
        let token = try ChangesAPI.undoToken(app, label: "glossary from the calendar", stores: ChangesAPI.storePaths(app, "glossary")) { _ in
            _ = try change(app) { g in for t in terms { try g.add(term: t) } }
        }
        let after = Set(Glossary(path: app.stores.glossary).terms.keys.map(ScalarKey.init))
        return .object([("added", .int(after.subtracting(before).count)), ("undo", .string(token))])
    }
}

extension JSONValue {
    /// The object without `key`.
    func removing(_ key: String) -> JSONValue {
        guard case .object(let fields) = self else { return self }
        return .object(fields.filter { !Py.same($0.0, key) })
    }
}

extension Router {
    /// The Glossary page (server.py's GET branch and `_glossary_post`): each change but a respelling from a meeting
    /// answers what changed and the page, with `"undo"` when it can be undone.
    static func addGlossaryRoutes(_ r: Router, app: ServerApp) {
        func strings(_ body: JSONValue, _ key: String) throws -> [String] {
            try MeetingsAPI.iterate(try PyBody.get(body, key) ?? .array([])).map(Py.str)
        }
        func answer(_ changed: JSONValue, token: String?) throws -> Response {
            var out = PyDict<JSONValue>([("changed", changed)])
            for (k, v) in PyDict<JSONValue>(try GlossaryAPI.page(app, userName: app.userName)) ?? PyDict() { out[k] = v }
            if let token, !token.isEmpty { out["undo"] = .string(token) }
            return .json(out.json)
        }

        r.get("/api/glossary") { _, _ in .json(try GlossaryAPI.page(app, userName: app.userName)) }
        // From a meeting: no glossary page needed.
        r.post("/api/glossary/respell") { req, _ in
            .json(try GlossaryAPI.respell(app, heard: Py.str(try PyBody.required(req.json, "heard")),
                                          term: Py.str(try PyBody.required(req.json, "term"))))
        }
        r.post("/api/glossary/unrespell") { req, _ in
            .json(try GlossaryAPI.unrespell(app, heard: Py.str(try PyBody.required(req.json, "heard"))))
        }
        r.post("/api/glossary/accept") { req, _ in
            let body = req.json
            let changed = try GlossaryAPI.accept(app, term: Py.str(try PyBody.required(body, "term")),
                                                 variants: try strings(body, "variants"),
                                                 note: Py.str(try PyBody.get(body, "note") ?? .string("")))
            return try answer(changed, token: nil)
        }
        r.post("/api/glossary/reject") { req, _ in
            let body = req.json
            let keys: [String]
            if case .array(let given)? = try PyBody.get(body, "keys") {
                keys = given.map(Py.str)
            } else {
                keys = [Py.str(try PyBody.required(body, "key"))]
            }
            return try answer(.null, token: try GlossaryAPI.reject(app, keys: keys))
        }
        r.post("/api/glossary/([0-9a-f]+)") { req, m in
            let body = req.json
            func text(_ key: String) throws -> String? {
                guard let v = try PyBody.get(body, key), v != .null else { return nil }
                return Py.str(v)
            }
            let changed = try GlossaryAPI.updateTerm(app, tid: m.group(1)!, term: try text("term"), note: try text("note"),
                                                     removeVariant: try text("remove_variant"),
                                                     addVariants: try strings(body, "add_variants"),
                                                     delete: try PyBody.get(body, "delete")?.truthy ?? false)
            return try answer(changed.removing("undo"), token: changed["undo"]?.stringValue)
        }
        r.post("/api/setup/glossary") { req, _ in .json(try GlossaryAPI.seed(app, req.json)) }
    }
}
