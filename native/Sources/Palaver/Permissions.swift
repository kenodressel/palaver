// The real permission requests (menubar.py request_permissions): AVCaptureDevice for the microphone, a
// dummy process tap for System Audio Recording. Called once at launch by the app (Task 14) and never from
// tests: they use fakes behind PermissionRequester. Screen Recording is never requested.
import AVFoundation
import Foundation
import PalaverCapture
import PalaverDaemon

struct SystemPermissionRequester: PermissionRequester {
    func micStatus() -> MicStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    /// Starts and stops a tap that captures nothing: macOS asks for System Audio Recording at the start.
    func probeSystemAudio() throws {
        let tap = ProcessTap(sink: CaptureRing(capacity: 1 << 16), routePollInterval: nil)
        try tap.start()
        tap.stop()
    }
}
