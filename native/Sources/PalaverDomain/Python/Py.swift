// Python's semantics where the domain has to give the Python writer's results: float round and
// repr, str's Unicode 15.1 rules (casefold, isalnum, isspace, split, strip), a stable sort, and
// datetime's ISO times. The Unicode rules come from UnicodeTables (generated from Python 3.13 by
// tools/make_unicode_tables.py), never from macOS or ICU.
import Foundation
import PalaverCore

/// Unicode 15.1 as Python 3.13's `str` and `re` see it. The data is UnicodeTables.swift.
public enum UnicodeTables {
    /// `\w`: `c.isalnum() or c == "_"`, as sorted closed ranges.
    public static let wordRanges = pairs(wordFlat)
    /// `\d`: `c.isdecimal()`.
    public static let digitRanges = pairs(digitFlat)
    /// `\s`: `c.isspace()`.
    public static let spaceRanges = pairs(spaceFlat)
    public static let upperRanges = pairs(upperFlat)
    public static let alphaRanges = pairs(alphaFlat)
    /// `c.casefold()` for every code point it changes (ß → ss).
    public static let caseFold: [UInt32: [UInt32]] = map(caseFoldFlat)
    /// `re.IGNORECASE`: each code point to the others it matches (k: K and the Kelvin sign).
    public static let simpleFold: [UInt32: [UInt32]] = map(simpleFoldFlat)

    /// Whether `v` is in the flat [lo, hi, lo, hi, …] ranges.
    static func contains(_ flat: [UInt32], _ v: UInt32) -> Bool {
        var lo = 0, hi = flat.count / 2
        while lo < hi {
            let mid = (lo + hi) / 2
            if v < flat[2 * mid] { hi = mid } else if v > flat[2 * mid + 1] { lo = mid + 1 } else { return true }
        }
        return false
    }

    private static func pairs(_ flat: [UInt32]) -> [(UInt32, UInt32)] {
        stride(from: 0, to: flat.count, by: 2).map { (flat[$0], flat[$0 + 1]) }
    }

    private static func map(_ flat: [UInt32]) -> [UInt32: [UInt32]] {
        var out: [UInt32: [UInt32]] = [:]
        var i = 0
        while i < flat.count {
            let n = Int(flat[i + 1])
            out[flat[i]] = Array(flat[(i + 2)..<(i + 2 + n)])
            i += 2 + n
        }
        return out
    }
}

public enum Py {
    // MARK: - Floats

    /// `round(x, digits)`: CPython's correctly rounded `float.__round__`, half to even on the exact
    /// binary value (`round(2.675, 2)` is 2.67, `round(0.125, 2)` is 0.12). Apple's printf rounds
    /// the exact value as CPython's dtoa does; strtod reads it back correctly rounded.
    public static func round(_ x: Double, _ digits: Int) -> Double {
        precondition(digits >= 0, "Py.round takes digits >= 0")
        guard x.isFinite, x != 0, digits <= 323 else { return x }  // CPython: NDIGITS_MAX
        return Double(String(format: "%.\(digits)f", x))!
    }

    /// What `int(x)` raises for NaN and infinity (ValueError, OverflowError); also for a value past Swift's Int, which
    /// Python's ints would hold. Only hand-edited files carry such numbers: a request fails, the server stays.
    public struct IntError: Error, CustomStringConvertible {
        public let description: String
    }

    /// `int(x)` of a float: truncated toward zero; throws where Swift's `Int(x)` would trap.
    public static func int(_ x: Double) throws -> Int {
        guard let n = Int(exactly: x.rounded(.towardZero)) else {
            throw IntError(description: x.isNaN ? "cannot convert float NaN to integer"
                                                : x.isInfinite ? "cannot convert float infinity to integer"
                                                : "the number \(repr(x)) is too large")
        }
        return n
    }

    /// `round(x)` of a float: an int, half to even; throws where Swift's `Int(x)` would trap.
    public static func roundInt(_ x: Double) throws -> Int { try int(x.rounded(.toNearestOrEven)) }

