// The Glossary page, its changes and the review queue (api.py `glossary_page`, `accept_suggestion`, `respell`,
// `unrespell`, `reject_suggestion`, `update_term`, `seed_glossary`, `review_queue`, `mark_reviewed`; server.py
// `_glossary_post`): the glossary and review tests of test_webapp.py and test_setup_api.py's seed test under their names.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"

private func write(_ value: JSONValue, to url: URL) throws { try Data(PythonJSON.dumps(value).utf8).write(to: url) }
private func read(_ url: URL) -> JSONValue { PythonJSON.read(url) ?? .null }
private func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

private extension JSONValue {
    subscript(i: Int) -> JSONValue? { arrayValue.flatMap { $0.indices.contains(i) ? $0[i] : nil } }
    var list: [JSONValue] { arrayValue ?? [] }
    func with(_ key: String, _ value: JSONValue) -> JSONValue {
        var d = PyDict<JSONValue>(self) ?? PyDict()
        d[key] = value
        return d.json
    }
    func changing(_ i: Int, _ f: (JSONValue) -> JSONValue) -> JSONValue {
        var items = list
        items[i] = f(items[i])
        return .array(items)
    }
}

/// The window's meeting and the app over it for "Timo" (no HTTP).
private final class Fixture {
    let dir: URL
    let out: URL
    let stores: StorePaths
    let app: ServerApp
    let paths: RecordingPaths

    init(meeting: Bool = true) throws {
        dir = tempFolder("glossary")
        out = dir.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        stores = StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                            home: dir.appendingPathComponent("home", isDirectory: true))
        app = ServerApp(outputDir: out, userName: "Timo", stores: stores)
        paths = RecordingPaths(out.appendingPathComponent(MEETING, isDirectory: true))
        if meeting { try pageMeeting(out) }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func page() throws -> JSONValue { try MeetingsAPI.getMeeting(app: app, id: MEETING) }
    /// The second line as the meeting shows it.
    func said() throws -> String { try page()["transcript"]?[1]?["text"]?.stringValue ?? "" }
    var glossary: Glossary { Glossary(path: stores.glossary) }
}

/// `_post`: the status and the JSON answer.
private func post(_ s: TestServer, _ path: String, _ body: JSONValue = .object([])) -> (Int, JSONValue) {
    let r = s.post(path, body)
    return (r.status, r.json ?? .null)
}

/// `_undo`: the answer's token undoes the change.
private func undo(_ s: TestServer, _ answer: JSONValue) {
    #expect(answer["undo"]?.stringValue?.isEmpty == false)
    #expect(post(s, "/api/undo", .object([("token", answer["undo"] ?? .null)])).0 == 200)
}

/// `_term`: the one term on the Glossary page.
private func term(_ s: TestServer) -> JSONValue { s.get("/api/glossary").json?["terms"]?[0] ?? .null }

private func server() throws -> TestServer { try TestServer(userName: "Timo", meetings: { try pageMeeting($0) }) }

private func object(_ pairs: [(String, JSONValue)]) -> JSONValue { .object(pairs) }

