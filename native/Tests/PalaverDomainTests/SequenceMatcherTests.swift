// SequenceMatcher against difflib (CPython 3.13, autojunk=False): the goldens section `difflib`.
import Foundation
import PalaverCore
import PalaverDomain
import Testing

@Suite struct SequenceMatcherTests {
    @Test func opcodesMatchDifflib() throws {
        let cases = try Goldens.cases("difflib", "cases")
        #expect(cases.count == 200)
        var reported = 0
        for c in cases {
            let a = try #require(c[0].arrayValue).compactMap(\.stringValue)
            let b = try #require(c[1].arrayValue).compactMap(\.stringValue)
            let want: [SequenceMatcher.Opcode] = try #require(c[2].arrayValue).map { row in
                let r = try #require(row.arrayValue)
                return SequenceMatcher.Opcode(tag: try #require(r[0].stringValue), i1: try Goldens.int(r[1]), i2: try Goldens.int(r[2]),
                                              j1: try Goldens.int(r[3]), j2: try Goldens.int(r[4]))
            }
            let got = SequenceMatcher(a, b).opcodes()
            if got != want, reported < 5 {
                Issue.record("opcodes(\(a), \(b)): got \(got), want \(want)")
                reported += 1
            }
        }
        #expect(reported == 0)
    }

    @Test func tokensCompareByScalars() {
        // NFC and NFD spellings are different tokens, as in Python.
        let ops = SequenceMatcher(["\u{e9}"], ["e\u{301}"]).opcodes()
        #expect(ops.map(\.tag) == ["replace"])
    }
}
