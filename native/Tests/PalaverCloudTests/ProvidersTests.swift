// The providers' settings, keys, readiness and choices (tests/test_providers.py's behaviours), the engine each feature
// gets and the context check (tests/test_llm.py's), and the access log (tests/test_access_log.py's).
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverCloud

private func refusal(_ work: () throws -> Void) -> String? { (thrown(work) as? SettingRefused)?.text }

@Suite struct ProviderSettingsTests {
    @Test func defaults() throws {
        let s = Home().settings
        let a = try s.settingsOf("anthropic")
        #expect(a["endpoint"] == .string("https://api.anthropic.com") && a["model"] == .string("claude-opus-5-5"))
        let o = try s.settingsOf("openai")
        #expect(o["endpoint"] == .string("https://api.openai.com/v1") && o["model"] == .string("") && o["auth"] == .string("auto"))
        #expect(try s.settingsOf("claude-cli")["model"] == .string("sonnet"))
        #expect(try s.settingsOf("claude-cli", defaults: PyDict([("model", .string("opus"))]))["model"] == .string("opus"))
    }

    @Test func configureSavesBesideTheOtherSettings() throws {
        let home = Home()
        let s = home.settings
        try SettingsFile.update([("realtime", .bool(false))], stores: home.stores)
        try s.configure("openai", [("endpoint", .string(" https://acme.openai.azure.com/openai/v1 ")), ("model", .string(" gpt-x ")),
                                   ("context_tokens", .int(200_000))])
        let saved = try s.settingsOf("openai")
        #expect(saved["endpoint"] == .string("https://acme.openai.azure.com/openai/v1") && saved["model"] == .string("gpt-x")
                && saved["context_tokens"] == .int(200_000))
        try s.configure("openai", [("model", .string("gpt-y"))])  // only what is given changes
        #expect(try s.settingsOf("openai")["endpoint"] == .string("https://acme.openai.azure.com/openai/v1"))
        #expect(home.saved["realtime"] == .bool(false) && home.saved["providers"]?["openai"]?["model"] == .string("gpt-y"))
    }

    @Test(arguments: ["ftp://x.test", "javascript:alert(1)", "api.openai.com", "", "http://api.openai.com/v1",
                      "https://user:secret@gateway.test/v1", "https://", "https://gw.test/v1#frag"])
    func badEndpointsAreRefused(_ endpoint: String) {
        let home = Home()
        #expect(refusal { try home.settings.configure("openai", [("endpoint", .string(endpoint))]) } != nil)
        #expect(home.saved["providers"] == nil)  // nothing saved
    }

    @Test func theRefusalsSayWhatIsWrong() {
        let s = Home().settings
        #expect(refusal { try s.configure("openai", [("endpoint", .string("https://u:p@gw.test/v1"))]) }
                == "put the key in the key field, not in the endpoint")
        #expect(refusal { try s.configure("openai", [("endpoint", .string("https://gw.test/v1#x"))]) }
                == "the endpoint must not have a #fragment")
        #expect(refusal { try s.configure("openai", [("endpoint", .int(3))]) } == "the endpoint must be a URL")
    }

    @Test(arguments: ["http://localhost:11434/v1", "http://127.0.0.1:8000/v1", "https://gw.test/v1?x=1"])
    func localHTTPGatewaysAndQueriesAreTaken(_ endpoint: String) throws {
        let s = Home().settings
        try s.configure("openai", [("endpoint", .string(endpoint))])
        #expect(try s.settingsOf("openai")["endpoint"] == .string(endpoint))
    }

    @Test func badValuesAreRefused() {
        let s = Home().settings
        let bad: [(String, JSONValue)] = [("model", .string("")), ("model", .string("a\nb")), ("model", .string(String(repeating: "x", count: 300))),
                                          ("model", .int(5)), ("context_tokens", .int(10)), ("context_tokens", .string("lots")),
                                          ("context_tokens", .bool(true)), ("context_tokens", .int(1_000_000_000))]
        for change in bad {
            #expect(refusal { try s.configure("anthropic", [change]) } != nil, "\(change)")
        }
    }

    @Test func unknownProvidersAndFieldsAreRefused() {
        let s = Home().settings
        #expect(refusal { try s.configure("nope", [("model", .string("x"))]) } == "no provider 'nope'")
        #expect(refusal { try s.configure("claude-cli", [("endpoint", .string("https://x.test"))]) } == "Claude Code CLI has no setting 'endpoint'")
        #expect(refusal { try s.configure("anthropic", [("auth", .string("bearer"))]) } != nil)  // only OpenAI-compatible ones have it
        #expect(refusal { try s.configure("openai", [("auth", .string("cookie"))]) } == "the key header must be one of auto, bearer, api-key")
        #expect(refusal { try s.configure("assemblyai", [("region", .string("mars"))]) } == "the region must be one of eu, us")
    }

    @Test func keysLiveInTheKeyStoreOnly() throws {
        let home = Home()
        let s = home.settings
        try s.configure("anthropic", [("model", .string("claude-sonnet-5-5"))])
        try s.setKey("anthropic", .string("  \(KEY)\n"))
        #expect(home.keychain == ["anthropic.api_key": KEY])
        #expect(s.hasKey("anthropic") && s.apiKey("anthropic") == KEY)
        #expect(!(try String(contentsOf: home.stores.settings, encoding: .utf8)).contains(KEY))
        let view = JSONValue.object(try s.publicView("anthropic"))
        #expect(view["key_set"] == .bool(true) && !PythonJSON.dumps(view).contains(KEY))
        try s.removeKey("anthropic")
        #expect(home.keychain.isEmpty)
        #expect(JSONValue.object(try s.publicView("anthropic"))["key_set"] == .bool(false))
    }

    @Test func noKeyForTheCLIAndNoKeyThatIsNone() {
        let s = Home().settings
        #expect(refusal { try s.setKey("claude-cli", .string(KEY)) } == "Claude Code CLI takes no API key")
        #expect(refusal { try s.setKey("anthropic", .int(3)) } == "that is not an API key")
        #expect(refusal { try s.setKey("anthropic", .string("two\nlines \(KEY)")) }.map { !$0.contains(KEY) } == true)
    }

    @Test func aFailingKeychainNeverShowsTheKey() throws {
        let home = Home()
        let broken = BrokenKeyStore()
        let s = ProviderSettings(config: home.config, stores: home.stores, keys: broken, env: home.env)
        let said = refusal { try s.setKey("anthropic", .string(KEY)) }
        #expect(said == "could not save anthropic.api_key in the Keychain")
        #expect(s.apiKey("anthropic") == nil && broken.reads == 1)  // read failed: no key, no error text
        #expect(refusal { try s.removeKey("anthropic") } == "could not remove anthropic.api_key from the Keychain")
    }

    @Test func presenceChecksNeverReadTheSecret() throws {
        let home = Home()
        let keys = CountingKeyStore(["anthropic.api_key": KEY, "assemblyai.api_key": "aai-x"])
        let s = ProviderSettings(config: home.config, stores: home.stores, keys: keys, env: home.env)
        _ = try s.registry()
        for pid in ModelChoice.providers.map(\.id) { _ = try s.publicView(pid) }
        #expect(keys.reads.isEmpty)
    }

    @Test func problemSaysWhatIsMissing() throws {
        let home = Home()
        var s = home.settings
        #expect(try s.problem("anthropic")?.contains("API key") == true)
        try home.keys.write("anthropic.api_key", KEY)
        #expect(try s.problem("anthropic") == nil)
        #expect(try s.problem("openai")?.contains("model") == true)
        try s.configure("openai", [("model", .string("gpt-x"))])
        #expect(try s.problem("openai")?.contains("endpoint") == true)  // the default endpoint is not a choice
        try s.configure("openai", [("endpoint", .string("http://localhost:11434/v1"))])
        #expect(try s.problem("openai") == nil)  // a gateway on this Mac may need no key
        #expect(try s.problem("claude-cli")?.contains("Claude Code") == true)
        let claude = home.dir.appendingPathComponent("claude")
        try "#!/bin/sh\n".write(to: claude, atomically: true, encoding: .utf8)
        chmod(claude.path, 0o755)
        home.config.claudePath = claude.path
        s = home.settings
        #expect(try s.problem("claude-cli") == nil)
    }

    @Test func thePublicView() throws {
        let s = Home().settings
        let view = JSONValue.object(try s.publicView("openai"))
        #expect(view["id"] == .string("openai") && view["label"]?.truthy == true && view["sends_to"]?.truthy == true)
        #expect(view["key"] == .string("optional") && view["key_set"] == .bool(false) && view["ready"] == .bool(false))
        #expect(view["problem"]?.truthy == true && view["has_endpoint"] == .bool(true) && view["auth"] == .string("auto"))
        #expect(JSONValue.object(try s.publicView("claude-cli"))["key"] == .string("none"))
        let soniox = JSONValue.object(try s.publicView("soniox"))
        #expect(soniox["usd_per_hour"] == .double(0.10) && soniox["region"] == .string("eu") && soniox["privacy"]?.truthy == true)
    }

    @Test func theChoiceDefaultsToWhatConfigTomlSays() {
        let s = Home().settings
        #expect(s.choice("notes", default: "local") == "local" && s.choice("notes", default: "claude-cli") == "claude-cli")
    }

    @Test func chooseNeedsAReadyProvider() throws {
        let home = Home()
        let s = home.settings
        #expect(refusal { try s.choose("notes", .string("anthropic")) } == "Anthropic API: Add the API key")
        #expect(home.saved["engines"] == nil)
        try home.keys.write("anthropic.api_key", KEY)
        try s.choose("notes", .string("anthropic"))
        #expect(s.choice("notes", default: "local") == "anthropic")
        #expect(s.choice("projects", default: "local") == "local")  // each feature is chosen on its own
        try s.choose("notes", .string("local"))
        #expect(s.choice("notes", default: "claude-cli") == "local")
        try s.choose("coach", .string("pending"))  // waiting for a cloud model: nothing to check
        #expect(s.choice("coach", default: "local") == "pending")
    }

    @Test func chooseRefusesUnknownFeaturesAndValues() {
        let s = Home().settings
        #expect(refusal { try s.choose("notes", .string("nope")) } == "no language model 'nope'")
        #expect(refusal { try s.choose("weather", .string("local")) } == "no feature 'weather'")
        #expect(refusal { try s.choose("notes", .int(3)) } == "no language model 3")
        #expect(refusal { try s.choose("transcription", .string("anthropic")) } == "no transcription service 'anthropic'")
        #expect(refusal { try s.choose("transcription", .string("pending")) } != nil)  // pending is for language models
    }

    @Test func aGarbledChoiceMeansLocal() throws {
        let home = Home()
        let s = home.settings
        try SettingsFile.update([("engines", .object([("notes", .string("evil-cloud")), ("projects", .int(7))]))], stores: home.stores)
        #expect(s.choice("notes", default: "claude-cli") == "local" && s.choice("projects", default: "claude-cli") == "local")
        try SettingsFile.update([("engines", .string("x"))], stores: home.stores)
        #expect(s.choice("notes", default: "local") == "local")
    }

    @Test func garbledProviderSettingsFallBackToTheDefaults() throws {
        let home = Home()
        try SettingsFile.update([("providers", .object([("openai", .object([("endpoint", .string("ftp://x")), ("model", .int(3)),
                                                                             ("context_tokens", .string("x"))]))]))], stores: home.stores)
        let o = try home.settings.settingsOf("openai")
        #expect(o["endpoint"] == .string("https://api.openai.com/v1") && o["model"] == .string("") && o["context_tokens"] == .int(128_000))
        // configure keeps what it does not touch, garbled or not
        try home.settings.configure("openai", [("model", .string("gpt-x"))])
        #expect(home.saved["providers"]?["openai"]?["endpoint"] == .string("ftp://x"))
    }

    // MARK: an OpenAI-compatible provider sends nothing until it is fully set up

    @Test func aRemoteEndpointWithoutAKeyIsNotReady() throws {
        let s = Home().settings
        try s.configure("openai", [("endpoint", .string("https://api.openai.com/v1")), ("model", .string("gpt-x"))])
        #expect(try s.problem("openai") == "Add the API key")
        #expect(refusal { try s.choose("notes", .string("openai")) }?.contains("API key") == true)
        try s.setKey("openai", .string("sk-proj-test-0123456789"))
        #expect(try s.problem("openai") == nil)
        try s.choose("notes", .string("openai"))
    }

    @Test func aKeyAndAModelWithoutASavedEndpointIsNotReady() throws {
        let s = Home().settings
        try s.setKey("openai", .string("sk-proj-test-0123456789"))
        try s.configure("openai", [("model", .string("gpt-x"))])
        #expect(try s.problem("openai") == "Save the endpoint")
        #expect(refusal { try s.choose("notes", .string("openai")) }?.contains("endpoint") == true)
    }

    @Test func anAzureKeyWithTheDefaultEndpointIsNotReady() throws {
        let s = Home().settings
        try s.setKey("openai", .string("0123456789abcdef0123456789abcdef"))
        try s.configure("openai", [("model", .string("gpt-4o-deployment")), ("auth", .string("api-key"))])  // "Azure" picked
        #expect(try s.problem("openai")?.contains("Azure") == true)
        try s.configure("openai", [("endpoint", .string("https://api.openai.com/v1"))])  // saved, but not the tenant's
        #expect(try s.problem("openai")?.contains("Azure") == true)
        try s.configure("openai", [("endpoint", .string("https://acme.openai.azure.com/openai/v1"))])
        #expect(try s.problem("openai") == nil)
    }

    @Test(arguments: ["https://openai.azure.com/openai/v1", "https://.openai.azure.com/v1"])
    func anAzureEndpointMustNameTheTenant(_ endpoint: String) throws {
        let s = Home().settings
        try s.setKey("openai", .string("0123456789abcdef0123456789abcdef"))
        try s.configure("openai", [("model", .string("gpt-x"))])
        guard (try? s.configure("openai", [("endpoint", .string(endpoint))])) != nil else { return }  // refused outright is fine
        #expect(try s.problem("openai")?.contains("Azure") == true)
    }

    @Test(arguments: ["http://localhost:11434/v1", "https://127.0.0.1:8443/v1", "http://127.0.0.1:8000/v1"])
    func theKeyIsOptionalOnlyOnThisMac(_ endpoint: String) throws {
        let s = Home().settings
        try s.configure("openai", [("endpoint", .string(endpoint)), ("model", .string("llama"))])
        #expect(try s.problem("openai") == nil)
    }

    @Test func theRegistry() throws {
        let home = Home()
        try home.keys.write("anthropic.api_key", KEY)
        let s = home.settings
        try s.choose("notes", .string("anthropic"))
        let reg = try s.registry()
        let providers = reg["providers"]?.arrayValue ?? []
        #expect(providers.compactMap { $0["id"]?.stringValue } == ["anthropic", "openai", "claude-cli", "assemblyai", "soniox",
                                                                     "mistral", "openai-transcribe"])
        #expect(providers[0]["uses"] == .strings(["language_model"]) && providers[0]["ready"] == .bool(true))
        #expect(providers[3]["uses"] == .strings(["transcription"]) && providers[3]["ready"] == .bool(false))
        let features = reg["features"]?.arrayValue ?? []
        #expect(features.compactMap { $0["id"]?.stringValue } == ["notes", "projects", "coach", "transcription"])
        #expect(features[0]["choice"] == .string("anthropic") && features[0]["ready"] == .bool(true) && features[0]["own"] == .bool(false))
        #expect(features[2]["own"] == .bool(true) && features[2]["default"] == .string("local"))
        #expect(features[3]["uses"] == .string("transcription") && features[3]["default"] == .string("local"))
        #expect(!PythonJSON.dumps(reg).contains(KEY))
    }
}

