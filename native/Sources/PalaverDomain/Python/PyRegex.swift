// Python's `re` over NSRegularExpression: the pattern is translated so ICU matches what Python
// 3.13 matches. `\w \W \d \D \s \S \b \B` (inside and outside `[...]`) become explicit classes and
// lookarounds built from UnicodeTables; IGNORECASE expands each cased letter to the letters
// `re` folds it with (`simpleFold`), never ICU's folding (which matches "ss" to "ß"). `.`, `^`,
// `$` and `\Z` take Python's meaning (only `\n` ends a line); a class's members are all escaped
// (ICU reads `[[`, `&&` and `--` as set operators). Spans are code point offsets, as Python's.
// Not supported (init throws): scoped flags `(?i:...)`, conditionals `(?(1)...)`, `\N{...}`, the
// ASCII and LOCALE flags, and backreferences under IGNORECASE.
import Foundation

public struct PyRegex: @unchecked Sendable {  // NSRegularExpression is immutable and thread-safe
    public struct Error: Swift.Error, CustomStringConvertible {
        public let message: String
        public let pattern: String
        public var description: String { "\(message) in \(pattern.debugDescription)" }
    }

    public let pattern: String
    /// `pattern.groups` and `pattern.groupindex`.
    public let groupCount: Int
    public let groupIndex: [String: Int]
    private let icu: ICU

    public init(_ pattern: String, ignoreCase: Bool = false, verbose: Bool = false) throws {
        var translator = Translator(pattern, ignoreCase: ignoreCase, verbose: verbose)
        let translated = try translator.translate()
        self.pattern = pattern
        groupCount = translator.groups
        groupIndex = translator.names
        icu = try ICU(translated, groups: translator.groups, pattern: pattern)
    }

    /// `re.escape(s)`: a backslash before each of `()[]{}?*+-|^$\.&~#`, space, `\t\n\r\v\f`.
    public static func escape(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if "()[]{}?*+-|^$\\.&~# \t\n\r\u{0B}\u{0C}".unicodeScalars.contains(u) { out.append("\\") }
            out.append(u)
        }
        return String(out)
    }

    // MARK: - Matching

    /// `pattern.search(text)`.
    public func firstMatch(in text: String) -> PyMatch? {
        let subject = Subject(text)
        return next(in: subject, from: 0, mustAdvance: false).map { PyMatch($0, subject, groupCount, groupIndex) }
    }

    /// `pattern.finditer(text)`.
    public func matches(in text: String) -> [PyMatch] {
        let subject = Subject(text)
        var out: [PyMatch] = []
        each(in: subject, count: 0) { out.append(PyMatch($0, subject, groupCount, groupIndex)) }
        return out
    }

    /// `pattern.fullmatch(text)`.
    public func fullMatch(_ text: String) -> PyMatch? {
        let subject = Subject(text)
        let options: NSRegularExpression.MatchingOptions = [.anchored, .withTransparentBounds, .withoutAnchoringBounds]
        return icu.full.firstMatch(in: subject.string, options: options, range: NSRange(location: 0, length: subject.length))
            .map { PyMatch($0, subject, groupCount, groupIndex) }
    }

    /// `pattern.sub(template, text, count)`: `\1`, `\g<1>`, `\g<name>` and Python's escapes in
    /// the template; a group that did not take part is "". Throws for a template `re` rejects.
    public func sub(_ template: String, in text: String, count: Int = 0) throws -> String {
        let parts = try Template(template, groups: groupCount, names: groupIndex, pattern: pattern).parts
        return sub(in: text, count: count) { m in
            parts.map { part in
                switch part {
                case .text(let s): return s
                case .group(let i): return m.group(i) ?? ""
                }
            }.joined()
        }
    }

    /// `pattern.sub(function, text, count)`.
    public func sub(in text: String, count: Int = 0, _ replace: (PyMatch) throws -> String) rethrows -> String {
        let subject = Subject(text)
        var out = ""
        var done = 0  // UTF-16 offset copied so far
        try each(in: subject, count: count) { r in
            out += subject.slice(done, r.range.location)
            out += try replace(PyMatch(r, subject, groupCount, groupIndex))
            done = NSMaxRange(r.range)
        }
        out += subject.slice(done, subject.length)
        return out
    }

    /// The matches `finditer` and `sub` see: after a match the next search starts at its end, and
    /// after an empty match the next one must not be empty at the same place (sre's must_advance).
    private func each(in subject: Subject, count: Int, _ body: (NSTextCheckingResult) throws -> Void) rethrows {
        var at = 0, n = 0, mustAdvance = false
        while count == 0 || n < count, let r = next(in: subject, from: at, mustAdvance: mustAdvance) {
            try body(r)
            n += 1
            at = NSMaxRange(r.range)
            mustAdvance = r.range.length == 0
        }
    }

    private func next(in subject: Subject, from at: Int, mustAdvance: Bool) -> NSTextCheckingResult? {
        let options: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]
        var start = at
        if mustAdvance {
            // A non-empty match right here, else a search from the next code point on.
            if let r = icu.nonEmpty.firstMatch(in: subject.string, options: options.union(.anchored),
                                               range: NSRange(location: at, length: subject.length - at)) {
                return r
            }
            guard at < subject.length else { return nil }
            start = subject.nextScalar(after: at)
        }
        return icu.search.firstMatch(in: subject.string, options: options,
                                     range: NSRange(location: start, length: subject.length - start))
    }
}

