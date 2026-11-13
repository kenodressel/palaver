// The speaker of single transcript lines (#12, test_line_speakers.py): a line diarization gave to the wrong voice
// ("Speaker 2" holds two people) said to be someone else's, in speakers_lines.json, applied wherever the meeting is
// shown, searched or exported, and kept when it is processed again. Ports test_line_speakers.py under its names; the
// notes prompt half of the room test is Python's (notes.generate stays there).
import Darwin
import Foundation
import Testing
import PalaverCore
@testable import PalaverDomain
@testable import PalaverServer

private let M = "2026-10-29T14-00-00"
private let USER = "Kim"
private let SR = 16_000

private func write(_ value: JSONValue, to url: URL) throws { try Data(PythonJSON.dumps(value).utf8).write(to: url) }
private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func lines() -> [Utterance] {
    [
        Utterance(speaker: USER, start: 0.0, end: 1.0, text: "Hi everyone."),
        Utterance(speaker: "Valerie", start: 1.0, end: 12.0, text: "Welcome to the Contoso review.", label: "SPEAKER_00"),
        Utterance(speaker: "SPEAKER_01", start: 13.0, end: 15.0, text: "The Northwind numbers are in."),
        Utterance(speaker: "SPEAKER_01", start: 16.0, end: 18.0, text: "I disagree with those numbers."),  // Timo Strauß, really
        Utterance(speaker: USER, start: 16.5, end: 17.5, text: "Really?"),  // at the same time, on the microphone
        Utterance(speaker: "SPEAKER_01", start: 19.0, end: 21.0, text: "Let us check them again."),
    ]
}

/// `_meeting`: Valerie named, Speaker 2 unnamed and two people in truth.
private final class Fixture {
    let dir: URL
    let out: URL
    let app: ServerApp
    let paths: RecordingPaths

    init() throws {
        dir = tempFolder("line-speakers")
        out = dir.appendingPathComponent("Meetings", isDirectory: true)
        let stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                                home: dir.appendingPathComponent("home", isDirectory: true))
        app = ServerApp(outputDir: out, userName: USER, stores: stores)
        paths = try Fixture.meeting(out, stores: stores)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    static func meeting(_ out: URL, stores: StorePaths) throws -> RecordingPaths {
        let paths = RecordingPaths(out.appendingPathComponent(M, isDirectory: true))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        let n = SR * 25
        try Wav16.write((0..<n).map { Int16(3000 * sin(Double($0) / 7)) }, rate: SR, to: paths.systemWav)
        try Wav16.write((0..<n).map { Int16(2000 * sin(Double($0) / 3)) }, rate: SR, to: paths.micWav)
        try write(.object([("start_time", .string("2026-10-29T14:00:00+01:00")), ("duration_seconds", .int(25))]), to: paths.meta)
        try write(.array([
            .object([("speaker", .string("SPEAKER_00")), ("start", .double(1.0)), ("end", .double(12.0))]),
            .object([("speaker", .string("SPEAKER_01")), ("start", .double(13.0)), ("end", .double(21.0))]),
            .object([("speaker", .string("SPEAKER_02")), ("start", .double(22.0)), ("end", .double(22.5))]),
        ]), to: paths.systemTurns)
        try write(.object([("SPEAKER_00", .string("Valerie"))]), to: paths.speakers)
        let utterances = lines()
        try write(.array(utterances.map(\.json)), to: paths.transcriptJson)
        try NotesFile.save(paths, .object([
            ("title", .string("Contoso review")), ("summary", .string("SPEAKER_01 has the numbers.")), ("sections", .array([])),
            ("next_steps", .array([])), ("decisions", .array([])), ("speaker_names", .array([])),
            ("transcript_hash", .string(Notes.transcriptHash(utterances))),
        ]))
        try Speakers.saveSpeakerNames(paths, PyDict([("SPEAKER_00", "Valerie")]), learn: false, stores: stores)
        return paths
    }

    func get() throws -> JSONValue { try MeetingsAPI.getMeeting(app: app, id: M) }

    @discardableResult
    func set(_ start: Double, _ to: JSONValue?, track: String? = nil) throws -> String {
        try ChangesAPI.setLineSpeaker(app, id: M, start: start, to: to, track: track)
    }