@Suite struct GlossaryRoutesTests {
    @Test func test_glossary_suggestions_accept_and_what_changed() throws {
        let f = try Fixture()
        let transcript = read(f.paths.transcriptJson)
            .changing(1) { $0.with("text", .string("Welcome, we run it on Databricks in Atterkring.")) }
            .changing(2) { $0.with("text", .string("Databricks is fine, Atterkring too.")) }
        try write(transcript, to: f.paths.transcriptJson)
        try Data("old".utf8).write(to: f.paths.transcriptMd)
        try write(object([("title", .string("Debrief")), ("start", .string("2026-10-27T16:03:07+01:00")),
                          ("end", .string("2026-10-27T16:30:00+01:00")),
                          ("attendees", .array([object([("name", .string("16 - Attakring | Conferenceroom"))])]))]), to: f.paths.calendar)

        let page = try GlossaryAPI.page(f.app, userName: "Timo")
        let variant = try #require(page["suggestions"]?.list.first { $0["kind"] == .string("variant") })
        #expect(variant["term"] == .string("Attakring") && variant["variants"] == .strings(["Atterkring"]))
        #expect(variant["examples"]?[0]?["title"] == .string("Debrief"))

        try write(read(f.paths.notes).with("summary", .string("Debrief held in Atterkring.")), to: f.paths.notes)
        let changed = try GlossaryAPI.accept(f.app, term: "Attakring", variants: ["Atterkring"])
        #expect(PythonJSON.dumps(changed) == #"{"meetings": ["2026-10-27T16-03-07"], "replacements": 2, "in_notes": 1}"#)
        #expect(try f.page()["notes"]?["summary"] == .string("Debrief held in Attakring."))
        #expect(try MeetingsAPI.listMeetings(app: f.app).first?["summary"] == .string("Debrief held in Attakring."))
        #expect(text(f.paths.transcriptMd).contains("Attakring"))  // rendered again
        #expect(try f.said() == "Welcome, we run it on Databricks in Attakring.")
        #expect(read(f.paths.transcriptJson)[1]?["text"]?.stringValue?.hasSuffix("Atterkring.") == true)  // kept as heard

        let terms = try GlossaryAPI.page(f.app, userName: "Timo")["terms"]?.list ?? []
        #expect(terms.count == 1)
        let tid = try #require(terms.first?["id"]?.stringValue)
        #expect(try GlossaryAPI.updateTerm(f.app, tid: tid, delete: true)["replacements"] == .int(2))
        #expect(try f.said().hasSuffix("Atterkring."))
    }

    @Test func test_respelling_words_as_a_meeting_shows_them() throws {
        let f = try Fixture()
        try write(read(f.paths.transcriptJson).changing(1) { $0.with("text", .string("Es geht darum, Tini abzulösen, den Genie-Teil im SDK.")) },
                  to: f.paths.transcriptJson)

        var d = try GlossaryAPI.respell(f.app, heard: "Tini", term: "Genie")
        #expect(d["changed"]?["replacements"] == .int(1) && d["term"]?["variants"] == .strings(["Tini"]))
        #expect(try f.said() == "Es geht darum, Genie abzulösen, den Genie-Teil im SDK.")

        // The meeting shows the term now: respelling it renames the term.
        d = try GlossaryAPI.respell(f.app, heard: "Genie", term: "Zini")
        #expect(d["changed"]?["replacements"] == .int(2))  // every word shown differently, not just the new variant
        #expect(d["term"]?["term"] == .string("Zini") && d["term"]?["variants"] == .strings(["Tini", "Genie"]))
        #expect(try f.said() == "Es geht darum, Zini abzulösen, den Zini-Teil im SDK.")

        // Another term by that spelling takes this one in.
        let gid = try #require(d["term"]?["id"]?.stringValue)
        _ = try GlossaryAPI.accept(f.app, term: "Zini GmbH", variants: [])
        d = try GlossaryAPI.respell(f.app, heard: "Zini", term: "zini gmbh")
        #expect(d["term"]?["term"] == .string("Zini GmbH") && d["term"]?["variants"] == .strings(["Zini", "Tini", "Genie"]))
        #expect(f.glossary.terms[gid] == nil)
        #expect(try f.said() == "Es geht darum, Zini GmbH abzulösen, den Zini GmbH-Teil im SDK.")

        #expect(throws: BadRequest.self) { try GlossaryAPI.respell(f.app, heard: "Zini", term: " ") }
    }

