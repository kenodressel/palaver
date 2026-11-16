// Series Palaver remembers itself (#24): learned from a hand-made link to a recurring event or a call title that
// repeats; joined by the next recordings; kept when the calendar loses the event.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

private typealias F = CalendarFixtures

@Suite struct MeetingSeriesTests {
    private struct Root {
        let t = F.folder("series")
        var stores: StorePaths {
            StorePaths.current(env: ["XDG_CONFIG_HOME": t.url.appendingPathComponent("config").path,
                                     "PALAVER_HOME": t.url.appendingPathComponent("home").path])
        }
        func remove() { t.remove() }

        /// A finished recording starting at `start`; `call`: the title its call window showed.
        func recording(_ name: String, _ start: PyDateTime, minutes: Double = 30, call: String? = nil,
                       people: [String] = []) throws -> RecordingPaths {
            let paths = RecordingPaths(t.url.appendingPathComponent(name, isDirectory: true))
            try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: false)
            try PythonJSON.write(.object([("start_time", .string(start.iso)), ("duration_seconds", .double(minutes * 60))]),
                                 to: paths.meta, indent: nil, ensureAscii: true)
            if call != nil || !people.isEmpty {
                try PythonJSON.write(.object([("app", .string("teams")), ("title", .str(call)), ("participants", .strings(people)),
                                              ("read_at", .string(start.iso))]), to: paths.callWindow, indent: 2, ensureAscii: false)
            }
            return paths
        }
    }

    private let week: Int64 = 7 * 1440

    private func at(_ minutes: Int64) -> PyDateTime { F.T0.adding(micros: minutes * 60_000_000) }

    /// An occurrence of the weekly "Northwind sync" series (its id: northwind-series).
    private func northwind(_ start: Int64, _ minutes: Int64 = 30) -> CalendarEvent {
        CalendarEvent(title: "Northwind sync", start: at(start), end: at(start + minutes),
                      attendees: [Attendee(name: "Timo Strauß", email: "timo@northwind.example")],
                      source: "macos-calendar", uid: "northwind-series", series: true)
    }

    @Test func theSlot() {
        #expect(MeetingSeries.slot(F.T0) == (2, 900))  // Tuesday 15:00 (+01:00)
        #expect(MeetingSeries.slotText(2, 900) == "Tuesdays around 15:00")
        #expect(MeetingSeries.slotText(nil, 900) == "")
    }

    @Test func aCallTitleThatRepeatsIsASeries() throws {
        let root = Root(); defer { root.remove() }
        let first = try root.recording("2026-10-20T15-00-00", at(-week), call: "Northwind  Weekly")
        #expect(try MeetingSeries.attach(first, provider: nil, stores: root.stores) == nil)  // once is no series
        let second = try root.recording("2026-10-27T15-00-00", F.T0, call: "Northwind weekly")
        let series = try #require(try MeetingSeries.attach(second, provider: nil, stores: root.stores))
        #expect(series.name == "Northwind weekly" && series.learned == "call-window")
        #expect(series.meetings == [first.id, second.id])
        #expect(series.weekday == 2 && series.minutes == 900)
        // The next one joins by its title, at any time of day; one with another title doesn't.
        let third = try root.recording("2026-11-03T09-00-00", at(week - 360), call: "northwind weekly")
        #expect(try MeetingSeries.attach(third, provider: nil, stores: root.stores)?.id == series.id)
        let other = try root.recording("2026-11-03T15-00-00", at(week), call: "Contoso review")
        #expect(try MeetingSeries.attach(other, provider: nil, stores: root.stores) == nil)
        #expect(MeetingSeries.of(meeting: third.id, stores: root.stores)?.id == series.id)
        // Without an event the call's title is the meeting's.
        #expect(Titles.resolve(third, stores: root.stores) == ("northwind weekly", "call"))
    }

    @Test func aRecurringEventLinkedByHandLinksTheNextOneInItsSlot() throws {
        let root = Root(); defer { root.remove() }
        // The calendar has the series at 09:00; the calls are held at 15:00.
        let first = try root.recording("2026-10-27T15-00-00", F.T0)
        try MeetingSeries.linkedByHand(first, event: northwind(-360), stores: root.stores)
        let series = try #require(MeetingSeries.of(meeting: first.id, stores: root.stores))
        #expect(series.calendarSeries == "northwind-series" && series.learned == "event" && series.name == "Northwind sync")
        let next = try root.recording("2026-11-03T15-10-00", at(week + 10))
        let provider: CalendarProvider = { _, _ in [self.northwind(self.week - 360), self.northwind(self.week + 1440 - 360)] }
        #expect(try MeetingSeries.attach(next, provider: provider, stores: root.stores)?.id == series.id)
        let event = try #require(CalendarEvents.load(next))
        #expect(event.start == at(week - 360))  // the occurrence that day
        let link = try #require(CalendarEvents.loadLink(next))
        #expect(link.source == "remembered" && link.unsure)  // the slot alone: asked about
        #expect(link.why == "remembered series: Tuesdays around 15:00")
        // Another time that day is not its slot.
        let later = try root.recording("2026-11-03T18-00-00", at(week + 180))
        #expect(try MeetingSeries.attach(later, provider: provider, stores: root.stores) == nil)
        #expect(CalendarEvents.load(later) == nil)
    }

    @Test func aCallTitleLinksTheSeriesSureAtAnyTime() throws {
        let root = Root(); defer { root.remove() }
        let first = try root.recording("2026-10-27T15-00-00", F.T0, call: "Northwind sync")
        try MeetingSeries.linkedByHand(first, event: northwind(-360), stores: root.stores)
        let next = try root.recording("2026-11-03T11-00-00", at(week - 240), call: "Northwind sync")
        let provider: CalendarProvider = { _, _ in [self.northwind(self.week - 360)] }
        _ = try #require(try MeetingSeries.attach(next, provider: provider, stores: root.stores))
        let link = try #require(CalendarEvents.loadLink(next))
        #expect(link.confidence == 0.8 && !link.unsure && link.why == "remembered series: the same title in the call")
    }

    @Test func aMeetingKeepsItsSeriesAndTitleWhenTheEventIsGone() throws {
        let root = Root(); defer { root.remove() }
        let first = try root.recording("2026-10-27T15-00-00", F.T0, call: "Northwind sync")
        try MeetingSeries.linkedByHand(first, event: northwind(0), stores: root.stores)
        // The organizer deleted the next occurrence before it was processed: the series by its call title still.
        let next = try root.recording("2026-11-03T15-00-00", at(week), call: "Northwind sync")
        #expect(try MeetingSeries.attach(next, provider: { _, _ in [] }, stores: root.stores) != nil)
        #expect(CalendarEvents.load(next) == nil)
        // A member that lost everything else is called by its series.
        try FileManager.default.removeItem(at: next.callWindow)
        #expect(Titles.resolve(next, stores: root.stores) == ("Northwind sync", "series"))
        // The calendar's own title wins while there is one.
        try CalendarEvents.save(first, northwind(0))
        #expect(Titles.resolve(first, stores: root.stores).source == "calendar")
    }

    @Test func aRecordingWithAnEventOfTheSeriesJoinsIt() throws {
        let root = Root(); defer { root.remove() }
        let first = try root.recording("2026-10-27T15-00-00", F.T0)
        try MeetingSeries.linkedByHand(first, event: northwind(0), stores: root.stores)
        let matched = try root.recording("2026-11-03T15-00-00", at(week))
        try CalendarEvents.save(matched, northwind(week))  // linked by time
        #expect(try MeetingSeries.attach(matched, provider: nil, stores: root.stores) != nil)
        #expect(MeetingSeries.of(meeting: matched.id, stores: root.stores)?.meetings.count == 2)
    }

    @Test func noGuessNoSeriesForOnceAndNeverAfterNone() throws {
        let root = Root(); defer { root.remove() }
        // A one-off event is nothing to remember.
        let once = try root.recording("2026-10-27T15-00-00", F.T0)
        var single = northwind(0)
        single.series = false
        try MeetingSeries.linkedByHand(once, event: single, stores: root.stores)
        #expect(MeetingSeries.all(stores: root.stores).isEmpty)
        // Two series fitting the slot as well: no guess.
        let a = try root.recording("2026-10-20T15-00-00", at(-week))
        try MeetingSeries.linkedByHand(a, event: northwind(-week), stores: root.stores)
        var contoso = northwind(-week)
        contoso.title = "Contoso"; contoso.uid = "contoso-series"
        try MeetingSeries.linkedByHand(once, event: contoso, stores: root.stores)
        let next = try root.recording("2026-11-03T15-00-00", at(week))
        var occurrence = contoso
        occurrence.start = at(week); occurrence.end = at(week + 30)
        let both: CalendarProvider = { _, _ in [self.northwind(self.week), occurrence] }
        #expect(try MeetingSeries.attach(next, provider: both, stores: root.stores) == nil)
        // "None of these": nothing joins it.
        try CalendarEvents.dismiss(next)
        #expect(try MeetingSeries.attach(next, provider: { _, _ in [self.northwind(self.week)] }, stores: root.stores) == nil)
    }

    @Test func linkedElsewhereOrForgotten() throws {
        let root = Root(); defer { root.remove() }
        let first = try root.recording("2026-10-27T15-00-00", F.T0, call: "Northwind sync")
        try MeetingSeries.linkedByHand(first, event: northwind(0), stores: root.stores)
        let id = try #require(MeetingSeries.of(meeting: first.id, stores: root.stores)).id
        // Linked to none: it leaves the series, which is still remembered.
        try MeetingSeries.linkedByHand(first, event: nil, stores: root.stores)
        #expect(MeetingSeries.of(meeting: first.id, stores: root.stores) == nil)
        #expect(MeetingSeries.all(stores: root.stores).map(\.id) == [id])
        try MeetingSeries.forget(id, stores: root.stores)
        #expect(MeetingSeries.all(stores: root.stores).isEmpty)
    }

    @Test func aCallTitleSeriesLearnsItsCalendarSeries() throws {
        let root = Root(); defer { root.remove() }
        let a = try root.recording("2026-10-20T15-00-00", at(-week), call: "Northwind sync")
        let b = try root.recording("2026-10-27T15-00-00", F.T0, call: "Northwind sync")
        let learned = try #require(try MeetingSeries.attach(b, provider: nil, stores: root.stores))
        try MeetingSeries.linkedByHand(a, event: northwind(-week), stores: root.stores)
        let all = MeetingSeries.all(stores: root.stores)
        #expect(all.count == 1 && all[0].id == learned.id && all[0].calendarSeries == "northwind-series")
    }

    @Test func theCallsPeopleAreHintsWithoutAnEvent() throws {
        let root = Root(); defer { root.remove() }
        let paths = try root.recording("2026-10-27T15-00-00", F.T0, people: ["Timo Strauß", "Anna Lindqvist", "Valerie"])
        #expect(CalendarEvents.invitedNames(paths, ["Timo"], userName: "Anna") == ["Timo", "Valerie"])
        try CalendarEvents.save(paths, northwind(0))
        #expect(CalendarEvents.invitedNames(paths, [], userName: "Anna") == ["Timo Strauß"])  // the event's
    }
}
