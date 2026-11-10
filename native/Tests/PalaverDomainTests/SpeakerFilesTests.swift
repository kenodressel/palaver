// Speaker names, merges and the files around them (speakers.py, test_speakers.py): saving names rewrites the
// transcript and teaches the voice bank; the meeting's lock guards every writer. The wizard and the process tests stay
// Python's (the ledger says why).
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

/// A meeting folder as test_speakers.py's `_folder` writes it (no audio: nothing here plays it), with the stores of a
/// temporary config dir.
struct SpeakerMeeting {
    let temp: TempFolder
    let paths: RecordingPaths
    let stores: StorePaths
    var bank: VoiceBank { VoiceBank(directory: stores.voices) }

    init(_ name: String = "2026-10-20T14-35-17") {
        temp = TempFolder("speakers")
        paths = RecordingPaths(temp.url.appendingPathComponent(name, isDirectory: true))
        try! FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        stores = StorePaths.current(env: ["XDG_CONFIG_HOME": temp.url.appendingPathComponent("config").path,
                                          "PALAVER_HOME": temp.url.appendingPathComponent("home").path])
    }

    func remove() { temp.remove() }

    func write(_ url: URL, _ value: JSONValue) {
        try! PythonJSON.write(value, to: url, indent: nil, ensureAscii: true)
    }

    func read(_ url: URL) -> JSONValue? { PythonJSON.read(url) }

    /// `{"speaker", "start", "end"}` turns.
    static func turns(_ t: [(String, Double, Double)]) -> JSONValue {
        .array(t.map { .object([("speaker", .string($0.0)), ("start", .double($0.1)), ("end", .double($0.2))]) })
    }

    static func line(_ speaker: String, _ start: Double, _ end: Double, _ text: String) -> JSONValue {
        .object([("speaker", .string(speaker)), ("start", .double(start)), ("end", .double(end)), ("text", .string(text))])
    }

    /// test_speakers.py's `_folder`.
    static func folder() -> SpeakerMeeting {
        let m = SpeakerMeeting()
        m.write(m.paths.meta, .object([("start_time", .string("2026-10-20T14:35:17+02:00")), ("duration_seconds", .int(20))]))
        m.write(m.paths.systemTurns, turns([("SPEAKER_00", 0.0, 4.0), ("SPEAKER_01", 5.0, 9.0), ("SPEAKER_02", 10.0, 12.0)]))
        m.write(m.paths.transcriptJson, .array([
            line("Timo", 0.0, 1.0, "Hi all."), line("SPEAKER_00", 0.5, 4.0, "Welcome to the review."),
            line("SPEAKER_01", 5.0, 9.0, "Numbers look good."), line("SPEAKER_02", 10.0, 12.0, "Agreed."),
        ]))
        return m
    }

    /// test_speakers.py's `_with_embeddings`.
    func withEmbeddings() {
        write(paths.systemTurns, Self.turns([("SPEAKER_00", 0.0, 30.0), ("SPEAKER_01", 30.0, 31.0)]))  // SPEAKER_01: too short to enrol
        write(paths.speakerEmbeddings, .object([("SPEAKER_00", .array([.double(1), .double(0), .double(0)])),
                                                ("SPEAKER_01", .array([.double(0), .double(1), .double(0)]))]))
    }

    func speakers() -> [String] { read(paths.transcriptJson)?.arrayValue?.compactMap { $0["speaker"]?.stringValue } ?? [] }

    func markdown() -> String { (try? String(contentsOf: paths.transcriptMd, encoding: .utf8)) ?? "" }

    func save(_ names: [(String, String)], learn: Bool = true) throws {
        try Speakers.saveSpeakerNames(paths, PyDict(names), bank: bank, learn: learn, stores: stores)
    }

    func merge(_ label: String, _ into: String?) throws {
        try Speakers.mergeSpeakers(paths, label, into: into, bank: bank, stores: stores)
    }
}

