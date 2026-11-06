// The permission prompts at launch (menubar.py permissions_to_request / request_permissions), so macOS asks
// now and not in the middle of the first meeting: Microphone, and System Audio Recording once per install
// (it has no status API: a marker file). Screen Recording is never requested. The requests themselves are
// behind `PermissionRequester`; the real one (AVCaptureDevice, a dummy ProcessTap) is in the app target,
// tests use fakes and never ask.
import Foundation

public enum MicStatus: Equatable, Sendable { case notDetermined, authorized, denied, restricted }

public protocol PermissionRequester: Sendable {
    func micStatus() -> MicStatus
    /// AVCaptureDevice.requestAccess(for: .audio); the answer is not needed.
    func requestMic()
    /// Starts and stops a process tap capturing nothing: that triggers the System Audio Recording prompt.
    /// May throw (denied, no output device): the marker is written all the same.
    func probeSystemAudio() throws
}

public enum Permissions {
    public static let microphone = "microphone", systemAudio = "system-audio"

    /// Which prompts to trigger now.
    public static func toRequest(mic: MicStatus, markerExists: Bool) -> [String] {
        var wanted: [String] = []
        if mic == .notDetermined { wanted.append(microphone) }
        if !markerExists { wanted.append(systemAudio) }
        return wanted
    }

    /// At launch, off the main thread. Returns what it asked for.
    @discardableResult
    public static func requestAtLaunch(_ requester: PermissionRequester, marker: URL,
                                       log: (String) -> Void = { _ in }) -> [String] {
        let wanted = toRequest(mic: requester.micStatus(), markerExists: FileManager.default.fileExists(atPath: marker.path))
        if wanted.contains(microphone) { requester.requestMic() }
        if wanted.contains(systemAudio) {
            do { try requester.probeSystemAudio() } catch { log("system audio prompt: \(error)") }
            try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "1".write(to: marker, atomically: true, encoding: .utf8)
        }
        return wanted
    }
}
