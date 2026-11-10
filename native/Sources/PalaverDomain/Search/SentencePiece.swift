// SentencePiece encode for a unigram model (XLM-R's sentencepiece.bpe.model, as multilingual-e5 uses it), as the
// Python `sentencepiece` package 0.2.2 does it in `SentencePieceProcessor.encode(text)`: normalize, then the best
// segmentation by piece scores. The ids are sentencepiece's own; the e5 embedder shifts them to fairseq's order.
//
// - Model file: a protobuf `ModelProto` — pieces (piece, score, type), `trainer_spec` (model type, whitespace as
//   suffix, byte fallback) and `normalizer_spec` (precompiled charsmap, add_dummy_prefix, remove_extra_whitespaces,
//   escape_whitespaces). Proto2 rules: unknown fields and fields of the wrong wire type are skipped, an enum value
//   it does not know leaves the default, a message field given twice is merged.
// - Normalization (normalizer.cc): the charsmap is a 4-byte little-endian trie size, a Darts-clone double array and
//   NUL-terminated replacement strings. At each place the longest rule (of the first 32 prefixes found) is
//   replaced, else one character is copied; a user-defined piece found there (longest of the first 64) is copied
//   as it is. Leading spaces and runs of spaces are dropped and trailing ones trimmed (remove_extra_whitespaces),
//   `▁` goes in front (add_dummy_prefix; behind with treat_whitespace_as_suffix) and spaces become `▁`.
// - Segmentation (unigram_model.cc `EncodeOptimized`): Viterbi over UTF-8 bytes in Float, as the C++ does. The best
//   path ending at each byte; a later candidate replaces it only when strictly better, so on equal scores the piece
//   that starts earlier (the longer one) wins. Unused pieces are never chosen. A user-defined piece scores
//   0.1 × (bytes − 1). A character no piece of its own length covers gets the unknown id at min score − 10;
//   consecutive unknowns become one. Path scores beyond ±100000 are shifted back to 0, as the C++ does.
//
// The file comes with the app but is read defensively: every length, varint and double-array index is checked;
// a broken file throws, it never traps.
import Foundation

public final class SentencePiece {
    public enum ModelError: Error, CustomStringConvertible {
        case unreadable(String)
        case malformed(String)
        case unsupported(String)

        public var description: String {
            switch self {
            case .unreadable(let s): return "sentencepiece model unreadable: \(s)"
            case .malformed(let s): return "sentencepiece model malformed: \(s)"
            case .unsupported(let s): return "sentencepiece model unsupported: \(s)"
            }
        }
    }

    // Piece types (ModelProto.SentencePiece.Type).
    private static let normal: UInt8 = 1, unknown: UInt8 = 2, userDefined: UInt8 = 4, unused: UInt8 = 5, byte: UInt8 = 6

    private let types: [UInt8]
    private let scores: [Float]
    private let unkID: Int32
    private let unkScore: Float
    private let hasUserDefined: Bool

    // The pieces (normal, user-defined, unused) as a byte trie: node 0 is the root; a node's children are the
    // nodes childStart ..< childStart + childCount, sorted by label; value is the piece id or -1.
    private let label: [UInt8]
    private let childStart: [Int32]
    private let childCount: [UInt16]
    private let value: [Int32]

    // The charsmap: double-array units and the replacement strings (empty: no rules).
    private let units: [UInt32]
    private let replacements: [UInt8]

    private let addDummyPrefix: Bool
    private let removeExtraWhitespaces: Bool
    private let escapeWhitespaces: Bool
    private let whitespaceAsSuffix: Bool

