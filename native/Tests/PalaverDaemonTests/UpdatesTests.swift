// tests/test_updater.py's state-machine tests (the Updater class and menubar.update_busy), against the Swift
// `Updates` with the Python commands faked. The disk half of test_updater.py (staging, unpacking, swap.sh,
// runtimes) stays Python: tests/test_updater.py and tests/test_app_update.py.
import Foundation
import Testing
import PalaverCore
@testable import PalaverDaemon

final class TClock: @unchecked Sendable {
    var t = 1000.0
}

final class FakeUpdateBackend: UpdateBackend, @unchecked Sendable {
    var installed: UpdateInstalled? = UpdateInstalled(version: "0.1.0", runtime: "rt-1")
    var previous: JSONValue?
    var latest: Result<UpdateCheck, Error> = .success(.plan(UpdatePlan(version: "0.2.0", downloadBytes: 5)))
    var downloadError: Error?
    var prepareError: Error?
    var onPrepare: () -> Void = {}
    var checks = 0, downloads: [String] = [], prepared: [[Int32]] = [], commits = 0, swaps: [String] = []
    var uninstalls: [(Bool, Bool, [Int32])] = []

    var statusFailures = 0, statusCalls = 0
    func status() throws -> (installed: UpdateInstalled?, previous: JSONValue?) {
        statusCalls += 1
        if statusFailures > 0 { statusFailures -= 1; throw Boom(description: "palaver-python did not answer") }
        return (installed, previous)
    }
    func check() throws -> UpdateCheck { checks += 1; return try latest.get() }
    func download(version: String, progress: @escaping @Sendable (Int) -> Void) throws {
        downloads.append(version)
        progress(5)
        if let downloadError { throw downloadError }
    }
    func prepare(waitFor: [Int32]) throws -> String {
        prepared.append(waitFor)
        onPrepare()
        if let prepareError { throw prepareError }
        return "/updates/swap.sh"
    }
    func commit() throws { commits += 1 }
    func spawnSwap(script: String) throws { swaps.append(script) }
    func uninstallStart(models: Bool, recordings: Bool, waitFor: [Int32]) throws -> [String] {
        uninstalls.append((models, recordings, waitFor))
        return ["/a"]
    }
}

struct Boom: Error, CustomStringConvertible { var description: String }

final class Saved: @unchecked Sendable {
    var all: [JSONValue] = []
    var last: JSONValue { all.last! }
}

struct Rig {
    let u: Updates
    let backend: FakeUpdateBackend
    let clock = TClock()
    let saved = Saved()
    let reason = Box<String?>(nil)
    let enabled = Box(true)
    let startedOk: URL

    init(installed: UpdateInstalled? = UpdateInstalled(version: "0.1.0", runtime: "rt-1"), previous: JSONValue? = nil,
         latest: Result<UpdateCheck, Error> = .success(.plan(UpdatePlan(version: "0.2.0", notes: "Faster notes.", downloadBytes: 5)))) {
        let backend = FakeUpdateBackend()
        backend.installed = installed
        backend.previous = previous
        backend.latest = latest
        self.backend = backend
        startedOk = tempDir().appendingPathComponent("started-ok")
        let clock = self.clock, saved = self.saved, reason = self.reason, enabled = self.enabled
        u = Updates(.init(backend: backend, busy: { reason.value }, enabled: { enabled.value }, now: { clock.t },
                          save: { saved.all.append($0) }, background: { $0() }, appPids: { [4242] }, startedOk: startedOk))
        u.load()
    }

    func clickInstall() { u.install() }
    var state: String { u.status()["state"]?.stringValue ?? "" }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}

