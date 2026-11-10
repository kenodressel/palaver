// `palaver-worker coach <folder>` (tests/test_coach_worker.py, tests/test_coach_notifications.py): the live coach as
// a worker of its own. It writes <folder>/coach.json every second (talk, talk_text, nudge, quiet), ends with the
// recording or on SIGTERM, and tells each new nudge once: a session.log line (kind and time, never the text) and a
// quiet notification that names nobody. Synthetic audio only, no calendar, notifications through a fake sender.
import Darwin
import Foundation
import PalaverCore
@testable import PalaverDomain
@testable import PalaverWorker
import Testing

private let SR = 16_000

/// Noise at about -24 dBFS: the voice activity takes it for speech.
private func speech(_ seconds: Double, seed: UInt64 = 5) -> [Int16] {
    var state = seed
    return (0..<Int(seconds * Double(SR))).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let u = Double(state >> 11) / Double(1 << 53) * 2 - 1
        return Int16(u * 3400)
    }
}

private func waitFor(_ timeout: Double = 10, _ cond: () -> Bool) -> Bool {
    let end = Date(timeIntervalSinceNow: timeout)
    while Date() < end {
        if cond() { return true }
        usleep(20_000)
    }
    return cond()
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func noNames(_ paths: RecordingPaths, _ invitees: [String]) -> (talk: PyDict<Double>, names: PyDict<String>) {
    (PyDict(), PyDict())
}

/// `run_coach` on a thread of its own, as the tests' threading.Thread.
private final class Running: @unchecked Sendable {
    let stop = StopEvent()
    let done = StopEvent()
    private let lock = NSLock()
    private var _result: Int32?
    var result: Int32? { lock.withLock { _result } }

    init(_ body: @escaping (StopEvent) -> Int32) {
        let stop = self.stop
        Thread { [self] in
            let rc = body(stop)
            lock.withLock { _result = rc }
            done.set()
        }.start()
    }

    /// Stops it (SIGTERM's flag) if it still runs; whether it ended in time.
    @discardableResult
    func finish(_ timeout: Double = 10) -> Bool {
        stop.set()
        return done.wait(timeout)
    }
}

private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CoachNotification] = []
    var all: [CoachNotification] { lock.withLock { items } }
    func add(_ n: CoachNotification) { lock.withLock { items.append(n) } }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Nudge] = []
    var all: [Nudge] { lock.withLock { items } }
    func add(_ n: Nudge) { lock.withLock { items.append(n) } }
}

private func logRows(_ folder: URL) -> [JSONValue] {
    ((try? String(contentsOf: RecordingPaths(folder).sessionLog, encoding: .utf8)) ?? "").split(separator: "\n")
        .map { try! PythonJSON.parse(Data($0.utf8)) }
}

/// A recording folder whose mic track has a header and is never written to.
private func idleRecording(_ folder: URL) -> RecordingPaths {
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let paths = RecordingPaths(folder)
    appendPart(partURL(paths.micRawWav), [])
    return paths
}