/// A match: code point spans of the match and its groups, as Python's `Match.span`.
public struct PyMatch {
    public let text: String
    /// `[m.span(0), m.span(1), …]`: nil for a group that did not take part.
    public let spans: [Range<Int>?]
    private let utf16: [NSRange]
    private let names: [String: Int]

    fileprivate init(_ r: NSTextCheckingResult, _ subject: Subject, _ groups: Int, _ names: [String: Int]) {
        text = subject.text
        utf16 = (0...groups).map { r.range(at: $0) }
        spans = utf16.map { $0.location == NSNotFound ? nil : subject.scalar($0.location)..<subject.scalar(NSMaxRange($0)) }
        self.names = names
    }

    /// `m.span()`.
    public var range: Range<Int> { spans[0]! }
    /// `m.span(i)`; nil for a group that did not take part.
    public func span(_ group: Int = 0) -> Range<Int>? { spans[group] }
    /// `m.group(i)`; nil for a group that did not take part.
    public func group(_ i: Int = 0) -> String? {
        let r = utf16[i]
        guard r.location != NSNotFound else { return nil }
        let start = String.Index(utf16Offset: r.location, in: text), end = String.Index(utf16Offset: NSMaxRange(r), in: text)
        return String(text[start..<end])
    }
    /// `m.group(name)`.
    public func group(_ name: String) -> String? { names[name].flatMap { group($0) } }
}

// MARK: - Internals

/// The three compiled forms: search, fullmatch (`\z` after it, anchored) and "non-empty here"
/// (the pattern, then an atomic `\G` test that fails when the match ended where it started). The
/// last two are compiled on first use: a big class makes each compile cost milliseconds.
private final class ICU: @unchecked Sendable {  // the lazy forms are made under the lock
    let search: NSRegularExpression
    private let translated: String
    private let groups: Int
    private let lock = NSLock()
    private var fullForm: NSRegularExpression?
    private var nonEmptyForm: NSRegularExpression?

    init(_ translated: String, groups: Int, pattern: String) throws {
        do {
            search = try NSRegularExpression(pattern: translated)
        } catch {
            throw PyRegex.Error(message: "ICU rejected the translation (\(error.localizedDescription))", pattern: pattern)
        }
        guard search.numberOfCaptureGroups == groups else {
            throw PyRegex.Error(message: "group count \(search.numberOfCaptureGroups) after translation, want \(groups)", pattern: pattern)
        }
        self.translated = translated
        self.groups = groups
    }

