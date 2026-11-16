// Note templates (#13): the built-in ones, the user's own in templates.json, the series' choices, the calendar title's
// rules, and the order a meeting's template is picked in.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct NoteTemplatesTests {
    private static let START = try! PyDateTime.parse("2026-11-16T10:00:00+01:00")

    private struct Setup {
        let t = TempFolder("templates")
        let paths: RecordingPaths
        let stores: StorePaths
        init() throws {
            paths = RecordingPaths(t.url.appendingPathComponent("2026-11-16T10-00-00", isDirectory: true))
            stores = StorePaths(configDir: t.url.appendingPathComponent("palaver"), home: t.url)
            try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        }
        func event(_ title: String, uid: String = "", series: Bool = false) throws {
            try CalendarEvents.save(paths, NoteTemplatesTests.event(title, uid: uid, series: series))
        }
        func pick() -> [String] {
            let p = NoteTemplates.pick(paths, stores: stores)
            return [p.template.id, p.from]
        }
    }

    private static func event(_ title: String, uid: String = "", series: Bool = false) -> CalendarEvent {
        CalendarEvent(title: title, start: START, end: START.adding(micros: 30 * 60_000_000), uid: uid, series: series)
    }

    @Test func theBuiltInTemplatesAreThereAndDefaultAddsNothing() throws {
        let ids = NoteTemplates.builtin.map(\.id)
        #expect(ids == ["default", "one-on-one", "customer-call", "interview", "workshop", "standup"])
        #expect(NoteTemplates.builtin[0].instructions.isEmpty && NoteTemplates.builtin.allSatisfy(\.builtin))
        #expect(NoteTemplates.builtin.dropFirst().allSatisfy { $0.instructions.contains("Next steps:") })
        let interview = try #require(NoteTemplates.builtin.first { $0.id == "interview" })
        for part in ["candidate", "strengths", "concerns", "recommendation"] { #expect(interview.instructions.contains(part)) }
        let customer = try #require(NoteTemplates.builtin.first { $0.id == "customer-call" })
        for part in ["needs", "objections", "next step agreed with the customer and its date"] { #expect(customer.instructions.contains(part)) }
    }

    @Test(arguments: [
        ("1:1 Timo / Anna", "one-on-one"), ("Anna <> Timo 1on1", "one-on-one"), ("One on One", "one-on-one"),
        ("one-on-one Kim", "one-on-one"), ("Mitarbeitergespräch Carla", "one-on-one"), ("1 on 1", "one-on-one"),
        ("Interview: Carla (Backend)", "interview"), ("Vorstellungsgespräch Kim", "interview"), ("Bewerbungsgespräch", "interview"),
        ("Daily", "standup"), ("Team Stand-up", "standup"), ("STANDUP Northwind", "standup"), ("stand up", "standup"),
        ("Workshop Roadmap 2027", "workshop"), ("Retro Sprint 12", "workshop"), ("Brainstorming Pricing", "workshop"),
        ("Kundentermin Contoso", "customer-call"), ("Customer call Northwind", "customer-call"), ("Sales Demo", "customer-call"),
        ("Interview 1:1", "interview"),  // the first rule that matches wins
    ])
    func theCalendarTitleSaysTheTemplate(_ title: String, _ id: String) {
        #expect(NoteTemplates.byTitle(title) == id, "\(title)")
    }

    @Test(arguments: ["Weekly sync", "Planning 2026-11-12", "Budget 11:15", "Q1 review", "Dailymotion pitch", ""])
    func otherTitlesHaveNoTemplate(_ title: String) {
        #expect(NoteTemplates.byTitle(title) == nil, "\(title)")
    }

    @Test func theUsersOwnTemplatesAreAddedEditedAndDeleted() throws {
        let s = try Setup(); defer { s.t.remove() }
        let made = try NoteTemplates.add(name: "  Board\nmeeting ", instructions: " Sections: per agenda item. ", stores: s.stores)
        #expect(made.id.hasPrefix("my-") && made.name == "Board meeting" && made.instructions == "Sections: per agenda item.")
        #expect(NoteTemplates.all(stores: s.stores).map(\.id) == NoteTemplates.builtin.map(\.id) + [made.id])
        #expect(NoteTemplates.find(made.id, stores: s.stores)?.builtin == false)
        try NoteTemplates.update(made.id, name: "Board", instructions: "Per agenda item.", stores: s.stores)
        #expect(NoteTemplates.own(stores: s.stores) == [NoteTemplate(id: made.id, name: "Board", instructions: "Per agenda item.")])
        // Stored readably next to the other stores.
        let stored = try #require(PythonJSON.read(s.stores.noteTemplates))
        #expect(stored["templates"]?.arrayValue?.first?["name"] == .string("Board"))
        // Nothing empty, nothing built in changed.
        #expect(throws: NoteTemplateError.self) { try NoteTemplates.add(name: " ", instructions: "x", stores: s.stores) }
        #expect(throws: NoteTemplateError.self) { try NoteTemplates.add(name: "x", instructions: "\n", stores: s.stores) }
        #expect(throws: NoteTemplateError.self) {
            try NoteTemplates.add(name: "x", instructions: String(repeating: "a", count: 4001), stores: s.stores)
        }
        #expect(throws: NoteTemplateError.self) { try NoteTemplates.update("interview", name: "x", instructions: "y", stores: s.stores) }
        #expect(throws: NoteTemplateError.self) { try NoteTemplates.delete("default", stores: s.stores) }
        #expect(throws: NoteTemplateError.self) { try NoteTemplates.delete("my-none", stores: s.stores) }
        try NoteTemplates.delete(made.id, stores: s.stores)
        #expect(NoteTemplates.own(stores: s.stores).isEmpty)
    }

    @Test func aMeetingsTemplateIsPickedInOrder() throws {
        let s = try Setup(); defer { s.t.remove() }
        #expect(s.pick() == ["default", "default"])  // no event, no choice
        try s.event("Weekly Northwind", uid: "S1", series: true)
        #expect(s.pick() == ["default", "default"])
        try s.event("Interview Carla", uid: "S1", series: true)
        #expect(s.pick() == ["interview", "title"])
        // The series remembered beats the title.
        try NoteTemplates.rememberSeries(Self.event("Interview Carla", uid: "S1", series: true), "workshop", stores: s.stores)
        #expect(s.pick() == ["workshop", "series"])
        // The notes keep the template they were written with.
        try NotesFile.save(s.paths, .object([("title", .string("T")), ("template", .string("customer-call"))]))
        #expect(s.pick() == ["customer-call", "notes"])
        // The meeting's own choice beats all.
        try NoteTemplates.choose(s.paths, "standup", stores: s.stores)
        #expect(s.pick() == ["standup", "meeting"])
        #expect(NoteTemplates.meetingChoice(s.paths) == "standup")
        try NoteTemplates.choose(s.paths, nil, stores: s.stores)
        #expect(s.pick() == ["customer-call", "notes"])
        #expect(throws: NoteTemplateError.self) { try NoteTemplates.choose(s.paths, "nope", stores: s.stores) }
    }

    @Test func aMeetingSeriesOfPalaversOwnRemembersItsTemplate() throws {
        let s = try Setup(); defer { s.t.remove() }
        #expect(NoteTemplates.seriesKey(s.paths, event: nil, stores: s.stores) == nil)
        #expect(throws: NoteTemplateError.self) { try NoteTemplates.rememberSeries(s.paths, event: nil, "interview", stores: s.stores) }
        // In a series of the user's (#39): remembered for it, under its name in Settings.
        let own = try MeetingSeries.put(s.paths, intoNamed: "Valerie 1:1", stores: s.stores)
        try NoteTemplates.rememberSeries(s.paths, event: nil, "one-on-one", stores: s.stores)
        #expect(s.pick() == ["one-on-one", "series"])
        #expect(NoteTemplates.rememberedSeries(stores: s.stores).map { [$0.series, $0.title, $0.template] }
                == [["palaver:\(own.id)", "Valerie 1:1", "one-on-one"]])
        // The next meeting of the series has it too.
        let next = RecordingPaths(s.t.url.appendingPathComponent("2026-11-23T10-00-00", isDirectory: true))
        try FileManager.default.createDirectory(at: next.folder, withIntermediateDirectories: true)
        try MeetingSeries.put(next, into: own.id, stores: s.stores)
        #expect(NoteTemplates.pick(next, stores: s.stores).template.id == "one-on-one")
        // A recurring calendar event's own choice comes first.
        try s.event("Valerie 1:1", uid: "V1", series: true)
        #expect(NoteTemplates.seriesKey(s.paths, event: CalendarEvents.load(s.paths), stores: s.stores)?.key == "V1")
        #expect(s.pick() == ["one-on-one", "series"])  // the calendar series remembers none: the meeting series'
        try NoteTemplates.rememberSeries(s.paths, event: CalendarEvents.load(s.paths), "standup", stores: s.stores)
        #expect(s.pick() == ["standup", "series"])
    }

    @Test func aDeletedTemplateFallsBackToTheNextInLine() throws {
        let s = try Setup(); defer { s.t.remove() }
        try s.event("Stand-up", uid: "S2", series: true)
        let mine = try NoteTemplates.add(name: "Our daily", instructions: "Per person: yesterday, today.", stores: s.stores)
        try NoteTemplates.rememberSeries(Self.event("Stand-up", uid: "S2", series: true), mine.id, stores: s.stores)
        try NoteTemplates.choose(s.paths, mine.id, stores: s.stores)
        try NotesFile.save(s.paths, .object([("title", .string("T")), ("template", .string(mine.id))]))
        #expect(s.pick() == [mine.id, "meeting"])
        try NoteTemplates.delete(mine.id, stores: s.stores)
        #expect(s.pick() == ["standup", "title"])  // the series forgot it too
        #expect(NoteTemplates.rememberedSeries(stores: s.stores).isEmpty)
    }

    @Test func onlyARecurringEventsSeriesIsRemembered() throws {
        let s = try Setup(); defer { s.t.remove() }
        #expect(NoteTemplates.seriesId(nil) == nil)
        #expect(NoteTemplates.seriesId(Self.event("Once", uid: "X1")) == nil)
        #expect(NoteTemplates.seriesId(Self.event("Weekly", series: true)) == nil)
        // A moved occurrence belongs to its series.
        #expect(NoteTemplates.seriesId(Self.event("Weekly", uid: "W1/RID=20261116", series: true)) == "W1")
        #expect(throws: NoteTemplateError.self) { try NoteTemplates.rememberSeries(Self.event("Once", uid: "X1"), "interview", stores: s.stores) }
        let weekly = Self.event("Weekly Kim", uid: "W1", series: true)
        #expect(throws: NoteTemplateError.self) { try NoteTemplates.rememberSeries(weekly, "nope", stores: s.stores) }
        try NoteTemplates.rememberSeries(weekly, "one-on-one", stores: s.stores)
        #expect(NoteTemplates.seriesChoice(Self.event("Weekly Kim", uid: "W1/RID=x", series: true), stores: s.stores) == "one-on-one")
        #expect(NoteTemplates.rememberedSeries(stores: s.stores).map { [$0.series, $0.title, $0.template] } == [["W1", "Weekly Kim", "one-on-one"]])
        try NoteTemplates.rememberSeries(weekly, nil, stores: s.stores)
        #expect(NoteTemplates.seriesChoice(weekly, stores: s.stores) == nil)
        try NoteTemplates.rememberSeries(weekly, "workshop", stores: s.stores)
        try NoteTemplates.forgetSeries("W1", stores: s.stores)
        #expect(NoteTemplates.rememberedSeries(stores: s.stores).isEmpty)
    }

    @Test func aBrokenStoreIsNoTemplates() throws {
        let s = try Setup(); defer { s.t.remove() }
        try FileManager.default.createDirectory(at: s.stores.configDir, withIntermediateDirectories: true)
        try "not json".write(to: s.stores.noteTemplates, atomically: true, encoding: .utf8)
        #expect(NoteTemplates.own(stores: s.stores).isEmpty && s.pick() == ["default", "default"])
        try #"{"templates": [{"name": "no id"}, 3, {"id": "my-1", "name": "Kept"}]}"#.write(to: s.stores.noteTemplates, atomically: true, encoding: .utf8)
        #expect(NoteTemplates.own(stores: s.stores).map(\.name) == ["Kept"])
    }
}