    /// "dem" became a variant of "Demo" by mistake: from the meeting, only that mapping goes; the term and its other
    /// spellings stay.
    @Test func test_a_wrong_respelling_is_removed_where_it_shows() throws {
        let f = try Fixture()
        try write(read(f.paths.transcriptJson).changing(1) { $0.with("text", .string("Wir zeigen dem Kunden die Demmo morgen.")) },
                  to: f.paths.transcriptJson)
        _ = try GlossaryAPI.accept(f.app, term: "Demo", variants: ["dem", "Demmo"])
        #expect(try f.said() == "Wir zeigen Demo Kunden die Demo morgen.")

        let d = try GlossaryAPI.unrespell(f.app, heard: "Dem")  // as heard, any case
        #expect(d["changed"]?["replacements"] == .int(1) && d["term"]?["term"] == .string("Demo"))
        #expect(d["term"]?["variants"] == .strings(["Demmo"]))
        #expect(try f.said() == "Wir zeigen dem Kunden die Demo morgen.")
        _ = try UndoRoute.undoChange(f.app, token: d["undo"]?.stringValue ?? "")
        #expect(try f.said() == "Wir zeigen Demo Kunden die Demo morgen.")

        let refused = #expect(throws: Refused.self) { try GlossaryAPI.unrespell(f.app, heard: "Kunden") }
        #expect(refused?.text.contains("not respelled by the glossary") == true)
    }

    @Test func test_review_queue_lists_what_is_open_until_done() throws {
        let f = try Fixture()
        var queue = try ReviewAPI.queue(f.app, userName: "Timo")
        #expect(queue.count == 1)
        let open = queue.first?["open"]
        #expect(open?["unnamed"] == .int(1) && open?["projects"] == .string("none") && open?["notes"] == .string("ok"))
        try ReviewAPI.markReviewed(f.app, id: MEETING, done: true)
        #expect(try ReviewAPI.queue(f.app, userName: "Timo") == [])
        try ReviewAPI.markReviewed(f.app, id: MEETING, done: false)
        queue = try ReviewAPI.queue(f.app, userName: "Timo")
        #expect(queue.count == 1)
    }

