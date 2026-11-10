// The searcher by meaning (semantic.py:234-350): embeds a search's words and compares them with the meetings' stored
// vectors. The model is loaded at the first search and let go `idleSeconds` after the last one; the indexes are read
// once per change of their `.sig`. Scores are numpy's to the bit: the float16 rows as float32, `matrix @ vector`
// through the BLAS call numpy makes, the floor compared in float32 (NEP 50), the order numpy's `argsort`.
import Darwin
import Foundation
import os
import PalaverCore

public final class Searcher {
    /// Makes the encoder; nil when the model is not on this Mac.
    public typealias Factory = () throws -> MeaningEncoder?
    /// Runs the second argument after the first's seconds (Python's `threading.Timer`).
    public typealias Timer = (Double, @escaping () -> Void) -> Void

    private struct Index {
        let built: Int
        let pieces: [JSONValue]
        let matrix: Npy.Matrix
    }

    private let outputDir: URL
    private let factory: Factory
    private let idle: Double
    private let clock: () -> Double
    private let timer: Timer?
    private let model: String
    private var encoder: MeaningEncoder?
    private var used = 0.0
    private var armed = false
    private let lock = NSLock()
    private var indexes: [ScalarKey: Index] = [:]
    private var queries: [ScalarKey: [Float]] = [:]
    private static let log = Logger(subsystem: "com.kenodressel.palaver", category: "semantic")

    /// `encoderFactory`: the e5 model where it is cached (never downloaded) by default. `clock`: monotonic seconds.
    /// `timer`: how the release is scheduled (a dispatch after the delay plus a second by default; nil: never, a test
    /// calls `release()`).
    public init(outputDir: URL, encoderFactory: Factory? = nil, idleSeconds: Double = SearchIndex.IDLE_SECONDS,
                clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
                timer: Timer? = Searcher.dispatchTimer, model: String = SearchIndex.model) {
        self.outputDir = outputDir
        self.factory = encoderFactory ?? { try E5Encoder.modelFolder().map { try E5Encoder(folder: $0) } }
        self.idle = idleSeconds
        self.clock = clock
        self.timer = timer
        self.model = model
    }

