// wordfreq 3.1.1's `zipf_frequency` for German and English (wordlist "large"), as the glossary's
// "rare word" test uses it (glossary.py `zipf` / `is_rare`). The word lists and the character classes of
// wordfreq's tokenizer come from Resources/zipf.bin (tools/make_zipf_table.py); the tokenizer
// (`simple_tokenize`'s regex: Unicode word breaks and grapheme clusters), `smash_numbers`, the
// digit estimates and the rounding are ported from wordfreq, so the numbers match Python's to the digit.
import Compression
import Foundation
import PalaverCore

public enum Zipf {
    /// glossary.py RARE_ZIPF: a word under this is rare (heard but not an ordinary German or English word).
    public static let rareZipf = 2.0

    /// How often the table was read from disk (a test counter: it must stay 1).
    public static var loads: Int { counter.value }

    /// `glossary.zipf`: how common a word is in German or English, whichever is more.
    public static func zipf(_ word: String) -> Double {
        let w = Py.casefold(word)
        let de = frequency(w, lang: "de"), en = frequency(w, lang: "en")
        return en > de ? en : de  // Python's max keeps the first on a tie
    }

    /// `glossary.is_rare`.
    public static func isRare(_ word: String) -> Bool { zipf(word) < rareZipf }

    /// `wordfreq.zipf_frequency(word, lang)` (lang "de" or "en"; any other language is 0.0, where wordfreq raises).
    public static func frequency(_ word: String, lang: String) -> Double {
        guard let list = tables.words[lang] else { return 0.0 }
        let minimum = pow(10, 0.0) / 1e9  // zipf_to_freq(0.0)
        let freq = wordFrequency(word, list, minimum)
        return Py.round(log(freq) / log(10.0) + 9, 2)  // freq_to_zipf: math.log(freq, 10) + 9
    }

    /// `wordfreq.tokens.lossy_tokenize(text, "de")` (the same for "en"): what the lookup sees.
    public static func lossyTokens(_ text: String) -> [String] {
        tokenize(text).map { String(String.UnicodeScalarView($0.compactMap(Unicode.Scalar.init))) }
    }

    // MARK: - word_frequency

    private static func wordFrequency(_ word: String, _ list: [Utf8Key: Int], _ minimum: Double) -> Double {
        let tokens = tokenize(word)
        if tokens.isEmpty { return minimum }
        var oneOverResult = 0.0
        for token in tokens {
            let smashed = smashNumbers(token)
            guard let index = list[Utf8Key(string(smashed))] else { return minimum }
            var freq = pow(10.0, Double(-index) / 100)  // cB_to_freq(-index)
            if smashed != token { freq *= digitFreq(token) }
            oneOverResult += 1.0 / freq
        }
        let freq = 1.0 / oneOverResult
        let unrounded = minimum > freq ? minimum : freq
        if unrounded == 0.0 { return 0.0 }
        let leadingZeroes = Int(floor(-(log(unrounded) / log(10.0))))
        return Py.round(unrounded, leadingZeroes + 3)
    }

    private static func string(_ scalars: [UInt32]) -> String {
        String(String.UnicodeScalarView(scalars.compactMap(Unicode.Scalar.init)))
    }

    // MARK: - numbers.py

    private static let digitFreqs = [0.009, 0.300, 0.175, 0.124, 0.096, 0.078, 0.066, 0.057, 0.050, 0.045]

    private static func isDigit(_ v: UInt32) -> Bool { tables.digits.contains(v) }

    /// `int(c)` of a decimal digit: its place in its run of ten.
    private static func digitValue(_ v: UInt32) -> Int {
        guard let r = tables.digits.find(v) else { return 0 }
        return Int((v - r.lo) % 10)
    }

