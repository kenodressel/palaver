// People across meetings (people.py, test_people.py): recognition in every meeting, the directory with its groups of
// unnamed voices, naming and renaming everywhere, suggestions.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

/// A recordings folder with the stores of a temporary config dir, and meetings written as test_people.py's and
/// test_inference.py's `_meeting` write them.
struct PeopleRoot {
    let temp: TempFolder
    let root: URL
    let stores: StorePaths
    var bank: VoiceBank { VoiceBank(directory: stores.voices) }

    init() {
        temp = TempFolder("people")
        root = temp.url.appendingPathComponent("Meetings", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        stores = StorePaths.current(env: ["XDG_CONFIG_HOME": temp.url.appendingPathComponent("config").path,
                                          "PALAVER_HOME": temp.url.appendingPathComponent("home").path])
    }

    func remove() { temp.remove() }

    func write(_ url: URL, _ value: JSONValue) {
        try! PythonJSON.write(value, to: url, indent: nil, ensureAscii: true)
    }

    /// `_unit(*v)`: the vector over its norm (numpy's).
    static func unit(_ v: Double...) -> [Double] { VoiceMath.unit(v) }

    /// A processed recording; `speakers`: (label, voice, seconds of talk). `user`: the transcript starts with the
    /// user's line (test_people.py) or not (test_inference.py).
    @discardableResult
    func meeting(_ name: String, _ speakers: [(String, [Double], Double)], start: String = "2026-10-27T10:00:00+01:00",
                 duration: Int = 600, user: Bool = true) -> RecordingPaths {
        let paths = RecordingPaths(root.appendingPathComponent(name, isDirectory: true))
        try! FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        write(paths.meta, .object([("start_time", .string(start)), ("duration_seconds", .int(duration))]))
        var turns: [JSONValue] = []
        var transcript: [JSONValue] = user ? [SpeakerMeeting.line("Timo", 0.0, 1.0, "Hi.")] : []
        var t = user ? 1.0 : 0.0
        for (label, _, talk) in speakers {
            turns.append(.object([("speaker", .string(label)), ("start", .double(t)), ("end", .double(t + talk))]))
            transcript.append(SpeakerMeeting.line(label, t, t + talk, "I am \(label)."))
            t += talk
        }
        write(paths.systemTurns, .array(turns))
        write(paths.transcriptJson, .array(transcript))
        write(paths.speakerEmbeddings, .object(speakers.map { ($0.0, .array($0.1.map { .double($0) })) }))
        return paths
    }

    /// `_names_in`: label (or speaker) → the name the transcript shows.
    func names(_ paths: RecordingPaths) -> PyDict<String> {
        PyDict((PythonJSON.read(paths.transcriptJson)?.arrayValue ?? []).map { u in
            let shown = u["speaker"]?.stringValue ?? ""
            let label = u["label"]?.stringValue ?? ""
            return (label.isEmpty ? shown : label, shown)
        })
    }

    func directory(me: Set<String> = []) throws -> JSONValue {
        try People.directory(outputDir: root, me: me, bank: bank, stores: stores)
    }

    func nameVoices(_ members: [(String, String)], _ name: String) throws {
        try People.nameVoices(outputDir: root, members: members, name: name, bank: bank, stores: stores)
    }
}

@Suite struct PeopleTests {
    static let ANNA = PeopleRoot.unit(1, 0, 0, 0)
    static let BEN = PeopleRoot.unit(0, 1, 0, 0)
    static let CARL = PeopleRoot.unit(0, 0, 1, 0)

    private func dumps(_ v: JSONValue?) -> String { v.map { PythonJSON.dumps($0, ensureAscii: false) } ?? "nil" }

