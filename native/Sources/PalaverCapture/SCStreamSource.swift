// ScreenCaptureKit, the fallback for whichever source failed (capture_recorder.py:823-943).
// Needs Screen Recording permission, which macOS revokes from time to time:
// that is why the process tap and AVCaptureSession come first.
import CoreMedia
import Foundation
import ScreenCaptureKit
import Synchronization

public struct ScreenCaptureError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// One audio buffer from a stream output: which track, PTS (host ns), format, bytes.
public typealias ScreenCaptureOutput = (CaptureTrack, Int64, PCMFormat, UnsafeRawBufferPointer) -> Void

/// The ScreenCaptureKit calls the fallback makes; tests use a fake (late starts, timeouts, errors).
public protocol ScreenCaptureAPI: AnyObject {
    /// SCShareableContent: the first display, or the error's text. May call back late or never.
    func loadFirstDisplay(_ done: @escaping @Sendable (Result<AnyObject, ScreenCaptureError>) -> Void)
    /// An SCStream on `display` with the audio and/or microphone outputs attached, delivering to `output`.
    func makeStream(display: AnyObject, captureMic: Bool, captureSystem: Bool,
                    output: @escaping ScreenCaptureOutput) throws -> AnyObject
    /// startCapture; `done(nil)` on success, the error's text otherwise. May call back late or never.
    func startCapture(_ stream: AnyObject, _ done: @escaping @Sendable (String?) -> Void)
    func stopCapture(_ stream: AnyObject, _ done: @escaping @Sendable (String?) -> Void)
}

/// What the recorder needs of the fallback: one start attempt, and stop.
public protocol ScreenCaptureFallback: AnyObject {
    func start(captureMic: Bool, captureSystem: Bool) throws
    func stop()
}

/// The ScreenCaptureKit fallback (`_start_scstream`): one stream that captures the microphone,
/// system audio or both into the recorder's rings.
///
/// - getShareableContent waits at most 5 s, startCapture at most 10 s.
/// - Each attempt has a generation; buffers from an older one (a start that timed out and came
///   alive later) are dropped, and a timed-out stream is asked to stop.
public final class SCStreamSource: ScreenCaptureFallback, @unchecked Sendable {
    public static let contentTimeout = 5.0
    public static let startTimeout = 10.0
    public static let stopTimeout = 5.0

    private let mic: CaptureRing
    private let system: CaptureRing
    private let api: ScreenCaptureAPI
    private let contentTimeout: Double
    private let startTimeout: Double
    private let generation = Atomic<Int>(0)
    private let lock = NSLock()
    private var stream: AnyObject?

    public init(mic: CaptureRing, system: CaptureRing, api: ScreenCaptureAPI = LiveScreenCapture(),
                contentTimeout: Double = SCStreamSource.contentTimeout,
                startTimeout: Double = SCStreamSource.startTimeout) {
        self.mic = mic
        self.system = system
        self.api = api
        self.contentTimeout = contentTimeout
        self.startTimeout = startTimeout
    }

    /// The current generation (tests).
    var currentGeneration: Int { generation.load(ordering: .relaxed) }

    public func start(captureMic: Bool, captureSystem: Bool) throws {
        // 1. Shareable content: the first display.
        let content = Waiter<Result<AnyObject, ScreenCaptureError>>()
        api.loadFirstDisplay { content.put($0) }
        guard let loaded = content.wait(contentTimeout) else {
            throw ScreenCaptureError("Timed out fetching SCShareableContent (Screen Recording permission?)")
        }
        let display = try loaded.get()

        // 2. The stream, its outputs bound to this attempt's generation.
        let mine = generation.add(1, ordering: .relaxed).newValue
        let output: ScreenCaptureOutput = { [weak self, mic, system] track, pts, format, bytes in
            guard let self, self.generation.load(ordering: .relaxed) == mine else { return }
            (track == .mic ? mic : system).push(pts: pts, format: format, bytes: bytes)
        }
        let newStream = try api.makeStream(display: display, captureMic: captureMic, captureSystem: captureSystem,
                                           output: output)

        // 3. Start.
        let started = Waiter<String?>()
        api.startCapture(newStream) { started.put($0) }
        guard let result = started.wait(startTimeout) else {
            // It may still finish starting after a retry: retire its generation and ask it to stop
            // so it can neither feed nor hold the microphone.
            generation.add(1, ordering: .relaxed)
            api.stopCapture(newStream) { _ in }
            throw ScreenCaptureError("Timed out starting SCStream capture")
        }
        if let error = result { throw ScreenCaptureError("SCStream startCapture failed: \(error)") }
        lock.withLock { stream = newStream }
    }

