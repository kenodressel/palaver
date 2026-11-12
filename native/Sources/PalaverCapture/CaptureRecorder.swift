// The recorder: two sources, one writer thread, two aligned `.part` files
// (capture_recorder.py's CaptureRecorder: start/stop, the sources and their
// fallbacks :318-532, the writer thread :536-647, the stall watchdog).
import Darwin
import Foundation
import PalaverCore

/// A capture source the recorder starts and stops: the process tap or the microphone.
public protocol CaptureSource: AnyObject {
    func start() throws
    func stop()
    /// What keeps it from recording right now, for the status: "access", "device" or nil.
    var problem: String? { get }
    /// The microphone recorded from, or the output the tap is clocked by.
    var deviceName: String? { get }
}

/// How the recorder makes its sources; tests pass fakes.
public struct CaptureSources {
    public var systemTap: (CaptureRing) -> CaptureSource
    public var mic: (CaptureRing) -> CaptureSource
    /// ScreenCaptureKit for whichever of the two failed: (mic ring, system ring).
    public var screenCapture: (CaptureRing, CaptureRing) -> ScreenCaptureFallback

    public init(systemTap: @escaping (CaptureRing) -> CaptureSource, mic: @escaping (CaptureRing) -> CaptureSource,
                screenCapture: @escaping (CaptureRing, CaptureRing) -> ScreenCaptureFallback) {
        self.systemTap = systemTap
        self.mic = mic
        self.screenCapture = screenCapture
    }

    /// The real sources. `excludedPIDs` is asked when the tap starts: the app's own pid and its
    /// workers' (the daemon knows them); the tap records everything else.
    public static func live(excludedPIDs: @escaping () -> [pid_t] = { [getpid()] },
                            log: @escaping (String) -> Void) -> CaptureSources {
        CaptureSources(
            systemTap: { ProcessTap(sink: $0, excludedPIDs: excludedPIDs, backend: CoreAudioTapBackend(log: log), log: log) },
            mic: { AVMic(sink: $0, log: log) },
            screenCapture: { SCStreamSource(mic: $0, system: $1) })
    }
}

/// What the health monitor (Task 7, AudioHealth) is shown every 0.25 s from the writer thread.
public struct CaptureStatus: Sendable, Equatable {
    public var now: Double
    /// Seconds written per track.
    public var written: [CaptureTrack: Double]
    public var startPts: Int64?
    /// The sources' own problems ("access" / "device"), by track.
    public var access: [CaptureTrack: String]
    /// No microphone buffer for 30 s (unless the microphone is missing).
    public var micStalled: Bool
    /// No tap buffer for 30 s (the tap only: whether ScreenCaptureKit's audio delivers silence is unknown).
    public var systemStalled: Bool
    /// Tracks whose last write failed (disk full, I/O error), with the error's text.
    public var writeFailures: [CaptureTrack: String]
    /// Buffers thrown away so far, per track (a full capture ring: the writer fell behind), cumulative.
    public var dropped: [CaptureTrack: Int] = [:]
}

/// The audio-health hooks (Task 7). Every call runs on the writer thread and is guarded: whatever
/// one throws, the audio still reaches disk; after 3 failures the monitor is off for the recording.
public protocol CaptureMonitor: AnyObject {
    /// A recording is starting (`now` on the recorder's clock); the monitor starts afresh.
    func begin(now: Double) throws
    /// Each captured buffer, decoded, before resampling.
    func chunk(_ track: CaptureTrack, now: Double, pts: Int64, samples: [Float], rate: Double) throws
    /// A drift re-anchor; true keeps it out of the log (its wrong-speed incident is open).
    func reanchor(_ track: CaptureTrack, now: Double, drift: Double) throws -> Bool
    func check(_ status: CaptureStatus) throws
    /// The recording stopped.
    func close(now: Double) throws
}

extension CaptureMonitor {
    public func begin(now: Double) throws {}
}

