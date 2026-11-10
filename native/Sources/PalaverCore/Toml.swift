import Foundation

/// A TOML value of the subset Palaver's config.toml uses.
public enum TomlValue: Equatable, Sendable {
    case string(String), int(Int), double(Double), bool(Bool)
    /// An array, inline table or anything else: parsed past, its content not kept.
    case other
}

/// A tolerant reader for the part of TOML config.toml uses: `[sections]` (also dotted),
/// bare or quoted keys, strings (basic, literal, multi-line), integers, floats, booleans,
/// comments. Arrays and inline tables are skipped. A line that does not parse is ignored:
/// a broken config never stops the app. Values are never logged.
public enum Toml {
    /// Flat map, keyed "section.key" ("key" at the top level).
    public static func parse(_ text: String) -> [String: TomlValue] { parseOrdered(text).values }

    /// `parse`, and the keys in the order the file gave them (a repeated key keeps its first place).
    public static func parseOrdered(_ text: String) -> (values: [String: TomlValue], order: [String]) {
        var out: [String: TomlValue] = [:]
        var order: [String] = []
        func put(_ key: String, _ value: TomlValue) {
            if out.updateValue(value, forKey: key) == nil { order.append(key) }
        }
        var section = ""
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            i += 1
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                if line.hasPrefix("[[") { section = "\u{0}array"; continue }
                var scan = Scanner(line.dropFirst())
                if let name = scan.keyPath(until: "]") { section = name } else { section = "\u{0}bad" }
                continue
            }
            var scan = Scanner(Substring(line))
            guard let key = scan.keyPath(until: "="), scan.consume("=") else { continue }
            scan.skipSpaces()
            let full = section.isEmpty ? key : section + "." + key
            let rest = scan.rest
            // Multi-line strings.
            for q in ["\"\"\"", "'''"] where rest.hasPrefix(q) {
                var body = String(rest.dropFirst(3))
                if let end = body.range(of: q) {
                    put(full, .string(String(body[..<end.lowerBound])))
                } else {
                    while i < lines.count {
                        body += "\n" + lines[i]
                        i += 1
                        if let end = body.range(of: q) {
                            put(full, .string(String(body[..<end.lowerBound]).trimmingCharacters(in: .newlines)))
                            break
                        }
                    }
                }
                break
            }
            if out[full] != nil, rest.hasPrefix("\"\"\"") || rest.hasPrefix("'''") { continue }
            if rest.hasPrefix("[") || rest.hasPrefix("{") {
                // Skip to the matching close, across lines.
                var depth = 0, inStr: Character? = nil
                var text = rest
                while true {
                    var escaped = false
                    for ch in text {
                        if let q = inStr {
                            if escaped { escaped = false }
                            else if ch == "\\", q == "\"" { escaped = true }
                            else if ch == q { inStr = nil }
                            continue
                        }
                        if ch == "\"" || ch == "'" { inStr = ch }
                        else if ch == "#" { break }
                        else if ch == "[" || ch == "{" { depth += 1 }
                        else if ch == "]" || ch == "}" { depth -= 1 }
                    }
                    if depth <= 0 || i >= lines.count { break }
                    text = lines[i]
                    i += 1
                }
                put(full, TomlValue.other)
                continue
            }
            if let v = scan.scalar() { put(full, v) }
        }
        return (out, order)
    }

    struct Scanner {
        private var s: Substring
        init(_ s: Substring) { self.s = s }
        var rest: String { s.trimmingCharacters(in: .whitespaces) }
        mutating func skipSpaces() { while s.first == " " || s.first == "\t" { s.removeFirst() } }
        mutating func consume(_ c: Character) -> Bool {
            skipSpaces()
            if s.first == c { s.removeFirst(); return true }
            return false
        }
        /// A (dotted) key, bare or quoted, up to `end` (not consumed).
        mutating func keyPath(until end: Character) -> String? {
            var parts: [String] = []
            while true {
                skipSpaces()
                guard let c = s.first else { return nil }
                if c == "\"" || c == "'" {
                    guard let str = quoted() else { return nil }
                    parts.append(str)
                } else {
                    var k = ""
                    while let ch = s.first, ch.isLetter || ch.isNumber || ch == "_" || ch == "-" { k.append(ch); s.removeFirst() }
                    if k.isEmpty { return nil }
                    parts.append(k)
                }
                skipSpaces()
                if s.first == "." { s.removeFirst(); continue }
                if s.first == end { if end == "]" { s.removeFirst() }; return parts.joined(separator: ".") }
                return nil
            }
        }
        mutating func quoted() -> String? {
            guard let q = s.first else { return nil }
            s.removeFirst()
            var out = ""
            while let ch = s.first {
                s.removeFirst()
                if ch == q { return out }
                if ch == "\\", q == "\"", let n = s.first {
                    s.removeFirst()
                    switch n {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "u", "U":
                        let len = n == "u" ? 4 : 8
                        let hex = String(s.prefix(len))
                        if let code = UInt32(hex, radix: 16), let u = Unicode.Scalar(code) { out.unicodeScalars.append(u); s.removeFirst(len) }
                    default: out.append(n)
                    }
                } else { out.append(ch) }
            }
            return nil
        }
        mutating func scalar() -> TomlValue? {
            skipSpaces()
            guard let c = s.first else { return nil }
            if c == "\"" || c == "'" { return quoted().map(TomlValue.string) }
            var tok = ""
            while let ch = s.first, ch != "#", ch != " ", ch != "\t", ch != "," { tok.append(ch); s.removeFirst() }
            switch tok {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: break
            }
            let clean = tok.replacingOccurrences(of: "_", with: "")
            if let n = Int(clean) { return .int(n) }
            if let d = Double(clean) { return .double(d) }
            return nil
        }
    }
}
