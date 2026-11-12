// Housekeeping, the calendar (onboarding.Calendar and menubar's attach retry), the permission prompts
// (menubar.permissions_to_request) and the Python commands behind updates. Fakes only: nothing is asked of
// macOS, nothing is started.
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverDaemon

final class ExtraWorker: WorkerProcess, @unchecked Sendable {
    var pid: Int32 = 1
    var ended = false
    func poll() -> Int32? { ended ? 0 : nil }
    func terminate() {}
    func kill() {}
}

final class Started: @unchecked Sendable {
    var all: [(String, [String])] = []
    var workers: [ExtraWorker] = []
    var fail = false
    lazy var start: WorkerStarter = { [self] cmd, extra in
        if fail { throw WorkerError(description: "no python") }
        all.append((cmd, extra))
        let w = ExtraWorker()
        workers.append(w)
        return w
    }
}

/// Runs each part at once, or keeps it to run later (`hold`).
final class Parts: @unchecked Sendable {
    var ran: [String] = []
    var hold = false
    var held: [(@Sendable () -> Void, @Sendable () -> Void)] = []
    lazy var run: Housekeeping.Runner = { [self] name, work, done in
        ran.append(name)
        if hold { held.append((work, done)) } else { work(); done() }
    }
    func finish() { for (work, done) in held { work(); done() }; held = [] }
}

@Suite struct HousekeepingTests {
    final class Count: @unchecked Sendable { var startup = 0, hourly = 0 }

    @Test func atStartItRunsTheStartPartOnce() {
        let parts = Parts(), count = Count()
        let h = Housekeeping(atStart: { count.startup += 1 }, hourly: { count.hourly += 1 }, run: parts.run)
        h.atStart(); h.atStart()
        #expect(count.startup == 1 && count.hourly == 0 && parts.ran == ["housekeeping"])
    }

    @Test func theHourlyPartRunsOnTheFirstTickThenEveryHourWhenTheLastHasEnded() {
        let parts = Parts(), count = Count(), clock = TClock()
        let h = Housekeeping(atStart: {}, hourly: { count.hourly += 1 }, run: parts.run, now: { clock.t })
        h.tick()
        #expect(count.hourly == 1)
        clock.t += 3599; h.tick()
        #expect(count.hourly == 1)
        clock.t += 1; h.tick()
        #expect(count.hourly == 2)
    }

    @Test func aLongRunningHourlyPartIsNotStartedTwice() {
        let parts = Parts(), count = Count(), clock = TClock()
        parts.hold = true
        let h = Housekeeping(atStart: {}, hourly: { count.hourly += 1 }, run: parts.run, now: { clock.t })
        h.tick()
        clock.t += 7200; h.tick()
        #expect(parts.ran == ["audio-cleanup"])
        parts.finish()
        #expect(count.hourly == 1)
        clock.t += 3600; h.tick()
        #expect(parts.ran.count == 2)
    }

    /// A temporary home: the Hugging Face cache, settings.json, a recordings folder.
    final class Home {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-housekeeping-\(UUID().uuidString)")
        let stores: StorePaths
        var rec: URL { dir.appendingPathComponent("Recordings", isDirectory: true) }
        var config: Config { var c = Config(); c.outputDir = rec; return c }

        init() {
            stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver"), home: dir.appendingPathComponent("home"),
                                hubCache: dir.appendingPathComponent("hub"))
        }
        deinit { try? FileManager.default.removeItem(at: dir) }

