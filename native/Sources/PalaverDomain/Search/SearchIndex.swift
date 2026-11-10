// Search by meaning (semantic.py:1-231): each processed meeting gets an index, its notes piece by piece (summary,
// decisions, next steps, points) and its transcript in runs of one speaker, one float16 vector per piece.
//
// The index is four files in the meeting's folder: `search-index.npy` (numpy's format 1.0, `<f2`, C order),
// `search-index.json` (the pieces), `search-index.sig` (written last: the model and the times of the files the index
// was made from) and, after a failure, `search-index.failed`. Each is written through a `.tmp` and renamed, as Python
// does; a crash before the `.sig` leaves the meeting stale, never current with a broken index. The files are read
// back later, so every read is defensive: a broken file is no index, never a trap.
import Darwin
import Foundation
import os
import PalaverCore

/// What turns texts into vectors: `E5Encoder`, or a test's stand-in (embeddings.Encoder's `query` and `passages`).
public protocol MeaningEncoder: AnyObject {
    /// Numbers per vector: the width of `passages([])`.
    var dimension: Int { get }
    func query(_ text: String) throws -> [Float]
    func passages(_ texts: [String]) throws -> [[Float]]
}

extension E5Encoder: MeaningEncoder {}

/// What Python raises while a meeting is indexed or searched (a TypeError on a notes value that is no text, a
/// broken vector shape, numpy's matmul error): the meeting's indexing fails, or the search does.
public struct SearchIndexError: Error, CustomStringConvertible {
    public let description: String
}

public enum SearchIndex {
    /// The model whose vectors the indexes hold (embeddings.MODEL); an index of another model is not used.
    public static let model = "intfloat/multilingual-e5-small"

    public static let INDEX_NPY = "search-index.npy"
    public static let INDEX_JSON = "search-index.json"
    /// Written last: which model, and the times of the files the index was made from, read when the indexing began.
    /// The index is current while they match.
    public static let INDEX_SIG = "search-index.sig"
    /// A meeting whose indexing failed: skipped until its files change.
    public static let INDEX_FAILED = "search-index.failed"
    /// A piece of the transcript: one speaker's lines, up to this many words; a run shorter than MIN_WORDS
    /// ("Ja, genau.") says too little to be found by.
    public static let CHUNK_WORDS = 80
    public static let MIN_WORDS = 8
    /// A hit has to stand out: MARGIN above the median of the pieces searched, never below MIN_SCORE. With fewer
    /// than MEDIAN_PIECES the median says little: SMALL_SCORE.
    public static let MIN_SCORE = 0.78
    public static let MARGIN = 0.06
    public static let MEDIAN_PIECES = 100
    public static let SMALL_SCORE = 0.80
    public static let HITS_PER_MEETING = 3
    /// The model goes after this long without a search.
    public static let IDLE_SECONDS = 300.0
    /// What `palaver index` needs free: its peak was ~240 MB footprint.
    public static let INDEX_MEMORY_GB = 1.0

    private static let log = Logger(subsystem: "com.kenodressel.palaver", category: "semantic")

    /// Settings.search_meaning.
    public static func enabled(stores: StorePaths = .current()) -> Bool {
        SettingsFile.load(stores: stores).searchMeaning
    }

    // MARK: - Current, stale, failed

    private static func sources(_ paths: RecordingPaths) -> [URL] {
        [paths.transcriptJson, paths.notes, paths.speakersIgnored, paths.speakersLines]
    }

    /// The files an index is made from and their `st_mtime_ns` (links followed); a missing one is null.
    static func signature(_ paths: RecordingPaths) -> JSONValue {
        .object(sources(paths).map { url in
            var st = stat()
            guard stat(url.path, &st) == 0 else { return (url.lastPathComponent, .null) }
            // Python's int has no limit; ours does. A time that does not fit becomes NaN, which equals nothing
            // (not even itself, nor what Python wrote), so the meeting counts as changed and is indexed again.
            guard let ns = FileTimes.mtimeNs(st) else { return (url.lastPathComponent, .double(.nan)) }
            return (url.lastPathComponent, .int(ns))
        })
    }

