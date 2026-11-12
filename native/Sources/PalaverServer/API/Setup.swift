// The setup assistant (#55): what the page shows and the changes it makes, each one the user's click (api.py
// `SEED_PAST_DAYS`, `SEED_NEXT_DAYS`, `_SWITCHES`, `setup_registry`, `_setup_current`, `_feature_default`, `_chosen`,
// `_hardware_dict`, `_setup_state`, `_has_meetings`, `setup_offer`, `setup_recommendations`, `_calendar_events`,
// `_profile`, `setup_page`, `_apply_one`, `apply_setup`, `setup_profile`, `setup_autostart`, `finish_setup`,
// `setup_downloads`, `start_downloads`, `_recording_now`, `_test_mode`, `setup_test`, `setup_calendar`; server.py's GET
// branches and `_setup_post`). What it recommends comes from Recommendations (onboarding.py's pure part); here it meets
// the stores. Looking changes nothing.
//
// Each provider's readiness (its key in the Keychain, by attributes only) comes from `app.provider`'s `registry`
// (Providers, in this process). Adding Palaver to Claude is McpAPI.install (in this process, McpSetup). The test recording and the calendar
// permission are the menu bar app's (`RemoteTest`, `RecordingRemote.calendarStatus/calendarConnect`), as the window's
// Python server has them (webapp/process.py `serve`). `POST /api/setup/glossary` is GlossaryAPI.seed.
import Foundation
import PalaverCore
import PalaverDomain

public enum SetupAPI {
    /// The calendar's days the glossary seed and the organization are read from.
    public static let SEED_PAST_DAYS = 30
    public static let SEED_NEXT_DAYS = 14
    /// The recommendations that are settings.json switches.
    public static let SWITCHES = ["realtime", "live_processing", "search_meaning", "record_teams", "record_slack"]
    /// onboarding.ABORTED: what the app's test recording says when a call stopped it (the page shows its status).
    public static let ABORTED = "A call started, so the test stopped; nothing was kept. Try again after the call."

    static let LM = ModelChoice.LANGUAGE_MODEL
    static let TR = ModelChoice.TRANSCRIPTION
    static let LOCAL = ModelChoice.LOCAL

    /// A choice Python's providers/llm refuse with ValueError: `Refused` with its text.
    struct ChoiceError: Error { let text: String }

    // MARK: - what is set now

    /// `setup_registry`: each feature's kind of provider (a feature chosen on its own, the coach, is not part of the
    /// assistant's bulk choice) and each provider's readiness, from `app.provider`'s `registry`.
    static func registry(_ app: ServerApp) throws -> SetupRegistry {
        let answer = try app.provider.call("registry", body: .object([]), timeout: Providers.TIMEOUT)
        var features = PyDict<String>(), providers = PyDict<SetupProviderInfo>()
        for f in answer["features"]?.arrayValue ?? [] {
            guard let id = f["id"]?.stringValue, f["own"]?.truthy != true else { continue }
            features[id] = f["uses"]?.stringValue ?? LM
        }
        for p in answer["providers"]?.arrayValue ?? [] {
            guard let id = p["id"]?.stringValue else { continue }
            providers[id] = SetupProviderInfo(label: p["label"]?.stringValue ?? id,
                                              uses: (p["uses"]?.arrayValue ?? []).compactMap(\.stringValue),
                                              ready: p["ready"]?.truthy ?? false, problem: p["problem"]?.stringValue)
        }
        return SetupRegistry(features: features, providers: providers)
    }

    /// `_setup_current`.
    static func current(_ app: ServerApp, registry given: SetupRegistry? = nil) throws -> SetupCurrent {
        let reg = try given ?? registry(app)
        let code = try McpLog.registered(stores: app.stores)
        let desktop = try McpLog.desktopRegistered(stores: app.stores, app: app.claudeDesktopApp)
        let mcp = PyDict<Bool>([("code", code["registered"]?.truthy ?? false),
                                ("desktop", desktop["registered"]?.truthy ?? false)])
        var settings = PyDict<Bool>()
        if case .object(let fields) = SettingsFile.load(defaults: app.settingsDefaults, stores: app.stores).json {
            for (k, v) in fields { settings[k] = v.boolValue ?? false }
        }
        var choices = PyDict<String>()
        for f in reg.features.keys {
            choices[f] = ModelChoice.choice(feature: f, default: featureDefault(app, f, reg), stores: app.stores)
        }
        return SetupCurrent(settings: settings, choices: choices,
                            localModel: ModelChoice.localModel(config: app.config, stores: app.stores),
                            downloaded: app.probe.downloaded(), registry: reg, mcp: mcp, chosen: chosen(app, reg, mcp))
    }

