// projects.py (test_projects.py): the store and the rules. The model's tests (suggest_with_model, describe_with_model,
// cli._sort_into_projects and the cloud) stay Python until phase 4 (ledger).
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

/// A temporary output folder with its own config dir (projects.json, settings.json, the glossary).
struct ProjectsRoot {
    let temp = TempFolder("projects")
    var recordings: URL { temp.url.appendingPathComponent("Recordings", isDirectory: true) }
    var stores: StorePaths {
        StorePaths.current(env: ["XDG_CONFIG_HOME": temp.url.appendingPathComponent("config").path,
                                 "PALAVER_HOME": temp.url.appendingPathComponent("home").path])
    }

    func remove() { temp.remove() }

    func store() -> ProjectStore { ProjectStore(path: stores.projects) }

    /// test_projects.py's `_meeting`: a processed meeting at 2026-10-27 10:00 with its event (the user and `people`
    /// invited, their addresses at `domain`), and notes when there is a `summary`.
    @discardableResult
    func meeting(_ name: String, _ title: String, _ people: String..., domain: String = "kloud.io",
                 summary: String = "") throws -> RecordingPaths {
        let paths = RecordingPaths(recordings.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        try PythonJSON.write(.object([("start_time", .string("2026-10-27T10:00:00+01:00")), ("duration_seconds", .int(600))]),
                             to: paths.meta, indent: nil, ensureAscii: true)
        try PythonJSON.write(.array([]), to: paths.transcriptJson, indent: nil, ensureAscii: true)
        let start = try PyDateTime.parse("2026-10-27T10:00:00+01:00")
        let attendees = [Attendee(name: "Timo Strauss", email: "timo@kloud.io", isSelf: true)] + people.map {
            Attendee(name: $0, email: "\(Py.strLower(Py.split($0)[0]))@\(domain)")
        }
        try CalendarEvents.save(paths, CalendarEvent(title: title, start: start, end: start.adding(micros: 30 * 60_000_000),
                                                     attendees: attendees))
        if !summary.isEmpty {
            try PythonJSON.write(.object([("title", .string(title)), ("summary", .string(summary))]), to: paths.notes,
                                 indent: nil, ensureAscii: true)
        }
        return paths
    }
}

@Suite struct ProjectsTests {
    private func dumps(_ v: JSONValue) -> String { PythonJSON.dumps(v, ensureAscii: false) }
    private func ids(_ d: PyDict<JSONValue>) -> Set<String> { Set(d.keys) }

    // MARK: the store

    @Test func test_store_keeps_projects_and_n_to_m_assignments() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        let store = root.store()
        let northwind = try store.create("Northwind", description: "Rollout for Contoso")
        let hiring = try store.create("Recruiting")
        #expect(try store.create("northwind") == northwind)  // same name, same project
        try store.assign("m1", northwind)
        try store.assign("m1", hiring)  // a 1:1 about two topics
        try store.save()

        let again = root.store()
        #expect(ids(again.ofMeeting("m1")) == [northwind, hiring])
        #expect(again.projects[northwind]?["description"]?.stringValue == "Rollout for Contoso")
        #expect(throws: ProjectValueError.self) { try again.update(hiring, name: "Northwind") }
    }