@Suite struct UpdatesTests {
    @Test func aNewerReleaseIsAvailableWithoutDownloadingAnything() {
        let r = Rig()
        #expect(r.u.due())
        let s = r.u.runCheck()
        #expect(s["state"] == .string("available"))
        #expect(s["available"] == .object([("version", .string("0.2.0")), ("notes", .string("Faster notes.")),
                                          ("download_bytes", .int(5)), ("runtime", .bool(false)), ("models", .array([]))]))
        #expect(r.backend.downloads.isEmpty)
        #expect(MenuText.updateTitle(s) == "Update available (0.2.0)")
        #expect(r.saved.last["state"] == .string("available"))  // update.json, for the window
    }

    @Test func theSameReleaseIsUpToDate() {
        let r = Rig(latest: .success(.upToDate))
        let s = r.u.runCheck()
        #expect(s["state"] == .string("up_to_date"))
        #expect(MenuText.updateTitle(s) == "Check for Updates… (Palaver 0.1.0)")
        let said = MenuText.checkResult(s)
        #expect(said?.title == "Palaver is up to date" && said?.body == "Palaver 0.1.0 is the latest version.")
    }

    @Test func statusKeepsUpdateJsonsKeysInOrder() {
        let r = Rig()
        guard case .object(let fields) = r.u.status() else { Issue.record("not an object"); return }
        #expect(fields.map(\.0) == ["state", "current", "available", "done_bytes", "waiting_for", "error",
                                    "check_error", "checked_at", "automatic", "announced"])
    }

    @Test func aNewReleaseIsAnnouncedOnce() {
        let r = Rig()
        #expect(r.u.announce() == nil)  // nothing known yet
        r.u.runCheck()
        #expect(r.u.announce() == "0.2.0")
        #expect(r.saved.last["announced"] == .string("0.2.0"))  // kept in update.json: not again after a restart
        r.u.runCheck()
        #expect(r.u.announce() == nil)
        let a = MenuText.announcement("0.2.0")
        #expect(a.title == "Palaver 0.2.0 is available" && a.body == "Click to see what's new and install it.")
    }

    @Test func anAnnouncedReleaseStaysAnnouncedAfterARestartAndANewerOneIsNew() {
        let r = Rig(previous: .object([("state", .string("available")), ("announced", .string("0.2.0"))]))
        r.u.runCheck()
        #expect(r.u.announce() == nil)
        r.backend.latest = .success(.plan(UpdatePlan(version: "0.3.0", downloadBytes: 5)))
        r.u.runCheck()
        #expect(r.u.announce() == "0.3.0")
    }

    @Test func nothingIsAnnouncedWhenUpToDateOrFromACheckout() {
        let r = Rig(latest: .success(.upToDate))
        r.u.runCheck()
        #expect(r.u.announce() == nil)
        #expect(Rig(installed: nil).u.announce() == nil)
    }

    @Test func theNotificationIsTheAnnouncementOnceAndAClickOpensSettingsUpdate() {
        let r = Rig()
        r.u.runCheck()
        let n = r.u.pendingNotification()
        #expect(n?.title == "Palaver 0.2.0 is available" && n?.meeting == "settings/update")
        #expect(r.u.pendingNotification() == nil)
    }

    @Test func aCheckTheUserAskedForSaysWhatItFoundInsteadOfTheAnnouncement() {
        let r = Rig()
        r.u.menuClicked()  // nothing known: it checks, and says what it found
        let n = r.u.pendingNotification()
        #expect(n?.title == "Palaver 0.2.0 is available" && n?.body == "Choose “Update available” in Palaver's menu to install it.")
        #expect(n?.meeting == nil)
        #expect(r.u.pendingNotification() == nil)  // announced in that same go
    }

    @Test func aClickOnTheItemWithAReleaseKnownInstallsIt() {
        let r = Rig()
        r.u.runCheck()
        r.u.menuClicked()
        #expect(r.backend.downloads == ["0.2.0"])
        #expect(r.state == "ready")
    }

    @Test func itChecksAtStartAndThenEveryHour() {
        let r = Rig()
        #expect(r.u.due())
        r.u.runCheck()
        r.clock.t += 3599
        #expect(!r.u.due())
        r.clock.t += 1
        #expect(r.u.due())
    }

    @Test func nothingIsDueBeforeTheInstalledReleaseIsKnown() {
        let backend = FakeUpdateBackend()
        let u = Updates(.init(backend: backend, startedOk: tempDir().appendingPathComponent("ok")))
        #expect(!u.due())
    }

    @Test func openingTheWindowChecksUnlessACheckWasJustMade() {
        let r = Rig()
        r.u.runCheck()
        r.clock.t += Updates.windowCheckAfter - 1
        r.u.windowOpened()
        #expect(r.backend.checks == 1)
        r.clock.t += 1
        #expect(r.u.due(every: Updates.windowCheckAfter) && !r.u.due())  // the hourly one is not due yet
        r.u.windowOpened()
        #expect(r.backend.checks == 2)
    }

    @Test func automaticChecksCanBeTurnedOff() {
        let r = Rig()
        r.enabled.value = false
        #expect(!r.u.due())
        #expect(r.u.runCheck()["state"] == .string("available"))  // "Check now" still works
    }

    @Test func aFailedCheckChangesNothingAndIsTriedAgainInAnHour() {
        let r = Rig(latest: .failure(Boom(description: "offline")))
        let s = r.u.runCheck()
        #expect(s["state"] == .string("idle") && s["check_error"] == .string("offline"))
        r.clock.t += 1800
        #expect(!r.u.due())
        r.clock.t += 1800
        #expect(r.u.due())
        #expect(MenuText.checkResult(s)?.title == "Could not check for updates")
    }

    @Test func aClickDownloadsAndInstallsAtOnceWhenIdle() {
        let r = Rig()
        r.u.runCheck()
        #expect(r.u.request())
        #expect(r.state == "downloading")
        #expect(r.u.runDownload()["state"] == .string("ready"))
        #expect(r.u.tick() == true)  // applied: the app quits for the swap
        #expect(r.backend.swaps == ["/updates/swap.sh"] && r.backend.commits == 1)
        #expect(r.backend.prepared == [[4242]])  // the swap waits for this app to quit
        #expect(r.state == "installing")
    }

    @Test func anUpdateNeverInstallsWhileRecordingOrProcessing() {
        let r = Rig()
        r.reason.value = "recording"
        r.u.runCheck(); r.u.request(); r.u.runDownload()
        #expect(r.u.tick() == false && r.u.tick() == false)
        #expect(r.backend.swaps.isEmpty && r.backend.prepared.isEmpty)
        let s = r.u.status()
        #expect(s["state"] == .string("ready") && s["waiting_for"] == .string("recording"))
        #expect(MenuText.updateTitle(s) == "Update 0.2.0 installs when Palaver is idle (recording)")
        r.reason.value = "transcribing"
        #expect(r.u.tick() == false)
        r.reason.value = nil  // the next idle moment
        #expect(r.u.tick() == true && r.backend.swaps.count == 1)
    }

    @Test func aCallStartingAtTheLastMomentWinsOverTheUpdate() {
        let r = Rig()
        r.backend.onPrepare = { r.reason.value = "a call" }  // began while the script was written
        r.u.runCheck(); r.u.request(); r.u.runDownload()
        #expect(r.u.tick() == false)  // nothing quits
        let s = r.u.status()
        #expect(s["state"] == .string("ready") && s["waiting_for"] == .string("a call") && s["error"] == .null)
        #expect(r.backend.swaps.isEmpty && r.backend.commits == 0)  // no swap started, nothing remembered
        r.reason.value = nil
        r.backend.onPrepare = {}
        #expect(r.u.tick() == true && r.backend.swaps.count == 1)
    }

    @Test func aFailedDownloadKeepsTheRunningVersionAndSaysWhy() {
        let r = Rig()
        r.backend.downloadError = Boom(description: "palaver-app-0.2.0.zip arrived damaged (checksum mismatch)")
        r.u.runCheck(); r.u.request()
        let s = r.u.runDownload()
        #expect(s["state"] == .string("failed"))
        #expect(s["error"] == .string("Download failed: palaver-app-0.2.0.zip arrived damaged (checksum mismatch). Palaver 0.1.0 stays."))
        #expect(r.u.tick() == false && r.backend.prepared.isEmpty)
        #expect(MenuText.updateTitle(s) == "Update 0.2.0 failed — try again")
        r.u.runCheck()  // a later check keeps saying it failed
        #expect(r.state == "failed")
        #expect(r.u.request() && r.u.status()["error"] == .null)  // trying again
    }

    @Test func aFailedSwapKeepsTheRunningVersion() {
        let r = Rig()
        r.backend.prepareError = Boom(description: "disk full")
        r.u.runCheck(); r.u.request(); r.u.runDownload()
        #expect(r.u.tick() == false)
        #expect(r.state == "failed" && r.u.status()["error"]?.stringValue?.contains("disk full") == true)
        #expect(r.backend.swaps.isEmpty)
    }

    @Test func aCheckoutHasNothingToUpdate() {
        let r = Rig(installed: nil)
        #expect(r.state == "unsupported")
        #expect(!r.u.due())
        r.u.check()
        #expect(r.backend.checks == 0)
        #expect(MenuText.updateTitle(r.u.status()) == nil)
    }

    @Test func nothingHappensWithoutTheUsersClick() {
        let r = Rig()
        r.u.runCheck()
        for _ in 0..<3 { #expect(r.u.tick() == false) }
        #expect(r.backend.downloads.isEmpty && r.backend.prepared.isEmpty)
    }

    @Test func aFailedSwapIsStillSaidAfterTheAppReopened() {
        let message = "Palaver 0.2.0 did not start; 0.1.0 is back."
        let r = Rig(previous: .object([("state", .string("failed")), ("from_swap", .bool(true)), ("error", .string(message)),
                                       ("available", .object([("version", .string("0.2.0"))]))]))
        #expect(r.state == "failed" && r.u.status()["error"] == .string(message))
        #expect(r.u.runCheck()["state"] == .string("failed"))  // the same release: the error stays until the user tries again
        #expect(r.u.status()["error"] == .string(message))
        #expect(r.u.request() && r.u.status()["error"] == .null)
    }

    @Test func anUpdateThatDidNotFailLeavesNoErrorAfterTheRestart() {
        let r = Rig(previous: .object([("state", .string("installing")), ("available", .object([("version", .string("0.2.0"))]))]))
        #expect(r.state == "idle" && r.u.status()["error"] == .null)
    }

    @Test func updateJsonSaysWhatThisVersionIsRightAfterStart() {
        let r = Rig()
        #expect(r.saved.last["current"] == .string("0.1.0") && r.saved.last["state"] == .string("idle"))
    }

    // MARK: started-ok, uninstall, the main tick

    @Test func startedOkIsTheVersionOnceTheFirstTickRan() throws {
        let r = Rig()
        #expect(!exists(r.startedOk))
        r.u.started()
        #expect(try String(contentsOf: r.startedOk, encoding: .utf8) == "0.1.0")
    }

    @Test func aCheckoutWritesNoStartedOk() {
        let r = Rig(installed: nil)
        r.u.started()
        r.u.started()
        #expect(!exists(r.startedOk))
    }

    @Test func startedBeforeTheInstalledVersionIsKnownIsWrittenOnALaterTick() throws {
        let backend = FakeUpdateBackend()
        let ok = tempDir().appendingPathComponent("started-ok")
        let u = Updates(.init(backend: backend, startedOk: ok))
        u.started()  // the first tick came before load() finished
        #expect(!exists(ok) && !u.startedWritten)
        u.load()
        u.started()
        #expect(try String(contentsOf: ok, encoding: .utf8) == "0.1.0" && u.startedWritten)
    }

    @Test func aFailingWriteIsRetriedOnTheNextTick() throws {
        let backend = FakeUpdateBackend()
        let dir = tempDir()
        let blocker = dir.appendingPathComponent("sub")
        touch(blocker, "a file where the folder should be")  // createDirectory fails
        let ok = blocker.appendingPathComponent("started-ok")
        let u = Updates(.init(backend: backend, startedOk: ok))
        u.load()
        u.started()
        #expect(!exists(ok) && !u.startedWritten)
        try FileManager.default.removeItem(at: blocker)
        u.started()
        #expect(try String(contentsOf: ok, encoding: .utf8) == "0.1.0" && u.startedWritten)
    }

    @Test func startedOkIsTheBundlesVersionWhenPythonNeverAnswers() throws {
        // 0.3.14's swap.sh restores the version before when started-ok does not come: it must not
        // hang on `palaver app update status` answering.
        let backend = FakeUpdateBackend()
        backend.statusFailures = 1000
        let ok = tempDir().appendingPathComponent("started-ok")
        let u = Updates(.init(backend: backend, startedOk: ok, bundleVersion: "0.5.0"))
        u.load()
        #expect(!u.startedDone)
        u.started()
        #expect(try String(contentsOf: ok, encoding: .utf8) == "0.5.0" && u.startedDone)
        #expect(!u.due())  // nothing else happens until Python answers
    }

    @Test func aDevelopmentBuildStillWritesNoStartedOk() {
        let r = Rig(installed: nil)
        r.u.started()
        #expect(!exists(r.startedOk) && r.u.startedDone)
    }

    @Test func loadIsAskedAgainWithBackoffUntilPythonAnswers() {
        let backend = FakeUpdateBackend()
        backend.statusFailures = 3
        let u = Updates(.init(backend: backend, startedOk: tempDir().appendingPathComponent("ok")))
        var slept: [Double] = []
        u.loadUntilAnswered(sleep: { slept.append($0) })
        #expect(slept == [2, 4, 8] && backend.statusCalls == 4)
        #expect(u.status()["state"] == .string("idle") && u.due())
    }

    @Test func theBackoffStopsGrowingAtItsCap() {
        let backend = FakeUpdateBackend()
        backend.statusFailures = 9
        let u = Updates(.init(backend: backend, startedOk: tempDir().appendingPathComponent("ok")))
        var slept: [Double] = []
        u.loadUntilAnswered(sleep: { slept.append($0) }, maxDelay: 30)
        #expect(slept == [2, 4, 8, 16, 30, 30, 30, 30, 30])
        #expect(u.load())  // answered: true
    }

    @Test func uninstallStartsTheScriptAndTheNextTickQuits() throws {
        let r = Rig()
        #expect(r.u.mainTick() == false)
        let a = try r.u.uninstall(models: true, recordings: false)
        #expect(a["removing"] as? [String] == ["/a"])
        #expect(r.backend.uninstalls.count == 1 && r.backend.uninstalls[0].0 && !r.backend.uninstalls[0].1
                && r.backend.uninstalls[0].2 == [4242])
        #expect(r.u.mainTick() == true)
    }

    @Test func theMainTickStartsADueCheckAndSwapsWhenIdle() {
        let r = Rig()
        #expect(r.u.mainTick() == false)  // the check at start ran
        #expect(r.backend.checks == 1 && r.state == "available")
        r.u.install()
        #expect(r.u.mainTick() == true)
    }

    @Test func onlyOneBackgroundJobRunsAtATime() {
        final class Held: @unchecked Sendable { var work: [@Sendable () -> Void] = [] }
        let held = Held()
        let backend = FakeUpdateBackend()
        let u = Updates(.init(backend: backend, background: { held.work.append($0) }, startedOk: tempDir().appendingPathComponent("ok")))
        u.load()
        u.check(); u.check()
        #expect(held.work.count == 1)
        held.work.removeFirst()()
        u.check()
        #expect(held.work.count == 1)
    }
}

