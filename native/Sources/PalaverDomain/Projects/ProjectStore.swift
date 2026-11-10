// Projects: meetings grouped by customer, initiative or topic (projects.py:1-202, issue #29). A project has a name and a
// description, and many meetings; a meeting is usually in one project but may be in several. Both are kept in
// projects.json next to the voice bank. Each assignment records who decided it: the user ("you"), the rules ("auto") or
// the language model ("model"); a weaker decider never replaces a stronger one, and a meeting the user took out of a
// project stays out for the rules and the model.
import Foundation
import PalaverCore

/// `LookupError(pid)`: there is no project with this id (the window answers 500).
public struct ProjectLookupError: Error, CustomStringConvertible {
    public let description: String
    public init(_ pid: String) { description = pid }
}

/// What Python raises as `ValueError` (a name missing or taken, a merge into itself) or `KeyError` (an unknown decider in
/// the file): the window answers 400.
public struct ProjectValueError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// projects.json: `{"projects": {id: {"name", "description", "description_by"}}, "meetings": {meeting: {"assigned":
/// {id: {"by", "why", "confidence"?}}, "rejected": [id, …]}}}`, written like Python's `json.dumps(indent=2,
/// ensure_ascii=False)` through `projects.json.tmp` under `projects.json.lock`. The file's other top-level keys and their
/// order are kept. Change it as Python's callers do: `locked { reload(); change; save() }`.
public final class ProjectStore {
    /// Who decided an assignment, strongest first: a stronger one is never replaced by a weaker one.
    public static let STRENGTH: [String: Int] = ["you": 3, "model": 2, "auto": 1]

    public let path: URL
    /// The file's top-level keys in order ("projects" and "meetings" stand for the two below).
    private var top = PyDict<JSONValue>()
    /// id → {"name", "description", "description_by": "you" | "model" | null}, in file order.
    public private(set) var projects = PyDict<JSONValue>()
    /// meeting id → {"assigned", "rejected"}, in file order.
    private var meetings = PyDict<JSONValue>()
    /// New ids; `uuid4().hex[:8]` in Python. Replaceable for deterministic runs.
    public var makeId: () -> String = { String(format: "%08x", UInt32.random(in: 0...UInt32.max)) }

    public init(path: URL? = nil) {
        self.path = path ?? StorePaths.current().projects
        reload()
    }

    /// Read the file again: someone else may have changed it (the window while the model was thinking). A missing or
    /// broken file is an empty store.
    public func reload() {
        top = PythonJSON.read(path).flatMap { PyDict<JSONValue>($0) } ?? PyDict()
        if top["projects"] == nil { top["projects"] = .object([]) }
        if top["meetings"] == nil { top["meetings"] = .object([]) }
        projects = top["projects"].flatMap { PyDict<JSONValue>($0) } ?? PyDict()
        meetings = top["meetings"].flatMap { PyDict<JSONValue>($0) } ?? PyDict()
    }

    /// Holds the store's lock (`projects.json.lock`, the one Python takes) around `body`: reload, change, save inside it.
    /// Never around a model run.
    public func locked<T>(_ body: () throws -> T) throws -> T { try StoreLock.with(path, body) }

    public func save() throws {
        try locked {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            var out = top
            out["projects"] = projects.json
            out["meetings"] = meetings.json
            // `path.with_suffix(".json.tmp")`.
            try PythonJSON.write(out.json, to: path, indent: 2, ensureAscii: false,
                                 via: path.deletingPathExtension().lastPathComponent + ".json.tmp")
        }
    }

    // MARK: - projects

    /// The project called `name` (case and surrounding spaces aside), if any.
    public func find(_ name: String) -> String? {
        let want = Py.casefold(Py.strip(name))
        for (pid, p) in projects {
            if let n = p["name"]?.stringValue, Py.same(Py.casefold(n), want) { return pid }
        }
        return nil
    }

    /// A new project, or the one already called `name`. An empty description is the model's to write.
    @discardableResult
    public func create(_ name: String, description: String = "", by: String = "you") throws -> String {
        let name = Py.strip(name)
        guard !name.isEmpty else { throw ProjectValueError("a project needs a name") }
        if let existing = find(name), !existing.isEmpty { return existing }
        let pid = makeId()
        let text = Py.strip(description)
        projects[pid] = .object([("name", .string(name)), ("description", .string(text)),
                                 ("description_by", text.isEmpty ? .null : .string(by))])
        return pid
    }

    public func update(_ pid: String, name: String? = nil, description: String? = nil, by: String = "you") throws {
        var project = try self.project(pid)
        if let name {
            let name = Py.strip(name)
            guard !name.isEmpty else { throw ProjectValueError("a project needs a name") }
            if let other = find(name), !other.isEmpty, !Py.same(other, pid) {
                throw ProjectValueError("there is already a project called \(name)")
            }
            project["name"] = .string(name)
            projects[pid] = project.json
        }
        if let description {
            project["description"] = .string(Py.strip(description))
            project["description_by"] = .string(by)
            projects[pid] = project.json
        }
    }

    /// The project goes; its meetings are in it no more (nor taken out of it).
    public func delete(_ pid: String) throws {
        _ = try project(pid)
        projects[pid] = nil
        for (meeting, value) in meetings {
            guard var entry = PyDict<JSONValue>(value) else { continue }
            var changed = false
            if var assigned = entry["assigned"].flatMap({ PyDict<JSONValue>($0) }), assigned.removeValue(forKey: pid) != nil {
                entry["assigned"] = assigned.json
                changed = true
            }
            if var rejected = entry["rejected"]?.arrayValue, let i = Self.index(of: pid, in: rejected) {
                rejected.remove(at: i)
                entry["rejected"] = .array(rejected)
                changed = true
            }
            if changed { meetings[meeting] = entry.json }
        }
    }

