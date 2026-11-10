// The setup assistant's look at this Mac (palaver/onboarding.py `Probe`, `APP_DIRS`, `TEAMS_APPS`, `SLACK_APPS`,
// `speech_here`, `SPEECH_CACHE_SECONDS`, `fetch_missing_speech`; app_bundle.py `set_autostart`, `launch_agent_plist`;
// notes.py `find_claude`; webapp/process.py `fetch_speech`). Read-only, except for autostart (a LaunchAgent under the home
// of `PALAVER_HOME`) and the downloads the user starts.
import Darwin
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

extension SetupProbe {
    /// Starts downloading the speech models if they are not here (onboarding.fetch_missing_speech). Every meeting waits for
    /// them and there is nothing to choose (0.5 GB), so a copy that is missing is fetched at once instead of waiting for
    /// someone to find it in Settings. True when a download was started.
    @discardableResult
    public func fetchMissingSpeech() -> Bool {
        if !hardware().appleSilicon || downloaded().contains(where: { Py.same($0, "speech") }) { return false }
        _ = try? downloads.start(["speech"])
        return true
    }
}

/// Whether the speech models are ready (onboarding.speech_here). The files say no for certain; when they are all there, the
/// engine (`hello`, its own ModelStore rule) has the last word. Without an engine binary the files decide; an engine that
/// crashes on `hello` means not ready. Remembered for `SPEECH_CACHE_SECONDS` so the pages don't start an engine each.
public final class SpeechCheck: @unchecked Sendable {
    public static let SPEECH_CACHE_SECONDS = 30.0
    /// `Engine(idle_timeout=30)` for `hello`.
    public static let HELLO_IDLE = 30.0

    let stores: StorePaths
    let enginePath: () throws -> URL
    let clock: () -> Double
    let hello: (URL) throws -> JSONValue
    private let lock = NSLock()
    private var cached: (at: Double, ready: Bool)?

    /// `hello(engine)`: the engine's answer to `hello` (`SpeechCheck.hello(engine:stores:env:)` by default).
    public init(stores: StorePaths, enginePath: @escaping () throws -> URL, env: [String: String] = ProcessInfo.processInfo.environment,
                clock: @escaping () -> Double = SpeechCheck.monotonic, hello: ((URL) throws -> JSONValue)? = nil) {
        self.stores = stores
        self.enginePath = enginePath
        self.clock = clock
        self.hello = hello ?? { try SpeechCheck.hello(engine: $0, stores: stores, env: env) }
    }

    public static func monotonic() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

    /// The engine's model folder.
    public static func models(_ stores: StorePaths) -> URL {
        stores.modelsDir.appendingPathComponent(ModelCatalog.SPEECH_FOLDER, isDirectory: true)
    }

    /// One engine, one `hello`, closed again.
    public static func hello(engine: URL, stores: StorePaths, env: [String: String]) throws -> JSONValue {
        let e = EngineProcess(path: { engine }, models: models(stores), version: Exchange.palaverVersion, env: env,
                              idle: HELLO_IDLE)
        defer { e.close() }
        return try e.call("hello")
    }

    public func here() -> Bool {
        lock.withLock {
            let now = clock()
            if let cached, now - cached.at < Self.SPEECH_CACHE_SECONDS { return cached.ready }
            let ready = self.ready()
            cached = (now, ready)
            return ready
        }
    }

    /// Forgets the last answer (`speech_here.cache_clear()`): the models just downloaded.
    public func clear() { lock.withLock { cached = nil } }

    private func ready() -> Bool {
        guard ModelCatalog.speechFilesHere(stores: stores) else { return false }
        guard let engine = try? enginePath(), FileManager.default.fileExists(atPath: engine.path) else {
            return true  // no engine binary: the files decide
        }
        guard let answer = try? hello(engine), case .object(let models)? = answer["models"] else { return false }
        return !models.isEmpty && models.allSatisfy { $0.1.truthy }
    }
}

/// Palaver at login: a LaunchAgent that opens the app through LaunchServices, so it runs as the app (with its own
/// permissions), not as a bare launchd job (app_bundle.set_autostart). Under the home of `PALAVER_HOME`.
public enum Autostart {
    /// app_bundle.BUNDLE_ID.
    public static let BUNDLE_ID = "com.kenodressel.meeting-transcribe"

    /// The app it opens: `~/Applications/Palaver.app` (app_bundle.APPS_DIR).
    public static func app(_ stores: StorePaths) -> URL { stores.applications.appendingPathComponent("Palaver.app") }

