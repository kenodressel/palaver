// The Swift side of the `projects`, `prep` and `calendar-attach` parity ops (tools/parity/ops.py, section "projects
// (Task 15)").
import Foundation
import PalaverCore
import PalaverDomain

/// Python's `ValueError` (and `KeyError`) of the projects: the window answers 400.
extension ProjectValueError: ParityErrorKind {
    var parityKind: String { "bad_request" }
}

extension ParityOps {
    static let projects: [String: Op] = ["projects": projectsOp, "prep": prepOp, "calendar-attach": calendarAttachOp]

    /// A project a step names: its id, else its name.
    private static func projectRef(_ store: ProjectStore, _ ref: JSONValue?) -> String {
        let ref = ref?.stringValue ?? ref.map { PythonJSON.dumps($0) } ?? "None"
        return store.projects[ref] != nil ? ref : (store.find(ref) ?? ref)
    }

    private static func factsJSON(_ f: ProjectFacts) -> JSONValue {
        .object([("meeting", .string(f.meeting)), ("title", .string(f.title)), ("start", .string(f.start)),
                 ("people", .strings(f.people)), ("orgs", .strings(f.orgs)), ("words", .strings(f.words)),
                 ("summary", .string(f.summary)), ("series", .string(f.series))])
    }

    /// The fake calendar (events.json) as EventKit answers it: the events overlapping the window asked for.
    static func provider(_ side: ParitySide) throws -> CalendarProvider {
        let events = try side.events.map { try CalendarEvent(json: $0) }
        return { start, end in
            let from = PyDateTime(start, offset: 0), to = PyDateTime(end, offset: 0)
            return events.filter { $0.start < to && $0.end > from }
        }
    }

    private static func now(_ side: ParitySide, _ args: JSONValue) throws -> PyDateTime {
        if let text = args["now"]?.stringValue { return try PyDateTime.parse(text) }
        if let before = args["now"]?["before"], case .object = before {
            let hours = args["now"]?["hours"]?.doubleValue ?? 2
            return try calendarEvent(side, before).start.adding(seconds: -hours * 3600)
        }
        throw BadArgs(description: "prep needs now")
    }

