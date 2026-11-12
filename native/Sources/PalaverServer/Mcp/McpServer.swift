// `palaver mcp`'s protocol (mcp_server.py `build_server`; issue #35): the Model Context Protocol over stdio, one JSON-RPC
// message per line. A small hand-written loop rather than the SDK: the server needs `initialize`, `ping`, `tools/list`
// and `tools/call` (plus empty `prompts/list` and `resources/list`), and the app links no extra package for them.
//
// The server is called "palaver" (McpSetup.NAME; "meetings" before 0.6.3) and gives Claude its instructions and seven
// read-only tools, with the Python server's names, parameters and defaults. The instructions and descriptions say what
// it serves in the words a user asks with (meetings, calls, Teams, transcripts, next steps, customers …), so Claude
// picks it for such a question. A tool's answer is its JSON (one text block per item of
// a list, as the Python SDK sent it) and the same value as `structuredContent`. Every call that runs leaves one line
// in the access log (McpSession.record): the arguments given (without defaults, long text cut short), how much went
// out and which meetings.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

public final class McpServer {
    public static let NAME = McpSetup.NAME

    /// What the server serves and how to read it, sent at `initialize`.
    public static let INSTRUCTIONS = """
        Palaver: the user's recorded meetings and calls (Microsoft Teams, Slack huddles, in person), in German and \
        English: transcripts with speaker names, meeting notes (summary, next steps, decisions), projects (customers, \
        initiatives, topics) and people. Use it whenever the user asks about a meeting, call, 1:1 or conversation: what \
        was said or decided, who said what, next steps or action items, a customer, project or person. Start with \
        search_meetings or list_meetings; read a meeting with get_meeting (notes first; ask for the transcript only when \
        the notes are not enough, preferably a time range). get_project and open_next_steps gather across meetings. \
        Meeting ids look like 2026-10-21T16-29-29 (the start, local time). Meetings the user keeps on this Mac are not \
        shared here.
        """

    /// The protocol versions this server speaks, newest first: a client's own is answered with itself, any other with
    /// the newest.
    public static let PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// Logged text arguments are cut to this many characters.
    public static let ARG_CHARS = 120
    /// Meeting ids per log line, at most.
    public static let LOGGED_MEETINGS = 100

    public let tools: McpTools
    public let session: McpSession
    let version: String
    private let outLock = NSLock()

    public init(tools: McpTools, session: McpSession, version: String = "") {
        self.tools = tools
        self.session = session
        self.version = version
    }

    // MARK: - the tools

    enum Kind: String { case string, integer, number, boolean }

    struct Param {
        let name: String
        let kind: Kind
        /// nil: required; `.null`: optional (`X | None = None`); else the default.
        let fallback: JSONValue?

        var title: String { name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }

        var schema: JSONValue {
            switch fallback {
            case nil: return .object([("title", .string(title)), ("type", .string(kind.rawValue))])
            case .null?: return .object([("anyOf", .array([.object([("type", .string(kind.rawValue))]), .object([("type", .string("null"))])])),
                                         ("default", .null), ("title", .string(title))])
            case let given?: return .object([("default", given), ("title", .string(title)), ("type", .string(kind.rawValue))])
            }
        }
    }

    /// The arguments of one call, checked and with the defaults filled in.
    struct Args {
        let values: [String: JSONValue]
        func string(_ k: String) -> String? { values[k]?.stringValue }
        func int(_ k: String) -> Int { if case .int(let i)? = values[k] { return i }; return 0 }
        func double(_ k: String) -> Double? { values[k]?.doubleValue }
        func bool(_ k: String) -> Bool { values[k]?.boolValue ?? false }
    }

    struct Tool {
        let name: String
        let description: String
        let params: [Param]
        /// What one item of its list answer is (`_ITEMS`; search_meetings' are its "meetings").
        let items: String?
        let run: (Args) throws -> JSONValue

        /// Whether it answers a list (else an object).
        var answersList: Bool { items != nil && name != "search_meetings" }

