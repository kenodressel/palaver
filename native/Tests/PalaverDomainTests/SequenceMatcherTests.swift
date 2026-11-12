// SequenceMatcher: tokens compare by their scalars.
import Foundation
import PalaverCore
import PalaverDomain
import Testing

@Suite struct SequenceMatcherTests {

    @Test func tokensCompareByScalars() {
        // NFC and NFD spellings are different tokens, as in Python.
        let ops = SequenceMatcher(["\u{e9}"], ["e\u{301}"]).opcodes()
        #expect(ops.map(\.tag) == ["replace"])
    }
}
