// Notion in this process (#34): where uploads go, as Settings shows it, and Upload to Notion from a meeting's ⋯ menu.
// Uploads once went to the wrong workspace unnoticed; the window now names the workspace and the page or database, and
// links every uploaded meeting's page.
//
// config.toml is read again for each call, so a changed target shows without a restart. Notion is asked where uploads
// go at most every TARGET_SECONDS (an answer that says what is wrong every ERROR_SECONDS, so a page shared meanwhile
// shows soon). The token is read only for a request and never kept, logged or shown.
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

public final class NotionService: NotionLink, @unchecked Sendable {
    public static let TARGET_SECONDS = 300.0
    public static let ERROR_SECONDS = 30.0
    /// The budget of the lookup Settings waits for.
    public static let TARGET_TIMEOUT = 60.0
    /// The budget of an upload: a long meeting is many requests of 100 blocks.
    public static let UPLOAD_TIMEOUT = 600.0
    public static let BUSY = "This meeting is being uploaded to Notion already."
    public static let NO_TOKEN = "Notion isn't set up: no Notion token in config.toml, the environment or the Keychain"

    let configURL: URL
    let stores: StorePaths
    let keys: KeyStore
    let env: [String: String]
    let http: HTTPClient
    let base: String
    let clock: () -> Double

    private let lock = NSLock()
    private var cached: (key: String, at: Double, described: NotionSync.Described)?
    private var uploading: Set<String> = []

    /// `base`: Notion's API (the end-to-end tests' stub in a debug build); `clock`: seconds, for the cache.
    public init(configURL: URL, stores: StorePaths, keys: KeyStore, env: [String: String] = ProcessInfo.processInfo.environment,
                http: HTTPClient = HTTPClient(), base: String = NotionClient.BASE_URL,
                clock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.configURL = configURL
        self.stores = stores
        self.keys = keys
        self.env = env
        self.http = http
        self.base = base
        self.clock = clock
    }

    /// `PALAVER_TEST_NOTION_API` (debug builds only): the stub Notion the end-to-end tests run, instead of Notion.
    public static let TEST_API = "PALAVER_TEST_NOTION_API"

    /// Notion's API as `env` says: Notion's own, or the end-to-end tests' stub in a debug build.
    public static func api(env: [String: String]) -> String {
        #if DEBUG
        if let stub = env[TEST_API], !stub.isEmpty { return stub }
        #endif
        return NotionClient.BASE_URL
    }

    func config() -> Config { Config.load(configURL, environment: env) }

    /// Whether there is a token, never reading it (the Keychain by its attributes only).
    func hasToken() -> Bool { Tokens.present(Tokens.NOTION, configToml: configURL, env: env, keys: keys) }

    public func configured() -> NotionTarget? {
        guard hasToken() else { return nil }
        return NotionTarget.configured(config())
    }

    public func target() -> JSONValue? {
        guard hasToken() else { return nil }
        let config = config()
        guard let described = describe(config) else { return nil }
        return described.json.adding("auto_sync", .bool(config.notionAutoSyncSetting))
    }

    /// What Notion said of the target `config` names, from the cache while it is fresh; nil without a token.
    func describe(_ config: Config) -> NotionSync.Described? {
        let key = "\(config.notionMode) \(NotionTarget.configured(config)?.id ?? "")"
        let now = clock()
        if let c = lock.withLock({ cached }), c.key == key,
           now - c.at < (c.described.error == nil ? Self.TARGET_SECONDS : Self.ERROR_SECONDS) {
            return c.described
        }
        guard let token = Tokens.value(Tokens.NOTION, configToml: configURL, env: env, keys: keys) else { return nil }
        let client = NotionClient(token: token, base: base, http: http)
        let described: NotionSync.Described
        do {
            described = try runBlocking(timeout: Self.TARGET_TIMEOUT) { await NotionSync.describe(config: config, token: token, client: client) }
        } catch {
            var late = NotionSync.Described(mode: config.notionMode, id: NotionTarget.configured(config)?.id)
            late.error = "Notion did not answer within \(Int(Self.TARGET_TIMEOUT)) seconds"
            described = late
        }
        lock.withLock { cached = (key, now, described) }
        return described
    }

    /// The workspace of the target `config` names, when Settings asked Notion for it lately: an upload records it
    /// without another request.
    func knownWorkspace(_ config: Config) -> String? {
        let key = "\(config.notionMode) \(NotionTarget.configured(config)?.id ?? "")"
        return lock.withLock { cached?.key == key ? cached?.described.workspace : nil }
    }

    public func upload(_ paths: RecordingPaths) throws -> String {
        let folder = paths.folder.path
        // Two clicks would make two pages.
        guard lock.withLock({ uploading.insert(folder).inserted }) else { throw Conflict(Self.BUSY) }
        defer { lock.withLock { _ = uploading.remove(folder) } }
        let config = config()
        guard let token = Tokens.value(Tokens.NOTION, configToml: configURL, env: env, keys: keys) else {
            throw Unavailable(Self.NO_TOKEN)
        }
        let log = SessionLog(url: paths.sessionLog, logger: "palaver")
        do {
            let plan = try NotionSync.plan(paths, glossary: Glossary.current(stores: stores))
            log.event("notion_upload_start", logger: "palaver", [("blocks", plan.blocks.count), ("from", "window")])
            let client = NotionClient(token: token, base: base, http: http)
            let url = try runBlocking(timeout: Self.UPLOAD_TIMEOUT) {
                try await NotionSync.upload(plan, config: config, token: token, client: client)
            }
            try NotionSync.writeInfo(paths, url: url, target: NotionTarget.configured(config), workspace: knownWorkspace(config))
            log.event("notion_upload_done", logger: "palaver", [("page_url", url), ("from", "window")])
            return url
        } catch {
            log.message("upload to Notion failed: \(HTTPClient.redactedDescription(error, key: token))", level: "ERROR", logger: "palaver")
            throw error
        }
    }
}
