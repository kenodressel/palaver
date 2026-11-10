// What waits on the user (api.py:2269-2524): the review queue (finished meetings not reviewed yet, with what is open),
// the open questions (#48: which event, every unsure link), and "Needs you" (phase 2 of the UI spec: per meeting, which
// event, a cut looked up in the background, voices without a name, unsure names and projects, the review). Made from
// the stored files, cached per meeting by their times; a reviewed meeting shows only what appeared after its review.
import Foundation
import PalaverCore
import PalaverDomain

public enum ReviewAPI {
    /// `_NEED_ORDER`: the order of a meeting's items, as its page shows them; "review" last.
    public static let NEED_ORDER = ["which_event", "event", "no_event", "cut", "unnamed", "speaker", "project", "review"]

    // MARK: - the review queue

    /// `_open_items`: what is still open in listed meeting `m`.
    static func openItems(_ m: JSONValue, _ suggestions: [JSONValue]) -> PyDict<JSONValue> {
        let projects = m["projects"]?.arrayValue ?? []
        let unsure = projects.contains { $0["by"]?.stringValue.map { !Py.same($0, "you") } ?? true }
        let id = m["id"]?.stringValue ?? ""
        let glossary = suggestions.filter { s in (s["meetings"]?.arrayValue ?? []).contains { $0.stringValue.map { Py.same($0, id) } ?? false } }
        let notes = !(m["has_notes"]?.truthy ?? false) ? "missing" : (m["notes_stale"]?.truthy ?? false) ? "stale" : "ok"
        return PyDict([
            ("unnamed", m["unnamed"] ?? .null),
            ("projects", .string(projects.isEmpty ? "none" : unsure ? "unsure" : "ok")),
            ("glossary", .array(Array(glossary.prefix(GlossaryAPI.REVIEW_SUGGESTIONS)))),
            ("notes", .string(notes)),
        ])
    }

    /// `review_queue`: finished meetings not reviewed yet, newest first, with what is open.
    public static func queue(_ app: ServerApp, userName: String) throws -> [JSONValue] {
        let meetings = try MeetingsAPI.listMeetings(app: app).filter {
            $0["status"]?.stringValue == "ready" && !MeetingsAPI.exists(SearchAPI.paths(app, $0).review)
        }
        let suggestions = meetings.isEmpty ? [] : try GlossaryAPI.suggestions(app, userName: userName)
        let titles = GlossaryAPI.titles(meetings)
        return meetings.map { m in
            var open = openItems(m, suggestions)
            open["glossary"] = .array(GlossaryAPI.withTitles(open["glossary"]?.arrayValue ?? [], titles))
            var entry = PyDict<JSONValue>(m) ?? PyDict()
            entry["open"] = open.json
            return entry.json
        }
    }

    // MARK: - the open questions

    /// `_lane_links`: how each speaker got its name, from the stored files alone (no transcript): what the questions
    /// need of the lanes.
    static func laneLinks(_ paths: RecordingPaths) throws -> [JSONValue] {
        let manual = try Speakers.loadSpeakerNames(paths), recognized = try Speakers.loadRecognizedNames(paths)
        let rejected = Speakers.loadRejectedNames(paths)
        var inferred = PyDict<JSONValue>()
        for (label, i) in Inference.load(paths) where i.isObject {
            let no = Set((rejected[label] ?? []).map { ScalarKey(Py.casefold($0)) })
            if !no.contains(ScalarKey(Py.casefold(i["name"]?.stringValue ?? ""))) { inferred[label] = i }
        }
        let skip = Set(Speakers.loadMerges(paths).keys.map(ScalarKey.init)).union(Speakers.loadIgnored(paths).map(ScalarKey.init))
            .union(SharedMic.sharedLabels(paths))
        let labels = SearchAPI.unique(manual.keys + recognized.keys + inferred.keys)
        var out: [JSONValue] = []
        for label in Py.stableSorted(labels, by: Py.less) where !skip.contains(ScalarKey(label)) {
            let auto = recognized[label]
            let guess = manual[label] == nil && auto == nil ? inferred[label] : nil
            let typed = manual[label].map { !Py.same($0, label) } ?? false
            let namedBy = typed ? "you" : auto != nil && manual[label] == nil ? "voice" : guess != nil ? "inferred" : nil
            let name = namedBy == "you" ? manual[label] : namedBy == "voice" ? auto?.0 : guess?["name"]?.stringValue
            let link = try MeetingsAPI.speakerLink(name, namedBy, auto, guess)
            if link.truthy { out.append(.object([("label", .string(label)), ("link", link)])) }
        }
        return out
    }

