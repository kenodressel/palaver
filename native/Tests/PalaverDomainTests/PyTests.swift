// Py against Python 3.13: the goldens section `py` (tools/parity/goldens.py) for round, repr,
// casefold and str.split; the Unicode tables (tools/make_unicode_tables.py) are 15.1.
import Foundation
import PalaverCore
import PalaverDomain
import Testing

/// `float.hex()`.
func pyHex(_ d: Double) -> String {
    if d.isNaN { return "nan" }
    if d.isInfinite { return d < 0 ? "-inf" : "inf" }
    let sign = d.sign == .minus ? "-" : ""
    if d == 0 { return sign + "0x0.0p+0" }
    let mantissa = String(d.significandBitPattern, radix: 16)
    let digits = String(repeating: "0", count: 13 - mantissa.count) + mantissa
    if d.isSubnormal { return "\(sign)0x0.\(digits)p-1022" }
    let e = Int(d.exponentBitPattern) - 1023
    return "\(sign)0x1.\(digits)p\(e < 0 ? "-" : "+")\(abs(e))"
}

/// Python's `float.fromhex` for what `float.hex()` writes.
func fromPyHex(_ s: String?) throws -> Double {
    try #require(s.flatMap { Double($0) }, "not a float.hex: \(s ?? "nil")")
}

@Suite struct PyTests {
    @Test func roundMatchesPython() throws {
        let cases = try Goldens.cases("py", "round")
        #expect(cases.count == 1620)
        let actual: [JSONValue] = try cases.map { c in
            let x = try fromPyHex(c[0].stringValue), digits = try Goldens.int(c[1])
            return .array([.string(pyHex(x)), .int(digits), .string(pyHex(Py.round(x, digits)))])
        }
        Goldens.expectEach(actual, "py", "round")
    }

    @Test func reprMatchesPython() throws {
        let cases = try Goldens.cases("py", "repr")
        let actual: [JSONValue] = try cases.map { c in
            let x = try fromPyHex(c[0].stringValue)
            return .array([.string(pyHex(x)), .string(Py.repr(x))])
        }
        Goldens.expectEach(actual, "py", "repr")
        #expect([Py.repr(.nan), Py.repr(.infinity), Py.repr(-.infinity), Py.repr(-0.0)] == ["nan", "inf", "-inf", "-0.0"])
    }

    @Test func casefoldMatchesPython() throws {
        let actual: [JSONValue] = try Goldens.cases("py", "casefold").map { c in
            let s = try #require(c[0].stringValue)
            return .array([.string(s), .string(Py.casefold(s))])
        }
        Goldens.expectEach(actual, "py", "casefold")
    }

    @Test func splitMatchesPython() throws {
        let actual: [JSONValue] = try Goldens.cases("py", "split").map { c in
            let s = try #require(c[0].stringValue)
            return .array([.string(s), .strings(Py.split(s))])
        }
        Goldens.expectEach(actual, "py", "split")
        #expect(Py.strip("\u{85}\u{1C} Timo Strauß\t\u{3000}") == "Timo Strauß")
        #expect(Py.strip("\u{200B}x\u{200B}") == "\u{200B}x\u{200B}")  // not whitespace to Python
    }

    @Test func stableSortKeepsEqualOrder() {
        var rng = SystemRandomNumberGenerator()
        let items = (0..<500).map { (key: Int.random(in: 0..<7, using: &rng), at: $0) }
        let sorted = Py.stableSorted(items) { $0.key < $1.key }
        let want = items.enumerated().sorted { ($0.element.key, $0.offset) < ($1.element.key, $1.offset) }.map(\.element)
        #expect(sorted.map(\.at) == want.map(\.at))
        #expect(Py.stableSorted([Int]()) { $0 < $1 } == [])
        #expect(Py.stableSorted([3, 1, 2]) { $0 > $1 } == [3, 2, 1])
    }

