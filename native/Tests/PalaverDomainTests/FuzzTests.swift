// Fuzz.ratio: the edge cases.
import Foundation
import PalaverCore
import PalaverDomain
import Testing

@Suite struct FuzzTests {

    @Test func edgeCases() {
        #expect(Fuzz.ratio("", "") == 100.0)
        #expect(Fuzz.ratio("", "a") == 0.0)
        // Scalars, not Characters: NFC and NFD spellings differ.
        #expect(Fuzz.ratio("\u{e9}", "e\u{301}") < 100.0)
    }
}
