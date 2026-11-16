// The live assistant (#15): catch me up over the last 5/10/15 minutes, the next steps so far, a free question with
// quotes; the notes' model (a meeting kept on this Mac stays local), the access log names it "assistant"; nothing written.
import Foundation
import Testing
import PalaverCloud
import PalaverCore
import PalaverDomain
@testable import PalaverLM

private func line(_ speaker: String, _ start: Double, _ text: String) -> JSONValue {
    .object([("speaker", .string(speaker)), ("start", .double(start)), ("text", .string(text))])
}

private func inputs(_ kind: String, _ extra: [(String, JSONValue)] = [], lines: [JSONValue]? = nil) -> JSONValue {
    .object([("kind", .string(kind)), ("user", .string("Timo")), ("now", .int(1200)), ("title", .string("Contoso Angebot")),
             ("lines", .array(lines ?? [line("Valerie", 30, "Wir starten mit dem Budget."),
                                        line("Timo", 500, "Das Budget sind 40.000 Euro."),
                                        line("Others", 1000, "Carla schickt das Angebot bis Freitag."),
                                        line("Valerie", 1100, "   ")]))] + extra)
}

@Suite struct LiveAssistantTests {
    @Test func catchMeUpReadsOnlyTheLastMinutes() throws {
        var prompt = try LiveAssistant.buildPrompt(inputs("catchup", [("minutes", .int(15))]))
        #expect(prompt.hasPrefix("You help Timo during a meeting that is going on right now."))
        for part in ["Never invent names, numbers, dates, decisions or facts.", "what was said in the last 15 minutes",
                     "Meeting: Contoso Angebot", "## Transcript (the last 15 minutes)\n[08:20] Timo: Das Budget sind 40.000 Euro.\n"
                     + "[16:40] Others: Carla schickt das Angebot bis Freitag."] {
            #expect(prompt.contains(part), "\(part)")
        }
        #expect(!prompt.contains("Wir starten"))
        // 5 minutes (the default, also for a span not offered): the last line alone is too little, the last two are kept.
        for minutes: JSONValue in [.int(5), .int(7), .null] {
            prompt = try LiveAssistant.buildPrompt(inputs("catchup", [("minutes", minutes)]))
            #expect(prompt.contains("in the last 5 minutes") && prompt.contains("[08:20] Timo") && !prompt.contains("Wir starten"))
        }
    }

