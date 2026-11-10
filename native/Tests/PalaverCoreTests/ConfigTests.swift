import Foundation
import Testing
@testable import PalaverCore

/// What `~` stands for in tests: the temporary PALAVER_HOME make swift-test sets (TestIsolation), never the real home.
private let home = ProcessInfo.processInfo.environment["PALAVER_HOME"] ?? "<PALAVER_HOME unset>"

@Test func configDefaultsWithoutAFile() {
    let c = Config.load(URL(fileURLWithPath: "/nonexistent/config.toml"), environment: [:])
    #expect(c.outputDir.path == home + "/Meetings/Recordings")
    #expect(c.retentionDays == 14 && c.maxSessionHours == 4 && c.gracePeriodSeconds == 10)
    #expect(c.recordSlack && c.processingLive && c.notesEnabled && c.calendarEnabled)
    #expect(c.notesEngine == "local" && c.notionMode == "page" && c.userName == "User" && c.notesModel == "sonnet")
    #expect(!c.notionAutoSync)  // no token: nothing to upload to
    #expect(c.memory.isEmpty)
}

@Test func configReadsTheKeysTheAppUses() {
    let c = Config(toml: """
        # a comment
        [user]
        name = "Timo Strauß"   # trailing comment

        [notion]
        token = "ntn_test"
        parent_page_id = "abc-123"
        auto_sync = true
        mode = 'database'
        database_id = "db-1"

        [recording]
        output_dir = "~/Meetings/Rec"
        retention_days = 7
        max_session_hours = 6
        grace_period_seconds = 20
        slack = false

        [processing]
        live = false

        [notes]
        enabled = false
        engine = "claude"
        local_model = "org/some-model"
        model = "opus"

        [calendar]
        enabled = false

        [memory]
        live_gb = 5
        notes_gb = 9.5
        """, environment: [:])
    #expect(c.userName == "Timo Strauß")
    #expect(c.hasNotionToken && c.notionAutoSync && c.notionMode == "database")
    #expect(c.notionParentPageId == "abc-123" && c.notionDatabaseId == "db-1")
    #expect(c.outputDir.path == home + "/Meetings/Rec")
    #expect(c.retentionDays == 7 && c.maxSessionHours == 6 && c.gracePeriodSeconds == 20)
    #expect(!c.recordSlack && !c.processingLive && !c.notesEnabled && !c.calendarEnabled)
    #expect(c.notesEngine == "claude" && c.notesLocalModel == "org/some-model" && c.notesModel == "opus")
    #expect(c.memory == ["live_gb": 5, "notes_gb": 9.5])
}

@Test func autoSyncNeedsATokenAndCanBeSwitchedOff() {
    #expect(!Config(toml: "[notion]\nauto_sync = true\n", environment: [:]).notionAutoSync)
    #expect(Config(toml: "[notion]\nauto_sync = true\n", environment: ["NOTION_TOKEN": "x"]).notionAutoSync)
    #expect(!Config(toml: "[notion]\ntoken = \"x\"\nauto_sync = false\n", environment: [:]).notionAutoSync)
    #expect(Config(toml: "[notion]\ntoken = \"x\"\n", environment: [:]).notionAutoSync)  // default on
}

@Test func badValuesNeverFail() {
    let c = Config(toml: """
        [recording]
        max_session_hours = "lots"
        grace_period_seconds = -3
        slack = "yes"
        retention_days = 3.9
        [notes]
        engine = "gpt"
        [notion]
        mode = "wiki"
        [memory]
        live_gb = 0
        stream_gb = "big"
        unknown_gb = 3
        [broken
        key without equals
        = 3
        """, environment: [:])
    #expect(c.maxSessionHours == 4 && c.gracePeriodSeconds == 10 && c.recordSlack)
    #expect(c.retentionDays == 3)
    #expect(c.notesEngine == "local" && c.notionMode == "page")
    #expect(c.memory.isEmpty)
}

@Test func tokensAreParsedPastAndNeverKept() {
    let secret = "ntn_SECRET_VALUE_123"
    let c = Config(toml: "[notion]\ntoken = \"\(secret)\"\n[hf]\ntoken = \"hf_SECRET\"\n[recording]\nslack = false\n", environment: [:])
    #expect(c.hasNotionToken && c.hasHfToken && !c.recordSlack)
    #expect(!"\(c)".contains(secret) && !"\(c)".contains("hf_SECRET"))
}

@Test func tomlSubsetOddities() {
    let t = Toml.parse("""
        top = 1
        "quoted key" = "a \\"b\\" \\u00e4"
        [a.b]
        list = [1, 2,
                3]  # multi-line array
        inline = { x = 1, y = "z" }
        n = 1_000
        f = 2.5
        t = true
        text = \"\"\"
        two
        lines\"\"\"
        after = 7
        [[tables]]
        skipped = 1
        [c]
        ok = "yes"
        """)
    #expect(t["top"] == .int(1))
    #expect(t["quoted key"] == .string("a \"b\" ä"))
    #expect(t["a.b.list"] == .other && t["a.b.inline"] == .other)
    #expect(t["a.b.n"] == .int(1000) && t["a.b.f"] == .double(2.5) && t["a.b.t"] == .bool(true))
    #expect(t["a.b.text"] == .string("two\nlines"))
    #expect(t["a.b.after"] == .int(7))
    #expect(t["c.ok"] == .string("yes"))
}

// MARK: settings.json

private func settingsFile(_ json: String?) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("settings.json")
    if let json { try json.write(to: url, atomically: true, encoding: .utf8) }
    return url
}

