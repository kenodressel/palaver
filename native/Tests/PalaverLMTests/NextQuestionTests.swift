// The best next question: the last minutes (or at least two lines, at most 120), the prep, the user's notes cut at
// 4000 characters, at most three questions; earlier meetings kept on this Mac never reach a cloud model; nothing written.
// The best answer: the same inputs with `kind: "answer"`, its own rules and schema, at most three points.
import Foundation
import Testing
import PalaverCloud
import PalaverCore
import PalaverDomain
@testable import PalaverLM

private func line(_ speaker: String, _ start: Double, _ text: String) -> JSONValue {
    .object([("speaker", .string(speaker)), ("start", .double(start)), ("text", .string(text))])
}

@Suite struct NextQuestionTests {
    @Test func thePromptHoldsTheLastMinutesAndThePrep() throws {
        var lines = (0..<400).map { line("Valerie", Double($0), "Zeile \($0)") }
        lines.append(line("Timo", 1000, "   "))  // nothing said
        let inputs = JSONValue.object([
            ("user", .string("Timo")), ("now", .int(400)), ("lines", .array(lines)), ("title", .string("Contoso Angebot")),
            ("invitees", .strings(["Valerie", "Rico"])), ("quiet", .strings(["Rico"])),
            ("last_time", .array([.object([("title", .string("Kickoff")), ("start", .string("2026-10-14T10:00:00+02:00")),
                                           ("summary", .string("Start des Projekts.")),
                                           ("next_steps", .array([.object([("task", .string("Preis klären")), ("owner", .string("Rico"))]),
                                                                  .object([("task", .string(""))]), .string("x")]))])])),
            ("my_notes", .strings([String(repeating: "n", count: 5000), "  "])),
        ])
        let prompt = try NextQuestion.buildPrompt(inputs)
        #expect(prompt.hasPrefix("You help Timo during a meeting that is going on right now. Suggest one to three questions Timo could ask next."))
        for part in ["Never invent names, numbers, dates, decisions or facts.", "- an invitee who has not said anything yet;",
                     "Write the questions in the language the meeting is held in.", "## Context", "Meeting: Contoso Angebot",
                     "Invited: Valerie, Rico", "Invited but not heard yet: Rico",
                     "Last time (2026-10-14, Kickoff): Start des Projekts.", "- open next step: Preis klären (Rico)",
                     "Timo's own notes on the meeting:", "## Transcript (the last minutes)"] {
            #expect(prompt.contains(part), "\(part)")
        }
        #expect(prompt.contains(String(repeating: "n", count: 4000) + "\n") && !prompt.contains(String(repeating: "n", count: 4001)))
        // The last five minutes: from 100 s on, at most 120 lines.
        let said = prompt.components(separatedBy: "## Transcript (the last minutes)\n")[1].split(separator: "\n")
        #expect(said.count == 120 && said.last == "[06:39] Valerie: Zeile 399" && said.first == "[04:40] Valerie: Zeile 280")
    }

    @Test func atLeastTwoLinesAndNothingSaidIsSaid() throws {
        let inputs = JSONValue.object([("now", .int(4000)), ("lines", .array([line("", 10, "Eins"), line("Valerie", 20, "Zwei"),
                                                                              line("Valerie", 3700, "Drei")]))])
        let prompt = try NextQuestion.buildPrompt(inputs)
        #expect(prompt.hasPrefix("You help the user during") && prompt.hasSuffix("[00:20] Valerie: Zwei\n[1:01:40] Valerie: Drei"))
        #expect(thrown { try NextQuestion.buildPrompt(.object([("lines", .array([line("V", 0, " ")]))])) } is NextQuestion.NothingYet)
    }

