// The Swift side of the `attribution` parity op (tools/parity/ops.py, section "calendar (Task 10)").
import Foundation
import PalaverCore
import PalaverDomain

/// What Python raises as KeyError, ValueError or TypeError for an event or a meeting it can't read: the window
/// answers 400 (ops.error_kind: bad_request).
struct CalendarBadRequest: ParityErrorKind, CustomStringConvertible {
    let description: String
    var parityKind: String { "bad_request" }
}

extension ParityOps {
    static let calendar: [String: Op] = ["attribution": attributionOp, "organizations": organizationsOp, "title": titleOp]

    private static func calendarEvents(_ side: ParitySide, _ args: JSONValue) throws -> [CalendarEvent] {
        try (args["events"]?.arrayValue ?? side.events).map { try CalendarEvent(json: $0) }
    }

    static func calendarEvent(_ side: ParitySide, _ ref: JSONValue) throws -> CalendarEvent {
        guard let title = ref["title"]?.stringValue else { throw BadArgs(description: "calendar: an event needs a title") }
        let start = ref["start"]?.stringValue ?? ""
        for d in side.events where d["title"]?.stringValue == title && (d["start"]?.stringValue ?? "").hasPrefix(start) {
            return try CalendarEvent(json: d)
        }
        throw BadArgs(description: "calendar: no event \(PythonJSON.dumps(ref))")
    }

    static func calendarFolder(_ side: ParitySide, _ args: JSONValue) throws -> RecordingPaths {
        let name = args["folder"]?.stringValue ?? ""
        var isDir: ObjCBool = false
        let url = side.recordings.appendingPathComponent(name)
        guard !name.isEmpty, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw NotFound(description: "no meeting \(args["folder"]?.stringValue ?? "None")")
        }
        return RecordingPaths(url)
    }

    static func attributionOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        do { return try attributionAction(side, args) }
        catch let e as Attribution.MissingKey { throw CalendarBadRequest(description: e.description) }
        catch let e as CalendarFormatError { throw CalendarBadRequest(description: e.description) }
    }

    private static func attributionAction(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let action = args["action"]?.stringValue
        func text(_ key: String) throws -> String {
            guard let s = args[key]?.stringValue else { throw Attribution.MissingKey(key: key) }
            return s
        }
        switch action {
        case "questions":
            guard let meeting = args["meeting"] else { throw Attribution.MissingKey(key: "meeting") }
            return .object([("questions", .array(try Attribution.questions(meeting)))])
        case "key-at":
            return .object([("key", .str(CalendarEvents.eventKeyAt(try calendarEvents(side, args), try PyDateTime.parse(try text("when")))))])
        case "evidence":
            let ev = Evidence(path: side.stores.attributions, outputDir: side.recordings)
            for step in args["steps"]?.arrayValue ?? [] {
                switch step["do"]?.stringValue {
                case "forget":
                    guard let series = step["series"]?.stringValue else { throw Attribution.MissingKey(key: "series") }
                    ev.forgetRule(series)
                case "reject", "confirm":
                    let event = try calendarEvent(side, step["event"] ?? .null)
                    guard let meeting = step["meeting"]?.stringValue else { throw Attribution.MissingKey(key: "meeting") }
                    if step["do"]?.stringValue == "reject" { ev.rejectEvent(event, meeting) } else { ev.confirmEvent(event, meeting) }
                default: throw BadArgs(description: "attribution evidence: unknown step")
                }
            }
            if args["save"]?.boolValue ?? true { try ev.save() }
            var checked: [JSONValue] = []
            for ref in args["check"]?.arrayValue ?? [] {
                let e = try calendarEvent(side, ref)
                checked.append(.object([("rejections", .int(ev.eventRejections(e))), ("acceptances", .int(ev.acceptances(e))),
                                        ("doubted", .int(ev.doubted(e))), ("never_by_time", .bool(ev.neverByTime(e))),
                                        ("rule", ev.rule(e)?.json ?? .null)]))
            }
            return .object([("rules", .array(ev.rules().map(\.json))), ("checked", .array(checked))])
        default: break
        }
        let paths = try calendarFolder(side, args)
        switch action {
        case "decide":
            let start: PyDateTime, end: PyDateTime
            if args["folder"] != nil && args["start"] == nil {
                (start, end) = try CalendarEvents.recordingSpan(paths)
            } else {
                start = try PyDateTime.parse(try text("start")); end = try PyDateTime.parse(try text("end"))
            }
            let evidence = args["evidence"]?.boolValue ?? true ? Evidence(path: side.stores.attributions, outputDir: side.recordings) : nil
            let d = CalendarEvents.decide(try calendarEvents(side, args), start, end, evidence: evidence)
            if args["store"]?.truthy == true {
                if let question = d.question, !question.isEmpty { try CalendarEvents.ask(paths, question) }
                else if let event = d.event { try CalendarEvents.save(paths, event, d.link) }
            }
            return .object([("event", d.event?.json ?? .null), ("link", d.link?.toDict() ?? .null),
                            ("question", d.question.map { .array($0.map(\.json)) } ?? .null)])
        case "state":
            return .object([("event", CalendarEvents.load(paths)?.json ?? .null),
                            ("link", CalendarEvents.loadLink(paths)?.toDict() ?? .null),
                            ("question", CalendarEvents.loadQuestion(paths).map { .array($0.map(\.json)) } ?? .null),
                            ("dismissed", .bool(CalendarEvents.dismissed(paths)))])
        case "dismiss":
            try CalendarEvents.dismiss(paths)
            return .object([("dismissed", .bool(CalendarEvents.dismissed(paths)))])
        case "invited":
            let known = (args["known"]?.arrayValue ?? []).compactMap(\.stringValue)
            return .object([("names", CalendarEvents.invitedNames(paths, known, userName: side.userName).map { .strings($0) } ?? .null)])
        default:
            throw BadArgs(description: "attribution: unknown action \(action.map { "'\($0)'" } ?? "None")")
        }
    }
}

