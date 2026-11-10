// Speakers named by inference (inference.py, test_inference.py), the import's name hints (exchange.py `hints`, the hint
// tests of test_exchange.py) and the inference test of test_attribution.py. The window's `name_speaker` is api.py's
// (ported with it): `nameSpeaker` below does the domain steps it takes for the cases these tests use.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

extension PeopleRoot {
    static let T0 = "2026-10-20T10:00:00+02:00"

    /// test_inference.py's `_meeting`: a meeting from T0 for an hour, its event with the user and `invited` (and a room).
    @discardableResult
    func inferMeeting(_ name: String, _ speakers: [(String, [Double], Double)], _ invited: [String], room: Bool = false) -> RecordingPaths {
        let paths = meeting(name, speakers, start: Self.T0, duration: 3600, user: false)
        let t0 = try! PyDateTime.parse(Self.T0)
        var attendees = [Attendee(name: "Timo Strauss", email: "timo@kloud.io", isSelf: true)]
        attendees += invited.map { Attendee(name: $0, email: "\(Py.strLower(Py.split($0)[0]))@x.com") }
        if room { attendees.append(Attendee(name: "Room 3", email: "room@x.com", isRoom: true)) }
        try! CalendarEvents.save(paths, CalendarEvent(title: name, start: t0, end: try! t0.adding(seconds: 3600), attendees: attendees))
        return paths
    }

    func refresh(userName: String = "") throws -> Int {
        try Inference.refresh(outputDir: root, userName: userName, bank: bank, stores: stores)
    }

    /// What api.name_speaker does in the domain (not while recording): a name given, confirmed or emptied; emptying a
    /// recognized or inferred name rejects it for this voice. Then recognition everywhere.
    func nameSpeaker(_ paths: RecordingPaths, _ label: String, _ typed: String) throws {
        let label = Speakers.loadMerges(paths)[label] ?? label
        var names = try Speakers.loadSpeakerNames(paths)
        let name = Py.strip(typed)
        var automatic: String?
        if names[label] == nil { automatic = try Speakers.loadRecognizedNames(paths)[label]?.0 ?? Speakers.loadInferredNames(paths)[label] }
        if name.isEmpty, let automatic {
            try Speakers.setRejectedName(paths, label, automatic)
        } else if !name.isEmpty {
            try Speakers.setUnknown(paths, label, false)
            names[label] = name
        } else if try Speakers.loadRecognizedNames(paths)[label] != nil || Inference.load(paths)[label] != nil {
            names[label] = label
        } else {
            names[label] = nil
        }
        try Speakers.saveSpeakerNames(paths, names, bank: bank, stores: stores)
        try People.refreshRecognition(outputDir: root, bank: bank, stores: stores)
    }

    /// test_exchange.py's `imported_with_voices`: an imported meeting whose voices were said yes to, but whose names
    /// are still the sender's hints.
    func importedWithVoices(invited: [String], talk: [(String, Double)], hint: [(String, String)]) -> RecordingPaths {
        let paths = RecordingPaths(root.appendingPathComponent("2026-10-29T10-00-00", isDirectory: true))
        try! FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        write(paths.meta, .object([("start_time", .string("2026-10-29T10:00:00+01:00")), ("duration_seconds", .int(600))]))
        var turns: [JSONValue] = [], at = 0.0
        for (label, seconds) in talk {
            turns.append(.object([("speaker", .string(label)), ("start", .double(at)), ("end", .double(at + seconds))]))
            at += seconds
        }
        write(paths.systemTurns, .array(turns))
        write(paths.transcriptJson, .array(turns.map {
            .object([("speaker", $0["speaker"]!), ("start", $0["start"]!), ("end", $0["end"]!), ("text", .string("Hallo."))])
        }))
        // Python draws 64 random numbers per voice: far apart. Axes are as far apart, and the same on every Mac.
        write(paths.speakerEmbeddings, .object(talk.enumerated().map { i, t in
            (t.0, .array((0..<8).map { .double($0 == i ? 1 : 0) }))
        }))
        let attendees: [JSONValue] = invited.map { .object([("name", .string($0)), ("email", .string("\($0.prefix(1))@x"))]) }
            + [.object([("name", .string("Timo")), ("is_self", .bool(true))])]
        write(paths.calendar, .object([
            ("title", .string("Budget review")), ("start", .string("2026-10-29T10:00:00+01:00")), ("end", .string("2026-10-29T10:30:00+01:00")),
            ("uid", .string("ABC-123")), ("series", .bool(true)), ("location", .string("Teams")), ("attendees", .array(attendees)),
            ("link", .object([("source", .string("calendar")), ("confidence", .double(0.9)), ("reason", .string("time match"))])),
        ]))
        write(paths.imported, .object([("from", .string("Anna")), ("names", .object(hint.map {
            ($0.0, .object([("name", .string($0.1)), ("how", .string("hand"))]))
        }))]))
        return paths
    }
}

