// The text embedder of search by meaning (embeddings.py `Encoder`): multilingual-e5-small, an XLM-RoBERTa encoder
// stored as a BERT model, run on the CPU from the memory-mapped safetensors file, mean-pooled and L2-normalized, in
// Float32 throughout. The matrix products go through Accelerate's `cblas_sgemm` (the ILP64 entry point numpy calls);
// everything else follows numpy's
// order of operations (sums along the last axis in numpy's pairwise order, `NumpyReduce`).
// Downloading the model stays with Python (Task 61): `modelFolder` only finds it.
import Darwin
import Foundation
import os
import PalaverCore

public enum E5EncoderError: Error, CustomStringConvertible {
    case config(String)
    case shape(String)

    public var description: String {
        switch self {
        case .config(let m): return "e5: config.json: \(m)"
        case .shape(let m): return "e5: model.safetensors: \(m)"
        }
    }
}

public final class E5Encoder {
    public static let model = "intfloat/multilingual-e5-small"
    public static let revision = "614241f622f53c4eeff9890bdc4f31cfecc418b3"
    public static let modelFiles = ["config.json", "sentencepiece.bpe.model", "model.safetensors"]
    public static let MAX_TOKENS = 512
    /// A batch of 16 long pieces held ~2x the memory, no faster (embeddings.py).
    public static let BATCH = 8
    static let BOS = 0, EOS = 2, UNK = 3

    let heads: Int
    let layers: Int
    let eps: Float
    let pad: Int
    let firstPosition: Int
    public let maxTokens: Int
    /// Numbers per vector (the hidden size).
    public let dimension: Int
    public let prefixQuery: String
    public let prefixPassage: String
    let weights: Safetensors
    /// Tensor names without XLM-R's "roberta." prefix → the names in the file.
    private let names: [String: String]
    let pieces: SentencePiece

    public init(folder: URL, prefixQuery: String = "query: ", prefixPassage: String = "passage: ") throws {
        let configFile = folder.appendingPathComponent("config.json")
        let config: JSONValue
        do { config = try PythonJSON.parse(Data(contentsOf: configFile)) } catch {
            throw E5EncoderError.config("\(error)")
        }
        func int(_ key: String, _ fallback: Int? = nil) throws -> Int {
            switch config[key] {
            case .int(let n)?: return n
            case nil where fallback != nil: return fallback!
            default: throw E5EncoderError.config("\(key) is not an integer")
            }
        }
        heads = try int("num_attention_heads")
        layers = try int("num_hidden_layers")
        switch config["layer_norm_eps"] {
        case nil: eps = 1e-12
        case let v?: guard let d = v.doubleValue else { throw E5EncoderError.config("layer_norm_eps is no number") }
            eps = Float(d)
        }
        pad = try int("pad_token_id", 1)
        let type = config["model_type"]?.stringValue
        firstPosition = type == "xlm-roberta" || type == "roberta" ? pad + 1 : 0
        let (limit, overflow) = try int("max_position_embeddings").subtractingReportingOverflow(firstPosition)
        maxTokens = min(Self.MAX_TOKENS, overflow ? Int.min : limit)
        guard heads > 0, layers >= 0, maxTokens >= 2, pad >= 0 else {
            throw E5EncoderError.config("heads, layers, positions or pad_token_id out of range")
        }
        weights = try Safetensors(url: folder.appendingPathComponent("model.safetensors"))
        var names: [String: String] = [:]
        for name in weights.names {
            names[name.hasPrefix("roberta.") ? String(name.dropFirst("roberta.".count)) : name] = name
        }
        self.names = names
        let words = try Self.tensor(weights, names, "embeddings.word_embeddings.weight")
        guard words.shape.count == 2, words.shape[1] > 0, words.shape[1] % heads == 0 else {
            throw E5EncoderError.shape("word embeddings of shape \(words.shape) for \(heads) heads")
        }
        dimension = words.shape[1]
        pieces = try SentencePiece(modelFile: folder.appendingPathComponent("sentencepiece.bpe.model"))
        self.prefixQuery = prefixQuery
        self.prefixPassage = prefixPassage
    }

    private static func tensor(_ weights: Safetensors, _ names: [String: String], _ name: String) throws -> SafeTensor {
        try weights.tensor(names[name] ?? name)
    }

