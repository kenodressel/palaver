// The coach's pages, what the page counts, and Report a Problem (api.py `coach_meeting`, `coach_overview`,
// `record_usage`, `create_report`; server.py's branches for them).
import Foundation
import PalaverCore
import PalaverDomain

public enum CoachAPI {
    /// `coach_meeting`: how the user talked in one meeting, with what is usual for them and the few things worth saying.
    /// While the meeting records: the same numbers from what the live worker has so far (`"live": true`).
    public static func meeting(_ app: ServerApp, _ id: String) throws -> JSONValue {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        let recording = MeetingsAPI.exists(paths.live) && MeetingsAPI.state(paths) == "recording"
        guard recording || MeetingsAPI.exists(paths.transcriptJson) else { throw NotFound(id) }
        let base = try Coach.baseline(Coach.history(app.outputDir, userName: app.userName, limit: Coach.BASELINE_MEETINGS,
                                                    stores: app.stores))
        let r = recording ? try live(app, paths) : try Coach.result(paths, userName: app.userName, stores: app.stores)
        var out = PyDict<JSONValue>(r) ?? PyDict()
        out["baseline"] = base
        out["highlights"] = .array(try Coach.highlights(r, base).map { .string($0) })
        out["live"] = .bool(recording)
        return out.json
    }

    /// The coach's numbers of a meeting being recorded: its live page's lines (mine have no label) and names.
    static func live(_ app: ServerApp, _ paths: RecordingPaths) throws -> JSONValue {
        let page = try LivePage.meeting(app: app, paths: paths)
        var mine: [Utterance] = [], theirs: [Utterance] = []
        for item in page["transcript"]?.arrayValue ?? [] {
            guard let start = LivePage.number(item["start"]), let end = LivePage.number(item["end"]),
                  let text = item["text"]?.stringValue, let speaker = item["speaker"]?.stringValue else { continue }
            if let label = item["label"]?.stringValue, !label.isEmpty {
                theirs.append(Utterance(speaker: label, start: start, end: end, text: text, label: label))
            } else {
                mine.append(Utterance(speaker: speaker, start: start, end: end, text: text))
            }
        }
        var names = PyDict<String>()
        for s in page["speakers"]?.arrayValue ?? [] {
            if let label = s["label"]?.stringValue, let shown = s["display"]?.stringValue { names[label] = shown }
        }
        var seen = Set<ScalarKey>(), known: [String] = []
        let voices = try VoiceBank(directory: app.stores.voices).names()
        for name in names.values + voices.keys where seen.insert(ScalarKey(name)).inserted { known.append(name) }
        let invited = CalendarEvents.invitedNames(paths, Py.stableSorted(known, by: Py.less), userName: app.userName) ?? []
        return try Coach.analyze(paths, userName: app.userName, invited: invited, names: names, stores: app.stores,
                                 lines: (mine, theirs))
    }

    /// `coach_overview`: every meeting's key numbers, newest first, and the averages; for the charts of the page (#43)
    /// also each meeting's length, words, people and topics, the totals and the share by meeting size.
    public static func overview(_ app: ServerApp) throws -> JSONValue {
        var titles = PyDict<JSONValue>()
        for m in try MeetingsAPI.listMeetings(app: app) {
            if case .string(let id)? = m["id"] { titles[id] = m }
        }
        var results = PyDict<JSONValue>()
        var found = PyDict<RecordingPaths>()
        for p in Coach.meetings(app.outputDir) {
            results[p.folder.lastPathComponent] = try Coach.result(p, userName: app.userName, stores: app.stores)
            found[p.folder.lastPathComponent] = p
        }
        let glossary = Glossary.current(stores: app.stores)
        let rows: [JSONValue] = Py.stableSorted(results.keys) { Py.less($1, $0) }.map { id in
            let r = results[id]!, m = titles[id]
            func at(_ a: String, _ b: String) -> JSONValue { r[a]?[b] ?? .null }
            let monologues = r["monologues"] ?? .null
            let one = r["talk"]?["people"].flatMap { PyNum($0) }.map { $0 == 2 } ?? false
            let projects: [JSONValue] = (m?["projects"]?.arrayValue ?? []).compactMap { $0["name"] }
            return .object([
                ("id", .string(id)), ("title", m?["title"] ?? .null), ("start", m?["start"] ?? .null),
                ("people", at("talk", "people")), ("share", at("talk", "share")), ("wpm", at("pace", "wpm")),
                ("fillers", at("fillers", "per_minute")), ("language", r["language"] ?? .null),
                ("longest", monologues.truthy ? (monologues.arrayValue?.first?["seconds"] ?? .null) : .int(0)),
                ("questions", at("questions", "count")), ("interruptions", at("interruptions", "by_me")),
                // What the charts add.
                ("kind", .string(one ? "1:1" : "group")), ("fair", at("talk", "fair")),
                ("duration", m?["duration"] ?? .null), ("minutes_talked", r["minutes_talked"] ?? .null),
                ("words", at("words", "me")), ("words_all", at("words", "all")),
                ("questions_per_hour", at("questions", "per_hour")), ("cut_off", at("interruptions", "of_me")),
                ("fastest", r["pace"]?["fastest"]?["wpm"] ?? .null), ("monologues", .int(monologues.arrayValue?.count ?? 0)),
                ("names", m?["people"] ?? .array([])), ("projects", .array(projects)),
                ("series", m?["series"]?["name"] ?? .null),
                ("terms", .array(terms(found[id]!, glossary).map { .object([("term", .string($0.term)), ("count", .int($0.count))]) })),
            ])
        }
        return .object([("baseline", try Coach.baseline(results.values)), ("meetings", .array(rows)),
                        ("trends", try Coach.trends(Coach.history(app.outputDir, userName: app.userName, stores: app.stores))),
                        ("totals", totals(rows)), ("by_size", try bySize(rows))])
    }