    /// `_feature_default`: a feature's choice when never made in Settings: config.toml's [notes].engine for the language
    /// models, local for transcription.
    static func featureDefault(_ app: ServerApp, _ feature: String, _ reg: SetupRegistry) -> String {
        reg.features[feature].map { Py.same($0, LM) } == true ? ModelChoice.defaultChoice(feature: feature, config: app.config, stores: app.stores)
            : LOCAL
    }

    /// `_chosen`: the recommendations whose current value the user set on purpose: in settings.json or config.toml, or
    /// Palaver added to Claude. Re-opening the assistant offers to keep those.
    static func chosen(_ app: ServerApp, _ reg: SetupRegistry, _ mcp: PyDict<Bool>) -> [String] {
        let raw = PyDict<JSONValue>(SettingsFile.readRaw(stores: app.stores)) ?? PyDict()
        var engines = PyDict<JSONValue>()
        if case .object(let fields)? = raw["engines"] { engines = PyDict(fields) }
        var out = SWITCHES.filter { raw[$0] != nil }
        if raw["local_model"] != nil || reg.featuresOf(LM).contains(where: { engines[$0] != nil })
            || !Py.same(ModelChoice.defaultChoice(feature: nil, config: app.config), LOCAL)
            || !Py.same(app.config.notesLocalModel, Recommendations.GEMMA) {
            out.append("language_model")
        }
        if reg.featuresOf(TR).contains(where: { engines[$0] != nil }) { out.append("transcription") }
        for (target, on) in mcp where on { out.append("claude_\(target)") }
        return out
    }

    /// `_hardware_dict`. The memory is a whole number of GB (the probe rounds it), written as Python's int.
    static func hardwareDict(_ hw: Hardware) -> JSONValue {
        let memory: JSONValue = hw.memoryGB.rounded() == hw.memoryGB && abs(hw.memoryGB) < 1e15
            ? .int(Int(hw.memoryGB)) : .double(hw.memoryGB)
        return .object([("chip", .string(hw.chip)), ("short", .string(hw.short)), ("memory_gb", memory),
                        ("free_disk_gb", .double(Py.round(hw.freeDiskGB, 1))), ("apple_silicon", .bool(hw.appleSilicon)),
                        ("fingerprint", .string(hw.fingerprint))])
    }

    /// `_setup_state`: settings.json's "setup", when it is an object.
    static func setupState(_ app: ServerApp) -> PyDict<JSONValue>? {
        guard case .object(let fields)? = SettingsFile.readRaw(stores: app.stores)["setup"] else { return nil }
        return PyDict(fields)
    }

    /// `_has_meetings`.
    static func hasMeetings(_ outputDir: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
        return names.contains(where: RecordingPaths.isRecordingFolderName)
    }

    // MARK: - what the page shows

    /// `setup_offer`: whether the window opens the assistant now. An existing user who never ran it is not asked:
    /// nothing is looked at.
    public static func offer(_ app: ServerApp) throws -> JSONValue {
        let state = setupState(app)
        let has = hasMeetings(app.outputDir)
        let hw = app.probe.hardware()
        let set = !(state?.isEmpty ?? true)
        let done = state?["done"].map(Recommendations.truthy) ?? false
        // After the assistant ran: every missing model. Never ran, but has meetings: they wait for the speech models.
        let missing = (set && done) || (!set && has) ? Recommendations.missingModels(try current(app), hw) : []
        guard var offer = Recommendations.offer(state, hw.fingerprint, hasMeetings: has, missing: missing) else { return .null }
        if let models = offer["models"]?.arrayValue, !models.isEmpty {
            var labels = PyDict<JSONValue>()
            for m in models.compactMap(\.stringValue) { labels[m] = .string(SetupDownloads.model(m)?.label ?? m) }
            offer["labels"] = labels.json
        }
        return offer.json
    }

