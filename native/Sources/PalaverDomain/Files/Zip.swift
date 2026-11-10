// Zip files as Python's `zipfile` reads and writes them, and exchange's rules for a meeting's zip (exchange.py:563-676,
// issue #58).
//
// `ZipReader` reads the table of contents as `zipfile.ZipFile` does (the end record found the same way, zip64 records
// and extra fields, a zip appended to other data, names in UTF-8 or cp437 cut at a NUL, the Unicode path field) and an
// entry's data as `ZipFile.open` does: its local header checked against the directory, no entry running into the next
// ("overlapped entries", a zip bomb), never more than the size the directory gives, the CRC checked at the end. Only
// stored (0) and deflated (8) entries are read, never an encrypted one. The file is untrusted: every size and offset is
// checked against the file and for overflow before anything is allocated, and whatever does not fit throws `ZipError`;
// nothing traps. Entry names are data, never paths: nothing here creates a file from one.
//
// `ZipWriter` writes what `ZipFile.writestr` and `ZipFile.write` write (no zip64: an entry or offset beyond 4 GiB
// throws). Deflate is raw DEFLATE through Compression's `COMPRESSION_ZLIB`, so the compressed bytes are not zlib's; any
// reader reads them.
//
// `ExchangeZip` holds exchange's caps and its checks of a meeting's zip: `precheck` (`_precheck`), `entries`
// (`_entries`, `_root`, `_SKIPPED`, `_FOLDERS`) and `readEntry` (`_read_entry`), each refusing with Python's words.
import Compression
import CryptoKit
import Darwin
import Foundation
import PalaverCore

/// What `zipfile` raises reading a zip (`BadZipFile` and its other errors), in its words where it has them.
public enum ZipError: Error, Equatable, CustomStringConvertible {
    /// The file or its table of contents is no zip this reader reads (`BadZipFile` when opening).
    case notAZip(String)
    /// An entry's data or local header is broken: a bad CRC, broken deflate data, a header that doesn't fit.
    case damaged(String)
    /// Not done here: another compression method, encryption, patched data, a table of contents over the cap, zip64
    /// on writing.
    case refused(String)
    /// `read(limit:)` got more than `limit` bytes.
    case overLimit
    /// A system call failed (errno).
    case io(Int32)

    public var description: String {
        switch self {
        case .notAZip(let m), .damaged(let m), .refused(let m): return m
        case .overLimit: return "more than the limit"
        case .io(let e): return String(cString: strerror(e))
        }
    }
}

/// One entry of a zip's table of contents, as `zipfile.ZipInfo` has it.
public struct ZipEntry: Sendable {
    /// `filename`: decoded (UTF-8 with flag bit 11, else cp437), cut at a NUL, or the Unicode path extra field's.
    public let name: String
    public let flagBits: UInt16
    /// `compress_type`: 0 stored, 8 deflated.
    public let method: UInt16
    public let crc: UInt32
    public let compressedSize: UInt64
    /// `file_size`: what the entry unpacks to, by the directory.
    public let size: UInt64
    public let externalAttr: UInt32
    /// Where its local header is, in the file.
    public let headerOffset: UInt64
    /// `orig_filename`: the name as decoded, before it was cut at a NUL (the local header must spell it so).
    let originalName: String
    /// Where the next entry's header (or the directory) starts: the entry's data must end before.
    fileprivate(set) var endOffset: UInt64

    /// `is_dir()`: the name ends with "/".
    public var isDir: Bool { name.unicodeScalars.last == "/" }
    /// `S_ISLNK(external_attr >> 16)`.
    public var isSymlink: Bool { (externalAttr >> 16) & 0o170000 == 0o120000 }
}

/// CRC-32 as zlib's `crc32` (the zip checksum), eight bytes at a time.
public enum CRC32 {
    static let tables: [[UInt32]] = {
        var t = [[UInt32]](repeating: [UInt32](repeating: 0, count: 256), count: 8)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            t[0][i] = c
        }
        for i in 0..<256 { for k in 1..<8 { t[k][i] = (t[k - 1][i] >> 8) ^ t[0][Int(t[k - 1][i] & 0xFF)] } }
        return t
    }()

    public static func update(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var c = ~crc
        let t = tables
        var p = 0, n = bytes.count
        t[0].withUnsafeBufferPointer { t0 in t[1].withUnsafeBufferPointer { t1 in t[2].withUnsafeBufferPointer { t2 in
        t[3].withUnsafeBufferPointer { t3 in t[4].withUnsafeBufferPointer { t4 in t[5].withUnsafeBufferPointer { t5 in
        t[6].withUnsafeBufferPointer { t6 in t[7].withUnsafeBufferPointer { t7 in
            while n >= 8 {
                let lo = c ^ (UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24)
                let hi = UInt32(bytes[p + 4]) | UInt32(bytes[p + 5]) << 8 | UInt32(bytes[p + 6]) << 16 | UInt32(bytes[p + 7]) << 24
                c = t7[Int(lo & 0xFF)] ^ t6[Int(lo >> 8 & 0xFF)] ^ t5[Int(lo >> 16 & 0xFF)] ^ t4[Int(lo >> 24)]
                    ^ t3[Int(hi & 0xFF)] ^ t2[Int(hi >> 8 & 0xFF)] ^ t1[Int(hi >> 16 & 0xFF)] ^ t0[Int(hi >> 24)]
                p += 8
                n -= 8
            }
            while n > 0 {
                c = t0[Int((c ^ UInt32(bytes[p])) & 0xFF)] ^ (c >> 8)
                p += 1
                n -= 1
            }
        } } } } } } } }
        return ~c
    }

    public static func checksum(_ data: Data) -> UInt32 { data.withUnsafeBytes { update(0, $0) } }
}

