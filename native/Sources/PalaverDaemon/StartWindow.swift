// Whether the app opens its window by itself when it starts (#20). A menu bar app that starts
// silently looks as if nothing happened to someone who has never used one: the first start (and
// every start until the setup assistant was finished or skipped) opens the window, where the page
// shows the assistant. Later starts, at login and after an update, stay quiet in the menu bar.
// The same rule as the page's (onboarding.offer "first"): a user with meetings from before the
// assistant is not asked.
import Foundation
import PalaverCore

//
// It opens by itself only once (`marker`, written when it does): someone who closed it mid-setup
// is not shown it at every start (the login start too). Opening Palaver again from the Finder,
// Launchpad, Spotlight or the Dock always brings it (applicationShouldHandleReopen).
public enum StartWindow {
    public static func opensAtStart(settings: Settings, outputDir: URL, marker: URL) -> Bool {
        !FileManager.default.fileExists(atPath: marker.path) && !settings.setupFinished && !hasMeetings(outputDir)
    }

    /// opensAtStart, and when it does, the marker is written so the next start stays quiet.
    public static func claimAtStart(settings: Settings, outputDir: URL, marker: URL) -> Bool {
        guard opensAtStart(settings: settings, outputDir: outputDir, marker: marker) else { return false }
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        return true
    }

    /// A recording folder in `dir` (api._has_meetings).
    public static func hasMeetings(_ dir: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { RecordingFolders.isRecordingName($0) }
    }
}
