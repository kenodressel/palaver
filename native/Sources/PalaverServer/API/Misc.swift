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

    /// `coach_overview`: every meeting's key numbers, newest first, and the averages.
    public static func overview(_ app: ServerApp) throws -> JSONValue {
        var titles = PyDict<JSONValue>()
        for m in try MeetingsAPI.listMeetings(app: app) {
            if case .string(let id)? = m["id"] { titles[id] = m }
        }
        var results = PyDict<JSONValue>()
        for p in Coach.meetings(app.outputDir) {
            results[p.folder.lastPathComponent] = try Coach.result(p, userName: app.userName, stores: app.stores)
        }
        let rows: [JSONValue] = Py.stableSorted(results.keys) { Py.less($1, $0) }.map { id in
            let r = results[id]!, m = titles[id]
            func at(_ a: String, _ b: String) -> JSONValue { r[a]?[b] ?? .null }
            let monologues = r["monologues"] ?? .null
            return .object([
                ("id", .string(id)), ("title", m?["title"] ?? .null), ("start", m?["start"] ?? .null),
                ("people", at("talk", "people")), ("share", at("talk", "share")), ("wpm", at("pace", "wpm")),
                ("fillers", at("fillers", "per_minute")), ("language", r["language"] ?? .null),
                ("longest", monologues.truthy ? (monologues.arrayValue?.first?["seconds"] ?? .null) : .int(0)),
                ("questions", at("questions", "count")), ("interruptions", at("interruptions", "by_me")),
            ])
        }
        return .object([("baseline", try Coach.baseline(results.values)), ("meetings", .array(rows)),
                        ("trends", try Coach.trends(Coach.history(app.outputDir, userName: app.userName, stores: app.stores)))])
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
