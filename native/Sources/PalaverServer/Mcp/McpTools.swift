// What Claude's tools answer (mcp_server.py `Meetings`, issue #35): meetings with their notes and transcripts,
// projects, people and open next steps, read-only, from the same functions as the window (MeetingsAPI, SearchAPI,
// ProjectsAPI, PeopleAPI), so names, merges and the glossary apply here too. Transcripts are long, so tools answer with
// summaries and excerpts first; the transcript (or a time range of it) only when asked for.
//
// Meetings kept on this Mac (#53) are invisible: no tool shows them or what is in them, not even as a name or project
// the search read out of the query; a project whose meetings are all kept on this Mac answers like one that doesn't
// exist, and a person met only there is not listed.
import Foundation
import PalaverCore
import PalaverDomain

/// A deliberate answer to a call that can't be answered (Python's ValueError): Claude sees its text.
public struct McpToolError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public final class McpTools {
    /// `KEPT_ON_THIS_MAC`.
    public static let KEPT_ON_THIS_MAC = "This meeting is kept on this Mac; it is not shared with Claude."
    /// get_meeting's transcript lines, at most.
    public static let TRANSCRIPT_LINES = 400

    public let app: ServerApp
    /// config.toml's name; settings.json's wins, read per call (a name changed in the app applies without a restart).
    let configUserName: String
    /// The search by meaning within the query's filters (`api.search_meaning`): text, meetings left out, projects
    /// hidden. Tests replace it.
    public var meaning: (String, Set<ScalarKey>, Set<ScalarKey>) throws -> [JSONValue]

    public init(app: ServerApp, userName: String) {
        self.app = app
        configUserName = userName
        meaning = { [unowned app] text, exclude, hidden in
            try SearchAPI.meaning(app, text, userName: app.userName, exclude: exclude, hideProjects: hidden)
        }
    }

    /// The user's name now, also set on the app (the window's functions read it there).
    @discardableResult
    func userName() -> String {
        let name = SettingsFile.currentUserName(default: configUserName, stores: app.stores)
        app.userName = name
        return name
    }

    // MARK: - helpers

    /// `_private`: the meetings kept on this Mac.
    func privateMeetings() -> Set<ScalarKey> { Set(LocalOnly.meetings(outputDir: app.outputDir).map(ScalarKey.init)) }

    /// `_hidden_projects`: projects whose meetings are all kept on this Mac (their name and description came from them).
    func hiddenProjects(_ hidden: Set<ScalarKey>) -> Set<ScalarKey> {
        let store = ProjectStore(path: app.stores.projects)
        var out = Set<ScalarKey>()
        for (pid, _) in store.projects {
            let members = store.meetingsOf(pid)
            if !members.isEmpty && members.keys.allSatisfy({ hidden.contains(ScalarKey($0)) }) { out.insert(ScalarKey(pid)) }
        }
        return out
    }

    static func id(_ m: JSONValue) -> String { m["id"]?.stringValue ?? "" }

    func meetings() throws -> [JSONValue] {
        let hidden = privateMeetings()
        return try MeetingsAPI.listMeetings(app: app).filter { !hidden.contains(ScalarKey(Self.id($0))) }
    }

    /// `_project_id`: the project named or with that id; a hidden one answers like one that doesn't exist.
    func projectId(_ project: String?) throws -> String? {
        guard let project, !project.isEmpty else { return nil }
        let store = ProjectStore(path: app.stores.projects)
        let pid = store.projects[project] != nil ? project : store.find(project)
        guard let pid, !hiddenProjects(privateMeetings()).contains(ScalarKey(pid)) else {
            throw McpToolError("no project \(Py.repr(.string(project))); list_projects shows them")
        }
        return pid
    }