@Suite struct UpdateBusyTests {
    private func daemon(_ fields: [(String, JSONValue)]) -> JSONValue { .object(fields) }

    @Test func theDaemonSaysWhatKeepsItBusy() {
        func reason(_ f: [(String, JSONValue)]) -> String? { UpdateBusy.reason(daemon: daemon(f), jobs: [], testState: nil, downloading: false) }
        #expect(reason([("state", .string("recording"))]) == "recording")
        #expect(reason([("state", .string("idle")), ("transcribing", .bool(true))]) == "transcribing")
        #expect(reason([("state", .string("idle")), ("queued", .array([.string("/m/a")]))]) == "transcribing")
        #expect(reason([("state", .string("idle")), ("writing_notes", .string("/m/a"))]) == "writing notes")
        #expect(reason([("state", .string("idle")), ("notes_queued", .array([.string("/m/a")]))]) == "writing notes")
        #expect(reason([("state", .string("idle")), ("indexing", .bool(true))]) == nil)  // stopped when Palaver quits
        #expect(reason([("state", .string("idle")), ("teams_active", .bool(true))]) == "a call")  // about to record
        #expect(reason([("state", .string("paused"))]) == nil)
    }

    @Test func modelJobsATestRecordingAndModelDownloadsKeepItBusyToo() {
        let idle = daemon([("state", .string("idle"))])
        #expect(UpdateBusy.reason(daemon: idle, jobs: ["notes"], testState: nil, downloading: false) == "writing notes")
        #expect(UpdateBusy.reason(daemon: idle, jobs: ["projects"], testState: nil, downloading: false) == "sorting projects")
        #expect(UpdateBusy.reason(daemon: idle, jobs: [], testState: "recording", downloading: false) == "a test recording")
        for done in ["idle", "done", "failed", nil] {
            #expect(UpdateBusy.reason(daemon: idle, jobs: [], testState: done, downloading: false) == nil)
        }
        #expect(UpdateBusy.reason(daemon: idle, jobs: [], testState: nil, downloading: true) == "downloading models")
        // the daemon's reason comes first
        #expect(UpdateBusy.reason(daemon: daemon([("state", .string("recording"))]), jobs: ["notes"], testState: nil, downloading: true) == "recording")
    }