    /// `sum(xs)` of floats as CPython 3.12+ adds them (bltinmodule.c `builtin_sum_impl`, the float path from the int
    /// start 0): Neumaier's compensated summation, the compensation added once at the end when it is finite. A plain
    /// left-to-right `+` can differ in the last bits (200 times 0.3 is 60.0 here, 59.99999999999979 there).
    public static func sum(_ xs: [Double]) -> Double {
        var total = 0.0, c = 0.0
        for x in xs {
            let t = total + x
            if abs(total) >= abs(x) { c += (total - t) + x } else { c += (x - t) + total }
            total = t
        }
        if c != 0 && c.isFinite { total += c }
        return total
    }

    /// `repr(d)`: the shortest digits that read back, Python's layout ("1e-05", "600.0", "inf").
    public static func repr(_ d: Double) -> String {
        if d.isNaN { return "nan" }
        if d.isInfinite { return d < 0 ? "-inf" : "inf" }
        return JSONValue.pythonFloat(d)
    }

    // MARK: - str

    /// `s.casefold()`: full case folding, one code point at a time ("Straße" → "strasse").
    public static func casefold(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if let folded = UnicodeTables.caseFold[u.value] {
                out.append(contentsOf: folded.compactMap(Unicode.Scalar.init))
            } else {
                out.append(u)
            }
        }
        return String(out)
    }

    /// `\w` of Python's `re`: `c.isalnum() or c == "_"`.
    public static func isWordScalar(_ u: Unicode.Scalar) -> Bool { UnicodeTables.contains(UnicodeTables.wordFlat, u.value) }
    public static func isSpace(_ u: Unicode.Scalar) -> Bool { UnicodeTables.contains(UnicodeTables.spaceFlat, u.value) }
    public static func isDecimal(_ u: Unicode.Scalar) -> Bool { UnicodeTables.contains(UnicodeTables.digitFlat, u.value) }
    public static func isUpper(_ u: Unicode.Scalar) -> Bool { UnicodeTables.contains(UnicodeTables.upperFlat, u.value) }
    public static func isAlpha(_ u: Unicode.Scalar) -> Bool { UnicodeTables.contains(UnicodeTables.alphaFlat, u.value) }

    /// `s.split()`: the runs between whitespace (`\x1c`, `\x85` and U+3000 are whitespace too).
    public static func split(_ s: String) -> [String] {
        var out: [String] = []
        var word = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if isSpace(u) {
                if !word.isEmpty { out.append(String(word)); word = String.UnicodeScalarView() }
            } else {
                word.append(u)
            }
        }
        if !word.isEmpty { out.append(String(word)) }
        return out
    }

    /// `repr(x)` of a JSON value (a dict's keys in order, strings quoted as Python quotes them).
    public static func repr(_ v: JSONValue) -> String { MyNotes.pyRepr(v) }

    /// `str(x)` of a JSON value: a string as it is, anything else as `repr` writes it.
    public static func str(_ v: JSONValue) -> String {
        if case .string(let s) = v { return s }
        return repr(v)
    }

    /// `s.strip()`: without leading and trailing whitespace.
    public static func strip(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isSpace($0) }),
              let last = scalars.lastIndex(where: { !isSpace($0) }) else { return "" }
        return String(scalars[first...last])
    }

    /// `float(text)` of a string; nil where Python raises ValueError. Any script's decimal digits and whitespace count
    /// (Python turns them into ASCII first); single underscores between digits; `inf`, `infinity`, `nan` in any case,
    /// signed; no hex.
    public static func float(_ text: String) -> Double? {
        var ascii: [UInt8] = []
        for u in text.unicodeScalars {
            if isSpace(u) {
                ascii.append(0x20)
            } else if isDecimal(u), let digit = u.properties.numericValue {
                ascii.append(0x30 + UInt8(digit))
            } else if u.isASCII {
                ascii.append(UInt8(u.value))
            } else {
                return nil
            }
        }
        let isDigit = { (b: UInt8) in b >= 0x30 && b <= 0x39 }
        guard let first = ascii.firstIndex(where: { $0 != 0x20 }), let last = ascii.lastIndex(where: { $0 != 0x20 }) else {
            return nil
        }
        var s: [UInt8] = []
        var prev: UInt8 = 0
        for b in ascii[first...last] {  // underscores only between digits
            if b == 0x5F {
                guard isDigit(prev) else { return nil }
            } else {
                if prev == 0x5F && !isDigit(b) { return nil }
                s.append(b)
            }
            prev = b
        }
        if prev == 0x5F { return nil }
        var i = 0
        var negative = false
        if i < s.count, s[i] == 0x2B || s[i] == 0x2D { negative = s[i] == 0x2D; i += 1 }
        let word = String(decoding: s[i...], as: UTF8.self).lowercased()
        if word == "inf" || word == "infinity" { return negative ? -.infinity : .infinity }
        if word == "nan" { return .nan }
        func digits() -> Int {
            let start = i
            while i < s.count, isDigit(s[i]) { i += 1 }
            return i - start
        }
        var mantissa = digits()
        if i < s.count, s[i] == 0x2E {
            i += 1
            mantissa += digits()
        }
        guard mantissa > 0 else { return nil }
        if i < s.count, s[i] == 0x65 || s[i] == 0x45 {
            i += 1
            if i < s.count, s[i] == 0x2B || s[i] == 0x2D { i += 1 }
            guard digits() > 0 else { return nil }
        }
        guard i == s.count else { return nil }
        return Double(String(decoding: s, as: UTF8.self))
    }

    // MARK: - Sorting

    /// `sorted(items, key=...)`: a merge sort, so equal items keep their order as in Python
    /// (Swift's `sort` is not documented as stable). `less` is Python's `<` on the keys.
    public static func stableSorted<T>(_ items: [T], by less: (T, T) throws -> Bool) rethrows -> [T] {
        var a = items
        guard a.count > 1 else { return a }
        var b = a
        var width = 1
        while width < a.count {
            var start = 0
            while start < a.count {
                let mid = min(start + width, a.count), end = min(start + 2 * width, a.count)
                var l = start, r = mid, k = start
                while l < mid && r < end {
                    if try less(a[r], a[l]) { b[k] = a[r]; r += 1 } else { b[k] = a[l]; l += 1 }
                    k += 1
                }
                while l < mid { b[k] = a[l]; l += 1; k += 1 }
                while r < end { b[k] = a[r]; r += 1; k += 1 }
                start = end
            }
            swap(&a, &b)
            width *= 2
        }
        return a
    }

    // MARK: - Times

    /// `datetime.now().astimezone().isoformat(timespec=...)`: "auto" (microseconds when there are
    /// any), "hours", "minutes", "seconds", "milliseconds" or "microseconds".
    public static func isoNow(timespec: String = "auto", now: Date = Date(), timeZone: TimeZone = .current) -> String {
        if timespec == "auto" { return WallTime.iso(now, timeZone) }
        let seconds = WallTime.iso(now, timeZone, seconds: true)  // 2026-11-04T13:57:51+01:00
        let stamp = String(seconds.dropLast(6)), offset = String(seconds.suffix(6))
        let whole = now.timeIntervalSince1970.rounded(.down)
        let micros = min(Int(((now.timeIntervalSince1970 - whole) * 1_000_000).rounded()), 999_999)
        switch timespec {
        case "hours": return String(stamp.prefix(13)) + offset
        case "minutes": return String(stamp.prefix(16)) + offset
        case "seconds": return seconds
        case "milliseconds": return stamp + String(format: ".%03d", micros / 1000) + offset
        case "microseconds": return stamp + String(format: ".%06d", micros) + offset
        default: preconditionFailure("Unknown timespec value \(timespec)")
        }
    }

    /// `datetime.fromisoformat(s)` as a moment: the offset it names is kept; one without an offset
    /// is local time, a bare date its midnight.
    public static func fromIso(_ s: String, timeZone: TimeZone = .current) -> Date? {
        let bareDate = s.utf8.count == 10 && s.unicodeScalars.enumerated().allSatisfy { i, u in
            i == 4 || i == 7 ? u == "-" : ("0"..."9").contains(u)
        }
        return WallTime.parse(bareDate ? s + "T00:00" : s, timeZone)
    }
}
