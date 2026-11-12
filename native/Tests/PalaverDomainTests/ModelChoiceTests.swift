// tests/test_llm.py's choice tests: which language model runs a feature. Local by default, a cloud provider only when
// the user chose it, never for a meeting kept on this Mac. The engines and their runners are not here (the choice's
// read side only); a choice is saved by writing settings.json's "engines" as providers.choose does.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

private struct Place {
    let t = TempFolder("model-choice")
    var stores: StorePaths {
        StorePaths(configDir: t.url.appendingPathComponent("config/palaver", isDirectory: true),
                   home: t.url.appendingPathComponent("home", isDirectory: true),
                   hubCache: t.url.appendingPathComponent("hub", isDirectory: true))
    }
    func remove() { t.remove() }

    /// providers.choose without its checks: settings.json's "engines" with `feature` set.
    func choose(_ feature: String, _ value: JSONValue) throws {
        var engines: [(String, JSONValue)] = []
        if case .object(let fields)? = SettingsFile.readRaw(stores: stores)["engines"] { engines = fields }
        engines.removeAll { $0.0 == feature }
        engines.append((feature, value))
        try SettingsFile.update([("engines", .object(engines))], stores: stores)
    }

    func meeting(_ name: String) -> URL {
        let folder = t.url.appendingPathComponent(name, isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// tests/test_llm.py's `cfg(**kw)`: notes local, the local model "repo/x".
private func cfg(engine: String = "local", localModel: String = "repo/x", model: String = "sonnet") -> Config {
    var c = Config()
    c.notesEngine = engine
    c.notesLocalModel = localModel
    c.notesModel = model
    return c
}

private let GEMMA = "mlx-community/gemma-4-12B-it-OptiQ-4bit"

@Suite struct ModelChoiceTests {
    @Test func test_local_by_default() {
        let place = Place(); defer { place.remove() }
        #expect(ModelChoice.choiceFor(feature: "notes", config: cfg(), stores: place.stores) == "local")
        #expect(ModelChoice.localModel(config: cfg(), stores: place.stores) == "repo/x")
        #expect(ModelChoice.choiceFor(feature: "projects", config: cfg(), stores: place.stores) == "local")
    }

    @Test func test_config_toml_claude_still_means_the_claude_cli() throws {
        let place = Place(); defer { place.remove() }
        let c = cfg(engine: "claude", model: "opus")
        #expect(ModelChoice.choiceFor(feature: "notes", config: c, stores: place.stores) == "claude-cli")
        let settings = try ModelChoice.settingsOf("claude-cli", defaults: ModelChoice.providerDefaults(config: c, pid: "claude-cli"),
                                                  stores: place.stores)
        #expect(settings["model"] == .string("opus"))
        #expect(ModelChoice.label(choice: "claude-cli") == "Claude Code CLI")
    }

    @Test func test_a_meeting_kept_on_this_mac_overrides_the_cloud() throws {
        let place = Place(); defer { place.remove() }
        try place.choose("notes", .string("anthropic"))
        let meeting = place.meeting("m")
        try LocalOnly.set(meeting, on: true)
        #expect(LocalOnly.isLocalOnly(meeting))
        #expect(ModelChoice.choiceFor(feature: "notes", folders: [meeting], config: cfg(), stores: place.stores) == "local")
        try LocalOnly.set(meeting, on: false)
        #expect(!LocalOnly.isLocalOnly(meeting))
        #expect(ModelChoice.choiceFor(feature: "notes", folders: [meeting], config: cfg(), stores: place.stores) == "anthropic")
    }

    @Test func test_local_model_from_settings() throws {
        let place = Place(); defer { place.remove() }
        try SettingsFile.update([("local_model", .string(GEMMA))], stores: place.stores)  // llm.choose_local_model's write
        #expect(ModelChoice.localModel(config: cfg(), stores: place.stores) == GEMMA)
        for gone in ["evil/model", "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"] {
            #expect(!ModelChoice.LOCAL_MODELS.contains { Py.same($0.0, gone) })  // what choose_local_model refuses
        }
    }

    @Test func test_qwen_chosen_before_falls_back_to_the_default() throws {
        let place = Place(); defer { place.remove() }
        try SettingsFile.update([("local_model", .string("mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"))], stores: place.stores)
        #expect(ModelChoice.localModel(config: cfg(), stores: place.stores) == cfg().notesLocalModel)
        #expect(ModelChoice.localModel(config: Config(), stores: place.stores) == GEMMA)
    }

    @Test func test_notes_memory_follows_the_choice_and_the_meeting() throws {
        let place = Place(); defer { place.remove() }
        try place.choose("notes", .string("anthropic"))
        let c = cfg(localModel: GEMMA)
        let meeting = place.meeting("m")
        #expect(ModelChoice.memoryGB(feature: "notes", config: c, stores: place.stores) == 0.0)  // Anthropic chosen: nothing to load here
        #expect(ModelChoice.memoryGB(feature: "notes", folder: meeting, config: c, stores: place.stores) == 0.0)
        try LocalOnly.set(meeting, on: true)
        #expect(ModelChoice.memoryGB(feature: "notes", folder: meeting, config: c, stores: place.stores) == 14.0)
        try place.choose("notes", .string("local"))
        #expect(ModelChoice.memoryGB(feature: "notes", config: c, stores: place.stores) == 14.0)
        // Chosen in Settings, local wins over config.toml's claude; never chosen, config.toml decides.
        #expect(ModelChoice.memoryGB(feature: "notes", config: cfg(engine: "claude", localModel: GEMMA), stores: place.stores) > 0)
        try SettingsFile.update([("engines", .object([]))], stores: place.stores)
        #expect(ModelChoice.memoryGB(feature: "notes", config: cfg(engine: "claude"), stores: place.stores) == 0.0)
    }

    @Test func aNotesRunNeedsTheMostOfItsNotesAndProjectsModels() throws {
        let place = Place(); defer { place.remove() }
        let c = cfg(localModel: GEMMA)
        #expect(ModelChoice.notesRunMemoryGB(config: c, stores: place.stores) == 14.0)  // both local
        try place.choose("notes", .string("claude-cli"))
        #expect(ModelChoice.memoryGB(feature: "notes", config: c, stores: place.stores) == 0.0)
        // Projects never chosen follow the notes: the sort no longer loads Gemma for cloud notes (#26).
        #expect(ModelChoice.choiceFor(feature: "projects", config: c, stores: place.stores) == "claude-cli")
        #expect(ModelChoice.notesRunMemoryGB(config: c, stores: place.stores) == 0.0)
        try place.choose("projects", .string("local"))  // chosen on purpose: kept
        #expect(ModelChoice.notesRunMemoryGB(config: c, stores: place.stores) == 14.0)
        try place.choose("projects", .string("anthropic"))
        #expect(ModelChoice.notesRunMemoryGB(config: c, stores: place.stores) == 0.0)  // nothing to load here
        let meeting = place.meeting("m")
        try LocalOnly.set(meeting, on: true)
        #expect(ModelChoice.notesRunMemoryGB(folder: meeting, config: c, stores: place.stores) == 14.0)  // kept here: local
        // config.toml's claude is both features' default.
        try SettingsFile.update([("engines", .object([]))], stores: place.stores)
        #expect(ModelChoice.notesRunMemoryGB(config: cfg(engine: "claude"), stores: place.stores) == 0.0)
    }

    @Test func test_notes_waiting_for_a_cloud_model_run_nothing() throws {
        let place = Place(); defer { place.remove() }
        try place.choose("notes", .string("pending"))
        #expect(ModelChoice.choiceFor(feature: "notes", config: Config(), stores: place.stores) == ModelChoice.PENDING)
        let meeting = place.meeting("m")
        try LocalOnly.set(meeting, on: true)
        #expect(ModelChoice.choiceFor(feature: "notes", folders: [meeting], config: Config(), stores: place.stores) == ModelChoice.PENDING)
        #expect(ModelChoice.memoryGB(feature: "notes", folder: meeting, config: Config(), stores: place.stores) == 0.0)  // nothing waits for memory
    }

    // MARK: - Swift only

    @Test func aSavedChoiceThatIsNoChoiceMeansLocal() throws {
        let place = Place(); defer { place.remove() }
        try place.choose("notes", .string("soniox"))  // a transcription service
        #expect(ModelChoice.choiceFor(feature: "notes", config: cfg(), stores: place.stores) == "local")
        try place.choose("notes", .int(5))
        #expect(ModelChoice.choiceFor(feature: "notes", config: cfg(), stores: place.stores) == "local")
        try place.choose("transcription", .string("pending"))  // pending is for language models only
        #expect(ModelChoice.choiceFor(feature: "transcription", config: cfg(), stores: place.stores) == "local")
        try place.choose("transcription", .string("soniox"))
        #expect(ModelChoice.choiceFor(feature: "transcription", config: cfg(), stores: place.stores) == "soniox")
        // The coach is chosen on its own: config.toml's claude is not its default.
        #expect(ModelChoice.choiceFor(feature: "coach", config: cfg(engine: "claude"), stores: place.stores) == "local")
        #expect(ModelChoice.defaultChoice(feature: "coach", config: cfg(engine: "claude")) == "local")
        #expect(ModelChoice.defaultChoice(feature: nil, config: cfg(engine: "claude")) == "claude-cli")
        try SettingsFile.update([("engines", .string("anthropic"))], stores: place.stores)
        #expect(ModelChoice.choiceFor(feature: "notes", config: cfg(engine: "claude"), stores: place.stores) == "claude-cli")
    }

    @Test func aLocalModelNotListedNeedsTheMostMemory() throws {
        let place = Place(); defer { place.remove() }
        #expect(ModelChoice.memoryGB(feature: "notes", config: cfg(), stores: place.stores) == ModelChoice.NOTES_MEMORY_GB)
        #expect(ModelChoice.NOTES_MEMORY_GB == 20.0)
        #expect(ModelChoice.notesMemoryGB("mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit") == 20.0)
        #expect(ModelChoice.notesMemoryGB(GEMMA) == 14.0)
    }

    @Test func settingsAreTheProvidersOwnUnlessSavedValuesPassTheChecks() throws {
        let place = Place(); defer { place.remove() }
        #expect(PythonJSON.dumps(try ModelChoice.settingsOf("openai", stores: place.stores).json)
                == #"{"model": "", "context_tokens": 128000, "auth": "auto", "endpoint": "https://api.openai.com/v1"}"#)
        #expect(PythonJSON.dumps(try ModelChoice.settingsOf("soniox", stores: place.stores).json)
                == #"{"model": "stt-async-v5", "context_tokens": 0, "region": "eu"}"#)
        let saved: JSONValue = .object([
            ("openai", .object([("endpoint", .string(" http://localhost:4000/v1 ")), ("model", .string("  gpt-x  ")),
                                ("context_tokens", .int(999)), ("auth", .string("bearer")), ("region", .string("us")),
                                ("api_key", .string("not read"))])),
            ("anthropic", .object([("endpoint", .string("http://api.example.com")), ("model", .string("a\nb")),
                                   ("context_tokens", .bool(true))])),
            ("soniox", .object([("region", .string("us")), ("context_tokens", .int(5000))])),
        ])
        try SettingsFile.update([("providers", saved)], stores: place.stores)
        #expect(PythonJSON.dumps(try ModelChoice.settingsOf("openai", stores: place.stores).json)
                == #"{"model": "gpt-x", "context_tokens": 128000, "auth": "bearer", "endpoint": "http://localhost:4000/v1"}"#)
        #expect(PythonJSON.dumps(try ModelChoice.settingsOf("anthropic", stores: place.stores).json)
                == #"{"model": "claude-opus-5-5", "context_tokens": 1000000, "endpoint": "https://api.anthropic.com"}"#)
        #expect(PythonJSON.dumps(try ModelChoice.settingsOf("soniox", stores: place.stores).json)
                == #"{"model": "stt-async-v5", "context_tokens": 5000, "region": "us"}"#)
        #expect { try ModelChoice.settingsOf("nope", stores: place.stores) } throws: { "\($0)" == "no provider 'nope'" }
    }

    @Test func anEndpointIsHttpsOrAGatewayOnThisMacOrTheLocalNetwork() {
        let good = ["https://api.example.com/v1", "http://localhost:4000", "http://127.0.0.1/v1", "http://[::1]:8080/v1",
                    "HTTPS://Example.COM", "https://@example.com", "https://[v1.x]/", "https://example.com/?q=1",
                    "http://llm.lan:8080/v1", "http://gpu-box.local:11434", "http://nas.home.arpa/v1", "http://192.168.1.20:1234"]
        let bad = ["http://example.com", "ftp://example.com", "https://user:pw@example.com", "https://user@example.com",
                   "https://example.com#frag", "https://[::1", "https://::1]", "https://[1.2.3.4]/", "https://[nope]/",
                   "https://x[::1]/", "https://[::1]x/", "example.com", "https:///path", "https://exa\u{2100}mple.com",
                   "http://gpu-box.corp:11434", "http://8.8.8.8/v1", "http://lan/", "http://user:pw@llm.lan/"]
        for url in good { #expect(ModelChoice.checkEndpoint(.string(url)) != nil, "\(url)") }
        for url in bad { #expect(ModelChoice.checkEndpoint(.string(url)) == nil, "\(url)") }
        #expect(ModelChoice.checkEndpoint(.int(1)) == nil)
        #expect(ModelChoice.endpointProblem(.string("http://api.example.com"))
                == "the endpoint must be an https:// URL (http:// only for a gateway on this Mac or your local network)")
    }

    /// Plain http:// goes only to this Mac, local-network names and private addresses (Keno's ruling after the final
    /// review); every public host stays https only.
    @Test(arguments: [
        ("localhost", true), ("LOCALHOST", true), ("127.0.0.1", true), ("127.8.9.10", true), ("::1", true),
        ("gpu-box.local", true), ("gpu-box.local.", true), ("llm.lan", true), ("a.b.lan", true), ("nas.home.arpa", true),
        ("10.0.0.1", true), ("10.255.255.255", true), ("172.16.0.1", true), ("172.31.255.254", true),
        ("192.168.0.1", true), ("192.168.255.255", true),
        ("fc00::1", true), ("fd12:3456::1", true), ("fe80::1", true), ("fe80::1%en0", true), ("febf::1", true),
        // public, or just outside a range
        ("example.com", false), ("llm.corp", false), ("local", false), (".local", false), ("lan", false), ("home.arpa", false),
        ("evil-local", false), ("mylan", false), ("example.lan.com", false),
        ("9.255.255.255", false), ("11.0.0.1", false), ("172.15.255.255", false), ("172.32.0.1", false),
        ("192.167.1.1", false), ("192.169.0.1", false), ("8.8.8.8", false), ("169.254.1.1", false), ("100.64.0.1", false),
        ("fbff::1", false), ("fec0::1", false), ("2001:db8::1", false), ("::", false), ("::2", false), ("::ffff:10.0.0.1", false),
        ("10.0.0", false), ("1.2.3.4.5", false), ("", false),
    ])
    func whichHostsPlainHttpMayReach(_ host: String, _ local: Bool) {
        #expect(ModelChoice.isLocalNetwork(host) == local, "\(host)")
    }

    @Test func theProvidersAndFeaturesArePythons() {
        #expect(ModelChoice.providers.map(\.id) == ["anthropic", "openai", "claude-cli", "assemblyai", "soniox", "mistral",
                                                    "openai-transcribe"])
        #expect(ModelChoice.providerLabels.keys == ModelChoice.providers.map(\.id))
        #expect(ModelChoice.providerLabels["openai-transcribe"] == "OpenAI-compatible transcription")
        #expect(ModelChoice.label(choice: "local") == nil)
        #expect(ModelChoice.forFeature("notes") == ["anthropic", "openai", "claude-cli"])
        #expect(ModelChoice.forFeature("transcription") == ["assemblyai", "soniox", "mistral", "openai-transcribe"])
        #expect(ModelChoice.forFeature("nope") == ["anthropic", "openai", "claude-cli"])
        #expect(ModelChoice.features.map(\.id) == ["notes", "projects", "coach", "transcription"])
        #expect(ModelChoice.LOCAL_MODELS.map(\.0) == [GEMMA] && ModelChoice.LOCAL_MODELS[0].1.contextTokens == 131_072)
    }
}
