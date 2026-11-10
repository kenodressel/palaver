// `palaver doctor` in Swift (doctor.py): each check with this Mac and the network faked, failing in turn; the text
// and the exit code. Nothing is asked of macOS, nothing goes online. Ports tests/test_doctor.py's tests.
import Darwin
import Foundation
import Testing
import PalaverCloud
import PalaverCore
import PalaverDomain
@testable import PalaverServer

/// This Mac and the network as a test sets them.
private final class FakeDoctorProbe: DoctorProbe, @unchecked Sendable {
    var version = "15.1"
    var http: [String: Int] = [:]
    var offline = false
    var keychainToken: String?
    /// The Keychain's token from elsewhere (the server's key store) instead of `keychainToken`.
    var keychain: (() -> String?)?
    /// Each request's Authorization header.
    var authorizations: [String] = []
    var hello: Result<JSONValue?, Error> = .success(.object([("models", .object([("asr", .bool(true)), ("diarizer", .bool(true))]))]))
    var filesHere = true
    var inBundle = true
    var microphone = 3
    var devices: Result<(input: (String, Double)?, output: (String, Double)?), Error> = .success((("MacBook Pro Microphone", 48000),
                                                                                                  ("MacBook Pro Speakers", 44100)))
    var processes: Result<[AudioProcess], Error> = .success([AudioProcess(bundleId: "com.microsoft.teams2", runningInput: false)])
    var teams = true
    var free = 100 * (1 << 30)
    var ram = 32.0
    var running: JSONValue?
    var asked: [String] = []

    func macOSVersion() -> String { version }
    func httpStatus(_ url: String, headers: [String: String]) throws -> Int {
        asked.append(url)
        authorizations.append(headers["Authorization"] ?? "")
        if offline { throw URLError(.notConnectedToInternet) }
        return http[url] ?? 404
    }
    func keychainNotionToken() -> String? { keychain.map { $0() } ?? keychainToken }
    func engineHello() throws -> JSONValue? { try hello.get() }
    func speechFilesHere() -> Bool { filesHere }
    func microphoneStatus() -> Int { microphone }
    func defaultDevices() throws -> (input: (String, Double)?, output: (String, Double)?) { try devices.get() }
    func audioProcesses() throws -> [AudioProcess] { try processes.get() }
    func teamsInstalled() -> Bool { teams }
    func freeBytes(_ url: URL) -> Int { free }
    func ramGB() -> Double { ram }
    func runningMemory() -> JSONValue? { running }
}

private struct Failure: Error, CustomStringConvertible { let description: String }

private final class Home {
    let dir = tempFolder("doctor")
    let stores: StorePaths
    var rec: URL { dir.appendingPathComponent("Recordings", isDirectory: true) }

    init(config: String = "") {
        stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                            home: dir.appendingPathComponent("home", isDirectory: true))
        try! FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: stores.configDir, withIntermediateDirectories: true)
        try! Data(("[recording]\noutput_dir = \"\(rec.path)\"\n" + config).utf8).write(to: stores.configToml)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func run(_ probe: FakeDoctorProbe, env: [String: String] = [:], offline: Bool = false) -> [SetupCheck] {
        Doctor.run(configURL: stores.configToml, stores: stores, env: env, offline: offline, probe: probe, timeZone: TimeZone(identifier: "Europe/Berlin")!)
    }

    func meeting(_ name: String, _ files: [String: String]) {
        let folder = rec.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (file, text) in files { try! Data(text.utf8).write(to: folder.appendingPathComponent(file)) }
    }
}

private func check(_ checks: [SetupCheck], _ name: String) -> SetupCheck? { checks.first { $0.name == name } }

