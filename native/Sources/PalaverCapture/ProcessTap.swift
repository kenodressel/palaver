// System audio through a Core Audio process tap (palaver/_audio/process_tap.py).
//
// The IO proc runs on the clock device's cycle, silence included: every
// recording's system and mic tracks ended within 0.1 s of each other. A tap
// that delivers nothing has lost its device and is rebuilt.
import CoreAudio
import Darwin
import Foundation
import Synchronization

/// A process-tap failure, with Python's texts (process_tap.py:38-41, 408-423).
public struct ProcessTapError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public let osStatus: OSStatus?

    public init(_ message: String, osStatus: OSStatus? = nil) {
        self.message = message
        self.osStatus = osStatus
    }

    public var description: String { message }

    public static let permissionDeniedText = "permission denied - System Settings -> Privacy -> System Audio Recording"
    public static let unsupportedText = "requires macOS 14.4+ and an audio output device"

    /// An OSStatus from a Core Audio call → the error the status shows (`_error_for_status`).
    public static func forStatus(_ message: String, _ status: OSStatus) -> ProcessTapError {
        if status == kAudioHardwareIllegalOperationError { return ProcessTapError(permissionDeniedText, osStatus: status) }
        if status == kAudioHardwareUnsupportedOperationError { return ProcessTapError(unsupportedText, osStatus: status) }
        return ProcessTapError("\(message): OSStatus \(formatOSStatus(status))", osStatus: status)
    }
}

/// `1852797029 ('nope')` for a four-char code, the bare number otherwise (`_format_osstatus`).
public func formatOSStatus(_ status: OSStatus) -> String {
    guard status >= 0 else { return String(status) }
    let raw = withUnsafeBytes(of: UInt32(status).bigEndian) { Array($0) }
    guard raw.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return String(status) }
    return "\(status) ('\(String(decoding: raw, as: UTF8.self))')"
}

public struct TapFormat: Equatable, Sendable {
    public var sampleRate: Double
    public var channels: Int
    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// An `AudioDeviceIOProcID`, opaque to `ProcessTap` (fakes hand out their own).
public struct IOProcToken: Hashable, Sendable {
    public let raw: UInt
    public init(raw: UInt) { self.raw = raw }
}

/// The IO block's arguments `ProcessTap` reads: (inNow, inInputData, inInputTime).
/// Called on Core Audio's realtime IO thread.
public typealias TapIOHandler = (UnsafePointer<AudioTimeStamp>?, UnsafePointer<AudioBufferList>?,
                                 UnsafePointer<AudioTimeStamp>?) -> Void

/// Everything the tap asks of Core Audio (process_tap.py's `_Backend`); tests use a fake.
public protocol TapBackend: AnyObject {
    /// kAudioHardwarePropertyTranslatePIDToProcessObject; nil when the pid has no process object.
    func translatePID(_ pid: pid_t) throws -> AudioObjectID?
    /// A private, unmuted, mixed-down mono global tap of everything except `processes`; its id and UUID.
    func createProcessTap(excluding processes: [AudioObjectID]) throws -> (id: AudioObjectID, uid: String)
    func readTapFormat(_ tap: AudioObjectID) throws -> TapFormat
    /// kAudioDevicePropertyNominalSampleRate; nil when it says 0.
    func deviceSampleRate(_ device: AudioObjectID) throws -> Double?
    /// The private aggregate "Palaver System Audio" on the default output, carrying the tap.
    func createAggregateDevice(tapUID: String) throws -> AudioObjectID
    func createIOProc(_ device: AudioObjectID, handler: @escaping TapIOHandler) throws -> IOProcToken
    func startDevice(_ device: AudioObjectID, _ proc: IOProcToken) throws
    func stopDevice(_ device: AudioObjectID, _ proc: IOProcToken)
    func destroyIOProc(_ device: AudioObjectID, _ proc: IOProcToken)
    func destroyAggregateDevice(_ device: AudioObjectID)
    func destroyProcessTap(_ tap: AudioObjectID)
    func defaultOutputUID() throws -> String
    func defaultOutputName() throws -> String?
    /// AudioConvertHostTimeToNanos. Called on the IO thread: must not allocate or lock.
    func hostTimeToNanos(_ hostTime: UInt64) -> Int64
}

/// Global "everything but us" system-audio tap (`ProcessTap`).
///
/// - The tap excludes the app's own process and its workers: `excludedPIDs`
///   is asked once, at `start` (today's Python excluded itself and its parent).
/// - The private aggregate that carries the tap takes its clock from the
///   default output at creation. A watcher (every `routePollInterval`)
///   rebuilds it when the default output changes, follows the aggregate's
///   nominal rate when that changes (AirPods dropping to 24 kHz in a call),
///   and rebuilds it when it delivered nothing for 5 s, then 10, 20, 40, at
///   most 60 s. A failed rebuild sets `problem = "device"` and is retried
///   every tick.
/// - The IO proc copies the first buffer's float32 bytes into the ring with
///   PTS = AudioConvertHostTimeToNanos(inInputTime.mHostTime) and the
///   aggregate's current rate; nothing else happens on the IO thread.
public final class ProcessTap: CaptureSource, @unchecked Sendable {
    public static let quietRebuildSeconds = 5.0
    public static let quietRebuildMaxSeconds = 60.0

