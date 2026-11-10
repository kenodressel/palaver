// The glossary seed from the calendar (tests/test_onboarding.py: `test_seed_terms_from_the_calendar`,
// `test_own_organization_from_the_calendar`) and the Python goldens over event sets, users and known terms.
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private typealias F = SetupFixtures

private let AT = try! PyDateTime.parse("2026-10-28T10:00:00")

private func event(_ title: String, _ people: (String, String?, Bool)...) -> CalendarEvent {
    CalendarEvent(title: title, start: AT, end: AT, attendees: people.map { Attendee(name: $0.0, email: $0.1, isSelf: $0.2) })
}

@Suite struct SeedTermsTests {
    @Test func test_seed_terms_from_the_calendar() throws {
        let me = ("Timo Strauss", Optional("timo@kloud.io"), true)
        let events = [
            event("Contoso Northwind Weekly", me, ("Stefan Dornbusch", "stefan@contoso.at", false),
                  ("Anna Huber", "anna@kloud.io", false)),
            event("Northwind Planning", me, ("Stefan Dornbusch", "stefan@contoso.at", false), ("Room 4", nil, false)),
            event("Lunch", me, ("Max", "max@gmail.com", false)),
        ]
        let terms = Recommendations.seedTerms(events, userName: "Timo Strauss", known: ["anna huber"])
        let byTerm = Dictionary(uniqueKeysWithValues: terms.map { ($0.term, $0) })
        #expect(byTerm["Stefan Dornbusch"]?.kind == "person" && byTerm["Stefan Dornbusch"]?.count == 2)
        #expect(byTerm["Contoso"]?.kind == "organization")
        #expect(byTerm["Northwind"]?.kind == "title")
        #expect(byTerm["Timo Strauss"] == nil && byTerm["Anna Huber"] == nil)  // the user; already known
        #expect(byTerm["KLOUD"] == nil)  // the user's own organization
        #expect(byTerm["Extern"] == nil && byTerm["Room 4"] == nil && byTerm["Lunch"] == nil)
        #expect(["Stefan Dornbusch", "Contoso", "Northwind"].contains(try #require(terms.first).term))  // the most frequent first
    }

    @Test func test_own_organization_from_the_calendar() {
        let me = ("Timo Strauss", Optional("timo@kloud.io"), true)
        #expect(Recommendations.ownOrganization([event("Sync", me)]) == "KLOUD")
        #expect(Recommendations.ownOrganization([]) == nil)
    }

    private func events(_ specs: JSONValue?) -> [CalendarEvent] {
        (specs?.arrayValue ?? []).map { spec in
            let people = (spec["attendees"]?.arrayValue ?? []).map { a -> Attendee in
                let p = a.arrayValue!
                return Attendee(name: p[0].stringValue!, email: p[1].stringValue, isSelf: p[2].boolValue!, isRoom: p[3].boolValue!)
            }
            return CalendarEvent(title: spec["title"]!.stringValue!, start: AT, end: AT, attendees: people)
        }
    }

    @Test func golden_seed_terms_and_own_organization() {
        let sets = F.list("events").map { events($0) }
        var got: [JSONValue] = [], want: [JSONValue] = []
        for c in F.list("seeds") {
            let a = c.arrayValue!
            let terms = Recommendations.seedTerms(sets[F.int(a[0])], userName: a[1].stringValue!, known: F.strings(a[2]))
            got.append(.array(terms.map(\.json)))
            want.append(a[3])
        }
        #expect(want.count > 50)
        var reported = 0
        for (i, (g, w)) in zip(got, want).enumerated() where reported < 5 && F.dumps(g) != F.dumps(w) {
            Issue.record("seed_terms #\(i): got \(F.dumps(g)), want \(F.dumps(w))")
            reported += 1
        }
        #expect(reported == 0 && got.count == want.count)
        for c in F.list("own") {
            let a = c.arrayValue!
            #expect(Recommendations.ownOrganization(sets[F.int(a[0])]) == a[1].stringValue, "own \(a[0])")
        }
    }
}
