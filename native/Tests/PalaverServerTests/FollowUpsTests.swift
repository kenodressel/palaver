// Follow-ups after a call (#18): the recap email as a draft for the mail app, the next steps into Todoist or a Notion
// to-do database (the user's own by default, each once), the due day read from a step, and Settings → Follow-ups.
// Synthetic meetings only: Valerie records, Timo Strauß and Kim are the others; the services are stubs.
import Foundation
import Testing
import PalaverCloud
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let ID = "2026-10-29T10-00-00"
private let TODOIST_TOKEN = "0123456789abcdef0123456789abcdef01234567"
private let NOTION_TOKEN = "secret_notion_0123456789abcdefghijklmnopqrstuvwxyz"
private let DB = "0123abcd-0123-4567-89ab-0123456789ab"

private func write(_ v: JSONValue, _ url: URL) throws { try PythonJSON.write(v, to: url, indent: nil, ensureAscii: true) }

@discardableResult
private func meeting(_ root: URL, german: Bool = false, steps: [(String, String)]? = nil) throws -> RecordingPaths {
    let paths = RecordingPaths(root.appendingPathComponent(ID, isDirectory: true))
    try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
    try write(.object([("start_time", .string("2026-10-29T10:00:00+01:00")), ("duration_seconds", .int(1500))]), paths.meta)
    let utterances = german
        ? [Utterance(speaker: "Valerie", start: 0, end: 2, text: "Hallo zusammen, das ist der Plan und wir sind uns einig."),
           Utterance(speaker: "SPEAKER_00", start: 5, end: 8, text: "Ich schicke die Zahlen bis Freitag.", label: "SPEAKER_00")]
        : [Utterance(speaker: "Valerie", start: 0, end: 2, text: "Hello everyone, this is the plan and we all agree."),
           Utterance(speaker: "SPEAKER_00", start: 5, end: 8, text: "I will send the figures by Friday.", label: "SPEAKER_00")]
    try write(.array(utterances.map(\.json)), paths.transcriptJson)
    try write(.object([("SPEAKER_00", .string("Timo Strauß"))]), paths.speakers)
    let next = steps ?? [("SPEAKER_00", "Send the figures by Friday"), ("Valerie", "Book a room for 18 Nov"), ("", "Ask Northwind")]
    try NotesFile.save(paths, .object([
        ("title", .string("Budget review")), ("summary", .string("SPEAKER_00 presented the budget.")),
        ("sections", .array([])),
        ("next_steps", .array(next.map { .object([("owner", .string($0.0)), ("task", .string($0.1))]) })),
        ("decisions", .strings(["Budget approved"])),
        ("speaker_names", .array([])), ("transcript_hash", .string(Notes.transcriptHash(utterances))),
    ]))
    let start = try PyDateTime.parse("2026-10-29T10:00:00+01:00")
    try CalendarEvents.save(paths, CalendarEvent(title: "Budget review", start: start, end: start.adding(micros: 1_800_000_000), attendees: [
        Attendee(name: "Valerie", email: "valerie@contoso.example", organizer: true, isSelf: true),
        Attendee(name: "Timo Strauß", email: "timo@contoso.example"),
        Attendee(name: "Kim", email: "KIM@northwind.example"),
        Attendee(name: "Kim", email: "kim@northwind.example"),
        Attendee(name: "Room 4", email: "room4@contoso.example", isRoom: true),
        Attendee(name: "Anna", email: nil),
    ]))
    return paths
}