    /// `pid` and `into` are the same project: keep `into`. Each meeting keeps the stronger of its two assignments; one
    /// the user took out of `into` stays out.
    public func merge(_ pid: String, into: String) throws {
        if Py.same(pid, into) { throw ProjectValueError("a project cannot be merged into itself") }
        let source = try project(pid)
        var target = try project(into)
        if !(target["description"]?.truthy ?? false) && (source["description"]?.truthy ?? false) {
            target["description"] = source["description"]
            target["description_by"] = source["description_by"] ?? .null
            projects[into] = target.json
        }
        for (meeting, value) in meetings {
            guard var entry = PyDict<JSONValue>(value) else { continue }
            let rejected = entry["rejected"]?.arrayValue ?? []
            if var assigned = entry["assigned"].flatMap({ PyDict<JSONValue>($0) }), let moved = assigned.removeValue(forKey: pid) {
                if moved.truthy && Self.index(of: into, in: rejected) == nil {
                    let current = assigned[into]
                    if try current == nil || Self.strength(moved["by"]) > Self.strength(current?["by"]) { assigned[into] = moved }
                }
                entry["assigned"] = assigned.json
            }
            if var list = entry["rejected"]?.arrayValue, let i = Self.index(of: pid, in: list) {
                list.remove(at: i)
                entry["rejected"] = .array(list)
            }
            meetings[meeting] = entry.json
        }
        projects[pid] = nil
    }

    private func project(_ pid: String) throws -> PyDict<JSONValue> {
        guard let p = projects[pid] else { throw ProjectLookupError(pid) }
        return PyDict<JSONValue>(p) ?? PyDict()
    }

    // MARK: - meetings

    /// project id → {"by", "why", "confidence"?} for `meeting`.
    public func ofMeeting(_ meeting: String) -> PyDict<JSONValue> {
        meetings[meeting]?["assigned"].flatMap { PyDict<JSONValue>($0) } ?? PyDict()
    }

    /// The projects the user took `meeting` out of.
    public func rejected(_ meeting: String) -> [String] {
        (meetings[meeting]?["rejected"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    /// meeting id → {"by", "why", "confidence"?} for project `pid`, in the file's order of meetings.
    public func meetingsOf(_ pid: String) -> PyDict<JSONValue> {
        var out = PyDict<JSONValue>()
        for (meeting, entry) in meetings {
            if let how = entry["assigned"]?[pid] { out[meeting] = how }
        }
        return out
    }

    /// Put `meeting` in project `pid`. Rules and the model never override the user: not an assignment, not a removal.
    /// `confidence`: how sure the rules were (their score), kept with the reason (#48). False when nothing changed.
    @discardableResult
    public func assign(_ meeting: String, _ pid: String, by: String = "you", why: String = "",
                       confidence: Double? = nil) throws -> Bool {
        _ = try project(pid)
        var entry = self.entry(meeting)
        defer { meetings[meeting] = entry.json }
        var assigned = entry["assigned"].flatMap { PyDict<JSONValue>($0) } ?? PyDict()
        var rejected = entry["rejected"]?.arrayValue ?? []
        let isRejected = Self.index(of: pid, in: rejected) != nil
        if by != "you" && isRejected { return false }
        if let current = assigned[pid], try Self.strength(current["by"]) >= Self.strength(.string(by)) { return false }
        if by == "you", let i = Self.index(of: pid, in: rejected) {
            rejected.remove(at: i)
            entry["rejected"] = .array(rejected)
        }
        var how: [(String, JSONValue)] = [("by", .string(by)), ("why", .string(why))]
        if let confidence { how.append(("confidence", .double(confidence))) }
        assigned[pid] = .object(how)
        entry["assigned"] = assigned.json
        return true
    }

    /// A recording that is gone (joined into another).
    public func forgetMeeting(_ meeting: String) { meetings[meeting] = nil }

    /// Take `meeting` out of `pid` for good.
    public func unassign(_ meeting: String, _ pid: String) {
        var entry = self.entry(meeting)
        if var assigned = entry["assigned"].flatMap({ PyDict<JSONValue>($0) }), assigned.removeValue(forKey: pid) != nil {
            entry["assigned"] = assigned.json
        }
        var rejected = entry["rejected"]?.arrayValue ?? []
        if Self.index(of: pid, in: rejected) == nil {
            rejected.append(.string(pid))
            entry["rejected"] = .array(rejected)
        }
        meetings[meeting] = entry.json
    }

    /// `_entry`: the meeting's entry with "assigned" and "rejected" added when missing (`setdefault`); the caller
    /// writes it back.
    private func entry(_ meeting: String) -> PyDict<JSONValue> {
        var entry = meetings[meeting].flatMap { PyDict<JSONValue>($0) } ?? PyDict()
        if entry["assigned"] == nil { entry["assigned"] = .object([]) }
        if entry["rejected"] == nil { entry["rejected"] = .array([]) }
        return entry
    }

    /// `list.index(pid)` by code points; nil when absent.
    private static func index(of pid: String, in list: [JSONValue]) -> Int? {
        list.firstIndex { $0.stringValue.map { Py.same($0, pid) } ?? false }
    }

    /// `STRENGTH[by]`; a decider Python does not know raises KeyError (its text: the key's repr).
    static func strength(_ by: JSONValue?) throws -> Int {
        guard let name = by?.stringValue, let n = STRENGTH.first(where: { Py.same($0.key, name) })?.value else {
            throw ProjectValueError(by.map { $0.stringValue.map { "'\($0)'" } ?? PythonJSON.dumps($0) } ?? "'by'")
        }
        return n
    }
}
