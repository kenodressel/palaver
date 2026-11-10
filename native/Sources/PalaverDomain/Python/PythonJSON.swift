// Every JSON file the domain, the server and the worker read or write goes through here, so the
// bytes on disk stay what Python's `json` writes: key order, separators, `indent`, `ensure_ascii`,
// Python's float repr, ints apart from floats. Never JSONSerialization, JSONValue.parse or Codable.
import Darwin
import Foundation
import PalaverCore

public enum PythonJSON {
    /// How deep `parse` reads nested lists and objects; deeper is an error.
    public static let MAX_DEPTH = 200

    public struct ParseError: Error, CustomStringConvertible {
        public let message: String
        public let offset: Int
        public var description: String { "\(message): byte \(offset)" }
    }

    // MARK: - json.loads

    /// `json.loads`: keys in file order; a duplicate key keeps the last value at the first key's
    /// place (a dict assignment). Accepts `NaN`, `Infinity` and `-Infinity`. An integer literal is
    /// `.int` (one too big for Int becomes `.double`), anything with `.`, `e` or `E` is `.double`.
    /// UTF-8 only; control characters inside strings are errors, as with `strict=True`. `parseConstant` is
    /// `json.loads(parse_constant=)`: called with "NaN", "Infinity" or "-Infinity" where one is read; what it throws
    /// comes out of `parse` as it is.
    public static func parse(_ data: Data, parseConstant: ((String) throws -> JSONValue)? = nil) throws -> JSONValue {
        var parser = Parser(bytes: [UInt8](data), parseConstant: parseConstant)
        parser.skipSpace()
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.at == parser.bytes.count else { throw parser.error("Extra data") }
        return value
    }