/// A stub transport: each "METHOD url" answers its list in turn (the last one again); anything else can't connect.
private final class Stub: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: [(Int, String)]]
    private(set) var requests: [URLRequest] = []

    init(_ routes: [String: [(Int, String)]]) { self.routes = routes }

    var client: HTTPClient {
        HTTPClient(transport: { [self] request in
            let route = "\(request.httpMethod ?? "GET") \(request.url!.absoluteString)"
            let answer: (Int, String)? = lock.withLock {
                requests.append(request)
                guard var list = routes[route], !list.isEmpty else { return nil }
                let a = list.count > 1 ? list.removeFirst() : list[0]
                routes[route] = list
                return a
            }
            guard let (status, body) = answer else { throw URLError(.cannotConnectToHost) }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }, sleep: { _ in })
    }

    func bodies(_ method: String, _ url: String) -> [JSONValue] {
        lock.withLock { requests }.filter { $0.httpMethod == method && $0.url?.absoluteString == url }
            .compactMap { $0.httpBody.flatMap { try? PythonJSON.parse($0) } }
    }
}

private final class Opened: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

private func server(german: Bool = false, steps: [(String, String)]? = nil, keys: [String: String] = [:]) throws -> TestServer {
    let s = try TestServer(userName: "Valerie", meetings: { try meeting($0, german: german, steps: steps) })
    let store = FileKeyStore(s.dir.appendingPathComponent("keychain.json"))
    for (k, v) in keys { try store.write(k, v) }
    s.app.keys = store
    s.app.draftsDir = s.dir.appendingPathComponent("drafts", isDirectory: true)
    return s
}

private let TASKS = "https://api.todoist.com/api/v1/tasks"

@Suite struct FollowUpsTests {
    // MARK: whose step

    @Test func aStepIsMineByMyNameAnEarlierNameOrMyFirstName() {
        let me: Set<String> = ["valerie kim", "vally"]
        #expect(FollowUps.isMine("Valerie Kim", me: me) && FollowUps.isMine("valerie", me: me) && FollowUps.isMine("Vally", me: me))
        #expect(FollowUps.isMine("Timo Strauß and Valerie", me: me) && FollowUps.isMine("Timo, Valerie Kim", me: me))
        #expect(!FollowUps.isMine("Timo Strauß", me: me) && !FollowUps.isMine("", me: me) && !FollowUps.isMine("Kim", me: me))
    }

    @Test func aStepKeepsItsKeyWhenItsSpeakerIsNamedLater() {
        let stored = JSONValue.object([("next_steps", .array([.object([("owner", .string("SPEAKER_00")), ("task", .string("Send it"))])]))])
        let shown = JSONValue.object([("next_steps", .array([.object([("owner", .string("Timo")), ("task", .string("Send it"))])]))])
        let steps = FollowUps.steps(shown: shown, stored: stored, me: ["valerie"])
        #expect(steps.map(\.owner) == ["Timo"] && steps[0].key == FollowUps.key(owner: "SPEAKER_00", task: "Send it"))
    }

    // MARK: due days

    @Test(arguments: [
        ("Send the figures by Friday", "2026-10-30"),             // the meeting was on a Thursday
        ("Zahlen bis Freitag schicken", "2026-10-30"),
        ("Call Kim tomorrow", "2026-10-30"),
        ("Morgen ab 15 Uhr anrufen", "2026-10-30"),
        ("Heute Nachmittag die Folien schicken", "2026-10-29"),
        ("Book a room for 18 Nov", "2026-11-18"),
        ("Raum buchen bis 18.11.", "2026-11-18"),
        ("Vertrag bis 3. Januar prüfen", "2027-01-03"),               // early next year, not this January
        ("Review on November 2nd, then on Monday", "2026-11-02"),     // the first one said
        ("Send it by 2026-12-01", "2026-12-01"),
        ("Bis Ende der Woche fertig", "2026-10-30"),
        ("Thursday sync with Northwind", "2026-11-05"),                // the meeting's own weekday: next week's
        ("Fri 15:30 call", "2026-10-30"),
        ("Übermorgen nachfragen", "2026-10-31"),
    ])
    func aDueDayIsReadAgainstTheMeetingsDay(text: String, due: String) {
        #expect(DueDates.find(text, meeting: "2026-10-29T10:00:00+01:00") == due)
    }

