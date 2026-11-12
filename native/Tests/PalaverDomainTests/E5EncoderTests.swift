// The e5 encoder and its safetensors reader: against transformers' vectors and the reference tokenizer's ids, F16 rows
// converted one at a time, and broken safetensors files that throw, never trap.
import Foundation
import PalaverCore
@testable import PalaverDomain
import Testing

@Suite struct E5EncoderTests {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // native/Tests/PalaverDomainTests
        .appendingPathComponent("../../..").standardizedFileURL

    private static func fixture(_ kind: String) -> URL {
        repo.appendingPathComponent("tests/fixtures/tiny_embedder/\(kind)", isDirectory: true)
    }

    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("e5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `_tiny_model`: the golden tiny model of `kind` copied into `folder`; its reference texts and embeddings.
    private static func tinyModel(_ folder: URL, _ kind: String = "xlm-roberta") throws -> (texts: [String], want: [[Float]]) {
        for name in E5Encoder.modelFiles {
            try FileManager.default.copyItem(at: fixture(kind).appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
        let reference = try #require(PythonJSON.read(fixture(kind).appendingPathComponent("expected.json")))
        let texts = try #require(reference["texts"]?.arrayValue).map { try #require($0.stringValue) }
        let want = try #require(reference["embeddings"]?.arrayValue).map { row in
            try #require(row.arrayValue).map { Float(try #require($0.doubleValue)) }
        }
        return (texts, want)
    }

    private static func maxDifference(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .infinity }
        return zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    private static func norm(_ v: [Float]) -> Float { v.map { $0 * $0 }.reduce(0, +).squareRoot() }

    // MARK: - tests/test_embeddings.py

    @Test(arguments: ["xlm-roberta", "bert"])
    func test_the_encoder_matches_transformers(kind: String) throws {
        let folder = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (texts, want) = try Self.tinyModel(folder, kind)

        let encoder = try E5Encoder(folder: folder, prefixQuery: "", prefixPassage: "")
        let got = try encoder.passages(texts)  // one padded batch: padding must not change anything
        #expect(got.count == 3 && got.allSatisfy { $0.count == 32 })
        for (g, w) in zip(got, want) {
            #expect(Self.maxDifference(g, w) < 1e-4)
            #expect(abs(Self.norm(g) - 1) < 1e-5)
        }
        #expect(Self.maxDifference(try encoder.query("hello world"), want[0]) < 1e-4)
    }

    @Test func test_the_encoder_maps_its_weights_instead_of_reading_them() throws {
        let folder = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try Self.tinyModel(folder)
        let weights = try Safetensors(url: folder.appendingPathComponent("model.safetensors"))
        #expect(!weights.names.isEmpty)
        for name in weights.names {
            let tensor = try weights.tensor(name)
            // The F32 numbers are read where the file's bytes are mapped: no copy is made or kept.
            let inMap = try tensor.withFloat32 { floats in
                tensor.map.data.withUnsafeBytes { all in
                    UnsafeRawPointer(floats.baseAddress!) == all.baseAddress! + tensor.offset
                }
            }
            #expect(inMap, "\(name)")
            #expect(!tensor.isConverted)
        }
    }

    @Test func test_prefixes_go_in_front_of_queries_and_passages() throws {
        let folder = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try Self.tinyModel(folder)
        let encoder = try E5Encoder(folder: folder, prefixQuery: "hello ", prefixPassage: "world ")
        let plain = try E5Encoder(folder: folder, prefixQuery: "", prefixPassage: "")
        #expect(Self.maxDifference(try encoder.query("cost"), try plain.query("hello cost")) < 1e-6)
        #expect(Self.maxDifference(try encoder.passages(["cost"])[0], try plain.passages(["world cost"])[0]) < 1e-6)
    }

    @Test func test_the_model_files_are_found_only_where_they_are() throws {
        let home = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let stores = StorePaths(configDir: home.appendingPathComponent("config", isDirectory: true), home: home)
        #expect(E5Encoder.modelFolder(stores: stores) == nil)  // nothing cached

        let repo = stores.hubCache.appendingPathComponent("models--intfloat--multilingual-e5-small", isDirectory: true)
        let blobs = repo.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        func snapshot(_ revision: String, _ files: [String]) throws -> URL {
            let dir = repo.appendingPathComponent("snapshots/\(revision)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in files {  // as huggingface_hub lays them out: links into blobs/
                let blob = blobs.appendingPathComponent("\(revision)-\(file)")
                try Data("x".utf8).write(to: blob)
                try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent(file).path,
                                                           withDestinationPath: "../../blobs/\(blob.lastPathComponent)")
            }
            return dir
        }
        _ = try snapshot("0000000000000000000000000000000000000000", E5Encoder.modelFiles)  // another revision
        #expect(E5Encoder.modelFolder(stores: stores) == nil)
        let pinned = try snapshot(E5Encoder.revision, ["config.json", "sentencepiece.bpe.model"])  // one file missing
        #expect(E5Encoder.modelFolder(stores: stores) == nil)
        try FileManager.default.createSymbolicLink(atPath: pinned.appendingPathComponent("model.safetensors").path,
                                                   withDestinationPath: "../../blobs/gone")  // a link whose blob is gone
        #expect(E5Encoder.modelFolder(stores: stores) == nil)
        try FileManager.default.removeItem(at: pinned.appendingPathComponent("model.safetensors"))
        try Data("x".utf8).write(to: blobs.appendingPathComponent("weights"))
        try FileManager.default.createSymbolicLink(atPath: pinned.appendingPathComponent("model.safetensors").path,
                                                   withDestinationPath: "../../blobs/weights")
        #expect(E5Encoder.modelFolder(stores: stores)?.standardizedFileURL == pinned.standardizedFileURL)
        #expect(E5Encoder.model == "intfloat/multilingual-e5-small")
        #expect(E5Encoder.revision == "614241f622f53c4eeff9890bdc4f31cfecc418b3")  // the pinned model, every time
    }

    @Test func test_the_encoder_stays_in_float32() throws {
        // Float32 by type; and a float16 model is computed in Float32 too (converted on load), close to its float32
        // original.
        let folder = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try Self.tinyModel(folder)
        let encoder = try E5Encoder(folder: folder)
        let vectors: [[Float]] = try encoder.passages(["hello world", "cost"])
        let query: [Float] = try encoder.query("cost")
        #expect(vectors.count == 2 && query.count == encoder.dimension)

        #if arch(arm64)
        let half = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: half) }
        for name in ["config.json", "sentencepiece.bpe.model"] {
            try FileManager.default.copyItem(at: folder.appendingPathComponent(name), to: half.appendingPathComponent(name))
        }
        let weights = try Safetensors(url: folder.appendingPathComponent("model.safetensors"))
        let tensors = try weights.names.map { name -> (String, String, [Int], [UInt8]) in
            let t = try weights.tensor(name)
            let bytes = try t.withFloat32 { floats in floats.flatMap { f -> [UInt8] in
                let bits = Float16(f).bitPattern
                return [UInt8(bits & 0xff), UInt8(bits >> 8)]
            } }
            return (name, "F16", t.shape, bytes)
        }
        try Self.writeSafetensors(half.appendingPathComponent("model.safetensors"), tensors)
        let halved = try E5Encoder(folder: half).passages(["hello world", "cost"])
        for (h, f) in zip(halved, vectors) { #expect(Self.maxDifference(h, f) < 0.05) }
        #endif
    }