    /// `setup_recommendations`: for the Settings page's "Recommended for this Mac".
    /// `registry`: the provider helper's answer when the caller just asked it.
    public static func recommendations(_ app: ServerApp, registry: SetupRegistry? = nil) throws -> JSONValue {
        let hw = app.probe.hardware()
        let recs = Recommendations.recommend(hw, app.probe.installed(), try current(app, registry: registry))
        return .object([("hardware", hardwareDict(hw)), ("recommendations", .array(recs.map { $0.toDict() }))])
    }

    /// `_calendar_events`: the calendar's events around now (none when it is off or fails).
    static func calendarEvents(_ app: ServerApp) -> [CalendarEvent] {
        let now = Date()
        do {
            return try app.probe.calendarEvents(now.addingTimeInterval(-Double(SEED_PAST_DAYS) * 86400),
                                                now.addingTimeInterval(Double(SEED_NEXT_DAYS) * 86400))
        } catch {
            app.log?.message("reading the calendar for the setup assistant failed: \(error)", level: "ERROR",
                             logger: "palaver.webapp.api")
            return []
        }
    }

    /// `_profile`: the name to prefill (chosen in the app, else config.toml's, else macOS's) and the organization.
    static func profile(_ app: ServerApp, _ events: [CalendarEvent]) -> JSONValue {
        let name: String, source: String
        if let chosen = SettingsFile.userName(stores: app.stores) {
            (name, source) = (chosen, "app")
        } else if !app.userName.isEmpty && !Py.same(app.userName, "User") {
            (name, source) = (app.userName, "config")
        } else {
            (name, source) = (app.probe.fullName(), "macOS")
        }
        let orgs = Organizations(path: app.stores.organizations)
        var org = name.isEmpty ? nil : Orgs.ownOrg(Orgs.peopleIndex(outputDir: app.outputDir), orgs, userName: name)
        if org?.isEmpty ?? true { org = Recommendations.ownOrganization(events) }
        return .object([("name", .string(name)), ("name_from", .string(source)), ("organization", .str(org))])
    }

    /// The app's test recording as it is (`RemoteTest.status`); idle outside the app.
    static func testStatus(_ app: ServerApp) -> JSONValue {
        guard let recording = app.recording else {
            return .object([("state", .string("idle")), ("max_seconds", .double(RemoteTest.MAX_SECONDS))])
        }
        return RemoteTest(recording).status()
    }

    /// `setup_page`: everything the assistant shows: the checks, the recommendations, the downloads, what to prefill, and
    /// the summary.
    public static func page(_ app: ServerApp) throws -> JSONValue {
        let hw = app.probe.hardware()
        let installed = app.probe.installed()
        let permissions = app.probe.permissions()
        let current = try self.current(app)
        let recs = Recommendations.recommend(hw, installed, current)
        // What the choices as they are now need: after the Models step, the ones chosen there.
        var needed = Recommendations.missingModels(current, hw)
        if current.settings["search_meaning"] ?? true, !current.has("e5") { needed.append("e5") }
        let events = calendarEvents(app)
        let profile = self.profile(app, events)
        let known = Glossary(path: app.stores.glossary).terms.values.compactMap { $0["term"]?.stringValue }
        let state = setupState(app)
        let missing = state.map { !$0.isEmpty && ($0["done"].map(Recommendations.truthy) ?? false) } == true
            ? Recommendations.missingModels(current, hw) : []
        let offer = Recommendations.offer(state, hw.fingerprint, hasMeetings: hasMeetings(app.outputDir), missing: missing)
        let downloads: [JSONValue] = needed.map { m in
            let info = SetupDownloads.model(m)!
            return .object([("id", .string(m)), ("label", .string(info.label)), ("purpose", .string(info.purpose)),
                            ("disk_gb", .double(info.diskGB)), ("note", .string(Recommendations.downloadNote(m, hw)))])
        }
        // `round(download_size(needed), 2)`: Python's sum of nothing is the int 0.
        let total: JSONValue = needed.isEmpty ? .int(0) : .double(Py.round(Recommendations.downloadSize(needed), 2))
        let cloud: [JSONValue] = ModelChoice.features.map { f in
            // The coach's own choice too (#41): not the assistant's to set, but where its text goes.
            let choice = current.choices[f.id] ?? ModelChoice.choice(
                feature: f.id, default: ModelChoice.defaultChoice(feature: f.id, config: app.config, stores: app.stores), stores: app.stores)
            return .object([("feature", .string(f.id)), ("label", .string(f.label)), ("choice", .string(choice))])
        }
        let name = profile["name"]?.stringValue ?? ""
        return .object([
            ("offer", offer?.json ?? .null),
            ("state", state?.json ?? .null),
            ("hardware", hardwareDict(hw)),
            ("installed", .object([("teams", .bool(installed.teams)), ("slack", .bool(installed.slack)),
                                   ("claude_code", .bool(installed.claudeCode)),
                                   ("claude_desktop", .bool(installed.claudeDesktop))])),
            ("permissions", permissions.json),
            ("recommendations", .array(recs.map { $0.toDict() })),
            ("downloads", .object([("needed", .array(downloads)), ("total_gb", total),
                                   ("free_disk_gb", .double(Py.round(hw.freeDiskGB, 1))),
                                   ("status", app.probe.downloads.status())])),
            ("profile", profile),
            ("glossary", .array(Recommendations.seedTerms(events, userName: name.isEmpty ? app.userName : name,
                                                          known: known).map(\.json))),
            ("storage", .object([("recordings", .string(app.outputDir.path)),
                                 ("audio_days", .int(Storage.audioDays(stores: app.stores))),  // 0: kept; Settings → Storage
                                 ("cloud", .array(cloud)),
                                 ("autostart", .bool(app.probe.autostart()))])),
            ("mcp", try McpAPI.status(app)),
            ("summary", .array(Recommendations.summary(hw, permissions, installed, current).map(\.json))),
            ("test", testStatus(app)),
        ])
    }

