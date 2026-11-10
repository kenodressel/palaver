// `palaver mcp` in Swift (phase 4 batch 6): Claude's seven tools over the window's domain, the JSON-RPC messages, the
// access log and heartbeat the window reads, the lifetime, the `palaver-cli` binary over stdio and the one-release
// `bin/python` shim. Ports tests/test_mcp_server.py under its names (`Meetings` is McpTools; `build_server` is
// McpServer). Every file is under the test's own folder: never the real Application Support, ~/Meetings or Claude.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"
private let PRIVATE = "2026-10-26T09-00-00"
private let SECRET_WORDS = ["Confidential", "merger", "Mara"]

private func dumps(_ v: JSONValue) -> String { PythonJSON.dumps(v, ensureAscii: false) }
private func strings(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap(\.stringValue) }
private func ids(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap { $0["id"]?.stringValue } }

/// Recordings, stores and the tools over them for "Timo" (`mcp_server.Meetings(tmp_path, "Timo")`).
private final class Fixture {
    let dir = tempFolder("mcp-server")
    let out: URL
    let stores: StorePaths
    let app: ServerApp
    let tools: McpTools
    let session: McpSession
    let server: McpServer

    init() throws {
        out = dir.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                            home: dir.appendingPathComponent("home", isDirectory: true))
        app = ServerApp(outputDir: out, userName: "Timo", stores: stores, probe: FakeProbe())
        tools = McpTools(app: app, userName: "Timo")
        tools.meaning = { _, _, _ in [] }  // nothing indexed
        session = McpSession(stores: stores)
        server = McpServer(tools: tools, session: session, version: "0.6.0")
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func paths(_ id: String = MEETING) -> RecordingPaths { RecordingPaths(out.appendingPathComponent(id, isDirectory: true)) }

    @discardableResult
    func meeting(_ id: String = MEETING) throws -> RecordingPaths { try pageMeeting(out, id) }

    func notes(_ id: String = MEETING, _ change: (inout [(String, JSONValue)]) -> Void) throws {
        guard case .object(var fields)? = Notes.load(paths(id)) else { return }
        change(&fields)
        try NotesFile.save(paths(id), .object(fields))
    }

    /// `_with_a_private_meeting`: MEETING shared, PRIVATE kept on this Mac with secrets in its notes and names, both in
    /// "Hiring", PRIVATE alone in "Secret deal".
    func withAPrivateMeeting() throws {
        try meeting()
        try meeting(PRIVATE)
        try notes(PRIVATE) { f in
            McpSetup.set(&f, "title", .string("Confidential merger"))
            McpSetup.set(&f, "summary", .string("Confidential merger talks."))
            McpSetup.set(&f, "next_steps", .array([.object([("owner", .string("Mara Hidden")), ("task", .string("Sign the merger"))])]))
        }
        _ = try PeopleAPI.nameSpeaker(app, id: PRIVATE, label: "SPEAKER_01", name: "Mara Hidden")
        try ProjectsAPI.setMeetingProject(app, id: MEETING, name: "Hiring")
        try ProjectsAPI.setMeetingProject(app, id: PRIVATE, name: "Hiring")
        try ProjectsAPI.setMeetingProject(app, id: PRIVATE, name: "Secret deal")
        try LocalOnly.set(paths(PRIVATE).folder, on: true)
    }

    /// A JSON-RPC request through the server; its `result`.
    func request(_ method: String, _ params: JSONValue? = nil, id: Int = 1) -> JSONValue? {
        var message: [(String, JSONValue)] = [("jsonrpc", .string("2.0")), ("id", .int(id)), ("method", .string(method))]
        if let params { message.append(("params", params)) }
        return server.handle(.object(message))
    }

    /// `server.call_tool(name, args)`: the result of tools/call.
    func call(_ name: String, _ args: [(String, JSONValue)] = []) -> JSONValue {
        request("tools/call", .object([("name", .string(name)), ("arguments", .object(args))]))?["result"] ?? .null
    }

