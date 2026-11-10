// attribution.py (test_attribution.py): links, evidence, decisions, attaching events and the Needs-you questions. Tests
// of other modules (voices, speakers, organizations, the window's API) are in the ledger.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct AttributionTests {
    typealias F = CalendarFixtures
    static let T0 = F.T0

    private func json(_ text: String) -> JSONValue { try! PythonJSON.parse(Data(text.utf8)) }

    // MARK: the record

    @Test func test_a_link_without_fields_is_of_unknown_source_and_not_unsure() {
        let link = Link.from(kind: "event", target: "Team standup", nil)
        #expect(link.source == "unknown" && link.confidence == nil && link.reason == "")
        #expect(!link.unsure && !link.byYou)
        #expect(link.toDict()["label"]?.stringValue == "Event: Team standup")
    }

    @Test func test_low_confidence_is_unsure_unless_the_user_set_it() {
        let sure = Link("event", "Northwind", "calendar", 0.9, "time match")
        let unsure = Link("event", "Northwind", "calendar", 0.6, "time match, 2 events overlapped")
        let yours = Link("event", "Northwind", "you", nil, "")
        #expect(!sure.unsure && unsure.unsure && !yours.unsure)
        #expect(PythonJSON.dumps(unsure.toDict()) == PythonJSON.dumps(json("""
            {"kind": "event", "target": "Northwind", "source": "calendar", "confidence": 0.6,
             "reason": "time match, 2 events overlapped", "unsure": true,
             "label": "Event: Northwind (time match, 2 events overlapped)"}
            """)))
        #expect(yours.toDict()["label"]?.stringValue == "Event: Northwind (you)")
    }

    @Test func test_a_project_is_unsure_until_the_user_confirms_it() {
        // Rules and the model only propose projects (#29): sure or not, the user decides.
        #expect(Link("project", "Foundry", "rules", 0.95, "series").unsure)
        #expect(Link.fromProject("Foundry", json(#"{"by": "model", "why": "suggested by the model"}"#)).unsure)
        let link = Link.fromProject("Foundry", json(#"{"by": "auto", "why": "people like “Sync”", "confidence": 0.72}"#))
        #expect(link.source == "rules" && link.confidence == 0.72 && link.reason == "people like “Sync”")
        #expect(!Link.fromProject("Foundry", json(#"{"by": "you", "why": ""}"#)).unsure)
    }

    // MARK: meeting and calendar event

    @Test func test_one_event_in_the_slot_is_a_sure_time_match() {
        let d = CalendarEvents.decide([F.event("Receipt case study", 0, 60, "Anna")], F.at(0), F.at(58))
        #expect(d.event?.title == "Receipt case study" && d.question == nil)
        #expect(d.link?.source == "calendar" && d.link?.confidence == 0.9 && d.link?.reason == "time match")
        #expect(d.link?.unsure == false)
    }

    @Test func test_a_clear_winner_among_overlapping_events_is_unsure_and_says_so() {
        let events = [F.event("Northwind", 0, 60, "Anna"), F.event("Standup", 45, 75, "Bob")]
        let d = CalendarEvents.decide(events, F.at(0), F.at(60))
        #expect(d.event?.title == "Northwind")
        #expect(d.link?.reason == "time match, 2 events overlapped" && d.link?.unsure == true)
        #expect(d.link?.toDict()["label"]?.stringValue == "Event: Northwind (time match, 2 events overlapped)")
    }

    @Test func test_two_events_at_the_same_time_are_a_question_not_a_guess() {
        let events = [F.event("Northwind", 0, 60, "Anna"), F.event("Contoso sync", 0, 60, "Bob", "Carl")]
        let d = CalendarEvents.decide(events, F.at(0), F.at(55))
        #expect(d.event == nil && d.link == nil)
        #expect(d.question?.map(\.title) == ["Contoso sync", "Northwind"])
    }

    @Test func test_a_blocker_without_invitees_does_not_make_it_a_question() {
        let events = [F.event("Focus time", -60, 120), F.event("Northwind", 0, 60, "Anna")]
        let d = CalendarEvents.decide(events, F.at(0), F.at(55))
        #expect(d.event?.title == "Northwind")
        #expect(d.link?.reason == "time match, 2 events overlapped; the other has no invitees" && d.link?.unsure == false)
    }

    /// A temporary folder's config dir: the stores attach writes (prepared.json, projects.json, …).
    private func stores(_ t: TempFolder) -> StorePaths {
        StorePaths.current(env: ["XDG_CONFIG_HOME": t.url.appendingPathComponent("config").path,
                                 "PALAVER_HOME": t.url.appendingPathComponent("home").path])
    }

    @Test func test_attach_stores_the_link_and_old_files_have_an_unknown_source() throws {
        let t = F.folder(); defer { t.remove() }
        let paths = RecordingPaths(t.url)
        try CalendarEvents.attach(paths, provider: { _, _ in [F.event("Receipt case study", 0, 60, "Anna")] },
                                  start: F.at(0), end: F.at(58), stores: stores(t))
        #expect(CalendarEvents.loadLink(paths)?.reason == "time match")
        #expect(CalendarEvents.load(paths)?.title == "Receipt case study")

        try CalendarEvents.save(paths, F.event("Old", 0, 60))  // stored before links had a source
        var stored = try #require(PythonJSON.read(paths.calendar))
        guard case .object(var fields) = stored else { Issue.record("not an object"); return }
        fields.removeAll { $0.0 == "link" }
        stored = .object(fields)
        t.write("calendar.json", PythonJSON.dumps(stored))
        let link = try #require(CalendarEvents.loadLink(paths))
        #expect(link.target == "Old" && link.source == "unknown")
    }

    @Test func test_attach_asks_when_events_overlap_and_the_answer_sticks() throws {
        let t = F.folder(); defer { t.remove() }
        let paths = RecordingPaths(t.url)
        let both: CalendarProvider = { _, _ in [F.event("Northwind", 0, 60, "Anna"), F.event("Contoso sync", 0, 60, "Bob")] }
        #expect(try CalendarEvents.attach(paths, provider: both, start: F.at(0), end: F.at(55), stores: stores(t)) == nil)
        #expect(CalendarEvents.load(paths) == nil && CalendarEvents.loadLink(paths) == nil)  // no title, no invitees from a guess
        #expect(CalendarEvents.loadQuestion(paths)?.map(\.title) == ["Contoso sync", "Northwind"])

        try CalendarEvents.assign(paths, try #require(CalendarEvents.loadQuestion(paths))[1],
                                  link: Link("event", "Northwind", "you", nil, "you chose it"), stores: stores(t))
        #expect(CalendarEvents.loadQuestion(paths) == nil)
        // Processing again never overrides what the user chose.
        let other: CalendarProvider = { _, _ in [F.event("Contoso sync", 0, 60, "Bob")] }
        #expect(try CalendarEvents.attach(paths, provider: other, start: F.at(0), end: F.at(55), stores: stores(t))?.title == "Northwind")
        #expect(CalendarEvents.loadLink(paths)?.byYou == true)
    }

    @Test func test_none_of_these_sticks() throws {
        let t = F.folder(); defer { t.remove() }
        let paths = RecordingPaths(t.url)
        try CalendarEvents.dismiss(paths)
        #expect(CalendarEvents.dismissed(paths))
        #expect(try CalendarEvents.attach(paths, provider: { _, _ in [F.event("Northwind", 0, 60, "Anna")] },
                                          start: F.at(0), end: F.at(55), stores: stores(t)) == nil)
        t.write("calendar.json", #"{"none": true}"#)  // as stored before links had a source
        #expect(CalendarEvents.dismissed(paths))
    }

    @Test func test_an_event_rejected_once_is_unsure_and_twice_never_matched_by_time() throws {
        let t = F.folder(); defer { t.remove() }
        let file = t.url.appendingPathComponent("attributions.json")
        var evidence = Evidence(path: file)
        let focus = F.event("Focus time", 0, 60, "Anna", uid: "focus/RID=1", series: true)
        evidence.rejectEvent(focus, "m1")
        var d = CalendarEvents.decide([focus], F.at(0), F.at(55), evidence: evidence)
        #expect(d.event == focus && d.link?.unsure == true)
        #expect(d.link?.reason == "time match; you said a recording was not this event once")

        evidence.rejectEvent(focus, "m2")
        try evidence.save()
        evidence = Evidence(path: file)
        #expect(CalendarEvents.decide([focus], F.at(0), F.at(55), evidence: evidence).event == nil)
        #expect(evidence.rules() == [EvidenceRule(series: "focus", title: "Focus time", rejected: 2, accepted: 0,
                                                  rule: "Not linked by time any more: Focus time — rejected 2×")])
        // With another candidate, the rejected one is no rival.
        let sync = F.event("Sync", 0, 60, "Bob")
        #expect(CalendarEvents.decide([focus, sync], F.at(0), F.at(55), evidence: evidence).event == sync)

        evidence.confirmEvent(focus, "m3")  // chosen by hand once: still said no more often
        #expect(evidence.neverByTime(focus))
        evidence.confirmEvent(focus, "m4")  // as often kept as rejected: no rule, and no doubt either
        d = CalendarEvents.decide([focus], F.at(0), F.at(55), evidence: evidence)
        #expect(d.event == focus && d.link?.reason == "time match")
        #expect(evidence.rules().isEmpty)
    }

    @Test func test_re_attaching_never_turns_a_stored_event_into_a_question() throws {
        let root = F.folder(); defer { root.remove() }
        let old = try recordingAt(root, Self.T0)
        let legacy = F.event("Sync", 0, 60, "Anna", "Bob", uid: "x")
        guard case .object(let fields) = legacy.json else { Issue.record("not an object"); return }
        let stored = JSONValue.object(fields.map { $0.0 == "uid" ? ($0.0, .string("")) : $0 })  // stored before events had an id
        try PythonJSON.write(stored, to: old.calendar, indent: nil, ensureAscii: true)
        let both: CalendarProvider = { _, _ in [F.event("Sync", 0, 60, uid: "sync-uid"), F.event("Contoso", 0, 60, "Carl")] }
        try CalendarEvents.attachAll(outputDir: root.url, provider: both, stores: stores(root))
        #expect(CalendarEvents.loadQuestion(old) == nil)
        var kept = try #require(CalendarEvents.load(old))
        #expect(kept.title == "Sync" && kept.attendees.map(\.name) == ["Anna", "Bob"])  // invitees kept

        // The same occurrence found again with its id: it gets the id, keeps its invitees.
        try CalendarEvents.attachAll(outputDir: root.url, provider: { _, _ in [F.event("Sync", 0, 60, uid: "sync-uid")] },
                                     stores: stores(root))
        kept = try #require(CalendarEvents.load(old))
        #expect(kept.uid == "sync-uid" && kept.attendees.map(\.name) == ["Anna", "Bob"])

        let fresh = try recordingAt(root, F.at(24 * 60))  // no calendar decision yet: may be asked
        let day: CalendarProvider = { _, _ in [F.event("A", 24 * 60, 24 * 60 + 60, "Anna"), F.event("B", 24 * 60, 24 * 60 + 60, "Bob")] }
        try CalendarEvents.attachAll(outputDir: root.url, provider: day, stores: stores(root))
        #expect(CalendarEvents.loadQuestion(fresh)?.map(\.title) == ["A", "B"])
    }

    // MARK: what needs the user

    @Test func test_questions_is_a_pure_function_of_the_meeting() throws {
        let m = JSONValue.object([
            ("id", .string("m1")), ("title", .string("Sync")), ("start", .string("2026-10-27T10:00:00+01:00")),
            ("event_question", .null),
            ("calendar", .object([("link", Link("event", "Sync", "calendar", 0.6, "time match, 2 events overlapped").toDict())])),
            ("speakers", .array([.object([("label", .null), ("is_user", .bool(true))]),
                                 .object([("label", .string("SPEAKER_00")), ("link", Link("speaker", "Tom", "you", nil, "").toDict())])])),
            ("projects", .array([.object([("id", .string("p1")), ("name", .string("Foundry")),
                                          ("link", Link("project", "Foundry", "rules", 0.7, "title").toDict())])])),
        ])
        let found = try Attribution.questions(m)
        #expect(found.map { "\($0["kind"]!.stringValue!):\($0["link"]!["target"]!.stringValue!)" } == ["event:Sync", "project:Foundry"])
        #expect(found[0]["question"]?.stringValue == "Was this recording “Sync”?")
        #expect(found[1]["question"]?.stringValue == "Is this meeting part of Foundry?")
    }

    @Test func test_an_event_with_only_the_user_on_it_is_a_blocker() {
        let me = Attendee(name: "Timo", email: "timo@kloud.io", isSelf: true)
        let blocker = CalendarEvent(title: "Focus", start: F.at(0), end: F.at(60), attendees: [me], uid: "focus")
        let call = F.event("Northwind", 0, 60, "Anna")
        let d = CalendarEvents.decide([blocker, call], F.at(0), F.at(55))
        #expect(d.event == call && d.link?.unsure == false)
    }

    // MARK: events: acceptances, rules

    private func jourFixe(_ week: Int) -> CalendarEvent {
        let start = F.at(7 * 24 * 60 * week)
        return CalendarEvent(title: "Jour fixe", start: start, end: start.adding(micros: 3_600_000_000),
                             attendees: [Attendee(name: "Anna", email: "anna@x.com")], uid: "jf/RID=\(week)", series: true)
    }

    /// test_attribution.py's `_recording_at`: a folder named after `start`, 55 minutes long.
    private func recordingAt(_ root: TempFolder, _ start: PyDateTime, minutes: Int = 55) throws -> RecordingPaths {
        let name = String(start.iso.prefix(19)).replacingOccurrences(of: ":", with: "-")
        let paths = RecordingPaths(root.url.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        try PythonJSON.write(.object([("start_time", .string(start.iso)), ("duration_seconds", .int(minutes * 60))]),
                             to: paths.meta, indent: nil, ensureAscii: true)
        return paths
    }

    @Test func test_the_weekly_jour_fixe_kept_by_the_user_is_no_rule() throws {
        let root = F.folder(); defer { root.remove() }
        let file = root.url.appendingPathComponent("attributions.json")
        // Four weeks the Jour fixe was linked by time and kept.
        for week in 0..<4 {
            let rec = try recordingAt(root, jourFixe(week).start)
            let (start, end) = try CalendarEvents.recordingSpan(rec)
            try CalendarEvents.attach(rec, provider: { _, _ in [self.jourFixe(week)] }, start: start, end: end, stores: stores(root))
        }
        // Twice an ad-hoc call took its slot: "not the Jour fixe".
        var ev = Evidence(path: file, outputDir: root.url)
        ev.rejectEvent(jourFixe(4), "adhoc-1")
        ev.rejectEvent(jourFixe(5), "adhoc-2")
        try ev.save()
        ev = Evidence(path: file, outputDir: root.url)
        #expect(ev.acceptances(jourFixe(6)) == 4)
        #expect(!ev.neverByTime(jourFixe(6)) && ev.rules().isEmpty)
        let d = CalendarEvents.decide([jourFixe(6)], jourFixe(6).start, jourFixe(6).end, evidence: ev)
        #expect(d.event != nil && d.link?.reason == "time match" && d.link?.unsure == false)

        // Rejected more often than kept: then it is a rule.
        for n in 0..<3 { ev.rejectEvent(jourFixe(7 + n), "adhoc-\(3 + n)") }
        #expect(ev.neverByTime(jourFixe(10)))
        let rule = try #require(ev.rules().first)
        #expect(ev.rules().count == 1)
        #expect(rule.rule == "Not linked by time any more: Jour fixe — rejected 5×")
        ev.forgetRule(rule.series)
        #expect(!ev.neverByTime(jourFixe(10)) && ev.rules().isEmpty)
    }

    // MARK: on disk (Swift's own: the bytes are Python's)

    @Test func theEvidenceFileIsPythonsBytesUnderItsLock() throws {
        let t = F.folder(); defer { t.remove() }
        let file = t.url.appendingPathComponent("attributions.json")
        let evidence = Evidence(path: file, outputDir: t.url)
        let focus = F.event("Focus time", 0, 60, "Anna", uid: "focus/RID=1", series: true)
        let nameless = CalendarEvent(title: "", start: F.at(0), end: F.at(5))
        for m in ["m1", "m2"] { evidence.rejectEvent(focus, m) }
        evidence.confirmEvent(focus, "m3")
        evidence.confirmEvent(focus, "m2")
        for m in ["ä1", "ä2", "ä3"] { evidence.rejectEvent(nameless, m) }
        evidence.forgetRule("nothing")
        try evidence.save()
        #expect(t.text("attributions.json") == Goldens.load("calendar")["evidence_file"]?.stringValue)
        #expect(t.exists("attributions.json.lock"))
        #expect(!t.exists("attributions.json.tmp"))
        evidence.forgetRule("")
        try evidence.save()
        #expect(t.text("attributions.json") == Goldens.load("calendar")["evidence_after_forget"]?.stringValue)
        Goldens.expect(.array(evidence.rules().map(\.json)), "calendar", "evidence_rules")
    }

    @Test func aStoreKeepsTheFilesOtherKeysAndUnknownEntryFields() throws {
        let t = F.folder(); defer { t.remove() }
        let file = t.url.appendingPathComponent("attributions.json")
        try #"{"zz": 1, "events": {"b": {"title": "B", "extra": [1], "rejected": ["x"]}}, "aa": null}"#
            .write(to: file, atomically: false, encoding: .utf8)
        let evidence = Evidence(path: file)
        evidence.confirmEvent(CalendarEvent(title: "B", start: F.at(0), end: F.at(1), uid: "b"), "m")
        try evidence.save()
        #expect(t.text("attributions.json") == """
            {
              "zz": 1,
              "events": {
                "b": {
                  "title": "B",
                  "extra": [
                    1
                  ],
                  "rejected": [
                    "x"
                  ],
                  "chosen": [
                    "m"
                  ]
                }
              },
              "aa": null
            }
            """)
    }

    @Test func aMissingOrBrokenEvidenceFileIsEmpty() throws {
        let t = F.folder(); defer { t.remove() }
        let file = t.url.appendingPathComponent("attributions.json")
        #expect(Evidence(path: file).rules().isEmpty)
        try "[1, 2]".write(to: file, atomically: false, encoding: .utf8)
        let evidence = Evidence(path: file)
        try evidence.save()
        #expect(t.text("attributions.json") == "{\n  \"events\": {}\n}")
    }

    @Test func linksAreStoredAndShownAsInPython() {
        let link = Link("event", "Migration", "calendar", 0.54, "time match; you said a recording was not this event once")
        Goldens.expect(link.stored(), "calendar", "link_stored")
        Goldens.expect(link.toDict(), "calendar", "link_dict")
        #expect(Link("event", "x", "you").stored() == .object([("source", .string("you"))]))
        #expect(Link.from(kind: "org", target: "Contoso", .object([("source", .string("email")), ("confidence", .int(1))])).confidence == 1.0)
        #expect(Link.from(kind: "org", target: "Contoso", .object([("confidence", .bool(true))])).confidence == nil)
        #expect(Link("weird kind", "t").label == "Weird Kind: t")
    }

    // Python 3.13 knows Unicode 15.1: a letter assigned later (U+1C89, U+A7CB) is not cased there, whatever macOS says.
    @Test func newerScalarsAreUnassignedInTitleAndIsUpper() {
        #expect(Py.strTitle("a\u{1C89}b") == "A\u{1C89}B")
        #expect(Py.strTitle("a\u{A7CB}b") == "A\u{A7CB}B")
        #expect(!Py.strIsUpper("\u{1C89}") && !Py.strIsUpper("\u{A7CB}"))
        #expect(Py.strIsUpper("AB\u{1C89}") && Py.strIsUpper("ÄÖ"))
        #expect(Py.strTitle("ΟΔΥΣΣΕΥΣ ΑΝΔΡΕΑΣ") == "Οδυσσευς Ανδρεας")
        // The per-scalar table helper of Task 2 is still the one `Py.isUpper(_: Unicode.Scalar)` names.
        #expect(Py.isUpper("ẞ") && !Py.isUpper("\u{1C89}"))
    }
}
