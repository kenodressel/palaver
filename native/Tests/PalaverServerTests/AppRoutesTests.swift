// The routes that pass through to the menu bar app: the stop question and Start/Stop Recording,
// Transcribe Again, the live coach, memory, updates and uninstalling, notifications. Ports their
// tests of tests/test_webapp.py, test_webapp_remote.py, test_memory_api.py, test_update_api.py and
// test_live_coach_api.py. The app is a fake: a `RecordingRemote` in this process, or `Remote` on a
// fake socket in a temporary folder.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"

/// The menu bar app as the window's server reaches it (test_webapp.py `_Recording`, `_AppRecording`).
final class FakeRecording: RecordingRemote, @unchecked Sendable {
    var asked: JSONValue?
    var why: JSONValue?
    var live: JSONValue?
    var mem: JSONValue?
    var answers: [(String, String)] = []
    var queued: [URL] = []
    /// `record(action, meeting)`; without one, the app has no Start/Stop (Refused, as api.record says).
    var onRecord: ((String, String?) throws -> JSONValue)?
    /// `start_helper(kind, key, args)`; without one, the app does not answer (CallFailed).
    var onStartHelper: ((String, String, [String]) throws -> Int32)?
    /// `watch(folder, pid)` as asked, with whether the pid led its own process group then.
    var watched: [(folder: URL, pid: Int32, ownGroup: Bool)] = []

    init(question: JSONValue? = nil, why: JSONValue? = nil) {
        asked = question
        self.why = why
    }

    func question() -> JSONValue? { asked }
    func recording() -> JSONValue? { why }
    func coach() -> JSONValue? { live }
    func memory() -> JSONValue? { mem }
    func indexing() -> JSONValue { .object([("indexing", .bool(false)), ("downloading", .bool(false))]) }
    func busy() -> Bool { false }
    func answer(choice: String, meeting: String) throws -> Bool {
        answers.append((choice, meeting))
        return meeting == MEETING
    }
    func watch(folder: URL, pid: Int32) { watched.append((folder, pid, getpgid(pid) == pid)) }
    func startHelper(kind: String, key: String, args: [String]) throws -> Int32 {
        guard let onStartHelper else { throw AppCtlClient.CallFailed("fake") }
        return try onStartHelper(kind, key, args)
    }
    /// As the daemon does: queued, its failure forgotten.
    func transcribe(folder: URL) throws -> Bool {
        queued.append(folder)
        ProcessState.clear(RecordingPaths(folder))
        return true
    }
    func record(action: String, meeting: String?) throws -> JSONValue {
        guard let onRecord else { throw Refused(AppAPI.NOT_IN_THE_APP) }
        return try onRecord(action, meeting)
    }
    /// The apps whose record switch was turned off (`switched_off`), in order.
    var off: [String] = []
    func switchedOff(app: String) { off.append(app) }
    func calendarStatus() -> JSONValue { .object([]) }
    func calendarConnect() throws -> JSONValue { .object([]) }
    func test(_ args: JSONValue, timeout: Double) throws -> JSONValue { .object([]) }
    func updateCheck() throws -> JSONValue { throw Refused(Remote.APP_GONE) }
    func updateInstall() throws -> JSONValue { throw Refused(Remote.APP_GONE) }
    func uninstall(_ args: JSONValue) throws -> JSONValue { throw Refused(Remote.APP_GONE) }
}

