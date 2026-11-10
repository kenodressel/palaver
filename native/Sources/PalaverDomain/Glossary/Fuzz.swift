// rapidfuzz's fuzz.ratio: the normalized Indel similarity (insertions and deletions only), 0...100,
// unrounded, over Unicode scalars (Python str code points), not Swift Characters.
import Foundation

public enum Fuzz {
    /// `rapidfuzz.fuzz.ratio(a, b)`: 100 * (1 - indel distance / (len a + len b)); 100 for two empty strings.
    public static func ratio(_ a: String, _ b: String) -> Double {
        let x = a.unicodeScalars.map(\.value), y = b.unicodeScalars.map(\.value)
        let total = x.count + y.count
        if total == 0 { return 100.0 }
        let distance = total - 2 * lcsLength(x, y)
        let normalizedDistance = Double(distance) / Double(total)
        return (1.0 - normalizedDistance) * 100.0
    }

    /// `rapidfuzz.fuzz.partial_ratio(a, b)`: the best `ratio` of the shorter string against an alignment in the
    /// longer one: the windows of its length and the shorter prefixes that end with one of its characters, the
    /// suffixes that start with one; with equal lengths, both ways round. rapidfuzz 3.14's C++ prunes the windows it
    /// computes but finds the same best score (checked against it on 20 000 random pairs, short and long needles).
    public static func partialRatio(_ a: String, _ b: String) -> Double {
        let x = a.unicodeScalars.map(\.value), y = b.unicodeScalars.map(\.value)
        if x.isEmpty && y.isEmpty { return 100.0 }
        let (shorter, longer) = x.count <= y.count ? (x, y) : (y, x)
        var best = partial(shorter, longer)
        if best != 100 && x.count == y.count { best = max(best, partial(longer, shorter)) }
        return best
    }

    /// `_partial_ratio_impl`: `s1` no longer than `s2`.
    private static func partial(_ s1: [UInt32], _ s2: [UInt32]) -> Double {
        let len1 = s1.count, len2 = s2.count
        if len1 == 0 { return 0.0 }  // no character of it to align on
        let chars = Set(s1)
        let pattern = Pattern(s1)
        var best = 0.0
        func score(_ window: ArraySlice<UInt32>) -> Bool {
            let total = len1 + window.count
            let r = (1.0 - Double(total - 2 * pattern.lcsLength(window)) / Double(total)) * 100.0
            if r > best { best = r }
            return best == 100
        }
        if len1 > 1 {
            for i in 1..<len1 where chars.contains(s2[i - 1]) {
                if score(s2[0..<i]) { return best }
            }
        }
        for i in 0..<(len2 - len1) where chars.contains(s2[i + len1 - 1]) {
            if score(s2[i..<(i + len1)]) { return best }
        }
        for i in (len2 - len1)..<len2 where chars.contains(s2[i]) {
            if score(s2[i...]) { return best }
        }
        return best
    }

    /// A needle's bit masks for the bit-parallel LCS (Hyyrö 2004): what `partialRatio` computes over every window.
    private struct Pattern {
        let length: Int
        let words: Int
        let masks: [UInt32: [UInt64]]

        init(_ s: [UInt32]) {
            length = s.count
            words = (s.count + 63) / 64
            var masks: [UInt32: [UInt64]] = [:]
            for (i, c) in s.enumerated() {
                masks[c, default: [UInt64](repeating: 0, count: words)][i / 64] |= 1 << UInt64(i % 64)
            }
            self.masks = masks
        }

        /// The length of the longest common subsequence of the needle and `text`: the zero bits of V among the
        /// needle's.
        func lcsLength(_ text: ArraySlice<UInt32>) -> Int {
            var v = [UInt64](repeating: ~0, count: words)
            for c in text {
                guard let m = masks[c] else { continue }
                var carry: UInt64 = 0
                for w in 0..<words {
                    let u = v[w] & m[w]
                    let (s1, o1) = v[w].addingReportingOverflow(u)
                    let (s2, o2) = s1.addingReportingOverflow(carry)
                    carry = (o1 || o2) ? 1 : 0
                    v[w] = s2 | (v[w] & ~m[w])
                }
            }
            var lcs = 0
            for w in 0..<words {
                let bits = w == words - 1 && length % 64 != 0 ? length % 64 : 64
                let used: UInt64 = bits == 64 ? ~0 : (1 << UInt64(bits)) - 1
                lcs += (~v[w] & used).nonzeroBitCount
            }
            return lcs
        }
    }

    /// Length of the longest common subsequence.
    private static func lcsLength(_ x: [UInt32], _ y: [UInt32]) -> Int {
        if x.isEmpty || y.isEmpty { return 0 }
        var row = [Int](repeating: 0, count: y.count + 1)
        for xi in x {
            var diagonal = 0
            for j in 1...y.count {
                let above = row[j]
                row[j] = xi == y[j - 1] ? diagonal + 1 : max(above, row[j - 1])
                diagonal = above
            }
        }
        return row[y.count]
    }
}