    func log() throws -> [JSONValue] { try McpLog.read(stores: stores) }
}

private func noSecrets(_ answer: JSONValue) {
    let text = dumps(answer)
    #expect(!SECRET_WORDS.contains { text.contains($0) }, "\(text)")
    #expect(!text.contains(PRIVATE), "\(text)")
}

private func refused(_ text: String, _ body: () throws -> Any) -> Bool {
    do { _ = try body() } catch let e as McpToolError { return e.description == text } catch { return false }
    return false
}

@Suite struct McpServerTests {
    // MARK: - test_mcp_server.py

    @Test func test_tools_answer_from_the_same_data_as_the_window() throws {
        let f = try Fixture()
        try f.meeting()
        try f.notes { McpSetup.set(&$0, "summary", .string("SPEAKER_00 ran it.")) }
        _ = try PeopleAPI.nameSpeaker(f.app, id: MEETING, label: "SPEAKER_00", name: "Rico")
        try ProjectsAPI.setMeetingProject(f.app, id: MEETING, name: "Hiring")
        let m = f.tools

        let briefs = try #require(try m.listMeetings(project: "hiring").arrayValue)
        #expect(briefs.count == 1)
        #expect(briefs[0]["id"] == .string(MEETING) && briefs[0]["projects"] == .strings(["Hiring"])
                && briefs[0]["summary"] == .string("SPEAKER_00 ran it."))
        #expect(ids(try m.listMeetings(person: "rico")) == [MEETING])
        #expect(try m.listMeetings(since: "2026-11-01") == .array([]))

        let hits = try #require(try m.searchMeetings(query: "salary")["meetings"]?.arrayValue)
        #expect(hits.count == 1 && strings(hits[0]["lines"]) == ["[0:13] Speaker 2: Thanks Rico, the salary band is fine."])
        #expect(hits[0]["matched_by"] == .string("words"))

        let meeting = try m.getMeeting(meetingId: MEETING)
        #expect(meeting["notes"]?["summary"] == .string("Rico ran it.") && meeting["transcript"] == nil)
        let part = try m.getMeeting(meetingId: MEETING, fromMinute: 0, toMinute: 0.01)  // the first 0.6 s
        #expect(strings(part["transcript"]) == ["[0:00] Timo: Hi Rico welcome."])

