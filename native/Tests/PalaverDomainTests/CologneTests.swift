// Cologne phonetics (the glossary's sound-alikes).
import Foundation
import PalaverCore
import PalaverDomain
import Testing

@Suite struct CologneTests {

    @Test func test_cologne_phonetics() {
        #expect(Cologne.code("Wasti") == "382" && Cologne.code("Vasti") == "382")
        #expect(Cologne.code("Müller") == "657" && Cologne.code("Mueller") == "657")
        #expect(Cologne.code("Wikipedia") == "3412")
        #expect(Cologne.code("") == "")
    }
}