    private func w(_ name: String) throws -> SafeTensor { try Self.tensor(weights, names, name) }

    /// The snapshot folder of `intfloat/multilingual-e5-small` at the pinned revision in the Hugging Face cache, when
    /// its three files are there (`model_folder(download=False)`); nil otherwise. It never downloads.
    public static func modelFolder(stores: StorePaths = .current()) -> URL? {
        let snapshot = ModelCatalog.cacheDir(model, stores: stores)
            .appendingPathComponent("snapshots", isDirectory: true).appendingPathComponent(revision, isDirectory: true)
        for file in modelFiles {
            var st = stat()
            guard stat(snapshot.appendingPathComponent(file).path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        }
        return snapshot
    }

    /// One query's vector: the query prefix in front.
    public func query(_ text: String) throws -> [Float] {
        try encode([prefixQuery + text])[0]
    }

    /// One vector per text (the passage prefix in front), in the texts' order; encoded in batches of `BATCH` of
    /// similar length (by characters), so little padding.
    public func passages(_ texts: [String]) throws -> [[Float]] {
        let texts = texts.map { prefixPassage + $0 }
        var out = [[Float]](repeating: [], count: texts.count)
        let lengths = texts.map { $0.unicodeScalars.count }
        let order = Py.stableSorted(Array(texts.indices)) { lengths[$0] < lengths[$1] }
        var at = 0
        while at < order.count {
            let rows = Array(order[at ..< min(at + Self.BATCH, order.count)])
            for (row, vector) in zip(rows, try encode(rows.map { texts[$0] })) { out[row] = vector }
            at += Self.BATCH
        }
        return out
    }

    /// XLM-R's ids: <s> pieces </s>, the SentencePiece ids one up (fairseq's order puts <s> <pad> </s> <unk>
    /// first), its unknown (0) → 3; at most `maxTokens` in all.
    public func ids(_ text: String) -> [Int] {
        let encoded = pieces.encode(text).prefix(maxTokens - 2)
        return [Self.BOS] + encoded.map { $0 != 0 ? $0 + 1 : Self.UNK } + [Self.EOS]
    }

    // MARK: - The forward pass

    func encode(_ texts: [String]) throws -> [[Float]] {
        let encoded = texts.map(ids)
        let batch = encoded.count
        guard batch > 0 else { return [] }
        let width = encoded.map(\.count).max() ?? 0
        let hidden = dimension, size = hidden / heads, rows = batch * width
        var mask = [Float](repeating: 0, count: rows)
        for (b, e) in encoded.enumerated() { for t in 0..<e.count { mask[b * width + t] = 1 } }

        // Embeddings: word + position + token type 0.
        let words = try w("embeddings.word_embeddings.weight")
        let positions = try w("embeddings.position_embeddings.weight")
        let types = try w("embeddings.token_type_embeddings.weight")
        guard positions.shape.count == 2, positions.shape[1] == hidden, types.shape.count == 2, types.shape[1] == hidden else {
            throw E5EncoderError.shape("position or token type embeddings are not [n, \(hidden)]")
        }
        let typeRow = try types.row(0)
        var x = [Float](repeating: 0, count: rows * hidden)
        try positions.withFloat32 { pos in
            for b in 0..<batch {
                for t in 0..<width {
                    let valid = t < encoded[b].count
                    let id = valid ? encoded[b][t] : pad
                    let p = valid ? t + firstPosition : pad
                    guard p < positions.shape[0] else { throw E5EncoderError.shape("no position \(p)") }
                    let word = try words.row(id)
                    let at = (b * width + t) * hidden
                    for j in 0..<hidden { x[at + j] = word[j] + pos[p * hidden + j] + typeRow[j] }
                }
            }
        }
        try layerNorm(&x, rows: rows, hidden: hidden, "embeddings.LayerNorm")

        // (1 - mask) * -1e9 on the keys.
        let blocked = mask.map { (1 - $0) * Float(-1e9) }
        let scale = Float(Double(size).squareRoot())
        let root2 = Float(2.0.squareRoot())
        for n in 0..<layers {
            let p = "encoder.layer.\(n)."
            let q = try dense(x, rows: rows, p + "attention.self.query")
            let k = try dense(x, rows: rows, p + "attention.self.key")
            let v = try dense(x, rows: rows, p + "attention.self.value")
            var context = [Float](repeating: 0, count: rows * hidden)
            var scores = [Float](repeating: 0, count: width * width)
            for b in 0..<batch {
                for h in 0..<heads {
                    let at = b * width * hidden + h * size
                    q.withUnsafeBufferPointer { qp in
                        k.withUnsafeBufferPointer { kp in
                            scores.withUnsafeMutableBufferPointer { sp in
                                Blas.sgemm(m: width, n: width, k: size, qp.baseAddress! + at, lda: hidden,
                                           kp.baseAddress! + at, ldb: hidden, transposeB: true, sp.baseAddress!, ldc: width)
                            }
                        }
                    }
                    for i in 0..<width {
                        let row = i * width
                        var top = -Float.infinity
                        for j in 0..<width {
                            let s = scores[row + j] / scale + blocked[b * width + j]
                            scores[row + j] = s
                            if s > top { top = s }
                        }
                        for j in 0..<width { scores[row + j] = expf(scores[row + j] - top) }
                        let total = scores.withUnsafeBufferPointer { s in NumpyReduce.pairwiseSum(from: row, count: width) { s[$0] } }
                        for j in 0..<width { scores[row + j] /= total }
                    }
                    scores.withUnsafeBufferPointer { sp in
                        v.withUnsafeBufferPointer { vp in
                            context.withUnsafeMutableBufferPointer { cp in
                                Blas.sgemm(m: width, n: size, k: width, sp.baseAddress!, lda: width,
                                           vp.baseAddress! + at, ldb: hidden, transposeB: false, cp.baseAddress! + at, ldc: hidden)
                            }
                        }
                    }
                }
            }
            let attended = try dense(context, rows: rows, p + "attention.output.dense")
            for i in x.indices { x[i] = x[i] + attended[i] }
            try layerNorm(&x, rows: rows, hidden: hidden, p + "attention.output.LayerNorm")
            var inner = try dense(x, rows: rows, p + "intermediate.dense")
            for i in inner.indices {
                let u = inner[i]
                inner[i] = Float(0.5) * u * (1 + Float(erf(Double(u / root2))))
            }
            let out = try dense(inner, rows: rows, p + "output.dense")
            for i in x.indices { x[i] = x[i] + out[i] }
            try layerNorm(&x, rows: rows, hidden: hidden, p + "output.LayerNorm")
        }

        // Mean pooling over the real tokens, then the L2 norm.
        var vectors: [[Float]] = []
        for b in 0..<batch {
            var pooled = [Float](repeating: 0, count: hidden)
            for t in 0..<width {
                let m = mask[b * width + t], at = (b * width + t) * hidden
                for j in 0..<hidden { pooled[j] += x[at + j] * m }
            }
            let count = mask.withUnsafeBufferPointer { m in NumpyReduce.pairwiseSum(from: b * width, count: width) { m[$0] } }
            for j in 0..<hidden { pooled[j] /= count }
            let norm = pooled.withUnsafeBufferPointer { NumpyReduce.sumOfSquares($0, from: 0, count: hidden) }.squareRoot()
            vectors.append(pooled.map { $0 / norm })
        }
        return vectors
    }

    /// `v @ W.T + b` for the `rows` rows of `input`, W of shape [out, in].
    private func dense(_ input: [Float], rows: Int, _ name: String) throws -> [Float] {
        let weight = try w(name + ".weight"), bias = try w(name + ".bias")
        guard weight.shape.count == 2, rows > 0, input.count % rows == 0, weight.shape[1] == input.count / rows,
              bias.shape == [weight.shape[0]] else {
            throw E5EncoderError.shape("\(name) has shape \(weight.shape) and bias \(bias.shape) for inputs of \(input.count / max(rows, 1))")
        }
        let outs = weight.shape[0], ins = weight.shape[1]
        var out = [Float](repeating: 0, count: rows * outs)
        try weight.withFloat32 { wp in
            input.withUnsafeBufferPointer { ip in
                out.withUnsafeMutableBufferPointer { op in
                    Blas.sgemm(m: rows, n: outs, k: ins, ip.baseAddress!, lda: ins, wp.baseAddress!, ldb: ins, transposeB: true,
                               op.baseAddress!, ldc: outs)
                }
            }
        }
        try bias.withFloat32 { bp in
            for r in 0..<rows { for j in 0..<outs { out[r * outs + j] += bp[j] } }
        }
        return out
    }

    /// `(x - mean) / sqrt(var + eps) * weight + bias` over each row of `hidden` numbers.
    private func layerNorm(_ x: inout [Float], rows: Int, hidden: Int, _ name: String) throws {
        let weight = try w(name + ".weight"), bias = try w(name + ".bias")
        guard weight.shape == [hidden], bias.shape == [hidden] else {
            throw E5EncoderError.shape("\(name) is not [\(hidden)]")
        }
        let n = Float(hidden)
        var centered = [Float](repeating: 0, count: hidden)
        try weight.withFloat32 { wp in
            try bias.withFloat32 { bp in
                for r in 0..<rows {
                    let at = r * hidden
                    let mean = x.withUnsafeBufferPointer { v in NumpyReduce.pairwiseSum(from: at, count: hidden) { v[$0] } } / n
                    for j in 0..<hidden { centered[j] = x[at + j] - mean }
                    let variance = centered.withUnsafeBufferPointer { NumpyReduce.sumOfSquares($0, from: 0, count: hidden) } / n
                    let deviation = (variance + eps).squareRoot()
                    for j in 0..<hidden { x[at + j] = centered[j] / deviation * wp[j] + bp[j] }
                }
            }
        }
    }
}

/// Accelerate's single-precision matrix product, through the ILP64 entry point numpy links
/// (`cblas_sgemm$NEWLAPACK$ILP64`), found by name as `VoiceMath` finds `cblas_ddot`: Swift's own `cblas_sgemm` is the
/// deprecated LP64 one.
enum Blas {
    private typealias SGemm = @convention(c) (Int32, Int32, Int32, Int, Int, Int, Float, UnsafePointer<Float>?, Int,
                                              UnsafePointer<Float>?, Int, Float, UnsafeMutablePointer<Float>?, Int) -> Void
    private static let rowMajor: Int32 = 101, noTrans: Int32 = 111, trans: Int32 = 112

