// What the routes need (webapp/server.py `App`, webapp/__init__.py `build_app`): where the
// recordings are, the config, the app's recording, the language model's helpers, the locks api.py
// keeps in its process, and the drain of the changes being made (Inflight).
import Foundation
import PalaverCore
import PalaverDomain

public final class ServerApp: @unchecked Sendable {
    public let outputDir: URL
    /// Where an export is saved (#58).
    public let downloads: URL
    public let config: Config
    /// The global CLI options (`--config`, `--dictionary`, `--no-notify`) for what the server starts.
    public let cliOptions: [String]
    public let staticDir: URL
    public let stores: StorePaths
    /// The defaults for what settings.json leaves out (`record_slack`, `live_processing` from config.toml).
    public let settingsDefaults: SettingsValues
    /// The language model's jobs on disk (#57), `<outputDir>/.jobs`: a restarted server finds them.
    public let jobs: URL
    public let inflight = Inflight()
    // api.py's in-process locks.
    public let projectsLock = NSLock()
    public let glossaryLock = NSLock()
    public let myNotesLock = NSLock()
    /// One language model at a time (`App.notes_lock`).
    public let notesLock = NSLock()
    /// The notes runs this server waits for, by meeting (`App.notes_jobs`).
    public let notesJobs = NotesJobs()
    /// `[notes].enabled`: without it the language model's routes answer 503.
    public let notesEnabled: Bool
    public let freeMemoryGB: () -> Double
    /// The menu bar app (daemon.json, app.sock); nil outside it (Python's `recording=None`).
    public let recording: RecordingRemote?
    /// Whether the speech models are on this Mac (onboarding.speech_here), asked by Transcribe Again: the probe's.
    public let speechHere: () -> Bool
    /// `open <url>` (System Settings at Palaver's notifications).
    public let openURL: (String) -> Void
    /// `$PALAVER_NOTIFY_STATE`: the file the app's launcher writes whether macOS lets Palaver notify into.
    public let notifyState: String?
    /// (start, end) -> events, for meetings still to come; nil when the calendar is turned off.
    public let calendar: CalendarProvider?
    /// The setup assistant's look at this Mac, its downloads (onboarding.Probe): `MacProbe` unless one is given.
    public let probe: SetupProbe
    public let helpers: HelperRunner
    public let nextQuestion: NextQuestionAsker
    public let provider: ProviderHelper
    /// Report a Problem: the zip on the Desktop (`SwiftReport`).
    public let report: ReportMaker
    /// The server's own background work: warming the search, the sweep, the cut lookups, the searcher by meaning.
    public let background = Background()
    /// What the search keeps per meeting while its files are unchanged.
    public let searchCaches = SearchCaches()
    /// The glossary's suggestions while the files they are made of are unchanged (api.py `_SUGGESTIONS`).
    public let glossarySuggestions = GlossarySuggestions()
    /// The open questions and Needs you per meeting while its files are unchanged.
    public let reviewCaches = ReviewCaches()
    /// The calendar keys already looked up for an upcoming meeting's notes (api.py `_KNOWN_EVENTS`): autosave needs
    /// no calendar call.
    public let knownEvents = KnownEvents()
    /// What reads the text in a pasted image (`my_notes.recognize_text`, macOS Vision); a test may replace it before
    /// the server serves (Python's tests monkeypatch it).
    public var recognizeText: (URL) throws -> String = MyNotes.recognizeText
    /// The meeting list's entries while their files are unchanged (api.py `_LIST_CACHE`): the window polls the list.
    public let meetingList = SignatureCache<PyDict<JSONValue>>()
    /// What the meeting changes do through the domain (ChangesAPI); a test may replace them before the server serves.
    public var changeOps = ChangeOps()
    /// api.py `_status` as the best next question asks it (Python's tests monkeypatch it); a test may replace it.
    public var meetingStatus: (RecordingPaths) -> String = MeetingsAPI.state
    /// Where Claude Desktop is installed (`mcp_access.DESKTOP_APP`, not under the home); a test may replace it.
    public var claudeDesktopApp: URL = McpLog.DESKTOP_APP
    /// Adding the MCP server to Claude Code and Claude Desktop (`install_mcp`): `bin/palaver` with the server's options;
    /// a test may replace it (in a test process no `claude` is found by default).
    public var mcpSetup: McpSetup
    /// daemon.log (the server's SessionLog), for what api.py logs itself; set by HTTPServer when it has one.
    public var log: SessionLog?

    private let nameLock = NSLock()
    private var name: String

    /// The user's name: the setup profile changes it while the server runs.
    public var userName: String {
        get { nameLock.withLock { name } }
        set { nameLock.withLock { name = newValue } }
    }

