// Ask your meetings (#42): the passages found for a question across the meetings (lines with their neighbours, notes,
// filters the question or the page names), the model asked with those only, its citations turned into sources with
// meeting and time; a meeting kept on this Mac never goes to a cloud model (left out and said, or the local model on
// "Ask on this Mac"); the local model during a call needs its memory and a second click. The model is a fake
// `MeetingsAsker` in this process, or `/bin/sh` standing in for palaver-lm — never a model.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let NORTHWIND = "2026-10-21T10-00-00"
private let BUDGET = "2026-11-02T09-00-00"

private func dumps(_ v: JSONValue?) -> String { v.map { PythonJSON.dumps($0, ensureAscii: false) } ?? "nil" }

private func write(_ value: JSONValue, to url: URL) throws { try Data(PythonJSON.dumps(value).utf8).write(to: url) }

/// A finished meeting: its start, its lines ((label, start, text); the user's own under the user's name) and its notes.
@discardableResult
private func meeting(_ out: URL, _ id: String, start: String, lines: [(String, Double, String)], notes: JSONValue) throws
    -> RecordingPaths {
    let paths = RecordingPaths(out.appendingPathComponent(id, isDirectory: true))
    try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
    try write(.object([("start_time", .string(start)), ("duration_seconds", .int(1800))]), to: paths.meta)
    try write(.array(lines.map { Utterance(speaker: $0.0, start: $0.1, end: $0.1 + 5, text: $0.2).json }), to: paths.transcriptJson)
    try write(.array(lines.filter { $0.0.hasPrefix("SPEAKER_") }.map {
        .object([("speaker", .string($0.0)), ("start", .double($0.1)), ("end", .double($0.1 + 5))])
    }), to: paths.systemTurns)
    try NotesFile.save(paths, notes)
    return paths
}

private func notes(_ title: String, summary: String, decisions: [String] = [], steps: [(String, String)] = []) -> JSONValue {
    .object([("title", .string(title)), ("summary", .string(summary)), ("sections", .array([])),
             ("next_steps", .array(steps.map { .object([("owner", .string($0.0)), ("task", .string($0.1))]) })),
             ("decisions", .strings(decisions)), ("speaker_names", .array([]))])
}

/// Two meetings: the term agreed with Northwind (Lena and Jonas), and a budget review (Mara) that mentions a term too.
private func twoMeetings(_ out: URL) throws {
    try meeting(out, NORTHWIND, start: "2026-10-21T10:00:00+02:00", lines: [
        ("Timo", 0, "Hallo zusammen, kurz zum Vertrag mit Northwind."),
        ("SPEAKER_00", 600, "Bei der Laufzeit bleiben wir bei 24 Monaten."),
        ("SPEAKER_01", 606, "Gut, dann schicke ich den Vertrag bis Freitag."),
        ("SPEAKER_00", 1200, "Sonst noch etwas? Dann bis nächste Woche."),
    ], notes: notes("Weekly with Northwind", summary: "Northwind: the contract stays as it is.",
                    decisions: ["Laufzeit 24 Monate"], steps: [("SPEAKER_01", "Vertrag schicken")]))
    try meeting(out, BUDGET, start: "2026-11-02T09:00:00+01:00", lines: [
        ("Timo", 10, "Das Budget für das erste Quartal steht."),
        ("SPEAKER_00", 20, "Die Laufzeit des Projekts ist noch offen."),
    ], notes: notes("Budget review", summary: "The budget for the first quarter is set."))
}

/// palaver-lm's answer to whatever is asked, or its error; each ask kept with the meeting it was watched for.
private final class FakeAsker: MeetingsAsker, @unchecked Sendable {
    var answer: Result<JSONValue, Error>
    private let lock = NSLock()
    private var asked: [(JSONValue, URL)] = []
    init(_ answer: Result<JSONValue, Error> = .success(.object([
        ("answer", .string("Die Laufzeit bleibt bei 24 Monaten [1][2].")), ("sources", .array([.int(1), .int(2)])),
        ("engine", .string("Fake model")),
    ]))) { self.answer = answer }
    func ask(inputs: JSONValue, watching: URL) throws -> JSONValue {
        lock.withLock { asked.append((inputs, watching)) }
        return try answer.get()
    }
    var calls: [(inputs: JSONValue, watching: URL)] { lock.withLock { asked.map { ($0.0, $0.1) } } }
}