@Suite struct CoachWorkerTests {
    @Test func test_coach_worker_writes_status() throws {
        let t = Temp(); defer { t.remove() }
        let folder = t.file("2026-11-07T10-00-00")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paths = RecordingPaths(folder)
        appendPart(partURL(paths.micRawWav), speech(20))
        appendPart(partURL(paths.systemWav), [Int16](repeating: 0, count: 20 * SR))
        let coach = LiveCoach(folder: folder, names: noNames)
        let run = Running { stop in
            LiveCoachRunner.run(folder: folder, coach: coach, stop: stop, every: 0.05, contextAfter: 3600,
                                parentAlive: { true })
        }
        defer { run.finish() }
        var status: JSONValue?
        #expect(waitFor {
            status = PythonJSON.read(LiveCoachRunner.coachPath(folder))
            return status?["talk"]?.truthy == true
        })
        let s = try #require(status)
        guard case .object(let fields) = s else { Issue.record("coach.json is no object"); return }
        #expect(fields.map(\.0).sorted() == ["nudge", "quiet", "talk", "talk_text"])
        #expect(s["talk"]?["speaking"] == .string("me"))
        #expect(s["talk_text"] == .str(VoiceActivity.talkText(s["talk"])))
        #expect(s["nudge"] == .null && s["quiet"] == .array([]))
        #expect(!exists(folder.appendingPathComponent("coach.json.tmp")))  // written atomically
        // The recording ends: both tracks final, meta.json there: the worker ends by itself.
        finalizePart(paths.micRawWav)
        finalizePart(paths.systemWav)
        t.write("2026-11-07T10-00-00/meta.json", "{}")
        #expect(run.done.wait(10))
        #expect(run.result == 0)
        #expect(!exists(LiveCoachRunner.coachPath(folder)))
    }

    @Test func test_coach_worker_ends_on_sigterm_flag() {
        let t = Temp(); defer { t.remove() }
        let folder = t.file("rec")
        _ = idleRecording(folder)
        let coach = LiveCoach(folder: folder, names: noNames)
        let run = Running { stop in
            LiveCoachRunner.run(folder: folder, coach: coach, stop: stop, every: 0.05, contextAfter: 3600, parentAlive: { true })
        }
        #expect(waitFor { exists(LiveCoachRunner.coachPath(folder)) })
        #expect(PythonJSON.read(LiveCoachRunner.coachPath(folder))
                == .object([("talk", .null), ("talk_text", .null), ("nudge", .null), ("quiet", .array([]))]))
        #expect(run.finish())
        #expect(run.result == 0 && !exists(LiveCoachRunner.coachPath(folder)))
    }

    @Test func test_nudge_switches_come_from_settings() throws {
        let t = Temp(); defer { t.remove() }
        let stores = StorePaths(configDir: t.file("config"), home: t.file("home"))
        var s = SettingsValues()
        s.nudgeMonologue = false
        #expect(Nudges.enabledKinds(s)["monologue"] == false)
        let switches = LiveCoachRunner.settingsSwitches(ttl: 0, stores: stores)
        #expect(switches()["monologue"] == true)
        try SettingsFile.update([("nudge_monologue", .bool(false))], stores: stores)
        #expect(switches()["monologue"] == false)
    }

    @Test func test_the_coach_command_is_parsed() throws {
        let o = try WorkerMain.parse(["coach", "/x/rec"])
        #expect(o.command == "coach" && o.args == ["/x/rec"])
        #expect(try WorkerMain.folderArgument(o).path == "/x/rec")
    }

    @Test func test_coach_worker_ends_when_its_parent_is_gone() {
        let t = Temp(); defer { t.remove() }
        let folder = t.file("rec")
        _ = idleRecording(folder)
        let alive = StopEvent()  // set: the parent is gone
        let coach = LiveCoach(folder: folder, names: noNames)
        let run = Running { stop in
            LiveCoachRunner.run(folder: folder, coach: coach, stop: stop, every: 0.02, contextAfter: 3600,
                                parentAlive: { !alive.isSet }, log: { _ in })
        }
        defer { run.finish() }
        #expect(waitFor { exists(LiveCoachRunner.coachPath(folder)) })
        alive.set()
        #expect(run.done.wait(10))
        #expect(run.result == 0 && !exists(LiveCoachRunner.coachPath(folder)))
    }

    @Test func test_coach_worker_ends_when_the_recording_stops_growing() {
        let t = Temp(); defer { t.remove() }
        let folder = t.file("rec")
        _ = idleRecording(folder)
        let coach = LiveCoach(folder: folder, names: noNames)
        let run = Running { stop in
            LiveCoachRunner.run(folder: folder, coach: coach, stop: stop, every: 0.02, contextAfter: 3600, stall: 0.3,
                                parentAlive: { true }, log: { _ in })
        }
        defer { run.finish() }
        #expect(run.done.wait(10))  // the .part never grows and is never finished
        #expect(run.result == 0 && !exists(LiveCoachRunner.coachPath(folder)))
    }

    @Test func test_coach_worker_keeps_going_while_the_recording_grows() {
        let t = Temp(); defer { t.remove() }
        let folder = t.file("rec")
        let paths = idleRecording(folder)
        let coach = LiveCoach(folder: folder, names: noNames)
        let run = Running { stop in
            LiveCoachRunner.run(folder: folder, coach: coach, stop: stop, every: 0.02, contextAfter: 3600, stall: 0.5,
                                parentAlive: { true }, log: { _ in })
        }
        for _ in 0..<30 {
            appendPart(partURL(paths.micRawWav), [Int16](repeating: 0, count: 160))
            usleep(30_000)
        }
        #expect(!run.done.isSet)
        #expect(run.finish())
    }

    @Test func test_coach_worker_ends_when_the_folder_is_gone() {
        let t = Temp(); defer { t.remove() }
        let folder = t.file("rec")
        _ = idleRecording(folder)
        let coach = LiveCoach(folder: folder, names: noNames)
        let run = Running { stop in
            LiveCoachRunner.run(folder: folder, coach: coach, stop: stop, every: 0.02, contextAfter: 3600, parentAlive: { true })
        }
        defer { run.finish() }
        #expect(waitFor { exists(LiveCoachRunner.coachPath(folder)) })
        // Gone at once (moved to the trash), so no write of the coach races a removal of its contents.
        #expect(rename(folder.path, t.file("trashed").path) == 0)
        #expect(run.done.wait(10))
        #expect(!exists(LiveCoachRunner.coachPath(folder)))
    }

    @Test func theVoicesHeardSoFarGetTheirNames() throws {
        // live_names: the live worker's voices, named by the voice bank and by names given while recording.
        let t = Temp(); defer { t.remove() }
        let folder = t.file("rec")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paths = RecordingPaths(folder)
        let bank = VoiceBank(directory: t.file("voices"))
        #expect(try Speakers.liveNames(paths, invitees: ["Valerie"], bank: bank).talk.isEmpty)  // no live.json yet
        try bank.add("Valerie", [1, 0, 0], source: "earlier:SPEAKER_00")
        t.write("rec/live.json", """
            {"turns": [{"speaker": "SPEAKER_00", "start": 0.0, "end": 60.0}, {"speaker": "SPEAKER_01", "start": 60.0, "end": 90.0}],
             "embeddings": {"SPEAKER_00": [1.0, 0.0, 0.0], "SPEAKER_01": [0.0, 1.0, 0.0]}}
            """)
        t.write("rec/speakers_live.json", #"[{"name": "Timo Strau\u00df", "embedding": [0.0, 1.0, 0.0]}]"#)
        let (byVoice, names) = try Speakers.liveNames(paths, invitees: ["Valerie Vogt"], bank: bank)
        #expect(byVoice["SPEAKER_00"] == 60 && byVoice["SPEAKER_01"] == 30)
        #expect(names["SPEAKER_00"] == "Valerie" && names["SPEAKER_01"] == "Timo Strauß")
    }

    // MARK: - nudges as quiet notifications (#19), tests/test_coach_notifications.py

    @Test func test_the_coach_tells_each_nudge_once() {
        let t = Temp(); defer { t.remove() }
        let clock = TestClock(), seen = Seen()
        let coach = LiveCoach(folder: t.url, clock: clock.callAsFunction, names: noNames, onNudge: seen.add)
        for now in [0.0, 1, 2, 60, 119] {
            clock.now = now
            coach.update(talk: talk(monologue: 200), mine: [])
        }
        #expect(seen.all.map(\.kind) == ["monologue"])
        clock.now = Nudges.NUDGE_EVERY + 1  // the next one only after three minutes
        coach.update(talk: talk(share: 0.8, monologue: 200), mine: [])
        #expect(seen.all.map(\.kind) == ["monologue", "talk_share"])
    }

    @Test func test_a_kind_switched_off_is_not_told() {
        let t = Temp(); defer { t.remove() }
        let seen = Seen()
        let coach = LiveCoach(folder: t.url, enabled: { ["monologue": false] }, clock: TestClock().callAsFunction,
                              names: noNames, onNudge: seen.add)
        coach.update(talk: talk(monologue: 200), mine: [])
        #expect(seen.all.isEmpty)
        #expect(coach.status()["nudge"] == .null)
    }

    @Test func test_a_nudge_becomes_a_notification_and_a_log_line() throws {
        let t = Temp(); defer { t.remove() }
        let folder = t.file("2026-11-07T10-00-00")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sent = Sent()
        let tell = LiveCoachRunner.nudgeNotifier(folder, show: { true }, send: sent.add)
        tell(Nudge(kind: "monologue", text: "4-min monologue", at: 300))
        // One quiet notification (no sound, gone when the nudge is no longer shown); a click opens the meeting.
        #expect(sent.all == [CoachNotification(title: "Live coach", message: "4-min monologue", meeting: "2026-11-07T10-00-00",
                                               quiet: true, expires: Nudges.NUDGE_SHOWN)])
        tell(Nudge(kind: "quiet_invitee", text: "Valerie hasn't said anything yet", at: 612.4))
        #expect(sent.all.last?.message == "Someone invited hasn't spoken yet")
        let row = try #require(logRows(folder).last)
        #expect(row["event"] == .string("coach_nudge") && row["kind"] == .string("quiet_invitee") && row["at"] == .double(612.4))
        #expect(row["logger"] == .string("palaver.live_coach") && row["level"] == .string("INFO"))
        #expect(!row.encoded(indent: nil).contains("Valerie") && row["text"] == nil)  // what the nudge said stays out
        #expect(logRows(folder).count == 2)  // every nudge is logged
    }

    @Test func test_with_the_switch_off_a_nudge_is_only_logged() {
        let t = Temp(); defer { t.remove() }
        let sent = Sent()
        let tell = LiveCoachRunner.nudgeNotifier(t.url, show: { false }, send: sent.add)
        tell(Nudge(kind: "monologue", text: "3-min monologue", at: 400))
        #expect(sent.all.isEmpty)
        #expect(logRows(t.url).last?["kind"] == .string("monologue"))
    }

    @Test func test_nudge_notifications_are_on_by_default_and_follow_settings() throws {
        let t = Temp(); defer { t.remove() }
        let stores = StorePaths(configDir: t.file("config"), home: t.file("home"))
        #expect(SettingsValues().nudgeNotify)
        let show = LiveCoachRunner.notifySwitch(ttl: 0, stores: stores)
        #expect(show())
        try SettingsFile.update([("nudge_notify", .bool(false))], stores: stores)
        #expect(!show())
    }

    @Test func test_nudges_are_told_from_a_running_coach_worker() {
        let t = Temp(); defer { t.remove() }
        let seen = Seen()
        let coach = LiveCoach(folder: t.url, clock: TestClock().callAsFunction, names: noNames, onNudge: seen.add)
        coach.update(talk: talk(monologue: 200), mine: [])
        let stop = StopEvent()
        stop.set()
        #expect(LiveCoachRunner.run(folder: t.url, coach: coach, stop: stop, every: 0.01, contextAfter: 3600,
                                    parentAlive: { true }) == 0)
        #expect(seen.all.count == 1)
    }

    @Test func test_no_nudge_notification_names_a_person() {
        // A banner is seen by everyone when the whole screen is shared, and stays in Notification Center: the
        // quiet-invitee nudge names nobody there (the menu and the meeting's page do).
        let t = Temp(); defer { t.remove() }
        let clock = TestClock()
        let names = ["Valerie Vogt", "Timo Strauß"]
        let n = Nudges(clock: clock.callAsFunction)
        let sent = Sent()
        let tell = LiveCoachRunner.nudgeNotifier(t.url, show: { true }, send: sent.add)
        for (i, quiet) in [Array(names.prefix(1)), names].enumerated() {
            clock.now = Double(i) * (Nudges.NUDGE_EVERY + 1)
            let nudge = n.update(talk(until: 900 + clock.now), quiet: quiet)
            let first = String(quiet.last!.split(separator: " ")[0])
            #expect(nudge?.text.contains(first) == true)  // the named text stays for the menu and the page
            if let fresh = n.fresh { tell(fresh) }
        }
        #expect(sent.all.count == 2)
        for note in sent.all {
            let text = note.title + " " + note.message
            #expect(!names.flatMap { $0.split(separator: " ") }.contains { text.contains($0) })
        }
    }

    @Test func newNudgeSendsOneQuietNotificationThroughTheAppSocket() throws {
        // The worker's datagram reaches the app's notification center as a quiet one that expires.
        let center = RecordingCenter()
        let dir = "/tmp/pc-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let notifications = Notifications(center: center, directory: dir, opener: { _ in }, fallback: { _, _ in })
        #expect(notifications.start(requestAuthorization: false))
        defer { notifications.stop() }
        let t = Temp(); defer { t.remove() }
        let folder = t.file("2026-11-07T10-00-00")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Through the datagram `Notify.send` sends, not `send` itself: other tests' `--no-notify` mutes the process.
        let tell = LiveCoachRunner.nudgeNotifier(folder, show: { true }) { n in
            _ = Notify.deliver(Notify.datagram(title: n.title, message: n.message, meeting: n.meeting, quiet: n.quiet,
                                               expires: n.expires), to: notifications.socketPath)
        }
        tell(Nudge(kind: "quiet_invitee", text: "Valerie hasn't said anything yet", at: 700))
        #expect(waitFor(5) { !center.posts.isEmpty })
        let post = try #require(center.posts.first)
        #expect(post.title == "Live coach" && post.body == "Someone invited hasn't spoken yet")
        #expect(post.userInfo == ["open": "2026-11-07T10-00-00"])
        #expect(post.quiet && post.expires == Nudges.NUDGE_SHOWN)
    }
}

/// A notification center that keeps what it was asked to post (never the real one).
private final class RecordingCenter: NotificationCenterLike, @unchecked Sendable {
    struct Post {
        let title: String, body: String, userInfo: [String: String], quiet: Bool, expires: Double?
    }
    private let lock = NSLock()
    private var items: [Post] = []
    var posts: [Post] { lock.withLock { items } }

    func post(title: String, body: String, userInfo: [String: String], quiet: Bool, expires: Double?,
              completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { items.append(Post(title: title, body: body, userInfo: userInfo, quiet: quiet, expires: expires)) }
        completion(nil)
    }
    func authorizationStatus(completion: @escaping @Sendable (NotifyPermission) -> Void) { completion(.notAsked) }
    func requestAuthorization(completion: @escaping @Sendable (Bool) -> Void) { completion(false) }
}
