// A meeting exported as one zip (exchange.py:1-132, 283-400, 416-519): the export tests of test_exchange.py, the
// export of the meeting Python exported for the exchange_zip golden, and the exchange_names golden (`file_name`,
// `free_name`). Fictional people only: Valerie exports, Timo Strauß is named by hand, Carla by voice.
import CryptoKit
import Darwin
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct ExchangeExportTests {
    static let ID = "2026-10-29T10-00-00"
    static let START = "2026-10-29T10:00:00+01:00"
    static let USER = "Valerie"
    static let EVENT: JSONValue = .object([
        ("title", .string("Budget review")), ("start", .string("2026-10-29T10:00:00+01:00")),
        ("end", .string("2026-10-29T10:30:00+01:00")), ("uid", .string("ABC-123")), ("series", .bool(true)),
        ("location", .string("Teams")),
        ("attendees", .array([
            .object([("name", .string("Valerie")), ("email", .string("valerie@northwind.example")), ("organizer", .bool(true)),
                     ("response", .string("accepted")), ("is_self", .bool(true))]),
            .object([("name", .string("Timo Strauß")), ("email", .string("timo@contoso.example")), ("response", .string("accepted"))]),
            .object([("name", .string("Carla")), ("email", .string("carla@contoso.example")), ("response", .string("accepted"))]),
        ])),
        ("link", .object([("source", .string("calendar")), ("confidence", .double(0.9)), ("reason", .string("time match"))])),
    ])

    static func vector(_ seed: Int) -> [Double] { (0..<8).map { Double(seed) + Double($0) / 8 - 0.3 } }

    static func write(_ v: JSONValue, _ url: URL, indent: Int? = nil) throws {
        try PythonJSON.write(v, to: url, indent: indent, ensureAscii: true)
    }

    /// Valerie's recording: Timo Strauß named by hand, Carla recognized by voice, SPEAKER_02 merged into Timo,
    /// SPEAKER_03 removed as noise.
    struct Setup {
        let t = TempFolder("exchange")
        let stores: StorePaths
        let paths: RecordingPaths

        init(event: Bool = true) throws {
            stores = StorePaths(configDir: t.url.appendingPathComponent("cfg/palaver"), home: t.url)
            paths = RecordingPaths(t.url.appendingPathComponent("valerie/\(ExchangeExportTests.ID)", isDirectory: true))
            try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
            try write(.object([("start_time", .string(START)), ("duration_seconds", .int(60))]), paths.meta)
            try "de".write(to: paths.language, atomically: false, encoding: .utf8)
            try write(.array([
                SpeakerTurn(speaker: "SPEAKER_00", start: 2, end: 20).json, SpeakerTurn(speaker: "SPEAKER_01", start: 21, end: 40).json,
                SpeakerTurn(speaker: "SPEAKER_02", start: 41, end: 44).json, SpeakerTurn(speaker: "SPEAKER_03", start: 45, end: 45.5).json,
            ]), paths.systemTurns)
            let utterances = [
                Utterance(speaker: USER, start: 0, end: 2, text: "Hallo zusammen."),
                Utterance(speaker: "Timo Strauß", start: 2, end: 20, text: "Das Budget steht.", label: "SPEAKER_00"),
                Utterance(speaker: "Carla", start: 21, end: 40, text: "Wir brauchen mehr Zeit.", label: "SPEAKER_01"),
                Utterance(speaker: "SPEAKER_02", start: 41, end: 44, text: "Genau."),
                Utterance(speaker: "SPEAKER_03", start: 45, end: 45.5, text: "Hm."),
                Utterance(speaker: USER, start: 50, end: 55, text: "Dann machen wir das so."),
            ]
            try write(.array(utterances.map(\.json)), paths.transcriptJson)
            try write(.object([("SPEAKER_00", .string("Timo Strauß"))]), paths.speakers)
            try write(.object([("SPEAKER_01", .object([("name", .string("Carla")), ("similarity", .double(0.9))]))]), paths.speakersAuto)
            try write(.object([("SPEAKER_02", .string("SPEAKER_00"))]), paths.speakersMerged)
            try write(.strings(["SPEAKER_03"]), paths.speakersIgnored)
            try write(.object((0..<4).map { ("SPEAKER_0\($0)", .array(vector($0).map { .double($0) })) }), paths.speakerEmbeddings)
            if event { try write(EVENT, paths.calendar) }
            try PythonJSON.write(.object([
                ("title", .string("Budget review")), ("summary", .string("SPEAKER_00 presented the budget.")),
                ("sections", .array([.object([("heading", .string("Budget")), ("points", .array([
                    .object([("text", .string("It is fixed")), ("details", .array([]))]),
                    .object([("text", .string("From my own notes")), ("details", .array([])), ("mine", .bool(true))]),
                ]))])])),
                ("next_steps", .array([
                    .object([("owner", .string("Timo Strauß")), ("task", .string("Send the numbers"))]),
                    .object([("owner", .string(USER)), ("task", .string("My private reminder")), ("mine", .bool(true))]),
                ])),
                ("decisions", .strings(["Budget approved", "A decision from my notes"])), ("decisions_mine", .array([.int(1)])),
                ("speaker_names", .array([])), ("transcript_hash", .string("0123abcd")), ("my_notes_hash", .string("abc")),
            ]), to: paths.notes, indent: 2, ensureAscii: false)
            // What never leaves: my notes (#44), review, the search index, coach data.
            try write(.object([("paragraphs", .array([.object([("text", .string("SECRET private note")), ("at", .int(3))])]))]), paths.myNotes)
            try write(.object([("reviewed", .string("2026-10-29T11:00:00+01:00"))]), paths.review)
            try Data("index".utf8).write(to: paths.folder.appendingPathComponent("search-index.npz"))
            try write(.object([("talk", .string("SECRET coach"))]), paths.folder.appendingPathComponent("coach.json"))
        }

        func export(_ name: String, notes: Bool = true, voices: Bool = false, confirmLocal: Bool = false) throws -> URL {
            try Exchange.exportMeeting(paths, dest: t.url.appendingPathComponent(name), userName: USER, notes: notes,
                                       voices: voices, confirmLocal: confirmLocal, stores: stores)
        }
    }

    /// name → bytes, in the zip's order.
    static func contents(_ url: URL) throws -> PyDict<Data> {
        let zip = try ZipReader(url: url, maxDirectoryBytes: ExchangeZip.MAX_DIRECTORY_BYTES)
        var out = PyDict<Data>()
        for entry in zip.entries { out[entry.name] = try zip.data(entry, limit: 1 << 26) }
        return out
    }

    static func names(_ url: URL) throws -> Set<String> { Set(try contents(url).keys) }

    static func doc(_ url: URL, _ name: String) throws -> JSONValue {
        try PythonJSON.parse(try #require(try contents(url)[name], "\(name) in the zip"))
    }

    // MARK: - test_exchange.py

    @Test func test_an_export_has_the_fixed_layout_and_a_manifest_with_checksums() throws {
        let s = try Setup(); defer { s.t.remove() }
        let out = try s.export("out/budget.zip")
        #expect(out.path == s.t.url.appendingPathComponent("out/budget.zip").path)
        #expect(try Self.names(out) == ["manifest.json", "meeting/meta.json", "meeting/calendar.json", "meeting/transcript.json",
                                        "meeting/turns.json", "meeting/speakers.json", "meeting/notes.json"])
        let manifest = try Self.doc(out, "manifest.json")
        #expect(manifest["format"] == .int(1) && manifest["exported_by"] == .string(Self.USER))
        #expect(manifest["palaver_version"]?.truthy == true && manifest["exported_at"]?.truthy == true)
        let files = try Self.contents(out)
        for (name, entry) in try #require(PyDict<JSONValue>(manifest["files"]!)) {
            let data = try #require(files[name])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(PythonJSON.dumps(entry) == PythonJSON.dumps(.object([("sha256", .string(digest)), ("bytes", .int(data.count))])))
        }
        let meta = try Self.doc(out, "meeting/meta.json")
        #expect(meta["start"] == .string(Self.START) && meta["duration"] == .double(60) && meta["title"] == .string("Budget review"))
        #expect(meta["language"] == .string("de"))
        // Nothing is left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.t.url.appendingPathComponent("out").path) == ["budget.zip"])
    }

    @Test func test_the_exporters_microphone_becomes_a_lane_named_after_them() throws {
        let s = try Setup(); defer { s.t.remove() }
        let out = try s.export("budget.zip")
        #expect(PythonJSON.dumps(try Self.doc(out, "meeting/speakers.json")) == PythonJSON.dumps(.array([
            .object([("label", .string("SPEAKER_00")), ("name", .string("Timo Strauß")), ("how", .string("hand"))]),
            .object([("label", .string("SPEAKER_01")), ("name", .string("Carla")), ("how", .string("voice"))]),
            .object([("label", .string("SPEAKER_04")), ("name", .string(Self.USER)), ("how", .string("exporter"))]),
        ])))
        let transcript = try #require(try Self.doc(out, "meeting/transcript.json").arrayValue)
        #expect(transcript.map { [$0["label"]!.stringValue!, $0["speaker"]!.stringValue!] } == [
            ["SPEAKER_04", Self.USER], ["SPEAKER_00", "Timo Strauß"], ["SPEAKER_01", "Carla"], ["SPEAKER_00", "Timo Strauß"],
            ["SPEAKER_04", Self.USER]])
        let turns = try #require(try Self.doc(out, "meeting/turns.json").arrayValue)
        #expect(Set(turns.map { $0["speaker"]!.stringValue! }) == ["SPEAKER_00", "SPEAKER_01", "SPEAKER_04"])  // merged folded, noise gone
        #expect(turns.contains { PythonJSON.dumps($0) == PythonJSON.dumps(.object([("speaker", .string("SPEAKER_04")), ("start", .double(50)), ("end", .double(55))])) })
    }

    @Test func test_lines_said_to_be_someone_elses_travel_with_their_speaker() throws {
        // #12: a line given to a speaker, to a person without a voice of their own, or to the exporter goes out as theirs.
        let s = try Setup(); defer { s.t.remove() }
        try Data(#"""
            [{"start": 0.0, "end": 2.0, "from": null, "label": "SPEAKER_00"},
             {"start": 21.0, "end": 40.0, "from": "SPEAKER_01", "name": "Bea"},
             {"start": 41.0, "end": 44.0, "from": "SPEAKER_02", "me": true, "name": "Valerie"}]
            """#.utf8).write(to: s.paths.speakersLines)
        let out = try s.export("budget.zip")
        let transcript = try #require(try Self.doc(out, "meeting/transcript.json").arrayValue)
        #expect(transcript.map { "\($0["start"]!.doubleValue!) \($0["label"]!.stringValue!) \($0["speaker"]!.stringValue!)" } == [
            "0.0 SPEAKER_00 Timo Strauß", "2.0 SPEAKER_00 Timo Strauß", "21.0 SPEAKER_05 Bea", "41.0 SPEAKER_04 Valerie",
            "50.0 SPEAKER_04 Valerie"])
        let speakers = try #require(try Self.doc(out, "meeting/speakers.json").arrayValue)
        #expect(speakers.contains { PythonJSON.dumps($0) == #"{"label": "SPEAKER_05", "name": "Bea", "how": "hand"}"# })
        let turns = try #require(try Self.doc(out, "meeting/turns.json").arrayValue).map { PythonJSON.dumps($0) }
        #expect(turns.contains(#"{"speaker": "SPEAKER_05", "start": 21.0, "end": 40.0}"#))
        #expect(turns.contains(#"{"speaker": "SPEAKER_04", "start": 41.0, "end": 44.0}"#))
        #expect(!(try Self.contents(out)).keys.joined(separator: " ").contains("speakers_lines"))  // applied, not sent along
    }

    @Test func test_own_notes_coach_review_and_indexes_never_leave() throws {
        let s = try Setup(); defer { s.t.remove() }
        let out = try s.export("budget.zip")
        let everything = try Self.contents(out).values.reduce(Data(), +)
        #expect(everything.range(of: Data("SECRET".utf8)) == nil && everything.range(of: Data("reviewed".utf8)) == nil)
        let shared = try Self.doc(out, "meeting/notes.json")
        #expect(shared["decisions"] == .strings(["Budget approved"]))
        #expect(shared["next_steps"]?.arrayValue?.map { $0["task"] } == [.string("Send the numbers")])
        #expect(shared["sections"]?.arrayValue?.first?["points"]?.arrayValue?.map { $0["text"] } == [.string("It is fixed")])
        #expect(shared["my_notes_hash"] == nil && shared["transcript_hash"] == nil && shared["decisions_mine"] == nil)
    }

    @Test func test_where_the_meeting_was_held_stays_home() throws {
        let s = try Setup(); defer { s.t.remove() }
        #expect(try Self.doc(try s.export("budget.zip"), "meeting/calendar.json")["location"] == nil)
    }

    @Test func test_notes_can_be_left_out() throws {
        let s = try Setup(); defer { s.t.remove() }
        #expect(!(try Self.names(try s.export("x.zip", notes: false))).contains("meeting/notes.json"))
    }

    @Test func test_voices_go_in_only_when_asked_and_only_of_people_named_by_hand_or_voice() throws {
        let s = try Setup(); defer { s.t.remove() }
        try Self.write(.object([("SPEAKER_01", .object([("name", .string("X")), ("rule", .string("calendar")), ("why", .string("")),
                                                         ("confidence", .double(0.9))]))]), s.paths.speakersInferred)
        #expect(!(try Self.names(try s.export("a.zip"))).contains { $0.hasPrefix("voices/") })
        let out = try s.export("x.zip", voices: true)
        let voices = try Self.names(out).filter { $0.hasPrefix("voices/") }
        #expect(voices == ["voices/SPEAKER_00.json", "voices/SPEAKER_01.json"])
        #expect(PythonJSON.dumps(try Self.doc(out, "voices/SPEAKER_00.json")) == PythonJSON.dumps(.object([
            ("label", .string("SPEAKER_00")), ("name", .string("Timo Strauß")), ("embedding", .array(Self.vector(0).map { .double($0) })),
        ])))
    }

    @Test func test_a_meeting_kept_on_this_mac_asks_before_it_exports() throws {
        let s = try Setup(); defer { s.t.remove() }
        try "{}".write(to: s.paths.localOnly, atomically: false, encoding: .utf8)
        #expect(throws: Exchange.KeptOnThisMac.self) { try s.export("x.zip") }
        #expect(!s.t.exists("x.zip"))
        #expect(FileManager.default.fileExists(atPath: try s.export("x.zip", confirmLocal: true).path))
    }

    /// The flag in meta.json, and the import keeping the meeting on this Mac until lifted (`api.get_meeting`'s
    /// `local_only` is the marker; `api.set_local_only` is `LocalOnly.set`).
    @Test func test_keep_on_this_mac_travels_with_the_file_and_can_be_lifted_here() throws {
        let s = try Setup(); defer { s.t.remove() }
        try "{}".write(to: s.paths.localOnly, atomically: false, encoding: .utf8)
        let out = try s.export("x.zip", confirmLocal: true)
        #expect(try Self.doc(out, "meeting/meta.json")["kept_on_this_mac"] == .bool(true))
        let mine = s.t.url.appendingPathComponent("timo", isDirectory: true)
        try Exchange.importPackage(mine, out, userName: "Timo", stores: s.stores, timeZone: TimeZone(identifier: "Europe/Berlin")!)
        let here = mine.appendingPathComponent(Self.ID, isDirectory: true)
        #expect(LocalOnly.isLocalOnly(here))
        try LocalOnly.set(here, on: false)
        #expect(!LocalOnly.isLocalOnly(here))
    }

    @Test func test_a_meeting_not_kept_on_this_mac_comes_in_as_any_other() throws {
        let s = try Setup(); defer { s.t.remove() }
        let out = try s.export("x.zip")
        #expect(try Self.doc(out, "meeting/meta.json")["kept_on_this_mac"] == .bool(false))
        let mine = s.t.url.appendingPathComponent("timo", isDirectory: true)
        try Exchange.importPackage(mine, out, userName: "Timo", stores: s.stores)
        #expect(!LocalOnly.isLocalOnly(mine.appendingPathComponent(Self.ID, isDirectory: true)))
    }

    @Test func test_a_meeting_still_being_processed_is_not_exported() throws {
        let s = try Setup(); defer { s.t.remove() }
        try FileManager.default.removeItem(at: s.paths.transcriptJson)
        #expect(throws: Exchange.NotReady.self) { try s.export("x.zip") }
    }

    @Test func test_the_file_name_is_date_and_title() throws {
        let s = try Setup(); defer { s.t.remove() }
        try Self.write(.object([("title", .string("Q3: budget / plan?"))]), s.paths.folder.appendingPathComponent("title.json"))
        #expect(Exchange.fileName(s.paths, timeZone: TimeZone(identifier: "Europe/Berlin")!, stores: s.stores)
                == "2026-10-29 Q3 budget plan.zip")
    }

    /// Ported for `sweep`: leftovers of imports go, fresh ones and other files stay; the export's leftovers go when
    /// Downloads is given. When the server sweeps which is its task (Task 41 on).
    @Test func test_leftovers_of_imports_are_swept_at_start_and_of_exports_on_the_next_export() throws {
        let t = TempFolder("sweep"); defer { t.remove() }
        let rec = t.url.appendingPathComponent("rec"), downloads = t.url.appendingPathComponent("Downloads")
        let old = rec.appendingPathComponent(".importing/a"), fresh = rec.appendingPathComponent(".importing/b")
        let oldExport = downloads.appendingPathComponent(".palaver-export-x1"), other = downloads.appendingPathComponent("keep.zip")
        let oldFile = rec.appendingPathComponent(".importing/c.txt")
        for d in [old, fresh, oldExport] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try "mine".write(to: other, atomically: false, encoding: .utf8)
        try "x".write(to: oldFile, atomically: false, encoding: .utf8)
        let hoursAgo = Date().addingTimeInterval(-2 * 3600)
        for url in [old, oldExport, other, oldFile] {
            try FileManager.default.setAttributes([.modificationDate: hoursAgo], ofItemAtPath: url.path)
        }
        func there(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        Exchange.sweep(rec)
        #expect(!there(old) && there(fresh) && there(oldExport) && there(other) && there(oldFile))
        Exchange.sweep(rec, downloads: downloads)
        #expect(!there(oldExport) && there(other))
    }

    // MARK: - against Python

}
