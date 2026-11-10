// Python's `statistics.mean` and `statistics.median` (CPython 3.13). `mean` sums exactly (as fractions) and rounds
// once: all ints give an int when the mean is whole, else the correctly rounded float of the exact mean; a float
// among them gives a float. A plain `sum / n` can be an ulp off, and that ulp can change a later `round(x, 3)`.
import Foundation

public enum PyStatistics {
    /// `statistics.mean(values)`; nil for no values (Python raises StatisticsError).
    public static func mean(_ values: [PyNum]) -> PyNum? {
        guard !values.isEmpty else { return nil }
        let n = values.count
        var ints: [Int] = []
        for v in values { if case .int(let i) = v { ints.append(i) } }
        if ints.count == n {
            var total = 0, overflow = false
            for i in ints {
                let (s, o) = total.addingReportingOverflow(i)
                total = s; overflow = overflow || o
            }
            if !overflow {
                if total % n == 0 { return .int(total / n) }
                if total.magnitude < (1 << 53) { return .float(Double(total) / Double(n)) }  // both exact: one rounding
            }
        }
        return .float(exactMean(values.map(\.double)))
    }

    /// `statistics.median(values)`: the middle value, or the mean of the middle two as `(a + b) / 2`; nil for none.
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let data = values.sorted()
        let n = data.count
        if n % 2 == 1 { return data[n / 2] }
        return (data[n / 2 - 1] + data[n / 2]) / 2
    }

    /// The mean of `xs` rounded once, to nearest, ties to even: `float(Fraction(sum) / n)`.
    static func exactMean(_ xs: [Double]) -> Double {
        if xs.contains(where: { !$0.isFinite }) { return xs.reduce(0, +) / Double(xs.count) }  // inf and nan as Python
        // Every double is m * 2^e with an integer m: sum the m's exactly on the smallest e.
        var parts: [(negative: Bool, m: UInt64, e: Int)] = []
        for x in xs where x != 0 {
            if x.isSubnormal {
                parts.append((x < 0, x.significandBitPattern, -1074))
            } else {
                parts.append((x < 0, x.significandBitPattern | (1 << 52), Int(x.exponentBitPattern) - 1075))
            }
        }
        guard let emin = parts.map(\.e).min() else { return 0.0 }
        var positive = Big(), negative = Big()
        for p in parts {
            let term = Big(p.m).shifted(left: p.e - emin)
            if p.negative { negative = negative + term } else { positive = positive + term }
        }
        let negativeResult = negative > positive
        let total = negativeResult ? negative - positive : positive - negative
        if total.isZero { return 0.0 }
        let n = UInt32(xs.count)
        // At least 55 bits of quotient, then round to 53 with the remainder as a sticky bit.
        let nBits = 32 - n.leadingZeroBitCount
        let k = max(0, 56 + nBits - total.bitLength)
        let (q, remainder) = total.shifted(left: k).divided(by: n)
        var sticky = remainder != 0
        let bits = q.bitLength
        var top: UInt64, shift = 0
        if bits > 64 {
            shift = bits - 64
            top = q.topBits(64)
            sticky = sticky || q.hasBitsBelow(shift)
        } else {
            top = q.low64
        }
        let width = 64 - top.leadingZeroBitCount
        let drop = width - 53
        var mantissa = top >> UInt64(drop)
        let rest = top & ((1 << UInt64(drop)) - 1), half = UInt64(1) << UInt64(drop - 1)
        if rest > half || (rest == half && (sticky || mantissa & 1 == 1)) {
            mantissa += 1
        }
        let exponent = emin - k + shift + drop
        let value = Double(sign: .plus, exponent: exponent, significand: Double(mantissa))
        return negativeResult ? -value : value
    }

    /// A non-negative integer of any size, little-endian 32-bit limbs: what the exact mean needs, no more.
    struct Big: Comparable {
        var limbs: [UInt32] = []

        init() {}
        init(_ v: UInt64) {
            limbs = [UInt32(truncatingIfNeeded: v), UInt32(truncatingIfNeeded: v >> 32)]
            trim()
        }

        private mutating func trim() { while limbs.last == 0 { limbs.removeLast() } }

        var isZero: Bool { limbs.isEmpty }
        var bitLength: Int { limbs.isEmpty ? 0 : limbs.count * 32 - limbs.last!.leadingZeroBitCount }
        var low64: UInt64 {
            (limbs.count > 0 ? UInt64(limbs[0]) : 0) | (limbs.count > 1 ? UInt64(limbs[1]) << 32 : 0)
        }

        func shifted(left bits: Int) -> Big {
            guard !isZero, bits > 0 else { return self }
            let whole = bits / 32, part = bits % 32
            var out = Big()
            out.limbs = [UInt32](repeating: 0, count: whole) + limbs + [0]
            if part > 0 {
                var carry: UInt32 = 0
                for i in whole..<out.limbs.count {
                    let v = out.limbs[i]
                    out.limbs[i] = (v << UInt32(part)) | carry
                    carry = v >> UInt32(32 - part)
                }
            }
            out.trim()
            return out
        }

        /// The quotient and remainder by a small divisor.
        func divided(by d: UInt32) -> (Big, UInt32) {
            var out = Big()
            out.limbs = [UInt32](repeating: 0, count: limbs.count)
            var remainder: UInt64 = 0
            for i in stride(from: limbs.count - 1, through: 0, by: -1) {
                let cur = (remainder << 32) | UInt64(limbs[i])
                out.limbs[i] = UInt32(cur / UInt64(d))
                remainder = cur % UInt64(d)
            }
            out.trim()
            return (out, UInt32(remainder))
        }

        func bit(_ i: Int) -> Bool { i / 32 < limbs.count && (limbs[i / 32] >> UInt32(i % 32)) & 1 == 1 }

        /// The highest `count` bits (at most 64) as an integer.
        func topBits(_ count: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in stride(from: bitLength - 1, through: bitLength - count, by: -1) { v = (v << 1) | (bit(i) ? 1 : 0) }
            return v
        }

        func hasBitsBelow(_ count: Int) -> Bool { (0..<count).contains { bit($0) } }

        static func + (a: Big, b: Big) -> Big {
            var out = Big()
            var carry: UInt64 = 0
            for i in 0..<max(a.limbs.count, b.limbs.count) {
                let s = UInt64(i < a.limbs.count ? a.limbs[i] : 0) + UInt64(i < b.limbs.count ? b.limbs[i] : 0) + carry
                out.limbs.append(UInt32(truncatingIfNeeded: s))
                carry = s >> 32
            }
            if carry > 0 { out.limbs.append(UInt32(carry)) }
            out.trim()
            return out
        }

        /// `a - b` for `a >= b`.
        static func - (a: Big, b: Big) -> Big {
            var out = Big()
            var borrow: Int64 = 0
            for i in 0..<a.limbs.count {
                var d = Int64(a.limbs[i]) - Int64(i < b.limbs.count ? b.limbs[i] : 0) - borrow
                borrow = d < 0 ? 1 : 0
                if d < 0 { d += 1 << 32 }
                out.limbs.append(UInt32(d))
            }
            out.trim()
            return out
        }

        static func < (a: Big, b: Big) -> Bool {
            if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
            for i in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[i] != b.limbs[i] {
                return a.limbs[i] < b.limbs[i]
            }
            return false
        }
    }
}