    /// How much was recorded and said in all, the longest meeting and the people met most often.
    static func totals(_ rows: [JSONValue]) -> JSONValue {
        func number(_ v: JSONValue?) -> Double { v.flatMap { PyNum($0) }?.double ?? 0 }
        var longest: JSONValue = .null, longestSeconds = 0.0
        var met = PyDict<Int>(), order: [String] = []
        for r in rows.reversed() {  // oldest first: the first one met wins a tie
            let seconds = number(r["duration"])
            if seconds > longestSeconds {
                longestSeconds = seconds
                longest = .object([("id", r["id"] ?? .null), ("title", r["title"] ?? .null), ("seconds", r["duration"] ?? .null)])
            }
            for n in r["names"]?.arrayValue ?? [] {
                guard let name = n.stringValue else { continue }
                if met[name] == nil { order.append(name) }
                met[name] = (met[name] ?? 0) + 1
            }
        }
        let people = Py.stableSorted(order) { met[$0]! > met[$1]! }.prefix(8)
        let recorded = rows.reduce(0.0) { $0 + number($1["duration"]) }
        let talked = rows.reduce(0.0) { $0 + number($1["minutes_talked"]) * 60 }
        return .object([
            ("meetings", .int(rows.count)),
            ("seconds", .int(Int(recorded.rounded()))),
            ("talked_seconds", .int(Int(talked.rounded()))),
            ("words", .int(rows.reduce(0) { $0 + Int(number($1["words"])) })),
            ("words_all", .int(rows.reduce(0) { $0 + Int(number($1["words_all"])) })),
            ("longest", longest),
            ("people", .array(people.map { .object([("name", .string($0)), ("meetings", .int(met[$0]!))]) })),
        ])
    }

    /// The meeting sizes the page compares: two people (a 1:1), three, four, five or more.
    static let SIZES = ["2", "3", "4", "5+"]

    /// The user's mean talk share by meeting size, beside the fair share of that size (for 5+: the mean of its
    /// meetings' fair shares). Meetings without a share (several people on one microphone) are left out.
    static func bySize(_ rows: [JSONValue]) throws -> JSONValue {
        var groups = PyDict<[JSONValue]>()
        for r in rows {
            guard let people = r["people"].flatMap({ PyNum($0) })?.double, people >= 2,
                  let share = r["share"], share != .null else { continue }
            let size = people >= 5 ? "5+" : String(Int(people))
            groups[size] = (groups[size] ?? []) + [r]
        }
        return .array(try SIZES.compactMap { size in
            guard let group = groups[size] else { return nil }
            return .object([("size", .string(size)), ("meetings", .int(group.count)),
                            ("share", try Coach.avg(group.map { $0["share"] ?? .null })),
                            ("fair", try Coach.avg(group.map { $0["fair"] ?? .null }))])
        })
    }

    /// The glossary terms said most in a meeting (each spelling of a term counts for it), at most TERMS_SHOWN of them;
    /// kept while the transcript and the glossary stay as they are.
    static let TERMS_SHOWN = 5
    private static let termCache = SignatureCache<[(term: String, count: Int)]>()

