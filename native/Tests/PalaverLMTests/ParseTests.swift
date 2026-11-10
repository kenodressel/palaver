// Reading the model's answer: the repairs small models need, on hand-written broken answers, and what can't be repaired.
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverLM

@Suite struct ParseTests {
    @Test func thinkingSpecialTokensAndAFenceAroundTheObjectAreDropped() throws {
        let text = """
        <think>The user wants {notes}. Let me think…</think>Sure! ```json
        <|channel>{"title": "Planung", "summary": "Kurz.<audio|>", "sections": [], "next_steps": [], "decisions": [],
         "speaker_names": []}
        ```
        """
        let notes = try NotesAnswer.parse(text)
        #expect(notes["title"] == .string("Planung") && notes["summary"] == .string("Kurz."))
        // Only the end of the thinking, when the chat template opened it.
        let opened = try NotesAnswer.parse(#"so {maybe} this</think>{"title": "T", "summary": "S"}"#)
        #expect(opened["title"] == .string("T") && opened["sections"] == .array([]) && opened["speaker_names"] == .array([]))
    }

    @Test func rawLineBreaksAndTabsInsideStringsAreTaken() throws {
        let notes = try NotesAnswer.parse("{\"title\": \"Zeile eins\nZeile\tzwei\", \"summary\": \"ok\"}")
        #expect(notes["title"] == .string("Zeile eins\nZeile\tzwei"))
        #expect(Answer.lenient("{\"a\": \"x\\\"\n\"}") == "{\"a\": \"x\\\"\\u000a\"}")  // an escaped quote stays inside
    }

    @Test func aDictOfSpeakerNamesBecomesTheirList() throws {
        let notes = try NotesAnswer.parse(#"""
        {"title": "T", "summary": "S", "speaker_names": {"SPEAKER_01": "Valerie", "SPEAKER_02": {"name": "Timo", "evidence": "ich bin Timo"},
         "SPEAKER_03": "  "}}
        """#)
        #expect(notes["speaker_names"] == .array([
            .object([("evidence", .string("")), ("name", .string("Valerie")), ("label", .string("SPEAKER_01"))]),
            .object([("evidence", .string("ich bin Timo")), ("name", .string("Timo")), ("label", .string("SPEAKER_02"))]),
        ]))
    }

    @Test func textsAndObjectsMixedUpArePutRight() throws {
        let notes = try NotesAnswer.parse(#"""
        {"title": "T", "summary": "S",
         "sections": ["Nur eine Überschrift", {"heading": {"text": "Preis"}, "points": "Ein Punkt"},
                      {"heading": "Termine", "points": [{"text": {"text": "Freitag"}, "details": "Valerie: bis Freitag"},
                                                         {"text": "Montag", "details": [{"text": "x"}, null, ""]}]}],
         "next_steps": ["Angebot schicken", {"owner": {"name": "Valerie"}, "task": {"text": "Preis klären"}},
                        {"owner": "Timo", "text": "Rückruf"}, {"owner": "Timo", "task": ""}],
         "decisions": [{"decision": "Freitag"}, "Montag", ""]}
        """#)
        #expect(notes["sections"] == .array([
            .object([("heading", .string("Nur eine Überschrift")), ("points", .array([]))]),
            .object([("heading", .string("Preis")), ("points", .array([.object([("text", .string("Ein Punkt")), ("details", .array([]))])]))]),
            .object([("heading", .string("Termine")), ("points", .array([
                .object([("text", .string("Freitag")), ("details", .strings(["Valerie: bis Freitag"]))]),
                .object([("text", .string("Montag")), ("details", .strings(["x"]))]),
            ]))]),
        ]))
        #expect(notes["next_steps"] == .array([
            .object([("owner", .string("")), ("task", .string("Angebot schicken"))]),
            .object([("owner", .string("Valerie")), ("task", .string("Preis klären"))]),
            .object([("owner", .string("Timo")), ("task", .string("Rückruf"))]),
        ]))  // a step without a task is dropped
        #expect(notes["decisions"] == .strings(["Freitag", "Montag"]) && notes["decisions_mine"] == nil)
    }

    @Test func mineIsTakenAlsoAsTextAndDecisionsFromMyNotesAreListedByIndex() throws {
        let notes = try NotesAnswer.parse(#"""
        {"title": "T", "summary": "S",
         "sections": [{"heading": "H", "points": [{"text": "a", "details": [], "mine": "True"}, {"text": "b", "details": [], "mine": false}]}],
         "next_steps": [{"owner": "", "task": "t", "mine": " true "}],
         "decisions": [{"text": "d0", "mine": false}, {"text": "d1", "mine": "true"}, {"text": "d2", "mine": true}],
         "decisions_mine": [7]}
        """#)
        let points = notes["sections"]?.arrayValue?.first?["points"]?.arrayValue
        #expect(points?[0]["mine"] == .bool(true) && points?[1]["mine"] == nil)
        #expect(notes["next_steps"]?.arrayValue?.first?["mine"] == .bool(true))
        #expect(notes["decisions"] == .strings(["d0", "d1", "d2"]) && notes["decisions_mine"] == .array([.int(1), .int(2)]))
    }

    @Test func whatCantBeRepairedIsABrokenAnswer() {
        let broken = [
            "no object here",
            #"{"summary": "S"}"#,  // no title
            #"{"title": "T", "summary": "S", "sections": {"heading": "H"}}"#,  // not a list
            #"{"title": "T", "summary": "S", "sections": [{"heading": " ", "points": []}]}"#,  // an empty section
            #"{"title": "T", "summary": "S", "sections": [42]}"#,
            #"{"title": "T", "summary": "S", "next_steps": [{"owner": "Timo"}]}"#,  // a step without its text
            #"{"title": "T", "summary": "S", "decisions": [{"text": "d", "mine": "maybe"}]}"#,
            #"{"title": "T", "summary": "S", "sections": [}"#,
            "[1, 2]",
        ]
        for text in broken {
            #expect(thrown { try NotesAnswer.parse(text) } is BrokenAnswer, "\(text)")
        }
    }

    @Test func projectsAndQuestionsAnswersAreCheckedToo() throws {
        #expect(try ProjectsPrompt.parseAnswer(#"x {"assignments": []} y"#) == .object([
            ("assignments", .array([])), ("new_projects", .array([])), ("descriptions", .array([]))]))
        #expect(thrown { try ProjectsPrompt.parseAnswer(#"{"new_projects": []}"#) } is BrokenAnswer)
        #expect(try ProjectsPrompt.parseDescription(#"{"description": "Kurz."}"#)["description"] == .string("Kurz."))
        #expect(thrown { try ProjectsPrompt.parseDescription(#"{"text": "Kurz."}"#) } is BrokenAnswer)
        let questions = try NextQuestion.parse(#"""
        {"questions": [{"question": " Wer schickt das Angebot? ", "why": "ohne Namen"}, {"question": ""}, "x",
                       {"question": "Q2"}, {"question": "Q3", "why": "w"}, {"question": "Q4", "why": "w"}]}
        """#)
        #expect(questions == .object([("questions", .array([
            .object([("question", .string("Wer schickt das Angebot?")), ("why", .string("ohne Namen"))]),
            .object([("question", .string("Q2")), ("why", .string(""))]),
            .object([("question", .string("Q3")), ("why", .string("w"))]),
        ]))]))
        #expect(thrown { try NextQuestion.parse(#"{"answer": []}"#) } is BrokenAnswer)
    }
}