    /// `_projects`: the window's projects without the meetings kept on this Mac (their people and dates left out too),
    /// and a project of only those left out whole.
    func projects() throws -> [JSONValue] {
        userName()
        let hidden = privateMeetings()
        let hiddenProjects = hiddenProjects(hidden)
        var people = PyDict<[String]>()
        for m in try MeetingsAPI.listMeetings(app: app) { people[Self.id(m)] = Self.strings(m["people"]) }
        var out: [JSONValue] = []
        for p in try ProjectsAPI.listProjects(app)["projects"]?.arrayValue ?? [] {
            guard !hiddenProjects.contains(ScalarKey(Self.id(p))), case .object(var fields) = p else { continue }
            let members = (p["meetings"]?.arrayValue ?? []).filter { !hidden.contains(ScalarKey(Self.id($0))) }
            var counts = PyDict<Int>()
            for x in members {
                for name in people[Self.id(x)] ?? [] { counts[name] = (counts[name] ?? 0) + 1 }
            }
            let ranked = Py.stableSorted(counts.keys) { a, b in
                counts[a]! != counts[b]! ? counts[a]! > counts[b]! : Py.less(Py.casefold(a), Py.casefold(b))
            }
            McpSetup.set(&fields, "meetings", .array(members))
            McpSetup.set(&fields, "people", .strings(Array(ranked.prefix(8))))
            McpSetup.set(&fields, "latest", members.first?["start"] ?? .null)
            out.append(.object(fields))
        }
        return out
    }

    /// `_matches`: in the project, with the person (spoke or invited; part of a name is enough), between the dates.
    func matches(_ m: JSONValue, project: String?, person: String?, since: String?, until: String?) -> Bool {
        if let project, !(m["projects"]?.arrayValue ?? []).contains(where: { Py.same(Self.id($0), project) }) { return false }
        if let person, !person.isEmpty {
            let wanted = Py.casefold(person)
            let names = Self.strings(m["people"]) + Self.strings(m["invited"])
            if !names.contains(where: { Self.contains(Py.casefold($0), wanted) }) { return false }
        }
        let start = Self.prefix(m["start"]?.stringValue ?? "", 10)
        if let since, !since.isEmpty, Py.less(start, Self.prefix(since, 10)) { return false }
        if let until, !until.isEmpty, Py.less(Self.prefix(until, 10), start) { return false }
        return true
    }

    /// `_brief`: a meeting in a list.
    static func brief(_ m: JSONValue) -> [(String, JSONValue)] {
        var out: [(String, JSONValue)] = [
            ("id", m["id"] ?? .null),
            ("title", (m["title"]?.truthy ?? false) ? m["title"]! : .string(Titles.fallback(m["start"]?.stringValue))),
            ("start", m["start"] ?? .null),
            ("minutes", .int(minutes(m["duration"]))),
            ("status", m["status"] ?? .null),
            ("projects", .array((m["projects"]?.arrayValue ?? []).map { $0["name"] ?? .null })),
            ("people", m["people"] ?? .array([])),
            ("summary", m["summary"] ?? .null),
        ]
        if let imported = m["imported"], imported.truthy {  // recorded by a colleague, not the user (#58)
            out.append(("imported_from", imported["from"] ?? .null))
        }
        return out
    }

    // MARK: - the tools

    public func listMeetings(project: String? = nil, person: String? = nil, since: String? = nil, until: String? = nil,
                             limit: Int = 30) throws -> JSONValue {
        let pid = try projectId(project)
        let found = try meetings().filter { matches($0, project: pid, person: person, since: since, until: until) }
        return .array(Self.slice(found, limit).map { .object(Self.brief($0)) })
    }