    public func stop() {
        guard let old = lock.withLock({ () -> AnyObject? in defer { stream = nil }; return stream }) else { return }
        generation.add(1, ordering: .relaxed)
        let stopped = Waiter<String?>()
        api.stopCapture(old) { stopped.put($0) }
        _ = stopped.wait(Self.stopTimeout)
    }
}

/// A one-shot hand-over from a completion handler with a timeout (`threading.Event` + a result list).
final class Waiter<T>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: T?
    private var filled = false

    func put(_ v: T) {
        let first = lock.withLock { () -> Bool in
            guard !filled else { return false }
            filled = true
            value = v
            return true
        }
        if first { semaphore.signal() }
    }

    /// The value, or nil after `seconds`.
    func wait(_ seconds: Double) -> T? {
        guard semaphore.wait(timeout: .now() + seconds) == .success else { return nil }
        return lock.withLock { value }
    }
}

// MARK: - The real ScreenCaptureKit calls

/// ScreenCaptureKit behind `ScreenCaptureAPI`. Creating one touches nothing.
public final class LiveScreenCapture: ScreenCaptureAPI {
    public init() {}

    public func loadFirstDisplay(_ done: @escaping @Sendable (Result<AnyObject, ScreenCaptureError>) -> Void) {
        SCShareableContent.getWithCompletionHandler { content, error in
            if let error { return done(.failure(ScreenCaptureError("SCShareableContent failed: \(error)"))) }
            guard let content else { return done(.failure(ScreenCaptureError("SCShareableContent failed: None"))) }
            guard let display = content.displays.first else {
                return done(.failure(ScreenCaptureError("No displays available for SCShareableContent")))
            }
            done(.success(display))
        }
    }

    public func makeStream(display: AnyObject, captureMic: Bool, captureSystem: Bool,
                           output: @escaping ScreenCaptureOutput) throws -> AnyObject {
        guard let display = display as? SCDisplay else { throw ScreenCaptureError("not a display") }
        // Everything on the display.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = captureSystem
        config.sampleRate = captureSampleRate
        config.channelCount = 1
        config.captureMicrophone = captureMic  // the microphone on the same stream (shared host clock)
        // SCStream still needs some video; ask for the minimum.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // one frame a second at most
        config.excludesCurrentProcessAudio = true
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let sink = StreamSampleSink(output: output)
        if captureSystem {
            do { try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: nil) } catch {
                throw ScreenCaptureError("addStreamOutput(audio) failed: \(error)")
            }
        }
        if captureMic {
            do { try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: nil) } catch {
                throw ScreenCaptureError("addStreamOutput(mic) failed: \(error)")
            }
        }
        return LiveStream(stream: stream, sink: sink)
    }

    public func startCapture(_ stream: AnyObject, _ done: @escaping @Sendable (String?) -> Void) {
        guard let live = stream as? LiveStream else { return done("not a stream") }
        live.stream.startCapture { error in done(error.map { "\($0)" }) }
    }

    public func stopCapture(_ stream: AnyObject, _ done: @escaping @Sendable (String?) -> Void) {
        guard let live = stream as? LiveStream else { return done("not a stream") }
        live.stream.stopCapture { error in done(error.map { "\($0)" }) }
    }
}

/// The stream and its output, kept together (the stream does not keep its outputs alive for us).
final class LiveStream {
    let stream: SCStream
    let sink: StreamSampleSink
    init(stream: SCStream, sink: StreamSampleSink) {
        self.stream = stream
        self.sink = sink
    }
}

/// The SCStreamOutput: audio → system track, microphone → mic track; bytes only, decoded later.
final class StreamSampleSink: NSObject, SCStreamOutput, @unchecked Sendable {
    private let output: ScreenCaptureOutput
    private let systemForwarder = SampleBufferForwarder()
    private let micForwarder = SampleBufferForwarder()

    init(output: @escaping ScreenCaptureOutput) { self.output = output }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio: forward(sampleBuffer, .system, systemForwarder)
        case .microphone: forward(sampleBuffer, .mic, micForwarder)
        default: return
        }
    }

    private func forward(_ sampleBuffer: CMSampleBuffer, _ track: CaptureTrack, _ forwarder: SampleBufferForwarder) {
        forwarder.read(sampleBuffer) { pts, format, bytes in output(track, pts, format, bytes) }
    }
}
