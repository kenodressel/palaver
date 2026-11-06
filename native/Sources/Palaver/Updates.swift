// The app's wiring of `Updates`, `Housekeeping`, `CalendarAttach` and the app.sock extras (Task 14 calls
// this from main.swift). Nothing here runs by itself.
import AppKit
import Foundation
import PalaverCore
import PalaverDaemon

/// What the app needs of the update machinery, built from the app's own pieces.
struct AppExtras {
    let updates: Updates
    let housekeeping: Housekeeping
    let calendarAttach: CalendarAttach
    let calendarOnboarding: CalendarOnboarding
    let permissions: PermissionRequester

    /// `daemonStatus`: Daemon.status() as JSON; `testState`: the setup assistant's test recording state;
    /// `transcribing`: whether a recording is processed now (the calendar retry waits). The Python
    /// commands run with `python` (palaver-python) and the app's `cliOptions`/`env`.
    init(paths: Paths, config: @escaping @Sendable () -> Config, settings: @escaping @Sendable () -> Settings,
         python: String, cliOptions: [String], env: [String: String], launcher: WorkerLauncher,
         daemonStatus: @escaping @Sendable () -> JSONValue, testState: @escaping @Sendable () -> String?,
         transcribing: @escaping @Sendable () -> Bool, bundleVersion: String?, log: @escaping @Sendable (String) -> Void) {
        let backend = PythonUpdateBackend(python: python, cliOptions: cliOptions, env: env, log: log)
        let jobsRoot = { config().outputDir.appendingPathComponent(".jobs") }
        let marker = paths.support.appendingPathComponent("downloading-models")
        let updateJson = paths.support.appendingPathComponent("update.json")
        updates = Updates(.init(
            backend: backend,
            busy: { UpdateBusy.reason(daemon: daemonStatus(), jobs: UpdateBusy.runningJobKinds(root: jobsRoot()),
                                      testState: testState(), downloading: UpdateBusy.downloadsRunning(marker: marker)) },
            enabled: { settings().checkUpdates },
            save: { status in
                // Atomically, through a hidden .tmp (updater.write_status), for the window's server.
                let tmp = updateJson.deletingLastPathComponent().appendingPathComponent(".update.json.\(getpid()).tmp")
                try? FileManager.default.createDirectory(at: updateJson.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? status.encoded(indent: 2).write(to: tmp, atomically: false, encoding: .utf8)) != nil {
                    _ = try? FileManager.default.replaceItemAt(updateJson, withItemAt: tmp)
                }
            },
            startedOk: paths.startedOk, bundleVersion: bundleVersion, log: log))
        let start: WorkerStarter = { cmd, extra in try launcher.launch(cmd, nil, qos: .background, extra: extra) }
        housekeeping = Housekeeping(start: start, log: log)
        let access = EventKitCalendarAccess()
        calendarAttach = CalendarAttach(access: access, transcribing: transcribing,
                                        start: start, log: log)
        calendarOnboarding = CalendarOnboarding(access: access, open: { url in
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        })
        permissions = SystemPermissionRequester()
    }

    /// The `extra` of `AppCalls.make`.
    func calls(main: MainRunner) -> [String: AppHandler] {
        ExtraCalls.make(calendar: calendarOnboarding, updates: updates, main: main)
    }
}