    public init(outputDir: URL, userName: String, config: Config = Config(), stores: StorePaths = .current(),
                downloads: URL? = nil, cliOptions: [String] = [],
                staticDir: URL = ServerApp.defaultStaticDir, settingsDefaults: SettingsValues? = nil,
                notesEnabled: Bool? = nil, freeMemoryGB: @escaping () -> Double = { .infinity },
                recording: RecordingRemote? = nil, calendar: CalendarProvider? = nil,
                probe: SetupProbe? = nil, helpers: HelperRunner? = nil,
                nextQuestion: NextQuestionAsker? = nil, provider: ProviderHelper? = nil,
                report: ReportMaker? = nil, speechHere: (() -> Bool)? = nil, openURL: @escaping (String) -> Void = ServerApp.open,
                notifyState: String? = ProcessInfo.processInfo.environment["PALAVER_NOTIFY_STATE"]) {
        self.outputDir = outputDir
        name = userName
        self.config = config
        self.stores = stores
        self.downloads = downloads ?? stores.downloads
        self.cliOptions = cliOptions
        self.staticDir = staticDir
        if let settingsDefaults {
            self.settingsDefaults = settingsDefaults
        } else {
            var s = SettingsValues()
            s.recordSlack = config.recordSlack
            s.liveProcessing = config.processingLive
            self.settingsDefaults = s
        }
        self.notesEnabled = notesEnabled ?? config.notesEnabled
        self.freeMemoryGB = freeMemoryGB
        self.recording = recording
        self.calendar = calendar
        let probe = probe ?? MacProbe(stores: stores, outputDir: outputDir, config: config, recording: recording,
                                      calendar: calendar, notifyState: notifyState)
        self.probe = probe
        // The release server gets every one (ServeMain.makeApp); tests leave out what they don't use.
        self.helpers = helpers ?? StubHelperRunner()
        self.nextQuestion = nextQuestion ?? StubNextQuestionAsker()
        self.provider = provider ?? StubProviderHelper()
        self.report = report ?? StubReportMaker()
        self.speechHere = speechHere ?? { probe.speechHere() }
        self.openURL = openURL
        self.notifyState = notifyState
        jobs = ModelJobs.root(outputDir)
        mcpSetup = McpSetup(stores: stores, executable: McpSetup.executable(), options: cliOptions)
        background.app = self
    }

    /// `subprocess.run(["open", url], check=False)`.
    public static func open(_ url: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url]
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {}
    }

    /// `PALAVER_TEST_OPENED` (debug builds only): the file a URL the server would open is appended to (one line each),
    /// so an end-to-end test sees it and nothing opens on the Mac.
    public static let TEST_OPENED = "PALAVER_TEST_OPENED"

    /// What `openURL` does: `open`; in a debug build with `$PALAVER_TEST_OPENED` set, a line in that file instead.
    public static func opener(env: [String: String]) -> (String) -> Void {
        #if DEBUG
        if let file = env[TEST_OPENED], !file.isEmpty { return { appendLine(file, $0) } }
        #endif
        return ServerApp.open
    }

    /// One line appended to `file` (the end-to-end tests' record of what would have been opened).
    static func appendLine(_ file: String, _ text: String) {
        let fd = Darwin.open(file, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let line = Array((text + "\n").utf8)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// `PALAVER_TEST_FREE_GB` (debug builds only): the file whose number is the free memory, in place of this Mac's.
    public static let TEST_FREE_GB = "PALAVER_TEST_FREE_GB"

    /// What `freeMemoryGB` asks: this Mac's free memory (`FreeMemory.availableGB`). In a debug build with
    /// `$PALAVER_TEST_FREE_GB` set, the number in the file it names, read at every request so an end-to-end test can
    /// change it while the server runs; a file that is missing or holds no number counts as this Mac's.
    public static func freeMemory(env: [String: String]) -> () -> Double {
        #if DEBUG
        if let file = env[TEST_FREE_GB], !file.isEmpty {
            return {
                (try? String(contentsOfFile: file, encoding: .utf8)).flatMap { Double(Py.strip($0)) }
                    ?? FreeMemory.availableGB()
            }
        }
        #endif
        return FreeMemory.availableGB
    }

    /// The page palaver-server serves without `--static` (the app always passes it): the bundle's or the checkout's
    /// copy, found from the running executable (`AppLocation.staticDir()`). A debug build outside both (a test
    /// runner in the toolchain) falls back to the checkout this source file is in; a release build never embeds
    /// that path (it would carry the builder's home folder and user name into the published binary).
    public static let defaultStaticDir: URL = staticDir(executable: Bundle.main.executableURL
                                                        ?? URL(fileURLWithPath: CommandLine.arguments[0]))

    static func staticDir(executable: URL) -> URL {
        if let found = AppLocation(executable: executable).staticDir() { return found }
        #if DEBUG
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("palaver/webapp/static", isDirectory: true)
        #else
        return executable.deletingLastPathComponent().appendingPathComponent("static", isDirectory: true)
        #endif
    }
}
