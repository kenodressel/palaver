// Clean verbatim (palaver/readable.py): the transcript as it is read, without filler words and
// stutters, with names spelled as the glossary says. transcript.json stays word for word.
import Foundation
import PalaverCore

public enum Readable {
    // Hesitations in German and English. Not "eh": in Austrian German it means "anyway". Not "er": German for "he".
    private static let filler = try! PyRegex(
        "(?:m{2,}|u+h+|u+h*m+|e+r+m+|ä+h*m*|ö+h*m*|h+m+|m*h+m+|m+-?h+m+|uh-huh)", ignoreCase: true)

    // Doubled on purpose, not stutters ("Ja, ja", "ciao ciao", "sehr sehr gut").
    private static let keepRepeated: Set<String> = [
        "ja", "jaja", "nein", "nee", "no", "yes", "yeah", "okay", "ok", "genau", "passt",
        "gut", "sehr", "very", "ciao", "bye", "tschüss", "hallo", "hello", "hi", "danke",
        "thanks", "bla", "absolut",
    ]

    // German "um" is a word ("um zu", "damit um"); only English "um" is a filler, and German "Um," opening a
    // sentence. Which language a turn is in: whichever has more of these common words.
    static let german: Set<String> = [
        "der", "die", "das", "und", "ist", "ich", "wir", "nicht", "ein", "eine", "zu", "mit",
        "auf", "für", "dass", "es", "sie", "aber", "auch", "dann", "noch", "jetzt", "haben",
        "wird", "man", "halt", "schon", "genau", "ja", "oder", "wenn", "damit", "da", "einem",
    ]
    static let english: Set<String> = [
        "the", "and", "is", "i", "we", "not", "a", "to", "with", "on", "for", "that", "it",
        "you", "but", "of", "this", "so", "they", "have", "be", "what", "like", "yeah",
    ]

    private static let sentenceEnd: Set<Unicode.Scalar> = [".", "?", "!"]
    private static let trailingMarks: Set<Unicode.Scalar> = [",", ".", "?", "!", ";", ":"]

