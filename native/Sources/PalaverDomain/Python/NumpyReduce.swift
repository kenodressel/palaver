// numpy's `add.reduce` over a contiguous run of floats (float32 or float64), in numpy's order: pairwise, in blocks of
// up to 128 with eight accumulators (numpy's `pairwise_sum`). The one copy of that order; `GrowingTrack.quietestCut`
// and `Cleanup`'s levels sum through it, and their goldens pin it to the bit. Plain `*` and `+` only: Swift never
// contracts them into a fused multiply-add.
import Foundation

enum NumpyReduce {
    /// The sum of `term(i)` for i in `i0..<i0 + n`, added as numpy adds them.
    static func pairwiseSum<T: BinaryFloatingPoint>(from i0: Int, count n: Int, _ term: (Int) -> T) -> T {
        if n < 8 {
            var r: T = 0
            for i in i0..<(i0 + n) { r += term(i) }
            return r
        }
        if n <= 128 {
            var r0 = term(i0), r1 = term(i0 + 1), r2 = term(i0 + 2), r3 = term(i0 + 3)
            var r4 = term(i0 + 4), r5 = term(i0 + 5), r6 = term(i0 + 6), r7 = term(i0 + 7)
            var i = i0 + 8
            let blocks = i0 + n - n % 8
            while i < blocks {
                r0 += term(i); r1 += term(i + 1); r2 += term(i + 2); r3 += term(i + 3)
                r4 += term(i + 4); r5 += term(i + 5); r6 += term(i + 6); r7 += term(i + 7)
                i += 8
            }
            var res = ((r0 + r1) + (r2 + r3)) + ((r4 + r5) + (r6 + r7))
            while i < i0 + n { res += term(i); i += 1 }
            return res
        }
        var n2 = n / 2
        n2 -= n2 % 8
        return pairwiseSum(from: i0, count: n2, term) + pairwiseSum(from: i0 + n2, count: n - n2, term)
    }

    /// float32 `add.reduce` of `s[i0..<i0 + n] ** 2` (each square rounded to float32 first, as `frames**2` is).
    static func sumOfSquares(_ s: UnsafeBufferPointer<Float>, from i0: Int, count n: Int) -> Float {
        pairwiseSum(from: i0, count: n) { s[$0] * s[$0] }
    }

    /// float64 `add.reduce` of `x.astype(np.float64) ** 2` over int16 samples.
    static func sumOfSquares(_ s: UnsafeBufferPointer<Int16>, from i0: Int, count n: Int) -> Double {
        pairwiseSum(from: i0, count: n) { let x = Double(s[$0]); return x * x }
    }
}
