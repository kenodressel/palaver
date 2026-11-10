// The transcript models (palaver/models.py), with the JSON the Python app writes: same key order,
// same omitted keys. Numbers are floats whatever the file said (`float(d["start"])`).
import Foundation
import PalaverCore

/// Below this a word is "unsure": on recorded meetings such words differed from the final transcript
/// 50–100 % of the time (above 0.95: 3–12 %).
public let UNSURE_CONFIDENCE = 0.85

/// What `from_dict` raises: a missing key (`KeyError`), or a value `float()` or `str` could not take.
public struct ModelError: Error, CustomStringConvertible {
    public let description: String
}

private enum Field {
    static func required(_ d: JSONValue, _ key: String) throws -> JSONValue {
        guard let v = d[key] else { throw ModelError(description: "KeyError: '\(key)'") }
        return v
    }

    /// `float(v)`: a number, a numeric string, a bool.
    static func float(_ v: JSONValue, _ key: String) throws -> Double {
        switch v {
        case .int(let i): return Double(i)
        case .double(let x): return x
        case .bool(let b): return b ? 1 : 0
        case .string(let s):
            let t = Py.strip(s).replacingOccurrences(of: "_", with: "")
            if let x = Double(t), !t.lowercased().contains("x") { return x }
            throw ModelError(description: "ValueError: could not convert string to float: \(s.debugDescription)")
        default:
            throw ModelError(description: "TypeError: float() argument for '\(key)' must be a string or a real number")
        }
    }

    static func string(_ v: JSONValue, _ key: String) throws -> String {
        guard case .string(let s) = v else {
            throw ModelError(description: "TypeError: '\(key)' is not text")
        }
        return s
    }

    /// `d.get(key)` that is a string or None.
    static func optionalString(_ d: JSONValue, _ key: String) -> String? {
        if case .string(let s)? = d[key] { return s }
        return nil
    }

    static func object(_ d: JSONValue) throws -> JSONValue {
        guard case .object = d else { throw ModelError(description: "TypeError: not an object") }
        return d
    }
}

/// A single word with sub-second timing.
public struct Word: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    /// How sure the transcriber was (0–1, its least sure piece); nil: unknown.
    public var confidence: Double?

    public init(text: String, start: Double, end: Double, confidence: Double? = nil) {
        self.text = text; self.start = start; self.end = end; self.confidence = confidence
    }

    /// `Word.from_dict`.
    public init(json d: JSONValue) throws {
        let d = try Field.object(d)
        text = try Field.string(Field.required(d, "text"), "text")
        start = try Field.float(Field.required(d, "start"), "start")
        end = try Field.float(Field.required(d, "end"), "end")
        if let c = d["confidence"], !c.isNull { confidence = try Field.float(c, "confidence") } else { confidence = nil }
    }

    /// `Word.to_dict`: no `confidence` key when it is unknown.
    public var json: JSONValue {
        var fields: [(String, JSONValue)] = [("text", .string(text)), ("start", .double(start)), ("end", .double(end))]
        if let confidence { fields.append(("confidence", .double(confidence))) }
        return .object(fields)
    }
}

/// A Whisper segment (~30s chunk) with optional word-level timings.
public struct Segment: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: String?
    public var words: [Word]

    public init(start: Double, end: Double, text: String, speaker: String? = nil, words: [Word] = []) {
        self.start = start; self.end = end; self.text = text; self.speaker = speaker; self.words = words
    }

    /// `Segment.from_dict`.
    public init(json d: JSONValue) throws {
        let d = try Field.object(d)
        start = try Field.float(Field.required(d, "start"), "start")
        end = try Field.float(Field.required(d, "end"), "end")
        text = try Field.string(Field.required(d, "text"), "text")
        speaker = Field.optionalString(d, "speaker")
        words = try (d["words"]?.arrayValue ?? []).map { try Word(json: $0) }
    }

    /// `Segment.to_dict`.
    public var json: JSONValue {
        .object([("start", .double(start)), ("end", .double(end)), ("text", .string(text)),
                 ("speaker", .str(speaker)), ("words", .array(words.map(\.json)))])
    }
}

