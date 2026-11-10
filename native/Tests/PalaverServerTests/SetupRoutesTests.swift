// The setup assistant's routes (tests/test_setup_api.py): what the page shows, and the changes it makes only when the
// user clicks. A fake Mac (FakeProbe), a fake menu bar app (the test recording and the calendar permission, as the app
// answers them through app.sock) and a fake provider helper (each provider's readiness as `palaver provider registry`
// answers it from a fake Keychain) and a fake `claude` that only notes what it was asked: nothing here looks at this Mac, downloads, records or
// plays a sound. test_setup_api.py's speech-download tests are in ProbeTests and AppRoutesTests (Task 50), its glossary
// seed test in GlossaryRoutesTests.
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let GEMMA = SetupFixtures.GEMMA
private let QWEN = SetupFixtures.QWEN

/// `palaver provider` with a fake Keychain (conftest's `fake_keychain`): `registry` as provider_helper.registry answers
/// it (a provider is ready once its key is set; the gateway needs its endpoint; no `claude` on this fake Mac).
private final class FakeProviders: ProviderHelper, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []
    private var made: [(String, JSONValue)] = []

    /// `providers.set_key(pid, key)`: only that one is set, never the key itself.
    func setKey(_ pid: String) { lock.withLock { keys.append(pid) } }
    var calls: [(String, JSONValue)] { lock.withLock { made } }

    func call(_ action: String, body: JSONValue, timeout: Double) throws -> JSONValue {
        lock.withLock { made.append((action, body)) }
        guard action == "registry" else { throw BadRequest("no action \(action)") }
        let have = lock.withLock { keys }
        let providers: [JSONValue] = ModelChoice.providers.map { p in
            let problem: String?
            switch p.key {
            case "none": problem = "Claude Code CLI (`claude`) not found on this Mac"
            case "optional": problem = "Save the endpoint"
            default: problem = have.contains(p.id) ? nil : "Add the API key"
            }
            return .object([("id", .string(p.id)), ("label", .string(p.label)), ("ready", .bool(problem == nil)),
                            ("problem", .str(problem)), ("uses", .strings(p.uses.sorted()))])
        }
        let features: [JSONValue] = ModelChoice.features.map { f in
            .object([("id", .string(f.id)), ("label", .string(f.label)), ("uses", .string(f.uses)), ("own", .bool(f.own))])
        }
        return .object([("features", .array(features)), ("providers", .array(providers))])
    }
}

/// The menu bar app as the setup assistant reaches it: its test recording (onboarding.TestRecording with
/// tests/fake_probe.py's FakeRecorder: no microphone, the result given) and the calendar permission (FakeCalendar:
/// asking is a click on Allow), which it keeps in the fake Mac's permissions.
private final class FakeMenuBarApp: RecordingRemote, @unchecked Sendable {
    let probe: FakeProbe
    private let lock = NSLock()
    private var state = "idle"
    private var checks: [JSONValue] = []
    /// The modes the test recordings were started with (`recorder.modes`), one per start.
    private(set) var started: [JSONValue] = []
    private(set) var stopped = 0
    var asked = 0
    var openedSettings = 0
    /// `recording()`: a meeting recording now (menubar.RecordingQuestion), nil when none.
    var now: JSONValue?
    var processing = false
    let result = PyDict<JSONValue>([
        ("mic", .object([("recorded", .bool(true)), ("level_db", .double(-24.0)), ("text", .string("This is my test sentence"))])),
        ("system", .object([("recorded", .bool(true)), ("level_db", .double(-90.0))])),
    ])

    init(_ probe: FakeProbe) { self.probe = probe }

    private func status() -> JSONValue {
        var out: [(String, JSONValue)] = [("state", .string(state)), ("max_seconds", .double(RemoteTest.MAX_SECONDS))]
        if state == "done" { out.append(("checks", .array(checks))) }
        return .object(out)
    }

    func test(_ args: JSONValue, timeout: Double) throws -> JSONValue {
        lock.withLock {
            switch args["action"]?.stringValue {
            case "start"?:
                if state != "recording" {
                    state = "recording"
                    started.append(args["mode"] ?? .object([]))
                }
            case "stop"?:
                if state == "recording" {
                    stopped += 1
                    state = "done"
                    checks = Recommendations.testVerdict(result).map(\.json)
                }
            default: break
            }
            return status()
        }
    }

