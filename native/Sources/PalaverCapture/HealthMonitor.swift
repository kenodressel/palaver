// The glue between the recorder and `AudioHealth` (capture_recorder.py `_run_health_check`,
// `_keep_problems`): incidents opening and ending go to session.log and beside the audio, as
// `audio_problems.json`, rewritten atomically (tmp, fsync, rename) so a crash before stop still has them.
import Darwin
import Foundation
import PalaverCore

/// Where session.log events go: (level, event name, ordered fields).
public typealias EventSink = @Sendable (_ level: String, _ event: String, _ fields: [(String, Any)]) -> Void

/// The file system the problems file is written through; tests inject failures.
public struct ProblemsFileSystem: Sendable {
    public var exists: @Sendable (URL) -> Bool
    /// Writes `data` to `url` so that a reader sees the old or the new content, never half.
    public var writeAtomically: @Sendable (Data, URL) throws -> Void

    public static let real = ProblemsFileSystem(
        exists: { FileManager.default.fileExists(atPath: $0.path) },
        writeAtomically: { data, url in
            let tmp = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".tmp")
            let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard fd >= 0 else { throw CaptureError("cannot write \(tmp.path): \(String(cString: strerror(errno)))") }
            do {
                try data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                        if n < 0 { throw CaptureError("cannot write \(tmp.path): \(String(cString: strerror(errno)))") }
                        offset += n
                    }
                }
                fsync(fd)
            } catch { close(fd); throw error }
            close(fd)
            guard rename(tmp.path, url.path) == 0 else {
                throw CaptureError("cannot replace \(url.path): \(String(cString: strerror(errno)))")
            }
        })
}

/// The recorder's health monitor: feeds `AudioHealth`, logs and keeps the incidents.
///
/// `begin(now:)` (called by the recorder at start) creates a fresh `AudioHealth` dated from the
/// recorder's clock, as Python's `start()` did. All calls come from the writer thread; `problems`,
/// `hints` and `openProblems` may be read from any.
public final class AudioHealthMonitor: CaptureMonitor, @unchecked Sendable {
    private let problemsURL: URL?
    private let events: EventSink
    private let debug: @Sendable (String) -> Void
    private let wall: @Sendable () -> Date
    private let timeZone: TimeZone
    private let fileSystem: ProblemsFileSystem
    private let lock = NSLock()
    private var health: AudioHealth

    /// `problemsURL`: `audio_problems.json` (nil: not kept).
    public init(problemsURL: URL?, events: @escaping EventSink, debug: @escaping @Sendable (String) -> Void = { _ in },
                wall: @escaping @Sendable () -> Date = Date.init, timeZone: TimeZone = .current,
                fileSystem: ProblemsFileSystem = .real) {
        self.problemsURL = problemsURL
        self.events = events
        self.debug = debug
        self.wall = wall
        self.timeZone = timeZone
        self.fileSystem = fileSystem
        health = AudioHealth(started: 0, wall: wall, timeZone: timeZone)
    }

    /// Convenience: events go to a `SessionLog`.
    public convenience init(problemsURL: URL?, log: SessionLog, debug: @escaping @Sendable (String) -> Void = { _ in },
                            fileSystem: ProblemsFileSystem = .real) {
        self.init(problemsURL: problemsURL, events: { level, event, fields in log.event(event, level: level, fields) },
                  debug: debug, fileSystem: fileSystem)
    }

    private var current: AudioHealth { lock.withLock { health } }

    public func begin(now: Double) throws {
        lock.withLock { health = AudioHealth(started: now, wall: wall, timeZone: timeZone) }
    }

    public func chunk(_ track: CaptureTrack, now: Double, pts: Int64, samples: [Float], rate: Double) throws {
        current.chunk(track, now: now, pts: Double(pts) / 1e9, samples: samples, rate: rate)
    }

    public func reanchor(_ track: CaptureTrack, now: Double, drift: Double) throws -> Bool {
        let health = current
        health.reanchor(track, now: now, drift: drift)
        return health.isOpen("speed", track)
    }

    public func check(_ status: CaptureStatus) throws {
        let health = current
        let (opened, closed) = health.check(
            status.now, written: status.written, startPts: status.startPts.map { Double($0) / 1e9 },
            access: status.access, stalled: status.micStalled, systemStalled: status.systemStalled,
            dropped: status.dropped, writeFailures: status.writeFailures)
        for p in opened {
            let text = ProblemWords.warning(kind: p.kind, track: p.track)
            let perMinute = health.reanchorsPerMinute(CaptureTrack(rawValue: p.track) ?? .mic)
            events("WARNING", "audio_problem", [("kind", p.kind), ("track", p.track), ("start", p.start), ("at", p.at),
                                                ("text", text), ("reanchors_per_minute", perMinute)])
        }
        for p in closed {
            events("INFO", "audio_problem_over", [("kind", p.kind), ("track", p.track), ("end", p.end as Any)])
        }
        if !opened.isEmpty || !closed.isEmpty { keepProblems() }
    }

    public func close(now: Double) throws {
        current.closeAll(now)
        keepProblems()
    }

    // MARK: read by the status

    /// Every incident of this recording: `{id, kind, track, start, end, at}`.
    public var problems: [AudioIncident] { current.problems() }
    public var openProblems: [AudioIncident] { current.openProblems() }
    public var hints: [(kind: String, track: String)] { current.hints() }

    /// The incidents beside the audio, atomically; nothing is written while there are none and no file
    /// exists yet. Never throws: a failure is a debug line.
    func keepProblems() {
        guard let problemsURL else { return }
        let all = current.problems()
        if all.isEmpty && !fileSystem.exists(problemsURL) { return }
        let json = all.isEmpty ? "[]" : "[\n" + all.map { p in
            "  {\n" + p.jsonFields.map { "    " + JSONLines.string($0.0) + ": " + JSONLines.value($0.1) }.joined(separator: ",\n") + "\n  }"
        }.joined(separator: ",\n") + "\n]"
        do { try fileSystem.writeAtomically(Data(json.utf8), problemsURL) } catch { debug("could not keep the audio problems: \(error)") }
    }
}