private func server(_ model: FakeAsker = FakeAsker(), free: Double = 64.0, notes: Bool? = nil) throws -> TestServer {
    let s = try TestServer(userName: "Timo", recording: FakeRecording(), notesEnabled: notes, askMeetings: model,
                           freeMemoryGB: { free }, meetings: { try twoMeetings($0) })
    func name(_ id: String, _ names: [(String, String)]) throws {
        _ = try Speakers.saveSpeakerNames(RecordingPaths(s.app.outputDir.appendingPathComponent(id, isDirectory: true)),
                                          PyDict(names), learn: false, stores: s.app.stores)
    }
    try name(NORTHWIND, [("SPEAKER_00", "Lena Berg"), ("SPEAKER_01", "Jonas Wirth")])
    try name(BUDGET, [("SPEAKER_00", "Mara Klein")])
    return s
}

private func ask(_ s: TestServer, _ question: String, _ extra: [(String, JSONValue)] = []) -> (Int, JSONValue) {
    let r = s.post("/api/ask", .object([("question", .string(question))] + extra))
    return (r.status, r.json ?? .null)
}

private func choose(_ s: TestServer, _ engines: [(String, JSONValue)]) throws {
    try SettingsFile.update([("engines", .object(engines))], stores: s.app.stores)
}

private func passages(_ inputs: JSONValue?) -> [JSONValue] { inputs?["passages"]?.arrayValue ?? [] }

private func meetingsOf(_ inputs: JSONValue?) -> [String] { passages(inputs).compactMap { $0["meeting"]?.stringValue } }