/// Raw DEFLATE through Compression (`COMPRESSION_ZLIB`), fed in pieces.
final class Deflate {
    private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    private var buffer = [UInt8](repeating: 0, count: 1 << 16)
    private(set) var ended = false
    /// How many bytes came out so far.
    private(set) var produced = 0
    private let encode: Bool

    init(encode: Bool) throws {
        self.encode = encode
        guard compression_stream_init(stream, encode ? COMPRESSION_STREAM_ENCODE : COMPRESSION_STREAM_DECODE,
                                      COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            stream.deallocate()
            throw ZipError.refused("Compression can't start a stream")
        }
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
    }

    /// Feeds `input` (`finish`: the last of it) and hands what comes out to `out`. Decoding stops at the end of the
    /// deflate stream (`ended`); bytes after it are ignored. Broken data throws `ZipError.damaged`; a stream that is
    /// only cut short ends quietly when finished (zlib's `flush` returns what it has; the CRC tells).
    /// `out` answers whether it takes more: once it says no, nothing more is inflated (zlib's `max_length`: an entry
    /// whose size is reached is not inflated further, whatever its compressed data would still unpack to).
    func process(_ input: UnsafeRawBufferPointer, finish: Bool, _ out: (UnsafeRawBufferPointer) throws -> Bool) throws {
        try run(input, finalize: false, out)
        if finish { try run(UnsafeRawBufferPointer(start: nil, count: 0), finalize: true, out) }
    }

    private static let none = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)

    private func run(_ input: UnsafeRawBufferPointer, finalize: Bool, _ out: (UnsafeRawBufferPointer) throws -> Bool) throws {
        guard !ended else { return }
        stream.pointee.src_ptr = input.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafePointer(Self.none)
        stream.pointee.src_size = input.count
        while true {
            let before = stream.pointee.src_size
            let status: compression_status = buffer.withUnsafeMutableBufferPointer { buf in
                stream.pointee.dst_ptr = buf.baseAddress!
                stream.pointee.dst_size = buf.count
                return compression_stream_process(stream, finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
            }
            let produced = buffer.count - stream.pointee.dst_size
            self.produced += produced
            if produced > 0, try !buffer.withUnsafeBytes({ try out(UnsafeRawBufferPointer(rebasing: $0[..<produced])) }) {
                ended = true  // nothing more is wanted
                return
            }
            switch status {
            case COMPRESSION_STATUS_END:
                ended = true
                return
            case COMPRESSION_STATUS_OK:
                if stream.pointee.dst_size == 0 { continue }  // the buffer filled: there may be more
                if produced == 0 && stream.pointee.src_size == before {  // nothing more comes of this input
                    if finalize { ended = true }
                    return
                }
                if stream.pointee.src_size == 0 && !finalize { return }
            default:
                if encode { throw ZipError.refused("Compression failed to deflate") }
                if finalize { ended = true; return }
                throw ZipError.damaged("Error -3 while decompressing data")
            }
        }
    }
}

// MARK: - Reading

public final class ZipReader {
    /// `infolist()`: the table of contents in its order (a name may come twice).
    public let entries: [ZipEntry]
    private let fd: Int32
    private let fileSize: UInt64
    static let CHUNK = 1 << 20
    /// What the last `read` inflated (for the tests: an entry's size reached, nothing more is inflated).
    private(set) var lastInflated = 0

