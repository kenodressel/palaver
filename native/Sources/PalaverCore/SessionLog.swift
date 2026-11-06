// The per-recording JSON-lines log, `<folder>/session.log`, in the format palaver/session_log.py writes
// (`_JsonFormatter`): one object per line with, in this order, `ts` (local time, isoformat with
// microseconds and offset), `level` ("INFO", "WARNING", ...), `logger` ("palaver.<module>"), then
// `event` plus the event's fields, or `message` for a plain line. Python's readers (report, doctor,
// the web app's pipeline view) parse lines written here: tests/test_session_log_swift.py pins that.
import Darwin
import Foundation

public final class SessionLog: @unchecked Sendable {
    public let url: URL
    private let clock: () -> Date
    private let timeZone: TimeZone
    private let logger: String
    private let lock = NSLock()
    private let formatter: DateFormatter

    public init(url: URL, logger: String = "palaver.capture_recorder", clock: @escaping () -> Date = Date.init,
                timeZone: TimeZone = .current) {
        self.url = url
        self.logger = logger
        self.clock = clock
        self.timeZone = timeZone
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxx"
    }

    /// A structured event (`LOGGER.info(name, extra={"event": name, "fields": fields})`).
    public func event(_ name: String, level: String = "INFO", logger: String? = nil, _ fields: [(String, Any)] = []) {
        append(level: level, logger: logger, [("event", name)] + fields)
    }

    /// A plain message line (`LOGGER.warning("...")`).
    public func message(_ text: String, level: String = "INFO", logger: String? = nil) {
        append(level: level, logger: logger, [("message", text)])
    }

    /// The line as written, without the newline.
    public func line(level: String, logger: String? = nil, _ fields: [(String, Any)]) -> String {
        let head: [(String, Any)] = [("ts", formatter.string(from: clock())), ("level", level), ("logger", logger ?? self.logger)]
        return JSONLines.object(head + fields)
    }

    /// One write(2) per line on an O_APPEND descriptor: the files are shared with the workers' own
    /// O_APPEND writers (daemon.log, session.log), and only the kernel's append is atomic against them
    /// (a seek to the end and a write could land over a line another process just appended). Opened per
    /// line, so a file moved or removed meanwhile is simply made again.
    private func append(level: String, logger: String?, _ fields: [(String, Any)]) {
        let bytes = Array((line(level: level, logger: logger, fields) + "\n").utf8)
        lock.lock(); defer { lock.unlock() }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var done = 0
        while done < bytes.count {  // a short write (a full disk) leaves the rest unwritten
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + done, bytes.count - done) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            done += n
        }
    }
}

/// Small JSON writer that keeps key order and prints numbers the way Python does (20.0, not 20).
public enum JSONLines {
    public static func value(_ v: Any) -> String {
        switch v {
        case let s as String: return string(s)
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let d as Double: return d.isFinite ? "\(d)" : "null"
        case let f as Float: return f.isFinite ? "\(Double(f))" : "null"
        case let a as [Any]: return "[" + a.map(value).joined(separator: ", ") + "]"
        case let o as [(String, Any)]: return object(o)
        default:
            if let opt = v as? OptionalProtocol, opt.isNil { return "null" }
            return string("\(v)")
        }
    }

    public static func object(_ fields: [(String, Any)]) -> String {
        "{" + fields.map { string($0.0) + ": " + value($0.1) }.joined(separator: ", ") + "}"
    }

    /// Python's `json.dumps(ensure_ascii=True)` escapes.
    public static func string(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 || u.value > 0x7E {
                    if u.value > 0xFFFF {
                        let v = u.value - 0x10000
                        out += String(format: "\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
                    } else {
                        out += String(format: "\\u%04x", u.value)
                    }
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}

private protocol OptionalProtocol { var isNil: Bool { get } }
extension Optional: OptionalProtocol { var isNil: Bool { self == nil } }
