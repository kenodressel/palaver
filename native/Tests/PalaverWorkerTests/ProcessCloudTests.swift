// `process` with a transcription service chosen (the system track through PalaverCloud, in this process, against a
// stub service), `run`'s upload to Notion against a stub, and the notes helper at the end (still Python: a shell
// script here that writes down how it was called).
import Foundation
import PalaverCloud
import PalaverCore
@testable import PalaverDomain
@testable import PalaverWorker
import Testing

/// A stand-in for `<python> -m palaver …` (the notes helper): each call's arguments as a line in `calls.log`; `notes`
/// exits with `$NOTES_EXIT`.
private let PYTHON = """
#!/bin/sh
echo "$*" >> "$CALLS"
case " $* " in
  *" notes "*) exit "${NOTES_EXIT:-0}" ;;
esac
exit 0
"""

private let ASR_KEY = "soniox-SECRET-abcdefghijklmnopqrstuvwxyz0123"
private let NOTION_TOKEN = "secret_notion_abcdefghijklmnopqrstuvwxyz0123"
private let SONIOX = "https://api.eu.soniox.com"

/// The services on fixed cloud hosts, faked: answers by "METHOD URL" (each route's answers in turn, the last again),
/// every request kept; anything else can't be reached.
final class Services: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: [(Int, String)]] = [:]
    private var kept: [URLRequest] = []

    func on(_ route: String, _ answers: (Int, String)...) { lock.withLock { routes[route] = answers } }

    var requests: [URLRequest] { lock.withLock { kept } }

    var client: HTTPClient {
        HTTPClient(transport: { [self] request in
            let route = "\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")"
            let next: (Int, String)? = lock.withLock {
                kept.append(request)
                guard var answers = routes[route], !answers.isEmpty else { return nil }
                let a = answers.count > 1 ? answers.removeFirst() : answers[0]
                routes[route] = answers
                return a
            }
            guard let (status, body) = next else { throw URLError(.cannotConnectToHost) }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }, sleep: { _ in })
    }

    func json(_ r: URLRequest) -> JSONValue? { r.httpBody.flatMap { try? PythonJSON.parse($0) } }

    /// Soniox hearing `tokens` (its JSON list) in whatever it gets.
    func soniox(_ tokens: String) {
        on("POST \(SONIOX)/v1/files", (200, #"{"id": "f1"}"#))
        on("POST \(SONIOX)/v1/transcriptions", (200, #"{"id": "j1"}"#))
        on("GET \(SONIOX)/v1/transcriptions/j1", (200, #"{"status": "completed"}"#))
        on("GET \(SONIOX)/v1/transcriptions/j1/transcript", (200, #"{"tokens": \#(tokens)}"#))
        on("DELETE \(SONIOX)/v1/transcriptions/j1", (200, ""))
        on("DELETE \(SONIOX)/v1/files/f1", (200, ""))
    }
}

private let HEARD = #"[{"text": "From", "start_ms": 600, "end_ms": 900, "language": "en"}, {"text": " the", "start_ms": 950, "end_ms": 1100, "language": "en"}, {"text": " cloud.", "start_ms": 1150, "end_ms": 1500, "language": "en"}]"#

private struct Cloud {
    let t: Temp
    var h: Harness
    let paths: RecordingPaths
    var env: [String: String]
    let services = Services()
    let keys: FileKeyStore

    init(_ t: Temp, service: String? = "soniox") throws {
        self.t = t
        h = Harness(t)
        paths = try h.meeting(mic: track(10, loud: [(0.5, 1.5)]), system: track(10, loud: [(2.0, 4.0), (6.0, 7.0)], seed: 2))
        t.write("python", PYTHON)
        chmod(t.file("python").path, 0o755)
        env = testEnv(t)
        env["CALLS"] = t.file("calls.log").path
        keys = FileKeyStore(t.file("keychain.json"))
        try keys.write("soniox.api_key", ASR_KEY)
        if let service {
            try FileManager.default.createDirectory(at: h.stores.configDir, withIntermediateDirectories: true)
            try PythonJSON.write(.object([("engines", .object([("transcription", .string(service))]))]), to: h.stores.settings,
                                 indent: 2, ensureAscii: true)
        }
    }

    func setup(_ engine: EngineCalls, calendar: CalendarProvider? = nil) -> Pipeline.Setup {
        var s = h.setup(engine, python: t.file("python").path, calendar: calendar)
        s.python = PythonHelper(python: t.file("python").path, options: ["--config", "/c/config.toml", "--no-notify"], env: env)
        s.cloud = CloudServices(keys: keys, http: services.client, configToml: t.file("config.toml"), env: env)
        s.lm = t.file("python").path  // palaver-lm: the same script
        return s
    }

    var calls: [String] {
        ((try? String(contentsOf: t.file("calls.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    var sent: [String] { services.requests.map { "\($0.httpMethod!) \($0.url!.path)" } }
}

private let ENGINE = """
{"transcribe": {"mic.wav": [{"start": 0.5, "end": 1.5, "text": "Hallo.", "speaker": null, "words": []}],
                "system.wav": [{"start": 6.0, "end": 7.0, "text": "From this Mac.", "speaker": null, "words": []}]},
 "diarize": {"system.wav": {"turns": [{"speaker": "SPEAKER_00", "start": 1.5, "end": 8.0}], "embeddings": {"SPEAKER_00": [1.0, 0.0]}}}}
"""

private func texts(_ paths: RecordingPaths) -> [String?]? { readJSON(paths.transcriptJson)?.arrayValue?.map { $0["text"]?.stringValue } }

@Suite(.serialized) struct ProcessCloudTests {
    @Test func cloudChoiceSendsTheSystemTrackInsteadOfTheEngine() async throws {
        let t = Temp(); defer { t.remove() }
        let c = try Cloud(t)
        c.services.soniox(HEARD)
        let event = CalendarEvent(title: "Northwind sync", start: try PyDateTime.parse("2026-10-20T14:30:00+02:00"),
                                  end: try PyDateTime.parse("2026-10-20T15:00:00+02:00"), attendees: [Attendee(name: "Valerie")],
                                  uid: "northwind-sync")
        let engine = fake(ENGINE)
        #expect(try await Pipeline.process(c.paths.folder, c.setup(engine, calendar: { _, _ in [event] }), notes: false) == 0)
        #expect(c.calls.isEmpty)  // no Python
        #expect(c.sent == ["POST /v1/files", "POST /v1/transcriptions", "GET /v1/transcriptions/j1", "GET /v1/transcriptions/j1/transcript",
                           "DELETE /v1/transcriptions/j1", "DELETE /v1/files/f1"])
        #expect(c.services.requests.allSatisfy { $0.url?.host == "api.eu.soniox.com" })
        // The calendar attached first: the invitees are keyterms.
        let job = c.services.json(c.services.requests[1])
        #expect(job?["context"]?["terms"] == .strings(["Valerie"]))
        #expect(texts(c.paths) == ["Hallo.", "From the cloud."])  // the engine heard only the mic
        #expect(!engine.calls.contains("transcribe system.wav") && engine.calls.contains("transcribe mic.wav"))
        let marker = readJSON(c.paths.transcription)?["system"]
        #expect(marker?["engine"] == .string("soniox") && marker?["model"]?.stringValue != nil)
        #expect(marker?["sent_seconds"] == .double(5.0) && marker?["usd"]?.doubleValue != nil && marker?["at"]?.stringValue != nil)
        #expect(try String(contentsOf: c.paths.language, encoding: .utf8) == "en\n")
        let system = readJSON(c.paths.systemSegments)?.arrayValue?.first
        #expect(system?["start"] == .double(2.1) && system?["words"]?.arrayValue?.count == 3)
        #expect(c.h.said.contains("Transcribing system track with Soniox…") && !c.h.said.contains("Transcribing system track…"))
        let log = AccessLog.recent(nil, stores: c.h.stores)
        #expect(log.count == 1 && log[0]["track"] == .string("system") && log[0]["audio_seconds"] == .double(5.0))
        #expect(events(c.paths).contains("transcribe_start") && events(c.paths).contains("transcribe_done"))
        // Done by the service: a second run sends nothing.
        #expect(try await Pipeline.process(c.paths.folder, c.setup(fake(ENGINE)), notes: false) == 0)
        #expect(c.services.requests.count == 6)
        #expect(c.h.said.contains("Skipping system transcription (already done)"))
    }

    @Test func aMeetingKeptOnThisMacStaysHere() async throws {
        let t = Temp(); defer { t.remove() }
        let c = try Cloud(t)
        try LocalOnly.set(c.paths.folder, on: true)
        #expect(CloudChoice.provider(folder: c.paths.folder, stores: c.h.stores) == nil)
        #expect(try await Pipeline.process(c.paths.folder, c.setup(fake(ENGINE)), notes: false) == 0)
        #expect(c.services.requests.isEmpty && c.calls.isEmpty)
        #expect(texts(c.paths) == ["Hallo.", "From this Mac."])
        #expect(readJSON(c.paths.transcription)?["system"]?["engine"] == .string("local"))
    }

    @Test func cloudChoiceIsTheServiceChosenInSettings() throws {
        let t = Temp(); defer { t.remove() }
        let c = try Cloud(t)
        #expect(CloudChoice.provider(folder: c.paths.folder, stores: c.h.stores) == "soniox")
        for value in ["local", "anthropic", "nope"] {  // this Mac; a language model is no transcription service
            try PythonJSON.write(.object([("engines", .object([("transcription", .string(value))]))]), to: c.h.stores.settings,
                                 indent: 2, ensureAscii: true)
            #expect(CloudChoice.provider(folder: c.paths.folder, stores: c.h.stores) == nil)
        }
        try FileManager.default.removeItem(at: c.h.stores.settings)
        #expect(CloudChoice.provider(folder: c.paths.folder, stores: c.h.stores) == nil)
    }

    @Test func aFailedServiceFallsBackToThisMacAndSaysSo() async throws {
        let t = Temp(); defer { t.remove() }
        let c = try Cloud(t)
        c.services.on("POST \(SONIOX)/v1/files", (500, #"{"message": "down"}"#))
        let engine = fake(ENGINE)
        #expect(try await Pipeline.process(c.paths.folder, c.setup(engine), notes: false) == 0)
        #expect(c.sent == ["POST /v1/files"])  // an upload is never sent twice after a server error
        #expect(texts(c.paths) == ["Hallo.", "From this Mac."])
        let marker = readJSON(c.paths.transcription)?["system"]
        #expect(marker?["engine"] == .string("local") && marker?["fallback_from"] == .string("soniox"))
        #expect(marker?["error"] == .string("HTTP 500: down"))
        #expect(c.h.said.contains("Soniox failed (HTTP 500: down); transcribing on this Mac instead"))
        #expect(events(c.paths).contains("cloud_transcription_failed"))
        // Transcribed here after a failure: the service is asked again at the next process.
        #expect(TranscriptionMarker.wantsCloud(c.paths))
        let log = AccessLog.recent(nil, stores: c.h.stores)
        #expect(log.first?["ok"] == .bool(false))
    }

    @Test func aServiceThatIsNotSetUpFallsBackWithoutSending() async throws {
        let t = Temp(); defer { t.remove() }
        let c = try Cloud(t)
        try c.keys.delete("soniox.api_key")
        #expect(try await Pipeline.process(c.paths.folder, c.setup(fake(ENGINE)), notes: false) == 0)
        #expect(c.services.requests.isEmpty)
        #expect(readJSON(c.paths.transcription)?["system"]?["error"] == .string("Soniox: Add the API key"))
    }

    @Test func liveTextIsKeptWhenTheServiceFails() async throws {
        let t = Temp(); defer { t.remove() }
        let c = try Cloud(t)
        try Pipeline.saveSegments(c.paths.systemSegments, [Segment(start: 2, end: 4, text: "Said live.")])
        try TranscriptionMarker.write(c.paths, track: "system", info: [("engine", .string("live"))])
        c.services.on("POST \(SONIOX)/v1/files", (401, "{}"))
        let engine = fake(ENGINE)
        #expect(try await Pipeline.process(c.paths.folder, c.setup(engine), notes: false) == 0)
        #expect(!engine.calls.contains("transcribe system.wav"))
        #expect(texts(c.paths) == ["Hallo.", "Said live."])
        let marker = readJSON(c.paths.transcription)?["system"]
        #expect(marker?["engine"] == .string("live") && marker?["fallback_from"] == .string("soniox"))
        #expect((marker?["error"]?.stringValue ?? "").contains("refused the API key") && marker?["error"]?.stringValue?.contains(ASR_KEY) == false)
    }

    @Test func liveTextKeptHereIsNeverSentLater() async throws {
        let t = Temp(); defer { t.remove() }
        let c = try Cloud(t, service: nil)
        try Pipeline.saveSegments(c.paths.systemSegments, [Segment(start: 2, end: 4, text: "Said live.")])
        try TranscriptionMarker.write(c.paths, track: "system", info: [("engine", .string("live"))])
        #expect(try await Pipeline.process(c.paths.folder, c.setup(fake(ENGINE)), notes: false) == 0)
        #expect(readJSON(c.paths.transcription)?["system"]?["engine"] == .string("local"))
        // A service chosen afterwards never sends it.
        try PythonJSON.write(.object([("engines", .object([("transcription", .string("soniox"))]))]), to: c.h.stores.settings,
                             indent: 2, ensureAscii: true)
        try FileManager.default.removeItem(at: c.paths.transcriptJson)
        #expect(try await Pipeline.process(c.paths.folder, c.setup(fake(ENGINE)), notes: false) == 0)
        #expect(c.services.requests.isEmpty && texts(c.paths) == ["Hallo.", "Said live."])
    }

    @Test func fallbackWithoutSpeechModelsWaitsForThem() async throws {
        let t = Temp(); defer { t.remove() }
        let c = try Cloud(t)
        c.services.on("POST \(SONIOX)/v1/files", (500, "{}"))
        let engine = fake(#"{"fail": {"transcribe": "models missing: asr"}}"#)
        #expect(try await Pipeline.process(c.paths.folder, c.setup(engine), notes: false) == 4)
        let state = ProcessState.read(c.paths)
        #expect(state?["reason"] == .string("models") && state?["missing"] == .strings(["Speech models"]))
        #expect(c.h.said.last == "error: models missing: asr; \(c.paths.id) is transcribed once the speech models are downloaded.")
        #expect(!FileManager.default.fileExists(atPath: c.paths.transcriptJson.path))
        #expect(!FileManager.default.fileExists(atPath: c.paths.systemSegments.path))
    }

    @Test func aFallbackThatFailsFailsTheRun() async throws {
        let t = Temp(); defer { t.remove() }
        let c = try Cloud(t)
        c.services.on("POST \(SONIOX)/v1/files", (500, "{}"))
        await #expect(throws: PalaverWorker.WorkerError.self) {
            try await Pipeline.process(c.paths.folder, c.setup(fake(#"{"fail": {"transcribe": "the speech engine stopped"}}"#)), notes: false)
        }
        #expect(ProcessState.read(c.paths)?["reason"] == .string("error"))
        #expect(ProcessState.read(c.paths)?["error"] == .string("the speech engine stopped"))
        #expect(!FileManager.default.fileExists(atPath: c.paths.micSegments.path))
    }

    @Test func pendingDeletionsAreRetriedWithoutAService() async throws {
        let t = Temp(); defer { t.remove() }
        let c = try Cloud(t, service: nil)
        #expect(try await Pipeline.process(c.paths.folder, c.setup(fake(ENGINE)), notes: false) == 0)
        #expect(c.services.requests.isEmpty)  // nothing owed: nothing sent
        try PythonJSON.write(.array([.object([("provider", .string("soniox")), ("host", .string("api.eu.soniox.com")),
                                              ("what", .string("file")), ("url", .string("\(SONIOX)/v1/files/f0")),
                                              ("since", .string("2026-10-20T14:40:00+02:00")), ("error", .string("HTTP 500"))])]),
                             to: c.paths.cloudPending, indent: 2, ensureAscii: true)
        c.services.on("DELETE \(SONIOX)/v1/files/f0", (200, ""))
        for f in [c.paths.systemSegments, c.paths.transcriptJson] { try FileManager.default.removeItem(at: f) }
        #expect(try await Pipeline.process(c.paths.folder, c.setup(fake(ENGINE)), notes: false) == 0)
        #expect(c.sent == ["DELETE /v1/files/f0"] && c.services.requests[0].value(forHTTPHeaderField: "authorization") == "Bearer \(ASR_KEY)")
        #expect(!FileManager.default.fileExists(atPath: c.paths.cloudPending.path))
        #expect(texts(c.paths) == ["Hallo.", "From this Mac."])
    }

    // MARK: - run: the upload to Notion

    @Test func runUploadsToNotionAfterTheTranscript() async throws {
        let t = Temp(); defer { t.remove() }
        var c = try Cloud(t, service: nil)
        c.h.config.notionParentPageId = "parent-1"
        c.env["NOTION_TOKEN"] = NOTION_TOKEN
        c.services.on("POST https://api.notion.com/v1/pages", (429, "{}"), (200, #"{"id": "p1", "url": "https://www.notion.so/p1"}"#))
        #expect(try await Run.run(c.paths.folder, c.setup(fake(ENGINE))) == 0)
        #expect(c.sent == ["POST /v1/pages", "POST /v1/pages"])  // a rate limit is tried again
        let page = c.services.json(c.services.requests[1])
        #expect(page?["parent"] == .object([("page_id", .string("parent-1"))]))
        let rich = page?["children"]?.arrayValue?.first?["paragraph"]?["rich_text"]?.arrayValue
        #expect(rich?.first?["text"]?["content"] == .string("Timo") && rich?.first?["annotations"]?["bold"] == .bool(true))
        #expect(rich?[1]["text"]?["content"] == .string(" [14:35:17]"))
        #expect(c.services.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(NOTION_TOKEN)" })
        #expect(readJSON(c.paths.notionInfo)?["page_url"] == .string("https://www.notion.so/p1"))
        #expect(events(c.paths).contains("notion_upload_start") && events(c.paths).contains("notion_upload_done"))
        #expect(c.h.said.contains("Uploading to Notion (2 blocks)…") && c.h.said.contains("✓ https://www.notion.so/p1"))
        #expect(c.calls.isEmpty)  // no Python
    }

    @Test func runInDatabaseModeWithTheTokenFromTheKeychain() async throws {
        let t = Temp(); defer { t.remove() }
        var c = try Cloud(t, service: nil)
        c.h.config.notionMode = "database"
        c.h.config.notionDatabaseId = "db1"
        try c.keys.write("NOTION_TOKEN", NOTION_TOKEN)
        c.services.on("GET https://api.notion.com/v1/databases/db1", (200, #"{"properties": {"Titel": {"type": "title"}, "Datum": {"type": "date"}}}"#))
        c.services.on("POST https://api.notion.com/v1/pages", (200, #"{"id": "p2", "url": "https://www.notion.so/p2"}"#))
        #expect(try await Run.run(c.paths.folder, c.setup(fake(ENGINE))) == 0)
        let props = c.services.json(c.services.requests[1])?["properties"]
        #expect(props?["Datum"]?["date"]?["start"] == .string("2026-10-20T14:35:17+02:00") && props?["Titel"] != nil)
        #expect(readJSON(c.paths.notionInfo)?["page_url"] == .string("https://www.notion.so/p2"))
    }

    @Test func aRefusedUploadFailsRunAndLeavesNoNotionJson() async throws {
        let t = Temp(); defer { t.remove() }
        var c = try Cloud(t, service: nil)
        c.h.config.notionParentPageId = "parent-1"
        c.env["NOTION_TOKEN"] = NOTION_TOKEN
        c.services.on("POST https://api.notion.com/v1/pages", (400, #"{"message": "validation failed"}"#))
        await #expect(throws: NotionError.self) { try await Run.run(c.paths.folder, c.setup(fake(ENGINE))) }
        #expect(c.sent == ["POST /v1/pages"])  // a 400 is not tried again
        #expect(!FileManager.default.fileExists(atPath: c.paths.notionInfo.path))
        #expect(FileManager.default.fileExists(atPath: c.paths.transcriptMd.path))  // the transcript is there either way
        #expect(events(c.paths).contains("notion_upload_start") && !events(c.paths).contains("notion_upload_done"))
    }

    // MARK: - the notes helper

    @Test func notesHelperRunsWithoutNoNotes() async throws {
        let t = Temp(); defer { t.remove() }
        var c = try Cloud(t, service: nil)
        c.h.config.notesEnabled = true
        c.env["NOTES_EXIT"] = "1"  // a failed notes run is logged; the transcript is there either way
        #expect(try await Pipeline.process(c.paths.folder, c.setup(fake(ENGINE)), notes: true) == 0)
        #expect(c.calls == ["--config /c/config.toml --no-notify notes \(c.paths.folder.path)"])  // palaver-lm, no Python
        #expect(ProcessState.read(c.paths) == nil)
        let log = try String(contentsOf: c.paths.sessionLog, encoding: .utf8)
        #expect(log.contains("the notes helper exited with 1"))
        // Notes switched off in config.toml: no helper.
        c.h.config.notesEnabled = false
        #expect(try await Pipeline.process(c.paths.folder, c.setup(fake(ENGINE)), notes: true) == 0)
        #expect(c.calls.count == 1)
    }

    @Test func notesThatAreUpToDateNeedNoHelper() async throws {
        let t = Temp(); defer { t.remove() }
        var c = try Cloud(t, service: nil)
        c.h.config.notesEnabled = true
        #expect(try await Pipeline.process(c.paths.folder, c.setup(fake(ENGINE)), notes: false) == 0)
        let utterances = try Pipeline.readList(c.paths.transcriptJson).map { try Utterance(json: $0) }
        try PythonJSON.write(.object([("title", .string("Sync")), ("transcript_hash", .string(Notes.transcriptHash(utterances)))]),
                             to: c.paths.notes, indent: 2, ensureAscii: false)
        #expect(try await Pipeline.process(c.paths.folder, c.setup(fake(ENGINE)), notes: true) == 0)
        #expect(c.calls.isEmpty)
        #expect(c.h.said.contains("Notes are up to date"))
    }

    @Test func test_process_can_leave_the_notes_for_later() async throws {
        // The app transcribes right away (--no-notes) but writes notes when no call records.
        let t = Temp(); defer { t.remove() }
        let c = try Cloud(t, service: nil)
        t.write("engine.json", ENGINE)
        t.write("config.toml", "[user]\nname = \"Timo\"\n[recording]\noutput_dir = \"\(c.h.config.outputDir.path)\"\n[calendar]\nenabled = false\n")
        var env = c.env
        env[FakeEngine.ENV] = t.file("engine.json").path
        env["PALAVER_LM_BIN"] = t.file("python").path  // palaver-lm: the same script
        let head = ["--config", t.file("config.toml").path, "--no-notify"]
        #expect(await WorkerMain.run(head + ["process", c.paths.folder.path, "--no-notes"], env: env) == 0)
        #expect(c.calls.isEmpty)
        #expect(await WorkerMain.run(head + ["process", c.paths.folder.path], env: env) == 0)
        #expect(c.calls == ["--config \(t.file("config.toml").path) --no-notify notes \(c.paths.folder.path)"])
    }
}

/// How the worker runs its Python helpers (Batch B review): in its own process group, stderr read until the helper
/// exits plus a bounded drain.
@Suite struct PythonHelperTests {
    private func helper(_ t: Temp, _ script: String) -> PythonHelper {
        t.write("python", "#!/bin/sh\n" + script)
        chmod(t.file("python").path, 0o755)
        var env = testEnv(t)
        env["OUT"] = t.file("out").path
        return PythonHelper(python: t.file("python").path, env: env)
    }

    @Test func aHelperStaysInTheWorkersProcessGroup() throws {
        let t = Temp(); defer { t.remove() }
        let done = try helper(t, "/bin/ps -o pgid= -p $$ > \"$OUT\"\necho \"last words\" >&2\nexit 7\n").run([])
        #expect(done.code == 7)
        #expect(done.lastError == "last words")
        #expect(Int32(Py.strip(try String(contentsOf: t.file("out"), encoding: .utf8))) == getpgrp())
    }

    @Test func somethingTheHelperLeftHoldingStderrDoesNotHoldTheWorker() throws {
        let t = Temp(); defer { t.remove() }
        let started = Date()
        let done = try helper(t, "/bin/sleep 60 >&2 &\necho $! > \"$OUT\"\necho \"done\" >&2\nexit 0\n").run([])
        defer { if let pid = Int32(Py.strip((try? String(contentsOf: t.file("out"), encoding: .utf8)) ?? "")) { kill(pid, SIGKILL) } }
        #expect(done.code == 0 && done.lastError == "done")
        #expect(Date().timeIntervalSince(started) < 30)  // not the sleep's 60 s
    }

    @Test func aHelperThatCannotStartIsAnError() {
        let t = Temp(); defer { t.remove() }
        #expect(throws: PalaverWorker.WorkerError.self) { try PythonHelper(python: t.file("missing").path, env: testEnv(t)).run([]) }
    }
}
