// The end-to-end tests' Mac (tests/fake_probe.py's FakeProbe for palaver-server): what it detects comes from the JSON
// file `$PALAVER_TEST_PROBE` names, read at every look so a test can change it while the server runs. Nothing here looks
// at the real Mac or downloads a real model (`hub_downloads` fetches from the test's stub hub, `HF_ENDPOINT`). Debug
// builds only: a release ignores the variable.
#if DEBUG
import Darwin
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

/// `PALAVER_TEST_PROBE`: `{"hardware": {"chip", "memory_gb", "free_disk_gb"}, "installed": {"teams", "slack",
/// "claude_code", "claude_desktop"}, "permissions": {key: {state, detail[, fix]}}, "downloaded": [id], "events":
/// [calendar event], "hold_downloads": bool, "hub_downloads": bool}`, and optionally `"full_name"` and `"fail_once": [id]`
/// (those fail their first download). Every key may be left out (FakeProbe's defaults). A download "fetches" at once and
/// is downloaded from then on; with `hold_downloads`, each one waits while `<probe>.hold` exists (deleting it releases
/// them); with `hub_downloads`, the models other than the speech models really download, from the hub `HF_ENDPOINT`
/// names into the Hugging Face cache (the token as a real download gets it), and the page's progress is the cache's.
/// Each try is recorded in `<probe>.fetched`. Autostart writes the real LaunchAgent under `PALAVER_HOME`.
public final class TestProbe: SetupProbe, @unchecked Sendable {
    public static let ENV = "PALAVER_TEST_PROBE"
    /// How long a held download waits for `<probe>.hold` to go.
    public static let HOLD_SECONDS = 60.0

    let file: URL
    let stores: StorePaths
    let hub: HubDownloader
    let token: () -> String?
    private let lock = NSLock()
    private var failed: [String] = []
    private var got: [String] = []
    public let downloads: SetupDownloads

    private final class Ref { weak var probe: TestProbe? }

    public init(file: URL, stores: StorePaths, env: [String: String] = [:], keys: KeyStore? = nil) {
        self.file = file
        self.stores = stores
        hub = HubDownloader(stores: stores, env: env)
        token = { keys.flatMap { Tokens.huggingFace(configToml: stores.configToml, env: env, keys: $0, home: stores.home) } }
        let ref = Ref()
        downloads = SetupDownloads(fetch: { m, _ in try ref.probe?.fetch(m) },
                                   progress: { ModelCatalog.downloadProgress($0, stores: stores) }, done: { _ in true },
                                   marker: stores.downloadingModels)
        ref.probe = self
    }

    /// The hold file: while it exists (and `hold_downloads` is set), downloads wait.
    public var holdFile: URL { URL(fileURLWithPath: file.path + ".hold") }

    /// The record of every download tried (FakeProbe's `fetched`): one model id per line, a failed try included, so a
    /// test outside this process can read what was fetched.
    public var fetchedFile: URL { URL(fileURLWithPath: file.path + ".fetched") }

    private func read() -> JSONValue { PythonJSON.read(file) ?? .object([]) }

    private func fetch(_ m: ModelInfo) throws {
        if read()["hold_downloads"]?.truthy == true {
            let deadline = Date().addingTimeInterval(Self.HOLD_SECONDS)
            while FileManager.default.fileExists(atPath: holdFile.path) && Date() < deadline { usleep(20_000) }
        }
        let failOnce = (read()["fail_once"]?.arrayValue ?? []).compactMap(\.stringValue)
        if read()["hub_downloads"]?.truthy == true && !Py.same(m.id, "speech") {
            lock.withLock { record(m.id) }
            try SetupDownloads.fetchFromHub(repo: ModelCatalog.repoFor(m), hub: hub, token: token)
            lock.withLock { if !got.contains(where: { Py.same($0, m.id) }) { got.append(m.id) } }
            return
        }
        try lock.withLock {
            record(m.id)
            if failOnce.contains(where: { Py.same($0, m.id) }) && !failed.contains(where: { Py.same($0, m.id) }) {
                failed.append(m.id)
                throw SetupDownloads.DownloadFailed(description: "connection reset")
            }
            if !got.contains(where: { Py.same($0, m.id) }) { got.append(m.id) }
        }
    }

    /// Appends `id` to `fetchedFile` (under `lock`).
    private func record(_ id: String) {
        let fd = open(fetchedFile.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let line = Array((id + "\n").utf8)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    public func hardware() -> Hardware {
        let hw = read()["hardware"]
        return Hardware(chip: hw?["chip"]?.stringValue ?? "Apple M4 Pro", memoryGB: hw?["memory_gb"]?.doubleValue ?? 48,
                        freeDiskGB: hw?["free_disk_gb"]?.doubleValue ?? 120)
    }

    public func installed() -> Installed {
        guard let i = read()["installed"] else { return Installed(teams: true, slack: false, claudeCode: true) }
        func flag(_ k: String) -> Bool { i[k]?.truthy ?? false }
        return Installed(teams: flag("teams"), slack: flag("slack"), claudeCode: flag("claude_code"),
                         claudeDesktop: flag("claude_desktop"))
    }

    public func permissions() -> PyDict<JSONValue> {
        if case .object(let given)? = read()["permissions"] { return PyDict(given) }
        func state(_ s: String, _ detail: String) -> JSONValue { .object([("state", .string(s)), ("detail", .string(detail))]) }
        return PyDict([
            ("microphone", state("granted", "allowed")),
            ("system_audio", state("unverified", "not verified yet")),
            ("calendar", state("not_asked", "not connected")),
            ("notifications", state("unknown", "Palaver can't check this itself")),
        ])
    }

    /// The file's `downloaded`, then what was fetched since (once each).
    public func downloaded() -> [String] {
        var out = (read()["downloaded"]?.arrayValue ?? []).compactMap(\.stringValue)
        for id in lock.withLock({ got }) where !out.contains(where: { Py.same($0, id) }) { out.append(id) }
        return out
    }

    public func fullName() -> String { read()["full_name"]?.stringValue ?? "Timo Strauss" }

    public func autostart() -> Bool { Autostart.isOn(stores) }

    public func setAutostart(_ on: Bool) throws { try Autostart.set(on, stores: stores) }

    /// The file's events that overlap the window, as EventKit answers.
    public func calendarEvents(_ start: Date, _ end: Date) throws -> [CalendarEvent] {
        (read()["events"]?.arrayValue ?? []).compactMap { try? CalendarEvent(json: $0) }
            .filter { $0.start.date < end && $0.end.date > start }
    }

    public func speechHere() -> Bool { downloaded().contains { Py.same($0, "speech") } }

    /// `$PALAVER_TEST_PROBE`'s probe, nil when it is not set.
    public static func fromEnvironment(_ env: [String: String], stores: StorePaths, keys: KeyStore? = nil) -> TestProbe? {
        guard let path = env[ENV], !path.isEmpty else { return nil }
        return TestProbe(file: URL(fileURLWithPath: path), stores: stores, env: env, keys: keys)
    }
}
#endif
