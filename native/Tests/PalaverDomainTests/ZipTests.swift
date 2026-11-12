// Zip reading and writing (Zip.swift) and exchange's rules for a meeting's zip (exchange.py:563-676): a zip Python's
// exporter wrote, read here; one written here, read by Python's zipfile; and what exchange makes of small zips, built
// in Python (the golden's `zips`) or here, compared with Python's words.
import CryptoKit
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

/// Builds zips for the tests: entries in order, each deflated, stored, or a folder.
struct ZipBuilder {
    var entries: [(name: String, data: Data, deflate: Bool)] = []

    mutating func add(_ name: String, _ data: Data = Data(), deflate: Bool = true) { entries.append((name, data, deflate)) }
    mutating func add(_ name: String, _ text: String) { add(name, Data(text.utf8)) }

    func write(_ url: URL) throws {
        let writer = try ZipWriter(url: url)
        for e in entries { try writer.add(name: e.name, data: e.data, deflate: e.deflate) }
        try writer.finish()
    }
}

/// `bytes` of a zip with the central directory record of `name` changed at `offset` (from the record's start).
func patchedDirectory(_ bytes: Data, _ name: String, at offset: Int, _ value: [UInt8]) -> Data {
    var out = [UInt8](bytes)
    let sig: [UInt8] = [0x50, 0x4B, 0x01, 0x02], key = Array(name.utf8)
    var i = 0
    while i + 46 <= out.count {
        if Array(out[i..<i + 4]) == sig {
            let n = Int(out[i + 28]) | Int(out[i + 29]) << 8
            if n == key.count, i + 46 + n <= out.count, Array(out[i + 46..<i + 46 + n]) == key {
                for (k, b) in value.enumerated() { out[i + offset + k] = b }
            }
        }
        i += 1
    }
    return Data(out)
}

func hexData(_ hex: String) -> Data {
    var out = Data(capacity: hex.utf8.count / 2)
    var it = hex.utf8.makeIterator()
    func nibble(_ c: UInt8) -> UInt8 { c <= 0x39 ? c - 0x30 : (c | 0x20) - 0x61 + 10 }
    while let a = it.next(), let b = it.next() { out.append(nibble(a) << 4 | nibble(b)) }
    return out
}

func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

@Suite struct ZipTests {
    static let python = Goldens.url("exchange-python.zip")

    /// The export's files and the manifest's list of them.
    static func exported() throws -> (files: [(String, Data)], listed: JSONValue) {
        let zip = try ZipReader(url: python, maxDirectoryBytes: ExchangeZip.MAX_DIRECTORY_BYTES)
        let files = try zip.entries.map { ($0.name, try zip.data($0, limit: 1 << 20)) }
        let manifest = try PythonJSON.parse(files.first { $0.0 == "manifest.json" }!.1)
        return (files, manifest["files"]!)
    }

    /// `repack` (test_exchange.py): the export with files changed (nil: left out) and extra entries after them.
    static func repack(_ dst: URL, change: [String: Data?] = [:], extra: [(String, Data)] = []) throws -> URL {
        var b = ZipBuilder()
        for (name, data) in try exported().files {
            if let changed = change[name] { if let changed { b.add(name, changed) } } else { b.add(name, data) }
        }
        for (name, data) in extra { b.add(name, data) }
        try b.write(dst)
        return dst
    }

    /// `in_folder` (test_exchange.py): the zip as Finder compresses its unpacked folder again.
    static func inFolder(_ src: URL, _ dst: URL, _ folder: String, extra: [(String, Data)] = []) throws -> URL {
        let zip = try ZipReader(url: src, maxDirectoryBytes: 1 << 20)
        let files = try zip.entries.map { ($0.name, try zip.data($0, limit: 1 << 24)) }
        var b = ZipBuilder()
        for d in ["", "meeting/", "voices/", "audio/"] where d == "" || files.contains(where: { $0.0.hasPrefix(d) }) {
            b.add("\(folder)/\(d)")
        }
        for (n, d) in files {
            b.add("\(folder)/\(n)", d)
            var parts = n.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            parts[parts.count - 1] = "._" + parts[parts.count - 1]
            b.add("__MACOSX/\(folder)/\(parts.joined(separator: "/"))", Data([0, 5, 22, 7]))
        }
        b.add("\(folder)/.DS_Store", Data([0, 0, 0, 1]) + Data("Bud1".utf8))
        for (n, d) in extra { b.add(n, d) }
        try b.write(dst)
        return dst
    }

