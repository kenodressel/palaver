// Which calendar event a recording was: the choices the page's picker offers (api.py `_candidate_events`,
// `meeting_events`, :630-659) — the calendar's events around the recording, the stored one and those asked about
// even without a calendar, each with how often the user rejected its series and the rule that made.
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

    /// `_candidate_events`: the calendar's events overlapping the recording (not all-day ones; a calendar that fails
    /// counts as none), then the stored event and the question's not among them, by start and title.
    static func candidateEvents(_ app: ServerApp, _ paths: RecordingPaths) throws -> [CalendarEvent] {
        let (start, duration) = try Cutting.span(paths)
        let end = try start.adding(seconds: duration)
        var events: [CalendarEvent] = []
        if let calendar = app.calendar,
           let found = try? calendar(try start.adding(seconds: -CalendarEvents.SEARCH_MARGIN).date,
                                     try end.adding(seconds: CalendarEvents.SEARCH_MARGIN).date) {
            events = found
        }
        events = events.filter { !$0.allDay && $0.end > start && $0.start < end }
        // The stored event, and the ones asked about, even without a calendar at hand.
        for stored in [CalendarEvents.load(paths)] + (CalendarEvents.loadQuestion(paths) ?? []).map(Optional.some) {
            guard let stored else { continue }
            if events.allSatisfy({ !Py.same($0.key, stored.key) || stored.key.isEmpty }) && !events.contains(where: { same($0, stored) }) {
                events.append(stored)
            }
        }
        return Py.stableSorted(events) { a, b in a.start != b.start ? a.start < b.start : Py.less(a.title, b.title) }
    }

    /// `meeting_events`: each choice (`_event_choice`, keyed "stored|<i>" without a calendar id), with `rejected`
    /// and the series' `rule`.
    public static func meetingEvents(app: ServerApp, id: String) throws -> [JSONValue] {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        let current = CalendarEvents.load(paths)
        let evidence = Evidence(path: app.stores.attributions, outputDir: app.outputDir)
        return try candidateEvents(app, paths).enumerated().map { i, e in
            guard case .object(var fields) = MeetingsAPI.eventChoice(e, key: e.key.isEmpty ? "stored|\(i)" : e.key, current: current)
            else { return .null }
            let rule = evidence.rule(e).map { JSONValue.object([("series", .string($0.series)), ("text", .string($0.rule))]) }
            fields.append(("rejected", .int(evidence.eventRejections(e))))
            fields.append(("rule", rule ?? .null))
            return .object(fields)
        }
    }
}