    /// `plistlib.dumps({"Label", "ProgramArguments": ["/usr/bin/open", "-g", "-a", app], "RunAtLoad": True})`.
    public static func plist(app: String) -> Data {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let text = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>Label</key>
            \t<string>\(BUNDLE_ID)</string>
            \t<key>ProgramArguments</key>
            \t<array>
            \t\t<string>/usr/bin/open</string>
            \t\t<string>-g</string>
            \t\t<string>-a</string>
            \t\t<string>\(escape(app))</string>
            \t</array>
            \t<key>RunAtLoad</key>
            \t<true/>
            </dict>
            </plist>

            """
        return Data(text.utf8)
    }

    public static func isOn(_ stores: StorePaths) -> Bool { FileManager.default.fileExists(atPath: stores.launchAgent.path) }

    public static func set(_ on: Bool, stores: StorePaths) throws {
        let agent = stores.launchAgent
        #if DEBUG
        TestIsolation.checkOutsideHome(agent, "the LaunchAgent")
        #endif
        if on {
            try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plist(app: app(stores).path).write(to: agent)
        } else if isOn(stores) {
            try FileManager.default.removeItem(at: agent)
        }
    }
}

/// The Mac as it is (onboarding.Probe).
public final class MacProbe: SetupProbe, @unchecked Sendable {
    public static let TEAMS_APPS = ["Microsoft Teams.app", "Microsoft Teams (work or school).app", "Microsoft Teams classic.app"]
    public static let SLACK_APPS = ["Slack.app"]

    let stores: StorePaths
    let outputDir: URL
    let claudePath: String?
    let recording: RecordingRemote?
    let calendar: CalendarProvider?
    let notifyState: String?
    let env: [String: String]
    /// Where Claude Desktop is installed (`mcp_access.DESKTOP_APP`).
    var desktopApp: URL = McpLog.DESKTOP_APP
    public let speech: SpeechCheck
    public let downloads: SetupDownloads

    /// `recording`: the menu bar app, whose answer is the calendar permission (nil: this process's); `calendar`: the
    /// calendar's events (nil: turned off); `hfToken`: the Hugging Face token, asked when a model download starts.
    public init(stores: StorePaths, outputDir: URL, config: Config, recording: RecordingRemote?,
                calendar: CalendarProvider?, notifyState: String?, env: [String: String] = ProcessInfo.processInfo.environment,
                enginePath: (() throws -> URL)? = nil, hfToken: @escaping () -> String? = { nil }) {
        self.stores = stores
        self.outputDir = outputDir
        claudePath = config.claudePath
        self.recording = recording
        self.calendar = calendar
        self.notifyState = notifyState
        self.env = env
        let engine = enginePath ?? { try EnginePath.find(env: env) }
        let speech = SpeechCheck(stores: stores, enginePath: engine, env: env)
        self.speech = speech
        downloads = SetupDownloads(stores: stores, hub: HubDownloader(stores: stores, env: env), token: hfToken, speech: speech) {
            EngineProcess(path: engine, models: SpeechCheck.models(stores), version: Exchange.palaverVersion, env: env)
        }
    }

    /// `APP_DIRS`: /Applications and the home's Applications.
    public var appDirs: [URL] { [URL(fileURLWithPath: "/Applications", isDirectory: true), stores.applications] }

    public func hardware() -> Hardware {
        let memory = (Self.sysctlInt("hw.memsize").map { Double($0) } ?? 0) / 1_073_741_824.0
        var free = 0.0
        var st = statvfs()
        if statvfs(stores.home.path, &st) == 0 { free = Double(st.f_bavail) * Double(st.f_frsize) / 1_073_741_824.0 }
        let brand = Py.strip(Self.sysctlString("machdep.cpu.brand_string") ?? "")
        return Hardware(chip: brand.isEmpty ? "unknown" : brand, memoryGB: memory.rounded(.toNearestOrEven), freeDiskGB: free)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func sysctlInt(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    public func installed() -> Installed {
        func app(_ names: [String]) -> Bool {
            appDirs.contains { d in names.contains { FileManager.default.fileExists(atPath: d.appendingPathComponent($0).path) } }
        }
        return Installed(teams: app(Self.TEAMS_APPS), slack: app(Self.SLACK_APPS),
                         claudeCode: Self.findClaude(configured: claudePath, env: env, home: stores.home) != nil,
                         claudeDesktop: FileManager.default.fileExists(atPath: desktopApp.path))
    }

    /// The Claude Code CLI (notes.find_claude): `ClaudeCLI.find`.
    static func findClaude(configured: String?, env: [String: String], home: URL) -> String? {
        ClaudeCLI.find(configured: configured, env: env, home: home)
    }

    public func permissions() -> PyDict<JSONValue> {
        PyDict([
            ("microphone", SetupPermissions.microphone()),
            ("calendar", recording?.calendarStatus() ?? Remote.calendarPermission()),
            ("system_audio", SetupPermissions.systemAudio(outputDir: outputDir)),
            ("notifications", SetupPermissions.notifications(statePath: notifyState)),
        ])
    }

    /// The models whose every file is on this Mac (a partial download is not); the speech models as the engine says.
    public func downloaded() -> [String] {
        ModelCatalog.models.filter { m in
            var here = ModelCatalog.modelHere(m, repo: ModelCatalog.repoFor(m), speechHere: speech.here, stores: stores)
            if Py.same(m.id, "e5") && here {  // pinned to a revision: that one must be there
                here = E5Encoder.modelFolder(stores: stores) != nil
            }
            return here
        }.map(\.id)
    }

    public func fullName() -> String {
        guard let pw = getpwuid(getuid()), let gecos = pw.pointee.pw_gecos else { return "" }
        let text = String(cString: gecos)
        return Py.strip(text.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? "")
    }

    public func autostart() -> Bool { Autostart.isOn(stores) }

    public func setAutostart(_ on: Bool) throws { try Autostart.set(on, stores: stores) }

    public func calendarEvents(_ start: Date, _ end: Date) throws -> [CalendarEvent] {
        try calendar?(start, end) ?? []
    }

    public func speechHere() -> Bool { speech.here() }
}

extension ServeMain {
    /// The speech models download by themselves when they are missing (a tester's calls waited for a download nobody
    /// started), started after the ready line. Only in an installed release (`installed`): a checkout's server
    /// (development, tests) never downloads on its own (process.fetch_speech).
    static func fetchSpeech(_ app: ServerApp, installed: Bool = EnginePath.location.bundle != nil) {
        guard installed else { return }
        app.probe.fetchMissingSpeech()
    }
}