    /// `MULTI_DIGIT_RE.finditer`: `\d[\d.,]+`, as (start, end) in `s`.
    private static func multiDigitRuns(_ s: [UInt32]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var i = 0
        while i < s.count {
            if isDigit(s[i]), i + 1 < s.count, isDigit(s[i + 1]) || s[i + 1] == 0x2E || s[i + 1] == 0x2C {
                var j = i + 1
                while j < s.count, isDigit(s[j]) || s[j] == 0x2E || s[j] == 0x2C { j += 1 }
                out.append((i, j))
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    /// `smash_numbers`: the digits of a number with more than one digit become "0".
    private static func smashNumbers(_ s: [UInt32]) -> [UInt32] {
        var out = s
        for (a, b) in multiDigitRuns(s) {
            for k in a..<b where isDigit(s[k]) { out[k] = 0x30 }
        }
        return out
    }

    private static func benfordFreq(_ digits: ArraySlice<UInt32>) -> Double {
        let first = digitFreqs[digitValue(digits[digits.startIndex])]
        return first / (Double("1e\(digits.count - 1)") ?? .infinity)  // `/ 10 ** n`: the int as a float, rounded once
    }

    private static func yearFreq(_ digits: ArraySlice<UInt32>) -> Double {
        let year = digits.reduce(0) { $0 * 10 + digitValue($1) }
        let peak = -1.9185, reference = 2019, plateau = 20
        let logFreq: Double
        if year <= reference {
            logFreq = peak - 0.0083 * Double(reference - year)
        } else if year <= reference + plateau {
            logFreq = peak
        } else {
            logFreq = peak - 0.2 * Double(year - (reference + plateau))
        }
        return pow(10.0, logFreq) + 0.1 * benfordFreq(digits)
    }

    /// `digit_freq`.
    private static func digitFreq(_ s: [UInt32]) -> Double {
        var freq = 1.0
        for (a, b) in multiDigitRuns(s) {
            var k = a
            while k < b {  // PURE_DIGIT_RE.findall
                guard isDigit(s[k]) else { k += 1; continue }
                var e = k
                while e < b, isDigit(s[e]) { e += 1 }
                freq *= e - k == 4 ? yearFreq(s[k..<e]) : benfordFreq(s[k..<e])
                k = e
            }
        }
        return freq
    }

    // MARK: - tokens.py

    /// `lossy_tokenize`: preprocess_text (NFC, casefold), `simple_tokenize`, then `uncurl_quotes`.
    private static func tokenize(_ text: String) -> [[UInt32]] {
        // Foundation's NFC: the one Unicode rule here that is not from a Python-derived table (a difference
        // needs a character normalised differently by macOS and Python 3.13, i.e. newer than Unicode 15.1).
        let nfc = { (s: String) in s.precomposedStringWithCanonicalMapping }
        let prepared = nfc(Py.casefold(nfc(text)))
        let scalars = nfc(prepared).unicodeScalars.map(\.value)
        var out: [[UInt32]] = []
        for (a, b) in Scanner(scalars, tables).tokens() {
            var token = Array(scalars[a..<b])
            while token.first == 0x27 { token.removeFirst() }  // str.strip("'")
            while token.last == 0x27 { token.removeLast() }
            token = Py.casefold(string(token)).unicodeScalars.map(\.value)
            out.append(token.map { v in
                if v == 0x2BC || (0x2018...0x201B).contains(v) { return 0x27 }  // SINGLE_QUOTE_RE
                if (0x201C...0x201F).contains(v) { return 0x22 }  // DOUBLE_QUOTE_RE
                return v
            })
        }
        return out
    }

    // MARK: - the table

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        func bump() { lock.lock(); n += 1; lock.unlock() }
    }

    private static let counter = Counter()
    private static let tables: Tables = {
        counter.bump()
        return Tables.load()
    }()

    /// A word list key: compared by UTF-8 bytes, so NFC and NFD forms stay apart (as Python's dict does).
    fileprivate struct Utf8Key: Hashable {
        let s: String
        init(_ s: String) { self.s = s }
        static func == (a: Utf8Key, b: Utf8Key) -> Bool { a.s.utf8.elementsEqual(b.s.utf8) }
        func hash(into hasher: inout Hasher) {
            var s = self.s
            s.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        }
    }

    fileprivate struct Ranges {
        var flat: [UInt32] = []  // lo, hi, lo, hi, ...
        func find(_ v: UInt32) -> (lo: UInt32, hi: UInt32)? {
            var a = 0, b = flat.count / 2
            while a < b {
                let m = (a + b) / 2
                if v < flat[2 * m] { b = m } else if v > flat[2 * m + 1] { a = m + 1 } else { return (flat[2 * m], flat[2 * m + 1]) }
            }
            return nil
        }
        func contains(_ v: UInt32) -> Bool { find(v) != nil }
    }

    /// Code point → class, for the property tables (word break, grapheme break).
    fileprivate struct ClassMap<Tag> {
        var entries: [(lo: UInt32, hi: UInt32, tag: Tag)] = []
        let none: Tag
        init(none: Tag) { self.none = none }
        mutating func sort() { entries.sort { $0.lo < $1.lo } }
        func tag(_ v: UInt32) -> Tag {
            var a = 0, b = entries.count
            while a < b {
                let m = (a + b) / 2
                if v < entries[m].lo { b = m } else if v > entries[m].hi { a = m + 1 } else { return entries[m].tag }
            }
            return none
        }
    }

    fileprivate struct Tables {
        var words: [String: [Utf8Key: Int]] = [:]
        var w = Ranges(), digits = Ranges(), so = Ranges(), spaceless = Ranges(), extpict = Ranges()
        var wb = ClassMap<WB>(none: .other)
        var gcb = ClassMap<GCB>(none: .other)

        static func load() -> Tables {
            guard let url = DomainResources.url("zipf.bin"), let packed = try? Data(contentsOf: url),
                  let data = try? (packed as NSData).decompressed(using: .zlib) as Data else {
                fatalError("zipf.bin is missing or unreadable")  // a packaging error: the app cannot run without it
            }
            var t = Tables()
            var lang: String?, set: String?
            var list: [Utf8Key: Int] = [:]
            func closeLang() { if let l = lang { t.words[l] = list }; list = [:]; lang = nil }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                if line.first == 0x23 {  // "#lang de" / "#set w"
                    closeLang(); set = nil
                    let head = String(decoding: line.dropFirst(), as: UTF8.self)
                    if head.hasPrefix("lang ") { lang = String(head.dropFirst(5)) } else if head.hasPrefix("set ") { set = String(head.dropFirst(4)) }
                } else if lang != nil {
                    var fields = line.split(separator: 0x09, omittingEmptySubsequences: false).makeIterator()
                    guard let first = fields.next(), let index = Int(String(decoding: first, as: UTF8.self)) else { continue }
                    while let word = fields.next() { list[Utf8Key(String(decoding: word, as: UTF8.self))] = index }
                } else if let name = set {
                    t.addSet(name, String(decoding: line, as: UTF8.self))
                }
            }
            closeLang()
            t.wb.sort(); t.gcb.sort()
            return t
        }

        mutating func addSet(_ name: String, _ text: String) {
            var flat: [UInt32] = []
            for part in text.split(separator: ",") {
                let ends = part.split(separator: "-").compactMap { UInt32($0, radix: 16) }
                guard let lo = ends.first else { continue }
                flat += [lo, ends.last ?? lo]
            }
            switch name {
            case "w": w.flat = flat
            case "d": digits.flat = flat
            case "so": so.flat = flat
            case "spaceless": spaceless.flat = flat
            case "extpict": extpict.flat = flat
            default:
                if name.hasPrefix("wb:"), let tag = WB(rawValue: String(name.dropFirst(3))) {
                    for i in stride(from: 0, to: flat.count, by: 2) { wb.entries.append((flat[i], flat[i + 1], tag)) }
                } else if name.hasPrefix("gcb:"), let tag = GCB(rawValue: String(name.dropFirst(4))) {
                    for i in stride(from: 0, to: flat.count, by: 2) { gcb.entries.append((flat[i], flat[i + 1], tag)) }
                }
            }
        }
    }

    fileprivate enum WB: String {
        case other, CR, LF, Newline, Extend, ZWJ, Regional_Indicator, Format, Katakana, Hebrew_Letter, ALetter
        case Single_Quote, Double_Quote, MidNumLet, MidLetter, MidNum, Numeric, ExtendNumLet, WSegSpace
    }

    fileprivate enum GCB: String {
        case other, Control, CR, LF, Extend, ZWJ, Regional_Indicator, Prepend, SpacingMark, L, V, T, LV, LVT
    }

    // MARK: - TOKEN_RE

    /// `findall` of wordfreq's TOKEN_RE over one string: Unicode word breaks (`\b` in the regex module's
    /// WORD mode, UAX #29) and grapheme clusters (`\X`), over the classes read from zipf.bin.
    /// Not ported: the Indic conjunct rule of grapheme clusters (GB9c), which no German or English text meets.
    fileprivate struct Scanner {
        let s: [UInt32]
        let t: Tables
        let wb: [WB]
        let gcb: [GCB]
        let isWord: [Bool]

        init(_ s: [UInt32], _ t: Tables) {
            self.s = s
            self.t = t
            wb = s.map { t.wb.tag($0) }
            gcb = s.map { t.gcb.tag($0) }
            isWord = s.map { t.w.contains($0) }
        }

        private func w(_ i: Int) -> Bool { i >= 0 && i < s.count && isWord[i] }
        private func at(_ i: Int, _ v: UInt32) -> Bool { i >= 0 && i < s.count && s[i] == v }

        // `[AEHIOUYÁÉÍÓÚÀÈÌÒÙÂÊÎÔÛÅÏÖŒaehiouyáéíóúàèìòùâêîôûåïöœ]`
        private static let vowels = Set("AEHIOUYÁÉÍÓÚÀÈÌÒÙÂÊÎÔÛÅÏÖŒaehiouyáéíóúàèìòùâêîôûåïöœ".unicodeScalars.map(\.value))

        /// The letters after which the regex module's `\b` keeps an apostrophe attached (found by asking it, for every
        /// ALetter after an apostrophe): A E I O U a e i o u, À-Â È-Ê Ì-Î Ò-Ô Ù-Û à-â è-ê ì-î ò-ô ù-û, İ.
        private static let apostropheVowels: Set<UInt32> = {
            var set = Set("AEIOUaeiou".unicodeScalars.map(\.value))
            for base in [0xC0, 0xC8, 0xCC, 0xD2, 0xD9, 0xE0, 0xE8, 0xEC, 0xF2, 0xF9] as [UInt32] { set.formUnion(base...base + 2) }
            set.insert(0x130)
            return set
        }()

        func tokens() -> [(Int, Int)] {
            var out: [(Int, Int)] = []
            var pos = 0
            while pos < s.count {
                if let end = match(at: pos) { out.append((pos, end)); pos = end } else { pos += 1 }
            }
            return out
        }

        private func match(at pos: Int) -> Int? {
            // Case 1: [SPACELESS]+
            if t.spaceless.contains(s[pos]) {
                var e = pos + 1
                while e < s.count, t.spaceless.contains(s[e]) { e += 1 }
                return e
            }
            // Case 2: @s \b
            if s[pos] == 0x40, at(pos + 1, 0x73), wordBreak(pos + 2) { return pos + 2 }
            // Case 3: (?=[\w\p{So}]) (?!\w\w?'<VOWEL>) \X+? (?: @s? (?!\w) | \b )
            if isWord[pos] || t.so.contains(s[pos]) {
                let frenchElision = (w(pos) && at(pos + 1, 0x27) && at(pos + 2, { Self.vowels.contains($0) }))
                    || (w(pos) && w(pos + 1) && at(pos + 2, 0x27) && at(pos + 3, { Self.vowels.contains($0) }))
                if !frenchElision {
                    var e = nextGrapheme(pos)
                    while true {
                        if at(e, 0x40) {
                            if at(e + 1, 0x73), !w(e + 2) { return e + 2 }
                            if !w(e + 1) { return e + 1 }
                        }
                        if wordBreak(e) { return e }
                        if e >= s.count { break }
                        e = nextGrapheme(e)
                    }
                }
            }
            // Case 4: \w\w?'
            if isWord[pos] {
                if w(pos + 1), at(pos + 2, 0x27) { return pos + 3 }
                if at(pos + 1, 0x27) { return pos + 2 }
            }
            return nil
        }

        private func at(_ i: Int, _ test: (UInt32) -> Bool) -> Bool { i >= 0 && i < s.count && test(s[i]) }

        // MARK: \X

        private func nextGrapheme(_ i: Int) -> Int {
            var j = i + 1
            while j < s.count, !graphemeBoundary(j) { j += 1 }
            return j
        }

        private func graphemeBoundary(_ i: Int) -> Bool {
            if i <= 0 || i >= s.count { return true }
            let a = gcb[i - 1], b = gcb[i]
            if a == .CR && b == .LF { return false }
            if a == .Control || a == .CR || a == .LF { return true }
            if b == .Control || b == .CR || b == .LF { return true }
            if a == .L && (b == .L || b == .V || b == .LV || b == .LVT) { return false }
            if (a == .LV || a == .V) && (b == .V || b == .T) { return false }
            if (a == .LVT || a == .T) && b == .T { return false }
            if b == .Extend || b == .ZWJ || b == .SpacingMark { return false }
            if a == .Prepend { return false }
            if a == .ZWJ, t.extpict.contains(s[i]) {  // GB11: ExtPict Extend* ZWJ × ExtPict
                var p = i - 2
                while p >= 0, gcb[p] == .Extend { p -= 1 }
                if p >= 0, t.extpict.contains(s[p]) { return false }
            }
            if a == .Regional_Indicator && b == .Regional_Indicator {  // GB12/13: pairs
                var n = 0, p = i - 1
                while p >= 0, gcb[p] == .Regional_Indicator { n += 1; p -= 1 }
                if n % 2 == 1 { return false }
            }
            return true
        }

        // MARK: \b (UAX #29 word boundaries)

        private func efz(_ c: WB) -> Bool { c == .Extend || c == .Format || c == .ZWJ }
        private func newline(_ c: WB) -> Bool { c == .Newline || c == .CR || c == .LF }
        private func ahl(_ c: WB) -> Bool { c == .ALetter || c == .Hebrew_Letter }
        private func midNumLetQ(_ c: WB) -> Bool { c == .MidNumLet || c == .Single_Quote }

        /// The WB4 unit that ends just before `end`: its class (Extend/Format/ZWJ fold into what they follow)
        /// and where it starts.
        private func prev(_ end: Int) -> (cls: WB, idx: Int) {
            var p = end - 1
            while p > 0, efz(wb[p]) { p -= 1 }
            if p < end - 1 || efz(wb[p]) {
                if efz(wb[p]) || newline(wb[p]) { return (.other, p) }  // a chain with nothing to attach to
            }
            return (wb[p], p)
        }

        /// The class right after position `i`. The regex module looks one character ahead and behind
        /// without skipping Extend/Format/ZWJ in its lookaround rules (WB6, WB7, WB7b, WB7c, WB11, WB12);
        /// tools/make_zipf_table.py's classes and an exhaustive check of all class sequences up to length 5
        /// against `regex` settled that.
        private func nextBase(after i: Int) -> WB? { i + 1 < s.count ? wb[i + 1] : nil }

        private func before(_ e: Int) -> WB { wb[e - 1] }

        func wordBreak(_ i: Int) -> Bool {
            if s.isEmpty { return false }
            if i <= 0 || i >= s.count { return true }  // WB1, WB2
            let a = wb[i - 1], b = wb[i]
            if a == .CR && b == .LF { return false }  // WB3
            if newline(a) || newline(b) { return true }  // WB3a, WB3b
            if a == .ZWJ && t.extpict.contains(s[i]) { return false }  // WB3c
            if a == .WSegSpace && b == .WSegSpace { return false }  // WB3d
            if efz(b) { return false }  // WB4
            let (pa, aIdx) = prev(i)
            if efz(wb[0]) && aIdx == 0 && pa == .other { return false }  // regex: nothing breaks after marks that open the text
            if ahl(pa) && ahl(b) { return false }  // WB5
            if (s[aIdx] == 0x27 || s[aIdx] == 0x2019) && Self.apostropheVowels.contains(s[i]) { return false }  // regex: ' or ’ before one of these vowels is no break
            if ahl(pa) && (b == .MidLetter || midNumLetQ(b)), let c = nextBase(after: i), ahl(c) { return false }  // WB6
            if (pa == .MidLetter || midNumLetQ(pa)) && ahl(b), aIdx > 0, ahl(before(aIdx)) { return false }  // WB7
            if pa == .Hebrew_Letter && b == .Single_Quote { return false }  // WB7a
            if pa == .Hebrew_Letter && b == .Double_Quote, nextBase(after: i) == .Hebrew_Letter { return false }  // WB7b
            if pa == .Double_Quote && b == .Hebrew_Letter, aIdx > 0, before(aIdx) == .Hebrew_Letter { return false }  // WB7c
            if pa == .Numeric && b == .Numeric { return false }  // WB8
            if ahl(pa) && b == .Numeric { return false }  // WB9
            if pa == .Numeric && ahl(b) { return false }  // WB10
            if (pa == .MidNum || midNumLetQ(pa)) && b == .Numeric, aIdx > 0, before(aIdx) == .Numeric { return false }  // WB11
            if pa == .Numeric && (b == .MidNum || midNumLetQ(b)), nextBase(after: i) == .Numeric { return false }  // WB12
            if pa == .Katakana && b == .Katakana { return false }  // WB13
            if (ahl(pa) || pa == .Numeric || pa == .Katakana || pa == .ExtendNumLet) && b == .ExtendNumLet { return false }  // WB13a
            if pa == .ExtendNumLet && (ahl(b) || b == .Numeric || b == .Katakana) { return false }  // WB13b
            if pa == .Regional_Indicator {  // WB15, WB16 (the regex module applies it whatever follows)
                var n = 0, e = i
                while e > 0 {
                    let u = n == 0 ? prev(e) : (before(e), e - 1)
                    if u.0 != .Regional_Indicator { break }
                    n += 1
                    e = u.1
                }
                if n % 2 == 1 { return false }
            }
            return true  // WB999
        }
    }
}
