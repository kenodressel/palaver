// The setup assistant's recommendations, pure (tests/test_onboarding.py: the chip, the profile table, notes, disk, calls,
// transcription, what to record, offers, missing models, the summary, the test recording's verdict) under their names, and
// the Python goldens over many Macs and settings (tools/parity/goldens.py "setup"). The tests of the probe, the downloads
// and the test recording itself are Task 50's and 51's.
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private typealias F = SetupFixtures
private let GEMMA = F.GEMMA
private let QWEN = F.QWEN
private let CHIPS = ["Apple M1", "Apple M2 Pro", "Apple M4 Pro"]
private let MEMORY: [Double] = [8, 16, 24, 32, 48, 64]

private func option(_ r: Recommendation, _ value: SetupValue) -> SetupOption? { r.options.first { $0.value == value } }
private func s(_ v: String) -> SetupValue { .string(v) }
private func b(_ v: Bool) -> SetupValue { .bool(v) }

@Suite struct RecommendationsTests {
    // MARK: - the chip

    @Test func test_parse_chip() {
        let cases: [(String, (Int, String)?)] = [
            ("Apple M1", (1, "base")), ("Apple M2 Pro", (2, "pro")), ("Apple M3 Max", (3, "max")),
            ("Apple M4 Pro", (4, "pro")), ("Apple M2 Ultra", (2, "ultra")), ("Apple M5", (5, "base")),
            ("Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz", nil), ("", nil),
        ]
        for (brand, want) in cases {
            let got = Recommendations.parseChip(brand)
            #expect(got?.generation == want?.0 && got?.tier == want?.1, "\(brand)")
        }
    }

    @Test func test_hardware_says_what_it_is() {
        let hw = Hardware(chip: "Apple M4 Pro", memoryGB: 48.0, freeDiskGB: 120.4)
        #expect(hw.appleSilicon && hw.generation == 4 && hw.tier == "pro")
        #expect(hw.fingerprint == "Apple M4 Pro, 48 GB")
        #expect(!Hardware(chip: "Intel(R) Core(TM) i7", memoryGB: 16, freeDiskGB: 100).appleSilicon)
    }

    // MARK: - the recommendation table: every profile