    public static let dispatchTimer: Timer = { delay, run in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay + 1.0, execute: run)
    }

    /// Whether the model is in memory.
    public var loaded: Bool { lock.withLock { encoder != nil } }

    /// How many meetings' indexes are kept in memory.
    var cachedIndexes: Int { lock.withLock { indexes.count } }

    /// Lets the model and the indexes go when unused for `idleSeconds` (`release_if_idle`); used since: looks again
    /// that long after the last use.
    public func release() {
        let later: Double? = lock.withLock {
            armed = false
            if encoder == nil && indexes.isEmpty { return nil }
            let left = idle - (clock() - used)
            if left > 0 { return arm(left) }
            encoder = nil
            indexes.removeAll()
            queries.removeAll()
            Self.log.info("search by meaning: model let go after \(Int(self.idle.rounded()), privacy: .public) s idle")
            return nil
        }
        schedule(later)
    }

    /// One timer at a time (called with the lock held): the delay to schedule once the lock is let go, nil when one is
    /// armed already or there is no timer.
    private func arm(_ delay: Double) -> Double? {
        guard !armed, timer != nil else { return nil }
        armed = true
        return delay
    }

    /// Starts the timer `arm` asked for, outside the lock: a timer may run its release at once.
    private func schedule(_ delay: Double?) {
        guard let delay, let timer else { return }
        timer(delay) { [weak self] in self?.release() }
    }

    private func index(_ paths: RecordingPaths) -> Index? {
        guard SearchIndex.isCurrent(paths, model: model) else { return nil }
        var st = stat()
        guard stat(paths.folder.appendingPathComponent(SearchIndex.INDEX_SIG).path, &st) == 0 else { return nil }
        // A time beyond Int's nanoseconds (year 2262+) is never cached: the index is read again each time.
        let stamp = FileTimes.mtimeNs(st)
        let built = stamp ?? Int.min
        let key = ScalarKey(paths.folder.path)
        if let stamp, let cached = indexes[key], cached.built == stamp { return cached }
        guard let meta = PythonJSON.read(paths.folder.appendingPathComponent(SearchIndex.INDEX_JSON)),
              let data = try? Data(contentsOf: paths.folder.appendingPathComponent(SearchIndex.INDEX_NPY)),
              let matrix = try? Npy.read(data),
              PythonJSON.equal(meta["model"] ?? .null, .string(model)),
              let pieces = (meta["chunks"] ?? .array([])).arrayValue, pieces.count == matrix.rows,
              pieces.allSatisfy({ if case .object = $0 { return true } else { return false } })
        else { return nil }
        let index = Index(built: built, pieces: pieces, matrix: matrix)
        indexes[key] = index
        return index
    }

    private func query(_ text: String, later: inout Double?) throws -> [Float]? {
        if encoder == nil {
            encoder = try factory()
            if encoder == nil { return nil }
        }
        used = clock()
        later = arm(idle)
        let key = ScalarKey(text)
        if let vector = queries[key] { return vector }
        if queries.count > 64 { queries.removeAll() }
        let vector = try encoder!.query(text)
        queries[key] = vector
        return vector
    }

    /// Meeting id → its best pieces about `text` (scored over `SearchIndex.floor`), best first, each with its
    /// `score` (3 places). `meetings`: these (the recording folders of the output dir by default). `kinds`: only
    /// these pieces; `speaker(paths, label)`: only lines of the speakers it accepts.
    public func search(_ text: String, in meetings: [RecordingPaths]? = nil, kinds: [String]? = nil,
                       speaker: ((RecordingPaths, String) -> Bool)? = nil) throws -> PyDict<[JSONValue]> {
        let text = Py.strip(text)
        if text.isEmpty { return PyDict() }
        let meetings = meetings ?? SearchIndex.meetings(outputDir)
        let found: [(RecordingPaths, Index)]
        let vector: [Float]
        var later: Double?
        defer { schedule(later) }
        lock.lock()
        do {
            defer { lock.unlock() }
            found = meetings.compactMap { p in index(p).map { (p, $0) } }
            if found.isEmpty { return PyDict() }
            guard let v = try query(text, later: &later) else {  // no model on this Mac: keep nothing
                indexes.removeAll()
                return PyDict()
            }
            vector = v
        }
        let scored = try found.map { ($0.0, $0.1.pieces, try Self.scores($0.1.matrix, vector)) }
        let lowest = Float(SearchIndex.floor(scored.flatMap(\.2)))
        var out = PyDict<[JSONValue]>()
        for (paths, pieces, scores) in scored {
            var hits: [JSONValue] = []
            for i in Self.argsort(scores.map { -$0 }) {
                if scores[i] < lowest || hits.count >= SearchIndex.HITS_PER_MEETING { break }
                let piece = pieces[i]
                let kind = piece["kind"]?.stringValue
                if let kinds, !kinds.contains(where: { k in kind.map { Py.same($0, k) } ?? false }) { continue }
                if let speaker {
                    guard let kind, Py.same(kind, "line"), let label = piece["speaker"]?.stringValue,
                          speaker(paths, label) else { continue }
                }
                var hit = PyDict<JSONValue>(piece) ?? PyDict()
                hit["score"] = .double(Py.round(Double(scores[i]), 3))
                hits.append(hit.json)
            }
            if !hits.isEmpty { out[paths.folder.lastPathComponent] = hits }
        }
        return out
    }

    // MARK: - numpy's arithmetic

    /// `matrix @ vector` as numpy computes it for a float32 matrix and vector: `cblas_sdot` for one row, a plain
    /// product for one column, `cblas_sgemv` (column-major, transposed, as matmul.c.src calls it) otherwise.
    static func scores(_ m: Npy.Matrix, _ v: [Float]) throws -> [Float] {
        guard m.columns == v.count else {
            throw SearchIndexError(description: "matmul: Input operand 1 has a mismatch in its core dimension 0 (size \(v.count) is different from \(m.columns))")
        }
        if m.rows == 0 { return [] }
        if m.columns == 0 { return [Float](repeating: 0, count: m.rows) }
        if m.rows == 1 { return [Blas.sdot(m.values, v)] }
        if m.columns == 1 { return m.values.map { 0 + $0 * v[0] } }
        return Blas.sgemv(rows: m.rows, columns: m.columns, m.values, v)
    }

    /// `np.argsort(keys)` (kind "quicksort" on float32): numpy's introsort on indices, median of three, insertion sort
    /// under 17, heapsort past twice the depth; NaN last. Ties come out in numpy's order, not by index.
    static func argsort(_ v: [Float]) -> [Int] {
        func less(_ a: Float, _ b: Float) -> Bool { a < b || (b != b && a == a) }
        var t = Array(v.indices)
        let num = t.count
        if num <= 1 { return t }
        var pl = 0, pr = num - 1
        var stack: [(Int, Int, Int)] = []
        var depth = (Int.bitWidth - 1 - num.leadingZeroBitCount) * 2
        while true {
            if depth < 0 {
                heapsort(v, &t, from: pl, count: pr - pl + 1, less)
            } else {
                while pr - pl > 15 {
                    let pm = pl + ((pr - pl) >> 1)
                    if less(v[t[pm]], v[t[pl]]) { t.swapAt(pm, pl) }
                    if less(v[t[pr]], v[t[pm]]) { t.swapAt(pr, pm) }
                    if less(v[t[pm]], v[t[pl]]) { t.swapAt(pm, pl) }
                    let vp = v[t[pm]]
                    var pi = pl, pj = pr - 1
                    t.swapAt(pm, pj)
                    while true {
                        repeat { pi += 1 } while less(v[t[pi]], vp)
                        repeat { pj -= 1 } while less(vp, v[t[pj]])
                        if pi >= pj { break }
                        t.swapAt(pi, pj)
                    }
                    t.swapAt(pi, pr - 1)
                    depth -= 1
                    if pi - pl < pr - pi {
                        stack.append((pi + 1, pr, depth))
                        pr = pi - 1
                    } else {
                        stack.append((pl, pi - 1, depth))
                        pl = pi + 1
                    }
                }
                var pi = pl + 1
                while pi <= pr {
                    let vi = t[pi], vp = v[vi]
                    var pj = pi
                    while pj > pl && less(vp, v[t[pj - 1]]) {
                        t[pj] = t[pj - 1]
                        pj -= 1
                    }
                    t[pj] = vi
                    pi += 1
                }
            }
            guard let next = stack.popLast() else { break }
            (pl, pr, depth) = next
        }
        return t
    }

    /// numpy's `aheapsort` on `t[from ..< from + count]`.
    private static func heapsort(_ v: [Float], _ t: inout [Int], from: Int, count: Int, _ less: (Float, Float) -> Bool) {
        var n = count
        func get(_ k: Int) -> Int { t[from + k - 1] }
        func set(_ k: Int, _ x: Int) { t[from + k - 1] = x }
        func sift(_ start: Int, _ tmp: Int) {
            var i = start, j = start << 1
            while j <= n {
                if j < n && less(v[get(j)], v[get(j + 1)]) { j += 1 }
                if less(v[tmp], v[get(j)]) {
                    set(i, get(j))
                    i = j
                    j += j
                } else { break }
            }
            set(i, tmp)
        }
        var l = n >> 1
        while l > 0 {
            sift(l, get(l))
            l -= 1
        }
        while n > 1 {
            let tmp = get(n)
            set(n, get(1))
            n -= 1
            sift(1, tmp)
        }
    }
}