/// A finished meeting as test_webapp.py `_meeting` leaves it, as far as these routes look: its tracks, meta.json and
/// transcript; `transcribed: false` is `_untranscribed` (no transcript, no notes).
@discardableResult
private func meeting(_ root: URL, _ name: String = MEETING, transcribed: Bool = true) throws -> RecordingPaths {
    let paths = RecordingPaths(root.appendingPathComponent(name, isDirectory: true))
    try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
    for track in [paths.systemWav, paths.micWav] { try Data().write(to: track) }
    try Data(#"{"start_time": "2026-10-27T16:03:07+01:00", "duration_seconds": 20}"#.utf8).write(to: paths.meta)
    if transcribed { try Data("[]".utf8).write(to: paths.transcriptJson) }
    return paths
}

private func untranscribed(_ root: URL, _ reason: String, missing: [String] = [], error: String? = nil) throws -> RecordingPaths {
    let paths = try meeting(root, transcribed: false)
    try ProcessState.mark(paths, reason: reason, missing: missing, error: error)
    return paths
}

/// A flag a test flips while the server runs.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool
    init(_ on: Bool) { self.on = on }
    var value: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

@Suite struct AppRoutesTests {
    // MARK: - the stop question, Start/Stop Recording (test_webapp.py)

    @Test func test_http_the_recording_question_and_its_answers() throws {
        let asked: JSONValue = .object([("meeting", .string(MEETING)), ("reason", .string("teams")), ("minutes", .int(10)),
                                        ("message", .string("Stop recording?"))])
        let rec = FakeRecording(question: asked)
        let s = try TestServer(recording: rec, meetings: { try meeting($0) })
        defer { s.stop() }
        let q = s.get("/api/recording/question")
        #expect(q.status == 200 && q.json == .object([("question", asked), ("recording", .null)]))
        let kept = s.post("/api/recording/keep", .object([("meeting", .string(MEETING))]))
        #expect(kept.status == 200 && kept.json == .object([("kept", .string(MEETING))]))
        let stopped = s.post("/api/recording/stop", .object([("meeting", .string(MEETING))]))
        #expect(stopped.status == 200 && stopped.json == .object([("stopped", .string(MEETING))]))
        #expect(rec.answers.map { "\($0.0) \($0.1)" } == ["keep \(MEETING)", "stop \(MEETING)"])
        let gone = s.post("/api/recording/stop", .object([("meeting", .string("2026-10-27T09-00-00"))]))
        #expect(gone.status == 400 && gone.error?.contains("no longer") == true)
        let none = s.post("/api/recording/stop")
        #expect(none.status == 400 && none.error == "bad request: 'meeting'")
    }

    @Test func test_http_the_window_starts_and_stops_a_recording() throws {
        let rec = FakeRecording()
        var asked: [String] = []
        rec.onRecord = { action, meeting in
            asked.append("\(action) \(meeting ?? "None")")
            if action == "start" { return .object([("meeting", .string(MEETING))]) }
            if meeting != MEETING { throw Refused(AppAPI.NO_LONGER_RUNNING) }
            return .object([("stopped", .string(MEETING))])
        }
        let s = try TestServer(recording: rec, meetings: { try meeting($0) })
        defer { s.stop() }
        let started = s.post("/api/recording/start")
        #expect(started.status == 200 && started.json == .object([("meeting", .string(MEETING))]))
        let ended = s.post("/api/recording/end", .object([("meeting", .string(MEETING))]))
        #expect(ended.status == 200 && ended.json == .object([("stopped", .string(MEETING))]))
        let other = s.post("/api/recording/end", .object([("meeting", .string("2026-10-27T09-00-00"))]))
        #expect(other.status == 400 && other.error?.contains("no longer") == true)
        #expect(asked == ["start None", "stop \(MEETING)", "stop 2026-10-27T09-00-00"])
    }

    @Test func test_http_no_recording_question_outside_the_menu_bar_app() throws {
        let s = try TestServer(meetings: { try meeting($0) })
        defer { s.stop() }
        #expect(s.get("/api/recording/question").json == .object([("question", .null), ("recording", .null)]))
        #expect(s.post("/api/recording/stop", .object([("meeting", .string(MEETING))])).status == 400)
        let start = s.post("/api/recording/start")
        #expect(start.status == 400 && start.error?.contains("menu bar app") == true)
    }

    @Test func test_http_says_why_the_running_recording_records() throws {
        let why: JSONValue = .object([("meeting", .string(MEETING)),
                                      ("text", .string("Recording · Teams call since 16:03 · mic AirPods (24 kHz)"))])
        let s = try TestServer(recording: FakeRecording(why: why), meetings: { try meeting($0) })
        defer { s.stop() }
        #expect(s.get("/api/recording/question").json == .object([("question", .null), ("recording", why)]))
    }

    /// Stopped from the menu: the recorder is done (no .part, meta.json written), but the live worker takes another
    /// minute. The window must not offer Stop for it any more.
    @Test func test_a_stopped_recording_whose_live_worker_still_finishes_is_no_longer_stoppable() throws {
        let rec = FakeRecording()
        rec.onRecord = { _, _ in throw Refused(AppAPI.NO_LONGER_RUNNING) }  // the app answers as it does once it ended
        var folder: URL?
        let s = try TestServer(recording: rec, meetings: { folder = try meeting($0).folder })
        defer { s.stop() }
        let live = try fakeLiveWorker(folder!)
        defer { live.terminate(); live.waitUntilExit() }
        let listed = s.get("/api/meetings").json?.arrayValue?.first
        #expect(listed?["status"] == .string("recording") && listed?["finishing"] == .bool(true))  // the live view stays
        #expect(s.get("/api/meetings/\(MEETING)").json?["finishing"] == .bool(true))
        let stopped = s.post("/api/recording/end", .object([("meeting", .string(MEETING))]))
        #expect(stopped.status == 200 && stopped.json == .object([("stopped", .string(MEETING))]))
        let unknown = s.post("/api/recording/end")  // which one is unknown: say so
        #expect(unknown.status == 400 && unknown.error?.contains("no longer running") == true)
    }

    // MARK: - Transcribe Again (test_webapp.py)

    @Test func test_a_failed_transcription_shows_why_and_can_be_transcribed_again() throws {
        let rec = FakeRecording()
        var folder: URL?
        let s = try TestServer(recording: rec, meetings: {
            folder = try untranscribed($0, ProcessState.error, error: "Unable to reach MTLCompilerService").folder
        })
        defer { s.stop() }
        let page = s.get("/api/meetings/\(MEETING)").json
        #expect(page?["status"] == .string("failed"))
        #expect(page?["untranscribed"]?["error"] == .string("Unable to reach MTLCompilerService"))
        #expect(s.get("/api/meetings").json?.arrayValue?.map { $0["status"] } == [.string("failed")])
        let first = s.post("/api/meetings/\(MEETING)/transcribe")  // the meeting's page, as GET answers it
        #expect(first.status == 200 && first.json?["status"] == .string("processing"))
        #expect(first.json?["id"] == .string(MEETING) && first.json?["untranscribed"] == .null)
        #expect(first.json == s.get("/api/meetings/\(MEETING)").json)
        #expect(rec.queued.map(\.path) == [folder!.path])
        let again = s.post("/api/meetings/\(MEETING)/transcribe")  // already on its way
        #expect(again.status == 400 && again.error?.contains("transcribed already, or being transcribed") == true)
    }

    /// The page and the Refused halves (the marker and `missing_models` are ProcessStateTests').
    @Test func test_a_meeting_waiting_for_its_models_says_which() throws {
        let rec = FakeRecording()
        let here = Flag(false)
        let s = try TestServer(recording: rec, speechHere: { here.value }, meetings: {
            _ = try untranscribed($0, ProcessState.models, missing: ["Speech models"])
        })
        defer { s.stop() }
        let page = s.get("/api/meetings/\(MEETING)").json
        #expect(page?["status"] == .string("waiting") && page?["untranscribed"]?["missing"] == .strings(["Speech models"]))
        let waiting = s.post("/api/meetings/\(MEETING)/transcribe")
        #expect(waiting.status == 400 && waiting.error?.hasPrefix("Waiting for Speech models: not downloaded yet") == true)
        #expect(waiting.error == "Waiting for Speech models: not downloaded yet. Palaver downloads it now; "
                + "the meeting is transcribed once it is done.")
        #expect(rec.queued.isEmpty)
        here.value = true
        #expect(s.post("/api/meetings/\(MEETING)/transcribe").status == 200 && rec.queued.count == 1)
    }

    /// test_setup_api.py: a meeting waiting for the speech models starts their download.
    @Test func test_transcribe_again_starts_the_missing_download() throws {
        let probe = FakeProbe()
        let s = try TestServer(recording: FakeRecording(), probe: probe, speechHere: { false }, meetings: {
            _ = try untranscribed($0, ProcessState.models, missing: ["Speech models"])
        })
        defer { s.stop() }
        let r = s.post("/api/meetings/\(MEETING)/transcribe")
        #expect(r.status == 400 && r.error?.contains("Palaver downloads it now") == true)
        #expect(until { probe.fetched == ["speech"] })
        // Here already: nothing more to fetch.
        #expect(s.post("/api/meetings/\(MEETING)/transcribe").status == 400)
        usleep(100_000)
        #expect(probe.fetched == ["speech"])
    }

    /// The server's own answer to whether the speech models are here is the probe's (the engine's, cached).
    @Test func transcribeAgainAsksTheProbeWhetherTheSpeechModelsAreHere() throws {
        let probe = FakeProbe(downloaded: ["speech"])
        let rec = FakeRecording()
        let dir = tempFolder("probe-server")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = try untranscribed(out, ProcessState.models, missing: ["Speech models"])
        let app = ServerApp(outputDir: out, userName: "Timo", stores: StorePaths(configDir: dir.appendingPathComponent("config"),
                                                                                 home: dir.appendingPathComponent("home")),
                            recording: rec, probe: probe)
        #expect(try AppAPI.transcribeAgain(app, MEETING) && rec.queued.count == 1)
        _ = try untranscribed(out, ProcessState.models, missing: ["Speech models"])
        probe.forget("speech")
        #expect(throws: Refused.self) { try AppAPI.transcribeAgain(app, MEETING) }
        #expect(until { probe.fetched == ["speech"] })
    }

    @Test func test_a_transcribed_meeting_is_not_transcribed_again() throws {
        let rec = FakeRecording()
        let s = try TestServer(recording: rec, meetings: { try meeting($0) })
        defer { s.stop() }
        #expect(s.post("/api/meetings/\(MEETING)/transcribe").status == 400)
        #expect(rec.queued.isEmpty)
        #expect(s.get("/api/meetings/\(MEETING)").json?["untranscribed"] == .null)
    }

    @Test func test_without_the_menu_bar_app_nothing_is_transcribed() throws {
        let s = try TestServer(meetings: { _ = try untranscribed($0, ProcessState.error) })
        defer { s.stop() }
        let r = s.post("/api/meetings/\(MEETING)/transcribe")
        #expect(r.status == 400 && r.error == AppAPI.NOT_TRANSCRIBED_HERE)
    }

    @Test func test_http_transcribe_again() throws {
        let rec = FakeRecording()
        let s = try TestServer(recording: rec, meetings: { _ = try untranscribed($0, ProcessState.error, error: "boom") })
        defer { s.stop() }
        let first = s.post("/api/meetings/\(MEETING)/transcribe")
        #expect(first.status == 200 && first.json?["status"] == .string("processing") && rec.queued.count == 1)
        #expect(first.json?["id"] == .string(MEETING) && first.json?["speakers"] != nil)
        let again = s.post("/api/meetings/\(MEETING)/transcribe")
        #expect(again.status == 400 && again.error?.contains("being transcribed") == true)
    }

    @Test func transcribeAgainOnlyReachesRecordingFolders() throws {
        let rec = FakeRecording()
        let s = try TestServer(recording: rec, meetings: { _ = try untranscribed($0, ProcessState.error) })
        defer { s.stop() }
        let r = s.post("/api/meetings/2026-10-27T09-00-00/transcribe")
        #expect(r.status == 404 && r.error == "not found: 2026-10-27T09-00-00")
        #expect(s.post("/api/meetings/..%2F..%2Fetc/transcribe").status == 404)
        #expect(s.post("/api/meetings/\(MEETING)/transcribe?x=1").status == 404)  // a POST matches its target as sent
        #expect(rec.queued.isEmpty)
    }

    // MARK: - over a socket (test_webapp_remote.py)

    @Test func test_http_without_a_recording_process_shows_the_page_without_live_bits() throws {
        let f = AppFolder()
        let s = try TestServer(recording: f.remote(nil), meetings: { try meeting($0) })
        defer { s.stop() }
        #expect(s.get("/api/recording/question").json == .object([("question", .null), ("recording", .null)]))
        #expect(s.get("/api/recording/coach").json == .object([("coach", .null)]))
        #expect(s.get("/api/memory").json == .object([("memory", .null)]))
        #expect(s.get("/api/search/status").json == .object([("indexing", .bool(false)), ("downloading", .bool(false))]))
        #expect(s.get("/").status == 200)
        let stop = s.post("/api/recording/stop", .object([("meeting", .string(MEETING))]))
        #expect(stop.status == 400 && stop.error?.contains("did not answer") == true)
    }

    @Test func test_http_live_bits_from_the_recording_process() throws {
        let f = AppFolder()
        let status: JSONValue = .object([
            ("state", .string("recording")), ("folder", .string("/m/\(MEETING)")), ("pid", .int(Int(getpid()))),
            ("updated", .string(Py.isoNow(timespec: "seconds"))), ("why_text", .string("Recording · manual")),
            ("stop_question", .object([("meeting", .string(MEETING)), ("reason", .string("silence"))])),
            ("indexing", .bool(true)), ("index_downloading", .int(1)),
        ])
        let remote = Remote(statePath: f.state, socketPath: f.socket)
        try Data(PythonJSON.dumps(status).utf8).write(to: f.state)
        let s = try TestServer(recording: remote, meetings: { try meeting($0) })
        defer { s.stop() }
        let answer = s.get("/api/recording/question").json
        #expect(answer?["question"]?["reason"] == .string("silence") && answer?["recording"]?["meeting"] == .string(MEETING))
        #expect(s.get("/api/search/status").json == .object([("indexing", .bool(true)), ("downloading", .bool(true))]))
    }

    // MARK: - memory (test_memory_api.py), the live coach (test_live_coach_api.py)

    @Test func test_http_memory_from_the_menu_bar_app() throws {
        let mem: JSONValue = .object([("total", .int(5 << 30)), ("app", .int(1 << 28)), ("workers", .array([])),
                                      ("budgets", .object([("live", .double(5.0))]))])
        let rec = FakeRecording()
        rec.mem = mem
        let s = try TestServer(recording: rec)
        defer { s.stop() }
        let r = s.get("/api/memory")
        #expect(r.status == 200 && r.text == PythonJSON.dumps(.object([("memory", mem)]), ensureAscii: false))
    }

    @Test func test_http_no_memory_outside_the_menu_bar_app() throws {
        for rec in [nil, FakeRecording()] as [RecordingRemote?] {
            let s = try TestServer(recording: rec)
            defer { s.stop() }
            let r = s.get("/api/memory")
            #expect(r.status == 200 && r.json == .object([("memory", .null)]))
        }
    }

    @Test func test_http_the_live_coach_of_the_running_recording() throws {
        let coach: JSONValue = .object([
            ("meeting", .string(MEETING)), ("talk", .object([("speaking", .string("me")), ("share", .double(0.62))])),
            ("text", .string("You 62 % of the last 10 min")),
            ("nudge", .object([("kind", .string("monologue")), ("text", .string("4-min monologue")), ("at", .double(610.0))])),
        ])
        let rec = FakeRecording()
        rec.live = coach
        let s = try TestServer(recording: rec, meetings: { try meeting($0) })
        defer { s.stop() }
        let r = s.get("/api/recording/coach")
        #expect(r.status == 200 && r.text == PythonJSON.dumps(.object([("coach", coach)]), ensureAscii: false))
    }

    @Test func test_no_live_coach_outside_the_menu_bar_app() throws {
        for rec in [nil, FakeRecording()] as [RecordingRemote?] {  // none, and an app without one
            let s = try TestServer(recording: rec)
            defer { s.stop() }
            #expect(s.get("/api/recording/coach").json == .object([("coach", .null)]))
        }
    }

    // MARK: - updates and uninstalling (test_update_api.py)

    @Test func test_settings_show_what_the_updater_knows_and_whether_it_checks_by_itself() throws {
        let s = try TestServer()
        defer { s.stop() }
        let update = s.app.stores.updateJson
        try FileManager.default.createDirectory(at: update.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"state": "available", "available": {"version": "0.2.0", "notes": "n"}}"#.utf8).write(to: update)
        let status = s.get("/api/update").json
        #expect(status?["state"] == .string("available") && status?["available"]?["version"] == .string("0.2.0"))
        #expect(status?["check_updates"] == .bool(true))
        #expect(s.get("/api/update").text == #"{"state": "available", "available": {"version": "0.2.0", "notes": "n"}, "check_updates": true}"#)
        try SettingsFile.update([("check_updates", .bool(false))], stores: s.app.stores)
        try FileManager.default.removeItem(at: update)
        #expect(s.get("/api/update").json == .object([("state", .string("unsupported")), ("check_updates", .bool(false))]))
        // update.json's own check_updates keeps its place; settings.json's value wins.
        try Data(#"{"check_updates": true, "state": "idle"}"#.utf8).write(to: update)
        #expect(s.get("/api/update").text == #"{"check_updates": false, "state": "idle"}"#)
        for broken in ["[1]", "{}", "{nope"] {
            try Data(broken.utf8).write(to: update)
            #expect(s.get("/api/update").json == .object([("state", .string("unsupported")), ("check_updates", .bool(false))]))
        }
    }

    @Test func test_check_and_install_go_to_the_menu_bar_app() throws {
        let f = AppFolder()
        let app = f.serve { _, _ in .ok(.object([("state", .string("downloading"))])) }
        defer { app.stop() }
        let s = try TestServer(recording: f.remote())
        defer { s.stop() }
        let r = s.post("/api/update/install")
        #expect(r.status == 200 && r.json == .object([("state", .string("downloading"))]))
        #expect(app.calls.map(\.0) == ["update_install"])
        #expect(s.post("/api/update/rm%20-rf").status == 404)
        #expect(s.post("/api/update/check").status == 200 && app.calls.map(\.0) == ["update_install", "update_check"])
    }

    @Test func test_without_the_menu_bar_app_the_window_says_so() throws {
        let s = try TestServer(recording: AppFolder().remote())
        defer { s.stop() }
        let r = s.post("/api/update/check")
        #expect(r.status == 400 && r.error == Remote.APP_GONE && r.error?.contains("does not answer") == true)
        let refused = AppFolder()
        let app = refused.serve { _, _ in .refused("an update is being installed") }
        defer { app.stop() }
        let t = try TestServer(recording: refused.remote())
        defer { t.stop() }
        #expect(t.post("/api/update/install").error == "an update is being installed")
    }

    @Test func test_uninstalling_needs_a_confirmation_and_keeps_recordings_unless_ticked() throws {
        let f = AppFolder()
        let app = f.serve { _, _ in .ok(.object([("removing", .array([]))])) }
        defer { app.stop() }
        let s = try TestServer(recording: f.remote())
        defer { s.stop() }
        let unconfirmed = s.post("/api/uninstall", .object([("models", .bool(true))]))
        #expect(unconfirmed.status == 400 && unconfirmed.error?.contains("confirmation") == true)
        #expect(s.post("/api/uninstall", .object([("confirm", .int(1))])).status == 400)  // only true itself
        #expect(s.post("/api/uninstall", .object([("confirm", .bool(true))])).status == 200)
        #expect(s.post("/api/uninstall", .object([("confirm", .bool(true)), ("models", .bool(true)),
                                                  ("recordings", .string("yes"))])).status == 200)
        // Only a real tick counts.
        #expect(app.calls.map { "\($0.0) \(PythonJSON.dumps($0.1))" } == [
            #"uninstall {"models": false, "recordings": false}"#, #"uninstall {"models": true, "recordings": false}"#])
    }

    @Test func outsideTheAppUpdatesAndUninstallingSayItIsGone() throws {
        let s = try TestServer()
        defer { s.stop() }
        #expect(s.post("/api/update/check").error == Remote.APP_GONE)
        #expect(s.post("/api/uninstall", .object([("confirm", .bool(true))])).error == Remote.APP_GONE)
        #expect(s.post("/api/uninstall").error == AppAPI.NEEDS_CONFIRMATION)  // the confirmation is asked first
    }

    // MARK: - notifications

    @Test func notificationsSayWhatTheLauncherLastWrote() throws {
        let dir = tempFolder("notify")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = dir.appendingPathComponent("palaver-1.notifications")
        var opened: [String] = []
        let s = try TestServer(openURL: { opened.append($0) }, notifyState: state.path)
        defer { s.stop() }
        #expect(s.get("/api/notifications").json == .object([("state", .string("unknown")),
                                                              ("detail", .string("Palaver can't check this itself"))]))
        for (written, shown, detail) in [("allowed\n", "granted", "allowed"), (" denied ", "denied", "not allowed"),
                                         ("not_asked", "not_asked", "not asked yet"), ("maybe", "unknown", "Palaver can't check this itself")] {
            try Data(written.utf8).write(to: state)
            #expect(s.get("/api/notifications").json == .object([("state", .string(shown)), ("detail", .string(detail))]))
        }
        try Data("allowed".utf8).write(to: state)
        let r = s.post("/api/notifications/open")
        #expect(r.status == 200 && r.json?["state"] == .string("granted"))
        #expect(opened == [AppAPI.SETTINGS_URL])
        let outside = try TestServer()  // no $PALAVER_NOTIFY_STATE: not in the app
        defer { outside.stop() }
        #expect(outside.get("/api/notifications").json?["state"] == .string("unknown"))
    }

    @Test func accessibilityIsWhatTheAppLastWroteAndItsSettingsOpen() throws {
        let dir = tempFolder("ax")
        defer { try? FileManager.default.removeItem(at: dir) }
        var trusted = false
        let file = AccessibilityStateFile(directory: dir.path, pid: 7, trusted: { [trusted] in trusted })
        var opened: [String] = []
        let s = try TestServer(openURL: { opened.append($0) }, accessibilityState: file.path)
        defer { s.stop() }
        #expect(s.get("/api/accessibility").json == .object([("state", .string("unknown"))]))  // not written yet
        file.write()
        #expect(s.get("/api/accessibility").json == .object([("state", .string("denied"))]))
        trusted = true
        AccessibilityStateFile(directory: dir.path, pid: 7, trusted: { [trusted] in trusted }).write()
        let r = s.post("/api/accessibility/open")
        #expect(r.status == 200 && r.json == .object([("state", .string("allowed"))]))
        #expect(opened == ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"])
        file.stop()
        #expect(s.get("/api/accessibility").json?["state"] == .string("unknown"))
        let outside = try TestServer()  // no $PALAVER_AX_STATE: not in the app
        defer { outside.stop() }
        #expect(outside.get("/api/accessibility").json?["state"] == .string("unknown"))
    }

    // MARK: - bodies as Python's handler reads them

}