    /// The file's JSON when it is an object (`_read`); nil when missing, broken or anything else.
    private static func readObject(_ url: URL) -> JSONValue? {
        guard let v = PythonJSON.read(url), case .object = v else { return nil }
        return v
    }

    private static func exists(_ url: URL) -> Bool {
        var st = stat()
        return stat(url.path, &st) == 0
    }

    private static func indexable(_ paths: RecordingPaths) -> Bool {
        exists(paths.transcriptJson) && !WorkerPids.liveRunning(paths.folder)
    }

    /// Whether the meeting's `.sig` names `model` and the files as they are now.
    public static func isCurrent(_ paths: RecordingPaths, model: String = model) -> Bool {
        guard let sig = readObject(paths.folder.appendingPathComponent(INDEX_SIG)), sig.truthy else { return false }
        return PythonJSON.equal(sig["model"] ?? .null, .string(model))
            && PythonJSON.equal(sig["sources"] ?? .null, signature(paths))
    }

    /// Indexing failed on the files as they are now.
    private static func failed(_ paths: RecordingPaths) -> Bool {
        guard let mark = readObject(paths.folder.appendingPathComponent(INDEX_FAILED)), mark.truthy else { return false }
        return PythonJSON.equal(mark["sources"] ?? .null, signature(paths))
    }

    /// The recording folders of `outputDir`, newest (the greatest name) first.
    static func meetings(_ outputDir: URL) -> [RecordingPaths] {
        guard Undo.isDir(outputDir.path),
              let names = try? FileManager.default.contentsOfDirectory(atPath: outputDir.path) else { return [] }
        return Py.stableSorted(names) { Py.less($1, $0) }
            .filter { Undo.isDir(outputDir.path + "/" + $0) && RecordingPaths.isRecordingFolderName($0) }
            .map { RecordingPaths(outputDir.appendingPathComponent($0, isDirectory: true)) }
    }

    /// Processed meetings without a current index, newest first: never one a live worker is still recording, nor one
    /// whose indexing failed on its files as they are. Only file times are read: cheap enough to ask every few
    /// minutes.
    public static func stale(outputDir: URL, model: String = model) -> [RecordingPaths] {
        meetings(outputDir).filter { indexable($0) && !isCurrent($0, model: model) && !failed($0) }
    }

    // MARK: - The pieces

    /// Python's `for x in v` over a parsed JSON value: a list's items, a text's characters, an object's keys; a
    /// number, a bool or null is a TypeError.
    private static func items(_ v: JSONValue, _ what: String) throws -> [JSONValue] {
        switch v {
        case .array(let a): return a
        case .string(let s): return s.unicodeScalars.map { .string(String($0)) }
        case .object(let fields): return fields.map { .string($0.0) }
        default: throw SearchIndexError(description: "TypeError: \(what) is not iterable")
        }
    }

    /// `v or []` iterated.
    private static func orEmpty(_ v: JSONValue?, _ what: String) throws -> [JSONValue] {
        guard let v, v.truthy else { return [] }
        return try items(v, what)
    }

    /// `x.get(key)` on a value Python calls `.get` on: only a dict has it.
    private static func get(_ x: JSONValue, _ key: String, _ what: String) throws -> JSONValue? {
        guard case .object = x else { throw SearchIndexError(description: "AttributeError: \(what) has no attribute 'get'") }
        return x[key]
    }

    /// The meeting's utterances (`Utterance.from_dict` of each); none when the file is missing or no JSON, or a
    /// time is a text `float()` can't read (Python's `except (OSError, ValueError)`); any other broken line raises.
    private static func utterances(_ paths: RecordingPaths) throws -> [Utterance] {
        guard let data = try? Data(contentsOf: paths.transcriptJson), let value = try? PythonJSON.parse(data) else { return [] }
        var out: [Utterance] = []
        for item in try items(value, "transcript.json") {
            do { out.append(try Utterance(json: item)) } catch let e as ModelError where e.description.hasPrefix("ValueError") {
                return []
            }
        }
        return out
    }

    private static func who(_ u: Utterance) -> String {
        if let label = u.label, !label.isEmpty { return label }
        return u.speaker
    }

