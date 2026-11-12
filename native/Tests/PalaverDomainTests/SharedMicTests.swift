// Speakers that can't be separated (shared_mic.py, test_shared_mic.py): the marks and their setters, the series memory,
// the signals and the suggestion, and the marks as names, transcripts and the voice bank read them. The tests of
// test_shared_mic.py that run through people, the window's api, the coach, notes, the CLI or the MCP server are in the
// ledger (skipped lines).
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct SharedMicTests {
    /// test_shared_mic.py's `_paths`: three voices on the system track.
    private func meeting(_ name: String = "2026-10-27T16-03-07") -> SpeakerMeeting {
        let m = SpeakerMeeting(name)
        m.write(m.paths.systemTurns, SpeakerMeeting.turns([("SPEAKER_00", 0, 30), ("SPEAKER_01", 31, 60), ("SPEAKER_02", 61, 62)]))
        return m
    }

    /// test_people.py's `_meeting` with ANNA and BEN (`_bank_meeting`): a processed recording, 60 s each.
    private func bankMeeting() -> SpeakerMeeting {
        let m = SpeakerMeeting("2026-10-20T10-00-00")
        m.write(m.paths.meta, .object([("start_time", .string("2026-10-27T10:00:00+01:00")), ("duration_seconds", .int(600))]))
        m.write(m.paths.systemTurns, SpeakerMeeting.turns([("SPEAKER_00", 1, 61), ("SPEAKER_01", 61, 121)]))
        m.write(m.paths.transcriptJson, .array([SpeakerMeeting.line("Timo", 0, 1, "Hi."), SpeakerMeeting.line("SPEAKER_00", 1, 61, "I am SPEAKER_00."),
                                                 SpeakerMeeting.line("SPEAKER_01", 61, 121, "I am SPEAKER_01.")]))
        m.write(m.paths.speakerEmbeddings, .object([("SPEAKER_00", .array([.double(1), .double(0), .double(0), .double(0)])),
                                                    ("SPEAKER_01", .array([.double(0), .double(1), .double(0), .double(0)]))]))
        return m
    }

    /// test_people.py's `_names_in`: label (or speaker) → the name the transcript shows.
    private func namesIn(_ m: SpeakerMeeting) -> [String: String] {
        var out: [String: String] = [:]
        for u in m.read(m.paths.transcriptJson)?.arrayValue ?? [] {
            out[u["label"]?.stringValue ?? u["speaker"]!.stringValue!] = u["speaker"]!.stringValue!
        }
        return out
    }

    private func markLane(_ m: SpeakerMeeting, _ label: String, _ name: String? = nil) throws {
        try SharedMic.setLane(m.paths, label, true, name: name)
    }

    private func markMeeting(_ m: SpeakerMeeting, _ on: Bool) throws { try SharedMic.setMeeting(m.paths, on) }

    private static let start = try! PyDateTime.parse("2026-10-27T16:00:00+01:00")

    /// test_shared_mic.py's `_event`.
    private func event(_ title: String = "Weekly", invited: Int = 2, room: Bool = false, location: String = "",
                       uid: String = "abc", series: Bool = false) -> CalendarEvent {
        let people = (0..<invited).map { Attendee(name: "Person \($0)") }
        let rooms = room ? [Attendee(name: "Raum 3.12", isRoom: true)] : []
        return CalendarEvent(title: title, start: Self.start, end: Self.start.adding(micros: 3_600_000_000),
                             attendees: people + rooms + [Attendee(name: "Timo", isSelf: true)], uid: uid, series: series, location: location)
    }

    @Test func test_a_meeting_without_a_mark_shows_every_voice_as_itself() {
        let m = meeting(); defer { m.remove() }
        #expect(SharedMic.display(m.paths).isEmpty)
        #expect(!SharedMic.meetingMarked(m.paths))
        #expect(!FileManager.default.fileExists(atPath: m.paths.speakersShared.path))
    }

    @Test func test_a_whole_meeting_mark_makes_every_remote_voice_several_people() throws {
        let m = meeting(); defer { m.remove() }
        try markMeeting(m, true)
        #expect(SharedMic.display(m.paths) == PyDict(["SPEAKER_00", "SPEAKER_01", "SPEAKER_02"].map { ($0, "Several people") }))
        try markMeeting(m, false)
        #expect(SharedMic.display(m.paths).isEmpty)
    }

    @Test func test_a_voice_merged_into_a_room_is_the_room_too() throws {
        let m = meeting(); defer { m.remove() }
        m.write(m.paths.speakersMerged, .object([("SPEAKER_02", .string("SPEAKER_01"))]))
        try markLane(m, "SPEAKER_01", "Lab")
        #expect(SharedMic.display(m.paths) == PyDict([("SPEAKER_01", "Room (Lab)"), ("SPEAKER_02", "Room (Lab)")]))
    }

    @Test func test_a_room_keeps_no_name_and_its_lines_show_the_room() throws {
        let m = bankMeeting(); defer { m.remove() }
        m.write(m.paths.speakersAuto, .object([("SPEAKER_01", .object([("name", .string("Ben")), ("similarity", .double(0.9))]))]))
        m.write(m.paths.speakersInferred, .object([("SPEAKER_00", .object([("name", .string("Anna")), ("rule", .string("only")),
                                                                           ("why", .string("")), ("confidence", .double(0.8))]))]))
        try markLane(m, "SPEAKER_01", "Lab")
        try m.save([])
        #expect(try Speakers.namesInEffect(m.paths) == PyDict([("SPEAKER_00", "Anna")]))  // the auto name on the room no longer counts
        #expect(namesIn(m) == ["Timo": "Timo", "SPEAKER_00": "Anna", "SPEAKER_01": "Room (Lab)"])
    }

    @Test func test_a_whole_meeting_mark_names_nobody_on_the_system_track() throws {
        let m = bankMeeting(); defer { m.remove() }
        try markMeeting(m, true)
        try m.save([("SPEAKER_00", "Anna")])
        #expect(try Speakers.namesInEffect(m.paths).isEmpty)
        #expect(namesIn(m) == ["Timo": "Timo", "SPEAKER_00": "Several people", "SPEAKER_01": "Several people"])
        try markMeeting(m, false)  // the name given by hand comes back
        try m.save([("SPEAKER_00", "Anna")])
        #expect(try Speakers.namesInEffect(m.paths) == PyDict([("SPEAKER_00", "Anna")]))
    }

    @Test func test_a_room_never_teaches_the_voice_bank() throws {
        let m = bankMeeting(); defer { m.remove() }
        try m.save([("SPEAKER_01", "Ben")])
        #expect(try m.bank.names()["Ben"] != nil)
        try markLane(m, "SPEAKER_01")
        try m.save([("SPEAKER_01", "Ben")])
        #expect(try m.bank.names()["Ben"] == nil)  // what it taught before is taken back
    }

    @Test func test_a_lane_marked_as_a_room_shows_as_the_room() throws {
        let m = meeting(); defer { m.remove() }
        try SharedMic.setLane(m.paths, "SPEAKER_01", true, name: "Raum 3.12")
        try SharedMic.setLane(m.paths, "SPEAKER_02", true)
        #expect(SharedMic.display(m.paths) == PyDict([("SPEAKER_01", "Room (Raum 3.12)"), ("SPEAKER_02", "Room")]))
        #expect(SharedMic.roomNames(m.paths) == PyDict([("SPEAKER_01", "Raum 3.12"), ("SPEAKER_02", "")]))

        try SharedMic.setLane(m.paths, "SPEAKER_01", false)
        try SharedMic.setLane(m.paths, "SPEAKER_02", false)
        #expect(SharedMic.display(m.paths).isEmpty && !SharedMic.marked(m.paths))
        try SharedMic.setLane(m.paths, "SPEAKER_01", true)  // marked again: the room's name comes back
        #expect(SharedMic.display(m.paths) == PyDict([("SPEAKER_01", "Room (Raum 3.12)")]))
        try SharedMic.setLane(m.paths, "SPEAKER_02", true, name: " " + String(repeating: "x", count: 100))
        #expect(SharedMic.roomNames(m.paths)["SPEAKER_02"] == String(repeating: "x", count: SharedMic.NAME_LENGTH))
    }

    @Test func test_a_remembered_series_marks_its_next_meetings() throws {
        let later = meeting("2026-11-24T16-00-00"); defer { later.remove() }
        let e = event("All Hands", uid: "series-1/RID=2026-10-27", series: true)
        #expect(SharedMic.canRemember(e))
        #expect(!SharedMic.remembered(e, stores: later.stores))
        try SharedMic.remember(e, true, stores: later.stores)
        #expect(SharedMic.remembered(event("All Hands", uid: "series-1/RID=2026-11-24", series: true), stores: later.stores))

        #expect(try SharedMic.applySeries(later.paths, event: e, stores: later.stores))
        #expect(SharedMic.meetingMarked(later.paths))

        try SharedMic.remember(e, false, stores: later.stores)
        #expect(!SharedMic.remembered(e, stores: later.stores))
    }

    @Test func test_a_meeting_the_user_unmarked_stays_unmarked_for_its_series() throws {
        let m = meeting(); defer { m.remove() }
        let e = event("All Hands", series: true)
        try SharedMic.remember(e, true, stores: m.stores)
        try SharedMic.setMeeting(m.paths, false)
        #expect(try !SharedMic.applySeries(m.paths, event: e, stores: m.stores))
        #expect(!SharedMic.meetingMarked(m.paths))
    }

    @Test func test_a_single_event_cannot_be_remembered() {
        #expect(!SharedMic.canRemember(event("All Hands", series: false)))
        #expect(!SharedMic.canRemember(nil))
    }

    @Test func test_an_all_hands_in_the_calendar_suggests_the_mark() throws {
        let m = meeting(); defer { m.remove() }
        let found = try SharedMic.signals(m.paths, event: event("Company All-Hands October"))
        #expect(found.gathering && !found.room)
        let why = try #require(try SharedMic.suggestion(m.paths, event: event("Company All-Hands October")))
        #expect(why.contains("All-Hands") && why == "The calendar calls it \u{201C}Company All-Hands October\u{201D}.")
    }

    @Test func test_a_room_with_many_invitees_but_few_voices_suggests_the_mark() throws {
        let m = meeting(); defer { m.remove() }
        let e = event("Sprint review", invited: 12, room: true)
        let found = try SharedMic.signals(m.paths, event: e)
        #expect(PythonJSON.dumps(found.json) == #"{"gathering": false, "room": true, "invitees": 12, "voices": 2, "few_voices": true}"#)
        #expect(try SharedMic.suggestion(m.paths, event: e)
                == "A meeting room was booked, and 12 people were invited but only 2 voices were heard.")
    }

    @Test func test_a_meeting_room_alone_is_no_reason_to_suggest() throws {
        let m = meeting(); defer { m.remove() }
        #expect(try SharedMic.suggestion(m.paths, event: event("Sprint review", invited: 3, room: true)) == nil)
        #expect(try SharedMic.suggestion(m.paths, event: event("Sprint review", invited: 3, location: "Raum 3.12")) == nil)
    }

    @Test func test_many_quiet_invitees_alone_are_no_reason_to_suggest() throws {
        let m = meeting(); defer { m.remove() }  // a webinar: many invited, one or two speak
        #expect(try SharedMic.suggestion(m.paths, event: event("Webinar", invited: 30)) == nil)
    }

    @Test func test_a_room_in_the_location_counts_as_a_room() throws {
        let m = meeting(); defer { m.remove() }
        #expect(try SharedMic.signals(m.paths, event: event("Review", invited: 12, location: "Besprechungsraum Attakring")).room)
    }

    @Test func test_a_dismissed_or_marked_meeting_is_not_suggested_again() throws {
        let m = meeting(); defer { m.remove() }
        let e = event("All Hands")
        try SharedMic.dismissSuggestion(m.paths, true)
        #expect(try SharedMic.suggestion(m.paths, event: e) == nil)
        try SharedMic.dismissSuggestion(m.paths, false)
        #expect(try SharedMic.suggestion(m.paths, event: e) != nil)
        try SharedMic.setLane(m.paths, "SPEAKER_00", true)
        #expect(try SharedMic.suggestion(m.paths, event: e) == nil)
    }

    @Test func test_a_meeting_without_an_event_has_no_suggestion() throws {
        let m = meeting(); defer { m.remove() }
        #expect(try SharedMic.suggestion(m.paths, event: nil) == nil)
        #expect(try SharedMic.signals(m.paths, event: nil).invitees == 0)
    }

    @Test func test_a_room_is_not_recognized_suggested_or_an_unknown_recurring_voice() throws {
        let r = PeopleRoot(); defer { r.remove() }
        let anna = PeopleTests.ANNA, ben = PeopleTests.BEN
        let first = r.meeting("2026-10-20T10-00-00", [("SPEAKER_00", anna, 60), ("SPEAKER_01", ben, 60)])
        let second = r.meeting("2026-10-27T10-00-00", [("SPEAKER_00", anna, 60), ("SPEAKER_01", ben, 60)])
        #expect(try r.directory()["unknown"]?.arrayValue?.count == 2)  // Anna and Ben recur
        try SharedMic.setLane(first, "SPEAKER_01", true)
        try SharedMic.setLane(second, "SPEAKER_01", true)
        #expect(try r.directory()["unknown"]?.arrayValue?.count == 1)

        try r.bank.add("Ben", ben, source: "elsewhere:SPEAKER_05")
        try r.nameVoices([("2026-10-20T10-00-00", "SPEAKER_00")], "Anna")
        #expect(r.names(second)["SPEAKER_00"] == "Anna")
        #expect(r.names(second)["SPEAKER_01"] == "Room")
        #expect(PythonJSON.read(second.speakersAuto)?["SPEAKER_01"] == nil)
        try r.bank.add("Bert", [0.7, 0.71, 0, 0], source: "elsewhere:SPEAKER_06")
        #expect(try People.suggestions(second, bank: r.bank, stores: r.stores).isEmpty)
    }

    // MARK: - beyond test_shared_mic.py: the microphone, merges and the file

    @Test func test_the_mic_lines_show_the_room_while_several_people_sat_at_it() throws {
        let m = bankMeeting(); defer { m.remove() }
        #expect(SharedMic.micRoom(m.paths) == nil && SharedMic.micDisplay(m.paths) == nil && !SharedMic.marked(m.paths))
        var data = SharedMic.load(m.paths)
        data["mic"] = .string("")
        try SharedMic.save(m.paths, data)
        #expect(SharedMic.micRoom(m.paths) == "" && SharedMic.micDisplay(m.paths) == "Room (with you)" && SharedMic.marked(m.paths))
        try m.save([])
        let md = m.markdown()
        #expect(md.contains("**Room (with you)** [10:00:00]  Hi.") && !md.contains("**Timo**"))
        #expect(namesIn(m)["Timo"] == "Timo")  // transcript.json keeps the microphone's lines the user's

        data["mic"] = .string("Raum 3.12")
        try SharedMic.save(m.paths, data)
        let lines = SharedMic.shown(m.paths, [Utterance(speaker: "Timo", start: 0, end: 1, text: "Hi."),
                                              Utterance(speaker: "SPEAKER_00", start: 1, end: 2, text: "Ja."),
                                              Utterance(speaker: "Anna", start: 2, end: 3, text: "Gut.", label: "SPEAKER_00")])
        #expect(lines.map(\.speaker) == ["Room (Raum 3.12)", "SPEAKER_00", "Anna"])

        // The whole meeting marked: the microphone is a room only in person (nobody on the system track).
        try SharedMic.save(m.paths, PyDict([("meeting", .bool(true))]))
        #expect(SharedMic.systemSpeech(m.paths) && SharedMic.micRoom(m.paths) == nil)
        try Speakers.setIgnored(m.paths, "SPEAKER_00")
        try Speakers.setIgnored(m.paths, "SPEAKER_01")
        #expect(!SharedMic.systemSpeech(m.paths) && SharedMic.micRoom(m.paths) == "")
    }

    @Test func test_a_room_merged_into_a_voice_makes_the_voice_the_room() throws {
        let m = bankMeeting(); defer { m.remove() }
        try markLane(m, "SPEAKER_01", "Lab")
        try m.merge("SPEAKER_01", "SPEAKER_00")
        #expect(SharedMic.roomNames(m.paths) == PyDict([("SPEAKER_01", "Lab"), ("SPEAKER_00", "Lab")]))
        #expect(try String(contentsOf: m.paths.speakersShared, encoding: .utf8)
                == "{\n  \"lanes\": {\n    \"SPEAKER_01\": \"Lab\",\n    \"SPEAKER_00\": \"Lab\"\n  }\n}")
        #expect(namesIn(m) == ["Timo": "Timo", "SPEAKER_00": "Room (Lab)", "SPEAKER_01": "Room (Lab)"])
    }

    @Test func test_the_marks_file_keeps_its_order_and_drops_what_is_empty() throws {
        let m = meeting(); defer { m.remove() }
        m.write(m.paths.speakersShared, .object([("dismissed", .bool(false)), ("names", .object([("mic", .int(0)), ("SPEAKER_09", .string("Lab"))])),
                                                 ("mic", .null), ("meeting", .bool(true)), ("extra", .array([]))]))
        let data = SharedMic.load(m.paths)
        #expect(data.keys == ["dismissed", "names", "mic", "meeting", "extra", "lanes"])
        #expect(data["mic"] == .string("") && data["names"] == .object([("mic", .string("")), ("SPEAKER_09", .string("Lab"))]))
        try SharedMic.save(m.paths, data)
        #expect(try String(contentsOf: m.paths.speakersShared, encoding: .utf8) == """
            {
              "names": {
                "mic": "",
                "SPEAKER_09": "Lab"
              },
              "mic": "",
              "meeting": true,
              "extra": []
            }
            """)
        #expect(!FileManager.default.fileExists(atPath: m.paths.speakersShared.path + ".tmp"))
        try SharedMic.save(m.paths, PyDict([("lanes", .object([])), ("dismissed", .bool(false))]))
        #expect(!FileManager.default.fileExists(atPath: m.paths.speakersShared.path))
        #expect(SharedMic.roomText("  ") == "Room" && SharedMic.roomText("Raum 3.12") == "Room (Raum 3.12)")
    }

    @Test func test_setting_marks_keeps_the_files_order_and_formats() throws {
        let m = meeting(); defer { m.remove() }
        try SharedMic.setLane(m.paths, SharedMic.MIC, true, name: "  Raum 3.12 ")
        try SharedMic.setLane(m.paths, "SPEAKER_01", true, name: "Lab")
        try SharedMic.setLane(m.paths, "SPEAKER_00", true)
        try SharedMic.setLane(m.paths, "SPEAKER_01", true, name: "Labor")  // popped and put back: last
        try SharedMic.setMeeting(m.paths, true)
        #expect(try String(contentsOf: m.paths.speakersShared, encoding: .utf8) == """
            {
              "mic": "Raum 3.12",
              "lanes": {
                "SPEAKER_00": "",
                "SPEAKER_01": "Labor"
              },
              "meeting": true
            }
            """)
        #expect(!FileManager.default.fileExists(atPath: m.paths.speakersShared.path + ".tmp"))
        try SharedMic.setLane(m.paths, SharedMic.MIC, false)
        try SharedMic.setLane(m.paths, "SPEAKER_00", false)  // a room without a name leaves none behind
        #expect(SharedMic.load(m.paths)["names"] == .object([("mic", .string("Raum 3.12"))]))
        try SharedMic.forgetLanes(m.paths)  // the lanes mean other voices now; the microphone is still the microphone
        #expect(SharedMic.load(m.paths)["lanes"] == .object([]) && SharedMic.load(m.paths)["names"] == .object([("mic", .string("Raum 3.12"))]))
        try SharedMic.setMeeting(m.paths, false)
        try SharedMic.setLane(m.paths, SharedMic.MIC, true)
        #expect(SharedMic.micRoom(m.paths) == "Raum 3.12")
    }

    @Test func test_a_part_of_a_split_keeps_the_rooms_among_its_voices() throws {
        let whole = PyDict<JSONValue>([("meeting", .bool(true)), ("lanes", .object([("SPEAKER_00", .string("Lab")), ("SPEAKER_01", .string(""))])),
                                       ("names", .object([("mic", .string("Raum 3.12")), ("SPEAKER_01", .string("Annex")), ("SPEAKER_05", .string("Hall"))])),
                                       ("mic", .string("Room Z"))])
        let labels: Set<ScalarKey> = [ScalarKey("SPEAKER_01"), ScalarKey("SPEAKER_05")]
        let head = SharedMic.splitPart(whole, labels: labels, head: true)
        #expect(PythonJSON.dumps(head.json) == #"{"meeting": true, "lanes": {"SPEAKER_01": ""}, "names": {"mic": "Raum 3.12", "SPEAKER_01": "Annex", "SPEAKER_05": "Hall"}, "mic": "Room Z"}"#)
        let tail = SharedMic.splitPart(whole, labels: labels, head: false)
        #expect(PythonJSON.dumps(tail.json) == #"{"lanes": {"SPEAKER_01": ""}, "names": {"SPEAKER_01": "Annex", "SPEAKER_05": "Hall"}}"#)
        #expect(PythonJSON.dumps(SharedMic.splitPart(PyDict(), labels: labels, head: true).json) == #"{"lanes": {}, "names": {}}"#)
    }

    @Test func test_joining_marks_relabels_theirs_and_keeps_what_is_already_there() throws {
        let m = meeting(); defer { m.remove() }
        try SharedMic.setLane(m.paths, "SPEAKER_00", true, name: "Lab")
        try SharedMic.setLane(m.paths, "SPEAKER_01", true, name: "Annex")
        try SharedMic.setLane(m.paths, "SPEAKER_01", false)  // names: SPEAKER_01 → Annex
        let theirs = PyDict<JSONValue>([("lanes", .object([("SPEAKER_00", .string("Hall")), ("SPEAKER_03", .string(""))])),
                                        ("names", .object([("SPEAKER_00", .string("Old")), ("SPEAKER_01", .string("Theirs")), ("SPEAKER_04", .string("Gone"))])),
                                        ("mic", .string("Raum 3.12")), ("meeting", .bool(true)), ("from_series", .bool(true)), ("dismissed", .bool(true))])
        try SharedMic.joinFrom(m.paths, theirs, relabel: PyDict([("SPEAKER_00", "SPEAKER_07"), ("SPEAKER_04", "SPEAKER_01")]))
        #expect(try String(contentsOf: m.paths.speakersShared, encoding: .utf8) == """
            {
              "lanes": {
                "SPEAKER_00": "Lab",
                "SPEAKER_07": "Hall",
                "SPEAKER_03": ""
              },
              "names": {
                "SPEAKER_01": "Annex",
                "SPEAKER_07": "Old"
              },
              "mic": "Raum 3.12",
              "meeting": true,
              "from_series": true,
              "dismissed": true
            }
            """)
        // What the receiving part has already stays.
        try SharedMic.setMeeting(m.paths, false)
        try SharedMic.joinFrom(m.paths, theirs, relabel: PyDict())
        #expect(SharedMic.load(m.paths)["meeting"] == .bool(false) && SharedMic.load(m.paths)["from_series"] == .bool(true))  // only a key it lacks comes over
    }

    // test_shared_mic.py's tests that run `calendar_events.assign` (which calls `apply_series`).
    @Test func test_an_event_of_a_remembered_series_marks_the_meeting_it_is_linked_to() throws {
        let m = meeting(); defer { m.remove() }
        try SharedMic.remember(event("All Hands", series: true), true, stores: m.stores)
        try CalendarEvents.assign(m.paths, event("All Hands", series: true), stores: m.stores)
        #expect(SharedMic.meetingMarked(m.paths))
        let other = RecordingPaths(m.temp.url.appendingPathComponent("2026-10-28T10-00-00", isDirectory: true))
        try FileManager.default.createDirectory(at: other.folder, withIntermediateDirectories: true)
        try CalendarEvents.assign(other, event("Weekly", uid: "other", series: true), stores: m.stores)
        #expect(!SharedMic.meetingMarked(other))
    }

    @Test func test_a_mark_from_a_series_goes_when_the_meeting_gets_another_event() throws {
        let m = meeting(); defer { m.remove() }
        try SharedMic.remember(event("All Hands", series: true), true, stores: m.stores)
        try CalendarEvents.assign(m.paths, event("All Hands", series: true), stores: m.stores)
        #expect(SharedMic.meetingMarked(m.paths))
        try CalendarEvents.assign(m.paths, event("Weekly", uid: "weekly", series: true), stores: m.stores)
        #expect(!SharedMic.meetingMarked(m.paths))
        try SharedMic.setMeeting(m.paths, true)  // marked by hand: stays with any event
        try CalendarEvents.assign(m.paths, event("Retro", uid: "retro"), stores: m.stores)
        #expect(SharedMic.meetingMarked(m.paths))
    }

    @Test func test_a_series_mark_goes_when_the_event_is_no_longer_remembered() throws {
        let m = meeting(); defer { m.remove() }
        let e = event("All Hands", series: true)
        #expect(try !SharedMic.applySeries(m.paths, event: e, stores: m.stores))  // not remembered: nothing marked
        try SharedMic.remember(e, true, stores: m.stores)
        #expect(try SharedMic.applySeries(m.paths, event: e, stores: m.stores))
        #expect(SharedMic.fromSeries(m.paths))
        #expect(try SharedMic.applySeries(m.paths, event: e, stores: m.stores))  // again: still from the series
        #expect(try !SharedMic.applySeries(m.paths, event: event("Weekly", uid: "weekly", series: true), stores: m.stores))
        #expect(!FileManager.default.fileExists(atPath: m.paths.speakersShared.path))  // the mark was the file's only content
        try SharedMic.setMeeting(m.paths, true)  // marked by hand: stays with any event
        #expect(try !SharedMic.applySeries(m.paths, event: event("Retro", uid: "retro"), stores: m.stores))
        #expect(SharedMic.meetingMarked(m.paths))
        // The series file: json.dumps(indent=2, ensure_ascii=False), no temp file left, an empty series is "{}".
        #expect(try String(contentsOf: m.stores.sharedSeries, encoding: .utf8) == "{\n  \"abc\": {\n    \"title\": \"All Hands\"\n  }\n}")
        try SharedMic.remember(e, false, stores: m.stores)
        #expect(try String(contentsOf: m.stores.sharedSeries, encoding: .utf8) == "{}")
        #expect(!FileManager.default.fileExists(atPath: m.stores.sharedSeries.path + ".tmp"))
        #expect(throws: SpeakersValueError.self) { try SharedMic.remember(event("One-off"), true, stores: m.stores) }
        #expect(throws: SpeakersValueError.self) { try SharedMic.remember(nil, true, stores: m.stores) }
    }

    @Test func test_signals_throw_on_turns_they_cannot_read_and_not_on_missing_ones() throws {
        let m = meeting(); defer { m.remove() }
        m.write(m.paths.systemTurns, .array([.object([("speaker", .string("SPEAKER_00"))])]))
        #expect(throws: (any Error).self) { try SharedMic.signals(m.paths, event: nil) }
        try? FileManager.default.removeItem(at: m.paths.systemTurns)
        #expect(try SharedMic.signals(m.paths, event: nil).voices == 0)
        m.write(m.paths.systemTurns, SpeakerMeeting.turns([("SPEAKER_00", 0, 30), ("SPEAKER_01", 30, 60), ("SPEAKER_02", 60, 62)]))
        m.write(m.paths.speakersIgnored, .array([.string("SPEAKER_01")]))
        m.write(m.paths.speakersMerged, .object([("SPEAKER_02", .string("SPEAKER_00"))]))
        #expect(try SharedMic.signals(m.paths, event: nil).voices == 1)  // SPEAKER_01 was removed; SPEAKER_02 is SPEAKER_00's
    }

    @Test func test_every_mark_setter_waits_for_the_meetings_lock_and_the_series_for_its_own() throws {
        let m = meeting(); defer { m.remove() }
        let e = event("All Hands", series: true)
        let writers: [(String, () throws -> Void)] = [
            ("setMeeting", { try SharedMic.setMeeting(m.paths, true) }),
            ("setLane", { try SharedMic.setLane(m.paths, "SPEAKER_00", true) }),
            ("forgetLanes", { try SharedMic.forgetLanes(m.paths) }),
            ("joinFrom", { try SharedMic.joinFrom(m.paths, PyDict(), relabel: PyDict()) }),
            ("dismissSuggestion", { try SharedMic.dismissSuggestion(m.paths) }),
            ("applySeries", { _ = try SharedMic.applySeries(m.paths, event: e, stores: m.stores) }),
        ]
        for (what, write) in writers {
            let held = try LockHolder(m.paths.folder.appendingPathComponent(".speakers.lock"), seconds: 0.4)
            let began = Date()
            try write()
            #expect(Date().timeIntervalSince(began) >= 0.3, "\(what) did not wait for the meeting's lock")
            held.wait()
        }
        let held = try LockHolder(m.stores.configDir.appendingPathComponent("shared-series.json.lock"), seconds: 0.4)
        let began = Date()
        try SharedMic.remember(e, true, stores: m.stores)
        #expect(Date().timeIntervalSince(began) >= 0.3, "remember did not wait for the series' lock")
        held.wait()
    }

    // MARK: - Swift only

}
