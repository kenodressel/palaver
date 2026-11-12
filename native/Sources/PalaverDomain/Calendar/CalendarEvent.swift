// A calendar event as calendar.json stores it (calendar_events.py:44-126): `CalendarEvent`, `Attendee`, and the
// `PyDateTime` they keep their times in. A datetime keeps its own UTC offset (isoformat writes it back) and its
// microseconds, which a `Date` would round.
import Foundation
import PalaverCore

/// Where an event comes from: any `(start, end) -> events` (the macOS calendar in EventKitCalendar, a fake in tests).
public typealias CalendarProvider = (Date, Date) throws -> [CalendarEvent]

public struct CalendarFormatError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// `datetime`: microseconds since the epoch (UTC) and the offset it is written with; nil offset is a naive
/// datetime (compared and subtracted as if it were UTC, which Python refuses to mix with aware ones).
public struct PyDateTime: Hashable, Comparable, Sendable {
    public let micros: Int64
    public let offset: Int?

    public init(micros: Int64, offset: Int?) { self.micros = micros; self.offset = offset }

    public init(_ date: Date, offset: Int?) {
        self.init(micros: Int64((date.timeIntervalSince1970 * 1_000_000).rounded()), offset: offset)
    }

    /// The instant, as a `Date` (to hand to a provider).
    public var date: Date { Date(timeIntervalSince1970: Double(micros) / 1_000_000) }

    /// Python's `==` on datetimes: the same instant (an aware one is never equal to a naive one).
    public static func == (a: PyDateTime, b: PyDateTime) -> Bool {
        a.micros == b.micros && (a.offset == nil) == (b.offset == nil)
    }
    public func hash(into h: inout Hasher) { h.combine(micros) }
    public static func < (a: PyDateTime, b: PyDateTime) -> Bool { a.micros < b.micros }

    /// `self + timedelta(microseconds=)`.
    public func adding(micros delta: Int64) -> PyDateTime { PyDateTime(micros: micros + delta, offset: offset) }
    /// `self + timedelta(seconds=)` (rounded to a microsecond, halves to even). Throws, as Python does, for NaN,
    /// infinity or a result past year 9999 (a hand-edited duration), where Swift's conversions would trap.
    public func adding(seconds: Double) throws -> PyDateTime {
        guard let delta = Int64(exactly: (seconds * 1_000_000).rounded(.toNearestOrEven)) else {
            throw Py.IntError(description: seconds.isNaN ? "cannot convert float NaN to integer" : "date value out of range")
        }
        let (sum, over) = micros.addingReportingOverflow(delta)
        guard !over, abs(sum) <= Self.maxMicros else { throw Py.IntError(description: "date value out of range") }
        return PyDateTime(micros: sum, offset: offset)
    }

    /// About year 10000 either side of the epoch: past Python's datetime, within Int64's microseconds.
    static let maxMicros: Int64 = 253_402_300_800 * 1_000_000
    /// `(self - other).total_seconds()`.
    public func seconds(since other: PyDateTime) -> Double { Double(micros - other.micros) / 1_000_000 }

    private static let perDay: Int64 = 86_400 * 1_000_000

    private static func floorDiv(_ a: Int64, _ b: Int64) -> (Int64, Int64) {
        let q = a / b, r = a % b
        return r < 0 ? (q - 1, r + b) : (q, r)
    }

    /// Days since 1970-01-01 of a civil date (proleptic Gregorian), and back.
    private static func days(_ y: Int, _ m: Int, _ d: Int) -> Int64 {
        let y = Int64(m <= 2 ? y - 1 : y), era = (y >= 0 ? y : y - 399) / 400, yoe = y - era * 400
        let doy = (153 * Int64(m > 2 ? m - 3 : m + 9) + 2) / 5 + Int64(d) - 1
        return era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
    }