    static func terms(_ paths: RecordingPaths, _ glossary: Glossary) -> [(term: String, count: Int)] {
        termCache.get(key: paths.folder.path + "\u{0}" + glossary.path.path, files: [paths.transcriptJson, glossary.path]) {
            var spelled = PyDict<String>()  // casefolded → the term as the glossary writes it
            for (_, e) in glossary.terms {
                if let t = e["term"]?.stringValue, !Py.strip(t).isEmpty { spelled[Py.casefold(t)] = t }
            }
            guard !spelled.isEmpty, let lines = try? MeetingsAPI.utterances(paths), !lines.isEmpty else { return [] }
            let alternatives = Py.stableSorted(spelled.keys) { $0.unicodeScalars.count > $1.unicodeScalars.count }
            guard let regex = try? PyRegex(#"(?<!\w)("# + alternatives.map(PyRegex.escape).joined(separator: "|") + #")(?!\w)"#,
                                           ignoreCase: true) else { return [] }
            var counts = PyDict<Int>(), order: [String] = []
            let text = glossary.apply(lines: lines.map(\.text)).joined(separator: "\n")
            for m in regex.matches(in: text) {
                guard let heard = m.group(1), let term = spelled[Py.casefold(heard)] else { continue }
                if counts[term] == nil { order.append(term) }
                counts[term] = (counts[term] ?? 0) + 1
            }
            return Py.stableSorted(order) { counts[$0]! > counts[$1]! }.prefix(TERMS_SHOWN).map { ($0, counts[$0]!) }
        }
    }
}

public enum UsageAPI {
    /// The most events of one `POST /api/usage` that are kept (api.py).
    public static let MAX_USAGE_EVENTS = 200
    /// The texts an event of the page may carry besides its kind and id (api.py `_USAGE_FIELDS`).
    public static let USAGE_FIELDS = ["text", "from"]

    /// `record_usage`: what the page counted (actions, views, tabs, ⌘K, errors shown) and, at its start, its catalog of
    /// features. Anything else is left out.
    public static func record(_ app: ServerApp, _ body: JSONValue) throws -> JSONValue {
        // The catalog first: whoever sees this post's events in usage.jsonl finds its catalog written too.
        if case .object? = body["catalog"] { try Usage.saveCatalog(body["catalog"], path: app.stores.usageFeatures) }
        let given = try PyBody.get(body, "events")
        let events = given.map { $0.truthy ? $0 : .array([]) } ?? .array([])
        guard case .array(let items) = events else { throw BadRequest("events is a list") }
        for e in items.prefix(MAX_USAGE_EVENTS) {
            guard case .object = e, case .string(let kind)? = e["kind"], Usage.PAGE_KINDS.contains(where: { Py.same($0, kind) })
            else { continue }
            let extra: [(String, JSONValue)] = USAGE_FIELDS.compactMap { k in
                if case .string? = e[k] { return (k, e[k]!) }
                return nil
            }
            let id = e["id"].map { $0.truthy ? Py.str($0) : "" } ?? ""
            let cut = String(String.UnicodeScalarView(id.unicodeScalars.prefix(80)))
            Usage.record(kind, cut.isEmpty ? nil : cut, fields: extra, path: app.stores.usage)
        }
        return .object([("ok", .bool(true))])
    }
}

extension Router {
    static func addMiscRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/coach") { _, _ in .json(try CoachAPI.overview(app)) }
        r.get("/api/meetings/([^/]+)/coach") { _, m in .json(try CoachAPI.meeting(app, m.group(1)!)) }
        r.post("/api/usage") { req, _ in .json(try UsageAPI.record(app, req.json)) }
        r.post("/api/report") { req, _ in
            let answer = try app.report.create(req.json)
            // `create_report`'s two lines, once the report is written.
            let body = req.json
            let kind = body["kind"]?.stringValue ?? "bug"
            let meeting = body["meeting"].flatMap { $0.truthy ? $0.stringValue : nil } ?? "None"
            let audio = body["audio"] == .bool(true) ? "True" : "False"
            app.log?.message("writing a problem report (\(kind), meeting \(meeting), audio \(audio))", logger: "palaver.webapp.api")
            let path = answer["path"].map(Py.str) ?? "None", size = answer["size_text"].map(Py.str) ?? "None"
            app.log?.message("problem report written: \(path) (\(size))", logger: "palaver.webapp.api")
            return .json(answer)
        }
    }
}