        var inputSchema: JSONValue {
            var fields: [(String, JSONValue)] = [("properties", .object(params.map { ($0.name, $0.schema) }))]
            let required = params.filter { $0.fallback == nil }.map(\.name)
            if !required.isEmpty { fields.append(("required", .strings(required))) }
            fields += [("type", .string("object")), ("title", .string("\(name)Arguments"))]
            return .object(fields)
        }

        var outputSchema: JSONValue {
            guard answersList else {
                return .object([("type", .string("object")), ("additionalProperties", .bool(true)), ("title", .string("\(name)DictOutput"))])
            }
            let list = JSONValue.object([("items", .object([("additionalProperties", .bool(true)), ("type", .string("object"))])),
                                         ("title", .string("Result")), ("type", .string("array"))])
            return .object([("properties", .object([("result", list)])), ("required", .strings(["result"])),
                            ("type", .string("object")), ("title", .string("\(name)Output"))])
        }

        var json: JSONValue {
            .object([("name", .string(name)), ("description", .string(description)), ("inputSchema", inputSchema),
                     ("outputSchema", outputSchema)])
        }
    }

    private static func optional(_ name: String, _ kind: Kind = .string) -> Param { Param(name: name, kind: kind, fallback: .null) }

    lazy var table: [Tool] = {
        let t = tools
        return [
            Tool(name: "list_meetings", description: """
                The user's recorded meetings and calls (Teams, Slack huddles, in person),
                newest first, with title, people, projects and summary. Filter by
                project or customer (name or id), person (spoke or was invited; part
                of a name is enough), and dates (YYYY-MM-DD).
                """,
                 params: [Self.optional("project"), Self.optional("person"), Self.optional("since"), Self.optional("until"),
                          Param(name: "limit", kind: .integer, fallback: .int(30))],
                 items: "meetings") { a in
                try t.listMeetings(project: a.string("project"), person: a.string("person"), since: a.string("since"),
                                   until: a.string("until"), limit: a.int("limit"))
            },
            Tool(name: "search_meetings", description: """
                Search the user's recorded meetings and calls: transcripts (who said
                what), notes, decisions, next steps. The query may name
                people ("Anna and Tom": both took part, as named speakers or invitees;
                "Anna or Tom"), projects, organizations ("ACB people"), dates ("last
                month", "since 2026-10-01", "oktober"), decisions or next steps ("what
                did we decide about X"), or one person's lines ("where did Mara talk
                about pricing"); quoted words stay words. Filters can be written out:
                person: project: org: since: until: in:decisions|steps|notes|transcript
                by:<name> is:reviewed has:steps. The other parameters add filters.
                Returns what was understood, and meetings found by words (title,
                notes, transcript lines), then ones found by meaning (similar
                wording, other language) when the index has them.
                """,
                 params: [Param(name: "query", kind: .string, fallback: nil), Self.optional("project"), Self.optional("person"),
                          Self.optional("organization"), Self.optional("since"), Self.optional("until"),
                          Param(name: "limit", kind: .integer, fallback: .int(10))],
                 items: "meetings") { a in
                try t.searchMeetings(query: a.string("query") ?? "", project: a.string("project"), person: a.string("person"),
                                     organization: a.string("organization"), since: a.string("since"), until: a.string("until"),
                                     limit: a.int("limit"))
            },
            Tool(name: "get_meeting", description: """
                One recorded meeting or call: who was invited and spoke, projects, its
                notes (summary, next steps, decisions) and the user's own notes. The
                transcript with speaker names only with include_transcript, or
                from_minute/to_minute for a part of it (minutes from the start).
                """,
                 params: [Param(name: "meeting_id", kind: .string, fallback: nil),
                          Param(name: "include_transcript", kind: .boolean, fallback: .bool(false)),
                          Self.optional("from_minute", .number), Self.optional("to_minute", .number)],
                 items: nil) { a in
                try t.getMeeting(meetingId: a.string("meeting_id") ?? "", includeTranscript: a.bool("include_transcript"),
                                 fromMinute: a.double("from_minute"), toMinute: a.double("to_minute"))
            },
            Tool(name: "list_projects", description: """
                Projects the user's meetings are sorted into (customers, initiatives,
                topics) with their description, how many meetings, the people
                involved and the latest meeting.
                """,
                 params: [], items: "projects") { _ in try t.listProjects() },
            Tool(name: "get_project", description: """
                A project or customer (name or id): description, its meetings and calls
                with summaries, people, and the next steps agreed in its meetings.
                """,
                 params: [Param(name: "project", kind: .string, fallback: nil)], items: nil) { a in
                try t.getProject(project: a.string("project") ?? "")
            },
            Tool(name: "list_people", description: """
                People in the user's meetings and calls (named speakers and invitees),
                with how many meetings and when the last one was.
                """,
                 params: [], items: "people") { _ in try t.listPeople() },
            Tool(name: "open_next_steps", description: """
                Next steps and action items agreed in the user's meetings and calls,
                newest first: filter by project, person in the meeting, owner of the
                step, and since (YYYY-MM-DD).
                """,
                 params: [Self.optional("project"), Self.optional("person"), Self.optional("owner"), Self.optional("since")],
                 items: "next_steps") { a in
                try t.openNextSteps(project: a.string("project"), person: a.string("person"), owner: a.string("owner"),
                                    since: a.string("since"))
            },
        ]
    }()