    /// The pieces of a meeting that get a vector each, as JSON objects in Python's key order: the summary, the
    /// decisions, the next steps (with their owner), the points of each section (with its heading), then the runs of
    /// one speaker's readable lines (at most CHUNK_WORDS words; a run under MIN_WORDS is left out). Throws where
    /// Python raises on notes of the wrong shape.
    public static func chunks(_ paths: RecordingPaths) throws -> [JSONValue] {
        var out: [JSONValue] = []
        var n = JSONValue.object([])
        if let notes = Notes.load(paths), notes.truthy { n = notes }
        let what = "notes.json"
        if let summary = try get(n, "summary", what), summary.truthy {
            out.append(.object([("kind", .string("summary")), ("text", summary)]))
        }
        for d in try orEmpty(try get(n, "decisions", what), "decisions") {
            if case .string(let s) = d, !s.isEmpty { out.append(.object([("kind", .string("decision")), ("text", d)])) }
        }
        for s in try orEmpty(try get(n, "next_steps", what), "next_steps") {
            guard case .object = s, let task = s["task"], task.truthy else { continue }
            let owner = s["owner"].flatMap { $0.truthy ? $0 : nil } ?? .string("")
            out.append(.object([("kind", .string("step")), ("text", task), ("owner", owner)]))
        }
        for section in try orEmpty(try get(n, "sections", what), "sections") {
            for point in try orEmpty(try get(section, "points", "a section"), "points") {
                var parts = [try get(point, "text", "a point").flatMap { $0.truthy ? $0 : nil } ?? .string("")]
                parts += try orEmpty(point["details"], "details")
                let words = try parts.map { part -> String in
                    guard case .string(let s) = part else { throw SearchIndexError(description: "TypeError: sequence item: expected str instance") }
                    return s
                }
                let text = Py.strip(words.joined(separator: " "))
                if !text.isEmpty {
                    let heading = section["heading"].flatMap { $0.truthy ? $0 : nil } ?? .string("")
                    out.append(.object([("kind", .string("point")), ("text", .string(text)), ("heading", heading)]))
                }
            }
        }

        var run: [Utterance] = []
        func flush() {
            let text = Py.strip(run.map(\.text).joined(separator: " "))
            if Py.split(text).count >= MIN_WORDS {
                out.append(.object([("kind", .string("line")), ("speaker", .string(who(run[0]))),
                                    ("start", .double(Py.round(run[0].start, 2))), ("text", .string(text))]))
            }
            run.removeAll()
        }
        for u in Readable.readable(try Speakers.withoutIgnored(paths, try utterances(paths))) {
            let words = run.reduce(0) { $0 + Py.split($1.text).count }
            if !run.isEmpty && (!Py.same(who(run[0]), who(u)) || words + Py.split(u.text).count > CHUNK_WORDS) {
                flush()
            }
            run.append(u)
        }
        if !run.isEmpty { flush() }
        return out
    }

    /// What a piece's vector is made of: its heading (a point's) and its text, joined by ": " (`_passage`).
    static func passage(_ chunk: JSONValue) throws -> String {
        let parts = [chunk["heading"], chunk["text"]].compactMap { $0 }.filter(\.truthy)
        return try parts.map { part -> String in
            guard case .string(let s) = part else { throw SearchIndexError(description: "TypeError: sequence item: expected str instance") }
            return s
        }.joined(separator: ": ")
    }

    // MARK: - Writing