    func calendarStatus() -> JSONValue { probe.perms["calendar"] ?? .object([]) }

    func calendarConnect() throws -> JSONValue {
        guard case .object(var now) = calendarStatus() else { return .object([]) }
        switch calendarStatus()["state"]?.stringValue {
        case "not_asked"?:
            asked += 1
            probe.perms["calendar"] = .object([("state", .string("granted")), ("detail", .string("connected (read only)"))])
            now.append(("asked", .bool(true)))
        case "denied"?:
            openedSettings += 1
            now.append(("opened_settings", .bool(true)))
        default: break
        }
        return .object(now)
    }

    func question() -> JSONValue? { nil }
    func recording() -> JSONValue? { now }
    func coach() -> JSONValue? { nil }
    func memory() -> JSONValue? { nil }
    func indexing() -> JSONValue { .object([("indexing", .bool(false)), ("downloading", .bool(false))]) }
    func busy() -> Bool { processing || now != nil }
    func answer(choice: String, meeting: String) throws -> Bool { false }
    func watch(folder: URL, pid: Int32) {}
    func startHelper(kind: String, key: String, args: [String]) throws -> Int32 { throw AppCtlClient.CallFailed("fake") }
    func transcribe(folder: URL) throws -> Bool { false }
    func record(action: String, meeting: String?) throws -> JSONValue { throw Refused(AppAPI.NOT_IN_THE_APP) }
    func switchedOff(app: String) {}
    func updateCheck() throws -> JSONValue { throw Refused(Remote.APP_GONE) }
    func updateInstall() throws -> JSONValue { throw Refused(Remote.APP_GONE) }
    func uninstall(_ args: JSONValue) throws -> JSONValue { throw Refused(Remote.APP_GONE) }
}

/// test_setup_api.py's `app` fixture: a recordings folder, config.toml's name "User", the calendar's one meeting (two
/// days ago), the fake Mac, app and Keychain; stores in a temporary folder.
private final class Fixture {
    let dir: URL
    let app: ServerApp
    let probe: FakeProbe
    let mac: FakeMenuBarApp
    let keys = FakeProviders()
    /// What the fake `claude` was asked (`claude mcp add …`).
    let claude = Shared<[[String]]>([])
    /// Targets Palaver was added to: "code" per `claude mcp add`, "desktop" once Claude Desktop's config has it.
    var installed: [String] {
        claude.value.filter { $0.count > 2 && $0[2] == "add" }.map { _ in "code" }
            + (PythonJSON.read(app.stores.claudeDesktopConfig)?["mcpServers"]?["meetings"] != nil ? ["desktop"] : [])
    }

    init(userName: String = "User", calendar: Bool = true, config: Config = Config()) throws {
        dir = tempFolder("setup")
        let stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                                home: dir.appendingPathComponent("home", isDirectory: true))
        let out = dir.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        probe = FakeProbe()
        if calendar { probe.events = [Fixture.weekly()] }
        mac = FakeMenuBarApp(probe)
        app = ServerApp(outputDir: out, userName: userName, config: config, stores: stores, recording: mac, probe: probe,
                        provider: keys)
        let claude = self.claude
        app.mcpSetup = McpSetup(stores: stores, executable: "/A/Contents/Resources/bin/palaver", findClaude: { "/fake/claude" }) { argv in
            claude.value.append(argv)
            return McpSetup.Ran(status: 0)
        }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    static func weekly() -> CalendarEvent {
        let at = Date().addingTimeInterval(-2 * 86400)
        let offset = TimeZone.current.secondsFromGMT(for: at)
        return CalendarEvent(title: "Contoso Northwind Weekly", start: PyDateTime(at, offset: offset),
                             end: PyDateTime(at.addingTimeInterval(3600), offset: offset),
                             attendees: [Attendee(name: "Timo Strauss", email: "timo@kloud.io", isSelf: true),
                                         Attendee(name: "Valerie Novak", email: "valerie@contoso.at"),
                                         Attendee(name: "Anna Berg", email: "anna@kloud.io")])
    }

    var stores: StorePaths { app.stores }
    var raw: JSONValue { SettingsFile.readRaw(stores: stores) }
    var engines: String { PythonJSON.dumps(raw["engines"] ?? .null) }

