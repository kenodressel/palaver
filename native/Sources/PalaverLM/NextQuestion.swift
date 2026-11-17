// The best next question (#41, next_question.py): on the user's click during a call, one to three questions to ask
// next, each with why. From the last minutes of what was said and the meeting's prep (its calendar title and invitees,
// who has not spoken, the last meeting with the same people and its open next steps, the user's own notes). The prompt
// is strict: only what the transcript and the context show. Nothing is written.
//
// The best answer (`kind: "answer"`): from the same inputs, what the user could say now to the latest question put to
// them, or to the topic of the last lines. It may draw on the model's knowledge of the subject, never on made-up facts
// about the people, companies, projects, numbers, dates or decisions: where the answer hangs on one, it says what to
// check instead.
import Foundation
import PalaverCore
import PalaverDomain

public enum NextQuestion {
    public static let FEATURE = "coach"
    /// The last five minutes of the transcript ...
    public static let RECENT_SECONDS = 300.0
    /// ... or at least the last two lines; never more than `MAX_LINES`.
    public static let MIN_LINES = 2
    public static let MAX_LINES = 120
    public static let MAX_QUESTIONS = 3
    public static let MAX_NOTES_CHARS = 4000
    public static let BUSY = "The language model is busy; try again in a minute."
    /// What is asked for (`inputs.kind`): questions to ask (the default), or the answer to give.
    public static let QUESTIONS = "questions"
    public static let ANSWER = "answer"
    public static let MAX_POINTS = 3

    /// The kind of `inputs`: `ANSWER`, or `QUESTIONS` for anything else.
    public static func kind(_ inputs: JSONValue) -> String {
        text(inputs["kind"]) == ANSWER ? ANSWER : QUESTIONS
    }

    public static let SCHEMA = JSONValue.object([
        ("type", .string("object")),
        ("properties", .object([("questions", .object([
            ("type", .string("array")), ("maxItems", .int(MAX_QUESTIONS)),
            ("items", .object([
                ("type", .string("object")),
                ("properties", .object([
                    ("question", .object([("type", .string("string")),
                                          ("description", .string("The question, as the user would ask it."))])),
                    ("why", .object([("type", .string("string")),
                                     ("description", .string("One short sentence: what in the transcript or the context it comes from."))])),
                ])),
                ("required", .strings(["question", "why"])),
            ])),
        ]))])),
        ("required", .strings(["questions"])),
    ])

    private static func string(_ description: String) -> JSONValue {
        .object([("type", .string("string")), ("description", .string(description))])
    }

    public static let ANSWER_SCHEMA = JSONValue.object([
        ("type", .string("object")),
        ("properties", .object([
            ("to", string("The question or topic answered, short, in the words of the transcript; empty when there is none.")),
            ("asked_by", string("Who asked it, as the transcript names them; empty for a topic or when unclear.")),
            ("time", string("When it was said, as the transcript shows it, e.g. 12:34; empty when unclear.")),
            ("answer", string("What the user could say now: first person, two to four short sentences.")),
            ("points", .object([("type", .string("array")), ("maxItems", .int(MAX_POINTS)),
                                ("items", string("A short point that backs the answer or that the user could add."))])),
            ("check", string("What the answer hangs on that the transcript and the context do not show; empty when nothing.")),
            ("basis", string("One short sentence: what the answer rests on (the transcript, the prep, general knowledge).")),
        ])),
        ("required", .strings(["to", "asked_by", "time", "answer", "points", "check", "basis"])),
    ])

    public static func schema(_ kind: String) -> JSONValue { kind == ANSWER ? ANSWER_SCHEMA : SCHEMA }

    /// What the end-to-end tests' model answers when the test gave no answer: nothing found.
    public static func fallback(_ kind: String) -> JSONValue {
        guard kind == ANSWER else { return .object([("questions", .array([]))]) }
        let empty = ["to", "asked_by", "time", "answer", "check", "basis"].map { ($0, JSONValue.string("")) }
        return .object(empty + [("points", .array([]))])
    }

