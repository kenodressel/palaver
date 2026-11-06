// daemon.json (inventory §4): the daemon's status, written atomically through `.tmp` on every
// tick, in the key order and value shapes of daemon.py's `Daemon.status()`; its readers are the
// window's server (webapp/remote.py), `process` (continuation.being_recorded), doctor and report.
// Also the JSON value type the status is built from, and Python's isoformat for wall times.
import Foundation
import PalaverCore

/// A JSON value that keeps its keys in order (Python dicts do, and daemon.json is read by people too).
public indirect enum JSONValue: Equatable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.int(x), .int(y)): return x == y
        case let (.double(x), .double(y)): return x == y
        case let (.int(x), .double(y)), let (.double(y), .int(x)): return Double(x) == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)):
            return x.count == y.count && x.allSatisfy { k, v in y.first { $0.0 == k }?.1 == v }
        default: return false
        }
    }

    public static func str(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
    public static func num(_ d: Double?) -> JSONValue { d.map { .double($0) } ?? .null }
    public static func strings(_ a: [String]) -> JSONValue { .array(a.map { .string($0) }) }

    /// From what JSONSerialization parsed (booleans told apart from numbers).
    public init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let s as String: self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else if CFNumberIsFloatType(n) { self = .double(n.doubleValue) }
            else { self = .int(n.intValue) }
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any]: self = .object(o.keys.sorted().map { ($0, JSONValue(any: o[$0])) })
        default: self = .null
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields.first { $0.0 == key }?.1 }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var doubleValue: Double? {
        switch self { case .double(let d): return d; case .int(let i): return Double(i); default: return nil }
    }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var isNull: Bool { if case .null = self { return true } else { return false } }
    /// Python's truthiness: null, false, 0, "", [] and {} are false.
    public var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    /// `json.dumps(value, indent=indent)` (ensure_ascii, Python's float repr).
    public func encoded(indent: Int? = 2) -> String {
        var out = ""
        write(into: &out, indent: indent, level: 0)
        return out
    }

    public var description: String { encoded(indent: nil) }

    private func write(into out: inout String, indent: Int?, level: Int) {
        func newline(_ l: Int) { if let indent { out += "\n" + String(repeating: " ", count: indent * l) } }
        let sep = indent == nil ? ", " : ","
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += JSONValue.pythonFloat(d)
        case .string(let s): out += JSONLines.string(s)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += sep }
                newline(level + 1)
                v.write(into: &out, indent: indent, level: level + 1)
            }
            newline(level)
            out += "]"
        case .object(let o):
            if o.isEmpty { out += "{}"; return }
            out += "{"
            for (i, (k, v)) in o.enumerated() {
                if i > 0 { out += sep }
                newline(level + 1)
                out += JSONLines.string(k) + ": "
                v.write(into: &out, indent: indent, level: level + 1)
            }
            newline(level)
            out += "}"
        }
    }

    /// Python's `repr(float)`: 600.0, 0.1, 1e-05, Infinity.
    static func pythonFloat(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        return "\(d)"
    }

    /// Parses JSON text; nil when it is not JSON.
    public static func parse(_ data: Data) -> JSONValue? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(any: any)
    }
}

// MARK: - wall times (Python's datetime.isoformat / fromisoformat)

public enum WallTime {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var calendars: [Int: Calendar] = [:]

    /// A Gregorian calendar in a fixed offset (made once: daemon.json is written every second).
    static func calendar(_ timeZone: TimeZone, at date: Date) -> Calendar {
        let offset = timeZone.secondsFromGMT(for: date)
        return lock.withLock {
            if let c = calendars[offset] { return c }
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(secondsFromGMT: offset) ?? timeZone
            calendars[offset] = c
            return c
        }
    }

    /// `datetime.isoformat()`: seconds, plus microseconds when there are any (`seconds: true`:
    /// `isoformat(timespec="seconds")`), with the UTC offset of `timeZone` at that moment.
    public static func iso(_ date: Date, _ timeZone: TimeZone, seconds: Bool = false) -> String {
        let cal = calendar(timeZone, at: date)
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let whole = date.timeIntervalSince1970.rounded(.down)
        let micros = Int(((date.timeIntervalSince1970 - whole) * 1_000_000).rounded())
        var s = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        if !seconds && micros > 0 && micros < 1_000_000 { s += String(format: ".%06d", micros) }
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        s += String(format: "%@%02d:%02d", sign, abs(offset) / 3600, abs(offset) % 3600 / 60)
        return s
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,6}))?)?(Z|[+-]\d{2}:?\d{2})?$"#)

    /// `datetime.fromisoformat`: a moment; one without an offset is local time (`timeZone`).
    public static func parse(_ text: String?, _ timeZone: TimeZone = .current) -> Date? {
        guard let text, let m = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: text) else { return nil }
            return String(text[r])
        }
        var c = DateComponents()
        c.year = Int(group(1)!); c.month = Int(group(2)!); c.day = Int(group(3)!)
        c.hour = Int(group(4)!); c.minute = Int(group(5)!); c.second = Int(group(6) ?? "0")
        var tz = timeZone
        if let off = group(8) {
            if off == "Z" { tz = TimeZone(secondsFromGMT: 0)! } else {
                let digits = off.dropFirst().replacingOccurrences(of: ":", with: "")
                let secs = (Int(digits.prefix(2))! * 3600 + Int(digits.suffix(2))! * 60) * (off.hasPrefix("-") ? -1 : 1)
                guard let z = TimeZone(secondsFromGMT: secs) else { return nil }
                tz = z
            }
        }
        let cal: Calendar
        if group(8) != nil {
            cal = calendar(tz, at: Date())  // a fixed offset
        } else {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = tz
            cal = c
        }
        guard let base = cal.date(from: c) else { return nil }
        let frac = group(7).map { Double("0." + $0) ?? 0 } ?? 0
        return base.addingTimeInterval(frac)
    }

    /// "12:06" in `timeZone`.
    public static func hm(_ date: Date, _ timeZone: TimeZone) -> String {
        let c = calendar(timeZone, at: date).dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }
}

// MARK: - the file

public enum DaemonStateFile {
    /// daemon.json as a dictionary; empty when it is missing, broken or not an object.
    public static func read(_ url: URL) -> JSONValue {
        guard let data = try? Data(contentsOf: url), let v = JSONValue.parse(data), case .object = v else { return .object([]) }
        return v
    }

    /// Writes `status` through `<name>.tmp` and a rename, as `_write_state` does. False when it failed.
    @discardableResult
    public static func write(_ status: JSONValue, to url: URL) -> Bool {
        let tmp = url.deletingPathExtension().appendingPathExtension("tmp")
        let data = Data(status.encoded(indent: 2).utf8)
        if (try? data.write(to: tmp)) == nil {  // the folder is made once, when it is missing
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: tmp)) != nil else { return false }
        }
        return rename(tmp.path, url.path) == 0
    }
}
