// Py's helpers the app relies on: a stable sort, the time with its offset, a dict in insertion order.
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

}
