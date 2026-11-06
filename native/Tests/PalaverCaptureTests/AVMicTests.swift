import Foundation
import Testing
@testable import PalaverCapture

/// test_av_mic.py, against a fake AVFoundation: no capture session, no microphone.
@Suite struct AVMicTests {
    @Test func startOpensSessionOnDefaultInputAndForwardsBuffers() throws {
        let backend = FakeMicBackend()
        let ring = CaptureRing(capacity: 1 << 16)
        let mic = AVMic(sink: ring, backend: backend, routePollInterval: nil)
        try mic.start()
        let session = try #require(backend.sessions.first)
        #expect(session.uid == "BuiltInMicrophoneDevice" && session.running)
        push(session.sink, pts: 12_500_000_000, [0.1, 0.2], rate: 48_000)
        let chunks = drain(ring)
        #expect(chunks.count == 1 && chunks[0].pts == 12_500_000_000 && chunks[0].samples == [0.1, 0.2]
            && chunks[0].rate == 48_000)
        mic.stop()
        #expect(!session.running)
    }

    @Test func startFailureThrows() {
        let backend = FakeMicBackend()
        backend.state.with { $0.fail = true }
        let mic = AVMic(sink: CaptureRing(capacity: 1 << 16), backend: backend, routePollInterval: nil)
        #expect(throws: AVMicError("microphone access denied", isPermission: true)) { try mic.start() }
    }

    @Test func authorizationStatusMapsToThePermissionError() {
        // AVAuthorizationStatus: 0 not determined, 1 restricted, 2 denied, 3 authorized.
        #expect(throws: AVMicError("microphone access denied", isPermission: true)) { try AVMicError.checkAuthorization(1) }
        #expect(throws: AVMicError("microphone access denied", isPermission: true)) { try AVMicError.checkAuthorization(2) }
        #expect(throws: Never.self) { try AVMicError.checkAuthorization(3) }
        #expect(throws: Never.self) { try AVMicError.checkAuthorization(0) }
    }

    @Test func followsDefaultInputChange() throws {
        // AirPods connect mid-meeting: record from them instead of going quiet.
        let backend = FakeMicBackend()
        let mic = AVMic(sink: CaptureRing(capacity: 1 << 16), backend: backend, routePollInterval: 0.01)
        try mic.start()
        backend.state.with { $0.uid = "AirPods-UID" }
        #expect(waitFor { backend.sessions.count == 2 })
        let sessions = backend.sessions
        #expect(!sessions[0].running && sessions[1].running && sessions[1].uid == "AirPods-UID")
        mic.stop()
        #expect(!sessions[1].running)
    }

    @Test func rebuildFailureKeepsRetrying() throws {
        let backend = FakeMicBackend()
        let mic = AVMic(sink: CaptureRing(capacity: 1 << 16), backend: backend, routePollInterval: 0.01)
        try mic.start()
        backend.state.with {
            $0.fail = true
            $0.uid = "AirPods-UID"
        }
        #expect(waitFor { mic.problem == "access" })
        backend.state.with { $0.fail = false }
        #expect(waitFor { backend.sessions.count == 2 && backend.sessions[1].running })
        #expect(waitFor { mic.problem == nil })
        mic.stop()
    }

    @Test func problemSaysAccessOrDevice() throws {
        // issue #50: what keeps the microphone from being followed.
        final class Backend: MicBackend {
            var error: Error?
            func defaultInputUID() throws -> String {
                if let error { throw error }
                return "BuiltInMicrophoneDevice"
            }
            func openSession(uid: String, sink: CaptureRing) throws -> MicSession { FakeMicSession(uid: uid, sink: sink) }
            func deviceName(uid: String) -> String? { nil }
        }
        let backend = Backend()
        let mic = AVMic(sink: CaptureRing(capacity: 1 << 16), backend: backend, routePollInterval: nil)
        try mic.start()
        backend.error = AVMicError("no microphone available")
        mic.checkRoute()
        #expect(mic.problem == "device")
        backend.error = AVMicError("microphone access denied", isPermission: true)
        mic.checkRoute()
        #expect(mic.problem == "access")
        backend.error = CocoaError(.featureUnsupported)  // anything else is transient: nothing changes
        mic.checkRoute()
        #expect(mic.problem == "access")
        backend.error = nil
        mic.checkRoute()
        #expect(mic.problem == nil)
        mic.stop()
    }

    @Test func namesTheMicrophoneItRecordsFrom() throws {
        // The menu says which mic records (issue #47), also after a switch.
        let backend = FakeMicBackend(names: ["BuiltInMicrophoneDevice": "MacBook Pro Microphone", "AirPods-UID": "AirPods"])
        let mic = AVMic(sink: CaptureRing(capacity: 1 << 16), backend: backend, routePollInterval: 0.01)
        try mic.start()
        #expect(mic.deviceName == "MacBook Pro Microphone")
        backend.state.with { $0.uid = "AirPods-UID" }
        #expect(waitFor { mic.deviceName == "AirPods" })
        mic.stop()
        #expect(AVMic(sink: CaptureRing(capacity: 1 << 16), backend: FakeMicBackend(), routePollInterval: nil).deviceName == nil)
    }
}
