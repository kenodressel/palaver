// What state a recording folder is in (palaver/cli.py `_status`).
import Foundation
import PalaverCore

public enum MeetingStatus {
    /// A `.part` file that grew within this many seconds belongs to a running recording.
    public static let livePartSeconds = 60.0

    /// "synced", "processed", "recorded", "recording", "crashed (run `process` to recover)" or "incomplete".
    public static func status(_ p: RecordingPaths, now: Date = Date()) -> String {
        let fm = FileManager.default
        func has(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        if has(p.notionInfo) { return "synced" }
        if has(p.transcriptJson) { return "processed" }
        if (has(p.micWav) || has(p.micRawWav)) && has(p.systemWav) { return "recorded" }
        let parts = [p.micRawWav, p.systemWav].map { URL(fileURLWithPath: $0.path + ".part") }
        let mtimes = parts.compactMap { part -> Date? in
            has(part) ? (try? fm.attributesOfItem(atPath: part.path))?[.modificationDate] as? Date : nil
        }
        if let newest = mtimes.max() {
            // The writer appends every few hundred ms; a .part file that is still growing belongs to a
            // running recording, not a crashed one.
            return now.timeIntervalSince(newest) < livePartSeconds ? "recording" : "crashed (run `process` to recover)"
        }
        return "incomplete"
    }
}
