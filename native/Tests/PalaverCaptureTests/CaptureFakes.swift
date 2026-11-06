import CoreAudio
import Foundation
@testable import PalaverCapture

// Fakes at the operating-system boundary only: nothing here opens a device, a tap or a stream.

/// A lock for fakes that a watcher thread and the test thread both touch.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    var get: T { lock.withLock { value } }
    func with<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&value) } }
}

/// One IO cycle into a tap's handler: interleaved float32 `samples`, both stamps at `host`.
func callIO(_ handler: TapIOHandler, _ samples: [Float], channels: UInt32, host: UInt64) {
    var stamp = AudioTimeStamp()
    stamp.mHostTime = host
    stamp.mFlags = .hostTimeValid
    samples.withUnsafeBytes { raw in
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: channels, mDataByteSize: UInt32(raw.count),
            mData: UnsafeMutableRawPointer(mutating: raw.baseAddress)))
        withUnsafePointer(to: &stamp) { ts in withUnsafePointer(to: &list) { handler(ts, $0, ts) } }
    }
}

/// What a ring holds, decoded by the production decoder: (pts ns, mono samples, rate).
func drain(_ ring: CaptureRing) -> [(pts: Int64, samples: [Float], rate: Double)] {
    var out: [(Int64, [Float], Double)] = []
    var buffer: [UInt8] = []
    while let (pts, format) = ring.pop(into: &buffer) {
        if let (samples, rate) = buffer.withUnsafeBytes({ PCM.mono($0, format: format) }) { out.append((pts, samples, rate)) }
    }
    return out
}

func waitFor(_ timeout: Double = 30, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return predicate()
}

/// Collects log lines.
final class LogLines: @unchecked Sendable {
    private let lines = Locked<[String]>([])
    var all: [String] { lines.get }
    var text: String { all.joined(separator: "\n") }
    func add(_ line: String) { lines.with { $0.append(line) } }
    func clear() { lines.with { $0.removeAll() } }
    var sink: (String) -> Void { { [self] in add($0) } }
}

// MARK: - test_process_tap.py's _FakeBackend

enum Call: Equatable {
    case translate(pid_t)
    case createTap([AudioObjectID])
    case format(AudioObjectID)
    case createAggregate(String, String)  // (tap uid, output uid)
    case createIO(AudioObjectID)
    case start(AudioObjectID, UInt)
    case stop(AudioObjectID, UInt)
    case destroyIO(AudioObjectID, UInt)
    case destroyAggregate(AudioObjectID)
    case destroyTap(AudioObjectID)
}

final class FakeTapBackend: TapBackend, @unchecked Sendable {
    struct State {
        var deliver = true
        var failStart = false
        var outputUID = "BuiltInSpeakerDevice"
        var deviceRate: Double = 48_000
        var nextAggregate: AudioObjectID = 20
        var calls: [Call] = []
        var excluded: [AudioObjectID]?
        var handler: TapIOHandler?
        var aggregateFailures = 0  // the next n aggregate creations fail
        var aggregateError: Error = ProcessTapError("pyobjc hiccup")
        var translateThrows: Set<pid_t> = []
    }
    let state = Locked(State())
    static let io: UInt = 0x10

    var calls: [Call] { state.get.calls }
    private func record(_ call: Call) { state.with { $0.calls.append(call) } }

    func translatePID(_ pid: pid_t) throws -> AudioObjectID? {
        record(.translate(pid))
        if state.get.translateThrows.contains(pid) { throw ProcessTapError("process-object translation failed") }
        switch pid {
        case 1234: return 99
        case 4321: return nil
        default: return AudioObjectID(1000 + pid)
        }
    }

    func createProcessTap(excluding processes: [AudioObjectID]) throws -> (id: AudioObjectID, uid: String) {
        record(.createTap(processes))
        state.with { $0.excluded = processes }
        return (10, "tap-uid")
    }

    func readTapFormat(_ tap: AudioObjectID) throws -> TapFormat {
        record(.format(tap))
        return TapFormat(sampleRate: 48_000, channels: 2)
    }

    func deviceSampleRate(_ device: AudioObjectID) throws -> Double? { state.get.deviceRate }

