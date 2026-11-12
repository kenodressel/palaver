// One recording from start to stop (palaver/session.py RecordingSession + recorder.py Recorder):
// creates the folder, captures until stop, writes meta.json, keeps session.log for the whole
// recording (`record_start`, `record_stop`, the recorder's warnings and the audio health events).
// Also the live levels of the running recording (the menu bar's LevelTracker), whose silence
// feeds the stop questions.
import Darwin
import Foundation
import PalaverCapture
import PalaverCore
import PalaverDomain

/// An audio incident of the running recording (issue #50), as `audio_health` keeps it.
public struct RecordingProblem: Equatable, Sendable {
    public var id: Int
    public var kind: String
    public var track: String
    public var start: Double
    public var end: Double?
    public var at: String?

    public init(id: Int, kind: String, track: String, start: Double, end: Double? = nil, at: String? = nil) {
        self.id = id; self.kind = kind; self.track = track; self.start = start; self.end = end; self.at = at
    }
}

/// What the daemon records with (daemon.py's `Session` protocol plus what `_why` reads).
public protocol RecordingSessionLike: AnyObject {
    /// Starts capturing; the recording's folder.
    func start() throws -> URL
    /// Finalizes the files and meta.json; the duration in seconds. `reason`: why it stopped.
    func stop(reason: String?) throws -> Double
    /// Tracks no source could record ("microphone", "system audio").
    var missing: [String] { get }
    var systemSource: String? { get }
    var micSource: String? { get }
    var micDevice: String? { get }
    var micRate: Double? { get }
    var systemDevice: String? { get }
    var systemRate: Double? { get }
    var problems: [RecordingProblem] { get }
    var hints: [(kind: String, track: String)] { get }
    /// The call app the user is muted in right now ("teams"), while the mic is not kept (CallMute).
    var mutedIn: String? { get }
    /// The call app whose mute can't be followed right now ("teams": no Accessibility, no readable log).
    var muteUnfollowed: String? { get }
}

public extension RecordingSessionLike {
    var mutedIn: String? { nil }
    var muteUnfollowed: String? { nil }
    var missing: [String] { [] }
    var systemSource: String? { nil }
    var micSource: String? { nil }
    var micDevice: String? { nil }
    var micRate: Double? { nil }
    var systemDevice: String? { nil }
    var systemRate: Double? { nil }
    var problems: [RecordingProblem] { [] }
    var hints: [(kind: String, track: String)] { [] }
}

/// The capture a `RecordingSession` drives (the `CaptureRecorder` with its health monitor; tests fake it).
public protocol SessionCapture: AnyObject {
    func start() throws
    func stop() throws
    var missing: [String] { get }
    var systemSource: String? { get }
    var micSource: String? { get }
    var micDevice: String? { get }
    var micRate: Double? { get }
    var systemDevice: String? { get }
    var systemRate: Double? { get }
    var problems: [RecordingProblem] { get }
    var hints: [(kind: String, track: String)] { get }
    var mutedIn: String? { get }
    var muteUnfollowed: String? { get }
}

public extension SessionCapture {
    var mutedIn: String? { nil }
    var muteUnfollowed: String? { nil }
}

/// The real capture: the recorder writing `mic_raw.wav(.part)` and `system.wav(.part)`, with its
/// warnings and the audio health events in session.log and the incidents in audio_problems.json.
public final class LiveCapture: SessionCapture {
    public let recorder: CaptureRecorder
    public let monitor: AudioHealthMonitor
    /// A call's mute (CallMute): its timeline gates the mic, its source sets it.
    private let mute: (timeline: MuteTimeline, source: CallMuteSource)?
    private let folder: URL
    private let gatesMic: Bool
    /// How often, after the stop, Teams' log is read while its late changes are waited for, and how long (nil:
    /// the timeline's hold).
    var afterStopPoll = 0.5
    var afterStopWait: Double?

