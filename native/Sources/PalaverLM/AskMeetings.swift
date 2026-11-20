// Ask your meetings (#42): one question across the whole archive, answered from passages the window's server found
// for it (transcript lines, notes, the user's own notes), never from whole transcripts. Each passage has a number; the
// answer cites the numbers it rests on, so every claim leads back to its meeting and the moment it was said.
//
// It runs on the model the user chose for the notes. The meetings of the passages decide where: one kept on this Mac
// makes it the local model (`EngineChoice` with every passage's folder), so a cloud model never sees such a passage.
import Foundation
import PalaverCore
import PalaverDomain

public enum AskMeetings {
    /// The model it runs on: the notes' (Settings → Language model).
    public static let FEATURE = "notes"
    /// What the access log and the test model call it.
    public static let LOG_FEATURE = "ask"
    public static let KIND = "ask-meetings"
    public static let MAX_QUESTION_CHARS = 500
    public static let MAX_SOURCES = 12
    public static let BUSY = "The language model is busy; try again in a minute."

    /// The inputs ask for something it does not do.
    public struct BadAsk: Error, CustomStringConvertible {
        public let description: String
    }

    public static let SCHEMA: JSONValue = .object([
        ("type", .string("object")),
        ("properties", .object([
            ("answer", .object([("type", .string("string")), ("description", .string(
                "The answer in one to five sentences, each statement followed by the numbers of the passages it rests on "
                    + "in square brackets, e.g. [2] or [1][4]; or that the passages do not say."))])),
            ("sources", .object([("type", .string("array")), ("maxItems", .int(MAX_SOURCES)),
                                 ("items", .object([("type", .string("integer")),
                                                    ("description", .string("The number of a passage the answer uses."))]))])),
        ])),
        ("required", .strings(["answer", "sources"])),
    ])

    /// What the end-to-end tests' model answers when the test gave no answer: nothing found.
    public static let fallback: JSONValue = .object([("answer", .string("")), ("sources", .array([]))])

    static func rules(user: String, today: String) -> String {
        """
        You answer \(user)'s questions about their past meetings.

        Only use what the passages below show. Never invent names, numbers, dates, decisions or facts. The passages \
        were found by a search for the question: some may not be about it, leave those out. Transcript passages are \
        made by speech recognition, so words may be misheard; notes passages are summaries written after the meeting; \
        "my notes" are what \(user) wrote down.\(today.isEmpty ? "" : " Today is \(today).")

        Answer the question briefly, in the language of the question. After each statement put the numbers of the \
        passages it rests on in square brackets, e.g. [2] or [1][4]. When meetings say different things, say so and \
        which is the newest. When the passages do not answer the question, say so plainly. List in "sources" the \
        numbers of the passages you used.
        """
    }

    /// One passage as the prompt shows it: `[3] 2026-10-28 · Weekly with Northwind · 12:34 · Lena: …`.
    static func line(_ p: JSONValue) -> String {
        let n = NextQuestion.number(p["n"]).map { Int($0) } ?? 0
        var where_: [String] = []
        let date = NextQuestion.text(p["date"]), title = NextQuestion.text(p["title"])
        if !date.isEmpty { where_.append(date) }
        if !title.isEmpty { where_.append(title) }
        let kind = NextQuestion.text(p["kind"])
        let text = Py.strip(NextQuestion.text(p["text"]))
        let said: String
        switch kind {
        case "line", "":
            if let time = NextQuestion.number(p["time"]) { where_.append(NextQuestion.clock(time)) }
            let who = NextQuestion.text(p["speaker"])
            said = who.isEmpty ? text : "\(who): \(text)"
        case "my_notes":
            said = "my notes: \(text)"
        case "step":
            let owner = NextQuestion.text(p["speaker"])
            said = "notes, next step: \(owner.isEmpty ? "" : "\(owner): ")\(text)"
        default:
            said = "notes, \(kind): \(text)"
        }
        return "[\(n)] " + (where_ + [said]).joined(separator: " · ")
    }

    /// The question asked, trimmed and cut at `MAX_QUESTION_CHARS`.
    public static func question(_ v: JSONValue?) -> String {
        String(String.UnicodeScalarView(Py.strip(NextQuestion.text(v)).unicodeScalars.prefix(MAX_QUESTION_CHARS)))
    }

    /// The passages with text, as given.
    static func passages(_ inputs: JSONValue) -> [JSONValue] {
        (inputs["passages"]?.arrayValue ?? []).filter { $0.isDict && !Py.strip(NextQuestion.text($0["text"])).isEmpty }
    }

    /// The prompt for `inputs`: `question`, `user`, `today` and `passages` ({n, meeting, title, date, time, speaker,
    /// kind, text}).
    public static func buildPrompt(_ inputs: JSONValue) throws -> String {
        let question = self.question(inputs["question"])
        if question.isEmpty { throw BadAsk(description: "Type a question first.") }
        let found = passages(inputs)
        if found.isEmpty { throw BadAsk(description: "No passages to answer from.") }
        let user = NextQuestion.text(inputs["user"]).isEmpty ? "the user" : NextQuestion.text(inputs["user"])
        return ([rules(user: user, today: NextQuestion.text(inputs["today"])), "", "## Question", question, "",
                 "## Passages"] + found.map(line)).joined(separator: "\n")
    }