@Suite struct EngineChoiceTests {
    @Test func localByDefault() {
        let s = Home().settings
        #expect(EngineChoice.for(feature: "notes", settings: s) == .local(model: ModelChoice.DEFAULT_LOCAL_MODEL))
    }

    @Test func configTomlClaudeMeansTheCLIAndItsAbsenceIsSaid() throws {
        let home = Home()
        home.config.notesEngine = "claude"
        var e = EngineChoice.for(feature: "notes", settings: home.settings)
        #expect(e == .unavailable("Claude Code CLI: Claude Code CLI (`claude`) not found on this Mac. Change it in Settings → Language model."))
        let claude = home.dir.appendingPathComponent("claude")
        try "#!/bin/sh\n".write(to: claude, atomically: true, encoding: .utf8)
        chmod(claude.path, 0o755)
        home.config.claudePath = claude.path
        e = EngineChoice.for(feature: "notes", settings: home.settings)
        #expect(e == .claudeCLI)
        #expect(EngineChoice.for(feature: "coach", settings: home.settings) == .local(model: ModelChoice.DEFAULT_LOCAL_MODEL))  // own
    }

    @Test func noSilentFallbackWhenTheChosenProviderIsNotReady() throws {
        let home = Home()
        try home.keys.write("anthropic.api_key", KEY)
        try home.settings.choose("notes", .string("anthropic"))
        #expect(EngineChoice.for(feature: "notes", settings: home.settings) == .cloud(provider: "anthropic"))
        try home.keys.delete("anthropic.api_key")
        #expect(EngineChoice.for(feature: "notes", settings: home.settings)
                == .unavailable("Anthropic API: Add the API key. Change it in Settings → Language model."))
    }

    @Test func aMeetingKeptOnThisMacOverridesTheCloud() throws {
        let home = Home()
        try home.keys.write("anthropic.api_key", KEY)
        try home.settings.choose("notes", .string("anthropic"))
        let meeting = home.dir.appendingPathComponent("Recordings/2026-11-08T10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        try "{}".write(to: RecordingPaths(meeting).localOnly, atomically: true, encoding: .utf8)
        #expect(LocalOnly.isLocalOnly(meeting))
        #expect(EngineChoice.for(feature: "notes", meetings: [meeting], settings: home.settings) == .local(model: ModelChoice.DEFAULT_LOCAL_MODEL))
        #expect(EngineChoice.for(feature: "projects", meetings: [meeting], settings: home.settings) == .local(model: ModelChoice.DEFAULT_LOCAL_MODEL))
    }

    @Test func pendingRunsNothing() throws {
        let home = Home()
        try home.settings.choose("notes", .string("pending"))
        #expect(EngineChoice.for(feature: "notes", settings: home.settings) == .unavailable(EngineChoice.PENDING_TEXT))
    }

    @Test func tooLongForTheContextWindowIsRefusedNeverCut() throws {
        let home = Home()
        try home.keys.write("anthropic.api_key", KEY)
        try home.settings.configure("anthropic", [("context_tokens", .int(40_000))])
        let e = EngineChoice.cloud(provider: "anthropic")
        try ContextCheck.fits(chars: 3 * 8_000, engine: e, settings: home.settings)  // 8 000 + 32 000 reserve = 40 000
        let refused = thrown { try ContextCheck.fits(chars: 3 * 8_000 + 1, engine: e, settings: home.settings) } as? ContextTooLong
        #expect(refused?.message == "This is about 8,001 tokens, and Anthropic API (claude-opus-5-5) reads at most 40,000 with room "
                + "for its answer. Choose a model with a larger context window. Change it in Settings → Language model.")
    }

    @Test func theLocalModelHasAContextWindowToo() {
        let s = Home().settings
        let local = EngineChoice.local(model: ModelChoice.DEFAULT_LOCAL_MODEL)
        #expect(thrown { try ContextCheck.fits(chars: 3 * (131_072 - 4096), engine: local, settings: s) } == nil)
        #expect(thrown { try ContextCheck.fits(chars: 3 * (131_072 - 4096) + 1, engine: local, settings: s) } is ContextTooLong)
        #expect(ContextCheck.reserve(.claudeCLI) == 0 && ContextCheck.estimateTokens(chars: 10) == 4)  // on the high side
    }
}