    @Test func theCommandAnswersWithTheQuestionsAndTheEngine() async throws {
        let home = Home()
        let paths = home.meeting()
        let fake = FakeModel(json: .object([("questions", .array([
            .object([("question", .string("Wer schickt das Angebot?")), ("why", .string("ohne Namen"))])]))]))
        var ctx = home.context(fake)
        ctx.readInput = { Data(PythonJSON.dumps(.object([("lines", .array([line("Valerie", 1, "Das Angebot kommt.")]))])).utf8) }
        #expect(try await run(["next-question", paths.folder.path], ctx) == 0)
        #expect(home.said == [#"{"questions": [{"question": "Wer schickt das Angebot?", "why": "ohne Namen"}], "engine": "Gemma 4 12B on this Mac"}"#])
        #expect(fake.asked.first?.schema == NextQuestion.SCHEMA)
        #expect(!FileManager.default.fileExists(atPath: paths.notes.path))  // nothing written
        ctx.readInput = { Data(#"{"lines": []}"#.utf8) }
        #expect(try await run(["next-question", paths.folder.path], ctx) == 1)
        #expect(home.said.last == #"{"error": "Nothing has been said yet."}"#)
        ctx.readInput = { Data("not json".utf8) }
        #expect(try await run(["next-question", paths.folder.path], ctx) == 1)
        #expect(home.said.last == #"{"error": "the inputs are not a JSON object"}"#)
    }

    @Test func theBestAnswerHasItsOwnRulesOnTheSameContext() throws {
        let inputs = JSONValue.object([
            ("kind", .string("answer")), ("user", .string("Timo")), ("now", .int(60)), ("title", .string("Contoso Angebot")),
            ("lines", .array([line("Valerie", 30, "Timo, ab wann könnt ihr starten?")])),
            ("my_notes", .strings(["Start frühestens im März"])),
        ])
        let prompt = try NextQuestion.buildPrompt(inputs)
        #expect(prompt.hasPrefix("You help Timo during a meeting that is going on right now. Suggest the best answer Timo could give now."))
        for part in ["the latest question in the transcript that was put to Timo", "You may use your general knowledge",
                     "Never invent facts about Timo", "Meeting: Contoso Angebot", "Start frühestens im März",
                     "[00:30] Valerie: Timo, ab wann könnt ihr starten?"] {
            #expect(prompt.contains(part), "\(part)")
        }
        #expect(!prompt.contains("Suggest one to three questions"))
        #expect(NextQuestion.kind(inputs) == NextQuestion.ANSWER && NextQuestion.kind(.object([])) == NextQuestion.QUESTIONS)
        #expect(NextQuestion.kind(.object([("kind", .string("poem"))])) == NextQuestion.QUESTIONS)
    }

    @Test func theBestAnswerIsKeptToItsSchema() throws {
        let a = try NextQuestion.checkedAnswer(.object([
            ("to", .string(" Ab wann könnt ihr starten? ")), ("asked_by", .string("Valerie")), ("time", .string("about noon")),
            ("answer", .string("Wir können im März starten.")), ("points", .strings(["a", " ", "b", "c", "d"])),
            ("basis", .string("Timos Notizen.")),
        ]))
        #expect(a == .object([("to", .string("Ab wann könnt ihr starten?")), ("asked_by", .string("Valerie")),
                              ("time", .string("")), ("answer", .string("Wir können im März starten.")),
                              ("points", .strings(["a", "b", "c"])), ("check", .string("")), ("basis", .string("Timos Notizen."))]))
        #expect(try NextQuestion.checkedAnswer(.object([("answer", .string("x")), ("time", .string("12:34"))]))["time"] == .string("12:34"))
        #expect(thrown { try NextQuestion.checkedAnswer(.object([("questions", .array([]))])) } is BrokenAnswer)
    }

    @Test func theCommandAnswersWithTheBestAnswer() async throws {
        let home = Home()
        let paths = home.meeting()
        let fake = FakeModel(json: .object([("to", .string("Start?")), ("asked_by", .string("Valerie")), ("time", .string("00:01")),
                                            ("answer", .string("Im März.")), ("points", .array([])), ("check", .string("")),
                                            ("basis", .string("Notizen."))]))
        var ctx = home.context(fake)
        ctx.readInput = { Data(PythonJSON.dumps(.object([("kind", .string("answer")),
                                                         ("lines", .array([line("Valerie", 1, "Ab wann?")]))])).utf8) }
        #expect(try await run(["next-question", paths.folder.path], ctx) == 0)
        #expect(home.said == [#"{"answer": {"to": "Start?", "asked_by": "Valerie", "time": "00:01", "answer": "Im März.", "points": [], "check": "", "basis": "Notizen."}, "engine": "Gemma 4 12B on this Mac"}"#])
        #expect(fake.asked.first?.schema == NextQuestion.ANSWER_SCHEMA)
    }

    @Test func aCloudModelGetsNoEarlierMeetingKeptOnThisMac() async throws {
        let home = Home()
        let paths = home.meeting()
        let kept = "2026-10-01T09-00-00", shared = "2026-10-08T09-00-00"
        home.meeting(kept)
        home.meeting(shared)
        try LocalOnly.set(home.outputDir.appendingPathComponent(kept), on: true)
        try home.keys.write("anthropic.api_key", KEY)
        try home.settings.choose(NextQuestion.FEATURE, .string("anthropic"))
        let fake = FakeModel(json: .object([("questions", .array([]))]))
        var ctx = home.context(fake)
        ctx.readInput = { Data(PythonJSON.dumps(.object([
            ("lines", .array([line("Valerie", 1, "Hallo")])), ("meetings", .strings([MEETING, kept, shared])),
            ("last_time", .array([.object([("id", .string(kept)), ("summary", .string("Geheimes Gespräch"))]),
                                  .object([("id", .string(shared)), ("summary", .string("Offenes Gespräch"))])])),
        ])).utf8) }
        #expect(try await run(["next-question", paths.folder.path], ctx) == 0)
        let prompt = try #require(fake.asked.first?.prompt)
        #expect(!prompt.contains("Geheimes") && prompt.contains("Offenes Gespräch"))
        #expect(home.said.last?.hasSuffix(#""engine": "Anthropic API"}"#) == true)
        let log = AccessLog.recent(stores: home.stores)
        #expect(log.first?["feature"] == .string("coach") && log.first?["meetings"] == .strings([MEETING, shared]))
        // The current meeting kept on this Mac keeps the question local.
        try LocalOnly.set(paths.folder, on: true)
        #expect(try await run(["next-question", paths.folder.path], ctx) == 0)
        #expect(home.said.last?.hasSuffix(#""engine": "Gemma 4 12B on this Mac"}"#) == true)
    }
}