    private let sink: CaptureRing
    private let backend: TapBackend
    private let excludedPIDs: () -> [pid_t]
    private let routePollInterval: Double?
    private let clock: () -> Double
    private let log: (String) -> Void

    // Guarded by `lock` (the watcher, start and stop).
    private let lock = NSLock()
    private var tapID: AudioObjectID?
    private var tapUID: String?
    private var aggregateID: AudioObjectID?
    private var ioProc: IOProcToken?
    private var outputUID: String?
    private var started = false
    private var stopping = false
    // The watcher's own: when the aggregate last delivered (or was built), whether it has,
    // and how often it was rebuilt for delivering nothing since one did.
    private var lastAudio: Double
    private var delivered = false
    private var quietRebuilds = 0
    private var seenDeliveries = 0
    private var poller: Poller?

    // Shared with the IO thread: lock-free.
    private let sourceRateBits = Atomic<UInt64>(48_000.0.bitPattern)
    private let sourceChannels = Atomic<Int>(1)
    private let deliveries = Atomic<Int>(0)

    // For the status, read from other threads.
    private let status = Mutex<(name: String?, problem: String?)>((nil, nil))

    public init(sink: CaptureRing, excludedPIDs: @escaping () -> [pid_t] = { [getpid()] },
                backend: TapBackend = CoreAudioTapBackend(), routePollInterval: Double? = 1.0,
                clock: @escaping () -> Double = monotonicSeconds, log: @escaping (String) -> Void = { _ in }) {
        self.sink = sink
        self.excludedPIDs = excludedPIDs
        self.backend = backend
        self.routePollInterval = routePollInterval
        self.clock = clock
        self.log = log
        lastAudio = clock()
    }

    /// The output the tap is clocked by, e.g. "AirPods Pro" (for the status).
    public var deviceName: String? { status.withLock { $0.name } }

    /// "device" while the tap cannot be rebuilt on a new output; nil once it works.
    public var problem: String? { status.withLock { $0.problem } }

    /// The rate chunks are stamped with now: the aggregate's nominal rate.
    public var sourceRate: Double { Double(bitPattern: sourceRateBits.load(ordering: .relaxed)) }

    public func start() throws {
        try lock.withLock {
            if started || tapID != nil || aggregateID != nil { throw ProcessTapError("ProcessTap already started") }
            stopping = false
        }
        do {
            let excluded = try resolveExcludedProcesses()
            let tap = try backend.createProcessTap(excluding: excluded)
            try lock.withLock {
                tapID = tap.id
                tapUID = tap.uid
                try openAggregate()
                started = true
            }
        } catch {
            stop()
            throw error
        }
        if let interval = routePollInterval, interval > 0 {
            poller = Poller(name: "palaver.tap-route", interval: interval) { [weak self] in self?.checkRoute() }
        }
    }

    public func stop() {
        lock.withLock { stopping = true }
        poller?.cancel()
        poller = nil
        lock.withLock {
            closeAggregate()
            if let tap = tapID { backend.destroyProcessTap(tap) }
            tapID = nil
            tapUID = nil
            started = false
        }
    }