// MARK: - organizations and titles (Task 11)

extension ParityOps {
    static func organizationsOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let action = args["action"]?.stringValue
        if action == "keys" {
            let rows: [JSONValue] = (args["emails"]?.arrayValue ?? []).map { e in
                let key = Orgs.orgKey(e.stringValue)
                return .object([("email", e), ("key", .str(key)),
                                ("name", .str(key.flatMap { $0.isEmpty ? nil : Orgs.defaultName($0) }))])
            }
            return .object([("keys", .array(rows))])
        }
        let index = Orgs.peopleIndex(outputDir: side.recordings)
        if action == "index" { return .object([("index", .object(zip(index.keys, index.values).map { ($0, $1) }))]) }
        let orgs = Organizations(path: side.stores.organizations)
        switch action {
        case "edit":
            for step in args["steps"]?.arrayValue ?? [] {
                switch step["do"]?.stringValue {
                case "rename": orgs.rename(step["key"]?.stringValue ?? "", step["name"]?.stringValue ?? "")
                case "person": orgs.setPerson(step["person"]?.stringValue ?? "", step["org"]?.stringValue)
                default: throw BadArgs(description: "organizations edit: unknown step")
                }
            }
            let save = args["save"]?.boolValue ?? true
            if save { try orgs.save() }
            return .object([("saved", .bool(save))])
        case "state":
            let who: [JSONValue] = (args["people"]?.arrayValue ?? []).compactMap(\.stringValue).map { person in
                .object([("person", .string(person)), ("org", .str(Orgs.orgOf(person, index, orgs))),
                         ("link", Orgs.orgLink(person, index, orgs)?.toDict() ?? .null)])
            }
            return .object([("people", .array(who)),
                            ("own", .str(Orgs.ownOrg(index, orgs, userName: args["user"]?.stringValue ?? side.userName))),
                            ("summary", .array(Orgs.summary(index, orgs))),
                            ("index", .object(zip(index.keys, index.values).map { ($0, $1) }))])
        default:
            throw BadArgs(description: "organizations: unknown action \(action.map { "'\($0)'" } ?? "None")")
        }
    }

    static func titleOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let action = args["action"]?.stringValue
        switch action {
        case "clean":
            do { return .object([("title", .string(try Titles.clean(args["text"])))]) }
            catch let e as TitleError { throw CalendarBadRequest(description: e.description) }
        case "fallback":
            return .object([("title", .string(Titles.fallback(args["start"]?.stringValue)))])
        default: break
        }
        let paths = try calendarFolder(side, args)
        switch action {
        case "save":
            do { try Titles.save(paths, try Titles.clean(args["title"])) }
            catch let e as TitleError { throw CalendarBadRequest(description: e.description) }
            return .object([("own", .str(Titles.load(paths)))])
        case "resolve":
            let r = Titles.resolve(paths, event: args["no_event"]?.truthy == true ? .known(nil) : .unread,
                                   meetingNotes: args["no_notes"]?.truthy == true ? .known(nil) : .unread, stores: side.stores)
            return .object([("title", .str(r.title)), ("source", .str(r.source)), ("own", .str(Titles.load(paths))),
                            ("imported", .str(Titles.imported(paths)))])
        default:
            throw BadArgs(description: "title: unknown action \(action.map { "'\($0)'" } ?? "None")")
        }
    }
}
