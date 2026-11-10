// A recording cut by a Palaver restart and its continuation, joined into one meeting before it is processed
// (tests/test_continuation.py under its names; issue #47). Synthetic audio only. A kill in the middle of a join is
// set up as the join leaves it (its backup, half-written files), as CuttingTests do.
import Foundation
import PalaverCore
@testable import PalaverDomain
import Testing

enum Parts {
    static let SR = 16_000
    static let VOICE: JSONValue = .array([.double(1), .double(0), .double(0)])

    /// 2026-10-29 12:06:10 local wall time: folder names are local time, so the start is too.
    static let T0: PyDateTime = {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 10, 29, 12, 6, 10)
        let date = Calendar.current.date(from: c)!
        return PyDateTime(date, offset: TimeZone.current.secondsFromGMT(for: date))
    }()

    static func name(_ t: PyDateTime) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f.string(from: t.date)
    }

    static func write(_ url: URL, _ json: String) throws { try json.write(to: url, atomically: false, encoding: .utf8) }

    static func tone(_ seconds: Int) -> [Int16] { [Int16](repeating: 7, count: seconds * SR) }

    /// A recorded part; `live`: the live worker finished it (mic.wav, segments, turns, voices).
    static func part(_ root: URL, _ start: PyDateTime, _ seconds: Int, live: Bool, stopReason: String = "restart") throws -> RecordingPaths {
        let paths = RecordingPaths(root.appendingPathComponent(name(start), isDirectory: true))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        for track in [paths.micRawWav, paths.systemWav] { try Wav16.write(tone(seconds), rate: SR, to: track) }
        try write(paths.meta, #"{"start_time": "\#(start.iso)", "end_time": "\#(try! start.adding(seconds: Double(seconds)).iso)", "duration_seconds": \#(seconds), "trigger": "teams", "stop_reason": "\#(stopReason)"}"#)
        if live {
            try Wav16.write(tone(seconds), rate: SR, to: paths.micWav)
            try write(paths.systemSegments, #"[{"start": 1.0, "end": 3.0, "text": "Hallo.", "speaker": null}]"#)
            try write(paths.micSegments, #"[{"start": 4.0, "end": 5.0, "text": "Ja.", "speaker": "Timo"}]"#)
            try write(paths.systemTurns, #"[{"speaker": "SPEAKER_00", "start": 1.0, "end": 3.0}]"#)
            try write(paths.speakerEmbeddings, #"{"SPEAKER_00": [1.0, 0.0, 0.0]}"#)
        }
        return paths
    }

    /// A part the app died recording: .part files, no meta.json; last written `minutesAgo` (0: still growing).
    static func crashed(_ root: URL, _ start: PyDateTime, _ seconds: Int, minutesAgo: Double = 0) throws -> RecordingPaths {
        let paths = RecordingPaths(root.appendingPathComponent(name(start), isDirectory: true))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: false)
        for track in [paths.micRawWav, paths.systemWav] {
            let part = URL(fileURLWithPath: track.path + ".part")
            try Wav16.write(tone(seconds), rate: SR, to: part)
            if minutesAgo > 0 {
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-minutesAgo * 60)], ofItemAtPath: part.path)
            }
        }
        return paths
    }

    static func meta(_ p: RecordingPaths) -> JSONValue { PythonJSON.read(p.meta) ?? .null }
    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    static func duration(_ url: URL) throws -> Double { try Wav16.info(url).duration }
    static func starts(_ url: URL) -> [Double] { (PythonJSON.read(url)?.arrayValue ?? []).compactMap { $0["start"]?.doubleValue } }
    static func names(_ url: URL) -> [String] { (PythonJSON.read(url)?.arrayValue ?? []).compactMap { $0["name"]?.stringValue } }

    /// Every file of a folder (not parts.json and the locks) and its bytes.
    static func content(_ folder: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where !name.hasSuffix(".lock") && name != "parts.json" {
            var isDir: ObjCBool = false
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue { out[name] = try Data(contentsOf: url) }
        }
        return out
    }
}