    private static let CITE = try! PyRegex(#"\[(\d{1,3})\]"#)

    /// The model's answer kept to what it may say: the answer without citations of passages it was not given, and its
    /// sources (the numbers cited in the answer first, in their order, then the ones it listed) among `numbers`.
    public static func checked(_ answer: JSONValue, numbers: Set<Int>) throws -> JSONValue {
        guard answer.isDict else { throw BrokenAnswer("the answer is not a JSON object") }
        guard answer["answer"] != nil else { throw BrokenAnswer("the answer has no answer") }
        let text = CITE.sub(in: Py.strip(NextQuestion.text(answer["answer"]))) { m in
            Int(m.group(1) ?? "").map { numbers.contains($0) } ?? false ? m.group()! : ""
        }
        var sources: [Int] = []
        for m in CITE.matches(in: text) {
            if let n = Int(m.group(1) ?? ""), !sources.contains(n) { sources.append(n) }
        }
        for v in answer["sources"]?.arrayValue ?? [] {
            if let d = NextQuestion.number(v), d == d.rounded(), numbers.contains(Int(d)), !sources.contains(Int(d)) {
                sources.append(Int(d))
            }
        }
        return .object([("answer", .string(Py.strip(text))), ("sources", .array(sources.prefix(MAX_SOURCES).map { .int($0) }))])
    }

    public static func parser(numbers: Set<Int>) -> AnswerParser { { try checked(try Answer.object($0), numbers: numbers) } }

    /// The numbers of the passages given.
    public static func numbers(_ inputs: JSONValue) -> Set<Int> {
        Set(passages(inputs).compactMap { NextQuestion.number($0["n"]).map { Int($0) } })
    }

    /// The ids of the meetings the passages come from, in their order, each once; only plain folder names.
    public static func meetings(_ inputs: JSONValue) -> [String] {
        var out: [String] = []
        for p in passages(inputs) {
            let id = NextQuestion.text(p["meeting"])
            if id.isEmpty || id.hasPrefix(".") || id.contains("/") || out.contains(id) { continue }
            out.append(id)
        }
        return out
    }

    /// The answer, from the engine (`run`: the engine with the parser).
    public static func ask(_ inputs: JSONValue, run: (String, JSONValue) async throws -> JSONValue) async throws -> JSONValue {
        let prompt = try buildPrompt(inputs)
        return try checked(try await run(prompt, SCHEMA), numbers: numbers(inputs))
    }
}

// MARK: - the command

public enum AskMeetingsRun {
    /// `palaver-lm ask` (#42): the inputs on stdin, `{"answer", "sources", "engine"}` on stdout, or `{"error"}` with
    /// exit 1 (75 while a local model is in use). The model is the notes'; a passage of a meeting kept on this Mac
    /// keeps it local, and the access log names every meeting whose passages are sent.
    public static func command(_ o: LMMain.Options, _ ctx: LMMain.Context) async -> Int32 {
        func answer(_ fields: [(String, JSONValue)], _ code: Int32) -> Int32 {
            ctx.say(PythonJSON.dumps(.object(fields), ensureAscii: false))
            return code
        }
        do {
            guard let inputs = PyDict<JSONValue>((try? PythonJSON.parse(ctx.readInput())) ?? .null) else {
                throw LMError("the inputs are not a JSON object")
            }
            _ = try AskMeetings.buildPrompt(inputs.json)  // a wrong ask is said before a model loads
            let ids = AskMeetings.meetings(inputs.json)
            let folders = ids.map { ctx.config.outputDir.appendingPathComponent($0, isDirectory: true) }
            let engine = try ctx.engine(feature: AskMeetings.FEATURE, kind: AskMeetings.KIND, meetings: folders,
                                        details: [("meetings", .strings(ids))], fallback: AskMeetings.fallback,
                                        logAs: AskMeetings.LOG_FEATURE)
            if engine.cloud && folders.contains(where: LocalOnly.isLocalOnly) {  // EngineChoice keeps them local already
                throw LMError("a meeting kept on this Mac never goes to a cloud model")
            }
            let lastWords = FootprintWatchdog.addLastWords { why in
                ctx.say(PythonJSON.dumps(.object([("error", .string(why))]), ensureAscii: false))
            }
            defer { FootprintWatchdog.removeLastWords(lastWords) }
            let numbers = AskMeetings.numbers(inputs.json)
            let ask = {
                try await AskMeetings.ask(inputs.json) { try await engine.run($0, schema: $1, parse: AskMeetings.parser(numbers: numbers)) }
            }
            let out = engine.cloud ? try await ask() : try await ModelLock.with(stores: ctx.stores, wait: false, say: { _ in }, ask)
            var fields: [(String, JSONValue)] = []
            if case .object(let pairs) = out { fields += pairs }
            return answer(fields + [("engine", .string(engine.label))], 0)
        } catch is ModelBusyError {
            return answer([("error", .string(AskMeetings.BUSY))], ModelLock.EXIT_MODEL_BUSY)
        } catch {
            return answer([("error", .string(String(describing: error)))], 1)
        }
    }
}
