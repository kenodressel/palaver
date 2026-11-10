// calendar_events.py (test_calendar_events.py) and calendar_eventkit.py: matching, invitees, names, calendar.json,
// attaching events to recordings and the EventKit conversion (on hand-made raw events: the real calendar is never
// read).
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct CalendarEventsTests {
    typealias F = CalendarFixtures
    typealias C = CalendarEvents

    private func fields(_ v: JSONValue) throws -> [(String, JSONValue)] {
        guard case .object(let f) = v else { throw Goldens.ShapeError(what: "object", got: v) }
        return f
    }

    private func ev(_ title: String, _ start: Int, _ end: Int, _ names: String..., uid: String = "", allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(title: title, start: F.at(start), end: F.at(end),
                      attendees: names.map { Attendee(name: $0, email: "\(String($0.split(separator: " ")[0]).lowercased())@x.com") },
                      allDay: allDay, uid: uid)
    }

    /// `datetime + timedelta(seconds=)` of a hand-edited duration: an error, as in Python, never a trap.
    @Test func addingABrokenDurationThrows() throws {
        let start = try PyDateTime.parse("2026-10-27T16:03:07+01:00")
        for seconds in [Double.nan, .infinity, -.infinity, 1e300, 1e15] {
            #expect(throws: Py.IntError.self, "\(seconds)") { try start.adding(seconds: seconds) }
        }
        #expect(try start.adding(seconds: 90.5).iso == "2026-10-27T16:04:37.500000+01:00")
    }

    @Test func test_the_event_overlapping_the_recording_most_wins() {
        let events = [
            ev("Standup", -30, 0, "Anna"),
            ev("Receipt case study", 0, 60, "Anna", "Bob"),
            ev("Focus time", 30, 120),  // no attendees, overlaps less
            ev("Holiday", -600, 1000, allDay: true),
        ]
        #expect(C.match(events, F.at(1), F.at(59))?.title == "Receipt case study")
    }

    @Test func test_no_event_when_the_overlap_is_marginal() {
        #expect(C.match([ev("Before", -60, 2, "Anna")], F.at(0), F.at(30)) == nil)
    }

    @Test func test_a_call_that_runs_long_still_matches() {
        #expect(C.match([ev("Sync", 0, 30, "Anna")], F.at(2), F.at(55))?.title == "Sync")
    }

    @Test func test_candidates_leave_out_the_user_rooms_and_declines() {
        let event = CalendarEvent(title: "Sync", start: F.at(0), end: F.at(30), attendees: [
            Attendee(name: "Timo Strauss", email: "timo@x.com", isSelf: true),
            Attendee(name: "Anna Huber", email: "anna@x.com", organizer: true),
            Attendee(name: "Bob Weiss", email: "bob@x.com", response: "declined"),
            Attendee(name: "Room Wien 3", email: "room@x.com", isRoom: true),
            Attendee(name: "Carl Berg", email: "carl@x.com", response: "tentative"),
        ])
        #expect(C.candidates(event, userName: "Timo").map(\.name) == ["Anna Huber", "Carl Berg"])
    }

    @Test func test_invitees_resolve_to_names_already_in_use() {
        let known = ["Freddy", "Anna Huber", "Martin", "Martina Klein"]
        #expect(C.resolve("Anna Huber", known) == "Anna Huber")
        #expect(C.resolve("anna huber", known) == "Anna Huber")
        #expect(C.resolve("Freddy Schmidt", known) == "Freddy")  // first name, unambiguous
        #expect(C.resolve("Martin Wolf", known) == "Martin")
        #expect(C.resolve("Zoe Ray", known) == nil)
        #expect(C.resolve("Max Ray", ["Max", "max"]) == nil)  // two first-name hits: ambiguous
    }

    @Test func test_recording_span_uses_the_end_time_when_known() throws {
        let t = F.folder(); defer { t.remove() }
        let paths = RecordingPaths(t.url)
        t.write("meta.json", #"{"start_time": "2026-10-27T15:00:00+01:00", "duration_seconds": 1800.0}"#)
        let (start, end) = try C.recordingSpan(paths)
        #expect(start == F.T0 && end == F.at(30))
        t.write("meta.json", #"{"start_time": "2026-10-27T15:00:00+01:00", "end_time": "2026-10-27T15:05:00+01:00"}"#)
        #expect(try C.recordingSpan(paths).1 == F.at(5))
        t.write("meta.json", #"{"start_time": "2026-10-27T15:00:00+01:00"}"#)
        #expect(throws: (any Error).self) { try C.recordingSpan(paths) }
    }

    @Test func test_directory_names_become_names_people_say() throws {
        #expect(C.personName("Kralek, Karel (Contoso Services)") == "Karel Kralek")
        #expect(C.personName("Ortega, Luis Alberto (Contoso Technology, externer Mitarbeiter)") == "Luis Alberto Ortega")
        #expect(C.personName("GARCIA LOPEZ, JOSE MIGUEL EXT. (Contoso Technology Iberia External)") == "Jose Miguel Garcia Lopez")
        #expect(C.personName("Katharina Lichtenegg") == "Katharina Lichtenegg")
        #expect(C.looksLikeRoom("03 - Seestraße | Meetingroom | KLOUD Vienna"))
        #expect(C.looksLikeRoom("16 - Attakring | Conferenceroom | KLOUD Vienna"))
        #expect(!C.looksLikeRoom("Andres Moreno Vidal"))
        // Python's answers for more shapes (tools/parity/goldens.py calendar).
        for case_ in try #require(Goldens.load("calendar")["people"]?.arrayValue) {
            let c = try #require(case_.arrayValue)
            let raw = try #require(c[0].stringValue)
            #expect(C.personName(raw) == c[1].stringValue, "personName(\(raw.debugDescription))")
            #expect(C.looksLikeRoom(raw) == c[2].boolValue, "looksLikeRoom(\(raw.debugDescription))")
        }
    }

    @Test func test_stored_events_are_tidied_and_invitees_listed_once() throws {
        let event = try CalendarEvent(json: try PythonJSON.parse(Data("""
            {"title": "Migration", "start": "2026-10-27T15:00:00+01:00", "end": "2026-10-27T15:30:00+01:00",
             "attendees": [{"name": "Brunner, Felix (Contoso Technology)", "email": "d@x.com"},
                           {"name": "Felix Brunner", "email": "felix@y.com"},
                           {"name": "03 - Seestraße | Meetingroom | KLOUD Vienna", "email": "room@x.com"}]}
            """.utf8)))
        #expect(C.candidates(event, userName: "Timo").map(\.name) == ["Felix Brunner"])
    }

    @Test func test_the_event_at_a_moment_tells_back_to_back_meetings_apart() {
        // For a call continued after a restart: still the same event? (#47)
        let events = [ev("Standup", -30, 0, "Anna", uid: "s"), ev("1:1", 0, 30, "Bob", uid: "o"),
                      ev("Holiday", -600, 1000, allDay: true)]
        #expect(C.eventKeyAt(events, F.at(-2)) == events[0].key)
        #expect(C.eventKeyAt(events, F.at(1)) == events[1].key)
        #expect(C.eventKeyAt(events, F.at(120)) == nil)
        let noUid = [CalendarEvent(title: "Sync", start: F.at(0), end: F.at(30), attendees: [Attendee(name: "Anna")])]
        #expect(C.eventKeyAt(noUid, F.at(5)) == "Sync|\(noUid[0].start.iso)")
    }

    // MARK: attach

    /// A temporary folder and the config dir attach writes its stores into (prepared.json, projects.json, …).
    private struct Root {
        let t = F.folder()
        var stores: StorePaths {
            StorePaths.current(env: ["XDG_CONFIG_HOME": t.url.appendingPathComponent("config").path,
                                     "PALAVER_HOME": t.url.appendingPathComponent("home").path])
        }
        func remove() { t.remove() }
    }

    /// test_calendar_events.py's `_recording`: a folder with meta.json when it has a start.
    private func recording(_ root: Root, _ name: String, _ start: PyDateTime?, minutes: Double = 30) throws -> RecordingPaths {
        let paths = RecordingPaths(root.t.url.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: false)
        if let start {
            try PythonJSON.write(.object([("start_time", .string(start.iso)), ("duration_seconds", .double(minutes * 60))]),
                                 to: paths.meta, indent: nil, ensureAscii: true)
        }
        return paths
    }

    @Test func test_attach_stores_the_matched_event() throws {
        let root = Root(); defer { root.remove() }
        let paths = RecordingPaths(root.t.url)
        var seen: [(Date, Date)] = []
        let provider: CalendarProvider = { start, end in
            seen.append((start, end))
            return [self.ev("Receipt case study", 0, 60, "Valerie Brandt")]
        }
        let event = try #require(try C.attach(paths, provider: provider, start: F.T0, end: F.at(58), stores: root.stores))
        #expect(event.title == "Receipt case study")
        #expect(seen[0].0 < F.T0.date && seen[0].1 > F.at(58).date)  // searched around it
        let loaded = C.load(paths)
        #expect(loaded == event && loaded?.attendees[0].email == "valerie@x.com")
    }

    @Test func test_attach_without_a_match_leaves_nothing() throws {
        let root = Root(); defer { root.remove() }
        let paths = RecordingPaths(root.t.url)
        #expect(try C.attach(paths, provider: { _, _ in [] }, start: F.T0, end: F.at(30), stores: root.stores) == nil)
        #expect(C.load(paths) == nil)
    }

    @Test func test_attach_all_fills_in_earlier_recordings() throws {
        let root = Root(); defer { root.remove() }
        let done = try recording(root, "2026-10-27T14-00-00", F.at(-60))
        try C.save(done, ev("Stored", -60, -30, uid: "u1"))
        let old = try recording(root, "2026-10-27T15-05-00", F.at(5), minutes: 20)
        try C.save(old, ev("Stored before events had ids", -30, 0))
        let hit = try recording(root, "2026-10-27T15-00-00", F.T0)
        _ = try recording(root, "2026-10-27T18-00-00", F.at(180))  // no event then
        _ = try recording(root, "2026-10-27T19-00-00", nil)  // still recording: no meta yet
        try FileManager.default.createDirectory(at: root.t.url.appendingPathComponent("notes"), withIntermediateDirectories: false)
        var asked: [Date] = []
        let provider: CalendarProvider = { start, _ in
            asked.append(start)
            return [self.ev("Receipt case study", 0, 30, "Valerie Brandt")]
        }
        #expect(try C.attachAll(outputDir: root.t.url, provider: provider, stores: root.stores) == 2)
        #expect(C.load(hit)?.title == "Receipt case study")
        #expect(C.load(done)?.title == "Stored")  // not looked up again
        // Looked up again (it had no id), but a stored event is never replaced by another (#48).
        #expect(C.load(old)?.title == "Stored before events had ids")
        #expect(asked.count == 3)
    }

    @Test func test_attach_all_can_look_only_at_recent_recordings() throws {
        let root = Root(); defer { root.remove() }
        let old = try recording(root, "2026-10-26T15-00-00", F.at(-1440))
        let new = try recording(root, "2026-10-27T15-00-00", F.T0)
        let provider: CalendarProvider = { _, _ in [self.ev("Yesterday", -1440, -1410, "Anna"), self.ev("Today", 0, 30, "Anna")] }
        #expect(try C.attachAll(outputDir: root.t.url, provider: provider, since: F.at(-60), stores: root.stores) == 1)
        #expect(C.load(new) != nil && C.load(old) == nil)
    }

    @Test func test_a_dismissed_event_is_not_attached_again() throws {
        let root = Root(); defer { root.remove() }
        let paths = try recording(root, "2026-10-27T15-00-00", F.T0)
        let provider: CalendarProvider = { _, _ in [self.ev("Receipt case study", 0, 30, "Valerie Brandt")] }
        try C.attach(paths, provider: provider, start: F.T0, end: F.at(30), stores: root.stores)
        try C.dismiss(paths)
        #expect(C.load(paths) == nil && C.dismissed(paths))
        #expect(try C.attach(paths, provider: provider, start: F.T0, end: F.at(30), stores: root.stores) == nil)
        #expect(try C.attachAll(outputDir: root.t.url, provider: provider, stores: root.stores) == 0)
        #expect(C.load(paths) == nil)
    }

    /// The coordinator's rule (Task 10): a calendar.json Swift cannot read, though Python may, is never overwritten.
    @Test func aCalendarFileThisCodeCannotReadIsLeftAlone() throws {
        let root = Root(); defer { root.remove() }
        let paths = try recording(root, "2026-10-27T15-00-00", F.T0)
        let text = #"{"title": 7, "start": "2026-10-27T15:00:00+01:00", "end": "2026-10-27T15:30:00+01:00", "uid": ""}"#
        try text.write(to: paths.calendar, atomically: false, encoding: .utf8)
        #expect(C.storedButUnreadable(paths))
        var asked = 0
        let provider: CalendarProvider = { _, _ in
            asked += 1
            return [self.ev("Receipt case study", 0, 30, "Valerie Brandt"), self.ev("Contoso sync", 0, 30, "Anna")]
        }
        #expect(try C.attach(paths, provider: provider, start: F.T0, end: F.at(30), stores: root.stores) == nil)
        #expect(try C.attachAll(outputDir: root.t.url, provider: provider, stores: root.stores) == 0)
        #expect(asked == 0)
        #expect(try String(contentsOf: paths.calendar, encoding: .utf8) == text)
        #expect(C.loadQuestion(paths) == nil)
    }

    @Test func assignBringsWhatWasPreparedAndTheSeriesMark() throws {
        let root = Root(); defer { root.remove() }
        let paths = try recording(root, "2026-10-27T15-00-00", F.T0)
        let event = ev("Northwind weekly", 0, 30, "Valerie Brandt", uid: "northwind-weekly")
        let weekly = CalendarEvent(title: event.title, start: event.start, end: event.end, attendees: event.attendees,
                                   uid: event.uid, series: true)
        let store = ProjectStore(path: root.stores.projects)
        let pid = try store.create("Northwind rollout")
        try store.save()
        try Prep.choose(weekly, pid, stores: root.stores)
        _ = try MyNotes.save(MyNotes.prepFolder(weekly.key, stores: root.stores),
                             paragraphs: .array([.object([("text", .string("Ask about the numbers")), ("at", .null)])]))
        try SharedMic.remember(weekly, true, stores: root.stores)

        try C.assign(paths, weekly, link: Link("event", weekly.title, "calendar", 0.9, "time match"), stores: root.stores)
        #expect(C.load(paths) == weekly && C.loadLink(paths)?.reason == "time match")
        #expect(ProjectStore(path: root.stores.projects).ofMeeting(paths.id)[pid]?["why"]?.stringValue == "chosen before the meeting")
        #expect(Prep.chosen(weekly, stores: root.stores).isEmpty)
        #expect(MyNotes.load(paths.folder).map(\.text) == ["Ask about the numbers"])
        #expect(SharedMic.meetingMarked(paths) && SharedMic.fromSeries(paths))
    }

    // MARK: EventKit (on raw events; the calendar itself is read by hand, see the report)

    @Test func test_eventkit_events_become_events() {
        typealias P = EventKitCalendar.RawParticipant
        let org = P(name: "Anna Huber", url: "mailto:Anna@x.com", status: 2, type: 1, isCurrentUser: false)
        let raw = EventKitCalendar.RawEvent(
            title: "Receipt case study", start: F.T0.date, end: F.at(30).date,
            attendees: [P(name: "Timo Strauss", url: "mailto:timo@x.com", status: 2, type: 1, isCurrentUser: true),
                        P(name: "Bob Weiss", url: "mailto:bob@x.com", status: 3, type: 1, isCurrentUser: false),
                        P(name: "Wien 3", url: "mailto:room@x.com", status: 0, type: 2, isCurrentUser: false)],
            organizer: org, isAllDay: false, hasRecurrenceRules: true, location: nil, externalIdentifier: nil,
            eventIdentifier: "ek-1")
        let event = EventKitCalendar.event(raw)
        #expect(event.title == "Receipt case study" && event.start == F.T0 && event.end == F.at(30))
        #expect(event.start.offset == TimeZone.current.secondsFromGMT(for: F.T0.date)
                && event.end.offset == TimeZone.current.secondsFromGMT(for: F.at(30).date))
        #expect(event.source == "macos-calendar" && event.uid == "ek-1" && event.series && event.location == "")
        struct Row: Equatable { let name: String; let organizer: Bool; let response: String; let isSelf: Bool; let isRoom: Bool }
        #expect(event.attendees.map { Row(name: $0.name, organizer: $0.organizer, response: $0.response, isSelf: $0.isSelf, isRoom: $0.isRoom) } == [
            Row(name: "Anna Huber", organizer: true, response: "accepted", isSelf: false, isRoom: false),  // organizer, not in the attendee list
            Row(name: "Timo Strauss", organizer: false, response: "accepted", isSelf: true, isRoom: false),
            Row(name: "Bob Weiss", organizer: false, response: "declined", isSelf: false, isRoom: false),
            Row(name: "Wien 3", organizer: false, response: "unknown", isSelf: false, isRoom: true),
        ])
        #expect(event.attendees[0].email == "anna@x.com")
        #expect(C.candidates(event, userName: "Timo").map(\.name) == ["Anna Huber"])
    }

    @Test func eventKitEventsTakeTheExternalIdAndFallBackToTheirOwn() {
        func uid(_ external: String?, _ own: String?) -> String {
            EventKitCalendar.event(.init(title: nil, start: F.T0.date, end: F.at(5).date, attendees: [], organizer: nil,
                                         isAllDay: false, hasRecurrenceRules: false, location: nil,
                                         externalIdentifier: external, eventIdentifier: own)).uid
        }
        #expect(uid("ext-1", "own-1") == "ext-1")
        #expect(uid("", "own-1") == "own-1")
        #expect(uid(nil, nil) == "")
    }

    // Reading the real calendar needs the user's consent and a calendar: only `PALAVER_TEST_REAL_CALENDAR=1` runs this
    // one read-only check (event counts of the next 24 hours); never by default, never in CI.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PALAVER_TEST_REAL_CALENDAR"] == "1"))
    func theRealCalendarIsReadOnlyWhenAskedTo() throws {
        let calendar = EventKitCalendar()
        guard calendar.hasAccess() else { return }
        let events = try calendar.eventsBetween(Date(), Date().addingTimeInterval(24 * 3600))
        print("EventKit: \(events.count) events in the next 24 h")
    }

    // MARK: calendar.json bytes

    @Test func aStoredEventIsReadAndWrittenAsPythonDoes() throws {
        let t = F.folder(); defer { t.remove() }
        let paths = RecordingPaths(t.url)
        let golden = Goldens.load("calendar")
        let stored = try #require(golden["stored"])
        let event = try CalendarEvent(json: stored)
        Goldens.expect(event.json, "calendar", "event_json")
        #expect(event.key == golden["event_key"]?.stringValue)
        #expect(event.seriesId == golden["event_series_id"]?.stringValue)
        let link = Link("event", "Migration", "calendar", 0.54, "time match; you said a recording was not this event once")
        try C.save(paths, event, link)
        #expect(t.text("calendar.json") == golden["saved"]?.stringValue)
        let other = try CalendarEvent(json: .object(try fields(stored).map { key, value in
            switch key {
            case "title": return (key, .string("Äpfel"))
            case "start": return (key, .string("2026-10-27T14:00:00+01:00"))
            case "end": return (key, .string("2026-10-27T15:00:00+01:00"))
            default: return (key, value)
            }
        }))
        try C.ask(paths, [event, other])
        #expect(t.text("calendar.json") == golden["asked"]?.stringValue)
        try C.dismiss(paths)
        #expect(t.text("calendar.json") == golden["dismissed"]?.stringValue)
    }

    @Test func anUnchangedQuestionIsNotRewritten() throws {
        let t = F.folder(); defer { t.remove() }
        let paths = RecordingPaths(t.url)
        let events = [ev("B", 0, 60, "Bob"), ev("A", 0, 60, "Anna")]
        try C.ask(paths, events)
        let first = try #require(try FileManager.default.attributesOfItem(atPath: paths.calendar.path)[.modificationDate] as? Date)
        // Give the file a time in the past: a rewrite would bring the present back.
        let past = first.addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: paths.calendar.path)
        try C.ask(paths, events.reversed())
        let after = try #require(try FileManager.default.attributesOfItem(atPath: paths.calendar.path)[.modificationDate] as? Date)
        #expect(abs(after.timeIntervalSince(past)) < 1)
        try C.ask(paths, [ev("C", 0, 60, "Carl")])
        #expect(C.loadQuestion(paths)?.map(\.title) == ["C"])
    }

    @Test func aBrokenCalendarFileIsNoEventAndNoQuestion() throws {
        let t = F.folder(); defer { t.remove() }
        let paths = RecordingPaths(t.url)
        for text in ["", "not json", "[]", #"{"title": "x"}"#, #"{"title": "x", "start": "soon", "end": "later"}"#,
                     #"{"question": [{"title": 1}]}"#, #"{"question": "x"}"#] {
            t.write("calendar.json", text)
            #expect(C.load(paths) == nil, "\(text)")
            #expect(C.loadQuestion(paths) == nil, "\(text)")
            #expect(!C.dismissed(paths))
        }
    }

    @Test func aCalendarFileSwiftCannotLoadIsStoredButUnreadable() throws {
        let t = F.folder(); defer { t.remove() }
        let paths = RecordingPaths(t.url)
        #expect(!C.storedButUnreadable(paths))  // no file
        try C.save(paths, ev("Sync", 0, 30, "Anna"))
        #expect(!C.storedButUnreadable(paths))
        try C.ask(paths, [ev("A", 0, 60, "Anna"), ev("B", 0, 60, "Bob")])
        #expect(!C.storedButUnreadable(paths))
        try C.dismiss(paths)
        #expect(!C.storedButUnreadable(paths))
        for text in ["not json", #"{"title": 5, "start": "2026-10-27T15:00:00+01:00", "end": "2026-10-27T15:30:00+01:00"}"#,
                     #"{"title": "x", "start": "20261027T1500", "end": "20261027T1530"}"#] {
            t.write("calendar.json", text)
            #expect(C.storedButUnreadable(paths), "\(text)")
        }
    }

    @Test func invitedNamesComeFromTheStoredEvent() throws {
        let t = F.folder(); defer { t.remove() }
        let paths = RecordingPaths(t.url)
        #expect(C.invitedNames(paths, ["Freddy"]) == nil)
        try C.save(paths, ev("Sync", 0, 30, "Timo Strauß", "Freddy Schmidt", "Zoe Ray"))
        #expect(C.invitedNames(paths, ["Freddy"], userName: "Timo") == ["Freddy", "Zoe Ray"])
    }

    // MARK: datetimes

    @Test func datetimesParseAndPrintAsPythonDoes() throws {
        for row in try #require(Goldens.load("calendar")["parsed"]?.arrayValue) {
            let r = try #require(row.arrayValue)
            let text = try #require(r[0].stringValue)
            guard let iso = r[1].stringValue else {
                #expect(throws: (any Error).self, "\(text)") { try PyDateTime.parse(text) }
                continue
            }
            let d = try PyDateTime.parse(text)
            #expect(d.iso == iso, "\(text)")
            #expect(d.dayISO == r[2].stringValue, "\(text)")
            if let stamp = r[3].doubleValue { #expect(Double(d.micros) / 1_000_000 == stamp, "\(text)") }
        }
    }

    @Test func aNaiveAndAnAwareDatetimeAreNeverEqual() throws {
        let naive = try PyDateTime.parse("2026-10-27T15:00:00"), aware = try PyDateTime.parse("2026-10-27T15:00:00+00:00")
        #expect(naive != aware)
        #expect(try PyDateTime.parse("2026-10-27T16:00:00+01:00") == PyDateTime.parse("2026-10-27T15:00:00Z"))
    }

    // MARK: decisions

    @Test func decisionsAreThoseOfPython() throws {
        for (name, c) in try fields(try #require(Goldens.load("calendar")["decisions"])) {
            let events = try #require(c["events"]?.arrayValue).map { try CalendarEvent(json: $0) }
            let start = F.at(try Goldens.int(c["start"])), end = F.at(try Goldens.int(c["end"]))
            let d = C.decide(events, start, end)
            #expect(d.event?.title == c["event"]?.stringValue, "\(name)")
            if let link = c["link"], !link.isNull { #expect(PythonJSON.dumps(d.link?.toDict() ?? .null) == PythonJSON.dumps(link), "\(name)") }
            else { #expect(d.link == nil, "\(name)") }
            #expect(d.question?.map(\.title) == c["question"]?.arrayValue?.compactMap(\.stringValue), "\(name)")
        }
    }
}