    public convenience init(modelFile: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: modelFile) } catch { throw ModelError.unreadable("\(modelFile.path): \(error)") }
        try self.init(model: [UInt8](data))
    }

    init(model bytes: [UInt8]) throws {
        let proto = try ModelProto(bytes)
        guard proto.modelType == 1 else { throw ModelError.unsupported("model type \(proto.modelType), not unigram") }
        guard !proto.byteFallback else { throw ModelError.unsupported("byte fallback") }

        // model_interface.cc InitializePieces and unigram_model.cc Model::Model.
        var types = [UInt8](), scores = [Float]()
        types.reserveCapacity(proto.pieces.count)
        scores.reserveCapacity(proto.pieces.count)
        var trieIDs = [Int32]()
        var reserved = Set<ArraySlice<UInt8>>()
        var unk: Int32 = -1
        var minScore = Float.greatestFiniteMagnitude
        var hasUserDefined = false
        for (i, p) in proto.pieces.enumerated() {
            let piece = bytes[p.piece]
            if piece.count >= 8000 { throw ModelError.malformed("piece \(i) is too long") }
            if piece.isEmpty { throw ModelError.malformed("piece \(i) is empty") }
            if piece.contains(0) { throw ModelError.malformed("piece \(i) has a NUL") }
            if p.type == Self.normal || p.type == Self.userDefined || p.type == Self.unused {
                trieIDs.append(Int32(i))
            } else if !reserved.insert(piece).inserted {
                throw ModelError.malformed("piece \(i) is already defined")
            }
            if p.type == Self.userDefined { hasUserDefined = true }
            if p.type == Self.unknown {
                if unk >= 0 { throw ModelError.malformed("unk is already defined") }
                unk = Int32(i)
            }
            if p.type == Self.byte { throw ModelError.malformed("byte piece \(i) although byte_fallback is false") }
            types.append(p.type)
            scores.append(p.score)
        }
        if unk < 0 { throw ModelError.malformed("unk is not defined") }
        for (p, score) in zip(proto.pieces, scores) {
            if score.isNaN || score.isInfinite { throw ModelError.malformed("score is NaN or Inf") }
            if p.type == Self.normal { minScore = min(minScore, score) }
        }
        if trieIDs.isEmpty { throw ModelError.malformed("no pieces are loaded") }
        self.types = types
        self.scores = scores
        self.unkID = unk
        self.unkScore = minScore - 10.0
        self.hasUserDefined = hasUserDefined
        (label, childStart, childCount, value) = try Self.buildTrie(trieIDs, proto.pieces.map(\.piece), bytes)

        (units, replacements) = try Self.charsmap(bytes[proto.charsmap])
        addDummyPrefix = proto.addDummyPrefix
        removeExtraWhitespaces = proto.removeExtraWhitespaces
        escapeWhitespaces = proto.escapeWhitespaces
        whitespaceAsSuffix = proto.whitespaceAsSuffix
    }

    /// sentencepiece's ids for `text` (no <s> or </s>).
    public func encode(_ text: String) -> [Int] {
        var text = text
        return text.withUTF8 { input -> [Int] in
            let normalized = normalize(input)
            return normalized.withUnsafeBufferPointer { viterbi($0) }
        }
    }

    // MARK: - Normalization

    /// Where one step of normalization reads its output from. (Never sentencepiece's U+FFFD for malformed UTF-8:
    /// a Swift string is valid UTF-8.)
    private enum Source { case input, table }

    /// normalizer.cc NormalizePrefix at `pos`: what to write (source and byte range) and how many input bytes it
    /// consumes.
    @inline(__always)
    private func normalizePrefix(_ input: UnsafeBufferPointer<UInt8>, _ pos: Int,
                                 _ units: UnsafeBufferPointer<UInt32>) -> (Source, Int, Int, Int) {
        if hasUserDefined {
            let n = longestUserDefined(input, pos)
            if n > 0 { return (.input, pos, pos + n, n) }
        }
        var longestLength = 0, longestValue = 0
        if units.count > 0 {
            // Darts-clone commonPrefixSearch, the first 32 results.
            var found = 0
            var node = Int(units[0].offset)
            var i = pos
            while i < input.count && found < 32 {
                let b = input[i]
                node ^= Int(b)
                guard node < units.count else { break }
                let unit = units[node]
                if unit.label != UInt32(b) { break }
                node ^= Int(unit.offset)
                guard node < units.count else { break }
                if unit.hasLeaf {
                    let length = i + 1 - pos
                    if longestLength == 0 || length > longestLength {
                        longestLength = length
                        longestValue = Int(units[node].value)
                    }
                    found += 1
                }
                i += 1
            }
        }
        if longestLength == 0 || longestValue >= replacements.count {
            let n = min(Self.charLength(input[pos]), input.count - pos)
            return (.input, pos, pos + n, n)
        }
        var end = longestValue
        while end < replacements.count && replacements[end] != 0 { end += 1 }
        return (.table, longestValue, end, longestLength)
    }

    /// The longest user-defined piece at `pos` (of the first 64 found), 0 when none.
    private func longestUserDefined(_ input: UnsafeBufferPointer<UInt8>, _ pos: Int) -> Int {
        var node = 0, i = pos, found = 0, longest = 0
        while i < input.count && found < 64 {
            guard let next = child(node, input[i]) else { break }
            node = next
            i += 1
            let id = value[node]
            if id >= 0 && types[Int(id)] == Self.userDefined {
                longest = i - pos
                found += 1
            }
        }
        return longest
    }

    private func normalize(_ input: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        replacements.withUnsafeBufferPointer { table -> [UInt8] in
            units.withUnsafeBufferPointer { units -> [UInt8] in
                normalize(input, table, units)
            }
        }
    }

    private func normalize(_ input: UnsafeBufferPointer<UInt8>, _ table: UnsafeBufferPointer<UInt8>,
                           _ units: UnsafeBufferPointer<UInt32>) -> [UInt8] {
        var out = [UInt8]()
        guard input.count > 0 else { return out }
        let space: UInt8 = 0x20
        let spaceSymbol: [UInt8] = escapeWhitespaces ? [0xE2, 0x96, 0x81] : [space]
        var pos = 0
        if removeExtraWhitespaces {
            while pos < input.count {
                let (source, start, end, consumed) = normalizePrefix(input, pos, units)
                let isSpace = end - start == 1 && (source == .input ? input[start] : table[start]) == space
                if !isSpace { break }
                pos += consumed
            }
        }
        if pos == input.count { return out }
        out.reserveCapacity((input.count - pos) * 3 / 2 + 4)
        if !whitespaceAsSuffix && addDummyPrefix { out.append(contentsOf: spaceSymbol) }

        var isPrevSpace = removeExtraWhitespaces
        while pos < input.count {
            let (source, s, e, consumed) = normalizePrefix(input, pos, units)
            func byte(_ k: Int) -> UInt8 { source == .input ? input[k] : table[k] }
            var start = s
            while isPrevSpace && start < e && byte(start) == space { start += 1 }
            if start < e {
                for k in start..<e {
                    let b = byte(k)
                    if b == space { out.append(contentsOf: spaceSymbol) } else { out.append(b) }
                }
                isPrevSpace = byte(e - 1) == space
            }
            pos += consumed
            if !removeExtraWhitespaces { isPrevSpace = false }
        }
        if removeExtraWhitespaces {
            while out.count >= spaceSymbol.count && out[(out.count - spaceSymbol.count)...].elementsEqual(spaceSymbol) {
                out.removeLast(spaceSymbol.count)
            }
        }
        if whitespaceAsSuffix && addDummyPrefix { out.append(contentsOf: spaceSymbol) }
        return out
    }

    /// string_util::OneCharLen: the length of the UTF-8 character a lead byte starts (1 for a stray continuation).
    @inline(__always)
    private static func charLength(_ lead: UInt8) -> Int {
        switch lead >> 4 {
        case 0xC, 0xD: return 2
        case 0xE: return 3
        case 0xF: return 4
        default: return 1
        }
    }

    // MARK: - Segmentation

    @inline(__always)
    private func child(_ node: Int, _ b: UInt8) -> Int? {
        var lo = Int(childStart[node]), hi = lo + Int(childCount[node])
        while lo < hi {
            let mid = (lo + hi) >> 1
            let l = label[mid]
            if l == b { return mid }
            if l < b { lo = mid + 1 } else { hi = mid }
        }
        return nil
    }

    private func viterbi(_ text: UnsafeBufferPointer<UInt8>) -> [Int] {
        let size = text.count
        guard size > 0 else { return [] }
        var best = [Float](repeating: 0, count: size + 1)
        var startsAt = [Int32](repeating: -1, count: size + 1)
        var ids = [Int32](repeating: -1, count: size + 1)
        let resetThreshold: Float = 100000
        var maxFrontier = 0
        var start = 0
        while start < size {
            var tillHere = best[start]
            if tillHere < -resetThreshold || tillHere > resetThreshold {
                let offset = tillHere
                if maxFrontier >= start {
                    for i in start...maxFrontier where i == start || startsAt[i] != -1 { best[i] -= offset }
                }
                tillHere = 0
            }
            var hasSingleNode = false
            let mblen = min(Self.charLength(text[start]), size - start)
            var node = 0, end = start
            while end < size, let next = child(node, text[end]) {
                node = next
                end += 1
                let id = value[node]
                guard id >= 0 else { continue }
                let type = types[Int(id)]
                if type == Self.unused { continue }
                maxFrontier = max(maxFrontier, end)
                let length = end - start
                let score = type == Self.userDefined ? Float(0.1 * Double(length - 1)) : scores[Int(id)]
                let candidate = score + tillHere
                if startsAt[end] == -1 || candidate > best[end] {
                    best[end] = candidate
                    startsAt[end] = Int32(start)
                    ids[end] = id
                }
                if length == mblen { hasSingleNode = true }
            }
            if !hasSingleNode {
                let end = start + mblen
                maxFrontier = max(maxFrontier, end)
                let candidate = unkScore + tillHere
                if startsAt[end] == -1 || candidate > best[end] {
                    best[end] = candidate
                    startsAt[end] = Int32(start)
                    ids[end] = unkID
                }
            }
            start += mblen
        }
        // Back from the end; then forward, one id for each run of unknowns.
        var path = [Int32]()
        path.reserveCapacity(size / 4 + 1)
        var end = size
        while end > 0 {
            let from = Int(startsAt[end])
            guard from >= 0 && from < end else { break }  // cannot happen: every character start is reached
            path.append(ids[end])
            end = from
        }
        var out = [Int]()
        out.reserveCapacity(path.count)
        var prevUnknown = false
        for id in path.reversed() {
            let isUnknown = types[Int(id)] == Self.unknown
            if !(prevUnknown && isUnknown) { out.append(Int(id)) }
            prevUnknown = isUnknown
        }
        return out
    }

    // MARK: - Loading

    /// The byte trie of the pieces `ids`, each a byte range of `file`; throws on a piece given twice.
    private static func buildTrie(_ ids: [Int32], _ ranges: [Range<Int>], _ file: [UInt8]) throws
        -> ([UInt8], [Int32], [UInt16], [Int32]) {
        try file.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            let start = ranges.map { $0.lowerBound }, length = ranges.map { $0.count }
            func compare(_ a: Int, _ b: Int) -> Int32 {
                let c = memcmp(base + start[a], base + start[b], min(length[a], length[b]))
                return c != 0 ? c : length[a] < length[b] ? -1 : length[a] > length[b] ? 1 : 0
            }
            let sorted = ids.sorted { compare(Int($0), Int($1)) < 0 }
            for k in sorted.indices.dropFirst() where compare(Int(sorted[k - 1]), Int(sorted[k])) == 0 {
                throw ModelError.malformed("piece \(max(sorted[k - 1], sorted[k])) is already defined")
            }
            var label: [UInt8] = [0], childStart: [Int32] = [0], childCount: [UInt16] = [0], value: [Int32] = [-1]
            // Breadth first: (node, keys lo ..< hi of `sorted`, depth); a node's children are appended together.
            var queue: [(node: Int, lo: Int, hi: Int, depth: Int)] = [(0, 0, sorted.count, 0)]
            var head = 0
            while head < queue.count {
                var (node, lo, hi, depth) = queue[head]
                head += 1
                if lo < hi && length[Int(sorted[lo])] == depth {
                    value[node] = sorted[lo]
                    lo += 1
                }
                childStart[node] = Int32(label.count)
                var count = 0
                var k = lo
                while k < hi {
                    let b = buf[start[Int(sorted[k])] + depth]
                    var j = k + 1
                    while j < hi && buf[start[Int(sorted[j])] + depth] == b { j += 1 }
                    guard label.count < Int(Int32.max) else { throw ModelError.malformed("too many pieces") }
                    label.append(b)
                    childStart.append(0)
                    childCount.append(0)
                    value.append(-1)
                    queue.append((label.count - 1, k, j, depth + 1))
                    count += 1
                    k = j
                }
                childCount[node] = UInt16(count)  // at most 256 labels
            }
            return (label, childStart, childCount, value)
        }
    }

    /// normalizer.cc DecodePrecompiledCharsMap and Darts-clone validate: the double array's units and the
    /// replacement strings; nothing for an empty charsmap.
    private static func charsmap(_ blob: ArraySlice<UInt8>) throws -> ([UInt32], [UInt8]) {
        if blob.isEmpty { return ([], []) }
        guard blob.count > 4 else { throw ModelError.malformed("charsmap is broken") }
        let b = blob.startIndex
        let trieSize = Int(blob[b]) | Int(blob[b + 1]) << 8 | Int(blob[b + 2]) << 16 | Int(blob[b + 3]) << 24
        guard trieSize < blob.count - 4 else { throw ModelError.malformed("charsmap trie size exceeds the charsmap") }
        guard trieSize >= 1024 && trieSize & 0x3FF == 0 else {
            throw ModelError.malformed("charsmap trie size is not divisible by 1024")
        }
        var units = [UInt32](repeating: 0, count: trieSize / 4)
        for i in units.indices {
            let o = b + 4 + i * 4
            units[i] = UInt32(blob[o]) | UInt32(blob[o + 1]) << 8 | UInt32(blob[o + 2]) << 16 | UInt32(blob[o + 3]) << 24
        }
        let replacements = [UInt8](blob[(b + 4 + trieSize)...])
        guard replacements.last == 0 else { throw ModelError.malformed("charsmap strings are not NUL-terminated") }
        // Darts-clone validate(normalized size): every index a lookup can reach stays inside the array.
        let n = units.count
        let root = units[0]
        guard root.label == 0, !root.hasLeaf, root.offset != 0, Int(root.offset) | 0xFF < n else {
            throw ModelError.malformed("charsmap double array is invalid")
        }
        for i in 1..<n {
            let unit = units[i]
            if unit.label <= 0xFF {
                if (i ^ Int(unit.offset)) | 0xFF >= n { throw ModelError.malformed("charsmap double array is invalid") }
            } else if Int(unit.value) >= replacements.count {
                throw ModelError.malformed("charsmap double array is invalid")
            }
        }
        return (units, replacements)
    }
}

