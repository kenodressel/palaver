// Follow-ups after a call (#18): the next steps into Todoist or a Notion to-do database, and the recap email
// (RecapEmail.swift). Nothing here happens by itself: each is a button on the meeting's page.
//
// By default only the user's own next steps go (the owner is the user's name or one of their earlier names); the
// others' on request. follow-ups.json in the meeting's folder remembers which step went where, so pressing again adds
// only the new ones and the page says "Added to Todoist ✓". A step is known by its owner and text as notes.json has
// them (before names are swapped in), so naming a speaker later doesn't make their steps new. Todoist and Notion are
// cloud services: a meeting kept on this Mac (#53) sends them nothing.
//
// Tokens are read for the request only (the environment, config.toml, the Keychain: `Tokens.value`) and never shown,
// logged or answered.
import CryptoKit
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

public enum FollowUps {
    /// In the meeting's folder: `{target: {step key: {task, owner, id, url, added_at}}}`.
    public static let FILE = "follow-ups.json"
    /// settings.json: the Todoist project tasks go to (`{"id", "name"}`; none: the Inbox).
    public static let TODOIST_PROJECT = "todoist_project"
    /// settings.json: the Notion to-do database's id.
    public static let NOTION_DATABASE = "notion_tasks_database"
    /// The targets, in the page's order.
    public static let TARGETS = [TodoistClient.NAME.lowercased(), "notion"]
    static let LABELS = ["todoist": TodoistClient.NAME, "notion": "Notion"]
    /// The most a press waits for the service.
    static let TIMEOUT = 120.0
    /// One press at a time: two would both find a step new.
    static let lock = NSLock()

    // MARK: - the steps

    struct Step: Equatable, Sendable {
        let key: String
        let task: String
        let owner: String
        let mine: Bool
    }

    /// The meeting's next steps as the page shows them (`shown`: notes with names and glossary), each keyed by what
    /// notes.json says (`stored`, same order) and marked when it is the user's.
    static func steps(shown: JSONValue?, stored: JSONValue?, me: Set<String>) -> [Step] {
        let list = shown?["next_steps"]?.arrayValue ?? []
        let raw = stored?["next_steps"]?.arrayValue ?? []
        return list.enumerated().compactMap { i, s in
            guard case .object = s, let task = s["task"]?.stringValue.map(Py.strip), !task.isEmpty else { return nil }
            let owner = Py.strip(s["owner"]?.stringValue ?? "")
            let source = i < raw.count ? raw[i] : s
            return Step(key: key(owner: source["owner"]?.stringValue ?? owner, task: source["task"]?.stringValue ?? task),
                        task: task, owner: owner, mine: isMine(owner, me: me))
        }
    }

    /// The user's: the owner, or one of several owners ("Valerie and Kim"), is one of the user's names (casefolded) or
    /// the first name of one.
    static func isMine(_ owner: String, me: Set<String>) -> Bool {
        let firstNames = Set(me.compactMap { Py.split($0).first }.filter { !$0.isEmpty })
        let parts = owner.components(separatedBy: CharacterSet(charactersIn: ",&+/")).flatMap { part in
            part.replacingOccurrences(of: " and ", with: "\u{0}").replacingOccurrences(of: " und ", with: "\u{0}")
                .components(separatedBy: "\u{0}")
        }
        return parts.map { Py.casefold(Py.strip($0)) }.contains { !$0.isEmpty && (me.contains($0) || firstNames.contains($0)) }
    }

