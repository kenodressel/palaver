// Next steps out of Palaver (#18): a meeting's tasks into the to-do service the user set up, Todoist or a Notion to-do
// database. Only ever when the user presses the meeting's button, never by itself. Each service is a `TaskTarget`, so
// another one (Reminders, Microsoft To Do, Linear) is one more type here.
//
// The token goes only to its service and is never shown, logged or put into an error (`HTTPClient.redact`). A task
// is sent once: a create that may have arrived is not sent again (`idempotent: false`), so a flaky line can't leave
// the same task twice in the list.
import Foundation
import PalaverCore
import PalaverDomain

/// One next step as it goes out.
public struct FollowUpTask: Equatable, Sendable {
    /// The step itself.
    public var text: String
    /// Whose it is, when it isn't the user's own (nil: the user's, or nobody's).
    public var owner: String?
    /// The day it is due (YYYY-MM-DD), when the step said one.
    public var due: String?
    /// The meeting it came from, as a line: "Budget review, 2026-10-29".
    public var meeting: String
    /// A link to the meeting, when there is one (its Notion page).
    public var link: String?

    public init(text: String, owner: String? = nil, due: String? = nil, meeting: String, link: String? = nil) {
        self.text = text
        self.owner = owner.flatMap { $0.isEmpty ? nil : $0 }
        self.due = due
        self.meeting = meeting
        self.link = link
    }

    /// The task's title: the step, with the owner in front when it is someone else's.
    public var title: String { owner.map { "\($0): \(text)" } ?? text }

    /// Where it came from, for the task's description.
    public var reference: String {
        "From the meeting “\(meeting)” (Palaver)" + (link.map { "\n\($0)" } ?? "")
    }
}

/// A task the service made: its id there and, when it gave one, its address.
public struct AddedTask: Equatable, Sendable {
    public let id: String
    public let url: String?
    public init(id: String, url: String?) { self.id = id; self.url = url }
}

/// Where next steps go.
public protocol TaskTarget: Sendable {
    /// "todoist", "notion": the key of what was sent where (follow-ups.json).
    var id: String { get }
    /// The service's name, for the page.
    var label: String { get }
    /// Adds `tasks` in their order; `added` is told each one as soon as the service has it, so a failure part-way
    /// leaves what went through on record and a second press doesn't send it again.
    func add(_ tasks: [FollowUpTask], added: (Int, AddedTask) throws -> Void) async throws
}

// MARK: - Todoist

/// Todoist's REST API v2: a task per step (content, description, due date) in the project chosen in Settings, else the
/// Inbox.
public struct TodoistClient: TaskTarget {
    public static let BASE_URL = "https://api.todoist.com/rest/v2"
    public static let NAME = "Todoist"
    public static let TIMEOUT_SECONDS = 30.0

    public let id = "todoist"
    public let label = NAME
    let token: String
    let projectId: String?
    let base: String
    let http: HTTPClient

    public init(token: String, projectId: String? = nil, base: String = BASE_URL, http: HTTPClient = HTTPClient()) {
        self.token = token
        self.projectId = projectId.flatMap { $0.isEmpty ? nil : $0 }
        self.base = base
        self.http = http
    }

    public struct Project: Equatable, Sendable {
        public let id: String
        public let name: String
        public let inbox: Bool
    }

    /// The user's projects, the Inbox first (Settings' project picker and its Check).
    public func projects() async throws -> [Project] {
        let (data, _) = try await http.send(try request("GET", "/projects"), name: Self.NAME, key: token)
        guard let answer = try? PythonJSON.parse(data) else { throw CloudError("\(Self.NAME) answered with something that is not JSON") }
        // v2 answers a list; the newer API wraps it in "results".
        let items = answer.arrayValue ?? answer["results"]?.arrayValue ?? []
        let projects: [Project] = items.compactMap { p in
            guard let id = Self.idText(p["id"]), let name = p["name"]?.stringValue else { return nil }
            let inbox = p["is_inbox_project"]?.boolValue ?? p["inbox_project"]?.boolValue ?? false
            return Project(id: id, name: name, inbox: inbox)
        }
        return projects.filter(\.inbox) + projects.filter { !$0.inbox }
    }