    func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        let failure: Error? = state.with { s in
            guard s.aggregateFailures > 0 else { return nil }
            s.aggregateFailures -= 1
            return s.aggregateError
        }
        if let failure { throw failure }
        let s = state.get
        record(.createAggregate(tapUID, s.outputUID))
        return s.nextAggregate
    }

    func createIOProc(_ device: AudioObjectID, handler: @escaping TapIOHandler) throws -> IOProcToken {
        record(.createIO(device))
        state.with { $0.handler = handler }
        return IOProcToken(raw: Self.io)
    }

    func startDevice(_ device: AudioObjectID, _ proc: IOProcToken) throws {
        record(.start(device, proc.raw))
        let s = state.get
        if s.failStart { throw ProcessTapError("AudioDeviceStart failed", osStatus: -1) }
        if s.deliver, let handler = s.handler {
            // 480 frames at 48 kHz stereo (1, 0) → 480 mono frames of 0.5 at the native rate.
            let frames: [Float] = (0..<480).flatMap { _ -> [Float] in [1, 0] }
            callIO(handler, frames, channels: 2, host: 123_000_000)
        }
    }

    func stopDevice(_ device: AudioObjectID, _ proc: IOProcToken) { record(.stop(device, proc.raw)) }
    func destroyIOProc(_ device: AudioObjectID, _ proc: IOProcToken) { record(.destroyIO(device, proc.raw)) }
    func destroyAggregateDevice(_ device: AudioObjectID) { record(.destroyAggregate(device)) }
    func destroyProcessTap(_ tap: AudioObjectID) { record(.destroyTap(tap)) }
    func defaultOutputUID() throws -> String { state.get.outputUID }
    func defaultOutputName() throws -> String? { nil }
    func hostTimeToNanos(_ hostTime: UInt64) -> Int64 { Int64(hostTime) }

    /// One IO cycle of the current aggregate (`_buffer`).
    func buffer(_ n: Int = 240) {
        if let handler = state.get.handler { callIO(handler, [Float](repeating: 0, count: n), channels: 1, host: 123_000_000) }
    }

    var aggregates: Int { calls.filter { if case .createAggregate = $0 { return true } else { return false } }.count }
}

// MARK: - test_av_mic.py's fakes

final class FakeMicSession: MicSession, @unchecked Sendable {
    let uid: String
    let sink: CaptureRing
    private let flag = Locked(false)
    var running: Bool { flag.get }
    init(uid: String, sink: CaptureRing) {
        self.uid = uid
        self.sink = sink
    }
    func start() throws { flag.with { $0 = true } }
    func stop() { flag.with { $0 = false } }
}

final class FakeMicBackend: MicBackend, @unchecked Sendable {
    struct State {
        var uid = "BuiltInMicrophoneDevice"
        var fail = false
        var sessions: [FakeMicSession] = []
        var names: [String: String] = [:]
    }
    let state = Locked(State())
    var sessions: [FakeMicSession] { state.get.sessions }

    init(names: [String: String] = [:]) { state.with { $0.names = names } }

    func defaultInputUID() throws -> String { state.get.uid }

    func openSession(uid: String, sink: CaptureRing) throws -> MicSession {
        if state.get.fail { throw AVMicError("microphone access denied", isPermission: true) }
        let session = FakeMicSession(uid: uid, sink: sink)
        state.with { $0.sessions.append(session) }
        return session
    }

    func deviceName(uid: String) -> String? { state.get.names[uid] }
}

/// Pushes float32 mono samples into a ring the way a capture delegate does.
func push(_ ring: CaptureRing, pts: Int64, _ samples: [Float], rate: Double) {
    _ = samples.withUnsafeBytes {
        ring.push(pts: pts, format: PCMFormat(sampleRate: rate, formatFlags: PCMFormat.flagIsFloat, channels: 1,
                                              bitsPerChannel: 32), bytes: $0)
    }
}

// MARK: - test_capture_recorder.py's _FakeSource and the faked _start_scstream

final class FakeSource: CaptureSource, @unchecked Sendable {
    let ring: CaptureRing
    let error: Error?
    private let flags = Locked((started: false, stopped: false))
    var started: Bool { flags.get.started }
    var stopped: Bool { flags.get.stopped }
    var problem: String?
    var deviceName: String?
    init(ring: CaptureRing, error: Error?) {
        self.ring = ring
        self.error = error
    }
    func start() throws {
        if let error { throw error }
        flags.with { $0.started = true }
    }
    func stop() { flags.with { $0.stopped = true } }
}

final class FakeScreenCapture: ScreenCaptureFallback, @unchecked Sendable {
    var calls: [(mic: Bool, system: Bool)] = []
    var failuresLeft: Int
    var stopped = false
    let mic: CaptureRing
    let system: CaptureRing
    init(mic: CaptureRing, system: CaptureRing, failures: Int) {
        self.mic = mic
        self.system = system
        failuresLeft = failures
    }
    func start(captureMic: Bool, captureSystem: Bool) throws {
        calls.append((captureMic, captureSystem))
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw ScreenCaptureError("SCStream startCapture failed")
        }
    }
    func stop() { stopped = true }
}