@Test func settingsDefaults() throws {
    let s = Settings(url: try settingsFile(nil))
    #expect(s.realtime && s.recordTeams && s.recordSlack && s.liveProcessing && s.searchMeaning && s.checkUpdates)
    #expect(s.nudgeTalkShare && s.nudgeMonologue && s.nudgeQuietInvitee && s.nudgeNotify)
    #expect(!s.nudgePace && !s.nudgeFillers)
    #expect(!Settings(url: try settingsFile(#"{"nudge_notify": false}"#)).nudgeNotify)
    #expect(s.audioDays == 0 && s.userName == nil)
}

@Test func settingsBrokenFileAndWrongTypesTakeTheDefault() throws {
    #expect(Settings(url: try settingsFile("{broken")).realtime)
    let s = Settings(url: try settingsFile(#"{"realtime": false, "record_teams": "no", "record_slack": 0, "audio_days": 30, "user_name": "  Anna Huber "}"#),
                     defaults: { var c = Config(); c.recordSlack = false; return c }())
    #expect(!s.realtime)
    #expect(s.recordTeams)          // a string is not a boolean
    #expect(!s.recordSlack)         // 0 is not a boolean: config.toml's default stands
    #expect(s.audioDays == 30 && s.userName == "Anna Huber")
    #expect(Settings(url: try settingsFile(#"{"audio_days": 5, "user_name": " "}"#)).audioDays == 0)
    #expect(Settings(url: try settingsFile(#"{"audio_days": true}"#)).audioDays == 0)
}

@Test func liveProcessingFollowsConfigUntilSettingsSaysOtherwise() throws {
    var c = Config(); c.processingLive = false
    #expect(!Settings(url: try settingsFile(nil), defaults: c).liveProcessing)
    #expect(Settings(url: try settingsFile(#"{"live_processing": true}"#), defaults: c).liveProcessing)
}

@Test func settingsAreReadAgainWhenTheFileChanges() throws {
    let url = try settingsFile(#"{"realtime": false}"#)
    let s = Settings(url: url)
    #expect(!s.realtime)
    try #"{"realtime": true}"#.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
    #expect(s.realtime)
    try FileManager.default.removeItem(at: url)
    #expect(s.realtime)  // gone: default (true)
}

@Test func pathsFollowTheLayout() {
    let p = Paths(home: URL(fileURLWithPath: "/h"))
    #expect(p.support.path == "/h/Library/Application Support/palaver")
    #expect(p.logs.path == "/h/Library/Logs/palaver")
    #expect(p.daemonJson.path.hasSuffix("palaver/daemon.json") && p.appSock.lastPathComponent == "app.sock")
    #expect(p.startedOk.lastPathComponent == "started-ok" && p.permissionsMarker.lastPathComponent == "permissions-requested")
    #expect(p.outputDir(Config()).path.hasSuffix("Meetings/Recordings"))
}

@Test func tomlStripsAByteOrderMarkAndHonoursEscapesWhileSkipping() {
    let t = Toml.parse("\u{FEFF}[user]\nname = \"Timo\"\n[x]\nlist = [\"a \\\" ]\", \"b\"]\nafter = 1\ninline = { s = \"\\\\\" }\nlast = 2\n")
    #expect(t["user.name"] == .string("Timo"))
    #expect(t["x.list"] == .other && t["x.after"] == .int(1))
    #expect(t["x.inline"] == .other && t["x.last"] == .int(2))
}

@Test func testsNeverReachTheRealHome() {
    #expect(TestIsolation.isTestProcess)
    let env = ProcessInfo.processInfo.environment
    #expect(!(env["PALAVER_HOME"] ?? "").isEmpty && !(env["XDG_CONFIG_HOME"] ?? "").isEmpty)
    #expect(Paths.fromEnvironment().home.path == env["PALAVER_HOME"])
    #expect(Paths.fromEnvironment().configDir.path == env["XDG_CONFIG_HOME"]! + "/palaver")
    let own = URL(fileURLWithPath: "/tmp/ph/own", isDirectory: true)
    #expect(Paths(home: URL(fileURLWithPath: "/tmp/ph"), configDir: own).settingsJson.path == "/tmp/ph/own/settings.json")
    #expect(Paths(home: URL(fileURLWithPath: "/tmp/ph"), env: [:]).configToml.path == "/tmp/ph/.config/palaver/config.toml")
    #expect(Config(toml: "[recording]\noutput_dir = \"~/x\"\n").outputDir.path == env["PALAVER_HOME"]! + "/x")
}

/// A test that would reach the user's real home, ~/.config or ~/Meetings stops before anything is read.
@Test func aTestReachingTheRealHomeStops() async {
    await #expect(processExitsWith: .failure) { _ = Paths.fromEnvironment([:]) }
    await #expect(processExitsWith: .failure) { _ = Paths(home: URL(fileURLWithPath: TestIsolation.realHome!)) }
    await #expect(processExitsWith: .failure) {
        _ = Paths(home: URL(fileURLWithPath: "/tmp/ph"), configDir: URL(fileURLWithPath: TestIsolation.realHome! + "/.config/palaver"))
    }
    await #expect(processExitsWith: .failure) {
        _ = Paths(home: URL(fileURLWithPath: "/tmp/ph"), env: ["XDG_CONFIG_HOME": TestIsolation.realHome! + "/.config"])
    }
    await #expect(processExitsWith: .failure) { _ = Config(toml: "[recording]\noutput_dir = \"\(TestIsolation.realHome!)/Meetings/Recordings\"\n") }
    await #expect(processExitsWith: .failure) {
        var env = ProcessInfo.processInfo.environment
        env["PALAVER_HOME"] = nil
        _ = TestIsolation.testHome(env)
    }
}
