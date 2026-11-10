// `palaver-lm notes`: notes.json with notes.py's keys, read by the app's read side and up to date by its staleness
// check; the repair and retry path; skipped and failed runs said in session.log; the usage line; sorting into projects.
import Foundation
import Testing
import PalaverCloud
import PalaverCore
import PalaverDomain
@testable import PalaverLM

@Suite struct NotesRunTests {
    @Test func notesAreWrittenWithNotesPysKeysAndAreThenUpToDate() async throws {
        let home = Home()
        let paths = home.meeting()
        let fake = FakeModel(json: NOTES_ANSWER, ControlFallback.suggest)
        #expect(try await run(["notes", paths.folder.path], home.context(fake)) == 0)
        let notes = try #require(Notes.load(paths))
        #expect(PyDict<JSONValue>(notes)!.keys == ["title", "summary", "sections", "next_steps", "decisions", "speaker_names",
                                                    "transcript_hash", "generated_at"])
        #expect(notes["title"] == .string("Angebot für Contoso"))
        #expect(notes["speaker_names"]?.arrayValue?.count == 1)  // only the transcript's unnamed voices
        #expect(!Notes.isStale(paths, GERMAN))
        // The app shows the names given later in place of the labels.
        let named = Notes.withNames(notes, PyDict([("SPEAKER_01", "Valerie")]))
        #expect(named["next_steps"]?.arrayValue?.first?["owner"] == .string("Valerie"))
        #expect(home.said.contains("Writing notes with Gemma 4 12B on this Mac…"))
        #expect(home.said.contains("Wrote \(paths.notes.path) — Angebot für Contoso"))
        // Up to date: the model is not asked again, unless --force.
        let asked = fake.asked.count
        #expect(try await run(["notes", paths.folder.path], home.context(fake)) == 0)
        #expect(fake.asked.count == asked && home.said.last == "Notes are up to date")
        let again = FakeModel(json: NOTES_ANSWER, ControlFallback.suggest)
        #expect(try await run(["notes", paths.folder.path, "--force"], home.context(again)) == 0)
        #expect(again.asked.first?.prompt == fake.asked.first?.prompt)
    }

    @Test func theRunIsInSessionLogAndTheUsageLog() async throws {
        let home = Home()
        let paths = home.meeting()
        #expect(try await run(["notes", paths.folder.path], home.context(FakeModel(json: NOTES_ANSWER, ControlFallback.suggest))) == 0)
        let events = home.events(paths)
        let start = try #require(events.first { $0["event"] == .string("notes_start") })
        #expect(start["engine"] == .string("local") && start["model"] == .string(ModelChoice.DEFAULT_LOCAL_MODEL))
        #expect(start["swift"] == .bool(true) && start["pid"] != nil)  // stamped
        let done = try #require(events.first { $0["event"] == .string("notes_done") })
        #expect(done["seconds"]?.doubleValue != nil && done["engine"] == .string("local"))
        #expect(events.contains { $0["event"] == .string("projects_start") } && events.contains { $0["event"] == .string("projects_done") })
        let used = home.usage().first { $0["kind"] == .string("notes") }
        #expect(used?["ok"] == .bool(true) && used?["engine"] == .string("local") && used?["model"] == .string(ModelChoice.DEFAULT_LOCAL_MODEL))
    }

    @Test func aBrokenAnswerIsAskedForAgainAndRepaired() async throws {
        let home = Home()
        let paths = home.meeting()
        let fake = FakeModel([.text(#"{"title": "T", "summary": "S", "sections": [{"heading": "", "points": []}]}"#),
                              .text("<think>hm</think>```json\n{\"title\": \"Zweiter\nVersuch\", \"summary\": \"S\", "
                                    + "\"speaker_names\": {\"SPEAKER_01\": \"Valerie\"}}\n```"),
                              .json(ControlFallback.suggest)])
        #expect(try await run(["notes", paths.folder.path], home.context(fake)) == 0)
        let notes = try #require(Notes.load(paths))
        #expect(notes["title"] == .string("Zweiter\nVersuch") && notes["sections"] == .array([]))
        #expect(notes["speaker_names"] == .array([.object([("evidence", .string("")), ("name", .string("Valerie")),
                                                            ("label", .string("SPEAKER_01"))])]))
        #expect(fake.asked.prefix(2).allSatisfy { $0.prompt == fake.asked[0].prompt })
    }

    @Test func twoBrokenAnswersFailTheRunAndLeaveTheNotesAsTheyWere() async throws {
        let home = Home()
        let paths = home.meeting()
        let fake = FakeModel([.text("not JSON"), .text(#"{"summary": "no title"}"#)])
        #expect(try await run(["notes", paths.folder.path], home.context(fake)) == 1)
        #expect(Notes.load(paths) == nil && fake.asked.count == 2)
        let failed = try #require(home.events(paths).first { $0["event"] == .string("notes_failed") })
        #expect(failed["error"]?.stringValue?.hasPrefix("The fake model did not return a valid answer: 'title' missing") == true)
        #expect(home.said.last?.hasPrefix("warning: notes failed: The fake model did not return a valid answer") == true)
        #expect(!home.events(paths).contains { $0["event"] == .string("notes_done") })
        #expect(home.usage().first { $0["kind"] == .string("notes") }?["ok"] == .bool(false))
    }

    @Test func noModelSetUpSkipsTheNotesAndSaysWhy() async throws {
        let home = Home()
        let paths = home.meeting()
        try PythonJSON.write(.object([("engines", .object([("notes", .string(ModelChoice.PENDING))]))]), to: home.stores.settings,
                             indent: 2, ensureAscii: false)
        let fake = FakeModel(json: NOTES_ANSWER)
        #expect(try await run(["notes", paths.folder.path], home.context(fake)) == 1)
        #expect(fake.asked.isEmpty && Notes.load(paths) == nil)
        #expect(home.said.last == "Skipping notes: \(EngineChoice.PENDING_TEXT)")
        #expect(home.events(paths).first { $0["event"] == .string("notes_skipped") }?["reason"] == .string(EngineChoice.PENDING_TEXT))
        // Without the local runner built in, a local engine says so instead of running.
        try FileManager.default.removeItem(at: home.stores.settings)
        #expect(try await run(["notes", paths.folder.path], home.context()) == 1)
        #expect(home.said.last == "Skipping notes: \(LocalModels.NOT_BUILT)")
    }

    @Test func aMeetingWithoutATranscriptIsRefused() async throws {
        let home = Home()
        let folder = home.outputDir.appendingPathComponent(MEETING, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(try await run(["notes", folder.path], home.context(FakeModel(json: NOTES_ANSWER))) == 2)
        #expect(home.said == ["error: \(folder.path) has no transcript yet — run `process` first."])
    }

    @Test func theUsersCorrectionsAndNotesReachThePromptAndTheHashes() async throws {
        let home = Home()
        let paths = home.meeting()
        // A removed voice says nothing; the user's own notes count more; the user's title is a hint.
        try PythonJSON.write(.strings(["SPEAKER_02"]), to: paths.speakersIgnored, indent: 2, ensureAscii: false)
        _ = try MyNotes.save(paths.folder, paragraphs: .array([.object([("text", .string("Preis noch offen")), ("at", .double(30))])]))
        try Titles.save(paths, "Preisrunde Contoso")
        let fake = FakeModel(json: NOTES_ANSWER, ControlFallback.suggest)
        #expect(try await run(["notes", paths.folder.path], home.context(fake)) == 0)
        let prompt = try #require(fake.asked.first?.prompt)
        #expect(!prompt.contains("nächste Woche") && prompt.contains("Preis noch offen") && prompt.contains("\"Preisrunde Contoso\""))
        #expect(fake.asked.first?.schema["properties"]?["decisions"]?["items"]?["required"] == .strings(["text", "mine"]))
        let notes = try #require(Notes.load(paths))
        #expect(notes["my_notes_hash"] == .string(Notes.myNotesHash(MyNotes.promptText(paths.folder))))
        #expect(notes["transcript_hash"] == .string(Notes.transcriptHash(try Speakers.withoutIgnored(paths, GERMAN))))
        #expect(Notes.staleReason(paths, try Speakers.withoutIgnored(paths, GERMAN)) == nil)
        // The notes change: the notes are out of date again.
        _ = try MyNotes.save(paths.folder, paragraphs: .array([.object([("text", .string("Preis geklärt"))])]))
        #expect(Notes.staleReason(paths, try Speakers.withoutIgnored(paths, GERMAN)) == "my_notes")
    }

    @Test func aFreshMeetingIsSortedIntoTheProjectTheModelSuggests() async throws {
        let home = Home()
        let paths = home.meeting()
        let suggestion = JSONValue.object([
            ("new_projects", .array([.object([("key", .string("new1")), ("name", .string("Contoso")),
                                              ("description", .string("Das Angebot für Contoso."))])])),
            ("assignments", .array([.object([("meeting", .string(MEETING)), ("projects", .strings(["new1"]))])])),
        ])
        let fake = FakeModel(json: NOTES_ANSWER, suggestion)
        #expect(try await run(["notes", paths.folder.path], home.context(fake)) == 0)
        let store = ProjectStore(path: home.stores.projects)
        let pid = try #require(store.find("Contoso"))
        #expect(store.projects[pid]?["description_by"] == .string("model"))
        #expect(store.ofMeeting(MEETING)[pid]?["by"] == .string("model"))
        #expect(home.said.last == "Project: Contoso")
        #expect(fake.asked.last?.prompt.contains("- id \(MEETING): “Angebot für Contoso” on 2026-10-21") == true)
    }

    @Test func unreadableVoiceCorrectionsAreSaidAndTheNotesAreWrittenWithEveryVoice() async throws {
        let home = Home()
        let paths = home.meeting()
        // A line given to another voice (applied by name) while speakers.json is no object: the names can't be read.
        try Data(#"[{"start": 9, "end": 13, "label": "SPEAKER_02"}]"#.utf8).write(to: paths.speakersLines)
        try Data("[]".utf8).write(to: paths.speakers)
        #expect(try await run(["notes", paths.folder.path], home.context(FakeModel(json: NOTES_ANSWER))) == 0)
        #expect(home.said.contains { $0.hasPrefix("warning: the voices removed as noise could not be read (") })
        #expect(Notes.load(paths)?["title"] == .string("Angebot für Contoso"))
        let log = try String(contentsOf: paths.sessionLog, encoding: .utf8)
        #expect(log.contains("could not read the ignored voices: speakers.json is not an object"))
    }
}