@Suite struct DoctorTests {
    @Test func aGoodMacIsAllSetAndExitsZero() {
        let home = Home()
        let checks = home.run(FakeDoctorProbe())
        #expect(checks.map(\.name) == ["macOS", "Config", "Speech models", "Memory budgets", "Echo cancellation library",
                                       "Microphone permission", "System audio capture", "Audio devices", "Last recording's audio",
                                       "Teams detection", "Disk space"])
        #expect(checks.allSatisfy { $0.status != "fail" })
        #expect(Doctor.exitCode(checks) == 0)
        #expect(Doctor.text(checks).hasSuffix("\n\nAll set."))
        #expect(check(checks, "Echo cancellation library")?.detail == "built in")
        #expect(check(checks, "Audio devices")?.detail == "input MacBook Pro Microphone (48 kHz), output MacBook Pro Speakers (44.1 kHz)")
        #expect(check(checks, "Teams detection")?.detail == "works (1 audio processes; Teams running)")
    }

    @Test func formatMarksEachCheckAndHintsOnlyWhereSomethingIsWrong() {
        let text = Doctor.format([SetupCheck("A", "ok", "fine", "never shown"), SetupCheck("B", "warn", "hmm", "do this"),
                                  SetupCheck("C", "fail", "broken", "fix that")])
        #expect(text == "✓ A: fine\n! B: hmm\n    → do this\n✗ C: broken\n    → fix that")
        let checks = [SetupCheck("C", "fail", "broken", "fix that"), SetupCheck("D", "fail", "too", "")]
        #expect(Doctor.text(checks).hasSuffix("\n\n2 problem(s) to fix.") && Doctor.exitCode(checks) == 1)
    }

    @Test func anOldMacOSMustBeFixed() {
        let probe = FakeDoctorProbe()
        probe.version = "14.6.1"
        let c = check(Home().run(probe), "macOS")!
        #expect(c.status == "fail" && c.fix == "Palaver needs macOS 15+")
    }

    @Test func notionIsCheckedOnlineWithItsTokenAndTarget() {
        let home = Home(config: "[notion]\ntoken = \"secret_abc\"\nparent_page_id = \"page1\"\n")
        let probe = FakeDoctorProbe()
        probe.http = ["\(Doctor.NOTION_API)/users/me": 200, "\(Doctor.NOTION_API)/pages/page1": 200]
        #expect(check(home.run(probe), "Notion")?.detail == "token valid, page accessible")
        probe.http["\(Doctor.NOTION_API)/users/me"] = 401
        let rejected = check(home.run(probe), "Notion")!
        #expect(rejected.status == "fail" && rejected.detail == "token rejected")
        probe.http["\(Doctor.NOTION_API)/users/me"] = 200
        probe.http["\(Doctor.NOTION_API)/pages/page1"] = 404
        let unshared = check(home.run(probe), "Notion")!
        #expect(unshared.status == "fail" && unshared.detail == "page page1 not accessible (404)")
        #expect(unshared.fix == "share the page with your integration (••• → Connections)")
        probe.offline = true
        #expect(check(home.run(probe), "Notion")?.status == "warn")
        probe.asked = []
        #expect(check(home.run(probe, offline: true), "Notion") == nil && probe.asked.isEmpty)  // --offline asks nothing
    }

    @Test func notionWithoutATokenIsNotChecked_andTheKeychainsTokenCounts() {
        let home = Home(config: "[notion]\nmode = \"database\"\ndatabase_id = \"db1\"\n")
        let probe = FakeDoctorProbe()
        #expect(check(home.run(probe), "Notion") == nil && probe.asked.isEmpty)
        probe.keychainToken = "from-the-keychain"
        probe.http = ["\(Doctor.NOTION_API)/users/me": 200, "\(Doctor.NOTION_API)/databases/db1": 200]
        #expect(check(home.run(probe), "Notion")?.detail == "token valid, database accessible")
        probe.keychainToken = nil
        #expect(check(home.run(probe, env: ["NOTION_TOKEN": "from-env"]), "Notion")?.status == "ok")
    }

    @Test func theDoctorFindsANotionTokenOnlyThePythonAppSaved() throws {
        let home = Home(config: "[notion]\nmode = \"database\"\ndatabase_id = \"db1\"\n")
        let kc = try PythonKeychain(account: Tokens.NOTION, value: "secret_saved_by_python")
        let probe = FakeDoctorProbe()
        probe.keychain = ServeMain.doctorProbe(stores: home.stores, env: [:], keys: kc.store).keychainNotionToken
        probe.http = ["\(Doctor.NOTION_API)/users/me": 200, "\(Doctor.NOTION_API)/databases/db1": 200]
        #expect(check(home.run(probe), "Notion")?.detail == "token valid, database accessible")
        #expect(probe.authorizations.first == "Bearer secret_saved_by_python")
        #expect(kc.copied(Tokens.NOTION))
    }

    @Test func theServersDoctorUsesANotionTokenOnlyTheKeychainHolds_afterTheEnvironmentAndConfigToml() throws {
        let home = Home(config: "[notion]\nmode = \"database\"\ndatabase_id = \"db1\"\n")
        let keys = FileKeyStore(home.dir.appendingPathComponent("keychain.json"))
        try keys.write(Tokens.NOTION, "secret_only_in_the_keychain")
        let mac = ServeMain.doctorProbe(stores: home.stores, env: [:], keys: keys)
        let probe = FakeDoctorProbe()
        probe.keychain = mac.keychainNotionToken
        probe.http = ["\(Doctor.NOTION_API)/users/me": 200, "\(Doctor.NOTION_API)/databases/db1": 200]
        #expect(check(home.run(probe), "Notion")?.detail == "token valid, database accessible")
        #expect(probe.authorizations == ["Bearer secret_only_in_the_keychain", "Bearer secret_only_in_the_keychain"])
        probe.authorizations = []
        _ = home.run(probe, env: ["NOTION_TOKEN": "from-env"])
        #expect(probe.authorizations.first == "Bearer from-env")
        let configured = Home(config: "[notion]\ntoken = \"from-config-toml\"\nmode = \"database\"\ndatabase_id = \"db1\"\n")
        probe.authorizations = []
        _ = configured.run(probe)
        #expect(probe.authorizations.first == "Bearer from-config-toml")
    }

    @Test func speechModelsAreAskedOfTheEngine() {
        let probe = FakeDoctorProbe()
        probe.hello = .success(.object([("models", .object([("asr", .bool(true)), ("diarizer", .bool(false))]))]))
        let missing = check(Home().run(probe), "Speech models")!
        #expect(missing.status == "warn" && missing.detail == "not downloaded yet (speakers)")
        probe.hello = .failure(Failure(description: "dyld: missing symbol\nmore"))
        let broken = check(Home().run(probe), "Speech models")!
        #expect(broken.status == "fail" && broken.detail == "the speech engine does not run (dyld: missing symbol)")
        #expect(broken.fix == "reinstall Palaver")
    }

    @Test func withoutTheEngineTheFilesSay() {
        let probe = FakeDoctorProbe()
        probe.hello = .success(nil)
        #expect(check(Home().run(probe), "Speech models")?.detail == "downloaded (the engine is not built, files checked)")
        probe.filesHere = false
        probe.inBundle = false
        let c = check(Home().run(probe), "Speech models")!
        #expect(c.status == "warn" && c.detail.contains("run `make engine`") && c.fix.hasSuffix("run `make engine` first"))
    }

    @Test func microphonePermissionStates() {
        #expect(Doctor.checkMicrophone(3).status == "ok")
        #expect(Doctor.checkMicrophone(0).status == "warn")
        let denied = Doctor.checkMicrophone(2)
        #expect(denied.status == "fail" && denied.fix.contains("Microphone"))
        let probe = FakeDoctorProbe()
        probe.microphone = 2
        let checks = Home().run(probe)
        #expect(check(checks, "Microphone permission")?.status == "fail" && Doctor.exitCode(checks) == 1)
    }

    @Test func systemAudioFromTheLastRecording() {
        let home = Home()
        #expect(check(home.run(FakeDoctorProbe()), "System audio capture")?.detail == "not verified yet")
        home.meeting("2026-10-29T16-07-00", ["session.log": #"{"event": "record_start", "system_source": "screencapturekit"}"# + "\n",
                                             "title.json": #"{"title": "Weekly"}"#])
        let fallback = check(home.run(FakeDoctorProbe()), "System audio capture")!
        #expect(fallback.status == "warn" && fallback.detail.contains("ScreenCaptureKit") && fallback.detail.contains("“Weekly”"))
        home.meeting("2026-10-30T09-00-00", ["session.log": "not json\n" + #"{"event": "record_start", "system_source": "process-tap"}"# + "\n"])
        #expect(check(home.run(FakeDoctorProbe()), "System audio capture")?.status == "ok")
    }

    @Test func audioDevicesNameMissingOnesAndSurviveCoreAudioFailing() {
        let probe = FakeDoctorProbe()
        probe.devices = .success((("USB Mic", 16000), nil))
        let c = check(Home().run(probe), "Audio devices")!
        #expect(c.status == "warn" && c.detail == "input USB Mic (16 kHz), no output device")
        probe.devices = .failure(Failure(description: "kAudioHardwareNotRunningError"))
        #expect(check(Home().run(probe), "Audio devices")?.detail == "could not read them (kAudioHardwareNotRunningError)")
    }

    @Test func theLastRecordingsAudioProblems() {
        let home = Home()
        home.meeting("2026-10-29T10-00-00", ["meta.json": #"{"start_time": "2026-10-29T10:00:00+01:00"}"#])
        home.meeting("2026-10-30T10-00-00", ["meta.json": #"{"start_time": "2026-10-30T10:00:00+01:00", "audio_problems": [{"kind": "mic_silent", "start": 60}, {"kind": "x", "start": 90}]}"#])
        let c = check(home.run(FakeDoctorProbe()), "Last recording's audio")!
        #expect(c.status == "warn" && c.detail.hasPrefix("2026-10-30T10-00-00: ") && c.detail.hasSuffix(" (and 1 more)"))
        #expect(c.fix.hasSuffix("2026-10-30T10-00-00/session.log"))
    }

    @Test func teamsDetection() {
        let probe = FakeDoctorProbe()
        probe.teams = false
        #expect(check(Home().run(probe), "Teams detection")?.detail == "Microsoft Teams not installed in /Applications")
        probe.processes = .failure(Failure(description: "status -1"))
        let c = check(Home().run(probe), "Teams detection")!
        #expect(c.status == "fail" && c.fix == "needs macOS 14.4+")
    }

    @Test func diskSpace() {
        let probe = FakeDoctorProbe()
        probe.free = 1 << 30
        #expect(check(Home().run(probe), "Disk space")?.status == "fail")
        probe.free = 5 * (1 << 30)
        #expect(check(Home().run(probe), "Disk space")?.status == "warn")
    }

    @Test func memoryBudgetsAgainstThisMacAndWhatPalaverUses() {
        var b = MemoryBudgets()
        let ok = Doctor.checkMemory(b, ramGB: 64, running: .object([("total", .int(3 * (1 << 30)))]))
        #expect(ok.status == "ok" && ok.detail.hasPrefix("live 2 GB, realtime 1.5 GB, transcription 4 GB, notes 14 GB, search index 1 GB"))
        #expect(ok.detail.hasSuffix("; Palaver uses 3 GB now"))
        #expect(Doctor.checkMemory(b, ramGB: 6, running: nil).detail.contains("during a call"))
        #expect(Doctor.checkMemory(b, ramGB: 16, running: nil).detail.hasPrefix("notes may use 14 GB"))
        b.notes = 2
        b.process = 14
        #expect(Doctor.checkMemory(b, ramGB: 16, running: nil).detail.hasPrefix("a transcription may use 14 GB"))
        let over = Doctor.checkMemory(MemoryBudgets(), ramGB: 64, running: .object([("workers", .array([
            .object([("label", .string("Live transcription")), ("used", .int(3 * (1 << 30))), ("budget", .double(2.0))])]))]))
        #expect(over.status == "warn" && over.detail == "Live transcription uses 3 GB, over its 2 GB budget")
    }

    @Test func aConfigThatCannotBeReadMustBeFixed_aMissingOneIsTheDefaults() throws {
        let home = Home()
        try Data([0xFF, 0xFE, 0x00]).write(to: home.stores.configToml)
        let checks = home.run(FakeDoctorProbe())
        #expect(check(checks, "Config")?.status == "fail" && check(checks, "Speech models") == nil)
        try FileManager.default.removeItem(at: home.stores.configToml)
        #expect(check(home.run(FakeDoctorProbe()), "Config")?.detail == "none: the defaults")
    }

    /// This Mac's read-only answers (no microphone prompt, no engine, no network): they come back without failing.
    @Test func theMacProbeReadsThisMacWithoutAskingAnything() throws {
        let home = Home()
        let probe = MacDoctorProbe(stores: home.stores, env: ["PALAVER_ENGINE": home.dir.appendingPathComponent("none").path])
        #expect(probe.macOSVersion().split(separator: ".").count >= 2)
        #expect(probe.ramGB() > 0 && probe.freeBytes(home.dir) > 0)
        #expect(probe.runningMemory() == nil)  // no daemon.json in this home
        _ = try? probe.defaultDevices()  // a Mac without devices answers nil, never traps
        #expect(try probe.engineHello() == nil)  // no engine binary: the files decide
    }
}
