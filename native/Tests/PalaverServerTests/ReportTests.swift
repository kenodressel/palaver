// Report a Problem (report.py `create`, in Swift): one zip on the Desktop with everything the maintainer needs, never
// a secret. Everything here is synthetic and in a temporary home: made-up meetings, logs and crash reports, a config
// with made-up tokens, the tests' quiet probe (nothing is asked of this Mac). Ports tests/test_report.py's tests of
// `create` and its parts; `report open` and `report usage` stay the maintainer's Python.
import Darwin
import Foundation
import Testing
import PalaverCloud
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let TZ = TimeZone(identifier: "Europe/Berlin")!
private let NOW: Date = {
    var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 30; c.hour = 14; c.minute = 5; c.second = 30
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TZ
    return cal.date(from: c)!
}()
private let OLD = "2026-10-29T10-00-00"
private let NEW = "2026-10-30T09-00-00"
private let NOTION = "secret_TOKEN_abcdef123456"
private let HF = "hf_SECRET_987654321"

private func ts(_ minutesAgo: Double) -> String { WallTime.iso(NOW.addingTimeInterval(-minutesAgo * 60), TZ, seconds: true) }

private func jsonl(_ rows: [String]) -> String { rows.map { $0 + "\n" }.joined() }

private func write(_ url: URL, _ text: String) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
}

/// test_report.py's `world`: two meetings, Palaver's logs, crash reports, a config with two tokens.
private final class World {
    let dir = tempFolder("report")
    let stores: StorePaths
    var rec: URL { dir.appendingPathComponent("Recordings", isDirectory: true) }
    var config: URL { stores.configToml }
    var desktop: URL { stores.home.appendingPathComponent("Desktop", isDirectory: true) }
    var logs: URL { stores.logs }
    var env: [String: String] = ["HOME": "/nowhere"]
    var keychain: [String: String] = [:]

