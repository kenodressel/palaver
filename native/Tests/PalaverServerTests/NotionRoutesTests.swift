// Notion in the window (#34): where uploads go (Settings), a meeting's Notion page (opened only on Notion's own hosts),
// and Upload to Notion (Again) — refused for a meeting kept on this Mac. NotionService against a fake transport (no
// network, a key store in a file, config.toml in a temporary folder); the routes against a fake NotionLink. Fake
// workspace, ids and URLs only; Valerie records, Timo Strauß is the other side.
import Foundation
import Testing
import PalaverCloud
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let ID = "2026-10-29T10-00-00"
private let TOKEN = "secret_notion_test_0123456789abcdefghijklmnop"
private let PAGE = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
private let OTHER = "1a2b3c4d5e6f47589a0b1c2d3e4f5a6b"
private let API = "https://api.notion.com/v1"
private let NEW_PAGE = "https://www.notion.so/Budget-review-9a8b7c6d5e4f40312a1b0c9d8e7f6a5b"

@discardableResult
private func meeting(_ root: URL, _ name: String = ID) throws -> RecordingPaths {
    let paths = RecordingPaths(root.appendingPathComponent(name, isDirectory: true))
    try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
    try PythonJSON.write(.object([("start_time", .string("2026-10-29T10:00:00+01:00")), ("duration_seconds", .int(1500))]),
                         to: paths.meta, indent: nil, ensureAscii: true)
    try PythonJSON.write(.array([Utterance(speaker: "Valerie", start: 0, end: 2, text: "Hallo zusammen.").json,
                                 Utterance(speaker: "Timo Strauß", start: 5, end: 9, text: "Das Budget steht.").json]),
                         to: paths.transcriptJson, indent: nil, ensureAscii: true)
    return paths
}

