// Zipf: word frequencies from the bundled table.
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