    private static func civil(_ days: Int64) -> (Int, Int, Int) {
        let z = days + 719_468, era = (z >= 0 ? z : z - 146_096) / 146_097, doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100), mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1, m = mp < 10 ? mp + 3 : mp - 9
        return (Int(yoe + era * 400 + (m <= 2 ? 1 : 0)), Int(m), Int(d))
    }

    private static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        if m == 2 { return (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28 }
        return [4, 6, 9, 11].contains(m) ? 30 : 31
    }

    private var local: (days: Int64, rest: Int64) { Self.floorDiv(micros + Int64(offset ?? 0) * 1_000_000, Self.perDay) }

    /// `datetime.date().isoformat()`: the day in the datetime's own offset.
    public var dayISO: String {
        let (y, m, d) = Self.civil(local.days)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Midnight of the day in the datetime's own offset.
    public var startOfDay: PyDateTime { PyDateTime(micros: micros - local.rest, offset: offset) }

    /// `datetime.isoformat()`.
    public var iso: String {
        let (days, rest) = local
        let (y, m, d) = Self.civil(days)
        let us = Int(rest % 1_000_000), secs = Int(rest / 1_000_000)
        var s = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", y, m, d, secs / 3600, secs % 3600 / 60, secs % 60)
        if us != 0 { s += String(format: ".%06d", us) }
        if let offset {
            let a = abs(offset)
            s += String(format: "%@%02d:%02d", offset < 0 ? "-" : "+", a / 3600, a % 3600 / 60)
            if a % 60 != 0 { s += String(format: ":%02d", a % 60) }
        }
        return s
    }

    /// `datetime.fromisoformat(s)`: `YYYY-MM-DD`, then optionally a separator and `HH:MM[:SS[.ffffff]]`, then
    /// optionally `Z` or `±HH[:MM[:SS]]` (`±HHMM` too). Throws what Python raises ValueError for.
    public static func parse(_ text: String) throws -> PyDateTime {
        let u = Array(text.unicodeScalars)
        var i = 0
        func fail() -> CalendarFormatError {
            // Python's message, with the text as its repr.
            let quote = text.contains("'") && !text.contains("\"") ? "\"" : "'"
            let body = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: quote == "'" ? "'" : "\"", with: "\\" + quote)
            return CalendarFormatError("Invalid isoformat string: \(quote)\(body)\(quote)")
        }
        func digits(_ n: Int) throws -> Int {
            guard i + n <= u.count else { throw fail() }
            var v = 0
            for k in 0..<n {
                guard let d = Int(String(u[i + k])), ("0"..."9").contains(u[i + k]) else { throw fail() }
                v = v * 10 + d
            }
            i += n
            return v
        }
        func colon() throws { guard i < u.count, u[i] == ":" else { throw fail() }; i += 1 }
        let y = try digits(4)
        guard i < u.count, u[i] == "-" else { throw fail() }
        i += 1
        let mo = try digits(2)
        guard i < u.count, u[i] == "-" else { throw fail() }
        i += 1
        let d = try digits(2)
        guard (1...9999).contains(y), (1...12).contains(mo), (1...daysInMonth(y, mo)).contains(d) else { throw fail() }
        var h = 0, mi = 0, s = 0, us = 0
        var offset: Int?
        if i < u.count {
            i += 1  // the separator: any one character
            h = try digits(2)
            if i < u.count, u[i] == ":" {
                i += 1
                mi = try digits(2)
                if i < u.count, u[i] == ":" {
                    i += 1
                    s = try digits(2)
                    if i < u.count, u[i] == "." || u[i] == "," {
                        i += 1
                        var frac = ""
                        while i < u.count, ("0"..."9").contains(u[i]) { frac.unicodeScalars.append(u[i]); i += 1 }
                        guard !frac.isEmpty else { throw fail() }
                        us = Int(frac.prefix(6).padding(toLength: 6, withPad: "0", startingAt: 0))!
                    }
                }
            }
            guard h < 24, mi < 60, s < 60 else { throw fail() }
            if i < u.count {
                if u[i] == "Z" { i += 1; offset = 0 } else {
                    guard u[i] == "+" || u[i] == "-" else { throw fail() }
                    let sign = u[i] == "-" ? -1 : 1
                    i += 1
                    let oh = try digits(2)
                    var om = 0, os = 0
                    if i < u.count {
                        if u[i] == ":" { i += 1 }
                        om = try digits(2)
                        if i < u.count, u[i] == ":" { i += 1; os = try digits(2) }
                    }
                    guard oh < 24, om < 60, os < 60 else { throw fail() }
                    offset = sign * (oh * 3600 + om * 60 + os)
                }
            }
        }
        guard i == u.count else { throw fail() }
        let local = (days(y, mo, d) * 86_400 + Int64(h * 3600 + mi * 60 + s)) * 1_000_000 + Int64(us)
        return PyDateTime(micros: local - Int64(offset ?? 0) * 1_000_000, offset: offset)
    }
}

public struct Attendee: Hashable, Sendable {
    public var name: String
    public var email: String?
    public var organizer: Bool
    /// accepted | tentative | declined | unknown
    public var response: String
    public var isSelf: Bool
    public var isRoom: Bool