    // MARK: - arguments

    struct Invalid: Error {
        let param: String
        let message: String
    }

    /// The arguments as the Python SDK's validation read them (pydantic's lax mode): text must be text; a whole number
    /// may come as a number or its text; a flag as true/false, 0/1 or their words; null only where the default is null.
    /// Unknown arguments are ignored.
    static func check(_ given: JSONValue?, _ params: [Param]) throws -> Args {
        var values: [String: JSONValue] = [:]
        for p in params {
            let v = given?[p.name]
            guard let v, !(v.isNull && p.fallback == .null) else {
                if let fallback = p.fallback { values[p.name] = fallback; continue }
                throw Invalid(param: p.name, message: "Field required")
            }
            values[p.name] = try coerce(v, p)
        }
        return Args(values: values)
    }

    static func coerce(_ v: JSONValue, _ p: Param) throws -> JSONValue {
        switch (p.kind, v) {
        case (.string, .string): return v
        case (.string, _): throw Invalid(param: p.name, message: "Input should be a valid string")
        case (.integer, .int): return v
        case (.integer, .double(let d)) where d.rounded() == d && abs(d) < 1e15: return .int(Int(d))
        case (.integer, .string(let s)) where Int(Py.strip(s)) != nil: return .int(Int(Py.strip(s))!)
        case (.integer, _): throw Invalid(param: p.name, message: "Input should be a valid integer")
        case (.number, .int(let i)): return .double(Double(i))
        case (.number, .double): return v
        case (.number, .string(let s)) where Double(Py.strip(s))?.isFinite == true: return .double(Double(Py.strip(s))!)
        case (.number, _): throw Invalid(param: p.name, message: "Input should be a valid number")
        case (.boolean, .bool): return v
        case (.boolean, .int(let i)) where i == 0 || i == 1: return .bool(i == 1)
        case (.boolean, .string(let s)):
            switch Py.casefold(Py.strip(s)) {
            case "1", "on", "t", "true", "y", "yes": return .bool(true)
            case "0", "off", "f", "false", "n", "no": return .bool(false)
            default: throw Invalid(param: p.name, message: "Input should be a valid boolean")
            }
        case (.boolean, _): throw Invalid(param: p.name, message: "Input should be a valid boolean")
        }
    }

    // MARK: - the access log's line

