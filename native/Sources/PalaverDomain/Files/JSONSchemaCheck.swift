// The checks an imported meeting's JSON goes through (exchange.py:133-280, issue #58): the schemas of the files a
// meeting's zip holds, `check` (the subset of JSON Schema they use), strict JSON (`_json`) and times (`_time`). The file
// is untrusted: whatever does not fit is `ExchangeRejected`, with Python's words, which the user sees.
import Foundation
import PalaverCore

/// The file can't be imported; the message says why, in words for the user. Python's `exchange.Rejected`.
public struct ExchangeRejected: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A JSON Schema of the subset `check` reads (type, enum, maxLength, minLength, pattern, minimum, maximum, maxItems,
/// minItems, items, maxProperties, required, properties, additionalProperties, propertyNames), compiled from its JSON.
public final class JSONSchema: @unchecked Sendable {  // immutable
    /// The schema as Python has it.
    public let json: JSONValue
    let types: [String]?
    let enumValues: [JSONValue]?
    let maxLength: Int?, minLength: Int?
    let pattern: PyRegex?
    let minimum: JSONValue?, maximum: JSONValue?
    let maxItems: Int?, minItems: Int?
    let items: JSONSchema?
    let maxProperties: Int?
    let required: [String]
    public let properties: PyDict<JSONSchema>
    enum Additional { case allowed, forbidden, schema(JSONSchema) }
    let additional: Additional
    let propertyNames: JSONSchema?

    /// `json` must be a schema of that subset; the schemas are constants, so anything else is a programming error.
    public init(_ json: JSONValue) {
        self.json = json
        func int(_ key: String) -> Int? { json[key].map { v in guard case .int(let i) = v else { preconditionFailure(key) }; return i } }
        switch json["type"] {
        case nil: types = nil
        case .string(let t)?: types = [t]
        case .array(let ts)?: types = ts.map { $0.stringValue! }
        default: preconditionFailure("type")
        }
        enumValues = json["enum"].map { $0.arrayValue! }
        maxLength = int("maxLength")
        minLength = int("minLength")
        pattern = json["pattern"].map { try! PyRegex($0.stringValue!) }
        minimum = json["minimum"]
        maximum = json["maximum"]
        maxItems = int("maxItems")
        minItems = int("minItems")
        items = json["items"].map(JSONSchema.init)
        maxProperties = int("maxProperties")
        required = json["required"].map { $0.arrayValue!.map { $0.stringValue! } } ?? []
        var props = PyDict<JSONSchema>()
        if case .object(let fields)? = json["properties"] { for (k, v) in fields { props[k] = JSONSchema(v) } }
        properties = props
        switch json["additionalProperties"] {
        case nil, .bool(true)?: additional = .allowed
        case .bool(false)?: additional = .forbidden
        case let s?: additional = .schema(JSONSchema(s))
        }
        propertyNames = json["propertyNames"].map(JSONSchema.init)
    }
}

/// A time as `datetime.fromisoformat` reads it (always with an offset): its fields as written, and the moment.
public struct ExchangeTime: Comparable, Sendable {
    public let year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, microsecond: Int
    /// The UTC offset, in seconds (`utcoffset()`).
    public let utcOffset: Int
    /// Microseconds since 1970 UTC: what Python compares aware datetimes by.
    public let epochMicroseconds: Int64

    public var date: Date { Date(timeIntervalSince1970: Double(epochMicroseconds) / 1_000_000) }
    public static func == (a: Self, b: Self) -> Bool { a.epochMicroseconds == b.epochMicroseconds }
    public static func < (a: Self, b: Self) -> Bool { a.epochMicroseconds < b.epochMicroseconds }
}

public enum JSONSchemaCheck {
    public static let MAX_SECONDS = 12 * 3600
    static let LABEL = #"SPEAKER_\d{1,3}"#

    // MARK: - The schemas (exchange.py:133-203)

    static func s(_ fields: KeyValuePairs<String, JSONValue>) -> JSONValue { .object(fields.map { ($0.key, $0.value) }) }

    static let TIME = s(["type": .string("string"), "maxLength": .int(40),
                         "pattern": .string(#"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?([+-]\d{2}:\d{2}|Z)"#)])
    static let SECONDS = s(["type": .string("number"), "minimum": .int(0), "maximum": .int(MAX_SECONDS)])
    static let TEXT = s(["type": .string("string"), "maxLength": .int(20000)])
    static let NAME_TEXT = s(["type": .string("string"), "maxLength": .int(200)])
    static let LABEL_TEXT = s(["type": .string("string"), "pattern": .string(LABEL)])

    static func str(_ maxLength: Int) -> JSONValue { s(["type": .string("string"), "maxLength": .int(maxLength)]) }
    static func strOrNull(_ maxLength: Int) -> JSONValue {
        s(["type": .array([.string("string"), .string("null")]), "maxLength": .int(maxLength)])
    }
    static let BOOLEAN = s(["type": .string("boolean")])

    /// `_obj`.
    static func obj(_ props: KeyValuePairs<String, JSONValue>, _ required: [String] = []) -> JSONValue {
        s(["type": .string("object"), "properties": s(props), "required": .array(required.map { .string($0) }),
           "additionalProperties": .bool(false)])
    }

    /// `_list`.
    static func list(_ items: JSONValue, _ maxItems: Int) -> JSONValue {
        s(["type": .string("array"), "items": items, "maxItems": .int(maxItems)])
    }

    public static let MANIFEST = JSONSchema(obj([
        "format": s(["type": .string("integer")]),
        "palaver_version": str(40),
        "exported_at": TIME,
        "exported_by": s(["type": .string("string"), "maxLength": .int(200), "minLength": .int(1)]),
        "files": s(["type": .string("object"), "maxProperties": .int(ExchangeZip.MAX_ENTRIES), "propertyNames": str(100),
                    "additionalProperties": obj(["sha256": s(["type": .string("string"), "pattern": .string("[0-9a-f]{64}")]),
                                                 "bytes": s(["type": .string("integer"), "minimum": .int(0)])], ["sha256", "bytes"])]),
    ], ["format", "palaver_version", "exported_at", "exported_by", "files"]))

    public static let SCHEMAS = PyDict<JSONSchema>([
        ("meeting/meta.json", JSONSchema(obj([
            "start": TIME, "end": TIME, "duration": SECONDS,
            "title": strOrNull(500),
            "language": strOrNull(16),
            "projects": list(str(200), 50),
            "kept_on_this_mac": BOOLEAN,
        ], ["start", "end", "duration"]))),
        ("meeting/calendar.json", JSONSchema(obj([
            "uid": str(1000), "start": TIME, "end": TIME,
            "title": str(500), "series": BOOLEAN,
            "attendees": list(obj([
                "name": NAME_TEXT, "email": strOrNull(320),
                "organizer": BOOLEAN,
                "response": s(["type": .string("string"),
                               "enum": .array(["accepted", "tentative", "declined", "unknown"].map { .string($0) })]),
                "room": BOOLEAN,
            ], ["name"]), 1000),
        ], ["uid", "start", "end", "title", "attendees"]))),
        ("meeting/transcript.json", JSONSchema(list(obj([
            "start": SECONDS, "end": SECONDS, "text": TEXT, "label": LABEL_TEXT, "speaker": NAME_TEXT,
        ], ["start", "end", "text", "label"]), 200_000))),
        ("meeting/turns.json", JSONSchema(list(obj(["speaker": LABEL_TEXT, "start": SECONDS, "end": SECONDS],
                                                   ["speaker", "start", "end"]), 400_000))),
        ("meeting/speakers.json", JSONSchema(list(obj([
            "label": LABEL_TEXT, "name": strOrNull(200),
            "how": s(["type": .array([.string("string"), .string("null")]), "enum": .array(ExchangeHints.HOWS.map { .string($0) } + [.null])]),
        ], ["label", "name", "how"]), 1000))),
        ("meeting/notes.json", JSONSchema(obj([
            "title": str(500),
            "summary": TEXT,
            "sections": list(obj([
                "heading": str(1000),
                "points": list(obj(["text": TEXT, "details": list(TEXT, 200)], ["text"]), 500),
            ], ["heading", "points"]), 200),
            "next_steps": list(obj(["owner": str(500), "task": TEXT], ["task"]), 500),
            "decisions": list(TEXT, 500),
            "speaker_names": list(obj(["label": str(50), "name": NAME_TEXT, "evidence": TEXT], ["label", "name"]), 500),
        ], ["summary"]))),
    ])

    public static let VOICE = JSONSchema(obj([
        "label": LABEL_TEXT, "name": NAME_TEXT,
        "embedding": s(["type": .string("array"), "items": s(["type": .string("number")]), "minItems": .int(16), "maxItems": .int(4096)]),
    ], ["label", "name", "embedding"]))

    // MARK: - check

    /// `isinstance` per JSON Schema type, as `_TYPES` (a bool is no integer or number).
    static func isType(_ value: JSONValue, _ type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("integer", .int), ("number", .int),
             ("number", .double), ("boolean", .bool), ("null", .null): return true
        default: return false
        }
    }

    /// `a < b` on two JSON numbers, as Python compares an int with an int or a float.
    static func less(_ a: JSONValue, _ b: JSONValue) -> Bool {
        if case .int(let x) = a, case .int(let y) = b { return x < y }
        return (a.doubleValue ?? 0) < (b.doubleValue ?? 0)
    }

    /// `check`: `value` against `schema`; throws `ExchangeRejected` naming the first place that does not fit.
    public static func check(_ value: JSONValue, schema: JSONSchema, where at: String) throws {
        if let types = schema.types, !types.contains(where: { isType(value, $0) }) {
            throw ExchangeRejected("\(at) is not \(types.joined(separator: " or "))")
        }
        if let options = schema.enumValues, !options.contains(where: { PythonJSON.equal(value, $0) }) {
            throw ExchangeRejected("\(at) has a value it can't have")
        }
        switch value {
        case .string(let text):
            let n = text.unicodeScalars.count
            if n > (schema.maxLength ?? n) || n < (schema.minLength ?? 0) {
                throw ExchangeRejected("\(at) is too long or too short")
            }
            if let pattern = schema.pattern, pattern.fullMatch(text) == nil {
                throw ExchangeRejected("\(at) is not in the expected form")
            }
        case .int, .double:
            if case .double(let d) = value, !d.isFinite { throw ExchangeRejected("\(at) is not a finite number") }  // 1e999
            if let min = schema.minimum, less(value, min) { throw ExchangeRejected("\(at) is out of range") }
            if let max = schema.maximum, less(max, value) { throw ExchangeRejected("\(at) is out of range") }
        case .array(let items):
            if items.count > (schema.maxItems ?? items.count) || items.count < (schema.minItems ?? 0) {
                throw ExchangeRejected("\(at) has too many or too few items")
            }
            if let itemSchema = schema.items {
                for (i, item) in items.enumerated() { try check(item, schema: itemSchema, where: "\(at)[\(i)]") }
            }
        case .object(let fields):
            if fields.count > (schema.maxProperties ?? fields.count) { throw ExchangeRejected("\(at) has too many entries") }
            for key in schema.required where !fields.contains(where: { Py.same($0.0, key) }) {
                throw ExchangeRejected("\(at) lacks \(MyNotes.pyRepr(.string(key)))")
            }
            for (key, item) in fields {
                if let names = schema.propertyNames { try check(.string(key), schema: names, where: "\(at) key") }
                if let prop = schema.properties[key] {
                    try check(item, schema: prop, where: "\(at).\(key)")
                } else {
                    switch schema.additional {
                    case .allowed: break
                    case .forbidden: throw ExchangeRejected("\(at) has \(MyNotes.pyRepr(.string(first40(key)))), which it can't have")
                    case .schema(let extra): try check(item, schema: extra, where: "\(at).\(first40(key))")
                    }
                }
            }
        case .null, .bool:
            break
        }
    }

    /// `key[:40]`, in code points.
    static func first40(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.prefix(40))) }

    // MARK: - _json and _time

    /// `_json`: strict JSON. UTF-8, no NaN or Infinity, no nesting deep enough to hurt.
    public static func json(_ data: Data, where at: String) throws -> JSONValue {
        let invalid = ExchangeRejected("\(at) is not valid JSON")
        guard String(validating: data, as: UTF8.self) != nil else { throw invalid }  // data.decode("utf-8") first
        do {
            return try PythonJSON.parse(data) { name in throw ExchangeRejected("\(at) has \(name), which JSON can't have") }
        } catch let rejected as ExchangeRejected {
            throw rejected
        } catch {
            throw invalid
        }
    }

    /// `_time`: `datetime.fromisoformat(text.replace("Z", "+00:00"))`, which must have a time zone and a year from 2000
    /// to 2100. Reads the forms the schemas' TIME pattern lets through (`YYYY-MM-DD`, any one character, `HH:MM:SS`, a
    /// fraction, `±HH:MM`; also a bare date or `HH:MM`), with ASCII digits as Python 3.13 does; anything else "is not a time".
    public static func time(_ text: String, where at: String) throws -> ExchangeTime {
        let notATime = ExchangeRejected("\(at) is not a time")
        let s = Array(text.replacingOccurrences(of: "Z", with: "+00:00").unicodeScalars)  // literal, as str.replace
        var i = 0
        func digits(_ n: Int) throws -> Int {
            guard i + n <= s.count else { throw notATime }
            var v = 0
            for u in s[i..<i + n] {
                guard ("0"..."9").contains(u) else { throw notATime }
                v = v * 10 + Int(u.value - 48)
            }
            i += n
            return v
        }
        func expect(_ c: Unicode.Scalar) throws {
            guard i < s.count, s[i] == c else { throw notATime }
            i += 1
        }
        let year = try digits(4); try expect("-")
        let month = try digits(2); try expect("-")
        let day = try digits(2)
        var hour = 0, minute = 0, second = 0, micro = 0
        var offset: Int?
        if i < s.count {
            i += 1  // the separator: any one character
            hour = try digits(2); try expect(":")
            minute = try digits(2)
            if i < s.count, s[i] == ":" {
                i += 1
                second = try digits(2)
                if i < s.count, s[i] == "." {
                    i += 1
                    let from = i
                    while i < s.count, ("0"..."9").contains(s[i]) { i += 1 }
                    guard i > from else { throw notATime }
                    let fraction = s[from..<min(i, from + 6)].map { Int($0.value - 48) }
                    micro = (fraction + Array(repeating: 0, count: 6 - fraction.count)).reduce(0) { $0 * 10 + $1 }
                }
            }
            if i < s.count {
                let sign = s[i]
                guard sign == "+" || sign == "-" else { throw notATime }
                i += 1
                let hh = try digits(2); try expect(":")
                let mm = try digits(2)
                let seconds = hh * 3600 + mm * 60
                guard seconds < 86400 else { throw notATime }  // strictly between -24 h and 24 h
                offset = sign == "-" ? -seconds : seconds
            }
            guard i == s.count else { throw notATime }
        }
        guard (1...12).contains(month), (1...daysIn(year, month)).contains(day), (0...23).contains(hour),
              (0...59).contains(minute), (0...59).contains(second), year >= 1 else { throw notATime }
        guard let offset else { throw ExchangeRejected("\(at) has no time zone") }
        guard (2000...2100).contains(year) else { throw ExchangeRejected("\(at) is out of range") }
        let local = Int64(daysFromCivil(year, month, day)) * 86400 + Int64(hour * 3600 + minute * 60 + second)
        return ExchangeTime(year: year, month: month, day: day, hour: hour, minute: minute, second: second, microsecond: micro,
                            utcOffset: offset, epochMicroseconds: (local - Int64(offset)) * 1_000_000 + Int64(micro))
    }

    static func daysIn(_ year: Int, _ month: Int) -> Int {
        guard (1...12).contains(month) else { return 0 }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date.
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
