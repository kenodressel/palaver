// Settings → Updates and the setup assistant's "Share anonymous usage numbers" (#6): the exact ping the menu bar app
// would send, with this Mac's values, and "New ID". The switch itself is settings.json's `share_usage`
// (/api/settings); the app sends (StatsPing), the window only shows.
import Foundation
import PalaverCore
import PalaverDomain

public enum UsageStatsAPI {
    /// This Palaver's version: the bundle's, or a checkout's VERSION.
    public static func currentVersion() -> String {
        AppLocation(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).version()
    }

    /// `{"share_usage", "check_updates", "body", "page", "last_sent"}`: `body` is the ping byte for byte (the install
    /// id is made now when there is none: it is shown before anything is sent), `page` the public totals, `last_sent`
    /// the UTC day of the last ping taken (null: never).
    public static func status(_ app: ServerApp, version: String = currentVersion(), macos: String = UsageStats.macOS(),
                              environment: [String: String] = ProcessInfo.processInfo.environment) throws -> JSONValue {
        let settings = SettingsFile.load(defaults: app.settingsDefaults, stores: app.stores)
        let support = app.stores.support
        let install = try UsageStats.installID(support: support)
        let endpoint = UsageStats.endpoint(environment: environment)
        return .object([
            ("share_usage", .bool(settings.shareUsage)),
            ("check_updates", .bool(settings.checkUpdates)),
            ("body", .string(UsageStats.body(install: install, version: version, macos: macos))),
            ("page", .string(UsageStats.page(endpoint: endpoint))),
            ("last_sent", .str(UsageStats.lastSent(support: support))),
        ])
    }

    /// "New ID": the install id is replaced; the status with the new one.
    public static func newID(_ app: ServerApp, version: String = currentVersion(), macos: String = UsageStats.macOS(),
                             environment: [String: String] = ProcessInfo.processInfo.environment) throws -> JSONValue {
        try UsageStats.newInstallID(support: app.stores.support)
        return try status(app, version: version, macos: macos, environment: environment)
    }

    /// The public page in the browser (the window follows no link itself); only the page of the endpoint pings go to.
    public static func openPage(_ app: ServerApp, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> JSONValue {
        let endpoint = UsageStats.endpoint(environment: environment)
        guard UsageStats.sendable(endpoint) != nil else { throw Refused("The page with the numbers is not set up yet.") }
        let page = UsageStats.page(endpoint: endpoint)
        app.openURL(page)
        return .object([("opened", .string(page))])
    }
}

extension Router {
    static func addUsageStatsRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/usage-stats") { _, _ in .json(try UsageStatsAPI.status(app)) }
        r.post("/api/usage-stats/new-id") { _, _ in .json(try UsageStatsAPI.newID(app)) }
        r.post("/api/usage-stats/open-page") { _, _ in .json(try UsageStatsAPI.openPage(app)) }
    }
}