    /// The window's search: the query read the same way (people, projects, organizations, dates, decisions, who said
    /// it), the parameters as written-out filters, then meetings found by meaning.
    public func searchMeetings(query: String, project: String? = nil, person: String? = nil, organization: String? = nil,
                               since: String? = nil, until: String? = nil, limit: Int = 10) throws -> JSONValue {
        let name = userName()
        var text = query
        if let project, !project.isEmpty, let pid = try projectId(project) {
            let store = ProjectStore(path: app.stores.projects)
            text += " project:\"\(store.projects[pid]?["name"].map(Py.str) ?? "")\""
        }
        for (key, value) in [("person", person), ("org", organization), ("since", since), ("until", until)] {
            if let value, !value.isEmpty, !Self.quotable(value).isEmpty { text += " \(key):\"\(Self.quotable(value))\"" }
        }
        for (key, value) in [("since", since), ("until", until)] {
            guard let value, !value.isEmpty else { continue }
            let q = SearchParser.parse("\(key):\"\(Self.quotable(value))\"", vocab: Vocabulary())
            if !q.filters.contains(where: { $0.kind == key }) {
                throw McpToolError("\(key) must be a date like 2026-10-01 (or 2026-10, or a month name); got \(Py.repr(.string(value)))")
            }
        }
        // Kept on this Mac (#53): never searched for Claude, by words or by meaning, nor their people and projects read
        // out of the query.
        let hidden = privateMeetings()
        let hiddenProjects = hiddenProjects(hidden)
        let (q, found) = try SearchAPI.run(app, text, userName: name, exclude: hidden, hideProjects: hiddenProjects)
        let results = found.filter { !hidden.contains(ScalarKey(Self.id($0))) }
        var out: [JSONValue] = Self.slice(results, limit).map { r in
            .object(Self.brief(r) + [
                ("matched_by", .string("words")),
                ("found_in_notes", r["in_notes"] ?? .bool(false)),
                ("notes", .strings((r["notes_hits"]?.arrayValue ?? []).map(Self.note))),
                ("matches_in_transcript", r["hit_count"] ?? .int(0)),
                ("lines", .strings((r["hits"]?.arrayValue ?? []).map(Self.line))),
            ])
        }
        if out.count < limit && !q.words.isEmpty {
            var seen = Set(out.map { ScalarKey(Self.id($0)) })
            for r in try meaning(text, hidden, hiddenProjects) {
                let rid = ScalarKey(Self.id(r))
                if seen.contains(rid) || hidden.contains(rid) || out.count >= limit { continue }
                seen.insert(rid)
                let pieces = r["meaning"]?.arrayValue ?? []
                out.append(.object(Self.brief(r) + [
                    ("matched_by", .string("meaning")),
                    ("notes", .strings(pieces.filter { $0["kind"]?.stringValue != "line" }.map(Self.note))),
                    ("lines", .strings(pieces.filter { $0["kind"]?.stringValue == "line" }.map(Self.line))),
                ]))
            }
        }
        return .object([("understood", .array(q.chips().map { $0["label"] ?? .null })), ("meetings", .array(out))])
    }