/// Notion's answers by method and URL, each request kept.
private final class FakeNotionAPI: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: (Int, String)]
    private(set) var requests: [URLRequest] = []

    init(_ answers: [String: (Int, String)]) { self.answers = answers }

    func set(_ route: String, _ status: Int, _ body: String) { lock.withLock { answers[route] = (status, body) } }

    var client: HTTPClient {
        HTTPClient(transport: { [self] request in
            let route = "\(request.httpMethod ?? "GET") \(request.url!.absoluteString)"
            let answer = lock.withLock { () -> (Int, String)? in
                requests.append(request)
                return answers[route]
            }
            // What Notion answers for what it doesn't have, or doesn't share with the integration.
            let (status, body) = answer ?? (404, #"{"message": "Could not find it."}"#)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }, sleep: { _ in })
    }

    var gets: Int { lock.withLock { requests.filter { $0.httpMethod == "GET" }.count } }
}

/// config.toml, a key store and a clock of their own for a NotionService.
private final class Setup {
    let dir = tempFolder("notion")
    var now = 1_000_000.0
    lazy var stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                                 home: dir.appendingPathComponent("home", isDirectory: true))
    lazy var keys = FileKeyStore(dir.appendingPathComponent("keychain.json"))
    var toml: URL { dir.appendingPathComponent("config.toml") }

    func config(_ notion: String) throws { try Data("[notion]\n\(notion)\n".utf8).write(to: toml) }

    func service(_ api: FakeNotionAPI, env: [String: String] = ["NOTION_TOKEN": TOKEN]) -> NotionService {
        NotionService(configURL: toml, stores: stores, keys: keys, env: env, http: api.client, clock: { [unowned self] in now })
    }

    deinit { try? FileManager.default.removeItem(at: dir) }
}

private func contoso() -> FakeNotionAPI {
    FakeNotionAPI([
        "GET \(API)/users/me": (200, #"{"bot": {"workspace_name": "Contoso"}}"#),
        "GET \(API)/pages/\(PAGE)": (200, #"{"object": "page", "url": "https://www.notion.so/Meetings-0f1e2d3c", "properties": {"title": {"type": "title", "title": [{"plain_text": "Meetings"}]}}}"#),
        "POST \(API)/pages": (200, #"{"id": "9a8b7c6d", "url": "\#(NEW_PAGE)"}"#),
    ])
}

@Suite struct NotionServiceTests {
    @Test func withoutATokenNotionIsNotSetUpAndNothingIsAsked() throws {
        let s = Setup()
        try s.config("parent_page_id = \"\(PAGE)\"")
        let api = contoso()
        let service = s.service(api, env: [:])
        #expect(service.configured() == nil && service.target() == nil)
        #expect(api.requests.isEmpty)
    }

    @Test func theTargetIsDescribedOnceForAFewMinutes() throws {
        let s = Setup()
        try s.config("parent_page_id = \"\(PAGE)\"\nauto_sync = false")
        let api = contoso()
        let service = s.service(api)
        #expect(service.configured() == NotionTarget(mode: "page", id: PAGE))
        let t = try #require(service.target())
        #expect(t["workspace"] == .string("Contoso") && t["title"] == .string("Meetings") && t["mode"] == .string("page"))
        #expect(t["url"] == .string("https://www.notion.so/Meetings-0f1e2d3c") && t["error"] == .null)
        #expect(t["auto_sync"] == .bool(false))
        #expect(api.gets == 2)
        s.now += NotionService.TARGET_SECONDS - 1
        _ = service.target()
        #expect(api.gets == 2)  // cached
        s.now += 2
        _ = service.target()
        #expect(api.gets == 4)  // asked again
    }

    @Test func aChangedTargetIsAskedAtOnceAndAProblemSoonAgain() throws {
        let s = Setup()
        try s.config("parent_page_id = \"\(PAGE)\"")
        let api = contoso()
        let service = s.service(api)
        _ = service.target()
        try s.config("mode = \"database\"\ndatabase_id = \"\(OTHER)\"")  // edited while the server runs
        #expect(service.configured() == NotionTarget(mode: "database", id: OTHER))
        let t = try #require(service.target())
        #expect(t["mode"] == .string("database") && t["error"]?.stringValue?.contains("isn't shared with the integration") == true)
        let before = api.gets
        api.set("GET \(API)/databases/\(OTHER)", 200, #"{"object": "database", "title": [{"plain_text": "Calls"}], "url": "https://www.notion.so/1a2b"}"#)
        s.now += NotionService.ERROR_SECONDS + 1  // the page was shared meanwhile
        #expect(service.target()?["title"] == .string("Calls") && api.gets == before + 2)
    }

    @Test func anUploadIsTheWorkersAndRecordsWhereItWent() throws {
        let s = Setup()
        try s.config("parent_page_id = \"\(PAGE)\"")
        let api = contoso()
        let service = s.service(api)
        let paths = try meeting(s.dir)
        _ = service.target()  // Settings asked: the workspace is known
        #expect(try service.upload(paths) == NEW_PAGE)
        let create = try #require(api.requests.last { $0.httpMethod == "POST" })
        #expect(create.value(forHTTPHeaderField: "Authorization") == "Bearer \(TOKEN)")
        let body = try #require(create.httpBody.flatMap { try? PythonJSON.parse($0) })
        #expect(body["parent"] == .object([("page_id", .string(PAGE))]))
        let info = try #require(NotionSync.info(paths))
        #expect(info.url == NEW_PAGE && info.target == NotionTarget(mode: "page", id: PAGE) && info.workspace == "Contoso")
        let log = try String(contentsOf: paths.sessionLog, encoding: .utf8)
        #expect(log.contains("notion_upload_start") && log.contains("notion_upload_done") && !log.contains(TOKEN))
    }

    @Test func aRefusedUploadWritesNoNotionJsonAndLogsWithoutTheToken() throws {
        let s = Setup()
        try s.config("parent_page_id = \"\(PAGE)\"")
        let api = contoso()
        api.set("POST \(API)/pages", 400, #"{"message": "validation failed for \#(TOKEN)"}"#)
        let paths = try meeting(s.dir)
        #expect(throws: NotionError.self) { try s.service(api).upload(paths) }
        #expect(NotionSync.info(paths) == nil)
        #expect(try !String(contentsOf: paths.sessionLog, encoding: .utf8).contains(TOKEN))
    }
}

/// What the routes ask of Notion: a target, and uploads that write notion.json as the real one does.
private final class FakeNotion: NotionLink, @unchecked Sendable {
    var now: NotionTarget? = NotionTarget(mode: "page", id: PAGE)
    var described: JSONValue? = .object([("mode", .string("page")), ("id", .string(PAGE)), ("workspace", .string("Contoso")),
                                         ("title", .string("Meetings")), ("url", .string("https://www.notion.so/Meetings-0f1e2d3c")),
                                         ("error", .null), ("auto_sync", .bool(true))])
    var uploads: [String] = []
    var refuse: Error?

    func configured() -> NotionTarget? { now }
    func target() -> JSONValue? { described }
    func upload(_ paths: RecordingPaths) throws -> String {
        if let refuse { throw refuse }
        uploads.append(paths.folder.lastPathComponent)
        try NotionSync.writeInfo(paths, url: NEW_PAGE, target: now, workspace: "Contoso")
        return NEW_PAGE
    }
}

@Suite struct NotionRoutesTests {
    func server(_ notion: NotionLink = FakeNotion(), opened: @escaping (String) -> Void = { _ in }) throws -> TestServer {
        try TestServer(userName: "Valerie", openURL: opened, notion: notion, meetings: { try meeting($0) })
    }

    @Test func settingsShowWhereUploadsGoOrThatNotionIsNotSetUp() throws {
        let s = try server()
        defer { s.stop() }
        let t = try #require(s.get("/api/notion").json)
        #expect(t["set_up"] == .bool(true) && t["workspace"] == .string("Contoso") && t["title"] == .string("Meetings"))
        let none = try server(StubNotionLink())
        defer { none.stop() }
        #expect(none.get("/api/notion").json == .object([("set_up", .bool(false))]))
    }

    @Test func aMeetingNotInNotionHasNoLinkAndOffersTheUploadWhileNotionIsSetUp() throws {
        let s = try server()
        defer { s.stop() }
        let page = try #require(s.get("/api/meetings/\(ID)").json)
        #expect(page["notion"] == .null && page["notion_set_up"] == .bool(true))
        let none = try server(StubNotionLink())
        defer { none.stop() }
        #expect(none.get("/api/meetings/\(ID)").json?["notion_set_up"] == .bool(false))
    }

    @Test func uploadingLinksThePageAndAChangedTargetLeavesItWhereItIs() throws {
        let notion = FakeNotion()
        let s = try server(notion)
        defer { s.stop() }
        let r = s.post("/api/meetings/\(ID)/notion/upload")
        #expect(r.status == 200 && notion.uploads == [ID])
        #expect(r.json?["notion"]?["url"] == .string(NEW_PAGE) && r.json?["notion"]?["elsewhere"] == .bool(false))
        var page = try #require(s.get("/api/meetings/\(ID)").json)
        #expect(page["notion"]?["url"] == .string(NEW_PAGE) && page["notion"]?["workspace"] == .string("Contoso"))
        #expect(page["notion"]?["uploaded_at"]?.stringValue != nil)
        notion.now = NotionTarget(mode: "database", id: OTHER)  // the target changed in config.toml
        page = try #require(s.get("/api/meetings/\(ID)").json)
        #expect(page["notion"]?["url"] == .string(NEW_PAGE) && page["notion"]?["elsewhere"] == .bool(true))
        #expect(notion.uploads == [ID])  // nothing went again by itself
    }

    @Test func aMeetingKeptOnThisMacIsNotUploaded() throws {
        let notion = FakeNotion()
        let s = try server(notion)
        defer { s.stop() }
        #expect(s.post("/api/meetings/\(ID)/local-only", .object([("on", .bool(true))])).status == 200)
        let r = s.post("/api/meetings/\(ID)/notion/upload")
        #expect(r.status == 400 && r.error == NotionAPI.KEPT_HERE && notion.uploads.isEmpty)
    }

    @Test func aMeetingImportedFromNotionIsNotUploadedBack() throws {
        let notion = FakeNotion()
        let s = try server(notion)
        defer { s.stop() }
        let paths = RecordingPaths(s.app.outputDir.appendingPathComponent(ID, isDirectory: true))
        try PythonJSON.write(.object([("kind", .string("notion")), ("url", .string("https://www.notion.so/Northwind-sync-77aa"))]),
                             to: paths.source, indent: nil, ensureAscii: true)
        let r = s.post("/api/meetings/\(ID)/notion/upload")
        #expect(r.status == 400 && r.error == NotionAPI.FROM_NOTION && notion.uploads.isEmpty)
    }

    @Test func noUploadWithoutNotionAndNotionsRefusalIsShown() throws {
        let none = try server(StubNotionLink())
        defer { none.stop() }
        #expect(none.post("/api/meetings/\(ID)/notion/upload").error == NotionAPI.NOT_SET_UP)
        let notion = FakeNotion()
        notion.refuse = NotionError("Notion create_page failed: 400 {\"message\": \"validation failed\"}")
        let s = try server(notion)
        defer { s.stop() }
        let r = s.post("/api/meetings/\(ID)/notion/upload")
        #expect(r.status == 502 && r.error == "Notion create_page failed: 400 {\"message\": \"validation failed\"}")
        notion.refuse = Conflict(NotionService.BUSY)
        #expect(s.post("/api/meetings/\(ID)/notion/upload").status == 409)
    }

    @Test func openInNotionOpensTheMeetingsOwnPageOnly() throws {
        final class Opened: @unchecked Sendable { var urls: [String] = [] }
        let opened = Opened()
        let s = try server(opened: { opened.urls.append($0) })
        defer { s.stop() }
        #expect(s.post("/api/meetings/\(ID)/notion/open").error == NotionAPI.NOT_UPLOADED)
        let paths = RecordingPaths(s.app.outputDir.appendingPathComponent(ID, isDirectory: true))
        try NotionSync.writeInfo(paths, url: NEW_PAGE)
        let r = s.post("/api/meetings/\(ID)/notion/open")
        #expect(r.status == 200 && opened.urls == [NEW_PAGE])
        try NotionSync.writeInfo(paths, url: "file:///Applications/Calculator.app")  // a hand-edited notion.json
        #expect(s.post("/api/meetings/\(ID)/notion/open").error == NotionAPI.NOT_NOTION && opened.urls == [NEW_PAGE])
        // Settings' Open in Notion: where uploads go.
        #expect(s.post("/api/notion/open").status == 200 && opened.urls.last == "https://www.notion.so/Meetings-0f1e2d3c")
    }

    @Test(arguments: [("https://www.notion.so/Budget-9a8b", true), ("https://contoso.notion.site/Budget-9a8b", true),
                      ("https://app.notion.com/p/9a8b", true), ("https://notion.so/9a8b", true),
                      ("http://www.notion.so/9a8b", false), ("https://notion.so.contoso.example/9a8b", false),
                      ("https://evilnotion.so/9a8b", false), ("https://user@www.notion.so/9a8b", false),
                      ("https://www.notion.so:8443/9a8b", false), ("javascript:alert(1)", false), ("", false)])
    func onlyNotionsOwnHostsCountAsItsPages(url: String, ok: Bool) {
        #expect(NotionAPI.isNotionPage(url) == ok)
    }
}
