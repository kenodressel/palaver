// The app put together (menubar.py run_app / create_app, in inventory §1's order): the daemon.log
// logger, notifications, the daemon with the real capture, the shared test recorder, app.sock, the
// window's server, the window, the menu bar, the updater, housekeeping and the calendar, the
// permission prompts, the 1 s tick and the quit. Nothing here runs in tests: the parts are tested
// in PalaverCore and PalaverDaemon with fakes; this only binds them to AppKit and the run loop.
import AppKit
import Foundation
import PalaverCapture
import PalaverCore
import PalaverDaemon

/// daemon.log: JSON lines in session_log's format (the Python app's LOGGER wrote there too).
final class AppLog: @unchecked Sendable {
    let file: SessionLog

    init(paths: Paths) {
        try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        file = SessionLog(url: paths.daemonLog, logger: "palaver.app")
    }

    func line(_ level: String, _ message: String, logger: String = "palaver.app") {
        file.message(message, level: level, logger: logger)
    }

    func info(_ message: String) { line("INFO", message) }
    func warning(_ message: String) { line("WARNING", message) }
}

/// What main.swift found out before the app starts.
struct AppSetup {
    let paths: Paths
    let location: AppLocation
    let options: AppOptions
    let version: String
    let python: String
    let log: AppLog
    /// What every child gets on top of the app's environment (PALAVER_APP, PALAVER_NOTIFY, …).
    var childEnv: [String: String]
    var cliOptions: [String] {
        WorkerLauncher.forwardedOptions(config: options.config, dictionary: options.dictionary, noNotify: options.noNotify)
    }
}

@MainActor
final class PalaverApp: NSObject, NSApplicationDelegate {
    private let setup: AppSetup
    private let notifications: Notifications?
    private let config: Config
    private let settings: Settings
    private let core: AppCore
    private let extras: AppExtras
    private let appSocket: AppSocket
    /// The window's server; nil when it could not start (no window, the rest runs).
    private let web: WebSupervisor?
    private let window = MeetingsWindow()
    private var menu: MenuBar?
    private var ticker: AppTicker?
    private var quitter: AppQuit?
    private var timer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private let usage: UsageLog
    /// The bundle as it was at the start: another one there now (a swap put the version before back) quits.
    private let bundleWatch: BundleWatch?

