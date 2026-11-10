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
    @Test func test_new_recording_folder_uses_timestamp() throws {
        let tmp = TempFolder("paths"); defer { tmp.remove() }
        let folder = try RecordingPaths.newRecordingFolder(root: tmp.url, now: moment(.current))
        #expect(folder.deletingLastPathComponent().path == tmp.url.path)
        #expect(folder.lastPathComponent == "2026-04-17T14-30-00")
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func test_new_recording_folder_appends_suffix_on_collision() throws {
        let tmp = TempFolder("paths"); defer { tmp.remove() }
        let first = try RecordingPaths.newRecordingFolder(root: tmp.url, now: moment(.current))
        let second = try RecordingPaths.newRecordingFolder(root: tmp.url, now: moment(.current))
        #expect(first != second)
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func folderNamesMatchPython() throws {
        // The golden: the names Python's new_recording_folder gives for a free name and 1, 2, 3 collisions.
        let cases = try #require(Goldens.load("folder_names")["cases"]?.arrayValue)
        var got: [JSONValue] = []
        for c in cases {
            let tmp = TempFolder("names"); defer { tmp.remove() }
            let root = tmp.url.appendingPathComponent("Recordings")  // not there yet: the call makes it
            let taken = try Goldens.int(c["taken"])
            let names = try (0...taken).map { _ in
                try RecordingPaths.newRecordingFolder(root: root, now: moment(.current)).lastPathComponent
            }
            got.append(.object([("taken", .int(taken)), ("names", .strings(names))]))
        }
        Goldens.expect(.array(got), "folder_names", "cases")
    }

    @Test func aFolderNameIsReadInTheGivenZone() throws {
        let tmp = TempFolder("paths"); defer { tmp.remove() }
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let folder = try RecordingPaths.newRecordingFolder(root: tmp.url, now: moment(tokyo), timeZone: tokyo)
        #expect(folder.lastPathComponent == "2026-04-17T14-30-00")
    }

    @Test func test_recording_paths_surfaces_all_files() {
        let r = RecordingPaths(URL(fileURLWithPath: "/tmp/x", isDirectory: true))
        let t = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        #expect(r.micWav == t.appendingPathComponent("mic.wav"))
        #expect(r.systemWav == t.appendingPathComponent("system.wav"))
        #expect(r.meta == t.appendingPathComponent("meta.json"))
        #expect(r.micSegments == t.appendingPathComponent("mic_segments.json"))
        #expect(r.systemSegments == t.appendingPathComponent("system_segments.json"))
        #expect(r.systemTurns == t.appendingPathComponent("system_turns.json"))
        #expect(r.transcriptJson == t.appendingPathComponent("transcript.json"))
        #expect(r.transcriptMd == t.appendingPathComponent("transcript.md"))
        #expect(r.notionInfo == t.appendingPathComponent("notion.json"))
        #expect(r.sessionLog == t.appendingPathComponent("session.log"))
        #expect(r.id == "x" && r.folder == t)
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
    }

    @Test func test_mic_raw_wav_path() {
        let paths = RecordingPaths(URL(fileURLWithPath: "/tmp/x"))
        #expect(paths.micRawWav == URL(fileURLWithPath: "/tmp/x/mic_raw.wav"))
    }

    @Test func test_is_recording_folder_name() {
        #expect(RecordingPaths.isRecordingFolderName("2026-10-20T14-35-17"))
        #expect(RecordingPaths.isRecordingFolderName("2026-10-20T14-35-17-2"))
        #expect(!RecordingPaths.isRecordingFolderName("notes"))
        #expect(!RecordingPaths.isRecordingFolderName("2026-10-20T14-35-17.txt"))
        // Python's `$` also matches before a trailing newline, and `\d` takes any decimal digit.
        #expect(RecordingPaths.isRecordingFolderName("2026-10-20T14-35-17\n"))
        #expect(RecordingPaths.isRecordingFolderName("٢٠٢٦-10-20T14-35-17"))
        #expect(!RecordingPaths.isRecordingFolderName("2026-10-20T14-35-17-"))
        #expect(!RecordingPaths.isRecordingFolderName("x2026-10-20T14-35-17"))
    }

    @Test func theTimestampIsTheNameWithoutItsSuffix() {
        #expect(RecordingPaths.recordingFolderTimestamp("2026-10-20T14-35-17") == "2026-10-20T14-35-17")
        #expect(RecordingPaths.recordingFolderTimestamp("2026-10-20T14-35-17-12") == "2026-10-20T14-35-17")
        #expect(RecordingPaths.recordingFolderTimestamp("notes") == nil)
    }
}