    /// Writes the meeting's index; the number of pieces. It is current only if its files did not change while it was
    /// made: the `.sig` holds their times from before.
    @discardableResult
    public static func indexMeeting(_ paths: RecordingPaths, encoder: MeaningEncoder?, model: String = model) throws -> Int {
        let sources = signature(paths)
        let pieces = try chunks(paths)
        guard let encoder else { throw SearchIndexError(description: "AttributeError: no encoder") }
        let vectors = try encoder.passages(try pieces.map(passage))
        let columns = vectors.first?.count ?? encoder.dimension
        guard vectors.allSatisfy({ $0.count == columns }) else {
            throw SearchIndexError(description: "ValueError: the vectors have different lengths")
        }
        let folder = paths.folder
        try writeFile(Npy.float16(rows: vectors.count, columns: columns, vectors.joined()),
                      folder.appendingPathComponent(INDEX_NPY + ".tmp").path)
        try rename(folder.appendingPathComponent(INDEX_NPY + ".tmp"), folder.appendingPathComponent(INDEX_NPY))
        try PythonJSON.write(.object([("model", .string(model)), ("chunks", .array(pieces))]),
                             to: folder.appendingPathComponent(INDEX_JSON), indent: nil, ensureAscii: false,
                             via: INDEX_JSON + ".tmp")
        // Last: says the index is whole and from which files.
        try PythonJSON.write(.object([("model", .string(model)), ("sources", sources), ("count", .int(pieces.count))]),
                             to: folder.appendingPathComponent(INDEX_SIG), indent: nil, ensureAscii: true,
                             via: INDEX_SIG + ".tmp")
        if unlink(folder.appendingPathComponent(INDEX_FAILED).path) != 0 && errno != ENOENT { throw posixError() }
        return pieces.count
    }

    /// `open(path, "wb")` and write: created 0666 less the umask, an existing file truncated.
    private static func writeFile(_ bytes: [UInt8], _ path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + done, bytes.count - done) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw posixError() }
            done += n
        }
    }

    private static func rename(_ from: URL, _ to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else { throw posixError() }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    /// Indexes the meetings without a current index (or `only` these), newest first; the number indexed. The encoder
    /// is made once, and only when there is something to index (it throws: out of here); a meeting that fails is
    /// marked (`.failed`, with its files' times) and skipped until its files change. `shouldStop` is asked before
    /// each meeting.
    @discardableResult
    public static func indexStale(outputDir: URL, encoder factory: () throws -> MeaningEncoder?, model: String = model,
                                  shouldStop: () -> Bool = { false }, only: [RecordingPaths]? = nil) throws -> Int {
        let todo = only ?? stale(outputDir: outputDir, model: model)
        var encoder: MeaningEncoder?
        var done = 0
        for paths in todo {
            if shouldStop() { break }
            if encoder == nil { encoder = try factory() }
            let started = ProcessInfo.processInfo.systemUptime
            let sources = signature(paths)
            let n: Int
            do {
                n = try indexMeeting(paths, encoder: encoder, model: model)
            } catch {
                log.error("indexing \(paths.id, privacy: .public) failed; trying again when its files change: \(String(describing: error), privacy: .public)")
                try? PythonJSON.write(.object([("sources", sources)]), to: paths.folder.appendingPathComponent(INDEX_FAILED),
                                      indent: nil, ensureAscii: true)
                continue
            }
            let seconds = ProcessInfo.processInfo.systemUptime - started
            log.info("indexed \(paths.id, privacy: .public): \(n) pieces in \(String(format: "%.1f", seconds), privacy: .public) s")
            done += 1
        }
        return done
    }

    // MARK: - Searching

    /// Whether a search by meaning can find anything: switched on, at least one meeting indexed, and the model on
    /// this Mac.
    public static func ready(outputDir: URL, model: String = model, stores: StorePaths = .current(),
                             modelFolder: (() -> URL?)? = nil) -> Bool {
        guard enabled(stores: stores) else { return false }
        guard meetings(outputDir).contains(where: {
            exists($0.folder.appendingPathComponent(INDEX_SIG)) && isCurrent($0, model: model)
        }) else { return false }
        return (modelFolder ?? { E5Encoder.modelFolder(stores: stores) })() != nil
    }

    /// The lowest score that counts as a hit among `scores`: SMALL_SCORE under MEDIAN_PIECES of them, else
    /// MARGIN above their median (numpy's, in float32), never below MIN_SCORE.
    public static func floor(_ scores: [Float]) -> Double {
        if scores.count < MEDIAN_PIECES { return SMALL_SCORE }
        let m = Double(median(scores)) + MARGIN
        return m > MIN_SCORE ? m : MIN_SCORE  // max(MIN_SCORE, m): the first unless m is greater
    }

    /// `np.median` of float32 values: NaN when one is; of an even count the two middle ones' float32 mean.
    static func median(_ xs: [Float]) -> Float {
        if xs.isEmpty || xs.contains(where: \.isNaN) { return .nan }
        let s = xs.sorted()
        let half = s.count / 2
        return s.count % 2 == 1 ? s[half] : (s[half - 1] + s[half]) / 2
    }
}

