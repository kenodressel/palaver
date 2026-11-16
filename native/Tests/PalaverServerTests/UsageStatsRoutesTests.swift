// Settings → Updates' "Share anonymous usage numbers" (#6): the ping as the app would send it, "New ID" and the
// public page. The switch is /api/settings' `share_usage` (SettingsRoutesTests has its place among the switches).
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

@Suite struct UsageStatsRoutesTests {
    private let env = ["PALAVER_STATS_URL": "https://palaver-stats.contoso.workers.dev/ping"]

    @Test func theWindowShowsTheExactPingWithThisMacsValues() throws {
        let s = try TestServer()
        defer { s.stop() }
        let status = try UsageStatsAPI.status(s.app, version: "0.6.8", macos: "15.5", environment: env)
        let id = try UsageStats.installID(support: s.app.stores.support)  // made by the look, kept
        #expect(status == .object([
            ("share_usage", .bool(true)), ("check_updates", .bool(true)),
            ("body", .string(#"{"install": "\#(id)", "version": "0.6.8", "macos": "15.5"}"#)),
            ("page", .string("https://palaver-stats.contoso.workers.dev/")), ("last_sent", .null),
        ]))
        try SettingsFile.update([("share_usage", .bool(false)), ("check_updates", .bool(false))], stores: s.app.stores)
        try UsageStats.markSent(day: "2026-11-16", support: s.app.stores.support)
        let on = try UsageStatsAPI.status(s.app, version: "0.6.8", macos: "15.5", environment: env)
        #expect(on["share_usage"] == .bool(false) && on["check_updates"] == .bool(false))
        #expect(on["last_sent"] == .string("2026-11-16"))
        #expect(on["body"] == status["body"])  // the same id until a new one is asked for
    }

    @Test func theRoutesAnswerAndANewIdReplacesTheOldOne() throws {
        let s = try TestServer()
        defer { s.stop() }
        let first = try #require(s.get("/api/usage-stats").json)
        let old = try UsageStats.installID(support: s.app.stores.support)
        #expect(first["body"]?.stringValue?.contains(old) == true)
        #expect(first["body"]?.stringValue?.contains(UsageStatsAPI.currentVersion()) == true)
        #expect(first["share_usage"] == .bool(true))
        let renewed = try #require(s.post("/api/usage-stats/new-id").json)
        let new = try UsageStats.installID(support: s.app.stores.support)
        #expect(new != old)
        #expect(renewed["body"]?.stringValue?.contains(new) == true)
        // The switch is one of the settings.
        #expect(s.post("/api/settings", .object([("share_usage", .bool(false))])).json?["share_usage"] == .bool(false))
        #expect(s.get("/api/usage-stats").json?["share_usage"] == .bool(false))
    }

    @Test func thePageOpensInTheBrowserOnlyWhenThereIsOne() throws {
        var opened: [String] = []
        let s = try TestServer(openURL: { opened.append($0) })
        defer { s.stop() }
        #expect(try UsageStatsAPI.openPage(s.app, environment: env) == .object([("opened", .string("https://palaver-stats.contoso.workers.dev/"))]))
        #expect(opened == ["https://palaver-stats.contoso.workers.dev/"])
        #expect(throws: Refused.self) { try UsageStatsAPI.openPage(s.app, environment: ["PALAVER_STATS_URL": "https://palaver-stats.<placeholder>.workers.dev/ping"]) }
        #expect(try UsageStatsAPI.openPage(s.app, environment: [:]) == .object([("opened", .string("https://palaver-stats.ardobras.workers.dev/"))]))
        #expect(opened.count == 2)  // the deployed Worker's page, through the test's openURL: no browser
    }
}
