// The Notion upload (notion_client.py, cli.py `_cmd_sync`): the transcript as a Notion page under the parent page, or
// as a row of a database (its columns matched by type and a name keyword, so any schema works), one paragraph per
// utterance: the speaker in bold, the wall time `[HH:MM:SS]`, the text. 100 blocks go with the page, the rest are
// appended 100 at a time.
//
// Retries only where Notion most likely did NOT apply the request (429, 502, 503, 504, and a connection that never
// reached it): retrying a 500 or a timed-out create/append could duplicate the page or its blocks. The token is sent
// only to Notion and never shown.
import Foundation
import PalaverCore
import PalaverDomain

public struct NotionError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct NotionClient: Sendable {
    public static let VERSION = "2022-06-28"
    public static let BASE_URL = "https://api.notion.com/v1"
    public static let MAX_BLOCKS_PER_REQUEST = 100
    public static let REQUEST_TIMEOUT_SECONDS = 30.0
    public static let RETRY_DELAYS_SECONDS = [0.5, 1.0, 2.0]
    public static let MAX_RETRY_AFTER_SECONDS = 30.0
    public static let RETRYABLE_STATUSES: Set<Int> = [429, 502, 503, 504]

    let token: String
    let base: String
    let http: HTTPClient

    /// `http`: its transport and sleep (Notion's own retry policy is here, not HTTPClient.send's).
    public init(token: String, base: String = BASE_URL, http: HTTPClient = HTTPClient()) {
        self.token = token
        self.base = base
        self.http = http
    }

    // MARK: - Blocks and columns

    /// One paragraph per utterance: the speaker (bold), ` [HH:MM:SS]` (the wall time in `timeZone`), `  text`.
    public static func blocks(_ utterances: [Utterance], start: Date, timeZone: TimeZone) throws -> [JSONValue] {
        try utterances.map { u in
            func text(_ s: String, bold: Bool = false) -> JSONValue {
                var fields: [(String, JSONValue)] = [("type", .string("text")), ("text", .object([("content", .string(s))]))]
                if bold { fields.append(("annotations", .object([("bold", .bool(true))]))) }
                return .object(fields)
            }
            let wall = try Render.wallTime(start, plus: u.start, timeZone)
            return .object([("object", .string("block")), ("type", .string("paragraph")), ("paragraph", .object([
                ("rich_text", .array([text(u.speaker, bold: true), text(" [\(wall)]"), text("  \(u.text)")])),
            ]))])
        }
    }

    /// Name keywords per column kind (English and German).
    static let COLUMN_KEYWORDS: [String: [String]] = [
        "date": ["date", "datum", "when", "start"],
        "duration": ["duration", "dauer", "minutes", "length"],
        "speakers": ["speaker", "sprecher", "participant", "teilnehmer"],
        "source": ["source", "quelle", "platform", "tool"],
    ]

    /// The first column of `type` whose name holds one of the kind's keywords.
    static func column(_ schema: JSONValue, _ kind: String, _ type: String) -> String? {
        guard case .object(let props)? = schema["properties"] else { return nil }
        for (name, prop) in props where prop["type"]?.stringValue == type {
            let lowered = name.lowercased()
            if COLUMN_KEYWORDS[kind]!.contains(where: { lowered.contains($0) }) { return name }
        }
        return nil
    }

    /// Page properties for a database row, limited to the schema's columns.
    public static func databaseProperties(_ schema: JSONValue, title: String, start: String, durationMinutes: Double,
                                          speakers: Int, source: String) -> JSONValue {
        var props = PyDict<JSONValue>()
        if case .object(let all)? = schema["properties"] {
            for (name, prop) in all where prop["type"]?.stringValue == "title" {
                props[name] = .object([("title", .array([.object([("text", .object([("content", .string(title))]))])]))])
            }
        }
        if let c = column(schema, "date", "date") { props[c] = .object([("date", .object([("start", .string(start))]))]) }
        if let c = column(schema, "duration", "number") { props[c] = .object([("number", .double(Py.round(durationMinutes, 1)))]) }
        if let c = column(schema, "speakers", "number") { props[c] = .object([("number", .int(speakers))]) }
        if let c = column(schema, "source", "select") { props[c] = .object([("select", .object([("name", .string(source))]))]) }
        return props.json
    }

