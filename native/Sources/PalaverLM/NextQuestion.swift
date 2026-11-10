// The best next question (#41, next_question.py): on the user's click during a call, one to three questions to ask
// next, each with why. From the last minutes of what was said and the meeting's prep (its calendar title and invitees,
// who has not spoken, the last meeting with the same people and its open next steps, the user's own notes). The prompt
// is strict: only what the transcript and the context show. Nothing is written.
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
        var parts = [rules(user: user), "", "## Context"]
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

    public static func parse(_ text: String) throws -> JSONValue { try checked(try Answer.object(text)) }

    /// The questions, from the engine (`run`: the engine with `parse`).
    public static func ask(_ inputs: JSONValue, run: (String, JSONValue) async throws -> JSONValue) async throws -> JSONValue {
        try checked(try await run(try buildPrompt(inputs), SCHEMA))
    }
}
