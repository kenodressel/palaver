// The work behind `Updates`, in this process (phase 4 batch 9; before, palaver/app_update.py's `app update …` and
// `app uninstall-start`): the installed release from the bundle's runtime.json, the manifest and the download
// (ReleaseDownloads), the staging (UpdateStaging), swap.sh (UpdateSwap) and the uninstall script (Uninstall).
import Darwin
import Foundation
import PalaverCore

public final class SwiftUpdateBackend: UpdateBackend, @unchecked Sendable {
    public struct Deps: @unchecked Sendable {
        public var paths: Paths
        /// The running Palaver.app; nil from a checkout (nothing to update).
        public var bundle: URL?
        public var downloads: ReleaseDownloads
        public var macos: String?
        /// The recordings folder (config.toml's), for an uninstall that takes the recordings too.
        public var outputDir: @Sendable () -> URL
        /// `open` for the swap's restart (tests: a fake).
        public var open: String
        /// Seconds the new version has to write started-ok before the swap puts the old one back.
        public var startTimeout: Double
        /// Runs a script with /bin/sh on its own (tests record it).
        public var runScript: @Sendable (String) throws -> Void
        /// Where the uninstall script is written (outside what it removes).
        public var temp: URL

        public init(paths: Paths, bundle: URL?, downloads: ReleaseDownloads, macos: String? = ReleaseVersion.macos(),
                    outputDir: @escaping @Sendable () -> URL, open: String = "/usr/bin/open", startTimeout: Double = 120,
                    runScript: @escaping @Sendable (String) throws -> Void = SwiftUpdateBackend.spawnScript,
                    temp: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)) {
            self.paths = paths; self.bundle = bundle; self.downloads = downloads; self.macos = macos; self.outputDir = outputDir
            self.open = open; self.startTimeout = startTimeout; self.runScript = runScript; self.temp = temp
        }
    }

    private let deps: Deps
    private let lock = NSLock()
    private var staged: StagedUpdate?

    public init(_ deps: Deps) { self.deps = deps }

    var updates: URL { deps.paths.support.appendingPathComponent("updates", isDirectory: true) }

    /// `/bin/sh script` in a session of its own, so it outlives the app; its output to /dev/null.
    public static let spawnScript: @Sendable (String) throws -> Void = { script in
        let null = Darwin.open("/dev/null", O_WRONLY)
        defer { if null >= 0 { close(null) } }
        _ = try spawnChild(["/bin/sh", script], env: ProcessInfo.processInfo.environment, output: null >= 0 ? null : nil)
    }

    private var installedVersion: String? { deps.bundle.flatMap(UpdateStaging.bundleVersion) }

    public func status() throws -> (installed: UpdateInstalled?, previous: JSONValue?) {
        let installed = installedVersion.map { UpdateInstalled(version: $0) }
        let file = deps.paths.support.appendingPathComponent("update.json")
        var previous: JSONValue?
        if let data = try? Data(contentsOf: file), let value = JSONValue.parse(data), case .object = value { previous = value }
        return (installed, previous)
    }

    /// The plan for the latest release; nil when it is not newer. `version`: the one the user chose must still be it.
    private func plan(_ version: String? = nil) throws -> (UpdatePlan, ReleaseManifest)? {
        guard let installed = installedVersion else { return nil }
        let manifest = try deps.downloads.fetchManifest()
        guard let plan = try UpdatePlanner.plan(installed: installed, manifest: manifest, macos: deps.macos) else { return nil }
        if let version, plan.version != version {
            throw ManifestError("Palaver \(plan.version) came out, not \(version); check again")
        }
        return (plan, manifest)
    }

    public func check() throws -> UpdateCheck {
        guard let (plan, _) = try plan() else { return .upToDate }
        return .plan(plan)
    }

    public func download(version: String, progress: @escaping @Sendable (Int) -> Void) throws {
        guard let (plan, manifest) = try plan(version) else { throw ManifestError("there is nothing to download") }
        lock.withLock { staged = nil }
        let result = try UpdateStaging.stage(version: plan.version, asset: manifest.app, updates: updates,
                                             download: { asset, dest, p in try self.deps.downloads.download(asset, to: dest, progress: p) },
                                             progress: { progress($0) })
        lock.withLock { staged = result }
    }

    private func stagedOrThrow() throws -> StagedUpdate {
        guard let s = lock.withLock({ staged }), FileManager.default.fileExists(atPath: s.app.path) else {
            throw ManifestError("no downloaded update to install")
        }
        return s
    }

    private func places(_ s: StagedUpdate) -> UpdateSwap.Places {
        // The bundle that runs is the one replaced; without one, where install.sh puts it.
        let target = deps.bundle ?? deps.paths.home.appendingPathComponent("Applications/Palaver.app", isDirectory: true)
        return UpdateSwap.Places(target: target, staged: s.app, support: deps.paths.support)
    }

    public func prepare(waitFor: [Int32]) throws -> String {
        let s = try stagedOrThrow()
        return try UpdateSwap.prepare(s, current: installedVersion, places: places(s), pids: waitFor,
                                      open: deps.open, startTimeout: deps.startTimeout).path
    }

    public func commit() throws {
        _ = try stagedOrThrow()
        UpdateSwap.commit(support: deps.paths.support)
    }

    public func spawnSwap(script: String) throws { try deps.runScript(script) }

    public func uninstallStart(models: Bool, recordings: Bool, waitFor: [Int32]) throws -> [String] {
        let out = deps.outputDir()
        let remove = Uninstall.plan(paths: deps.paths, outputDir: out, models: models, recordings: recordings)
        try Uninstall.start(remove, waitFor: waitFor, work: deps.temp,
                            thenIfEmpty: recordings ? Uninstall.emptied(paths: deps.paths, outputDir: out) : [],
                            run: deps.runScript)
        return remove.map(\.path)
    }
}