    // The transcriber glues numbers to the word before ("für150", "Ende2030"): a word of two or more
    // letters, ending in lower case, then two or more digits. Leaves "H100", "MP3", "GPT4", "COVID19" alone.
    private static let glued = try! PyRegex(#"\b([^\W\d_]*[a-zäöüß]{2})(\d{2,})"#)

    // MARK: - Python's str helpers

    /// `str.lower()`, with the final sigma rule.
    static func lower(_ s: String) -> String {
        if s.utf8.allSatisfy({ $0 < 0x80 }) { return s.lowercased() }
        return Py.strLower(s)
    }

    /// `re.sub(r"^\W+|\W+$", "", token).lower()`.
    static func core(_ token: String) -> String {
        let scalars = Array(token.unicodeScalars)
        guard let first = scalars.firstIndex(where: Py.isWordScalar), let last = scalars.lastIndex(where: Py.isWordScalar)
        else { return "" }
        return lower(String(String.UnicodeScalarView(scalars[first...last])))
    }

    /// The punctuation a token ends on: `token[len(token.rstrip(",.?!;:")):]`.
    private static func trailing(_ token: String) -> String {
        let scalars = Array(token.unicodeScalars)
        var i = scalars.count
        while i > 0, trailingMarks.contains(scalars[i - 1]) { i -= 1 }
        return String(String.UnicodeScalarView(scalars[i...]))
    }

    /// The token without that punctuation.
    private static func stem(_ token: String) -> String {
        String(token.unicodeScalars.dropLast(trailing(token).unicodeScalars.count))
    }

    private static func capitalize(_ token: String) -> String {
        guard let first = token.unicodeScalars.first else { return token }
        return first.properties.uppercaseMapping + String(token.unicodeScalars.dropFirst())
    }

    private static func endsSentence(_ token: String) -> Bool {
        token.unicodeScalars.last.map(sentenceEnd.contains) ?? false
    }

    // MARK: - clean text

    /// "we made we made it" → "we made it": a phrase said twice in a row keeps its first copy, with the
    /// punctuation the second one ended on.
    private static func collapsePhrases(_ input: [String], longest: Int = 4) -> [String] {
        var tokens = input
        var cores = tokens.map(core)
        var i = 0
        while i < tokens.count {
            var collapsed = false
            var n = min(longest, (tokens.count - i) / 2)
            while n >= 2 {
                let phrase = Array(cores[i..<i + n])
                if !phrase.contains(""), phrase == Array(cores[i + n..<i + 2 * n]), !Set(phrase).isSubset(of: keepRepeated) {
                    let last = tokens[i + n - 1]
                    tokens[i + n - 1] = stem(last) + trailing(tokens[i + 2 * n - 1])
                    tokens.removeSubrange(i + n..<i + 2 * n)
                    cores.removeSubrange(i + n..<i + 2 * n)
                    collapsed = true
                    break
                }
                n -= 1
            }
            if !collapsed { i += 1 }
        }
        return tokens
    }

    /// Drops filler words and collapses stutters ("the the the" → "the", "we made we made" → "we made"),
    /// and puts a space before numbers glued to a word ("für150" → "für 150").
    public static func cleanText(_ input: String) -> String {
        let text = (try? glued.sub("\\1 \\2", in: input)) ?? input
        let words = Py.split(text)
        let cores = words.map(core)
        let isGerman = cores.filter(german.contains).count > cores.filter(english.contains).count
        var tokens: [String] = []
        var shifted = false  // a removal moved the next token to where a sentence starts
        for (token, core) in zip(words, cores) {
            let opensSentence = tokens.isEmpty || endsSentence(tokens[tokens.count - 1])
            let germanWord = isGerman && core == "um" && !(opensSentence && token.unicodeScalars.last == ",")
            if !core.isEmpty, filler.fullMatch(core) != nil, !germanWord {
                let end = trailing(token)
                if !tokens.isEmpty, !end.isEmpty {
                    // Commas around a filler are the filler's; its full stop is the sentence's.
                    let stop = String(String.UnicodeScalarView(end.unicodeScalars.filter(sentenceEnd.contains)))
                    var before = Array(tokens[tokens.count - 1].unicodeScalars)
                    while before.last == "," { before.removeLast() }
                    let last = String(String.UnicodeScalarView(before)) + stop
                    if !last.isEmpty { tokens[tokens.count - 1] = last } else { tokens.removeLast() }  // a lone comma before it
                }
                shifted = tokens.isEmpty || endsSentence(tokens[tokens.count - 1])  // the filler's "." moved over
                continue
            }
            if let previous = tokens.last, !core.isEmpty, core == Self.core(previous), !keepRepeated.contains(core),
               !(isGerman && previous.unicodeScalars.last == ",") {
                tokens[tokens.count - 1] = stem(previous) + trailing(token)
                continue
            }
            tokens.append(shifted ? capitalize(token) : token)
            shifted = false
        }
        return collapsePhrases(tokens).joined(separator: " ")
    }

    /// Cleaned copies with names spelled as the glossary says (the user's, unless `glossary` is given);
    /// turns that were nothing but filler ("Mm-hmm.") are dropped. Words the user wrote stay as written:
    /// no filler removal.
    public static func readable(_ utterances: [Utterance], glossary: Glossary? = nil) -> [Utterance] {
        let glossary = glossary ?? Glossary.current()
        var out: [Utterance] = []
        for u in utterances {
            let (text, glossed) = glossary.applyMarked(u.heard != nil ? u.text : cleanText(u.text))
            if !core(text).isEmpty {
                var copy = u
                copy.text = text
                copy.glossed = glossed
                out.append(copy)
            }
        }
        return out
    }
}