    /// The file's JSON; nil when it is missing or not JSON.
    public static func read(_ url: URL) -> JSONValue? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? parse(data)
    }

    /// Python's `==` on two parsed values: objects with the same keys (in any order), strings by code points, numbers
    /// by value (`1 == 1.0`, `True == 1`).
    public static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
        func number(_ v: JSONValue) -> Double? {
            switch v {
            case .int(let i): return Double(i)
            case .double(let d): return d
            case .bool(let b): return b ? 1 : 0
            default: return nil
            }
        }
        switch (a, b) {
        case (.null, .null): return true
        case let (.int(x), .int(y)): return x == y
        case let (.string(x), .string(y)): return Py.same(x, y)
        case let (.array(x), .array(y)): return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        case (.object, .object):
            guard let dx = PyDict<JSONValue>(a), let dy = PyDict<JSONValue>(b), dx.count == dy.count else { return false }
            return dx.allSatisfy { key, value in dy[key].map { equal(value, $0) } ?? false }
        default:
            guard let x = number(a), let y = number(b) else { return false }
            return x == y
        }
    }

    // MARK: - json.dumps

    /// `json.dumps(v, indent=, ensure_ascii=, sort_keys=)`: `", "` and `": "` without an indent,
    /// `","` and a newline plus `indent` spaces per level with one; empty lists and objects stay `[]`
    /// and `{}`. Floats are Python's repr.
    public static func dumps(_ v: JSONValue, indent: Int? = nil, ensureAscii: Bool = true, sortKeys: Bool = false) -> String {
        var out = ""
        dump(v, into: &out, indent: indent, ensureAscii: ensureAscii, sortKeys: sortKeys, level: 0)
        return out
    }

    /// Writes `dumps(v)` (plus "\n" when `newline`) as UTF-8. With `tmp`: into that name in the
    /// same folder, then renamed over `url` (`tmp.write_text(...); tmp.replace(path)`). Without:
    /// in place, truncating, as `Path.write_text` does.
    public static func write(_ v: JSONValue, to url: URL, indent: Int?, ensureAscii: Bool,
                             newline: Bool = false, via tmp: String? = nil) throws {
        var text = dumps(v, indent: indent, ensureAscii: ensureAscii)
        if newline { text += "\n" }
        guard let tmp else { return try writeText(text, url.path) }
        let staged = url.deletingLastPathComponent().appendingPathComponent(tmp).path
        try writeText(text, staged)
        guard rename(staged, url.path) == 0 else { throw posixError() }
    }

    /// `open(path, "w")` and write, as `Path.write_text` does: created 0666 less the umask, an
    /// existing file truncated and kept (its inode and mode).
    private static func writeText(_ text: String, _ path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + done, bytes.count - done) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw posixError() }
            done += n
        }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private static func dump(_ v: JSONValue, into out: inout String, indent: Int?, ensureAscii: Bool, sortKeys: Bool, level: Int) {
        func newline(_ l: Int) { if let indent { out += "\n" + String(repeating: " ", count: indent * l) } }
        let separator = indent == nil ? ", " : ","
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += JSONValue.pythonFloat(d)
        case .string(let s): out += string(s, ensureAscii: ensureAscii)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += separator }
                newline(level + 1)
                dump(item, into: &out, indent: indent, ensureAscii: ensureAscii, sortKeys: sortKeys, level: level + 1)
            }
            newline(level)
            out += "]"
        case .object(var fields):
            if fields.isEmpty { out += "{}"; return }
            if sortKeys { fields = sortedByKey(fields) }
            out += "{"
            for (i, (key, item)) in fields.enumerated() {
                if i > 0 { out += separator }
                newline(level + 1)
                out += string(key, ensureAscii: ensureAscii) + ": "
                dump(item, into: &out, indent: indent, ensureAscii: ensureAscii, sortKeys: sortKeys, level: level + 1)
            }
            newline(level)
            out += "}"
        }
    }

    /// Python's `sorted(dct.items())` on keys: code point order, stable.
    private static func sortedByKey(_ fields: [(String, JSONValue)]) -> [(String, JSONValue)] {
        let keyed = fields.enumerated().map { (Array($0.element.0.unicodeScalars.map(\.value)), $0.offset, $0.element) }
        return keyed.sorted { a, b in
            a.0 == b.0 ? a.1 < b.1 : a.0.lexicographicallyPrecedes(b.0)
        }.map(\.2)
    }

    /// A string literal: with `ensureAscii` everything outside ASCII 0x20–0x7E is `\uXXXX`
    /// (surrogate pairs above U+FFFF); without it only `"`, `\` and control characters are escaped.
    private static func string(_ s: String, ensureAscii: Bool) -> String {
        if ensureAscii { return JSONLines.string(s) }
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    // MARK: - the parser

    private struct Parser {
        let bytes: [UInt8]
        let parseConstant: ((String) throws -> JSONValue)?
        var at = 0

        func error(_ message: String) -> ParseError { ParseError(message: message, offset: at) }

        mutating func skipSpace() {
            while at < bytes.count, bytes[at] == 0x20 || bytes[at] == 0x09 || bytes[at] == 0x0A || bytes[at] == 0x0D { at += 1 }
        }

        mutating func literal(_ word: String) -> Bool {
            let w = Array(word.utf8)
            guard at + w.count <= bytes.count, Array(bytes[at..<at + w.count]) == w else { return false }
            at += w.count
            return true
        }

        mutating func value(depth: Int) throws -> JSONValue {
            // Python reads deeper (to its recursion limit, past 1000); here 1000 levels overflow a 512 KB thread stack in a
            // debug build. No file Palaver writes nests beyond a dozen levels; the exchange reads untrusted ones.
            guard depth < MAX_DEPTH else { throw error("Too deeply nested") }
            guard at < bytes.count else { throw error("Expecting value") }
            switch bytes[at] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            default: break
            }
            if literal("null") { return .null }
            if literal("true") { return .bool(true) }
            if literal("false") { return .bool(false) }
            if literal("NaN") { return try parseConstant?("NaN") ?? .double(.nan) }
            if literal("Infinity") { return try parseConstant?("Infinity") ?? .double(.infinity) }
            if literal("-Infinity") { return try parseConstant?("-Infinity") ?? .double(-.infinity) }
            return try number()
        }

        mutating func object(depth: Int) throws -> JSONValue {
            at += 1
            var fields: [(String, JSONValue)] = []
            var index: [ScalarKey: Int] = [:]
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "}") { at += 1; return .object([]) }
            while true {
                guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else {
                    throw error("Expecting property name enclosed in double quotes")
                }
                let key = try string()
                skipSpace()
                guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { throw error("Expecting ':' delimiter") }
                at += 1
                skipSpace()
                let item = try value(depth: depth + 1)
                if let i = index[ScalarKey(key)] { fields[i].1 = item } else { index[ScalarKey(key)] = fields.count; fields.append((key, item)) }
                skipSpace()
                guard at < bytes.count else { throw error("Expecting ',' delimiter") }
                if bytes[at] == UInt8(ascii: "}") { at += 1; return .object(fields) }
                guard bytes[at] == UInt8(ascii: ",") else { throw error("Expecting ',' delimiter") }
                at += 1
                skipSpace()
            }
        }

        mutating func array(depth: Int) throws -> JSONValue {
            at += 1
            var items: [JSONValue] = []
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "]") { at += 1; return .array([]) }
            while true {
                items.append(try value(depth: depth + 1))
                skipSpace()
                guard at < bytes.count else { throw error("Expecting ',' delimiter") }
                if bytes[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
                guard bytes[at] == UInt8(ascii: ",") else { throw error("Expecting ',' delimiter") }
                at += 1
                skipSpace()
            }
        }

        /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?`, json's NUMBER_RE.
        mutating func number() throws -> JSONValue {
            let start = at
            func digits() -> Int {
                let from = at
                while at < bytes.count, bytes[at] >= 0x30, bytes[at] <= 0x39 { at += 1 }
                return at - from
            }
            if at < bytes.count, bytes[at] == UInt8(ascii: "-") { at += 1 }
            guard at < bytes.count, bytes[at] >= 0x30, bytes[at] <= 0x39 else { at = start; throw error("Expecting value") }
            if bytes[at] == UInt8(ascii: "0") { at += 1 } else { _ = digits() }
            var isFloat = false
            if at + 1 < bytes.count, bytes[at] == UInt8(ascii: "."), bytes[at + 1] >= 0x30, bytes[at + 1] <= 0x39 {
                at += 1
                _ = digits()
                isFloat = true
            }
            if at < bytes.count, bytes[at] == UInt8(ascii: "e") || bytes[at] == UInt8(ascii: "E") {
                let mark = at
                at += 1
                if at < bytes.count, bytes[at] == UInt8(ascii: "-") || bytes[at] == UInt8(ascii: "+") { at += 1 }
                if digits() > 0 { isFloat = true } else { at = mark }  // "1e" is 1, then extra data
            }
            let text = String(decoding: bytes[start..<at], as: UTF8.self)
            if !isFloat, let i = Int(text) { return .int(i) }
            guard let d = Double(text) else { throw error("Expecting value") }
            return .double(d)
        }

        mutating func string() throws -> String {
            at += 1
            var raw: [UInt8] = []
            while true {
                guard at < bytes.count else { throw error("Unterminated string") }
                let b = bytes[at]
                if b == UInt8(ascii: "\"") { at += 1; break }
                if b < 0x20 { throw error("Invalid control character") }
                if b != UInt8(ascii: "\\") { raw.append(b); at += 1; continue }
                at += 1
                guard at < bytes.count else { throw error("Unterminated string") }
                let e = bytes[at]
                at += 1
                switch e {
                case UInt8(ascii: "\""): raw.append(e)
                case UInt8(ascii: "\\"): raw.append(e)
                case UInt8(ascii: "/"): raw.append(e)
                case UInt8(ascii: "b"): raw.append(0x08)
                case UInt8(ascii: "f"): raw.append(0x0C)
                case UInt8(ascii: "n"): raw.append(0x0A)
                case UInt8(ascii: "r"): raw.append(0x0D)
                case UInt8(ascii: "t"): raw.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800..<0xDC00).contains(scalar), at + 1 < bytes.count,
                       bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u") {
                        let mark = at
                        at += 2
                        let low = try hex4()
                        if (0xDC00..<0xE000).contains(low) {
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            at = mark  // a lone high surrogate; the next escape stands alone
                        }
                    }
                    // Python keeps a lone surrogate; a Swift string cannot hold one.
                    UTF8.encode(Unicode.Scalar(scalar) ?? "\u{FFFD}") { raw.append($0) }
                default:
                    at -= 1
                    throw error("Invalid \\escape")
                }
            }
            guard let s = String(validating: raw, as: UTF8.self) else { throw error("Invalid UTF-8") }
            return s
        }

        mutating func hex4() throws -> UInt32 {
            guard at + 4 <= bytes.count else { throw error("Invalid \\uXXXX escape") }
            var v: UInt32 = 0
            for b in bytes[at..<at + 4] {
                let digit: UInt8
                switch b {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = b - UInt8(ascii: "0")
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = b - UInt8(ascii: "a") + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = b - UInt8(ascii: "A") + 10
                default: throw error("Invalid \\uXXXX escape")
                }
                v = v << 4 | UInt32(digit)
            }
            at += 4
            return v
        }
    }
}
