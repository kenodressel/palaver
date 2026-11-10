// The notes' read side (notes.py, test_notes.py): the hashes against Python's, staleness, name guesses, with_names.
// Generation and parsing (the other tests of test_notes.py) are phase 4.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct NotesReadTests {
    private func u(_ speaker: String, _ start: Double, _ end: Double, _ text: String, label: String? = nil) -> Utterance {
        Utterance(speaker: speaker, start: start, end: end, text: text, label: label)
    }

    private let utterances: [Utterance]
    private let glossary: Glossary
    private let temp = TempFolder("notes-read")

    init() {
        utterances = [Utterance(speaker: "SPEAKER_00", start: 0, end: 4, text: "Um, wir starten den Rollout am Montag."),
                      Utterance(speaker: "Timo", start: 5, end: 8, text: "Ich schicke dir bis Freitag die Liste."),
                      Utterance(speaker: "Anna", start: 65, end: 70, text: "Passt, danke Timo.", label: "SPEAKER_01")]
        glossary = Glossary(path: temp.url.appendingPathComponent("none.json"))
    }

    private func line(_ v: JSONValue) throws -> Utterance {
        let a = try #require(v.arrayValue)
        return Utterance(speaker: a[0].stringValue!, start: a[1].doubleValue!, end: a[2].doubleValue!, text: a[3].stringValue!,
                         label: a.count > 4 ? a[4].stringValue : nil)
    }

    private func fields(_ v: JSONValue) -> [(String, JSONValue)] {
        if case .object(let f) = v { return f } else { return [] }
    }

    // MARK: goldens

    @Test func test_transcript_hash_matches_python_for_tricky_starts() throws {
        let cases = try Goldens.cases("notes_read", "hash")
        #expect(cases.count > 100)
        for c in cases {
            let us = try #require(c[0].arrayValue).map { row -> Utterance in
                let a = row.arrayValue!
                return Utterance(speaker: a[1].stringValue!, start: Double(a[2].stringValue!)!, end: 0, text: a[3].stringValue!,
                                 label: a[0].stringValue)
            }
            #expect(Notes.transcriptHash(us) == c[1].stringValue, "\(PythonJSON.dumps(c[0]))")
        }
    }

    @Test func test_fixed_point_start_spelling() {
        #expect(Notes.fixed2(0.125) == "0.12" && Notes.fixed2(0.375) == "0.38" && Notes.fixed2(2.675) == "2.67")
        #expect(Notes.fixed2(-0.004) == "-0.00" && Notes.fixed2(-0.0) == "-0.00" && Notes.fixed2(1e6) == "1000000.00")
        #expect(Notes.fixed2(.nan) == "nan" && Notes.fixed2(-.infinity) == "-inf" && Notes.fixed2(.infinity) == "inf")
    }

    @Test func test_meeting_language_matches_python() throws {
        for c in try Goldens.cases("notes_read", "language") {
            let us = try #require(c[0].arrayValue).map { Utterance(speaker: $0.arrayValue![0].stringValue!, start: 0, end: 1, text: $0.arrayValue![1].stringValue!) }
            #expect(Notes.meetingLanguage(us) == c[1].stringValue, "\(PythonJSON.dumps(c[0]))")
        }
    }

    @Test func test_shared_lanes_match_python() throws {
        for c in try Goldens.cases("notes_read", "lanes") {
            let us = try #require(c[0].arrayValue).map { Utterance(speaker: $0.arrayValue![0].stringValue!, start: 0, end: 1, text: "t", label: $0.arrayValue![1].stringValue) }
            let shared = PyDict(fields(c[1]).map { ($0.0, $0.1.stringValue ?? "") })
            #expect(Notes.sharedLanes(us, shared: shared, mic: c[2].stringValue) == c[3].arrayValue?.compactMap(\.stringValue), "\(PythonJSON.dumps(c[0]))")
        }
    }

    @Test func test_backed_name_guesses_match_python() throws {
        let scenarios = try #require(Goldens.load("notes_read")["guesses"]?.arrayValue)
        #expect(scenarios.count > 100)
        for s in scenarios {
            let us = try #require(s["lines"]?.arrayValue).map(line)
            let kept = Notes.backedNameGuesses(try #require(s["guesses"]?.arrayValue), us, glossary: glossary)
            #expect(PythonJSON.dumps(.array(kept)) == PythonJSON.dumps(s["kept"]!), "\(PythonJSON.dumps(s["lines"]!)) \(PythonJSON.dumps(s["guesses"]!))")
        }
    }

    @Test func test_with_names_matches_python() throws {
        for c in try Goldens.cases("notes_read", "names") {
            let names = PyDict(fields(c[1]).map { ($0.0, $0.1.stringValue ?? "") })
            #expect(PythonJSON.dumps(Notes.withNames(c[0], names)) == PythonJSON.dumps(c[2]), "\(PythonJSON.dumps(c[0])) \(PythonJSON.dumps(c[1]))")
        }
    }

    // MARK: test_notes.py

    @Test func test_transcript_hash_ignores_names_but_not_words() {
        let renamed = [u("Bob", 0, 4, utterances[0].text, label: "SPEAKER_00")] + utterances.dropFirst()
        #expect(Notes.transcriptHash(renamed) == Notes.transcriptHash(utterances))
        let changed = [u("SPEAKER_00", 0, 4, "Wir starten am Dienstag.")] + utterances.dropFirst()
        #expect(Notes.transcriptHash(changed) != Notes.transcriptHash(utterances))
    }

    private func meeting() -> SpeakerMeeting { SpeakerMeeting() }

    private func saveNotes(_ paths: RecordingPaths, _ extra: [(String, JSONValue)] = []) throws {
        let base: [(String, JSONValue)] = [("title", .string("Rollout-Planung")), ("transcript_hash", .string(Notes.transcriptHash(utterances)))]
        try PythonJSON.write(.object(base + extra), to: paths.notes, indent: 2, ensureAscii: false)
    }

    @Test func test_notes_round_trip_and_staleness() throws {
        let m = meeting(); defer { m.remove() }
        #expect(Notes.load(m.paths) == nil)
        #expect(Notes.isStale(m.paths, utterances) && Notes.staleReason(m.paths, utterances) == "missing")
        try saveNotes(m.paths)
        #expect(Notes.load(m.paths)?["title"]?.stringValue == "Rollout-Planung")
        #expect(!Notes.isStale(m.paths, utterances))
        m.temp.write("2026-10-20T14-35-17/notes.json", "not json")
        #expect(Notes.load(m.paths) == nil && Notes.staleReason(m.paths, utterances) == "missing")
    }

    @Test func test_notes_go_stale_when_voices_are_said_to_be_several_people() throws {
        let m = meeting(); defer { m.remove() }
        try saveNotes(m.paths)
        #expect(Notes.staleReason(m.paths, utterances) == nil)
        m.write(m.paths.systemTurns, SpeakerMeeting.turns([("SPEAKER_01", 65, 70)]))
        try SharedMic.setLane(m.paths, "SPEAKER_01", true)
        #expect(Notes.staleReason(m.paths, utterances) == "shared")
        try saveNotes(m.paths, [("shared_lanes", .strings(["SPEAKER_01"]))])
        #expect(Notes.staleReason(m.paths, utterances) == nil)
    }

    @Test func test_notes_go_stale_when_the_users_notes_change() throws {
        let m = meeting(); defer { m.remove() }
        try saveNotes(m.paths)
        #expect(Notes.staleReason(m.paths, utterances) == nil)  // no notes of mine then or now
        _ = try MyNotes.save(m.paths.folder, paragraphs: try PythonJSON.parse(Data(#"[{"text": "Budget frozen", "at": 12}]"#.utf8)))
        #expect(Notes.staleReason(m.paths, utterances) == "my_notes" && Notes.isStale(m.paths, utterances))
        let stamped = Notes.myNotesHash(MyNotes.promptText(m.paths.folder))
        #expect(!stamped.isEmpty)
        try saveNotes(m.paths, [("my_notes_hash", .string(stamped))])
        #expect(Notes.staleReason(m.paths, utterances) == nil)
        #expect(Notes.staleReason(m.paths, Array(utterances.prefix(1))) == "transcript")
    }

    @Test func test_with_names_replaces_labels_everywhere() {
        let notes: JSONValue = .object([("next_steps", .array([.object([("owner", .string("SPEAKER_01")),
                                                                         ("task", .string("Ask SPEAKER_00 for the model"))])]))])
        let named = Notes.withNames(notes, PyDict([("SPEAKER_00", "Dani"), ("SPEAKER_01", "Anna")]))
        #expect(PythonJSON.dumps(named) == #"{"next_steps": [{"owner": "Anna", "task": "Ask Dani for the model"}]}"#)
        // SPEAKER_1 must not clobber SPEAKER_10
        let one = Notes.withNames(.object([("s", .string("SPEAKER_10 and SPEAKER_1"))]), PyDict([("SPEAKER_1", "A")]))
        #expect(PythonJSON.dumps(one) == #"{"s": "SPEAKER_10 and A"}"#)
    }

    private func guess(_ label: String, _ name: String) -> JSONValue {
        .object([("label", .string(label)), ("name", .string(name)), ("evidence", .string(""))])
    }

    private func backed(_ guesses: [JSONValue], _ us: [Utterance]) -> [String] {
        Notes.backedNameGuesses(guesses, us, glossary: glossary).map { "\($0["label"]!.stringValue!)/\($0["name"]!.stringValue!)" }
    }

    @Test func test_name_guesses_must_be_backed_by_the_transcript() {
        let us = [u("Timo", 0, 1, "Hi Rico, good to see you."), u("SPEAKER_00", 1.5, 3, "Hi Timo."),
                  u("SPEAKER_01", 4, 6, "Okay, thank you, Lenka."), u("SPEAKER_02", 7, 9, "Hallo, ich bin Andrea vom Data Team."),
                  u("SPEAKER_03", 10, 11, "Sure.")]
        let guesses = [guess("SPEAKER_00", "Rico"), guess("SPEAKER_01", "Lenka"), guess("SPEAKER_02", "Andrea"), guess("SPEAKER_03", "William")]
        #expect(backed(guesses, us) == ["SPEAKER_00/Rico", "SPEAKER_02/Andrea"])
    }

    @Test func test_meeting_language_from_common_words() {
        let german = [u("Timo", 0, 5, "Wir haben das mit dem Rollout nicht gemacht und es ist auch noch nicht fertig, aber wir machen das jetzt.")]
        let english = [u("Timo", 0, 5, "So I think we should send the list out today and then talk on Friday."),
                       u("SPEAKER_01", 6, 9, "Yeah, that works for me, but I have to check it with the team.")]
        #expect(Notes.meetingLanguage(german) == "de" && Notes.meetingLanguage(english) == "en")
        #expect(Notes.meetingLanguage(german + english.prefix(1)) == "de")
        #expect(Notes.meetingLanguage(english + german.prefix(1) + english) == "en")
        #expect(Notes.meetingLanguage([u("Timo", 0, 5, "Bonjour, nous allons parler du projet et de la livraison demain matin.")]) == nil)
        #expect(Notes.meetingLanguage([u("Timo", 0, 1, "Hi.")]) == nil)
    }

    @Test func test_name_from_a_garbled_first_line_is_not_backed() {
        let us = [u("Timo", 0, 2, "Servus, schön dass ihr da seid."),
                  u("SPEAKER_03", 2.5, 6, "Hallo, ich bin Moritz Dings Kaufmann äh wegen dem Angebot."), u("Timo", 7, 9, "Genau, das Angebot.")]
        #expect(backed([guess("SPEAKER_03", "Moritz Dings Kaufmann")], us).isEmpty)
        let plain = [u("SPEAKER_03", 0, 2, "Hi, this is Anna Huber from sales.")]
        #expect(backed([guess("SPEAKER_03", "Anna")], plain) == ["SPEAKER_03/Anna"])
    }

    @Test func test_names_followed_by_german_nouns_are_backed() {
        let cases: [([(String, String)], String)] = [
            ([("SPEAKER_02", "Hallo, ich bin Anna Huber Projektleiterin bei Kloud.")], "Anna Huber"),
            ([("SPEAKER_02", "ich bin Anna Huber äh Projektleiterin")], "Anna Huber"),
            ([("Timo", "Hallo Anna Projektplan ist fertig."), ("SPEAKER_02", "Super, danke.")], "Anna"),
        ]
        for (lines, name) in cases {
            let us = lines.enumerated().map { u($1.0, Double($0), Double($0) + 0.9, $1.1) }
            #expect(backed([guess("SPEAKER_02", name)], us) == ["SPEAKER_02/\(name)"], "\(lines)")
        }
    }

    @Test func test_a_handover_names_the_next_speaker() {
        for handover in ["I finished the migration, over to you Bob.", "That's it from me, back to you Bob",
                         "Damit übergebe ich an Bob.", "Gut, weiter an Bob."] {
            let us = [u("Timo", 0, 2, handover), u("SPEAKER_01", 2.5, 4, "Thanks, so on my side …")]
            #expect(backed([guess("SPEAKER_01", "Bob")], us) == ["SPEAKER_01/Bob"], "\(handover)")
        }
    }

    @Test func test_a_name_guess_has_to_look_like_a_name() {
        let us = [u("SPEAKER_02", 0, 2, "Hallo, ich bin Speaker 3 und das ist SPEAKER_03."), u("SPEAKER_03", 3, 4, "Hi, this is Anna.")]
        for (label, name) in [("SPEAKER_02", "Speaker 3"), ("SPEAKER_03", "anna")] {
            #expect(backed([guess(label, name)], us).isEmpty)
        }
    }

    @Test func test_a_name_only_talked_about_is_not_backed() {
        let us = [u("Timo", 0, 3, "Ich hab gestern mit Moritz gesprochen, der kommt nicht."), u("SPEAKER_03", 3.5, 5, "Okay, schade."),
                  u("Timo", 6, 8, "Was meinst du, Maria?"), u("SPEAKER_04", 8.5, 10, "Passt für mich."),
                  u("Timo", 11, 12, "Danke Helena von der Heide."), u("SPEAKER_05", 12.5, 13, "Gerne.")]
        let guesses = [guess("SPEAKER_03", "Moritz"), guess("SPEAKER_04", "Maria"), guess("SPEAKER_05", "Helena von der Heide")]
        #expect(backed(guesses, us) == ["SPEAKER_04/Maria", "SPEAKER_05/Helena von der Heide"])
    }
}