    var fixes: String { PythonJSON.dumps(.array(Speakers.loadLineSpeakers(paths)), ensureAscii: false) }
    var markdown: String { (try? String(contentsOf: paths.transcriptMd, encoding: .utf8)) ?? "" }
}

/// `_line`: the line starting at `start` that is not the microphone's "Really?".
private func line(_ m: JSONValue, _ start: Double) -> JSONValue {
    (m["transcript"]?.arrayValue ?? []).first { $0["start"] == .double(start) && $0["text"] != .string("Really?") } ?? .null
}

private func really(_ m: JSONValue) -> JSONValue {
    (m["transcript"]?.arrayValue ?? []).first { $0["text"] == .string("Really?") } ?? .null
}

private func label(_ name: String) -> JSONValue { .object([("label", .string(name))]) }
private func named(_ name: String) -> JSONValue { .object([("name", .string(name))]) }
private let me: JSONValue = .object([("me", .bool(true))])

private func fixedValue(_ was: String, _ from: String?) -> JSONValue { .object([("was", .string(was)), ("from", .str(from))]) }

@Suite struct LineSpeakersTests {
    // MARK: - moving a line

    @Test func test_a_line_moves_to_another_speaker() throws {
        let f = try Fixture()
        let token = try f.set(16.0, label("SPEAKER_00"))
        #expect(!token.isEmpty)
        let m = try f.get()
        let moved = line(m, 16.0)
        #expect(moved["speaker"] == .string("Valerie") && moved["label"] == .string("SPEAKER_00"))
        #expect(moved["fixed"] == fixedValue("Speaker 2", "SPEAKER_01"))
        #expect(line(m, 13.0)["speaker"] == .string("Speaker 2") && line(m, 13.0)["fixed"] == .null)
        #expect(really(m)["speaker"] == .string(USER))  // the mic is not moved
        #expect(f.fixes == #"[{"start": 16.0, "end": 18.0, "from": "SPEAKER_01", "label": "SPEAKER_00"}]"#)
        #expect(f.markdown.contains("**Valerie** [14:00:16]  I disagree with those numbers."))
    }

    @Test func test_a_line_goes_to_a_person_who_has_no_voice_of_their_own() throws {
        let f = try Fixture()
        try f.set(16.0, named("  Timo Strauß "))
        let moved = line(try f.get(), 16.0)
        #expect(moved["speaker"] == .string("Timo Strauß") && moved["fixed"] == fixedValue("Speaker 2", "SPEAKER_01"))
        #expect(f.fixes == #"[{"start": 16.0, "end": 18.0, "from": "SPEAKER_01", "name": "Timo Strauß"}]"#)
        #expect(f.markdown.contains("**Timo Strauß** [14:00:16]"))
    }

    @Test func test_a_line_is_mine() throws {
        let f = try Fixture()
        try f.set(19.0, me)
        let m = try f.get()
        let mine = line(m, 19.0)
        #expect(mine["speaker"] == .string(USER) && mine["label"] == .null)
        #expect(f.fixes == #"[{"start": 19.0, "end": 21.0, "from": "SPEAKER_01", "me": true, "name": "Kim"}]"#)
        let you = try #require(m["speakers"]?.arrayValue?.first { $0["is_user"] == .bool(true) })
        #expect(you["talk_seconds"] == .double(4.0))  // 0–1, 16.5–17.5 and now 19–21
    }

    @Test func test_a_line_of_mine_goes_to_someone_else() throws {
        let f = try Fixture()
        try f.set(0.0, label("SPEAKER_01"))
        let first = try #require(try f.get()["transcript"]?.arrayValue?.first)
        #expect(first["speaker"] == .string("Speaker 2") && first["label"] == .string("SPEAKER_01"))
        #expect(first["fixed"] == fixedValue(USER, nil))
    }

    @Test func test_the_name_of_a_speaker_moves_the_line_to_that_speaker() throws {
        let f = try Fixture()
        try f.set(16.0, named("valerie"))
        #expect(Speakers.loadLineSpeakers(f.paths)[0]["label"] == .string("SPEAKER_00"))
        try f.set(13.0, named("kim"))  // the user's own name: mine
        #expect(Speakers.loadLineSpeakers(f.paths)[0]["me"] == .bool(true))
    }

