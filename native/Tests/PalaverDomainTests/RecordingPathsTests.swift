// tests/test_paths.py: the recording-folder layout and the folder names.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

/// 2026-04-17 14:30:00 as a naive local time, in the zone the test names.
private func moment(_ zone: TimeZone) -> Date {
    var c = DateComponents()
    c.year = 2026; c.month = 4; c.day = 17; c.hour = 14; c.minute = 30; c.second = 0
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    return cal.date(from: c)!
}

@Suite struct RecordingPathsTests {
    @Test func test_new_recording_folder_uses_timestamp_and_appends_suffix_on_collision() throws {
        let tmp = TempFolder("paths"); defer { tmp.remove() }
        let folder = try RecordingPaths.newRecordingFolder(root: tmp.url, now: moment(.current))
        #expect(folder.deletingLastPathComponent().path == tmp.url.path)
        #expect(folder.lastPathComponent == "2026-04-17T14-30-00")
        #expect(FileManager.default.fileExists(atPath: folder.path))
        let second = try RecordingPaths.newRecordingFolder(root: tmp.url, now: moment(.current))
        #expect(folder != second)
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func aFolderNameIsReadInTheGivenZone() throws {
        let tmp = TempFolder("paths"); defer { tmp.remove() }
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let folder = try RecordingPaths.newRecordingFolder(root: tmp.url, now: moment(tokyo), timeZone: tokyo)
        #expect(folder.lastPathComponent == "2026-04-17T14-30-00")
    }

    @Test func everyFileHasItsPythonName() {
        let r = RecordingPaths(URL(fileURLWithPath: "/m/2026-10-20T14-35-17", isDirectory: true))
        let names: [(URL, String)] = [
            (r.micWav, "mic.wav"), (r.micRawWav, "mic_raw.wav"), (r.systemWav, "system.wav"), (r.meta, "meta.json"),
            (r.micSegments, "mic_segments.json"), (r.systemSegments, "system_segments.json"), (r.language, "language.txt"),
            (r.speakerEmbeddings, "speaker_embeddings.json"), (r.speakersAuto, "speakers_auto.json"),
            (r.speakers, "speakers.json"), (r.live, "live.json"), (r.stream, "stream.json"), (r.streamPid, "stream.pid"),
            (r.speakersIgnored, "speakers_ignored.json"), (r.speakersInferred, "speakers_inferred.json"),
            (r.speakersRejected, "speakers_rejected.json"), (r.speakersUnknown, "speakers_unknown.json"),
            (r.speakersLive, "speakers_live.json"), (r.title, "title.json"), (r.imported, "imported.json"),
            (r.importedVoices, "imported_voices.json"), (r.cutDismissed, "cut_dismissed.json"),
            (r.silenceDismissed, "silence_dismissed.json"),
            (r.localOnly, "local_only.json"), (r.transcription, "transcription.json"),
            (r.cloudPending, "cloud-pending.json"), (r.parts, "parts.json"), (r.review, "review.json"),
            (r.speakersMerged, "speakers_merged.json"), (r.speakersLines, "speakers_lines.json"), (r.speakersShared, "speakers_shared.json"),
            (r.systemTurns, "system_turns.json"), (r.transcriptJson, "transcript.json"), (r.transcriptMd, "transcript.md"),
            (r.notes, "notes.json"), (r.myNotes, "my-notes.json"), (r.myNotesImages, "my-notes"),
            (r.calendar, "calendar.json"), (r.notionInfo, "notion.json"), (r.audioProblems, "audio_problems.json"),
            (r.sessionLog, "session.log"),
        ]
        #expect(names.count == 41)
        for (url, name) in names { #expect(url.path == "/m/2026-10-20T14-35-17/" + name) }
        #expect(r.live != r.stream && Set(names.map { $0.0 }).count == names.count)
        let folder = URL(fileURLWithPath: "/m/2026-10-20T14-35-17", isDirectory: true)
        #expect(r.id == "2026-10-20T14-35-17" && r.folder == folder && r.micWav == folder.appendingPathComponent("mic.wav"))
        // A folder URL given without its trailing slash names the same files.
        #expect(RecordingPaths(URL(fileURLWithPath: "/tmp/x")).micRawWav == URL(fileURLWithPath: "/tmp/x/mic_raw.wav"))
    }

    @Test func test_is_recording_folder_name_and_its_timestamp() {
        #expect(RecordingPaths.isRecordingFolderName("2026-10-20T14-35-17"))
        #expect(RecordingPaths.isRecordingFolderName("2026-10-20T14-35-17-2"))
        #expect(!RecordingPaths.isRecordingFolderName("notes"))
        #expect(!RecordingPaths.isRecordingFolderName("2026-10-20T14-35-17.txt"))
        // Python's `$` also matches before a trailing newline, and `\d` takes any decimal digit.
        #expect(RecordingPaths.isRecordingFolderName("2026-10-20T14-35-17\n"))
        #expect(RecordingPaths.isRecordingFolderName("٢٠٢٦-10-20T14-35-17"))
        #expect(!RecordingPaths.isRecordingFolderName("2026-10-20T14-35-17-"))
        #expect(!RecordingPaths.isRecordingFolderName("x2026-10-20T14-35-17"))
        // The timestamp is the name without its suffix.
        #expect(RecordingPaths.recordingFolderTimestamp("2026-10-20T14-35-17") == "2026-10-20T14-35-17")
        #expect(RecordingPaths.recordingFolderTimestamp("2026-10-20T14-35-17-12") == "2026-10-20T14-35-17")
        #expect(RecordingPaths.recordingFolderTimestamp("notes") == nil)
    }
}