    public func getMeeting(meetingId: String, includeTranscript: Bool = false, fromMinute: Double? = nil,
                           toMinute: Double? = nil) throws -> JSONValue {
        if privateMeetings().contains(ScalarKey(meetingId)) {
            return .object([("id", .string(meetingId)), ("kept_on_this_mac", .bool(true)), ("message", .string(Self.KEPT_ON_THIS_MAC))])
        }
        userName()
        let m = try MeetingsAPI.getMeeting(app: app, id: meetingId, calendar: false)
        let notes = m["notes"].flatMap { $0.isObject ? $0 : nil } ?? .object([])
        var out: [(String, JSONValue)] = [
            ("id", m["id"] ?? .string(meetingId)),
            ("title", (m["title"]?.truthy ?? false) ? m["title"]! : .string(Titles.fallback(m["start"]?.stringValue))),
            ("start", m["start"] ?? .null),
            ("minutes", .int(Self.minutes(m["duration"]))),
            ("status", m["status"] ?? .null),
            ("invited", .array((m["calendar"]?["attendees"]?.arrayValue ?? []).map { $0["name"] ?? .null })),
            ("speakers", .strings((m["speakers"]?.arrayValue ?? []).map { s in
                let name = (s["name"]?.truthy ?? false) ? Py.str(s["name"]!) : Py.str(s["display"] ?? .null)
                if let org = s["org"], org.truthy { return "\(name) (\(Py.str(org)))" }
                return name
            })),
            ("projects", .array((m["projects"]?.arrayValue ?? []).map { $0["name"] ?? .null })),
        ]
        if let imported = m["imported"], imported.truthy {
            let from = imported["from"] ?? .null
            out.append(("imported_from", from))
            out.append(("note", .string("Imported from \(Py.str(from)): recorded by them, not by the user.")))
        }
        out.append(("notes", .object(["summary", "sections", "next_steps", "decisions", "decisions_mine"].compactMap { k in
            guard let v = notes[k], v.truthy else { return nil }
            return (k, v)
        })))
        let mine = MyNotes.promptText(app.outputDir.appendingPathComponent(meetingId, isDirectory: true))  // the user's own (#44)
        if !mine.isEmpty { out.append(("my_notes", .string(mine))) }
        if includeTranscript || fromMinute != nil || toMinute != nil {
            let lo = (fromMinute ?? 0) * 60
            let hi = toMinute.map { $0 * 60 } ?? .infinity
            let lines = (m["transcript"]?.arrayValue ?? []).filter { t in
                let start = t["start"]?.doubleValue ?? 0
                return lo <= start && start < hi
            }.map(Self.line)
            out.append(("transcript", .strings(Array(lines.prefix(Self.TRANSCRIPT_LINES)))))
            if lines.count > Self.TRANSCRIPT_LINES {
                out.append(("transcript_truncated",
                            .string("\(lines.count - Self.TRANSCRIPT_LINES) more lines; ask again with from_minute/to_minute")))
            }
        }
        return .object(out)
    }

    public func listProjects() throws -> JSONValue {
        .array(try projects().map { p in
            .object([("id", p["id"] ?? .null), ("name", p["name"] ?? .null), ("description", p["description"] ?? .null),
                     ("meetings", .int(p["meetings"]?.arrayValue?.count ?? 0)), ("people", p["people"] ?? .array([])),
                     ("latest", p["latest"] ?? .null)])
        })
    }

    public func getProject(project: String) throws -> JSONValue {
        guard let pid = try projectId(project) else { throw McpToolError("no project \(Py.repr(.string(project))); list_projects shows them") }
        guard let p = try projects().first(where: { Py.same(Self.id($0), pid) }) else {
            throw McpToolError("no project \(Py.repr(.string(project))); list_projects shows them")
        }
        return .object([
            ("id", p["id"] ?? .null), ("name", p["name"] ?? .null), ("description", p["description"] ?? .null),
            ("people", p["people"] ?? .array([])),
            ("meetings", .array((p["meetings"]?.arrayValue ?? []).map { x in
                .object([("id", x["id"] ?? .null), ("title", x["title"] ?? .null), ("start", x["start"] ?? .null),
                         ("summary", x["summary"] ?? .null)])
            })),
            ("next_steps", try openNextSteps(project: pid)),
        ])
    }

    /// People from the meetings that are shared: someone met only in meetings kept on this Mac is not listed.
    public func listPeople() throws -> JSONValue {
        let hidden = privateMeetings()
        var out: [JSONValue] = []
        for p in try PeopleAPI.directory(app, userName: userName())["people"]?.arrayValue ?? [] {
            let all = p["meetings"]?.arrayValue ?? []
            let seen = all.filter { !hidden.contains(ScalarKey(Self.id($0))) }
            if !all.isEmpty && seen.isEmpty { continue }
            let talked = seen.reduce(0.0) { $0 + ($1["talk_seconds"]?.doubleValue ?? 0) }
            out.append(.object([("name", p["name"] ?? .null), ("organization", p["org"] ?? .null), ("meetings", .int(seen.count)),
                                ("minutes_talked", .int(Self.rounded(talked / 60))),
                                ("last_meeting", seen.first?["start"] ?? .null)]))
        }
        return .array(out)
    }

