// organizations.py (test_organizations.py, the organization tests of test_attribution.py): the domain says the
// organization, a person can be given one, organizations can be renamed. The page halves of the window's tests (the
// speakers' and invitees' `org`, the directory) are ported with api.py.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct OrganizationsTests {
    private func folder() -> TempFolder { TempFolder("organizations") }

    private func entry(_ name: String, _ emails: [String], me: Bool = false) -> JSONValue {
        var counts: [(String, JSONValue)] = []
        for e in emails {
            if let i = counts.firstIndex(where: { $0.0 == e }), case .int(let n) = counts[i].1 { counts[i].1 = .int(n + 1) }
            else { counts.append((e, .int(1))) }
        }
        return .object([("name", .string(name)), ("email", .string(emails.last!)), ("emails", .object(counts)), ("self", .bool(me))])
    }

    private func index(_ pairs: [(String, JSONValue)]) -> PyDict<JSONValue> { PyDict(pairs) }

    private func orgs(_ t: TempFolder, _ name: String = "organizations.json") -> Organizations {
        Organizations(path: t.url.appendingPathComponent(name))
    }

    @Test func test_the_email_domain_says_the_organization() {
        #expect(Orgs.orgKey("karel@contoso.es") == "contoso" && Orgs.orgKey("jan@contoso.com") == "contoso")
        #expect(Orgs.orgKey("ana@externos.contoso.es") == "contoso")
        #expect(Orgs.orgKey("stefan@gmail.com") == "extern")
        #expect(Orgs.orgKey(nil) == nil)
        #expect(Orgs.defaultName("kloud") == "KLOUD" && Orgs.defaultName("contoso") == "Contoso")
        #expect(Orgs.defaultName("extern") == "Extern")
    }

    @Test func test_the_keys_and_names_are_pythons_over_unicode_15_1() throws {
        for c in try Goldens.cases("organizations", "keys") {
            #expect(Orgs.orgKey(c[0].stringValue) == c[1].stringValue, "key of \(PythonJSON.dumps(c[0]))")
        }
        for c in try Goldens.cases("organizations", "defaults") {
            #expect(Orgs.defaultName(c[0].stringValue ?? "") == c[1].stringValue, "name of \(PythonJSON.dumps(c[0]))")
        }
    }

    private func withInvitees(_ t: TempFolder) throws -> RecordingPaths {
        let paths = RecordingPaths(t.url.appendingPathComponent("2026-10-27T16-03-07", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        let start = try PyDateTime.parse("2026-10-27T16:03:07+01:00")
        try CalendarEvents.save(paths, CalendarEvent(title: "Debrief", start: start, end: start.adding(micros: 30 * 60_000_000), attendees: [
            Attendee(name: "Timo Strauß", email: "timo@kloud.io", isSelf: true),
            Attendee(name: "Rico Lanza", email: "rico@muellerbau.at"),
            Attendee(name: "Anna Huber", email: "anna@gmail.com"),
            Attendee(name: "Room 3", email: "room@kloud.io", isRoom: true),
        ]))
        return paths
    }

    @Test func test_speakers_and_invitees_show_their_organization() throws {
        let t = folder(); defer { t.remove() }
        _ = try withInvitees(t)
        let index = Orgs.peopleIndex(outputDir: t.url)
        #expect(index.keys == ["timo strauss", "rico lanza", "anna huber"])  // the room is no invitee
        let o = orgs(t, "none.json")
        // "Rico": a first name resolves to Rico Lanza; "Timo" to the user; an unknown speaker has none.
        #expect(["Timo", "Rico", "Zoe"].map { Orgs.orgOf($0, index, o) } == ["KLOUD", "Muellerbau", nil])
        #expect(["Rico Lanza", "Anna Huber"].map { Orgs.orgOf($0, index, o) } == ["Muellerbau", "Extern"])
        #expect(Orgs.ownOrg(index, o, userName: "Timo") == "KLOUD")
    }

    @Test func test_organizations_can_be_renamed_and_people_given_one() throws {
        let t = folder(); defer { t.remove() }
        _ = try withInvitees(t)
        let index = Orgs.peopleIndex(outputDir: t.url)
        let o = orgs(t)
        o.rename("muellerbau", "Müllerbau")
        o.setPerson("Stefan D", "Extern")
        try o.save()
        let again = orgs(t)
        #expect(["Timo", "Rico", "Stefan D"].map { Orgs.orgOf($0, index, again) } == ["KLOUD", "Müllerbau", "Extern"])
        #expect(Orgs.orgLink("Stefan D", index, again)?.byYou == true)
        #expect(PythonJSON.dumps(.array(Orgs.summary(index, again)), ensureAscii: false)
                == PythonJSON.dumps(try PythonJSON.parse(Data("""
                [{"key": "extern", "name": "Extern", "default": "Extern", "people": 1},
                 {"key": "kloud", "name": "KLOUD", "default": "KLOUD", "people": 1},
                 {"key": "muellerbau", "name": "Müllerbau", "default": "Muellerbau", "people": 1}]
                """.utf8)), ensureAscii: false))
        again.setPerson("Stefan D", "")
        #expect(Orgs.orgOf("Stefan D", index, again) == nil)
        try again.save()
        let file = try #require(PythonJSON.read(t.url.appendingPathComponent("organizations.json")))
        #expect(PythonJSON.dumps(try #require(file["names"]), ensureAscii: false) == #"{"muellerbau": "Müllerbau"}"#)
    }

    @Test func test_a_colleague_at_a_client_stays_a_colleague() {
        // Felix is KLOUD but was invited with his Contoso address lately; Anna has two client addresses, more often the
        // Contoso one.
        let index = index([
            ("timo", entry("Timo", ["timo@kloud.io"], me: true)),
            ("felix brunner", entry("Felix Brunner", ["felix@kloud.io", "felix.brunner@contoso.es"])),
            ("anna huber", entry("Anna Huber", ["anna@contoso.de", "anna@contoso.de", "anna@muellerbau.at"])),
        ])
        let o = Organizations(path: URL(fileURLWithPath: "/nonexistent/organizations.json"))
        #expect(Orgs.orgOf("Felix Brunner", index, o) == "KLOUD")
        #expect(Orgs.orgOf("Anna Huber", index, o) == "Contoso")
    }

    @Test func test_the_index_keeps_every_address_of_a_person() throws {
        let t = folder(); defer { t.remove() }
        let start = try PyDateTime.parse("2026-10-27T16:03:07+01:00")
        for (name, email) in [("2026-10-27T16-03-07", "felix@kloud.io"), ("2026-10-28T16-03-07", "felix.brunner@contoso.es")] {
            let paths = RecordingPaths(t.url.appendingPathComponent(name, isDirectory: true))
            try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
            try CalendarEvents.save(paths, CalendarEvent(title: "Sync", start: start, end: start.adding(micros: 30 * 60_000_000),
                                                         attendees: [Attendee(name: "Felix Brunner", email: email)]))
        }
        let entry = try #require(Orgs.peopleIndex(outputDir: t.url)["felix brunner"])
        #expect(PythonJSON.dumps(try #require(entry["emails"])) == #"{"felix@kloud.io": 1, "felix.brunner@contoso.es": 1}"#)
        #expect(entry["email"]?.stringValue == "felix.brunner@contoso.es")  // the latest
    }

    @Test func test_the_organization_says_where_it_came_from() {
        let index = index([
            ("anna huber", entry("Anna Huber", ["anna@contoso.de", "anna@contoso.de", "anna@contoso.de"])),
            ("bob weiss", entry("Bob Weiss", ["bob@contoso.de", "bob@contoso.de", "bob@rtv.at", "bob@rtv.at"])),
        ])
        let o = Organizations(path: URL(fileURLWithPath: "/nonexistent/organizations.json"))
        let anna = Orgs.orgLink("Anna Huber", index, o)
        #expect(anna?.target == "Contoso" && anna?.source == "email" && anna?.reason == "invited as anna@contoso.de" && anna?.unsure == false)
        let bob = Orgs.orgLink("Bob Weiss", index, o)
        #expect(bob?.unsure == true && bob?.reason == "invited with addresses of 2 organizations")
        #expect(Orgs.orgLink("Anna", index, o)?.reason == "invited as anna@contoso.de; matched by first name")
        o.setPerson("Bob Weiss", "RTV")
        #expect(Orgs.orgLink("Bob Weiss", index, o)?.byYou == true)
        #expect(Orgs.orgLink("Zoe", index, o) == nil)
    }

    @Test func test_a_colleague_at_a_client_is_not_unsure() {
        let index = index([
            ("timo", .object([("name", .string("Timo")), ("email", .string("timo@kloud.io")),
                              ("emails", .object([("timo@kloud.io", .int(5))])), ("self", .bool(true))])),
            ("mia lang", .object([("name", .string("Mia Lang")), ("email", .string("mia@contoso.de")),
                                  ("emails", .object([("mia@contoso.de", .int(4)), ("mia@kloud.io", .int(1))])), ("self", .bool(false))])),
        ])
        let link = Orgs.orgLink("Mia Lang", index, Organizations(path: URL(fileURLWithPath: "/nonexistent/organizations.json")))
        #expect(link?.target == "KLOUD" && link?.unsure == false && link?.reason == "has an address of your organization")
    }

    // MARK: the store

    @Test func theFileKeepsItsOwnKeysAndIsWrittenLikePython() throws {
        let t = folder(); defer { t.remove() }
        let file = t.url.appendingPathComponent("organizations.json")
        try Data(#"{"extra": [1, 2.50], "people": {"timo strauss": "KLOUD"}, "names": {"northwind": "Northwind Traders"}}"#.utf8).write(to: file)
        let o = Organizations(path: file)
        o.rename("kloud", "KLOUD")  // the default again: nothing stored
        o.rename("contoso", "  Contoso Iberia ")
        o.setPerson(" Timo Strauß ", "x")
        o.setPerson("  Anna ", "  RTV ")
        try o.save()
        let want = """
        {
          "extra": [
            1,
            2.5
          ],
          "people": {
            "timo strauss": "x",
            "anna": "RTV"
          },
          "names": {
            "northwind": "Northwind Traders",
            "contoso": "Contoso Iberia"
          }
        }
        """
        #expect(try String(contentsOf: file, encoding: .utf8) == want)  // ensure_ascii off, no trailing newline
        #expect(!FileManager.default.fileExists(atPath: t.url.appendingPathComponent("organizations.json.tmp").path))
    }

    @Test func aFileMissingItsKeysGetsThemInPythonsOrder() throws {
        let t = folder(); defer { t.remove() }
        let o = orgs(t)
        try o.save()
        #expect(try String(contentsOf: t.url.appendingPathComponent("organizations.json"), encoding: .utf8)
                == "{\n  \"names\": {},\n  \"people\": {}\n}")
        try Data("{not json".utf8).write(to: t.url.appendingPathComponent("broken.json"))
        let broken = orgs(t, "broken.json")
        #expect(broken.name("kloud") == "KLOUD" && broken.person("Anna") == nil)
    }

    @Test func savingWaitsForTheStoreLockAndKeepsItsFile() throws {
        let t = folder(); defer { t.remove() }
        let file = t.url.appendingPathComponent("organizations.json")
        // Another process (Python's `locked`) holds organizations.json.lock for half a second.
        let held = try LockHolder(URL(fileURLWithPath: file.path + ".lock"), seconds: 0.5)
        let o = orgs(t)
        o.setPerson("Anna", "RTV")
        let start = Date()
        try o.save()
        #expect(Date().timeIntervalSince(start) >= 0.4)
        held.wait()
        #expect(orgs(t).person("anna") == "RTV")
    }

    // MARK: canonically equivalent spellings are different keys, as in Python

    private static let nfc = "Zo\u{00EB}", nfd = "Zoe\u{0308}"

    @Test func aPyDictKeepsNFCAndNFDAsTwoKeys() throws {
        let text = #"{"Zo\u00eb": 1, "Zoe\u0308": 2}"#
        let d = try #require(PyDict<JSONValue>(try PythonJSON.parse(Data(text.utf8))))
        #expect(d.count == 2 && d[Self.nfc] == .int(1) && d[Self.nfd] == .int(2))
        #expect(PythonJSON.dumps(d.json) == text)
        var e = d
        e[Self.nfd] = nil
        #expect(e.count == 1 && e[Self.nfc] == .int(1) && e[Self.nfd] == nil)
        #expect(!Py.same(Self.nfc, Self.nfd) && Py.same(Self.nfc, Self.nfc))
    }

    @Test func anOrganizationsFileWithBothFormsSurvivesASave() throws {
        let t = folder(); defer { t.remove() }
        let file = t.url.appendingPathComponent("organizations.json")
        let text = "{\n  \"names\": {\n    \"\(Self.nfc)\": \"A\",\n    \"\(Self.nfd)\": \"B\"\n  },\n  \"people\": {\n    \"\(Self.nfc.lowercased())\": \"C\",\n    \"\(Self.nfd.lowercased())\": \"D\"\n  }\n}"
        try Data(text.utf8).write(to: file)
        let o = Organizations(path: file)
        #expect(o.name(Self.nfc) == "A" && o.name(Self.nfd) == "B")
        #expect(o.person(Self.nfc) == "C" && o.person(Self.nfd) == "D")
        try o.save()
        #expect(try Data(contentsOf: file) == Data(text.utf8))
    }

    @Test func aPersonInAnotherFormIsAnotherPerson() {
        let index = index([("\(Self.nfc.lowercased()) lang", entry("\(Self.nfc) Lang", ["z@contoso.de"]))])
        let o = Organizations(path: URL(fileURLWithPath: "/nonexistent/organizations.json"))
        let lowerNFC = Self.nfc.lowercased()
        #expect(Orgs.orgLink("\(Self.nfd) Lang", index, o) == nil)  // the other spelling: nobody
        #expect(Orgs.orgLink(Self.nfd, index, o) == nil)  // not even by first name
        let first = Orgs.orgLink(lowerNFC, index, o)
        #expect(first?.confidence == 0.6 && first?.reason == "invited as z@contoso.de; matched by first name")
    }
}
