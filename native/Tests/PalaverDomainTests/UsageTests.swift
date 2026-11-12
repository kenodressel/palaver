// tests/test_usage.py (usage.py:1-136): the local usage log. `summary`, `catalog` and `MENUBAR_FEATURES` stay Python
// (only `palaver report` uses them), so their three tests are skipped in the ledger.
import Darwin
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func text(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

private func rows(_ url: URL) throws -> [JSONValue] {
    try text(url).split(separator: "\n", omittingEmptySubsequences: true).map { try PythonJSON.parse(Data($0.utf8)) }
}

@Suite struct UsageTests {
    @Test func test_record_appends_one_small_json_line_per_event() throws {
        let path = try tempDir().appendingPathComponent("support/usage.jsonl")
        Usage.record("action", "meeting.trash", path: path)
        Usage.record("recording_stop", fields: [("trigger", .string("teams")), ("seconds", .double(1800.4))], path: path)
        let all = try rows(path)
        #expect(all.map { $0["kind"] } == [.string("action"), .string("recording_stop")])
        #expect(all[0]["id"] == .string("meeting.trash"))
        #expect(all[1]["trigger"] == .string("teams") && all[1]["seconds"] == .double(1800.4))
        #expect(all.allSatisfy { $0["ts"] != nil })
    }

    @Test func test_record_never_raises() throws {
        // A file where the folder should be. (Python's second call, an `id` that is no JSON, cannot be written in Swift.)
        let blocker = try tempDir().appendingPathComponent("file")
        try Data().write(to: blocker)
        Usage.record("action", "meeting.trash", path: blocker.appendingPathComponent("usage.jsonl"))
        Usage.record("action", nil, path: blocker.appendingPathComponent("usage.jsonl"))
    }

    @Test func test_long_texts_are_cut_so_events_stay_small() throws {
        let path = try tempDir().appendingPathComponent("usage.jsonl")
        Usage.record("error", fields: [("text", .string(String(repeating: "x", count: 5000)))], path: path)
        let row = try #require(try rows(path).first)
        #expect(row["text"]?.stringValue?.unicodeScalars.count == Usage.MAX_TEXT)
    }

    @Test func test_read_skips_broken_lines() throws {
        let path = try tempDir().appendingPathComponent("usage.jsonl")
        try Data(("{\"kind\": \"view\", \"id\": \"today\", \"ts\": \"2026-10-30T10:00:00+01:00\"}\n{\"kind\": \"vi\n[1]\n").utf8)
            .write(to: path)
        #expect(Usage.read(path).map { $0["id"] } == [.string("today")])
    }

    @Test func test_setting_events_name_the_key_never_a_secret() throws {
        func body(_ s: String) throws -> JSONValue { try PythonJSON.parse(Data(s.utf8)) }
        func dumps(_ v: [JSONValue]) -> String { PythonJSON.dumps(.array(v)) }
        #expect(dumps(Usage.settingEvents(path: "/api/settings", body: try body(#"{"realtime": false, "bogus": 3}"#)))
                == #"[{"id": "realtime", "value": false}]"#)
        #expect(dumps(Usage.settingEvents(path: "/api/language-model/key", body: try body(#"{"provider": "openai", "key": "sk-123"}"#)))
                == #"[{"id": "key.openai", "removed": false}]"#)
        let lm = dumps(Usage.settingEvents(path: "/api/language-model", body: try body(
            #"{"use": {"notes": "claude"}, "provider": "azure", "endpoint": "https://x", "auth": "sk-zzz"}"#)))
        #expect(lm == #"[{"id": "use.notes", "value": "claude"}, {"id": "provider.azure", "fields": ["auth", "endpoint"]}]"#)
        #expect(!lm.contains("sk-zzz") && !lm.contains("https://x"))
    }

    @Test func test_the_catalog_of_the_window_is_kept() throws {
        // The window's half of Python's test_the_catalog_of_the_window_is_kept_and_merged_with_cli_and_settings:
        // the file `save_catalog` writes (the merge with the CLI and the settings is `usage.catalog`, Python).
        let path = try tempDir().appendingPathComponent("support/features.json")
        try Usage.saveCatalog(try PythonJSON.parse(Data(
            #"{"action": ["meeting.trash", "a", "meeting.trash", 3], "view": ["today"], "evil": ["x"], "tab": "no"}"#.utf8)),
            path: path)
        #expect(try text(path) == "{\n \"action\": [\n  \"a\",\n  \"meeting.trash\"\n ],\n \"view\": [\n  \"today\"\n ]\n}")
    }

    // MARK: - Swift only: the formats and the edges

    @Test func textIsCutByCodePointsAndFieldsMayReplaceKindAndId() throws {
        let path = try tempDir().appendingPathComponent("usage.jsonl")
        let long = String(repeating: "e\u{301}", count: 150)  // 300 scalars, 150 characters
        Usage.record("error", long, fields: [("text", .string(long)), ("id", .string("x")), ("list", .array([.string(long)]))],
                     path: path)
        let row = try #require(try rows(path).first)
        #expect(row["text"]?.stringValue?.unicodeScalars.count == 200)
        #expect(row["id"] == .string("x"))
        #expect(row["list"]?.arrayValue?.first?.stringValue?.unicodeScalars.count == 200)
        #expect(try text(path).contains("\"kind\": \"error\", \"id\": \"x\", \"text\""))
    }

    @Test func eventsAppendToWhatIsThereAndManyWritersDoNotInterleave() async throws {
        let path = try tempDir().appendingPathComponent("usage.jsonl")
        try Data("{\"kind\": \"old\", \"ts\": \"t\"}\n".utf8).write(to: path)
        await withTaskGroup(of: Void.self) { group in
            for w in 0..<8 {
                group.addTask {
                    for i in 0..<100 { Usage.record("action", "w\(w).\(i)", fields: [("pad", .string(String(repeating: "p", count: 150)))], path: path) }
                }
            }
        }
        let all = Usage.read(path)
        #expect(all.count == 801)
        #expect(all.first?["kind"] == .string("old"))
        #expect(Set(all.dropFirst().compactMap { $0["id"]?.stringValue }).count == 800)
    }

    @Test func aFeatureIsAKindWithAnIdAndACliCommandOnlyWhenAPersonTypedIt() throws {
        func e(_ s: String) throws -> PyDict<JSONValue> { Usage.readLines(s).first ?? PyDict() }
        #expect(Usage.feature(try e(#"{"ts": "t", "kind": "action", "id": "meeting.trash"}"#)) == "action:meeting.trash")
        #expect(Usage.feature(try e(#"{"ts": "t", "kind": "cli", "id": "doctor", "by": "user"}"#)) == "cli:doctor")
        #expect(Usage.feature(try e(#"{"ts": "t", "kind": "cli", "id": "live", "by": "app"}"#)) == nil)
        #expect(Usage.feature(try e(#"{"ts": "t", "kind": "error", "id": "x"}"#)) == nil)
        #expect(Usage.feature(try e(#"{"ts": "t", "kind": "view", "id": ""}"#)) == nil)
        #expect(Usage.feature(try e(#"{"ts": "t", "kind": "view"}"#)) == nil)
        #expect(Usage.feature(try e(#"{"ts": "t", "kind": "view", "id": 7}"#)) == "view:7")
    }

    @Test func settingEventsOfOddBodies() throws {
        func body(_ s: String) throws -> JSONValue { try PythonJSON.parse(Data(s.utf8)) }
        func dumps(_ path: String, _ b: String) throws -> String {
            PythonJSON.dumps(.array(Usage.settingEvents(path: path, body: try body(b))))
        }
        #expect(Usage.settingEvents(path: "/api/settings", body: .array([])).isEmpty)
        #expect(try dumps("/api/language-model/key", #"{"remove": 1}"#) == #"[{"id": "key.None", "removed": true}]"#)
        #expect(try dumps("/api/language-model", #"{"use": "claude-" , "local_model": 5}"#)
                == #"[{"id": "use", "value": "claude-"}, {"id": "local_model", "value": "5"}]"#)
        #expect(try dumps("/api/language-model", #"{"use": {"notes": 1, "x": null}}"#)
                == #"[{"id": "use.notes", "value": "1"}, {"id": "use.x", "value": "None"}]"#)
        let long = String(repeating: "m", count: 300)
        #expect(try dumps("/api/language-model", #"{"local_model": "\#(long)"}"#)
                == #"[{"id": "local_model", "value": "\#(String(repeating: "m", count: 120))"}]"#)
        #expect(try dumps("/api/settings", #"{"check_updates": true, "nudge_pace": "yes", "realtime": 1}"#)
                == #"[{"id": "check_updates", "value": true}]"#)
    }

}
