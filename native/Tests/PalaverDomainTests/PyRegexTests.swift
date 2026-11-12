// PyRegex: the rules the translation to ICU has to keep (spans are code point offsets).
import Foundation
import PalaverCore
import PalaverDomain
import Testing

private func spans(_ pattern: String, _ text: String, ignoreCase: Bool = false, verbose: Bool = false) throws -> [[Int]] {
    try PyRegex(pattern, ignoreCase: ignoreCase, verbose: verbose).matches(in: text).map { [$0.range.lowerBound, $0.range.upperBound] }
}

@Suite struct PyRegexTests {

    @Test func wordClassUsesTheTablesNotICU() throws {
        let cp: UInt32 = 0x1C89  // a letter Unicode 16 added: \w follows the tables (15.1), not ICU's newer data
        let letter = String(try #require(Unicode.Scalar(cp)))
        #expect(try PyRegex(#"\w"#).firstMatch(in: letter) == nil)
        #expect(try PyRegex(#"[^\W\d_]"#).firstMatch(in: letter) == nil)
        #expect(try PyRegex(#"\W"#).fullMatch(letter) != nil)
        #expect(try spans(#"\b"#, "a\(letter)b") == [[0, 0], [1, 1], [2, 2], [3, 3]])
    }

    @Test func pythonSyntaxBecomesICU() throws {
        let m = try #require(try PyRegex(#"(?P<word>\w+)-(?P=word)"#).firstMatch(in: "na ja-ja"))
        #expect(m.range == 3..<8 && m.group("word") == "ja" && m.span(1) == 3..<5 && m.group() == "ja-ja")
        #expect(try spans("a{,2}", "aaa") == [[0, 2], [2, 3], [3, 3]])
        #expect(try spans("x{", "x{") == [[0, 2]])
        #expect(try spans("a$", "a\n") == [[0, 1]])
        #expect(try spans(".", "a\u{85}\n\u{2028}") == [[0, 1], [1, 2], [3, 4]])
        #expect(try spans("(?s).", "\n") == [[0, 1]])
        #expect(try spans("(?m)^b$", "a\nb\r\nb\u{2028}b\nb") == [[9, 10]])
        #expect(try spans(#"^a"#, "aa") == [[0, 1]])
        #expect(try spans(#"\Aa|a\Z"#, "aaa") == [[0, 1], [2, 3]])
        #expect(try spans(#"(?<=a)b"#, "ab") == [[1, 2]])
        #expect(try spans(#"\b"#, "ab cd") == [[0, 0], [2, 2], [3, 3], [5, 5]])
        #expect(try spans(#"\B"#, " ") == [[0, 0], [1, 1]])
        #expect(try spans(#"\B"#, "") == [])
        #expect(try spans(#"[\w-]+"#, "uh-huh ok") == [[0, 6], [7, 9]])
        #expect(try spans("[]a]", "]a") == [[0, 1], [1, 2]])
        #expect(try spans("[^]a]", "]ab") == [[2, 3]])
        #expect(try spans("[a-]", "x-a") == [[1, 2], [2, 3]])
        #expect(try spans("[[&&~]", "[&~a") == [[0, 1], [1, 2], [2, 3]])  // literal in Python, set operators in ICU
        #expect(try PyRegex(#"\x41ä\U0001F600\101\0"#).fullMatch("Aä😀A\u{0}") != nil)
        #expect(try PyRegex("a b # c\n c", verbose: true).fullMatch("abc") != nil)
        #expect(try PyRegex("(?x) a [ ]").fullMatch("a ") != nil)
        #expect(try PyRegex(PyRegex.escape("Timo Strauß (Contoso) 1+1")).fullMatch("Timo Strauß (Contoso) 1+1") != nil)
        #expect(PyRegex.escape("Timo Strauß-#&~\n") == "Timo\\ Strauß\\-\\#\\&\\~\\\n")
    }

    @Test func unsupportedSyntaxThrows() {
        for pattern in ["(?i:x)", #"\N{EM DASH}"#, "(a)(?(1)b|c)", "(", "[a", #"\q"#, "x(?i)", #"(a)\1"#] {
            let ignoreCase = pattern == #"(a)\1"#  // a backreference under IGNORECASE
            #expect(throws: PyRegex.Error.self, "\(pattern)") { try PyRegex(pattern, ignoreCase: ignoreCase) }
        }
    }
}
