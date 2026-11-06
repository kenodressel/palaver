// Housekeeping, the calendar (onboarding.Calendar and menubar's attach retry), the permission prompts
// (menubar.permissions_to_request) and the Python commands behind updates. Fakes only: nothing is asked of
// macOS, nothing is started.
import Foundation
import Testing
import PalaverCore
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

@Suite struct HousekeepingTests {
    @Test func atStartItRunsTheStartCommand() {
        let s = Started()
        Housekeeping(start: s.start).atStart()
        #expect(s.all.count == 1 && s.all[0].0 == "app" && s.all[0].1 == ["housekeeping"])
    }

    @Test func theHourlyPartRunsOnTheFirstTickThenEveryHourWhenTheLastHasEnded() {
        let s = Started(), clock = TClock()
        let h = Housekeeping(start: s.start, now: { clock.t })
        h.tick()
        #expect(s.all.map { $0.1 } == [["housekeeping", "--hourly"]])
        s.workers[0].ended = true
        clock.t += 3599; h.tick()
        #expect(s.all.count == 1)
        clock.t += 1; h.tick()
        #expect(s.all.count == 2)
    }

    @Test func aLongRunningHourlyWorkerIsNotStartedTwice() {
        let s = Started(), clock = TClock()
        let h = Housekeeping(start: s.start, now: { clock.t })
        h.tick()
        clock.t += 7200; h.tick()
        #expect(s.all.count == 1)
    }

    @Test func aStartFailureIsLoggedNotThrown() {
        let s = Started()
        s.fail = true
        final class Logged: @unchecked Sendable { var lines: [String] = [] }
        let l = Logged()
        let h = Housekeeping(start: s.start, log: { l.lines.append($0) })
        h.atStart(); h.tick()
        #expect(l.lines.count == 2)
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
        #expect(a.isConnected && s.all.count == 1 && s.all[0].0 == "calendar" && s.all[0].1 == ["attach"])
        a.check()
        #expect(s.all.count == 1)  // once
    }