public struct CaptureError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Records the microphone and system audio to two WAVs aligned by PTS (`CaptureRecorder`).
///
/// - Start: the process tap and AVCaptureSession first (neither needs Screen Recording);
///   ScreenCaptureKit fills in for a source that failed (3 attempts, 2 s apart). A track
///   nothing can deliver goes to `missing` and the recording continues with the other;
///   when both fail, start throws "neither the microphone nor system audio can be recorded: …".
/// - The sources' callbacks only copy bytes into a `CaptureRing` per track. One writer
///   thread drains both rings, decodes, resamples and places each chunk (`TrackAligner`),
///   and every 0.25 s while idle asks the health monitor.
/// - Stop finalizes each track to its own length; `abort` leaves the `.part` files.
/// - A failed write (disk full) is logged once with "⚠", kept in `writeFailures` and shown
///   to the monitor; the recording goes on (the writer cut the file back to what is valid,
///   so a later chunk still lands at its true offset) and the log says when writing works
///   again. Python's writer thread died silently on such an error and the queues grew.
public final class CaptureRecorder: @unchecked Sendable {
    public static let micStallSeconds = 30.0
    public static let micStallReminderSeconds = 60.0
    public static let systemStallSeconds = 30.0
    public static let healthCheckSeconds = 0.25
    public static let healthFailureLogSeconds = 60.0
    public static let healthFailuresOff = 3
    public static let screenCaptureStartAttempts = 3
    public static let screenCaptureRetrySeconds = 2.0
    public static let droppedLogSeconds = 60.0

    public let micURL: URL
    public let systemURL: URL

    private let sources: CaptureSources
    private let monitor: CaptureMonitor?
    private let log: (String) -> Void
    private let debug: (String) -> Void
    private let sleep: (Double) -> Void
    private let ringCapacity: Int
    private let runsWriterThread: Bool
    /// While muted in the recorded call, the mic is written as silence (MicMuteGate).
    private let mute: MuteTimeline?
    private var gate: MicMuteGate?
    /// Mic stretches (host ns) silenced after they were written: a mute told late.
    private let lateLock = NSLock()
    private var _late: [Range<Int64>] = []
    /// After the stop: where the mic track began and ended (host ns), for `silenceAfterStop`.
    private var finished: (start: Int64, end: Int64)?
    var makeWriter: (URL) throws -> TrackWriter = { try TrackWriter(finalURL: $0) }
    /// How long stop waits for the writer thread before it gives the files up as `.part`.
    var writerStopTimeout: Double = 60
    var clock: () -> Double

    // Public state, read from any thread.
    private let stateLock = NSLock()
    private var _systemSource: String?
    private var _micSource: String?
    private var _missing: [String] = []
    private var _micRate: Double?
    private var _systemRate: Double?
    private var _writeFailures: [CaptureTrack: String] = [:]
    private var micCapture: CaptureSource?
    private var systemTap: CaptureSource?

    // The caller's (start/stop/abort).
    private var started = false
    private var screen: ScreenCaptureFallback?
    private var writerThread: Thread?
    private var writerDone: DispatchSemaphore?
    private let stopFlag = StopEvent()

    // The writer thread's (or, once it has stopped, stop's).
    private var micRing = CaptureRing(capacity: 64)
    private var systemRing = CaptureRing(capacity: 64)
    private var aligner: TrackAligner?
    private var scratch: [UInt8] = []
    private var lastMicArrival: Double?
    private var lastSystemArrival: Double?
    private var lastStallWarning: Double?
    private var lastHealthCheck: Double?
    private var healthFailedAt: Double?
    private var healthFailures = 0
    private var healthOff = false
    private var droppedSinceLog: [CaptureTrack: Int] = [:]
    private var droppedLoggedAt: [CaptureTrack: Double] = [:]
    private var droppedTotal: [CaptureTrack: Int] = [:]