        func file(_ url: URL, _ bytes: Int) {
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(repeating: 7, count: bytes).write(to: url)
        }
        func model(_ repo: String) -> URL {
            let folder = ModelCatalog.cacheDir(repo, stores: stores)
            file(folder.appendingPathComponent("blobs/abc"), 100)
            return folder
        }
        func meeting(_ name: String) -> RecordingPaths {
            let p = RecordingPaths(rec.appendingPathComponent(name, isDirectory: true))
            file(p.micWav, 1000)
            file(p.transcriptJson, 2)
            return p
        }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    }

    @Test func atStartOnlyTheRetiredModelsGo_andWhatTheyFreedIsLogged() {
        let home = Home(), parts = Parts()
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let lines = Lines()
        let qwen = home.model(ModelCatalog.QWEN)
        let parakeet = home.model("mlx-community/parakeet-tdt-0.6b-v3")  // retired, but the user deletes it
        let gemma = home.model(ModelCatalog.GEMMA)  // offered
        let stores = home.stores, config = home.config
        final class Extras: @unchecked Sendable { var ran = 0 }
        let extras = Extras()
        let h = Housekeeping.inProcess(config: { config }, stores: { stores },
                                       extras: [("moving the MCP entries", { extras.ran += 1 }),
                                                ("pruning", { throw WorkerError(description: "disk gone") })],
                                       log: { lines.all.append($0) }, run: parts.run)
        h.atStart()
        #expect(!home.exists(qwen) && home.exists(parakeet) && home.exists(gemma))
        #expect(extras.ran == 1)
        #expect(lines.all.count == 2 && lines.all[0].hasPrefix("deleted the models no longer offered") && lines.all[1] == "pruning failed: disk gone")
    }

    @Test func atStartClaudesOldMcpEntriesMoveToTheBundlesBinPalaver() throws {
        let home = Home(), parts = Parts()
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let lines = Lines()
        let stores = home.stores, config = home.config
        let claude = stores.claudeConfig  // the test's own home: never the real ~/.claude.json
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mcpServers": {"meetings": {"command": "/Applications/Palaver.app/Contents/Resources/bin/python", "args": ["-m", "palaver", "mcp"]}}}"#.utf8)
            .write(to: claude)
        // An installed app: in the test home's ~/Applications, with its bin/palaver.
        let app = stores.applications.appendingPathComponent("Palaver.app")
        let bin = app.appendingPathComponent("Contents/Resources/bin/palaver")
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: bin)
        chmod(bin.path, 0o755)
        Housekeeping.inProcess(config: { config }, stores: { stores },
                               extras: [Housekeeping.movingMcpEntries(bundle: nil, stores: { stores }, log: { lines.all.append($0) })],
                               log: { lines.all.append($0) }, run: parts.run).atStart()
        #expect(PythonJSON.read(claude)?["mcpServers"]?["meetings"]?["command"]?.stringValue?.hasSuffix("/bin/python") == true)  // a checkout
        Housekeeping.inProcess(config: { config }, stores: { stores },
                               extras: [Housekeeping.movingMcpEntries(bundle: app, stores: { stores }, log: { lines.all.append($0) })],
                               log: { lines.all.append($0) }, run: parts.run).atStart()
        #expect(PythonJSON.read(claude)?["mcpServers"]?["palaver"]?["command"] == .string(bin.resolvingSymlinksInPath().path))
        #expect(PythonJSON.read(claude)?["mcpServers"]?["palaver"]?["args"] == .strings(["mcp"]))
        #expect(lines.all.contains("Claude's MCP entries were updated (code)"))
    }

    @Test func hourlyOnlyTheAudioOlderThanSettingsSayGoes() throws {
        let home = Home(), parts = Parts(), clock = TClock()
        let old = home.meeting("2020-01-01T10-00-00")
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let today = home.meeting(stamp.string(from: Date()))
        let stores = home.stores, config = home.config
        let h = Housekeeping.inProcess(config: { config }, stores: { stores }, run: parts.run, now: { clock.t })
        h.tick()  // Settings say nothing: the audio stays
        #expect(home.exists(old.micWav) && home.exists(today.micWav))
        try Storage.setAudioDays(.int(30), stores: stores)
        clock.t += 3600; h.tick()
        #expect(!home.exists(old.micWav) && home.exists(old.transcriptJson) && home.exists(today.micWav))
    }
}

final class FakeCalendar: CalendarAccess, @unchecked Sendable {
    var auth: CalendarAuth = .notDetermined
    var asked = 0
    func authorization() -> CalendarAuth { auth }
    func requestAccess() { asked += 1 }
}

final class Opened: @unchecked Sendable { var urls: [String] = [] }