@Suite struct SpeakerFilesTests {
    @Test func test_longest_turns_picks_longest_per_speaker() {
        let turns = [SpeakerTurn(speaker: "SPEAKER_00", start: 0, end: 2), SpeakerTurn(speaker: "SPEAKER_01", start: 2, end: 9),
                     SpeakerTurn(speaker: "SPEAKER_00", start: 10, end: 15)]
        let picked = Speakers.longestTurns(turns)
        #expect(picked["SPEAKER_00"] == SpeakerTurn(speaker: "SPEAKER_00", start: 10, end: 15))
        #expect(picked["SPEAKER_01"] == SpeakerTurn(speaker: "SPEAKER_01", start: 2, end: 9))
    }

    @Test func test_apply_speaker_names_keeps_unmapped_labels() {
        let utts = [Utterance(speaker: "SPEAKER_00", start: 0, end: 1, text: "a"), Utterance(speaker: "Timo", start: 1, end: 2, text: "b")]
        let out = Speakers.applySpeakerNames(utts, PyDict([("SPEAKER_00", "Anna")]))
        #expect(out.map(\.speaker) == ["Anna", "Timo"])
        #expect(out.map(\.label) == ["SPEAKER_00", nil])
    }

    @Test func test_save_speaker_names_moves_a_corrected_voice_to_the_right_person() throws {
        let m = SpeakerMeeting.folder(); defer { m.remove() }
        m.withEmbeddings()
        try m.save([("SPEAKER_00", "Anna")])
        #expect(try m.bank.names() == PyDict([("Anna", 1)]))

        try m.save([("SPEAKER_00", "Bea")])  // it was Bea all along
        #expect(try m.bank.names() == PyDict([("Bea", 1)]))
        let transcript = try #require(m.read(m.paths.transcriptJson)?.arrayValue)
        #expect(transcript[1]["speaker"]?.stringValue == "Bea" && transcript[1]["label"]?.stringValue == "SPEAKER_00")
        #expect(m.markdown().contains("**Bea**"))

        try m.save([])  // unnamed again
        #expect(try m.bank.names().isEmpty)
        #expect(m.speakers()[1] == "SPEAKER_00")
    }

    @Test func test_save_speaker_names_keeps_recognized_names_unless_rejected() throws {
        let m = SpeakerMeeting.folder(); defer { m.remove() }
        m.write(m.paths.speakersAuto, .object([("SPEAKER_01", .object([("name", .string("Carl")), ("similarity", .double(0.8))]))]))
        try m.save([("SPEAKER_00", "Anna")])
        #expect(m.speakers() == ["Timo", "Anna", "Carl", "SPEAKER_02"])

        try m.save([("SPEAKER_00", "Anna"), ("SPEAKER_01", "SPEAKER_01")])  // not Carl
        #expect(m.speakers() == ["Timo", "Anna", "SPEAKER_01", "SPEAKER_02"])
    }

    @Test func test_merging_a_split_speaker_and_splitting_it_off_again() throws {
        let m = SpeakerMeeting.folder(); defer { m.remove() }
        m.write(m.paths.speakerEmbeddings, .object([("SPEAKER_00", .array([.double(1), .double(0), .double(0)])),
                                                    ("SPEAKER_01", .array([.double(0), .double(1), .double(0)])),
                                                    ("SPEAKER_02", .array([.double(0), .double(0), .double(1)]))]))
        m.write(m.paths.systemTurns, SpeakerMeeting.turns([("SPEAKER_00", 0, 30), ("SPEAKER_01", 30, 60), ("SPEAKER_02", 60, 90)]))

        try m.merge("SPEAKER_01", "SPEAKER_00")  // both unnamed yet
        #expect(m.speakers() == ["Timo", "SPEAKER_00", "SPEAKER_00", "SPEAKER_02"])
        #expect(m.read(m.paths.transcriptJson)?.arrayValue?[2]["label"]?.stringValue == "SPEAKER_01")  // kept, to split again

        try m.merge("SPEAKER_00", "SPEAKER_02")  // its merged label follows it
        #expect(Speakers.loadMerges(m.paths) == PyDict([("SPEAKER_00", "SPEAKER_02"), ("SPEAKER_01", "SPEAKER_02")]))
        #expect(throws: SpeakersValueError.self) { try m.merge("SPEAKER_02", "SPEAKER_01") }

        try m.save([("SPEAKER_02", "Konrad")])
        #expect(m.speakers() == ["Timo", "Konrad", "Konrad", "Konrad"])
        #expect(try m.bank.names() == PyDict([("Konrad", 1)]))  // only the voice it was merged into

        try m.merge("SPEAKER_00", nil)
        try m.merge("SPEAKER_01", nil)
        #expect(m.speakers() == ["Timo", "SPEAKER_00", "SPEAKER_01", "Konrad"])
        #expect(!FileManager.default.fileExists(atPath: m.paths.speakersMerged.path))
    }