    @Test func nextStepsAndAskReadTheWholeCallSoFar() throws {
        let steps = try LiveAssistant.buildPrompt(inputs("next_steps"))
        #expect(steps.contains("List the next steps and the decisions of the meeting so far."))
        #expect(steps.hasSuffix("## Transcript (so far)\n[00:30] Valerie: Wir starten mit dem Budget.\n[08:20] Timo: Das Budget sind "
                                + "40.000 Euro.\n[16:40] Others: Carla schickt das Angebot bis Freitag."))
        let question = "  Welche Zahl wurde fürs Budget genannt? " + String(repeating: "x", count: 600)
        let ask = try LiveAssistant.buildPrompt(inputs("ask", [("question", .string(question))]))
        #expect(ask.contains("Answer in the language of the question."))
        #expect(ask.contains("## Question\nWelche Zahl wurde fürs Budget genannt? x"))
        #expect(ask.contains(String(repeating: "x", count: 500 - 39)) && !ask.contains(String(repeating: "x", count: 500 - 38)))
        #expect(ask.contains("## Transcript (so far)\n[00:30] Valerie"))
    }

    @Test func whatCanNotBeAskedIsSaid() {
        #expect(thrown { try LiveAssistant.buildPrompt(inputs("catchup", lines: [line("V", 0, " ")])) } is LiveAssistant.NothingYet)
        #expect(String(describing: thrown { try LiveAssistant.buildPrompt(inputs("ask", [("question", .string("  "))])) }!)
                == "Type a question first.")
        #expect(thrown { try LiveAssistant.buildPrompt(inputs("summary")) } is LiveAssistant.BadAsk)
    }

    @Test func theAnswersAreKeptToTheirSchema() throws {
        let bullets = try LiveAssistant.checked("catchup", .object([("bullets", .strings(["a", " ", "b", "c", "d", "e", "f"]))]))
        #expect(bullets == .object([("bullets", .strings(["a", "b", "c", "d", "e"]))]))
        let steps = try LiveAssistant.checked("next_steps", .object([
            ("next_steps", .array([.object([("owner", .string(" Carla ")), ("task", .string("Angebot schicken"))]),
                                   .object([("task", .string(""))]), .string("x"), .object([("task", .string("Preis klären"))])])),
            ("decisions", .strings(["Budget 40.000 Euro", ""])),
        ]))
        #expect(steps == .object([("next_steps", .array([.object([("owner", .string("Carla")), ("task", .string("Angebot schicken"))]),
                                                         .object([("owner", .string("")), ("task", .string("Preis klären"))])])),
                                  ("decisions", .strings(["Budget 40.000 Euro"]))]))
        let answer = try LiveAssistant.checked("ask", .object([
            ("answer", .string(" 40.000 Euro. ")),
            ("quotes", .array([.object([("time", .string("08:20")), ("speaker", .string("Timo")), ("text", .string("Das Budget sind 40.000 Euro."))]),
                               .object([("time", .string("gleich am Anfang")), ("speaker", .string("Valerie")), ("text", .string("Budget"))]),
                               .object([("time", .string("1:02:03")), ("text", .string(" "))]),
                               .object([("text", .string("c"))]), .object([("text", .string("d"))])])),
        ]))
        #expect(answer["answer"] == .string("40.000 Euro."))
        #expect(answer["quotes"]?.arrayValue?.map { $0["time"] } == [.string("08:20"), .string(""), .string("")])  // no made-up time
        #expect(answer["quotes"]?.arrayValue?.count == 3)
        #expect(thrown { try LiveAssistant.checked("catchup", .object([("points", .array([]))])) } is BrokenAnswer)
        #expect(thrown { try LiveAssistant.checked("ask", .object([("quotes", .array([]))])) } is BrokenAnswer)
    }

    @Test func theCommandAnswersWithTheKindAndTheEngine() async throws {
        let home = Home()
        let paths = home.meeting()
        let fake = FakeModel(json: .object([("bullets", .strings(["Das Budget sind 40.000 Euro."]))]))
        var ctx = home.context(fake)
        ctx.readInput = { Data(PythonJSON.dumps(inputs("catchup")).utf8) }
        #expect(try await run(["assistant", paths.folder.path], ctx) == 0)
        #expect(home.said == [#"{"kind": "catchup", "bullets": ["Das Budget sind 40.000 Euro."], "engine": "Gemma 4 12B on this Mac"}"#])
        #expect(fake.asked.first?.schema == LiveAssistant.CATCH_UP_SCHEMA)
        #expect(!FileManager.default.fileExists(atPath: paths.notes.path))  // nothing written
        ctx.readInput = { Data(PythonJSON.dumps(inputs("ask", [("question", .string(""))])).utf8) }
        #expect(try await run(["assistant", paths.folder.path], ctx) == 1)
        #expect(home.said.last == #"{"error": "Type a question first."}"#)
        #expect(fake.asked.count == 1)  // said before the model ran
        ctx.readInput = { Data("[]".utf8) }
        #expect(try await run(["assistant", paths.folder.path], ctx) == 1)
        #expect(home.said.last == #"{"error": "the inputs are not a JSON object"}"#)
    }

    /// The notes' model answers; the access log says "assistant"; a meeting kept on this Mac never goes to the cloud.
    @Test func itRunsOnTheNotesModelAndKeepsAMeetingOnThisMacLocal() async throws {
        let home = Home()
        let paths = home.meeting()
        try home.keys.write("anthropic.api_key", KEY)
        try home.settings.choose("notes", .string("anthropic"))
        try home.settings.choose(NextQuestion.FEATURE, .string(ModelChoice.LOCAL))  // the coach's own choice is not it
        let fake = FakeModel(json: .object([("answer", .string("40.000 Euro")), ("quotes", .array([]))]))
        var ctx = home.context(fake)
        ctx.readInput = { Data(PythonJSON.dumps(inputs("ask", [("question", .string("Welches Budget?"))])).utf8) }
        #expect(try await run(["assistant", paths.folder.path], ctx) == 0)
        #expect(home.said.last == #"{"kind": "ask", "answer": "40.000 Euro", "quotes": [], "engine": "Anthropic API"}"#)
        let log = AccessLog.recent(stores: home.stores)
        #expect(log.first?["feature"] == .string("assistant") && log.first?["meetings"] == .strings([MEETING]))
        try LocalOnly.set(paths.folder, on: true)
        #expect(try await run(["assistant", paths.folder.path], ctx) == 0)
        #expect(home.said.last?.hasSuffix(#""engine": "Gemma 4 12B on this Mac"}"#) == true)
        #expect(AccessLog.recent(stores: home.stores).count == 1)  // nothing more left this Mac
    }

    @Test func theCommandParses() throws {
        let o = try LMMain.parse(["--no-notify", "assistant", "/r/f"])
        #expect(o.command == "assistant" && o.folder == "/r/f")
        #expect(throws: LMMain.UsageError.self) { try LMMain.parse(["assistant"]) }
        #expect(throws: LMMain.UsageError.self) { try LMMain.parse(["assistant", "/r/f", "--force"]) }
    }
}