@Suite struct CalendarTests {
    @Test func statusMapsEventKitsStates() {
        let cal = FakeCalendar()
        let c = CalendarOnboarding(access: cal, open: { _ in })
        let expect: [(CalendarAuth, String, String)] = [
            (.notDetermined, "not_asked", "not connected"), (.fullAccess, "granted", "connected (read only)"),
            (.writeOnly, "denied", "write-only access: Palaver can't read events"), (.denied, "denied", "not allowed"),
            (.unknown, "unknown", "could not check")]
        for (auth, state, detail) in expect {
            cal.auth = auth
            let s = c.status()
            #expect(s["state"] as? String == state && s["detail"] as? String == detail)
        }
    }

    @Test func connectAsksOnceWhenNotAskedAndOpensSettingsWhenDenied() {
        let cal = FakeCalendar(), opened = Opened()
        let c = CalendarOnboarding(access: cal, open: { opened.urls.append($0) })
        var a = c.connect()
        #expect(cal.asked == 1 && a["asked"] as? Bool == true && a["state"] as? String == "not_asked" && opened.urls.isEmpty)
        cal.auth = .denied
        a = c.connect()
        #expect(cal.asked == 1 && a["opened_settings"] as? Bool == true)
        #expect(opened.urls == ["x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"])
        cal.auth = .fullAccess
        a = c.connect()
        #expect(a["state"] as? String == "granted" && a["asked"] == nil && a["opened_settings"] == nil)
        #expect(cal.asked == 1 && opened.urls.count == 1)
    }

    private func attach(transcribing: Bool = false) -> (CalendarAttach, FakeCalendar, Started, TClock, Box<Bool>) {
        let cal = FakeCalendar(), s = Started(), clock = TClock(), busy = Box(transcribing)
        let a = CalendarAttach(access: cal, transcribing: { busy.value }, start: s.start, now: { clock.t })
        return (a, cal, s, clock, busy)
    }

    @Test func onConnectEveryEarlierRecordingGetsItsEvent() {
        let (a, cal, s, _, _) = attach()
        a.check()
        #expect(s.all.isEmpty && !a.isConnected)  // not connected: nothing, and it asks nothing
        cal.auth = .fullAccess
        a.check()
        #expect(a.isConnected && s.all.count == 1 && s.all[0].0 == "calendar-attach" && s.all[0].1 == [])
        a.check()
        #expect(s.all.count == 1)  // once
    }

    @Test func theCalendarSwitchIsPythonsDecisionNotASecondGateHere() {
        // [calendar].enabled is read by `palaver-worker calendar-attach` (it answers "skipped"): Swift starts it whenever
        // access is given.
        let (a, cal, s, clock, _) = attach()
        cal.auth = .fullAccess
        a.check()
        s.workers[0].ended = true
        clock.t += 400
        a.retryTick()
        #expect(s.all.count == 2 && s.all[1].1 == ["--since", "36"])
    }

    @Test func theRetryRunsEveryFiveMinutesOverTheLast36HoursAndNotWhileTranscribing() {
        let (a, cal, s, clock, busy) = attach()
        cal.auth = .fullAccess
        a.check()
        s.workers[0].ended = true
        clock.t += 299; a.retryTick()
        #expect(s.all.count == 1)
        clock.t += 1; busy.value = true; a.retryTick()
        #expect(s.all.count == 1)  // transcribing: processing looks the event up itself; the 5 minutes restart
        busy.value = false
        clock.t += 299; a.retryTick()
        #expect(s.all.count == 1)
        clock.t += 1; a.retryTick()
        #expect(s.all.count == 2 && s.all[1].1 == ["--since", "36"])
    }

    @Test func noRetryBeforeAccessIsGiven() {
        let (a, _, s, clock, _) = attach()
        clock.t += 1000; a.retryTick()
        #expect(s.all.isEmpty)
    }

    @Test func aRunningAttachIsNotStartedTwice() {
        let (a, cal, s, clock, _) = attach()
        cal.auth = .fullAccess
        a.check()
        clock.t += 400; a.retryTick()
        #expect(s.all.count == 1)
    }
}

final class FakeRequester: PermissionRequester, @unchecked Sendable {
    var mic: MicStatus = .notDetermined
    var requested = 0, probes = 0
    var probeFails = false
    func micStatus() -> MicStatus { mic }
    func requestMic() { requested += 1 }
    func probeSystemAudio() throws {
        probes += 1
        if probeFails { throw WorkerError(description: "denied") }
    }
}