    func page() throws -> JSONValue { try SetupAPI.page(app) }
    func apply(_ changes: [(String, JSONValue)]) throws -> JSONValue {
        try SetupAPI.apply(app, .object([("changes", .object(changes))]))
    }
    func recs() throws -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for r in try page()["recommendations"]?.arrayValue ?? [] { out[r["id"]!.stringValue!] = r }
        return out
    }
    func meeting(_ name: String) throws {
        try FileManager.default.createDirectory(at: app.outputDir.appendingPathComponent(name), withIntermediateDirectories: true)
    }
}

private func refused(_ text: String? = nil, _ body: () throws -> Any) -> Bool {
    do {
        _ = try body()
        return false
    } catch let e as Refused {
        return text.map { e.text.contains($0) } ?? true
    } catch {
        return false
    }
}

private func dumps(_ v: JSONValue?) -> String { PythonJSON.dumps(v ?? .null, ensureAscii: false) }
private func obj(_ fields: [(String, JSONValue)]) -> JSONValue { .object(fields) }

@Suite(.serialized) struct SetupRoutesTests {
    // MARK: - what the page shows

    @Test func test_the_page_has_the_checks_and_the_recommendations() throws {
        let f = try Fixture()
        let page = try f.page()
        #expect(page["hardware"]?["chip"] == .string("Apple M4 Pro") && dumps(page["hardware"]?["memory_gb"]) == "48")
        #expect(dumps(page["installed"]) == #"{"teams": true, "slack": false, "claude_code": true, "claude_desktop": false}"#)
        #expect(page["permissions"]?["calendar"]?["state"] == .string("not_asked"))
        let recs = try f.recs()
        #expect(recs["language_model"]?["value"] == .string("local:\(GEMMA)"))
        #expect(dumps(recs["transcription"]?["downloads"]) == #"["speech"]"#)
        #expect(dumps(page["offer"]) == #"{"why": "first"}"#)  // no meetings, never set up
    }

    @Test func test_the_page_lists_the_downloads_with_their_sizes() throws {
        let d = try Fixture().page()["downloads"]
        #expect((d?["needed"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue } == ["speech", "gemma", "e5"])
        #expect(abs((d?["total_gb"]?.doubleValue ?? 0) - (0.5 + 8.3 + 0.47)) < 1e-9)
        #expect(d?["free_disk_gb"] == .double(120))
        #expect(dumps(d?["status"]) == #"{"running": false, "models": []}"#)  // nothing starts by itself
    }

    @Test func test_the_profile_is_prefilled_from_macos_and_the_calendar() throws {
        let profile = try Fixture().page()["profile"]
        // config.toml says "User"
        #expect(profile?["name"] == .string("Timo Strauss") && profile?["name_from"] == .string("macOS"))
        #expect(profile?["organization"] == .string("KLOUD"))  // from the user's own address in the calendar
    }

    @Test func test_the_name_from_config_toml_is_kept() throws {
        let f = try Fixture(userName: "Timo", calendar: false)
        #expect(dumps(try f.page()["profile"]) == #"{"name": "Timo", "name_from": "config", "organization": null}"#)
    }

    @Test func test_connect_calendar_asks_macos_once_then_opens_system_settings() throws {
        let f = try Fixture()
        let connect = obj([("action", .string("connect"))])
        #expect(dumps(try SetupAPI.calendar(f.app, connect)) == #"{"state": "not_asked", "detail": "not connected", "asked": true}"#)
        let now = try SetupAPI.calendar(f.app, obj([]))
        #expect(f.mac.asked == 1 && now["state"] == .string("granted"))
        #expect(try f.page()["permissions"]?["calendar"]?["state"] == .string("granted"))
        #expect(try SetupAPI.calendar(f.app, connect)["asked"] == nil && f.mac.asked == 1)  // connected: nothing
        f.probe.perms["calendar"] = obj([("state", .string("denied")), ("detail", .string("not allowed"))])
        #expect(try SetupAPI.calendar(f.app, connect)["opened_settings"] == .bool(true))
        #expect(f.mac.openedSettings == 1 && f.mac.asked == 1)  // macOS asks no more once refused
        #expect(refused { try SetupAPI.calendar(f.app, obj([("action", .string("grant"))])) })
    }

