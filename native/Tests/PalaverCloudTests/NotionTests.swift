// The Notion upload (notion_client.py, cli.py `_cmd_sync`) against a stub: page mode, database mode with German column
// names, the blocks (bold speaker, wall time, text), 100 blocks per request, which statuses are retried and which not.
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverCloud

private let TOKEN = "secret_notion_0123456789abcdefghijklmnopqrstuvwxyz"
private let API = "https://api.notion.com/v1"

private func utterance(_ speaker: String, _ start: Double, _ text: String) -> Utterance {
    Utterance(speaker: speaker, start: start, end: start + 1, text: text)
}

@Suite struct NotionTests {
    @Test func blocksAreTheBoldSpeakerTheWallTimeAndTheText() throws {
        let start = try #require(Py.fromIso("2026-10-20T14:30:00+02:00"))
        let blocks = try NotionClient.blocks([utterance("Valerie", 75.4, "Guten Morgen.")], start: start,
                                             timeZone: TimeZone(secondsFromGMT: 7200)!)
        #expect(PythonJSON.dumps(blocks[0], ensureAscii: false) == """
            {"object": "block", "type": "paragraph", "paragraph": {"rich_text": [{"type": "text", "text": {"content": "Valerie"}, \
            "annotations": {"bold": true}}, {"type": "text", "text": {"content": " [14:31:15]"}}, {"type": "text", "text": \
            {"content": "  Guten Morgen."}}]}}
            """)
    }

    @Test func aPageUnderTheParentWithTheRestAppended100AtATime() async throws {
        let fake = Routes(["POST \(API)/pages": [.ok(#"{"id": "p1", "url": "https://www.notion.so/p1"}"#)],
                           "PATCH \(API)/blocks/p1/children": [.ok("{}")]])
        let blocks = (0..<250).map { JSONValue.object([("n", .int($0))]) }
        let url = try await NotionClient(token: TOKEN, http: fake.client).createPage(parentPageId: "parent-1", title: "T", blocks: blocks)
        #expect(url == "https://www.notion.so/p1")
        let create = try #require(fake.json(fake.requests[0]))
        #expect(create["parent"] == .object([("page_id", .string("parent-1"))]))
        #expect(create["properties"]?["title"]?["title"]?.arrayValue?.first?["text"]?["content"] == .string("T"))
        #expect(create["children"]?.arrayValue?.count == 100)
        let appends = fake.sent("PATCH", "\(API)/blocks/p1/children").compactMap { fake.json($0)?["children"]?.arrayValue }
        #expect(appends.map(\.count) == [100, 50] && appends[1].first?["n"] == .int(200))
        let headers = fake.requests[0].allHTTPHeaderFields ?? [:]
        #expect(headers["Authorization"] == "Bearer \(TOKEN)" && headers["Notion-Version"] == "2022-06-28")
        #expect(fake.requests.allSatisfy { $0.url?.host == "api.notion.com" })
    }

    @Test func aDatabaseRowFillsTheColumnsItHasGermanNamesToo() async throws {
        let schema = """
            {"properties": {"Name": {"type": "title"}, "Datum": {"type": "date"}, "Dauer (min)": {"type": "number"},
                            "Teilnehmer": {"type": "number"}, "Quelle": {"type": "select"}, "Notizen": {"type": "rich_text"}}}
            """
        let fake = Routes(["GET \(API)/databases/db1": [.ok(schema)],
                           "POST \(API)/pages": [.ok(#"{"id": "p2", "url": "https://www.notion.so/p2"}"#)]])
        let url = try await NotionClient(token: TOKEN, http: fake.client).createDatabasePage(
            databaseId: "db1", title: "Sync", blocks: [], start: "2026-10-20T14:30:00+02:00", durationMinutes: 42.26, speakers: 3,
            source: "Teams")
        #expect(url == "https://www.notion.so/p2")
        let create = try #require(fake.json(fake.sent("POST", "\(API)/pages")[0]))
        #expect(create["parent"] == .object([("database_id", .string("db1"))]))
        let props = try #require(create["properties"])
        #expect(props["Name"]?["title"]?.arrayValue?.first?["text"]?["content"] == .string("Sync"))
        #expect(props["Datum"]?["date"]?["start"] == .string("2026-10-20T14:30:00+02:00"))
        #expect(props["Dauer (min)"]?["number"] == .double(42.3) && props["Teilnehmer"]?["number"] == .int(3))
        #expect(props["Quelle"]?["select"]?["name"] == .string("Teams") && props["Notizen"] == nil)
    }

    @Test func aRateLimitIsWaitedOutAndTriedAgain() async throws {
        let fake = Routes(["POST \(API)/pages": [.json(429, "{}"), .json(503, "{}"), .ok(#"{"id": "p1", "url": "u"}"#)]])
        _ = try await NotionClient(token: TOKEN, http: fake.client).createPage(parentPageId: "x", title: "T", blocks: [])
        #expect(fake.requests.count == 3 && fake.waits.count == 2)
        #expect(fake.waits[0] >= 0.5 && fake.waits[0] <= 0.625 && fake.waits[1] >= 1.0 && fake.waits[1] <= 1.25)
    }

    @Test func retryAfterWinsAndIsCapped() async throws {
        let fake = FakeTransport(.answer(429, ["Retry-After": "120"], "{}"), .answer(200, [:], #"{"id": "p1", "url": "u"}"#))
        _ = try await NotionClient(token: TOKEN, http: fake.client).createPage(parentPageId: "x", title: "T", blocks: [])
        #expect(fake.waits == [30.0])
    }

    @Test(arguments: [400, 401, 404, 500])
    func otherErrorsAreNotRetriedTheyCouldDuplicateThePage(status: Int) async {
        let fake = Routes(["POST \(API)/pages": [.json(status, #"{"message": "nope"}"#)]])
        let e = await thrown { try await NotionClient(token: TOKEN, http: fake.client).createPage(parentPageId: "x", title: "T", blocks: []) }
        #expect((e as? NotionError)?.description == "Notion create_page failed: \(status) {\"message\": \"nope\"}")
        #expect(fake.requests.count == 1 && fake.waits.isEmpty)
    }

    @Test func aConnectionThatNeverReachedNotionIsRetriedOneThatMayHaveIsNot() async throws {
        let fake = FakeTransport(.fail(URLError(.cannotConnectToHost)), .answer(200, [:], #"{"id": "p1", "url": "u"}"#))
        _ = try await NotionClient(token: TOKEN, http: fake.client).createPage(parentPageId: "x", title: "T", blocks: [])
        #expect(fake.requests.count == 2)
        let dropped = FakeTransport(.fail(URLError(.networkConnectionLost)), .answer(200, [:], "{}"))
        let e = await thrown { try await NotionClient(token: TOKEN, http: dropped.client).createPage(parentPageId: "x", title: "T", blocks: []) }
        #expect((e as? URLError)?.code == .networkConnectionLost && dropped.requests.count == 1)
    }

    @Test func theSyncPlanIsTheReadableTranscript() async throws {
        let dir = tempFolder("notion")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = RecordingPaths(dir.appendingPathComponent("2026-10-20T14-30-00"))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        try PythonJSON.write(.array([utterance("Timo", 1, "Hallo zusammen.").json, utterance("Valerie", 5, "Mm-hmm.").json,
                                     utterance("Valerie", 9, "Los geht's.").json]), to: paths.transcriptJson, indent: 2, ensureAscii: true)
        try PythonJSON.write(.object([("start_time", .string("2026-10-20T14:30:00+02:00")), ("duration_seconds", .double(1500)),
                                      ("trigger", .string("teams"))]), to: paths.meta, indent: 2, ensureAscii: true)
        let plan = try NotionSync.plan(paths, glossary: Glossary(path: dir.appendingPathComponent("glossary.json")))
        #expect(plan.blocks.count == 2)  // the filler-only turn is left out
        #expect(plan.title == "2026-10-20 14:30 — Meeting (25 min, 2 speakers)")
        #expect(plan.source == "Teams" && plan.speakers == 2 && plan.durationMinutes == 25)
        var config = Config()
        config.notionParentPageId = nil
        let e = await thrown { try await NotionSync.upload(plan, config: config, token: TOKEN, client: NotionClient(token: TOKEN, http: Routes().client)) }
        #expect((e as? NotionError)?.description == "[notion].parent_page_id is required")
        try NotionSync.writeInfo(paths, url: "https://www.notion.so/p1")
        let info = PythonJSON.read(paths.notionInfo)
        #expect(info?["page_url"] == .string("https://www.notion.so/p1"))
        #expect(info?["uploaded_at"]?.stringValue.flatMap { Py.fromIso($0) } != nil)
    }
}
