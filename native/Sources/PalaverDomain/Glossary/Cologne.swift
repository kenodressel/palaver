// glossary.py's cologne(): Kölner Phonetik, a German sound code ("Wasti" and "Vasti" are both "382").
import Foundation

public enum Cologne {
    public static func code(_ word: String) -> String {
        // Python: word.upper() first, then Ä Ö Ü ß are mapped (ß is already "SS" after upper()).
        var w: [UInt8] = []
        for u in Py.strUpper(word).unicodeScalars {
            switch u {
            case "Ä": w.append(UInt8(ascii: "A"))
            case "Ö": w.append(UInt8(ascii: "O"))
            case "Ü": w.append(UInt8(ascii: "U"))
            case "ß": w.append(UInt8(ascii: "S"))
            default: if u.value >= 65 && u.value <= 90 { w.append(UInt8(u.value)) }
            }
        }
        func ch(_ s: String) -> UInt8 { s.utf8.first! }
        let none: UInt8 = 0
        var codes: [UInt8] = []
        for i in 0..<w.count {
            let c = w[i]
            let prev = i > 0 ? w[i - 1] : none
            let next = i + 1 < w.count ? w[i + 1] : none
            let code: String
            switch Character(Unicode.Scalar(c)) {
            case "A", "E", "I", "J", "O", "U", "Y": code = "0"
            case "H": code = ""
            case "B": code = "1"
            case "P": code = next == ch("H") ? "3" : "1"
            case "D", "T": code = [ch("C"), ch("S"), ch("Z")].contains(next) ? "8" : "2"
            case "F", "V", "W": code = "3"
            case "G", "K", "Q": code = "4"
            case "C":
                if i == 0 {
                    code = "AHKLOQRUX".utf8.contains(next) && next != none ? "4" : "8"
                } else {
                    code = "AHKOQUX".utf8.contains(next) && next != none && prev != ch("S") && prev != ch("Z") ? "4" : "8"
                }
            case "X": code = [ch("C"), ch("K"), ch("Q")].contains(prev) ? "8" : "48"
            case "L": code = "5"
            case "M", "N": code = "6"
            case "R": code = "7"
            default: code = "8"  // S, Z
            }
            codes.append(contentsOf: code.utf8)
        }
        var out: [UInt8] = []
        for c in codes where out.last != c { out.append(c) }
        guard let first = out.first else { return "" }
        return String(decoding: [first] + out.dropFirst().filter { $0 != ch("0") }, as: UTF8.self)
    }
}