@Suite struct AccessLogTests {
    @Test func recordAndReadBackNewestFirst() throws {
        let home = Home()
        try AccessLog.record(.init(provider: "anthropic", host: "api.anthropic.com", model: "claude-opus-5-5", feature: "notes",
                                   meetings: ["2026-10-27T16-03-07"], chars: 12_345, ok: true, seconds: 12.34), stores: home.stores)
        try AccessLog.record(.init(provider: "openai", host: "acme.openai.azure.com", model: "gpt-x", feature: "projects",
                                   meetings: ["a", "b"], chars: 900, ok: false, seconds: 3, error: "HTTP 503"), stores: home.stores)
        let entries = AccessLog.recent(stores: home.stores)
        #expect(entries.compactMap { $0["provider"]?.stringValue } == ["openai", "anthropic"])
        let first = entries[1]
        #expect(first["host"] == .string("api.anthropic.com") && first["feature"] == .string("notes"))
        #expect(first["meetings"] == .strings(["2026-10-27T16-03-07"]) && first["chars"] == .int(12_345))
        #expect(first["ok"] == .bool(true) && first["seconds"] == .double(12.3) && first["error"] == nil)
        #expect(first["time"]?.stringValue.flatMap(AccessLog.parseISO) != nil)  // ISO time with the offset
        #expect(entries[0]["error"] == .string("HTTP 503"))
        if case .object(let fields) = first {
            #expect(fields.map(\.0) == ["time", "provider", "host", "model", "feature", "meetings", "chars", "ok", "seconds"])
        }
    }