/// A Darts-clone double-array unit.
private extension UInt32 {
    var hasLeaf: Bool { (self >> 8) & 1 == 1 }
    var value: UInt32 { self & ((1 << 31) - 1) }
    var label: UInt32 { self & ((1 << 31) | 0xFF) }
    var offset: UInt32 { (self >> 10) << ((self & (1 << 9)) >> 6) }
}

/// The parts of sentencepiece_model.proto's ModelProto the encoder uses; byte ranges point into the file.
private struct ModelProto {
    struct Piece {
        var piece: Range<Int> = 0..<0
        var score: Float = 0
        var type: UInt8 = 1
    }

    var pieces: [Piece] = []
    var modelType: UInt64 = 1
    var whitespaceAsSuffix = false
    var byteFallback = false
    var charsmap: Range<Int> = 0..<0
    var addDummyPrefix = true
    var removeExtraWhitespaces = true
    var escapeWhitespaces = true

    init(_ bytes: [UInt8]) throws {
        var r = ProtoReader(bytes, 0..<bytes.count)
        while let (field, wire) = try r.tag() {
            switch (field, wire) {
            case (1, 2): pieces.append(try Self.piece(ProtoReader(bytes, try r.lengthDelimited())))
            case (2, 2): try trainer(ProtoReader(bytes, try r.lengthDelimited()))
            case (3, 2): try normalizer(ProtoReader(bytes, try r.lengthDelimited()))
            default: try r.skip(wire)
            }
        }
    }