    /// Opens `url` and reads its table of contents, refusing one larger than `maxDirectoryBytes` before reading it.
    public init(url: URL, maxDirectoryBytes: Int) throws {
        fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ZipError.io(errno) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { let e = errno; Darwin.close(fd); throw ZipError.io(e) }
        fileSize = UInt64(max(0, st.st_size))
        do {
            entries = try Self.directory(fd, fileSize, maxDirectoryBytes)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    deinit { Darwin.close(fd) }

    /// `pread` of up to `count` bytes at `offset` (fewer at the end of the file).
    static func read(_ fd: Int32, at offset: UInt64, count: Int) throws -> [UInt8] {
        guard count > 0, offset < UInt64(Int64.max) else { return [] }
        var out = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = out.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done)) }
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw ZipError.io(errno) }
            if n == 0 { break }
            done += n
        }
        out.removeSubrange(done...)
        return out
    }

    static func le16(_ b: ArraySlice<UInt8>, _ at: Int) -> UInt16 { UInt16(b[b.startIndex + at]) | UInt16(b[b.startIndex + at + 1]) << 8 }
    static func le32(_ b: ArraySlice<UInt8>, _ at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[b.startIndex + at + $1]) << (8 * $1) }
    }
    static func le64(_ b: ArraySlice<UInt8>, _ at: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[b.startIndex + at + $1]) << (8 * $1) }
    }

    static let END: [UInt8] = [0x50, 0x4B, 0x05, 0x06]

    /// `_EndRecData` and `_EndRecData64`: the directory's size and offset, and where the end record is.
    static func endRecord(_ fd: Int32, _ size: UInt64) throws -> (dirSize: UInt64, dirOffset: UInt64, location: UInt64, zip64: Bool) {
        let notAZip = ZipError.notAZip("File is not a zip file")
        guard size >= 22 else { throw notAZip }
        let record: ArraySlice<UInt8>
        let location: UInt64
        let last = try read(fd, at: size - 22, count: 22)
        if last.count == 22, Array(last[0..<4]) == END, last[20] == 0, last[21] == 0 {
            record = last[...]
            location = size - 22
        } else {
            let start = size > 22 + 0xFFFF ? size - 22 - 0xFFFF : 0
            let tail = try read(fd, at: start, count: Int(size - start))
            guard let at = lastIndex(of: END, in: tail), tail.count - at >= 22 else { throw notAZip }
            record = tail[at..<at + 22]
            location = start + UInt64(at)
        }
        var dirSize = UInt64(le32(record, 12)), dirOffset = UInt64(le32(record, 16)), zip64 = false
        // The zip64 locator (20 bytes) and end record (56 bytes) just before it, when there are.
        if location >= 20 {
            let locator = try read(fd, at: location - 20, count: 20)
            if locator.count == 20, Array(locator[0..<4]) == [0x50, 0x4B, 0x06, 0x07] {
                if le32(locator[...], 4) != 0 || le32(locator[...], 16) > 1 {
                    throw ZipError.notAZip("zipfiles that span multiple disks are not supported")
                }
                if location >= 76 {
                    let end64 = try read(fd, at: location - 76, count: 56)
                    if end64.count == 56, Array(end64[0..<4]) == [0x50, 0x4B, 0x06, 0x06] {
                        dirSize = le64(end64[...], 40)
                        dirOffset = le64(end64[...], 48)
                        zip64 = true
                    }
                }
            }
        }
        return (dirSize, dirOffset, location, zip64)
    }

    static func lastIndex(of needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        var i = hay.count - needle.count
        while i >= 0 {
            if hay[i] == needle[0] && hay[i + 1] == needle[1] && hay[i + 2] == needle[2] && hay[i + 3] == needle[3] { return i }
            i -= 1
        }
        return nil
    }

    /// `_RealGetContents`.
    static func directory(_ fd: Int32, _ size: UInt64, _ maxDirectoryBytes: Int) throws -> [ZipEntry] {
        let end = try endRecord(fd, size)
        // concat: bytes before the zip (a zip appended to other data); start_dir = offset + concat.
        let badOffset = ZipError.notAZip("Bad offset for central directory")
        guard end.dirSize <= UInt64(Int64.max / 4), end.dirOffset <= UInt64(Int64.max / 4) else { throw badOffset }
        let concat = Int64(end.location) - Int64(end.dirSize) - Int64(end.dirOffset) - (end.zip64 ? 76 : 0)
        let startDir = Int64(end.dirOffset) + concat
        guard startDir >= 0 else { throw badOffset }
        guard end.dirSize <= UInt64(maxDirectoryBytes) else {
            throw ZipError.refused("The table of contents is larger than \(maxDirectoryBytes) bytes")
        }
        let dirSize = Int(end.dirSize)
        let data = UInt64(startDir) < size ? try read(fd, at: UInt64(startDir), count: dirSize) : []
        var at = 0
        func take(_ n: Int) -> ArraySlice<UInt8> {  // BytesIO.read(n): what is there
            let from = min(at, data.count), to = min(at + n, data.count)
            at += n
            return data[from..<to]
        }
        var raw: [ZipEntry] = []
        var total = 0
        while total < dirSize {
            let fixed = take(46)
            guard fixed.count == 46 else { throw ZipError.notAZip("Truncated central directory") }
            guard Array(fixed.prefix(4)) == [0x50, 0x4B, 0x01, 0x02] else {
                throw ZipError.notAZip("Bad magic number for central directory")
            }
            let extractVersion = fixed[fixed.startIndex + 6]
            let flags = le16(fixed, 8), method = le16(fixed, 10), crc = le32(fixed, 16)
            var compressed = UInt64(le32(fixed, 20)), usize = UInt64(le32(fixed, 24))
            let nameLen = Int(le16(fixed, 28)), extraLen = Int(le16(fixed, 30)), commentLen = Int(le16(fixed, 32))
            let external = le32(fixed, 38)
            var offset = UInt64(le32(fixed, 42))
            let nameBytes = Array(take(nameLen))
            let extra = Array(take(extraLen))
            _ = take(commentLen)
            guard let decoded = decodeName(nameBytes, utf8: flags & 0x800 != 0) else {
                throw ZipError.notAZip("'utf-8' codec can't decode the name of an entry")
            }
            if extractVersion > 63 {
                throw ZipError.notAZip("zip file version \(extractVersion / 10).\(extractVersion % 10)")
            }
            var name = sanitized(decoded)
            // _decodeExtra
            var e = extra[...]
            while e.count >= 4 {
                let tp = le16(e, 0), ln = Int(le16(e, 2))
                guard ln + 4 <= e.count else {
                    throw ZipError.notAZip(String(format: "Corrupt extra field %04x (size=%d)", tp, ln))
                }
                var field = e[(e.startIndex + 4)..<(e.startIndex + 4 + ln)]
                if tp == 0x0001 {
                    func next(_ what: String) throws -> UInt64 {
                        guard field.count >= 8 else { throw ZipError.notAZip("Corrupt zip64 extra field. \(what) not found.") }
                        defer { field = field.dropFirst(8) }
                        return le64(field, 0)
                    }
                    if usize == 0xFFFF_FFFF { usize = try next("File size") }
                    if compressed == 0xFFFF_FFFF { compressed = try next("Compress size") }
                    if offset == 0xFFFF_FFFF { offset = try next("Header offset") }
                } else if tp == 0x7075 {
                    guard field.count >= 5 else { throw ZipError.notAZip("Corrupt unicode path extra field (0x7075)") }
                    if field[field.startIndex] == 1, le32(field, 1) == nameBytes.withUnsafeBytes({ CRC32.update(0, $0) }) {
                        guard let unicode = String(validating: field.dropFirst(5), as: UTF8.self) else {
                            throw ZipError.notAZip("Corrupt unicode path extra field (0x7075): invalid utf-8 bytes")
                        }
                        if !unicode.isEmpty { name = sanitized(unicode) }
                    }
                }
                e = e.dropFirst(4 + ln)
            }
            let (header, over) = Int64(clamping: offset).addingReportingOverflow(concat)
            guard !over, offset <= UInt64(Int64.max / 2), header >= 0 else { throw ZipError.notAZip("Bad offset for an entry") }
            raw.append(ZipEntry(name: name, flagBits: flags, method: method, crc: crc, compressedSize: compressed, size: usize,
                                externalAttr: external, headerOffset: UInt64(header), originalName: decoded, endOffset: 0))
            total += 46 + nameLen + extraLen + commentLen
        }
        // _end_offset: the next header by offset (a stable sort, highest first), or the directory.
        var next = UInt64(startDir)
        let order = raw.indices.sorted { a, b in
            raw[a].headerOffset > raw[b].headerOffset || (raw[a].headerOffset == raw[b].headerOffset && a < b)
        }
        for i in order {
            raw[i].endOffset = next
            next = raw[i].headerOffset
        }
        return raw
    }

    /// The name as zipfile decodes it: UTF-8 (strict) with flag bit 11, else cp437.
    static func decodeName(_ bytes: [UInt8], utf8: Bool) -> String? {
        if utf8 { return String(validating: bytes, as: UTF8.self) }
        var out = String.UnicodeScalarView()
        for b in bytes { out.append(b < 0x80 ? Unicode.Scalar(b) : CP437[Int(b - 0x80)]) }
        return String(out)
    }

    /// `_sanitize_filename`: cut at the first NUL.
    static func sanitized(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.prefix { $0 != "\0" }))
    }

    /// cp437's upper half.
    static let CP437: [Unicode.Scalar] = Array(
        "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{A0}"
            .unicodeScalars)

    /// `repr(name)`.
    static func repr(_ s: String) -> String { MyNotes.pyRepr(.string(s)) }

    /// `repr(bytes)`.
    static func repr(_ b: [UInt8]) -> String {
        let quote: UInt8 = b.contains(0x27) && !b.contains(0x22) ? 0x22 : 0x27
        var out = "b" + String(UnicodeScalar(quote))
        for c in b {
            switch c {
            case quote, 0x5C: out += "\\" + String(UnicodeScalar(c))
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x20..<0x7F: out += String(UnicodeScalar(c))
            default: out += String(format: "\\x%02x", c)
            }
        }
        return out + String(UnicodeScalar(quote))
    }

    /// The entry's bytes, handed to `sink` in pieces of at most 1 MiB, as `ZipFile.open(entry).read()` gives them:
    /// never more than `entry.size`, the CRC checked once all is read. More than `limit` bytes throws `overLimit`
    /// before `sink` sees them. What `sink` throws comes out as it is.
    public func read(_ entry: ZipEntry, limit: Int, sink: (Data) throws -> Void) throws {
        let header = try Self.read(fd, at: entry.headerOffset, count: 30)
        guard header.count == 30 else { throw ZipError.damaged("Truncated file header") }
        guard Array(header[0..<4]) == [0x50, 0x4B, 0x03, 0x04] else { throw ZipError.damaged("Bad magic number for file header") }
        let localFlags = Self.le16(header[...], 6)
        let nameLen = Int(Self.le16(header[...], 26)), extraLen = Int(Self.le16(header[...], 28))
        let localName = try Self.read(fd, at: entry.headerOffset + 30, count: nameLen)
        if entry.flagBits & 0x20 != 0 { throw ZipError.refused("compressed patched data (flag bit 5)") }
        if entry.flagBits & 0x40 != 0 { throw ZipError.refused("strong encryption (flag bit 6)") }
        guard let decoded = Self.decodeName(localName, utf8: localFlags & 0x800 != 0), Py.same(decoded, entry.originalName) else {
            throw ZipError.damaged("File name in directory \(Self.repr(entry.originalName)) and header \(Self.repr(localName)) differ.")
        }
        let dataStart = entry.headerOffset + 30 + UInt64(nameLen) + UInt64(extraLen)
        let (dataEnd, over) = dataStart.addingReportingOverflow(entry.compressedSize)
        guard !over, dataEnd <= entry.endOffset else {
            throw ZipError.damaged("Overlapped entries: \(Self.repr(entry.originalName)) (possible zip bomb)")
        }
        if entry.flagBits & 0x1 != 0 {
            throw ZipError.refused("File \(Self.repr(entry.name)) is encrypted, password required for extraction")
        }
        guard entry.method == 0 || entry.method == 8 else { throw ZipError.refused("That compression method is not supported") }

        var left = entry.size  // what may still come out
        var compressedLeft = entry.compressedSize
        var position = dataStart
        var crc: UInt32 = 0
        var total = 0
        var pending = Data()
        @discardableResult
        func emit(_ bytes: UnsafeRawBufferPointer) throws -> Bool {
            guard left > 0 else { return false }
            let piece = UnsafeRawBufferPointer(rebasing: bytes.prefix(Int(min(UInt64(bytes.count), left))))
            left -= UInt64(piece.count)
            crc = CRC32.update(crc, piece)
            pending.append(contentsOf: piece)
            while pending.count >= Self.CHUNK { try flush(Self.CHUNK) }
            return left > 0
        }
        func flush(_ n: Int) throws {
            let chunk = pending.prefix(n)
            total += chunk.count
            guard total <= limit else { throw ZipError.overLimit }
            try sink(Data(chunk))
            pending.removeFirst(chunk.count)
        }
        let inflater = entry.method == 8 ? try Deflate(encode: false) : nil
        while left > 0 && compressedLeft > 0 && !(inflater?.ended ?? false) {
            let n = Int(min(UInt64(Self.CHUNK), compressedLeft))
            let block = try Self.read(fd, at: position, count: n)
            guard !block.isEmpty else { throw ZipError.damaged("") }  // EOFError
            position += UInt64(block.count)
            compressedLeft -= UInt64(block.count)
            try block.withUnsafeBytes { bytes in
                if let inflater {
                    try inflater.process(bytes, finish: compressedLeft == 0, emit)
                } else {
                    try emit(bytes)
                }
            }
        }
        lastInflated = inflater?.produced ?? 0
        if !pending.isEmpty { try flush(pending.count) }
        guard crc == entry.crc else { throw ZipError.damaged("Bad CRC-32 for file \(Self.repr(entry.name))") }
    }

    /// The entry's bytes (`read` into one `Data`).
    public func data(_ entry: ZipEntry, limit: Int) throws -> Data {
        var out = Data()
        try read(entry, limit: limit) { out.append($0) }
        return out
    }
}