    @Test func test_removing_a_meeting_is_final_for_rules_and_model() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        let store = root.store()
        let pid = try store.create("Northwind")
        #expect(try store.assign("m1", pid, by: "auto", why: "title"))
        store.unassign("m1", pid)
        #expect(try !store.assign("m1", pid, by: "model"))
        #expect(store.ofMeeting("m1").isEmpty)
        #expect(try store.assign("m1", pid))  // the user may change their mind
        #expect(store.rejected("m1") == [])
    }

    @Test func test_weaker_deciders_never_override_stronger_ones() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        let store = root.store()
        let pid = try store.create("Northwind")
        try store.assign("m1", pid, by: "you")
        #expect(try !store.assign("m1", pid, by: "auto", why: "title"))
        #expect(store.ofMeeting("m1")[pid]?["by"]?.stringValue == "you")
    }

    @Test func test_merging_projects_moves_their_meetings() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        let store = root.store()
        let a = try store.create("Northwind", description: "Contoso rollout"), b = try store.create("Northwind Rollout")
        try store.assign("m1", a, by: "auto", why: "title")
        try store.assign("m2", a)
        try store.assign("m2", b, by: "model")
        store.unassign("m3", a)
        try store.merge(a, into: b)

        #expect(ids(store.projects) == [b])
        #expect(dumps(store.ofMeeting("m1").json) == dumps(.object([(b, .object([("by", .string("auto")), ("why", .string("title"))]))])))
        #expect(store.ofMeeting("m2")[b]?["by"]?.stringValue == "you")  // the stronger one survives
        #expect(store.projects[b]?["description"]?.stringValue == "Contoso rollout")  // it had none
        #expect(store.rejected("m3") == [])
        #expect(throws: ProjectValueError.self) { try store.merge(b, into: b) }
    }

    @Test func test_deleting_a_project_frees_its_meetings() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        let store = root.store()
        let pid = try store.create("Northwind")
        try store.assign("m1", pid)
        try store.delete(pid)
        #expect(store.ofMeeting("m1").isEmpty && store.projects.isEmpty)
    }

    // test_attribution.py's (#48).
    @Test func test_rules_keep_how_sure_they_were() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        let store = root.store()
        let pid = try store.create("Northwind")
        #expect(try store.assign("m1", pid, by: "auto", why: "title", confidence: 0.72))
        #expect(dumps(store.ofMeeting("m1").json)
                == dumps(.object([(pid, .object([("by", .string("auto")), ("why", .string("title")), ("confidence", .double(0.72))]))])))
    }

    @Test func projectIdsAreEightLowercaseHex() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        let store = root.store()
        for i in 0..<64 {
            let pid = try store.create("Project \(i)")
            #expect(pid.unicodeScalars.count == 8 && pid.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) },
                    "\(pid)")
        }
        #expect(store.projects.count == 64)
    }

    @Test func aMissingProjectIsALookupErrorAndANameIsNeeded() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        let store = root.store()
        #expect(throws: ProjectLookupError.self) { try store.assign("m1", "0badf00d") }
        #expect(throws: ProjectLookupError.self) { try store.delete("0badf00d") }
        #expect(throws: ProjectLookupError.self) { try store.update("0badf00d", name: "x") }
        #expect(store.ofMeeting("m1").isEmpty && store.rejected("m1").isEmpty)  // no entry made for nothing
        #expect(throws: ProjectValueError.self) { try store.create("  ") }
    }

    @Test func saveWaitsForTheStoresLock() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        let file = root.stores.projects
        // Another process (Python's `locked`) holds projects.json.lock for half a second.
        let held = try LockHolder(URL(fileURLWithPath: file.path + ".lock"), seconds: 0.5)
        let store = root.store()
        try store.create("Northwind")
        let start = Date()
        try store.save()
        #expect(Date().timeIntervalSince(start) >= 0.4)
        held.wait()
        #expect(root.store().find("northwind") != nil)
    }

    // MARK: the rules

    @Test func test_rules_place_meetings_like_the_ones_already_in_a_project() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        try root.meeting("2026-10-20T10-00-00", "Northwind Sync", "Valerie")
        try root.meeting("2026-10-21T10-00-00", "Northwind Sync", "Valerie")  // the series again
        try root.meeting("2026-10-22T10-00-00", "Lunch", "Anna")
        try root.meeting("2026-10-23T10-00-00", "Recruiting Sync", "Carla")
        let setup = root.store()
        let pid = try setup.create("Northwind")
        try setup.assign("2026-10-20T10-00-00", pid)
        // Python hands its unsaved store in; the Swift pass reads the store afresh under the lock, so the setup is saved.
        try setup.save()

        let (store, added) = try ProjectRules.assignByRules(outputDir: root.recordings, userName: "Timo", stores: root.stores)
        #expect(added.map { "\($0.0) \($0.1)" } == ["2026-10-21T10-00-00 \(pid)"])
        #expect(store.ofMeeting("2026-10-21T10-00-00")[pid]?["by"]?.stringValue == "auto")
        #expect(store.ofMeeting("2026-10-21T10-00-00")[pid]?["why"]?.stringValue?.contains("Northwind Sync") == true)
        #expect(root.store().ofMeeting("2026-10-21T10-00-00")[pid] != nil)  // saved
    }

    @Test func test_a_customer_domain_and_people_count() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        let a = try ProjectRules.facts(try root.meeting("2026-10-20T10-00-00", "Spain migration", "Valerie Brandt", domain: "contoso.es"),
                                       userName: "Timo", stores: root.stores)
        let b = try ProjectRules.facts(try root.meeting("2026-10-21T10-00-00", "Verticalization", "Valerie Brandt", domain: "contoso.com"),
                                       userName: "Timo", stores: root.stores)
        #expect(a.orgs == ["contoso"] && !a.people.contains("timo strauss"))
        let (score, why) = Similarity(PyDict([(a.meeting, a), (b.meeting, b)]))(a, b)
        #expect(score >= ProjectRules.ASSIGN_SCORE && why == "people")
    }

    @Test func test_suggestions_skip_taken_and_rejected_projects() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        try root.meeting("2026-10-20T10-00-00", "Northwind Sync", "Valerie")
        try root.meeting("2026-10-21T10-00-00", "Northwind Review", "Valerie", "Carla")
        let store = root.store()
        let pid = try store.create("Northwind")
        try store.assign("2026-10-20T10-00-00", pid)
        let every = try ProjectRules.allFacts(outputDir: root.recordings, userName: "Timo", stores: root.stores)
        let found = ProjectRules.suggestions("2026-10-21T10-00-00", store: store, every: every)
        #expect(found.count == 1)
        #expect(found.first?["id"]?.stringValue == pid && found.first?["name"]?.stringValue == "Northwind")
        store.unassign("2026-10-21T10-00-00", pid)
        #expect(ProjectRules.suggestions("2026-10-21T10-00-00", store: store, every: every).isEmpty)
    }

    @Test func test_an_earlier_name_of_the_user_is_no_participant() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        let paths = try root.meeting("2026-10-20T10-00-00", "Northwind Sync", "Valerie Brandt", "Timo")
        try SettingsFile.update([("user_name", .string("Timo Strauß")), ("user_aliases", .array([.string("Timo")]))], stores: root.stores)
        let f = try ProjectRules.facts(paths, userName: "Timo Strauß", stores: root.stores)
        #expect(f.people == ["valerie brandt"])
        #expect(!ProjectRules.words("Timo Northwind", me: ProjectRules.me("Timo Strauß", stores: root.stores)).contains("timo"))
    }

    @Test func aRulePassReadsTheStoreAfreshAndKeepsWhatOthersSaved() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        try root.meeting("2026-10-20T10-00-00", "Northwind Sync", "Valerie")
        try root.meeting("2026-10-21T10-00-00", "Northwind Sync", "Valerie")
        let first = root.store()
        let pid = try first.create("Northwind")
        try first.assign("2026-10-20T10-00-00", pid)
        try first.save()
        // Another writer (the window) adds a project before the pass.
        let other = root.store()
        let hiring = try other.create("Recruiting")
        try other.save()

        let (store, added) = try ProjectRules.assignByRules(outputDir: root.recordings, userName: "Timo",
                                                            meetings: ["2026-10-21T10-00-00"], stores: root.stores)
        #expect(added.count == 1 && store.projects[hiring] != nil)
        let now = root.store()
        #expect(now.projects[hiring] != nil && now.ofMeeting("2026-10-21T10-00-00")[pid] != nil)
    }

    @Test func test_a_rule_pass_waits_for_the_stores_lock() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        try root.meeting("2026-10-20T10-00-00", "Northwind Sync", "Valerie")
        try root.meeting("2026-10-21T10-00-00", "Northwind Sync", "Valerie")
        let setup = root.store()
        let pid = try setup.create("Northwind")
        try setup.assign("2026-10-20T10-00-00", pid)
        try setup.save()
        let lock = URL(fileURLWithPath: root.stores.projects.path + ".lock")

        // Another process (Python's `locked`) holds projects.json.lock for half a second.
        var held = try LockHolder(lock, seconds: 0.5)
        var start = Date()
        let added = try ProjectRules.assignByRules(outputDir: root.recordings, userName: "Timo", stores: root.stores).added
        #expect(Date().timeIntervalSince(start) >= 0.4 && added.count == 1)
        held.wait()

        // Prep.apply assigns what was chosen beforehand under the same lock.
        let start2 = try PyDateTime.parse("2026-10-27T10:00:00+01:00")
        let event = CalendarEvent(title: "Northwind Sync", start: start2, end: try! start2.adding(seconds: 1800),
                                  attendees: [Attendee(name: "Valerie", email: "valerie@kloud.io")], uid: "abc")
        try Prep.choose(event, pid, stores: root.stores)
        let paths = try root.meeting("2026-10-22T10-00-00", "Northwind Sync", "Valerie")
        held = try LockHolder(lock, seconds: 0.5)
        start = Date()
        #expect(try Prep.apply(paths, event: event, stores: root.stores) == [pid])
        #expect(Date().timeIntervalSince(start) >= 0.4)
        held.wait()
    }

    @Test func aMeetingAlreadyInAProjectIsLeftToItsDecider() throws {
        let root = ProjectsRoot(); defer { root.remove() }
        try root.meeting("2026-10-20T10-00-00", "Northwind Sync", "Valerie")
        try root.meeting("2026-10-21T10-00-00", "Northwind Sync", "Valerie")
        let store = root.store()
        let a = try store.create("Northwind"), b = try store.create("Other")
        try store.assign("2026-10-20T10-00-00", a)
        try store.assign("2026-10-21T10-00-00", b, by: "model")
        try store.save()
        #expect(try ProjectRules.assignByRules(outputDir: root.recordings, userName: "Timo", stores: root.stores).added.isEmpty)
        // An auto assignment does not represent its project: the rules never feed on themselves.
        let scores = ProjectRules.scores(try ProjectRules.facts(RecordingPaths(root.recordings.appendingPathComponent("2026-10-21T10-00-00")),
                                                                userName: "Timo", stores: root.stores),
                                         store, try ProjectRules.allFacts(outputDir: root.recordings, userName: "Timo", stores: root.stores),
                                         Similarity(PyDict()))
        #expect(scores.map(\.pid) == [a])
        #expect(scores.first?.why == "people like “Northwind Sync”")  // people and title tie: the first wins
    }

    // MARK: goldens

}

private extension JSONValue {
    subscript(_ i: Int) -> JSONValue? { arrayValue.flatMap { i < $0.count ? $0[i] : nil } }
}