        let projects = try #require(try m.listProjects().arrayValue)
        #expect(projects.count == 1 && projects[0]["name"] == .string("Hiring") && projects[0]["meetings"] == .int(1))
        #expect(dumps(try m.getProject(project: "Hiring")["next_steps"]!) == dumps(.array([.object([
            ("meeting", .string(MEETING)), ("title", .string("Hiring debrief")), ("start", .string("2026-10-27T16:03:07+01:00")),
            ("owner", .string("Speaker 2")), ("task", .string("Send the offer"))])])))
        #expect(try m.openNextSteps(owner: "rico") == .array([]))
        #expect(try m.listPeople().arrayValue?.first?["name"] == .string("Rico"))
    }

    @Test func test_the_server_lists_its_tools() throws {
        let f = try Fixture()
        let tools = try #require(f.request("tools/list")?["result"]?["tools"]?.arrayValue)
        #expect(Set(tools.compactMap { $0["name"]?.stringValue }) == ["list_meetings", "search_meetings", "get_meeting",
                                                                         "list_projects", "get_project", "list_people", "open_next_steps"])
        func tool(_ name: String) -> JSONValue { tools.first { $0["name"]?.stringValue == name } ?? .null }
        // The parameters, defaults and required ones as the Python SDK described them.
        let list = tool("list_meetings")["inputSchema"]!
        #expect(list["properties"]?["limit"] == .object([("default", .int(30)), ("title", .string("Limit")), ("type", .string("integer"))]))
        #expect(dumps(list["properties"]!["project"]!)
                == #"{"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "Project"}"#)
        #expect(list["required"] == nil && list["title"] == .string("list_meetingsArguments"))
        #expect(tool("search_meetings")["inputSchema"]?["required"] == .strings(["query"]))
        #expect(tool("search_meetings")["inputSchema"]?["properties"]?["limit"]?["default"] == .int(10))
        let get = tool("get_meeting")["inputSchema"]!
        #expect(get["required"] == .strings(["meeting_id"]))
        #expect(get["properties"]?["include_transcript"]?["default"] == .bool(false))
        #expect(get["properties"]?["from_minute"]?["anyOf"]?.arrayValue?.first == .object([("type", .string("number"))]))
        #expect(tool("get_project")["inputSchema"]?["required"] == .strings(["project"]))
        #expect(tool("list_people")["inputSchema"]?["properties"] == .object([]))
        #expect(tool("list_people")["outputSchema"]?["required"] == .strings(["result"]))
        #expect(tool("get_meeting")["outputSchema"]?["title"] == .string("get_meetingDictOutput"))
        #expect(tool("search_meetings")["outputSchema"]?["title"] == .string("search_meetingsDictOutput"))
        #expect(tool("get_meeting")["description"]?.stringValue?.hasPrefix("One meeting: who was invited and spoke") == true)
    }

    @Test func test_install_adds_the_server_to_claude_code() throws {
        let f = try Fixture()
        let setup = McpSetup(stores: f.stores, executable: "/Applications/Palaver.app/Contents/Resources/bin/palaver")
        #expect(setup.installCommand() == ["claude", "mcp", "add", "--scope", "user", "meetings", "--",
                                           "/Applications/Palaver.app/Contents/Resources/bin/palaver", "mcp"])
        let withConfig = McpSetup(stores: f.stores, executable: "/A/bin/palaver", options: ["--config", "/c/config.toml"])
        #expect(withConfig.installCommand(claude: "/x/claude").suffix(4) == ["/A/bin/palaver", "--config", "/c/config.toml", "mcp"])
    }

    @Test func test_search_reads_the_query_like_the_window() throws {
        let f = try Fixture()
        try f.meeting()
        _ = try PeopleAPI.nameSpeaker(f.app, id: MEETING, label: "SPEAKER_00", name: "Rico")
        try ProjectsAPI.setMeetingProject(f.app, id: MEETING, name: "Hiring")
        let m = f.tools

        var found = try m.searchMeetings(query: "what did we decide about the offer")
        #expect(found["understood"] == .strings(["In decisions"]))
        let hit = try #require(found["meetings"]?.arrayValue?.first)
        #expect(strings(hit["notes"]) == ["Decision: Make an offer"] && strings(hit["lines"]) == [])
        #expect(try m.searchMeetings(query: "offer", project: "Hiring", person: "Rico", since: "2026-10-01")["meetings"]?.truthy == true)
        #expect(try m.searchMeetings(query: "offer", person: "Nobody")["meetings"] == .array([]))
        #expect(try m.searchMeetings(query: "offer", until: "2026-10-01")["meetings"] == .array([]))
        found = try m.searchMeetings(query: "salary", organization: "ACB")
        #expect(found["understood"] == .strings(["ACB"]) && found["meetings"] == .array([]))

        let entry = try #require(try MeetingsAPI.listMeetings(app: f.app).first)
        m.meaning = { _, _, _ in
            guard case .object(var fields) = entry else { return [] }
            fields.append(("meaning", .array([
                .object([("kind", .string("line")), ("speaker", .string("Rico")), ("start", .double(1.0)),
                         ("text", .string("Welcome to the debrief.")), ("score", .double(0.83))]),
                .object([("kind", .string("decision")), ("text", .string("Make an offer")), ("score", .double(0.81))]),
            ])))
            return [.object(fields)]
        }
        let meaning = try #require(try m.searchMeetings(query: "Gehalt")["meetings"]?.arrayValue?.first)  // no word matches
        #expect(meaning["matched_by"] == .string("meaning"))
        #expect(strings(meaning["lines"]) == ["[0:01] Rico: Welcome to the debrief."] && strings(meaning["notes"]) == ["Decision: Make an offer"])
    }

    @Test func test_search_parameters_cannot_break_out_of_their_filter() throws {
        let f = try Fixture()
        try f.meeting()
        _ = try PeopleAPI.nameSpeaker(f.app, id: MEETING, label: "SPEAKER_00", name: "Rico")
        let m = f.tools
        var found = try m.searchMeetings(query: "salary", person: #"Rico" is:reviewed "x"#)
        #expect(found["understood"] == .strings(["Rico is:reviewed x"]))  // one odd name, not a second filter
        found = try m.searchMeetings(query: "salary", organization: #""ACB""#)
        #expect(found["understood"] == .strings(["ACB"]) && found["meetings"] == .array([]))
        #expect(try m.searchMeetings(query: "salary", organization: "\"")["understood"] == .array([]))  // nothing left: no filter
        #expect(refused("since must be a date like 2026-10-01 (or 2026-10, or a month name); got 'last tuesday-ish'") {
            try m.searchMeetings(query: "salary", since: "last tuesday-ish")
        })
        #expect(refused("until must be a date like 2026-10-01 (or 2026-10, or a month name); got '2026-13-45'") {
            try m.searchMeetings(query: "salary", until: "2026-13-45")
        })
        #expect(try m.searchMeetings(query: "salary", since: "2026-10-01", until: "2026-10-31")["meetings"]?.truthy == true)
    }

    // MARK: - meetings kept on this Mac (#53)

    @Test func test_lists_and_search_leave_out_meetings_kept_on_this_mac() throws {
        let f = try Fixture()
        try f.withAPrivateMeeting()
        let m = f.tools
        #expect(ids(try m.listMeetings()) == [MEETING])
        #expect(ids(try m.listMeetings(project: "Hiring")) == [MEETING])
        #expect(ids(try m.searchMeetings(query: "salary")["meetings"]) == [MEETING])  // both transcripts say it
        #expect(try m.searchMeetings(query: "Confidential")["meetings"] == .array([]))
        for answer in [try m.listMeetings(), try m.searchMeetings(query: "salary"), try m.searchMeetings(query: "merger"),
                       try m.searchMeetings(query: "Mara"), try m.searchMeetings(query: "secret deal")] {
            noSecrets(answer)  // not even as a name or project the query was read as
        }
    }

    @Test func test_search_by_meaning_leaves_out_meetings_kept_on_this_mac() throws {
        let f = try Fixture()
        try f.withAPrivateMeeting()
        let m = f.tools
        let every = try MeetingsAPI.listMeetings(app: f.app)
        func withPiece(_ e: JSONValue, _ text: String) -> JSONValue {
            guard case .object(var fields) = e else { return e }
            fields.append(("meaning", .array([.object([("kind", .string("decision")), ("text", .string(text)), ("score", .double(0.9))])])))
            return .object(fields)
        }
        var asked: [Set<ScalarKey>] = []
        m.meaning = { _, exclude, _ in
            asked.append(exclude)
            return every.filter { !exclude.contains(ScalarKey($0["id"]?.stringValue ?? "")) }.map { withPiece($0, "Confidential merger") }
        }
        var found = try m.searchMeetings(query: "Übernahme")
        #expect(asked == [[ScalarKey(PRIVATE)]])  // not even searched
        #expect(ids(found["meetings"]) == [MEETING])
        m.meaning = { _, _, _ in every.map { withPiece($0, "x") } }
        found = try m.searchMeetings(query: "Übernahme")
        #expect(ids(found["meetings"]) == [MEETING])  // and dropped if it came
    }

    @Test func test_the_window_still_finds_meetings_kept_on_this_mac() throws {
        let f = try Fixture()
        try f.withAPrivateMeeting()
        #expect(Set(ids(.array(try SearchAPI.search(f.app, "salary", userName: "Timo")))) == [MEETING, PRIVATE])
    }

    @Test func test_get_meeting_says_it_is_kept_on_this_mac() throws {
        let f = try Fixture()
        try f.withAPrivateMeeting()
        let expected = #"{"id": "2026-10-26T09-00-00", "kept_on_this_mac": true, "message": "This meeting is kept on this Mac; it is not shared with Claude."}"#
        #expect(dumps(try f.tools.getMeeting(meetingId: PRIVATE)) == expected)
        #expect(dumps(try f.tools.getMeeting(meetingId: PRIVATE, includeTranscript: true)) == expected)
        #expect(dumps(try f.tools.getMeeting(meetingId: PRIVATE, fromMinute: 0, toMinute: 5)) == expected)
    }

    @Test func test_projects_people_and_next_steps_leave_them_out() throws {
        let f = try Fixture()
        try f.withAPrivateMeeting()
        let m = f.tools
        let projects = try m.listProjects()
        #expect(projects.arrayValue?.map { $0["name"] } == [.string("Hiring")])  // "Secret deal" has only the private meeting
        #expect(projects.arrayValue?.first?["meetings"] == .int(1))
        let hiring = try m.getProject(project: "Hiring")
        #expect(ids(hiring["meetings"]) == [MEETING])
        #expect(Set((hiring["next_steps"]?.arrayValue ?? []).compactMap { $0["meeting"]?.stringValue }) == [MEETING])
        for name in ["Secret deal", "No such project"] {  // a project of private meetings only answers like one that doesn't exist
            #expect(refused("no project '\(name)'; list_projects shows them") { try m.getProject(project: name) })
        }
        #expect(refused("no project 'Secret deal'; list_projects shows them") { try m.listMeetings(project: "Secret deal") })
        #expect(Set((try m.openNextSteps().arrayValue ?? []).compactMap { $0["meeting"]?.stringValue }) == [MEETING])
        #expect(try m.openNextSteps(owner: "Mara") == .array([]))
        #expect(!(try m.listPeople().arrayValue ?? []).contains { $0["name"] == .string("Mara Hidden") })
        for answer in [projects, hiring, try m.openNextSteps(), try m.listPeople()] { noSecrets(answer) }
    }

    @Test func test_the_served_tools_keep_them_out_too() throws {
        let f = try Fixture()
        try f.withAPrivateMeeting()
        let text = dumps(f.call("get_meeting", [("meeting_id", .string(PRIVATE)), ("include_transcript", .bool(true))]))
        #expect(text.contains("kept on this Mac") && !text.contains("salary") && !text.contains("Confidential"))
    }

    @Test func test_get_meeting_has_the_users_own_notes_unless_kept_on_this_mac() throws {
        let f = try Fixture()
        try f.withAPrivateMeeting()
        _ = try MyNotes.save(f.paths().folder, paragraphs: .array([
            .object([("text", .string("Ask about the salary band")), ("at", .null)]),
            .object([("text", .string("They said **yes**")), ("at", .int(14))])]))
        _ = try MyNotes.save(f.paths(PRIVATE).folder, paragraphs: .array([.object([("text", .string("Confidential merger price")), ("at", .int(3))])]))
        #expect(try f.tools.getMeeting(meetingId: MEETING)["my_notes"] == .string("Ask about the salary band\n[00:14] They said **yes**"))
        let hidden = try f.tools.getMeeting(meetingId: PRIVATE)
        #expect(hidden["kept_on_this_mac"] == .bool(true) && hidden["my_notes"] == nil && !dumps(hidden).contains("merger price"))
        try f.meeting("2026-10-25T09-00-00")
        #expect(try f.tools.getMeeting(meetingId: "2026-10-25T09-00-00")["my_notes"] == nil)
    }

    @Test func test_get_meeting_keeps_which_decisions_came_from_the_users_notes() throws {
        let f = try Fixture()
        try f.meeting()
        try f.notes { McpSetup.set(&$0, "decisions_mine", .array([.int(0)])) }
        #expect(try f.tools.getMeeting(meetingId: MEETING)["notes"]?["decisions_mine"] == .array([.int(0)]))
    }

    @Test func test_a_meeting_is_called_what_the_user_renamed_it_to() throws {
        let f = try Fixture()
        try f.meeting()
        _ = try ChangesAPI.setTitle(f.app, id: MEETING, title: .string("Offer for Rico"))
        #expect(try f.tools.listMeetings().arrayValue?.first?["title"] == .string("Offer for Rico"))
        #expect(try f.tools.getMeeting(meetingId: MEETING)["title"] == .string("Offer for Rico"))
        #expect(try f.tools.searchMeetings(query: "salary")["meetings"]?.arrayValue?.first?["title"] == .string("Offer for Rico"))
    }

    @Test func test_a_meeting_without_any_title_is_called_by_its_time() throws {
        let f = try Fixture()
        try f.meeting()
        try FileManager.default.removeItem(at: f.paths().notes)
        let expected = JSONValue.string(Titles.fallback("2026-10-27T16:03:07+01:00"))
        #expect(try f.tools.listMeetings().arrayValue?.first?["title"] == expected)
        #expect(try f.tools.getMeeting(meetingId: MEETING)["title"] == expected)
    }

    // MARK: - the transcript

    @Test func theTranscriptStopsAt400LinesAndSaysHowToAskForTheRest() throws {
        let f = try Fixture()
        let paths = try f.meeting()
        let lines: [JSONValue] = (0..<450).map { i in
            Utterance(speaker: "SPEAKER_00", start: Double(i) * 2, end: Double(i) * 2 + 1.5, text: "Line \(i) of the debrief.").json
        }
        try Data(PythonJSON.dumps(.array(lines)).utf8).write(to: paths.transcriptJson)
        let m = try f.tools.getMeeting(meetingId: MEETING, includeTranscript: true)
        #expect(m["transcript"]?.arrayValue?.count == 400)
        #expect(m["transcript_truncated"] == .string("50 more lines; ask again with from_minute/to_minute"))
        let part = try f.tools.getMeeting(meetingId: MEETING, fromMinute: 10, toMinute: 11)  // 600 s ..< 660 s
        #expect(part["transcript"]?.arrayValue?.count == 30 && part["transcript_truncated"] == nil)
        #expect(strings(part["transcript"]).first?.hasPrefix("[10:00] ") == true)
        #expect(McpTools.clock(3725.9) == "1:02:05" && McpTools.clock(59.9) == "0:59")
    }

    // MARK: - the protocol

    @Test func initializeNamesTheServerGivesItsInstructionsAndRecordsTheClient() throws {
        let f = try Fixture()
        f.session.start()
        defer { f.session.stop() }
        let r = try #require(f.request("initialize", .object([
            ("protocolVersion", .string("2025-06-18")), ("capabilities", .object([])),
            ("clientInfo", .object([("name", .string("claude-code")), ("version", .string("2.1.3"))]))]))?["result"])
        #expect(r["protocolVersion"] == .string("2025-06-18"))
        #expect(r["serverInfo"] == .object([("name", .string("meetings")), ("version", .string("0.6.0"))]))
        #expect(r["instructions"]?.stringValue?.hasPrefix("The user's recorded meetings (mostly Microsoft Teams calls") == true)
        #expect(r["instructions"]?.stringValue?.hasSuffix("Meetings the user keeps on this Mac are not shared here.") == true)
        #expect(r["capabilities"]?["tools"] == .object([("listChanged", .bool(false))]))
        // The window sees the client in the heartbeat file.
        let client = try #require(McpLog.clients(stores: f.stores).first)
        #expect(client["client"] == .object([("name", .string("claude-code")), ("version", .string("2.1.3"))]))
        #expect(client["pid"] == .int(Int(getpid())) && client["calls"] == .int(0))
        // An unknown version is answered with the newest one.
        #expect(f.request("initialize", .object([("protocolVersion", .string("1999-01-01"))]))?["result"]?["protocolVersion"]
                == .string(McpServer.PROTOCOL_VERSIONS[0]))
    }

    @Test func notificationsGetNoAnswerAndUnknownMethodsAndBadLinesGetErrors() throws {
        let f = try Fixture()
        #expect(f.server.handle(.object([("jsonrpc", .string("2.0")), ("method", .string("notifications/initialized"))])) == nil)
        #expect(f.request("ping")?["result"] == .object([]))
        let missing = try #require(f.request("sampling/nothing")?["error"])
        #expect(missing["code"] == .int(-32601) && missing["message"] == .string("Method not found"))
        let bad = try #require(f.server.handle(line: Data("{not json".utf8)))
        #expect(bad.contains("-32700") && !bad.contains("\n"))
        #expect(f.server.handle(line: Data("   ".utf8)) == nil)
        #expect(f.request("tools/call", .object([]))?["error"]?["code"] == .int(-32602))
        #expect(f.request("prompts/list")?["result"]?["prompts"] == .array([]))
    }

    @Test func toolErrorsReachClaudeAsErrorResultsWithTheirTextOnlyWhenDeliberate() throws {
        let f = try Fixture()
        try f.meeting()
        func text(_ r: JSONValue) -> String { r["content"]?.arrayValue?.first?["text"]?.stringValue ?? "" }
        var r = f.call("zzz")
        #expect(r["isError"] == .bool(true) && text(r) == "Unknown tool: zzz")
        r = f.call("list_meetings", [("limit", .string("abc"))])
        #expect(r["isError"] == .bool(true)
                && text(r) == "Error executing tool list_meetings: 1 validation error for list_meetingsArguments\nlimit\n  Input should be a valid integer")
        r = f.call("get_meeting", [])
        #expect(text(r).hasSuffix("meeting_id\n  Field required"))
        r = f.call("get_project", [("project", .string("nope"))])
        #expect(r["isError"] == .bool(true) && text(r) == "Error executing tool get_project: no project 'nope'; list_projects shows them")
        r = f.call("get_meeting", [("meeting_id", .string("2026-01-01T00-00-00"))])  // not there: nothing of the error goes out
        #expect(r["isError"] == .bool(true) && text(r) == "Error executing tool get_meeting")
        // Lax arguments as the Python SDK took them: a number's text, a flag's word.
        r = f.call("list_meetings", [("limit", .string("1")), ("project", .null)])
        #expect(r["isError"] == .bool(false) && r["structuredContent"]?["result"]?.arrayValue?.count == 1)
        r = f.call("get_meeting", [("meeting_id", .string(MEETING)), ("include_transcript", .string("yes"))])
        #expect(r["structuredContent"]?["transcript"]?.arrayValue?.count == 3)
    }

    @Test func aToolsAnswerIsItsJsonOneTextPerListItemAndTheSameValueStructured() throws {
        let f = try Fixture()
        try f.meeting()
        try f.meeting("2026-10-26T09-00-00")
        let list = f.call("list_meetings")
        let content = try #require(list["content"]?.arrayValue)
        #expect(content.count == 2 && content.allSatisfy { $0["type"] == .string("text") })
        let first = try PythonJSON.parse(Data((content[0]["text"]?.stringValue ?? "").utf8))
        #expect(first["id"] == .string(MEETING) && content[0]["text"]?.stringValue?.contains("\n  \"id\": ") == true)  // indent 2
        #expect(list["structuredContent"]?["result"]?.arrayValue?.count == 2)
        let meeting = f.call("get_meeting", [("meeting_id", .string(MEETING))])
        #expect(meeting["content"]?.arrayValue?.count == 1 && meeting["structuredContent"]?["id"] == .string(MEETING))
        #expect(f.call("list_projects")["content"] == .array([]))  // an empty list: no text at all, as Python sent it
        let search = f.call("search_meetings", [("query", .string("salary"))])
        #expect(search["content"]?.arrayValue?.count == 1 && search["structuredContent"]?["understood"] == .array([]))
    }

    // MARK: - the access log (#45)

    @Test func everyCallLeavesOneLineTheWindowReads() throws {
        let f = try Fixture()
        try f.withAPrivateMeeting()
        f.session.start()
        defer { f.session.stop() }
        _ = f.request("initialize", .object([("clientInfo", .object([("name", .string("Claude Desktop")), ("version", .int(1))]))]))
        _ = f.call("search_meetings", [("query", .string(String(repeating: "salary ", count: 30))), ("limit", .int(10))])
        _ = f.call("get_meeting", [("meeting_id", .string(MEETING)), ("include_transcript", .bool(true))])
        _ = f.call("open_next_steps")
        _ = f.call("get_project", [("project", .string("Secret deal"))])
        _ = f.call("list_meetings", [("limit", .string("x"))])  // refused before it ran: no line

        let log = try f.log()  // newest first
        #expect(log.map { $0["tool"] } == [.string("get_project"), .string("open_next_steps"), .string("get_meeting"), .string("search_meetings")])
        let search = log[3]
        if case .object(let fields) = search {  // mcp_access.Session.record's keys, in its order
            #expect(fields.map(\.0) == ["time", "pid", "client", "tool", "args", "out", "ms", "meetings"])
        }
        #expect(search["pid"] == .int(Int(getpid())) && search["client"] == .object([("name", .string("Claude Desktop")), ("version", .string("1"))]))
        let query = try #require(search["args"]?["query"]?.stringValue)  // the limit is the default: not logged
        #expect(search["args"]?["limit"] == nil && query.unicodeScalars.count == 120 && query.hasSuffix("…"))
        #expect(search["out"]?["meetings"] == .int(1) && search["out"]?["lines"] == .int(1) && search["out"]?["chars"]?.truthy == true)
        #expect(search["meetings"] == .strings([MEETING]) && search["time"]?.stringValue?.count == 25)
        let get = log[2]
        #expect(get["args"] == .object([("meeting_id", .string(MEETING)), ("include_transcript", .bool(true))]))
        #expect(get["out"]?["meetings"] == .int(1) && get["out"]?["lines"] == .int(3) && get["meetings"] == .strings([MEETING]))
        #expect(log[1]["out"]?["next_steps"] == .int(1) && log[1]["out"]?["meetings"] == .int(1) && log[1]["args"] == .object([]))
        #expect(log[0]["error"] == .string("no project 'Secret deal'; list_projects shows them") && log[0]["out"] == .object([])
                && log[0]["meetings"] == nil)
        // The window's view of one meeting's reads, and of the client's calls.
        #expect(try McpLog.read(meeting: MEETING, stores: f.stores).map { $0["tool"] } == [.string("open_next_steps"), .string("get_meeting"), .string("search_meetings")])
        let client = try #require(McpLog.clients(stores: f.stores).first)
        #expect(client["calls"] == .int(4) && client["last_tool"] == .string("get_project") && client["last_call"]?.truthy == true)
        #expect(!dumps(.array(log)).contains(PRIVATE))
    }

    // MARK: - lifetime

    @Test func theHeartbeatGoesWhenTheServerStopsOrItsClientIsGone() throws {
        let f = try Fixture()
        let beat = f.stores.mcpDir.appendingPathComponent("\(getpid()).json")
        f.session.start()
        #expect(FileManager.default.fileExists(atPath: beat.path))
        f.session.stop()
        #expect(!FileManager.default.fileExists(atPath: beat.path))
        f.session.beat()  // nothing brings it back
        #expect(!FileManager.default.fileExists(atPath: beat.path))

        f.session.start()
        let parent = Shared(Int32(100))
        let gone = Shared(false)
        let t = f.session.watchParent(interval: 0.02, beatEvery: 0.01, parent: { parent.value }, gone: { gone.value = true })
        Thread.sleep(forTimeInterval: 0.1)
        #expect(FileManager.default.fileExists(atPath: beat.path) && !gone.value)
        parent.value = 1  // reparented to launchd: the client died
        #expect(until(3) { gone.value })
        #expect(!FileManager.default.fileExists(atPath: beat.path))
        #expect(until(3) { t.isFinished })
    }
}