    var full: NSRegularExpression { lazily(\.fullForm, "(?:\(translated))\\z") }
    var nonEmpty: NSRegularExpression { lazily(\.nonEmptyForm, "(?:\(translated))(?>\\G|())(?:\\\(groups + 1))") }

    private func lazily(_ slot: ReferenceWritableKeyPath<ICU, NSRegularExpression?>, _ form: @autoclosure () -> String) -> NSRegularExpression {
        lock.withLock {
            if let made = self[keyPath: slot] { return made }
            // The search form compiled, so these (it plus a fixed tail) do too.
            let made = try! NSRegularExpression(pattern: form())
            self[keyPath: slot] = made
            return made
        }
    }
}

/// The text as ICU sees it (UTF-16, made once per call) and its UTF-16 → code point offsets.
private struct Subject {
    let text: String
    let string: String  // backed by UTF-16 storage, so ICU does not convert it on every search
    let length: Int
    private let scalars: [Int]

    init(_ text: String) {
        self.text = text
        let units = Array(text.utf16)
        length = units.count
        string = NSString(characters: units, length: units.count) as String
        var map = [Int](repeating: 0, count: units.count + 1)
        var u = 0, s = 0
        for scalar in text.unicodeScalars {
            map[u] = s
            if scalar.value > 0xFFFF { map[u + 1] = s }
            u += scalar.value > 0xFFFF ? 2 : 1
            s += 1
        }
        map[u] = s
        scalars = map
    }

    func scalar(_ utf16: Int) -> Int { scalars[utf16] }

    func nextScalar(after utf16: Int) -> Int {
        utf16 + 1 < length && scalars[utf16 + 1] == scalars[utf16] ? utf16 + 2 : utf16 + 1
    }

    func slice(_ from: Int, _ to: Int) -> String {
        guard from < to else { return "" }
        return String(text[String.Index(utf16Offset: from, in: text)..<String.Index(utf16Offset: to, in: text)])
    }
}

/// Sorted, merged, closed code point ranges.
private struct RangeSet {
    private(set) var ranges: [(UInt32, UInt32)]

    init(_ items: [(UInt32, UInt32)]) {
        var merged: [(UInt32, UInt32)] = []
        for (lo, hi) in items.sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, lo <= last.1 &+ 1 {
                merged[merged.count - 1].1 = max(last.1, hi)
            } else {
                merged.append((lo, hi))
            }
        }
        ranges = merged
    }

    func contains(_ v: UInt32) -> Bool {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if v < ranges[mid].0 { hi = mid } else if v > ranges[mid].1 { lo = mid + 1 } else { return true }
        }
        return false
    }

    var complement: RangeSet {
        var out: [(UInt32, UInt32)] = []
        var next: UInt32 = 0
        for (lo, hi) in ranges {
            if lo > next { out.append((next, lo - 1)) }
            next = hi + 1
        }
        if next <= 0x10FFFF { out.append((next, 0x10FFFF)) }
        return RangeSet(out)
    }

    /// With every code point `re.IGNORECASE` matches to a member (a class matches a letter when
    /// any letter of its fold class is in it).
    var caseClosed: RangeSet {
        var extra: [(UInt32, UInt32)] = []
        for (cp, others) in UnicodeTables.simpleFold where contains(cp) {
            extra += others.map { ($0, $0) }
        }
        return extra.isEmpty ? self : RangeSet(ranges + extra)
    }

    /// An ICU class of escaped members, without surrogates (a Swift string has none).
    func icu(negated: Bool) -> String {
        var body = ""
        for (lo, hi) in ranges {
            for (a, b) in [(lo, min(hi, 0xD7FF)), (max(lo, 0xE000), hi)] where a <= b {
                body += a == b ? "\\x{\(hex(a))}" : "\\x{\(hex(a))}-\\x{\(hex(b))}"
            }
        }
        if body.isEmpty { return negated ? "[\\x{0}-\\x{10FFFF}]" : "(?!)" }
        return "[" + (negated ? "^" : "") + body + "]"
    }
}