    @Test func test_the_glossary_seed_comes_from_the_calendar() throws {
        let seed = try Fixture().page()["glossary"]?.arrayValue ?? []
        let terms = Dictionary(uniqueKeysWithValues: seed.map { ($0["term"]!.stringValue!, $0["kind"]!.stringValue!) })
        #expect(terms == ["Valerie Novak": "person", "Contoso": "organization", "Northwind": "title", "Anna Berg": "person"])
    }

    @Test func test_without_a_calendar_there_is_no_seed() throws {
        let page = try Fixture(userName: "Timo", calendar: false).page()
        #expect(page["glossary"] == .array([]) && page["profile"]?["organization"] == .null)
    }

    @Test func test_the_summary_is_the_doctor_in_the_window() throws {
        var by: [String: JSONValue] = [:]
        for c in try Fixture().page()["summary"]?.arrayValue ?? [] { by[c["name"]!.stringValue!] = c }
        #expect(by["Microphone"]?["status"] == .string("ok"))
        #expect(by["Speech models"]?["status"] == .string("warn") && by["Speech models"]?["fix"]?.stringValue?.contains("0.5 GB") == true)
        #expect(by["Claude Code access"]?["status"] == .string("warn"))
    }

    @Test func test_storage_and_privacy_say_where_things_are() throws {
        let f = try Fixture()
        let s = try f.page()["storage"]
        #expect(s?["recordings"] == .string(f.app.outputDir.path))
        #expect(s?["audio_days"] == .int(0) && s?["autostart"] == .bool(false))
        #expect(dumps(.object((s?["cloud"]?.arrayValue ?? []).map { ($0["feature"]!.stringValue!, $0["choice"]!) })) ==
                #"{"notes": "local", "projects": "local", "coach": "local", "transcription": "local"}"#)
    }

    @Test func test_an_existing_user_is_not_offered_the_assistant() throws {
        let f = try Fixture()
        try f.meeting("2026-10-27T09-00-00")
        f.probe.add("speech")
        #expect(try SetupAPI.offer(f.app) == .null)
    }

    @Test func test_an_existing_user_whose_meetings_wait_for_the_speech_models_is_told() throws {
        let f = try Fixture()
        try f.meeting("2026-10-27T09-00-00")
        #expect(dumps(try SetupAPI.offer(f.app)) ==
                #"{"why": "missing", "models": ["speech"], "labels": {"speech": "Speech models"}}"#)
    }