    /// What exchange makes of the zip: `_precheck`, `_entries`, then `_read_entry` of each entry `listed` names.
    static func scan(_ url: URL, _ caps: ExchangeZip.Caps = .standard, listed: JSONValue? = nil) throws -> JSONValue {
        let listed = try listed ?? exported().listed
        do {
            let zip = try ExchangeZip.open(url, caps: caps)
            let (root, entries) = try ExchangeZip.entries(zip, caps: caps)
            var reads: [(String, JSONValue)] = []
            for (name, entry) in entries {
                guard let expected = listed[name] else { continue }
                do {
                    reads.append((name, .string(sha256Hex(try ExchangeZip.readEntry(zip, name, entry, expected: expected, caps: caps)))))
                } catch let e as ExchangeRejected {
                    reads.append((name, .object([("rejected", .string(e.message))])))
                }
            }
            return .object([("root", .string(root)), ("names", .array(entries.keys.map { .string($0) })), ("reads", .object(reads))])
        } catch let e as ExchangeRejected {
            return .object([("rejected", .string(e.message))])
        }
    }

    /// `rejected` (test_exchange.py): the zip is refused, the message containing `match`.
    static func rejected(_ url: URL, _ match: String, _ caps: ExchangeZip.Caps = .standard,
                         sourceLocation: SourceLocation = #_sourceLocation) throws {
        let result = try scan(url, caps)
        var message = result["rejected"]?.stringValue
        if message == nil, case .object(let reads)? = result["reads"] {
            message = reads.compactMap { $0.1["rejected"]?.stringValue }.first
        }
        #expect(message?.contains(match) == true, "want \(match), got \(PythonJSON.dumps(result))", sourceLocation: sourceLocation)
    }

    // MARK: - Python's zips and Swift's

    static let uv: String? = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", NSHomeDirectory() + "/.local/bin/uv",
                              NSHomeDirectory() + "/.cargo/bin/uv"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
        ?? (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { "\($0)/uv" }.first { FileManager.default.isExecutableFile(atPath: $0) }

    // MARK: - The tests of test_exchange.py that are about the zip

    @Test func test_not_a_zip_is_rejected() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        let bad = temp.url.appendingPathComponent("x.zip")
        try Data("hello".utf8).write(to: bad)
        try Self.rejected(bad, "not a zip")
    }

    @Test func test_a_file_not_matching_its_checksum_is_rejected() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        let transcript = Data(#"[{"start": 0, "end": 1, "text": "forged", "label": "SPEAKER_00"}]"#.utf8)
        try Self.rejected(try Self.repack(temp.url.appendingPathComponent("x.zip"), change: ["meeting/transcript.json": transcript]),
                          "does not match its checksum")
    }

