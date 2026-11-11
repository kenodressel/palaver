// Helpers of the setup assistant's suites: tests/test_onboarding.py's `lm_registry`, `with_transcription`, `current`, `recs`
// and the goldens of tools/parity/goldens.py's "setup" section (Fixtures/setup-goldens.json).
import CryptoKit
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

enum SetupFixtures {
    static let GEMMA = "mlx-community/gemma-4-12B-it-OptiQ-4bit"
    static let QWEN = "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"
    static let ALL_DOWNLOADED = ["speech", "gemma", "e5"]

    static func lmRegistry(ready: [String] = []) -> SetupRegistry {
        let lm = ["language_model"]
        return SetupRegistry(
            features: PyDict([("notes", "language_model"), ("projects", "language_model")]),
            providers: PyDict([
                ("anthropic", SetupProviderInfo(label: "Anthropic API", uses: lm, ready: ready.contains("anthropic"),
                                                problem: ready.contains("anthropic") ? nil : "Add the API key")),
                ("openai", SetupProviderInfo(label: "OpenAI-compatible", uses: lm, ready: ready.contains("openai"),
                                             problem: ready.contains("openai") ? nil : "Save the endpoint")),
                ("claude-cli", SetupProviderInfo(label: "Claude Code CLI", uses: lm, ready: ready.contains("claude-cli"),
                                                 problem: ready.contains("claude-cli") ? nil
                                                     : "Claude Code CLI (`claude`) not found")),
            ]))
    }

    /// #54 adds a transcription feature and its services to the same registry.
    static func withTranscription(_ reg: SetupRegistry, ready: [String] = []) -> SetupRegistry {
        let tr = ["transcription"]
        var features = reg.features, providers = reg.providers
        features["transcription"] = "transcription"
        providers["assemblyai"] = SetupProviderInfo(label: "AssemblyAI", uses: tr, ready: ready.contains("assemblyai"),
                                                    problem: ready.contains("assemblyai") ? nil : "Add the API key")
        providers["soniox"] = SetupProviderInfo(label: "Soniox", uses: tr, ready: ready.contains("soniox"),
                                                problem: ready.contains("soniox") ? nil : "Add the API key")
        return SetupRegistry(features: features, providers: providers)
    }

    static func current(settings: PyDict<Bool>? = nil, choices: PyDict<String>? = nil, localModel: String = GEMMA,
                        downloaded: [String] = ALL_DOWNLOADED, registry: SetupRegistry? = nil, mcp: PyDict<Bool>? = nil,
                        chosen: [String] = []) -> SetupCurrent {
        SetupCurrent(settings: settings ?? PyDict([("realtime", true), ("record_teams", true), ("record_slack", true),
                                                   ("live_processing", true), ("search_meaning", true)]),
                     choices: choices ?? PyDict([("notes", "local"), ("projects", "local")]), localModel: localModel,
                     downloaded: downloaded, registry: registry ?? lmRegistry(),
                     mcp: mcp ?? PyDict([("code", false), ("desktop", false)]), chosen: chosen)
    }

    static func recs(_ chip: String, _ memory: Double, disk: Double = 200, installed: Installed = Installed(),
                     _ cur: SetupCurrent? = nil) -> [String: Recommendation] {
        var out: [String: Recommendation] = [:]
        for r in Recommendations.recommend(Hardware(chip: chip, memoryGB: memory, freeDiskGB: disk), installed, cur ?? current()) {
            out[r.id] = r
        }
        return out
    }

    // MARK: - goldens

    /// Fixtures/setup-goldens.json.gz (tools/parity/goldens.py writes goldens past 100 KB gzip-compressed).
    static let golden: JSONValue = {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/setup-goldens.json.gz")
        guard let packed = try? Data(contentsOf: url), let data = gunzip(packed), let value = try? PythonJSON.parse(data) else {
            Issue.record("no golden \(url.path): the goldens are frozen, restore it from git")
            return .object([])
        }
        return value
    }()

    /// One gzip member's content (Python's `gzip.compress`: no name, comment or extra field); nil when it is not one.
    static func gunzip(_ packed: Data) -> Data? {
        let b = [UInt8](packed)
        guard b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8, b[3] == 0,
              let out = try? (Data(b[10..<(b.count - 8)]) as NSData).decompressed(using: .zlib) as Data else { return nil }
        let size = b[(b.count - 4)...].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return UInt32(truncatingIfNeeded: out.count) == size ? out : nil
    }

    static func list(_ key: String) -> [JSONValue] { golden[key]?.arrayValue ?? [] }

    static func num(_ v: JSONValue?) -> Double {
        switch v {
        case .int(let i)?: return Double(i)
        case .double(let d)?: return d
        default: return .nan
        }
    }

    static func int(_ v: JSONValue?) -> Int { if case .int(let i)? = v { return i }; return -1 }

    static func dumps(_ v: JSONValue) -> String { PythonJSON.dumps(v, ensureAscii: false) }

    static func strings(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap(\.stringValue) }

    static func installed(_ v: JSONValue?) -> Installed {
        Installed(teams: v?["teams"]?.boolValue ?? false, slack: v?["slack"]?.boolValue ?? false,
                  claudeCode: v?["claude_code"]?.boolValue ?? false, claudeDesktop: v?["claude_desktop"]?.boolValue ?? false)
    }

    static func pyDict(_ v: JSONValue?) -> PyDict<JSONValue> { v.flatMap { PyDict<JSONValue>($0) } ?? PyDict() }