    @Test func test_naming_a_voice_recognizes_it_in_other_meetings() throws {
        let r = PeopleRoot(); defer { r.remove() }
        let m1 = r.meeting("2026-10-20T10-00-00", [("SPEAKER_00", Self.ANNA, 60), ("SPEAKER_01", Self.BEN, 60)])
        let m2 = r.meeting("2026-10-27T10-00-00", [("SPEAKER_00", Self.BEN, 30), ("SPEAKER_01", PeopleRoot.unit(1, 0.05, 0, 0), 40)])

        try r.nameVoices([("2026-10-20T10-00-00", "SPEAKER_00")], "Anna")

        #expect(r.names(m1)["SPEAKER_00"] == "Anna")
        #expect(r.names(m2)["SPEAKER_01"] == "Anna")  // same voice, other meeting
        #expect(PythonJSON.read(m2.speakersAuto)?["SPEAKER_01"]?["name"]?.stringValue == "Anna")
        #expect(r.names(m2)["SPEAKER_00"] == "SPEAKER_00")  // Ben is still unknown
    }

    @Test func test_recurring_unknown_voices_are_grouped_across_meetings() throws {
        let r = PeopleRoot(); defer { r.remove() }
        r.meeting("2026-10-20T10-00-00", [("SPEAKER_00", Self.ANNA, 60), ("SPEAKER_01", Self.BEN, 60)])
        r.meeting("2026-10-27T10-00-00", [("SPEAKER_00", PeopleRoot.unit(0.05, 1, 0, 0), 30), ("SPEAKER_01", Self.CARL, 40)])

        let unknown = try #require(try r.directory()["unknown"]?.arrayValue)

        #expect(unknown.count == 1)  // Ben twice; Anna and Carl are in one meeting only
        let members = (unknown[0]["voices"]?.arrayValue ?? []).map { ($0["meeting"]?.stringValue ?? "", $0["label"]?.stringValue ?? "") }
        #expect(members.map { "\($0.0) \($0.1)" } == ["2026-10-20T10-00-00 SPEAKER_01", "2026-10-27T10-00-00 SPEAKER_00"])

        try r.nameVoices(members, "Ben")
        let d = try r.directory()
        #expect(d["unknown"]?.arrayValue?.isEmpty == true)
        let people = try #require(d["people"]?.arrayValue)
        #expect(people.count == 1)
        #expect(people[0]["name"]?.stringValue == "Ben" && people[0]["meetings"]?.arrayValue?.count == 2)
        #expect(people[0]["talk_seconds"]?.doubleValue == 90)
    }

    @Test func test_directory_lists_named_people_with_their_meetings() throws {
        let r = PeopleRoot(); defer { r.remove() }
        let m1 = r.meeting("2026-10-20T10-00-00", [("SPEAKER_00", Self.ANNA, 60), ("SPEAKER_01", Self.BEN, 5)])
        r.write(m1.speakers, .object([("SPEAKER_00", .string("Anna")), ("SPEAKER_01", .string("Ben"))]))
        let people = try #require(try r.directory()["people"]?.arrayValue)
        let byName = PyDict(people.map { ($0["name"]?.stringValue ?? "", $0) })
        #expect(Set(byName.keys) == ["Anna", "Ben"])  // Ben too, though too short to learn his voice
        #expect(dumps(byName["Anna"]?["meetings"]?.arrayValue?.first)
            == #"{"id": "2026-10-20T10-00-00", "label": "SPEAKER_00", "talk_seconds": 60.0, "named_by": "you"}"#)
    }

    @Test func test_renaming_a_person_renames_them_everywhere() throws {
        let r = PeopleRoot(); defer { r.remove() }
        let m1 = r.meeting("2026-10-20T10-00-00", [("SPEAKER_00", Self.ANNA, 60)])
        let m2 = r.meeting("2026-10-27T10-00-00", [("SPEAKER_03", Self.ANNA, 60)])
        try r.nameVoices([("2026-10-20T10-00-00", "SPEAKER_00")], "Ana")
        #expect(r.names(m2)["SPEAKER_03"] == "Ana")

        try People.renamePerson(outputDir: r.root, old: "Ana", new: "Anna Müller", bank: r.bank, stores: r.stores)

        #expect(r.names(m1)["SPEAKER_00"] == "Anna Müller")
        #expect(r.names(m2)["SPEAKER_03"] == "Anna Müller")
        #expect(try r.bank.names() == PyDict([("Anna Müller", 1)]))
    }

