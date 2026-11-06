// The microphone through AVCaptureSession (palaver/_audio/av_mic.py).
//
// Raw device input (no voice processing), delivered as CMSampleBuffers whose
// presentation timestamps are on the host clock, the same clock as the
// process tap, so the two tracks align by PTS. Needs only the Microphone
// permission. The session is bound to one device; a watcher reopens it on the
// new default input when that changes (AirPods connect, headphones
// unplugged). The reopen leaves a short PTS gap, which the writer zero-pads.
import AVFoundation
import CoreMedia
import Foundation
import Synchronization

/// A microphone failure (`AVMicError` / `AVMicPermissionError`).
public struct AVMicError: Error, CustomStringConvertible, Equatable {
    public let message: String
    /// The authorization status says no: a real permission problem.
    public let isPermission: Bool

    public init(_ message: String, isPermission: Bool = false) {
        self.message = message
        self.isPermission = isPermission
    }

    public var description: String { message }

    /// AVAuthorizationStatus 1 (restricted) or 2 (denied) → the permission error (`check_authorization`).
    public static func checkAuthorization(_ status: Int) throws {
        if status == 1 || status == 2 { throw AVMicError("microphone access denied", isPermission: true) }
    }
}

public protocol MicSession: AnyObject {
    func start() throws
    func stop()
}

/// Everything the microphone source asks of AVFoundation (av_mic.py's backend); tests use a fake.
public protocol MicBackend: AnyObject {
    /// The default input's unique ID; checks the authorization first.
    func defaultInputUID() throws -> String
    /// A capture session on that device whose buffers go into `sink`.
    func openSession(uid: String, sink: CaptureRing) throws -> MicSession
    /// The device's localizedName, e.g. "AirPods" (for the menu).
    func deviceName(uid: String) -> String?
}

/// The microphone source (`AVMicCapture`).
public final class AVMic: CaptureSource, @unchecked Sendable {
    private let sink: CaptureRing
    private let backend: MicBackend
    private let routePollInterval: Double?
    private let log: (String) -> Void
    private let lock = NSLock()
    private var session: MicSession?
    private var uid: String?
    private var stopping = false
    private var poller: Poller?
    private let status = Mutex<(name: String?, problem: String?)>((nil, nil))

    public init(sink: CaptureRing, backend: MicBackend = AVFoundationMicBackend(), routePollInterval: Double? = 1.0,
                log: @escaping (String) -> Void = { _ in }) {
        self.sink = sink
        self.backend = backend
        self.routePollInterval = routePollInterval
        self.log = log
    }

    /// The input recorded from, e.g. "AirPods".
    public var deviceName: String? { status.withLock { $0.name } }

    /// What keeps the microphone from being followed (issue #50): "access" (the authorization
    /// status says no) or "device" (no microphone, or it will not open); nil once it works.
    public var problem: String? { status.withLock { $0.problem } }

    public func start() throws {
        try lock.withLock {
            stopping = false
            try open()
        }
        if let interval = routePollInterval, interval > 0 {
            poller = Poller(name: "palaver.mic-route", interval: interval) { [weak self] in self?.checkRoute() }
        }
    }

    public func stop() {
        lock.withLock { stopping = true }
        poller?.cancel()
        poller = nil
        lock.withLock { close() }
    }

    /// One look at the default input: follow it when it changed (`_check_route`).
    func checkRoute() {
        let newUID: String
        do {
            newUID = try backend.defaultInputUID()
        } catch let error as AVMicError {
            report(error)
            return
        } catch {
            return  // transient while devices switch
        }
        let current = lock.withLock { uid }
        if newUID == current {
            setProblem(nil)
            return
        }
        log("microphone changed (\(current ?? "None") → \(newUID)); following it")
        lock.withLock {
            if stopping { return }
            close()
            do {
                try open()
                setProblem(nil)
            } catch {
                log("switching microphone failed; retrying: \(error)")
                report(error)
                uid = nil  // forces another attempt next tick
            }
        }
    }

    // MARK: - private (lock held)

    private func open() throws {
        let newUID = try backend.defaultInputUID()
        let newSession = try backend.openSession(uid: newUID, sink: sink)
        try newSession.start()
        session = newSession
        uid = newUID
        let name = backend.deviceName(uid: newUID)  // for the menu; recording goes on without it
        status.withLock { $0.name = name }
    }

    private func close() {
        let old = session
        session = nil
        old?.stop()
    }

    private func report(_ error: Error) {
        let kind = (error as? AVMicError)?.isPermission == true ? "access" : "device"
        if problem != kind { log("microphone: \(error)") }
        setProblem(kind)
    }

    private func setProblem(_ kind: String?) { status.withLock { $0.problem = kind } }
}

// MARK: - The real AVFoundation backend

/// AVFoundation behind `MicBackend`. Creating one touches nothing; `defaultInputUID` only reads the
/// authorization status (no prompt); `MicSession.start` opens the microphone.
public final class AVFoundationMicBackend: MicBackend {
    public init() {}

    public func defaultInputUID() throws -> String {
        try AVMicError.checkAuthorization(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)
        guard let device = AVCaptureDevice.default(for: .audio) else { throw AVMicError("no microphone available") }
        return device.uniqueID
    }

    public func openSession(uid: String, sink: CaptureRing) throws -> MicSession {
        try AVCaptureMicSession(uid: uid, sink: sink)
    }

    public func deviceName(uid: String) -> String? { AVCaptureDevice(uniqueID: uid)?.localizedName }
}

/// AVCaptureSession + AVCaptureAudioDataOutput on the serial queue `palaver.mic` (`_AVFoundationSession`).
final class AVCaptureMicSession: MicSession {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let delegate: MicSampleSink
    private let queue = DispatchQueue(label: "palaver.mic")

    init(uid: String, sink: CaptureRing) throws {
        guard let device = AVCaptureDevice(uniqueID: uid) else { throw AVMicError("input device \(uid) not found") }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            throw AVMicError("microphone unavailable: \(error)")
        }
        guard session.canAddInput(input) else { throw AVMicError("cannot add the microphone to a capture session") }
        session.addInput(input)
        delegate = MicSampleSink(sink: sink)
        output.setSampleBufferDelegate(delegate, queue: queue)
        guard session.canAddOutput(output) else { throw AVMicError("cannot add the microphone to a capture session") }
        session.addOutput(output)
    }

    func start() throws {
        session.startRunning()
        guard session.isRunning else { throw AVMicError("microphone capture did not start (permission denied?)") }
    }

    func stop() { session.stopRunning() }
}

/// The AVCaptureAudioDataOutput delegate: forwards each buffer's bytes, decodes nothing.
final class MicSampleSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let sink: CaptureRing
    private let forwarder = SampleBufferForwarder()

    init(sink: CaptureRing) { self.sink = sink }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        forwarder.forward(sampleBuffer, to: sink)
    }
}
