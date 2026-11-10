// Meeting prep (prep.py, #31): a meeting before it happens, from the calendar. Upcoming events are listed with
// suggestions for their project (the same rules as for recordings; a recurring event goes where its earlier occurrences
// went) and context: the last meetings with the same people or in the same series, with their summary and open next
// steps. A project chosen ahead of time is kept in prepared.json and given to the recording once it is matched to the
// event (`apply`), with the notes written before it.
import Foundation
import PalaverCore

public enum Prep {
    /// How far ahead upcoming meetings are listed (seconds: 36 hours).
    public static let AHEAD: TimeInterval = 36 * 3600
    /// How many earlier meetings `context` brings.
    public static let CONTEXT_MEETINGS = 2

    /// prepared.json is written without a file lock, as Python's prep.py does; this serializes Swift's own writers.
    private static let fileLock = NSLock()

    // MARK: - prepared.json

    /// event key → {"title", "start", "projects": [id, …]}; a missing or broken file is empty.
    static func load(_ stores: StorePaths) -> PyDict<JSONValue> {
        PythonJSON.read(stores.prepared).flatMap { PyDict<JSONValue>($0) } ?? PyDict()
    }

    /// `json.dumps(data, indent=2, ensure_ascii=False)` through `prepared.json.tmp` (prep.py:42).
    static func save(_ data: PyDict<JSONValue>, _ stores: StorePaths) throws {
        let path = stores.prepared
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PythonJSON.write(data.json, to: path, indent: 2, ensureAscii: false,
                             via: path.deletingPathExtension().lastPathComponent + ".json.tmp")
    }

    // MARK: - upcoming meetings

    /// Meetings still to come (or running) in the next day and a half: events with someone else invited, by start.
    public static func upcoming(provider: CalendarProvider, now: PyDateTime) throws -> [CalendarEvent] {
        let until = try now.adding(seconds: AHEAD)
        let events = try provider(now.date, until.date).filter { e in
            !e.allDay && e.end > now && e.start < until && !e.key.isEmpty
                && e.attendees.contains { !$0.isSelf && !$0.isRoom }  // a meeting, not a reminder
        }
        return Py.stableSorted(events) { $0.start < $1.start }
    }

    /// An upcoming event by its key.
    public static func find(provider: CalendarProvider, key: String, now: PyDateTime) throws -> CalendarEvent? {
        try upcoming(provider: provider, now: now).first { Py.same($0.key, key) }
    }