    @Test func test_renaming_onto_an_existing_person_merges() throws {
        let r = PeopleRoot(); defer { r.remove() }
        r.meeting("2026-10-20T10-00-00", [("SPEAKER_00", Self.ANNA, 60), ("SPEAKER_01", Self.BEN, 60)])
        try r.nameVoices([("2026-10-20T10-00-00", "SPEAKER_00")], "Anna")
        try r.nameVoices([("2026-10-20T10-00-00", "SPEAKER_01")], "Anna M.")
        try People.renamePerson(outputDir: r.root, old: "Anna M.", new: "Anna", bank: r.bank, stores: r.stores)
        #expect(try r.bank.names() == PyDict([("Anna", 2)]))
        #expect(try r.directory()["people"]?.arrayValue?.map { $0["name"]?.stringValue } == ["Anna"])
    }

    @Test func test_close_but_uncertain_voices_are_only_suggested() throws {
        let r = PeopleRoot(); defer { r.remove() }
        r.meeting("2026-10-20T10-00-00", [("SPEAKER_00", Self.ANNA, 60)])
        let m2 = r.meeting("2026-10-27T10-00-00", [("SPEAKER_00", PeopleRoot.unit(1, 0.9, 0, 0), 60)])  // cos 0.74
        try r.nameVoices([("2026-10-20T10-00-00", "SPEAKER_00")], "Anna")
        #expect(r.names(m2)["SPEAKER_00"] == "SPEAKER_00")
        let close = try #require(try People.suggestions(m2, bank: r.bank, stores: r.stores)["SPEAKER_00"])
        #expect(close.count == 1)
        #expect(close[0].0 == "Anna" && 0.65 <= close[0].1 && close[0].1 < 0.75)
    }