    /// A step's key: sha256 of its owner and text, the first 16 hex digits.
    static func key(owner: String, task: String) -> String {
        SHA256.hash(data: Data("\(Py.strip(owner))\t\(Py.strip(task))".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - what went where

    static func file(_ paths: RecordingPaths) -> URL { paths.folder.appendingPathComponent(FILE) }

    /// follow-ups.json: target → the keys sent there (an entry each).
    static func sent(_ paths: RecordingPaths) -> [String: PyDict<JSONValue>] {
        guard let all = PythonJSON.read(file(paths)).flatMap({ PyDict<JSONValue>($0) }) else { return [:] }
        var out: [String: PyDict<JSONValue>] = [:]
        for (target, v) in all { if let steps = PyDict<JSONValue>(v) { out[target] = steps } }
        return out
    }

    static func record(_ paths: RecordingPaths, target: String, step: Step, added: AddedTask, now: Date = Date()) throws {
        var all = PythonJSON.read(file(paths)).flatMap { PyDict<JSONValue>($0) } ?? PyDict()
        var steps = all[target].flatMap { PyDict<JSONValue>($0) } ?? PyDict()
        steps[step.key] = .object([("task", .string(step.task)), ("owner", .string(step.owner)), ("id", .string(added.id)),
                                   ("url", .str(added.url)), ("added_at", .string(Py.isoNow(timespec: "seconds", now: now)))])
        all[target] = steps.json
        try PythonJSON.write(all.json, to: file(paths), indent: 2, ensureAscii: false, via: "\(FILE).tmp")
    }

    // MARK: - the targets

    /// A token for the request only (the environment, config.toml, the Keychain); nil when there is none.
    static func token(_ app: ServerApp, _ name: String) -> String? {
        guard let config = app.configToml else { return app.env[name].flatMap { $0.isEmpty ? nil : $0 } ?? ((try? app.keys?.read(name)) ?? nil) }
        return Tokens.value(name, configToml: config, env: app.env, keys: app.keys ?? NoKeys())
    }

    /// Whether there is a token, without reading a secret.
    static func hasToken(_ app: ServerApp, _ name: String) -> Bool {
        if let v = app.env[name], !v.isEmpty { return true }
        if let config = app.configToml, Tokens.present(name, configToml: config, env: app.env, keys: app.keys ?? NoKeys()) { return true }
        return app.keys?.has(name) ?? false
    }

    static func todoistProject(_ app: ServerApp) -> (id: String, name: String)? {
        let v = SettingsFile.readRaw(stores: app.stores)[TODOIST_PROJECT]
        guard let id = v?["id"]?.stringValue, !id.isEmpty else { return nil }
        return (id, v?["name"]?.stringValue ?? "")
    }

    static func notionDatabase(_ app: ServerApp) -> String? {
        SettingsFile.readRaw(stores: app.stores)[NOTION_DATABASE]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Why `target` can't take tasks now; nil: it can.
    static func problem(_ app: ServerApp, _ target: String) -> String? {
        switch target {
        case "todoist":
            return hasToken(app, Tokens.TODOIST) ? nil : "No Todoist token yet: add one in Settings → Follow-ups"
        case "notion":
            if notionDatabase(app) == nil { return "No Notion to-do database yet: choose one in Settings → Follow-ups" }
            return hasToken(app, Tokens.NOTION) ? nil : "No Notion token: Palaver needs one to write to Notion"
        default:
            return "no follow-up target \(Py.repr(.string(target)))"
        }
    }

    static func makeTarget(_ app: ServerApp, _ target: String) throws -> TaskTarget {
        if let why = problem(app, target) { throw Refused(why) }
        switch target {
        case "todoist":
            guard let token = token(app, Tokens.TODOIST) else { throw Refused("No Todoist token yet: add one in Settings → Follow-ups") }
            return TodoistClient(token: token, projectId: todoistProject(app)?.id, base: app.todoistBase, http: app.followUpHTTP)
        default:
            guard let token = token(app, Tokens.NOTION) else { throw Refused("No Notion token: Palaver needs one to write to Notion") }
            return NotionTaskDatabase(client: NotionClient(token: token, base: app.notionBase, http: app.followUpHTTP),
                                      databaseId: notionDatabase(app)!)
        }
    }

    // MARK: - the meeting's follow-ups

    struct Meeting {
        let paths: RecordingPaths
        let page: JSONValue
        let steps: [Step]
        let localOnly: Bool
    }

    static func meeting(_ app: ServerApp, _ id: String) throws -> Meeting {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        let page = try MeetingsAPI.getMeeting(app: app, id: id, calendar: false)
        let me = SettingsFile.me(userName: app.userName, stores: app.stores)
        return Meeting(paths: paths, page: page, steps: steps(shown: page["notes"], stored: Notes.load(paths), me: me),
                       localOnly: LocalOnly.isLocalOnly(paths.folder))
    }

    /// The meeting page's follow-ups: the recap's addressees, the steps (whose, where they went), and per target
    /// whether it is set up and how many steps are new for it, the user's own and all.
    public static func status(_ app: ServerApp, id: String) throws -> JSONValue {
        status(app, try meeting(app, id))
    }

    static func status(_ app: ServerApp, _ m: Meeting) -> JSONValue {
        let done = sent(m.paths)
        let steps: [JSONValue] = m.steps.map { s in
            .object([("task", .string(s.task)), ("owner", .string(s.owner)), ("mine", .bool(s.mine)),
                     ("sent", .strings(TARGETS.filter { done[$0]?[s.key] != nil }))])
        }
        let targets: [JSONValue] = TARGETS.map { t in
            let fresh = m.steps.filter { done[t]?[$0.key] == nil }
            var fields: [(String, JSONValue)] = [
                ("id", .string(t)), ("label", .string(LABELS[t]!)), ("problem", .str(problem(app, t))),
                ("sent", .int(m.steps.filter { done[t]?[$0.key] != nil }.count)),
                ("new_mine", .int(fresh.filter(\.mine).count)), ("new_all", .int(fresh.count)),
            ]
            if t == "todoist", let project = todoistProject(app) { fields.append(("project", .string(project.name))) }
            return .object(fields)
        }
        let event = CalendarEvents.load(m.paths)
        let me = SettingsFile.me(userName: app.userName, stores: app.stores)
        return .object([
            ("has_notes", .bool(m.page["notes"]?.truthy ?? false)),
            ("local_only", .bool(m.localOnly)),
            ("recap_to", .strings(RecapEmail.recipients(event, me: me).map { $0.name.isEmpty ? $0.email : $0.name })),
            ("steps", .array(steps)),
            ("mine", .int(m.steps.filter(\.mine).count)),
            ("targets", .array(targets)),
        ])
    }

    /// The meeting's line in a task: "Budget review, 2026-10-29".
    static func meetingLine(_ page: JSONValue) -> String {
        let start = page["start"]?.stringValue ?? ""
        let title = (page["title"]?.stringValue).flatMap { $0.isEmpty ? nil : $0 } ?? Titles.fallback(start)
        return start.count >= 10 ? "\(title), \(start.prefix(10))" : title
    }

    /// Sends the steps not sent to `target` yet: the user's own, with `others` everyone's. The status after, with how
    /// many were added. A failure part-way keeps what went through (it isn't sent again) and says how far it got.
    public static func send(_ app: ServerApp, id: String, target: String, others: Bool) throws -> JSONValue {
        guard let label = LABELS[target] else { throw NotFound("no follow-up target \(target)") }
        return try lock.withLock {
            let m = try meeting(app, id)
            if m.localOnly { throw Refused("This meeting is kept on this Mac, so its next steps don't go to \(label).") }
            guard m.page["notes"]?.truthy ?? false else { throw Refused("This meeting has no notes yet.") }
            let done = sent(m.paths)[target]
            let fresh = m.steps.filter { (others || $0.mine) && done?[$0.key] == nil }
            if fresh.isEmpty { return withAdded(status(app, m), 0) }
            let destination = try makeTarget(app, target)
            let start = m.page["start"]?.stringValue ?? ""
            let line = meetingLine(m.page)
            let link = NotionSync.info(m.paths)?.url  // the meeting's Notion page, when it was uploaded (#34)
            let tasks = fresh.map { s in
                FollowUpTask(text: s.task, owner: s.mine ? nil : s.owner, due: DueDates.find(s.task, meeting: start),
                             meeting: line, link: link)
            }
            let count = Counter()
            let paths = m.paths
            do {
                try runBlocking(timeout: TIMEOUT) {
                    try await destination.add(tasks) { i, added in
                        try record(paths, target: target, step: fresh[i], added: added)
                        count.add()
                    }
                }
            } catch {
                let why: String
                switch error {
                case let e as CloudError: why = e.message
                case let e as NotionError: why = e.description
                case let e as TimedOut: why = "\(label) gave \(e)"
                default: why = HTTPClient.redactedDescription(error, key: nil)
                }
                app.log?.message("follow-ups: \(target) for \(id): \(count.value) of \(tasks.count) added: \(why)",
                                 level: "WARNING", logger: "palaver.follow-ups")
                throw BadGateway(count.value == 0 ? why : "\(count.value) of \(tasks.count) added to \(label), then: \(why)")
            }
            return withAdded(status(app, try meeting(app, id)), count.value)
        }
    }

    static func withAdded(_ status: JSONValue, _ n: Int) -> JSONValue {
        guard case .object(var fields) = status else { return status }
        fields.append(("added", .int(n)))
        return .object(fields)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    // MARK: - Settings → Follow-ups

    /// What the pane shows: whether a token is set (never the token), the project, the database.
    public static func settings(_ app: ServerApp) -> JSONValue {
        let project = todoistProject(app)
        return .object([
            ("todoist", .object([
                ("token_set", .bool(hasToken(app, Tokens.TODOIST))),
                // Saved here, so Remove can take it out (one in config.toml or the environment stays there).
                ("token_saved", .bool(app.keys?.has(Tokens.TODOIST) ?? false)),
                ("project", project.map { .object([("id", .string($0.id)), ("name", .string($0.name))]) } ?? .null),
            ])),
            ("notion", .object([
                ("token_set", .bool(hasToken(app, Tokens.NOTION))),
                ("database", .string(notionDatabase(app) ?? "")),
            ])),
        ])
    }

    /// `{"todoist_token"}` saves the token in the Keychain, `{"todoist_token_remove": true}` takes it out,
    /// `{"todoist_project": {"id", "name"} | null}` chooses the project, `{"notion_database": link or id | ""}` the
    /// database. The pane's answer after.
    public static func setSettings(_ app: ServerApp, _ body: JSONValue) throws -> JSONValue {
        guard case .object = body else { throw BadRequest("an object, please") }
        if let value = body["todoist_token"] {
            guard let keys = app.keys else { throw Refused("There is no Keychain to save the token in") }
            let token: String
            do {
                token = try APIKey.checked(value.stringValue ?? "")
            } catch let e as KeyRefused {
                throw Refused("Token not saved: \(e.text)")
            }
            do { try keys.write(Tokens.TODOIST, token) } catch { throw Refused("Token not saved: could not save it in the Keychain") }
        }
        if body["todoist_token_remove"]?.truthy == true {
            do { try app.keys?.delete(Tokens.TODOIST) } catch { throw Refused("Token not removed: \(error)") }
        }
        if let project = body["todoist_project"] {
            if case .object = project, let pid = project["id"].map(Py.str), !pid.isEmpty {
                try SettingsFile.update([(TODOIST_PROJECT, .object([("id", .string(pid)),
                                                                     ("name", .string(project["name"]?.stringValue ?? ""))]))],
                                        stores: app.stores)
            } else {
                try SettingsFile.update([(TODOIST_PROJECT, .null)], stores: app.stores)
            }
        }
        if let value = body["notion_database"] {
            let text = Py.strip(value.stringValue ?? "")
            guard text.isEmpty || NotionTaskDatabase.databaseId(text) != nil else {
                throw Refused("That is no Notion database link or id")
            }
            try SettingsFile.update([(NOTION_DATABASE, .string(text.isEmpty ? "" : NotionTaskDatabase.databaseId(text)!))],
                                    stores: app.stores)
        }
        return settings(app)
    }

    /// The pane's Check: Todoist's projects (for the picker), or what the Notion database is and which columns a task
    /// fills. Refused (400) without a token or database; Bad Gateway (502) with why the service said no.
    public static func check(_ app: ServerApp, target: String) throws -> JSONValue {
        let destination = try makeTarget(app, target)
        do {
            if let todoist = destination as? TodoistClient {
                let projects = try runBlocking(timeout: TIMEOUT) { try await todoist.projects() }
                let n = projects.count
                return .object([
                    ("text", .string("Connected to Todoist: \(n) project\(n == 1 ? "" : "s").")),
                    ("projects", .array(projects.map {
                        .object([("id", .string($0.id)), ("name", .string($0.name)), ("inbox", .bool($0.inbox))])
                    })),
                ])
            }
            let database = destination as! NotionTaskDatabase
            let info = try runBlocking(timeout: TIMEOUT) { try await database.check() }
            return .object([("text", .string(checkText(info))), ("title", .string(info.title))])
        } catch let e as CloudError {
            throw BadGateway(e.message)
        } catch let e as NotionError {
            throw BadGateway(e.description)
        } catch let e as TimedOut {
            throw BadGateway("\(LABELS[target] ?? target) gave \(e)")
        }
    }

    /// "“Tasks” is ready: a step goes into Name, its due date into Due, the meeting into Meeting."
    static func checkText(_ info: NotionTaskDatabase.Info) -> String {
        var into = ["a step goes into \(info.titleColumn)"]
        if let c = info.due { into.append("its due date into \(c)") }
        if let c = info.owner { into.append("whose it is into \(c)") }
        if let c = info.meeting { into.append("the meeting into \(c)") }
        if let c = info.link { into.append("the meeting's link into \(c)") }
        let list = into.count == 1 ? into[0] : into.dropLast().joined(separator: ", ") + " and " + into.last!
        return "“\(info.title)” is ready: \(list)."
    }
}

/// No Keychain: no token is there, none can be saved.
final class NoKeys: KeyStore, @unchecked Sendable {
    func has(_ account: String) -> Bool { false }
    func read(_ account: String) throws -> String? { nil }
    func write(_ account: String, _ value: String) throws { throw KeychainError("no Keychain") }
    func delete(_ account: String) throws {}
}

extension Router {
    /// The meeting page's follow-ups and Settings → Follow-ups (#18).
    static func addFollowUpRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/meetings/([^/]+)/follow-ups") { _, m in .json(try FollowUps.status(app, id: m.group(1)!)) }
        r.post("/api/meetings/([^/]+)/follow-ups/([a-z]+)") { req, m in
            .json(try FollowUps.send(app, id: m.group(1)!, target: m.group(2)!,
                                     others: try ChangesAPI.flag(req.json, "others", default: false)))
        }
        r.post("/api/meetings/([^/]+)/recap-email") { _, m in .json(try RecapEmail.open(app, id: m.group(1)!)) }
        r.get("/api/follow-ups") { _, _ in .json(FollowUps.settings(app)) }
        r.post("/api/follow-ups") { req, _ in .json(try FollowUps.setSettings(app, req.json)) }
        r.post("/api/follow-ups/check") { req, _ in
            guard let target = req.json["target"]?.stringValue else { throw BadRequest("target is todoist or notion") }
            return .json(try FollowUps.check(app, target: target))
        }
    }
}
