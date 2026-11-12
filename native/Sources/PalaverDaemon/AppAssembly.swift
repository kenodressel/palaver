// The app's assembly without AppKit (menubar.py create_app, MeetingApp.tick, finalize): the daemon
// and its app.sock actions around one test recorder, the 1 s tick's order, and the quit's order.
// The Palaver target binds these to the menu bar, the window and the run loop; tests drive them
// with fakes.
import Foundation
import PalaverCapture
import PalaverCore

/// The daemon and the actions app.sock calls on it. One TestRecorder serves both: a meeting starting
/// (the daemon's `beforeRecord`) stops the very test the setup assistant started over app.sock.
public struct AppCore {
    public let daemon: Daemon
    public let actions: DaemonActions
    public let testRecorder: TestRecorder

    public static func build(config: Config, settings: Settings, paths: Paths, launcher: WorkerLauncher,
                             facts: PythonFacts, notion: AutoSyncAnswer, detector: CallDetector,
                             version: String, notify: @escaping (String, String, String?) -> Void,
                             log: @escaping (String, String) -> Void,
                             sources: ((Daemon?) -> CaptureSources)? = nil,
                             testRecorder: TestRecorder, helpers: HelperJobs?,
                             restartWeb: @escaping () -> Int32? = { nil },
                             refresh: @escaping () -> Void = {},
                             askAccessibility: (() -> Void)? = nil) throws -> AppCore {
        let daemon = try DaemonFactory.build(config: config, settings: settings, paths: paths, launcher: launcher,
                                             facts: facts, notion: notion,
                                             detector: detector, version: version, notify: notify, log: log,
                                             sources: sources, askAccessibility: askAccessibility, testRecorder: testRecorder)
        let actions = DaemonActions(
            daemon: daemon, refresh: refresh,
            launchHelper: { kind, key, args in
                guard let helpers else { throw CallRefused("no helper \(kind)") }
                return try helpers.launch(kind: kind, key: key, args: args)
            },
            restartWeb: restartWeb,
            testRecording: { action, mode, busy in try testRecorder.testRecording(action: action, mode: mode, busy: busy) })
        return AppCore(daemon: daemon, actions: actions, testRecorder: testRecorder)
    }
}

/// A part the app runs without when it cannot start (the window's server: no port to listen on). The
/// menu bar and recording do not depend on it; its failure is logged and the part is nil.
public enum AppPart {
    public static func optional<T>(_ name: String, log: (String) -> Void, _ make: () throws -> T) -> T? {
        do { return try make() } catch {
            log("\(name) did not start (\(error)); Palaver runs without its window")
            return nil
        }
    }
}

/// One second of the app (MeetingApp.tick), in Python's order: the daemon's tick; once it ran, the
/// started-ok mark (every tick until it is written); the menu; the calendar retry; housekeeping; the
/// updater, which may say the app must quit now (an update is swapped in, or the user uninstalled).
/// Before all of it: the bundle the app started from is still there (BundleWatch). A swap that put the
/// version before back (0.3.14's ends only its own launcher) or an app removed: quit, reason "restart".
public final class AppTicker {
    public struct Steps {
        public var daemonTick: () -> Void
        public var started: () -> Void
        public var startedDone: () -> Bool
        public var refresh: () -> Void
        public var calendarRetry: () -> Void
        public var housekeeping: () -> Void
        /// Updates.mainTick: true when the app must quit.
        public var updates: () -> Bool
        public var quit: () -> Void
        /// The bundle at the launch path is gone or another one: quit at once.
        public var bundleReplaced: () -> Bool

        public init(daemonTick: @escaping () -> Void, started: @escaping () -> Void, startedDone: @escaping () -> Bool,
                    refresh: @escaping () -> Void, calendarRetry: @escaping () -> Void, housekeeping: @escaping () -> Void,
                    updates: @escaping () -> Bool, quit: @escaping () -> Void, bundleReplaced: @escaping () -> Bool = { false }) {
            self.daemonTick = daemonTick; self.started = started; self.startedDone = startedDone; self.refresh = refresh
            self.calendarRetry = calendarRetry; self.housekeeping = housekeeping; self.updates = updates; self.quit = quit
            self.bundleReplaced = bundleReplaced
        }
    }

    private let steps: Steps
    public private(set) var stopped = false

    public init(_ steps: Steps) { self.steps = steps }

    public func tick() {
        guard !stopped else { return }
        if steps.bundleReplaced() {
            stopped = true
            steps.quit()
            return
        }
        steps.daemonTick()
        if !steps.startedDone() { steps.started() }
        steps.refresh()
        steps.calendarRetry()
        steps.housekeeping()
        if steps.updates() {
            stopped = true
            steps.quit()
        }
    }

    /// The quit stops the tick first (finalize).
    public func stop() { stopped = true }
}

/// Quitting (menubar.finalize, plus what the launcher did on its way out): the reason is "by_you"
/// from the menu's Quit or ⌘Q in the window, else "restart" (SIGTERM, logout, an update), which
/// keeps a call's recording as a cut for the next start. Runs once, in this order: the tick stops,
/// a test recording is dropped, the daemon shuts down (the WAVs are finished), the window's server
/// stops in the background, app.sock closes, the notify socket goes.
public final class AppQuit {
    public struct Steps {
        public var stopTick: () -> Void
        public var abortTest: () -> Void
        public var shutdown: (String) -> Void
        public var stopWeb: () -> Void
        public var closeSocket: () -> Void
        public var stopNotifications: () -> Void

        public init(stopTick: @escaping () -> Void, abortTest: @escaping () -> Void, shutdown: @escaping (String) -> Void,
                    stopWeb: @escaping () -> Void, closeSocket: @escaping () -> Void, stopNotifications: @escaping () -> Void) {
            self.stopTick = stopTick; self.abortTest = abortTest; self.shutdown = shutdown
            self.stopWeb = stopWeb; self.closeSocket = closeSocket; self.stopNotifications = stopNotifications
        }
    }

    public static let byYou = "by_you", restart = "restart"
    private let steps: Steps
    public private(set) var reason = AppQuit.restart
    public private(set) var finalized = false

    public init(_ steps: Steps) { self.steps = steps }

    /// The user's own quit: the recording is processed now.
    public func byUser() { reason = Self.byYou }

    /// Finishes everything once; false when it already ran.
    @discardableResult
    public func finalize() -> Bool {
        guard !finalized else { return false }
        finalized = true
        steps.stopTick()
        steps.abortTest()
        steps.shutdown(reason)
        steps.stopWeb()
        steps.closeSocket()
        steps.stopNotifications()
        return true
    }
}
