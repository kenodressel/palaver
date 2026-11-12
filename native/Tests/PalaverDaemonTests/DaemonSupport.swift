// test_daemon.py's fakes: _FakeSession, _Done, _Running, the fake clock and _daemon / _notes_daemon /
// _index_daemon / _daemon_held. Nothing records, nothing is spawned, no notification is shown.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDaemon

/// The suites that tick a daemon thousands of times run one test at a time in each of four groups: all in parallel
/// they would keep the cooperative pool busy for seconds, and app.sock's tests need it; all in one line they take
/// half a minute.
@Suite(.serialized) struct DaemonTicks {}
@Suite(.serialized) struct DaemonTicksB {}
@Suite(.serialized) struct DaemonTicksC {}
@Suite(.serialized) struct DaemonTicksD {}

/// The wall clock at the fake clock's 0: what daemon.json and the status show.
let WALL0 = WallTime.parse("2026-10-29T12:06:00+01:00")!
let TZ = TimeZone(secondsFromGMT: 3600)!

func wall(_ seconds: Double) -> String { WallTime.iso(WALL0.addingTimeInterval(seconds), TZ) }

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-daemon-\(getpid())-\(UUID().uuidString.prefix(8))",
                                                                            isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.resolvingSymlinksInPath()
}

func mkdir(_ url: URL) { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
func touch(_ url: URL, _ text: String = "") { try? text.write(to: url, atomically: true, encoding: .utf8) }
func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
func writeJSON(_ url: URL, _ obj: Any) {
    try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]).write(to: url)
}

final class FakeSession: RecordingSessionLike {
    let folder: URL
    let duration: Double
    var started = false
    var stopped = false
    var stopReason: String?
    var trigger = ""
    var t0 = 0.0
    var onStart: () -> Void = {}
    var missing: [String] = []
    var micDevice: String?
    var micRate: Double?
    var micSource: String?
    var systemDevice: String?
    var systemRate: Double?
    var systemSource: String?
    var problems: [RecordingProblem] = []
    var hints: [(kind: String, track: String)] = []
    var mutedIn: String?

    init(folder: URL, duration: Double) {
        self.folder = folder
        self.duration = duration
    }

    func start() throws -> URL {
        onStart()
        started = true
        mkdir(folder)
        return folder
    }

    func stop(reason: String?) throws -> Double {
        stopped = true
        stopReason = reason
        return duration
    }
}

/// The sessions of a daemon and of the daemons started again after it (`nil`: recorded before).
final class Sessions {
    var items: [FakeSession?]
    init(_ items: [FakeSession?] = []) { self.items = items }
    var count: Int { items.count }
    subscript(i: Int) -> FakeSession { items[i]! }
    var last: FakeSession? { items.last ?? nil }
}

/// A background process that runs until `done` says otherwise (`_Running`); `_Done` is done at once.
final class FakeWorker: WorkerProcess {
    let pid: Int32
    var done: () -> Bool
    var rc: Int32
    var terminated = false
    var polled: [Double] = []
    var onPoll: () -> Void = {}

    init(pid: Int32 = 999_999, done: @escaping () -> Bool = { false }, rc: Int32 = 0) {
        self.pid = pid
        self.done = done
        self.rc = rc
    }

    func poll() -> Int32? {
        onPoll()
        return terminated || done() ? rc : nil
    }

    func terminate() { terminated = true }
    func kill() { terminated = true }
}

/// `_daemon`: the daemon over a fake clock (2 s per tick), fake sessions in `dir/rec<N>` and a
/// processing launcher that records the folder and is done at once.
final class Harness {
    let dir: URL
    var clock: Double
    let sessions: Sessions
    let duration: Double
    var activity: (Double) throws -> CallApp?
    /// The call app the daemon said it records, at its last detection.
    var recording: CallApp?
    var launched: [URL] = []
    var notifications: [(title: String, message: String, open: String?)] = []
    var logs: [(level: String, message: String)] = []
    var launchProcessing: (URL) throws -> WorkerProcess
    var newSession: ((String) -> FakeSession)?
    var daemon: Daemon!

    var statePath: URL { dir.appendingPathComponent("state.json") }
    var titles: [String] { notifications.map(\.title) }
    var sent: [(String, String)] { notifications.map { ($0.title, $0.message) } }
    var logText: String { logs.map(\.message).joined(separator: "\n") }