@Suite struct ContinuationPartsTests {
    typealias P = Parts

    @Test func test_parts_are_listed_on_the_first_part_in_order() throws {
        let t = TempFolder("parts"); defer { t.remove() }
        let a = t.url.appendingPathComponent("a"), b = t.url.appendingPathComponent("b"), c = t.url.appendingPathComponent("c")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: false)
        #expect(Continuation.parts(a).isEmpty)
        try Continuation.addPart(a, b)
        try Continuation.addPart(a, c)
        try Continuation.addPart(a, c)  // once
        #expect(Continuation.parts(a).map(\.path) == [b.path, c.path])
        #expect(t.text("a/parts.json") == "{\n  \"parts\": [\n    \"b\",\n    \"c\"\n  ]\n}")
        // What `process` keeps there stays, in its place.
        t.write("a/parts.json", #"{"parts": ["b"], "complete": false}"#)
        try Continuation.addPart(a, c)
        #expect(PythonJSON.dumps(PythonJSON.read(a.appendingPathComponent("parts.json"))!) == #"{"parts": ["b", "c"], "complete": false}"#)
        #expect(throws: (any Error).self) { try Continuation.addPart(t.url.appendingPathComponent("gone"), b) }
    }

    @Test func test_parts_the_live_worker_finished_are_joined_with_their_transcription() throws {
        let t = TempFolder("parts"); defer { t.remove() }
        let a = try P.part(t.url, P.T0, 30, live: true)
        let b = try P.part(t.url, try! P.T0.adding(seconds: 39), 60, live: true, stopReason: "call_ended")
        try Continuation.addPart(a.folder, b.folder)
        var lines: [String] = []
        #expect(try Continuation.joinParts(a, log: { lines.append("\($0) \($1)") }) == 1)
        #expect(!P.exists(b.folder) && !P.exists(a.parts))
        let meta = P.meta(a)
        #expect(PythonJSON.dumps(meta["gaps"]!) == #"[{"start": 30.0, "end": 39.0, "why": "restart"}]"#)
        #expect(meta["stop_reason"] == .string("call_ended") && meta["duration_seconds"]?.doubleValue == 99)
        #expect(try P.duration(a.micWav) == 99)
        #expect(P.starts(a.systemSegments) == [1.0, 40.0])
        #expect(P.starts(a.systemTurns) == [1.0, 40.0])
        #expect(!P.exists(a.transcriptJson))  // `process` merges it anew
        #expect(lines == ["INFO joined 1 part(s) into \(a.id)"])
    }

    @Test func test_a_part_whose_live_worker_was_stopped_is_transcribed_whole() throws {
        let t = TempFolder("parts"); defer { t.remove() }
        let a = try P.part(t.url, P.T0, 30, live: false)
        let b = try P.part(t.url, try! P.T0.adding(seconds: 39), 60, live: true, stopReason: "call_ended")
        try Continuation.addPart(a.folder, b.folder)
        try Continuation.joinParts(a)
        for derived in [a.micWav, a.micSegments, a.systemSegments, a.systemTurns, a.speakerEmbeddings, a.transcriptJson, a.speakersMerged] {
            #expect(!P.exists(derived), "\(derived.lastPathComponent)")
        }
        #expect(try P.duration(a.micRawWav) == 99 && P.duration(a.systemWav) == 99)
    }