@Suite(.serialized) struct AskMeetingsRoutesTests {
    @Test func theModelGetsOnlyThePassagesFoundAndItsCitationsComeBackAsSources() throws {
        let model = FakeAsker()
        let s = try server(model)
        defer { s.stop() }
        let info = s.get("/api/ask").json
        #expect(dumps(info) == #"{"ready": true, "reason": null, "model": "Gemma, on this Mac", "local": true, "local_model": "Gemma"}"#)
        let (status, answer) = ask(s, "Was haben wir zur Laufzeit vereinbart?")
        #expect(status == 200)
        let call = try #require(model.calls.first)
        #expect(call.inputs["question"] == .string("Was haben wir zur Laufzeit vereinbart?") && call.inputs["user"] == .string("Timo"))
        // The meetings in time order, each with its notes first; the line found with the lines around it.
        #expect(dumps(.array(passages(call.inputs))) == dumps(.array([
            .object([("n", .int(1)), ("meeting", .string(NORTHWIND)), ("title", .string("Weekly with Northwind")),
                     ("date", .string("2026-10-21")), ("time", .null), ("speaker", .string("")), ("kind", .string("decision")),
                     ("text", .string("Laufzeit 24 Monate"))]),
            .object([("n", .int(2)), ("meeting", .string(NORTHWIND)), ("title", .string("Weekly with Northwind")),
                     ("date", .string("2026-10-21")), ("time", .double(600.0)), ("speaker", .string("Lena Berg")),
                     ("kind", .string("line")),
                     ("text", .string("Timo: Hallo zusammen, kurz zum Vertrag mit Northwind. / Lena Berg: Bei der Laufzeit bleiben "
                                      + "wir bei 24 Monaten. / Jonas Wirth: Gut, dann schicke ich den Vertrag bis Freitag."))]),
            .object([("n", .int(3)), ("meeting", .string(BUDGET)), ("title", .string("Budget review")),
                     ("date", .string("2026-11-02")), ("time", .double(20.0)), ("speaker", .string("Mara Klein")),
                     ("kind", .string("line")),
                     ("text", .string("Timo: Das Budget für das erste Quartal steht. / Mara Klein: Die Laufzeit des Projekts ist noch offen."))]),
        ])))
        #expect(call.watching.lastPathComponent == NORTHWIND)
        #expect(answer["answer"] == .string("Die Laufzeit bleibt bei 24 Monaten [1][2].") && answer["engine"] == .string("Fake model"))
        #expect(dumps(answer["sources"]) == dumps(.array([
            .object([("meeting", .string(NORTHWIND)), ("title", .string("Weekly with Northwind")),
                     ("start", .string("2026-10-21T10:00:00+02:00")), ("kind", .string("decision")), ("time", .null),
                     ("speaker", .string("")), ("text", .string("Laufzeit 24 Monate")), ("n", .int(1))]),
            .object([("meeting", .string(NORTHWIND)), ("title", .string("Weekly with Northwind")),
                     ("start", .string("2026-10-21T10:00:00+02:00")), ("kind", .string("line")), ("time", .double(600.0)),
                     ("speaker", .string("Lena Berg")), ("text", .string("Bei der Laufzeit bleiben wir bei 24 Monaten.")),
                     ("n", .int(2))]),
        ])))
        #expect(answer["passages"] == .int(3) && answer["meetings"] == .int(2) && answer["left_out"] == .int(0))
        #expect(answer["question"] == .string("Was haben wir zur Laufzeit vereinbart?"))
    }

    @Test func peopleProjectsAndDatesNarrowTheMeetings() throws {
        let model = FakeAsker()
        let s = try server(model)
        defer { s.stop() }
        // Named in the question: only Lena's lines, in the meetings she took part in.
        var (status, answer) = ask(s, "Was hat Lena zur Laufzeit gesagt?")
        #expect(status == 200 && meetingsOf(model.calls.last?.inputs) == [NORTHWIND, NORTHWIND])
        #expect(passages(model.calls.last?.inputs).last?["speaker"] == .string("Lena Berg"))
        #expect(answer["understood"]?.arrayValue?.compactMap { $0["label"]?.stringValue } == ["Lena Berg", "Said by Lena Berg"])
        // The page's filters: a person, a time.
        (status, _) = ask(s, "Laufzeit", [("person", .string("Mara Klein"))])
        #expect(status == 200 && meetingsOf(model.calls.last?.inputs) == [BUDGET])
        (status, _) = ask(s, "Laufzeit", [("since", .string("2026-11-01"))])
        #expect(status == 200 && meetingsOf(model.calls.last?.inputs) == [BUDGET])
        // Nothing to look for but a person: the newest summaries of the meetings with her.
        (status, answer) = ask(s, "Was gab es mit Mara?")
        #expect(status == 200 && dumps(.array(passages(model.calls.last?.inputs).map { $0["kind"] ?? .null })) == #"["summary"]"#)
        #expect(passages(model.calls.last?.inputs).first?["text"] == .string("The budget for the first quarter is set."))
    }

    @Test func linesFoundCloseTogetherAreOnePassageAndRarerWordsWeighMore() throws {
        let s = try server()
        defer { s.stop() }
        let (_, found) = try AskMeetingsAPI.find(s.app, question: "Laufzeit Vertrag Freitag", filters: [])
        let lines = found.filter { $0.meeting == NORTHWIND && $0.kind == "line" }
        #expect(lines.count == 1)  // 0:00, 10:00 and 10:06 in one passage
        #expect(lines.first?.text.contains("Laufzeit") == true && lines.first?.text.contains("bis Freitag") == true)
        #expect(found.first?.meeting == NORTHWIND)  // three of the words, against one in the budget review
        #expect(found.last?.meeting == BUDGET)
    }

    @Test func whenNothingMatchesNoModelRuns() throws {
        let model = FakeAsker()
        let s = try server(model)
        defer { s.stop() }
        let (status, answer) = ask(s, "Wann wurde der Excel-Export erwähnt?")
        #expect(status == 200 && answer["answer"] == .null && answer["sources"] == .array([]) && answer["passages"] == .int(0))
        #expect(model.calls.isEmpty)
        let empty = ask(s, "   ")
        #expect(empty.0 == 400 && empty.1["error"] == .string("Type a question first."))
    }

    /// With a cloud model a meeting kept on this Mac is left out and counted; "Ask on this Mac" runs the local model
    /// with it.
    @Test func aMeetingKeptOnThisMacNeverGoesToACloudModel() throws {
        let model = FakeAsker()
        let s = try server(model)
        defer { s.stop() }
        try choose(s, [("notes", .string("anthropic"))])
        let info = s.get("/api/ask").json
        #expect(info?["model"] == .string("Claude Opus 5.5, cloud") && info?["local"] == .bool(false))
        try LocalOnly.set(s.app.outputDir.appendingPathComponent(NORTHWIND, isDirectory: true), on: true)
        var (status, answer) = ask(s, "Was haben wir zur Laufzeit vereinbart?")
        #expect(status == 200 && meetingsOf(model.calls.last?.inputs) == [BUDGET])
        #expect(answer["left_out"] == .int(1) && answer["meetings"] == .int(1))
        // Only the meeting kept here matches: no model, and it says so.
        (status, answer) = ask(s, "Vertrag Freitag")
        #expect(status == 200 && answer["passages"] == .int(0) && answer["left_out"] == .int(1) && model.calls.count == 1)
        // On this Mac: both, on the local model (watched with that meeting's budget).
        (status, answer) = ask(s, "Was haben wir zur Laufzeit vereinbart?", [("include_local", .bool(true))])
        #expect(status == 200 && Set(meetingsOf(model.calls.last?.inputs)) == [NORTHWIND, BUDGET])
        #expect(model.calls.last?.watching.lastPathComponent == NORTHWIND && answer["left_out"] == .int(0))
    }

    /// The local model during a call: its memory first, then a second click. A cloud model needs neither.
    @Test func theLocalModelDuringACallNeedsItsMemoryAndASecondClick() throws {
        let model = FakeAsker()
        let s = try server(model)
        defer { s.stop() }
        s.app.meetingStatus = { $0.folder.lastPathComponent == BUDGET ? "recording" : "ready" }
        var (status, answer) = ask(s, "Laufzeit")
        #expect(status == 200 && answer["confirm"] == .string("Runs Gemma on this Mac during the call (about 10 GB, may slow the call)"))
        #expect(model.calls.isEmpty && answer["answer"] == nil)
        (status, answer) = ask(s, "Laufzeit", [("confirmed", .bool(true))])
        #expect(status == 200 && model.calls.count == 1 && answer["answer"] != nil)

        let low = try server(model, free: 1.0)
        defer { low.stop() }
        low.app.meetingStatus = { _ in "recording" }
        (status, answer) = ask(low, "Laufzeit", [("confirmed", .bool(true))])
        #expect(status == 400 && (answer["error"]?.stringValue ?? "").hasPrefix("Not enough free memory for the local model during the call"))
        try choose(low, [("notes", .string("anthropic"))])
        (status, answer) = ask(low, "Laufzeit")
        #expect(status == 200 && answer["confirm"] == nil && model.calls.count == 2)
    }

    @Test func offOrWithoutAModelItSaysWhy() throws {
        let off = try server(notes: false)
        defer { off.stop() }
        let (status, answer) = ask(off, "Laufzeit")
        #expect(status == 503 && (answer["error"]?.stringValue ?? "").contains("turned off"))
        let model = FakeAsker()
        let s = try server(model)
        defer { s.stop() }
        try choose(s, [("notes", .string(ModelChoice.PENDING))])
        let info = s.get("/api/ask").json
        #expect(info?["ready"] == .bool(false))
        #expect(info?["reason"] == .string("No model yet: choose one for Notes in Settings → Language model."))
        #expect(ask(s, "Laufzeit").0 == 400 && model.calls.isEmpty)
    }

    @Test func aModelThatFailsSaysWhy() throws {
        let s = try server(FakeAsker(.failure(BadGateway("Anthropic API: the key was refused"))))
        defer { s.stop() }
        let (status, answer) = ask(s, "Laufzeit")
        #expect(status == 502 && answer["error"] == .string("Anthropic API: the key was refused"))
    }

    /// `palaver-lm … ask`, faked by a shell script: the inputs on stdin, the answer's last line read, the app watching it.
    @Test func theAppAsksInAHelperProcess() throws {
        let dir = tempFolder("ask")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("Meetings", isDirectory: true)
        try twoMeetings(out)
        let script = dir.appendingPathComponent("palaver-lm")
        try Data("""
            #!/bin/sh
            echo "$@" > "\(dir.path)/argv"
            cat > "\(dir.path)/input"
            cat "\(dir.path)/answer"
            exit "$(cat "\(dir.path)/end")"

            """.utf8).write(to: script)
        chmod(script.path, 0o755)
        let rec = FakeRecording()
        let asker = LMAskMeetings(outputDir: out, lm: script.path, cliOptions: ["--config", "/c.toml"], recording: rec,
                                  taskpolicy: dir.appendingPathComponent("no-taskpolicy").path)
        let inputs: JSONValue = .object([("question", .string("Laufzeit?")), ("passages", .array([]))])
        let answer: JSONValue = .object([("answer", .string("24 Monate [1].")), ("sources", .array([.int(1)])), ("engine", .string("Fake"))])
        try Data(("loading…\n" + PythonJSON.dumps(answer) + "\n").utf8).write(to: dir.appendingPathComponent("answer"))
        try Data("0".utf8).write(to: dir.appendingPathComponent("end"))
        let watching = out.appendingPathComponent(NORTHWIND, isDirectory: true)
        #expect(dumps(try asker.ask(inputs: inputs, watching: watching)) == dumps(answer))
        #expect(try String(contentsOf: dir.appendingPathComponent("argv"), encoding: .utf8) == "--config /c.toml --no-notify ask\n")
        #expect(PythonJSON.read(dir.appendingPathComponent("input")) == inputs)
        #expect(rec.watched.count == 1 && rec.watched.first?.folder == watching)
        try Data(PythonJSON.dumps(.object([("error", .string("No passages to answer from."))])).utf8)
            .write(to: dir.appendingPathComponent("answer"))
        try Data("1".utf8).write(to: dir.appendingPathComponent("end"))
        do {
            _ = try asker.ask(inputs: inputs, watching: watching)
            Issue.record("no error")
        } catch let e as BadGateway {
            #expect(e.text == "No passages to answer from.")
        }
    }
}