    /// `log` gets the warnings and notes that go to session.log; `debug` the rest.
    public convenience init(micURL: URL, systemURL: URL, sources: CaptureSources, monitor: CaptureMonitor? = nil,
                clock: @escaping () -> Double = monotonicSeconds,
                log: @escaping (String) -> Void = { _ in }, debug: @escaping (String) -> Void = { _ in },
                sleep: @escaping (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
                ringCapacity: Int = CaptureRing.defaultCapacity, mute: MuteTimeline? = nil) {
        self.init(micURL: micURL, systemURL: systemURL, sources: sources, monitor: monitor, clock: clock, log: log,
                  debug: debug, sleep: sleep, ringCapacity: ringCapacity, runsWriterThread: true, mute: mute)
    }

    /// `runsWriterThread: false`: the test pumps `drainOnce` and `checkHealth` itself, in simulated time.
    init(micURL: URL, systemURL: URL, sources: CaptureSources, monitor: CaptureMonitor?, clock: @escaping () -> Double,
         log: @escaping (String) -> Void, debug: @escaping (String) -> Void, sleep: @escaping (Double) -> Void,
         ringCapacity: Int, runsWriterThread: Bool, mute: MuteTimeline? = nil) {
        self.micURL = micURL
        self.mute = mute
        self.systemURL = systemURL
        self.sources = sources
        self.monitor = monitor
        self.clock = clock
        self.log = log
        self.debug = debug
        self.sleep = sleep
        self.ringCapacity = ringCapacity
        self.runsWriterThread = runsWriterThread
    }

    // MARK: - public state

    /// "process-tap" or "scstream" once started; nil when nothing records system audio.
    public var systemSource: String? { stateLock.withLock { _systemSource } }
    /// "avcapture" or "scstream" once started; nil when nothing records the microphone.
    public var micSource: String? { stateLock.withLock { _micSource } }
    /// Tracks no source could deliver: "microphone", "system audio".
    public var missing: [String] { stateLock.withLock { _missing } }
    /// The rate each track arrives at before resampling (e.g. 24 kHz from AirPods), once it delivered.
    public var micRate: Double? { stateLock.withLock { _micRate } }
    public var systemRate: Double? { stateLock.withLock { _systemRate } }
    /// The microphone's name (AVCaptureSession only), e.g. "AirPods".
    public var micDevice: String? { stateLock.withLock { micCapture }?.deviceName }
    /// The output the tap is clocked by, e.g. "AirPods Pro".
    public var systemDevice: String? { stateLock.withLock { systemTap }?.deviceName }
    /// Tracks whose last write failed, with the error.
    public var writeFailures: [CaptureTrack: String] { stateLock.withLock { _writeFailures } }

    // MARK: - start / stop

    public func start() throws {
        guard !started else { throw CaptureError("CaptureRecorder already started") }
        stopFlag.clear()
        lastHealthCheck = nil
        healthFailures = 0
        healthOff = false
        droppedSinceLog = [:]
        droppedLoggedAt = [:]
        droppedTotal = [:]
        guarded(()) { try monitor?.begin(now: clock()) }
        micRing = CaptureRing(capacity: ringCapacity)
        systemRing = CaptureRing(capacity: ringCapacity)
        stateLock.withLock {
            _systemSource = nil
            _micSource = nil
            _missing = []
            _micRate = nil
            _systemRate = nil
            _writeFailures = [:]
        }
        let micWriter = try makeWriter(micURL)
        let systemWriter: TrackWriter
        do { systemWriter = try makeWriter(systemURL) } catch { micWriter.abort(); throw error }
        gate = mute.map(MicMuteGate.init)
        aligner = TrackAligner(mic: micWriter, system: systemWriter,
                               onReanchor: { [unowned self] track, drift in self.onReanchor(track, drift) },
                               log: log)
        armMicWatchdog()
        startWriterThread()
        do {
            try startCapture()
        } catch {
            stopSources()
            stopWriterThread()
            aligner?.abort()
            aligner = nil
            throw error
        }
        started = true
    }

    /// Stops the sources, drains what they delivered and finalizes both files, each to its own
    /// length (issue #18). Returns the frames per track; nil when it was not recording.
    /// Throws when finalizing failed (the `.part` files then keep a header stating what is valid),
    /// or when the writer thread did not finish within `writerStopTimeout`: then the files are left
    /// as `.part`, their headers patched once the stuck write returns, for `process` to recover.
    @discardableResult
    public func stop() throws -> (mic: Int, system: Int)? {
        guard started else { return nil }
        started = false
        stopSources()
        let finished = stopWriterThread()
        defer {
            aligner = nil
            guarded(()) { try monitor?.close(now: clock()) }
        }
        guard finished else {
            abandonWriters()
            throw CaptureError("the capture writer did not finish within \(Int(writerStopTimeout)) s; "
                               + "the .part files are left for `process` to recover")
        }
        let lengths = try finalize()
        if let start = aligner?.startPts { self.finished = (start, start + Int64(lengths.mic) * nanosPerFrame) }
        return lengths
    }

    /// Stops without finalizing: both `.part` files stay, their headers stating what was written.
    public func abort() {
        guard started else { return }
        started = false
        stopSources()
        if stopWriterThread() {
            drainAll()
            aligner?.abort()
        } else {
            abandonWriters()
        }
        aligner = nil
        guarded(()) { try monitor?.close(now: clock()) }
    }

    /// The writer thread is stuck in a write: the files are never touched from two threads, so the
    /// headers are patched (abort) on a thread of their own, once the stuck write lets go of the file.
    private func abandonWriters() {
        log("⚠ the capture writer did not finish within \(Int(writerStopTimeout)) s; "
            + "leaving the .part files for `process` to recover")
        guard let aligner else { return }
        let mic = aligner.mic, system = aligner.system
        let t = Thread { mic.abort(); system.abort() }
        t.name = "palaver.capture-abandon"
        t.start()
    }

    // MARK: - sources (`_start_capture`)

    private func startCapture() throws {
        let tapOK = startSystemTap()
        let micOK = startMic()
        stateLock.withLock {
            _systemSource = tapOK ? "process-tap" : nil
            _micSource = micOK ? "avcapture" : nil
        }
        let needMic = !micOK, needSystem = !tapOK
        guard needMic || needSystem else { return }
        do {
            try startScreenCaptureWithRetries(captureMic: needMic, captureSystem: needSystem)
        } catch {
            if !(micOK || tapOK) {
                throw CaptureError("neither the microphone nor system audio can be recorded: \(error)")
            }
            stateLock.withLock {
                if needMic { _missing.append("microphone") }
                if needSystem { _missing.append("system audio") }
            }
            if needMic { log("⚠ recording without the microphone: \(error)") }
            if needSystem { log("⚠ recording without system audio (the other participants): \(error)") }
            return
        }
        stateLock.withLock {
            if needMic { _micSource = "scstream" }
            if needSystem { _systemSource = "scstream" }
        }
    }

    private func startScreenCaptureWithRetries(captureMic: Bool, captureSystem: Bool) throws {
        let fallback = sources.screenCapture(micRing, systemRing)
        let attempts = Self.screenCaptureStartAttempts
        for attempt in 1...attempts {
            do {
                try fallback.start(captureMic: captureMic, captureSystem: captureSystem)
                screen = fallback
                return
            } catch {
                if attempt == attempts { throw error }
                log("warning: \(error); retrying in \(String(format: "%g", Self.screenCaptureRetrySeconds)) s "
                    + "(\(attempt)/\(attempts - 1))")
                sleep(Self.screenCaptureRetrySeconds)
            }
        }
    }

    private func startSystemTap() -> Bool {
        let tap = sources.systemTap(systemRing)
        do { try tap.start() } catch {
            log("warning: system audio tap unavailable (\(error)); falling back to ScreenCaptureKit system audio, "
                + "which other recorders running in parallel can starve.")
            return false
        }
        stateLock.withLock { systemTap = tap }
        return true
    }

    private func startMic() -> Bool {
        let mic = sources.mic(micRing)
        do { try mic.start() } catch {
            log("warning: microphone via AVCaptureSession unavailable (\(error)); trying ScreenCaptureKit.")
            return false
        }
        stateLock.withLock { micCapture = mic }
        return true
    }

    /// ScreenCaptureKit, then the microphone, then the tap (Python's order).
    private func stopSources() {
        screen?.stop()
        screen = nil
        let (mic, tap) = stateLock.withLock { () -> (CaptureSource?, CaptureSource?) in
            defer { micCapture = nil; systemTap = nil }
            return (micCapture, systemTap)
        }
        mic?.stop()
        tap?.stop()
    }

    // MARK: - the writer thread (`_writer_loop`)

    private func startWriterThread() {
        guard runsWriterThread else { return }
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in  // strong: the thread ends when stopFlag is set
            while !stopFlag.isSet {
                if !drainOnce() {
                    checkHealth()
                    _ = stopFlag.wait(0.02)
                }
            }
            done.signal()
        }
        thread.name = "palaver.capture-writer"
        thread.qualityOfService = .userInitiated
        writerThread = thread
        writerDone = done
        thread.start()
    }