/// The `.npy` files of the index: numpy's format, written as `np.save` writes a float16 matrix and read as `np.load`
/// reads what numpy writes. Reading checks the header against the file and throws, never traps.
enum Npy {
    static let magic: [UInt8] = [0x93] + Array("NUMPY".utf8)
    /// numpy's `ARRAY_ALIGN` and `GROWTH_AXIS_MAX_DIGITS`.
    static let align = 64, growthDigits = 21

    /// `np.save` of a C-ordered `rows` × `columns` float16 array made from `values` (`astype(np.float16)`).
    static func float16<S: Sequence>(rows: Int, columns: Int, _ values: S) -> [UInt8] where S.Element == Float {
        var header = "{'descr': '<f2', 'fortran_order': False, 'shape': (\(rows), \(columns)), }"
        header += String(repeating: " ", count: max(0, growthDigits - String(rows).count))
        let hlen = header.utf8.count + 1
        let pad = align - ((magic.count + 2 + 2 + hlen) % align)
        let total = hlen + pad
        var out = magic + [1, 0, UInt8(total & 0xff), UInt8(total >> 8)]
        out += Array(header.utf8) + [UInt8](repeating: 0x20, count: pad) + [0x0a]
        out.reserveCapacity(out.count + rows * columns * 2)
        for v in values {
            let h = floatToHalf(v)
            out.append(UInt8(h & 0xff))
            out.append(UInt8(h >> 8))
        }
        return out
    }

    /// numpy's float32 → float16 on this Mac (`npy_floatbits_to_halfbits`, and NEON's `fcvt` for NaN): round half to even,
    /// overflow to infinity, a NaN quiet with the top of its payload.
    static func floatToHalf(_ value: Float) -> UInt16 {
        let f = value.bitPattern
        let sign = UInt16((f & 0x8000_0000) >> 16)
        var fexp = f & 0x7f80_0000
        if fexp >= 0x4780_0000 {
            if fexp == 0x7f80_0000 {
                let fsig = f & 0x007f_ffff
                if fsig != 0 { return sign + (0x7e00 | UInt16(fsig >> 13)) }  // NEON's fcvt: a quiet NaN, payload kept
            }
            return sign + 0x7c00
        }
        if fexp <= 0x3800_0000 {
            if fexp < 0x3300_0000 { return sign }
            fexp >>= 23
            var fsig = 0x0080_0000 + (f & 0x007f_ffff)
            fsig >>= (113 - fexp)
            if (fsig & 0x3fff) != 0x1000 || (f & 0x7ff) != 0 { fsig += 0x1000 }
            return sign + UInt16(fsig >> 13)
        }
        let hexp = UInt16((fexp - 0x3800_0000) >> 13)
        var fsig = f & 0x007f_ffff
        if (fsig & 0x3fff) != 0x1000 { fsig += 0x1000 }
        return sign + (UInt16(fsig >> 13) + hexp)
    }

    struct Matrix {
        let rows: Int
        let columns: Int
        /// Row by row, as float32 (`astype(np.float32)`).
        let values: [Float]
    }

