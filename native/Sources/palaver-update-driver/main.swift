// Test-only (tools/smoke_install.sh, never in Palaver.app): drives the Swift updater of an installed Palaver.app as the
// app does from its menu (Updates → check, download, install), without starting the app:
//   palaver-update-driver --home H --bundle APP --open OPENER [--start-timeout S]
// The manifest is $PALAVER_MANIFEST_URL's (a file:// one: its file:// assets are allowed then). It checks for an
// update (one newer than the bundle's runtime.json must be there), downloads and stages it, writes swap.sh and commits,
// prints one JSON line {"version", "download_bytes", "runtime", "swap"} and exits 0; the caller runs `/bin/sh <swap>`
// as the app would once it quit. Exit 1 with the error on stderr.
import Foundation
import PalaverCore
import PalaverDaemon
import PalaverDomain

func value(_ flag: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

guard let home = value("--home"), let bundle = value("--bundle"), let open = value("--open") else {
    FileHandle.standardError.write(Data("usage: palaver-update-driver --home H --bundle APP --open OPENER [--start-timeout S]\n".utf8))
    exit(2)
}
let env = ProcessInfo.processInfo.environment
let paths = Paths(home: URL(fileURLWithPath: home, isDirectory: true), env: env)
let app = URL(fileURLWithPath: bundle, isDirectory: true)
let backend = SwiftUpdateBackend(.init(
    paths: paths, bundle: app, downloads: ReleaseDownloads(manifestURL: ReleaseDownloads.manifestURL(environment: env)),
    outputDir: { paths.home.appendingPathComponent("Meetings/Recordings", isDirectory: true) }, open: open,
    startTimeout: Double(value("--start-timeout") ?? "") ?? 120, runScript: { _ in }))
do {
    guard case .plan(let plan) = try backend.check() else { throw ManifestError("no update: the bundle is up to date") }
    try backend.download(version: plan.version, progress: { _ in })
    let swap = try backend.prepare(waitFor: [])
    try backend.commit()
    let out: JSONValue = .object([("version", .string(plan.version)), ("download_bytes", .int(plan.downloadBytes)),
                                  ("runtime", .bool(plan.runtime)), ("swap", .string(swap))])
    print(PythonJSON.dumps(out))
} catch {
    FileHandle.standardError.write(Data("palaver-update-driver: \(error)\n".utf8))
    exit(1)
}