    /// Python joined for 5 s and then finalized anyway, racing a writer stuck in a slow write. Here
    /// the files are never touched from two threads: after 5 s it says so and keeps waiting, up to
    /// `writerStopTimeout` in all. False when the writer thread is still busy then.
    @discardableResult
    private func stopWriterThread() -> Bool {
        stopFlag.set()
        defer { writerThread = nil; writerDone = nil }
        guard let done = writerDone else { return true }
        let warnAfter = min(5, writerStopTimeout)
        if done.wait(timeout: .now() + warnAfter) == .success { return true }
        log("⚠ the capture writer is still busy after \(Int(warnAfter)) s (slow disk?); waiting for it")
        return done.wait(timeout: .now() + max(0, writerStopTimeout - warnAfter)) == .success
    }

    /// One buffer from each ring, if there is one; true when something was handled (`_drain_once`).
    @discardableResult
    func drainOnce() -> Bool {
        var progress = false
        for track in [CaptureTrack.mic, .system] {
            let ring = track == .mic ? micRing : systemRing
            if let (pts, format) = ring.pop(into: &scratch) {
                handle(pts: pts, format: format, track: track)
                progress = true
            }
            let dropped = ring.takeDropped()
            if dropped > 0 || droppedSinceLog[track, default: 0] > 0 { noteDropped(dropped, track) }
        }
        return releaseMic() || progress
    }