    /// Builds everything in Python's order; throws DaemonRunning when another Palaver records.
    init(setup: AppSetup, notifications: Notifications?) throws {
        self.setup = setup
        self.notifications = notifications
        let log = setup.log
        let paths = setup.paths
        let cliOptions = setup.cliOptions
        let config = Config.load(setup.options.config.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
                                 ?? paths.configToml)
        let settings = Settings(url: paths.settingsJson, defaults: config)
        self.config = config
        self.settings = settings
        usage = UsageLog(url: paths.support.appendingPathComponent("usage.jsonl"))
        bundleWatch = BundleWatch(bundle: setup.location.bundle)

        let launcher = WorkerLauncher(python: setup.python, cliOptions: cliOptions, log: paths.daemonLog, env: setup.childEnv)
        let facts = PythonFacts(python: setup.python, cliOptions: cliOptions, env: setup.childEnv, log: { log.warning($0) })
        // Built at once with the last answer (or config.toml's view); Python is asked in the background.
        let notion = AutoSyncAnswer(cache: paths.support.appendingPathComponent("notion-auto-sync.json"),
                                    fallback: .init(autoSync: config.notionAutoSync, notes: config.notesEnabled))
        Self.askNotion(notion, setup: setup)
        let detector = CallDetector(lister: CoreAudioProcessLister(), teams: { settings.recordTeams },
                                    slack: { settings.recordSlack }, log: { log.line("INFO", $0, logger: "palaver.teams_detector") })

        // One test recorder for the daemon (a meeting starting stops it) and app.sock (the setup
        // assistant starts it). Its capture leaves out the daemon's own workers, as a meeting's does.
        let pids = PidsBox()
        let testRecorder = TestRecorder.live(
            sources: { CaptureSources.live(excludedPIDs: { pids.daemon?.excludedPIDs() ?? [getpid()] },
                                           log: { log.line("INFO", $0, logger: "palaver.onboarding") }) },
            python: setup.python, cliOptions: cliOptions, env: setup.childEnv)
        let helpers = HelperJobs(outputDir: { config.outputDir }, python: setup.python, cliOptions: cliOptions, env: setup.childEnv)

        let later = Later()  // the menu and the window's server exist only after the daemon
        core = try AppCore.build(
            config: config, settings: settings, paths: paths, launcher: launcher, facts: facts,
            notion: notion, detector: detector, version: setup.version,
            notify: { title, message, meeting in later.notify?(title, message, meeting) },
            log: { level, message in log.line(level, message, logger: "palaver.daemon") },
            testRecorder: testRecorder, helpers: helpers,
            restartWeb: { later.web?.restart() },
            refresh: { later.refresh?() })
        pids.daemon = core.daemon
        let daemon = core.daemon

        extras = AppExtras(paths: paths, config: { config }, settings: { settings }, python: setup.python,
                           cliOptions: cliOptions, env: setup.childEnv, launcher: launcher,
                           daemonStatus: { daemon.status() },  // asked on the main tick, as in Python
                           testState: { testRecorder.status()["state"] as? String },
                           transcribing: { daemon.status()["transcribing"]?.truthy ?? false },
                           bundleVersion: setup.location.releaseVersion(),
                           log: { log.line("INFO", $0, logger: "palaver.updater") })

        let main = MainRunner()
        appSocket = AppSocket(path: paths.appSock.path,
                              handlers: AppCalls.make(actions: core.actions, main: main, extra: extras.calls(main: main)),
                              log: { log.warning($0) })
        let window = self.window
        web = AppPart.optional("the window's server", log: { log.warning($0) }) {
            try startWebServer(window: window, python: setup.python, cliOptions: cliOptions, appSocket: paths.appSock,
                               env: WebSupervisor.childEnv(ProcessInfo.processInfo.environment.merging(setup.childEnv) { $1 }),
                               log: { log.line("INFO", $0, logger: "palaver.webapp") })
        }
        super.init()
        later.web = web
        later.notify = { [weak self] title, message, meeting in
            // At once on the main thread (the daemon's tick, its shutdown at quit), else handed to it.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.notify(title, message, meeting) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.notify(title, message, meeting) } }
            }
        }
        later.refresh = { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        if !appSocket.start() { log.warning("app.sock could not be bound at \(paths.appSock.path)") }
    }

    /// `notion-auto-sync` from Python (the token may be in the Keychain, which only Python reads), on a
    /// thread of its own until it answers; the daemon reads `notion` as each worker starts.
    private static func askNotion(_ notion: AutoSyncAnswer, setup: AppSetup) {
        let python = setup.python, options = setup.cliOptions, env = setup.childEnv, log = setup.log
        Thread.detachNewThread {
            notion.askUntilAnswered(ask: { PythonFacts.notionAutoSyncNow(python: python, cliOptions: options, env: env) },
                                    log: { log.warning($0) })
        }
    }

    // MARK: running

    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = self
        window.quit = { [weak self] in self?.quit(byUser: true) }  // ⌘Q in the window: as the menu's Quit
        menu = MenuBar(actions: menuActions())
        let extras = self.extras, core = self.core, web = self.web, appSocket = self.appSocket, notifications = self.notifications
        let watch = bundleWatch, log = setup.log
        ticker = AppTicker(.init(
            daemonTick: { core.daemon.tick() },
            started: { extras.updates.started() },
            startedDone: { extras.updates.startedDone },
            refresh: { [weak self] in self?.refresh() },
            calendarRetry: { extras.calendarAttach.retryTick() },
            housekeeping: { extras.housekeeping.tick() },
            updates: { extras.updates.mainTick() },
            quit: { [weak self] in self?.quit(byUser: false) },
            bundleReplaced: {
                guard let watch, watch.replaced() else { return false }
                log.warning("\(watch.path) is no longer the app this process started from (an update put another one there): quitting")
                return true
            }))
        quitter = AppQuit(.init(
            stopTick: { [weak self] in self?.timer?.invalidate(); self?.ticker?.stop() },
            abortTest: { core.testRecorder.abort() },
            shutdown: { reason in core.daemon.shutdown(reason) },
            stopWeb: { _ = web?.stopInBackground() },
            closeSocket: { appSocket.stop() },
            stopNotifications: { notifications?.stop() }))