    init(_ dir: URL, activity: @escaping (Double) throws -> CallApp?, duration: Double = 600, sessions: Sessions = Sessions(),
         start: Double = 0, trigger: Trigger = Trigger(startAfter: 4, grace: 10, maxSession: 3600),
         configure: (inout DaemonDeps, Harness) -> Void = { _, _ in }) throws {
        self.dir = dir
        clock = start
        self.sessions = sessions
        self.duration = duration
        self.activity = activity
        launchProcessing = { _ in FakeWorker(done: { true }) }
        var deps = DaemonDeps(
            detect: { [unowned self] recording in self.recording = recording; return try self.activity(self.clock) },
            newSession: { [unowned self] trigger in self.makeSession(trigger) },
            launchProcessing: { [unowned self] folder in
                self.launched.append(folder)
                return try self.launchProcessing(folder)
            },
            statePath: dir.appendingPathComponent("state.json"), trigger: trigger,
            clock: { [unowned self] in self.clock })
        deps.wall = { [unowned self] in WALL0.addingTimeInterval(self.clock) }
        deps.timeZone = TZ
        deps.notify = { [unowned self] in self.notifications.append(($0, $1, $2)) }
        deps.log = { [unowned self] in self.logs.append(($0, $1)) }
        deps.palaverAlive = { _ in false }
        configure(&deps, self)
        daemon = try Daemon(deps)
    }

    func makeSession(_ trigger: String) -> FakeSession {
        if let newSession { return newSession(trigger) }
        let s = FakeSession(folder: dir.appendingPathComponent("rec\(sessions.count)", isDirectory: true), duration: duration)
        s.trigger = trigger
        s.t0 = clock
        sessions.items.append(s)
        return s
    }

    func now() -> Double { clock }

    /// Ticks on a thread of its own: thousands of ticks must not hold a thread of the cooperative
    /// pool, which app.sock's handlers (and their tests, in parallel) run on.
    func run(until: @escaping (Double) -> Bool) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let t = Thread { [self] in
                daemon.run(until: { until(self.clock) }, poll: 2, sleep: { self.clock += $0 })
                cont.resume()
            }
            t.stackSize = 4 << 20
            t.start()
        }
    }

    func state() -> JSONValue { DaemonStateFile.read(statePath) }
    func status() -> JSONValue { daemon.status() }
    func rec(_ n: Int) -> URL { dir.appendingPathComponent("rec\(n)", isDirectory: true) }
}

/// Activities: the call app on in these spans of the fake clock.
func teams(_ on: @escaping (Double) -> Bool) -> (Double) -> CallApp? { { on($0) ? .teams : nil } }
func slack(_ on: @escaping (Double) -> Bool) -> (Double) -> CallApp? { { on($0) ? .slack : nil } }
let noCall: (Double) -> CallApp? = { _ in nil }

/// `_notes_daemon`: notes launched as `FakeWorker`s; processing done once the clock reaches `processingUntil`.
final class NotesRig {
    let h: Harness
    var notes: [(folder: URL, process: FakeWorker)] = []
    var free: Double

    init(_ dir: URL, activity: @escaping (Double) -> CallApp?, processingUntil: Double = 0, free: Double = 40,
         notesMemory: ((URL) -> Double?)? = nil, sessions: Sessions = Sessions(),
         configure: (inout DaemonDeps, Harness) -> Void = { _, _ in }) throws {
        self.free = free
        var me: NotesRig?
        h = try Harness(dir, activity: activity, sessions: sessions) { deps, h in
            deps.memoryFreeGB = { me!.free }
            if let notesMemory { deps.notesMemoryGB = notesMemory }
            deps.launchNotes = { folder in
                let p = FakeWorker()
                me!.notes.append((folder, p))
                return p
            }
            configure(&deps, h)
        }
        me = self
        h.launchProcessing = { [unowned h] _ in FakeWorker(done: { h.clock >= processingUntil }) }
    }

    var notedFolders: [URL] { notes.map(\.folder) }
}

/// `_index_daemon`: the search index launched as `FakeWorker`s.
final class IndexRig {
    let rig: NotesRig
    var runs: [FakeWorker] = []
    var wanted: () -> Bool? = { true }
    var modelReady: () -> Bool = { true }
    var h: Harness { rig.h }

