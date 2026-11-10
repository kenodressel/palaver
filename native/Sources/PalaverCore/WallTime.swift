// Wall times as Python writes and reads them: datetime.isoformat / fromisoformat.
import Foundation

public enum WallTime {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var calendars: [Int: Calendar] = [:]

    /// A Gregorian calendar in a fixed offset (made once: daemon.json is written every second).
    public static func calendar(_ timeZone: TimeZone, at date: Date) -> Calendar {
        let offset = timeZone.secondsFromGMT(for: date)
        return lock.withLock {
            if let c = calendars[offset] { return c }
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(secondsFromGMT: offset) ?? timeZone
            calendars[offset] = c
            return c
        }
    }

    /// `datetime.isoformat()`: seconds, plus microseconds when there are any (`seconds: true`:
    /// `isoformat(timespec="seconds")`), with the UTC offset of `timeZone` at that moment.
    public static func iso(_ date: Date, _ timeZone: TimeZone, seconds: Bool = false) -> String {
        let cal = calendar(timeZone, at: date)
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let whole = date.timeIntervalSince1970.rounded(.down)
        let micros = Int(((date.timeIntervalSince1970 - whole) * 1_000_000).rounded())
        var s = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        if !seconds && micros > 0 && micros < 1_000_000 { s += String(format: ".%06d", micros) }
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        s += String(format: "%@%02d:%02d", sign, abs(offset) / 3600, abs(offset) % 3600 / 60)
        return s
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,6}))?)?(Z|[+-]\d{2}:?\d{2})?$"#)

    /// `datetime.fromisoformat`: a moment; one without an offset is local time (`timeZone`).
    public static func parse(_ text: String?, _ timeZone: TimeZone = .current) -> Date? {
        guard let text, let m = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: text) else { return nil }
            return String(text[r])
        }
        var c = DateComponents()
        c.year = Int(group(1)!); c.month = Int(group(2)!); c.day = Int(group(3)!)
        c.hour = Int(group(4)!); c.minute = Int(group(5)!); c.second = Int(group(6) ?? "0")
        var tz = timeZone
        if let off = group(8) {
            if off == "Z" { tz = TimeZone(secondsFromGMT: 0)! } else {
                let digits = off.dropFirst().replacingOccurrences(of: ":", with: "")
                let secs = (Int(digits.prefix(2))! * 3600 + Int(digits.suffix(2))! * 60) * (off.hasPrefix("-") ? -1 : 1)
                guard let z = TimeZone(secondsFromGMT: secs) else { return nil }
                tz = z
            }
        }
        let cal: Calendar
        if group(8) != nil {
            cal = calendar(tz, at: Date())  // a fixed offset
        } else {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = tz
            cal = c
        }
        guard let base = cal.date(from: c) else { return nil }
        let frac = group(7).map { Double("0." + $0) ?? 0 } ?? 0
        return base.addingTimeInterval(frac)
    }

    /// "12:06" in `timeZone`.
    public static func hm(_ date: Date, _ timeZone: TimeZone) -> String {
        let c = calendar(timeZone, at: date).dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }
}