    /// `mute`: made with the session log's line writer (`CallMute.logger`), for a call recorded with
    /// `respect_call_mute` on.
    /// `gatesMic` false: the source is followed for what else it tells (a Slack huddle's end), the mic kept whole.
    public init(folder: URL, log: SessionLog, sources: CaptureSources,
                mute: ((@escaping @Sendable (String) -> Void) -> (MuteTimeline, CallMuteSource))? = nil,
                gatesMic: Bool = true) {
        let logger = "palaver.capture_recorder"
        self.folder = folder
        monitor = AudioHealthMonitor(problemsURL: folder.appendingPathComponent("audio_problems.json"),
                                     events: { level, event, fields in log.event(event, level: level, logger: logger, fields) })
        let made = mute?({ text in
            // Not gating, the timeline's mute stretches are no news: only the source's own lines.
            if !gatesMic, text.hasPrefix("muted in ") { return }
            log.message(text, level: text.hasPrefix("⚠") ? "WARNING" : "INFO", logger: "palaver.call_mute")
        })
        self.mute = made.map { (timeline: $0.0, source: $0.1) }
        self.gatesMic = gatesMic
        recorder = CaptureRecorder(micURL: folder.appendingPathComponent("mic_raw.wav"),
                                   systemURL: folder.appendingPathComponent("system.wav"), sources: sources, monitor: monitor,
                                   log: { log.message($0, level: $0.hasPrefix("⚠") ? "WARNING" : "INFO", logger: logger) },
                                   mute: gatesMic ? made?.0 : nil)
    }

    public func start() throws {
        mute?.source.start()
        do { try recorder.start() } catch {
            mute?.source.stop()
            throw error
        }
    }

    /// The source reads what is new first, so the last held audio is cut by it too. A source whose changes come
    /// late (Teams' log) is followed on for its hold after the stop, on a thread of its own: what it tells then
    /// silences the finished mic track, and `mic_muted.json` says `pending` until it is done (`process` waits).
    public func stop() throws {
        guard let mute else { try recorder.stop(); return }
        mute.source.refresh()
        do { try recorder.stop() } catch {
            mute.source.stop()
            mute.timeline.close()
            throw error
        }
        let wait = mute.source.tellsLate ? afterStopWait ?? mute.timeline.delay : 0
        let (recorder, folder, poll) = (self.recorder, self.folder, afterStopPoll)
        let finish: @Sendable () -> Void = {
            recorder.silenceAfterStop()
            let late = recorder.lateSilenced
            if !late.isEmpty || wait > 0 { try? MicMuted.write(.init(pending: false, late: late), folder: folder) }
            mute.source.stop()
            mute.timeline.close()
        }
        guard wait > 0 else { finish(); return }
        try? MicMuted.write(.init(pending: true, late: recorder.lateSilenced), folder: folder)
        let t = Thread {
            let deadline = Date().addingTimeInterval(wait)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: min(poll, max(0, deadline.timeIntervalSinceNow)))
                mute.source.refresh()
            }
            finish()
        }
        t.name = "palaver.mute-after-stop"
        t.start()
    }

    public var mutedIn: String? {
        guard gatesMic else { return nil }
        return mute.flatMap { $0.timeline.mutedNow ? $0.timeline.app.rawValue : nil }
    }
    public var muteUnfollowed: String? {
        guard gatesMic else { return nil }
        return mute.flatMap { $0.source.unfollowed ? $0.timeline.app.rawValue : nil }
    }
    public var missing: [String] { recorder.missing }
    public var systemSource: String? { recorder.systemSource }
    public var micSource: String? { recorder.micSource }
    public var micDevice: String? { recorder.micDevice }
    public var micRate: Double? { recorder.micRate }
    public var systemDevice: String? { recorder.systemDevice }
    public var systemRate: Double? { recorder.systemRate }
    public var problems: [RecordingProblem] {
        monitor.problems.map { RecordingProblem(id: $0.id, kind: $0.kind, track: $0.track, start: $0.start, end: $0.end, at: $0.at) }
    }
    public var hints: [(kind: String, track: String)] { monitor.hints }
}

