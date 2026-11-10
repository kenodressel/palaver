// The JSON value the daemon builds daemon.json from and the domain reads and writes every file
// with (PalaverDomain's PythonJSON): keys stay in order, as in Python's dicts.
import Foundation

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
        if case .object(let fields) = self { return fields.first { $0.0.unicodeScalars.elementsEqual(key.unicodeScalars) }?.1 }
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

    /// A float as `json.dumps` writes it: Python's `repr` (600.0, 0.1, 1e-05, 1e+16, -0.0), and
    /// NaN, Infinity, -Infinity. Swift's description has the same shortest round-trip digits; only
    /// the layout is Python's: an exponent when the decimal point is 4 or more places left of the
    /// first digit or more than 16 right of it (CPython's `float_repr_style == "short"`).
    public static func pythonFloat(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        let sign = d.sign == .minus ? "-" : ""
        if d == 0 { return sign + "0.0" }
        var text = d.magnitude.description  // "600.0", "0.0001", "1e-05", "1.2345678901234568e+17"
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...])!
            text = String(text[..<e])
        }
        let whole = text.prefix { $0 != "." }
        var digits = String(text.filter { $0 != "." })
        var point = whole.count + exponent  // the value is 0.<digits> × 10^point
        while digits.hasPrefix("0") { digits.removeFirst(); point -= 1 }
        while digits.hasSuffix("0") { digits.removeLast() }
        if point <= -4 || point > 16 {
            let e = point - 1
            let mantissa = digits.count > 1 ? "\(digits.first!).\(digits.dropFirst())" : digits
            return sign + mantissa + "e" + (e < 0 ? "-" : "+") + (abs(e) < 10 ? "0" : "") + String(abs(e))
        }
        if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
        if point >= digits.count { return sign + digits + String(repeating: "0", count: point - digits.count) + ".0" }
        let split = digits.index(digits.startIndex, offsetBy: point)
        return sign + digits[..<split] + "." + digits[split...]
    }

    /// Parses JSON text; nil when it is not JSON. Sorts object keys (JSONSerialization loses their
    /// order): the daemon's reads only. The domain reads with PythonJSON.parse, which keeps it.
    public static func parse(_ data: Data) -> JSONValue? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(any: any)
    }
}