    /// Project ids chosen for `event` ahead of time.
    public static func chosen(_ event: CalendarEvent, stores: StorePaths = .current()) -> [String] {
        (load(stores)[event.key]?["projects"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    /// Choose `project` for `event` ahead of time, or (`remove`) no longer; an event with none chosen is forgotten.
    public static func choose(_ event: CalendarEvent, _ project: String, remove: Bool = false,
                              stores: StorePaths = .current()) throws {
        try fileLock.withLock {
            var data = load(stores)
            var entry = data[event.key].flatMap { PyDict<JSONValue>($0) }
                ?? PyDict([("title", .string(event.title)), ("start", .string(event.start.iso)), ("projects", .array([]))])
            var projects = entry["projects"]?.arrayValue ?? []
            let isProject = { (p: JSONValue) in p.stringValue.map { Py.same($0, project) } ?? false }
            if remove {
                projects.removeAll(where: isProject)
            } else if !projects.contains(where: isProject) {
                projects.append(.string(project))
            }
            entry["projects"] = .array(projects)
            data[event.key] = projects.isEmpty ? nil : entry.json
            try save(data, stores)
        }
    }

    /// Give a recording what was prepared for its event beforehand: the user's own notes (#44) and the projects chosen
    /// (assigned as the user's, under the projects' lock after a reload). Returns the projects added.
    @discardableResult
    public static func apply(_ paths: RecordingPaths, event: CalendarEvent, stores: StorePaths = .current()) throws -> [String] {
        guard !event.key.isEmpty else { return [] }
        _ = try MyNotes.adopt(MyNotes.prepFolder(event.key, stores: stores), paths.folder)
        guard let entry = load(stores)[event.key], entry.truthy else { return [] }
        let wanted = (entry["projects"]?.arrayValue ?? []).compactMap(\.stringValue)
        let store = ProjectStore(path: stores.projects)
        let added = try store.locked {
            store.reload()
            let added = try wanted.filter { pid in
                try store.projects[pid] != nil && store.assign(paths.folder.lastPathComponent, pid, why: "chosen before the meeting")
            }
            try store.save()
            return added
        }
        // Used up. The projects first: should this fail, they are given again next time, and that changes nothing.
        try fileLock.withLock {
            var data = load(stores)
            data[event.key] = nil
            try save(data, stores)
        }
        return added
    }

    // MARK: - suggestions and context

    /// Projects the upcoming `event` might belong to, as `ProjectRules.suggestions` answers them; chosen ones aside.
    public static func suggestions(_ event: CalendarEvent, outputDir: URL, userName: String, store: ProjectStore? = nil,
                                   every: PyDict<ProjectFacts>? = nil, stores: StorePaths = .current()) throws -> [JSONValue] {
        let store = store ?? ProjectStore(path: stores.projects)
        let every = try every ?? ProjectRules.allFacts(outputDir: outputDir, userName: userName, stores: stores)
        let facts = ProjectRules.eventFacts(event, userName: userName, stores: stores)
        var withEvent = every
        withEvent[facts.meeting] = facts
        let taken = Set(chosen(event, stores: stores).map(ScalarKey.init))
        return ProjectRules.offered(ProjectRules.scores(facts, store, every, Similarity(withEvent)), store, taken: taken)
    }

    /// The last meetings that lead up to this one: earlier occurrences of the series first, then those that shared the
    /// most invitees. Each `{"id", "title", "start", "why", "summary", "next_steps"}`, the notes with speakers' names
    /// and the glossary's spellings.
    public static func context(_ event: CalendarEvent, outputDir: URL, userName: String, every: PyDict<ProjectFacts>? = nil,
                               stores: StorePaths = .current()) throws -> [JSONValue] {
        let every = try every ?? ProjectRules.allFacts(outputDir: outputDir, userName: userName, stores: stores)
        let facts = ProjectRules.eventFacts(event, userName: userName, stores: stores)
        let start = event.start.iso
        let invited = Set(facts.people.map(ScalarKey.init))
        func sameSeries(_ f: ProjectFacts) -> Bool { !facts.series.isEmpty && Py.same(facts.series, f.series) }
        var ranked: [(series: Bool, shared: Int, start: String, mid: String)] = []
        for (mid, f) in every {
            if !f.start.isEmpty && !Py.less(f.start, start) { continue }  // `f.start >= event.start.isoformat()`
            let shared = f.people.filter { invited.contains(ScalarKey($0)) }.count
            if sameSeries(f) || shared > 0 { ranked.append((sameSeries(f), shared, f.start, mid)) }
        }
        // sorted(ranked, reverse=True) on (same_series, shared, start) and the id.
        let best = Py.stableSorted(ranked) { a, b in
            if a.series != b.series { return a.series }
            if a.shared != b.shared { return a.shared > b.shared }
            if !Py.same(a.start, b.start) { return Py.less(b.start, a.start) }
            return Py.less(b.mid, a.mid)
        }.prefix(CONTEXT_MEETINGS)
        let glossary = Glossary.current(stores: stores)
        return try best.map { r in
            let paths = RecordingPaths(outputDir.appendingPathComponent(r.mid, isDirectory: true))
            let notes = NotesFile.load(paths).flatMap { $0.truthy ? $0 : nil } ?? .object([])
            let n = glossary.applyTo(try withNames(notes, displayNames(paths, notes)))
            let f = every[r.mid]!
            return .object([("id", .string(r.mid)), ("title", .string(f.title)), ("start", .string(f.start)),
                            ("why", .string(sameSeries(f) ? "same series" : "same people")),
                            ("summary", n["summary"] ?? .null), ("next_steps", n["next_steps"] ?? .array([]))])
        }
    }

    // MARK: - speaker labels in the notes

    private static let speakerLabel = try! PyRegex(#"SPEAKER_\d+"#)
    private static let regexLock = NSLock()
    nonisolated(unsafe) private static var namePatterns: [String: PyRegex] = [:]

    /// SPEAKER_xx → the name in effect, a room (#56), or "Speaker N", for the labels of the notes and of the names.
    static func displayNames(_ paths: RecordingPaths, _ notes: JSONValue) throws -> PyDict<String> {
        var names = try Speakers.namesInEffect(paths)
        for (label, shown) in SharedMic.display(paths) { names[label] = shown }
        var out = PyDict<String>()
        let labels = speakerLabel.matches(in: PythonJSON.dumps(notes)).compactMap { $0.group() }
        for label in labels + names.keys where out[label] == nil {
            if let name = names[label], !name.isEmpty {
                out[label] = name
            } else {
                // `int(label.rsplit("_", 1)[1]) + 1`
                guard let underscore = label.unicodeScalars.lastIndex(of: "_"),
                      let n = Int(String(label.unicodeScalars[label.unicodeScalars.index(after: underscore)...])) else {
                    throw ProjectValueError("no speaker number in \(label)")
                }
                out[label] = "Speaker \(n + 1)"
            }
        }
        return out
    }

    /// `notes.with_names`: `value` (notes or any part of them) with SPEAKER_xx labels replaced.
    static func withNames(_ value: JSONValue, _ names: PyDict<String>) throws -> JSONValue {
        guard !names.isEmpty else { return value }
        // sorted(names, key=len, reverse=True): the longest first, equals in their order.
        let alternatives = Py.stableSorted(names.keys) { $0.unicodeScalars.count > $1.unicodeScalars.count }
        let pattern = #"\b("# + alternatives.map(PyRegex.escape).joined(separator: "|") + #")\b"#
        let regex = try regexLock.withLock {
            if let r = namePatterns[pattern] { return r }
            let r = try PyRegex(pattern)
            namePatterns[pattern] = r
            return r
        }
        func sub(_ v: JSONValue) -> JSONValue {
            switch v {
            case .string(let s): return .string(regex.sub(in: s) { m in m.group(1).flatMap { names[$0] } ?? "" })
            case .array(let items): return .array(items.map(sub))
            case .object(let fields): return .object(fields.map { ($0.0, sub($0.1)) })
            default: return v
            }
        }
        return sub(value)
    }
}