    // MARK: - Pages

    /// Creates a page under `parentPageId`; its URL.
    public func createPage(parentPageId: String, title: String, blocks: [JSONValue]) async throws -> String {
        try await create(parent: .object([("page_id", .string(parentPageId))]),
                         properties: .object([("title", .object([("title", .array([.object([("text", .object([("content", .string(title))]))])]))]))]),
                         blocks: blocks)
    }

    /// Creates a row in a database, filling the columns its schema has; its URL.
    public func createDatabasePage(databaseId: String, title: String, blocks: [JSONValue], start: String, durationMinutes: Double,
                                   speakers: Int, source: String) async throws -> String {
        let (data, status) = try await request("GET", "\(base)/databases/\(databaseId)")
        guard status == 200, let schema = try? PythonJSON.parse(data) else {
            throw NotionError("Notion database lookup failed: \(status) \(Self.text(data))")
        }
        let properties = Self.databaseProperties(schema, title: title, start: start, durationMinutes: durationMinutes,
                                                 speakers: speakers, source: source)
        return try await create(parent: .object([("database_id", .string(databaseId))]), properties: properties, blocks: blocks)
    }

    func create(parent: JSONValue, properties: JSONValue, blocks: [JSONValue]) async throws -> String {
        let first = Array(blocks.prefix(Self.MAX_BLOCKS_PER_REQUEST))
        let payload = JSONValue.object([("parent", parent), ("properties", properties), ("children", .array(first))])
        let (data, status) = try await request("POST", "\(base)/pages", json: payload)
        guard status == 200, let page = try? PythonJSON.parse(data), let pageId = page["id"]?.stringValue else {
            throw NotionError("Notion create_page failed: \(status) \(Self.text(data))")
        }
        let url = page["url"]?.stringValue ?? ""
        var at = Self.MAX_BLOCKS_PER_REQUEST
        while at < blocks.count {
            let batch = Array(blocks[at..<min(at + Self.MAX_BLOCKS_PER_REQUEST, blocks.count)])
            let (body, code) = try await request("PATCH", "\(base)/blocks/\(pageId)/children", json: .object([("children", .array(batch))]))
            guard code == 200 else { throw NotionError("Notion append blocks failed: \(code) \(Self.text(body))") }
            at += Self.MAX_BLOCKS_PER_REQUEST
        }
        return url
    }

    static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    // MARK: - Requests

    /// A connection that provably never reached Notion (no route, no host, refused). A dropped connection or a timeout
    /// may already have created the page or appended the blocks.
    static func neverSent(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet].contains(e.code)
    }

    static func backoff(_ attempt: Int) -> Double { RETRY_DELAYS_SECONDS[attempt] * (1 + Double.random(in: 0...0.25)) }

    static func retryAfter(_ response: HTTPURLResponse) -> Double? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After").flatMap({ Double(Py.strip($0)) }) else { return nil }
        return min(max(value, 0), MAX_RETRY_AFTER_SECONDS)
    }

    /// Sends with retries on rate limits, gateway errors and connections that never reached Notion (0.5 s, 1 s, 2 s
    /// backoff with jitter; Retry-After wins). The last answer's body and status, whatever it is.
    func request(_ method: String, _ url: String, json: JSONValue? = nil) async throws -> (Data, Int) {
        guard let target = URL(string: url) else { throw NotionError("not a Notion address: \(url)") }
        var request = URLRequest(url: target, timeoutInterval: Self.REQUEST_TIMEOUT_SECONDS)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.VERSION, forHTTPHeaderField: "Notion-Version")
        if let json { request.httpBody = Data(PythonJSON.dumps(json, ensureAscii: false).utf8) }
        let attempts = Self.RETRY_DELAYS_SECONDS.count + 1
        for attempt in 0..<attempts {
            let last = attempt == attempts - 1
            let data: Data, response: HTTPURLResponse
            do {
                (data, response) = try await http.transport(request)
            } catch {
                if last || !Self.neverSent(error) { throw error }
                await http.sleep(Self.backoff(attempt))
                continue
            }
            if !Self.RETRYABLE_STATUSES.contains(response.statusCode) || last { return (data, response.statusCode) }
            await http.sleep(Self.retryAfter(response) ?? Self.backoff(attempt))
        }
        throw NotionError("unreachable")
    }
}