    @Test func test_back_to_the_speaker_it_was() throws {
        let f = try Fixture()
        try f.set(16.0, named("Timo Strauß"))
        try f.set(16.0, label("SPEAKER_00"))  // changed again: one correction per line
        #expect(Speakers.loadLineSpeakers(f.paths).count == 1)
        try f.set(16.0, nil)
        #expect(!exists(f.paths.speakersLines))
        #expect(line(try f.get(), 16.0)["speaker"] == .string("Speaker 2"))
        try f.set(16.0, label("SPEAKER_01"))  // its own speaker: nothing to correct
        #expect(!exists(f.paths.speakersLines))
    }

    @Test func test_what_cannot_be_chosen() throws {
        let f = try Fixture()
        #expect(throws: NotFound.self) { try f.set(16.0, label("SPEAKER_09")) }
        #expect(throws: NotFound.self) { try f.set(3.0, me) }  // no line starts there
        #expect(throws: BadRequest.self) { try f.set(16.0, named("  ")) }
        #expect(throws: BadRequest.self) { try f.set(16.0, .object([("who", .string("Valerie"))])) }
    }

    // MARK: - wherever the meeting is used

    @Test func test_notes_search_and_the_list_use_the_corrected_speaker() throws {
        let f = try Fixture()
        func listed() throws -> JSONValue? { try MeetingsAPI.listMeetings(app: f.app).first?["notes_stale"] }
        #expect(try f.get()["notes_stale"] == .bool(false) && listed() == .bool(false))
        try f.set(16.0, named("Timo Strauß"))
        #expect(try f.get()["notes_stale"] == .bool(true))  // the notes said who said what: written again
        #expect(try listed() == .bool(true))
        let hits = try SearchAPI.search(f.app, "disagree", userName: USER)
        #expect(hits.count == 1 && hits.first?["hits"]?.arrayValue?.first?["speaker"] == .string("Timo Strauß"))
    }