    init(_ dir: URL, activity: @escaping (Double) -> CallApp?, free: Double = 40) throws {
        var me: IndexRig?
        rig = try NotesRig(dir, activity: activity, free: free, configure: { deps, _ in
            deps.launchIndex = {
                let p = FakeWorker()
                me!.runs.append(p)
                return p
            }
            deps.indexWanted = { me!.wanted() }
            deps.indexModelReady = { me!.modelReady() }
        })
        me = self
    }
}

// MARK: - _daemon_held: a real CallDetector over fake processes

struct FakeLister: ProcessLister {
    let list: @Sendable () -> [AudioProcess]
    func processes() throws -> [AudioProcess] { list() }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    init(_ v: Double = 0) { value = v }
    var now: Double {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

let SLACK = "com.tinyspeck.slackmacgap.helper"
let TEAMS = "com.microsoft.teams2.modulehost"

/// A detector over fake processes: Slack and Teams hold the mic in these (start, end) spans; in
/// `slackSpeaker`'s, Slack only plays (a muted huddle, a ringtone). `audio`: more processes at a time.
func apps(slack: [(Double, Double)] = [], teams: [(Double, Double)] = [],
          slackSpeaker: [(Double, Double)] = [],
          audio: @escaping @Sendable (Double) -> [AudioProcess] = { _ in [] }) -> (CallDetector, Clock) {
    let clock = Clock()
    let lister = FakeLister {
        let now = clock.now
        var out: [AudioProcess] = audio(now)
        if slack.contains(where: { $0.0 <= now && now < $0.1 }) { out.append(AudioProcess(bundleId: SLACK, runningInput: true, runningOutput: true)) }
        else if slackSpeaker.contains(where: { $0.0 <= now && now < $0.1 }) { out.append(AudioProcess(bundleId: SLACK, runningInput: false, runningOutput: true)) }
        if teams.contains(where: { $0.0 <= now && now < $0.1 }) { out.append(AudioProcess(bundleId: TEAMS, runningInput: true, runningOutput: true)) }
        return out
    }
    return (CallDetector(lister: lister, clock: { clock.now }), clock)
}

/// The daemon over a real CallDetector. The others are heard in the `heard` spans; with
/// `talking` the user always is. Silence counts from the start of the running recording.
final class HeldRig {
    let h: Harness
    let detector: CallDetector

    init(_ dir: URL, slack: [(Double, Double)] = [], teams: [(Double, Double)] = [], slackSpeaker: [(Double, Double)] = [],
         heard: [(Double, Double)] = [], talking: Bool = false, sessions: Sessions = Sessions(), start: Double = 0,
         grace: Double = 10, audio: @escaping @Sendable (Double) -> [AudioProcess] = { _ in [] },
         huddleLeft: (@Sendable (Double) -> Bool)? = nil) throws {
        let (detector, dclock) = apps(slack: slack, teams: teams, slackSpeaker: slackSpeaker, audio: audio)
        dclock.now = start
        self.detector = detector
        if let huddleLeft { detector.huddleLeft = { huddleLeft(dclock.now) } }
        var hh: Harness?
        func othersQuiet() -> Double {
            let h = hh!
            let now = h.clock
            if heard.contains(where: { $0.0 <= now && now < $0.1 }) { return 0 }
            let t0 = h.sessions.last?.t0 ?? start
            let last = (heard.map(\.1).filter { $0 <= now } + [t0]).max()!
            return max(0, now - max(last, t0))
        }
        h = try Harness(dir, activity: { _ in detector.detect(recording: hh?.recording) }, sessions: sessions, start: start,
                        trigger: Trigger(startAfter: 4, grace: grace, maxSession: 4 * 3600)) { deps, _ in
            deps.ignore = { detector.ignore(named: $0) }
            deps.ignored = { detector.ignored.map(\.rawValue) }
            deps.othersSilence = { othersQuiet() }
            deps.silence = { talking ? 5 : othersQuiet() }
            if let huddleLeft { deps.callLeft = { app in app == .slack && huddleLeft(dclock.now) } }
        }
        hh = h
        // The detector's clock follows the daemon's.
        let real = h.activity
        h.activity = { now in dclock.now = now; return try real(now) }
    }
}