@Suite struct InferenceTests {
    static let ANNA = PeopleRoot.unit(1, 0, 0, 0), BEN = PeopleRoot.unit(0, 1, 0, 0)
    static let CARL = PeopleRoot.unit(0, 0, 1, 0), DORA = PeopleRoot.unit(0, 0, 0, 1)

    private func entry(_ paths: RecordingPaths, _ label: String) -> JSONValue? { Inference.load(paths)[label] }

    @Test func test_a_one_on_one_names_the_other_voice() throws {
        let r = PeopleRoot(); defer { r.remove() }
        let m = r.inferMeeting("2026-10-20T10-00-00", [("SPEAKER_00", Self.ANNA, 600), ("SPEAKER_01", Self.BEN, 12)], ["Anna Huber"])
        #expect(try r.refresh() == 1)
        let i = try #require(entry(m, "SPEAKER_00"))
        #expect(i["name"]?.stringValue == "Anna Huber" && i["rule"]?.stringValue == "calendar" && i["confidence"]?.doubleValue == 0.9)
        #expect(i["why"]?.stringValue?.contains("Only Anna Huber was invited") == true)
        #expect(r.names(m)["SPEAKER_00"] == "Anna Huber")
        #expect(try r.refresh() == 0)  // nothing new
    }

    @Test func test_a_room_of_several_people_is_never_inferred_to_be_someone() throws {
        let r = PeopleRoot(); defer { r.remove() }
        let m = r.inferMeeting("2026-10-20T10-00-00", [("SPEAKER_00", Self.ANNA, 600), ("SPEAKER_01", Self.BEN, 12)], ["Anna Huber"])
        try SharedMic.save(m, PyDict([("lanes", .object([("SPEAKER_00", .string("Lab"))]))]))  // set_lane(m, "SPEAKER_00", True, "Lab")
        _ = try r.refresh()
        #expect(Inference.load(m).isEmpty)
        #expect(r.names(m)["SPEAKER_00"] == "SPEAKER_00")  // rewritten only when an inference changes
    }

    @Test func test_a_room_in_the_meeting_leaves_nobody_to_eliminate() throws {
        // Anna may be in the room: the other voice is not her by elimination.
        let r = PeopleRoot(); defer { r.remove() }
        let m = r.inferMeeting("2026-10-20T10-00-00", [("SPEAKER_00", Self.ANNA, 600), ("SPEAKER_01", Self.BEN, 600)], ["Anna Huber"])
        try SharedMic.save(m, PyDict([("lanes", .object([("SPEAKER_00", .string(""))]))]))  // set_lane(m, "SPEAKER_00", True)
        _ = try r.refresh()
        #expect(Inference.load(m).isEmpty)
        try SharedMic.save(m, PyDict([("mic", .string(""))]))  // the lane one voice again; several people at the microphone
        _ = try r.refresh()
        #expect(Inference.load(m).isEmpty)
    }

    @Test func test_no_guess_when_the_calendar_does_not_say_enough() throws {
        let r = PeopleRoot(); defer { r.remove() }
        let twoVoices = r.inferMeeting("2026-10-20T10-00-00", [("SPEAKER_00", Self.ANNA, 600), ("SPEAKER_01", Self.BEN, 300)], ["Anna Huber"])
        let aRoom = r.inferMeeting("2026-10-21T10-00-00", [("SPEAKER_00", Self.CARL, 600)], ["Carl Berg"], room: true)
        let split = r.inferMeeting("2026-10-22T10-00-00",  // 25 s of another voice: maybe Dora split in two
                                   [("SPEAKER_00", Self.DORA, 100), ("SPEAKER_01", PeopleRoot.unit(0.1, 0.2, 0.3, 1), 25)], ["Dora Klein"])
        _ = try r.refresh()
        #expect([twoVoices, aRoom, split].allSatisfy { Inference.load($0).isEmpty })
    }

