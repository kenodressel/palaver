// The report's timeline (report.py `timeline_entries`, `collapse_repeats`, `timeline`): the last week's warnings,
// errors, events and crashes across Palaver's logs and every meeting's session.log, merged by time.
import Foundation
import PalaverCore
import PalaverDomain

public enum ReportTimeline {
    static let LEVELS = ["WARNING", "ERROR", "CRITICAL"]
    static let QUIET_FIELDS: Set<String> = ["ts", "level", "logger", "event", "message", "argv", "python", "pid", "traceback"]
    static let plainProblem = try! NSRegularExpression(pattern: #"(^|\b)(warning|error|traceback|exception|failed)\b"#,
                                                       options: [.caseInsensitive])

    public struct Entry: Equatable {
        public let when: Date
        public let level: String
        public let source: String
        public let body: String
    }

    /// A row's other fields as `k=v` (texts as they are, the rest as JSON).
    static func fieldsText(_ row: [(String, JSONValue)]) -> String {
        row.filter { !QUIET_FIELDS.contains($0.0) }.map { k, v in
            "\(k)=\(v.stringValue ?? PythonJSON.dumps(v, ensureAscii: false))"
        }.joined(separator: " ")
    }

    static func lastLine(_ text: String) -> String {
        ModelJobs.splitlines(text).last { !Py.strip($0).isEmpty }.map { Py.strip($0) } ?? ""
    }

    static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// `timeline_entries`: a log's warnings, errors, events and crashes since `since`. Plain lines (a helper's output
    /// in daemon.log, app.log) that look like a problem take the time of the JSON line before them.
    public static func entries(_ source: String, _ text: String, since: Date, timeZone: TimeZone = .current) -> [Entry] {
        var out: [Entry] = []
        var last: Date?
        var crashHead: (Date, String)?
        var crashLines: [String] = []
        func closeCrash() {
            if let (when, head) = crashHead {
                out.append(Entry(when: when, level: "CRASH", source: source, body: "\(head): \(lastLine(crashLines.joined(separator: "\n")))"))
            }
        }
        for line in ModelJobs.splitlines(text) {
            if line.hasPrefix("=== ") {  // crashes.log: "=== <ts> <where> pid …", then the traceback
                closeCrash()
                let rest = line.dropFirst(4)
                let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                let ts = WallTime.parse(parts.first.map(String.init), timeZone)
                crashHead = ts.map { ($0, parts.count > 1 ? String(parts[1]) : "") }
                crashLines = []
                if let ts { last = ts }
                continue
            }
            if crashHead != nil {
                crashLines.append(line)
                continue
            }
            var row: [(String, JSONValue)]?
            if line.hasPrefix("{"), let parsed = try? PythonJSON.parse(Data(line.utf8)), case .object(let pairs) = parsed {
                row = pairs
            }
            if let row, let tsValue = row.first(where: { $0.0 == "ts" })?.1, tsValue.truthy {
                guard let ts = WallTime.parse(tsValue.stringValue ?? Py.str(tsValue), timeZone) else { continue }
                last = ts
                func field(_ k: String) -> JSONValue? { row.first { $0.0 == k }?.1 }
                let levelValue = field("level")
                let level = levelValue.map { $0.truthy ? ($0.stringValue ?? Py.str($0)) : "INFO" } ?? "INFO"
                if let event = field("event"), event.truthy {
                    let body = Py.strip("\(event.stringValue ?? Py.str(event)) \(fieldsText(row))")
                    out.append(Entry(when: ts, level: LEVELS.contains(level) ? level : "EVENT", source: source, body: body))
                } else if LEVELS.contains(level) {
                    func text(_ v: JSONValue?) -> String { v.map { $0.stringValue ?? Py.str($0) } ?? "" }
                    var body = "\(text(field("logger"))): \(text(field("message")))"
                    if let tb = field("traceback"), tb.truthy { body += " ↳ \(lastLine(text(tb)))" }
                    out.append(Entry(when: ts, level: level, source: source, body: body))
                }
            } else if let last, matches(plainProblem, line) {
                out.append(Entry(when: last, level: "OUTPUT", source: source, body: "≈ \(Py.strip(line))"))
            }
        }
        closeCrash()
        return out.filter { $0.when >= since }
    }

    /// `timeline`: every source's entries merged and sorted by time, each line once (a recording's lines are in its
    /// session.log and in daemon.log). Times are this Mac's (`timeZone`).
    public static func timeline(_ sources: [(String, String)], since: Date, timeZone: TimeZone = .current) -> [String] {
        var seen = Set<String>()
        var all: [Entry] = []
        for (source, text) in sources {
            for e in entries(source, text, since: since, timeZone: timeZone) {
                let key = "\(e.when.timeIntervalSince1970)\u{0}\(e.level)\u{0}\(e.body)"
                if seen.insert(key).inserted { all.append(e) }
            }
        }
        let sorted = all.enumerated().sorted { ($0.element.when, $0.offset) < ($1.element.when, $1.offset) }.map(\.element)
        return sorted.map { e in
            let body = String(String.UnicodeScalarView(e.body.unicodeScalars.prefix(600)))
            return "\(Report.stamp(e.when, timeZone, "%04d-%02d-%02d %02d:%02d:%02d"))  \(Report.pad(e.level, 8)) "
                + "\(Report.pad(e.source, 36)) \(body)"
        }
    }

    /// `collapse_repeats`: a run of the same message (a poll failing every 10 s) as its first line, "×N until <time>".
    public static func collapseRepeats(_ lines: [String]) -> [String] {
        func cut(_ s: String, from: Int, to: Int? = nil) -> String {
            let u = Array(s.unicodeScalars)
            guard from < u.count else { return "" }
            return String(String.UnicodeScalarView(u[from..<min(to ?? u.count, u.count)]))
        }
        var out: [String] = []
        var runKey: String?
        var count = 0
        var lastTime = ""
        for line in lines {
            let key = cut(line, from: 21)  // after "YYYY-MM-DD HH:MM:SS  "
            if let runKey, key == runKey {
                count += 1
                lastTime = cut(line, from: 11, to: 19)
                continue
            }
            if count > 1 { out[out.count - 1] += "  (×\(count), until \(lastTime))" }
            out.append(line)
            runKey = key
            count = 1
        }
        if count > 1 { out[out.count - 1] += "  (×\(count), until \(lastTime))" }
        return out
    }
}
