// Staging an update (updater.Installer.stage, #60): the app archive downloaded into Application Support's
// updates/ folder, unpacked with ditto, its version checked against the release (runtime.json's `version`; its
// `runtime` is the placeholder that releases before 0.6 check, not read here) and macOS's quarantine taken off.
// Anything failing leaves no updates/ folder behind and keeps the version that runs.
import Foundation

/// An update downloaded and checked, waiting to be swapped in.
public struct StagedUpdate: Equatable, Sendable {
    public var version: String
    /// The new Palaver.app, unpacked.
    public var app: URL
}

public enum UpdateStaging {
    public static let appName = "Palaver.app"

    /// The release's `version` of a bundle (Contents/Resources/runtime.json); nil when it has none.
    public static func bundleVersion(_ app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Resources/runtime.json")),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let v = obj["version"] as? String, !v.isEmpty else { return nil }
        return v
    }

    /// Downloads `asset` (release `version`) with `download` into `updates`, unpacks and checks it.
    public static func stage(version: String, asset: ReleaseAsset, updates: URL,
                             download: (ReleaseAsset, URL, (Int) -> Void) throws -> URL,
                             progress: @escaping (Int) -> Void = { _ in }) throws -> StagedUpdate {
        let fm = FileManager.default
        try? fm.removeItem(at: updates)
        try fm.createDirectory(at: updates, withIntermediateDirectories: true)
        do {
            let archive = try download(asset, updates.appendingPathComponent(asset.name + ".part"), progress)
            let out = updates.appendingPathComponent("app", isDirectory: true)
            try run("/usr/bin/ditto", ["-xk", archive.path, out.path], what: "unpacking \(asset.name)")
            try? fm.removeItem(at: archive)
            let app = out.appendingPathComponent(appName, isDirectory: true)
            guard bundleVersion(app) == version else { throw ManifestError("the downloaded app is not Palaver \(version)") }
            _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path], what: "")
            return StagedUpdate(version: version, app: app)
        } catch {
            try? fm.removeItem(at: updates)
            throw error
        }
    }

    /// Runs a tool to its end; a failure throws with its stderr.
    static func run(_ tool: String, _ args: [String], what: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let why = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManifestError("\(what) failed" + (why.isEmpty ? "" : ": \(why)"))
        }
    }
}