    /// The held mic chunks that are due (all: the recording stops) to the aligner; true when there were any.
    @discardableResult
    private func releaseMic(all: Bool = false) -> Bool {
        guard let gate else { return false }
        var due: [TimedChunk] = []
        if !gate.isEmpty {
            due = gate.release(now: Int64((clock() * 1e9).rounded()), all: all)
            for chunk in due { place(chunk, .mic) }
        }
        silenceLate(gate)
        return !due.isEmpty
    }

    /// A mute told later than the hold: what the mic track already has of it is overwritten with
    /// silence (the live workers may have read it meanwhile).
    private func silenceLate(_ gate: MicMuteGate) {
        guard let from = gate.timeline.takeChangedFrom(), let until = gate.releasedUntil, from < until,
              let aligner, let start = aligner.startPts else { return }
        var seconds = 0.0
        for r in gate.timeline.mutedRanges(from: from, to: until) {
            let frames = TrackAligner.frameOffset(r.lowerBound - start)..<TrackAligner.frameOffset(r.upperBound - start)
            guard aligner.mic.silence(frames) else { writeFailed(.mic, CaptureError("cannot silence a late mute")); continue }
            seconds += Double(r.upperBound - r.lowerBound) / 1e9
            lateLock.withLock { _late.append(r) }
        }
        if seconds > 0 {
            log("silenced \(String(format: "%.1f", seconds)) s of microphone already written: "
                + "\(gate.timeline.appName) told the mute late")
        }
    }

    /// A full ring (the writer fell behind by seconds): logged at most once a minute per track.
    private func noteDropped(_ count: Int, _ track: CaptureTrack) {
        droppedSinceLog[track, default: 0] += count
        droppedTotal[track, default: 0] += count
        let now = clock()
        if let last = droppedLoggedAt[track], now - last < Self.droppedLogSeconds { return }
        droppedLoggedAt[track] = now
        log("⚠ capture buffer full: \(droppedSinceLog[track]!) \(Self.trackName(track)) buffers dropped")
        droppedSinceLog[track] = 0
    }