    @Test func test_elimination_rests_on_names_and_falls_with_them() throws {
        let r = PeopleRoot(); defer { r.remove() }
        let m = r.inferMeeting("2026-10-20T10-00-00", [("SPEAKER_00", Self.ANNA, 300), ("SPEAKER_01", Self.BEN, 300)], ["Anna Huber", "Ben Weiss"])
        try r.nameSpeaker(m, "SPEAKER_00", "Anna Huber")
        let i = try #require(entry(m, "SPEAKER_01"))
        #expect(i["name"]?.stringValue == "Ben Weiss" && i["rule"]?.stringValue == "elimination")
        #expect(i["depends"] == .strings(["2026-10-20T10-00-00:SPEAKER_00"]))
        #expect(i["confidence"]?.doubleValue == 0.85)

        try r.nameSpeaker(m, "SPEAKER_00", "")  // Anna unnamed again
        #expect(Inference.load(m).isEmpty)
        #expect(r.names(m)["SPEAKER_01"] == "SPEAKER_01")
    }

    @Test func test_an_inferred_voice_names_itself_elsewhere_and_a_rejection_takes_it_all_back() throws {
        let r = PeopleRoot(); defer { r.remove() }
        let oneOnOne = r.inferMeeting("2026-10-20T10-00-00", [("SPEAKER_00", Self.ANNA, 600)], ["Anna Huber"])
        let group = r.inferMeeting("2026-10-21T10-00-00", [("SPEAKER_00", Self.BEN, 300), ("SPEAKER_01", PeopleRoot.unit(1, 0.1, 0, 0), 300)],
                                   ["Anna Huber", "Ben Weiss"])
        _ = try r.refresh()
        let voice = try #require(entry(group, "SPEAKER_01"))
        #expect(voice["name"]?.stringValue == "Anna Huber" && voice["rule"]?.stringValue == "voice")
        #expect(voice["depends"] == .strings(["2026-10-20T10-00-00:SPEAKER_00"]))
        let ben = try #require(entry(group, "SPEAKER_00"))
        #expect(ben["name"]?.stringValue == "Ben Weiss" && ben["rule"]?.stringValue == "elimination")
        #expect(ben["depends"] == .strings(["2026-10-21T10-00-00:SPEAKER_01"]))
        #expect(ben["confidence"]?.doubleValue == Py.round(0.85 * 0.9 * 0.9, 3))

        // "That is not Anna": the 1:1 guess goes, and with it all that followed.
        try r.nameSpeaker(oneOnOne, "SPEAKER_00", "")
        #expect(Inference.load(oneOnOne).isEmpty && Inference.load(group).isEmpty)
        // Not Anna, rather than nobody: another name may still fit this voice (#48).
        #expect(PythonJSON.read(oneOnOne.speakersRejected).map { PythonJSON.dumps($0) } == #"{"SPEAKER_00": ["Anna Huber"]}"#)
        #expect(PythonJSON.read(oneOnOne.speakers) == .object([]))
    }

    @Test func test_a_recurring_voice_is_the_invitee_its_meetings_share() throws {
        let r = PeopleRoot(); defer { r.remove() }
        let a = r.inferMeeting("2026-10-20T10-00-00", [("SPEAKER_00", Self.CARL, 300), ("SPEAKER_01", Self.BEN, 300)], ["Carl Berg", "Ben Weiss"])
        let b = r.inferMeeting("2026-10-21T10-00-00", [("SPEAKER_00", PeopleRoot.unit(0.05, 0, 1, 0), 300), ("SPEAKER_01", Self.DORA, 300)],
                               ["Carl Berg", "Dora Klein"])
        _ = try r.refresh()
        #expect(entry(a, "SPEAKER_00")?["rule"]?.stringValue == "intersection")
        #expect(entry(a, "SPEAKER_00")?["name"]?.stringValue == "Carl Berg" && entry(b, "SPEAKER_00")?["name"]?.stringValue == "Carl Berg")
        // ... and then the rest by elimination
        #expect(entry(a, "SPEAKER_01")?["name"]?.stringValue == "Ben Weiss")
        #expect(entry(b, "SPEAKER_01")?["name"]?.stringValue == "Dora Klein")
    }