    @Test(.enabled(if: E5EncoderTests.realModel != nil, "multilingual-e5-small is not downloaded"))
    func test_the_ids_are_the_ones_xlm_r_s_own_tokenizer_gives() throws {
        // On the real vocabulary (read where it is in the Hugging Face cache, never downloaded for a test);
        // transformers' XLMRobertaTokenizer gave the golden ids.
        let real = try #require(Goldens.load("e5_tiny")["real"], "goldens.py e5_tiny ran without the model")
        let ours = try E5Encoder(folder: try #require(Self.realModel))
        let texts = try #require(real["texts"]?.arrayValue).map { try #require($0.stringValue) }
        let want = try #require(real["ids"]?.arrayValue)
        #expect(texts.count == want.count && texts.count == 8)
        for (text, ids) in zip(texts, want) {
            #expect(PythonJSON.dumps(.array(ours.ids(text).map { .int($0) })) == PythonJSON.dumps(ids), "\(text.prefix(40))")
        }
    }

    /// The real model in the user's Hugging Face cache (HF_HUB_CACHE, HF_HOME/hub, else the real home's), read only.
    static let realModel: URL? = {
        let env = ProcessInfo.processInfo.environment
        var hub: URL
        if let h = env["HF_HUB_CACHE"], !h.isEmpty { hub = URL(fileURLWithPath: h, isDirectory: true) }
        else if let h = env["HF_HOME"], !h.isEmpty { hub = URL(fileURLWithPath: h, isDirectory: true).appendingPathComponent("hub") }
        else {
            guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
            hub = URL(fileURLWithPath: String(cString: dir), isDirectory: true).appendingPathComponent(".cache/huggingface/hub")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("e5-real-\(getpid())", isDirectory: true)
        return E5Encoder.modelFolder(stores: StorePaths(configDir: scratch.appendingPathComponent("config"), home: scratch, hubCache: hub))
    }()

    // MARK: - The Python encoder's own vectors

    /// A fallback loop is said in the log once per entry point, not at every call.
    @Test func aBlasFallbackIsSaidOnce() {
        let name = "cblas_test_only_\(UUID().uuidString)"
        #expect(Blas.fellBack(name))
        #expect(!Blas.fellBack(name))
    }

    // MARK: - Safetensors

    /// A safetensors file of `tensors` (name, dtype, shape, bytes), the header padded to 8 bytes as the writer does.
    static func writeSafetensors(_ url: URL, _ tensors: [(String, String, [Int], [UInt8])], header override: String? = nil) throws {
        var at = 0
        var fields: [(String, JSONValue)] = [("__metadata__", .object([("format", .string("pt"))]))]
        for (name, dtype, shape, bytes) in tensors {
            fields.append((name, .object([("dtype", .string(dtype)), ("shape", .array(shape.map { .int($0) })),
                                          ("data_offsets", .array([.int(at), .int(at + bytes.count)]))])))
            at += bytes.count
        }
        var header = Array((override ?? PythonJSON.dumps(.object(fields))).utf8)
        while header.count % 8 != 0 { header.append(0x20) }
        var out = (0..<8).map { UInt8(truncatingIfNeeded: UInt64(header.count) >> (8 * UInt64($0))) }
        out += header
        for (_, _, _, bytes) in tensors { out += bytes }
        try Data(out).write(to: url)
    }

    private static func halfBytes(_ values: [UInt16]) -> [UInt8] { values.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] } }

