import Foundation
import Testing
@testable import PalaverCapture

/// ScreenCaptureKit as the fallback sees it: content and start answer at once, late, never, or with an error.
private final class FakeScreenCaptureAPI: ScreenCaptureAPI, @unchecked Sendable {
    enum Answer { case now(String?), after(Double, String?), never }
    struct Stream { let id: Int; let mic: Bool; let system: Bool; let output: ScreenCaptureOutput }
    let state = Locked((content: Answer.now(nil), start: [Answer](), streams: [Stream](), stopped: [Int](),
                        makeError: String?.none))

    func loadFirstDisplay(_ done: @escaping @Sendable (Result<AnyObject, ScreenCaptureError>) -> Void) {
        answer(state.get.content) { error in
            done(error.map { .failure(ScreenCaptureError($0)) } ?? .success(NSObject()))
        }
    }

    func makeStream(display: AnyObject, captureMic: Bool, captureSystem: Bool,
                    output: @escaping ScreenCaptureOutput) throws -> AnyObject {
        if let error = state.get.makeError { throw ScreenCaptureError(error) }
        let id = state.with { s -> Int in
            s.streams.append(Stream(id: s.streams.count, mic: captureMic, system: captureSystem, output: output))
            return s.streams.count - 1
        }
        return NSNumber(value: id)
    }

    func startCapture(_ stream: AnyObject, _ done: @escaping @Sendable (String?) -> Void) {
        let answer = state.with { s -> Answer in s.start.isEmpty ? .now(nil) : s.start.removeFirst() }
        self.answer(answer, done)
    }

    func stopCapture(_ stream: AnyObject, _ done: @escaping @Sendable (String?) -> Void) {
        state.with { $0.stopped.append((stream as! NSNumber).intValue) }
        done(nil)
    }

    /// A buffer from stream `id`'s output.
    func deliver(_ id: Int, _ track: CaptureTrack, pts: Int64, _ samples: [Float]) {
        let output = state.get.streams[id].output
        samples.withUnsafeBytes {
            output(track, pts, PCMFormat(sampleRate: 16_000, formatFlags: PCMFormat.flagIsFloat, channels: 1, bitsPerChannel: 32), $0)
        }
    }

    private func answer(_ answer: Answer, _ done: @escaping @Sendable (String?) -> Void) {
        switch answer {
        case let .now(error): done(error)
        case let .after(seconds, error): DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done(error) }
        case .never: break
        }
    }
}

@Suite struct SCStreamSourceTests {
    private func source(_ api: FakeScreenCaptureAPI) -> (SCStreamSource, CaptureRing, CaptureRing) {
        let mic = CaptureRing(capacity: 1 << 16), system = CaptureRing(capacity: 1 << 16)
        return (SCStreamSource(mic: mic, system: system, api: api, contentTimeout: 0.05, startTimeout: 0.05), mic, system)
    }

    @Test func buffersGoToTheirTrack() throws {
        let api = FakeScreenCaptureAPI()
        let (source, mic, system) = source(api)
        try source.start(captureMic: true, captureSystem: false)
        #expect(api.state.get.streams.map { [$0.mic, $0.system] } == [[true, false]])
        api.deliver(0, .mic, pts: 1, [0.5])
        api.deliver(0, .system, pts: 2, [0.25])
        #expect(drain(mic).map(\.samples) == [[0.5]])
        #expect(drain(system).map(\.samples) == [[0.25]])
        source.stop()
        #expect(api.state.get.stopped == [0])
        api.deliver(0, .mic, pts: 3, [0.5])  // after stop: dropped
        #expect(mic.isEmpty)
    }

    @Test func contentTimeoutAndErrorTexts() {
        let api = FakeScreenCaptureAPI()
        let (source, _, _) = source(api)
        api.state.with { $0.content = .never }
        #expect(throws: ScreenCaptureError("Timed out fetching SCShareableContent (Screen Recording permission?)")) {
            try source.start(captureMic: true, captureSystem: true)
        }
        api.state.with { $0.content = .now("No displays available for SCShareableContent") }
        #expect(throws: ScreenCaptureError("No displays available for SCShareableContent")) {
            try source.start(captureMic: true, captureSystem: true)
        }
        api.state.with {
            $0.content = .now(nil)
            $0.makeError = "addStreamOutput(mic) failed: nope"
        }
        #expect(throws: ScreenCaptureError("addStreamOutput(mic) failed: nope")) {
            try source.start(captureMic: true, captureSystem: false)
        }
    }

    @Test func startErrorText() {
        let api = FakeScreenCaptureAPI()
        let (source, _, _) = source(api)
        api.state.with { $0.start = [.now("Stream failed to start microphone")] }
        #expect(throws: ScreenCaptureError("SCStream startCapture failed: Stream failed to start microphone")) {
            try source.start(captureMic: true, captureSystem: false)
        }
    }

    @Test func aLateStartIsStoppedAndItsBuffersDropped() throws {
        // A start that timed out may come alive while the retry runs: it must neither feed nor hold the mic.
        let api = FakeScreenCaptureAPI()
        let (source, mic, _) = source(api)
        api.state.with { $0.start = [.after(0.2, nil), .now(nil)] }
        #expect(throws: ScreenCaptureError("Timed out starting SCStream capture")) {
            try source.start(captureMic: true, captureSystem: false)
        }
        #expect(api.state.get.stopped == [0])
        try source.start(captureMic: true, captureSystem: false)  // the retry
        Thread.sleep(forTimeInterval: 0.3)  // the late start completes now
        api.deliver(0, .mic, pts: 1, [0.9])  // the late stream: dropped
        api.deliver(1, .mic, pts: 2, [0.1])
        #expect(drain(mic).map(\.pts) == [2])
        source.stop()
    }
}
