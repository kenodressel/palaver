// Average-linkage (UPGMA) clusters of voices, as people.py's `_groups` makes them with scipy:
// `fcluster(linkage(X, "average", metric="cosine"), t, criterion="distance")`. Ported from scipy 1.17's own steps so the
// clusters and their numbers are scipy's, ties included: `pdist` (cosine), `nn_chain` (the nearest-neighbour chain
// average linkage runs), the stable sort by distance, `label` (union-find), `cluster_dist`/`cluster_monocrit`.
// The arithmetic is the compiled scipy's: its dot products and the average update use fused multiply-adds (clang
// contracts `a * b + c`), checked bit for bit against scipy on 2400 random and tied cases (golden `upgma`).
import Foundation

/// What scipy raises as ValueError: vectors of two lengths (`np.stack`), or a distance that is not finite (a zero or
/// non-finite vector).
public struct UpgmaError: Error, CustomStringConvertible {
    public let description: String
}

public enum Upgma {
    /// One merge of the linkage matrix `Z`: clusters `a` < `b` (scipy's numbers: leaves 0..<n, then n, n+1, … for the
    /// merges in order), their distance, and the new cluster's size.
    struct Merge: Equatable {
        let a: Int
        let b: Int
        let distance: Double
        let size: Int
    }

    /// `pdist(X, "cosine")` in condensed order (0-1, 0-2, …, 1-2, …): `1 - u·v / (|u| |v|)`, the cosine clipped to
    /// [-1, 1]; each sum of products fused, in order.
    static func cosineDistances(_ vectors: [[Double]]) throws -> [Double] {
        let n = vectors.count
        guard let dim = vectors.first?.count, vectors.allSatisfy({ $0.count == dim }) else {
            if vectors.isEmpty { return [] }
            throw UpgmaError(description: "all input arrays must have the same shape")
        }
        var out: [Double] = []
        out.reserveCapacity(n * (n - 1) / 2)
        for i in 0..<n {
            for j in (i + 1)..<n {
                var xy = 0.0, xx = 0.0, yy = 0.0
                let u = vectors[i], v = vectors[j]
                for k in 0..<dim {
                    xy = xy.addingProduct(u[k], v[k])
                    xx = xx.addingProduct(u[k], u[k])
                    yy = yy.addingProduct(v[k], v[k])
                }
                var cosine = xy / (xx.squareRoot() * yy.squareRoot())
                if abs(cosine) > 1 { cosine = cosine < 0 ? -1 : 1 }
                out.append(1 - cosine)
            }
        }
        guard out.allSatisfy(\.isFinite) else {
            throw UpgmaError(description: "The condensed distance matrix must contain only finite values.")
        }
        return out
    }

    /// `condensed_index(n, i, j)`.
    private static func condensed(_ n: Int, _ i: Int, _ j: Int) -> Int {
        let (a, b) = i < j ? (i, j) : (j, i)
        return n * a - (a * (a + 1)) / 2 + (b - a - 1)
    }