    @Test func test_merging_moves_a_name_given_only_to_the_merged_speaker() throws {
        let m = SpeakerMeeting.folder(); defer { m.remove() }
        try m.save([("SPEAKER_01", "Konrad")])
        try m.merge("SPEAKER_01", "SPEAKER_00")
        #expect(m.read(m.paths.speakers).flatMap { PyDict<JSONValue>($0) } == PyDict([("SPEAKER_00", JSONValue.string("Konrad"))]))
        #expect(Array(m.speakers()[1...2]) == ["Konrad", "Konrad"])
    }

    // MARK: - beyond test_speakers.py: the files as Python writes them, and the locks

    @Test func test_the_speaker_files_are_written_as_python_writes_them() throws {
        let m = SpeakerMeeting.folder(); defer { m.remove() }
        try m.save([("SPEAKER_01", "Zoë Ärger"), ("SPEAKER_00", "Valerie")])
        #expect(try String(contentsOf: m.paths.speakers, encoding: .utf8) == "{\n  \"SPEAKER_01\": \"Zoë Ärger\",\n  \"SPEAKER_00\": \"Valerie\"\n}")
        let transcript = try String(contentsOf: m.paths.transcriptJson, encoding: .utf8)
        #expect(transcript.hasPrefix("[\n  {\n    \"speaker\": \"Timo\",\n    \"start\": 0.0,"))
        #expect(transcript.contains("\"speaker\": \"Zo\\u00eb \\u00c4rger\",\n    \"start\": 5.0,\n    \"end\": 9.0,\n    \"text\": \"Numbers look good.\",\n    \"label\": \"SPEAKER_01\""))
        #expect(m.markdown() == """
            # 2026-10-20 14:35 — Meeting (0 min, 4 speakers)

            **Timo** [14:35:17]  Hi all.

            **Valerie** [14:35:17]  Welcome to the review.

            **Zoë Ärger** [14:35:22]  Numbers look good.

            **SPEAKER_02** [14:35:27]  Agreed.

            """)

        try Speakers.setIgnored(m.paths, "SPEAKER_02")
        try Speakers.setIgnored(m.paths, "SPEAKER_00")
        #expect(try String(contentsOf: m.paths.speakersIgnored, encoding: .utf8) == "[\"SPEAKER_00\", \"SPEAKER_02\"]")
        try Speakers.setIgnored(m.paths, "SPEAKER_00", false)
        try Speakers.setIgnored(m.paths, "SPEAKER_02", false)
        #expect(!FileManager.default.fileExists(atPath: m.paths.speakersIgnored.path))

        try Speakers.setUnknown(m.paths, "SPEAKER_01")
        #expect(Speakers.loadUnknown(m.paths) == ["SPEAKER_01"])
        try Speakers.setRejectedName(m.paths, "SPEAKER_01", "Tom")
        try Speakers.setRejectedName(m.paths, "SPEAKER_01", "Zoë")
        try Speakers.setRejectedName(m.paths, "SPEAKER_01", "TOM")  // once, as last said
        #expect(try String(contentsOf: m.paths.speakersRejected, encoding: .utf8)
                == "{\n  \"SPEAKER_01\": [\n    \"Zoë\",\n    \"TOM\"\n  ]\n}")
        try Speakers.setRejectedName(m.paths, "SPEAKER_01", "zoë", false)
        try Speakers.setRejectedName(m.paths, "SPEAKER_01", "tom", false)
        #expect(!FileManager.default.fileExists(atPath: m.paths.speakersRejected.path))
    }

    @Test func test_names_in_effect_layer_inferred_recognized_and_given_names() throws {
        let m = SpeakerMeeting.folder(); defer { m.remove() }
        m.write(m.paths.speakersInferred, .object([("SPEAKER_00", .object([("name", .string("Carla"))])),
                                                   ("SPEAKER_02", .object([("name", .string("Anna"))]))]))
        m.write(m.paths.speakersAuto, .object([("SPEAKER_00", .object([("name", .string("Valerie")), ("similarity", .double(0.9))])),
                                               ("SPEAKER_01", .object([("name", .string("Tom")), ("similarity", .int(1))]))]))
        m.write(m.paths.speakers, .object([("SPEAKER_02", .string("SPEAKER_02"))]))
        m.write(m.paths.speakersRejected, .object([("SPEAKER_01", .strings(["tom"]))]))
        #expect(try Speakers.namesInEffect(m.paths) == PyDict([("SPEAKER_00", "Valerie")]))
        m.write(m.paths.speakersMerged, .object([("SPEAKER_01", .string("SPEAKER_00"))]))
        #expect(try Speakers.namesInEffect(m.paths) == PyDict([("SPEAKER_00", "Valerie"), ("SPEAKER_01", "Valerie")]))
        #expect(try Speakers.loadRecognizedNames(m.paths).keys == ["SPEAKER_00"])
    }

    @Test func test_names_given_while_recording_are_adopted_unless_named_afterwards() throws {
        let m = SpeakerMeeting.folder(); defer { m.remove() }
        m.write(m.paths.live, .object([("embeddings", .object([("SPEAKER_07", .array([.int(1), .int(0), .int(0)])),
                                                              ("SPEAKER_08", .array([.double(0), .double(1), .double(0.1)]))]))]))
        #expect(throws: NoLiveVoice.self) { try Speakers.nameLiveSpeaker(m.paths, "SPEAKER_09", "Valerie") }
        try Speakers.nameLiveSpeaker(m.paths, "SPEAKER_07", "  Valerie ")
        try Speakers.nameLiveSpeaker(m.paths, "SPEAKER_08", "Timo Strauß")
        #expect(try String(contentsOf: m.paths.speakersLive, encoding: .utf8)
                == #"[{"name": "Valerie", "embedding": [1, 0, 0]}, {"name": "Timo Strauß", "embedding": [0.0, 1.0, 0.1]}]"#)
        try Speakers.nameLiveSpeaker(m.paths, "SPEAKER_07", "Carla")  // renamed: Valerie goes
        try Speakers.nameLiveSpeaker(m.paths, "SPEAKER_08", " ")  // forgotten
        #expect(Speakers.loadLiveNames(m.paths).compactMap { $0["name"]?.stringValue } == ["Carla"])

        m.write(m.paths.speakerEmbeddings, .object([("SPEAKER_00", .array([.double(0.9), .double(0.1), .double(0)])),
                                                    ("SPEAKER_01", .array([.double(0), .double(1), .double(0)]))]))
        try Speakers.nameLiveSpeaker(m.paths, "SPEAKER_08", "Timo Strauß")
        m.write(m.paths.speakers, .object([("SPEAKER_01", .string("Valerie"))]))  // named afterwards: wins
        #expect(try Speakers.adoptLiveNames(m.paths) == PyDict([("SPEAKER_00", "Carla")]))
        #expect(try Speakers.loadSpeakerNames(m.paths) == PyDict([("SPEAKER_01", "Valerie"), ("SPEAKER_00", "Carla")]))
        #expect(!FileManager.default.fileExists(atPath: m.paths.speakersLive.path))
    }

    @Test func test_every_speaker_writer_waits_for_the_meetings_lock() async throws {
        let m = SpeakerMeeting.folder(); defer { m.remove() }
        m.withEmbeddings()
        let writers: [(String, () throws -> Void)] = [
            ("ignored", { try Speakers.setIgnored(m.paths, "SPEAKER_02") }),
            ("unknown", { try Speakers.setUnknown(m.paths, "SPEAKER_02") }),
            ("rejected", { try Speakers.setRejectedName(m.paths, "SPEAKER_02", "Tom") }),
            ("names", { try m.save([("SPEAKER_00", "Anna")]) }),
            ("merge", { try m.merge("SPEAKER_01", "SPEAKER_00") }),
        ]
        for (what, write) in writers {
            let held = try LockHolder(m.paths.folder.appendingPathComponent(".speakers.lock"), seconds: 0.4)
            let start = Date()
            try write()
            #expect(Date().timeIntervalSince(start) >= 0.3, "\(what) did not wait for the meeting's lock")
            held.wait()
        }
    }
}
