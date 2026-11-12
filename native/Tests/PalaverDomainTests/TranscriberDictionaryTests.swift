// tests/test_dictionary.py: the dictionary loader and the replacements.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct TranscriberDictionaryTests {
    @Test func test_missing_file_returns_empty() {
        let t = TempFolder("dict"); defer { t.remove() }
        let d = TranscriberDictionary.load(t.url.appendingPathComponent("nope.toml"))
        #expect(d.initialPrompt == "")
        #expect(d.replacements == PyDict<String>())
    }

    @Test func test_load_initial_prompt() {
        let t = TempFolder("dict"); defer { t.remove() }
        t.write("dict.toml", "[initial_prompt]\ntext = \"Sprint Planning OKRs KPIs\"\n")
        #expect(TranscriberDictionary.load(t.url.appendingPathComponent("dict.toml")).initialPrompt == "Sprint Planning OKRs KPIs")
    }

    @Test func test_load_replacements() {
        let t = TempFolder("dict"); defer { t.remove() }
        t.write("dict.toml", """

        [replacements]
        "kay pee eye" = "KPI"
        "oh kay are" = "OKR"

        """)
        let d = TranscriberDictionary.load(t.url.appendingPathComponent("dict.toml"))
        #expect(d.replacements == PyDict([("kay pee eye", "KPI"), ("oh kay are", "OKR")]))
        #expect(d.replacements.keys == ["kay pee eye", "oh kay are"])  // file order, as tomllib's dict
    }

    @Test func test_apply_replacements_case_insensitive() {
        let d = TranscriberDictionary(initialPrompt: "", replacements: PyDict([("kay pee eye", "KPI")]))
        #expect(d.apply("Our Kay Pee Eye is great") == "Our KPI is great")
    }

    @Test func test_apply_replacements_leaves_unmatched_text() {
        let d = TranscriberDictionary(initialPrompt: "", replacements: PyDict([("foo", "bar")]))
        #expect(d.apply("nothing to replace here") == "nothing to replace here")
    }

    @Test func test_apply_with_empty_replacements() {
        let d = TranscriberDictionary(initialPrompt: "hint", replacements: PyDict())
        #expect(d.apply("hello world") == "hello world")
    }

    @Test func theLongestSourceGoesFirstAndEqualOnesInFileOrder() {
        let d = TranscriberDictionary(initialPrompt: "", replacements: PyDict([("kay pee", "KP"), ("kay pee eye", "KPI")]))
        #expect(d.apply("kay pee eye, kay pee") == "KPI, KP")
        let tie = TranscriberDictionary(initialPrompt: "", replacements: PyDict([("Ab", "1"), ("aB", "2")]))
        #expect(tie.apply("AB") == "1")  // the first of two of the same length takes it
    }

    @Test func aReplacementIsATemplateNotLiteralText() {
        let d = TranscriberDictionary(initialPrompt: "", replacements: PyDict([("a.b", #"a\\b"#), ("x", #"[\g<0>]"#)]))
        #expect(d.apply("a.b but not axb; x") == #"a\b but not a[x]b; [x]"#)
    }

    @Test func nonTextValuesAreStrings() throws {
        let t = TempFolder("dict"); defer { t.remove() }
        t.write("dict.toml", "[replacements]\nfour = 4\nyes = true\nhalf = 0.5\n")
        let d = TranscriberDictionary.load(t.url.appendingPathComponent("dict.toml"))
        #expect(d.replacements == PyDict([("four", "4"), ("yes", "True"), ("half", "0.5")]))
    }
}