@Suite struct PermissionsTests {
    @Test func whichPromptsAreTriggered() {
        #expect(Permissions.toRequest(mic: .notDetermined, markerExists: false) == ["microphone", "system-audio"])
        #expect(Permissions.toRequest(mic: .authorized, markerExists: false) == ["system-audio"])
        #expect(Permissions.toRequest(mic: .notDetermined, markerExists: true) == ["microphone"])
        #expect(Permissions.toRequest(mic: .denied, markerExists: true) == [])
        #expect(Permissions.toRequest(mic: .restricted, markerExists: true) == [])
    }

    @Test func atLaunchItAsksForTheMicAndProbesSystemAudioOnceWritingTheMarker() throws {
        let r = FakeRequester(), marker = tempDir().appendingPathComponent("sub/permissions-requested")
        #expect(Permissions.requestAtLaunch(r, marker: marker) == ["microphone", "system-audio"])
        #expect(r.requested == 1 && r.probes == 1 && exists(marker))
        r.mic = .denied
        #expect(Permissions.requestAtLaunch(r, marker: marker) == [])
        #expect(r.requested == 1 && r.probes == 1)  // asked once per install
    }

    @Test func aFailingProbeStillWritesTheMarkerSoItIsNotRepeatedEachStart() {
        let r = FakeRequester(), marker = tempDir().appendingPathComponent("permissions-requested")
        r.probeFails = true
        r.mic = .authorized
        final class Logged: @unchecked Sendable { var lines: [String] = [] }
        let l = Logged()
        Permissions.requestAtLaunch(r, marker: marker, log: { l.lines.append($0) })
        #expect(exists(marker) && l.lines.count == 1)
    }

    @Test func anUpdateRemovesTheMarkerSoTheNewBuildAsksAtItsRestart() {
        // updater.Installer.commit does (tests/test_updater.py): here, that the marker decides.
        let r = FakeRequester(), marker = tempDir().appendingPathComponent("permissions-requested")
        r.mic = .authorized
        Permissions.requestAtLaunch(r, marker: marker)
        try? FileManager.default.removeItem(at: marker)
        Permissions.requestAtLaunch(r, marker: marker)
        #expect(r.probes == 2)
    }
}

@Suite struct ExtraCallsTests {
    private func rig() -> (calls: [String: AppHandler], cal: FakeCalendar, backend: FakeUpdateBackend, opened: Opened) {
        let cal = FakeCalendar(), opened = Opened(), backend = FakeUpdateBackend()
        let updates = Updates(.init(backend: backend, background: { $0() }, appPids: { [77] }, startedOk: tempDir().appendingPathComponent("ok")))
        updates.load()
        let main = MainRunner(schedule: { $0() })
        return (ExtraCalls.make(calendar: CalendarOnboarding(access: cal, open: { opened.urls.append($0) }), updates: updates, main: main),
                cal, backend, opened)
    }

    @Test func calendarIsStatusOrConnect() async throws {
        let r = rig()
        let status = try await r.calls["calendar"]!([:]) as? [String: Any]
        #expect(status?["state"] as? String == "not_asked" && r.cal.asked == 0)
        let connect = try await r.calls["calendar"]!(["action": "connect"]) as? [String: Any]
        #expect(connect?["asked"] as? Bool == true && r.cal.asked == 1)
    }

    @Test func updateCheckAndInstallAnswerTheStatus() async throws {
        let r = rig()
        let checked = try await r.calls["update_check"]!([:]) as? [String: Any]
        #expect(checked?["current"] as? String == "0.1.0")
        #expect(r.backend.checks == 1)
        let installed = try await r.calls["update_install"]!([:]) as? [String: Any]
        #expect(installed?["state"] as? String == "ready" && r.backend.downloads == ["0.2.0"])
    }

    @Test func uninstallStartsTheScriptOnTheMainThreadAndIsNeverRealHere() async throws {
        let r = rig()
        let a = try await r.calls["uninstall"]!(["models": true, "recordings": false]) as? [String: Any]
        #expect(a?["removing"] as? [String] == ["/a"])
        #expect(r.backend.uninstalls.count == 1 && r.backend.uninstalls[0].0 && !r.backend.uninstalls[0].1 && r.backend.uninstalls[0].2 == [77])
    }
}