    @Test func test_http_glossary_and_review() throws {
        let s = try server()
        defer { s.stop() }
        var (status, d) = post(s, "/api/glossary/accept", object([("term", .string("Rico")), ("variants", .strings(["Riko"]))]))
        #expect(status == 200 && d["terms"]?[0]?["term"] == .string("Rico") && d["changed"]?["replacements"] == .int(0))
        let tid = d["terms"]?[0]?["id"] ?? .null
        (status, d) = post(s, "/api/glossary/respell", object([("heard", .string("Rico")), ("term", .string("Riko"))]))
        #expect(status == 200 && PythonJSON.dumps(d["term"] ?? .null)
                == PythonJSON.dumps(object([("id", tid), ("term", .string("Riko")), ("variants", .strings(["Rico"])), ("note", .string(""))])))
        #expect(post(s, "/api/glossary/reject", object([("key", .string("term:x"))])).0 == 200)
        (status, d) = post(s, "/api/meetings/\(MEETING)/reviewed", object([("done", .bool(true))]))
        #expect(status == 200 && d == .array([]))
        #expect(post(s, "/api/glossary/ffff", object([("term", .string("X"))])).0 == 404)
    }

    @Test func test_http_glossary_delete_can_be_undone() throws {
        let s = try server()
        defer { s.stop() }
        _ = post(s, "/api/glossary/accept", object([("term", .string("Genie")), ("variants", .strings(["Tini"]))]))
        let tid = try #require(Glossary(path: s.app.stores.glossary).terms.keys.first)
        let (status, answer) = post(s, "/api/glossary/\(tid)", object([("delete", .bool(true))]))
        #expect(status == 200 && answer["undo"]?.stringValue?.isEmpty == false && Glossary(path: s.app.stores.glossary).terms.isEmpty)
        #expect(post(s, "/api/undo", object([("token", answer["undo"] ?? .null)])).0 == 200)
        #expect(Glossary(path: s.app.stores.glossary).terms.keys == [tid])
    }

    @Test func test_http_glossary_undo_renders_the_markdown_again() throws {
        let s = try server()
        defer { s.stop() }
        let md = s.app.outputDir.appendingPathComponent(MEETING).appendingPathComponent("transcript.md")
        try Data("rendered".utf8).write(to: md)  // the glossary only re-renders a Markdown that exists
        _ = post(s, "/api/glossary/accept", object([("term", .string("Rico Lanza")), ("variants", .strings(["Rico"]))]))
        let tid = try #require(Glossary(path: s.app.stores.glossary).terms.keys.first)
        let (_, answer) = post(s, "/api/glossary/\(tid)", object([("delete", .bool(true))]))
        #expect(!text(md).contains("Rico Lanza"))
        _ = post(s, "/api/undo", object([("token", answer["undo"] ?? .null)]))
        #expect(text(md).contains("Rico Lanza"))
    }

    @Test func test_http_term_rename_can_be_undone() throws {
        let s = try server()
        defer { s.stop() }
        _ = post(s, "/api/glossary/accept", object([("term", .string("Genie")), ("variants", .strings(["Tini"]))]))
        let tid = term(s)["id"]?.stringValue ?? ""
        let (status, answer) = post(s, "/api/glossary/\(tid)", object([("term", .string("Jeanie"))]))
        #expect(status == 200 && answer["terms"]?[0]?["term"] == .string("Jeanie"))
        undo(s, answer)
        #expect(term(s)["term"] == .string("Genie"))
    }

    @Test func test_http_term_note_can_be_undone() throws {
        let s = try server()
        defer { s.stop() }
        _ = post(s, "/api/glossary/accept", object([("term", .string("Genie")), ("variants", .strings(["Tini"])), ("note", .string("the bot"))]))
        let tid = term(s)["id"]?.stringValue ?? ""
        let (status, answer) = post(s, "/api/glossary/\(tid)", object([("note", .string("the lamp"))]))
        #expect(status == 200 && answer["terms"]?[0]?["note"] == .string("the lamp"))
        undo(s, answer)
        #expect(term(s)["note"] == .string("the bot"))
    }

    @Test func test_http_not_this_can_be_undone() throws {
        let s = try server()
        defer { s.stop() }
        let (status, answer) = post(s, "/api/glossary/reject", object([("key", .string("term:rico"))]))
        #expect(status == 200 && Glossary(path: s.app.stores.glossary).isRejected("term:rico"))
        undo(s, answer)
        #expect(!Glossary(path: s.app.stores.glossary).isRejected("term:rico"))
    }

    /// A card's "Not this" goes for each of its spellings, or the rest come back.
    @Test func test_http_not_this_takes_several_spellings_at_once() throws {
        let s = try server()
        defer { s.stop() }
        let keys = ["variant:kein:timo", "variant:kino:timo"]
        let (status, answer) = post(s, "/api/glossary/reject", object([("keys", .strings(keys))]))
        #expect(status == 200 && keys.allSatisfy(Glossary(path: s.app.stores.glossary).isRejected))
        undo(s, answer)
        #expect(!keys.contains(where: Glossary(path: s.app.stores.glossary).isRejected))
    }

    /// test_setup_api.py's (the names: fictional).
    @Test func test_glossary_seed_adds_the_terms_chosen_and_can_be_undone() throws {
        let f = try Fixture(meeting: false)
        let out = try GlossaryAPI.seed(f.app, object([("terms", .strings(["Timo Strauß", "Northwind", " "]))]))
        #expect(out["added"] == .int(2) && out["undo"]?.stringValue?.isEmpty == false)
        #expect(Py.stableSorted(f.glossary.terms.values.compactMap { $0["term"]?.stringValue }, by: Py.less) == ["Northwind", "Timo Strauß"])
        _ = try UndoRoute.undoChange(f.app, token: out["undo"]?.stringValue ?? "")
        #expect(f.glossary.terms.isEmpty)
        #expect(try GlossaryAPI.seed(f.app, object([("terms", .strings([" "]))])) == object([("added", .int(0)), ("undo", .null)]))
    }

}