    /// Next steps from the notes, newest meeting first. Notes have no done/undone state yet: these are all that were
    /// agreed.
    public func openNextSteps(project: String? = nil, person: String? = nil, owner: String? = nil,
                              since: String? = nil) throws -> JSONValue {
        let pid = try projectId(project)
        let glossary = Glossary.current(stores: app.stores)
        var out: [JSONValue] = []
        for m in try meetings() {
            guard m["has_notes"]?.truthy == true, matches(m, project: pid, person: person, since: since, until: nil) else { continue }
            let paths = RecordingPaths(app.outputDir.appendingPathComponent(Self.id(m), isDirectory: true))
            let steps = Notes.load(paths)?["next_steps"] ?? .array([])
            let named = glossary.applyTo(Notes.withNames(steps, try MeetingsAPI.displayNames(paths)))
            for s in named.arrayValue ?? [] {
                let stepOwner = (s["owner"]?.truthy ?? false) ? Py.str(s["owner"]!) : ""
                if let owner, !owner.isEmpty, !Self.contains(Py.casefold(stepOwner), Py.casefold(owner)) { continue }
                out.append(.object([("meeting", m["id"] ?? .null), ("title", m["title"] ?? .null), ("start", m["start"] ?? .null),
                                    ("owner", stepOwner.isEmpty ? .null : s["owner"]!), ("task", s["task"] ?? .null)]))
            }
        }
        return .array(out)
    }

    // MARK: - text

    /// `_clock`: "1:02:03", or "2:03" under an hour.
    static func clock(_ seconds: Double) -> String {
        let s = seconds.isFinite ? Int(seconds) : 0
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "[0:13] Speaker 2: …".
    static func line(_ t: JSONValue) -> String {
        "[\(clock(t["start"]?.doubleValue ?? 0))] \(Py.str(t["speaker"] ?? .null)): \(Py.str(t["text"] ?? .null))"
    }

    /// `_quotable`: a parameter as one quoted filter value: the search has no escape for a quote, so quotes go.
    static func quotable(_ value: String) -> String {
        Py.split(value.replacingOccurrences(of: "\"", with: " ")).joined(separator: " ")
    }

    static let NOTE_KINDS = ["decision": "Decision", "step": "Next step", "point": "Point", "summary": "Summary"]

    /// `_note`: "Decision: …", "Next step (Anna): …".
    static func note(_ n: JSONValue) -> String {
        let kind = Py.str(n["kind"] ?? .null)
        let owner = (n["owner"]?.truthy ?? false) ? " (\(Py.str(n["owner"]!)))" : ""
        return "\(NOTE_KINDS[kind] ?? kind.capitalized)\(owner): \(Py.str(n["text"] ?? .null))"
    }

    /// `round((duration or 0) / 60)`.
    static func minutes(_ duration: JSONValue?) -> Int { rounded((duration?.doubleValue ?? 0) / 60) }

    static func rounded(_ x: Double) -> Int { x.isFinite ? Int(x.rounded(.toNearestOrEven)) : 0 }

    static func strings(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap(\.stringValue) }

    /// `part in text`, by code points.
    static func contains(_ text: String, _ part: String) -> Bool {
        let t = Array(text.unicodeScalars), p = Array(part.unicodeScalars)
        if p.isEmpty { return true }
        guard p.count <= t.count else { return false }
        return (0...(t.count - p.count)).contains { Array(t[$0..<$0 + p.count]) == p }
    }

    /// `text[:n]`, by code points.
    static func prefix(_ text: String, _ n: Int) -> String { String(String.UnicodeScalarView(text.unicodeScalars.prefix(n))) }

    /// `items[:limit]` (a negative limit leaves that many out at the end).
    static func slice<T>(_ items: [T], _ limit: Int) -> [T] {
        limit >= 0 ? Array(items.prefix(limit)) : Array(items.dropLast(-limit))
    }
}
