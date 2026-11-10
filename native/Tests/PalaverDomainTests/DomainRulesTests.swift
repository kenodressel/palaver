// Rules the domain's sources keep, checked on the sources themselves.
import Foundation
import Testing

@Suite struct DomainRulesTests {
    /// Every JSON read and write in PalaverDomain goes through PythonJSON: JSONSerialization,
    /// Codable's coders and the daemon's JSONValue.parse lose key order and Python's floats.
    @Test func domainNeverUsesFoundationJSON() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PalaverDomain")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 1, "no sources under \(sources.path)")
        let banned = try NSRegularExpression(pattern: #"\bJSONSerialization\b|\bJSON(De|En)coder\b|\bJSONValue\s*\.\s*parse\b"#)
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (n, line) in lines.enumerated() {
                let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line  // comments may name them
                if banned.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                    Issue.record("\(file.lastPathComponent):\(n + 1) uses Foundation JSON, not PythonJSON: \(line)")
                }
            }
        }
    }
}