    @Test func brokenLinesAreSkippedAndTheLimitHolds() throws {
        let home = Home()
        for i in 0..<5 {
            try AccessLog.record(.init(provider: "p", host: "h", model: "m", feature: "notes", meetings: [], chars: i, ok: true, seconds: 1),
                                 stores: home.stores)
        }
        let h = try FileHandle(forWritingTo: home.stores.accessLog)
        h.seekToEndOfFile()
        h.write(Data("{broken\n".utf8))
        try h.close()
        #expect(AccessLog.recent(3, stores: home.stores).compactMap { $0["chars"] } == [.int(4), .int(3), .int(2)])
        #expect(AccessLog.recent(nil, stores: home.stores).count == 5)
    }

    @Test func noLogReadsAsEmptyAndTheFileIsPrivate() throws {
        let home = Home()
        #expect(AccessLog.recent(stores: home.stores).isEmpty)
        try AccessLog.record(.init(provider: "p", host: "h", model: "m", feature: "notes", meetings: [], chars: 1, ok: true, seconds: 0),
                             stores: home.stores)
        let mode = try FileManager.default.attributesOfItem(atPath: home.stores.accessLog.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func whatWasSentForTranscriptionThisMonth() throws {
        let home = Home()
        let now = Date()
        let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: now)!
        func upload(_ pid: String, _ seconds: Double, _ meeting: String, ok: Bool = true, at: Date) throws {
            try AccessLog.record(.init(provider: pid, host: "h", model: "m", feature: "transcription", meetings: [meeting], chars: 0,
                                       ok: ok, seconds: 1, audioSeconds: seconds, track: "system"), stores: home.stores, now: at)
        }
        try upload("assemblyai", 3600, "m1", at: now)
        try upload("soniox", 1800, "m1", at: now)
        try upload("soniox", 1800, "m2", ok: false, at: now)  // failed: not counted
        try upload("soniox", 3600, "m3", at: lastMonth)
        try AccessLog.record(.init(provider: "anthropic", host: "h", model: "m", feature: "notes", meetings: ["m4"], chars: 9, ok: true,
                                   seconds: 1), stores: home.stores, now: now)
        let month = AccessLog.month(stores: home.stores, now: now)
        #expect(month["seconds"] == .double(5400) && month["meetings"] == .int(1) && month["usd"] == .double(0.33))
        #expect(month["since"]?.stringValue?.hasSuffix("-01") == true)
        #expect(AccessLog.month(stores: Home().stores)["seconds"] == .double(0))
    }
}
