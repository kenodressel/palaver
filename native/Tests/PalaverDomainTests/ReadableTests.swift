// The clean-verbatim transcript (readable.py, test_readable.py).
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct ReadableTests {
    private func none() -> (TempFolder, Glossary) {
        let t = TempFolder("readable")
        return (t, Glossary(path: t.url.appendingPathComponent("none.json")))
    }

    @Test func test_filler_words_are_removed() {
        let cases: [(String, String)] = [
            ("Um, so we, uh, need a plan.", "So we need a plan."),
            ("Und dann, ähm, machen wir das.", "Und dann machen wir das."),
            ("Das passt, äh.", "Das passt."),
            ("Das passt, äh. und dann weiter", "Das passt. Und dann weiter"),
            ("I think uh we can also quickly go over the last point.", "I think we can also quickly go over the last point."),
            ("Mm-hmm, that's right.", "That's right."),
            ("Das ist eh klar.", "Das ist eh klar."),
            ("Wie gehen wir damit um.", "Wie gehen wir damit um."),
            ("Wir brauchen Zeit, um da zu einem Ergebnis zu kommen.", "Wir brauchen Zeit, um da zu einem Ergebnis zu kommen."),
            ("Let's think about this um I also don't know.", "Let's think about this I also don't know."),
            ("Um, wir starten den Rollout am Montag.", "Wir starten den Rollout am Montag."),
            ("Wie gehen wir damit um, wenn das passiert?", "Wie gehen wir damit um, wenn das passiert?"),
            (", äh, also wo stehen wir gerade?", "Also wo stehen wir gerade?"),
        ]
        for (raw, clean) in cases { #expect(Readable.cleanText(raw) == clean, "\(raw)") }
    }

    @Test func test_stutters_collapse() {
        let cases: [(String, String)] = [
            ("If the the the tax ministry comes", "If the tax ministry comes"),
            ("I think uh we we can do that.", "I think we can do that."),
            ("And, and that was it.", "And that was it."),
            ("the uh the thing", "the thing"),
            ("Mm -hmm.", ""),
            ("oder seit seit vier Monaten", "oder seit vier Monaten"),
            ("I'm happy we made we made it in the end", "I'm happy we made it in the end"),
            ("not sure if you remember when I when I told you", "not sure if you remember when I told you"),
            ("Yeah, I remember, I remember and I was also sick.", "Yeah, I remember and I was also sick."),
            ("Sorry, we have a Facebook, this one, this one.", "Sorry, we have a Facebook, this one."),
            ("Wie gesagt, wie gesagt, das passt.", "Wie gesagt, das passt."),
            ("I would say I would say we start.", "I would say we start."),
        ]
        for (raw, clean) in cases { #expect(Readable.cleanText(raw) == clean, "\(raw)") }
    }

    @Test func test_deliberate_repeats_stay() {
        let texts = [
            "Ja, ja.", "Ja, ja, ja.", "Ciao, ciao.", "Okay, bye bye.", "Das ist sehr sehr gut.",
            "Absolut, absolut, absolut.", "bla bla",
            "Und ich glaube die, die Bescheid wussten, waren dabei.", "Das war echt, echt chill.",
            "Das wird nach und nach besser.", "Okay, bye bye.", "Ja, ja, ja, ja.", "bla bla bla bla bla.",
        ]
        for text in texts { #expect(Readable.cleanText(text) == text) }
    }

    @Test func test_readable_drops_filler_only_turns_and_keeps_short_answers() {
        let (t, g) = none(); defer { t.remove() }
        let utterances = [
            Utterance(speaker: "Anna", start: 0.0, end: 2.0, text: "Wir starten am Montag."),
            Utterance(speaker: "Timo", start: 2.0, end: 2.5, text: "Mm-hmm."),
            Utterance(speaker: "Timo", start: 3.0, end: 3.5, text: "Um"),
            Utterance(speaker: "Timo", start: 4.0, end: 4.5, text: "Genau."),
            Utterance(speaker: "Anna", start: 5.0, end: 7.0, text: "Und, äh, dann der Rollout."),
        ]
        let out = Readable.readable(utterances, glossary: g)
        #expect(out.map(\.speaker) == ["Anna", "Timo", "Anna"])
        #expect(out.map(\.start) == [0.0, 4.0, 5.0])
        #expect(out.map(\.text) == ["Wir starten am Montag.", "Genau.", "Und dann der Rollout."])
        #expect(utterances[4].text == "Und, äh, dann der Rollout.")  // input untouched
    }

    @Test func test_numbers_glued_to_words_get_their_space() {
        #expect(Readable.cleanText("Wir zahlen aktuell1040 für150 Millionen bis Ende2030.")
                == "Wir zahlen aktuell 1040 für 150 Millionen bis Ende 2030.")
        #expect(Readable.cleanText("H100, MP3, GPT4, COVID19 und S3 bleiben.") == "H100, MP3, GPT4, COVID19 und S3 bleiben.")
    }

    @Test func test_readable_lines_carry_where_the_glossary_respelled() throws {
        let (t, g) = none(); defer { t.remove() }
        try g.add(term: "Zini", variants: ["Tini"])
        let out = Readable.readable([Utterance(speaker: "A", start: 0.0, end: 1.0, text: "Äh, wir lösen Tini ab.")], glossary: g)
        let u = try #require(out.first)
        let s = Array(u.text.unicodeScalars)
        #expect(u.text == "Wir lösen Zini ab.")
        #expect(u.glossed.map { [String(String.UnicodeScalarView(s[$0.start..<$0.end])), $0.heard] } == [["Zini", "Tini"]])
        #expect(PythonJSON.dumps(u.json).contains("glossed") == false)  // worked out when shown, never stored
    }

    @Test func wordsTheUserWroteStayAsWritten() {
        let (t, g) = none(); defer { t.remove() }
        let u = Utterance(speaker: "A", start: 0, end: 1, text: "äh the the plan", heard: "uh the the plan")
        #expect(Readable.readable([u], glossary: g).map(\.text) == ["äh the the plan"])
    }

    @Test func goldenCleanTextMatchesPython() throws {
        let cases = try Goldens.cases("readable", "cases")
        let got = cases.map { JSONValue.array([$0[0], .string(Readable.cleanText($0[0].stringValue!))]) }
        Goldens.expectEach(got, "readable", "cases")
    }
}