    public func add(_ tasks: [FollowUpTask], added: (Int, AddedTask) throws -> Void) async throws {
        for (i, task) in tasks.enumerated() {
            try added(i, try await add(task))
        }
    }

    /// One task; what Todoist made.
    public func add(_ task: FollowUpTask) async throws -> AddedTask {
        var fields: [(String, JSONValue)] = [("content", .string(task.title)), ("description", .string(task.reference))]
        if let projectId { fields.append(("project_id", .string(projectId))) }
        if let due = task.due { fields.append(("due_date", .string(due))) }
        var req = try request("POST", "/tasks", json: .object(fields))
        // Todoist drops a second request with the same id: a create sent twice is made once.
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        let answer = try await http.sendJSON(req, name: Self.NAME, key: token, idempotent: false)
        guard let id = Self.idText(answer["id"]) else { throw CloudError("\(Self.NAME) made the task but gave no id") }
        return AddedTask(id: id, url: answer["url"]?.stringValue)
    }

    /// An id as text: v2 sends strings, older answers numbers.
    static func idText(_ v: JSONValue?) -> String? {
        switch v {
        case .string(let s)? where !s.isEmpty: return s
        case .int(let n)?: return String(n)
        default: return nil
        }
    }

    func request(_ method: String, _ path: String, json: JSONValue? = nil) throws -> URLRequest {
        guard let url = URL(string: base + path) else { throw CloudError("not a \(Self.NAME) address") }
        var r = URLRequest(url: url, timeoutInterval: Self.TIMEOUT_SECONDS)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(PythonJSON.dumps(json, ensureAscii: false).utf8)
        }
        return r
    }
}

// MARK: - Notion

/// A Notion to-do database the user named in Settings: a row per step. The title column gets the step; the columns it
/// has besides, matched by type and a name keyword as the meeting upload's are, get the due date, the owner, the
/// meeting and its link; a checkbox or status column is left to its default. The row's page says where it came from.
public struct NotionTaskDatabase: TaskTarget {
    public let id = "notion"
    public let label = "Notion"
    let client: NotionClient
    public let databaseId: String

    /// Name keywords of the columns a task fills (English and German).
    static let DUE = ["due", "fällig", "faellig", "deadline", "frist", "until", "bis"]
    static let OWNER = ["owner", "assignee", "verantwortlich", "zuständig", "who", "person"]
    static let MEETING = ["meeting", "besprechung", "termin", "source", "quelle", "context", "kontext", "from"]
    static let LINK = ["meeting", "besprechung", "link", "url", "source", "quelle"]

    public init(client: NotionClient, databaseId: String) {
        self.client = client
        self.databaseId = databaseId
    }