private func hex(_ v: UInt32) -> String { String(v, radix: 16, uppercase: true) }

/// `\w \d \s` from UnicodeTables, as sets and as ICU text (made once).
private enum Category {
    static let word = RangeSet(UnicodeTables.wordRanges)
    static let digit = RangeSet(UnicodeTables.digitRanges)
    static let space = RangeSet(UnicodeTables.spaceRanges)
    static let wordClass = word.icu(negated: false)
    static let notWordClass = word.icu(negated: true)
    static let digitClass = digit.icu(negated: false)
    static let notDigitClass = digit.icu(negated: true)
    static let spaceClass = space.icu(negated: false)
    static let notSpaceClass = space.icu(negated: true)
    /// `\b`: a word character on one side only; never in an empty string.
    static let boundary = "(?:(?<=\(wordClass))(?!\(wordClass))|(?<!\(wordClass))(?=\(wordClass)))"
    /// `\B`: word characters on both sides or neither, but not in an empty string (Python 3.13).
    static let nonBoundary = "(?:(?<=\(wordClass))(?=\(wordClass))|(?<!\(wordClass))(?!\(wordClass))(?!\\A\\z))"

    /// The set an escape letter names inside `[...]`, or nil.
    static func set(_ letter: Unicode.Scalar) -> RangeSet? {
        switch letter {
        case "w": return word
        case "W": return word.complement
        case "d": return digit
        case "D": return digit.complement
        case "s": return space
        case "S": return space.complement
        default: return nil
        }
    }

    /// The ICU class an escape letter names outside `[...]`, or nil.
    static func text(_ letter: Unicode.Scalar) -> String? {
        switch letter {
        case "w": return wordClass
        case "W": return notWordClass
        case "d": return digitClass
        case "D": return notDigitClass
        case "s": return spaceClass
        case "S": return notSpaceClass
        default: return nil
        }
    }
}

private func isASCIIDigit(_ u: Unicode.Scalar) -> Bool { ("0"..."9").contains(u) }
private func isOctal(_ u: Unicode.Scalar) -> Bool { ("0"..."7").contains(u) }
private func isASCIILetter(_ u: Unicode.Scalar) -> Bool { ("a"..."z").contains(u) || ("A"..."Z").contains(u) }

/// `\a \f \n \r \t \v \\`, the escapes Python's pattern and template parsers share.
private let simpleEscapes: [Unicode.Scalar: UInt32] = ["a": 7, "f": 12, "n": 10, "r": 13, "t": 9, "v": 11, "\\": 92]

/// Python's pattern syntax (re/_parser.py) to ICU's.
private struct Translator {
    private let source: [Unicode.Scalar]
    private let pattern: String
    private var at = 0
    private var out = ""
    private var depth = 0
    private var ignoreCase: Bool
    private var verbose: Bool
    private var multiline = false
    private var dotAll = false
    private(set) var groups = 0
    private(set) var names: [String: Int] = [:]

    init(_ pattern: String, ignoreCase: Bool, verbose: Bool) {
        source = Array(pattern.unicodeScalars)
        self.pattern = pattern
        self.ignoreCase = ignoreCase
        self.verbose = verbose
    }

    private func error(_ message: String) -> PyRegex.Error { PyRegex.Error(message: "\(message) at position \(at)", pattern: pattern) }

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? { at + offset < source.count ? source[at + offset] : nil }

    private mutating func take() throws -> Unicode.Scalar {
        guard at < source.count else { throw error("unexpected end of pattern") }
        defer { at += 1 }
        return source[at]
    }

    mutating func translate() throws -> String {
        while at < source.count { try item() }
        guard depth == 0 else { throw error("missing ), unterminated subpattern") }
        return out
    }