    @Test func test_names_given_while_recording_come_along() throws {
        let t = TempFolder("parts"); defer { t.remove() }
        let a = try P.part(t.url, P.T0, 30, live: true)
        let b = try P.part(t.url, try! P.T0.adding(seconds: 39), 60, live: true)
        try P.write(a.speakersLive, #"[{"name": "Valerie", "embedding": [1.0, 0.0, 0.0]}]"#)
        try P.write(b.speakersLive, #"[{"name": "Timo Strauß", "embedding": [0.0, 1.0, 0.0]}]"#)
        try Continuation.addPart(a.folder, b.folder)
        try Continuation.joinParts(a)
        #expect(P.names(a.speakersLive) == ["Valerie", "Timo Strauß"])
        #expect(try String(contentsOf: a.speakersLive, encoding: .utf8).contains("Strauß"))  // ensure_ascii=False
    }

    @Test func test_a_part_that_never_finished_recording_is_recovered_and_joined() throws {
        let t = TempFolder("parts"); defer { t.remove() }
        let a = try P.part(t.url, P.T0, 30, live: false)
        let crashed = try P.crashed(t.url, try! P.T0.adding(seconds: 39), 20)
        let gone = t.url.appendingPathComponent("2026-10-29T12-30-00")  // moved to the trash meanwhile
        try Continuation.addPart(a.folder, crashed.folder)
        try Continuation.addPart(a.folder, gone)
        var lines: [String] = []
        #expect(try Continuation.joinParts(a, log: { lines.append("\($0) \($1)") }) == 1)
        #expect(!P.exists(crashed.folder) && !P.exists(a.parts))
        #expect(P.meta(a)["duration_seconds"]?.doubleValue == 59)
        #expect(try P.duration(a.systemWav) == 59)
        #expect(lines.contains("WARNING 2026-10-29T12-30-00, a part of \(a.id), is gone"))
    }

    @Test func test_a_part_that_cannot_be_read_stays_listed_to_recover_later() throws {
        let t = TempFolder("parts"); defer { t.remove() }
        let a = try P.part(t.url, P.T0, 30, live: false)
        let b = try P.part(t.url, try! P.T0.adding(seconds: 39), 20, live: false)
        let empty = RecordingPaths(t.url.appendingPathComponent("2026-10-29T12-07-30"))
        try FileManager.default.createDirectory(at: empty.folder, withIntermediateDirectories: false)  // nothing written
        try Continuation.addPart(a.folder, b.folder)
        try Continuation.addPart(a.folder, empty.folder)
        #expect(try Continuation.joinParts(a) == 1)
        #expect(Continuation.parts(a.folder).map(\.path) == [empty.folder.path] && P.exists(empty.folder))
    }

    @Test func test_a_failed_join_leaves_the_first_part_as_it_was() throws {
        // Python breaks `_per_label_files`; here the part's meta.json has gaps that are no list: the join fails after
        // the tracks were rewritten, and its backup puts them back.
        let t = TempFolder("parts"); defer { t.remove() }
        let a = try P.part(t.url, P.T0, 30, live: true)
        let b = try P.part(t.url, try! P.T0.adding(seconds: 39), 60, live: true)
        var bMeta = PyDict<JSONValue>(P.meta(b))!
        bMeta["gaps"] = .int(5)
        try PythonJSON.write(bMeta.json, to: b.meta, indent: nil, ensureAscii: true)
        try Continuation.addPart(a.folder, b.folder)
        let before = try P.content(a.folder)
        #expect(throws: (any Error).self) { try Continuation.joinParts(a) }
        #expect(try P.content(a.folder) == before && !P.exists(a.folder.appendingPathComponent(".join-backup")))
        #expect(P.exists(b.folder) && Continuation.parts(a.folder).map(\.path) == [b.folder.path])
    }

    @Test func test_a_join_killed_half_way_is_undone_before_it_runs_again() throws {
        let t = TempFolder("parts"); defer { t.remove() }
        let a = try P.part(t.url, P.T0, 30, live: true)
        let b = try P.part(t.url, try! P.T0.adding(seconds: 39), 60, live: true)
        try Continuation.addPart(a.folder, b.folder)
        // Killed after the backup and the joined tracks: nothing ran after it, no restore either.
        _ = try Cutting.makeBackup(a, b)
        for track in [a.micRawWav, a.systemWav, a.micWav] { try Wav16.write(P.tone(99), rate: P.SR, to: track) }
        #expect(try P.duration(a.systemWav) == 99)  // half-joined: the tracks are, the rest is not
        #expect(try Continuation.joinParts(a) == 1)  // undone first, then joined once
        #expect(P.meta(a)["duration_seconds"]?.doubleValue == 99)
        #expect(try P.duration(a.systemWav) == 99 && !P.exists(b.folder))
    }

    @Test func test_a_join_killed_after_writing_is_finished_not_repeated() throws {
        let t = TempFolder("parts"); defer { t.remove() }
        let a = try P.part(t.url, P.T0, 30, live: true)
        let b = try P.part(t.url, try! P.T0.adding(seconds: 39), 60, live: true)
        try Continuation.addPart(a.folder, b.folder)
        // Everything was written, only the move of the other part to the trash is missing (as the join leaves it).
        let copy = t.url.appendingPathComponent("b-copy")
        try FileManager.default.copyItem(at: b.folder, to: copy)
        try Cutting.join(a, b, keep: a, gapWhy: "restart")
        try FileManager.default.moveItem(at: copy, to: b.folder)
        let backup = a.folder.appendingPathComponent(".join-backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        try P.write(backup.appendingPathComponent("files.json"), #"{"files": ["meta.json"], "other": "\#(b.id)"}"#)
        try P.write(backup.appendingPathComponent("done"), "")
        try Continuation.joinParts(a)
        #expect(P.meta(a)["duration_seconds"]?.doubleValue == 99)  // not joined twice
        #expect(!P.exists(b.folder) && !P.exists(a.parts))
    }

    @Test func test_process_refuses_while_a_part_is_still_recording() throws {
        // The refusal itself is the worker's (WorkerMainTests.aFolderBeingRecordedIsExit3); here what it asks.
        let t = TempFolder("parts"); defer { t.remove() }
        let a = try P.part(t.url, P.T0, 3, live: false)
        let b = try P.crashed(t.url, try! P.T0.adding(seconds: 5), 3)  // .part files written just now: recording
        try Continuation.addPart(a.folder, b.folder)
        let stores = StorePaths(configDir: t.url.appendingPathComponent("config"), home: t.url.appendingPathComponent("home"))
        #expect(Continuation.stillRecording(a.folder, stores: stores).map(\.path) == [b.folder.path])
        #expect(P.exists(b.folder) && Continuation.parts(a.folder).map(\.path) == [b.folder.path])
    }

    @Test func test_a_first_part_the_app_died_recording_is_recovered_before_joining() throws {
        let t = TempFolder("parts"); defer { t.remove() }
        let a = try P.crashed(t.url, P.T0, 30, minutesAgo: 5)
        let b = try P.part(t.url, try! P.T0.adding(seconds: 39), 20, live: false, stopReason: "call_ended")
        try Continuation.addPart(a.folder, b.folder)
        #expect(try Continuation.joinParts(a) == 1)
        let meta = P.meta(a)
        #expect(meta["start_time"] == .string(P.T0.iso) && meta["duration_seconds"]?.doubleValue == 59)
        #expect(PythonJSON.dumps(meta["gaps"]!) == #"[{"start": 30.0, "end": 39.0, "why": "restart"}]"#)
    }

    @Test func test_a_first_part_without_audio_hands_the_meeting_to_the_next() throws {
        let t = TempFolder("parts"); defer { t.remove() }
        let a = RecordingPaths(t.url.appendingPathComponent(P.name(P.T0)))
        try FileManager.default.createDirectory(at: a.folder, withIntermediateDirectories: false)  // died before writing
        let b = try P.part(t.url, try! P.T0.adding(seconds: 39), 20, live: false)
        let c = try P.part(t.url, try! P.T0.adding(seconds: 70), 20, live: false, stopReason: "call_ended")
        try Continuation.addPart(a.folder, b.folder)
        try Continuation.addPart(a.folder, c.folder)
        var lines: [String] = []
        let head = try Continuation.recoverHead(a, log: { lines.append("\($0) \($1)") })
        #expect(head.folder == b.folder && Continuation.parts(b.folder).map(\.path) == [c.folder.path])
        #expect(!P.exists(a.parts) && P.exists(a.folder))  // left as it is: visible, can be trashed
        #expect(lines == ["WARNING \(a.id) has no audio; \(b.id) is the meeting now"])
        #expect(try Continuation.joinParts(head) == 1)
    }

    @Test func test_process_refuses_while_the_first_part_is_still_being_recorded() throws {
        let t = TempFolder("parts"); defer { t.remove() }
        let stores = StorePaths(configDir: t.url.appendingPathComponent("config"), home: t.url.appendingPathComponent("home"))
        let growing = try P.crashed(t.url, P.T0, 3)  // .part files written just now
        #expect(Continuation.stillRecording(growing.folder, stores: stores).map(\.path) == [growing.folder.path])

        let finished = try P.part(t.url, try! P.T0.adding(seconds: 300), 3, live: false)
        #expect(Continuation.stillRecording(finished.folder, stores: stores).isEmpty)
        try FileManager.default.createDirectory(at: stores.daemonJson.deletingLastPathComponent(), withIntermediateDirectories: true)
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        running.arguments = ["-c", "import time; time.sleep(30)", "palaver", "menubar"]
        try running.run()
        defer { running.terminate(); running.waitUntilExit() }
        try P.write(stores.daemonJson, #"{"state": "recording", "folder": "\#(finished.folder.path)", "pid": \#(running.processIdentifier)}"#)
        #expect(Continuation.stillRecording(finished.folder, stores: stores).map(\.path) == [finished.folder.path])  // a running app records into it
        try P.write(stores.daemonJson, #"{"state": "recording", "folder": "\#(finished.folder.path)", "pid": 999999999}"#)
        #expect(Continuation.stillRecording(finished.folder, stores: stores).isEmpty)  // that app is gone
        try P.write(stores.daemonJson, #"{"state": "stopped", "folder": "\#(finished.folder.path)", "pid": \#(running.processIdentifier)}"#)
        #expect(Continuation.stillRecording(finished.folder, stores: stores).isEmpty)
    }

    @Test func test_names_given_while_recording_are_not_doubled_by_a_join_run_again() throws {
        let t = TempFolder("parts"); defer { t.remove() }
        let a = try P.part(t.url, P.T0, 30, live: true)
        let b = try P.part(t.url, try! P.T0.adding(seconds: 39), 60, live: true)
        // A first run was killed after it wrote the names together into the head.
        try P.write(a.speakersLive, #"[{"name": "Valerie", "embedding": [1.0, 0.0, 0.0]}, {"name": "Timo Strauß", "embedding": [0.0, 1.0, 0.0]}]"#)
        try P.write(b.speakersLive, #"[{"embedding": [0.0, 1.0, 0.0], "name": "Timo Strauß"}]"#)
        try Continuation.addPart(a.folder, b.folder)
        try Continuation.joinParts(a)
        #expect(P.names(a.speakersLive) == ["Valerie", "Timo Strauß"])
    }

    @Test func test_the_join_backup_links_the_audio_and_copies_the_rest() throws {
        let t = TempFolder("parts"); defer { t.remove() }
        let a = try P.part(t.url, P.T0, 30, live: true)
        let b = try P.part(t.url, try! P.T0.adding(seconds: 39), 60, live: true)
        let backup = try Cutting.makeBackup(a, b)
        func inode(_ url: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as! NSNumber).intValue }
        #expect(try inode(backup.appendingPathComponent("system.wav")) == inode(a.systemWav))  // no 100 MB copies
        #expect(try inode(backup.appendingPathComponent("meta.json")) != inode(a.meta))  // rewritten in place: a copy
        try Cutting.finishUnfinishedJoin(a)
        #expect(!P.exists(backup))
    }
}