    // MARK: - applying: only what the user clicked

    /// `apply_setup`: `{"changes": {recommendation id: value}}`, what the user chose in a step. Answers with the
    /// recommendations as they are now.
    public static func apply(_ app: ServerApp, _ body: JSONValue) throws -> JSONValue {
        guard case .object(let fields)? = try PyBody.get(body, "changes"), !fields.isEmpty else {
            throw Refused("nothing to change")
        }
        let reg = try registry(app)
        for (rid, value) in PyDict(fields) { try applyOne(app, rid, value, reg) }
        return try recommendations(app, registry: reg)  // the helper asked once (a Python start, about 1 s)
    }

    /// `_apply_one`.
    static func applyOne(_ app: ServerApp, _ rid: String, _ value: JSONValue, _ reg: SetupRegistry) throws {
        if SWITCHES.contains(where: { Py.same($0, rid) }) {
            guard case .bool(let on) = value else { throw Refused("\(rid) must be true or false") }
            try SettingsFile.update([(rid, .bool(on))], stores: app.stores)
            return
        }
        if Py.same(rid, "claude_code") || Py.same(rid, "claude_desktop") {
            guard case .bool(let on) = value else { throw Refused("\(rid) must be true or false") }
            if on { _ = try McpAPI.install(app, target: Py.same(rid, "claude_code") ? "code" : "desktop") }
            return
        }
        let kind: String
        if Py.same(rid, "language_model") {
            kind = LM
        } else if Py.same(rid, "transcription") {
            kind = TR
        } else {
            throw Refused("nothing to set for \(Py.repr(.string(rid)))")
        }
        guard case .string(var choice) = value else { throw Refused("no choice \(Py.repr(value))") }
        let features = reg.featuresOf(kind)
        let localPrefix = "\(LOCAL):".unicodeScalars
        do {
            if Py.same(choice, ModelChoice.PENDING) && kind != LM { throw ChoiceError(text: "only notes can wait for a cloud model") }
            if choice.unicodeScalars.starts(with: localPrefix) && kind == LM {
                try chooseLocalModel(app, String(String.UnicodeScalarView(choice.unicodeScalars.dropFirst(localPrefix.count))))
                choice = LOCAL
            }
            if features.isEmpty {  // e.g. transcription before #54: on this Mac, nothing to choose
                if !Py.same(choice, LOCAL) {
                    let what = rid.replacingOccurrences(of: "_", with: " ")
                    throw ChoiceError(text: "no \(what) service \(Py.repr(.string(choice)))")
                }
                return
            }
            for f in features { try choose(app, f, choice, reg) }
        } catch let e as ChoiceError {
            throw Refused(e.text)
        }
    }

    /// `llm.choose_local_model`.
    static func chooseLocalModel(_ app: ServerApp, _ repo: String) throws {
        guard ModelChoice.localModelInfo(repo) != nil else { throw ChoiceError(text: "no local model \(Py.repr(.string(repo)))") }
        try SettingsFile.update([("local_model", .string(repo))], stores: app.stores)
    }