/// `palaver sync <folder>` (cli.py `_cmd_sync`): the meeting's transcript to Notion, as config.toml says (page or
/// database mode), then notion.json `{page_url, uploaded_at}`, the session's `notion_upload_start/_done` and the
/// "Uploaded to Notion" notification (the caller's).
public enum NotionSync {
    public struct Plan {
        public let title: String
        public let blocks: [JSONValue]
        public let start: String
        public let durationMinutes: Double
        public let speakers: Int
        public let source: String
    }

    /// What goes up: the readable transcript (glossary spellings, filler-only turns left out) as blocks, the title,
    /// and the database columns' values.
    public static func plan(_ paths: RecordingPaths, glossary: Glossary? = nil) throws -> Plan {
        guard let raw = PythonJSON.read(paths.transcriptJson)?.arrayValue else {
            throw NotionError("\(paths.transcriptJson.lastPathComponent) is missing or not a list")
        }
        let utterances = Readable.readable(try raw.map { try Utterance(json: $0) }, glossary: glossary)
        guard let meta = PythonJSON.read(paths.meta), let iso = meta["start_time"]?.stringValue, let start = Py.fromIso(iso),
              let duration = meta["duration_seconds"]?.doubleValue else {
            throw NotionError("\(paths.meta.lastPathComponent) has no start_time or duration_seconds")
        }
        let zone = Lifecycle.offsetZone(iso) ?? .current
        let speakers = Set(utterances.map { ScalarKey($0.speaker) }).count
        return Plan(title: try Render.buildMeetingTitle(start, duration, speakers, timeZone: zone),
                    blocks: try NotionClient.blocks(utterances, start: start, timeZone: zone), start: iso,
                    durationMinutes: duration / 60, speakers: speakers,
                    source: meta["trigger"]?.stringValue == "teams" ? "Teams" : "Manual recording")
    }

    /// Uploads `plan` as `config` says; the page's URL. Throws NotionError for a missing setting or a refused request.
    public static func upload(_ plan: Plan, config: Config, token: String, client: NotionClient) async throws -> String {
        if config.notionMode == "database" {
            guard let db = config.notionDatabaseId, !db.isEmpty else {
                throw NotionError("[notion].database_id is required when mode = \"database\"")
            }
            return try await client.createDatabasePage(databaseId: db, title: plan.title, blocks: plan.blocks, start: plan.start,
                                                       durationMinutes: plan.durationMinutes, speakers: plan.speakers,
                                                       source: plan.source)
        }
        guard let parent = config.notionParentPageId, !parent.isEmpty else { throw NotionError("[notion].parent_page_id is required") }
        return try await client.createPage(parentPageId: parent, title: plan.title, blocks: plan.blocks)
    }

    /// notion.json: `{page_url, uploaded_at}` (local time without offset, to the microsecond, as Python wrote it).
    public static func writeInfo(_ paths: RecordingPaths, url: String, now: Date = Date()) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        try PythonJSON.write(.object([("page_url", .string(url)), ("uploaded_at", .string(f.string(from: now)))]),
                             to: paths.notionInfo, indent: 2, ensureAscii: true)
    }
}