    private static func piece(_ reader: ProtoReader) throws -> Piece {
        var r = reader, p = Piece()
        while let (field, wire) = try r.tag() {
            switch (field, wire) {
            case (1, 2): p.piece = try r.lengthDelimited()
            case (2, 5): p.score = Float(bitPattern: try r.fixed32())
            case (3, 0):
                let v = try r.varint()
                if (1...6).contains(v) { p.type = UInt8(v) }  // proto2: an unknown enum value keeps the default
            default: try r.skip(wire)
            }
        }
        return p
    }

    private mutating func trainer(_ reader: ProtoReader) throws {
        var r = reader
        while let (field, wire) = try r.tag() {
            switch (field, wire) {
            case (3, 0):
                let v = try r.varint()
                if (1...4).contains(v) { modelType = v }
            case (24, 0): whitespaceAsSuffix = try r.varint() != 0
            case (35, 0): byteFallback = try r.varint() != 0
            default: try r.skip(wire)
            }
        }
    }

    private mutating func normalizer(_ reader: ProtoReader) throws {
        var r = reader
        while let (field, wire) = try r.tag() {
            switch (field, wire) {
            case (2, 2): charsmap = try r.lengthDelimited()
            case (3, 0): addDummyPrefix = try r.varint() != 0
            case (4, 0): removeExtraWhitespaces = try r.varint() != 0
            case (5, 0): escapeWhitespaces = try r.varint() != 0
            default: try r.skip(wire)
            }
        }
    }
}