    static func registry(_ v: JSONValue?) -> SetupRegistry {
        var features = PyDict<String>(), providers = PyDict<SetupProviderInfo>()
        for (k, f) in pyDict(v?["features"]) { features[k] = f.stringValue }
        for (k, p) in pyDict(v?["providers"]) {
            let a = p.arrayValue ?? []
            providers[k] = SetupProviderInfo(label: a[0].stringValue!, uses: strings(a[1]), ready: a[2].boolValue!,
                                             problem: a[3].stringValue)
        }
        return SetupRegistry(features: features, providers: providers)
    }

    static func current(_ v: JSONValue?) -> SetupCurrent {
        var settings = PyDict<Bool>(), choices = PyDict<String>(), mcp = PyDict<Bool>()
        for (k, b) in pyDict(v?["settings"]) { settings[k] = b.boolValue }
        for (k, c) in pyDict(v?["choices"]) { choices[k] = c.stringValue }
        for (k, b) in pyDict(v?["mcp"]) { mcp[k] = b.boolValue }
        return SetupCurrent(settings: settings, choices: choices, localModel: v?["local_model"]?.stringValue ?? "",
                            downloaded: strings(v?["downloaded"]), registry: registry(v?["registry"]), mcp: mcp,
                            chosen: strings(v?["chosen"]))
    }

    static func currents() -> [SetupCurrent] { list("currents").map { current($0) } }

    static func hardware(_ v: JSONValue?) -> Hardware {
        let a = v?.arrayValue ?? []
        return Hardware(chip: a[0].stringValue ?? "", memoryGB: num(a[1]), freeDiskGB: a.count > 2 ? num(a[2]) : 1)
    }

    static func checks(_ list: [SetupCheck]) -> JSONValue {
        .array(list.map { .array([.string($0.name), .string($0.status), .string($0.detail), .string($0.fix)]) })
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A Mac for the setup assistant's tests (tests/fake_probe.py `FakeProbe`): what it detects is given, its downloads are
/// fakes. Nothing here looks at the real Mac or downloads a model.
final class FakeProbe: SetupProbe, @unchecked Sendable {
    private final class Ref { weak var probe: FakeProbe? }

    private let lock = NSLock()
    var hw: Hardware
    var inst: Installed
    var perms: PyDict<JSONValue>
    var name: String
    var events: [CalendarEvent] = []
    private var have: [String]
    private var fetchedIDs: [String] = []
    private var failOnceIDs: [String] = []
    private var autostartOn = false
    /// Downloads wait here while it is closed (`fetch_gate`).
    let gate = DispatchSemaphore(value: 0)
    private var gateOpen = true
    let downloads: SetupDownloads

    init(hardware: Hardware = Hardware(chip: "Apple M4 Pro", memoryGB: 48, freeDiskGB: 120),
         installed: Installed = Installed(teams: true, slack: false, claudeCode: true), downloaded: [String] = [],
         permissions: PyDict<JSONValue>? = nil, fullName: String = "Timo Strauss") {
        hw = hardware
        inst = installed
        have = downloaded
        func state(_ s: String, _ detail: String) -> JSONValue { .object([("state", .string(s)), ("detail", .string(detail))]) }
        perms = permissions ?? PyDict([("microphone", state("granted", "allowed")),
                                       ("system_audio", state("unverified", "not verified yet")),
                                       ("calendar", state("not_asked", "not connected")),
                                       ("notifications", state("unknown", "Palaver can't check this itself"))])
        name = fullName
        let ref = Ref()
        downloads = SetupDownloads(fetch: { m, _ in try ref.probe?.fetch(m) }, progress: { _ in 0 }, done: { _ in true })
        ref.probe = self
    }

    var fetched: [String] { lock.withLock { fetchedIDs } }
    var failOnce: [String] {
        get { lock.withLock { failOnceIDs } }
        set { lock.withLock { failOnceIDs = newValue } }
    }

    /// Closes the gate: downloads wait until `release()`.
    func hold() { lock.withLock { gateOpen = false } }
    func release() {
        lock.withLock { gateOpen = true }
        for _ in 0..<16 { gate.signal() }
    }

    private func fetch(_ m: ModelInfo) throws {
        if !lock.withLock({ gateOpen }) { _ = gate.wait(timeout: .now() + 10) }
        try lock.withLock {
            fetchedIDs.append(m.id)
            if let i = failOnceIDs.firstIndex(where: { Py.same($0, m.id) }) {
                failOnceIDs.remove(at: i)
                throw SetupDownloads.DownloadFailed(description: "connection reset")
            }
            if !have.contains(where: { Py.same($0, m.id) }) { have.append(m.id) }
        }
    }

    func hardware() -> Hardware { hw }
    func installed() -> Installed { inst }
    func permissions() -> PyDict<JSONValue> { perms }
    func downloaded() -> [String] { lock.withLock { have } }
    func forget(_ id: String) { lock.withLock { have.removeAll { Py.same($0, id) } } }
    /// `_downloaded.add(id)`.
    func add(_ id: String) { lock.withLock { if !have.contains(where: { Py.same($0, id) }) { have.append(id) } } }
    func fullName() -> String { name }
    func autostart() -> Bool { lock.withLock { autostartOn } }
    func setAutostart(_ on: Bool) throws { lock.withLock { autostartOn = on } }
    func calendarEvents(_ start: Date, _ end: Date) throws -> [CalendarEvent] {
        events.filter { $0.start.date < end && $0.end.date > start }
    }
    func speechHere() -> Bool { downloaded().contains { Py.same($0, "speech") } }
}
