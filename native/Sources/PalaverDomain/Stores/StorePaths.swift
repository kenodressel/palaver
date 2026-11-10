import Foundation
import PalaverCore

/// Where every store lives: the config dir (user data), Application Support (state), the home folders.
/// File names are the Python app's (config.py, install_layout.py, the store modules).
public struct StorePaths: Sendable {
    public let configDir: URL
    public let home: URL
    public let hubCache: URL

    public init(configDir: URL, home: URL, hubCache: URL? = nil) {
        self.configDir = configDir
        self.home = home
        self.hubCache = hubCache ?? home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        #if DEBUG
        TestIsolation.check(configDir, "the config dir")
        TestIsolation.check(home, "the home")
        #endif
    }

    /// `PALAVER_HOME` moves the home; `XDG_CONFIG_HOME` (when not empty) moves the config dir;
    /// `HF_HUB_CACHE`, else `HF_HOME/hub`, the model cache.
    public static func current(env: [String: String] = ProcessInfo.processInfo.environment) -> StorePaths {
        let home = Paths.fromEnvironment(env).home
        func set(_ k: String) -> String? { env[k].flatMap { $0.isEmpty ? nil : $0 } }
        let base = set("XDG_CONFIG_HOME").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        var hub: URL?
        if let h = set("HF_HUB_CACHE") { hub = URL(fileURLWithPath: h, isDirectory: true) }
        else if let h = set("HF_HOME") { hub = URL(fileURLWithPath: h, isDirectory: true).appendingPathComponent("hub", isDirectory: true) }
        return StorePaths(configDir: base.appendingPathComponent("palaver", isDirectory: true), home: home, hubCache: hub)
    }

    private func cfg(_ n: String, dir: Bool = false) -> URL { configDir.appendingPathComponent(n, isDirectory: dir) }
    private func sup(_ n: String, dir: Bool = false) -> URL { support.appendingPathComponent(n, isDirectory: dir) }

    // Config dir
    public var configToml: URL { cfg("config.toml") }
    public var settings: URL { cfg("settings.json") }
    public var voices: URL { cfg("voices", dir: true) }
    public var projects: URL { cfg("projects.json") }
    public var glossary: URL { cfg("glossary.json") }
    public var organizations: URL { cfg("organizations.json") }
    public var attributions: URL { cfg("attributions.json") }
    public var prepared: URL { cfg("prepared.json") }
    public var preparedNotes: URL { cfg("prepared-notes", dir: true) }
    public var sharedSeries: URL { cfg("shared-series.json") }
    public var coachBaseline: URL { cfg("coach-baseline.json") }
    public var accessLog: URL { cfg("access-log.jsonl") }
    public var dictionary: URL { cfg("dictionary.toml") }
    public var cloudPending: URL { cfg("cloud-pending.json") }

    // Application Support
    public var support: URL { home.appendingPathComponent("Library/Application Support/palaver", isDirectory: true) }
    public var usage: URL { sup("usage.jsonl") }
    public var usageFeatures: URL { sup("usage-features.json") }
    public var notesLock: URL { sup("notes.lock") }
    public var mcpAccess: URL { sup("mcp-access.jsonl") }
    public var mcpDir: URL { sup("mcp", dir: true) }
    public var updateJson: URL { sup("update.json") }
    public var downloadingModels: URL { sup("downloading-models") }
    public var daemonJson: URL { sup("daemon.json") }
    public var appSock: URL { sup("app.sock") }
    public var modelsDir: URL { sup("models", dir: true) }
    public var engineProvenMarker: URL { sup("engine-transcribed") }
    public var permissionsMarker: URL { sup("permissions-requested") }

    // Under home
    public var launchAgent: URL {
        home.appendingPathComponent("Library/LaunchAgents/com.kenodressel.meeting-transcribe.plist")
    }
    public var downloads: URL { home.appendingPathComponent("Downloads", isDirectory: true) }
    public var applications: URL { home.appendingPathComponent("Applications", isDirectory: true) }
    public var logs: URL { home.appendingPathComponent("Library/Logs/palaver", isDirectory: true) }
    /// Claude Code's config (`claude mcp add --scope user` writes there): only read (McpLog).
    public var claudeConfig: URL { home.appendingPathComponent(".claude.json") }
    /// Claude Desktop's config: only read (McpLog).
    public var claudeDesktopConfig: URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }
}