    @Test(arguments: ["Ask Northwind", "Guten Morgen an alle schicken", "Version 2.1.3 ausrollen", "Slides for the next week",
                      "Spend 15.30 euros", "We may 5x the budget"])
    func noDayNoDueDate(text: String) {
        #expect(DueDates.find(text, meeting: "2026-10-29T10:00:00+01:00") == nil)
    }

    // MARK: the recap email

    @Test func theRecapGoesToTheInviteesNotMeNotTheRoomEachOnce() throws {
        let s = try server()
        defer { s.stop() }
        let event = CalendarEvents.load(RecordingPaths(s.app.outputDir.appendingPathComponent(ID)))
        #expect(RecapEmail.recipients(event, me: ["valerie"]).map(\.email) == ["timo@contoso.example", "KIM@northwind.example"])
    }

    @Test func theRecapIsTheSummaryTheDecisionsAndTheStepsWithWhoseTheyAre() throws {
        let s = try server()
        defer { s.stop() }
        let page = try MeetingsAPI.getMeeting(app: s.app, id: ID, calendar: false)
        let d = RecapEmail.draft(page: page, to: [RecapEmail.Recipient(name: "Timo Strauß", email: "timo@contoso.example"),
                                                  RecapEmail.Recipient(name: "Kim", email: "kim@northwind.example")],
                                 userName: "Valerie Kim", language: "en")
        #expect(d.subject == "Recap: Budget review")
        #expect(d.body == """
            Hi all,

            here is a short recap of “Budget review” on 29 October 2026.

            Summary
            Timo Strauß presented the budget.

            Decisions
            - Budget approved

            Next steps
            - Timo Strauß: Send the figures by Friday
            - Valerie: Book a room for 18 Nov
            - Ask Northwind

            Best regards
            Valerie

            """)
    }

    @Test func aGermanMeetingsRecapHasGermanWordsAndOneAddresseeIsGreetedByName() throws {
        let s = try server(german: true)
        defer { s.stop() }
        let page = try MeetingsAPI.getMeeting(app: s.app, id: ID, calendar: false)
        let d = RecapEmail.draft(page: page, to: [RecapEmail.Recipient(name: "Timo Strauß", email: "timo@contoso.example")],
                                 userName: "Valerie", language: "de")
        #expect(d.body.hasPrefix("Hallo Timo,\n\nhier eine kurze Zusammenfassung von „Budget review“ am 29. Oktober 2026.\n"))
        #expect(d.body.contains("\nZusammenfassung\n") && d.body.contains("\nEntscheidungen\n") && d.body.contains("\nNächste Schritte\n"))
        #expect(d.body.hasSuffix("\nViele Grüße\nValerie\n"))
    }

    @Test func theDraftIsAnUnsentMessageTheMailAppOpens() throws {
        let d = RecapEmail.Draft(to: [RecapEmail.Recipient(name: "Timo Strauß", email: "timo@contoso.example"),
                                      RecapEmail.Recipient(name: "Kim", email: "kim@northwind.example")],
                                 subject: "Recap: Budget review", body: "Hi all,\n\nÄnderungen\n")
        let eml = RecapEmail.eml(d)
        let (head, body) = (eml.components(separatedBy: "\r\n\r\n")[0], eml.components(separatedBy: "\r\n\r\n")[1])
        #expect(head.hasPrefix("X-Unsent: 1\r\n"))
        #expect(head.contains("To: =?utf-8?B?VGltbyBTdHJhdcOf?= <timo@contoso.example>,\r\n Kim <kim@northwind.example>\r\n"))
        #expect(head.contains("Subject: Recap: Budget review\r\n") && head.contains("Content-Type: text/plain; charset=utf-8"))
        let decoded = Data(base64Encoded: body.replacingOccurrences(of: "\r\n", with: ""))
        #expect(decoded.map { String(decoding: $0, as: UTF8.self) } == "Hi all,\r\n\r\nÄnderungen\r\n")
        #expect(RecapEmail.encodedWord("Strauß, Timo", phrase: true).hasPrefix("=?utf-8?B?"))
        #expect(RecapEmail.encodedWord("Doe, John") == "Doe, John")
    }

    @Test func theMailtoFallbackCarriesTheAddressesSubjectAndBody() {
        let d = RecapEmail.Draft(to: [RecapEmail.Recipient(name: "", email: "timo@contoso.example")], subject: "Recap: A & B",
                                 body: "Hi Timo,\nok")
        #expect(RecapEmail.mailto(d) == "mailto:timo@contoso.example?subject=Recap%3A%20A%20%26%20B&body=Hi%20Timo%2C%0Aok")
    }

    @Test func draftRecapEmailWritesTheDraftAndOpensIt() throws {
        let s = try server()
        defer { s.stop() }
        let opened = Opened()
        s.app.openDraft = { opened.add($0) }
        let r = s.post("/api/meetings/\(ID)/recap-email")
        #expect(r.status == 200 && r.json?["opened"] == .string("draft") && r.json?["to"] == .int(2))
        let file = try #require(opened.all.first)
        #expect(file.hasSuffix(".eml") && file.hasPrefix(s.app.draftsDir.path))
        let eml = try String(contentsOfFile: file, encoding: .utf8)
        #expect(eml.hasPrefix("X-Unsent: 1\r\nTo: ") && eml.contains("timo@contoso.example") && !eml.contains("valerie@"))
    }

    @Test func aMeetingKeptOnThisMacMayDraftARecap() throws {
        let s = try server()
        defer { s.stop() }
        try LocalOnly.set(s.app.outputDir.appendingPathComponent(ID), on: true)
        let opened = Opened()
        s.app.openDraft = { opened.add($0) }
        #expect(s.post("/api/meetings/\(ID)/recap-email").status == 200 && opened.all.count == 1)
    }

    // MARK: next steps out

    @Test func onlyMyOwnStepsGoByDefaultEachOnceThenTheOthersOnRequest() throws {
        let s = try server(keys: [Tokens.TODOIST: TODOIST_TOKEN])
        defer { s.stop() }
        let stub = Stub(["POST \(TASKS)": [(200, #"{"id": "6X7rM8997g3RQmv1"}"#), (200, #"{"id": "6X7rM8997g3RQmv2"}"#),
                                          (200, #"{"id": "6X7rM8997g3RQmv3"}"#)]])
        s.app.followUpHTTP = stub.client
        let before = try #require(s.get("/api/meetings/\(ID)/follow-ups").json)
        let todoist = before["targets"]?.arrayValue?.first
        #expect(before["mine"] == .int(1) && before["recap_to"] == .strings(["Timo Strauß", "Kim"]))
        #expect(todoist?["problem"] == .null && todoist?["new_mine"] == .int(1) && todoist?["new_all"] == .int(3))

        let first = s.post("/api/meetings/\(ID)/follow-ups/todoist")
        #expect(first.status == 200 && first.json?["added"] == .int(1))
        let sent = stub.bodies("POST", TASKS)
        #expect(sent.map { $0["content"] } == [.string("Book a room for 18 Nov")])
        #expect(sent[0]["due_date"] == .string("2026-11-18"))
        #expect(sent[0]["description"] == .string("From the meeting “Budget review, 2026-10-29” (Palaver)"))

        #expect(s.post("/api/meetings/\(ID)/follow-ups/todoist").json?["added"] == .int(0))  // nothing new
        let all = s.post("/api/meetings/\(ID)/follow-ups/todoist", .object([("others", .bool(true))]))
        #expect(all.json?["added"] == .int(2))
        #expect(stub.bodies("POST", TASKS).dropFirst().map { $0["content"] }
                == [.string("Timo Strauß: Send the figures by Friday"), .string("Ask Northwind")])
        let after = try #require(all.json)
        #expect(after["targets"]?.arrayValue?.first?["sent"] == .int(3) && after["targets"]?.arrayValue?.first?["new_all"] == .int(0))
        #expect(after["steps"]?.arrayValue?.allSatisfy { $0["sent"] == .strings(["todoist"]) } == true)
        let record = try #require(PythonJSON.read(s.app.outputDir.appendingPathComponent("\(ID)/follow-ups.json")))
        #expect(record["todoist"]?.objectCount == 3)
        let entry = try #require(PyDict<JSONValue>(record["todoist"] ?? .null)?.values.first)
        #expect(entry["id"] == .string("6X7rM8997g3RQmv1") && entry["url"] == .string("https://app.todoist.com/app/task/6X7rM8997g3RQmv1"))
        #expect(!(String(data: try Data(contentsOf: s.app.outputDir.appendingPathComponent("\(ID)/follow-ups.json")), encoding: .utf8) ?? "")
            .contains(TODOIST_TOKEN))
    }

    @Test func aMeetingKeptOnThisMacSendsNoTasks() throws {
        let s = try server(keys: [Tokens.TODOIST: TODOIST_TOKEN])
        defer { s.stop() }
        let stub = Stub([:])
        s.app.followUpHTTP = stub.client
        try LocalOnly.set(s.app.outputDir.appendingPathComponent(ID), on: true)
        let r = s.post("/api/meetings/\(ID)/follow-ups/todoist")
        #expect(r.status == 400 && (r.error ?? "").contains("kept on this Mac") && stub.requests.isEmpty)
        #expect(s.get("/api/meetings/\(ID)/follow-ups").json?["local_only"] == .bool(true))
    }

    @Test func withoutATokenTheButtonSaysWhereToAddOne() throws {
        let s = try server()
        defer { s.stop() }
        let r = s.post("/api/meetings/\(ID)/follow-ups/todoist")
        #expect(r.status == 400 && (r.error ?? "").contains("Settings → Follow-ups"))
        let notion = s.get("/api/meetings/\(ID)/follow-ups").json?["targets"]?.arrayValue?.last
        #expect(notion?["problem"]?.stringValue?.contains("No Notion to-do database") == true)
    }

    @Test func aFailurePartWayKeepsWhatWentThrough() throws {
        let s = try server(keys: [Tokens.TODOIST: TODOIST_TOKEN])
        defer { s.stop() }
        let stub = Stub(["POST \(TASKS)": [(200, #"{"id": "6X7rM8997g3RQmv1"}"#), (400, #"{"error": "content too long"}"#)]])
        s.app.followUpHTTP = stub.client
        let r = s.post("/api/meetings/\(ID)/follow-ups/todoist", .object([("others", .bool(true))]))
        #expect(r.status == 502 && (r.error ?? "").contains("1 of 3 added to Todoist, then: HTTP 400: content too long"))
        #expect(!r.text.contains(TODOIST_TOKEN))
        let status = try #require(s.get("/api/meetings/\(ID)/follow-ups").json)
        #expect(status["targets"]?.arrayValue?.first?["sent"] == .int(1))
    }

    @Test func aNotionRowPerStepInTheChosenDatabase() throws {
        let s = try server(keys: [Tokens.NOTION: NOTION_TOKEN])
        defer { s.stop() }
        let stub = Stub(["GET https://api.notion.com/v1/databases/\(DB)": [(200, #"{"properties": {"Task": {"type": "title"}, "Due": {"type": "date"}}}"#)],
                         "POST https://api.notion.com/v1/pages": [(200, #"{"id": "row-1", "url": "https://www.notion.so/row-1"}"#)]])
        s.app.followUpHTTP = stub.client
        #expect(s.post("/api/follow-ups", .object([("notion_database", .string("https://www.notion.so/Tasks-0123abcd0123456789ab0123456789ab"))]))
            .json?["notion"]?["database"] == .string(DB))
        let r = s.post("/api/meetings/\(ID)/follow-ups/notion")
        #expect(r.status == 200 && r.json?["added"] == .int(1))
        let row = try #require(stub.bodies("POST", "https://api.notion.com/v1/pages").first)
        #expect(row["properties"]?["Task"]?["title"]?.arrayValue?.first?["text"]?["content"] == .string("Book a room for 18 Nov"))
        #expect(row["properties"]?["Due"]?["date"]?["start"] == .string("2026-11-18"))
    }

    // MARK: Settings → Follow-ups

    @Test func theTokenIsSavedInTheKeychainAndNeverAnswered() throws {
        let s = try server()
        defer { s.stop() }
        let r = s.post("/api/follow-ups", .object([("todoist_token", .string("  \(TODOIST_TOKEN)  "))]))
        #expect(r.status == 200 && r.json?["todoist"]?["token_set"] == .bool(true) && !r.text.contains(TODOIST_TOKEN))
        #expect(try s.app.keys?.read(Tokens.TODOIST) == TODOIST_TOKEN)
        #expect(!s.get("/api/follow-ups").text.contains(TODOIST_TOKEN))
        #expect(s.post("/api/follow-ups", .object([("todoist_token", .string("two words"))])).status == 400)
        #expect(s.post("/api/follow-ups", .object([("todoist_token_remove", .bool(true))])).json?["todoist"]?["token_set"] == .bool(false))
    }

    @Test func theProjectAndTheDatabaseAreChosen() throws {
        let s = try server()
        defer { s.stop() }
        let r = s.post("/api/follow-ups", .object([("todoist_project", .object([("id", .string("6Jf8VQXxpwv56VQ7")), ("name", .string("Contoso"))]))]))
        #expect(r.json?["todoist"]?["project"] == .object([("id", .string("6Jf8VQXxpwv56VQ7")), ("name", .string("Contoso"))]))
        #expect(s.post("/api/follow-ups", .object([("todoist_project", .null)])).json?["todoist"]?["project"] == .null)
        #expect(s.post("/api/follow-ups", .object([("notion_database", .string("https://www.notion.so/Tasks"))])).status == 400)
        #expect(s.post("/api/follow-ups", .object([("notion_database", .string(""))])).json?["notion"]?["database"] == .string(""))
    }

    @Test func checkListsTodoistsProjectsAndNamesTheNotionDatabase() throws {
        let s = try server(keys: [Tokens.TODOIST: TODOIST_TOKEN, Tokens.NOTION: NOTION_TOKEN])
        defer { s.stop() }
        let stub = Stub(["GET https://api.todoist.com/api/v1/projects?limit=200": [(200, #"{"results": [{"id": "6Jf8VQXxpwv56VQ7", "name": "Contoso"}, {"id": "6Jf8VQXxpwv56VQ8", "name": "Inbox", "inbox_project": true}], "next_cursor": null}"#)],
                         "GET https://api.notion.com/v1/databases/\(DB)": [(404, #"{"message": "not found"}"#),
                                                                          (200, #"{"title": [{"plain_text": "Tasks"}], "properties": {"Name": {"type": "title"}, "Due": {"type": "date"}}}"#)]])
        s.app.followUpHTTP = stub.client
        let todoist = s.post("/api/follow-ups/check", .object([("target", .string("todoist"))]))
        #expect(todoist.json?["text"] == .string("Connected to Todoist: 2 projects."))
        #expect(todoist.json?["projects"]?.arrayValue?.first?["name"] == .string("Inbox"))
        #expect(s.post("/api/follow-ups/check", .object([("target", .string("notion"))])).status == 400)  // no database yet
        _ = s.post("/api/follow-ups", .object([("notion_database", .string(DB))]))
        let missing = s.post("/api/follow-ups/check", .object([("target", .string("notion"))]))
        #expect(missing.status == 502 && (missing.error ?? "").contains("share it with your integration"))
        let ok = s.post("/api/follow-ups/check", .object([("target", .string("notion"))]))
        #expect(ok.json?["text"] == .string("“Tasks” is ready: a step goes into Name and its due date into Due."))
    }
}

private extension JSONValue {
    var objectCount: Int? { if case .object(let f) = self { return f.count } else { return nil } }
}
