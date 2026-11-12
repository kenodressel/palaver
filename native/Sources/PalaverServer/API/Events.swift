// Which calendar event a recording was: the choices the page's picker offers (api.py `_candidate_events`,
// `meeting_events`, :630-659) — the calendar's events of the recording's day and the days around it, the stored one
// and those asked about even without a calendar, each with how often the user rejected its series and the rule that
// made.
import Foundation
import PalaverCore
import PalaverDomain

public enum EventsAPI {
    /// Python's `==` on two `Event` dataclasses: every field, text by its code points (`Py.same`), times by instant.
    static func same(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool {
        func sameAttendee(_ x: Attendee, _ y: Attendee) -> Bool {
            Py.same(x.name, y.name) && x.organizer == y.organizer && Py.same(x.response, y.response)
                && x.isSelf == y.isSelf && x.isRoom == y.isRoom
                && (x.email == nil ? y.email == nil : y.email.map { Py.same(x.email!, $0) } ?? false)
        }
        return Py.same(a.title, b.title) && a.start == b.start && a.end == b.end && a.allDay == b.allDay
            && Py.same(a.source, b.source) && Py.same(a.uid, b.uid) && a.series == b.series && Py.same(a.location, b.location)
            && a.attendees.count == b.attendees.count && zip(a.attendees, b.attendees).allSatisfy(sameAttendee)
    }

    /// `_candidate_events`: the calendar's events of the recording's day and the days before and after it (not all-day ones;
    /// a calendar that fails counts as none), then the stored event and the question's not among them. A call held
    /// hours before or after its slot can be linked to it by hand (#28). Those overlapping the recording come first,
    /// by start and title; then the others, nearest first.
    static func candidateEvents(_ app: ServerApp, _ paths: RecordingPaths) throws -> [CalendarEvent] {
        let (start, duration) = try Cutting.span(paths)
        let end = try start.adding(seconds: duration)
        var events: [CalendarEvent] = []
        if let calendar = app.calendar,
           let found = try? calendar(try start.startOfDay.adding(seconds: -86_400).date,
                                     try end.startOfDay.adding(seconds: 2 * 86_400).date) {
            events = found
        }
        events = events.filter { !$0.allDay }
        // The stored event, and the ones asked about, even without a calendar at hand.
        for stored in [CalendarEvents.load(paths)] + (CalendarEvents.loadQuestion(paths) ?? []).map(Optional.some) {
            guard let stored else { continue }
            if events.allSatisfy({ !Py.same($0.key, stored.key) || stored.key.isEmpty }) && !events.contains(where: { same($0, stored) }) {
                events.append(stored)
            }
        }
        return Py.stableSorted(events) { a, b in
            let x = distance(a, start, end), y = distance(b, start, end)
            if x != y { return x < y }
            return a.start != b.start ? a.start < b.start : Py.less(a.title, b.title)
        }
    }

    /// Whether the event overlaps the recording `start`..`end`.
    static func overlaps(_ e: CalendarEvent, _ start: PyDateTime, _ end: PyDateTime) -> Bool { e.end > start && e.start < end }

    /// How far the event lies from the recording `start`..`end`, in seconds: 0 while they overlap.
    static func distance(_ e: CalendarEvent, _ start: PyDateTime, _ end: PyDateTime) -> Double {
        if overlaps(e, start, end) { return 0 }
        return e.start >= end ? e.start.seconds(since: end) : start.seconds(since: e.end)
    }

    /// `meeting_events`: each choice (`_event_choice`, keyed "stored|<i>" without a calendar id), with `rejected`,
    /// the series' `rule` and whether it `overlaps` the recording.
    public static func meetingEvents(app: ServerApp, id: String) throws -> [JSONValue] {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        let current = CalendarEvents.load(paths)
        let evidence = Evidence(path: app.stores.attributions, outputDir: app.outputDir)
        let (start, duration) = try Cutting.span(paths)
        let end = try start.adding(seconds: duration)
        return try candidateEvents(app, paths).enumerated().map { i, e in
            guard case .object(var fields) = MeetingsAPI.eventChoice(e, key: e.key.isEmpty ? "stored|\(i)" : e.key, current: current)
            else { return .null }
            let rule = evidence.rule(e).map { JSONValue.object([("series", .string($0.series)), ("text", .string($0.rule))]) }
            fields.append(("rejected", .int(evidence.eventRejections(e))))
            fields.append(("rule", rule ?? .null))
            fields.append(("overlaps", .bool(overlaps(e, start, end))))
            return .object(fields)
        }
    }
}