    private mutating func item() throws {
        let c = try take()
        switch c {
        case "\\": try escape()
        case "[": try charClass()
        case "(": try group()
        case ")":
            guard depth > 0 else { throw error("unbalanced parenthesis") }
            depth -= 1
            out += ")"
        case "|", "*", "+", "?": out.unicodeScalars.append(c)
        case "{": quantifier()
        case ".": out += dotAll ? "[\\x{0}-\\x{10FFFF}]" : "[^\\x{A}]"
        case "^": out += multiline ? "(?:\\A|(?<=\\x{A}))" : "\\A"
        case "$": out += multiline ? "(?=\\x{A}|\\z)" : "(?=\\x{A}?\\z)"
        case "#" where verbose:
            while let n = peek(), n != "\n" { at += 1 }
        default:
            // VERBOSE skips whitespace outside classes (re/_parser.py WHITESPACE).
            if verbose && " \t\n\r\u{0B}\u{0C}".unicodeScalars.contains(c) { return }
            literal(c.value)
        }
    }

    /// One code point outside a class; under IGNORECASE, a class of it and its fold partners.
    private mutating func literal(_ v: UInt32) {
        if ignoreCase, let others = UnicodeTables.simpleFold[v] {
            out += RangeSet(([v] + others).map { ($0, $0) }).icu(negated: false)
        } else if v < 0x80, let u = Unicode.Scalar(v), isASCIILetter(u) || isASCIIDigit(u) {
            out.unicodeScalars.append(u)
        } else {
            out += "\\x{\(hex(v))}"
        }
    }

    /// `{m}`, `{m,}`, `{,n}`, `{m,n}`; anything else is a literal `{`.
    private mutating func quantifier() {
        let start = at
        var lo = "", hi = "", comma = false
        if peek() != "}" {
            while let d = peek(), isASCIIDigit(d) { lo.unicodeScalars.append(d); at += 1 }
            if peek() == "," {
                comma = true
                at += 1
                while let d = peek(), isASCIIDigit(d) { hi.unicodeScalars.append(d); at += 1 }
            }
            if peek() == "}" {
                at += 1
                out += comma ? "{\(lo.isEmpty ? "0" : lo),\(hi)}" : "{\(lo)}"
                return
            }
        }
        at = start
        literal(0x7B)
    }

    private mutating func escape() throws {
        guard at < source.count else { throw error("bad escape (end of pattern)") }
        let c = try take()
        if let category = Category.text(c) { out += category; return }
        switch c {
        case "A": out += "\\A"
        case "Z": out += "\\z"
        case "b": out += Category.boundary
        case "B": out += Category.nonBoundary
        case "x", "u", "U": literal(try hexEscape(c))
        case "0":
            var v: UInt32 = 0
            for _ in 0..<2 { guard let d = peek(), isOctal(d) else { break }; v = v * 8 + d.value - 48; at += 1 }
            literal(v)
        case "1"..."9":
            if let d = peek(), isASCIIDigit(d) {
                if isOctal(c), isOctal(d), let e = peek(1), isOctal(e) {
                    at += 2
                    let v = (c.value - 48) * 64 + (d.value - 48) * 8 + (e.value - 48)
                    guard v <= 0o377 else { throw error("octal escape value \\\(c)\(d)\(e) outside of range 0-0o377") }
                    literal(v)
                    return
                }
                at += 1
                try backreference(Int(c.value - 48) * 10 + Int(d.value - 48))
            } else {
                try backreference(Int(c.value - 48))
            }
        default:
            if let v = simpleEscapes[c] { literal(v); return }
            if c == "N" { throw error("\\N{...} is not supported") }
            if isASCIILetter(c) || isASCIIDigit(c) { throw error("bad escape \\\(c)") }
            literal(c.value)
        }
    }

    private mutating func backreference(_ group: Int) throws {
        guard group <= groups else { throw error("invalid group reference \(group)") }
        if ignoreCase { throw error("a backreference under IGNORECASE is not supported") }
        out += "(?:\\\(group))"
    }

