// Test-only (debug builds): in a test process (`swift test`) the home, the stores and the recordings must be
// temporary. `make swift-test` and `make engine-test` export XDG_CONFIG_HOME and PALAVER_HOME as temporary folders;
// Paths, StorePaths and Config stop the process when a test would reach the user's real home, ~/.config or
// ~/Meetings instead, so no test can read or write the user's data. Release builds and the app are not affected.
#if DEBUG
import Foundation

public enum TestIsolation {
    /// Running under swift test: the swift-testing helper or XCTest, or a loaded .xctest bundle.
    public static let isTestProcess: Bool = {
        let name = ProcessInfo.processInfo.processName
        return name == "swiftpm-testing-helper" || name == "xctest" || Bundle.main.bundlePath.hasSuffix(".xctest")
            || Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }()

    /// The user's real home, from the password database (Foundation and $HOME can be changed; this can't).
    static let realHome: String? = {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        return resolved(String(cString: dir))
    }()

    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isUnder(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    /// Stops a test process whose `path` (`what` says which) is the real home, or inside the real ~/.config or
    /// ~/Meetings.
    public static func check(_ path: URL, _ what: String) {
        guard isTestProcess, let home = realHome else { return }
        let p = resolved(path.path)
        if p == home || isUnder(p, home + "/.config") || isUnder(p, home + "/Meetings") {
            fatalError("TestIsolation: \(what) is the user's real \(p) in a test; run the tests with make swift-test or "
                       + "make engine-test (they set XDG_CONFIG_HOME and PALAVER_HOME), or pass a temporary folder")
        }
    }

    /// Stops a test process whose `path` (`what` says which) lies anywhere in the user's real home: for what
    /// talks to the running app (its app.sock, daemon.json), where even ~/Library is out of bounds.
    public static func checkOutsideHome(_ path: URL, _ what: String) {
        guard isTestProcess, let home = realHome else { return }
        let p = resolved(path.path)
        if isUnder(p, home) {
            fatalError("TestIsolation: \(what) is in the user's real home (\(p)) in a test; pass a temporary folder")
        }
    }

    /// Stops a test process when `key` is not set (or empty) in `env`.
    public static func require(_ key: String, in env: [String: String]) {
        guard isTestProcess, (env[key] ?? "").isEmpty else { return }
        fatalError("TestIsolation: \(key) is not set in a test; run the tests with make swift-test or make engine-test, "
                   + "or pass an environment with a temporary folder")
    }

    /// The home `~` stands for in a test process: PALAVER_HOME (required), never the real one. nil outside tests.
    public static func testHome(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard isTestProcess else { return nil }
        require("PALAVER_HOME", in: env)
        let home = env["PALAVER_HOME"]!
        check(URL(fileURLWithPath: home), "PALAVER_HOME")
        return home
    }
}
#endif
