// PyRegex against Python 3.13's re: the goldens section `py` (regex, regex_sub, regex_fullmatch)
// and the rules the translation to ICU has to keep (spans are code point offsets).
import Foundation
import PalaverCore
import PalaverDomain
import Testing

private func spans(_ pattern: String, _ text: String, ignoreCase: Bool = false, verbose: Bool = false) throws -> [[Int]] {
    try PyRegex(pattern, ignoreCase: ignoreCase, verbose: verbose).matches(in: text).map { [$0.range.lowerBound, $0.range.upperBound] }
}

@Suite struct PyRegexTests {
    @Test func regexMatchesPython() throws {
        let cases = try Goldens.cases("py", "regex")
        #expect(cases.count == 100)
        let actual: [JSONValue] = try cases.map { c in
            let pattern = try #require(c[0].stringValue), flags = try #require(c[1].stringValue)
            let text = try #require(c[2].stringValue)
            let found = try spans(pattern, text, ignoreCase: flags == "i")
            return .array([.string(pattern), .string(flags), .string(text), .array(found.map { .array($0.map { .int($0) }) })])
        }
        Goldens.expectEach(actual, "py", "regex")
    }

    @Test func subMatchesPython() throws {
        let actual: [JSONValue] = try Goldens.cases("py", "regex_sub").map { c in
            let pattern = try #require(c[0].stringValue), template = try #require(c[2].stringValue)
            let text = try #require(c[3].stringValue)
            let out = try PyRegex(pattern, ignoreCase: c[1].stringValue == "i").sub(template, in: text)
            return .array([c[0], c[1], c[2], c[3], .string(out)])
        }
        Goldens.expectEach(actual, "py", "regex_sub")
    }

    @Test func fullMatchMatchesPython() throws {
        let actual: [JSONValue] = try Goldens.cases("py", "regex_fullmatch").map { c in
            let pattern = try #require(c[0].stringValue), text = try #require(c[2].stringValue)
            let regex = try PyRegex(pattern, ignoreCase: c[1].stringValue == "i")
            return .array([c[0], c[1], c[2], .bool(regex.fullMatch(text) != nil)])
        }
        Goldens.expectEach(actual, "py", "regex_fullmatch")
    }

    @Test func wordClassUsesTheTablesNotICU() throws {
        let cp = UInt32(try Goldens.int(Goldens.load("py")["newer_than_15_1"]))
        let letter = String(try #require(Unicode.Scalar(cp)))
        #expect(try PyRegex(#"\w"#).firstMatch(in: letter) == nil)
        #expect(try PyRegex(#"[^\W\d_]"#).firstMatch(in: letter) == nil)
        #expect(try PyRegex(#"\W"#).fullMatch(letter) != nil)
        #expect(try spans(#"\b"#, "a\(letter)b") == [[0, 0], [1, 1], [2, 2], [3, 3]])
    }

    @Test func ignoreCaseUsesPythonsFolds() throws {
        #expect(try PyRegex("k", ignoreCase: true).fullMatch("\u{212A}") != nil)
        #expect(try PyRegex("ß", ignoreCase: true).fullMatch("ẞ") != nil)
        #expect(try PyRegex("ss", ignoreCase: true).fullMatch("ß") == nil)  // ICU's full folding would match
        #expect(try PyRegex("[a-z]+", ignoreCase: true).fullMatch("\u{212A}ſ") != nil)
        #expect(try PyRegex("[^a-z]", ignoreCase: true).firstMatch(in: "\u{212A}ſK") == nil)
        #expect(try PyRegex("strasse").fullMatch("STRASSE") == nil)
    }

    @Test func emptyMatchesAdvanceLikePython() throws {
        #expect(try PyRegex("x*").sub("-", in: "abxd") == "-a-b--d-")
        #expect(try spans("|a", "a") == [[0, 0], [0, 1], [1, 1]])
        #expect(try spans("a*?", "aa") == [[0, 0], [0, 1], [1, 1], [1, 2], [2, 2]])
        #expect(try PyRegex("a|(?=b)").sub("-", in: "ab") == "--b")
        #expect(try spans("😀|b", "a😀b") == [[1, 2], [2, 3]])
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

    @Test func templatesAreParsedLikePython() throws {
        let words = try PyRegex(#"(\w+) (\w+)"#)
        #expect(try words.sub(#"\g<2>\n\1\-\g<0>"#, in: "Timo Strauß") == "Strauß\nTimo\\-Timo Strauß")
        #expect(try PyRegex("(a)|b").sub(#"[\1]"#, in: "ab") == "[a][]")
        #expect(try PyRegex("a").sub("x", in: "aaa", count: 2) == "xxa")
        #expect(try PyRegex("(?P<n>a)").sub(#"\g<n>\g<n>"#, in: "ab") == "aab")
        #expect(throws: PyRegex.Error.self) { try words.sub(#"\3"#, in: "a b") }
        #expect(throws: PyRegex.Error.self) { try words.sub(#"\q"#, in: "a b") }
        #expect(words.sub(in: "Timo Strauß und Valerie") { "\($0.group(2)!) \($0.group(1)!)" } == "Strauß Timo Valerie und")
    }

    @Test func unsupportedSyntaxThrows() {
        for pattern in ["(?i:x)", #"\N{EM DASH}"#, "(a)(?(1)b|c)", "(", "[a", #"\q"#, "x(?i)", #"(a)\1"#] {
            let ignoreCase = pattern == #"(a)\1"#  // a backreference under IGNORECASE
            #expect(throws: PyRegex.Error.self, "\(pattern)") { try PyRegex(pattern, ignoreCase: ignoreCase) }
        }
    }
}
