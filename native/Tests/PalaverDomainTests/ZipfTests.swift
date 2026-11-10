// Zipf against wordfreq 3.1.1: the goldens section `zipf` (tools/parity/goldens.py), bit for bit.
import Foundation
import PalaverCore
import PalaverDomain
import Testing

@Suite struct ZipfTests {
    private func double(_ v: JSONValue?) throws -> Double {
        switch v {
        case .double(let d)?: return d
        case .int(let i)?: return Double(i)
        default: throw Goldens.ShapeError(what: "number", got: v)
        }
    }

    @Test func zipfMatchesWordfreq() throws {
        let cases = try Goldens.cases("zipf", "cases")
        #expect(cases.count > 3000)
        var reported = 0
        for c in cases {
            let word = try #require(c[0].stringValue)
            let want = try (1...3).map { try double(c[$0]) }
            let got = [Zipf.frequency(Py.casefold(word), lang: "de"), Zipf.frequency(Py.casefold(word), lang: "en"), Zipf.zipf(word)]
            if got.map(\.bitPattern) != want.map(\.bitPattern), reported < 10 {
                Issue.record("zipf(\(word.debugDescription)): got \(got), want \(want)")
                reported += 1
            }
        }
        #expect(reported == 0)
    }

    @Test func theTokenizerFindsWordfreqsTokens() throws {
        let cases = try Goldens.cases("zipf", "tokens")
        #expect(cases.count > 9000)
        var reported = 0
        for c in cases {
            let text = try #require(c[0].stringValue)
            let want = try #require(c[1].arrayValue).compactMap(\.stringValue)
            let got = Zipf.lossyTokens(text)
            // Compare scalar by scalar: Swift's String == treats NFC and NFD as equal.
            let same = got.count == want.count && zip(got, want).allSatisfy { $0.unicodeScalars.elementsEqual($1.unicodeScalars) }
            if !same, reported < 10 {
                Issue.record("tokens of \(text.unicodeScalars.map { String($0.value, radix: 16) }): got \(got), want \(want)")
                reported += 1
            }
        }
        #expect(reported == 0)
    }

    @Test func rareWordsAreRare() {
        #expect(Zipf.isRare("Qwxyzq"))
        #expect(!Zipf.isRare("Straße"))
        #expect(!Zipf.isRare("meeting"))
        #expect(Zipf.zipf("") == 0)
    }

    @Test func theTableLoadsOnce() {
        for i in 0..<100 { _ = Zipf.zipf(i % 2 == 0 ? "Besprechung" : "meeting") }
        #expect(Zipf.loads == 1)
    }
}
