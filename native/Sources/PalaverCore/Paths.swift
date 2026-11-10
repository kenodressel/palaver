import Foundation

/// Where Palaver keeps its files (inventory section 9). `home` and `configDir` are injectable for tests.
public struct Paths: Sendable {
    public let home: URL
    /// $XDG_CONFIG_HOME or ~/.config, then palaver/.
    public let configDir: URL

    /// `configDir` nil: `$XDG_CONFIG_HOME/palaver` of `env` when it is set and not empty, else `home/.config/palaver`.
    /// Tests pass their own, so no test shares the process's config dir with another.
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, configDir: URL? = nil,
                env: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        if let configDir {
            self.configDir = configDir
        } else if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            self.configDir = URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("palaver", isDirectory: true)
        } else {
            self.configDir = home.appendingPathComponent(".config/palaver", isDirectory: true)
        }
        #if DEBUG
        TestIsolation.check(home, "the home")
        TestIsolation.check(self.configDir, "the config dir")
        #endif
    }

    /// The home of `environment`: `PALAVER_HOME` when set and not empty, else `$HOME` (as Python's `Path.home()` and
    /// `expanduser`), else the account's. The app runs with $HOME set to the account's, so this is the same there.
    public static func home(environment env: [String: String]) -> URL {
        if let h = env["PALAVER_HOME"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true) }
        if let h = env["HOME"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `home` is `home(environment:)`'s; the config dir is `env`'s.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        #if DEBUG
        TestIsolation.require("PALAVER_HOME", in: env)
        #endif
        return Paths(home: home(environment: env), env: env)
    }

    /// ~/Library/Application Support/palaver
    public var support: URL { home.appendingPathComponent("Library/Application Support/palaver", isDirectory: true) }
    /// ~/Library/Logs/palaver
    public var logs: URL { home.appendingPathComponent("Library/Logs/palaver", isDirectory: true) }
    public var configToml: URL { configDir.appendingPathComponent("config.toml") }
    public var settingsJson: URL { configDir.appendingPathComponent("settings.json") }

    public var daemonJson: URL { support.appendingPathComponent("daemon.json") }
    public var appSock: URL { support.appendingPathComponent("app.sock") }
    /// The single-instance lock (InstanceLock), held while the Swift app runs.
    public var appLock: URL { support.appendingPathComponent("app.lock") }
    public var startedOk: URL { support.appendingPathComponent("started-ok") }
    public var permissionsMarker: URL { support.appendingPathComponent("permissions-requested") }
    /// The window was opened by itself at a start (#20): it is not again.
    public var windowOfferedMarker: URL { support.appendingPathComponent("window-offered") }
    public var appLog: URL { logs.appendingPathComponent("app.log") }
    public var daemonLog: URL { logs.appendingPathComponent("daemon.log") }
    public var crashesLog: URL { logs.appendingPathComponent("crashes.log") }

    /// The folder meetings are recorded into (`[recording].output_dir`).
    public func outputDir(_ config: Config) -> URL { config.outputDir }
}