    @Test func test_recommendations_alone_for_the_settings_page() throws {
        let out = try SetupAPI.recommendations(try Fixture().app)
        #expect(out["hardware"]?["fingerprint"] == .string("Apple M4 Pro, 48 GB"))
        let ids = Set((out["recommendations"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
        #expect(ids.isSuperset(of: ["realtime", "live_processing", "language_model"]))
    }

    // MARK: - applying: only what the user clicked

    @Test func test_looking_changes_nothing() throws {
        let f = try Fixture()
        _ = try f.page()
        _ = try SetupAPI.recommendations(f.app)
        _ = try SetupAPI.offer(f.app)
        _ = f.app.probe.downloads.status()
        _ = try SetupAPI.test(f.app, obj([]))
        #expect(f.raw == .object([]))
        #expect(f.probe.fetched.isEmpty && dumps(f.probe.downloads.status()) == #"{"running": false, "models": []}"#)
        #expect(f.mac.started.isEmpty && f.probe.autostart() == false)
        #expect(Glossary(path: f.stores.glossary).terms.isEmpty)
        #expect(f.keys.calls.allSatisfy { $0.0 == "registry" })  // nothing added to Claude
    }

    @Test func test_apply_switches() throws {
        let f = try Fixture()
        _ = try f.apply([("realtime", .bool(false)), ("live_processing", .bool(false)), ("record_slack", .bool(false))])
        let s = SettingsFile.load(stores: f.stores)
        #expect(!s.realtime && !s.liveProcessing && !s.recordSlack)
        #expect(refused("realtime must be true or false") { try f.apply([("realtime", .string("yes"))]) })
        #expect(refused("nothing to set for 'no_such'") { try f.apply([("no_such", .bool(true))]) })
        #expect(refused("nothing to change") { try SetupAPI.apply(f.app, obj([("changes", .object([]))])) })
    }

    /// One apply asks the provider helper (a Python start) once, for the choices and the answer.
    @Test func anApplyAsksTheRegistryOnce() throws {
        let f = try Fixture()
        let before = f.keys.calls.count
        _ = try f.apply([("realtime", .bool(false)), ("language_model", .string("local"))])
        #expect(f.keys.calls.dropFirst(before).map(\.0) == ["registry"])
    }

    @Test func test_apply_the_local_model() throws {
        let f = try Fixture()
        _ = try f.apply([("language_model", .string("local:\(GEMMA)"))])
        #expect(f.raw["local_model"] == .string(GEMMA))
        #expect(f.engines == #"{"notes": "local", "projects": "local"}"#)
        #expect(refused("no local model") { try f.apply([("language_model", .string("local:\(QWEN)"))]) })  // no longer offered
    }

    @Test func test_apply_a_cloud_model_only_when_it_is_set_up() throws {
        let f = try Fixture()
        #expect(refused("Anthropic API: Add the API key") { try f.apply([("language_model", .string("anthropic"))]) })
        #expect(f.raw["engines"] == nil)
        f.keys.setKey("anthropic")
        _ = try f.apply([("language_model", .string("anthropic"))])
        #expect(f.engines == #"{"notes": "anthropic", "projects": "anthropic"}"#)
        // "a cloud model" is no choice
        #expect(refused("no language model 'cloud'") { try f.apply([("language_model", .string("cloud"))]) })
    }

    @Test func test_apply_transcription_takes_only_a_transcription_service() throws {
        let f = try Fixture()
        _ = try f.apply([("transcription", .string("local"))])
        #expect(f.raw["engines"]?["transcription"] == .string("local"))
        // a language model
        #expect(refused("no transcription service 'anthropic'") { try f.apply([("transcription", .string("anthropic"))]) })
        #expect(refused("Add the API key") { try f.apply([("transcription", .string("soniox"))]) })
        f.keys.setKey("soniox")
        _ = try f.apply([("transcription", .string("soniox"))])
        #expect(f.raw["engines"]?["transcription"] == .string("soniox"))
        #expect(refused("only notes can wait for a cloud model") { try f.apply([("transcription", .string("pending"))]) })
        #expect(refused("no choice 1") { try f.apply([("transcription", .int(1))]) })
    }

    @Test func test_apply_claude_access() throws {
        let f = try Fixture()
        _ = try f.apply([("claude_code", .bool(true)), ("claude_desktop", .bool(false))])
        #expect(f.installed == ["code"])
        #expect(refused("claude_desktop must be true or false") { try f.apply([("claude_desktop", .string("yes"))]) })
    }

    @Test func test_apply_answers_with_the_new_recommendations() throws {
        let out = try Fixture().apply([("realtime", .bool(false))])
        let rec = (out["recommendations"]?.arrayValue ?? []).first { $0["id"] == .string("realtime") }
        #expect(rec?["current"] == .bool(false) && rec?["matches"] == .bool(false))
    }

    @Test func test_profile_saves_the_name_and_the_organization() throws {
        let f = try Fixture()
        _ = try SetupAPI.setProfile(f.app, obj([("name", .string("Timo Strauß")), ("organization", .string("KLOUD"))]))
        #expect(SettingsFile.userName(stores: f.stores) == "Timo Strauß" && f.app.userName == "Timo Strauß")
        #expect(Organizations(path: f.stores.organizations).person("Timo Strauß") == "KLOUD")
        #expect(refused("your name must be one line of text") { try SetupAPI.setProfile(f.app, obj([("name", .string("  "))])) })
        #expect(refused { try SetupAPI.setProfile(f.app, obj([("name", .string("Timo\nStrauß"))])) })
        #expect(refused { try SetupAPI.setProfile(f.app, obj([("name", .string(String(repeating: "x", count: 121)))])) })
    }

    @Test func test_autostart_only_on_a_click() throws {
        let f = try Fixture()
        #expect(try SetupAPI.setAutostart(f.app, obj([("on", .bool(true))])) == obj([("autostart", .bool(true))]))
        #expect(f.probe.autostart() == true)
        #expect(refused("on must be true or false") { try SetupAPI.setAutostart(f.app, obj([("on", .int(1))])) })
    }

    @Test func test_finish_and_skip_are_remembered() throws {
        let f = try Fixture()
        let out = try SetupAPI.finish(f.app, obj([("how", .string("done"))]))
        #expect(out["state"]?["done"]?.stringValue?.isEmpty == false && out["state"]?["hardware"] == .string("Apple M4 Pro, 48 GB"))
        let offer = try SetupAPI.offer(f.app)
        #expect(offer == .null || offer["why"] == .string("missing"))
        _ = try SetupAPI.finish(f.app, obj([("how", .string("skipped"))]))
        #expect(f.raw["setup"]?["skipped"]?.stringValue?.isEmpty == false)
        #expect(refused(#"how must be "done" or "skipped""#) { try SetupAPI.finish(f.app, obj([("how", .string("later"))])) })
    }

    @Test func test_a_new_mac_offers_the_assistant_again() throws {
        let f = try Fixture()
        _ = try SetupAPI.finish(f.app, obj([("how", .string("done"))]))
        f.probe.hw = Hardware(chip: "Apple M5 Max", memoryGB: 64, freeDiskGB: 500)
        #expect(try SetupAPI.offer(f.app)["why"] == .string("changed"))
    }

    @Test func test_a_missing_model_offers_the_downloads() throws {
        let f = try Fixture()
        for m in ["speech", "gemma"] { f.probe.add(m) }
        _ = try SetupAPI.finish(f.app, obj([("how", .string("done"))]))
        #expect(try SetupAPI.offer(f.app) == .null)
        f.probe.forget("gemma")
        #expect(dumps(try SetupAPI.offer(f.app)) ==
                #"{"why": "missing", "models": ["gemma"], "labels": {"gemma": "Gemma 4 12B"}}"#)
    }

    // MARK: - downloads and the test recording: started by the user

    @Test func test_downloads_start_on_request_and_report_progress() throws {
        let f = try Fixture()
        f.probe.hold()
        let status = try SetupAPI.startDownloads(f.app, obj([("models", .strings(["speech", "gemma"]))]))
        #expect(status["running"] == .bool(true))
        #expect((status["models"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue } == ["speech", "gemma"])
        f.probe.release()
        #expect(until { f.app.probe.downloads.status()["running"] == .bool(false) })
        #expect(f.probe.fetched == ["speech", "gemma"])
        #expect(Set((f.app.probe.downloads.status()["models"]?.arrayValue ?? []).compactMap { $0["state"]?.stringValue }) == ["done"])
        #expect(refused("no model 'not-a-model'") { try SetupAPI.startDownloads(f.app, obj([("models", .strings(["not-a-model"]))])) })
        #expect(refused("no models to download") { try SetupAPI.startDownloads(f.app, obj([("models", .array([]))])) })
    }

    @Test func test_the_test_recording_runs_only_when_started() throws {
        let f = try Fixture()
        #expect(try SetupAPI.test(f.app, obj([]))["state"] == .string("idle"))  // a GET never starts it
        #expect(f.mac.started.isEmpty)
        let status = try SetupAPI.test(f.app, obj([("action", .string("start"))]))
        #expect(status["state"] == .string("recording") && f.mac.started.count == 1)
        _ = try SetupAPI.test(f.app, obj([("action", .string("stop"))]))
        let done = try SetupAPI.test(f.app, obj([]))
        #expect(done["state"] == .string("done") && f.mac.stopped == 1)
        #expect((done["checks"]?.arrayValue ?? []).compactMap { $0["status"]?.stringValue } == ["ok", "ok"])
        #expect(done["checks"]?.arrayValue?.first?["detail"]?.stringValue?.contains("This is my test sentence") == true)
        #expect(refused(#"action must be "start" or "stop""#) { try SetupAPI.test(f.app, obj([("action", .string("go"))])) })
        #expect(try SetupAPI.test(f.app, obj([("action", .null)]))["state"] == .string("done"))  // null: no action
    }

    @Test func test_no_test_recording_during_a_meeting() throws {
        let f = try Fixture()
        f.mac.now = obj([("meeting", .string("2026-10-30T09-00-00")), ("text", .string("Teams call"))])
        #expect(refused("being recorded") { try SetupAPI.test(f.app, obj([("action", .string("start"))])) })
        #expect(f.mac.started.isEmpty)
    }

    @Test func test_the_menubar_recording_path_decides_too() throws {
        let f = try Fixture()
        f.mac.processing = true  // processing an earlier meeting: no reason to refuse
        #expect(try SetupAPI.test(f.app, obj([("action", .string("start"))]))["state"] == .string("recording"))
        _ = try SetupAPI.test(f.app, obj([("action", .string("stop"))]))
        #expect(try SetupAPI.test(f.app, obj([]))["state"] == .string("done"))
        f.mac.now = obj([("meeting", .string("2026-10-30T09-00-00")), ("text", .string("Teams call"))])
        #expect(refused("being recorded") { try SetupAPI.test(f.app, obj([("action", .string("start"))])) })
    }

    @Test func test_the_test_never_transcribes_with_a_download_or_the_cloud() throws {
        let f = try Fixture()
        _ = try SetupAPI.test(f.app, obj([("action", .string("start"))]))
        _ = try SetupAPI.test(f.app, obj([("action", .string("stop"))]))
        #expect(dumps(f.mac.started.last) == #"{"transcribe": "local"}"#)
        f.keys.setKey("soniox")
        _ = try f.apply([("transcription", .string("soniox"))])
        _ = try SetupAPI.test(f.app, obj([("action", .string("start"))]))
        _ = try SetupAPI.test(f.app, obj([("action", .string("stop"))]))
        #expect(f.mac.started.count == 2 && dumps(f.mac.started.last) == #"{"transcribe": "cloud", "service": "Soniox"}"#)
    }

    @Test func test_transcription_stays_local_when_config_toml_sends_notes_to_claude() throws {
        var config = Config()
        config.notesEngine = "claude"
        let f = try Fixture(userName: "Timo", calendar: false, config: config)
        let cloud = try f.page()["storage"]?["cloud"]?.arrayValue ?? []
        #expect(dumps(.object(cloud.map { ($0["feature"]!.stringValue!, $0["choice"]!) })) ==
                #"{"notes": "claude-cli", "projects": "claude-cli", "coach": "local", "transcription": "local"}"#)
        let recs = try f.recs()
        #expect(recs["transcription"]?["current"] == .string("local") && recs["transcription"]?["matches"] == .bool(true))
        #expect(recs["language_model"]?["chosen"] == .bool(true))  // set in config.toml: deliberate
    }

    @Test func test_use_recommended_on_16_gb_turns_notes_off_until_a_cloud_model() throws {
        let f = try Fixture()
        f.probe.hw = Hardware(chip: "Apple M2 Pro", memoryGB: 16, freeDiskGB: 200)
        #expect(try f.recs()["language_model"]?["value"] == .string("pending"))
        _ = try f.apply([("language_model", .string("pending"))])
        #expect(f.engines == #"{"notes": "pending", "projects": "pending"}"#)
        let d = try f.page()["downloads"]
        #expect(!(d?["needed"]?.arrayValue ?? []).contains { $0["id"] == .string("gemma") })  // not chosen: not downloaded
        var by: [String: JSONValue] = [:]
        for c in try f.page()["summary"]?.arrayValue ?? [] { by[c["name"]!.stringValue!] = c }
        #expect(by["Notes and projects"]?["detail"]?.stringValue?.contains("none yet") == true)
    }

    @Test func test_gemma_chosen_on_16_gb_is_a_download_with_its_catch() throws {
        let f = try Fixture()
        f.probe.hw = Hardware(chip: "Apple M2 Pro", memoryGB: 16, freeDiskGB: 200)
        _ = try f.apply([("language_model", .string("local:\(GEMMA)"))])
        let gemma = (try f.page()["downloads"]?["needed"]?.arrayValue ?? []).first { $0["id"] == .string("gemma") }
        #expect(gemma?["disk_gb"] == .double(8.3))
        #expect(gemma?["note"] == .string("needs 14 GB free while writing; this Mac has 16 GB"))
    }

    @Test func test_the_page_asks_for_no_hugging_face_token() throws {
        let d = try Fixture().page()["downloads"]
        #expect(d?["hf_token"] == nil)  // the speech models come without an account
    }

    @Test func test_a_deliberate_switch_is_chosen() throws {
        let f = try Fixture()
        try SettingsFile.update([("realtime", .bool(false))], stores: f.stores)
        let recs = try f.recs()
        #expect(recs["realtime"]?["chosen"] == .bool(true) && recs["live_processing"]?["chosen"] == .bool(false))
    }

    @Test func test_a_new_name_keeps_the_old_one_as_an_alias() throws {
        let f = try Fixture()
        f.app.userName = "Timo"
        func name(_ n: String) throws { _ = try SetupAPI.setProfile(f.app, obj([("name", .string(n)), ("organization", .string(""))])) }
        try name("Timo Strauß")
        #expect(SettingsFile.userAliases(stores: f.stores) == ["Timo"])
        try name("Timo Strauß")  // unchanged: nothing more
        try name("T. Strauß")
        #expect(SettingsFile.userAliases(stores: f.stores) == ["Timo", "Timo Strauß"])
        try name("Timo")  // back: no longer an alias
        #expect(SettingsFile.userAliases(stores: f.stores) == ["Timo Strauß", "T. Strauß"])
    }

    // MARK: - over HTTP

    @Test func test_http_setup_routes() throws {
        let probe = FakeProbe()
        probe.events = [Fixture.weekly()]
        let mac = FakeMenuBarApp(probe)
        let s = try TestServer(userName: "User", recording: mac, probe: probe, provider: FakeProviders())
        defer { s.stop() }
        let page = s.get("/api/setup")
        #expect(page.status == 200 && dumps(page.json?["offer"]) == #"{"why": "first"}"#)
        #expect(dumps(s.get("/api/setup/offer").json) == #"{"offer": {"why": "first"}}"#)
        #expect(s.get("/api/setup/recommendations").status == 200)
        #expect(s.post("/api/setup/apply", obj([("changes", obj([("realtime", .bool(false))]))])).status == 200)
        #expect(SettingsFile.load(stores: s.app.stores).realtime == false)
        let wrong = s.post("/api/setup/apply", obj([("changes", obj([("realtime", .int(1))]))]))
        #expect(wrong.status == 400 && wrong.error == "realtime must be true or false")
        #expect(s.post("/api/setup/profile", obj([("name", .string("Anna")), ("organization", .string(""))])).status == 200)
        #expect(s.post("/api/setup/glossary", obj([("terms", .strings(["Northwind"]))])).json?["added"] == .int(1))
        #expect(s.post("/api/setup/autostart", obj([("on", .bool(true))])).status == 200)
        #expect(s.get("/api/setup/test").json?["state"] == .string("idle"))
        #expect(s.get("/api/setup/calendar").json?["state"] == .string("not_asked"))
        #expect(s.post("/api/setup/calendar", obj([("action", .string("connect"))])).json?["asked"] == .bool(true))
        #expect(s.get("/api/setup/calendar").json?["state"] == .string("granted"))
        #expect(dumps(s.get("/api/setup/downloads").json) == #"{"running": false, "models": []}"#)
        #expect(s.post("/api/setup/finish", obj([("how", .string("skipped"))])).status == 200)
        #expect(dumps(s.get("/api/setup/offer").json) == #"{"offer": null}"#)
        #expect(s.post("/api/setup/nothing", obj([])).status == 404)
        #expect(s.post("/api/setup/finish", .array([])).status == 500)  // `body.get` of a list
    }

    /// Outside the menu bar app (`recording` nil): the test is idle and never starts, the calendar is this process's to
    /// read and nobody's to ask.
    @Test func outsideTheAppTheTestAndTheCalendarCannotStart() throws {
        let s = try TestServer(userName: "User", recording: nil, probe: FakeProbe(), provider: FakeProviders())
        defer { s.stop() }
        #expect(dumps(s.get("/api/setup/test").json) == #"{"state": "idle", "max_seconds": 20.0}"#)
        #expect(s.post("/api/setup/test", obj([("action", .string("start"))])).error == Remote.NO_ANSWER)
        #expect(s.post("/api/setup/test", obj([("action", .string("stop"))])).json?["state"] == .string("idle"))
        #expect(s.post("/api/setup/calendar", obj([("action", .string("connect"))])).error == Remote.NO_ANSWER)
        #expect(s.get("/api/setup/calendar").json?["state"]?.stringValue != nil)
    }
}