// MARK: - Writing

/// A zip written entry by entry, as `zipfile.ZipFile(path, "w")` writes it; `finish` writes the table of contents.
public final class ZipWriter {
    private var fd: Int32
    private var offset: UInt64 = 0
    private var directory: [UInt8] = []
    private var count = 0
    private var finished = false

    /// Creates (or truncates) the file at `url`.
    public init(url: URL) throws {
        fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw ZipError.io(errno) }
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    /// `writestr(name, data, compress_type=ZIP_DEFLATED if deflate else ZIP_STORED)`: dated now, mode 0600.
    public func add(name: String, data: Data, deflate: Bool) throws {
        let mode: UInt32 = name.unicodeScalars.last == "/" ? (0o40775 << 16) | 0x10 : 0o600 << 16
        try entry(name: name, date: Date(), external: mode, deflate: deflate) { write in
            try data.withUnsafeBytes { try write($0) }
        }
    }

    /// `write(file, name, compress_type=ZIP_STORED if stored else ZIP_DEFLATED)`: dated and moded as the file, read in
    /// pieces.
    public func add(name: String, file: URL, stored: Bool) throws {
        let input = Darwin.open(file.path, O_RDONLY | O_CLOEXEC)
        guard input >= 0 else { throw ZipError.io(errno) }
        defer { Darwin.close(input) }
        var st = stat()
        guard fstat(input, &st) == 0 else { throw ZipError.io(errno) }
        let mtime = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))
        try entry(name: name, date: mtime, external: UInt32(st.st_mode) << 16, deflate: !stored) { write in
            var buffer = [UInt8](repeating: 0, count: ZipReader.CHUNK)
            while true {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress!, $0.count) }
                if n < 0 && errno == EINTR { continue }
                guard n >= 0 else { throw ZipError.io(errno) }
                if n == 0 { break }
                try buffer.withUnsafeBytes { try write(UnsafeRawBufferPointer(rebasing: $0[..<n])) }
            }
        }
    }

    /// Writes the table of contents and the end record, and closes the file.
    public func finish() throws {
        guard !finished else { return }
        guard count <= 0xFFFF, offset <= 0xFFFF_FFFF, UInt64(directory.count) <= 0xFFFF_FFFF else {
            throw ZipError.refused("A zip this large needs zip64")
        }
        var end: [UInt8] = [0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0]
        end += Self.le(UInt64(count), 2) + Self.le(UInt64(count), 2) + Self.le(UInt64(directory.count), 4) + Self.le(offset, 4) + [0, 0]
        try write(directory)
        try write(end)
        finished = true
        guard Darwin.close(fd) == 0 else { fd = -1; throw ZipError.io(errno) }
        fd = -1
    }

    static func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

    private func write(_ bytes: [UInt8]) throws { try bytes.withUnsafeBytes { try write($0) } }

    private func write(_ bytes: UnsafeRawBufferPointer) throws {
        var done = 0
        while done < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress! + done, bytes.count - done)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ZipError.io(errno) }
            done += n
        }
        offset += UInt64(bytes.count)
    }

    /// DOS date and time of `date` in local time, as `time.localtime` gives them (1980 at the earliest).
    static func dosTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        var t = time_t(date.timeIntervalSince1970.rounded(.down))
        var tm = Darwin.tm()
        localtime_r(&t, &tm)
        let year = max(1980, Int(tm.tm_year) + 1900)
        let d = (year - 1980) << 9 | Int(tm.tm_mon + 1) << 5 | Int(tm.tm_mday)
        let time = Int(tm.tm_hour) << 11 | Int(tm.tm_min) << 5 | Int(tm.tm_sec) / 2
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: d))
    }

    /// The local header, the data `body` gives (deflated or as it is), then the header again with its CRC and sizes,
    /// and the entry's directory record.
    private func entry(name: String, date: Date, external: UInt32, deflate: Bool,
                       body: ((UnsafeRawBufferPointer) throws -> Void) throws -> Void) throws {
        guard !finished else { throw ZipError.refused("The zip is finished") }
        let nameBytes = Array(name.utf8)
        guard nameBytes.count <= 0xFFFF else { throw ZipError.refused("The name is too long") }
        guard offset <= 0xFFFF_FFFF else { throw ZipError.refused("A zip this large needs zip64") }
        let flags: UInt16 = name.unicodeScalars.allSatisfy(\.isASCII) ? 0 : 0x800
        let method: UInt16 = deflate ? 8 : 0
        let (dosTime, dosDate) = Self.dosTime(date)
        let headerOffset = offset
        func header(crc: UInt32, compressed: UInt64, size: UInt64) -> [UInt8] {
            [0x50, 0x4B, 0x03, 0x04] + [20, 0] + Self.le(UInt64(flags), 2) + Self.le(UInt64(method), 2)
                + Self.le(UInt64(dosTime), 2) + Self.le(UInt64(dosDate), 2) + Self.le(UInt64(crc), 4)
                + Self.le(compressed, 4) + Self.le(size, 4) + Self.le(UInt64(nameBytes.count), 2) + [0, 0] + nameBytes
        }
        try write(header(crc: 0, compressed: 0, size: 0))
        let dataStart = offset
        var crc: UInt32 = 0
        var size: UInt64 = 0
        let deflater = deflate ? try Deflate(encode: true) : nil
        func out(_ bytes: UnsafeRawBufferPointer) throws -> Bool { try write(bytes); return true }
        try body { bytes in
            crc = CRC32.update(crc, bytes)
            size += UInt64(bytes.count)
            if let deflater { try deflater.process(bytes, finish: false, out) } else { _ = try out(bytes) }
        }
        if let deflater { try deflater.process(UnsafeRawBufferPointer(start: nil, count: 0), finish: true, out) }
        let compressed = offset - dataStart
        guard size <= 0xFFFF_FFFF, compressed <= 0xFFFF_FFFF else { throw ZipError.refused("A zip this large needs zip64") }
        let patched = header(crc: crc, compressed: compressed, size: size)
        try patched.withUnsafeBytes { bytes in
            guard pwrite(fd, bytes.baseAddress!, bytes.count, off_t(headerOffset)) == bytes.count else { throw ZipError.io(errno) }
        }
        directory += [0x50, 0x4B, 0x01, 0x02, 20, 3, 20, 0] + Self.le(UInt64(flags), 2) + Self.le(UInt64(method), 2)
            + Self.le(UInt64(dosTime), 2) + Self.le(UInt64(dosDate), 2) + Self.le(UInt64(crc), 4) + Self.le(compressed, 4)
            + Self.le(size, 4) + Self.le(UInt64(nameBytes.count), 2) + [0, 0, 0, 0, 0, 0, 0, 0] + Self.le(UInt64(external), 4)
            + Self.le(headerOffset, 4) + nameBytes
        count += 1
    }
}