    private mutating func hexEscape(_ kind: Unicode.Scalar) throws -> UInt32 {
        let width = kind == "x" ? 2 : kind == "u" ? 4 : 8
        var v: UInt32 = 0
        for _ in 0..<width {
            guard let d = peek(), let digit = Int(String(d), radix: 16) else { throw error("incomplete escape \\\(kind)") }
            v = v * 16 + UInt32(digit)
            at += 1
        }
        guard v <= 0x10FFFF else { throw error("bad escape \\\(kind)") }
        guard !(0xD800...0xDFFF).contains(v) else { throw error("a surrogate escape is not supported") }
        return v
    }

    private mutating func group() throws {
        guard peek() == "?" else {
            groups += 1
            depth += 1
            out += "("
            return
        }
        at += 1
        let c = try take()
        switch c {
        case ":", "=", "!", ">":
            depth += 1
            out += "(?" + String(c)
        case "<":
            let d = try take()
            guard d == "=" || d == "!" else { throw error("unknown extension ?<\(d)") }
            depth += 1
            out += "(?<" + String(d)
        case "P":
            let kind = try take()
            if kind == "<" {
                let name = try groupName(until: ">")
                guard names[name] == nil else { throw error("redefinition of group name \(name.debugDescription)") }
                groups += 1
                names[name] = groups
                depth += 1
                out += "("
            } else if kind == "=" {
                let name = try groupName(until: ")")
                guard let group = names[name] else { throw error("unknown group name \(name.debugDescription)") }
                try backreference(group)
            } else {
                throw error("unknown extension ?P\(kind)")
            }
        case "#":
            while try take() != ")" {}
        case "(":
            throw error("conditional groups are not supported")
        default:
            at -= 1
            try flags()
        }
    }

    private mutating func groupName(until end: Unicode.Scalar) throws -> String {
        var name = String.UnicodeScalarView()
        while true {
            let u = try take()
            if u == end { break }
            name.append(u)
        }
        let valid = name.first.map { $0 == "_" || Py.isAlpha($0) } == true && name.allSatisfy { Py.isWordScalar($0) }
        guard valid else { throw error("bad character in group name \(String(name).debugDescription)") }
        return String(name)
    }

    /// `(?imsx)` at the start of the pattern; scoped flags are not supported.
    private mutating func flags() throws {
        var letters: [Unicode.Scalar] = []
        while let u = peek(), "aiLmsux".unicodeScalars.contains(u) { letters.append(u); at += 1 }
        guard !letters.isEmpty, try take() == ")" else { throw error("scoped flags (?flags:...) are not supported") }
        guard out.isEmpty && depth == 0 else { throw error("global flags not at the start of the expression") }
        for letter in letters {
            switch letter {
            case "i": ignoreCase = true
            case "m": multiline = true
            case "s": dotAll = true
            case "x": verbose = true
            case "u": break
            default: throw error("the \(letter) flag is not supported")
            }
        }
    }

    private enum ClassItem {
        case code(UInt32)
        case set(RangeSet)
    }

    /// `[...]`: parsed into code point ranges, then written as an ICU class.
    private mutating func charClass() throws {
        var ranges: [(UInt32, UInt32)] = []
        func add(_ item: ClassItem) {
            switch item {
            case .code(let v): ranges.append((v, v))
            case .set(let s): ranges += s.ranges
            }
        }
        let negated = peek() == "^"
        if negated { at += 1 }
        var first = true
        while true {
            guard at < source.count else { throw error("unterminated character set") }
            let c = try take()
            if c == "]" && !first { break }
            first = false
            let item = c == "\\" ? try classEscape() : .code(c.value)
            guard peek() == "-" else { add(item); continue }
            at += 1
            guard at < source.count else { throw error("unterminated character set") }
            let d = try take()
            if d == "]" {
                add(item)
                ranges.append((0x2D, 0x2D))
                break
            }
            let upper = d == "\\" ? try classEscape() : .code(d.value)
            guard case .code(let lo) = item, case .code(let hi) = upper, lo <= hi else { throw error("bad character range") }
            ranges.append((lo, hi))
        }
        var set = RangeSet(ranges)
        if ignoreCase { set = set.caseClosed }
        out += set.icu(negated: negated)
    }