        // Asks Python until it answers (the updater is off until then); started-ok does not wait for it.
        Thread.detachNewThread { extras.updates.loadUntilAnswered() }
        extras.housekeeping.atStart()
        extras.calendarAttach.check()  // connecting looks everything up first
        // Off the main thread: the system-audio probe blocks until its prompt is answered, and the
        // menu bar icon should be up while the user decides.
        let requester = extras.permissions, marker = setup.paths.permissionsMarker
        Thread.detachNewThread { Permissions.requestAtLaunch(requester, marker: marker, log: { log.warning($0) }) }

        for sig in [SIGTERM, SIGINT] {  // from outside (an update, a restart, a terminal): "restart"
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.quit(byUser: false) } }
            source.resume()
            signalSources.append(source)
        }
        // Each second, also while the menu is open (common modes).
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.ticker?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
        app.run()
    }

    // MARK: quitting

    /// The menu's Quit and ⌘Q: "by_you" (processed now); a signal or an update: "restart".
    func quit(byUser: Bool) {
        if byUser { quitter?.byUser() }
        NSApp.terminate(nil)  // applicationShouldTerminate finalizes
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Logout and restart reach this too: "restart" unless the user chose Quit.
        if let quitter, quitter.finalize() {
            setup.log.info("Palaver quits (\(quitter.reason))")
        }
        return .terminateNow
    }

    // MARK: the menu

    private func menuActions() -> MenuActions {
        let daemon = core.daemon
        var a = MenuActions()
        a.openMeetings = { [weak self] in self?.openWindow(nil) }
        a.openSettings = { [weak self] in self?.openWindow("settings") }
        a.startManual = { [weak self] in _ = daemon.startManual(); self?.refresh() }
        a.stopManual = { [weak self] in daemon.stopManual(); self?.refresh() }
        a.keepRecording = { [weak self] in _ = daemon.answerStopQuestion("keep"); self?.refresh() }
        a.updateClicked = { [weak self] in self?.extras.updates.menuClicked(); self?.refresh() }
        a.reportProblem = { [weak self] in
            self?.usage.record("action", [("id", "menubar.reportProblem")])
            self?.openWindow("report", lookForUpdate: false)
        }
        a.quit = { [weak self] in self?.quit(byUser: true) }
        a.isRecording = { daemon.state.state == "recording" }
        return a
    }

    /// The window at the meeting's (or settings') page; opening it looks for a new release.
    func openWindow(_ route: String?, lookForUpdate: Bool = true) {
        if lookForUpdate { extras.updates.windowOpened() }
        guard let web else {
            setup.log.warning("the window was asked for, but its server did not start")
            notify("Palaver's window is not available", "Its server did not start; recording works. Restart Palaver to try again.", nil)
            return
        }
        window.open(url: web.url(route), key: web.key)
    }

    private func refresh() {
        if !extras.calendarAttach.isConnected { extras.calendarAttach.check() }  // consent given in the window
        let switches = ["record_teams": settings.recordTeams, "record_slack": settings.recordSlack]
        let status = MenuText.withRecordSwitches(core.daemon.status(), switches)
        let progress = status["transcribing_folder"]?.stringValue.map {
            MenuText.processingProgress(URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("session.log"))
        }
        let levels = (core.daemon.levels?.readings ?? []).map { (label: $0.label, db: $0.db, silentFor: $0.silentFor) }
        menu?.refresh(MenuSnapshot(status: status, levels: levels, now: Date(), progress: progress,
                                   update: extras.updates.status()))
        if let said = extras.updates.pendingNotification() { notify(said.title, said.body, said.meeting) }
    }

    // MARK: notifications

    /// notify.notify: posted as the app (its click opens `meeting`), osascript when there is no
    /// notification center (a development run); nothing with --no-notify.
    func notify(_ title: String, _ message: String, _ meeting: String?) {
        if setup.options.noNotify { return }
        guard let notifications else { return osascriptNotify(title: title, body: message) }
        let obj: [String: Any] = ["title": title, "message": message, "open": meeting ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: obj) { notifications.handleDatagram(data) }
    }
}

/// The daemon, once built, for the test recorder's capture.
private final class PidsBox: @unchecked Sendable {
    weak var daemon: Daemon?
}

/// What the daemon's callbacks reach once the app is complete.
private final class Later: @unchecked Sendable {
    var web: WebSupervisor?
    var notify: ((String, String, String?) -> Void)?
    var refresh: (() -> Void)?
}
