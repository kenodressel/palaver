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
    /// `transcribing`: whether a recording is processed now (the calendar retry waits). Updates run in this
    /// process (SwiftUpdateBackend).
    init(paths: Paths, config: @escaping @Sendable () -> Config, settings: @escaping @Sendable () -> Settings,
         launcher: WorkerLauncher,
         daemonStatus: @escaping @Sendable () -> JSONValue, testState: @escaping @Sendable () -> String?,
         transcribing: @escaping @Sendable () -> Bool, bundleVersion: String?, bundle: URL?,
         log: @escaping @Sendable (String) -> Void) {
        let environment = ProcessInfo.processInfo.environment
        let backend = SwiftUpdateBackend(.init(
            paths: paths, bundle: bundleVersion == nil ? nil : bundle,
            downloads: ReleaseDownloads(manifestURL: ReleaseDownloads.manifestURL(environment: environment)),
            outputDir: { config().outputDir }))
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
        // In this process (no Python child): at start also Claude's MCP entries moved to `bin/palaver mcp` (batch 6),
        // then the old Python runtime deleted once nothing needs it (batch 9).
        let runtime = RuntimeCleanup.Facts.app(bundle: bundle, bundleVersion: bundleVersion, support: paths.support,
                                               environment: environment)
        housekeeping = Housekeeping.inProcess(config: config, extras: [Housekeeping.movingMcpEntries(bundle: bundle, log: log),
                                                                       Housekeeping.removingOldRuntime(runtime, log: log)],
                                              log: log)
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