    /// `linkage(X, "average", metric="cosine")`: scipy's `nn_chain`, sorted by distance (stable), labelled.
    static func linkage(_ vectors: [[Double]]) throws -> [Merge] {
        let n = vectors.count
        var distances = try cosineDistances(vectors)
        guard n >= 2 else { return [] }
        var size = [Int](repeating: 1, count: n)
        var chain: [Int] = []
        var raw: [Merge] = []
        for _ in 0..<(n - 1) {
            if chain.isEmpty { chain = [size.firstIndex { $0 > 0 }!] }
            var x = 0, y = 0
            var current = Double.infinity
            // Along the chain of nearest neighbours until two are each other's.
            while true {
                x = chain[chain.count - 1]
                if chain.count > 1 {
                    // The chain's previous element is preferred: no cycles among equal distances.
                    y = chain[chain.count - 2]
                    current = distances[condensed(n, x, y)]
                } else {
                    current = .infinity
                }
                for i in 0..<n where size[i] > 0 && i != x {
                    let d = distances[condensed(n, x, i)]
                    if d < current {
                        current = d
                        y = i
                    }
                }
                if chain.count > 1 && y == chain[chain.count - 2] { break }
                chain.append(y)
            }
            chain.removeLast(2)
            if x > y { swap(&x, &y) }
            let nx = size[x], ny = size[y]
            raw.append(Merge(a: x, b: y, distance: current, size: nx + ny))
            size[x] = 0
            size[y] = nx + ny
            // `_average`: (nx * d_xi + ny * d_yi) / (nx + ny), the first product fused into the sum.
            for i in 0..<n where size[i] > 0 && i != y {
                let dxi = distances[condensed(n, i, x)], dyi = distances[condensed(n, i, y)]
                distances[condensed(n, i, y)] = (Double(ny) * dyi).addingProduct(Double(nx), dxi) / Double(nx + ny)
            }
        }
        // np.argsort(kind="mergesort"): stable.
        let sorted = Py.stableSorted(raw) { $0.distance < $1.distance }
        // `label`: the clusters' numbers in the sorted order (union-find).
        var parent = Array(0..<(2 * n - 1))
        var sizes = [Int](repeating: 1, count: 2 * n - 1)
        var next = n
        func find(_ start: Int) -> Int {
            var root = start
            while parent[root] != root { root = parent[root] }
            var p = start
            while parent[p] != root { (p, parent[p]) = (parent[p], root) }
            return root
        }
        return sorted.map { merge in
            let a = find(merge.a), b = find(merge.b)
            parent[a] = next
            parent[b] = next
            sizes[next] = sizes[a] + sizes[b]
            next += 1
            return Merge(a: min(a, b), b: max(a, b), distance: merge.distance, size: sizes[next - 1])
        }
    }

    /// `fcluster(Z, t=threshold, criterion="distance")` over `linkage(vectors)`: each vector's flat cluster (1, 2, …
    /// in scipy's numbering), the clusters whose merges are all at most `threshold` apart. `threshold` is the cosine
    /// distance (people.py passes `1 - GROUP_THRESHOLD`). One vector is cluster 1; none, no clusters (scipy raises:
    /// people.py never asks).
    public static func fcluster(_ vectors: [[Double]], threshold: Double) throws -> [Int] {
        let n = vectors.count
        if n < 2 {
            _ = try cosineDistances(vectors)
            return n == 1 ? [1] : []
        }
        let z = try linkage(vectors)
        return clusters(z, n, threshold)
    }

    /// `cluster_dist`: the largest merge distance under each node, then `cluster_monocrit`'s walk from the root.
    static func clusters(_ z: [Merge], _ n: Int, _ cutoff: Double) -> [Int] {
        var maxDistance = [Double](repeating: 0, count: n - 1)
        for (k, merge) in z.enumerated() {
            var m = merge.distance
            for child in [merge.a, merge.b] where child >= n { m = max(m, maxDistance[child - n]) }
            maxDistance[k] = m
        }
        var labels = [Int](repeating: 0, count: n)
        var visited = Set<Int>()
        var stack = [2 * n - 2]
        var count = 0
        var leader = -1
        while let top = stack.last {
            let root = top - n
            let left = z[root].a, right = z[root].b
            if leader == -1 && maxDistance[root] <= cutoff {  // found a cluster
                leader = root
                count += 1
            }
            if left >= n && !visited.contains(left) {
                visited.insert(left)
                stack.append(left)
                continue
            }
            if right >= n && !visited.contains(right) {
                visited.insert(right)
                stack.append(right)
                continue
            }
            if left < n {
                if leader == -1 { count += 1 }  // a cluster of one
                labels[left] = count
            }
            if right < n {
                if leader == -1 { count += 1 }
                labels[right] = count
            }
            if leader == root { leader = -1 }  // back at the cluster's top
            stack.removeLast()
        }
        return labels
    }
}