    private mutating func classEscape() throws -> ClassItem {
        let c = try take()
        if let category = Category.set(c) { return .set(category) }
        switch c {
        case "b": return .code(8)
        case "x", "u", "U": return .code(try hexEscape(c))
        case "0"..."7":
            var v = c.value - 48
            for _ in 0..<2 { guard let d = peek(), isOctal(d) else { break }; v = v * 8 + d.value - 48; at += 1 }
            guard v <= 0o377 else { throw error("octal escape value outside of range 0-0o377") }
            return .code(v)
        default:
            if let v = simpleEscapes[c] { return .code(v) }
            if c == "N" { throw error("\\N{...} is not supported") }
            if isASCIILetter(c) || isASCIIDigit(c) { throw error("bad escape \\\(c)") }
            return .code(c.value)
        }
    }
}

/// A `sub` template (re/_parser.py parse_template).
private struct Template {
    enum Part {
        case text(String)
        case group(Int)
    }

    private(set) var parts: [Part] = []

    init(_ template: String, groups: Int, names: [String: Int], pattern: String) throws {
        let s = Array(template.unicodeScalars)
        var at = 0
        var literal = String.UnicodeScalarView()
        func fail(_ message: String) -> PyRegex.Error { PyRegex.Error(message: "\(message) at position \(at) of the template", pattern: pattern) }
        func addGroup(_ i: Int) throws {
            guard i <= groups else { throw fail("invalid group reference \(i)") }
            if !literal.isEmpty { parts.append(.text(String(literal))); literal = String.UnicodeScalarView() }
            parts.append(.group(i))
        }
        while at < s.count {
            let c = s[at]
            at += 1
            guard c == "\\" else { literal.append(c); continue }
            guard at < s.count else { throw fail("bad escape (end of pattern)") }
            let e = s[at]
            at += 1
            switch e {
            case "g":
                guard at < s.count, s[at] == "<" else { throw fail("missing <") }
                guard let close = s[(at + 1)...].firstIndex(of: ">") else { throw fail("missing >, unterminated name") }
                let name = String(String.UnicodeScalarView(s[(at + 1)..<close]))
                at = close + 1
                if !name.isEmpty, name.unicodeScalars.allSatisfy(isASCIIDigit), let i = Int(name) {
                    try addGroup(i)
                } else if let i = names[name] {
                    try addGroup(i)
                } else {
                    throw fail("unknown group name \(name.debugDescription)")
                }
            case "0":
                var v = 0
                for _ in 0..<2 where at < s.count && isOctal(s[at]) { v = v * 8 + Int(s[at].value) - 48; at += 1 }
                literal.append(Unicode.Scalar(UInt8(v & 0xFF)))
            case "1"..."9":
                var digits = Int(e.value) - 48
                if at < s.count, isASCIIDigit(s[at]) {
                    let d = s[at]
                    at += 1
                    if isOctal(e), isOctal(d), at < s.count, isOctal(s[at]) {
                        let v = (Int(e.value) - 48) * 64 + (Int(d.value) - 48) * 8 + Int(s[at].value) - 48
                        at += 1
                        guard v <= 0o377 else { throw fail("octal escape value outside of range 0-0o377") }
                        literal.append(Unicode.Scalar(UInt8(v)))
                        continue
                    }
                    digits = digits * 10 + Int(d.value) - 48
                }
                try addGroup(digits)
            default:
                if let v = simpleEscapes[e] ?? (e == "b" ? 8 : nil), let u = Unicode.Scalar(v) {
                    literal.append(u)
                } else if isASCIILetter(e) {
                    throw fail("bad escape \\\(e)")
                } else {
                    literal.append("\\")  // Python keeps an unknown non-letter escape as it is
                    literal.append(e)
                }
            }
        }
        if !literal.isEmpty { parts.append(.text(String(literal))) }
    }
}