    @Test func test_float16_rows_are_converted_one_by_one() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("model.safetensors")
        // 5 rows of 3 halves: row r holds r, r + 0.5, -(r) (exact in half precision); 1.0 is 0x3c00.
        func half(_ x: Float) -> UInt16 {
            let bits = x.bitPattern
            if x == 0 { return UInt16(bits >> 16) & 0x8000 }
            return UInt16(bits >> 16) & 0x8000 | UInt16((Int(bits >> 23) & 0xff) - 127 + 15) << 10 | UInt16((bits >> 13) & 0x3ff)
        }
        let rows: [[Float]] = (0..<5).map { r in [Float(r), Float(r) + 0.5, -Float(r)] }
        try Self.writeSafetensors(file, [("vocab", "F16", [5, 3], Self.halfBytes(rows.flatMap { $0 }.map(half))),
                                         ("bias", "F32", [2], [0, 0, 0x80, 0x3f, 0, 0, 0, 0x40])])
        let weights = try Safetensors(url: file)
        #expect(weights.names == ["vocab", "bias"])
        let vocab = try weights.tensor("vocab")
        #expect(vocab.dtype == .f16 && vocab.shape == [5, 3])

        #expect(try vocab.row(3) == [3, 3.5, -3])
        #expect(vocab.rowsConverted == 1)
        #expect(!vocab.isConverted)  // the whole vocabulary was not converted for one row
        #expect(try vocab.row(0) == [0, 0.5, -0])
        #expect(vocab.rowsConverted == 2)

        let all = try vocab.withFloat32 { Array($0) }  // the whole tensor: converted once and kept
        #expect(all == rows.flatMap { $0 })
        #expect(vocab.isConverted)
        #expect(try vocab.row(4) == [4, 4.5, -4])
        #expect(vocab.rowsConverted == 2)  // served from the kept conversion
        #expect(try weights.tensor("bias").withFloat32 { Array($0) } == [1, 2])
        #expect(throws: SafetensorsError.self) { try vocab.row(5) }
        #expect(throws: SafetensorsError.self) { try weights.tensor("nope") }