    @Test func test_every_profile() {
        for chip in CHIPS {
            for memory in MEMORY {
                let got = F.recs(chip, memory)
                let (gen, tier) = Recommendations.parseChip(chip)!
                let fast = gen >= 3 || (gen == 2 && tier != "base")
                #expect(got["transcription"]!.value == s("local"), "\(chip) \(memory)")
                #expect(got["language_model"]!.value == s(memory >= 24 ? "local:\(GEMMA)" : "pending"), "\(chip) \(memory)")
                #expect(got["realtime"]!.value == b(fast && memory >= 16), "\(chip) \(memory)")
                #expect(got["live_processing"]!.value == b(memory >= 24), "\(chip) \(memory)")
                #expect(got["search_meaning"]!.value == b(true), "\(chip) \(memory)")
                for r in got.values {
                    #expect(!Py.strip(r.reason).isEmpty, "\(r.id)")  // every recommendation says why
                    if !r.options.isEmpty { #expect(r.options.contains { $0.value == r.value }, "\(r.id)") }
                }
            }
        }
    }

    @Test func test_the_profile_table_is_printable() {
        let profiles = CHIPS.flatMap { c in MEMORY.map { (c, $0, 200.0) } } + [("Apple M4 Pro", 32.0, 10.0)]
        let rows = Recommendations.profileTable(profiles, F.current(downloaded: []))
        #expect(rows.count == CHIPS.count * MEMORY.count + 1)
        #expect(rows[0].hasPrefix("Apple M1, 8 GB, 200 GB free"))
    }

    // MARK: - notes: the local model or the cloud

    @Test func test_24_gb_writes_notes_locally_with_gemma_and_says_why() {
        let r = F.recs("Apple M4 Pro", 24)["language_model"]!
        #expect(r.value == s("local:\(GEMMA)") && r.matches)
        #expect(r.reason.contains("24 GB") && r.reason.contains("14 GB"))
        #expect(r.features == ["notes", "projects"])
    }

    @Test func test_16_gb_recommends_a_cloud_model_and_explains_the_memory() throws {
        let r = F.recs("Apple M2 Pro", 16)["language_model"]!
        // Nothing is set up yet: notes wait for a cloud model, never Gemma by default.
        #expect(r.value == s("pending") && r.needsSetup)
        #expect(r.label == "None yet: set up a cloud model")
        #expect(r.reason.contains("16 GB") && r.reason.contains("14 GB"))
        #expect(r.reason.contains("Small local models wrote clearly worse notes in our tests, so we don't offer one."))
        let pending = try #require(option(r, s("pending")))
        #expect(pending.available && pending.note.contains("off until"))
        let gemma = try #require(option(r, s("local:\(GEMMA)")))
        #expect(gemma.available && gemma.note.contains("14 GB"))  // still possible, with its catch said
        #expect(!r.matches)
    }

    @Test func test_16_gb_recommends_a_cloud_model_that_is_ready() {
        var r = F.recs("Apple M2 Pro", 16, F.current(registry: F.lmRegistry(ready: ["anthropic", "claude-cli"])))["language_model"]!
        #expect(r.value == s("claude-cli") && !r.needsSetup)  // no key needed: the Claude Code login
        r = F.recs("Apple M2 Pro", 16, F.current(registry: F.lmRegistry(ready: ["anthropic"])))["language_model"]!
        #expect(r.value == s("anthropic"))
    }

    @Test func test_a_cloud_model_already_chosen_stays_recommended() {
        let cur = F.current(choices: PyDict([("notes", "openai"), ("projects", "openai")]),
                            registry: F.lmRegistry(ready: ["anthropic", "openai"]))
        let r = F.recs("Apple M1", 16, cur)["language_model"]!
        #expect(r.value == s("openai") && r.matches)
    }

    @Test func test_8_gb_cannot_run_gemma_at_all() throws {
        let r = F.recs("Apple M1", 8)["language_model"]!
        let gemma = try #require(option(r, s("local:\(GEMMA)")))
        #expect(r.value == s("pending") && !gemma.available)
    }

    @Test func test_qwen_is_no_longer_offered() {
        // It made more mistakes on German meetings than Gemma, at twice the size.
        let r = F.recs("Apple M4 Pro", 48)["language_model"]!
        #expect(r.value == s("local:\(GEMMA)"))
        #expect(option(r, s("local:\(QWEN)")) == nil)
    }

    @Test func test_cloud_providers_are_offered_with_their_problem() throws {
        let r = F.recs("Apple M4 Pro", 48)["language_model"]!
        let anthropic = try #require(option(r, s("anthropic")))
        #expect(!anthropic.available && anthropic.note == "Add the API key")
    }

    // MARK: - disk

    @Test func test_low_disk_recommends_the_cloud_and_says_how_much_is_needed() {
        let got = F.recs("Apple M4 Pro", 32, disk: 10, F.current(downloaded: []))
        let lm = got["language_model"]!
        #expect(lm.value == s("pending"))
        #expect(lm.reason.contains("8.3 GB") && lm.reason.contains("10 GB free"))
        #expect(got["transcription"]!.value == s("local"))  // Parakeet still fits: 0.5 GB
    }

    @Test func test_low_disk_is_fine_when_the_model_is_already_here() {
        let got = F.recs("Apple M4 Pro", 32, disk: 10)
        #expect(got["language_model"]!.value == s("local:\(GEMMA)"))
        #expect(got["disk"] == nil)
    }

    @Test func test_very_low_disk_says_what_to_free() {
        let got = F.recs("Apple M4 Pro", 48, disk: 3, F.current(downloaded: []))
        let disk = got["disk"]!
        #expect((disk.value.numberValue ?? 0) > 0 && disk.reason.contains("GB"))
        #expect(got["search_meaning"]!.value == b(false))  // no room for the 470 MB index model either
    }

    @Test func test_downloads_list_what_is_not_here_yet() {
        let got = F.recs("Apple M4 Pro", 48, F.current(downloaded: []))
        #expect(got["transcription"]!.downloads == ["speech"])
        #expect(got["language_model"]!.downloads == ["gemma"])
        #expect(got["search_meaning"]!.downloads == ["e5"])
        #expect(abs(Recommendations.downloadSize(["speech", "gemma", "e5"]) - (0.5 + 8.3 + 0.47)) < 1e-9)
    }

    // MARK: - during calls

    @Test func test_realtime_is_off_below_an_m2_pro_and_says_why() {
        var r = F.recs("Apple M1", 32)["realtime"]!
        #expect(r.value == b(false) && r.reason.contains("M2 Pro"))
        r = F.recs("Apple M4 Pro", 8)["realtime"]!
        #expect(r.value == b(false) && r.reason.contains("8 GB"))
    }

    @Test func test_realtime_names_its_cost() {
        let r = F.recs("Apple M4 Pro", 48)["realtime"]!
        #expect(r.value == b(true) && r.reason.contains("2.5 GB"))
    }

    @Test func test_live_processing_needs_24_gb() {
        #expect(F.recs("Apple M4 Pro", 16)["live_processing"]!.value == b(false))
        let r = F.recs("Apple M4 Pro", 24)["live_processing"]!
        #expect(r.value == b(true) && r.reason.contains("3.6 GB"))
    }

    // MARK: - transcription

    @Test func test_transcription_is_parakeet_on_any_apple_silicon() {
        for chip in CHIPS {
            let r = F.recs(chip, 8)["transcription"]!
            #expect(r.value == s("local") && r.reason.contains("Parakeet"))
            #expect(r.features.isEmpty)  // nothing to choose on master: no transcription feature yet
        }
    }

    @Test func test_transcription_offers_the_registrys_services_once_54_is_in() {
        let reg = F.withTranscription(F.lmRegistry(), ready: ["soniox"])
        let r = F.recs("Apple M4 Pro", 48, F.current(registry: reg))["transcription"]!
        #expect(r.value == s("local") && r.features == ["transcription"])
        #expect(r.options.map(\.value) == [s("local"), s("assemblyai"), s("soniox")])
        #expect(r.options.map(\.available) == [true, false, true])
        let lm = F.recs("Apple M4 Pro", 48, F.current(registry: reg))["language_model"]!
        #expect(lm.features == ["notes", "projects"])  // transcription services are no language model
        #expect(option(lm, s("assemblyai")) == nil)
    }

    @Test func test_an_intel_mac_is_not_supported_yet() {
        let reg = F.withTranscription(F.lmRegistry(), ready: ["assemblyai"])
        let got = F.recs("Intel(R) Core(TM) i7", 16, F.current(registry: reg))
        for id in ["transcription", "language_model"] {
            let r = got[id]!
            #expect(r.matches && r.label == "Not supported on this Mac")  // nothing to change
            #expect(r.reason.contains("Apple Silicon is required for local processing"))
            #expect(r.reason.contains("doesn't support Intel Macs yet"))
            #expect(!r.reason.contains("transcribes the calls"))
        }
        #expect(got["realtime"]!.value == b(false) && got["live_processing"]!.value == b(false))
    }

    @Test func test_a_transcription_service_chosen_stays_recommended() {
        let reg = F.withTranscription(F.lmRegistry(), ready: ["soniox"])
        let cur = F.current(choices: PyDict([("notes", "local"), ("transcription", "soniox")]), registry: reg)
        let r = F.recs("Apple M4 Pro", 48, cur)["transcription"]!
        #expect(r.value == s("local") && r.current == s("soniox") && !r.matches)  // local is still the advice
    }

    // MARK: - what to record, Claude

    @Test func test_teams_and_slack_follow_what_is_installed() {
        let cur = F.current(settings: PyDict([("record_teams", false), ("record_slack", true)]))
        let got = F.recs("Apple M4 Pro", 48, installed: Installed(teams: true, slack: false), cur)
        #expect(got["record_teams"]!.value == b(true) && got["record_teams"]!.reason.contains("installed"))
        #expect(got["record_slack"]!.value == b(true))  // not installed: keeps what it is, nothing to detect yet
        #expect(got["record_slack"]!.reason.contains("not installed"))
    }

    @Test func test_claude_access_is_recommended_where_claude_is_installed() {
        var got = F.recs("Apple M4 Pro", 48, installed: Installed(claudeCode: true))
        #expect(got["claude_code"]!.value == b(true) && !got["claude_code"]!.matches)
        #expect(got["claude_desktop"]!.value == b(false) && got["claude_desktop"]!.reason.contains("not installed"))
        got = F.recs("Apple M4 Pro", 48, installed: Installed(claudeCode: true),
                     F.current(mcp: PyDict([("code", true), ("desktop", false)])))
        #expect(got["claude_code"]!.matches)
    }

    @Test func test_a_recommendation_serializes_for_the_page() {
        let r = F.recs("Apple M2 Pro", 16)["language_model"]!.toDict()
        #expect(r["id"]?.stringValue == "language_model" && r["value"]?.stringValue == "pending")
        #expect(r["needs_setup"]?.boolValue == true)
        let first = PyDict<JSONValue>(r["options"]!.arrayValue![0])!
        #expect(["value", "label", "note", "available"].allSatisfy { first[$0] != nil })
        #expect(r["matches"]?.boolValue == false && r["step"]?.stringValue == "models" && r["chosen"]?.boolValue == false)
    }

    // MARK: - when to offer the assistant

    private func offerJSON(_ r: PyDict<JSONValue>?) -> String { r.map { F.dumps($0.json) } ?? "None" }

    @Test func test_offer_on_first_start_only_without_meetings() {
        #expect(offerJSON(Recommendations.offer(nil, "Apple M4 Pro, 48 GB", hasMeetings: false, missing: []))
            == #"{"why": "first"}"#)
        #expect(Recommendations.offer(nil, "Apple M4 Pro, 48 GB", hasMeetings: true, missing: []) == nil)  // an existing user
    }

    @Test func test_offer_again_when_the_mac_changed() {
        let state = PyDict<JSONValue>([("done", .string("2026-10-29T10:00:00+01:00")), ("hardware", .string("Apple M1, 16 GB"))])
        #expect(offerJSON(Recommendations.offer(state, "Apple M4 Pro, 48 GB", hasMeetings: true, missing: []))
            == #"{"why": "changed", "was": "Apple M1, 16 GB", "now": "Apple M4 Pro, 48 GB"}"#)
    }

    @Test func test_offer_the_downloads_when_a_model_is_missing() {
        let state = PyDict<JSONValue>([("done", .string("2026-10-29T10:00:00+01:00")),
                                       ("hardware", .string("Apple M4 Pro, 48 GB"))])
        #expect(offerJSON(Recommendations.offer(state, "Apple M4 Pro, 48 GB", hasMeetings: true, missing: ["gemma"]))
            == #"{"why": "missing", "models": ["gemma"]}"#)
        #expect(Recommendations.offer(state, "Apple M4 Pro, 48 GB", hasMeetings: true, missing: []) == nil)
    }

    @Test func test_skipped_is_not_offered_again() {
        let state = PyDict<JSONValue>([("skipped", .string("2026-10-29T10:00:00+01:00")),
                                       ("hardware", .string("Apple M4 Pro, 48 GB"))])
        #expect(Recommendations.offer(state, "Apple M4 Pro, 48 GB", hasMeetings: false, missing: ["gemma"]) == nil)
    }

    @Test func test_missing_models_are_those_the_choices_need() {
        let hw = Hardware(chip: "Apple M4 Pro", memoryGB: 48, freeDiskGB: 200)
        var c = F.current(downloaded: ["e5"])
        #expect(Recommendations.missingModels(c, hw) == ["speech", "gemma"])
        c = F.current(choices: PyDict([("notes", "anthropic")]), downloaded: ["speech", "e5"],
                      registry: F.lmRegistry(ready: ["anthropic"]))
        #expect(Recommendations.missingModels(c, hw) == [])
    }

    // MARK: - the summary (doctor in the window)

    @Test func test_summary_says_what_is_set_up_and_what_to_fix() {
        let hw = Hardware(chip: "Apple M2 Pro", memoryGB: 16, freeDiskGB: 50)
        func perm(_ state: String, _ detail: String) -> JSONValue { .object([("state", .string(state)), ("detail", .string(detail))]) }
        let permissions = PyDict<JSONValue>([("microphone", perm("granted", "granted")),
                                             ("system_audio", perm("unverified", "not verified yet")),
                                             ("calendar", perm("not_asked", "not connected")),
                                             ("notifications", perm("unknown", "macOS asks the first time"))])
        let c = F.current(choices: PyDict([("notes", "anthropic"), ("projects", "anthropic")]), downloaded: [])
        let by = Dictionary(uniqueKeysWithValues: Recommendations.summary(hw, permissions, Installed(), c).map { ($0.name, $0) })
        #expect(by["This Mac"]!.status == "ok" && by["This Mac"]!.detail.contains("M2 Pro"))
        #expect(by["Microphone"]!.status == "ok")
        #expect(by["Calendar"]!.status == "warn" && !by["Calendar"]!.fix.isEmpty)
        #expect(by["Speech models"]!.status == "warn" && by["Speech models"]!.fix.contains("0.5 GB"))
        #expect(by["Notes and projects"]!.status == "fail" && by["Notes and projects"]!.detail.contains("Add the API key"))
        #expect(by["Disk space"]!.status == "ok")
    }

    @Test func test_summary_local_notes_name_the_model_and_its_download() {
        let c = F.current(downloaded: ["speech", "e5"])
        let by = Dictionary(uniqueKeysWithValues: Recommendations.summary(
            Hardware(chip: "Apple M4 Pro", memoryGB: 48, freeDiskGB: 200), PyDict(), Installed(), c).map { ($0.name, $0) })
        #expect(by["Notes and projects"]!.status == "warn" && by["Notes and projects"]!.detail.contains("Gemma 4 12B"))
        #expect(by["Notes and projects"]!.fix.contains("8.3 GB"))
    }

    // MARK: - the test recording's verdict

    private func result(mic: JSONValue, system: JSONValue) -> PyDict<JSONValue> { PyDict([("mic", mic), ("system", system)]) }
    private func track(_ fields: [(String, JSONValue)]) -> JSONValue { .object(fields) }

    @Test func test_test_verdict_both_tracks() {
        let ok = Recommendations.testVerdict(result(
            mic: track([("recorded", .bool(true)), ("level_db", .double(-28.0)), ("text", .string("Hello this is a test"))]),
            system: track([("recorded", .bool(true)), ("level_db", .double(-80.0))])))
        #expect(ok.map(\.status) == ["ok", "ok"])
        #expect(ok[0].detail.contains("Hello this is a test"))
        #expect(ok[1].detail.contains("quiet"))  // nothing played: a silent system track is right
    }

    @Test func test_test_verdict_silent_mic_and_missing_system_track() {
        let bad = Recommendations.testVerdict(result(
            mic: track([("recorded", .bool(true)), ("level_db", .double(-75.0)), ("text", .string(""))]),
            system: track([("recorded", .bool(false)), ("level_db", .null)])))
        #expect(bad.map(\.status) == ["warn", "fail"])
        #expect(bad[0].fix.contains("input") && bad[1].fix.contains("System Audio Recording"))
        for c in bad { #expect(!(c.detail + c.fix).lowercased().contains("headphone")) }
    }

    @Test func test_test_verdict_mic_missing() {
        let bad = Recommendations.testVerdict(result(
            mic: track([("recorded", .bool(false)), ("level_db", .null), ("text", .null)]),
            system: track([("recorded", .bool(true)), ("level_db", .double(-20.0))])))
        #expect(bad[0].status == "fail" && bad[0].fix.contains("Microphone"))
        #expect(bad[1].status == "ok")
    }

    // MARK: - review fixes

    @Test func test_a_deliberate_choice_is_marked_chosen() {
        let got = F.recs("Apple M1", 32, F.current(settings: PyDict([("realtime", true)]), chosen: ["realtime"]))
        #expect(got["realtime"]!.chosen && !got["realtime"]!.matches)
        #expect(!got["live_processing"]!.chosen)
    }

    @Test func test_summary_says_notes_wait_for_a_cloud_model() {
        let c = F.current(choices: PyDict([("notes", "pending"), ("projects", "pending")]))
        let by = Dictionary(uniqueKeysWithValues: Recommendations.summary(
            Hardware(chip: "Apple M2 Pro", memoryGB: 16, freeDiskGB: 200), PyDict(), Installed(), c).map { ($0.name, $0) })
        #expect(by["Notes and projects"]!.status == "warn")
        #expect(by["Notes and projects"]!.detail.contains("none yet") && by["Notes and projects"]!.fix.contains("Language model"))
    }

    @Test func test_missing_models_never_include_gemma_while_notes_wait() {
        let c = F.current(choices: PyDict([("notes", "pending")]), downloaded: ["speech"])
        #expect(Recommendations.missingModels(c, Hardware(chip: "Apple M2 Pro", memoryGB: 16, freeDiskGB: 200)) == [])
    }

    @Test func test_the_catch_of_a_local_model_on_a_small_mac() {
        #expect(Recommendations.downloadNote("gemma", Hardware(chip: "Apple M2 Pro", memoryGB: 16, freeDiskGB: 200))
            == "needs 14 GB free while writing; this Mac has 16 GB")
        #expect(Recommendations.downloadNote("gemma", Hardware(chip: "Apple M4 Pro", memoryGB: 48, freeDiskGB: 200)) == "")
        #expect(Recommendations.downloadNote("speech", Hardware(chip: "Apple M2 Pro", memoryGB: 16, freeDiskGB: 200)) == "")
    }

    @Test func test_a_screencapturekit_fallback_works_with_a_fallback() {
        let permissions = PyDict<JSONValue>([("system_audio", .object([("state", .string("fallback")),
                                                                      ("detail", .string("works with a fallback"))]))])
        let by = Dictionary(uniqueKeysWithValues: Recommendations.summary(
            Hardware(chip: "Apple M4 Pro", memoryGB: 48, freeDiskGB: 200), permissions, Installed(), F.current())
            .map { ($0.name, $0) })
        #expect(by["System audio"]!.status == "warn" && by["System audio"]!.detail.contains("fallback"))
    }

    @Test func test_test_verdict_says_why_there_are_no_words() {
        let system = track([("recorded", .bool(true)), ("level_db", .double(-80.0))])
        let missing = Recommendations.testVerdict(result(
            mic: track([("recorded", .bool(true)), ("level_db", .double(-20.0)), ("text", .null),
                        ("transcript", .string("not_downloaded"))]), system: system))
        #expect(missing[0].status == "ok" && missing[0].detail.contains("speech models are not downloaded"))
        #expect(missing[0].fix.contains("Downloads"))
        let cloud = Recommendations.testVerdict(result(
            mic: track([("recorded", .bool(true)), ("level_db", .double(-20.0)), ("text", .null),
                        ("transcript", .string("cloud")), ("service", .string("Soniox"))]), system: system))
        #expect(cloud[0].detail.contains("transcription is skipped") && cloud[0].detail.contains("Soniox"))
    }

    @Test func test_a_user_without_setup_state_but_with_meetings_is_offered_the_speech_models() {
        #expect(offerJSON(Recommendations.offer(nil, "fp", hasMeetings: true, missing: ["speech", "gemma"]))
            == #"{"why": "missing", "models": ["speech"]}"#)
        #expect(Recommendations.offer(nil, "fp", hasMeetings: true, missing: ["gemma"]) == nil)
        #expect(Recommendations.offer(nil, "fp", hasMeetings: true, missing: []) == nil)
        #expect(offerJSON(Recommendations.offer(nil, "fp", hasMeetings: false, missing: ["speech"])) == #"{"why": "first"}"#)
    }

    // MARK: - Python goldens over many Macs and settings

    /// Records the first few differences of a golden list instead of every one.
    private func expectEach(_ got: [JSONValue], _ want: [JSONValue], _ what: String) {
        #expect(got.count == want.count, "\(what): case count")
        var reported = 0
        for (i, (g, w)) in zip(got, want).enumerated() where reported < 5 {
            let gs = F.dumps(g), ws = F.dumps(w)
            if gs != ws { Issue.record("\(what) #\(i): got \(gs), want \(ws)"); reported += 1 }
        }
    }

    @Test func golden_recommend_over_many_macs_and_settings() {
        let currents = F.currents()
        let cases = F.list("recommend")
        #expect(cases.count > 500)
        var wrong = 0, full = 0
        for c in cases {
            let hw = F.hardware(c["hw"])
            let j = F.int(c["current"])
            let got = Recommendations.recommend(hw, F.installed(c["installed"]), currents[j]).map { $0.toDict() }
            let text = F.dumps(.array(got))
            if let want = c["full"] {
                full += 1
                if text != F.dumps(want) && wrong < 3 { Issue.record("recommend \(hw): got \(text), want \(F.dumps(want))") }
            }
            if F.sha256(text) != c["digest"]?.stringValue {
                wrong += 1
                if wrong <= 3 { Issue.record("recommend \(hw) current \(j) differs: \(text)") }
            }
        }
        #expect(wrong == 0 && full > 20, "\(wrong) of \(cases.count) differ; \(full) in full")
    }

    @Test func golden_profile_table_over_many_profiles() {
        let currents = F.currents()
        for t in F.list("tables") {
            let profiles = (t["profiles"]?.arrayValue ?? []).map { p -> (String, Double, Double) in
                let a = p.arrayValue!
                return (a[0].stringValue!, F.num(a[1]), F.num(a[2]))
            }
            let rows = Recommendations.profileTable(profiles, currents[F.int(t["current"])], Installed(slack: true))
            expectEach(rows.map { .string($0) }, t["rows"]?.arrayValue ?? [], "profile_table current \(t["current"]!)")
        }
    }

    @Test func golden_offer_missing_models_and_download_note() {
        var got: [JSONValue] = [], want: [JSONValue] = []
        for c in F.list("offers") {
            let a = c.arrayValue!
            let state = a[0].isNull ? nil : PyDict<JSONValue>(a[0])
            let r = Recommendations.offer(state, a[1].stringValue!, hasMeetings: a[2].boolValue!, missing: F.strings(a[3]))
            got.append(r?.json ?? .null)
            want.append(a[4])
        }
        expectEach(got, want, "offer")
        #expect(want.count > 50)

        let currents = F.currents()
        got = []; want = []
        for c in F.list("missing") {
            let a = c.arrayValue!
            let hw = Hardware(chip: a[1].stringValue!, memoryGB: F.num(a[2]), freeDiskGB: 100)
            got.append(.strings(Recommendations.missingModels(currents[F.int(a[0])], hw)))
            want.append(a[3])
        }
        expectEach(got, want, "missing_models")

        got = []; want = []
        for c in F.list("download_note") {
            let a = c.arrayValue!
            got.append(.string(Recommendations.downloadNote(a[0].stringValue!,
                                                            Hardware(chip: "Apple M2 Pro", memoryGB: F.num(a[1]), freeDiskGB: 200))))
            want.append(a[2])
        }
        expectEach(got, want, "download_note")
    }

    @Test func golden_hardware_chip_fingerprint_and_short() {
        var got: [JSONValue] = [], want: [JSONValue] = []
        for c in F.list("hardware") {
            let a = c.arrayValue!
            let hw = Hardware(chip: a[0].stringValue!, memoryGB: F.num(a[1]), freeDiskGB: 1)
            let parsed = Recommendations.parseChip(hw.chip)
            got.append(.array([a[0], a[1], .string(hw.fingerprint), .string(hw.short),
                               parsed.map { .array([.int($0.generation), .string($0.tier)]) } ?? .null]))
            want.append(c)
        }
        expectEach(got, want, "hardware")
    }

    @Test func golden_summary_over_many_states() {
        let currents = F.currents(), perms = F.list("permissions")
        let cases = F.list("summaries")
        #expect(cases.count > 100)
        var got: [JSONValue] = [], want: [JSONValue] = []
        for c in cases {
            let hw = F.hardware(c["hw"])
            let checks = Recommendations.summary(hw, F.pyDict(perms[F.int(c["permissions"])]), F.installed(c["installed"]),
                                                 currents[F.int(c["current"])])
            got.append(F.checks(checks))
            want.append(c["checks"]!)
        }
        expectEach(got, want, "summary")
    }

    @Test func golden_test_verdict_over_many_results() {
        var got: [JSONValue] = [], want: [JSONValue] = []
        for c in F.list("verdicts") {
            let a = c.arrayValue!
            got.append(F.checks(Recommendations.testVerdict(F.pyDict(a[0]))))
            want.append(a[1])
        }
        expectEach(got, want, "test_verdict")
        #expect(want.count > 10)
    }
}