    init() {
        stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                            home: dir.appendingPathComponent("home", isDirectory: true))
        let old = rec.appendingPathComponent(OLD), new = rec.appendingPathComponent(NEW)
        write(old.appendingPathComponent("session.log"), jsonl([
            #"{"ts": "\#(ts(1700))", "level": "INFO", "logger": "palaver", "event": "record_start", "trigger": "teams"}"#,
            #"{"ts": "\#(ts(1640))", "level": "WARNING", "logger": "palaver.capture_recorder", "message": "mic stalled"}"#,
            #"{"ts": "\#(ts(1600))", "level": "INFO", "logger": "palaver", "event": "transcribe_done", "seconds": 41.5, "track": "system"}"#,
            #"{"ts": "\#(ts(1590))", "level": "INFO", "logger": "palaver", "event": "notes_failed", "error": "model gone"}"#,
        ]))
        write(old.appendingPathComponent("meta.json"), #"{"start_time": "2026-10-29T10:00:00+01:00"}"#)
        write(old.appendingPathComponent("audio_problems.json"), "[]")
        write(old.appendingPathComponent("transcript.json"), #"[{"text": "the whole transcript"}]"#)
        write(old.appendingPathComponent("notes.json"), #"{"title": "Weekly"}"#)
        write(old.appendingPathComponent("mic.wav"), "RIFF" + String(repeating: "\0", count: 2000))
        write(old.appendingPathComponent("system.wav"), "RIFF" + String(repeating: "\0", count: 3000))
        write(old.appendingPathComponent("my-notes/pasted.png"), "PNG")
        write(new.appendingPathComponent("session.log"), jsonl([
            #"{"ts": "\#(ts(60))", "level": "INFO", "logger": "palaver", "event": "record_start", "trigger": "manual"}"#]))
        write(new.appendingPathComponent("meta.json"), "{}")
        write(new.appendingPathComponent("stream.json"), "{}")
        write(new.appendingPathComponent("calendar.json"), #"{"title": "Standup"}"#)
        write(new.appendingPathComponent("transcript.json"), #"[{"text": "the other transcript"}]"#)
        write(new.appendingPathComponent("system.wav.part"), String(repeating: "\0", count: 100))
        write(rec.appendingPathComponent(".jobs/notes-x.json"), #"{"pid": 1}"#)
        try! FileManager.default.createDirectory(at: rec.appendingPathComponent(".trash"), withIntermediateDirectories: true)

        write(logs.appendingPathComponent("daemon.log"),
              jsonl([#"{"ts": "\#(ts(30))", "level": "ERROR", "logger": "palaver.daemon", "message": "processing failed", "traceback": "Traceback…\nRuntimeError: diarization exploded"}"#])
              + "Writing notes with Gemma…\nwarning: notes failed: the model ran out of memory\n"
              + jsonl([#"{"ts": "\#(ts(20))", "level": "INFO", "logger": "palaver", "event": "app_start", "version": "0.1.0"}"#,
                       #"{"ts": "\#(ts(60 * 24 * 9))", "level": "ERROR", "logger": "palaver", "message": "too old for the timeline"}"#]))
        write(logs.appendingPathComponent("app.log"), "just output\n")
        write(logs.appendingPathComponent("crashes.log"),
              "=== \(ts(10)) webapp pid 7 palaver 0.1.0 argv []\nTraceback (most recent call last):\n  File x\nKeyError: 'speakers'\n\n")

        let crashes = stores.home.appendingPathComponent("Library/Logs/DiagnosticReports")
        write(crashes.appendingPathComponent("palaver-worker-2026-10-29-101010.ips"), #"{"procPath": "/x/palaver-worker"}"#)
        write(crashes.appendingPathComponent("python3.13-2026-10-29-101010.ips"), #"{"procPath": "/x/python3.13", "argv": "-m Palaver menubar"}"#)
        write(crashes.appendingPathComponent("Safari-2026-10-29-101010.ips"), #"{"procPath": "/Applications/Safari.app"}"#)
        let oldCrash = crashes.appendingPathComponent("Palaver-2026-08-01-101010.ips")
        write(oldCrash, "palaver")
        let recent = NOW.addingTimeInterval(-86400)
        for name in ["palaver-worker-2026-10-29-101010.ips", "python3.13-2026-10-29-101010.ips", "Safari-2026-10-29-101010.ips"] {
            try! FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: crashes.appendingPathComponent(name).path)
        }
        try! FileManager.default.setAttributes([.modificationDate: NOW.addingTimeInterval(-60 * 86400)], ofItemAtPath: oldCrash.path)

        write(config, "[user]\nname = \"Tess\"\n[notion]\ntoken = \"\(NOTION)\"\nparent_page_id = \"page123\"\n"
              + "[hf]\ntoken = \"\(HF)\"\n[recording]\noutput_dir = \"\(rec.path)\"\n")
        Usage.record("action", "meeting.trash", path: stores.usage)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var place: Report.Place {
        let secrets = keychain
        return Report.Place(stores: stores, configURL: config, outputDir: rec, env: env, keychainSecrets: { secrets })
    }

    @discardableResult
    func create(_ form: Report.Form = Report.Form(), now: Date = NOW, probe: ReportProbe = QuietReportProbe()) throws -> Report.Written {
        try Report.create(form, place: place, now: now, timeZone: TZ, probe: probe)
    }
}

/// The zip's entries and their contents.
private struct Unzipped {
    let entries: [ZipEntry]
    let reader: ZipReader

    init(_ url: URL) throws {
        reader = try ZipReader(url: url, maxDirectoryBytes: 1 << 24)
        entries = reader.entries
    }

    var names: Set<String> { Set(entries.map(\.name)) }
    func data(_ name: String) throws -> Data { try reader.data(entries.first { $0.name == name }!, limit: 1 << 26) }
    func text(_ name: String) throws -> String { String(decoding: try data(name), as: UTF8.self) }
    func json(_ name: String) throws -> JSONValue { try PythonJSON.parse(try data(name)) }
}

@Suite struct ReportTests {
    @Test func test_the_zip_lands_on_the_desktop_named_by_the_minute_and_shown_in_finder() throws {
        let w = World()
        let written = try w.create()
        #expect(written.path.path == w.desktop.appendingPathComponent("Palaver report 2026-10-30 14-05.zip").path)
        #expect(written.size == (try FileManager.default.attributesOfItem(atPath: written.path.path)[.size] as? Int))
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.desktop.path) == [written.path.lastPathComponent])  // no temp
        let second = try w.create()
        #expect(second.path.lastPathComponent == "Palaver report 2026-10-30 14-05 (2).zip")
    }

    @Test func test_the_manifest_lists_every_file_in_the_zip() throws {
        let w = World()
        let z = try Unzipped(try w.create().path)
        let manifest = try z.text("MANIFEST.txt")
        for name in z.names { #expect(manifest.contains(name), "\(name)") }
        for expected in ["report.json", "settings.json", "doctor.txt", "timeline.txt", "usage-summary.json", "usage/usage.jsonl",
                         "system/audio-devices.json", "system/permissions.json", "system/memory.json", "logs/daemon.log",
                         "logs/app.log", "logs/crashes.log", "jobs/notes-x.json", "meetings/LISTING.txt"] {
            #expect(z.names.contains(expected), "\(expected)")
        }
        #expect(manifest.hasPrefix("Palaver report, 2026-10-30 14:05 — bug\n\n"))
        #expect(manifest.contains("MANIFEST.txt") && manifest.hasSuffix("this list\n"))
    }

    @Test func test_a_config_with_a_token_never_ends_up_in_the_zip() throws {
        let w = World()
        let envToken = "env_OPENAI_api_key_value"
        let keychainToken = "keychain-only-notion-token"
        w.env["OPENAI_API_KEY"] = envToken
        w.keychain = [Tokens.NOTION: keychainToken]
        write(w.logs.appendingPathComponent("daemon.log"), "oops, printed \(NOTION) and \(HF), \(envToken), \(keychainToken)\n")
        write(w.rec.appendingPathComponent(NEW).appendingPathComponent("session.log"), #"{"ts": "\#(ts(5))", "message": "\#(HF)"}"# + "\n")
        let z = try Unzipped(try w.create(Report.Form(meeting: NEW)).path)
        for name in z.names {
            let data = try z.data(name)
            for secret in [NOTION, HF, envToken, keychainToken] {
                #expect(data.range(of: Data(secret.utf8)) == nil, "\(name)")
            }
        }
        #expect(try z.text("logs/daemon.log").contains("(secret removed)"))
        let settings = try z.json("settings.json")
        #expect(settings["config"]?["notion_token"] == .string("(set)"))
        #expect(settings["config"]?["hf_token"] == .string("(set)"))
        #expect(settings["config_toml"]?["notion"]?["token"] == .string("(set)"))
        #expect(settings["config_toml"]?["notion"]?["parent_page_id"] == .string("page123"))  // not a secret: kept
        #expect(settings["config"]?["user_name"] == .string("Tess"))
        #expect(settings["secret_environment"] == .object([("OPENAI_API_KEY", .string("(set)"))]))
    }

    @Test func test_redact_names_set_and_unset_secrets_by_their_key() {
        var found: [String] = []
        let out = ReportSecrets.redact(.object([("api_key", .string("")), ("Password", .null),
                                                ("nested", .object([("client_secret", .string("abcdefg"))])), ("keep", .int(1))]), &found)
        #expect(out == .object([("api_key", .string("(not set)")), ("Password", .string("(not set)")),
                                ("nested", .object([("client_secret", .string("(set)"))])), ("keep", .int(1))]))
        #expect(found == ["", "abcdefg"])
    }

    @Test func test_every_meeting_gives_its_small_files_and_the_chosen_one_all_but_audio() throws {
        let w = World()
        let names = try Unzipped(try w.create(Report.Form(meeting: OLD)).path).names
        for n in ["session.log", "meta.json", "stream.json", "calendar.json"] { #expect(names.contains("meetings/\(NEW)/\(n)")) }
        #expect(!names.contains("meetings/\(NEW)/transcript.json"))  // not chosen
        for n in ["transcript.json", "notes.json", "audio_problems.json", "my-notes/pasted.png"] {
            #expect(names.contains("meetings/\(OLD)/\(n)"), "\(n)")
        }
        #expect(!names.contains { $0.hasSuffix(".wav") || $0.hasSuffix(".part") })
    }

    @Test func test_the_chosen_meetings_audio_goes_in_only_when_ticked() throws {
        let w = World()
        let z = try Unzipped(try w.create(Report.Form(meeting: OLD, audio: true)).path)
        #expect(z.names.isSuperset(of: ["meetings/\(OLD)/mic.wav", "meetings/\(OLD)/system.wav"]))
        #expect(z.entries.first { $0.name == "meetings/\(OLD)/system.wav" }?.method == 0)  // stored
        #expect(try z.data("meetings/\(OLD)/system.wav").count == 3004)
        #expect(!z.names.contains("meetings/\(NEW)/system.wav.part"))  // another meeting's audio never
    }

    @Test func test_what_left_the_mac_and_what_mcp_clients_read_go_in() throws {
        let w = World()
        write(w.stores.accessLog, #"{"provider": "anthropic", "feature": "notes"}"# + "\n")
        write(w.stores.mcpAccess, #"{"tool": "get_meeting"}"# + "\n")
        let names = try Unzipped(try w.create().path).names
        #expect(names.isSuperset(of: ["data/access-log.jsonl", "data/mcp-access.jsonl"]))
    }

    @Test func test_crash_reports_of_palaver_processes_from_the_last_30_days() throws {
        let w = World()
        let names = try Unzipped(try w.create().path).names.filter { $0.hasPrefix("crash-reports/") }.sorted()
        #expect(names == ["crash-reports/palaver-worker-2026-10-29-101010.ips", "crash-reports/python3.13-2026-10-29-101010.ips"])
    }

    @Test func test_the_timeline_merges_the_last_weeks_problems_and_events_by_time() throws {
        let w = World()
        let lines = try Unzipped(try w.create().path).text("timeline.txt").components(separatedBy: "\n")
        let text = lines.joined(separator: "\n")
        #expect(!text.contains("too old for the timeline"))
        let order = ["record_start trigger=teams", "mic stalled", "notes_failed", "record_start trigger=manual",
                     "diarization exploded", "warning: notes failed", "app_start", "KeyError: 'speakers'"].map { needle in
            lines.firstIndex { $0.contains(needle) } ?? -1
        }
        #expect(!order.contains(-1) && order == order.sorted(), "\(order)")
        #expect(lines.contains { $0.contains("CRASH") && $0.contains("webapp") })
        #expect(text.contains("meetings/\(OLD)") && text.contains("daemon.log"))
        #expect(lines.contains { $0.contains("transcribe_done seconds=41.5 track=system") })
    }

    @Test func test_a_message_repeating_every_few_seconds_is_one_line_with_its_count() {
        var lines = [0, 10, 20].map { "2026-10-30 08:58:\(String(format: "%02d", $0))  ERROR    daemon.log  GET /api/meetings/x failed" }
        lines.append("2026-10-30 08:59:00  WARNING  daemon.log  mic stalled")
        #expect(ReportTimeline.collapseRepeats(lines) == [
            "2026-10-30 08:58:00  ERROR    daemon.log  GET /api/meetings/x failed  (×3, until 08:58:20)",
            "2026-10-30 08:59:00  WARNING  daemon.log  mic stalled"])
    }

    @Test func test_report_json_has_the_form_the_versions_and_this_mac() throws {
        struct Git: ReportProbe {
            let quiet = QuietReportProbe()
            func doctor(configURL: URL) throws -> String { try quiet.doctor(configURL: configURL) }
            func hardware() throws -> JSONValue { try quiet.hardware() }
            func models() throws -> JSONValue { try quiet.models() }
            func audioDevices() throws -> JSONValue { try quiet.audioDevices() }
            func permissions(outputDir: URL) throws -> JSONValue { try quiet.permissions(outputDir: outputDir) }
            func memory(config: Config) throws -> JSONValue { try quiet.memory(config: config) }
            func processes() throws -> String { "" }
            func git() throws -> JSONValue { .object([("commit", .string("abc1234def")), ("dirty", .bool(true)), ("branch", .string("master"))]) }
        }
        let w = World()
        let z = try Unzipped(try w.create(Report.Form(kind: "wish", text: "A dark menu bar icon", meeting: NEW), probe: Git()).path)
        let r = try z.json("report.json"), summary = try z.json("usage-summary.json")
        #expect(r["form"] == .object([("kind", .string("wish")), ("text", .string("A dark menu bar icon")), ("meeting", .string(NEW)),
                                      ("audio", .bool(false))]))
        #expect(r["palaver"] == .object([("version", .string(Exchange.palaverVersion)), ("commit", .string("abc1234def")),
                                         ("dirty", .bool(true)), ("branch", .string("master"))]))
        #expect(r["hardware"]?["chip"] == .string("Test chip"))
        #expect((r["disk"]?["free_gb"]?.doubleValue ?? 0) > 0)
        #expect(r["daemon"] == .string("daemon has never run"))
        #expect(r["recordings"]?["meetings"] == .int(2))
        #expect(r["user"] == .string("Tess") && r["via"] == .string("window") && r["created"] == .string("2026-10-30T14:05:30+01:00"))
        #expect(r["last_errors"]?.arrayValue?.contains { $0.stringValue?.contains("diarization exploded") ?? false } == true)
        #expect(summary["features"]?["action:meeting.trash"]?["all"] == .int(1))
        #expect(summary["never_used"]?.arrayValue?.contains(.string("cli:doctor")) == true)
    }

    @Test func test_a_question_this_mac_cannot_answer_is_written_down_not_raised() throws {
        struct Failure: Error, CustomStringConvertible { let description: String }
        struct Broken: ReportProbe {
            let quiet = QuietReportProbe()
            func doctor(configURL: URL) throws -> String { throw Failure(description: "no CoreAudio") }
            func hardware() throws -> JSONValue { throw Failure(description: "sysctl gone") }
            func models() throws -> JSONValue { try quiet.models() }
            func audioDevices() throws -> JSONValue { try quiet.audioDevices() }
            func permissions(outputDir: URL) throws -> JSONValue { try quiet.permissions(outputDir: outputDir) }
            func memory(config: Config) throws -> JSONValue { try quiet.memory(config: config) }
            func processes() throws -> String { "" }
            func git() throws -> JSONValue { .object([]) }
        }
        let w = World()
        let z = try Unzipped(try w.create(probe: Broken()).path)
        #expect(try z.text("doctor.txt").contains("Failure: no CoreAudio"))
        #expect(try z.json("report.json")["hardware"] == .object([("error", .string("Failure: sysctl gone"))]))
    }

    @Test func test_a_meeting_that_does_not_exist_is_refused() throws {
        let w = World()
        #expect(throws: BadRequest.self) { try w.create(Report.Form(meeting: "../../etc")) }
        #expect(throws: BadRequest.self) { try w.create(Report.Form(meeting: "2026-01-01T00-00-00")) }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: w.desktop.path)) ?? []).isEmpty)
    }

    @Test func test_creating_a_report_is_counted() throws {
        let w = World()
        try w.create(Report.Form(kind: "bug", meeting: OLD))
        let last = Usage.read(w.stores.usage).last!
        #expect(last["kind"] == .string("report") && last["meeting"] == .bool(true) && last["via"] == .string("window"))
        #expect(last["what"] == .string("bug") && last["audio"] == .bool(false))
    }

    @Test func test_the_form_accepts_a_bug_or_a_wish_and_nothing_else() throws {
        let form = try Report.Form(json: .object([("kind", .string("wish")), ("text", .string("x")), ("meeting", .string("")),
                                                  ("audio", .bool(true))]))
        #expect(form == Report.Form(kind: "wish", text: "x", meeting: nil, audio: true))
        #expect(try Report.Form(json: .object([])) == Report.Form())
        for bad: JSONValue in [.object([("kind", .string("rant"))]), .object([("text", .int(3))]), .object([("audio", .string("yes"))]),
                               .object([("meeting", .int(1))]), .array([])] {
            #expect(throws: BadRequest.self) { try Report.Form(json: bad) }
        }
        let long = try Report.Form(json: .object([("text", .string(String(repeating: "é", count: 25_000)))]))
        #expect(long.text.unicodeScalars.count == 20_000)
    }

    @Test func sizeTextIsInMegabytesOrKilobytes() {
        #expect(Report.sizeText(48_213) == "48 KB")
        #expect(Report.sizeText(300) == "1 KB")
        #expect(Report.sizeText(3_210_000) == "3.2 MB")
        #expect(Report.grouped(1_234_567) == "1,234,567" && Report.grouped(12) == "12")
    }

    @Test func theDaemonsStatusIsOneLine() {
        let w = World()
        let file = w.stores.daemonJson
        write(file, #"{"pid": \#(getpid()), "state": "recording", "since": "2026-10-30T14:00:00+01:00", "folder": "/r/x", "queued": ["a"]}"#)
        #expect(DaemonFile.status(file) == "daemon running (pid \(getpid())): recording since 2026-10-30T14:00:00+01:00 → /r/x; transcribing, 1 queued")
        write(file, #"{"pid": 999999, "state": "idle", "updated": "2026-10-30T13:00:00+01:00"}"#)
        #expect(DaemonFile.status(file) == "daemon not running (last update 2026-10-30T13:00:00+01:00)")
    }

    @Test func theUsageCatalogHasTheWindowsTheCommandsTheSettingsAndTheMenuBar() throws {
        let w = World()
        try Usage.saveCatalog(.object([("action", .array([.string("meeting.split")]))]), path: w.stores.usageFeatures)
        let catalog = Usage.catalog(path: w.stores.usageFeatures)
        func ids(_ kind: String) -> [String] { catalog.first { $0.0 == kind }?.1 ?? [] }
        #expect(ids("action") == ["meeting.split", "menubar.reportProblem"])
        #expect(ids("cli").contains("doctor") && ids("setting").contains("record_teams"))
    }

    @Test func theHuggingFaceCacheIsListedByRepoWithItsSizeAndFiles() throws {
        let dir = tempFolder("hub")
        defer { try? FileManager.default.removeItem(at: dir) }
        write(dir.appendingPathComponent("models--mlx-community--gemma/blobs/a"), String(repeating: "x", count: 1000))
        write(dir.appendingPathComponent("models--mlx-community--gemma/blobs/b"), "y")
        write(dir.appendingPathComponent("datasets--contoso--words/blobs/c"), "z")
        write(dir.appendingPathComponent("version.txt"), "1")
        let repos = try MacReportProbe.hubCache(dir).arrayValue ?? []
        #expect(repos.map { $0["repo"]?.stringValue } == ["contoso/words", "mlx-community/gemma"])
        #expect(repos[0]["type"] == .string("dataset") && repos[1]["files"] == .int(2) && repos[1]["gb"] == .double(0.0))
        #expect(repos[1]["last_modified"]?.stringValue?.count == 19)
    }

    // MARK: - the route

    @Test func test_http_report_writes_the_zip_and_shows_it_in_finder() throws {
        let dir = tempFolder("report-route")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                                home: dir.appendingPathComponent("home", isDirectory: true))
        final class Shown: @unchecked Sendable { var urls: [URL] = [] }
        let shown = Shown()
        let report = SwiftReport(place: Report.Place(stores: stores, configURL: stores.configToml,
                                                     outputDir: dir.appendingPathComponent("Meetings", isDirectory: true), env: [:]),
                                 probe: { QuietReportProbe() }, reveal: { shown.urls.append($0) })
        let s = try TestServer(report: report, dir: dir, meetings: { root in
            write(root.appendingPathComponent(OLD).appendingPathComponent("transcript.json"), "[]")
        })
        defer { s.stop() }
        let r = s.post("/api/report", .object([("kind", .string("bug")), ("text", .string("Speakers mixed up")),
                                               ("meeting", .string(OLD)), ("audio", .bool(false))]))
        #expect(r.status == 200)
        let path = try #require(r.json?["path"]?.stringValue)
        #expect(shown.urls.map(\.path) == [path])
        #expect(path.hasPrefix(stores.home.appendingPathComponent("Desktop").path + "/Palaver report "))
        #expect(r.json?["shown"]?.stringValue == "~/Desktop/" + URL(fileURLWithPath: path).lastPathComponent)
        #expect(r.json?["name"]?.stringValue == URL(fileURLWithPath: path).lastPathComponent)
        #expect(r.json?["size_text"]?.stringValue?.hasSuffix("KB") == true && (r.json?["files"]?.doubleValue ?? 0) > 10)
        let z = try Unzipped(URL(fileURLWithPath: path))
        #expect(z.names.contains("meetings/\(OLD)/transcript.json"))
        #expect(s.log.contains("writing a problem report (bug, meeting \(OLD), audio False)"))
        #expect(s.log.contains("problem report written: \(path) ("))
    }

    @Test func theServersReportScrubsWhatOnlyTheKeychainHolds() throws {
        let dir = tempFolder("report-keychain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = [(Tokens.NOTION, "secret_notion_only_in_the_keychain"), (Tokens.HF, "hf_only_in_the_keychain_42"),
                       ("anthropic.api_key", "sk-ant-only-in-the-keychain")]
        let keychain = dir.appendingPathComponent("keychain.json")
        try Data(PythonJSON.dumps(.object(secrets.map { ($0.0, .string($0.1)) })).utf8).write(to: keychain)
        let config = dir.appendingPathComponent("config.toml")
        write(config, "[recording]\noutput_dir = \"\(dir.appendingPathComponent("Meetings").path)\"\n[calendar]\nenabled = false\n")
        let env = ["PALAVER_HOME": dir.appendingPathComponent("home").path, "XDG_CONFIG_HOME": dir.appendingPathComponent("config").path,
                   KeyStores.TEST_ENV: keychain.path, TestProbe.ENV: dir.appendingPathComponent("probe.json").path,
                   ServeMain.TEST_REVEALED: dir.appendingPathComponent("revealed").path]
        let made = ServeMain.makeApp(try ServeMain.parse(["--config", config.path, "--port", "0"]), env: env)
        write(made.stores.logs.appendingPathComponent("daemon.log"), "oops, printed " + secrets.map(\.1).joined(separator: " and ") + "\n")
        let answer = try made.report.create(.object([("kind", .string("bug")), ("text", .string("the keys"))]))
        let z = try Unzipped(URL(fileURLWithPath: try #require(answer["path"]?.stringValue)))
        for name in z.names {
            let data = try z.data(name)
            for (_, secret) in secrets { #expect(data.range(of: Data(secret.utf8)) == nil, "\(name)") }
        }
        #expect(try z.text("logs/daemon.log").contains("(secret removed)"))
        let settings = try z.json("settings.json")
        #expect(settings["config"]?["notion_token"] == .string("(set)") && settings["config"]?["hf_token"] == .string("(set)"))
    }

    @Test func aProviderKeyAloneDoesNotMakeTheNotionTokenSet() throws {
        let dir = tempFolder("report-keychain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = FileKeyStore(dir.appendingPathComponent("keychain.json"))
        try keys.write("openai.api_key", "sk-openai-in-the-keychain")
        let found = ReportSecrets.keychain(keys)
        #expect(found == ["openai.api_key": "sk-openai-in-the-keychain"])
        let stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                                home: dir.appendingPathComponent("home", isDirectory: true))
        let (snapshot, scrubbed) = ReportSecrets.snapshot(configURL: stores.configToml, stores: stores, env: [:], keychain: found)
        #expect(snapshot["config"]?["notion_token"] == .string("(not set)") && snapshot["config"]?["hf_token"] == .string("(not set)"))
        #expect(scrubbed == ["sk-openai-in-the-keychain"])
    }

    /// The report reads the Keychain through the same KeyStore as everything else: a key only the Python app's item
    /// holds is found (and copied, as at any first read), so a log that printed it is scrubbed.
    @Test func aKeyOnlyThePythonAppSavedIsScrubbedToo() throws {
        let kc = try PythonKeychain(account: "openai.api_key", value: "sk-openai-saved-by-python")
        let found = ReportSecrets.keychain(kc.store)
        #expect(found == ["openai.api_key": "sk-openai-saved-by-python"])
        #expect(kc.copied("openai.api_key"))
        let stores = StorePaths(configDir: kc.dir.appendingPathComponent("config/palaver", isDirectory: true),
                                home: kc.dir.appendingPathComponent("home", isDirectory: true))
        let (_, scrubbed) = ReportSecrets.snapshot(configURL: stores.configToml, stores: stores, env: [:], keychain: found)
        #expect(scrubbed == ["sk-openai-saved-by-python"])
    }

    @Test func test_http_report_refuses_a_bad_form() throws {
        let dir = tempFolder("report-route")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                                home: dir.appendingPathComponent("home", isDirectory: true))
        final class Shown: @unchecked Sendable { var urls: [URL] = [] }
        let shown = Shown()
        let report = SwiftReport(place: Report.Place(stores: stores, configURL: stores.configToml,
                                                     outputDir: dir.appendingPathComponent("Meetings", isDirectory: true), env: [:]),
                                 probe: { QuietReportProbe() }, reveal: { shown.urls.append($0) })
        let s = try TestServer(report: report, dir: dir)
        defer { s.stop() }
        var bad = s.post("/api/report", .object([("kind", .string("rant"))]))
        #expect(bad.status == 400 && bad.error == "bad request: kind is bug or wish")
        bad = s.post("/api/report", .object([("meeting", .string("../secrets"))]))
        #expect(bad.status == 400 && bad.error == "bad request: no meeting ../secrets")
        bad = s.post("/api/report", .array([]))
        #expect(bad.status == 400)
        #expect(shown.urls.isEmpty && !s.log.contains("problem report written"))
        #expect(!FileManager.default.fileExists(atPath: stores.home.appendingPathComponent("Desktop").path))
    }
}
