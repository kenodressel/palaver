// The live assistant (#15): on the meeting's Live view, on the user's click only, "Catch me up" (the last 5, 10 or 15
// minutes), "Next steps so far" and a free question about what was said, answered from the live transcript so far.
//
// It runs on the model the user chose for the notes (Settings → Language model), through palaver-lm (`app.assistant`,
// LMLiveAssistant), as the best next question does: a meeting kept on this Mac never goes to a cloud model, the local
// model runs only with the free memory the notes need, and during a call only after a second click. Nothing runs on its
// own. The answers are kept in the meeting's live-assistant.json for the record (a reload shows them again); the notes
// never read them.
import Foundation
import PalaverCore
import PalaverDomain

public enum LiveAssistantAPI {
    /// The model it runs on: the notes' (palaver-lm's LiveAssistant.FEATURE).
    public static let FEATURE = "notes"
    public static let FILE = "live-assistant.json"
    public static let KINDS = ["catchup", "next_steps", "ask"]
    public static let MINUTES = [5, 10, 15]
    public static let MAX_QUESTION_CHARS = 500
    /// The questions kept, the newest last.
    public static let KEEP_ASKS = 20
    static let PENDING = "No model yet: choose one for Notes in Settings → Language model."
    static let NO_QUESTION = "Type a question first."

    /// One read-change-write of a meeting's answers at a time (two cloud asks may end together).
    private static let saving = NSLock()

    static func file(_ paths: RecordingPaths) -> URL { paths.folder.appendingPathComponent(FILE) }

    /// What live-assistant.json keeps: `{"catchup": answer | null, "next_steps": answer | null, "asks": [answer…]}`.
    public static func load(_ paths: RecordingPaths) -> JSONValue {
        let kept = PythonJSON.read(file(paths))
        let one = { (key: String) -> JSONValue in kept?[key].flatMap { $0.isObject ? $0 : nil } ?? .null }
        return .object([("catchup", one("catchup")), ("next_steps", one("next_steps")),
                        ("asks", .array((kept?["asks"]?.arrayValue ?? []).filter(\.isObject)))])
    }

    /// `answer` kept as the newest of its kind.
    static func keep(_ paths: RecordingPaths, _ answer: JSONValue, kind: String) throws -> JSONValue {
        try saving.withLock {
            guard var all = PyDict<JSONValue>(load(paths)) else { return .null }
            if kind == "ask" {
                all["asks"] = .array(Array(((all["asks"]?.arrayValue ?? []) + [answer]).suffix(KEEP_ASKS)))
            } else {
                all[kind] = answer
            }
            try PythonJSON.write(all.json, to: file(paths), indent: 2, ensureAscii: false, via: FILE + ".tmp")
            return all.json
        }
    }

    /// The panel's model line: which model answers and where ("Claude Opus 5.5, cloud"), whether it can (`reason` when
    /// not), and the warning a local model during the call needs a second click for.
    public static func info(_ app: ServerApp, id: String) throws -> JSONValue {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        let found = try NextQuestionAPI.modelWhere(app, paths, feature: FEATURE, pending: PENDING)
        return .object([("ready", .bool(found.ready)), ("reason", found.reason.map { .string($0) } ?? .null),
                        ("model", found.place.map { .string($0) } ?? .null), ("local", .bool(found.local)),
                        ("warning", found.warning.map { .string($0) } ?? .null)])
    }

    /// The panel: `info` and the answers kept for the meeting.
    public static func state(_ app: ServerApp, id: String) throws -> JSONValue {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        return .object([("info", try info(app, id: id)), ("answers", load(paths))])
    }

    /// One ask, on the user's click: `{"kind": "catchup" | "next_steps" | "ask", "minutes", "question", "confirmed"}`.
    /// The answer is kept; the panel's answers come back.
    public static func ask(_ app: ServerApp, id: String, body: JSONValue) throws -> JSONValue {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        let kind = (try PyBody.get(body, "kind"))?.stringValue ?? ""
        guard KINDS.contains(kind) else { throw Refused("Unknown kind of ask: \(Py.repr(.string(kind)))") }
        var minutes = MINUTES[0]
        if case .int(let n)? = try PyBody.get(body, "minutes"), MINUTES.contains(n) { minutes = n }
        let question = String(String.UnicodeScalarView(Py.strip((try PyBody.get(body, "question"))?.stringValue ?? "")
            .unicodeScalars.prefix(MAX_QUESTION_CHARS)))
        if kind == "ask" && question.isEmpty { throw Refused(NO_QUESTION) }
        var confirmed = false
        if case .bool(true)? = try PyBody.get(body, "confirmed") { confirmed = true }

        let info = try info(app, id: id)
        let reason = info["reason"].map(Py.str) ?? ""
        guard app.notesEnabled else { throw Unavailable(reason) }
        guard info["ready"]?.truthy ?? false else { throw Refused(reason) }
        let local = info["local"]?.truthy ?? false
        let recording = app.meetingStatus(paths) == "recording"
        if let problem = NextQuestionAPI.memoryProblem(
            local: local, freeGB: app.freeMemoryGB(),
            needGB: ModelChoice.memoryGB(feature: FEATURE, folder: paths.folder, config: app.config, stores: app.stores),
            recording: recording) { throw Refused(problem) }
        if let warning = info["warning"], warning.truthy, !confirmed { throw Conflict(Py.str(warning)) }

        let lines = try NextQuestionAPI.said(app, id: id)
        let now = try NextQuestionAPI.largest(lines.map { try MeetingsAPI.key($0, "end") })
        let inputs = JSONValue.object([
            ("kind", .string(kind)), ("user", .string(app.userName)), ("now", now), ("lines", .array(lines)),
            ("title", .str(Titles.resolve(paths, stores: app.stores).title)),
            ("minutes", .int(minutes)), ("question", .string(question)),
        ])
        if NextQuestionAPI.nothingSaid(inputs) { throw Refused(NextQuestionAPI.NOTHING_YET) }  // before a model starts
        // The local model: one at a time with the notes. A cloud model needs no turn.
        if local {
            guard app.notesLock.try() else { throw ModelBusy() }
        }
        defer { if local { app.notesLock.unlock() } }
        let out = try app.assistant.ask(meetingId: id, inputs: inputs)
        var answer: [(String, JSONValue)] = [("asked_at", .string(Py.isoNow(timespec: "seconds"))), ("until", now)]
        if kind == "catchup" { answer.append(("minutes", .int(minutes))) }
        if kind == "ask" { answer.append(("question", .string(question))) }
        let fields: [String] = kind == "catchup" ? ["bullets"] : kind == "next_steps" ? ["next_steps", "decisions"] : ["answer", "quotes"]
        for key in fields + ["engine"] { answer.append((key, out[key] ?? .null)) }
        return .object([("info", info), ("answers", try keep(paths, .object(answer), kind: kind))])
    }
}

extension Router {
    /// The live assistant (#15): its panel, and one ask.
    static func addLiveAssistantRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/meetings/([^/]+)/assistant") { _, m in .json(try LiveAssistantAPI.state(app, id: m.group(1)!)) }
        r.post("/api/meetings/([^/]+)/assistant") { req, m in
            .json(try LiveAssistantAPI.ask(app, id: m.group(1)!, body: req.json))
        }
    }
}