    private static let entry: SGemm? = {
        guard let lib = dlopen("/System/Library/Frameworks/Accelerate.framework/Accelerate", RTLD_NOW),
              let symbol = dlsym(lib, "cblas_sgemm$NEWLAPACK$ILP64") else { return nil }
        return unsafeBitCast(symbol, to: SGemm.self)
    }()

    static var isAccelerate: Bool { entry != nil }

    private static let log = Logger(subsystem: "com.kenodressel.palaver", category: "blas")
    private static let saidLock = NSLock()
    nonisolated(unsafe) private static var said: Set<String> = []

    /// Says once per entry point, in the log (Console: com.kenodressel.palaver/blas), that its plain-loop fallback runs; true
    /// the first time. Never on macOS 15, where Accelerate has them all.
    @discardableResult
    static func fellBack(_ symbol: String) -> Bool {
        let first = saidLock.withLock { said.insert(symbol).inserted }
        if first {
            log.error("Accelerate's \(symbol, privacy: .public) is missing: plain loops instead (slower; sums no longer numpy's to the bit)")
        }
        return first
    }

    /// `C = A · B` (`transposeB`: `A · Bᵀ`), row-major: A is m×k (row stride `lda`), B k×n or, transposed, n×k (`ldb`),
    /// C m×n (`ldc`), overwritten.
    static func sgemm(m: Int, n: Int, k: Int, _ a: UnsafePointer<Float>, lda: Int, _ b: UnsafePointer<Float>, ldb: Int,
                      transposeB: Bool, _ c: UnsafeMutablePointer<Float>, ldc: Int) {
        if let entry {
            entry(rowMajor, noTrans, transposeB ? trans : noTrans, m, n, k, 1, a, lda, b, ldb, 0, c, ldc)
            return
        }
        // Never on macOS 15: Accelerate has the symbol.
        fellBack("cblas_sgemm$NEWLAPACK$ILP64")
        assertionFailure("E5Encoder: Accelerate's cblas_sgemm$NEWLAPACK$ILP64 is missing")
        for i in 0..<m {
            for j in 0..<n {
                var s: Float = 0
                for p in 0..<k { s += a[i * lda + p] * (transposeB ? b[j * ldb + p] : b[p * ldb + j]) }
                c[i * ldc + j] = s
            }
        }
    }
}
