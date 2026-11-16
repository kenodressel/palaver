// Next steps into Todoist and a Notion to-do database (#18), against stub transports: what each request carries, the
// token kept out of every error, a create never sent twice, the Notion database found from a pasted link and its
// columns matched by name.
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverCloud

private let TODOIST_TOKEN = "0123456789abcdef0123456789abcdef01234567"
private let NOTION_TOKEN = "secret_notion_0123456789abcdefghijklmnopqrstuvwxyz"
private let TODOIST = "https://api.todoist.com/rest/v2"
private let NOTION = "https://api.notion.com/v1"
private let DB = "0123abcd-0123-4567-89ab-0123456789ab"

private func task(_ text: String, owner: String? = nil, due: String? = nil, link: String? = nil) -> FollowUpTask {
    FollowUpTask(text: text, owner: owner, due: due, meeting: "Budget review, 2026-10-29", link: link)
}

@Suite struct TodoistTests {
    @Test func aTaskCarriesTheStepItsDueDayAndWhereItCameFrom() async throws {
        let fake = Routes(["POST \(TODOIST)/tasks": [.ok(#"{"id": "8001", "url": "https://app.todoist.com/app/task/8001"}"#)]])
        let client = TodoistClient(token: TODOIST_TOKEN, projectId: "220", http: fake.client)
        var got: [AddedTask] = []
        try await client.add([task("Send the figures", owner: "Timo Strauß", due: "2026-10-30")]) { _, added in got.append(added) }
        #expect(got == [AddedTask(id: "8001", url: "https://app.todoist.com/app/task/8001")])
        let r = fake.requests[0]
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer \(TODOIST_TOKEN)")
        #expect(!(r.value(forHTTPHeaderField: "X-Request-Id") ?? "").isEmpty)
        let body = try #require(fake.json(r))
        #expect(body["content"] == .string("Timo Strauß: Send the figures"))
        #expect(body["description"] == .string("From the meeting “Budget review, 2026-10-29” (Palaver)"))
        #expect(body["due_date"] == .string("2026-10-30") && body["project_id"] == .string("220"))
    }

    @Test func theUsersOwnStepHasNoOwnerAndTheInboxIsTheDefault() async throws {
        let fake = Routes(["POST \(TODOIST)/tasks": [.ok(#"{"id": 8002}"#)]])
        var ids: [String] = []
        try await TodoistClient(token: TODOIST_TOKEN, http: fake.client).add([task("Book a room", link: "https://www.notion.so/p1")]) {
            ids.append($1.id)
        }
        let body = try #require(fake.json(fake.requests[0]))
        #expect(ids == ["8002"] && body["content"] == .string("Book a room"))
        #expect(body["project_id"] == nil && body["due_date"] == nil)
        #expect(body["description"]?.stringValue?.hasSuffix("\nhttps://www.notion.so/p1") == true)
    }

    @Test func aRefusedTokenSaysSoWithoutTheToken() async throws {
        let fake = Routes(["POST \(TODOIST)/tasks": [.json(401, "Forbidden: \(TODOIST_TOKEN)")]])
        let error = await #expect(throws: CloudError.self) {
            try await TodoistClient(token: TODOIST_TOKEN, http: fake.client).add([task("x")]) { _, _ in }
        }
        #expect(error?.message.contains("Todoist refused") == true && error?.message.contains(TODOIST_TOKEN) == false)
    }

    @Test func aCreateThatMayHaveArrivedIsNotSentAgain() async throws {
        let fake = Routes(["POST \(TODOIST)/tasks": [.json(500, #"{"error": "oops"}"#)]])
        var added = 0
        await #expect(throws: CloudError.self) {
            try await TodoistClient(token: TODOIST_TOKEN, http: fake.client).add([task("a"), task("b")]) { _, _ in added += 1 }
        }
        #expect(fake.requests.count == 1 && added == 0)
    }

    @Test func theProjectsTheInboxFirstFromEitherAPI() async throws {
        let v2 = Routes(["GET \(TODOIST)/projects": [.ok("""
            [{"id": "220", "name": "Contoso"}, {"id": "100", "name": "Inbox", "is_inbox_project": true}]
            """)]])
        let projects = try await TodoistClient(token: TODOIST_TOKEN, http: v2.client).projects()
        #expect(projects.map(\.name) == ["Inbox", "Contoso"] && projects[0].inbox && projects[1].id == "220")
        let v1 = Routes(["GET \(TODOIST)/projects": [.ok(#"{"results": [{"id": "7", "name": "Northwind", "inbox_project": false}]}"#)]])
        #expect(try await TodoistClient(token: TODOIST_TOKEN, http: v1.client).projects().map(\.id) == ["7"])
    }
}

@Suite struct NotionTasksTests {
    @Test(arguments: [
        ("https://www.notion.so/contoso/Tasks-0123abcd0123456789ab0123456789ab?v=fedcba9876543210fedcba9876543210", DB),
        ("0123abcd0123456789ab0123456789ab", DB),
        ("  0123ABCD-0123-4567-89AB-0123456789AB  ", DB),
        ("https://www.notion.so/Cafe0123abcd0123456789ab0123456789ab/", DB),
    ])
    func theDatabaseIsFoundInWhatWasPasted(text: String, id: String) {
        #expect(NotionTaskDatabase.databaseId(text) == id)
    }

    @Test func somethingWithoutAnIdIsNone() {
        #expect(NotionTaskDatabase.databaseId("https://www.notion.so/contoso/Tasks") == nil)
        #expect(NotionTaskDatabase.databaseId("") == nil)
    }

    static let schema = """
        {"object": "database", "title": [{"plain_text": "Aufgaben"}],
         "properties": {"Aufgabe": {"type": "title"}, "Fällig": {"type": "date"}, "Erledigt": {"type": "checkbox"},
                        "Verantwortlich": {"type": "rich_text"}, "Besprechung": {"type": "rich_text"}, "Link": {"type": "url"}}}
        """

    @Test func checkSaysWhichColumnsATaskFills() async throws {
        let fake = Routes(["GET \(NOTION)/databases/\(DB)": [.ok(Self.schema)]])
        let info = try await NotionTaskDatabase(client: NotionClient(token: NOTION_TOKEN, http: fake.client), databaseId: DB).check()
        #expect(info == NotionTaskDatabase.Info(title: "Aufgaben", titleColumn: "Aufgabe", due: "Fällig", owner: "Verantwortlich",
                                                meeting: "Besprechung", link: "Link"))
    }

    @Test func aDatabaseNotSharedWithTheIntegrationSaysHowToShareIt() async throws {
        let fake = Routes(["GET \(NOTION)/databases/\(DB)": [.json(404, #"{"message": "Could not find database"}"#)]])
        let error = await #expect(throws: NotionError.self) {
            _ = try await NotionTaskDatabase(client: NotionClient(token: NOTION_TOKEN, http: fake.client), databaseId: DB).check()
        }
        #expect(error?.description.contains("share it with your integration") == true)
    }

    @Test func aRowFillsTheColumnsTheDatabaseHasAndLeavesTheCheckboxAlone() async throws {
        let fake = Routes(["GET \(NOTION)/databases/\(DB)": [.ok(Self.schema)],
                           "POST \(NOTION)/pages": [.ok(#"{"id": "row-1", "url": "https://www.notion.so/row-1"}"#)]])
        var got: [AddedTask] = []
        try await NotionTaskDatabase(client: NotionClient(token: NOTION_TOKEN, http: fake.client), databaseId: DB)
            .add([task("Zahlen schicken", owner: "Timo Strauß", due: "2026-10-30", link: "https://www.notion.so/meeting-1")]) {
                got.append($1)
            }
        #expect(got == [AddedTask(id: "row-1", url: "https://www.notion.so/row-1")])
        let body = try #require(fake.json(fake.sent("POST", "\(NOTION)/pages")[0]))
        #expect(body["parent"] == .object([("database_id", .string(DB))]))
        let props = try #require(body["properties"])
        #expect(props["Aufgabe"]?["title"]?.arrayValue?.first?["text"]?["content"] == .string("Zahlen schicken"))
        #expect(props["Verantwortlich"]?["rich_text"]?.arrayValue?.first?["text"]?["content"] == .string("Timo Strauß"))
        #expect(props["Fällig"]?["date"]?["start"] == .string("2026-10-30"))
        #expect(props["Besprechung"]?["rich_text"]?.arrayValue?.first?["text"]?["content"] == .string("Budget review, 2026-10-29"))
        #expect(props["Link"]?["url"] == .string("https://www.notion.so/meeting-1") && props["Erledigt"] == nil)
        #expect(PythonJSON.dumps(body["children"] ?? .null).contains("https://www.notion.so/meeting-1"))
    }

    @Test func withoutAnOwnerColumnTheOwnerIsInTheTitle() async throws {
        let schema = #"{"properties": {"Name": {"type": "title"}, "Status": {"type": "status"}}}"#
        let fake = Routes(["GET \(NOTION)/databases/\(DB)": [.ok(schema)], "POST \(NOTION)/pages": [.ok(#"{"id": "row-2"}"#)]])
        try await NotionTaskDatabase(client: NotionClient(token: NOTION_TOKEN, http: fake.client), databaseId: DB)
            .add([task("Send the figures", owner: "Kim")]) { _, _ in }
        let props = try #require(fake.json(fake.sent("POST", "\(NOTION)/pages")[0])?["properties"])
        #expect(props["Name"]?["title"]?.arrayValue?.first?["text"]?["content"] == .string("Kim: Send the figures"))
        #expect(props["Status"] == nil)
    }

    @Test func aRowThatFailsStopsWithWhatWentThroughOnRecord() async throws {
        let fake = Routes(["GET \(NOTION)/databases/\(DB)": [.ok(Self.schema)],
                           "POST \(NOTION)/pages": [.ok(#"{"id": "row-1"}"#), .json(400, #"{"message": "bad title"}"#)]])
        var got: [Int] = []
        let error = await #expect(throws: NotionError.self) {
            try await NotionTaskDatabase(client: NotionClient(token: NOTION_TOKEN, http: fake.client), databaseId: DB)
                .add([task("a"), task("b")]) { i, _ in got.append(i) }
        }
        #expect(got == [0] && error?.description == "Notion answered HTTP 400: bad title")
    }
}