    /// A two-dimensional `<f2`, `<f4` or `<f8` array (either byte order, C or Fortran order) as float32.
    static func read(_ data: Data) throws -> Matrix {
        func bad(_ m: String) -> SearchIndexError { SearchIndexError(description: "npy: \(m)") }
        let bytes = [UInt8](data)
        guard bytes.count >= 10, Array(bytes[0..<6]) == magic else { throw bad("no npy file") }
        let major = bytes[6]
        var hlen = 0, start = 0
        switch major {
        case 1:
            hlen = Int(bytes[8]) | Int(bytes[9]) << 8
            start = 10
        case 2, 3:
            guard bytes.count >= 12 else { throw bad("cut off") }
            hlen = (0..<4).reduce(0) { $0 | Int(bytes[8 + $1]) << (8 * $1) }
            start = 12
        default: throw bad("version \(major)")
        }
        guard hlen <= bytes.count - start else { throw bad("the header is longer than the file") }
        guard let header = String(bytes: bytes[start..<start + hlen], encoding: major == 3 ? .utf8 : .isoLatin1) else {
            throw bad("unreadable header")
        }
        let (descr, fortran, shape) = try parseHeader(header)
        guard shape.count == 2, shape.allSatisfy({ $0 >= 0 }) else { throw bad("shape \(shape) is no matrix") }
        guard descr.count == 3, let order = descr.first, "<>=|".contains(order), descr.dropFirst().first == "f",
              let size = Int(String(descr.last!)), [2, 4, 8].contains(size) else { throw bad("dtype \(descr)") }
        let swap = order == ">"
        let (rows, columns) = (shape[0], shape[1])
        let (count, o1) = rows.multipliedReportingOverflow(by: columns)
        let (length, o2) = count.multipliedReportingOverflow(by: size)
        let at = start + hlen
        guard !o1, !o2, length <= bytes.count - at else { throw bad("the data is shorter than its shape") }
        var flat = [Float](repeating: 0, count: count)
        bytes.withUnsafeBytes { raw in
            for i in 0..<count {
                let p = at + i * size
                switch size {
                case 2:
                    let h = raw.loadUnaligned(fromByteOffset: p, as: UInt16.self)
                    flat[i] = halfToFloat(swap ? h.byteSwapped : UInt16(littleEndian: h))
                case 4:
                    let b = raw.loadUnaligned(fromByteOffset: p, as: UInt32.self)
                    flat[i] = Float(bitPattern: swap ? b.byteSwapped : UInt32(littleEndian: b))
                default:
                    let b = raw.loadUnaligned(fromByteOffset: p, as: UInt64.self)
                    flat[i] = Float(Double(bitPattern: swap ? b.byteSwapped : UInt64(littleEndian: b)))
                }
            }
        }
        if fortran && rows > 1 && columns > 1 {
            var c = [Float](repeating: 0, count: count)
            for r in 0..<rows { for k in 0..<columns { c[r * columns + k] = flat[k * rows + r] } }
            flat = c
        }
        return Matrix(rows: rows, columns: columns, values: flat)
    }

    /// The `descr`, `fortran_order` and `shape` of the header's Python dict literal.
    private static func parseHeader(_ text: String) throws -> (String, Bool, [Int]) {
        func bad() -> SearchIndexError { SearchIndexError(description: "npy: header \(text.prefix(120))") }
        let s = Array(text.unicodeScalars)
        func value(_ key: String) throws -> ArraySlice<Unicode.Scalar> {
            for quote in ["'", "\""] {
                let k = Array((quote + key + quote).unicodeScalars)
                guard let i = (0...max(0, s.count - k.count)).first(where: { s.count >= k.count && Array(s[$0..<$0 + k.count]) == k })
                else { continue }
                var j = i + k.count
                while j < s.count, s[j] == " " { j += 1 }
                guard j < s.count, s[j] == ":" else { throw bad() }
                j += 1
                while j < s.count, s[j] == " " { j += 1 }
                return s[j...]
            }
            throw bad()
        }
        let d = try value("descr")
        guard let q = d.first, q == "'" || q == "\"", let end = d.dropFirst().firstIndex(of: q) else { throw bad() }
        let descr = String(String.UnicodeScalarView(d[d.startIndex + 1 ..< end]))
        let f = String(String.UnicodeScalarView(try value("fortran_order")))
        let fortran: Bool
        if f.hasPrefix("True") { fortran = true } else if f.hasPrefix("False") { fortran = false } else { throw bad() }
        let sh = try value("shape")
        guard sh.first == "(", let close = sh.firstIndex(of: ")") else { throw bad() }
        let inner = String(String.UnicodeScalarView(sh[sh.startIndex + 1 ..< close]))
        let shape = try inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { part -> Int in
                guard let n = Int(part.hasSuffix("L") ? String(part.dropLast()) : part) else { throw bad() }
                return n
            }
        return (descr, fortran, shape)
    }
}
