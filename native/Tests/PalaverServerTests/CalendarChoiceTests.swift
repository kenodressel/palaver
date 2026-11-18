// Settings → Calendar: the calendars Palaver reads, each on unless turned off (a personal calendar next to the work
// one). The choice is settings.json's `calendars_off`; the providers leave those calendars' events out.
import Foundation
import PalaverCore
import PalaverDomain
@testable import PalaverServer
import Testing

private let MAC = [CalendarInfo(id: "work-1", title: "Calendar", account: "Contoso", color: "#1e88e5"),
                   CalendarInfo(id: "home-1", title: "Family", account: "iCloud", color: "#43a047")]

private func on(_ answer: JSONValue?) -> [String: Bool] {
    var out: [String: Bool] = [:]
    for c in answer?["calendars"]?.arrayValue ?? [] { out[c["id"]?.stringValue ?? ""] = c["on"] == .bool(true) }
    return out
}

@Suite struct CalendarChoiceTests {
    @Test func aCalendarTurnedOffStaysOffAndBackOn() throws {
        let s = try TestServer(calendars: { MAC }); defer { s.stop() }
        #expect(on(s.get("/api/calendars").json) == ["work-1": true, "home-1": true])
        let answer = s.post("/api/calendars", .object([("id", .string("home-1")), ("on", .bool(false))]))
        #expect(answer.status == 200)
        #expect(on(answer.json) == ["work-1": true, "home-1": false])
        #expect(SettingsFile.calendarsOff(stores: s.app.stores) == ["home-1"])
        #expect(answer.json?["calendars"]?.arrayValue?.last?["account"] == .string("iCloud"))
        // Other settings stay as they are.
        _ = s.post("/api/settings", .object([("nudge_pace", .bool(true))]))
        _ = s.post("/api/calendars", .object([("id", .string("home-1")), ("on", .bool(true))]))
        #expect(SettingsFile.calendarsOff(stores: s.app.stores).isEmpty)
        #expect(SettingsFile.load(stores: s.app.stores).nudgePace)
    }

    @Test func onlyACalendarOfThisMacWithAYesOrNoIsTurned() throws {
        let s = try TestServer(calendars: { MAC }); defer { s.stop() }
        #expect(s.post("/api/calendars", .object([("id", .string("elsewhere")), ("on", .bool(false))])).status == 404)
        #expect(s.post("/api/calendars", .object([("id", .string("home-1"))])).status == 400)
        #expect(s.post("/api/calendars", .object([("id", .string("home-1")), ("on", .string("no"))])).status == 400)
        #expect(SettingsFile.calendarsOff(stores: s.app.stores).isEmpty)
    }

    @Test func withTheCalendarTurnedOffThereAreNoCalendarsToChoose() throws {
        let s = try TestServer(); defer { s.stop() }
        #expect(s.get("/api/calendars").json == .object([("calendars", .array([]))]))
        #expect(s.post("/api/calendars", .object([("id", .string("home-1")), ("on", .bool(false))])).status == 404)
    }
}