    @Test func theCalendarSwitchIsPythonsDecisionNotASecondGateHere() {
        // [calendar].enabled is read by `palaver calendar attach` (it answers "skipped"): Swift starts it whenever
        // access is given.
        let (a, cal, s, clock, _) = attach()
        cal.auth = .fullAccess
        a.check()
        s.workers[0].ended = true
        clock.t += 400
        a.retryTick()
        #expect(s.all.count == 2 && s.all[1].1 == ["attach", "--since", "36"])
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
        #expect(s.all.count == 2 && s.all[1].1 == ["attach", "--since", "36"])
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

/// A fake `python`: a shell script printing what it is told to for `-m palaver … <cmd>` and recording its args.
private func fakePython(_ body: String) -> (path: String, args: URL) {
    let dir = tempDir()
    let args = dir.appendingPathComponent("args.txt")
    let script = dir.appendingPathComponent("python")
    touch(script, "#!/bin/sh\necho \"$@\" >> '\(args.path)'\n\(body)\n")
    chmod(script.path, 0o755)
    return (script.path, args)
}

@Suite struct PythonCommandTests {
    @Test func progressLinesThenTheAnswer() throws {
        let (python, _) = fakePython("echo '{\"progress\": 40}'; echo '{\"progress\": 105}'; echo '{\"ok\": true}'")
        final class Seen: @unchecked Sendable { var n: [Int] = [] }
        let seen = Seen()
        let a = try pythonCommandBlocking(["app", "update", "download", "--json"], python: python) { o in
            if let n = o["progress"] as? Int { seen.n.append(n) }
        }
        #expect(a["ok"] as? Bool == true && seen.n == [40, 105])
    }

    @Test func anErrorAnswerAndNoAnswerThrow() {
        let (bad, _) = fakePython("echo '{\"error\": \"offline\"}'; exit 1")
        #expect(throws: WorkerError.self) { try pythonCommandBlocking(["x"], python: bad) }
        do { _ = try pythonCommandBlocking(["x"], python: bad) } catch { #expect("\(error)" == "offline") }
        let (none, _) = fakePython("exit 3")
        #expect(throws: WorkerError.self) { try pythonCommandBlocking(["x"], python: none) }
    }

    @Test func theChildsStderrGoesToTheLogSoACrashShowsItsTraceback() {
        final class Logged: @unchecked Sendable { var lines: [String] = [] }
        let l = Logged()
        let (python, _) = fakePython("echo 'Traceback (most recent call last):' >&2; echo 'ValueError: boom' >&2; exit 1")
        #expect(throws: WorkerError.self) { try pythonCommandBlocking(["app", "update", "check"], python: python, log: { l.lines.append($0) }) }
        #expect(l.lines.contains("Traceback (most recent call last):") && l.lines.contains("ValueError: boom"))
        #expect(l.lines.allSatisfy { !$0.isEmpty })
    }

    @Test func aLotOfStderrDoesNotBlockTheChild() throws {
        final class Logged: @unchecked Sendable { var n = 0 }
        let l = Logged()
        let (python, _) = fakePython("i=0; while [ $i -lt 5000 ]; do echo \"warning $i\" >&2; i=$((i+1)); done; echo '{\"ok\": true}'")
        let a = try pythonCommandBlocking(["x"], python: python, log: { _ in l.n += 1 })
        #expect(a["ok"] as? Bool == true && l.n == 5000)
    }

    @Test func theBackendAsksPythonTheCommandsOfApp_update_py() throws {
        let (python, argsFile) = fakePython("""
            case "$*" in
              *"update status"*) echo '{"installed": {"version": "0.1.0", "runtime": "rt-1"}, "previous": {"state": "failed", "from_swap": true}}';;
              *"update check"*) echo '{"plan": {"version": "0.2.0", "notes": "n", "download_bytes": 5, "runtime": true, "models": ["m"]}}';;
              *"update download"*) echo '{"progress": 3}'; echo '{"ok": true, "version": "0.2.0"}';;
              *"update prepare"*) echo '{"script": "/u/swap.sh"}';;
              *"update commit"*) echo '{"ok": true}';;
              *"uninstall-start"*) echo '{"removing": ["/a", "/b"]}';;
            esac
            """)
        final class Ran: @unchecked Sendable { var scripts: [String] = [] }
        let ran = Ran()
        let b = PythonUpdateBackend(python: python, cliOptions: ["--config", "/c.toml"], env: [:], runScript: { ran.scripts.append($0) })
        let s = try b.status()
        #expect(s.installed == UpdateInstalled(version: "0.1.0", runtime: "rt-1") && s.previous?["from_swap"] == .bool(true))
        #expect(try b.check() == .plan(UpdatePlan(version: "0.2.0", notes: "n", downloadBytes: 5, runtime: true, models: ["m"])))
        final class Prog: @unchecked Sendable { var n: [Int] = [] }
        let prog = Prog()
        try b.download(version: "0.2.0") { prog.n.append($0) }
        #expect(prog.n == [3])
        #expect(try b.prepare(waitFor: [7, 8]) == "/u/swap.sh")
        try b.commit()
        try b.spawnSwap(script: "/u/swap.sh")
        #expect(ran.scripts == ["/u/swap.sh"])
        #expect(try b.uninstallStart(models: true, recordings: false, waitFor: [9]) == ["/a", "/b"])
        let lines = try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == [
            "-m palaver --config /c.toml app update status --json",
            "-m palaver --config /c.toml app update check --json",
            "-m palaver --config /c.toml app update download --version 0.2.0 --json",
            "-m palaver --config /c.toml app update prepare --wait-for 7 8 --json",
            "-m palaver --config /c.toml app update commit --json",
            "-m palaver --config /c.toml app uninstall-start --models --wait-for 9 --json"])
    }

    @Test func aCheckWithNoPlanOrFromACheckoutIsUpToDate() throws {
        let (python, _) = fakePython("echo '{\"plan\": null, \"unsupported\": true}'")
        let b = PythonUpdateBackend(python: python, cliOptions: [], env: [:], runScript: { _ in })
        #expect(try b.check() == .upToDate)
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
