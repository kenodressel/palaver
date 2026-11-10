// Cologne.code against glossary.cologne: the goldens section `cologne`.
import Foundation
import PalaverCore
import PalaverDomain
import Testing

@Suite struct CologneTests {
    @Test func codesMatchPython() throws {
        let cases = try Goldens.cases("cologne", "cases")
        #expect(cases.count == 300)
        var reported = 0
        for c in cases {
            let word = try #require(c[0].stringValue), want = try #require(c[1].stringValue)
            let got = Cologne.code(word)
            if !got.unicodeScalars.elementsEqual(want.unicodeScalars), reported < 10 {
                Issue.record("cologne(\(word.debugDescription)): got \(got), want \(want)")
                reported += 1
            }
        }
        #expect(reported == 0)
    }

    @Test func test_cologne_phonetics() {
        #expect(Cologne.code("Wasti") == "382" && Cologne.code("Vasti") == "382")
        #expect(Cologne.code("Müller") == "657" && Cologne.code("Mueller") == "657")
        #expect(Cologne.code("Wikipedia") == "3412")
        #expect(Cologne.code("") == "")
    }
}
