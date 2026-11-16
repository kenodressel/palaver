// The live assistant (#15): during a call, on the user's click only, one of three answers from the live transcript so
// far — "catch me up" (the last 5, 10 or 15 minutes in a few bullets), "next steps so far" (next steps and decisions up
// to now) or the answer to a free question about what was said, with short quotes and their times. It runs on the
// model the user chose for the notes (a meeting kept on this Mac stays on the local model). The prompt is strict: only
// what the transcript shows. Nothing is written here (the window's server keeps the answers for the call).
import Foundation
import PalaverCore
import PalaverDomain

public enum LiveAssistant {
    /// The model it runs on: the notes' (Settings → Language model).
    public static let FEATURE = "notes"
    /// What the access log calls it.
    public static let LOG_FEATURE = "assistant"
    public static let CATCH_UP = "catchup"
    public static let NEXT_STEPS = "next_steps"
    public static let ASK = "ask"
    public static let KINDS = [CATCH_UP, NEXT_STEPS, ASK]
    /// How far "catch me up" looks back, in minutes; the first is the default.
    public static let MINUTES = [5, 10, 15]
    /// At least the last two lines however long ago, never more than `MAX_RECENT_LINES` for a catch-up.
    public static let MIN_LINES = 2
    public static let MAX_RECENT_LINES = 400
    public static let MAX_BULLETS = 5
    public static let MAX_QUOTES = 3
    public static let MAX_QUESTION_CHARS = 500
    public static let BUSY = "The language model is busy; try again in a minute."

    /// There is no transcript to answer from yet.
    public struct NothingYet: Error, CustomStringConvertible {
        public var description: String { "Nothing has been said yet." }
    }

    /// The inputs ask for something the assistant does not do.
    public struct BadAsk: Error, CustomStringConvertible {
        public let description: String
    }

    private static func string(_ description: String) -> JSONValue {
        .object([("type", .string("string")), ("description", .string(description))])
    }

    private static func list(_ items: JSONValue, max: Int? = nil) -> JSONValue {
        .object([("type", .string("array"))] + (max.map { [("maxItems", JSONValue.int($0))] } ?? []) + [("items", items)])
    }

    private static func object(_ properties: [(String, JSONValue)]) -> JSONValue {
        .object([("type", .string("object")), ("properties", .object(properties)), ("required", .strings(properties.map(\.0)))])
    }

    public static let CATCH_UP_SCHEMA = object([
        ("bullets", list(string("One short point: what was said, asked, agreed or left open."), max: MAX_BULLETS)),
    ])

    public static let NEXT_STEPS_SCHEMA = object([
        ("next_steps", list(object([
            ("owner", string("Who does it, as named in the transcript; empty when nobody was named.")),
            ("task", string("The task, with its date when one was said.")),
        ]))),
        ("decisions", list(string("What the meeting agreed on."))),
    ])

    public static let ASK_SCHEMA = object([
        ("answer", string("The answer in one to three sentences, or that the transcript does not say.")),
        ("quotes", list(object([
            ("time", string("The line's time as the transcript shows it, e.g. 12:34.")),
            ("speaker", string("Who said it, as the transcript names them.")),
            ("text", string("A short passage, word for word.")),
        ]), max: MAX_QUOTES)),
    ])

    public static func schema(_ kind: String) -> JSONValue {
        kind == CATCH_UP ? CATCH_UP_SCHEMA : kind == NEXT_STEPS ? NEXT_STEPS_SCHEMA : ASK_SCHEMA
    }

    /// What the end-to-end tests' model answers when the test gave no answer: nothing found.
    public static func fallback(_ kind: String) -> JSONValue {
        switch kind {
        case CATCH_UP: return .object([("bullets", .array([]))])
        case NEXT_STEPS: return .object([("next_steps", .array([])), ("decisions", .array([]))])
        default: return .object([("answer", .string("")), ("quotes", .array([]))])
        }
    }

    static func rules(user: String) -> String {
        """
        You help \(user) during a meeting that is going on right now.

        Only use what the transcript below shows. Never invent names, numbers, dates, decisions or facts. The transcript \
        is made by speech recognition while the meeting goes on: words may be misheard, and speakers the recognizer could \
        not tell apart are named "Others".
        """
    }

    static func task(_ kind: String, user: String, minutes: Int) -> String {
        switch kind {
        case CATCH_UP:
            return """
                \(user) stepped away or lost track. Say in two to five short bullets what was said in the last \
                \(minutes) minutes: what was discussed, asked, agreed or left open, and who said it when that matters. \
                Write in the language the meeting is held in.
                """
        case NEXT_STEPS:
            return """
                List the next steps and the decisions of the meeting so far. A next step is a task someone took on or \
                was given: say who (empty when nobody was named) and the task, with its date when one was said. A \
                decision is something the meeting agreed on. Leave out what was only discussed. Return empty lists when \
                there are none yet. Write in the language the meeting is held in.
                """
        default:
            return """
                \(user) asks a question about what was said. Answer it briefly from the transcript only; when the \
                transcript does not answer it, say so plainly. Quote up to three short passages that support the \
                answer, word for word, each with its time as the transcript shows it and who said it. Answer in the \
                language of the question.
                """
        }
    }

    /// The lines of the last `minutes` before `now`, or the last `MIN_LINES` when fewer were said in that time.
    static func recentLines(_ lines: [JSONValue], now: Double, minutes: Int) -> [JSONValue] {
        var recent = lines.filter { (NextQuestion.number($0["start"]) ?? 0) >= now - Double(minutes) * 60 }
        if recent.count < MIN_LINES { recent = Array(lines.suffix(MIN_LINES)) }
        return Array(recent.suffix(MAX_RECENT_LINES))
    }

