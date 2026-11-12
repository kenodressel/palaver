import Foundation
import Testing
@testable import PalaverCore
@testable import PalaverDomain

@Suite struct SettingsFileTests {
    private func stores() -> StorePaths {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString)", isDirectory: true)
        return StorePaths(configDir: d.appendingPathComponent("palaver", isDirectory: true), home: d)
    }
    private func write(_ s: StorePaths, _ text: String) throws {
        try FileManager.default.createDirectory(at: s.configDir, withIntermediateDirectories: true)
        try text.write(to: s.settings, atomically: false, encoding: .utf8)
    }

    @Test func test_settings_default_and_roundtrip() throws {
        let s = stores()
        #expect(SettingsFile.load(stores: s).realtime)
        var v = SettingsValues(); v.realtime = false
        try SettingsFile.save(v, stores: s)
        #expect(!SettingsFile.load(stores: s).realtime)
        #expect(SettingsFile.load(stores: s).recordTeams)
        try "{broken".write(to: s.settings, atomically: false, encoding: .utf8)
        #expect(SettingsFile.load(stores: s) == SettingsValues())
    }

    @Test func theKeysAreTheDataclasssInItsOrder() {
        // settings.Settings' fields, nudge_notify (#19, on by default) included.
        #expect(PythonJSON.dumps(SettingsValues().json) == #"{"realtime": true, "record_teams": true, "record_slack": true, "#
                + #""search_meaning": true, "live_processing": true, "nudge_talk_share": true, "nudge_monologue": true, "#
                + #""nudge_quiet_invitee": true, "nudge_pace": false, "nudge_fillers": false, "nudge_notify": true, "#
                + #""check_updates": true, "respect_call_mute": true}"#)
    }

    @Test func test_a_missing_key_takes_the_default_and_wrong_types_are_ignored() throws {
        let s = stores()
        try write(s, #"{"realtime": false, "record_teams": "no"}"#)
        var d = SettingsValues(); d.recordSlack = false
        let v = SettingsFile.load(defaults: d, stores: s)
        #expect(!v.realtime); #expect(v.recordTeams); #expect(!v.recordSlack)
    }

    @Test func test_live_processing_is_a_setting_the_app_changes() throws {
        let s = stores()
        #expect(SettingsFile.load(stores: s).liveProcessing)
        var off = SettingsValues(); off.liveProcessing = false
        #expect(!SettingsFile.load(defaults: off, stores: s).liveProcessing)
        try SettingsFile.update([("live_processing", .bool(false))], stores: s)
        #expect(!SettingsFile.load(stores: s).liveProcessing)
        // update adds no defaults, and writes indent 2 plus a newline
        #expect(try String(contentsOf: s.settings, encoding: .utf8) == "{\n  \"live_processing\": false\n}\n")
    }

    @Test func test_user_name_from_settings() throws {
        let s = stores()
        #expect(SettingsFile.userName(stores: s) == nil)
        try SettingsFile.update([("user_name", .string("  Anna Huber "))], stores: s)
        #expect(SettingsFile.userName(stores: s) == "Anna Huber")
        try SettingsFile.update([("user_name", .string(""))], stores: s)
        #expect(SettingsFile.userName(stores: s) == nil)
    }

    @Test func test_the_name_is_read_again_by_long_running_parts() throws {
        let s = stores()
        #expect(SettingsFile.currentUserName(default: "Timo", stores: s) == "Timo")
        try SettingsFile.update([("user_name", .string("Timo Strauß"))], stores: s)
        #expect(SettingsFile.currentUserName(default: "Timo", stores: s) == "Timo Strauß")
        try SettingsFile.update([("user_aliases", .strings([" Timo ", ""]))], stores: s)
        #expect(SettingsFile.userAliases(stores: s) == ["Timo"])
        #expect(SettingsFile.me(userName: "Timo Strauß", stores: s) == ["timo strauss", "timo"])
    }

    @Test func test_writers_updating_at_once_lose_no_change() throws {
        let s = stores()
        try FileManager.default.createDirectory(at: s.configDir, withIntermediateDirectories: true)
        let group = DispatchGroup()
        for who in ["a", "b", "c", "d"] {
            DispatchQueue.global().async(group: group) {
                for i in 0..<40 { try? SettingsFile.update([("\(who)\(i)", .bool(true))], stores: s) }
            }
        }
        group.wait()
        let raw = SettingsFile.readRaw(stores: s)
        for w in ["a", "b", "c", "d"] { for i in 0..<40 { #expect(raw["\(w)\(i)"] == .bool(true)) } }
        let left = try FileManager.default.contentsOfDirectory(atPath: s.configDir.path).filter { $0.contains(".tmp") }
        #expect(left.isEmpty)
    }
}
