import Foundation
import PalaverCore
import Testing

// The session.log lines palaver/session_log.py's readers parse (tests/test_session_log_swift.py reads them back).

@Suite struct SessionLogTests {
    private func log(_ name: String = "session.log") -> (SessionLog, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-sl-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let at = ISO8601DateFormatter().date(from: "2026-10-29T12:06:00+01:00")!.addingTimeInterval(0.25)
        return (SessionLog(url: url, clock: { at }, timeZone: TimeZone(secondsFromGMT: 3600)!), url)
    }

    @Test func aMessageLineAndAppending() throws {
        let (log, url) = log()
        log.message("Audio health checks failed; warnings are off for this recording", level: "WARNING")
        log.event("record_stop")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"message\": \"Audio health checks failed; warnings are off for this recording\""))
        #expect(lines[1].hasSuffix("\"event\": \"record_stop\"}"))
        for line in lines { #expect((try JSONSerialization.jsonObject(with: Data(line.utf8))) is [String: Any]) }
    }

    @Test func nilAndAstralCharactersSerialize() {
        let (log, _) = log()
        let line = log.line(level: "INFO", [("event", "x"), ("end", Double?.none as Any), ("s", "a😀")])
        #expect(line.hasSuffix("\"end\": null, \"s\": \"a\\ud83d\\ude00\"}"))
    }

    @Test func jsonValueFieldsAreWrittenAsJSON() {
        let (log, _) = log()
        let fields: JSONValue = .object([("n", .int(2)), ("x", .double(1.0)), ("s", .string("ä")), ("none", .null),
                                         ("list", .array([.bool(true), .string("b")]))])
        let line = log.line(level: "INFO", [("event", "x"), ("fields", fields), ("seconds", JSONValue.double(0.5))])
        #expect(line.hasSuffix("\"event\": \"x\", \"fields\": {\"n\": 2, \"x\": 1.0, \"s\": \"\\u00e4\", \"none\": null, "
                               + "\"list\": [true, \"b\"]}, \"seconds\": 0.5}"))
    }
}

@Suite struct SessionLogSharingTests {
    /// daemon.log and session.log are shared with the workers, which append with O_APPEND (Python's
    /// logging FileHandler): another process writing at the same time must lose no line, and no line
    /// may be cut into another.
    @Test func anotherProcessAppendingAtTheSameTimeLosesNothing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-sl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("daemon.log")
        let log = SessionLog(url: url, logger: "palaver.app")
        let n = 3000
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `>>` opens with O_APPEND, as the workers' log handlers do; one short write per line.
        other.arguments = ["-c", "i=0; while [ $i -lt \(n) ]; do echo \"{\\\"worker\\\": $i}\" >> \"$1\"; i=$((i+1)); done", "sh", url.path]
        try other.run()
        var i = 0
        while other.isRunning || i < n {
            if i < n { log.message("app \(i)") ; i += 1 } else { usleep(1000) }
        }
        other.waitUntilExit()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        var app = Set<Int>(), worker = Set<Int>()
        for line in lines {
            let obj = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "garbled: \(line)")
            if let w = obj["worker"] as? Int { worker.insert(w) }
            if let m = obj["message"] as? String, m.hasPrefix("app ") { app.insert(Int(m.dropFirst(4))!) }
        }
        #expect(lines.count == 2 * n)
        #expect(app.count == n && worker.count == n)
    }
}