    /// The question asked, trimmed and cut at `MAX_QUESTION_CHARS`.
    public static func question(_ v: JSONValue?) -> String {
        String(String.UnicodeScalarView(Py.strip(NextQuestion.text(v)).unicodeScalars.prefix(MAX_QUESTION_CHARS)))
    }

    /// The minutes a catch-up looks back: one of `MINUTES`, else the first.
    public static func minutes(_ v: JSONValue?) -> Int {
        let n = NextQuestion.number(v).map { Int($0) }
        return n.flatMap { MINUTES.contains($0) ? $0 : nil } ?? MINUTES[0]
    }

    /// The prompt for `inputs`: `kind`, `user`, `now` (seconds into the meeting), `lines` ({speaker, start, text}),
    /// `title`, and `minutes` (a catch-up) or `question` (an ask).
    public static func buildPrompt(_ inputs: JSONValue) throws -> String {
        let kind = NextQuestion.text(inputs["kind"])
        guard KINDS.contains(kind) else { throw BadAsk(description: "unknown kind of ask: \(Py.repr(.string(kind)))") }
        let said = Py.stableSorted((inputs["lines"]?.arrayValue ?? []).filter { !Py.strip(NextQuestion.text($0["text"])).isEmpty }) {
            (NextQuestion.number($0["start"]) ?? 0) < (NextQuestion.number($1["start"]) ?? 0)
        }
        if said.isEmpty { throw NothingYet() }
        let question = self.question(inputs["question"])
        if kind == ASK && question.isEmpty { throw BadAsk(description: "Type a question first.") }
        let user = NextQuestion.text(inputs["user"]).isEmpty ? "the user" : NextQuestion.text(inputs["user"])
        let minutes = self.minutes(inputs["minutes"])
        var parts = [rules(user: user), "", task(kind, user: user, minutes: minutes)]
        let title = NextQuestion.text(inputs["title"])
        if !title.isEmpty { parts += ["", "Meeting: \(title)"] }
        if kind == ASK { parts += ["", "## Question", question] }
        let lines: [JSONValue]
        if kind == CATCH_UP {
            lines = recentLines(said, now: NextQuestion.number(inputs["now"]) ?? 0, minutes: minutes)
            parts += ["", "## Transcript (the last \(minutes) minutes)"]
        } else {
            lines = said
            parts += ["", "## Transcript (so far)"]
        }
        parts += lines.map { line in
            let who = NextQuestion.text(line["speaker"]).isEmpty ? "Someone" : NextQuestion.text(line["speaker"])
            return "[\(NextQuestion.clock(NextQuestion.number(line["start"]) ?? 0))] \(who): \(Py.strip(NextQuestion.text(line["text"])))"
        }
        return parts.joined(separator: "\n")
    }

    private static let CLOCK = try! PyRegex(#"\d{1,2}(:\d{2}){1,2}"#)

    private static func strings(_ v: JSONValue?) -> [String] {
        (v?.arrayValue ?? []).map { Py.strip(NextQuestion.text($0)) }.filter { !$0.isEmpty }
    }

    /// The model's answer to a `kind` ask, kept to what its schema allows; `BrokenAnswer` when it is not that answer.
    public static func checked(_ kind: String, _ answer: JSONValue) throws -> JSONValue {
        guard answer.isDict else { throw BrokenAnswer("the answer is not a JSON object") }
        switch kind {
        case CATCH_UP:
            guard answer["bullets"]?.arrayValue != nil else { throw BrokenAnswer("the answer has no list of bullets") }
            return .object([("bullets", .strings(Array(strings(answer["bullets"]).prefix(MAX_BULLETS))))])
        case NEXT_STEPS:
            guard let steps = answer["next_steps"]?.arrayValue else { throw BrokenAnswer("the answer has no list of next steps") }
            let kept = steps.compactMap { s -> JSONValue? in
                guard s.isDict else { return nil }
                let task = Py.strip(NextQuestion.text(s["task"]))
                return task.isEmpty ? nil : .object([("owner", .string(Py.strip(NextQuestion.text(s["owner"])))), ("task", .string(task))])
            }
            return .object([("next_steps", .array(kept)), ("decisions", .strings(strings(answer["decisions"])))])
        default:
            guard answer["answer"] != nil else { throw BrokenAnswer("the answer has no answer") }
            let quotes = (answer["quotes"]?.arrayValue ?? []).compactMap { q -> JSONValue? in
                guard q.isDict else { return nil }
                let text = Py.strip(NextQuestion.text(q["text"]))
                let time = Py.strip(NextQuestion.text(q["time"]))
                return text.isEmpty ? nil : .object([("time", .string(CLOCK.fullMatch(time) == nil ? "" : time)),
                                                     ("speaker", .string(Py.strip(NextQuestion.text(q["speaker"])))),
                                                     ("text", .string(text))])
            }
            return .object([("answer", .string(Py.strip(NextQuestion.text(answer["answer"])))),
                            ("quotes", .array(Array(quotes.prefix(MAX_QUOTES))))])
        }
    }

    public static func parser(_ kind: String) -> AnswerParser { { try checked(kind, try Answer.object($0)) } }

    /// The answer, from the engine (`run`: the engine with the kind's parser).
    public static func ask(_ inputs: JSONValue, run: (String, JSONValue) async throws -> JSONValue) async throws -> JSONValue {
        let kind = NextQuestion.text(inputs["kind"])
        let prompt = try buildPrompt(inputs)
        return try checked(kind, try await run(prompt, schema(kind)))
    }
}