    /// `_short_args`: the arguments given, without the defaults; long text cut short.
    static func shortArgs(_ args: Args, _ params: [Param]) -> JSONValue {
        var out: [(String, JSONValue)] = []
        for p in params {
            guard var v = args.values[p.name], !v.isNull else { continue }
            if let fallback = p.fallback, PythonJSON.equal(v, fallback) { continue }
            if case .string(let s) = v, s.unicodeScalars.count > ARG_CHARS {
                v = .string(McpTools.prefix(s, ARG_CHARS - 1) + "…")
            }
            out.append((p.name, v))
        }
        return .object(out)
    }

    /// `_measure`: how much went out (meetings, projects, people, next steps, lines, characters), and which meetings.
    static func measure(_ tool: Tool, _ result: JSONValue) -> (JSONValue, [String]) {
        var out: [(String, JSONValue)] = []
        var ids: [String] = []
        var list = result.arrayValue
        if tool.name == "search_meetings" { list = result["meetings"]?.arrayValue ?? [] }
        if let items = tool.items, let list {
            out.append((items, .int(list.count)))
            if ["list_meetings", "search_meetings", "open_next_steps"].contains(tool.name) {
                ids = list.compactMap { ($0["meeting"]?.truthy ?? false ? $0["meeting"] : $0["id"])?.stringValue }
            }
            if tool.name == "search_meetings" {
                out.append(("lines", .int(list.reduce(0) { $0 + ($1["lines"]?.arrayValue?.count ?? 0) })))
            }
            if tool.name == "open_next_steps" { out.append(("meetings", .int(Set(ids.map(ScalarKey.init)).count))) }
        } else if tool.name == "get_meeting" {
            out.append(("meetings", .int(1)))
            ids = [result["id"]?.stringValue].compactMap { $0 }
            if let transcript = result["transcript"]?.arrayValue { out.append(("lines", .int(transcript.count))) }
        } else if tool.name == "get_project" {
            let meetings = result["meetings"]?.arrayValue ?? []
            out += [("projects", .int(1)), ("meetings", .int(meetings.count)),
                    ("next_steps", .int(result["next_steps"]?.arrayValue?.count ?? 0))]
            ids = meetings.compactMap { $0["id"]?.stringValue }
        }
        out.append(("chars", .int(PythonJSON.dumps(result, ensureAscii: false).unicodeScalars.count)))
        var seen = Set<ScalarKey>()
        let unique = ids.filter { !$0.isEmpty && seen.insert(ScalarKey($0)).inserted }
        return (.object(out), Array(unique.prefix(LOGGED_MEETINGS)))
    }

    // MARK: - the messages

    static func monotonic() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

    /// `tools/call`: the tool's answer, or what went wrong as an error result (`isError`) under the tool's name: a
    /// deliberate error (a project that isn't there, a date that isn't one, bad arguments) with its text, anything
    /// else without (nothing of an unexpected error reaches Claude).
    func call(_ name: String, _ arguments: JSONValue?) -> JSONValue {
        guard let tool = table.first(where: { $0.name == name }) else { return Self.failed("Unknown tool: \(name)") }
        let args: Args
        do {
            args = try Self.check(arguments, tool.params)
        } catch let bad as Invalid {
            return Self.failed("Error executing tool \(name): 1 validation error for \(name)Arguments\n\(bad.param)\n  \(bad.message)")
        } catch {
            return Self.failed("Error executing tool \(name)")
        }
        let t0 = Self.monotonic()
        var result: JSONValue?
        var failure: Error?
        do { result = try tool.run(args) } catch { failure = error }
        let ms = Int(((Self.monotonic() - t0) * 1000).rounded())
        let (out, ids) = result.map { Self.measure(tool, $0) } ?? (.object([]), [])
        let errorText = failure.map { e -> String in
            let text = String(describing: e)
            return McpTools.prefix(text.isEmpty ? "\(type(of: e))" : text, 300)
        }
        session.record(tool: name, args: Self.shortArgs(args, tool.params), out: out, meetings: ids, ms: ms, error: errorText)
        if let failure {
            if let deliberate = failure as? McpToolError { return Self.failed("Error executing tool \(name): \(deliberate.description)") }
            return Self.failed("Error executing tool \(name)")
        }
        let value = result ?? .null
        let items = tool.answersList ? (value.arrayValue ?? []) : [value]
        return .object([("content", .array(items.map { .object([("type", .string("text")),
                                                                 ("text", .string(PythonJSON.dumps($0, indent: 2, ensureAscii: false)))]) })),
                        ("structuredContent", tool.answersList ? .object([("result", value)]) : value),
                        ("isError", .bool(false))])
    }