    /// One look at the default output (`_check_route`): follow its rate, or
    /// rebuild the aggregate on a new one, or on the same one when it delivers nothing.
    func checkRoute() {
        let uid: String
        do { uid = try backend.defaultOutputUID() } catch { return }  // transient while devices switch
        let current = lock.withLock { outputUID }
        if uid != current {
            log("default output changed (\(current ?? "None") → \(uid)); rebuilding system audio tap")
            rebuild()
            return
        }
        lock.withLock { followDeviceRate() }
        let now = clock()
        let count = deliveries.load(ordering: .relaxed)
        if count != seenDeliveries {
            seenDeliveries = count
            lastAudio = now
            delivered = true
        }
        let quiet = now - lastAudio
        let wait = min(Self.quietRebuildSeconds * pow(2, Double(quietRebuilds)), Self.quietRebuildMaxSeconds)
        if quiet >= wait {
            log("system audio tap delivered nothing for \(String(format: "%.0f", quiet)) s; rebuilding it")
            quietRebuilds += 1
            rebuild()
        } else if quietRebuilds > 0, delivered {
            log("system audio tap delivers again")
            quietRebuilds = 0
        }
    }

    // MARK: - private (the lock is held unless said otherwise)

    /// A new aggregate on the current default output (`_rebuild`). Takes the lock.
    private func rebuild() {
        lock.withLock {
            if stopping { return }
            closeAggregate()
            do {
                try openAggregate()
                if problem != nil { log("system audio tap rebuilt; recording again") }
                setProblem(nil)
            } catch {
                // The old aggregate is gone; retried every tick. Not a permission problem as far
                // as anyone can tell (kAudioHardwareIllegalOperationError proves nothing): "device".
                if problem == nil { log("rebuilding system audio tap failed; retrying: \(error)") }
                setProblem("device")
                closeAggregate()
                outputUID = nil  // forces another attempt next tick
            }
        }
    }

    /// The aggregate on the current default output, IO started (`_open_aggregate`).
    private func openAggregate() throws {
        guard let tapID, let tapUID else { throw ProcessTapError("ProcessTap not started") }
        outputUID = try backend.defaultOutputUID()
        let name = try? backend.defaultOutputName()  // for the status; recording goes on without it
        status.withLock { $0.name = name }
        // The tap's mixdown format follows the output device; re-read it so chunks after a rebuild carry the right rate.
        let format = try backend.readTapFormat(tapID)
        sourceRateBits.store(format.sampleRate.bitPattern, ordering: .relaxed)
        sourceChannels.store(max(1, format.channels), ordering: .relaxed)
        let aggregate = try backend.createAggregateDevice(tapUID: tapUID)
        aggregateID = aggregate
        // Buffers arrive at the aggregate's rate, its clock device's: 24 kHz for AirPods in a call, whatever the tap says.
        followDeviceRate()
        lastAudio = clock()
        delivered = false
        seenDeliveries = deliveries.load(ordering: .relaxed)
        // Strong: Core Audio keeps the block (and so the tap) until the IO proc is destroyed in closeAggregate.
        let proc = try backend.createIOProc(aggregate) { now, input, inputTime in
            self.handleIO(now, input, inputTime)
        }
        ioProc = proc
        // No first-buffer gate: a quiet start is not a failure; the watcher rebuilds one that stays quiet.
        try backend.startDevice(aggregate, proc)
    }

    private func closeAggregate() {
        if let aggregate = aggregateID, let proc = ioProc {
            backend.stopDevice(aggregate, proc)
            backend.destroyIOProc(aggregate, proc)
        }
        if let aggregate = aggregateID { backend.destroyAggregateDevice(aggregate) }
        ioProc = nil
        aggregateID = nil
    }

    /// Takes the aggregate's current rate (`_follow_device_rate`): AirPods drop from 48 to 24 kHz once
    /// a call opens their mic; read at the old rate, the system track came out at double speed with gaps.
    private func followDeviceRate() {
        guard let aggregate = aggregateID else { return }
        guard let rate = try? backend.deviceSampleRate(aggregate), rate > 0 else { return }
        let old = sourceRate
        if rate != old {
            log("system audio rate \(String(format: "%g", old)) Hz → \(String(format: "%g", rate)) Hz")
            sourceRateBits.store(rate.bitPattern, ordering: .relaxed)
        }
    }