    private func drainAll() {
        while drainOnce() {}
        releaseMic(all: true)
    }

    private func handle(pts: Int64, format: PCMFormat, track: CaptureTrack) {
        guard let aligner, !aligner.finished else { return }
        guard let (samples, rate) = scratch.withUnsafeBytes({ PCM.mono($0, format: format) }) else { return }
        let now = clock()
        guarded(()) { try monitor?.chunk(track, now: now, pts: pts, samples: samples, rate: rate) }
        switch track {
        case .mic:
            if lastStallWarning != nil, let last = lastMicArrival {
                log("microphone audio resumed after \(String(format: "%.0f", now - last)) s.")
                lastStallWarning = nil
            }
            lastMicArrival = now
            stateLock.withLock { _micRate = rate }
        case .system:
            lastSystemArrival = now
            stateLock.withLock { _systemRate = rate }
        }
        let chunk = TimedChunk(pts: pts, samples: samples, rate: rate)
        guard track == .mic, let gate else { place(chunk, track); return }
        // Held back: the aligner learns where the mic starts now, so system audio is written meanwhile.
        if aligner.micFirstPts == nil {
            do { try aligner.announce(.mic, firstPts: pts) } catch { writeFailed(.system, error) }
        }
        gate.push(chunk)
    }

    private func place(_ chunk: TimedChunk, _ track: CaptureTrack) {
        guard let aligner, !aligner.finished else { return }
        let writer = aligner.writer(track)
        let before = writer.framesWritten
        do {
            try aligner.handle(chunk, track: track)
            if writer.framesWritten > before { writeSucceeded(track) }
        } catch {
            writeFailed(track, error)
        }
    }

    private func writeFailed(_ track: CaptureTrack, _ error: Error) {
        let first = stateLock.withLock { () -> Bool in
            defer { _writeFailures[track] = "\(error)" }
            return _writeFailures[track] == nil
        }
        if first { log("⚠ cannot write the \(Self.trackName(track)) track: \(error); audio is being lost") }
    }

    private func writeSucceeded(_ track: CaptureTrack) {
        let wasFailing = stateLock.withLock { _writeFailures.removeValue(forKey: track) != nil }
        if wasFailing { log("writing the \(Self.trackName(track)) track works again") }
    }

    private static func trackName(_ track: CaptureTrack) -> String { track == .mic ? "microphone" : "system audio" }

    /// Drains the rings, flushes the resamplers and Phase A, finalizes both files (`_finalize_writers`).
    private func finalize() throws -> (mic: Int, system: Int) {
        drainAll()
        guard let aligner else { return (0, 0) }
        return try aligner.finish()
    }

    // MARK: - health (`_check_health`, `_check_mic_stall`, `_guarded`)

    /// Counts from now, so a track that never delivers is caught too.
    private func armMicWatchdog() {
        let now = clock()
        lastMicArrival = now
        lastSystemArrival = now
        lastStallWarning = nil
    }

    /// The mic watchdog, then every 0.25 s the health monitor. Never throws: it runs on the writer thread.
    func checkHealth() {
        checkMicStall()
        let now = clock()
        if let last = lastHealthCheck, now - last < Self.healthCheckSeconds { return }
        lastHealthCheck = now
        guard let monitor else { return }
        let status = currentStatus(now)
        guarded(()) { try monitor.check(status) }
    }