    static func answerRules(user: String) -> String {
        """
        You help \(user) during a meeting that is going on right now. Suggest the best answer \(user) could give now.

        First find what \(user) should answer: the latest question in the transcript that was put to \(user), or to everyone, and is not answered yet; else the topic of the last lines. Then write the answer as \(user) would say it: first person, two to four short sentences, clear and to the point, in the language the meeting is held in.
        You may use your general knowledge of the subject, and the transcript and the context below. Never invent facts about \(user), the people, companies, projects, prices, numbers, dates or decisions that the transcript or the context do not show. Where the answer hangs on such a fact, keep the answer to what is safe to say and name in "check" what \(user) should look up, or offer to follow up on it.
        Add up to three short points that back the answer or that \(user) could add. In "basis", say in one short sentence what the answer rests on. The transcript is made by speech recognition while the meeting goes on: words may be misheard. If nothing in the last lines calls for an answer, return empty strings and an empty list.
        """
    }

    static func rules(user: String) -> String {
        """
        You help \(user) during a meeting that is going on right now. Suggest one to three questions \(user) could ask next.

        Only use what the transcript and the context below show. Never invent names, numbers, dates, decisions or facts. Look for gaps:
        - a decision or task without an owner or a date;
        - something raised and then dropped;
        - an open next step from last time that has not come up yet;
        - an invitee who has not said anything yet;
        - a question of the others that is still unanswered.
        For each question, say in one short sentence why, pointing to what in the transcript or the context it comes from. Write the questions in the language the meeting is held in. If nothing in the transcript supports a good question, return an empty list.
        """
    }

    /// There is no transcript to suggest a question from yet.
    public struct NothingYet: Error, CustomStringConvertible {
        public var description: String { "Nothing has been said yet." }
    }

    static func number(_ v: JSONValue?) -> Double? {
        switch v {
        case .int(let i)?: return Double(i)
        case .double(let d)?: return d
        case .bool(let b)?: return b ? 1 : 0
        default: return nil
        }
    }

