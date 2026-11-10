// Retention (prune.py, `palaver prune`): tests/test_prune.py under its names.
import Darwin
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

private let NOW = Date(timeIntervalSince1970: 1_792_497_600)  // 2026-10-20 12:00 UTC
private let UTC = TimeZone(secondsFromGMT: 0)!

/// `_recording`: a folder with 1000 bytes of audio, its meta.json when `start` is given, synced or not.
@discardableResult
private func recording(_ root: URL, _ name: String, synced: Bool, start: Date? = nil) throws -> URL {
    let folder = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(count: 1000).write(to: folder.appendingPathComponent("mic_raw.wav"))
    if let start {
        try PythonJSON.write(.object([("start_time", .string(WallTime.iso(start, UTC)))]), to: folder.appendingPathComponent("meta.json"),
                             indent: nil, ensureAscii: true)
    }
    if synced {
        try Data("[]".utf8).write(to: folder.appendingPathComponent("transcript.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("notion.json"))
    }
    return folder
}

private func days(_ n: Double) -> Date { NOW.addingTimeInterval(-n * 86400) }

@Suite struct PruneTests {
    @Test func test_plan_deletes_only_old_synced_recordings() throws {
        let t = TempFolder("prune"); defer { t.remove() }
        try recording(t.url, "2026-09-30T10-00-00", synced: true, start: days(20))
        try recording(t.url, "2026-09-30T11-00-00", synced: false, start: days(20))
        try recording(t.url, "2026-10-19T10-00-00", synced: true, start: days(1))
        try FileManager.default.createDirectory(at: t.url.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data("file, not folder".utf8).write(to: t.url.appendingPathComponent("2026-09-01T10-00-00.txt"))
        let plan = Prune.plan(t.url, retentionDays: 14, now: NOW, timeZone: UTC)
        #expect(plan.delete.map(\.lastPathComponent) == ["2026-09-30T10-00-00"])
        #expect(plan.keptUnsynced.map(\.lastPathComponent) == ["2026-09-30T11-00-00"])
    }

    @Test func test_include_unsynced() throws {
        let t = TempFolder("prune"); defer { t.remove() }
        try recording(t.url, "2026-09-30T11-00-00", synced: false, start: days(20))
        #expect(Prune.plan(t.url, retentionDays: 14, now: NOW, includeUnsynced: true, timeZone: UTC).delete.map(\.lastPathComponent)
                == ["2026-09-30T11-00-00"])
    }

    @Test func test_age_falls_back_to_folder_name() throws {
        let t = TempFolder("prune"); defer { t.remove() }
        try recording(t.url, "2026-09-01T10-00-00-2", synced: true)  // no meta.json, suffixed
        #expect(Prune.plan(t.url, retentionDays: 14, now: NOW, timeZone: UTC).delete.map(\.lastPathComponent) == ["2026-09-01T10-00-00-2"])
    }

    @Test func test_prune_dry_run_deletes_nothing() throws {
        let t = TempFolder("prune"); defer { t.remove() }
        let folder = try recording(t.url, "2026-09-30T10-00-00", synced: true, start: days(20))
        var said: [String] = []
        #expect(try Prune.run(t.url, retentionDays: 14, now: NOW, dryRun: true, timeZone: UTC, say: { said.append($0) }).isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(said == ["would delete 2026-09-30T10-00-00 (0 MB)", "would delete 1 recording(s), 0 MB"])
    }

    @Test func test_prune_deletes_and_reports_freed_space() throws {
        let t = TempFolder("prune"); defer { t.remove() }
        let folder = try recording(t.url, "2026-09-30T10-00-00", synced: true, start: days(20))
        var said: [String] = []
        #expect(try Prune.run(t.url, retentionDays: 14, now: NOW, timeZone: UTC, say: { said.append($0) }) == [folder])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(said.first == "deleted 2026-09-30T10-00-00 (0 MB)")
    }

    @Test func test_prune_missing_output_dir_is_noop() throws {
        let t = TempFolder("prune"); defer { t.remove() }
        var said: [String] = []
        #expect(try Prune.run(t.url.appendingPathComponent("missing"), retentionDays: 14, now: NOW, say: { said.append($0) }).isEmpty)
        #expect(said == ["nothing older than 14 days to delete"])
    }

    @Test func test_naive_meta_timestamp_is_treated_as_local() throws {
        let t = TempFolder("prune"); defer { t.remove() }
        let folder = try recording(t.url, "2026-09-30T10-00-00", synced: true)
        try Data(#"{"start_time": "2026-09-30T10:00:00"}"#.utf8).write(to: folder.appendingPathComponent("meta.json"))
        #expect(Prune.plan(t.url, retentionDays: 14, now: NOW, timeZone: TimeZone(identifier: "Europe/Berlin")!).delete
                    .map(\.lastPathComponent) == ["2026-09-30T10-00-00"])
    }

    @Test func aLinkToAnOldRecordingIsNeverFollowed() throws {
        let t = TempFolder("prune"); defer { t.remove() }
        let elsewhere = TempFolder("prune-elsewhere"); defer { elsewhere.remove() }
        let real = try recording(elsewhere.url, "2026-09-30T10-00-00", synced: true, start: days(20))
        try FileManager.default.createSymbolicLink(at: t.url.appendingPathComponent("2026-09-30T10-00-00"), withDestinationURL: real)
        #expect(Prune.plan(t.url, retentionDays: 14, now: NOW, timeZone: UTC).delete.isEmpty)
    }
}
