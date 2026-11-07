import Foundation

/// Where Palaver keeps its files (inventory section 9). `home` is injectable for tests.
public struct Paths: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// ~/Library/Application Support/palaver
    public var support: URL { home.appendingPathComponent("Library/Application Support/palaver", isDirectory: true) }
    /// ~/Library/Logs/palaver
    public var logs: URL { home.appendingPathComponent("Library/Logs/palaver", isDirectory: true) }
    /// $XDG_CONFIG_HOME or ~/.config, then palaver/
    public var configDir: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("palaver", isDirectory: true)
        }
        return home.appendingPathComponent(".config/palaver", isDirectory: true)
    }
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