    /// `text or ""` of an input that should be text.
    static func text(_ v: JSONValue?) -> String {
        guard let v, v.truthy else { return "" }
        return Py.str(v)
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.towardZero))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return h != 0 ? "\(h):\(two(m)):\(two(s))" : "\(two(m)):\(two(s))"
    }

    /// The lines of the last `RECENT_SECONDS`, or the last `MIN_LINES` when fewer were said in that time.
    static func recentLines(_ lines: [JSONValue], now: Double) -> [JSONValue] {
        let sorted = Py.stableSorted(lines) { (number($0["start"]) ?? 0) < (number($1["start"]) ?? 0) }
        var recent = sorted.filter { (number($0["start"]) ?? 0) >= now - RECENT_SECONDS }
        if recent.count < MIN_LINES { recent = Array(sorted.suffix(MIN_LINES)) }
        return Array(recent.suffix(MAX_LINES))
    }

    /// The prompt for `inputs`: `user`, `now` (seconds into the meeting), `lines` ({speaker, start, text}), `title`,
    /// `invitees`, `quiet` (invitees not heard yet), `last_time` ({title, start, summary, next_steps}), `my_notes`.
    public static func buildPrompt(_ inputs: JSONValue) throws -> String {
        let said = (inputs["lines"]?.arrayValue ?? []).filter { !Py.strip(text($0["text"])).isEmpty }
        let lines = recentLines(said, now: number(inputs["now"]) ?? 0)
        if lines.isEmpty { throw NothingYet() }
        let user = text(inputs["user"]).isEmpty ? "the user" : text(inputs["user"])
        var parts = [kind(inputs) == ANSWER ? answerRules(user: user) : rules(user: user), "", "## Context"]
        if !text(inputs["title"]).isEmpty { parts.append("Meeting: \(text(inputs["title"]))") }
        let invitees = (inputs["invitees"]?.arrayValue ?? []).map { Py.str($0) }
        if !invitees.isEmpty { parts.append("Invited: " + invitees.joined(separator: ", ")) }
        let quiet = (inputs["quiet"]?.arrayValue ?? []).map { Py.str($0) }
        if !quiet.isEmpty { parts.append("Invited but not heard yet: " + quiet.joined(separator: ", ")) }
        for m in inputs["last_time"]?.arrayValue ?? [] {
            let day = String(String.UnicodeScalarView(text(m["start"]).unicodeScalars.prefix(10)))
            let title = text(m["title"]).isEmpty ? "a meeting" : text(m["title"])
            let summary = text(m["summary"]).isEmpty ? "no summary" : text(m["summary"])
            parts.append("Last time (\(day), \(title)): \(summary)")
            for s in m["next_steps"]?.arrayValue ?? [] where s.isDict && !text(s["task"]).isEmpty {
                let owner = text(s["owner"])
                parts.append("- open next step: \(text(s["task"]))" + (owner.isEmpty ? "" : " (\(owner))"))
            }
        }
        let notes = (inputs["my_notes"]?.arrayValue ?? []).map { Py.str($0) }.filter { !Py.strip($0).isEmpty }
            .joined(separator: "\n")
        if !notes.isEmpty {
            parts += ["\(user)'s own notes on the meeting:", String(String.UnicodeScalarView(notes.unicodeScalars.prefix(MAX_NOTES_CHARS)))]
        }
        parts += ["", "## Transcript (the last minutes)"]
        parts += lines.map { line in
            let who = text(line["speaker"]).isEmpty ? "Someone" : text(line["speaker"])
            return "[\(clock(number(line["start"]) ?? 0))] \(who): \(Py.strip(text(line["text"])))"
        }
        return parts.joined(separator: "\n")
    }

    /// The model's answer, kept to what the schema allows: at most three questions, each with its why.
    public static func checked(_ answer: JSONValue) throws -> JSONValue {
        guard answer.isDict, let questions = answer["questions"]?.arrayValue else {
            throw BrokenAnswer("the answer has no list of questions")
        }
        let out = questions.compactMap { q -> JSONValue? in
            guard q.isDict else { return nil }
            let question = Py.strip(text(q["question"])), why = Py.strip(text(q["why"]))
            return question.isEmpty ? nil : .object([("question", .string(question)), ("why", .string(why))])
        }
        return .object([("questions", .array(Array(out.prefix(MAX_QUESTIONS))))])
    }

    private static let CLOCK = try! PyRegex(#"\d{1,2}(:\d{2}){1,2}"#)

    /// The model's best answer, kept to what `ANSWER_SCHEMA` allows: texts trimmed, at most three points, a time only
    /// when it looks like one. No answer is an empty `answer`.
    public static func checkedAnswer(_ answer: JSONValue) throws -> JSONValue {
        guard answer.isDict, answer["answer"] != nil else { throw BrokenAnswer("the answer has no answer") }
        func field(_ key: String) -> String { Py.strip(text(answer[key])) }
        let points = (answer["points"]?.arrayValue ?? []).map { Py.strip(text($0)) }.filter { !$0.isEmpty }
        let time = field("time")
        return .object([("to", .string(field("to"))), ("asked_by", .string(field("asked_by"))),
                        ("time", .string(CLOCK.fullMatch(time) == nil ? "" : time)), ("answer", .string(field("answer"))),
                        ("points", .strings(Array(points.prefix(MAX_POINTS)))), ("check", .string(field("check"))),
                        ("basis", .string(field("basis")))])
    }

    public static func parse(_ text: String) throws -> JSONValue { try checked(try Answer.object(text)) }

    /// The parser of a `kind`'s answer.
    public static func parser(_ kind: String) -> AnswerParser {
        kind == ANSWER ? { try checkedAnswer(try Answer.object($0)) } : parse
    }

    /// The questions (or, for `kind: "answer"`, the best answer), from the engine (`run`: the engine with `parser`).
    public static func ask(_ inputs: JSONValue, run: (String, JSONValue) async throws -> JSONValue) async throws -> JSONValue {
        let kind = kind(inputs)
        let answer = try await run(try buildPrompt(inputs), schema(kind))
        return kind == ANSWER ? try checkedAnswer(answer) : try checked(answer)
    }
}