        #expect(halfToFloat(0x3c00) == 1)
        #expect(halfToFloat(0x0001) == Float(sign: .plus, exponent: -24, significand: 1))  // the smallest subnormal
        #expect(halfToFloat(0x7c00) == .infinity && halfToFloat(0xfc00) == -.infinity && halfToFloat(0x7e00).isNaN)
        #expect(halfToFloat(0xc000) == -2 && halfToFloat(0x7bff) == 65504)
    }

    @Test func aBrokenSafetensorsFileThrowsNeverTraps() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("model.safetensors")
        func throwsOn(_ header: String, _ data: Int = 8) throws {
            try Self.writeSafetensors(file, [("t", "F32", [2], [UInt8](repeating: 0, count: data))], header: header)
            #expect(throws: SafetensorsError.self, "\(header)") { try Safetensors(url: file) }
        }
        try throwsOn(#"{"t": {"dtype": "F32", "shape": [2], "data_offsets": [0, 9]}}"#)  // past the end
        try throwsOn(#"{"t": {"dtype": "F32", "shape": [3], "data_offsets": [0, 8]}}"#)  // shape and bytes differ
        try throwsOn(#"{"t": {"dtype": "F32", "shape": [2], "data_offsets": [4, 0]}}"#)  // backwards
        try throwsOn(#"{"t": {"dtype": "F32", "shape": [2], "data_offsets": [-8, 0]}}"#)
        try throwsOn(#"{"t": {"dtype": "F32", "shape": [4611686018427387904, 4], "data_offsets": [0, 8]}}"#)  // overflow
        try throwsOn(#"{"t": {"dtype": "F32", "shape": [2], "data_offsets": [0, 99999999999999999999999]}}"#)  // no Int
        try throwsOn(#"{"t": {"dtype": "F32", "shape": [-2], "data_offsets": [0, 8]}}"#)
        try throwsOn(#"{"t": {"dtype": "BF16", "shape": [4], "data_offsets": [0, 8]}}"#)
        try throwsOn(#"{"t": {"dtype": "F32", "shape": [2]}}"#)
        try throwsOn(#"[1, 2]"#)
        try throwsOn(#"{"t": "#)

        for bytes in [[UInt8](), [1, 0, 0], [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7b, 0x7d], [16, 0, 0, 0, 0, 0, 0, 0, 0x7b, 0x7d]] {
            try Data(bytes).write(to: file)
            #expect(throws: SafetensorsError.self) { try Safetensors(url: file) }
        }
        #expect(throws: SafetensorsError.self) { try Safetensors(url: dir.appendingPathComponent("missing.safetensors")) }

        // An I64 tensor (the real model's position_ids) loads, but is no float tensor.
        try Self.writeSafetensors(file, [("ids", "I64", [1], [UInt8](repeating: 0, count: 8))])
        let ids = try Safetensors(url: file).tensor("ids")
        #expect(throws: SafetensorsError.self) { try ids.withFloat32 { $0.count } }
        // A file whose F32 data is not 4-aligned: copied once, the same numbers.
        try Self.writeSafetensors(file, [("pad", "F16", [1], [0, 0x3c]), ("odd", "F32", [1], [0, 0, 0x80, 0x3f])])
        let odd = try Safetensors(url: file).tensor("odd")
        #expect(try odd.withFloat32 { Array($0) } == [1])
    }

    @Test func aModelWithMissingOrMisshapenWeightsThrows() throws {
        let folder = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try Self.tinyModel(folder)
        let weights = try Safetensors(url: folder.appendingPathComponent("model.safetensors"))
        let kept = try weights.names.filter { $0 != "encoder.layer.1.output.dense.bias" }.map { name -> (String, String, [Int], [UInt8]) in
            let t = try weights.tensor(name)
            return (name, "F32", t.shape, try t.withFloat32 { $0.flatMap { withUnsafeBytes(of: $0) { Array($0) } } })
        }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("model.safetensors"))
        try Self.writeSafetensors(folder.appendingPathComponent("model.safetensors"), kept)
        let encoder = try E5Encoder(folder: folder)
        #expect(throws: SafetensorsError.self) { try encoder.query("cost") }

        try Data(#"{"num_attention_heads": 5, "num_hidden_layers": 2, "max_position_embeddings": 40}"#.utf8)
            .write(to: folder.appendingPathComponent("config.json"))  // 32 numbers don't split into 5 heads
        #expect(throws: E5EncoderError.self) { try E5Encoder(folder: folder) }
        try Data(#"{"num_attention_heads": 4}"#.utf8).write(to: folder.appendingPathComponent("config.json"))
        #expect(throws: E5EncoderError.self) { try E5Encoder(folder: folder) }
    }
}