    /// The domain half: the window's lane (`get_meeting`) is api.py's, ported with it.
    @Test func test_the_window_shows_inferred_names_and_confirming_makes_them_facts() throws {
        let r = PeopleRoot(); defer { r.remove() }
        let m = r.inferMeeting("2026-10-20T10-00-00", [("SPEAKER_00", Self.ANNA, 600)], ["Anna Huber"])
        _ = try r.refresh()
        #expect(try Speakers.namesInEffect(m)["SPEAKER_00"] == "Anna Huber")
        #expect(entry(m, "SPEAKER_00")?["rule"]?.stringValue == "calendar")

        try r.nameSpeaker(m, "SPEAKER_00", "Anna Huber")  // ✓
        #expect(try Speakers.loadSpeakerNames(m)["SPEAKER_00"] == "Anna Huber")
        #expect(Inference.load(m).isEmpty)  // a fact now, no longer inferred
        #expect(try r.bank.names() == PyDict([("Anna Huber", 1)]))  // now in the voice bank
    }

    // test_attribution.py
    @Test func test_inference_blocks_a_voice_like_a_rejected_one_only_when_more_alike_than_the_person() throws {
        // Anna's 1:1 names her voice. In a third meeting a voice 0.95 alike hers is 0.80 alike a voice rejected as Anna:
        // more like Anna than like the rejected one, so still Anna (alike = max(0.75, sim), as recognition decides).
        let r = PeopleRoot(); defer { r.remove() }
        let anna = PeopleRoot.unit(1, 0, 0), rejected = PeopleRoot.unit(0.572, 0.820, 0), thirdVoice = PeopleRoot.unit(0.95, 0.312, 0)
        let toThird = try VoiceMath.dot(rejected, thirdVoice), toAnna = try VoiceMath.dot(rejected, anna)
        #expect(abs(toThird - 0.80) <= 0.01 && toAnna < 0.75)
        let one = r.inferMeeting("2026-10-20T10-00-00", [("SPEAKER_00", anna, 600)], ["Anna Huber"])
        let other = r.inferMeeting("2026-10-21T10-00-00", [("SPEAKER_00", rejected, 600)], ["Bob Weiss"])
        r.write(other.speakersRejected, .object([("SPEAKER_00", .strings(["Anna Huber"]))]))
        let third = r.inferMeeting("2026-10-22T10-00-00", [("SPEAKER_00", thirdVoice, 600), ("SPEAKER_01", PeopleRoot.unit(0, 0, 1), 600)],
                                   ["Anna Huber", "Carl Berg"])
        _ = try r.refresh()
        #expect(entry(one, "SPEAKER_00")?["name"]?.stringValue == "Anna Huber")
        #expect(entry(third, "SPEAKER_00")?["name"]?.stringValue == "Anna Huber")
    }

    // test_exchange.py: the domain half (the import itself is Task 25's): an import leaves its hints in
    // speakers_inferred.json and its voices waiting (no speaker_embeddings.json); inference keeps them.
    @Test func test_inference_keeps_the_hints_of_an_import() throws {
        let r = PeopleRoot(); defer { r.remove() }
        let paths = r.importedWithVoices(invited: ["Tom Lang"], talk: [("SPEAKER_00", 18), ("SPEAKER_01", 19)], hint: [("SPEAKER_00", "Tom")])
        try FileManager.default.removeItem(at: paths.speakerEmbeddings)
        try PythonJSON.write(ExchangeHints.hints(paths).json, to: paths.speakersInferred, indent: 2, ensureAscii: false)
        _ = try r.refresh(userName: "Timo")
        #expect(entry(paths, "SPEAKER_00")?["rule"]?.stringValue == "imported")
    }

    @Test func test_a_hinted_name_counts_as_known_for_the_rules() throws {
        let r = PeopleRoot(); defer { r.remove() }
        let paths = r.importedWithVoices(invited: ["Tom Lang", "Carla Diaz"], talk: [("SPEAKER_00", 60), ("SPEAKER_01", 60)],
                                         hint: [("SPEAKER_00", "Tom Lang")])
        _ = try r.refresh(userName: "Timo")
        #expect(entry(paths, "SPEAKER_00")?["rule"]?.stringValue == "imported")
        #expect(entry(paths, "SPEAKER_01")?["name"]?.stringValue == "Carla Diaz" && entry(paths, "SPEAKER_01")?["rule"]?.stringValue == "elimination")
    }

    @Test func test_no_rule_gives_a_hinted_name_to_a_second_lane() throws {
        let r = PeopleRoot(); defer { r.remove() }
        let paths = r.importedWithVoices(invited: ["Tom Lang"], talk: [("SPEAKER_00", 15), ("SPEAKER_01", 100)], hint: [("SPEAKER_00", "Tom Lang")])
        _ = try r.refresh(userName: "Timo")
        #expect(Inference.load(paths).keys == ["SPEAKER_00"])
    }

