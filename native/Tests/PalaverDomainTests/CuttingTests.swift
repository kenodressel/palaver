// Splitting and joining recordings (cutting.py, test_cutting.py, #40), the silence and cut suggestions, and the join's
// backup (a join that fails or is killed half-way). The tests of test_cutting.py that run through the window's api are
// in the ledger (skipped lines); their cutting halves are here.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct CuttingTests {
    private static let SR = 16_000
    private static let T0 = try! PyDateTime.parse("2026-10-21T15:34:00+02:00")
    private static let ANNA = [1.0, 0.0, 0.0], VALERIE = [0.0, 1.0, 0.0]

    /// test_cutting.py's `_recording`: `speakers` are (label, start, end, voice), one turn and one line each; every track
    /// sample i is i % 100. `audio: false` leaves the tracks out (the suggestions never read them).
    private func recording(_ root: URL, _ start: PyDateTime, _ seconds: Int, _ speakers: [(String, PyNum, PyNum, [Double])],
                           userLine: (PyNum, String)? = nil, audio: Bool = true) throws -> RecordingPaths {
        let name = String(start.iso.prefix(19)).replacingOccurrences(of: ":", with: "-")
        let paths = RecordingPaths(root.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        if audio {
            let tone = (0..<(seconds * Self.SR)).map { Int16($0 % 100) }
            for track in [paths.micRawWav, paths.micWav, paths.systemWav] { try Wav16.write(tone, rate: Self.SR, to: track) }
        }
        try write(paths.meta, .object([("start_time", .string(start.iso)), ("duration_seconds", .int(seconds)),
                                       ("end_time", .string(try! start.adding(seconds: Double(seconds)).iso))]))
        try write(paths.systemTurns, .array(speakers.map { .object([("speaker", .string($0.0)), ("start", $0.1.json), ("end", $0.2.json)]) }))
        try write(paths.systemSegments, .array(speakers.map { s in
            .object([("start", s.1.json), ("end", s.2.json), ("text", .string("I am \(s.0).")), ("speaker", .null),
                     ("words", .array([.object([("text", .string("I")), ("start", s.1.json), ("end", (s.1 + 0.5).json)])]))])
        }))
        try write(paths.micSegments, .array([]))
        var lines = speakers.map { s in (s.1, JSONValue.object([("speaker", .string(s.0)), ("start", s.1.json), ("end", s.2.json),
                                                               ("text", .string("I am \(s.0)."))])) }
        if let (at, text) = userLine {
            lines.append((at, .object([("speaker", .string("Timo")), ("start", at.json), ("end", (at + 2).json), ("text", .string(text))])))
        }
        try write(paths.transcriptJson, .array(Py.stableSorted(lines) { $0.0 < $1.0 }.map(\.1)))
        try write(paths.speakerEmbeddings, .object(speakers.map { ($0.0, .array($0.3.map(JSONValue.double))) }))
        return paths
    }

    private func write(_ url: URL, _ v: JSONValue) throws { try PythonJSON.write(v, to: url, indent: nil, ensureAscii: true) }
    private func read(_ url: URL) -> JSONValue? { PythonJSON.read(url) }
    private func meta(_ p: RecordingPaths) -> JSONValue { read(p.meta) ?? .null }
    private func duration(_ url: URL) throws -> Double { try Wav16.info(url).duration }
    /// Python's `==` against a JSON literal.
    private func equal(_ v: JSONValue?, _ json: String) -> Bool {
        guard let v, let want = try? PythonJSON.parse(Data(json.utf8)) else { return false }
        return PythonJSON.equal(v, want)
    }
    private func speakers(_ url: URL) -> [String] { (read(url)?.arrayValue ?? []).compactMap { $0["speaker"]?.stringValue } }
    private func spans(_ v: JSONValue?) -> [[Double]] { (v?.arrayValue ?? []).map { [$0["start"]!.doubleValue!, $0["end"]!.doubleValue!] } }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func stores(_ temp: TempFolder) -> StorePaths {
        StorePaths.current(env: ["XDG_CONFIG_HOME": temp.url.appendingPathComponent("config").path,
                                 "PALAVER_HOME": temp.url.appendingPathComponent("home").path])
    }

    private func standard(_ root: URL) throws -> RecordingPaths {
        try recording(root, Self.T0, 60, [("SPEAKER_00", 1, 30, Self.ANNA), ("SPEAKER_01", 41, 59, Self.VALERIE)])
    }

    private func later(_ seconds: Double) -> PyDateTime { try! Self.T0.adding(seconds: seconds) }

    // MARK: - split and join

    @Test func test_split_cuts_audio_data_and_names_at_the_moment() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        try write(a.speakers, .object([("SPEAKER_00", .string("Anna")), ("SPEAKER_01", .string("Valerie"))]))
        let tail = try Cutting.split(a, at: 40)

        #expect(tail.folder.lastPathComponent == "2026-10-21T15-34-40")
        #expect(try duration(a.systemWav) == 40 && duration(tail.systemWav) == 20)
        #expect(try Wav16.read(tail.micWav, frames: 3) == (0..<3).map { Int16((40 * Self.SR + $0) % 100) })  // continues where the cut was
        #expect(speakers(a.systemTurns) == ["SPEAKER_00"])
        #expect(equal(read(tail.systemTurns), #"[{"speaker": "SPEAKER_01", "start": 1.0, "end": 19.0}]"#))
        #expect(read(tail.systemSegments)?.arrayValue?[0]["words"]?.arrayValue?[0]["start"]?.doubleValue == 1.0)
        #expect(read(a.speakerEmbeddings).flatMap { PyDict<JSONValue>($0) }?.keys == ["SPEAKER_00"])
        #expect(equal(read(tail.speakers), #"{"SPEAKER_01": "Valerie"}"#))
        #expect(meta(a)["duration_seconds"]?.doubleValue == 40)
        #expect(meta(tail)["start_time"]?.stringValue == later(40).iso)
    }

    @Test func test_split_takes_the_corrected_lines_along() throws {
        // #12: what was said about a line's speaker stays with the line.
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        try Data(#"""
            [{"start": 1.0, "end": 30.0, "from": "SPEAKER_00", "name": "Timo Strauß"},
             {"start": 41.0, "end": 59.0, "from": "SPEAKER_01", "me": true, "name": "Timo"},
             {"start": "soon", "name": "a broken entry is left out"}, 7]
            """#.utf8).write(to: a.speakersLines)
        let tail = try Cutting.split(a, at: 40)
        #expect(equal(read(a.speakersLines), #"[{"start": 1.0, "end": 30.0, "from": "SPEAKER_00", "name": "Timo Strauß"}]"#))
        #expect(equal(read(tail.speakersLines), #"[{"start": 1.0, "end": 19.0, "from": "SPEAKER_01", "me": true, "name": "Timo"}]"#))
        let b = try recording(temp.url, later(62), 30, [("SPEAKER_00", 2, 28, [0.05, 1.0, 0.0])])
        let kept = try Cutting.join(tail, b)
        #expect(equal(read(kept.speakersLines), #"[{"start": 1.0, "end": 19.0, "from": "SPEAKER_01", "me": true, "name": "Timo"}]"#))
    }

    @Test func aSplitWritesWhatPythonWrites() throws {
        // An int cut keeps the tail's moved times ints; the head's are floats (+ 0.0); meta.json gains its keys in order.
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        try write(a.meta, .object([("start_time", .string(Self.T0.iso)), ("duration_seconds", .int(60)), ("stop_reason", .string("call_ended")),
                                   ("audio_problems", .array([.object([("kind", .string("speed")), ("start", .int(30)), ("end", .null)])]))]))
        let tail = try Cutting.split(a, at: 40)
        #expect(try String(contentsOf: tail.systemTurns, encoding: .utf8) == "[\n  {\n    \"speaker\": \"SPEAKER_01\",\n    \"start\": 1,\n    \"end\": 19\n  }\n]")
        #expect(try String(contentsOf: a.systemTurns, encoding: .utf8) == "[\n  {\n    \"speaker\": \"SPEAKER_00\",\n    \"start\": 1.0,\n    \"end\": 30.0\n  }\n]")
        #expect(PythonJSON.dumps(meta(a)) == #"{"start_time": "2026-10-21T15:34:00+02:00", "duration_seconds": 40, "end_time": "2026-10-21T15:34:40+02:00", "audio_problems": [{"kind": "speed", "start": 30.0, "end": 40.0}]}"#)
        #expect(PythonJSON.dumps(meta(tail)) == #"{"start_time": "2026-10-21T15:34:40+02:00", "duration_seconds": 20.0, "stop_reason": "call_ended", "trigger": "split", "audio_problems": [{"kind": "speed", "start": 0, "end": 20.0}]}"#)
    }

    @Test func aCutOutsideTheRecordingIsRefused() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        for at: PyNum in [0.5, 59.5] {
            #expect { try Cutting.split(a, at: at) } throws: { ($0 as? CuttingError)?.description == "cut between 0:01 and 1:-1" }
        }
        #expect { try Cutting.discard(a, at: 20, side: "middle") } throws: { ($0 as? CuttingError)?.description == "discard 'after' or 'before', not 'middle'" }
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path) == [a.folder.lastPathComponent])
    }

    @Test func test_join_puts_the_tail_in_front_of_the_next_meeting_and_merges_the_same_voice() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        let b = try recording(temp.url, later(62), 30, [("SPEAKER_00", 2, 28, [0.05, 1.0, 0.0])], userLine: (1.0, "Hi Valerie."))
        try write(b.speakers, .object([("SPEAKER_00", .string("Valerie"))]))
        let tail = try Cutting.split(a, at: 40)
        let kept = try Cutting.join(tail, b)

        #expect(kept.folder == b.folder)  // the longer recording keeps the meeting
        #expect(!exists(tail.folder) && exists(temp.url.appendingPathComponent(".trash/\(tail.folder.lastPathComponent)")))
        #expect(try duration(kept.systemWav) == 52)  // 20 s tail, 2 s gap, 30 s
        #expect(meta(kept)["start_time"]?.stringValue == later(40).iso && meta(kept)["duration_seconds"]?.doubleValue == 52)
        #expect(equal(read(kept.systemTurns), #"[{"speaker": "SPEAKER_01", "start": 1.0, "end": 19.0}, {"speaker": "SPEAKER_00", "start": 24.0, "end": 50.0}]"#))
        #expect(equal(read(kept.speakersMerged), #"{"SPEAKER_01": "SPEAKER_00"}"#))  // Valerie both times
        let lines = (read(kept.transcriptJson)?.arrayValue ?? []).map { "\(Int($0["start"]!.doubleValue!.rounded())) \($0["speaker"]!.stringValue!)" }
        #expect(lines == ["1 SPEAKER_01", "23 Timo", "24 SPEAKER_00"])
        #expect(!exists(kept.folder.appendingPathComponent(".join-backup")))
    }

    @Test func test_discard_what_came_after_keeps_the_meeting() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        try write(a.notes, .object([("title", .string("Sync")), ("summary", .string("x"))]))
        let gone = try Cutting.discard(a, at: 40, side: "after")

        #expect(gone.path == temp.url.appendingPathComponent(".trash/2026-10-21T15-34-40").path)
        #expect(try duration(a.systemWav) == 40 && exists(a.notes))
        #expect(speakers(a.systemTurns) == ["SPEAKER_00"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).filter { $0 != ".trash" } == [a.folder.lastPathComponent])
    }

    @Test func test_discard_what_came_before_keeps_the_meeting_where_it_is() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        try #"{"title": "Sync"}"#.write(to: a.calendar, atomically: false, encoding: .utf8)
        try Cutting.discard(a, at: 40, side: "before")

        #expect(a.folder.lastPathComponent == "2026-10-21T15-34-00")
        #expect(try String(contentsOf: a.calendar, encoding: .utf8) == #"{"title": "Sync"}"#)
        #expect(try duration(a.systemWav) == 20)
        #expect(equal(read(a.systemTurns), #"[{"speaker": "SPEAKER_01", "start": 1.0, "end": 19.0}]"#))
        #expect(meta(a)["start_time"]?.stringValue == later(40).iso)
        let trashed = RecordingPaths(temp.url.appendingPathComponent(".trash/2026-10-21T15-34-40"))
        #expect(try duration(trashed.systemWav) == 40)  // what came before, kept in the trash
    }

    @Test func aRecordingTrashedTwiceKeepsBoth() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        for want in ["2026-10-21T15-34-00", "2026-10-21T15-34-00-2", "2026-10-21T15-34-00-3"] {
            let a = try recording(temp.url, Self.T0, 5, [], audio: false)
            #expect(try Cutting.trash(a).lastPathComponent == want)
        }
    }

    // MARK: - the suggestions

    @Test func test_long_silence_before_the_first_word_and_after_the_last_is_offered_for_removal() throws {
        // A one-on-one recorded seven minutes early, and left running five minutes after.
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 1800, [("SPEAKER_00", 420, 900, Self.ANNA), ("SPEAKER_01", 900, 1500, Self.VALERIE)], audio: false)
        #expect(PythonJSON.dumps(.array(try Cutting.suggestTrim(a)))
                == #"[{"edge": "start", "at": 418.0, "seconds": 418.0}, {"edge": "end", "at": 1502.0, "seconds": 298.0}]"#)
    }

    @Test func test_a_short_quiet_start_or_end_is_left_alone() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 600, [("SPEAKER_00", 60, 300, Self.ANNA), ("SPEAKER_01", 300, 540, Self.VALERIE)], audio: false)
        #expect(try Cutting.suggestTrim(a).isEmpty)
    }

    @Test func test_silence_said_no_to_is_not_offered_again_and_the_undo_offers_it_again() throws {
        // The window's dismiss_cut(what="silence") writes the marker (its api half is the server's).
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 1800, [("SPEAKER_00", 420, 1790, Self.ANNA)], audio: false)
        try write(a.silenceDismissed, .object([]))
        #expect(try Cutting.suggestTrim(a).isEmpty)
        #expect(try Cutting.suggestCut(a, events: []) == nil)  // the other suggestion is untouched by it
        #expect(!exists(a.cutDismissed))
        try FileManager.default.removeItem(at: a.silenceDismissed)
        #expect(try Cutting.suggestTrim(a).first?["edge"]?.stringValue == "start")
    }

    private func events(_ specs: [(String, Double, Double, [String])]) -> [CalendarEvent] {
        let me = Attendee(name: "Timo Strauß", email: "timo@x.com", isSelf: true)
        return specs.map { title, s, e, people in
            CalendarEvent(title: title, start: later(s), end: later(e),
                          attendees: [me] + people.map { Attendee(name: $0, email: "\(Py.casefold($0))@x.com") }, uid: title)
        }
    }

    @Test func test_a_cut_is_suggested_where_the_next_meeting_starts_and_a_new_voice_comes_in() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 600, [("SPEAKER_00", 10, 300, Self.ANNA), ("SPEAKER_01", 420, 580, Self.VALERIE)], audio: false)
        try CalendarEvents.save(a, events([("Sync", 0, 400, ["Anna"])])[0])
        let all = events([("Sync", 0, 400, ["Anna"]), ("Checkin", 400, 900, ["Valerie"]), ("Reminder", 200, 260, [])])

        let s = try #require(try Cutting.suggestCut(a, events: all))
        #expect(s["at"]?.doubleValue == 420 && s["event"]?.stringValue == "Checkin")
        #expect(s["why"]?.stringValue == "new voice from then on: Speaker 2; Speaker 1 stopped talking")
        #expect(PythonJSON.dumps(s) == #"{"at": 420, "event": "Checkin", "event_start": "2026-10-21T15:40:40+02:00", "why": "new voice from then on: Speaker 2; Speaker 1 stopped talking"}"#)

        try write(a.cutDismissed, .object([]))
        #expect(try Cutting.suggestCut(a, events: all) == nil)
    }

    @Test func test_no_cut_is_suggested_when_the_voices_go_on() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 600, [("SPEAKER_00", 10, 590, Self.ANNA)], audio: false)
        #expect(try Cutting.suggestCut(a, events: events([("Checkin", 400, 900, ["Valerie"])])) == nil)
    }

    @Test func aCutAtAPauseNamesTheVoicesThatStopped() throws {
        // Nobody new comes in: the cut goes in the middle of the longest pause around the event's start, then to the
        // next line; a named voice is called by its name.
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 900, [("SPEAKER_00", 10, 300, Self.ANNA), ("SPEAKER_02", 500.5, 890, [0, 0, 1])], audio: false)
        try write(a.speakers, .object([("SPEAKER_00", .string("Anna"))]))
        try write(a.speakersIgnored, .array([.string("SPEAKER_02")]))
        let s = try #require(try Cutting.suggestCut(a, events: events([("Checkin", 400, 900, ["Valerie"])])))
        #expect(PythonJSON.dumps(s) == #"{"at": 500.5, "event": "Checkin", "event_start": "2026-10-21T15:40:40+02:00", "why": "Anna stopped talking"}"#)
    }

    @Test func aCalendarFileThisCodeCannotReadSuggestsNoCut() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 600, [("SPEAKER_00", 10, 300, Self.ANNA), ("SPEAKER_01", 420, 580, Self.VALERIE)], audio: false)
        try write(a.calendar, .object([("title", .int(5)), ("start", .string("x"))]))
        #expect(CalendarEvents.storedButUnreadable(a))
        #expect(try Cutting.suggestCut(a, events: events([("Checkin", 400, 900, ["Valerie"])])) == nil)
    }

    // MARK: - names, voices and marks through split and join

    @Test func test_names_a_voice_is_not_go_with_the_voice_through_split_and_join() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        let b = try recording(temp.url, later(62), 30, [("SPEAKER_00", 2, 28, [0, 0, 1])])
        try write(a.speakersRejected, .object([("SPEAKER_00", .strings(["Carla"])), ("SPEAKER_01", .strings(["Timo Strauß"]))]))
        let tail = try Cutting.split(a, at: 40)
        #expect(equal(read(a.speakersRejected), #"{"SPEAKER_00": ["Carla"]}"#))
        #expect(equal(read(tail.speakersRejected), #"{"SPEAKER_01": ["Timo Strauß"]}"#))

        try write(b.speakersRejected, .object([("SPEAKER_00", .strings(["Valerie"]))]))
        let kept = try Cutting.join(tail, b)  // b keeps its labels, the tail's are renumbered after them
        #expect(equal(read(kept.speakersRejected), #"{"SPEAKER_00": ["Valerie"], "SPEAKER_01": ["Timo Strauß"]}"#))
    }

    @Test func test_voices_nobody_knows_go_with_the_voice_through_split_and_join() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        let b = try recording(temp.url, later(62), 30, [("SPEAKER_00", 2, 28, [0, 0, 1])])
        try write(a.speakersUnknown, .strings(["SPEAKER_00", "SPEAKER_01"]))
        let tail = try Cutting.split(a, at: 40)
        #expect(read(a.speakersUnknown) == .strings(["SPEAKER_00"]))
        #expect(read(tail.speakersUnknown) == .strings(["SPEAKER_01"]))

        try write(b.speakersUnknown, .strings(["SPEAKER_00"]))
        let kept = try Cutting.join(tail, b)  // b keeps its labels, the tail's are renumbered after them
        #expect(read(kept.speakersUnknown) == .strings(["SPEAKER_00", "SPEAKER_01"]))
    }

    @Test func test_rooms_and_a_whole_meeting_mark_go_with_split_and_join() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        let b = try recording(temp.url, later(62), 30, [("SPEAKER_00", 2, 28, [0, 0, 1])])
        try SharedMic.setLane(a, "SPEAKER_01", true, name: "Lab")
        let tail = try Cutting.split(a, at: 40)
        #expect(SharedMic.roomNames(a).isEmpty && SharedMic.roomNames(tail) == PyDict([("SPEAKER_01", "Lab")]))

        try SharedMic.setMeeting(b, true)
        let kept = try Cutting.join(tail, b)  // b keeps its labels, the tail's are renumbered after them
        #expect(SharedMic.roomNames(kept) == PyDict([("SPEAKER_01", "Lab")]) && SharedMic.meetingMarked(kept))
    }

    @Test func test_a_split_leaves_the_whole_meeting_mark_with_the_head() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        try SharedMic.setMeeting(a, true)
        try SharedMic.setLane(a, SharedMic.MIC, true, name: "Lab")
        try SharedMic.dismissSuggestion(a)
        let tail = try Cutting.split(a, at: 40)
        #expect(SharedMic.meetingMarked(a) && SharedMic.micRoom(a) == "Lab" && SharedMic.load(a)["dismissed"]?.truthy == true)
        #expect(!SharedMic.meetingMarked(tail) && SharedMic.micRoom(tail) == nil)
        #expect(SharedMic.load(tail)["dismissed"]?.truthy != true)
    }

    @Test func test_discarding_the_start_keeps_the_meetings_marks_and_the_rooms_after() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        try SharedMic.setMeeting(a, true)
        try SharedMic.setLane(a, "SPEAKER_01", true, name: "Lab")
        try Cutting.discard(a, at: 40, side: "before")
        #expect(SharedMic.meetingMarked(a) && SharedMic.roomNames(a) == PyDict([("SPEAKER_01", "Lab")]))
    }

    @Test func test_a_room_merged_into_a_voice_by_hand_makes_it_the_room() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        try SharedMic.setLane(a, "SPEAKER_01", true, name: "Lab")
        let stores = stores(temp)
        try Speakers.mergeSpeakers(a, "SPEAKER_01", into: "SPEAKER_00", bank: VoiceBank(directory: stores.voices), stores: stores)
        #expect(SharedMic.roomNames(a)["SPEAKER_00"] == "Lab")
        #expect(SharedMic.display(a) == PyDict([("SPEAKER_00", "Room (Lab)"), ("SPEAKER_01", "Room (Lab)")]))
    }

    @Test func test_a_marked_voice_merged_away_still_marks_its_target_as_a_safety_net() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        try SharedMic.setLane(a, "SPEAKER_01", true, name: "Lab")
        try write(a.speakersMerged, .object([("SPEAKER_01", .string("SPEAKER_00"))]))  // merged without follow_merges
        #expect(SharedMic.display(a) == PyDict([("SPEAKER_00", "Room (Lab)"), ("SPEAKER_01", "Room (Lab)")]))
    }

    @Test func test_a_room_merged_into_a_voice_by_a_join_makes_it_the_room() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 30, [("SPEAKER_00", 1, 28, Self.ANNA)])
        let b = try recording(temp.url, later(32), 60, [("SPEAKER_00", 2, 58, Self.ANNA)])  // the same voice, longer
        try SharedMic.setLane(a, "SPEAKER_00", true, name: "Lab")
        let kept = try Cutting.join(a, b)
        #expect(kept.folder == b.folder)
        #expect(Set(SharedMic.display(kept).values) == ["Room (Lab)"])  // b's own voice too: the room wins
    }

    @Test func test_a_meeting_kept_on_this_mac_stays_so_when_split_or_joined() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        try LocalOnly.set(a.folder, on: true)
        let tail = try Cutting.split(a, at: 40)
        #expect(LocalOnly.isLocalOnly(a.folder) && LocalOnly.isLocalOnly(tail.folder))  // both parts

        let b = try recording(temp.url, later(62), 30, [("SPEAKER_00", 2, 28, Self.VALERIE)])
        let kept = try Cutting.join(tail, b)  // b keeps the meeting; tail was local only
        #expect(kept.folder == b.folder && LocalOnly.isLocalOnly(kept.folder))
    }

    @Test func test_discarding_the_start_keeps_the_mark() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        try LocalOnly.set(a.folder, on: true)
        try Cutting.discard(a, at: 20, side: "before")
        #expect(LocalOnly.isLocalOnly(a.folder))
    }

    // MARK: - a recording continued after a restart (#47)

    @Test func test_join_can_keep_the_first_part_and_marks_the_gap() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 30, [("SPEAKER_00", 1, 20, Self.ANNA)])
        let b = try recording(temp.url, later(39), 60, [("SPEAKER_00", 2, 50, Self.ANNA)])
        var bMeta = PyDict<JSONValue>(meta(b))!
        bMeta["stop_reason"] = .string("call_ended")
        try write(b.meta, bMeta.json)
        let kept = try Cutting.join(a, b, keep: a, gapWhy: "restart")

        #expect(kept.folder == a.folder && !exists(b.folder))  // the first part keeps the meeting, though shorter
        let m = meta(a)
        #expect(m["duration_seconds"]?.doubleValue == 99 && m["start_time"]?.stringValue == Self.T0.iso)
        #expect(equal(m["gaps"], #"[{"start": 30.0, "end": 39.0, "why": "restart"}]"#))
        #expect(m["stop_reason"]?.stringValue == "call_ended")  // how the meeting ended: its last part
        let audio = try Wav16.read(a.systemWav)
        #expect(audio.count == 99 * Self.SR && audio[(30 * Self.SR)..<(39 * Self.SR)].allSatisfy { $0 == 0 })  // silence where nothing was recorded
    }

    @Test func test_gaps_move_with_later_joins_and_splits() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 30, [("SPEAKER_00", 1, 20, Self.ANNA)])
        let b = try recording(temp.url, later(39), 30, [("SPEAKER_00", 2, 20, Self.ANNA)])
        let c = try recording(temp.url, later(80), 20, [("SPEAKER_00", 2, 10, Self.ANNA)])
        try Cutting.join(a, b, keep: a, gapWhy: "restart")
        try Cutting.join(a, c, keep: a, gapWhy: "restart")
        #expect(spans(meta(a)["gaps"]) == [[30, 39], [69, 80]])

        let tail = try Cutting.split(a, at: 50)
        #expect(spans(meta(a)["gaps"]) == [[30, 39]])
        #expect(spans(meta(tail)["gaps"]) == [[19, 30]])
    }

    @Test func test_a_join_by_hand_marks_no_gap() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 30, [("SPEAKER_00", 1, 20, Self.ANNA)])
        let b = try recording(temp.url, later(39), 60, [("SPEAKER_00", 2, 50, Self.ANNA)])
        let kept = try Cutting.join(a, b)
        #expect(kept.folder == b.folder && meta(kept)["gaps"] == nil)
    }

    private func withProblems(_ p: RecordingPaths, _ problems: String) throws {
        var m = PyDict<JSONValue>(meta(p))!
        m["audio_problems"] = try PythonJSON.parse(Data(problems.utf8))
        try write(p.meta, m.json)
    }

    @Test func test_audio_problems_move_with_joins_and_splits() throws {
        // Issue #50: "Audio problem at 12:14" stays at 12:14 when parts are joined or cut.
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 30, [("SPEAKER_00", 1, 20, Self.ANNA)])
        let b = try recording(temp.url, later(39), 30, [("SPEAKER_00", 2, 20, Self.ANNA)])
        try withProblems(a, #"[{"kind": "speed", "track": "system", "start": 5.0, "end": 8.0}]"#)
        try withProblems(b, #"[{"kind": "speed", "track": "system", "start": 10.0, "end": 25.0}]"#)
        try Cutting.join(a, b, keep: a, gapWhy: "restart")
        #expect(spans(meta(a)["audio_problems"]) == [[5, 8], [49, 64]])

        let tail = try Cutting.split(a, at: 50)
        #expect(spans(meta(a)["audio_problems"]) == [[5, 8], [49, 50]])
        #expect(spans(meta(tail)["audio_problems"]) == [[0, 14]] && meta(tail)["audio_problems"]?.arrayValue?[0]["kind"]?.stringValue == "speed")
    }

    @Test func test_a_zero_length_audio_problem_moves_like_any_other() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 30, [("SPEAKER_00", 1, 20, Self.ANNA)])
        try withProblems(a, #"[{"kind": "stalled", "track": "mic", "start": 10.0, "end": 10.0}, {"kind": "stalled", "track": "mic", "start": 22.0, "end": 22.0}]"#)
        let tail = try Cutting.split(a, at: 20)
        #expect(spans(meta(a)["audio_problems"]) == [[10, 10]])
        #expect(spans(meta(tail)["audio_problems"]) == [[2, 2]])
    }

    // MARK: - who transcribed it (#54)

    private func marked(_ p: RecordingPaths, _ system: String) throws {
        try write(p.transcription, .object([("system", try PythonJSON.parse(Data(system.utf8)))]))
    }

    private func systemMarker(_ p: RecordingPaths) -> JSONValue { read(p.transcription)?["system"] ?? .null }

    @Test func test_a_split_carries_who_transcribed_it_to_both_halves() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        try marked(a, #"{"engine": "assemblyai", "model": "universal-3-5-pro", "sent_seconds": 50.0}"#)
        let tail = try Cutting.split(a, at: 40)
        #expect(systemMarker(a)["engine"]?.stringValue == "assemblyai" && systemMarker(tail)["engine"]?.stringValue == "assemblyai")
    }

    @Test func test_a_join_keeps_the_service_only_when_both_parts_had_it() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        func pair(_ dir: String, _ x: String?, _ y: String?) throws -> RecordingPaths {
            let root = temp.url.appendingPathComponent(dir)
            let a = try recording(root, Self.T0, 60, [("SPEAKER_00", 1, 30, Self.ANNA)])
            let b = try recording(root, later(60), 60, [("SPEAKER_00", 1, 30, Self.VALERIE)])
            if let x { try marked(a, x) }
            if let y { try marked(b, y) }
            return try Cutting.join(a, b)
        }
        let same = try pair("same", #"{"engine": "assemblyai", "model": "universal-3-5-pro", "sent_seconds": 40.0, "usd": 0.003}"#,
                            #"{"engine": "assemblyai", "model": "universal-3-5-pro", "sent_seconds": 20.0, "usd": 0.0015}"#)
        #expect(systemMarker(same)["engine"]?.stringValue == "assemblyai" && systemMarker(same)["sent_seconds"]?.doubleValue == 60)
        var shown = PyDict<JSONValue>(systemMarker(same))!
        #expect(shown.removeValue(forKey: "at") != nil)
        #expect(PythonJSON.dumps(shown.json) == #"{"engine": "assemblyai", "model": "universal-3-5-pro", "sent_seconds": 60.0, "usd": 0.0045}"#)

        let mixed = try pair("mixed", #"{"engine": "assemblyai", "model": "universal-3-5-pro", "sent_seconds": 40.0}"#, #"{"engine": "local"}"#)
        #expect(systemMarker(mixed)["engine"]?.stringValue == "mixed")
        #expect(systemMarker(mixed)["parts"] == .strings(["assemblyai", "local"]))

        let unknown = try pair("unknown", #"{"engine": "live"}"#, nil)  // the other part has no marker: transcribed before any of this
        #expect(systemMarker(unknown)["engine"]?.stringValue == "mixed")
    }

    @Test func test_a_failed_join_puts_the_marker_back() throws {
        // Python breaks `_with_gaps`; here the second part's meta.json has gaps that are no list: the join fails at the
        // same step, after the tracks and the speaker files were rewritten.
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 60, [("SPEAKER_00", 1, 30, Self.ANNA)])
        let b = try recording(temp.url, later(60), 60, [("SPEAKER_00", 1, 30, Self.VALERIE)])
        try marked(a, #"{"engine": "assemblyai", "sent_seconds": 40.0}"#)
        try marked(b, #"{"engine": "local"}"#)
        var bMeta = PyDict<JSONValue>(meta(b))!
        bMeta["gaps"] = .int(5)
        try write(b.meta, bMeta.json)
        let before = try content(a.folder)

        #expect(throws: CuttingError.self) { try Cutting.join(a, b, keep: a) }
        #expect(systemMarker(a)["engine"]?.stringValue == "assemblyai")
        #expect(try content(a.folder) == before && !exists(a.folder.appendingPathComponent(".join-backup")))
        #expect(exists(b.folder))
    }

    /// Every file of a folder (not the locks) and its bytes.
    private func content(_ folder: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where !name.hasSuffix(".lock") {
            var isDir: ObjCBool = false
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue { out[name] = try Data(contentsOf: url) }
        }
        return out
    }

    @Test func test_my_notes_follow_a_join_and_a_split() throws {
        // A restart mid-call (#47) joins two parts: what the user wrote in either is kept, on one clock.
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 30, [("SPEAKER_00", 1, 20, Self.ANNA)])
        let b = try recording(temp.url, later(39), 60, [("SPEAKER_00", 2, 50, Self.ANNA)])
        _ = try MyNotes.save(a.folder, paragraphs: try PythonJSON.parse(Data(#"[{"text": "prep", "at": null}, {"text": "in part one", "at": 10}]"#.utf8)))
        _ = try MyNotes.save(b.folder, paragraphs: try PythonJSON.parse(Data(#"[{"text": "in part two", "at": 5}]"#.utf8)))
        let kept = try Cutting.join(a, b, keep: a, gapWhy: "restart")
        #expect(MyNotes.load(kept.folder) == [.init(text: "prep"), .init(text: "in part one", at: 10), .init(text: "in part two", at: 44)])

        let tail = try Cutting.split(kept, at: 40)
        #expect(MyNotes.load(kept.folder) == [.init(text: "prep"), .init(text: "in part one", at: 10)])
        #expect(MyNotes.load(tail.folder) == [.init(text: "in part two", at: 4)])
    }

    @Test func test_the_users_title_stays_with_the_meeting_through_split_and_join() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        try Titles.save(a, "Budget with Anna")
        let tail = try Cutting.split(a, at: 40)
        #expect(Titles.load(a) == "Budget with Anna" && Titles.load(tail) == nil)  // the rest is another meeting

        try Titles.save(tail, "Budget, part two")
        let b = try recording(temp.url, later(62), 30, [("SPEAKER_00", 2, 28, Self.VALERIE)])
        let kept = try Cutting.join(tail, b)  // b keeps the meeting, and had no title of its own
        #expect(kept.folder == b.folder && Titles.load(kept) == "Budget, part two")
    }

    @Test func aJoinKeepsTheKeptRecordingsCalendarFileWhenThisCodeCannotReadIt() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 30, [("SPEAKER_00", 1, 20, Self.ANNA)])
        let b = try recording(temp.url, later(31), 60, [("SPEAKER_00", 2, 50, Self.ANNA)])
        try CalendarEvents.dismiss(a)  // the user's own decision, on the part that goes
        let unreadable = #"{"title": 5, "start": "2026-10-21T15:34:00+02:00"}"#
        try unreadable.write(to: b.calendar, atomically: false, encoding: .utf8)
        try Cutting.join(a, b)
        #expect(try String(contentsOf: b.calendar, encoding: .utf8) == unreadable)

        let c = try recording(temp.url, Self.T0, 30, [("SPEAKER_00", 1, 20, Self.ANNA)])
        try CalendarEvents.dismiss(c)
        let d = try recording(temp.url, later(200), 60, [("SPEAKER_00", 2, 50, Self.ANNA)])
        try Cutting.join(c, d)  // d had none: the other's decision comes along
        #expect(CalendarEvents.dismissed(d))
    }

    // MARK: - neighbours and the keeper

    @Test func neighboursAreTheProcessedRecordingsJustBeforeAndAfter() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 60, [], audio: false)
        let b = try recording(temp.url, later(90), 60, [], audio: false)  // 30 s after a
        let c = try recording(temp.url, later(150 + 31 * 60), 60, [], audio: false)  // too long after b
        _ = try recording(temp.url, later(120), 10, [], audio: false)  // b's other neighbour, never processed
        try FileManager.default.removeItem(at: temp.url.appendingPathComponent("2026-10-21T15-36-00").appendingPathComponent("transcript.json"))
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("2026-10-21T15-35-00"), withIntermediateDirectories: false)  // no meta
        #expect(try Cutting.neighbours(a) == (nil, b.folder.lastPathComponent))
        #expect(try Cutting.neighbours(b) == (a.folder.lastPathComponent, nil))
        #expect(try Cutting.neighbours(c) == (nil, nil))
        #expect(try Cutting.keeper(b, a).folder == a.folder)  // as long: the earlier one
    }

    // MARK: - the join's backup

    @Test func aJoinKilledHalfWayIsUndoneBeforeItRunsAgain() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 30, [("SPEAKER_00", 1, 20, Self.ANNA)])
        let b = try recording(temp.url, later(39), 60, [("SPEAKER_00", 2, 50, Self.ANNA)])
        try write(a.speakers, .object([("SPEAKER_00", .string("Anna"))]))
        let before = try content(a.folder)
        // Killed after the backup and a rewritten track and meta: nothing ran after it, no restore either.
        let backup = try Cutting.makeBackup(a, b)
        #expect(try String(contentsOf: backup.appendingPathComponent("files.json"), encoding: .utf8)
                == #"{"files": ["mic_raw.wav", "mic.wav", "system.wav", "meta.json", "speaker_embeddings.json", "speakers.json", "mic_segments.json", "system_segments.json", "system_turns.json", "transcript.json"], "other": "2026-10-21T15-34-39"}"#)
        try Wav16.write([1, 2, 3], rate: Self.SR, to: a.systemWav.deletingLastPathComponent().appendingPathComponent("system.wav.joining"))
        try Wav16.write([1, 2, 3], rate: Self.SR, to: a.micWav.deletingLastPathComponent().appendingPathComponent("mic.wav.joining"))
        try FileManager.default.removeItem(at: a.micWav)
        try FileManager.default.moveItem(at: a.micWav.deletingLastPathComponent().appendingPathComponent("mic.wav.joining"), to: a.micWav)
        try write(a.meta, .object([("start_time", .string(Self.T0.iso)), ("duration_seconds", .int(99))]))
        try write(a.speakersMerged, .object([("SPEAKER_01", .string("SPEAKER_00"))]))

        try Cutting.finishUnfinishedJoin(a)
        #expect(try content(a.folder) == before && !exists(backup))
        let kept = try Cutting.join(a, b, keep: a)  // undone first, then joined once
        #expect(meta(kept)["duration_seconds"]?.doubleValue == 99 && !exists(b.folder))
    }

    @Test func aJoinKilledAfterAllWasWrittenIsFinished() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 30, [("SPEAKER_00", 1, 20, Self.ANNA)])
        let b = try recording(temp.url, later(39), 60, [("SPEAKER_00", 2, 50, Self.ANNA)])
        // As Python leaves it: its files.json, "done", the other recording not yet in the trash.
        let backup = a.folder.appendingPathComponent(".join-backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        try #"{"files": ["meta.json"], "other": "2026-10-21T15-34-39"}"#.write(to: backup.appendingPathComponent("files.json"), atomically: false, encoding: .utf8)
        try "".write(to: backup.appendingPathComponent("done"), atomically: false, encoding: .utf8)
        let joined = try content(a.folder)
        try Cutting.finishUnfinishedJoin(a)
        #expect(!exists(b.folder) && exists(temp.url.appendingPathComponent(".trash/2026-10-21T15-34-39")))
        #expect(try content(a.folder) == joined && !exists(backup))

        // Killed while backing up (no files.json yet): nothing was changed; the backup goes.
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        try Cutting.finishUnfinishedJoin(a)
        #expect(!exists(backup))
        #expect(try content(a.folder) == joined)
    }

    // MARK: - locks

    @Test func aSplitWaitsForTheMeetingsLock() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        let holder = try LockHolder(a.folder.appendingPathComponent(".speakers.lock"), seconds: 1.0)
        let started = Date()
        try Cutting.split(a, at: 40)
        #expect(Date().timeIntervalSince(started) >= 0.7)
        #expect(holder.wait() == 0)
    }

    @Test func aJoinWaitsForTheOtherMeetingsLock() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try recording(temp.url, Self.T0, 30, [("SPEAKER_00", 1, 20, Self.ANNA)])
        let b = try recording(temp.url, later(39), 60, [("SPEAKER_00", 2, 50, Self.ANNA)])
        let holder = try LockHolder(a.folder.appendingPathComponent(".speakers.lock"), seconds: 1.0)
        let started = Date()
        try Cutting.join(a, b)  // b keeps the meeting; a's speaker files are read under a's lock
        #expect(Date().timeIntervalSince(started) >= 0.7)
        #expect(holder.wait() == 0)
    }

    @Test func aDurationThatIsNoFiniteNumberIsAValueErrorNotATrap() throws {
        let temp = TempFolder("cutting"); defer { temp.remove() }
        let a = try standard(temp.url)
        for (literal, message) in [("NaN", "cannot convert float NaN to integer"), ("Infinity", "cannot convert float infinity to integer"),
                                   ("-Infinity", "cannot convert float infinity to integer")] {
            try Data(#"{"start_time": "2026-10-21T15:34:00+02:00", "duration_seconds": \#(literal)}"#.utf8).write(to: a.meta)
            for call in [{ _ = try Cutting.span(a) }, { _ = try Cutting.split(a, at: 40) }, { _ = try Cutting.suggestTrim(a) },
                         { _ = try Cutting.neighbours(a) }] {
                do {
                    try call()
                    Issue.record("\(literal): no error")
                } catch let e as CuttingError {
                    #expect(e.kind == .value && e.description == message)
                }
            }
        }
    }

    @Test func labelsAreNumberedAfterTheKeptOnesWhateverDigitsTheyHave() {
        #expect(Cutting.relabeling(["SPEAKER_01", "SPEAKER_00", "SPEAKER_01"], ["SPEAKER_\u{0663}", "SPEAKER_01\n", "Room"])
                == PyDict([("SPEAKER_00", "SPEAKER_04"), ("SPEAKER_01", "SPEAKER_05")]))
        #expect(Cutting.relabeling(["x"], []) == PyDict([("x", "SPEAKER_00")]))
    }
}
