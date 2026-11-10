// Python's str case rules as Python 3.13 (Unicode 15.1) has them: title, isupper, lower, upper, and code-point
// comparison. Swift's own properties are used only for scalars assigned up to 15.1.
import Foundation

extension Py {
    /// The scalar's properties as Python 3.13 (Unicode 15.1) knows them: one assigned later reads as unassigned
    /// (nil), so macOS's newer Unicode never changes an answer.
    private static func known(_ u: Unicode.Scalar) -> Unicode.Scalar.Properties? {
        guard let age = u.properties.age, age.major < 15 || (age.major == 15 && age.minor <= 1) else { return nil }
        return u.properties
    }

    /// `s.title()`: the first cased letter of each run of cased letters in title case, the rest lower case (a capital
    /// sigma at the end of a word becomes the final sigma, as in Python). Named apart from Task 2's per-scalar table
    /// helpers: case mapping has no generated table, only Swift's properties limited to Unicode 15.1.
    static func strTitle(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var out = "", previousCased = false
        for (i, u) in scalars.enumerated() {
            guard let p = known(u) else { out.unicodeScalars.append(u); previousCased = false; continue }
            if previousCased {
                out += u == "\u{3A3}" && isFinalSigma(scalars, i) ? "\u{3C2}" : p.lowercaseMapping
            } else {
                out += p.titlecaseMapping
            }
            previousCased = p.isCased
        }
        return out
    }

    /// `s.lower()`: full lower-case mapping (Unicode 15.1), a capital sigma at the end of a word a final sigma.
    static func strLower(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var out = ""
        for (i, u) in scalars.enumerated() {
            guard let p = known(u) else { out.unicodeScalars.append(u); continue }
            out += u == "\u{3A3}" && isFinalSigma(scalars, i) ? "\u{3C2}" : p.lowercaseMapping
        }
        return out
    }

    /// `s.upper()`: full upper-case mapping (Unicode 15.1).
    static func strUpper(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            if let p = known(u) { out += p.uppercaseMapping } else { out.unicodeScalars.append(u) }
        }
        return out
    }

    /// Unicode's Final_Sigma: a cased letter before (case-ignorable characters skipped), none after.
    private static func isFinalSigma(_ s: [Unicode.Scalar], _ i: Int) -> Bool {
        var before = i - 1
        while before >= 0, known(s[before])?.isCaseIgnorable == true { before -= 1 }
        guard before >= 0, known(s[before])?.isCased == true else { return false }
        var after = i + 1
        while after < s.count, known(s[after])?.isCaseIgnorable == true { after += 1 }
        return !(after < s.count && known(s[after])?.isCased == true)
    }

    /// `s.isupper()`: at least one cased letter, none of them lower or title case.
    static func strIsUpper(_ s: String) -> Bool {
        var cased = false
        for u in s.unicodeScalars {
            if let p = known(u), p.isLowercase || p.generalCategory == .titlecaseLetter { return false }
            if isUpper(u) { cased = true }
        }
        return cased
    }

    /// `a == b` on strings: by code points (Swift's `==` treats canonically equivalent spellings as equal).
    public static func same(_ a: String, _ b: String) -> Bool { a.unicodeScalars.elementsEqual(b.unicodeScalars) }

    /// `a < b` on strings: by code point (Swift's `<` compares canonical equivalence).
    public static func less(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }
}