/// Protobuf wire format over a byte range, every read bounds-checked.
private struct ProtoReader {
    let bytes: [UInt8]
    var pos: Int
    let end: Int

    init(_ bytes: [UInt8], _ range: Range<Int>) {
        self.bytes = bytes
        pos = range.lowerBound
        end = range.upperBound
    }

    private static func broken(_ what: String) -> SentencePiece.ModelError { .malformed("protobuf: \(what)") }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard pos < end else { throw Self.broken("truncated varint") }
            let b = bytes[pos]
            pos += 1
            if shift == 63 && b > 1 { throw Self.broken("varint overflows 64 bits") }
            result |= UInt64(b & 0x7F) << shift
            if b < 0x80 { return result }
            shift += 7
            if shift > 63 { throw Self.broken("varint is too long") }
        }
    }

    /// The next field number and wire type; nil at the end.
    mutating func tag() throws -> (UInt64, UInt64)? {
        guard pos < end else { return nil }
        let t = try varint()
        guard t >> 3 != 0 else { throw Self.broken("field number 0") }
        return (t >> 3, t & 7)
    }

    mutating func fixed32() throws -> UInt32 {
        guard end - pos >= 4 else { throw Self.broken("truncated fixed32") }
        defer { pos += 4 }
        return UInt32(bytes[pos]) | UInt32(bytes[pos + 1]) << 8 | UInt32(bytes[pos + 2]) << 16 | UInt32(bytes[pos + 3]) << 24
    }

    /// A length-delimited field's byte range.
    mutating func lengthDelimited() throws -> Range<Int> {
        let n = try varint()
        guard n <= UInt64(end - pos) else { throw Self.broken("length exceeds the message") }
        let range = pos..<(pos + Int(n))
        pos += Int(n)
        return range
    }

    mutating func skip(_ wire: UInt64) throws {
        switch wire {
        case 0: _ = try varint()
        case 1:
            guard end - pos >= 8 else { throw Self.broken("truncated fixed64") }
            pos += 8
        case 2: _ = try lengthDelimited()
        case 5: _ = try fixed32()
        default: throw Self.broken("wire type \(wire)")
        }
    }
}
