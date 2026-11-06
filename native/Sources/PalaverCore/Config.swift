import Foundation

/// config.toml, the keys the app reads (inventory section 9), each with Palaver's default.
/// A missing file, a bad value or an unknown key never fails: the default stands.
/// Tokens are only noted as present, never kept or logged.
public struct Config: Equatable, Sendable {
    public var userName = "User"
    public var outputDir = URL(fileURLWithPath: NSString(string: "~/Meetings/Recordings").expandingTildeInPath, isDirectory: true)
    public var retentionDays = 14
    public var maxSessionHours = 4
    public var gracePeriodSeconds = 10
    public var recordSlack = true
    public var processingLive = true
    public var notionMode = "page"
    public var notionParentPageId: String?
    public var notionDatabaseId: String?
    public var notionAutoSyncSetting = true
    /// A `[notion].token` is in the file (or NOTION_TOKEN is set). The Keychain fallback is not looked at here.
    public var hasNotionToken = false
    public var hasHfToken = false
    public var notesEnabled = true
    public var notesEngine = "local"
    public var notesLocalModel = "mlx-community/gemma-4-12B-it-OptiQ-4bit"
    public var calendarEnabled = true
    /// `[memory]` budgets in GB by key (live_gb ...); unknown keys and values <= 0 are dropped.
    public var memory: [String: Double] = [:]

    public static let memoryKeys: Set<String> = ["live_gb", "stream_gb", "process_gb", "notes_gb", "index_gb"]

    /// Upload after the call (run) rather than process + notes: needs a token (Config.notion_auto_sync).
    public var notionAutoSync: Bool { hasNotionToken && notionAutoSyncSetting }

    public init() {}

    public init(toml text: String, environment: [String: String] = [:]) {
        let t = Toml.parse(text)
        func str(_ k: String) -> String? { if case .string(let s)? = t[k] { return s } else { return nil } }
        func int(_ k: String) -> Int? {
            switch t[k] { case .int(let n)?: return n; case .double(let d)?: return Int(exactly: d.rounded(.towardZero)); default: return nil }
        }
        func bool(_ k: String) -> Bool? { if case .bool(let b)? = t[k] { return b } else { return nil } }

        if let v = str("user.name") { userName = v }
        if let v = str("recording.output_dir"), !v.isEmpty {
            outputDir = URL(fileURLWithPath: NSString(string: v).expandingTildeInPath, isDirectory: true)
        }
        if let v = int("recording.retention_days") { retentionDays = v }
        if let v = int("recording.max_session_hours"), v > 0 { maxSessionHours = v }
        if let v = int("recording.grace_period_seconds"), v >= 0 { gracePeriodSeconds = v }
        if let v = bool("recording.slack") { recordSlack = v }
        if let v = bool("processing.live") { processingLive = v }
        if let v = str("notion.mode"), v == "page" || v == "database" { notionMode = v }
        notionParentPageId = str("notion.parent_page_id")
        notionDatabaseId = str("notion.database_id")
        if let v = bool("notion.auto_sync") { notionAutoSyncSetting = v }
        hasNotionToken = !(str("notion.token") ?? environment["NOTION_TOKEN"] ?? "").isEmpty
        hasHfToken = !(str("hf.token") ?? environment["HF_TOKEN"] ?? "").isEmpty
        if let v = bool("notes.enabled") { notesEnabled = v }
        if let v = str("notes.engine"), v == "local" || v == "claude" { notesEngine = v }
        if let v = str("notes.local_model"), !v.isEmpty { notesLocalModel = v }
        if let v = bool("calendar.enabled") { calendarEnabled = v }
        for key in Config.memoryKeys {
            switch t["memory." + key] {
            case .int(let n)? where n > 0: memory[key] = Double(n)
            case .double(let d)? where d > 0: memory[key] = d
            default: break
            }
        }
    }

    /// The file at `url`; the defaults when it is missing or unreadable.
    public static func load(_ url: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config(toml: "", environment: environment) }
        return Config(toml: String(decoding: data, as: UTF8.self), environment: environment)
    }
}