    @Test func test_a_meeting_just_started_has_no_suggestions_yet() throws {
        // A live meeting before its first block: no speaker turns yet (the window opened it and failed).
        let r = PeopleRoot(); defer { r.remove() }
        let paths = RecordingPaths(r.root.appendingPathComponent("2026-10-30T08-02-13", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        #expect(try People.suggestions(paths, bank: r.bank, stores: r.stores).isEmpty)
    }

    @Test func test_a_merged_speaker_counts_as_the_one_it_joined() throws {
        let r = PeopleRoot(); defer { r.remove() }
        let m = r.meeting("2026-10-21T16-29-29", [("SPEAKER_00", Self.ANNA, 60), ("SPEAKER_01", Self.BEN, 20)])
        let other = r.meeting("2026-10-27T10-00-00", [("SPEAKER_00", Self.BEN, 30)])
        try Speakers.mergeSpeakers(m, "SPEAKER_01", into: "SPEAKER_00", bank: r.bank, stores: r.stores)
        try r.nameVoices([("2026-10-21T16-29-29", "SPEAKER_00")], "Konrad")

        let people = try #require(try r.directory()["people"]?.arrayValue)
        #expect(people.count == 1)
        #expect(dumps(people.first?["meetings"])
            == #"[{"id": "2026-10-21T16-29-29", "label": "SPEAKER_00", "talk_seconds": 80.0, "named_by": "you"}]"#)
        #expect(r.names(other)["SPEAKER_00"] == "SPEAKER_00")  // Ben's voice did not become Konrad's
        #expect(try People.voices(r.root).filter { $0.meeting == m.id }.map(\.label) == ["SPEAKER_00"])
    }

    @Test func test_the_people_list_marks_the_user_by_any_of_their_names() throws {
        // #55: an old name kept as an alias is still the user.
        let r = PeopleRoot(); defer { r.remove() }
        r.meeting("2026-10-20T10-00-00", [("SPEAKER_00", Self.ANNA, 60), ("SPEAKER_01", Self.BEN, 60)])
        try r.nameVoices([("2026-10-20T10-00-00", "SPEAKER_00")], "Anna")
        try r.nameVoices([("2026-10-20T10-00-00", "SPEAKER_01")], "Timo")  // the user's echo, old name
        let people = try #require(try r.directory(me: ["timo strauß", "timo"])["people"]?.arrayValue)
        #expect(Dictionary(uniqueKeysWithValues: people.map { ($0["name"]?.stringValue ?? "", $0["you"]?.boolValue ?? false) })
            == ["Anna": false, "Timo": true])
    }

    // test_attribution.py
    @Test func test_renaming_a_person_moves_their_rejections() throws {
        let r = PeopleRoot(); defer { r.remove() }
        let a = r.meeting("2026-10-21T10-00-00", [("SPEAKER_00", PeopleRoot.unit(1, 0, 0), 60)], user: false)
        try Speakers.setRejectedName(a, "SPEAKER_00", "Tom")
        try People.renamePerson(outputDir: r.root, old: "Tom", new: "Thomas Berg", bank: r.bank, stores: r.stores)
        #expect(Speakers.loadRejectedNames(a) == PyDict([("SPEAKER_00", ["Thomas Berg"])]))
    }

    @Test func theDirectoryIsWrittenInPythonsShape() throws {
        // Key order, rounding and the order of people and groups: most talk first.
        let r = PeopleRoot(); defer { r.remove() }
        r.meeting("2026-10-20T10-00-00", [("SPEAKER_00", Self.ANNA, 60.04), ("SPEAKER_01", Self.BEN, 12.25), ("SPEAKER_02", Self.CARL, 30)])
        r.meeting("2026-10-27T10-00-00", [("SPEAKER_00", PeopleRoot.unit(0.05, 1, 0, 0), 30), ("SPEAKER_01", PeopleRoot.unit(0, 0.04, 1, 0), 40)])
        try r.nameVoices([("2026-10-20T10-00-00", "SPEAKER_00")], "Anna")
        #expect(dumps(try r.directory(me: ["anna"])) == """
            {"people": [{"name": "Anna", "meetings": [{"id": "2026-10-20T10-00-00", "label": "SPEAKER_00", "talk_seconds": 60.0, \
            "named_by": "you"}], "talk_seconds": 60.0, "voice_samples": 1, "you": true}], "unknown": [{"voices": [{"meeting": \
            "2026-10-20T10-00-00", "label": "SPEAKER_02", "talk_seconds": 30.0}, {"meeting": "2026-10-27T10-00-00", "label": \
            "SPEAKER_01", "talk_seconds": 40.0}], "talk_seconds": 70.0}, {"voices": [{"meeting": "2026-10-20T10-00-00", "label": \
            "SPEAKER_01", "talk_seconds": 12.2}, {"meeting": "2026-10-27T10-00-00", "label": "SPEAKER_00", "talk_seconds": 30.0}], \
            "talk_seconds": 42.2}]}
            """)
    }

    // MARK: - Swift only

    /// people.py sums a group's talk with Python's `sum()`, which is compensated: seven voices of 10.05 s are 70.4 s
    /// once rounded (Python, checked), a plain sum rounds to 70.3.
    @Test func anUnknownGroupsTalkIsPythonsSum() throws {
        let r = PeopleRoot(); defer { r.remove() }
        for day in 0..<7 { r.meeting("2026-10-\(20 + day)T10-00-00", [("SPEAKER_00", Self.BEN, 10.05)]) }
        let unknown = try #require(try r.directory()["unknown"]?.arrayValue)
        #expect(unknown.count == 1 && unknown[0]["voices"]?.arrayValue?.count == 7)
        #expect(unknown[0]["talk_seconds"] == .double(70.4))
    }
}