    private func setProblem(_ kind: String?) { status.withLock { $0.problem = kind } }

    /// Our own pid must translate; the others may be gone or not audio clients (`_resolve_excluded_processes`).
    private func resolveExcludedProcesses() throws -> [AudioObjectID] {
        var seen = Set<pid_t>()
        let pids = excludedPIDs().filter { $0 > 0 && seen.insert($0).inserted }
        var objects: [AudioObjectID] = []
        for (index, pid) in pids.enumerated() {
            do {
                if let object = try backend.translatePID(pid) {
                    objects.append(object)
                } else if index == 0 {
                    log("current PID \(pid) has no CoreAudio process object")
                }
            } catch {
                if index == 0 { throw error }
                log("excluded PID \(pid) is not a CoreAudio process")
            }
        }
        return objects
    }

    /// The IO proc (`_handle_io`/`_deliver`), on Core Audio's realtime thread: no allocation, no locks
    /// but the ring's, no Objective-C. The first buffer of the list holds the tap's interleaved float32.
    private func handleIO(_ now: UnsafePointer<AudioTimeStamp>?, _ input: UnsafePointer<AudioBufferList>?,
                          _ inputTime: UnsafePointer<AudioTimeStamp>?) {
        guard let input, input.pointee.mNumberBuffers > 0 else { return }
        let buffer = input.pointee.mBuffers  // the first AudioBuffer
        let byteCount = Int(buffer.mDataByteSize) & ~3
        guard byteCount > 0, let data = buffer.mData else { return }
        guard let stamp = inputTime ?? now else { return }
        let hostTime = stamp.pointee.mHostTime
        guard hostTime != 0 else { return }
        let pts = backend.hostTimeToNanos(hostTime)
        deliveries.add(1, ordering: .relaxed)
        let channels = buffer.mNumberChannels > 0 ? Int(buffer.mNumberChannels) : sourceChannels.load(ordering: .relaxed)
        let format = PCMFormat(sampleRate: sourceRate, formatFlags: PCMFormat.flagIsFloat | 0x8 /* packed */,
                               channels: channels, bitsPerChannel: 32)
        sink.push(pts: pts, format: format, bytes: UnsafeRawBufferPointer(start: data, count: byteCount))
    }
}

// MARK: - The real Core Audio backend

/// Core Audio calls behind `TapBackend`. Creating one touches nothing; only
/// `ProcessTap.start` does (that needs the System Audio Recording permission).
public final class CoreAudioTapBackend: TapBackend {
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    /// Stop-path failures are only logged (`_log_stop_status`).
    private let log: (String) -> Void

    public init(log: @escaping (String) -> Void = { _ in }) { self.log = log }

    public func translatePID(_ pid: pid_t) throws -> AudioObjectID? {
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(Self.system, &address, UInt32(MemoryLayout<pid_t>.size), &qualifier,
                                                &size, &object)
        guard status == kAudioHardwareNoError else {
            throw ProcessTapError.forStatus("process-object translation failed", status)
        }
        return object == kAudioObjectUnknown ? nil : object
    }

    public func createProcessTap(excluding processes: [AudioObjectID]) throws -> (id: AudioObjectID, uid: String) {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: processes)
        description.name = "Palaver System Audio Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.isMixdown = true
        description.isMono = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == kAudioHardwareNoError else { throw ProcessTapError.forStatus("process tap creation failed", status) }
        guard tap != kAudioObjectUnknown else { throw ProcessTapError("process tap creation returned no tap id") }
        return (tap, description.uuid.uuidString)
    }

    public func readTapFormat(_ tap: AudioObjectID) throws -> TapFormat {
        var address = Self.address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == kAudioHardwareNoError else { throw ProcessTapError.forStatus("tap format lookup failed", status) }
        return TapFormat(sampleRate: asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000,
                         channels: asbd.mChannelsPerFrame > 0 ? Int(asbd.mChannelsPerFrame) : 1)
    }

