// Python's `datetime.date`: a day of the proleptic Gregorian calendar from 0001-01-01 to 9999-12-31, with its
// ordinal arithmetic (`date ± timedelta(days=…)`), `weekday()`, `isoformat()` and `fromisoformat` of YYYY-MM-DD.
import Foundation

public struct PyDate: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    /// `date(year, month, day)`; nil where Python raises ValueError.
    public init?(_ year: Int, _ month: Int, _ day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), (1...Self.daysIn(year, month)).contains(day) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// `date.fromisoformat(s)` for the YYYY-MM-DD form (ASCII digits); nil for anything else.
    public init?(iso s: String) {
        let u = Array(s.unicodeScalars)
        guard u.count == 10, u[4] == "-", u[7] == "-" else { return nil }
        func number(_ r: Range<Int>) -> Int? {
            var n = 0
            for i in r {
                guard ("0"..."9").contains(u[i]) else { return nil }
                n = n * 10 + Int(u[i].value - 48)
            }
            return n
        }
        guard let y = number(0..<4), let m = number(5..<7), let d = number(8..<10) else { return nil }
        self.init(y, m, d)
    }

    /// The local date of a moment: `date.today()` (or `datetime.now().astimezone().date()`) in `timeZone`.
    public static func today(now: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> PyDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return PyDate(c.year!, c.month!, c.day!)!
    }

    /// `d.isoformat()`: "2026-10-30" (the year with four digits).
    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// `d.weekday()`: Monday is 0, Sunday 6.
    public var weekday: Int { (ordinal + 6) % 7 }

    /// `d + timedelta(days=n)`; nil where Python raises OverflowError (before 0001-01-01, after 9999-12-31).
    public func adding(days n: Int) -> PyDate? { PyDate(ordinal: ordinal + n) }

    public static func < (a: PyDate, b: PyDate) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    // MARK: - Calendar arithmetic (CPython's Lib/_pydatetime.py)

    static func isLeap(_ year: Int) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }

    /// `calendar.monthrange(year, month)[1]`.
    static func daysIn(_ year: Int, _ month: Int) -> Int {
        month == 2 && isLeap(year) ? 29 : daysInMonth[month]
    }

    private static let daysInMonth = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    private static let daysBeforeMonth: [Int] = {
        var out = [0], total = 0
        for m in 1...12 { out.append(total); total += daysInMonth[m] }
        return out
    }()

    /// `d.toordinal()`: 0001-01-01 is 1.
    var ordinal: Int {
        let y = year - 1
        return y * 365 + y / 4 - y / 100 + y / 400 + Self.daysBeforeMonth[month] + (month > 2 && Self.isLeap(year) ? 1 : 0) + day
    }

    /// `date.fromordinal(n)` (`_ord2ymd`); nil outside 1…3652059.
    init?(ordinal: Int) {
        guard (1...3_652_059).contains(ordinal) else { return nil }
        var n = ordinal - 1
        let n400 = n / 146_097; n %= 146_097
        var year = n400 * 400 + 1
        let n100 = n / 36_524; n %= 36_524
        let n4 = n / 1_461; n %= 1_461
        let n1 = n / 365; n %= 365
        year += n100 * 100 + n4 * 4 + n1
        if n1 == 4 || n100 == 4 {
            self.init(year - 1, 12, 31)
            return
        }
        let leap = n1 == 3 && (n4 != 24 || n100 == 3)
        var month = (n + 50) >> 5
        var preceding = Self.daysBeforeMonth[month] + (month > 2 && leap ? 1 : 0)
        if preceding > n {
            month -= 1
            preceding -= Self.daysInMonth[month] + (month == 2 && leap ? 1 : 0)
        }
        self.init(year, month, n - preceding + 1)
    }
}
