// Ask your meetings (#42): the prompt from the passages found (numbered, with meeting, date, time and who said it), the
// answer kept to the passages it was given, and the command: the notes' model, the access log names "ask" and every
// meeting sent, and a passage of a meeting kept on this Mac keeps the model local.
import Foundation
import Testing
import PalaverCloud
import PalaverCore
import PalaverDomain
@testable import PalaverLM

private let OTHER = "2026-11-02T09-00-00"

private func passage(_ n: Int, _ meeting: String, kind: String = "line", time: Double? = nil, speaker: String = "",
                     text: String, title: String = "Weekly with Northwind", date: String = "2026-10-21") -> JSONValue {
    .object([("n", .int(n)), ("meeting", .string(meeting)), ("title", .string(title)), ("date", .string(date)),
             ("time", time.map { .double($0) } ?? .null), ("speaker", .string(speaker)), ("kind", .string(kind)),
             ("text", .string(text))])
}

private func inputs(_ question: String = "Was haben wir mit Northwind zur Laufzeit vereinbart?",
                    passages: [JSONValue]? = nil) -> JSONValue {
    .object([("question", .string(question)), ("user", .string("Timo")), ("today", .string("2026-11-20")),
             ("passages", .array(passages ?? [
                passage(1, MEETING, time: 754.2, speaker: "", text: "Valerie: Die Laufzeit? / Lena: Bleibt bei 24 Monaten."),
                passage(2, MEETING, kind: "decision", text: "Laufzeit 24 Monate"),
                passage(3, OTHER, kind: "step", speaker: "Jonas", text: "Vertrag mit 24 Monaten schicken",
                        title: "Contract review", date: "2026-11-02"),
                passage(4, OTHER, kind: "my_notes", text: "Laufzeit nochmal prüfen", title: "Contract review", date: "2026-11-02"),
                passage(5, OTHER, kind: "line", text: "   "),
             ]))])
}

@Suite struct AskMeetingsTests {
    @Test func thePromptHasTheQuestionAndTheNumberedPassagesOnly() throws {
        let prompt = try AskMeetings.buildPrompt(inputs())
        #expect(prompt.hasPrefix("You answer Timo's questions about their past meetings."))
        for part in ["Never invent names, numbers, dates, decisions or facts.", "Today is 2026-11-20.",
                     "put the numbers of the passages it rests on in square brackets",
                     "## Question\nWas haben wir mit Northwind zur Laufzeit vereinbart?\n\n## Passages\n"
                     + "[1] 2026-10-21 · Weekly with Northwind · 12:34 · Valerie: Die Laufzeit? / Lena: Bleibt bei 24 Monaten.\n"
                     + "[2] 2026-10-21 · Weekly with Northwind · notes, decision: Laufzeit 24 Monate\n"
                     + "[3] 2026-11-02 · Contract review · notes, next step: Jonas: Vertrag mit 24 Monaten schicken\n"
                     + "[4] 2026-11-02 · Contract review · my notes: Laufzeit nochmal prüfen"] {
            #expect(prompt.contains(part), "\(part)")
        }
        #expect(!prompt.contains("[5]"))  // a passage without text is no passage
        #expect(AskMeetings.meetings(inputs()) == [MEETING, OTHER])
        #expect(AskMeetings.numbers(inputs()) == [1, 2, 3, 4])
    }

    @Test func whatCanNotBeAskedIsSaid() {
        #expect(String(describing: thrown { try AskMeetings.buildPrompt(inputs("  ")) }!) == "Type a question first.")
        #expect(String(describing: thrown { try AskMeetings.buildPrompt(inputs(passages: [])) }!) == "No passages to answer from.")
        // A meeting id that is no plain folder name is never a folder.
        #expect(AskMeetings.meetings(inputs(passages: [passage(1, "../secret", text: "x"), passage(2, ".hidden", text: "y"),
                                                       passage(3, MEETING, text: "z")])) == [MEETING])
    }

    @Test func theAnswerCitesOnlyPassagesItWasGiven() throws {
        let answer = try AskMeetings.checked(.object([
            ("answer", .string(" Die Laufzeit bleibt bei 24 Monaten [2][1], Jonas schickt den Vertrag [3] [9]. ")),
            ("sources", .array([.int(4), .int(2), .int(7), .double(1.5), .string("3")])),
        ]), numbers: [1, 2, 3, 4])
        #expect(answer["answer"] == .string("Die Laufzeit bleibt bei 24 Monaten [2][1], Jonas schickt den Vertrag [3] ."))
        #expect(answer["sources"] == .array([.int(2), .int(1), .int(3), .int(4)]))  // cited first, in order, then listed
        #expect(try AskMeetings.checked(.object([("answer", .string("Steht nicht drin.")), ("sources", .array([]))]),
                                        numbers: [1])["sources"] == .array([]))
        #expect(thrown { try AskMeetings.checked(.object([("sources", .array([]))]), numbers: [1]) } is BrokenAnswer)
        #expect(thrown { try AskMeetings.checked(.array([]), numbers: [1]) } is BrokenAnswer)
    }

    @Test func theCommandAnswersOnTheNotesModelAndLogsEveryMeetingSent() async throws {
        let home = Home()
        let first = home.meeting()
        let second = home.meeting(OTHER)
        try home.keys.write("anthropic.api_key", KEY)
        try home.settings.choose("notes", .string("anthropic"))
        let fake = FakeModel(json: .object([("answer", .string("24 Monate [2].")), ("sources", .array([.int(2)]))]))
        var ctx = home.context(fake)
        ctx.readInput = { Data(PythonJSON.dumps(inputs()).utf8) }
        #expect(try await run(["--no-notify", "ask"], ctx) == 0)
        #expect(home.said.last == #"{"answer": "24 Monate [2].", "sources": [2], "engine": "Anthropic API"}"#)
        #expect(fake.asked.first?.schema == AskMeetings.SCHEMA)
        let log = AccessLog.recent(stores: home.stores)
        #expect(log.first?["feature"] == .string("ask") && log.first?["meetings"] == .strings([MEETING, OTHER]))
        // A passage of a meeting kept on this Mac: the local model, nothing more sent.
        try LocalOnly.set(second.folder, on: true)
        #expect(try await run(["ask"], ctx) == 0)
        #expect(home.said.last?.hasSuffix(#""engine": "Gemma 4 12B on this Mac"}"#) == true)
        #expect(AccessLog.recent(stores: home.stores).count == 1)
        #expect(!FileManager.default.fileExists(atPath: first.notes.path))  // nothing written
        ctx.readInput = { Data(PythonJSON.dumps(inputs("")).utf8) }
        #expect(try await run(["ask"], ctx) == 1)
        #expect(home.said.last == #"{"error": "Type a question first."}"#)
        #expect(fake.asked.count == 2)  // said before a model ran
    }

    @Test func theCommandParses() throws {
        let o = try LMMain.parse(["--no-notify", "ask"])
        #expect(o.command == "ask" && o.folder == nil)
        #expect(throws: LMMain.UsageError.self) { try LMMain.parse(["ask", "/r/f"]) }
        #expect(throws: LMMain.UsageError.self) { try LMMain.parse(["ask", "--force"]) }
    }
}