/// usage.jsonl (palaver/usage.py `record`): one JSON line per event; never fails.
public struct UsageLog: Sendable {
    public let url: URL
    public var wall: @Sendable () -> Date = { Date() }
    public var timeZone: TimeZone = .current

    public init(url: URL) { self.url = url }

    public func record(_ kind: String, _ fields: [(String, Any)]) {
        func small(_ v: Any) -> Any {
            if let s = v as? String { return String(s.prefix(200)) }
            if let d = v as? Double { return (d * 10).rounded() / 10 }
            if let a = v as? [Any] { return a.prefix(20).map(small) }
            return v
        }
        let row: [(String, Any)] = [("ts", WallTime.iso(wall(), timeZone, seconds: true)), ("kind", kind)]
            + fields.map { ($0.0, small($0.1)) }
        let line = JSONLines.object(row) + "\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
    }
}

/// One recording: the folder, the capture, meta.json and session.log.
public final class RecordingSession: RecordingSessionLike {
    public let outputDir: URL
    public let trigger: String
    private let makeCapture: (URL, SessionLog) -> SessionCapture
    private let wall: () -> Date
    private let timeZone: TimeZone
    private let stamp: [(String, Any)]
    private let usage: UsageLog?
    public private(set) var folder: URL?
    public private(set) var log: SessionLog?
    public private(set) var recording = false
    private var capture: SessionCapture?
    private var startTime: Date?

    /// `stamp`: who writes (version, pid, argv), first in `record_start` as Python's runlog.stamp.
    public init(outputDir: URL, trigger: String, capture: @escaping (URL, SessionLog) -> SessionCapture,
                wall: @escaping () -> Date = Date.init, timeZone: TimeZone = .current,
                stamp: [(String, Any)] = [], usage: UsageLog? = nil) {
        self.outputDir = outputDir
        self.trigger = trigger
        self.makeCapture = capture
        self.wall = wall
        self.timeZone = timeZone
        self.stamp = stamp
        self.usage = usage
    }

    public var missing: [String] { capture?.missing ?? [] }
    public var systemSource: String? { capture?.systemSource }
    public var micSource: String? { capture?.micSource }
    public var micDevice: String? { capture?.micDevice }
    public var micRate: Double? { capture?.micRate }
    public var systemDevice: String? { capture?.systemDevice }
    public var systemRate: Double? { capture?.systemRate }
    public var problems: [RecordingProblem] { capture?.problems ?? [] }
    public var hints: [(kind: String, track: String)] { capture?.hints ?? [] }
    public var mutedIn: String? { recording ? capture?.mutedIn : nil }
    public var muteUnfollowed: String? { recording ? capture?.muteUnfollowed : nil }

    public func start() throws -> URL {
        let folder = try RecordingFolders.new(in: outputDir, at: wall(), timeZone: timeZone)
        let log = SessionLog(url: folder.appendingPathComponent("session.log"), logger: "palaver", timeZone: timeZone)
        let capture = makeCapture(folder, log)
        self.folder = folder
        self.log = log
        self.capture = capture
        startTime = wall()
        try capture.start()
        recording = true
        log.event("record_start", stamp + [("system_source", capture.systemSource as Any), ("mic_source", capture.micSource as Any),
                                           ("missing", capture.missing), ("trigger", trigger)])
        usage?.record("recording_start", [("trigger", trigger), ("system_source", capture.systemSource as Any),
                                          ("mic_source", capture.micSource as Any), ("missing", capture.missing)])
        return folder
    }

