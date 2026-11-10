// The goldens tools/parity/goldens.py writes from Python (Goldens/<section>.json, or <section>.json.gz past
// 100 KB). A golden is compared as text: PythonJSON.dumps of both sides, byte for byte, so key order and 1 vs
// 1.0 count. Never `JSONValue ==`.
import Foundation
import PalaverCore
import PalaverDomain
import Testing

enum Goldens {
    /// A file shipped under Goldens/.
    static func url(_ relative: String) -> URL {
        Bundle.module.url(forResource: "Goldens", withExtension: nil)!.appendingPathComponent(relative)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: JSONValue] = [:]

    /// Goldens/<section>.json or <section>.json.gz (read once per run); an issue and an empty object when it is
    /// missing or broken.
    static func load(_ section: String, sourceLocation: SourceLocation = #_sourceLocation) -> JSONValue {
        if let value = lock.withLock({ loaded[section] }) { return value }
        let file = url("\(section).json")
        guard let value = readJSON(file) else {
            Issue.record("no golden \(file.path)(.gz): run `uv run --extra dev python tools/parity/goldens.py \(section)`",
                         sourceLocation: sourceLocation)
            return .object([])
        }
        lock.withLock { loaded[section] = value }
        return value
    }

    /// `file`, or `file`.gz decompressed; nil when neither is there or it is no JSON.
    static func readJSON(_ file: URL) -> JSONValue? {
        if let data = try? Data(contentsOf: file) { return try? PythonJSON.parse(data) }
        guard let packed = try? Data(contentsOf: file.appendingPathExtension("gz")), let data = gunzip(packed) else { return nil }
        return try? PythonJSON.parse(data)
    }

    /// A gzip file's content (one member, as Python's `gzip.compress` writes it); nil when it is not one.
    static func gunzip(_ packed: Data) -> Data? {
        let b = [UInt8](packed)
        guard b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { guard i + 2 <= b.count else { return nil }; i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8) }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {  // a name, a comment: zero-terminated
            while i < b.count && b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x02 != 0 { i += 2 }
        guard i <= b.count - 8,
              let out = try? (Data(b[i..<(b.count - 8)]) as NSData).decompressed(using: .zlib) as Data else { return nil }
        let size = b[(b.count - 4)...].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return UInt32(truncatingIfNeeded: out.count) == size ? out : nil
    }

    /// Records an issue unless `actual` dumps to the same text as the golden `section[key]`.
    static func expect(_ actual: JSONValue, _ section: String, _ key: String,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        guard let golden = load(section, sourceLocation: sourceLocation)[key] else {
            Issue.record("golden \(section) has no key \(key)", sourceLocation: sourceLocation)
            return
        }
        let got = PythonJSON.dumps(actual, ensureAscii: false)
        let want = PythonJSON.dumps(golden, ensureAscii: false)
        #expect(got == want, "golden \(section).\(key)", sourceLocation: sourceLocation)
    }

    /// `section[key]` as a list of cases, each a list (`[input…, expected]`).
    static func cases(_ section: String, _ key: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> [[JSONValue]] {
        let cases = try #require(load(section, sourceLocation: sourceLocation)[key]?.arrayValue, "golden \(section).\(key)",
                                 sourceLocation: sourceLocation)
        return try cases.map { try #require($0.arrayValue, sourceLocation: sourceLocation) }
    }

    struct ShapeError: Error, CustomStringConvertible {
        let what: String
        let got: JSONValue?
        var description: String { "golden: want \(what), got \(got.map { PythonJSON.dumps($0) } ?? "nothing")" }
    }

    /// A golden int (`.int`, not a float).
    static func int(_ v: JSONValue?) throws -> Int {
        guard case .int(let i)? = v else { throw ShapeError(what: "int", got: v) }
        return i
    }

    /// `expect` for a golden list of cases, case by case, so a failure names the first few cases
    /// that differ instead of printing the whole list.
    static func expectEach(_ actual: [JSONValue], _ section: String, _ key: String,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        guard let golden = load(section, sourceLocation: sourceLocation)[key]?.arrayValue else {
            Issue.record("golden \(section) has no list \(key)", sourceLocation: sourceLocation)
            return
        }
        #expect(actual.count == golden.count, "golden \(section).\(key): case count", sourceLocation: sourceLocation)
        var reported = 0
        for (got, want) in zip(actual, golden) where reported < 5 {
            let g = PythonJSON.dumps(got, ensureAscii: false), w = PythonJSON.dumps(want, ensureAscii: false)
            if g != w {
                Issue.record("golden \(section).\(key): got \(g), want \(w)", sourceLocation: sourceLocation)
                reported += 1
            }
        }
    }
}
