// Events from the macOS calendar (calendar_eventkit.py:1-101): every account added to the Calendar app, e.g. Microsoft
// Exchange. Read-only, on this Mac. Access needs the user's consent once (asked by the app, whose Info.plist carries
// the reason shown in the dialog); the worker inherits it. Tests never reach the real calendar: the conversion works
// on `RawEvent`, which a test fills by hand, and everything else takes a `CalendarProvider`.
import EventKit
import Foundation

/// One of the Mac's calendars, for Settings' choice.
public struct CalendarInfo: Equatable, Sendable {
    public var id: String
    public var title: String
    /// The account it belongs to ("iCloud", "Exchange", ...).
    public var account: String
    /// "#rrggbb", or "".
    public var color: String

    public init(id: String, title: String, account: String = "", color: String = "") {
        self.id = id; self.title = title; self.account = account; self.color = color
    }
}

public struct EventKitCalendar {
    /// EKAuthorizationStatusFullAccess (= Authorized before macOS 14).
    static let statusFullAccess = 3
    /// EKParticipantStatus.
    static let response: [Int: String] = [2: "accepted", 3: "declined", 4: "tentative"]
    /// EKParticipantTypeRoom, EKParticipantTypeResource.
    static let roomTypes: Set<Int> = [2, 3]

    /// The calendars the user turned off in Settings (`calendarIdentifier`s, settings.json's `calendars_off`): their
    /// events are none of Palaver's, e.g. a personal calendar next to the work one.
    public var excluded: Set<String>

    public init(excluded: Set<String> = []) { self.excluded = excluded }

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

    /// Every event that starts or runs between the two moments, of every calendar but the ones turned off (empty
    /// without access, as EventKit answers).
    public func eventsBetween(_ start: Date, _ end: Date) throws -> [CalendarEvent] {
        let store = EKEventStore()
        var calendars: [EKCalendar]?
        if !excluded.isEmpty {
            calendars = store.calendars(for: .event).filter { !excluded.contains($0.calendarIdentifier) }
            if calendars!.isEmpty { return [] }  // EventKit reads an empty list as every calendar
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map { Self.event(Self.raw($0)) }
    }

    /// The Mac's calendars, by account and title (empty without access).
    public func calendars() -> [CalendarInfo] {
        guard hasAccess() else { return [] }
        let found = EKEventStore().calendars(for: .event).map { c in
            CalendarInfo(id: c.calendarIdentifier, title: c.title, account: c.source?.title ?? "", color: Self.hex(c.cgColor))
        }
        return found.sorted { ($0.account.lowercased(), $0.title.lowercased()) < ($1.account.lowercased(), $1.title.lowercased()) }
    }

    /// "#rrggbb" of a calendar's color; "" when it has none in RGB.
    private static func hex(_ color: CGColor?) -> String {
        guard let rgb = color?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = rgb.components, c.count >= 3 else { return "" }
        return String(format: "#%02x%02x%02x", Int((c[0] * 255).rounded()), Int((c[1] * 255).rounded()), Int((c[2] * 255).rounded()))
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
