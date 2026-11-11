// Palaver, the native app: the bundle's executable (Contents/MacOS/Palaver), or a development build
// (native/.build/…/Palaver). The window's server, the pipeline's workers and the language model are
// palaver-server, palaver-worker and palaver-lm.
import AppKit
import Foundation
import PalaverCore
import PalaverDaemon

// Read-only dev check: one line with the call apps' audio state. No audio, no permission prompt,
// nothing logged. `Palaver --call-state`
if CommandLine.arguments.dropFirst().first == "--call-state" {
    do {
        let procs = try CoreAudioProcessLister().processes().filter {
            let id = $0.bundleId.lowercased()
            return ($0.runningInput || $0.runningOutput) && (teamsBundlePrefixes + slackBundlePrefixes).contains { id.hasPrefix($0) }
        }
        let detected = CallDetector(lister: CoreAudioProcessLister())()
        let audio = procs.map { p in
            "\(p.bundleId)[" + [(p.runningInput, "mic"), (p.runningOutput, "speaker")].filter { $0.0 }.map { $0.1 }.joined(separator: "+") + "]"
        }
        print("call=\(detected?.rawValue ?? "none") apps=\(audio.isEmpty ? "none" : audio.joined(separator: ","))")
    } catch {
        print("call-state failed: \(error)")
        exit(1)
    }
    exit(0)
}

// Hardware dev check, only by hand: a real recording through the real sources (see CaptureCheck.swift).
if CommandLine.arguments.dropFirst().first == "--capture-check" {
    exit(runCaptureCheck(Array(CommandLine.arguments.dropFirst(2))))
}

let environment = ProcessInfo.processInfo.environment
let paths = Paths()
let location = AppLocation(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
let options = AppOptions.parse(Array(CommandLine.arguments.dropFirst()))
let version = location.version()
CrashLog.install(path: paths.crashesLog, version: version)

// The app's own output (and the window's server's, which inherits it) goes to app.log, as the
// launcher arranged; a development run keeps its terminal.
if location.bundle != nil {
    try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
    let fd = open(paths.appLog.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    if fd >= 0 {
        dup2(fd, 1)
        dup2(fd, 2)
        if fd > 2 { close(fd) }
    }
    setvbuf(stdout, nil, _IOLBF, 0)
}

let log = AppLog(paths: paths)
let bundled = location.bundle != nil && Bundle.main.bundleIdentifier != nil
var childEnv: [String: String] = [:]
if let bundle = location.bundle { childEnv["PALAVER_APP"] = bundle.path }
for (k, v) in childEnv { setenv(k, v, 1) }

/// A notification before the app runs (a second start): as the app when bundled, else osascript.
func notifyOnce(_ title: String, _ message: String) {
    if options.noNotify { return }
    guard bundled else { return osascriptNotify(title: title, body: message) }
    let done = DispatchSemaphore(value: 0)
    SystemCenter().post(title: title, body: message, userInfo: [:]) { error in
        if error != nil { osascriptNotify(title: title, body: message) }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 3)
}

/// The notify socket and its state file, only as the app (outside a bundle there is no notification
/// center). PALAVER_NOTIFY and PALAVER_NOTIFY_STATE go to the children only when it is bound. What an
/// earlier run left in $TMPDIR goes first.
@MainActor
func startNotifications(opener: @escaping @Sendable (String?) -> Void) -> Notifications? {
    guard bundled else { return nil }
    let removed = TempSweep.sweep(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
    if !removed.isEmpty { log.info("removed what an earlier run left in the temp folder: \(removed.joined(separator: ", "))") }
    let center = SystemCenter()
    let n = Notifications(center: center, directory: NSTemporaryDirectory(), opener: opener,
                          fallback: { osascriptNotify(title: $0, body: $1) },
                          log: { message in print(message) })  // into app.log, as the launcher's line
    center.onClick = { [n] info in n.didClick(userInfo: info) }
    center.install()
    guard n.start() else {
        log.warning("the notify socket could not be bound; notifications go through osascript")
        return nil
    }
    childEnv["PALAVER_NOTIFY"] = n.socketPath
    childEnv["PALAVER_NOTIFY_STATE"] = n.statePath
    for (k, v) in childEnv { setenv(k, v, 1) }  // anything else the app starts gets them too
    return n
}

// --- the app -----------------------------------------------------------------------------------------
log.file.event("app_start", logger: "palaver", [("version", version), ("pid", Int(getpid())),
                                                ("argv", Array(CommandLine.arguments.dropFirst())), ("app", "native")])

// A second Palaver must not touch the first one's recording: refused before anything is bound. The
// lock is held until the process ends; daemon.json's pid also catches a Python app (a version before)
// that takes no lock.
func refuseSecondStart(_ message: String) -> Never {
    print("error: \(message)")
    log.warning(message)
    notifyOnce("Palaver is already running", message)
    exit(1)
}
let instanceLock = InstanceLock(paths.appLock)
if instanceLock == nil {
    refuseSecondStart("Palaver is already running (\(paths.appLock.path) is held); quit it before starting another one.")
}
if let other = RunningApp.other(stateFile: paths.daemonJson, alive: { Processes.palaverAlive($0) }) {
    refuseSecondStart("Palaver is already running (pid \(other)); quit it before starting another one.")
}

MainActor.assumeIsolated {
    final class AppBox: @unchecked Sendable { var app: PalaverApp? }
    let box = AppBox()
    // A click on one of the app's notifications opens its meeting in the window.
    let notifications = startNotifications(opener: { meeting in
        DispatchQueue.main.async { MainActor.assumeIsolated { box.app?.openWindow(meeting, lookForUpdate: false) } }
    })
    // palaver-server, palaver-worker and palaver-lm; one not built is said once in app.log.
    let programs = AppPrograms.find(location: location, environment: environment)
    for line in programs.said { print(line) }
    let setup = AppSetup(paths: paths, location: location, options: options, version: version,
                         server: programs.server, worker: programs.worker, lm: programs.lm, log: log, childEnv: childEnv)
    do {
        let app = try PalaverApp(setup: setup, notifications: notifications)
        box.app = app
        app.run()
    } catch {
        let message = "\(error)"
        print("error: \(message)")
        log.warning("Palaver did not start: \(message)")
        notifications?.stop()
        if error is DaemonRunning { notifyOnce("Palaver is already running", message) }
        exit(1)
    }
}