// MARK: - A meeting's zip (exchange.py)

public enum ExchangeZip {
    public static let MAX_ENTRIES = 64
    /// A folder compressed again in Finder (Safari unpacks a downloaded zip) adds its folders, __MACOSX/, .DS_Store
    /// and ._ files: entries skipped, never read.
    public static let MAX_RAW_ENTRIES = 4 * MAX_ENTRIES
    public static let MAX_JSON_BYTES = 16 * 1024 * 1024
    public static let MAX_AUDIO_BYTES = 600 * 1024 * 1024
    public static let MAX_TOTAL_BYTES = 1300 * 1024 * 1024
    /// The file itself: what it unpacks to, and its zip headers.
    public static let MAX_FILE_BYTES = 1400 * 1024 * 1024
    /// The zip's table of contents: 256 entries need a few KB.
    public static let MAX_DIRECTORY_BYTES = 64 * 1024
    public static let END_OF_DIRECTORY: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    public static let NOT_EXPORTED = "This zip is not a meeting exported from Palaver: it has no manifest.json."
    static let CHUNK = 1 << 20

    /// The caps, each one a test may lower (Python's tests monkeypatch the module's constants).
    public struct Caps: Sendable {
        public var maxEntries = MAX_ENTRIES
        public var maxRawEntries = MAX_RAW_ENTRIES
        public var maxJSONBytes = MAX_JSON_BYTES
        public var maxAudioBytes = MAX_AUDIO_BYTES
        public var maxTotalBytes = MAX_TOTAL_BYTES
        public var maxFileBytes = MAX_FILE_BYTES
        public var maxDirectoryBytes = MAX_DIRECTORY_BYTES
        public static let standard = Caps()
    }