    public func deviceSampleRate(_ device: AudioObjectID) throws -> Double? {
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        guard status == kAudioHardwareNoError else { throw ProcessTapError.forStatus("sample rate lookup failed", status) }
        return rate > 0 ? rate : nil
    }

    public func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        // The aggregate needs a main sub-device for its clock: without one Core Audio calls the IO
        // proc once and stalls. The default output serves; it contributes a clock, no input.
        let mainUID = try defaultOutputUID()
        let properties: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Palaver System Audio",
            kAudioAggregateDeviceUIDKey: "palaver.system-tap.\(UUID().uuidString.lowercased())",
            kAudioAggregateDeviceMainSubDeviceKey: mainUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: mainUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(properties as CFDictionary, &device)
        guard status == kAudioHardwareNoError else {
            throw ProcessTapError.forStatus("aggregate device creation failed", status)
        }
        guard device != kAudioObjectUnknown else { throw ProcessTapError("aggregate device creation returned no device id") }
        return device
    }

    public func createIOProc(_ device: AudioObjectID, handler: @escaping TapIOHandler) throws -> IOProcToken {
        // The block form, dispatched on Core Audio's own IO thread (queue nil). In Swift the
        // block returns nothing: pyobjc's "must return inOutputTime" (issue #19) does not apply.
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { now, input, inputTime, _, _ in
            handler(now, input, inputTime)
        }
        guard status == kAudioHardwareNoError else { throw ProcessTapError.forStatus("IO proc registration failed", status) }
        guard let proc else { throw ProcessTapError("IO proc registration returned no IO proc id") }
        return IOProcToken(raw: UInt(bitPattern: unsafeBitCast(proc, to: UnsafeRawPointer.self)))
    }

    public func startDevice(_ device: AudioObjectID, _ proc: IOProcToken) throws {
        let status = AudioDeviceStart(device, Self.proc(proc))
        guard status == kAudioHardwareNoError else { throw ProcessTapError.forStatus("audio device start failed", status) }
    }

    public func stopDevice(_ device: AudioObjectID, _ proc: IOProcToken) {
        logStop("AudioDeviceStop", AudioDeviceStop(device, Self.proc(proc)))
    }

    public func destroyIOProc(_ device: AudioObjectID, _ proc: IOProcToken) {
        logStop("AudioDeviceDestroyIOProcID", AudioDeviceDestroyIOProcID(device, Self.proc(proc)))
    }

    public func destroyAggregateDevice(_ device: AudioObjectID) {
        logStop("AudioHardwareDestroyAggregateDevice", AudioHardwareDestroyAggregateDevice(device))
    }

    public func destroyProcessTap(_ tap: AudioObjectID) {
        logStop("AudioHardwareDestroyProcessTap", AudioHardwareDestroyProcessTap(tap))
    }

    public func defaultOutputUID() throws -> String {
        try string(defaultOutputDevice(), kAudioDevicePropertyDeviceUID, "default output device UID lookup failed")
    }

    public func defaultOutputName() throws -> String? {
        try string(defaultOutputDevice(), kAudioObjectPropertyName, "device name lookup failed")
    }

    public func hostTimeToNanos(_ hostTime: UInt64) -> Int64 { Int64(bitPattern: AudioConvertHostTimeToNanos(hostTime)) }

    private func logStop(_ action: String, _ status: OSStatus) {
        if status != kAudioHardwareNoError { log("\(action) returned OSStatus \(formatOSStatus(status))") }
    }

    private func defaultOutputDevice() throws -> AudioObjectID {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &device)
        guard status == kAudioHardwareNoError, device != kAudioObjectUnknown else {
            throw ProcessTapError.forStatus("default device lookup failed", status)
        }
        return device
    }

    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ message: String) throws -> String {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == kAudioHardwareNoError, let value else { throw ProcessTapError.forStatus(message, status) }
        return value.takeRetainedValue() as String
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func proc(_ token: IOProcToken) -> AudioDeviceIOProcID {
        unsafeBitCast(UnsafeRawPointer(bitPattern: token.raw)!, to: AudioDeviceIOProcID.self)
    }
}