    @Test func hintsSayWhoNamedThemAndHow() throws {
        let r = PeopleRoot(); defer { r.remove() }
        let paths = RecordingPaths(r.root.appendingPathComponent("2026-10-30T10-00-00", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        #expect(ExchangeHints.hints(paths).isEmpty && ExchangeHints.loadRecord(paths) == nil)
        r.write(paths.imported, .array([]))
        #expect(ExchangeHints.loadRecord(paths) == nil)
        r.write(paths.imported, .object([("from", .string("Valerie")), ("names", .object([
            ("SPEAKER_00", .object([("name", .string("Valerie")), ("how", .string("exporter"))])),
            ("SPEAKER_01", .object([("name", .string("Timo Strauß")), ("how", .string("voice"))])),
            ("SPEAKER_02", .object([("name", .string("Carla")), ("how", .string("guessed"))])),
            ("SPEAKER_03", .object([("name", .string(""))])),
            ("SPEAKER_04", .string("Anna")),
            ("SPEAKER_05", .object([("name", .string("Anna")), ("how", .string("hand"))])),
        ]))]))
        #expect(PythonJSON.dumps(ExchangeHints.hints(paths).json, ensureAscii: false) == """
            {"SPEAKER_00": {"name": "Valerie", "rule": "imported", "why": "Valerie's own microphone in their recording.", \
            "confidence": 1.0, "depends": [], "by": "Valerie", "how": "exporter"}, "SPEAKER_01": {"name": "Timo Strauß", "rule": \
            "imported", "why": "Valerie's Palaver recognized the voice.", "confidence": 0.8, "depends": [], "by": "Valerie", "how": \
            "voice"}, "SPEAKER_02": {"name": "Carla", "rule": "imported", "why": "Valerie's Palaver inferred the name.", \
            "confidence": 0.6, "depends": [], "by": "Valerie", "how": "inferred"}, "SPEAKER_05": {"name": "Anna", "rule": "imported", \
            "why": "Named by Valerie in their recording.", "confidence": 0.9, "depends": [], "by": "Valerie", "how": "hand"}}
            """)
        r.write(paths.imported, .object([("from", .null), ("names", .object([("SPEAKER_00", .object([("name", .string("Tom"))]))]))]))
        #expect(ExchangeHints.hints(paths)["SPEAKER_00"]?["by"]?.stringValue == "the sender")
    }

    @Test func everyWriterWaitsForTheMeetingsLock() throws {
        let r = PeopleRoot(); defer { r.remove() }
        // Inference writes speakers_inferred.json, recognition speakers_auto.json, renaming speakers_rejected.json.
        let m = r.inferMeeting("2026-10-20T10-00-00", [("SPEAKER_00", Self.ANNA, 600)], ["Anna Huber"])
        let known = r.inferMeeting("2026-10-21T10-00-00", [("SPEAKER_00", Self.BEN, 600)], [])
        try r.bank.add("Ben Weiss", Self.BEN, source: "2026-10-01T10-00-00:SPEAKER_00")
        r.write(m.speakersRejected, .object([("SPEAKER_01", .strings(["Ben"]))]))
        let writers: [(String, URL, () throws -> Void)] = [
            ("inference", m.folder, { _ = try r.refresh() }),
            ("recognition", known.folder, { try People.refreshRecognition(outputDir: r.root, bank: r.bank, stores: r.stores) }),
            ("rename", m.folder, { try People.renamePerson(outputDir: r.root, old: "Ben", new: "Ben Weiss", bank: r.bank, stores: r.stores) }),
        ]
        for (what, folder, write) in writers {
            let held = try LockHolder(folder.appendingPathComponent(".speakers.lock"), seconds: 0.4)
            let start = Date()
            try write()
            #expect(Date().timeIntervalSince(start) >= 0.3, "\(what) did not wait for the meeting's lock")
            held.wait()
        }
        #expect(Inference.load(m)["SPEAKER_00"]?["name"]?.stringValue == "Anna Huber")
        #expect(PythonJSON.read(known.speakersAuto)?["SPEAKER_00"]?["name"]?.stringValue == "Ben Weiss")
        #expect(PythonJSON.read(m.speakersRejected) == .object([("SPEAKER_01", .strings(["Ben Weiss"]))]))
    }
}
