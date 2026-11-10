// Fuzz.ratio against rapidfuzz 3.14: the goldens section `fuzz`, bit for bit.
import Foundation
import PalaverCore
import PalaverDomain
import Testing

@Suite struct FuzzTests {
    @Test func ratioMatchesRapidfuzzBitForBit() throws {
        let cases = try Goldens.cases("fuzz", "cases")
        #expect(cases.count == 500)
        var reported = 0
        for c in cases {
            let a = try #require(c[0].stringValue), b = try #require(c[1].stringValue)
            let want: Double
            switch c[2] {
            case .double(let d): want = d
            case .int(let i): want = Double(i)
            default: throw Goldens.ShapeError(what: "number", got: c[2])
            }
            let got = Fuzz.ratio(a, b)
            if got.bitPattern != want.bitPattern, reported < 10 {
                Issue.record("ratio(\(a.debugDescription), \(b.debugDescription)): got \(got), want \(want)")
                reported += 1
            }
        }
        #expect(reported == 0)
    }

    @Test func edgeCases() {
        #expect(Fuzz.ratio("", "") == 100.0)
        #expect(Fuzz.ratio("", "a") == 0.0)
        // Scalars, not Characters: NFC and NFD spellings differ.
        #expect(Fuzz.ratio("\u{e9}", "e\u{301}") < 100.0)
    }
}