    @Test func isoNowHasOffsetAndSeconds() throws {
        let iso = try PyRegex(#"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d"#)
        let now = Py.isoNow(timespec: "seconds")
        #expect(iso.fullMatch(now) != nil, "\(now)")
        let parsed = try #require(Py.fromIso(now))
        #expect(abs(parsed.timeIntervalSinceNow) < 5)
        #expect(try PyRegex(#"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d{6})?[+-]\d\d:\d\d"#).fullMatch(Py.isoNow()) != nil)

        let at = Date(timeIntervalSince1970: 1_793_820_471.25)
        let utc = TimeZone(secondsFromGMT: 0)!
        #expect(Py.isoNow(timespec: "auto", now: at, timeZone: utc) == "2026-11-04T19:27:51.250000+00:00")
        #expect(Py.isoNow(timespec: "milliseconds", now: at, timeZone: utc) == "2026-11-04T19:27:51.250+00:00")
        #expect(Py.isoNow(timespec: "minutes", now: at, timeZone: utc) == "2026-11-04T19:27+00:00")

        // datetime.fromisoformat(...).timestamp(), offsets kept.
        #expect(Py.fromIso("2026-11-04T13:57:51+01:00")?.timeIntervalSince1970 == 1_793_797_071.0)
        #expect(Py.fromIso("2026-11-04T13:57:51.250000-05:30")?.timeIntervalSince1970 == 1_793_820_471.25)
        #expect(Py.fromIso("2026-11-04") != nil)
        #expect(Py.fromIso("4 Nov 2026") == nil)
    }

    @Test func pyDictKeepsInsertionOrder() throws {
        var d = PyDict<Int>()
        d["z"] = 1; d["a"] = 2; d["m"] = 3
        d["z"] = 10  // an existing key keeps its place
        #expect(d.keys == ["z", "a", "m"])
        #expect(d.values == [10, 2, 3])
        #expect(d.removeValue(forKey: "a") == 2)
        d["a"] = 4  // a removed key comes back at the end
        #expect(d.map(\.key) == ["z", "m", "a"])
        d["m"] = nil
        #expect(d.keys == ["z", "a"] && d.count == 2 && d["m"] == nil && d["z"] == 10)

        let pairs = PyDict([("b", 1), ("a", 2), ("b", 3)])  // dict(pairs): first place, last value
        #expect(pairs.keys == ["b", "a"] && pairs["b"] == 3)

        let json = try PythonJSON.parse(Data(#"{"title": "Contoso", "n": 1, "speakers": {"b": 1, "a": 2}}"#.utf8))
        var fields = try #require(PyDict<JSONValue>(json))
        fields["n"] = .double(0.5)
        fields["added"] = .bool(true)
        #expect(PythonJSON.dumps(fields.json) == #"{"title": "Contoso", "n": 0.5, "speakers": {"b": 1, "a": 2}, "added": true}"#)
        #expect(PyDict<JSONValue>(.array([])) == nil)
    }

    @Test func tablesAreUnicode15_1() throws {
        #expect(UnicodeTables.version == "15.1.0")
        let newer = try #require(Unicode.Scalar(UInt32(try Goldens.int(Goldens.load("py")["newer_than_15_1"]))))
        #expect(!Py.isAlpha(newer) && !Py.isWordScalar(newer) && !Py.isUpper(newer))
        #expect(Py.isAlpha("ß") && Py.isUpper("ẞ") && !Py.isUpper("ǅ") && !Py.isUpper("ß"))
        #expect(Py.isDecimal("٣") && Py.isDecimal("४") && !Py.isDecimal("²") && Py.isWordScalar("²"))
        #expect(Py.isWordScalar("_") && !Py.isWordScalar("-") && !Py.isWordScalar("😀"))
        #expect(Py.isSpace("\u{1C}") && Py.isSpace("\u{85}") && Py.isSpace("\u{3000}") && !Py.isSpace("\u{200B}"))
        #expect(UnicodeTables.caseFold[0xDF] == [0x73, 0x73])
        #expect(UnicodeTables.simpleFold[0x6B] == [0x4B, 0x212A])  // k: K and the Kelvin sign
        #expect(UnicodeTables.simpleFold[0xDF] == [0x1E9E])  // ß only with ẞ, never "ss"
        #expect(UnicodeTables.wordRanges.first! == (0x30, 0x39))
    }
}