    static func failed(_ text: String) -> JSONValue {
        .object([("content", .array([.object([("type", .string("text")), ("text", .string(text))])])), ("isError", .bool(true))])
    }

    /// One message in; the answer to send (nil for a notification, which gets none).
    public func handle(_ message: JSONValue) -> JSONValue? {
        guard let method = message["method"]?.stringValue else {
            // A reply (this server asks the client nothing, so there is none to wait for), or no request at all.
            if message["result"] != nil || message["error"] != nil { return nil }
            return Self.error(message["id"] ?? .null, -32600, "Invalid Request")
        }
        guard let id = message["id"], !id.isNull else { return nil }  // notifications/initialized, notifications/cancelled
        let params = message["params"]
        switch method {
        case "initialize":
            session.setClient(params?["clientInfo"])
            let asked = params?["protocolVersion"]?.stringValue ?? ""
            let version = Self.PROTOCOL_VERSIONS.contains(asked) ? asked : Self.PROTOCOL_VERSIONS[0]
            return Self.result(id, .object([
                ("protocolVersion", .string(version)),
                ("capabilities", .object([("tools", .object([("listChanged", .bool(false))]))])),
                ("serverInfo", .object([("name", .string(Self.NAME)), ("version", .string(self.version))])),
                ("instructions", .string(Self.INSTRUCTIONS)),
            ]))
        case "ping":
            return Self.result(id, .object([]))
        case "tools/list":
            return Self.result(id, .object([("tools", .array(table.map(\.json)))]))
        case "tools/call":
            guard let name = params?["name"]?.stringValue else { return Self.error(id, -32602, "Invalid params") }
            return Self.result(id, call(name, params?["arguments"]))
        case "prompts/list":
            return Self.result(id, .object([("prompts", .array([]))]))
        case "resources/list":
            return Self.result(id, .object([("resources", .array([]))]))
        case "resources/templates/list":
            return Self.result(id, .object([("resourceTemplates", .array([]))]))
        default:
            return .object([("jsonrpc", .string("2.0")), ("id", id),
                            ("error", .object([("code", .int(-32601)), ("message", .string("Method not found")), ("data", .string(method))]))])
        }
    }

    static func result(_ id: JSONValue, _ value: JSONValue) -> JSONValue {
        .object([("jsonrpc", .string("2.0")), ("id", id), ("result", value)])
    }

    static func error(_ id: JSONValue, _ code: Int, _ message: String) -> JSONValue {
        .object([("jsonrpc", .string("2.0")), ("id", id), ("error", .object([("code", .int(code)), ("message", .string(message))]))])
    }

    /// One line in, the line to write (nil: nothing).
    public func handle(line: Data) -> String? {
        let text = String(decoding: line, as: UTF8.self)
        if Py.strip(text).isEmpty { return nil }
        guard let message = try? PythonJSON.parse(Data(text.utf8)) else {
            return PythonJSON.dumps(Self.error(.null, -32700, "Parse error"), ensureAscii: false)
        }
        return handle(message).map { PythonJSON.dumps($0, ensureAscii: false) }
    }

    /// Serves `input` until its end (the client closed the pipe), answering on `output`.
    public func serve(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let answer = handle(line: line) { send(answer, output) }
            }
        }
        if let answer = handle(line: buffer) { send(answer, output) }  // a last line without its newline
    }

    func send(_ line: String, _ fd: Int32) {
        let bytes = Array((line + "\n").utf8)
        outLock.withLock {
            var done = 0
            while done < bytes.count {
                let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + done, bytes.count - done) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return }
                done += n
            }
        }
    }
}
