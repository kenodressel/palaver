// Sorting meetings into projects and describing a project with the language model (projects.py `suggest_with_model`,
// `describe_with_model`). The model reads what the rules could not place: each meeting's title, date, people, customers
// and summary, and the projects there are. It proposes assignments (`by: "model"`, never over the user's) and new
// projects with a description (`description_by: "model"`); a description the user wrote is never rewritten. Meetings
// kept on this Mac are left out of what a cloud model reads, and a project whose meetings are all such is hidden from it
// whole. The store is never held while the model thinks: it is read again under its lock once the model is done.
import Foundation
import PalaverCore
import PalaverDomain

public enum ProjectsPrompt {
    public static let DESCRIPTION_RULES = "At most two short sentences: what the project is about and who is involved "
        + "(at most three names). Only what the meetings show — no guessing; when they say little, say little. "
        + "Never mention the person whose meetings these are."

    public static let SCHEMA: JSONValue = try! PythonJSON.parse(Data(#"""
    {"type": "object", "properties": {
      "new_projects": {"type": "array", "description": "Projects to create: only when no existing project fits.",
        "items": {"type": "object", "properties": {
          "key": {"type": "string", "description": "A placeholder id like new1, used in assignments."},
          "name": {"type": "string", "description": "Short: the customer, initiative or topic, 1-4 words."},
          "description": {"type": "string", "description": "RULES"}},
          "required": ["key", "name", "description"]}},
      "assignments": {"type": "array", "items": {"type": "object", "properties": {
        "meeting": {"type": "string", "description": "The meeting id, exactly as given."},
        "projects": {"type": "array", "items": {"type": "string"},
          "description": "Ids of existing projects or keys of new ones. Usually one; several only when the meeting really covered several."}},
        "required": ["meeting", "projects"]}},
      "descriptions": {"type": "array",
        "description": "New descriptions for existing projects marked (description can be rewritten).",
        "items": {"type": "object", "properties": {"project": {"type": "string"}, "description": {"type": "string"}},
          "required": ["project", "description"]}}},
     "required": ["new_projects", "assignments"]}
    """#.replacingOccurrences(of: "RULES", with: DESCRIPTION_RULES).utf8))

    public static let DESCRIPTION_SCHEMA = JSONValue.object([
        ("type", .string("object")), ("properties", .object([("description", .object([("type", .string("string"))]))])),
        ("required", .strings(["description"])),
    ])

    static func prompt(user: String, projects: String, meetings: String) -> String {
        """
        You sort the meetings \(user) recorded into projects: a customer, an \
        initiative, or a recurring topic such as hiring. Prefer the existing \
        projects; create a new project only for meetings none of them fits, and \
        group meetings that belong together into the same new project. Write names \
        and descriptions in the language most of the project's meetings use. \
        Descriptions: \(DESCRIPTION_RULES)

        Existing projects:
        \(projects)

        Meetings to sort:
        \(meetings)

        """
    }

    /// `_describe`: one meeting as the model reads it.
    static func describe(_ f: ProjectFacts) -> String {
        let people = Py.stableSorted(f.people, by: Py.less).prefix(8).joined(separator: ", ")
        let day = String(String.UnicodeScalarView(f.start.unicodeScalars.prefix(10)))
        var lines = ["- id \(f.meeting): “\(f.title.isEmpty ? "untitled" : f.title)” on \(day); people: \(people.isEmpty ? "unknown" : people)"]
        if !f.orgs.isEmpty { lines.append("  customers (email domains): \(Py.stableSorted(f.orgs, by: Py.less).joined(separator: ", "))") }
        if !f.summary.isEmpty { lines.append("  summary: \(f.summary)") }
        return lines.joined(separator: "\n")
    }

    /// `parse_answer`: the object with its list of assignments; the other lists are there, empty when not given.
    public static func parseAnswer(_ text: String) throws -> JSONValue {
        guard var out = PyDict<JSONValue>(try Answer.object(text)), out["assignments"]?.arrayValue != nil else {
            throw BrokenAnswer("no assignments")
        }
        if out["new_projects"] == nil { out["new_projects"] = .array([]) }
        if out["descriptions"] == nil { out["descriptions"] = .array([]) }
        return out.json
    }

    /// cli.py `_parse_description`.
    public static func parseDescription(_ text: String) throws -> JSONValue {
        let out = try Answer.object(text)
        guard out["description"]?.stringValue != nil else { throw BrokenAnswer("no description") }
        return out
    }
}

public enum ProjectsModel {
    public typealias Run = (_ prompt: String, _ schema: JSONValue) async throws -> JSONValue

    private static func list(_ v: JSONValue?) -> [JSONValue] { v?.arrayValue ?? [] }

    /// `str(x)` of a value the model gave; "" for nothing.
    private static func text(_ v: JSONValue?) -> String { v.map { Py.str($0) } ?? "" }

    /// Asks the model to place the meetings in no project (or only `meetings`) and creates the new projects it proposes
    /// (those it then put nothing in are dropped again). `private`: meetings kept on this Mac, left out of the prompt
    /// entirely (a cloud model is asked). The (meeting, project id) pairs added.
    public static func suggest(outputDir: URL, userName: String, meetings: [String]? = nil, private hidden: Set<String> = [],
                               stores: StorePaths, run: Run) async throws -> [(String, String)] {
        let isPrivate = { (m: String) in hidden.contains(m) }
        var every = PyDict<ProjectFacts>()
        for (m, f) in try ProjectRules.allFacts(outputDir: outputDir, userName: userName, stores: stores) where !isPrivate(m) {
            every[m] = f
        }
        let store = ProjectStore(path: stores.projects)
        let todo = (meetings ?? every.keys).compactMap { m in store.ofMeeting(m).isEmpty ? every[m] : nil }
        if todo.isEmpty { return [] }
        // A project whose meetings are all private is left out whole: its name and description were drawn from them.
        let hiddenProjects = Set(store.projects.keys.filter { pid in
            let ms = store.meetingsOf(pid).keys
            return !ms.isEmpty && ms.allSatisfy(isPrivate)
        }.map(ScalarKey.init))
        var shown: [String] = []
        for (pid, p) in store.projects where !hiddenProjects.contains(ScalarKey(pid)) {
            let sample = store.meetingsOf(pid).keys.compactMap { every[$0]?.title }.prefix(5)
            let rewrite = p["description_by"]?.stringValue == "you" ? "" : " (description can be rewritten)"
            let description = text(p["description"])
            shown.append("- id \(pid): \(text(p["name"])) — \(description.isEmpty ? "no description yet" : description)\(rewrite)"
                         + (sample.isEmpty ? "" : "\n  meetings: \(sample.joined(separator: "; "))"))
        }
        // No save before the model: a write of this process's older copy would undo changes made since.
        let answer = try await run(ProjectsPrompt.prompt(user: userName, projects: shown.isEmpty ? "(none yet)" : shown.joined(separator: "\n"),
                                                         meetings: todo.map(ProjectsPrompt.describe).joined(separator: "\n")),
                                   ProjectsPrompt.SCHEMA)
        // The model is done: read the store again under the lock (it may have changed meanwhile), apply, save.
        return try store.locked {
            store.reload()
            var created = PyDict<String>()
            for p in list(answer["new_projects"]) where p.isDict && !Py.strip(text(p["name"])).isEmpty {
                created[text(p["key"])] = try store.create(text(p["name"]), description: text(p["description"]), by: "model")
            }
            for d in list(answer["descriptions"]) where d.isDict {
                let pid = text(d["project"])
                if let project = store.projects[pid], !hiddenProjects.contains(ScalarKey(pid)),
                   project["description_by"]?.stringValue != "you" {
                    try store.update(pid, description: text(d["description"]), by: "model")
                }
            }
            let asked = Set(todo.map { ScalarKey($0.meeting) })
            var added: [(String, String)] = []
            for a in list(answer["assignments"]) where a.isDict {
                let mid = text(a["meeting"])
                guard asked.contains(ScalarKey(mid)) else { continue }
                for ref in list(a["projects"]) {
                    let pid = created[text(ref)] ?? text(ref)
                    if store.projects[pid] != nil, !hiddenProjects.contains(ScalarKey(pid)),
                       try store.assign(mid, pid, by: "model", why: "suggested by the model") {
                        added.append((mid, pid))
                    }
                }
            }
            for pid in created.values where store.meetingsOf(pid).isEmpty && store.projects[pid] != nil {
                try store.delete(pid)  // proposed, but nothing put in: noise
            }
            try store.save()
            return added
        }
    }

    /// (Re)writes project `pid`'s description from its meetings, except the `private` ones; with nothing else to go on
    /// the model is not asked. The description as it is then ("" when the project was deleted meanwhile).
    public static func describe(outputDir: URL, pid: String, userName: String, private hidden: Set<String> = [],
                                stores: StorePaths, run: Run) async throws -> String {
        let every = try ProjectRules.allFacts(outputDir: outputDir, userName: userName, stores: stores)
        let store = ProjectStore(path: stores.projects)
        guard let project = store.projects[pid] else { return "" }
        let meetings = store.meetingsOf(pid).keys.filter { !hidden.contains($0) }.compactMap { every[$0] }
            .map(ProjectsPrompt.describe).joined(separator: "\n")
        if meetings.isEmpty { return text(project["description"]) }
        let answer = try await run(
            "Describe the project “\(text(project["name"]))” from the meetings \(userName) recorded in it. "
                + "\(ProjectsPrompt.DESCRIPTION_RULES) Write in the language most of the meetings use. Its meetings:\n\(meetings)",
            ProjectsPrompt.DESCRIPTION_SCHEMA)
        return try store.locked {
            store.reload()
            guard store.projects[pid] != nil else { return "" }  // deleted meanwhile
            try store.update(pid, description: text(answer["description"]), by: "model")
            try store.save()
            return text(store.projects[pid]?["description"])
        }
    }
}