    @Test func test_a_correction_stays_when_the_meeting_is_processed_again() throws {
        let f = try Fixture()
        try f.set(16.0, named("Timo Strauß"))
        try f.set(19.0, label("SPEAKER_00"))
        // Transcribed again: the times move a little, the words may differ.
        let again = [
            Utterance(speaker: USER, start: 0.0, end: 1.1, text: "Hi everyone."),
            Utterance(speaker: "SPEAKER_00", start: 1.0, end: 12.0, text: "Welcome to the Contoso review."),
            Utterance(speaker: "SPEAKER_01", start: 13.1, end: 15.0, text: "The Northwind numbers are in."),
            Utterance(speaker: "SPEAKER_01", start: 16.08, end: 18.2, text: "I disagree with these numbers."),
            Utterance(speaker: USER, start: 16.4, end: 17.6, text: "Really?"),
            Utterance(speaker: "SPEAKER_01", start: 18.9, end: 20.7, text: "Let's check them again."),
        ]
        try write(.array(again.map(\.json)), to: f.paths.transcriptJson)
        try Speakers.saveSpeakerNames(f.paths, try Speakers.loadSpeakerNames(f.paths), learn: false, stores: f.app.stores)
        let m = try f.get()
        #expect(m["transcript"]?.arrayValue?.map { $0["speaker"] }
                == [USER, "Valerie", "Speaker 2", "Timo Strauß", USER, "Valerie"].map { .string($0) })
        #expect(f.markdown.contains("**Timo Strauß** [14:00:16]  I disagree with these numbers."))
    }

    @Test func test_lines_of_a_removed_voice_and_no_lines_moved_to_one() throws {
        let f = try Fixture()
        try f.set(16.0, named("Timo Strauß"))
        try PeopleAPI.removeSpeaker(f.app, id: M, label: "SPEAKER_01", removed: true)
        let texts = try f.get()["transcript"]?.arrayValue?.compactMap { $0["text"]?.stringValue } ?? []
        #expect(texts.contains("I disagree with those numbers."))  // someone else's line: it stays
        #expect(!texts.contains("Let us check them again."))
        let first = #expect(throws: Refused.self) { try f.set(0.0, label("SPEAKER_01")) }  // no lines for a removed voice
        #expect(first?.description.contains("Speaker 2 was removed as not a speaker") ?? false)
        try PeopleAPI.removeSpeaker(f.app, id: M, label: "SPEAKER_00", removed: true)
        let second = #expect(throws: Refused.self) { try f.set(0.0, named("Valerie")) }  // nor by its name
        #expect(second?.description.contains("removed as not a speaker") ?? false)
        #expect(f.markdown.contains("Hi everyone."))
    }

    @Test func test_a_line_given_to_a_person_keeps_their_name_where_the_microphone_is_a_room() throws {
        // #56: the microphone's lines show as "Room (with you)"; a line said to be a person's is no microphone line,
        // though it has no label.
        let f = try Fixture()
        try SharedMic.setLane(f.paths, SharedMic.MIC, true)
        try f.set(16.0, named("Timo Strauß"))
        #expect(f.markdown.contains("**Timo Strauß** [14:00:16]  I disagree with those numbers."))
        #expect(f.markdown.contains("**Room (with you)** [14:00:16]  Really?"))
        #expect(line(try f.get(), 16.0)["speaker"] == .string("Timo Strauß"))
        let hits = try SearchAPI.search(f.app, "disagree", userName: USER)
        #expect(hits.count == 1 && hits.first?["hits"]?.arrayValue?.first?["speaker"] == .string("Timo Strauß"))
        // What the notes prompt is given (notes.generate is Python's): the person's line keeps their name.
        let raw = try MeetingsAPI.utterances(f.paths)
        let shown = SharedMic.shown(f.paths, try Speakers.withoutIgnored(f.paths, raw))
        #expect(shown.first { $0.start == 16.0 }?.speaker == "Timo Strauß")
        #expect(shown.first { $0.text == "Really?" }?.speaker == "Room (with you)")
        #expect(Notes.sharedLanes(try Speakers.withoutIgnored(f.paths, raw), shared: PyDict(), mic: "Room (with you)") == ["mic"])
    }

    @Test func test_a_line_is_found_by_its_start_and_track() throws {
        let f = try Fixture()
        guard case .array(var items) = PythonJSON.read(f.paths.transcriptJson)!, case .object(var fourth) = items[4] else {
            Issue.record("transcript.json")
            return
        }
        fourth = fourth.map { $0.0 == "start" ? ($0.0, .double(16.005)) : $0 }  // the microphone's "Really?" starts with the system line
        items[4] = .object(fourth)
        try write(.array(items), to: f.paths.transcriptJson)
        let error = #expect(throws: BadRequest.self) { try f.set(16.0, label("SPEAKER_00")) }
        #expect(error?.description.contains("track") ?? false)
        try f.set(16.0, label("SPEAKER_00"), track: "mic")
        #expect(f.fixes == #"[{"start": 16.005, "end": 17.5, "from": null, "label": "SPEAKER_00"}]"#)
        let m = try f.get()
        #expect(really(m)["speaker"] == .string("Valerie") && really(m)["track"] == .string("mic")
                && really(m)["fixed"] == fixedValue(USER, nil))
        let disagree = line(m, 16.0)
        #expect(disagree["speaker"] == .string("Speaker 2") && disagree["track"] == .string("others") && disagree["fixed"] == .null)
        #expect(throws: BadRequest.self) { try f.set(16.0, nil, track: "system") }
    }

    @Test func test_a_line_speaker_changes_under_the_lock_names_change_under() throws {
        // api.py holds _PROJECTS_LOCK around it: while the projects lock is held elsewhere, the line waits.
        let f = try Fixture()
        let done = Latch()
        final class Failure: @unchecked Sendable { var error: Error? }
        let failure = Failure()
        f.app.projectsLock.lock()
        // A thread of its own, as the server answers each request. GCD starts a global queue's block only while fewer
        // of its threads than cores are busy: on CI's 3 cores the busy tests beside this one kept it waiting past 60 s.
        Thread {
            do { _ = try f.set(16.0, me) } catch { failure.error = error }
            done.open()
        }.start()
        usleep(300_000)
        let waited = !exists(f.paths.speakersLines) && !done.opened
        f.app.projectsLock.unlock()
        done.wait(60)
        #expect(done.opened && failure.error == nil, "\(String(describing: failure.error))")
        #expect(waited && exists(f.paths.speakersLines))
    }

    @Test func test_the_overlay_matches_lines_by_time_and_track() throws {
        let fixes = try PythonJSON.parse(Data(#"""
            [{"start": 16.0, "end": 18.0, "from": "SPEAKER_01", "name": "Timo Strauß"},
             {"start": 0.0, "end": 1.0, "from": null, "label": "SPEAKER_01"}]
            """#.utf8)).arrayValue!
        let given = [
            Utterance(speaker: USER, start: 0.05, end: 0.9, text: "Hi."),
            Utterance(speaker: "SPEAKER_01", start: 13.0, end: 15.9, text: "Before."),
            Utterance(speaker: "SPEAKER_03", start: 16.2, end: 18.0, text: "Relabelled by a new diarization."),
            Utterance(speaker: USER, start: 16.5, end: 17.5, text: "Really?"),
            Utterance(speaker: "SPEAKER_01", start: 17.9, end: 21.0, text: "Mostly after."),
        ]
        let out = Speakers.correctedLines(given, fixes, names: PyDict([("SPEAKER_01", "Bea")]))
        #expect(out.map { "\($0.speaker)|\($0.label ?? "None")" }
                == ["Bea|SPEAKER_01", "SPEAKER_01|None", "Timo Strauß|None", "\(USER)|None", "SPEAKER_01|None"])
        #expect(out.map(\.text) == given.map(\.text))
    }

    @Test func test_without_ignored_applies_the_corrections() throws {
        let f = try Fixture()
        try f.set(16.0, me)
        #expect(try Speakers.withoutIgnored(f.paths, try MeetingsAPI.utterances(f.paths))[3].speaker == USER)
    }

    // MARK: - undo, and where the file goes

    @Test func test_undo_puts_the_line_back() throws {
        let f = try Fixture()
        let first = try f.set(16.0, named("Timo Strauß"))
        let second = try f.set(19.0, me)
        #expect(try UndoRoute.undoChange(f.app, token: second) == [M])
        #expect(f.fixes == #"[{"start": 16.0, "end": 18.0, "from": "SPEAKER_01", "name": "Timo Strauß"}]"#)
        #expect(try UndoRoute.undoChange(f.app, token: first) == [M])
        #expect(!exists(f.paths.speakersLines))
        #expect(f.markdown.contains("**SPEAKER_01** [14:00:16]"))  // transcript.md follows
        #expect(throws: UndoGone.self) { try UndoRoute.undoChange(f.app, token: first) }
    }

    @Test func test_speakers_lines_is_one_of_the_speaker_files() throws {
        let f = try Fixture()
        try f.set(16.0, me)
        #expect(f.paths.speakersLines.lastPathComponent == "speakers_lines.json")
        #expect(Undo.matches("speakers_lines.json", Undo.SPEAKER_FILES))  // snapshots of speaker files take it
        #expect(SearchIndex.signature(f.paths)["speakers_lines.json"] != nil)  // the search index is made again
    }

    // MARK: - the window's server

    @Test func test_http_line_speaker_and_undo() throws {
        let s = try TestServer(userName: USER, meetings: { out in
            _ = try Fixture.meeting(out, stores: StorePaths(configDir: out.deletingLastPathComponent()
                .appendingPathComponent("config/palaver", isDirectory: true),
                home: out.deletingLastPathComponent().appendingPathComponent("home", isDirectory: true)))
        })
        defer { s.stop() }
        var r = s.post("/api/meetings/\(M)/line-speaker", .object([("start", .double(16.0)), ("to", named("Timo Strauß"))]))
        let token = r.json?["undo"]?.stringValue ?? ""
        #expect(r.status == 200 && !token.isEmpty)
        #expect(line(r.json ?? .null, 16.0)["speaker"] == .string("Timo Strauß"))
        r = s.post("/api/undo", .object([("token", .string(token))]))
        #expect(r.status == 200)
        r = s.post("/api/meetings/\(M)/line-speaker", .object([("start", .double(16.0)), ("to", label("SPEAKER_07"))]))
        #expect(r.status == 404)
        r = s.post("/api/meetings/\(M)/line-speaker", .object([("start", .double(16.0)), ("to", .string("Valerie"))]))
        #expect(r.status == 400)
    }
}