    /// `{**m, **made}`.
    static func merged(_ m: JSONValue, _ made: JSONValue) -> JSONValue {
        var out = PyDict<JSONValue>(m) ?? PyDict()
        for (k, v) in PyDict<JSONValue>(made) ?? PyDict() { out[k] = v }
        return out.json
    }

    /// `open_questions`: what Palaver is unsure of and asks the user (#48), newest meeting first: which event, when
    /// several overlapped a recording, and every unsure link (event, speaker, project).
    public static func questions(_ app: ServerApp) throws -> [JSONValue] {
        var out: [JSONValue] = []
        for m in try MeetingsAPI.listMeetings(app: app) where m["status"]?.stringValue == "ready" {
            let paths = SearchAPI.paths(app, m)
            let made = try app.reviewCaches.questions.get(key: paths.folder.path, files: MeetingsAPI.signatureFiles(paths, app)) {
                JSONValue.object([("event_question", MeetingsAPI.eventQuestion(paths)),
                                  ("calendar", CalendarEvents.loadLink(paths).map { .object([("link", $0.toDict())]) } ?? .null),
                                  ("speakers", .array(try laneLinks(paths)))])
            }
            out += try Attribution.questions(merged(m, made))
        }
        return out
    }

    // MARK: - Needs you

    /// `_unnamed_lanes`: the voices worth a name that have none, most talk first: their label, a clip to hear, and the
    /// names the notes found for them (backed by the transcript). "Don't Know" voices are not asked.
    static func unnamedLanes(_ app: ServerApp, _ paths: RecordingPaths) throws -> [JSONValue] {
        let turns = try MeetingsAPI.turns(paths)
        let talk = Speakers.talkSeconds(turns)
        let names = try Speakers.namesInEffect(paths)
        let skip = Set(Speakers.loadIgnored(paths).map(ScalarKey.init)).union(SharedMic.sharedLabels(paths))
            .union(Speakers.loadUnknown(paths).map(ScalarKey.init))
        let lanes = Py.stableSorted(talk.keys.filter {
            talk[$0]! >= Voices.MIN_TALK_SECONDS && !skip.contains(ScalarKey($0)) && names[$0] == nil
        }) { talk[$0]! > talk[$1]! }
        if lanes.isEmpty { return [] }
        let notes = Notes.load(paths).flatMap { $0.truthy ? $0 : nil } ?? .object([])
        guard notes.isObject else { throw PageError("'\(PyBody.typeName(notes))' object has no attribute 'get'") }
        let guesses = Notes.backedNameGuesses(try MeetingsAPI.iterate(notes["speaker_names"] ?? .array([])),
                                              try Speakers.withoutIgnored(paths, try MeetingsAPI.utterances(paths)),
                                              glossary: Glossary.current(stores: app.stores))
        return lanes.map { label in
            var longest: SpeakerTurn?
            for t in turns where Py.same(t.speaker, label) {
                if longest == nil || t.end - t.start > longest!.end - longest!.start { longest = t }
            }
            let clip: JSONValue = longest.map {
                .object([("start", .double($0.start)), ("end", .double(min($0.end, $0.start + MeetingsAPI.CLIP_SECONDS)))])
            } ?? .null
            let said = guesses.filter { $0["label"]?.stringValue.map { Py.same($0, label) } ?? false }.compactMap { $0["name"]?.stringValue }
            return .object([("label", .string(label)), ("display", .string(MeetingsAPI.labelDisplay(label))),
                            ("talk_seconds", .double(Py.round(talk[label]!, 1))), ("clip", clip),
                            ("guesses", .strings(SearchAPI.unique(said)))])
        }
    }

