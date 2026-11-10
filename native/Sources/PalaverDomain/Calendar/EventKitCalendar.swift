// Events from the macOS calendar (calendar_eventkit.py:1-101): every account added to the Calendar app, e.g. Microsoft
// Exchange. Read-only, on this Mac. Access needs the user's consent once (asked by the app, whose Info.plist carries
// the reason shown in the dialog); the worker inherits it. Tests never reach the real calendar: the conversion works
// on `RawEvent`, which a test fills by hand, and everything else takes a `CalendarProvider`.
import EventKit
import Foundation

public struct EventKitCalendar {
    /// EKAuthorizationStatusFullAccess (= Authorized before macOS 14).
    static let statusFullAccess = 3
    /// EKParticipantStatus.
    static let response: [Int: String] = [2: "accepted", 3: "declined", 4: "tentative"]
    /// EKParticipantTypeRoom, EKParticipantTypeResource.
    static let roomTypes: Set<Int> = [2, 3]

    public init() {}

    /// What the conversion reads of an EKParticipant.
    struct RawParticipant {
        var name: String?
        /// `URL.absoluteString`, e.g. "mailto:anna@x.com".
        var url: String?
        var status: Int
        var type: Int
        var isCurrentUser: Bool
    }

    /// What the conversion reads of an EKEvent.
    struct RawEvent {
        var title: String?
        var start: Date
        var end: Date
        var attendees: [RawParticipant]
        var organizer: RawParticipant?
        var isAllDay: Bool
        var hasRecurrenceRules: Bool
        var location: String?
        var externalIdentifier: String?
        var eventIdentifier: String?
    }

    public func hasAccess() -> Bool {
        EKEventStore.authorizationStatus(for: .event).rawValue == Self.statusFullAccess
    }

    /// Every event of every calendar that starts or runs between the two moments (empty without access, as EventKit
    /// answers).
    public func eventsBetween(_ start: Date, _ end: Date) throws -> [CalendarEvent] {
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { Self.event(Self.raw($0)) }
    }

    private static func raw(_ p: EKParticipant) -> RawParticipant {
        RawParticipant(name: p.name, url: p.url.absoluteString, status: p.participantStatus.rawValue,
                       type: p.participantType.rawValue, isCurrentUser: p.isCurrentUser)
    }

    private static func raw(_ e: EKEvent) -> RawEvent {
        RawEvent(title: e.title, start: e.startDate, end: e.endDate, attendees: (e.attendees ?? []).map(raw),
                 organizer: e.organizer.map(raw), isAllDay: e.isAllDay, hasRecurrenceRules: e.hasRecurrenceRules,
                 location: e.location, externalIdentifier: e.calendarItemExternalIdentifier, eventIdentifier: e.eventIdentifier)
    }

    /// The datetime in this Mac's zone at that moment (`datetime.astimezone()`).
    private static func local(_ date: Date) -> PyDateTime {
        PyDateTime(date, offset: TimeZone.current.secondsFromGMT(for: date))
    }

    private static func email(_ p: RawParticipant) -> String? {
        guard let text = p.url, text.lowercased().hasPrefix("mailto:") else { return nil }
        return String(text.dropFirst("mailto:".count)).lowercased()
    }

    static func attendee(_ p: RawParticipant, organizerEmail: String?) -> Attendee {
        let email = email(p)
        let rawName = [p.name, email].compactMap { $0 }.first { !$0.isEmpty } ?? "Unknown"
        return Attendee(name: CalendarEvents.personName(rawName), email: email,
                        organizer: email != nil && email == organizerEmail,
                        response: response[p.status] ?? "unknown", isSelf: p.isCurrentUser,
                        isRoom: roomTypes.contains(p.type) || CalendarEvents.looksLikeRoom(rawName))
    }

    /// The id Exchange gives the event (the same on this Mac and elsewhere, and on every occurrence of a series);
    /// else this calendar's own.
    private static func uid(_ e: RawEvent) -> String {
        for value in [e.externalIdentifier, e.eventIdentifier] { if let v = value, !v.isEmpty { return v } }
        return ""
    }

    static func event(_ ek: RawEvent) -> CalendarEvent {
        let organizerEmail = ek.organizer.flatMap(email)
        var attendees = ek.attendees.map { attendee($0, organizerEmail: organizerEmail) }
        if let organizer = ek.organizer, !attendees.contains(where: { $0.email == organizerEmail }) {
            attendees.insert(attendee(organizer, organizerEmail: organizerEmail), at: 0)
        }
        return CalendarEvent(title: ek.title ?? "", start: local(ek.start), end: local(ek.end), attendees: attendees,
                             allDay: ek.isAllDay, source: "macos-calendar", uid: uid(ek), series: ek.hasRecurrenceRules,
                             location: ek.location ?? "")
    }
}