    public init(name: String, email: String? = nil, organizer: Bool = false, response: String = "unknown",
                isSelf: Bool = false, isRoom: Bool = false) {
        self.name = name; self.email = email; self.organizer = organizer; self.response = response
        self.isSelf = isSelf; self.isRoom = isRoom
    }

    var json: JSONValue {
        .object([("name", .string(name)), ("email", .str(email)), ("organizer", .bool(organizer)),
                 ("response", .string(response)), ("is_self", .bool(isSelf)), ("is_room", .bool(isRoom))])
    }

    /// `Attendee(**a)`: the six fields and nothing else; throws where Python raises TypeError.
    init(json a: JSONValue) throws {
        guard case .object(let fields) = a else { throw CalendarFormatError("attendee is not an object") }
        let known: Set = ["name", "email", "organizer", "response", "is_self", "is_room"]
        guard fields.allSatisfy({ known.contains($0.0) }), let name = a["name"]?.stringValue else {
            throw CalendarFormatError("bad attendee")
        }
        func flag(_ key: String) throws -> Bool {
            guard let v = a[key] else { return false }
            guard let b = v.boolValue else { throw CalendarFormatError("attendee \(key) is not a bool") }
            return b
        }
        var email: String?
        if let v = a["email"], !v.isNull {
            guard let s = v.stringValue else { throw CalendarFormatError("attendee email is not a string") }
            email = s
        }
        var response = "unknown"
        if let v = a["response"] {
            guard let s = v.stringValue else { throw CalendarFormatError("attendee response is not a string") }
            response = s
        }
        self.init(name: name, email: email, organizer: try flag("organizer"), response: response,
                  isSelf: try flag("is_self"), isRoom: try flag("is_room"))
    }
}

public struct CalendarEvent: Hashable, Sendable {
    public var title: String
    public var start: PyDateTime
    public var end: PyDateTime
    public var attendees: [Attendee]
    public var allDay: Bool
    public var source: String
    /// The calendar's id for the event, the same on every occurrence.
    public var uid: String
    /// A recurring event.
    public var series: Bool
    /// Where it is held: a meeting room, a Teams link.
    public var location: String

    public init(title: String, start: PyDateTime, end: PyDateTime, attendees: [Attendee] = [], allDay: Bool = false,
                source: String = "", uid: String = "", series: Bool = false, location: String = "") {
        self.title = title; self.start = start; self.end = end; self.attendees = attendees; self.allDay = allDay
        self.source = source; self.uid = uid; self.series = series; self.location = location
    }

    /// The id every occurrence of a recurring event shares; a changed occurrence's own id is "<series id>/RID=<when>".
    public var seriesId: String {
        if let r = uid.range(of: "/RID=") { return String(uid[..<r.lowerBound]) }
        return uid
    }

    /// This occurrence: the id and the day.
    public var key: String { uid.isEmpty ? "" : "\(uid)|\(start.dayISO)" }

    /// `Event.to_dict()`.
    public var json: JSONValue {
        .object([("title", .string(title)), ("start", .string(start.iso)), ("end", .string(end.iso)),
                 ("attendees", .array(attendees.map(\.json))), ("all_day", .bool(allDay)), ("source", .string(source)),
                 ("uid", .string(uid)), ("series", .bool(series)), ("location", .string(location))])
    }

    /// `Event.from_dict(d)` (stored attendees tidied); throws where Python raises KeyError, TypeError,
    /// ValueError or AttributeError.
    public init(json d: JSONValue) throws {
        guard case .object = d, let title = d["title"]?.stringValue, let start = d["start"]?.stringValue,
              let end = d["end"]?.stringValue else { throw CalendarFormatError("not an event") }
        var attendees: [Attendee] = []
        if let list = d["attendees"] {
            guard let items = list.arrayValue else { throw CalendarFormatError("attendees is not a list") }
            attendees = try items.map { CalendarEvents.tidy(try Attendee(json: $0)) }
        }
        func text(_ key: String) throws -> String {
            guard let v = d[key] else { return "" }
            guard let s = v.stringValue else { throw CalendarFormatError("\(key) is not a string") }
            return s
        }
        self.init(title: title, start: try PyDateTime.parse(start), end: try PyDateTime.parse(end), attendees: attendees,
                  allDay: d["all_day"]?.truthy ?? false, source: try text("source"), uid: try text("uid"),
                  series: d["series"]?.truthy ?? false,
                  location: d["location"].flatMap { $0.truthy ? pyStr($0) : nil } ?? "")
    }
}