    /// `_need_id`: what an item is about, the same while it stays open — what a review remembers as seen
    /// ("speaker|SPEAKER_02|Carla": a new guess is another item).
    static func needId(_ item: PyDict<JSONValue>) -> String {
        func s(_ key: String) -> String { item[key].map { $0.stringValue ?? Py.str($0) } ?? "" }
        switch s("kind") {
        case "unnamed": return "unnamed|\(s("label"))"
        case "speaker": return "speaker|\(s("label"))|\(s("name"))"
        case "project": return "project|\(s("project"))"
        case "event": return "event|\(s("title"))"
        case let kind: return kind
        }
    }

    /// `link.get(key) or ""`.
    private static func orEmpty(_ v: JSONValue?) -> JSONValue { v.flatMap { $0.truthy ? $0 : nil } ?? .string("") }

    /// `_need_items`: a meeting's open items, in the order of its page, each with its id.
    static func needItems(_ m: JSONValue, _ made: JSONValue, cut: JSONValue?, calendarOn: Bool) throws -> [JSONValue] {
        var items: [PyDict<JSONValue>] = []
        for q in try Attribution.questions(merged(m, made)) {
            let link = q["link"].flatMap { $0.truthy ? $0 : nil } ?? .object([])
            let kind = q["kind"]?.stringValue
            if kind == "event", let choices = q["choices"], choices.truthy {
                items.append(PyDict([("kind", .string("which_event")), ("reason", q["reason"] ?? .null), ("choices", choices)]))
            } else if kind == "event" {
                items.append(PyDict([("kind", .string("event")), ("title", try MeetingsAPI.key(link, "target")),
                                     ("why", orEmpty(link["reason"]))]))
            } else if kind == "project" {
                items.append(PyDict([("kind", .string("project")), ("project", try MeetingsAPI.key(q, "project")),
                                     ("name", try MeetingsAPI.key(link, "target")), ("why", orEmpty(link["reason"]))]))
            }
        }
        // A name Palaver guessed: inferred ones always (the page asks Yes or No), by voice when unsure (#48).
        for lane in made["speakers"]?.arrayValue ?? [] {
            guard let link = lane["link"], let label = lane["label"]?.stringValue else { continue }
            if link["source"]?.stringValue == "inferred" || (link["unsure"]?.truthy ?? false) {
                items.append(PyDict([("kind", .string("speaker")), ("label", .string(label)),
                                     ("display", .string(MeetingsAPI.labelDisplay(label))), ("name", link["target"] ?? .null),
                                     ("why", orEmpty(link["reason"])), ("confidence", link["confidence"] ?? .null)]))
            }
        }
        if calendarOn && !(made["has_event"]?.truthy ?? false) && !(made["event_question"]?.truthy ?? false)
            && !(made["dismissed"]?.truthy ?? false) {
            items.append(PyDict([("kind", .string("no_event"))]))
        }
        if let cut, cut.truthy {
            var item = PyDict<JSONValue>([("kind", .string("cut"))])
            for (k, v) in PyDict<JSONValue>(cut) ?? PyDict() { item[k] = v }
            items.append(item)
        }
        for lane in made["unnamed"]?.arrayValue ?? [] {
            var item = PyDict<JSONValue>([("kind", .string("unnamed"))])
            for (k, v) in PyDict<JSONValue>(lane) ?? PyDict() { item[k] = v }
            items.append(item)
        }
        items.append(PyDict([("kind", .string("review"))]))
        let order = { (i: PyDict<JSONValue>) in NEED_ORDER.firstIndex(of: i["kind"]?.stringValue ?? "") ?? NEED_ORDER.count }
        return Py.stableSorted(items) { order($0) < order($1) }.map { i in
            var out = i
            out["id"] = .string(needId(i))
            return out.json
        }
    }

