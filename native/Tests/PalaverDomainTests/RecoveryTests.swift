// A recording the app died making, made whole (tests/test_cli.py's tests of `_promote_part_files`,
// `_synthesize_meta_from_audio`, `_fold_audio_problems` under their names). Synthetic audio only.
import Foundation
import PalaverCore
@testable import PalaverDomain
import Testing

@Suite struct RecoveryTests {
    private func silent(_ url: URL, _ seconds: Double) throws {
        try Wav16.write([Int16](repeating: 0, count: Int(16_000 * seconds)), rate: 16_000, to: url)
    }

    private func folder(_ t: TempFolder, _ name: String = "2026-04-29T14-30-00") throws -> RecordingPaths {
        let paths = RecordingPaths(t.url.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: false)
        return paths
    }

    @Test func test_promote_part_files_renames_orphans() throws {
        let t = TempFolder("recovery"); defer { t.remove() }
        let paths = RecordingPaths(t.url)
        try silent(URL(fileURLWithPath: paths.micRawWav.path + ".part"), 0.5)
        try silent(URL(fileURLWithPath: paths.systemWav.path + ".part"), 0.5)
        try Recovery.promoteParts(paths)
        #expect(!t.exists("mic_raw.wav.part") && !t.exists("system.wav.part"))
        #expect(t.exists("mic_raw.wav") && t.exists("system.wav"))
    }

    @Test func test_promote_part_files_skips_when_final_already_present() throws {
        let t = TempFolder("recovery"); defer { t.remove() }
        let paths = RecordingPaths(t.url)
        try silent(paths.micRawWav, 1.0)
        t.write("mic_raw.wav.part", "junk")
        let before = try Data(contentsOf: paths.micRawWav)
        try Recovery.promoteParts(paths)
        #expect(try Data(contentsOf: paths.micRawWav) == before)  // the final file is the source of truth
        #expect(t.text("mic_raw.wav.part") == "junk")  // left for the user to look at
    }

    @Test func test_synthesize_meta_from_audio_recovers_from_folder_name() throws {
        let t = TempFolder("recovery"); defer { t.remove() }
        let paths = try folder(t)
        try silent(paths.micRawWav, 12.5)
        #expect(Recovery.synthesizeMeta(paths))
        let meta = try #require(PythonJSON.read(paths.meta))
        guard case .object(let fields) = meta else { Issue.record("not an object"); return }
        #expect(fields.map(\.0) == ["start_time", "end_time", "duration_seconds"])
        #expect(meta["duration_seconds"] == .double(12.5))
        #expect(meta["start_time"]?.stringValue?.hasPrefix("2026-04-29T14:30:00") == true)
        #expect(meta["end_time"]?.stringValue?.hasPrefix("2026-04-29T14:30:12.500000") == true)
        // json.dumps(meta, indent=2).
        #expect(try String(contentsOf: paths.meta, encoding: .utf8).hasPrefix("{\n  \"start_time\": \"2026-04-29T14:30:00"))
    }

    @Test func test_synthesize_meta_from_audio_returns_false_without_audio() throws {
        let t = TempFolder("recovery"); defer { t.remove() }
        let paths = try folder(t)
        #expect(!Recovery.synthesizeMeta(paths))
        #expect(!FileManager.default.fileExists(atPath: paths.meta.path))
    }

    @Test func test_synthesize_meta_from_audio_returns_false_on_unparseable_folder() throws {
        let t = TempFolder("recovery"); defer { t.remove() }
        let paths = try folder(t, "not-a-timestamp")
        try silent(paths.micRawWav, 1.0)
        #expect(!Recovery.synthesizeMeta(paths))
        #expect(!FileManager.default.fileExists(atPath: paths.meta.path))
        #expect(Recovery.startTime("2026-02-30T10-00-00", timeZone: .current) == nil)
    }

    @Test func test_a_crashed_recordings_audio_problems_reach_meta() throws {
        let t = TempFolder("recovery"); defer { t.remove() }
        let paths = try folder(t)
        try silent(paths.micRawWav, 12.5)
        try #"[{"kind": "speed", "track": "system", "start": 2.0, "end": 4.0, "at": "2026-04-29T14:30:02+02:00"}, {"kind": "stalled", "track": "mic", "start": 9.0, "end": null, "at": "2026-04-29T14:30:09+02:00"}]"#
            .write(to: paths.audioProblems, atomically: false, encoding: .utf8)
        #expect(Recovery.synthesizeMeta(paths))
        let problems = PythonJSON.read(paths.meta)?["audio_problems"]
        #expect(PythonJSON.dumps(problems!) == #"[{"kind": "speed", "track": "system", "start": 2.0, "end": 4.0, "at": "2026-04-29T14:30:02+02:00"}, {"kind": "stalled", "track": "mic", "start": 9.0, "end": 12.5, "at": "2026-04-29T14:30:09+02:00"}]"#)
        #expect(!FileManager.default.fileExists(atPath: paths.audioProblems.path))
    }

    @Test func test_audio_problems_left_beside_a_finished_meta_are_folded_in() throws {
        let t = TempFolder("recovery"); defer { t.remove() }
        let paths = try folder(t)
        try silent(paths.micRawWav, 12.5)
        try #"{"start_time": "2026-04-29T14:30:00+02:00", "duration_seconds": 12.5}"#.write(to: paths.meta, atomically: false, encoding: .utf8)
        try #"[{"kind": "stalled", "track": "mic", "start": 9.0, "end": null, "at": "2026-04-29T14:30:09+02:00"}]"#
            .write(to: paths.audioProblems, atomically: false, encoding: .utf8)
        #expect(try Continuation.recover(paths))
        let meta = try #require(PythonJSON.read(paths.meta))
        #expect(meta["audio_problems"]?.arrayValue?.first?["end"] == .double(12.5))
        #expect(meta["duration_seconds"] == .double(12.5))
        #expect(!FileManager.default.fileExists(atPath: paths.audioProblems.path))
    }

    @Test func test_folding_audio_problems_keeps_those_meta_already_has() throws {
        let t = TempFolder("recovery"); defer { t.remove() }
        let paths = try folder(t)
        let kept = #"[{"kind": "speed", "track": "system", "start": 2.0, "end": 4.0}]"#
        try #"{"duration_seconds": 12.5, "audio_problems": \#(kept)}"#.write(to: paths.meta, atomically: false, encoding: .utf8)
        try #"[{"kind": "stalled", "track": "mic", "start": 9.0, "end": null}]"#.write(to: paths.audioProblems, atomically: false, encoding: .utf8)
        Recovery.foldAudioProblems(paths)
        #expect(PythonJSON.dumps(PythonJSON.read(paths.meta)!["audio_problems"]!) == kept)
        #expect(!FileManager.default.fileExists(atPath: paths.audioProblems.path))
        // Unreadable: nothing happens, the file stays.
        try "{".write(to: paths.audioProblems, atomically: false, encoding: .utf8)
        Recovery.foldAudioProblems(paths)
        #expect(FileManager.default.fileExists(atPath: paths.audioProblems.path))
    }
}