    @Test func test_a_path_out_of_the_folder_is_rejected() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        try Self.rejected(try Self.repack(temp.url.appendingPathComponent("x.zip"), extra: [("../../evil.json", Data("{}".utf8))]),
                          "unsafe path")
        try Self.rejected(try Self.repack(temp.url.appendingPathComponent("y.zip"), extra: [("/etc/evil.json", Data("{}".utf8))]),
                          "unsafe path")
    }

    @Test func test_a_link_is_rejected() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        let url = try Self.repack(temp.url.appendingPathComponent("x.zip"), extra: [("voices/SPEAKER_00.json", Data("/etc/passwd".utf8))])
        let mode = UInt32(0o120777) << 16
        let link = patchedDirectory(try Data(contentsOf: url), "voices/SPEAKER_00.json", at: 38,
                                    [0, 1, 2, 3].map { UInt8(truncatingIfNeeded: mode >> (8 * $0)) })
        try link.write(to: url)
        try Self.rejected(url, "link")
    }

    @Test func test_a_file_not_part_of_the_format_is_rejected() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        try Self.rejected(try Self.repack(temp.url.appendingPathComponent("x.zip"), extra: [("meeting/run.sh", Data("rm -rf ~".utf8))]),
                          "not part of an exported meeting")
    }

    @Test func test_a_zip_that_is_not_an_exported_meeting_says_so() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        let other = temp.url.appendingPathComponent("photos.zip")
        var b = ZipBuilder()
        b.add("photos/beach.jpg", Data([0xFF, 0xD8]))
        try b.write(other)
        try Self.rejected(other, "not a meeting exported from Palaver")
    }

    @Test func test_only_one_folder_around_the_meeting_is_taken() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        let t = temp.url
        try Self.rejected(try Self.inFolder(Self.python, t.appendingPathComponent("two.zip"), "a", extra: [("b/manifest.json", Data("{}".utf8))]),
                          "not a meeting exported from Palaver")
        let inner = try Self.inFolder(Self.python, t.appendingPathComponent("in.zip"), "inner")
        try Self.rejected(try Self.inFolder(inner, t.appendingPathComponent("deeper.zip"), "outer"), "not a meeting exported from Palaver")
    }

    @Test func test_under_the_folder_the_same_rules_hold() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        let t = temp.url
        try Self.rejected(try Self.inFolder(Self.python, t.appendingPathComponent("a.zip"), "m", extra: [("m/meeting/run.sh", Data("rm -rf ~".utf8))]),
                          "not part of an exported meeting")
        try Self.rejected(try Self.inFolder(Self.python, t.appendingPathComponent("b.zip"), "m", extra: [("m/scripts/", Data())]),
                          "folder 'm/scripts/'")
        try Self.rejected(try Self.inFolder(Self.python, t.appendingPathComponent("c.zip"), "m", extra: [("__MACOSX/../evil", Data())]),
                          "unsafe path")
        try Self.rejected(try Self.inFolder(Self.python, t.appendingPathComponent("d.zip"), "m", extra: [("m/.DS_Store/x.json", Data("{}".utf8))]),
                          "not part of an exported meeting")
    }

    @Test func test_a_changed_file_under_the_folder_fails_its_checksum() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        let forged = try Self.repack(temp.url.appendingPathComponent("f.zip"), change: [
            "meeting/transcript.json": Data(#"[{"start": 0, "end": 1, "text": "x", "label": "SPEAKER_00"}]"#.utf8)])
        try Self.rejected(try Self.inFolder(forged, temp.url.appendingPathComponent("g.zip"), "m"), "does not match its checksum")
    }

    @Test func test_finder_entries_do_not_count_as_files_but_are_capped() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        let junk = (0..<ExchangeZip.MAX_RAW_ENTRIES).map { ("__MACOSX/m/._\($0)", Data()) }
        try Self.rejected(try Self.inFolder(Self.python, temp.url.appendingPathComponent("j.zip"), "m", extra: junk),
                          "an exported meeting has at most 64")
        // Under the cap, they are skipped.
        let some = try Self.scan(try Self.inFolder(Self.python, temp.url.appendingPathComponent("k.zip"), "m", extra: Array(junk.prefix(100))))
        #expect(some["root"]?.stringValue == "m/" && some["names"]?.arrayValue?.count == 7)
    }

    @Test func test_a_zip_listing_too_many_entries_is_rejected_before_it_is_opened() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        let many = temp.url.appendingPathComponent("many.zip")
        var b = ZipBuilder()
        for i in 0..<300 { b.add("x\(i)") }
        try b.write(many)
        #expect(throws: ExchangeRejected("The zip has 300 entries; an exported meeting has at most 64.")) {
            try ExchangeZip.precheck(many, caps: .standard)
        }
        try Self.rejected(many, "300 entries; an exported meeting has at most 64")
    }

    @Test func test_a_zip_with_a_huge_table_of_contents_is_rejected() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        let big = temp.url.appendingPathComponent("big.zip")
        var b = ZipBuilder()
        for i in 0..<3 { b.add("\(i)" + String(repeating: "a", count: 30_000)) }
        try b.write(big)
        try Self.rejected(big, "table of contents is too large")
        // The reader on its own refuses it too, before it reads the table.
        #expect(throws: ZipError.self) { try ZipReader(url: big, maxDirectoryBytes: ExchangeZip.MAX_DIRECTORY_BYTES) }
    }

    @Test func test_a_file_larger_than_any_meeting_is_rejected_before_it_is_read() throws {
        var caps = ExchangeZip.Caps.standard
        caps.maxFileBytes = 1000
        try Self.rejected(Self.python, "The file is too large", caps)
    }

    @Test func test_too_many_entries_are_rejected() throws {
        var caps = ExchangeZip.Caps.standard
        caps.maxEntries = 5
        try Self.rejected(Self.python, "at most 5", caps)
    }

    @Test func test_a_file_too_large_is_rejected() throws {
        var caps = ExchangeZip.Caps.standard
        caps.maxJSONBytes = 100
        try Self.rejected(Self.python, "too large", caps)
    }

    @Test func test_too_much_in_total_is_rejected() throws {
        var caps = ExchangeZip.Caps.standard
        caps.maxTotalBytes = 500
        try Self.rejected(Self.python, "too large", caps)
    }

    @Test func test_an_entry_larger_than_its_header_says_is_rejected() throws {
        // Python's test lets `_entries` take everything and caps the transcript at 10 bytes: `_read_entry` stops there.
        let zip = try ZipReader(url: Self.python, maxDirectoryBytes: ExchangeZip.MAX_DIRECTORY_BYTES)
        let entry = zip.entries.first { $0.name == "meeting/transcript.json" }!
        var caps = ExchangeZip.Caps.standard
        caps.maxJSONBytes = 10
        let listed = try Self.exported().listed
        #expect(throws: ExchangeRejected("'meeting/transcript.json' is larger than it says.")) {
            try ExchangeZip.readEntry(zip, entry.name, entry, expected: listed[entry.name]!, caps: caps)
        }
    }

    @Test func test_an_unusual_compression_is_rejected() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        let url = try Self.repack(temp.url.appendingPathComponent("x.zip"), change: ["meeting/calendar.json": nil],
                                  extra: [("meeting/calendar.json", Data("{}".utf8))])
        try patchedDirectory(try Data(contentsOf: url), "meeting/calendar.json", at: 10, [12, 0]).write(to: url)  // bzip2
        try Self.rejected(url, "compressed in a way")
    }

    // MARK: - The reader on its own

    @Test func theReaderRefusesMethodsOtherThanStoredAndDeflated() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        let url = temp.url.appendingPathComponent("x.zip")
        var b = ZipBuilder()
        b.add("a.json", "{}")
        try b.write(url)
        try patchedDirectory(try Data(contentsOf: url), "a.json", at: 10, [14, 0]).write(to: url)  // LZMA
        let zip = try ZipReader(url: url, maxDirectoryBytes: 1 << 16)
        #expect(zip.entries[0].method == 14)
        #expect(throws: ZipError.self) { try zip.data(zip.entries[0], limit: 100) }
    }

    @Test func theReaderChecksTheCRC() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        let url = temp.url.appendingPathComponent("x.zip")
        var b = ZipBuilder()
        b.add("a.json", Data("[1, 2, 3]".utf8), deflate: false)
        try b.write(url)
        var bytes = [UInt8](try Data(contentsOf: url))
        let at = bytes.firstIndex(of: UInt8(ascii: "["))!
        bytes[at + 1] = UInt8(ascii: "7")
        try Data(bytes).write(to: url)
        let zip = try ZipReader(url: url, maxDirectoryBytes: 1 << 16)
        #expect(throws: ZipError.damaged("Bad CRC-32 for file 'a.json'")) { try zip.data(zip.entries[0], limit: 100) }
    }

    @Test func theReaderStopsAtItsLimitAndAtTheSizeTheDirectorySays() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        let url = temp.url.appendingPathComponent("x.zip")
        var b = ZipBuilder()
        b.add("a.txt", Data(repeating: 0x61, count: 5000))
        try b.write(url)
        let zip = try ZipReader(url: url, maxDirectoryBytes: 1 << 16)
        #expect(throws: ZipError.overLimit) { try zip.data(zip.entries[0], limit: 4999) }
        #expect(try zip.data(zip.entries[0], limit: 5000).count == 5000)
        // A directory saying 10 bytes: zipfile reads 10 and the CRC fails; never more.
        try patchedDirectory(try Data(contentsOf: url), "a.txt", at: 24, [10, 0, 0, 0]).write(to: url)
        let short = try ZipReader(url: url, maxDirectoryBytes: 1 << 16)
        var got = 0
        #expect(throws: ZipError.self) { try short.read(short.entries[0], limit: 1 << 20) { got += $0.count } }
        #expect(got <= 10)
    }

    @Test func aBombEntryIsInflatedNoFurtherThanItsSize() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        let url = temp.url.appendingPathComponent("bomb.zip")
        var b = ZipBuilder()
        b.add("a.txt", Data(count: 64 << 20))  // 64 MiB of zeros: about 64 KB deflated, one read block
        try b.write(url)
        let ten = CRC32.checksum(Data(count: 10))
        // The directory says 10 bytes (with their CRC): zipfile stops there, and so does the inflater.
        var bytes = patchedDirectory(try Data(contentsOf: url), "a.txt", at: 16, [0, 1, 2, 3].map { UInt8(truncatingIfNeeded: ten >> (8 * $0)) })
        bytes = patchedDirectory(bytes, "a.txt", at: 24, [10, 0, 0, 0])
        try bytes.write(to: url)
        let zip = try ZipReader(url: url, maxDirectoryBytes: 1 << 16)
        #expect(try zip.data(zip.entries[0], limit: 100) == Data(count: 10))
        #expect(zip.lastInflated <= 1 << 16)
    }

    @Test func entriesThatOverlapAreRefused() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        let url = temp.url.appendingPathComponent("x.zip")
        var b = ZipBuilder()
        b.add("a.txt", Data(repeating: 0x61, count: 100), deflate: false)
        b.add("b.txt", Data(repeating: 0x62, count: 100), deflate: false)
        try b.write(url)
        // a.txt claims 1000 compressed bytes, running into b.txt.
        try patchedDirectory(try Data(contentsOf: url), "a.txt", at: 20, [0xE8, 0x03, 0, 0]).write(to: url)
        let zip = try ZipReader(url: url, maxDirectoryBytes: 1 << 16)
        #expect(throws: ZipError.damaged("Overlapped entries: 'a.txt' (possible zip bomb)")) { try zip.data(zip.entries[0], limit: 1 << 20) }
    }

    @Test func aDamagedOrCutFileThrowsAndNeverTraps() throws {
        let temp = TempFolder("zip"); defer { temp.remove() }
        let good = [UInt8](try Data(contentsOf: Self.python))
        let url = temp.url.appendingPathComponent("x.zip")
        var seed: UInt64 = 0x5EED
        func next() -> Int { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return Int(seed >> 33) }
        var variants: [[UInt8]] = (0..<good.count).filter { $0 % 7 == 0 }.map { Array(good.prefix($0)) }  // cut short
        for _ in 0..<400 {
            var v = good
            for _ in 0..<(1 + next() % 4) { v[next() % v.count] = UInt8(truncatingIfNeeded: next()) }
            variants.append(v)
        }
        for _ in 0..<100 {  // sizes and offsets in the directory set to extremes
            var v = good
            let dir = Int(v[v.count - 6]) | Int(v[v.count - 5]) << 8 | Int(v[v.count - 4]) << 16 | Int(v[v.count - 3]) << 24
            let at = dir + 16 + 4 * (next() % 8)
            if at + 4 <= v.count { for k in 0..<4 { v[at + k] = next() % 2 == 0 ? 0xFF : UInt8(truncatingIfNeeded: next()) } }
            variants.append(v)
        }
        for v in variants {
            try Data(v).write(to: url)
            _ = try Self.scan(url)  // only ExchangeRejected may come out of it
            guard let zip = try? ZipReader(url: url, maxDirectoryBytes: 1 << 16) else { continue }
            for e in zip.entries { _ = try? zip.data(e, limit: 1 << 20) }
        }
    }

    @Test func zip64SizesInTheExtraFieldAreRead() throws {
        // A zip whose directory gives size, compressed size and offset in a zip64 extra field (as some writers do).
        let payload = Data("{}".utf8)
        let crc = CRC32.checksum(payload)
        func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        var local: [UInt8] = [0x50, 0x4B, 0x03, 0x04] + le(45, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(UInt64(crc), 4)
        local += le(2, 4) + le(2, 4) + le(1, 2) + le(0, 2) + Array("a".utf8) + Array(payload)
        let extra: [UInt8] = le(1, 2) + le(24, 2) + le(2, 8) + le(2, 8) + le(0, 8)
        var dir: [UInt8] = [0x50, 0x4B, 0x01, 0x02] + le(45, 2) + le(45, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(UInt64(crc), 4)
        dir += le(0xFFFF_FFFF, 4) + le(0xFFFF_FFFF, 4) + le(1, 2) + le(UInt64(extra.count), 2) + le(0, 2) + le(0, 2) + le(0, 2)
        dir += le(0, 4) + le(0xFFFF_FFFF, 4) + Array("a".utf8) + extra
        let end: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + le(0, 4) + le(1, 2) + le(1, 2) + le(UInt64(dir.count), 4)
            + le(UInt64(local.count), 4) + le(0, 2)
        let temp = TempFolder("zip"); defer { temp.remove() }
        let url = temp.url.appendingPathComponent("z.zip")
        try Data(local + dir + end).write(to: url)
        let zip = try ZipReader(url: url, maxDirectoryBytes: 1 << 16)
        #expect(zip.entries.count == 1 && zip.entries[0].size == 2 && zip.entries[0].compressedSize == 2)
        #expect(try zip.data(zip.entries[0], limit: 10) == payload)
    }
}