    /// The database's id from what the user pasted: a link ("https://www.notion.so/…/Tasks-<32 hex>?v=…"), the 32 hex
    /// digits, or the id with dashes. nil when there is none in it.
    public static func databaseId(_ text: String) -> String? {
        var s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = s[..<cut] }
        while s.hasSuffix("/") { s = s.dropLast() }
        let plain = s.replacingOccurrences(of: "-", with: "")
        let hex = plain.reversed().prefix { $0.isHexDigit && $0.isASCII }
        guard hex.count >= 32 else { return nil }
        let id = String(hex.prefix(32).reversed()).lowercased()
        let parts = [8, 4, 4, 4, 12]
        var out: [String] = [], at = id.startIndex
        for n in parts {
            let end = id.index(at, offsetBy: n)
            out.append(String(id[at..<end]))
            at = end
        }
        return out.joined(separator: "-")
    }

    /// What Check says: the database's title and which columns a task fills.
    public struct Info: Equatable, Sendable {
        public let title: String
        public let titleColumn: String
        public let due: String?
        public let owner: String?
        public let meeting: String?
        public let link: String?
    }

    /// The database as the tasks would see it; NotionError with what to do when it can't be used.
    public func check() async throws -> Info {
        let schema = try await self.schema()
        return try Self.info(schema)
    }

    func schema() async throws -> JSONValue {
        let (data, status) = try await client.request("GET", "\(client.base)/databases/\(databaseId)")
        guard status == 200, let schema = try? PythonJSON.parse(data) else {
            throw NotionError(Self.why(status, data, token: client.token))
        }
        return schema
    }

    /// Why Notion said no, in words for the page.
    static func why(_ status: Int, _ data: Data, token: String) -> String {
        switch status {
        case 401: return "Notion refused the token; check it"
        case 403, 404:
            return "Notion can't open this database: share it with your integration (in Notion: ••• → Connections) "
                + "and check the link"
        default:
            let said = HTTPClient.redact(HTTPClient.providerMessage(data), key: token)
            return said.isEmpty ? "Notion answered HTTP \(status)" : "Notion answered HTTP \(status): \(said)"
        }
    }

    static func info(_ schema: JSONValue) throws -> Info {
        guard schema["object"]?.stringValue ?? "database" == "database", case .object(let props)? = schema["properties"] else {
            throw NotionError("That is not a Notion database")
        }
        guard let title = props.first(where: { $0.1["type"]?.stringValue == "title" })?.0 else {
            throw NotionError("The database has no title column")
        }
        let name = NotionClient.plain(schema["title"])
        return Info(title: name.isEmpty ? "Untitled" : name, titleColumn: title,
                    due: NotionClient.column(schema, keywords: DUE, "date") ?? NotionClient.column(schema, "date", "date"),
                    owner: NotionClient.column(schema, keywords: OWNER, "rich_text"),
                    meeting: NotionClient.column(schema, keywords: MEETING, "rich_text"),
                    link: NotionClient.column(schema, keywords: LINK, "url"))
    }

    /// The row's properties for `task` in a database whose columns are `info`'s.
    static func properties(_ task: FollowUpTask, _ info: Info) -> JSONValue {
        func text(_ s: String) -> JSONValue { .array([.object([("text", .object([("content", .string(s))]))])]) }
        // Without an owner column the owner stays in the title.
        let title = info.owner == nil ? task.title : task.text
        var props: [(String, JSONValue)] = [(info.titleColumn, .object([("title", text(title))]))]
        if let c = info.due, let due = task.due { props.append((c, .object([("date", .object([("start", .string(due))]))]))) }
        if let c = info.owner, let owner = task.owner { props.append((c, .object([("rich_text", text(owner))]))) }
        if let c = info.meeting { props.append((c, .object([("rich_text", text(task.meeting))]))) }
        if let c = info.link, let link = task.link { props.append((c, .object([("url", .string(link))]))) }
        return .object(props)
    }

    /// The row's page: one paragraph saying where the task came from, linked to the meeting when it has a link.
    static func blocks(_ task: FollowUpTask) -> [JSONValue] {
        var parts: [JSONValue] = [.object([("type", .string("text")), ("text", .object([("content", .string("From the meeting "))]))])]
        var name: [(String, JSONValue)] = [("content", .string("“\(task.meeting)”"))]
        if let link = task.link { name.append(("link", .object([("url", .string(link))]))) }
        parts.append(.object([("type", .string("text")), ("text", .object(name))]))
        parts.append(.object([("type", .string("text")), ("text", .object([("content", .string(" (Palaver)"))]))]))
        return [.object([("object", .string("block")), ("type", .string("paragraph")),
                         ("paragraph", .object([("rich_text", .array(parts))]))])]
    }

    public func add(_ tasks: [FollowUpTask], added: (Int, AddedTask) throws -> Void) async throws {
        guard !tasks.isEmpty else { return }
        let info = try Self.info(try await schema())
        for (i, task) in tasks.enumerated() {
            let payload = JSONValue.object([("parent", .object([("database_id", .string(databaseId))])),
                                            ("properties", Self.properties(task, info)), ("children", .array(Self.blocks(task)))])
            let (data, status) = try await client.request("POST", "\(client.base)/pages", json: payload)
            guard status == 200, let page = try? PythonJSON.parse(data), let pageId = page["id"]?.stringValue else {
                throw NotionError(Self.why(status, data, token: client.token))
            }
            try added(i, AddedTask(id: pageId, url: page["url"]?.stringValue))
        }
    }
}