    /// `providers.choose`: "local" or a provider id for `feature`; a provider must be set up first (its readiness from
    /// the registry). This is the user's consent: nothing else writes it.
    static func choose(_ app: ServerApp, _ feature: String, _ value: String, _ reg: SetupRegistry) throws {
        guard let f = ModelChoice.feature(feature) else { throw ChoiceError(text: "no feature \(Py.repr(.string(feature)))") }
        if Py.same(value, ModelChoice.PENDING) && f.uses == LM {
            // off until a cloud model is set up: nothing to check
        } else if !Py.same(value, LOCAL) {
            guard ModelChoice.forFeature(feature).contains(where: { Py.same($0, value) }),
                  let provider = ModelChoice.provider(value) else {
                let what = f.uses == TR ? "transcription service" : "language model"
                throw ChoiceError(text: "no \(what) \(Py.repr(.string(value)))")
            }
            if let info = reg.providers[value], !info.ready {
                throw ChoiceError(text: "\(provider.label): \(info.problem ?? "not set up")")
            }
        }
        var engines = PyDict<JSONValue>()
        if case .object(let fields)? = SettingsFile.readRaw(stores: app.stores)["engines"] { engines = PyDict(fields) }
        engines[feature] = .string(value)
        try SettingsFile.update([("engines", engines.json)], stores: app.stores)
    }

