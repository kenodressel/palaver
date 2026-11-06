// The Python commands behind `Updates` (palaver/app_update.py): `palaver app update check|download|status|
// prepare|commit --json` and `palaver app uninstall-start`. swap.sh is written by Python (updater.py's
// _SWAP, unchanged) and run from here, on its own, once the app has asked the idle gate a last time.
import Darwin
import Foundation
import PalaverCore

public struct PythonUpdateBackend: UpdateBackend {
    public var python: String
    public var cliOptions: [String]
    public var env: [String: String]
    /// Where the commands' stderr goes (daemon.log): a crash's traceback.
    public var log: (@Sendable (String) -> Void)?
    /// Runs the swap script (tests record it).
    public var runScript: @Sendable (String) throws -> Void

    public init(python: String, cliOptions: [String], env: [String: String], log: (@Sendable (String) -> Void)? = nil,
                runScript: (@Sendable (String) throws -> Void)? = nil) {
        self.python = python; self.cliOptions = cliOptions; self.env = env; self.log = log
        self.runScript = runScript ?? { script in
            // Not the app's child: a session of its own, so it outlives the app. Output to /dev/null.
            let null = open("/dev/null", O_WRONLY)
            defer { if null >= 0 { close(null) } }
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            _ = try spawnChild(["/bin/sh", script], env: merged, output: null >= 0 ? null : nil)
        }
    }

    private func run(_ args: [String], timeout: TimeInterval = 120,
                     onObject: (([String: Any]) -> Void)? = nil) throws -> [String: Any] {
        try pythonCommandBlocking(args, python: python, extraArgs: cliOptions, env: env, timeout: timeout, log: log, onObject: onObject)
    }

    public func status() throws -> (installed: UpdateInstalled?, previous: JSONValue?) {
        let a = try run(["app", "update", "status", "--json"])
        var installed: UpdateInstalled?
        if let i = a["installed"] as? [String: Any], let v = i["version"] as? String {
            installed = UpdateInstalled(version: v, runtime: i["runtime"] as? String)
        }
        let previous = a["previous"].flatMap { $0 is NSNull ? nil : JSONValue(any: $0) }
        return (installed, previous)
    }

    public func check() throws -> UpdateCheck {
        let a = try run(["app", "update", "check", "--json"])
        guard let p = a["plan"] as? [String: Any], let version = p["version"] as? String else { return .upToDate }
        return .plan(UpdatePlan(version: version, notes: p["notes"] as? String,
                                downloadBytes: (p["download_bytes"] as? NSNumber)?.intValue ?? 0,
                                runtime: (p["runtime"] as? Bool) ?? false, models: (p["models"] as? [String]) ?? []))
    }

    public func download(version: String, progress: @escaping @Sendable (Int) -> Void) throws {
        _ = try run(["app", "update", "download", "--version", version, "--json"], timeout: 3 * 3600) { o in
            if let n = o["progress"] as? NSNumber { progress(n.intValue) }
        }
    }

    public func prepare(waitFor: [Int32]) throws -> String {
        let a = try run(["app", "update", "prepare", "--wait-for"] + waitFor.map(String.init) + ["--json"], timeout: 600)
        guard let script = a["script"] as? String else { throw WorkerError(description: "no swap script") }
        return script
    }

    public func commit() throws { _ = try run(["app", "update", "commit", "--json"]) }

    public func spawnSwap(script: String) throws { try runScript(script) }

    public func uninstallStart(models: Bool, recordings: Bool, waitFor: [Int32]) throws -> [String] {
        var args = ["app", "uninstall-start"]
        if models { args.append("--models") }
        if recordings { args.append("--recordings") }
        args += ["--wait-for"] + waitFor.map(String.init) + ["--json"]
        return (try run(args)["removing"] as? [String]) ?? []
    }
}