    /// `_NAME`: the files an exported meeting has.
    static let NAME = try! PyRegex(#"manifest\.json|meeting/(meta|calendar|transcript|turns|speakers|notes)\.json"#
                                   + #"|voices/SPEAKER_\d{1,3}\.json|audio/(system|mic)\.(opus|flac)"#)
    static let SKIPPED = try! PyRegex(#"__MACOSX/.*|(.*/)?(\.DS_Store|\._[^/]+)"#)
    static let FOLDERS = ["", "meeting/", "voices/", "audio/"]
    static let MB = 1024 * 1024

    static func repr(_ s: String) -> String { MyNotes.pyRepr(.string(s)) }
    static func prefix(_ s: String, _ n: Int) -> String { String(String.UnicodeScalarView(s.unicodeScalars.prefix(n))) }

    /// `_precheck`: the file's size and its table of contents, read from its end record before the table is read.
    public static func precheck(_ url: URL, caps: Caps) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ExchangeRejected("The file can't be read.") }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw ExchangeRejected("The file can't be read.") }
        let size = Int(st.st_size)
        if size > caps.maxFileBytes { throw ExchangeRejected("The file is too large (\(size / MB) MB).") }
        let start = max(0, size - 22 - 0xFFFF)  // the end record, behind at most a 64 KB comment
        guard let tail = try? ZipReader.read(fd, at: UInt64(start), count: size - start) else {
            throw ExchangeRejected("The file can't be read.")
        }
        guard let at = ZipReader.lastIndex(of: END_OF_DIRECTORY, in: tail), tail.count - at >= 22 else {
            throw ExchangeRejected("This is not a zip.")
        }
        let entries = Int(ZipReader.le16(tail[...], at + 10))
        let directory = Int(ZipReader.le32(tail[...], at + 12))
        if entries > caps.maxRawEntries {
            throw ExchangeRejected("The zip has \(entries) entries; an exported meeting has at most \(caps.maxEntries).")
        }
        if directory > caps.maxDirectoryBytes {
            throw ExchangeRejected("The zip's table of contents is too large for an exported meeting.")
        }
    }

    /// `_precheck`, then `zipfile.ZipFile(path)`: the zip, its table of contents read.
    public static func open(_ url: URL, caps: Caps = .standard) throws -> ZipReader {
        try precheck(url, caps: caps)
        do {
            return try ZipReader(url: url, maxDirectoryBytes: caps.maxDirectoryBytes)
        } catch {
            throw ExchangeRejected("This is not a zip.")
        }
    }

    static func unsafe(_ name: String) -> Bool {
        let u = name.unicodeScalars
        return u.first == "/" || u.first == "\\" || u.contains("\\") || u.contains(":")
            || parts(name).contains { $0.isEmpty || Py.same($0, ".") || Py.same($0, "..") }
    }

    /// `name.split("/")`, by code points: "/" followed by a combining mark is one Character but still a separator.
    static func parts(_ name: String) -> [String] {
        name.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
    }

    static func cap(_ name: String, _ caps: Caps) -> Int {
        name.unicodeScalars.starts(with: "audio/".unicodeScalars) ? caps.maxAudioBytes : caps.maxJSONBytes
    }

    /// `_entries`: the zip's root folder ("" or `<folder>/`) and its entries by their name under it, refused unless
    /// every one is a file an exported meeting has, of a size it takes, stored or deflated, not encrypted, not a link.
    /// Finder's additions (folders, `__MACOSX/`, `.DS_Store`, `._` files) are skipped.
    public static func entries(_ zip: ZipReader, caps: Caps = .standard) throws -> (root: String, entries: PyDict<ZipEntry>) {
        let infos = zip.entries
        if infos.count > caps.maxRawEntries {
            throw ExchangeRejected("The zip has \(infos.count) entries; an exported meeting has at most \(caps.maxEntries).")
        }
        var kept: [ZipEntry] = []
        for info in infos {
            let name = info.name
            var bare = name
            if bare.unicodeScalars.last == "/" { bare = String(String.UnicodeScalarView(bare.unicodeScalars.dropLast())) }
            if unsafe(bare) { throw ExchangeRejected("The zip has an unsafe path: \(repr(prefix(name, 80))).") }
            if info.isSymlink { throw ExchangeRejected("The zip has a link, which Palaver never follows: \(repr(prefix(name, 80))).") }
            if SKIPPED.fullMatch(name) == nil { kept.append(info) }
        }
        let root = try self.root(kept.map(\.name))
        let rootLength = root.unicodeScalars.count
        var out = PyDict<ZipEntry>()
        var total = 0
        for info in kept {
            let name = String(String.UnicodeScalarView(info.name.unicodeScalars.dropFirst(rootLength)))
            if info.isDir {
                guard FOLDERS.contains(where: { Py.same($0, name) }) else {
                    throw ExchangeRejected("The zip has the folder \(repr(prefix(info.name, 80))), which an exported meeting doesn't.")
                }
                continue
            }
            guard NAME.fullMatch(name) != nil else {
                throw ExchangeRejected("The zip has \(repr(prefix(info.name, 80))), which is not part of an exported meeting.")
            }
            if out[name] != nil { throw ExchangeRejected("The zip has \(repr(name)) twice.") }
            if info.flagBits & 0x1 != 0 { throw ExchangeRejected("The zip is encrypted.") }
            if info.method != 0 && info.method != 8 {
                throw ExchangeRejected("\(repr(name)) is compressed in a way Palaver does not read.")
            }
            if info.size > UInt64(cap(name, caps)) {
                throw ExchangeRejected("\(repr(name)) is too large (\(info.size / UInt64(MB)) MB).")
            }
            total += Int(info.size)  // at most a cap each, at most 256 of them
            out[name] = info
        }
        if out.count > caps.maxEntries {
            throw ExchangeRejected("The zip has \(out.count) files; an exported meeting has at most \(caps.maxEntries).")
        }
        if total > caps.maxTotalBytes { throw ExchangeRejected("The zip is too large (\(total / MB) MB unpacked).") }
        return (root, out)
    }

    /// `_root`: "" when the manifest is at the top; `<folder>/` when everything is in that one folder and the
    /// manifest is directly in it.
    static func root(_ names: [String]) throws -> String {
        if names.contains(where: { Py.same($0, "manifest.json") }) { return "" }
        var tops: [String] = []
        for n in names {
            let top = parts(n)[0]
            if !tops.contains(where: { Py.same($0, top) }) { tops.append(top) }
        }
        if tops.count == 1, names.contains(where: { Py.same($0, tops[0] + "/manifest.json") }) { return tops[0] + "/" }
        throw ExchangeRejected(NOT_EXPORTED)
    }

    /// `_read_entry`: the entry `name`'s bytes (or, with `sink`, handed there and an empty result), never more than
    /// its cap whatever its header says, and checked against the manifest's `expected` ({"sha256", "bytes"}).
    @discardableResult
    public static func readEntry(_ zip: ZipReader, _ name: String, _ entry: ZipEntry, expected: JSONValue, caps: Caps = .standard,
                                 sink: ((Data) throws -> Void)? = nil) throws -> Data {
        var digest = SHA256()
        var size = 0
        var out = Data()
        do {
            try zip.read(entry, limit: cap(name, caps)) { chunk in
                size += chunk.count
                digest.update(data: chunk)
                if let sink { try sink(chunk) } else { out.append(chunk) }
            }
        } catch ZipError.overLimit {
            throw ExchangeRejected("\(repr(name)) is larger than it says.")
        } catch let error as ZipError {
            throw ExchangeRejected("\(repr(name)) is damaged (\(error)).")
        }
        let hex = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard let sha = expected["sha256"], let bytes = expected["bytes"],
              PythonJSON.equal(.string(hex), sha), PythonJSON.equal(.int(size), bytes) else {
            throw ExchangeRejected("\(repr(name)) does not match its checksum: the zip was changed or damaged.")
        }
        return out
    }
}
