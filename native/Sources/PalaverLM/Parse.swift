// Reading a model's answer (notes.py `parse_notes` and its helpers, cloud_llm.py `_json_object`): the JSON object in
// the text, also when the model thought out loud first, leaked its own special tokens, wrapped the object in a code
// fence or a sentence, or left raw tabs and line breaks inside strings. The notes are then put into the shape the page
// shows; what can't be repaired is a `BrokenAnswer`, and the runner asks again.
import Foundation
import PalaverCore
import PalaverDomain

public enum Answer {
    private static let specialToken = try! NSRegularExpression(pattern: #"<\|[a-z_]{2,24}>|<[a-z_]{2,24}\|>"#)

    /// `text` without visible thinking ("<think>…</think>", or only its end when the chat template opened it) and
    /// without the model's own special tokens ("<audio|>", "<|image>").
    public static func cleaned(_ text: String) -> String {
        var rest = text
        while let open = rest.range(of: "<think>"), let close = rest.range(of: "</think>", range: open.upperBound..<rest.endIndex) {
            rest.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if let last = rest.range(of: "</think>", options: .backwards) { rest = String(rest[last.upperBound...]) }
        let ns = rest as NSString
        return specialToken.stringByReplacingMatches(in: rest, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    /// The JSON object in the model's answer: from its first `{` to its last `}`, read leniently (raw control
    /// characters inside strings allowed, as `json.loads(strict=False)`).
    public static func object(_ text: String) throws -> JSONValue {
        let text = cleaned(text)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else {
            throw BrokenAnswer("no JSON object in the answer")
        }
        let value: JSONValue
        do {
            value = try PythonJSON.parse(Data(lenient(String(text[start...end])).utf8))
        } catch {
            throw BrokenAnswer("the answer is not valid JSON: \(error)")
        }
        guard case .object = value else { throw BrokenAnswer("the answer is not a JSON object") }
        return value
    }

    /// Raw control characters inside JSON strings escaped, so a strict reader takes them.
    static func lenient(_ json: String) -> String {
        var out = String.UnicodeScalarView()
        var inString = false, escaped = false
        for u in json.unicodeScalars {
            if inString {
                if escaped {
                    escaped = false
                } else if u == "\\" {
                    escaped = true
                } else if u == "\"" {
                    inString = false
                } else if u.value < 0x20 {
                    out.append(contentsOf: String(format: "\\u%04x", u.value).unicodeScalars)
                    continue
                }
            } else if u == "\"" {
                inString = true
            }
            out.append(u)
        }
        return String(out)
    }
}

/// The notes as the model wrote them, repaired into the shape notes.json holds.
public enum NotesAnswer {
    /// `parse_notes`: the object with `title` and `summary` as texts and the lists in place. A dict of speaker names
    /// becomes their list; texts given as objects and objects given as texts are put right; string booleans for
    /// "mine" are taken. Decisions stay texts, those from the user's own notes listed by index in `decisions_mine`.
    public static func parse(_ text: String) throws -> JSONValue {
        guard var out = PyDict<JSONValue>(try Answer.object(text)) else { throw BrokenAnswer("the answer is not a JSON object") }
        for key in ["title", "summary"] where out[key]?.stringValue == nil {
            throw BrokenAnswer("'\(key)' missing")
        }
        if case .object(let names)? = out["speaker_names"] {  // {"SPEAKER_01": "Anna"}: the key is the label
            out["speaker_names"] = .array(names.map { label, v in
                var g = PyDict<JSONValue>(v) ?? PyDict([("name", v)])
                g["label"] = .string(label)
                return g.json
            })
        }
        for key in ["sections", "next_steps", "decisions", "speaker_names"] {
            if out[key] == nil { out[key] = .array([]) }
            guard out[key]?.arrayValue != nil else { throw BrokenAnswer("'\(key)' is not a list") }
        }
        out["sections"] = .array(try out["sections"]!.arrayValue!.map(section))
        out["next_steps"] = .array(try out["next_steps"]!.arrayValue!.map(step).filter { !(($0["task"]?.stringValue ?? "").isEmpty) })
        let decisions = try out["decisions"]!.arrayValue!.map { d -> (String, Bool) in
            (try decision(d), d.isDict ? try mine(d["mine"]) : false)
        }.filter { !$0.0.isEmpty }
        out["decisions"] = .strings(decisions.map(\.0))
        out["decisions_mine"] = nil
        if decisions.contains(where: \.1) {
            out["decisions_mine"] = .array(decisions.enumerated().filter { $0.element.1 }.map { .int($0.offset) })
        }
        out["speaker_names"] = .array(out["speaker_names"]!.arrayValue!.compactMap { g -> JSONValue? in
            guard let fields = PyDict<JSONValue>(g), let name = fields["name"]?.stringValue, !Py.strip(name).isEmpty else { return nil }
            var shown = PyDict<JSONValue>([("evidence", .string(""))])
            for (k, v) in fields { shown[k] = v }
            return shown.json
        })
        return out.json
    }

    private static func textOrObject(_ item: JSONValue, _ what: String) throws -> JSONValue {
        switch item {
        case .string, .object: return item
        default: throw BrokenAnswer(String("a \(what) is neither text nor an object: \(Py.repr(item))".prefix(200)))
        }
    }

    /// The text of a step or decision given as an object: its task, text or decision, never its owner.
    private static func objectText(_ item: JSONValue, _ what: String) throws -> String {
        for key in ["task", "text", "decision"] {
            var value = item[key]
            if case .object? = value { value = value?["text"] }
            if let s = value?.stringValue { return s }
        }
        throw BrokenAnswer(String("a \(what) without its text: \(Py.repr(item))".prefix(200)))
    }

    /// A text, also when wrapped in an object: its "text", else its first text.
    static func text(_ value: JSONValue?) -> String {
        switch value {
        case nil, .null?, .array?: return ""
        case .string(let s)?: return s
        case .object(let fields)?:
            if let s = value?["text"]?.stringValue { return s }
            return fields.lazy.map { text($0.1) }.first { !$0.isEmpty } ?? ""
        case let other?: return Py.str(other)
        }
    }

    /// A list, also when the model gave one item without it.
    private static func listed(_ value: JSONValue?) -> [JSONValue] {
        switch value {
        case nil, .null?: return []
        case .array(let items)?: return items
        case let one?: return [one]
        }
    }

    /// Whether an item came from the user's own notes: a yes or no, also written as text; anything else is broken.
    static func mine(_ value: JSONValue?) throws -> Bool {
        switch value {
        case nil, .null?: return false
        case .bool(let b)?: return b
        case .string(let s)?:
            let word = Py.strip(s).lowercased()  // only "true" and "false" count
            if word == "true" || word == "false" { return word == "true" }
        default: break
        }
        throw BrokenAnswer(String("'mine' is neither true nor false: \(Py.repr(value!))".prefix(200)))
    }

    private static func section(_ item: JSONValue) throws -> JSONValue {
        var fields: PyDict<JSONValue>
        if case .string(let heading) = try textOrObject(item, "section") {
            fields = PyDict([("heading", .string(heading)), ("points", .array([]))])
        } else {
            fields = PyDict<JSONValue>(item)!
        }
        let heading = text(fields["heading"])
        let points = try listed(fields["points"]).map(point)
        fields["heading"] = .string(heading)
        fields["points"] = .array(points)
        if Py.strip(heading).isEmpty && points.isEmpty { throw BrokenAnswer("a section with no heading and no points") }
        return fields.json
    }

    private static func point(_ item: JSONValue) throws -> JSONValue {
        if case .string(let s) = try textOrObject(item, "point") {
            return .object([("text", .string(s)), ("details", .array([]))])
        }
        var fields = PyDict<JSONValue>(item)!
        fields["text"] = .string(text(item["text"]))
        fields["details"] = .strings(listed(item["details"]).map { text($0) }.filter { !$0.isEmpty })
        fields["mine"] = nil
        if try mine(item["mine"]) { fields["mine"] = .bool(true) }
        return fields.json
    }

    private static func step(_ item: JSONValue) throws -> JSONValue {
        if case .string(let s) = try textOrObject(item, "next step") {
            return .object([("owner", .string("")), ("task", .string(s))])
        }
        var fields: [(String, JSONValue)] = [("owner", .string(text(item["owner"]))),
                                             ("task", .string(try objectText(item, "next step")))]
        if try mine(item["mine"]) { fields.append(("mine", .bool(true))) }
        return .object(fields)
    }

    private static func decision(_ item: JSONValue) throws -> String {
        if case .string(let s) = try textOrObject(item, "decision") { return s }
        return try objectText(item, "decision")
    }
}