extension Blas {
    private typealias SGemv = @convention(c) (Int32, Int32, Int, Int, Float, UnsafePointer<Float>?, Int,
                                              UnsafePointer<Float>?, Int, Float, UnsafeMutablePointer<Float>?, Int) -> Void
    private typealias SDot = @convention(c) (Int, UnsafePointer<Float>?, Int, UnsafePointer<Float>?, Int) -> Float

    private static let accelerate = dlopen("/System/Library/Frameworks/Accelerate.framework/Accelerate", RTLD_NOW)
    private static let gemv: SGemv? = accelerate.flatMap { dlsym($0, "cblas_sgemv$NEWLAPACK$ILP64") }
        .map { unsafeBitCast($0, to: SGemv.self) }
    private static let dot: SDot? = accelerate.flatMap { dlsym($0, "cblas_sdot$NEWLAPACK$ILP64") }
        .map { unsafeBitCast($0, to: SDot.self) }

    /// numpy's `FLOAT_dot` for contiguous vectors: `cblas_sdot`, added to a double, back to float32.
    static func sdot(_ a: [Float], _ b: [Float]) -> Float {
        guard let dot else {
            fellBack("cblas_sdot$NEWLAPACK$ILP64")
            assertionFailure("Blas: Accelerate's cblas_sdot$NEWLAPACK$ILP64 is missing")
            return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let sum = a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in dot(a.count, pa.baseAddress, 1, pb.baseAddress, 1) } }
        return Float(0 + Double(sum))
    }

    /// numpy's `FLOAT_gemv` for a C-ordered `rows` × `columns` matrix times a vector:
    /// `cblas_sgemv(ColMajor, Trans, columns, rows, 1, A, columns, x, 1, 0, y, 1)`.
    static func sgemv(rows: Int, columns: Int, _ a: [Float], _ x: [Float]) -> [Float] {
        var y = [Float](repeating: 0, count: rows)
        guard let gemv else {
            fellBack("cblas_sgemv$NEWLAPACK$ILP64")
            assertionFailure("Blas: Accelerate's cblas_sgemv$NEWLAPACK$ILP64 is missing")
            for r in 0..<rows { y[r] = (0..<columns).reduce(0) { $0 + a[r * columns + $1] * x[$1] } }
            return y
        }
        a.withUnsafeBufferPointer { pa in
            x.withUnsafeBufferPointer { px in
                y.withUnsafeMutableBufferPointer { py in
                    gemv(102, 112, columns, rows, 1, pa.baseAddress, columns, px.baseAddress, 1, 0, py.baseAddress, 1)
                }
            }
        }
        return y
    }
}