/// A contiguous interval during which one speaker was active.
public struct SpeakerTurn: Equatable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker; self.start = start; self.end = end
    }

    /// `SpeakerTurn.from_dict`.
    public init(json d: JSONValue) throws {
        let d = try Field.object(d)
        speaker = try Field.string(Field.required(d, "speaker"), "speaker")
        start = try Field.float(Field.required(d, "start"), "start")
        end = try Field.float(Field.required(d, "end"), "end")
    }

    /// `SpeakerTurn.to_dict`.
    public var json: JSONValue {
        .object([("speaker", .string(speaker)), ("start", .double(start)), ("end", .double(end))])
    }
}

/// Final merged output: who said what, when.
public struct Utterance: Equatable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String
    /// Original diarization label when `speaker` was renamed (speakers.json), so later renames can
    /// still map from it.
    public var label: String?
    /// What the transcriber heard, when the user rewrote `text` by hand.
    public var heard: String?
    /// Words in `text` the transcriber was unsure of (UNSURE_CONFIDENCE).
    public var unsure: [String]
    /// Where the glossary respelled `text` for showing it: (start, end, the variant heard). Worked
    /// out by `readable`, never stored.
    public var glossed: [(start: Int, end: Int, heard: String)]
    /// Who the user said said this line, when it is a person without a voice of their own (speakers_lines.json,
    /// #12): it is no microphone line then, though it has no label. Worked out when the transcript is read, never
    /// stored.
    public var saidBy: String?
    /// A corrected line's track and voice as heard: ("mic", nil) or ("others", label) (#12). Worked out when the
    /// transcript is read, never stored.
    public var heardAs: (track: String, label: String?)?

    public init(speaker: String, start: Double, end: Double, text: String, label: String? = nil, heard: String? = nil,
                unsure: [String] = [], glossed: [(start: Int, end: Int, heard: String)] = [], saidBy: String? = nil,
                heardAs: (track: String, label: String?)? = nil) {
        self.speaker = speaker; self.start = start; self.end = end; self.text = text
        self.label = label; self.heard = heard; self.unsure = unsure; self.glossed = glossed
        self.saidBy = saidBy; self.heardAs = heardAs
    }

    public static func == (a: Utterance, b: Utterance) -> Bool {
        a.speaker == b.speaker && a.start == b.start && a.end == b.end && a.text == b.text && a.label == b.label
            && a.heard == b.heard && a.unsure == b.unsure
            && a.glossed.count == b.glossed.count && zip(a.glossed, b.glossed).allSatisfy { $0.0 == $0.1 }
            && a.saidBy == b.saidBy && a.heardAs?.track == b.heardAs?.track && a.heardAs?.label == b.heardAs?.label
    }

    /// `Utterance.from_dict`: the glossary spans are never stored, so never read.
    public init(json d: JSONValue) throws {
        let d = try Field.object(d)
        speaker = try Field.string(Field.required(d, "speaker"), "speaker")
        start = try Field.float(Field.required(d, "start"), "start")
        end = try Field.float(Field.required(d, "end"), "end")
        text = try Field.string(Field.required(d, "text"), "text")
        label = Field.optionalString(d, "label")
        heard = Field.optionalString(d, "heard")
        unsure = (d["unsure"]?.arrayValue ?? []).compactMap(\.stringValue)
        glossed = []
        saidBy = nil
        heardAs = nil
    }

    /// `Utterance.to_dict`: no `glossed`, `said_by` or `heard_as`; `label`, `heard` and `unsure` only when there is something.
    public var json: JSONValue {
        var fields: [(String, JSONValue)] = [("speaker", .string(speaker)), ("start", .double(start)),
                                             ("end", .double(end)), ("text", .string(text))]
        if let label { fields.append(("label", .string(label))) }
        if let heard { fields.append(("heard", .string(heard))) }
        if !unsure.isEmpty { fields.append(("unsure", .strings(unsure))) }
        return .object(fields)
    }
}