    static func projectsOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let action = args["action"]?.stringValue
        let store = ProjectStore(path: side.stores.projects)
        let user = args["user"]?.stringValue ?? side.userName
        func text(_ step: JSONValue, _ key: String) throws -> String {
            guard let s = step[key]?.stringValue else { throw BadArgs(description: "projects: \(key) is missing") }
            return s
        }
        switch action {
        case "edit":
            func runSteps() throws -> [JSONValue] {
                var results: [JSONValue] = []
                for step in args["steps"]?.arrayValue ?? [] {
                    switch step["do"]?.stringValue {
                    case "create":
                        results.append(.string(try store.create(try text(step, "name"), description: step["description"]?.stringValue ?? "",
                                                                by: step["by"]?.stringValue ?? "you")))
                    case "update":
                        try store.update(projectRef(store, step["project"]), name: step["name"]?.stringValue,
                                         description: step["description"]?.stringValue, by: step["by"]?.stringValue ?? "you")
                        results.append(.null)
                    case "delete":
                        try store.delete(projectRef(store, step["project"]))
                        results.append(.null)
                    case "merge":
                        try store.merge(projectRef(store, step["project"]), into: projectRef(store, step["into"]))
                        results.append(.null)
                    case "assign":
                        results.append(.bool(try store.assign(try text(step, "meeting"), projectRef(store, step["project"]),
                                                              by: step["by"]?.stringValue ?? "you", why: step["why"]?.stringValue ?? "",
                                                              confidence: step["confidence"]?.doubleValue)))
                    case "unassign":
                        store.unassign(try text(step, "meeting"), projectRef(store, step["project"]))
                        results.append(.null)
                    case "forget":
                        store.forgetMeeting(try text(step, "meeting"))
                        results.append(.null)
                    default:
                        throw BadArgs(description: "projects edit: unknown step")
                    }
                }
                return results
            }
            if args["save"]?.boolValue == false { return .object([("results", .array(try runSteps()))]) }
            let results = try store.locked {
                store.reload()
                let results = try runSteps()
                try store.save()
                return results
            }
            return .object([("results", .array(results))])
        case "state":
            let meetings: [(String, JSONValue)] = (args["meetings"]?.arrayValue ?? []).compactMap(\.stringValue).map { m in
                (m, .object([("assigned", store.ofMeeting(m).json), ("rejected", .strings(store.rejected(m)))]))
            }
            return .object([("projects", store.projects.json), ("meetings", .object(meetings)),
                            ("of", .object(store.projects.keys.map { ($0, store.meetingsOf($0).json) }))])
        case "facts":
            let every = try ProjectRules.allFacts(outputDir: side.recordings, userName: user, stores: side.stores)
            return .object([("facts", .object(zip(every.keys, every.values).map { ($0, factsJSON($1)) }))])
        case "rules":
            let meetings = args["meetings"]?.arrayValue?.compactMap(\.stringValue)
            let added = try ProjectRules.assignByRules(outputDir: side.recordings, userName: user, meetings: meetings,
                                                       stores: side.stores).added
            return .object([("added", .array(added.map { .strings([$0.0, $0.1]) }))])
        case "scores", "suggestions":
            let every = try ProjectRules.allFacts(outputDir: side.recordings, userName: user, stores: side.stores)
            let meeting = try text(args, "meeting")
            if action == "suggestions" {
                return .object([("suggestions", .array(ProjectRules.suggestions(meeting, store: store, every: every)))])
            }
            guard let facts = every[meeting] else { throw ProjectValueError("'\(meeting)'") }  // Python's KeyError
            let scores = ProjectRules.scores(facts, store, every, Similarity(every))
            return .object([("scores", .array(scores.map { .array([.string($0.pid), .double(Py.round($0.score, 12)), .string($0.why)]) }))])
        default:
            throw BadArgs(description: "projects: unknown action \(action.map { "'\($0)'" } ?? "None")")
        }
    }

    static func prepOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let action = args["action"]?.stringValue
        switch action {
        case "upcoming":
            return .object([("upcoming", .array(try Prep.upcoming(provider: provider(side), now: now(side, args)).map(\.json)))])
        case "find":
            guard let key = args["key"]?.stringValue else { throw BadArgs(description: "prep find needs key") }
            return .object([("event", try Prep.find(provider: provider(side), key: key, now: now(side, args))?.json ?? .null)])
        default: break
        }
        let event = try calendarEvent(side, args["event"] ?? .null)
        let user = args["user"]?.stringValue ?? side.userName
        switch action {
        case "chosen":
            return .object([("chosen", .strings(Prep.chosen(event, stores: side.stores)))])
        case "choose":
            let project = projectRef(ProjectStore(path: side.stores.projects), args["project"])
            try Prep.choose(event, project, remove: args["remove"]?.truthy ?? false, stores: side.stores)
            return .object([("chosen", .strings(Prep.chosen(event, stores: side.stores)))])
        case "apply":
            return .object([("added", .strings(try Prep.apply(try calendarFolder(side, args), event: event, stores: side.stores)))])
        case "suggestions":
            return .object([("suggestions", .array(try Prep.suggestions(event, outputDir: side.recordings, userName: user, stores: side.stores)))])
        case "context":
            return .object([("context", .array(try Prep.context(event, outputDir: side.recordings, userName: user, stores: side.stores)))])
        default:
            throw BadArgs(description: "prep: unknown action \(action.map { "'\($0)'" } ?? "None")")
        }
    }

    static func calendarAttachOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let action = args["action"]?.stringValue
        if action == "attach-all" {
            var since: PyDateTime?
            if let text = args["since"]?.stringValue, !text.isEmpty { since = try PyDateTime.parse(text) }
            return .object([("found", .int(try CalendarEvents.attachAll(outputDir: side.recordings, provider: provider(side),
                                                                       since: since, stores: side.stores)))])
        }
        let paths = try calendarFolder(side, args)
        switch action {
        case "attach":
            let (start, end) = try CalendarEvents.recordingSpan(paths)
            let event = try CalendarEvents.attach(paths, provider: provider(side), start: start, end: end, stores: side.stores)
            return .object([("event", event?.json ?? .null)])
        case "assign":
            var link: Link?
            if let l = args["link"], case .object = l {
                link = Link(l["kind"]?.stringValue ?? "", l["target"]?.stringValue ?? "", l["source"]?.stringValue ?? "unknown",
                            l["confidence"]?.doubleValue, l["reason"]?.stringValue ?? "")
            }
            try CalendarEvents.assign(paths, try calendarEvent(side, args["event"] ?? .null), link: link, stores: side.stores)
            return .object([("event", CalendarEvents.load(paths)?.json ?? .null)])
        default:
            throw BadArgs(description: "calendar-attach: unknown action \(action.map { "'\($0)'" } ?? "None")")
        }
    }
}
