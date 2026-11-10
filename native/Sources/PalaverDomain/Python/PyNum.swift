// A JSON number as Python computes with it: an int stays an int through `+`, `-` and `round(x, n)`, and is written
// back as an int; with a float it is a float. Where a file's ints reach what is written again (cutting.py's moved
// times: `round(d["start"] + shift, 3)` of an int is an int), a Double would write "1.0" where Python writes "1".
import PalaverCore

public enum PyNum: CustomStringConvertible, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, Sendable {
    case int(Int)
    case float(Double)

    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .float(value) }

    /// A JSON number (a bool is Python's int 0 or 1); nil for anything else.
    public init?(_ v: JSONValue?) {
        switch v {
        case .int(let i)?: self = .int(i)
        case .double(let d)?: self = .float(d)
        case .bool(let b)?: self = .int(b ? 1 : 0)
        default: return nil
        }
    }

    public var double: Double {
        switch self {
        case .int(let i): return Double(i)
        case .float(let d): return d
        }
    }

    public var json: JSONValue {
        switch self {
        case .int(let i): return .int(i)
        case .float(let d): return .double(d)
        }
    }

    public var description: String {
        switch self {
        case .int(let i): return String(i)
        case .float(let d): return Py.repr(d)
        }
    }

    public static func + (a: PyNum, b: PyNum) -> PyNum {
        if case .int(let x) = a, case .int(let y) = b {
            let (s, overflow) = x.addingReportingOverflow(y)
            if !overflow { return .int(s) }
        }
        return .float(a.double + b.double)
    }

    public static func - (a: PyNum, b: PyNum) -> PyNum {
        if case .int(let x) = a, case .int(let y) = b {
            let (s, overflow) = x.subtractingReportingOverflow(y)
            if !overflow { return .int(s) }
        }
        return .float(a.double - b.double)
    }

    public static prefix func - (a: PyNum) -> PyNum { 0 - a }

    /// `round(x, digits)`: an int as it is, a float correctly rounded (`Py.round`).
    public func rounded(_ digits: Int) -> PyNum {
        switch self {
        case .int: return self
        case .float(let d): return .float(Py.round(d, digits))
        }
    }

    // Python's comparisons: ints exactly, a float with NaN never true.
    public static func == (a: PyNum, b: PyNum) -> Bool {
        if case .int(let x) = a, case .int(let y) = b { return x == y }
        return a.double == b.double
    }
    public static func != (a: PyNum, b: PyNum) -> Bool { !(a == b) }
    public static func < (a: PyNum, b: PyNum) -> Bool {
        if case .int(let x) = a, case .int(let y) = b { return x < y }
        return a.double < b.double
    }
    public static func <= (a: PyNum, b: PyNum) -> Bool {
        if case .int(let x) = a, case .int(let y) = b { return x <= y }
        return a.double <= b.double
    }
    public static func > (a: PyNum, b: PyNum) -> Bool { b < a }
    public static func >= (a: PyNum, b: PyNum) -> Bool { b <= a }

    /// `min(a, b)`: `a` unless `b < a`.
    public static func min(_ a: PyNum, _ b: PyNum) -> PyNum { b < a ? b : a }
    /// `max(a, b)`: `a` unless `b > a`.
    public static func max(_ a: PyNum, _ b: PyNum) -> PyNum { b > a ? b : a }
}