    /// `_meeting_needs`: every item open in finished meeting `m`, reviewed or not. `calendar`: whether a calendar is
    /// connected (`app.calendar`); without one there is no cut to look up and no "which event" for a meeting without one.
    static func meetingNeeds(_ app: ServerApp, _ m: JSONValue, calendar: Bool) throws -> [JSONValue] {
        let paths = SearchAPI.paths(app, m)
        let files = MeetingsAPI.signatureFiles(paths, app) + [paths.cutDismissed]
        let made = try app.reviewCaches.needs.get(key: paths.folder.path, files: files) {
            let link = CalendarEvents.loadLink(paths)
            return JSONValue.object([
                ("event_question", MeetingsAPI.eventQuestion(paths)),
                ("calendar", link.map { .object([("link", $0.toDict())]) } ?? .null),
                ("has_event", .bool(link != nil)),
                ("dismissed", .bool(CalendarEvents.dismissed(paths))),
                ("speakers", .array(try laneLinks(paths))),
                ("unnamed", .array(try unnamedLanes(app, paths))),
            ])
        }
        let cut = calendar ? app.background.cutLater(app, paths, files: SignatureCache<Int>.signature(files) ?? []) : nil
        return try needItems(m, made, cut: cut, calendarOn: calendar)
    }

    /// `needs`: what waits on the user, per meeting, newest first. Of a reviewed meeting only what appeared after its
    /// review: what was open then the user saw and left. `count`: the meetings with anything open.
    public static func needs(_ app: ServerApp) throws -> JSONValue {
        var out: [JSONValue] = []
        for m in try MeetingsAPI.listMeetings(app: app) where m["status"]?.stringValue == "ready" {
            var items = try meetingNeeds(app, m, calendar: app.calendar != nil)
            if let seen = try MeetingsAPI.seen(SearchAPI.paths(app, m)) {
                items = items.filter { $0["kind"]?.stringValue != "review" && !seen.contains(ScalarKey($0["id"]?.stringValue ?? "")) }
            }
            if !items.isEmpty {
                out.append(.object([("id", m["id"] ?? .null), ("title", m["title"] ?? .null), ("start", m["start"] ?? .null),
                                    ("items", .array(items))]))
            }
        }
        return .object([("count", .int(out.count)), ("meetings", .array(out))])
    }

    /// `mark_reviewed`: reviewed with the items open now (they stay answered), or in the review again.
    public static func markReviewed(_ app: ServerApp, id: String, done: Bool) throws {
        try ChangesAPI.markReviewed(app, id: id, done: done) { entry in
            try meetingNeeds(app, entry, calendar: app.calendar != nil).filter { $0["kind"]?.stringValue != "review" }
                .compactMap { $0["id"]?.stringValue }
        }
    }
}

/// What the review and Needs you keep per meeting (api.py `_QUESTIONS_CACHE`, `_NEEDS_CACHE`).
public final class ReviewCaches: @unchecked Sendable {
    public let questions = SignatureCache<JSONValue>()
    public let needs = SignatureCache<JSONValue>()
    public init() {}
}

extension Router {
    /// The review, the open questions and Needs you (server.py's GET branches).
    static func addReviewRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/questions") { _, _ in .json(.array(try ReviewAPI.questions(app))) }
        r.get("/api/needs") { _, _ in .json(try ReviewAPI.needs(app)) }
        r.get("/api/review") { _, _ in .json(.array(try ReviewAPI.queue(app, userName: app.userName))) }
    }
}