    /// `setup_profile`: `{"name", "organization"}`: the user's name (settings.json, which wins over config.toml) and
    /// their organization (organizations.json). The name before stays the user's as an alias: earlier meetings show it.
    public static func setProfile(_ app: ServerApp, _ body: JSONValue) throws -> JSONValue {
        guard case .string(let given)? = try PyBody.get(body, "name"), !Py.strip(given).isEmpty,
              given.unicodeScalars.count <= 120,
              !given.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
            throw Refused("your name must be one line of text")
        }
        let name = Py.strip(given)
        let key = Py.casefold(name)
        let before = SettingsFile.userName(stores: app.stores) ?? app.userName
        var aliases = SettingsFile.userAliases(stores: app.stores).filter { !Py.same(Py.casefold($0), key) }
        let beforeKey = Py.casefold(before)
        if !before.isEmpty && !Py.same(before, "User") && !Py.same(beforeKey, key)
            && !aliases.contains(where: { Py.same(Py.casefold($0), beforeKey) }) {
            aliases.append(before)
        }
        try SettingsFile.update([("user_name", .string(name)), ("user_aliases", .strings(aliases))], stores: app.stores)
        app.userName = name
        if case .string(let org)? = try PyBody.get(body, "organization") {
            let orgs = Organizations(path: app.stores.organizations)
            let stripped = Py.strip(org)
            orgs.setPerson(name, stripped.isEmpty ? nil : stripped)
            try orgs.save()
        }
        return .object([("name", .string(name)),
                        ("organization", .str(Organizations(path: app.stores.organizations).person(name)))])
    }

    /// `setup_autostart`: `{"on": bool}`.
    public static func setAutostart(_ app: ServerApp, _ body: JSONValue) throws -> JSONValue {
        guard case .bool(let on)? = try PyBody.get(body, "on") else { throw Refused("on must be true or false") }
        try app.probe.setAutostart(on)
        return .object([("autostart", .bool(app.probe.autostart()))])
    }

    /// `finish_setup`: `{"how": "done" | "skipped"}`, remembered with this Mac, so a new Mac (or a missing model) offers
    /// the assistant again.
    public static func finish(_ app: ServerApp, _ body: JSONValue) throws -> JSONValue {
        guard case .string(let how)? = try PyBody.get(body, "how"), Py.same(how, "done") || Py.same(how, "skipped") else {
            throw Refused(#"how must be "done" or "skipped""#)
        }
        let state = JSONValue.object([(how, .string(Py.isoNow(timespec: "seconds"))),
                                      ("hardware", .string(app.probe.hardware().fingerprint))])
        try SettingsFile.update([("setup", state)], stores: app.stores)
        return .object([("state", state)])
    }

    // MARK: - downloads, the test recording and the calendar: started by the user

    /// `start_downloads`: `{"models": [...]}`, the downloads the user agreed to, in the background.
    public static func startDownloads(_ app: ServerApp, _ body: JSONValue) throws -> JSONValue {
        guard case .array(let ids)? = try PyBody.get(body, "models"), !ids.isEmpty else {
            throw Refused("no models to download")
        }
        return try app.probe.downloads.start(ids.map(Py.str))
    }

    /// `_test_mode`: how the test may transcribe the mic track: with Parakeet on this Mac when it is there (never
    /// downloaded for the test), or not at all when a cloud service transcribes the calls (the test sends nothing).
    static func testMode(_ app: ServerApp) -> JSONValue {
        let transcription = ModelChoice.features.filter { !$0.own && $0.uses == TR }.map(\.id)
        let chosen = transcription.first.map { ModelChoice.choice(feature: $0, default: LOCAL, stores: app.stores) } ?? LOCAL
        if !Py.same(chosen, LOCAL) {
            return .object([("transcribe", .string("cloud")),
                            ("service", .string(ModelChoice.provider(chosen)?.label ?? chosen))])
        }
        return .object([("transcribe", .string("local"))])
    }

    /// A body's `action`; JSON null is none (`body.get("action")` is None).
    static func action(_ body: JSONValue) throws -> JSONValue? {
        guard let v = try PyBody.get(body, "action"), v != .null else { return nil }
        return v
    }

    /// `setup_test`: `{"action": "start"}` or `{"action": "stop"}` (the user's click); without one, how it is going. The
    /// menu bar app records it; outside the app it never starts.
    public static func test(_ app: ServerApp, _ body: JSONValue) throws -> JSONValue {
        let action = try self.action(body)
        if action == .string("start") {
            guard let recording = app.recording else { throw Refused(Remote.NO_ANSWER) }
            // `_recording_now`: a meeting recording now (the app's daemon.json), not one being processed.
            return try RemoteTest(recording).start(busy: { recording.recording() != nil }, mode: testMode(app))
        }
        if action == .string("stop") {
            guard let recording = app.recording else { return testStatus(app) }
            return RemoteTest(recording).stop()
        }
        if action != nil { throw Refused(#"action must be "start" or "stop""#) }
        return testStatus(app)
    }

    /// `setup_calendar`: `{"action": "connect"}` (the button) has the app ask macOS for the calendar, or open System
    /// Settings once refused; without one, its state, which the page looks at until it is connected.
    public static func calendar(_ app: ServerApp, _ body: JSONValue) throws -> JSONValue {
        let action = try self.action(body)
        if action == .string("connect") {
            guard let recording = app.recording else { throw Refused(Remote.NO_ANSWER) }
            return try recording.calendarConnect()
        }
        if action != nil { throw Refused(#"action must be "connect""#) }
        return app.recording?.calendarStatus() ?? Remote.calendarPermission()
    }
}

extension Router {
    /// The setup assistant's routes (server.py's GET branches and `_setup_post`; `/api/setup/glossary` is the glossary's).
    static func addSetupRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/setup") { _, _ in .json(try SetupAPI.page(app)) }
        r.get("/api/setup/offer") { _, _ in .json(.object([("offer", try SetupAPI.offer(app))])) }
        r.get("/api/setup/recommendations") { _, _ in .json(try SetupAPI.recommendations(app)) }
        r.get("/api/setup/downloads") { _, _ in .json(app.probe.downloads.status()) }
        r.get("/api/setup/test") { _, _ in .json(try SetupAPI.test(app, .object([]))) }
        r.get("/api/setup/calendar") { _, _ in .json(try SetupAPI.calendar(app, .object([]))) }

        r.post("/api/setup/apply") { req, _ in .json(try SetupAPI.apply(app, req.json)) }
        r.post("/api/setup/profile") { req, _ in .json(try SetupAPI.setProfile(app, req.json)) }
        r.post("/api/setup/autostart") { req, _ in .json(try SetupAPI.setAutostart(app, req.json)) }
        r.post("/api/setup/finish") { req, _ in .json(try SetupAPI.finish(app, req.json)) }
        r.post("/api/setup/downloads") { req, _ in .json(try SetupAPI.startDownloads(app, req.json)) }
        r.post("/api/setup/test") { req, _ in .json(try SetupAPI.test(app, req.json)) }
        r.post("/api/setup/calendar") { req, _ in .json(try SetupAPI.calendar(app, req.json)) }
    }
}