    public func stop(reason: String?) throws -> Double {
        guard let capture, let folder, let startTime, let log else {
            throw CaptureError("the recording was not started")
        }
        recording = false
        try capture.stop()
        let end = wall()
        let seconds = end.timeIntervalSince(startTime)
        var meta: [(String, JSONValue)] = [
            ("start_time", .string(WallTime.iso(startTime, timeZone))), ("end_time", .string(WallTime.iso(end, timeZone))),
            ("duration_seconds", .double(seconds)), ("trigger", .string(trigger)),
        ]
        if let reason, !reason.isEmpty { meta.append(("stop_reason", .string(reason))) }
        let problems = capture.problems
        if !problems.isEmpty {  // the meeting page: "Audio problem at 12:14 (…)"
            meta.append(("audio_problems", .array(problems.map { p in
                .object([("kind", .string(p.kind)), ("track", .string(p.track)), ("start", .double(p.start)),
                         ("end", .num(p.end)), ("at", .str(p.at))])
            })))
        }
        try Data(JSONValue.object(meta).encoded(indent: 2).utf8).write(to: folder.appendingPathComponent("meta.json"))
        unlink(folder.appendingPathComponent("audio_problems.json").path)  // folded in
        var fields: [(String, Any)] = [("reason", reason as Any)]
        for (name, file) in [("mic_seconds", "mic_raw.wav"), ("system_seconds", "system.wav")] {
            if let s = Self.trackSeconds(folder.appendingPathComponent(file)) { fields.append((name, s)) }
        }
        log.event("record_stop", fields)
        usage?.record("recording_stop", [("trigger", trigger), ("reason", reason as Any), ("seconds", seconds),
                                         ("problems", problems.count)])
        return seconds
    }

    /// A finished track's length from its header, rounded to 0.1 s; nil when it can't be read.
    static func trackSeconds(_ url: URL) -> Double? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let header = try? h.read(upToCount: 44), header.count == 44,
              header.prefix(4) == Data("RIFF".utf8) else { return nil }
        let rate = header[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let bytes = header[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard rate > 0 else { return nil }
        return (Double(bytes) / 2 / Double(rate) * 10).rounded() / 10
    }
}

/// The live levels of the running recording (menubar.py's LevelTracker): read once a tick from
/// its `.part` files; how long both tracks, and the system track (the others in a call), had no
/// sound feeds the stop questions.
public final class RecordingLevels: @unchecked Sendable {
    private let lock = NSLock()
    private let makeTracker: (URL) -> LevelTracker
    private var tracker: LevelTracker?
    private var folder: String?
    private var _readings: [LevelTracker.Reading] = []
    private var _quiet: Double?
    private var _othersQuiet: Double?

    public init(makeTracker: @escaping (URL) -> LevelTracker = { folder in
        LevelTracker(tracks: [("mic", folder.appendingPathComponent("mic_raw.wav.part")),
                              ("system", folder.appendingPathComponent("system.wav.part"))])
    }) {
        self.makeTracker = makeTracker
    }

    /// After each tick: the folder being recorded, or nil.
    public func update(recording folder: String?) {
        lock.lock(); defer { lock.unlock() }
        guard let folder else {
            tracker = nil; self.folder = nil; _readings = []; _quiet = nil; _othersQuiet = nil
            return
        }
        if self.folder != folder {
            tracker = makeTracker(URL(fileURLWithPath: folder, isDirectory: true))
            self.folder = folder
        }
        _readings = tracker!.read()
        _quiet = tracker!.quietFor()
        _othersQuiet = tracker!.quietFor("system")
    }

    /// The last levels read, for the menu.
    public var readings: [LevelTracker.Reading] { lock.lock(); defer { lock.unlock() }; return _readings }
    /// Seconds both tracks had no sound; nil while nothing records.
    public var quietFor: Double? { lock.lock(); defer { lock.unlock() }; return _quiet }
    /// Seconds the system track (the others) had no sound.
    public var othersQuietFor: Double? { lock.lock(); defer { lock.unlock() }; return _othersQuiet }
}
