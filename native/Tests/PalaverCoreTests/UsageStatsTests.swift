// The opt-in usage numbers (#6): the install id and its reset, the ping's exact bytes, the endpoint and its page.
// Temporary folders only; nothing is sent.
import Foundation
import Testing
@testable import PalaverCore

@Suite struct UsageStatsTests {
    private func support() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("usage-stats-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func theInstallIdIsARandomV4MadeOnceAndKept() throws {
        let dir = support()
        let id = try UsageStats.installID(support: dir)
        #expect(UsageStats.isInstallID(id))
        #expect(id == id.lowercased())
        #expect(try UsageStats.installID(support: dir) == id)  // read again, not made again
        #expect(try String(contentsOf: UsageStats.installFile(support: dir), encoding: .utf8) == id + "\n")
        let mode = try FileManager.default.attributesOfItem(atPath: UsageStats.installFile(support: dir).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try UsageStats.installID(support: support()) != id)  // another Mac, another id
        // No leftover temporary files beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["install-id"])
    }

    @Test func aNewIdReplacesTheOldOne() throws {
        let dir = support()
        let old = try UsageStats.installID(support: dir)
        let new = try UsageStats.newInstallID(support: dir)
        #expect(new != old && UsageStats.isInstallID(new))
        #expect(try UsageStats.installID(support: dir) == new)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["install-id"])
    }

    @Test func aFileThatHoldsNoIdIsReplaced() throws {
        let dir = support()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "Timo Strauß\n".write(to: UsageStats.installFile(support: dir), atomically: true, encoding: .utf8)
        let id = try UsageStats.installID(support: dir)
        #expect(UsageStats.isInstallID(id))
        #expect(try UsageStats.installID(support: dir) == id)
    }

    @Test func onlyALowercaseUuidV4IsAnInstallId() {
        #expect(UsageStats.isInstallID("3f2a9c4e-8b1d-4e6f-9a2b-7c5d1e0f4a3b"))
        #expect(!UsageStats.isInstallID("3F2A9C4E-8B1D-4E6F-9A2B-7C5D1E0F4A3B"))
        #expect(!UsageStats.isInstallID("3f2a9c4e-8b1d-1e6f-9a2b-7c5d1e0f4a3b"))  // v1
        #expect(!UsageStats.isInstallID("3f2a9c4e-8b1d-4e6f-9a2b-7c5d1e0f4a3b\nx"))
        #expect(!UsageStats.isInstallID(""))
    }

    @Test func thePingIsTheThreeFieldsAndNothingElse() {
        let body = UsageStats.body(install: "3f2a9c4e-8b1d-4e6f-9a2b-7c5d1e0f4a3b", version: "0.6.8", macos: "15.5")
        #expect(body == #"{"install": "3f2a9c4e-8b1d-4e6f-9a2b-7c5d1e0f4a3b", "version": "0.6.8", "macos": "15.5"}"#)
        #expect(UsageStats.macOS(OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2)) == "26.1")
        #expect(UsageStats.macOS(OperatingSystemVersion(majorVersion: 15, minorVersion: 5, patchVersion: 0)) == "15.5")
    }

    @Test func theEndpointItsPageAndWhatMaySend() {
        #expect(UsageStats.endpoint(environment: [:]) == UsageStats.defaultEndpoint)
        #expect(UsageStats.endpoint(environment: ["PALAVER_STATS_URL": ""]) == UsageStats.defaultEndpoint)
        #expect(UsageStats.endpoint(environment: ["PALAVER_STATS_URL": "http://127.0.0.1:9/ping"]) == "http://127.0.0.1:9/ping")
        #expect(UsageStats.page(endpoint: "https://palaver-stats.contoso.workers.dev/ping") == "https://palaver-stats.contoso.workers.dev/")
        #expect(UsageStats.sendable(UsageStats.defaultEndpoint) != nil)  // the deployed Worker
        #expect(UsageStats.sendable("https://palaver-stats.<placeholder>.workers.dev/ping") == nil)  // a placeholder sends nothing
        #expect(UsageStats.sendable("https://palaver-stats.contoso.workers.dev/ping") != nil)
        #expect(UsageStats.sendable("http://127.0.0.1:8123/ping") != nil)
        #expect(UsageStats.sendable("http://palaver-stats.contoso.workers.dev/ping") == nil)  // plain http only to this Mac
        #expect(UsageStats.sendable("file:///tmp/ping") == nil)
    }

    @Test func theDayIsUtcAndTheLastOneIsKept() throws {
        // 23:30 UTC on the 16th (00:30 on the 17th in Berlin) counts for the 16th, whatever this Mac's zone.
        #expect(UsageStats.utcDay(Date(timeIntervalSince1970: 1_794_871_800)) == "2026-11-16")
        let dir = support()
        #expect(UsageStats.lastSent(support: dir) == nil)
        try UsageStats.markSent(day: "2026-11-16", support: dir)
        #expect(UsageStats.lastSent(support: dir) == "2026-11-16")
        #expect(UsageStats.lastSentVersion(support: dir) == nil)  // an earlier release's file: the day alone
        try UsageStats.markSent(day: "2026-11-17", version: "0.7.4", support: dir)
        #expect(UsageStats.lastSent(support: dir) == "2026-11-17")
        #expect(UsageStats.lastSentVersion(support: dir) == "0.7.4")
        try "yesterday".write(to: UsageStats.sentFile(support: dir), atomically: true, encoding: .utf8)
        #expect(UsageStats.lastSent(support: dir) == nil)
    }
}