    @Test func runningModelJobsAreThoseWithALivePid() {
        let root = tempDir()
        writeJSON(root.appendingPathComponent("notes-a.json"), ["kind": "notes", "key": "a", "state": "running", "pid": 11])
        writeJSON(root.appendingPathComponent("projects-b.json"), ["kind": "projects", "key": "b", "state": "running", "pid": 12])
        writeJSON(root.appendingPathComponent("notes-c.json"), ["kind": "notes", "key": "c", "state": "done", "pid": 11])
        writeJSON(root.appendingPathComponent("other-d.json"), ["state": "running", "pid": 11])
        touch(root.appendingPathComponent("notes-e.json"), "not json")
        #expect(UpdateBusy.runningJobKinds(root: root, alive: { $0 == 11 }) == ["notes"])  // 12 is stale: its pid is gone
        #expect(UpdateBusy.runningJobKinds(root: root.appendingPathComponent("missing")) == [])
    }

    @Test func theDownloadsMarkerCountsWithALivePid() {
        let marker = tempDir().appendingPathComponent("downloading-models")
        #expect(!UpdateBusy.downloadsRunning(marker: marker))
        touch(marker, "\(getpid())\n")
        #expect(UpdateBusy.downloadsRunning(marker: marker))
        touch(marker, "not a pid")
        #expect(!UpdateBusy.downloadsRunning(marker: marker))
        touch(marker, "99")
        #expect(!UpdateBusy.downloadsRunning(marker: marker, alive: { _ in false }))
    }
}
