// difflib.SequenceMatcher(None, a, b, autojunk=False) over lists of strings (CPython 3.13): the matching
// blocks and opcodes, with CPython's tie-breaking in find_longest_match. Elements compare by Unicode
// scalars, as Python strings do.
import Foundation

public struct SequenceMatcher {
    public struct Opcode: Equatable {
        public let tag: String  // "replace", "delete", "insert", "equal"
        public let i1: Int, i2: Int, j1: Int, j2: Int
        public init(tag: String, i1: Int, i2: Int, j1: Int, j2: Int) { self.tag = tag; self.i1 = i1; self.i2 = i2; self.j1 = j1; self.j2 = j2 }
    }

    private let a: [Int]
    private let b: [Int]
    /// For each element of b, its indices in ascending order.
    private let b2j: [Int: [Int]]

    public init(_ a: [String], _ b: [String]) {
        var ids: [ScalarKey: Int] = [:]
        func id(_ s: String) -> Int {
            let key = ScalarKey(s)
            if let known = ids[key] { return known }
            ids[key] = ids.count
            return ids.count - 1
        }
        self.a = a.map(id)
        self.b = b.map(id)
        var index: [Int: [Int]] = [:]
        for (j, e) in self.b.enumerated() { index[e, default: []].append(j) }
        b2j = index
    }

    /// Longest matching block in a[alo..<ahi], b[blo..<bhi]: the earliest in a, then the earliest in b.
    private func longestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (a: Int, b: Int, size: Int) {
        var besti = alo, bestj = blo, bestsize = 0
        var j2len: [Int: Int] = [:]
        for i in alo..<ahi {
            var newj2len: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                newj2len[j] = k
                if k > bestsize { besti = i - k + 1; bestj = j - k + 1; bestsize = k }
            }
            j2len = newj2len
        }
        return (besti, bestj, bestsize)
    }

    /// get_matching_blocks(): adjacent blocks merged, ending with the (len a, len b, 0) sentinel.
    public func matchingBlocks() -> [(a: Int, b: Int, size: Int)] {
        var queue = [(0, a.count, 0, b.count)]
        var found: [(a: Int, b: Int, size: Int)] = []
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let m = longestMatch(alo, ahi, blo, bhi)
            guard m.size > 0 else { continue }
            found.append(m)
            if alo < m.a && blo < m.b { queue.append((alo, m.a, blo, m.b)) }
            if m.a + m.size < ahi && m.b + m.size < bhi { queue.append((m.a + m.size, ahi, m.b + m.size, bhi)) }
        }
        found.sort { ($0.a, $0.b, $0.size) < ($1.a, $1.b, $1.size) }
        var merged: [(a: Int, b: Int, size: Int)] = []
        var (i1, j1, k1) = (0, 0, 0)
        for (i2, j2, k2) in found {
            if i1 + k1 == i2 && j1 + k1 == j2 {
                k1 += k2
            } else {
                if k1 > 0 { merged.append((i1, j1, k1)) }
                (i1, j1, k1) = (i2, j2, k2)
            }
        }
        if k1 > 0 { merged.append((i1, j1, k1)) }
        merged.append((a.count, b.count, 0))
        return merged
    }

    public func opcodes() -> [Opcode] {
        var out: [Opcode] = []
        var i = 0, j = 0
        for (ai, bj, size) in matchingBlocks() {
            var tag = ""
            if i < ai && j < bj { tag = "replace" } else if i < ai { tag = "delete" } else if j < bj { tag = "insert" }
            if !tag.isEmpty { out.append(Opcode(tag: tag, i1: i, i2: ai, j1: j, j2: bj)) }
            i = ai + size; j = bj + size
            if size > 0 { out.append(Opcode(tag: "equal", i1: ai, i2: i, j1: bj, j2: j)) }
        }
        return out
    }
}
