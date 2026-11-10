// Where a recording's system track is transcribed (palaver/transcription.py `cloud_choice`, #54): on this Mac,
// unless the user chose a transcription service in Settings (settings.json `engines.transcription`) and the meeting
// is not one kept on this Mac. The service itself is PalaverCloud's (CloudTranscription), called by Pipeline.systemTrack.
import Foundation
import PalaverCore
import PalaverDomain

public enum CloudChoice {
    /// The service the system track of `folder` goes to; nil: this Mac.
    public static func provider(folder: URL, stores: StorePaths = .current()) -> String? {
        let chosen = ModelChoice.choice(feature: ModelChoice.TRANSCRIPTION, default: ModelChoice.LOCAL, stores: stores)
        if Py.same(chosen, ModelChoice.LOCAL) || LocalOnly.isLocalOnly(folder) { return nil }
        return chosen
    }

    /// Whether a service still owes the deletion of something it was sent (`cloud-pending.json` of a meeting in
    /// `root`, or the Test button's in the config dir): `transcription.sweep_pending` retries them at every `process`.
    public static func deletionsPending(root: URL, stores: StorePaths = .current()) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: stores.cloudPending.path) { return true }
        let name = RecordingPaths(root).cloudPending.lastPathComponent
        let folders = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return folders.contains { fm.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent(name).path) }
    }
}
