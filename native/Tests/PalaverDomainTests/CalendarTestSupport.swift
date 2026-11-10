// Helpers of the attribution and calendar suites: the events of the Python tests, written the same way.
import Foundation
import PalaverDomain

enum CalendarFixtures {
    /// 2026-10-27T15:00:00+01:00
    static let T0 = try! PyDateTime.parse("2026-10-27T15:00:00+01:00")

    static func at(_ minutes: Int) -> PyDateTime { T0.adding(micros: Int64(minutes) * 60_000_000) }

    static func event(_ title: String, _ start: Int, _ end: Int, _ names: String..., uid: String = "", series: Bool = false,
                      allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(title: title, start: at(start), end: at(end),
                      attendees: names.map { Attendee(name: $0, email: "\(String($0.split(separator: " ")[0]).lowercased())@x.com") },
                      allDay: allDay, uid: uid.isEmpty ? title.lowercased().replacingOccurrences(of: " ", with: "-") : uid, series: series)
    }

    static func folder(_ name: String = "calendar") -> TempFolder { TempFolder(name) }
}
