// #20: the first start opens the window (the setup assistant) instead of hiding in the menu bar;
// once setup is finished or skipped, or meetings exist (an existing user), a start stays quiet:
// at login and after an update as well.
import Foundation
import Testing
import PalaverCore
@testable import PalaverDaemon

@Suite struct StartWindowTests {
    private func settings(_ json: String?) throws -> Settings {
        let dir = tempDir()
        let url = dir.appendingPathComponent("settings.json")
        if let json { try json.write(to: url, atomically: true, encoding: .utf8) }
        return Settings(url: url)
    }

    @Test func setupIsFinishedOnceDoneOrSkipped() throws {
        #expect(try !settings(nil).setupFinished)
        #expect(try !settings(#"{"realtime": true}"#).setupFinished)
        #expect(try !settings(#"{"setup": {"hardware": "M1|16"}}"#).setupFinished)
        #expect(try !settings(#"{"setup": "done"}"#).setupFinished)
        #expect(try settings(#"{"setup": {"done": "2026-11-07T10:00:00+01:00", "hardware": "M1|16"}}"#).setupFinished)
        #expect(try settings(#"{"setup": {"skipped": "2026-11-07T10:00:00+01:00"}}"#).setupFinished)
    }

    @Test func meetingsAreRecordingFolders() throws {
        let out = tempDir().appendingPathComponent("Recordings", isDirectory: true)
        #expect(!StartWindow.hasMeetings(out))  // no folder yet
        try FileManager.default.createDirectory(at: out.appendingPathComponent("notes"), withIntermediateDirectories: true)
        #expect(!StartWindow.hasMeetings(out))
        try FileManager.default.createDirectory(at: out.appendingPathComponent("2026-11-07T10-00-00"), withIntermediateDirectories: true)
        #expect(StartWindow.hasMeetings(out))
    }

    private func marker() -> URL { tempDir().appendingPathComponent("support/window-offered") }

    @Test func theWindowOpensOnlyUntilSetupIsFinished() throws {
        let out = tempDir().appendingPathComponent("Recordings", isDirectory: true)
        #expect(StartWindow.opensAtStart(settings: try settings(nil), outputDir: out, marker: marker()))  // the very first start
        #expect(StartWindow.opensAtStart(settings: try settings(#"{"setup": {"hardware": "M1|16"}}"#), outputDir: out, marker: marker()))
        #expect(!StartWindow.opensAtStart(settings: try settings(#"{"setup": {"done": "x"}}"#), outputDir: out, marker: marker()))
        #expect(!StartWindow.opensAtStart(settings: try settings(#"{"setup": {"skipped": "x"}}"#), outputDir: out, marker: marker()))
        try FileManager.default.createDirectory(at: out.appendingPathComponent("2026-11-07T10-00-00"), withIntermediateDirectories: true)
        // Meetings but no setup: a user from before the assistant, whom the window doesn't ask either.
        #expect(!StartWindow.opensAtStart(settings: try settings(nil), outputDir: out, marker: marker()))
    }

    /// Opened by itself once: a user who closed the window mid-setup (no Finish, no Skip, no meeting
    /// yet) is not shown it again at every start, the login start included.
    @Test func theWindowOpensByItselfOnlyOnce() throws {
        let out = tempDir().appendingPathComponent("Recordings", isDirectory: true)
        let s = try settings(nil), m = marker()
        #expect(StartWindow.claimAtStart(settings: s, outputDir: out, marker: m))  // first start: opens
        #expect(FileManager.default.fileExists(atPath: m.path))
        #expect(!StartWindow.claimAtStart(settings: s, outputDir: out, marker: m))  // the next start: quiet
        #expect(!StartWindow.opensAtStart(settings: s, outputDir: out, marker: m))
    }

    @Test func aQuietStartLeavesNoMarker() throws {
        let m = marker()
        #expect(!StartWindow.claimAtStart(settings: try settings(#"{"setup": {"done": "x"}}"#),
                                          outputDir: tempDir(), marker: m))
        #expect(!FileManager.default.fileExists(atPath: m.path))
    }
}
