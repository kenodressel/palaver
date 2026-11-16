// A next step's due day (#18), from what the notes copied of it into the step: the notes keep a deadline said with a
// task in its text ("bis Freitag", "by Nov 18", "morgen", "18.11."; NotesPrompt), never as a field of its own. Read
// against the meeting's day, not today's: "tomorrow" in last week's meeting was last week's tomorrow. Plain English and
// German forms only; anything else is no due date rather than a wrong one. The first one in the text wins.
import Foundation

enum DueDates {
    /// The day `text` names, as YYYY-MM-DD; nil when it names none. `meeting`: the meeting's day (YYYY-MM-DD…).
    static func find(_ text: String, meeting: String) -> String? {
        guard let day = Day(meeting) else { return nil }
        var found: [(at: Int, day: Day)] = []
        let ns = text as NSString
        func each(_ re: NSRegularExpression, _ make: (NSTextCheckingResult) -> Day?) {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let d = make(m) { found.append((m.range.location, d)) }
            }
        }
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        each(iso) { m in Day(Int(group(m, 1)!)!, Int(group(m, 2)!)!, Int(group(m, 3)!)!) }
        each(dotted) { m in day.dated(Int(group(m, 1)!)!, Int(group(m, 2)!)!, year: group(m, 3).flatMap { Int($0) }) }
        each(dayMonth) { m in
            month(group(m, 2)!).flatMap { day.dated(Int(group(m, 1)!)!, $0, year: group(m, 3).flatMap { Int($0) }) }
        }
        each(monthDay) { m in
            month(group(m, 1)!).flatMap { day.dated(Int(group(m, 2)!)!, $0, year: group(m, 3).flatMap { Int($0) }) }
        }
        each(dayAfterTomorrow) { _ in day.plus(2) }
        each(tomorrow) { _ in day.plus(1) }
        each(today) { _ in day }
        each(endOfWeek) { _ in day.next(weekday: 5, today: true) }
        each(weekday) { m in weekdays[group(m, 1)!.lowercased()].map { day.next(weekday: $0, today: false) } }
        return found.min { $0.at < $1.at }?.day.text
    }

    // MARK: - the forms

    private static func re(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static let MONTH = #"(jan(?:uary|uar)?|feb(?:ruary|ruar)?|m(?:ä|ae)rz|mar(?:ch)?|apr(?:il)?|mai|may|jun(?:e|i)?|jul(?:y|i)?"#
        + #"|aug(?:ust)?|sep(?:t(?:ember)?)?|okt(?:ober)?|oct(?:ober)?|nov(?:ember)?|dez(?:ember)?|dec(?:ember)?)"#
    private static let iso = re(#"(?<!\d)(\d{4})-(\d{1,2})-(\d{1,2})(?!\d)"#)
    /// "18.11." and "18.11.2026" (not "2.1.3", not "15.30 Uhr").
    private static let dotted = re(#"(?<![\d.])(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})?(?!\d)"#)
    /// "18 Nov", "18. November 2026", "18th of November".
    private static let dayMonth = re(#"(?<![\d.])(\d{1,2})(?:st|nd|rd|th)?\.?\s+(?:of\s+)?"# + MONTH + #"\b\.?(?:\s+(\d{4}))?"#)
    /// "Nov 18", "November 18th, 2026".
    private static let monthDay = re(#"\b"# + MONTH + #"\b\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?![\w:])(?:,?\s+(\d{4}))?"#)
    private static let dayAfterTomorrow = re(#"\bübermorgen\b|\bday after tomorrow\b"#)
    /// Not "heute Morgen", "am Morgen", "Guten Morgen" (the morning) nor "day after tomorrow".
    private static let tomorrow = re(#"(?<!heute\s)(?<!am\s)(?<!guten\s)(?<!über)\bmorgen\b|(?<!after\s)\btomorrow\b"#)
    private static let today = re(#"\bheute\b|\btoday\b|\btonight\b|\bthis (?:afternoon|evening)\b|\bend of (?:the )?day\b|\bEOD\b"#)
    private static let endOfWeek = re(#"\bende (?:der|dieser) woche\b|\bend of (?:the|this) week\b|\bEOW\b"#)
    private static let weekday = re(#"\b(montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag|monday|tuesday|wednesday"#
                                    + #"|thursday|friday|saturday|sunday|mon|tues?|wed|thu(?:rs?)?|fri)s?\b"#)

    /// Monday 1 … Sunday 7.
    private static let weekdays: [String: Int] = [
        "montag": 1, "dienstag": 2, "mittwoch": 3, "donnerstag": 4, "freitag": 5, "samstag": 6, "sonntag": 7,
        "monday": 1, "tuesday": 2, "wednesday": 3, "thursday": 4, "friday": 5, "saturday": 6, "sunday": 7,
        "mon": 1, "tue": 2, "tues": 2, "wed": 3, "thu": 4, "thur": 4, "thurs": 4, "fri": 5,
    ]

    private static func month(_ name: String) -> Int? {
        let n = name.lowercased()
        let starts: [(String, Int)] = [("jan", 1), ("feb", 2), ("mär", 3), ("mae", 3), ("mar", 3), ("apr", 4), ("mai", 5),
                                       ("may", 5), ("jun", 6), ("jul", 7), ("aug", 8), ("sep", 9), ("okt", 10), ("oct", 10),
                                       ("nov", 11), ("dez", 12), ("dec", 12)]
        return starts.first { n.hasPrefix($0.0) }?.1
    }

    // MARK: - days

    /// A calendar day, counted in UTC so no zone or summer time moves it.
    struct Day {
        let date: Date
        private static let calendar: Calendar = {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "UTC")!
            return c
        }()

        init?(_ y: Int, _ m: Int, _ d: Int) {
            guard (1...12).contains(m), (1...31).contains(d), (1900...2999).contains(y),
                  let date = Self.calendar.date(from: DateComponents(year: y, month: m, day: d)),
                  Self.calendar.component(.day, from: date) == d else { return nil }
            self.date = date
        }

        /// The first ten characters of an ISO time: "2026-10-29".
        init?(_ iso: String) {
            let parts = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            self.init(parts[0], parts[1], parts[2])
        }

        private init(date: Date) { self.date = date }

        var parts: (Int, Int, Int) {
            let c = Self.calendar.dateComponents([.year, .month, .day], from: date)
            return (c.year!, c.month!, c.day!)
        }

        var text: String {
            let (y, m, d) = parts
            return String(format: "%04d-%02d-%02d", y, m, d)
        }

        func plus(_ days: Int) -> Day { Day(date: Self.calendar.date(byAdding: .day, value: days, to: date)!) }

        /// The next `weekday` (Monday 1 … Sunday 7) after this day; `today`: this day itself counts.
        func next(weekday: Int, today: Bool) -> Day {
            let own = (Self.calendar.component(.weekday, from: date) + 5) % 7 + 1  // Sunday 1 … → Monday 1 …
            var ahead = (weekday - own + 7) % 7
            if ahead == 0 && !today { ahead = 7 }
            return plus(ahead)
        }

        /// `day`.`month`. of the given year, else of this day's year (the next one when that day is well past).
        func dated(_ day: Int, _ month: Int, year: Int?) -> Day? {
            if let year { return Day(year < 100 ? 2000 + year : year, month, day) }
            let (y, _, _) = parts
            guard let same = Day(y, month, day) else { return nil }
            return same.date < plus(-60).date ? Day(y + 1, month, day) : same
        }
    }
}
