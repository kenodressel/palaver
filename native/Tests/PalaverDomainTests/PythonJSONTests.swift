// PythonJSON: parsing (key order, ints and floats apart, what it refuses) and writing files.
import Foundation
import PalaverCore
import PalaverDomain
import Testing

private func parse(_ text: String) throws -> JSONValue { try PythonJSON.parse(Data(text.utf8)) }

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pythonjson-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func text(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

@Suite struct PythonJSONTests {

    @Test func parseKeepsKeyOrder() throws {
        let v = try parse(#"{"z": 1, "a": {"y": true, "b": null}, "m": []}"#)
        guard case .object(let fields) = v, case .object(let inner)? = v["a"] else { Issue.record("not an object"); return }
        #expect(fields.map(\.0) == ["z", "a", "m"])
        #expect(inner.map(\.0) == ["y", "b"])
        #expect(PythonJSON.dumps(v) == #"{"z": 1, "a": {"y": true, "b": null}, "m": []}"#)
        #expect(PythonJSON.dumps(v, sortKeys: true) == #"{"a": {"b": null, "y": true}, "m": [], "z": 1}"#)
    }

    @Test func intAndFloatStayApart() throws {
        let v = try parse("[1, 1.0, 1e2, -0, -0.0, 2E-3]")
        #expect(PythonJSON.dumps(v) == "[1, 1.0, 100.0, 0, -0.0, 0.002]")
        guard case .array(let items) = v else { Issue.record("not an array"); return }
        if case .int = items[0] {} else { Issue.record("1 is not an int") }
        if case .double = items[1] {} else { Issue.record("1.0 is not a double") }
    }

    @Test func aDuplicateKeyKeepsItsFirstPlace() throws {
        let v = try parse(#"{"a": 1, "b": 2, "a": 3}"#)
        #expect(PythonJSON.dumps(v) == #"{"a": 3, "b": 2}"#)
    }

    @Test func parseAcceptsWhatJsonLoadsAcceptsOnly() throws {
        let special = try parse(" [NaN, Infinity, -Infinity, \"\\ud83d\\ude00\\u00df\\/\"] \n")
        #expect(PythonJSON.dumps(special, ensureAscii: false) == "[NaN, Infinity, -Infinity, \"😀ß/\"]")
        for broken in ["", "[1,]", "{\"a\" 1}", "[1] x", "01", "\"a\u{01}\"", "'a'", "{a: 1}", "[1e]", "\u{FEFF}[]"] {
            #expect(throws: PythonJSON.ParseError.self, "\(broken.debugDescription)") { try parse(broken) }
        }
    }

    @Test func readIsNilForAMissingOrBrokenFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.json")
        #expect(PythonJSON.read(file) == nil)
        try Data("{\"a\": ".utf8).write(to: file)
        #expect(PythonJSON.read(file) == nil)
        try Data("{\"a\": 1}".utf8).write(to: file)
        #expect(PythonJSON.read(file).map { PythonJSON.dumps($0) } == #"{"a": 1}"#)
    }

    @Test func writeViaTmpRenames() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("meta.json")
        try Data("old".utf8).write(to: file)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        let v: JSONValue = .object([("title", .string("Timo Strauß")), ("n", .double(0.1 + 0.2))])
        try PythonJSON.write(v, to: file, indent: 2, ensureAscii: false, via: "meta.json.tmp")
        #expect(try text(file) == "{\n  \"title\": \"Timo Strauß\",\n  \"n\": 0.30000000000000004\n}")
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        #expect(before != after)  // a new file renamed over the old one
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("meta.json.tmp").path))
    }

    @Test func writeInPlaceAddsNewlineOnlyWhenAsked() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("speakers.json")
        try PythonJSON.write(.object([("a", .int(1))]), to: file, indent: nil, ensureAscii: true)
        #expect(try text(file) == #"{"a": 1}"#)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        try PythonJSON.write(.array([.string("ß")]), to: file, indent: 1, ensureAscii: true, newline: true)
        #expect(try text(file) == "[\n \"\\u00df\"\n]\n")
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        #expect(before == after)  // the same file, truncated and rewritten
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["speakers.json"])
    }

}
