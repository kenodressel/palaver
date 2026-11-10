// SentencePiece (XLM-R unigram) encode against the Python sentencepiece package's ids (goldens section
// `sentencepiece`): 500 texts on the two tiny embedder models and on three constructed models (the nmt_nfkc
// charsmap; no dummy prefix and extra whitespace kept; whitespace as an unescaped suffix) with user-defined,
// unused and equal-score pieces. And model files that are broken: an error, never a trap.
import Foundation
import PalaverCore
import PalaverDomain
import Testing

@Suite struct SentencePieceTests {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // native/Tests/PalaverDomainTests
        .appendingPathComponent("../../..").standardizedFileURL

    /// A model named in the golden: repo-relative, or a file under Goldens/.
    private static func modelFile(_ file: String) -> URL {
        file.contains("/") ? repo.appendingPathComponent(file) : Goldens.url(file)
    }

    private static func idsMatch(_ names: [String], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let golden = Goldens.load("sentencepiece")
        // The encoder ported is sentencepiece 0.2.2's (tools/parity/goldens.py SENTENCEPIECE_VERSION).
        #expect(golden["version"] == .string("0.2.2"), sourceLocation: sourceLocation)
        let texts = try #require(golden["texts"]?.arrayValue).map { try #require($0.stringValue) }
        #expect(texts.count == 500)
        for name in names {
            let file = try #require(golden["models"]?[name]?.stringValue, "model \(name)")
            let model = try SentencePiece(modelFile: modelFile(file))
            let ids = texts.map { JSONValue.array(model.encode($0).map { .int($0) }) }
            guard let want = golden["ids"]?[name]?.arrayValue else {
                Issue.record("golden sentencepiece has no ids for \(name)", sourceLocation: sourceLocation)
                continue
            }
            #expect(ids.count == want.count, sourceLocation: sourceLocation)
            var reported = 0
            for (i, (got, exp)) in zip(ids, want).enumerated() where reported < 5 {
                let g = PythonJSON.dumps(got), w = PythonJSON.dumps(exp)
                if g != w {
                    Issue.record("\(name) text \(i) \(PythonJSON.dumps(.string(texts[i])).prefix(80)): got \(g.prefix(200)), want \(w.prefix(200))",
                                 sourceLocation: sourceLocation)
                    reported += 1
                }
            }
        }
    }

    @Test func idsMatchSentencepieceOnTheTinyModels() throws {
        try Self.idsMatch(["bert", "xlm-roberta"])
    }

    @Test func idsMatchSentencepieceOnTheConstructedModels() throws {
        try Self.idsMatch(["nfkc", "raw", "suffix"])
    }

    @Test func encodeIsTheSameOnEveryCall() throws {
        let model = try SentencePiece(modelFile: Goldens.url("sentencepiece-nfkc.model"))
        let first = model.encode("query: Timo Strauß ﬁx [Contoso] ab")
        #expect(model.encode("query: Timo Strauß ﬁx [Contoso] ab") == first)
        #expect(model.encode("") == [])
    }

    private static func throwsOrLoads(_ bytes: [UInt8], _ texts: [String]) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sp-\(UUID().uuidString).model")
        defer { try? FileManager.default.removeItem(at: file) }
        try? Data(bytes).write(to: file)
        guard let model = try? SentencePiece(modelFile: file) else { return }
        for text in texts { _ = model.encode(text) }  // must not trap
    }

    @Test func aMissingOrEmptyFileThrows() throws {
        #expect(throws: (any Error).self) {
            try SentencePiece(modelFile: URL(fileURLWithPath: "/nonexistent/sentencepiece.bpe.model"))
        }
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("sp-empty-\(UUID().uuidString).model")
        defer { try? FileManager.default.removeItem(at: empty) }
        try Data().write(to: empty)
        #expect(throws: SentencePiece.ModelError.self) { try SentencePiece(modelFile: empty) }
    }

    @Test func aTruncatedOrDamagedModelThrowsOrStillEncodes() throws {
        let texts = ["", "hello world", "ｈｅｌｌｏ ﬁx [Contoso] qa Straße 😀", "  a\u{3000}b  ", "\u{0}x"]
        let tiny = try [UInt8](Data(contentsOf: Self.repo.appendingPathComponent("tests/fixtures/tiny_embedder/bert/sentencepiece.bpe.model")))
        for n in 0..<tiny.count { Self.throwsOrLoads(Array(tiny[..<n]), texts) }
        var rng = SplitMix(seed: 33)
        for _ in 0..<300 {
            var bytes = tiny
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
            Self.throwsOrLoads(bytes, texts)
        }
        // the charsmap: its trie size, its double-array units and its replacement strings
        let nfkc = try [UInt8](Data(contentsOf: Goldens.url("sentencepiece-nfkc.model")))
        for _ in 0..<60 {
            var bytes = nfkc
            for _ in 0..<Int.random(in: 1...64, using: &rng) {
                bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
            Self.throwsOrLoads(bytes, texts)
        }
        for cut in [1, 2, 100, 4096, 100_000, nfkc.count - 2] { Self.throwsOrLoads(Array(nfkc[..<(nfkc.count - cut)]), texts) }
    }
}

/// A seeded generator, so a failing damage case comes back on the next run.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