    func currentStatus(_ now: Double) -> CaptureStatus {
        let (missing, systemSource, failures, mic, tap) = stateLock.withLock {
            (_missing, _systemSource, _writeFailures, micCapture, systemTap)
        }
        var written: [CaptureTrack: Double] = [:]
        if let aligner {
            // What the mute gate holds is on its way to disk (its delay is longer than the length check allows).
            written[.mic] = Double(aligner.mic.framesWritten) / Double(captureSampleRate) + (gate?.heldSeconds ?? 0)
            written[.system] = Double(aligner.system.framesWritten) / Double(captureSampleRate)
        }
        var access: [CaptureTrack: String] = [:]
        access[.mic] = mic?.problem
        access[.system] = tap?.problem
        let micStalled = lastMicArrival.map { !missing.contains("microphone") && now - $0 >= Self.micStallSeconds } ?? false
        let systemStalled = lastSystemArrival.map {
            systemSource == "process-tap" && now - $0 >= Self.systemStallSeconds
        } ?? false
        return CaptureStatus(now: now, written: written, startPts: aligner?.startPts, access: access,
                             micStalled: micStalled, systemStalled: systemStalled, writeFailures: failures,
                             dropped: droppedTotal)
    }

    func checkMicStall() {
        guard let last = lastMicArrival, !missing.contains("microphone") else { return }
        let now = clock()
        let idle = now - last
        guard idle >= Self.micStallSeconds else { return }
        if let warned = lastStallWarning, now - warned < Self.micStallReminderSeconds { return }
        lastStallWarning = now
        log("⚠ no microphone audio for \(String(format: "%.0f", idle)) s — ScreenCaptureKit may have "
            + "stopped delivering (display sleep, device change?).")
    }

    private func onReanchor(_ track: CaptureTrack, _ drift: Double) -> Bool {
        guarded(false) { try monitor?.reanchor(track, now: clock(), drift: drift) ?? false }
    }

    /// A health-monitor call: whatever it throws, the writer goes on (logged at debug, at most once a
    /// minute). A monitor that keeps failing is switched off for the recording, which the log says once.
    @discardableResult
    private func guarded<T>(_ fallback: T, _ body: () throws -> T) -> T {
        if healthOff { return fallback }
        do { return try body() } catch {
            let now = monotonicSeconds()
            if healthFailedAt == nil || now - healthFailedAt! >= Self.healthFailureLogSeconds {
                healthFailedAt = now
                debug("health monitor failed; recording goes on: \(error)")
            }
            healthFailures += 1
            if healthFailures >= Self.healthFailuresOff {
                healthOff = true
                log("Audio health checks failed; warnings are off for this recording")
            }
            return fallback
        }
    }

    /// The mic stretches silenced after they were written, in seconds from the track's start.
    public var lateSilenced: [ClosedRange<Double>] {
        let start = finished?.start ?? aligner?.startPts ?? 0
        return lateLock.withLock { _late }.map { Double($0.lowerBound - start) / 1e9...Double($0.upperBound - start) / 1e9 }
    }

    /// After the stop: mute changes told since then (Teams' log comes late) silence the finished mic track.
    /// The caller waits for them first; nothing runs on the writer thread any more.
    public func silenceAfterStop() {
        guard let mute, let (start, end) = finished, let from = mute.takeChangedFrom(), from < end else { return }
        let fd = open(micURL.path, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var seconds = 0.0
        let zeros = [UInt8](repeating: 0, count: 64 * 1024)
        for r in mute.mutedRanges(from: max(from, start), to: end) {
            var frame = TrackAligner.frameOffset(r.lowerBound - start)
            let stop = TrackAligner.frameOffset(r.upperBound - start)
            while frame < stop {
                let n = min(stop - frame, zeros.count / 2)
                guard zeros.withUnsafeBytes({ pwrite(fd, $0.baseAddress, n * 2, off_t(TrackWriter.headerSize + frame * 2)) }) == n * 2
                else { log("⚠ cannot silence the microphone track after the stop"); return }
                frame += n
            }
            seconds += Double(r.upperBound - r.lowerBound) / 1e9
            lateLock.withLock { _late.append(r) }
        }
        if seconds > 0 {
            log("silenced \(String(format: "%.1f", seconds)) s of microphone after the stop: \(mute.appName) told the mute late")
        }
    }

    // MARK: - tests

    /// The sources as started (tests reach their route watchers through these).
    var startedMic: CaptureSource? { stateLock.withLock { micCapture } }
    var startedTap: CaptureSource? { stateLock.withLock { systemTap } }
}
