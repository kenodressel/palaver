// The live assistant's routes (#15): the panel (which model, the answers kept) and one ask on the user's click. The
// model is the notes' choice, a meeting kept on this Mac stays local, the local model during a call needs its memory and
// a second click; the answers are kept in live-assistant.json. The model is a fake `LiveAssistantAsker` in this process,
// or `/bin/sh` standing in for palaver-lm — never a model.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"

private func dumps(_ v: JSONValue?) -> String { v.map { PythonJSON.dumps($0, ensureAscii: false) } ?? "nil" }

private func post(_ s: TestServer, _ body: JSONValue) -> (Int, JSONValue) {
    let r = s.post("/api/meetings/\(MEETING)/assistant", body)
    return (r.status, r.json ?? .null)
}

private let CATCH_UP: JSONValue = .object([("kind", .string("catchup")), ("minutes", .int(10))])

/// palaver-lm's answer to whatever is asked, or its error; each ask kept.
private final class FakeAssistant: LiveAssistantAsker, @unchecked Sendable {
    var answer: Result<JSONValue, Error>
    private let lock = NSLock()
    private var asked: [(String, JSONValue)] = []
    init(_ answer: Result<JSONValue, Error> = .success(.object([
        ("kind", .string("catchup")), ("bullets", .strings(["Rico ran the debrief.", "The salary band is fine."])),
        ("engine", .string("Fake model")),
    ]))) { self.answer = answer }
    func ask(meetingId: String, inputs: JSONValue) throws -> JSONValue {
        lock.withLock { asked.append((meetingId, inputs)) }
        return try answer.get()
    }
    var inputs: [(String, JSONValue)] { lock.withLock { asked } }
}

private func server(_ model: FakeAssistant = FakeAssistant(), free: Double = 64.0, notes: Bool? = nil,
                    recording: Bool = false) throws -> TestServer {
    let s = try TestServer(userName: "Timo", recording: FakeRecording(), notesEnabled: notes, assistant: model,
                           freeMemoryGB: { free }, meetings: { try pageMeeting($0) })
    if recording { s.app.meetingStatus = { _ in "recording" } }
    return s
}

private func choose(_ s: TestServer, _ engines: [(String, JSONValue)]) throws {
    try SettingsFile.update([("engines", .object(engines))], stores: s.app.stores)
}

private func kept(_ s: TestServer) -> JSONValue? {
    PythonJSON.read(s.app.outputDir.appendingPathComponent(MEETING).appendingPathComponent("live-assistant.json"))
}

@Suite(.serialized) struct LiveAssistantRoutesTests {
    @Test func catchMeUpAsksFromTheTranscriptAndKeepsTheAnswer() throws {
        let model = FakeAssistant()
        let s = try server(model)
        defer { s.stop() }
        let empty = s.get("/api/meetings/\(MEETING)/assistant").json
        #expect(dumps(empty?["answers"]) == #"{"catchup": null, "next_steps": null, "asks": []}"#)
        #expect(dumps(empty?["info"]) == #"{"ready": true, "reason": null, "model": "Gemma, on this Mac", "local": true, "warning": null}"#)
        let (status, answer) = post(s, CATCH_UP)
        #expect(status == 200)
        let (meeting, inputs) = try #require(model.inputs.first)
        #expect(meeting == MEETING)
        #expect(inputs["kind"] == .string("catchup") && inputs["minutes"] == .int(10) && inputs["user"] == .string("Timo"))
        #expect(inputs["lines"]?.arrayValue?.last?["text"] == .string("Thanks Rico, the salary band is fine."))
        #expect(inputs["now"] == .double(15.0) && inputs["title"] == .string("Hiring debrief"))
        let catchup = try #require(answer["answers"]?["catchup"])
        #expect(catchup["bullets"] == .strings(["Rico ran the debrief.", "The salary band is fine."]))
        #expect(catchup["minutes"] == .int(10) && catchup["until"] == .double(15.0) && catchup["engine"] == .string("Fake model"))
        #expect(catchup["asked_at"]?.stringValue?.isEmpty == false)
        // Kept for the call: a reload shows it again; the notes are not touched.
        #expect(dumps(kept(s)?["catchup"]) == dumps(catchup))
        #expect(dumps(s.get("/api/meetings/\(MEETING)/assistant").json?["answers"]) == dumps(answer["answers"]))
        // A span not offered is the default five minutes.
        _ = post(s, .object([("kind", .string("catchup")), ("minutes", .int(60))]))
        #expect(model.inputs.last?.1["minutes"] == .int(5))
    }

    @Test func nextStepsAndQuestionsAreKeptToo() throws {
        let model = FakeAssistant(.success(.object([
            ("kind", .string("next_steps")), ("next_steps", .array([.object([("owner", .string("Rico")), ("task", .string("Send the offer"))])])),
            ("decisions", .strings(["The band is fine"])), ("engine", .string("Fake model")),
        ])))
        let s = try server(model)
        defer { s.stop() }
        var (status, answer) = post(s, .object([("kind", .string("next_steps"))]))
        #expect(status == 200 && answer["answers"]?["next_steps"]?["decisions"] == .strings(["The band is fine"]))
        model.answer = .success(.object([("kind", .string("ask")), ("answer", .string("The band is fine.")),
                                         ("quotes", .array([.object([("time", .string("00:13")), ("speaker", .string("Rico")),
                                                                     ("text", .string("the salary band is fine"))])])),
                                         ("engine", .string("Fake model"))]))
        for i in 0..<22 {
            (status, answer) = post(s, .object([("kind", .string("ask")), ("question", .string("  What about the band? \(i) "))]))
            #expect(status == 200)
        }
        let asks = answer["answers"]?["asks"]?.arrayValue ?? []
        #expect(asks.count == 20 && asks.last?["question"] == .string("What about the band? 21"))  // the newest last
        #expect(asks.first?["question"] == .string("What about the band? 2"))
        #expect(asks.last?["quotes"]?.arrayValue?.first?["time"] == .string("00:13"))
        #expect(model.inputs.last?.1["question"] == .string("What about the band? 21"))
        // The next steps are still there.
        #expect(kept(s)?["next_steps"]?["next_steps"]?.arrayValue?.count == 1)
        let long = String(repeating: "q", count: 700)
        _ = post(s, .object([("kind", .string("ask")), ("question", .string(long))]))
        #expect(model.inputs.last?.1["question"]?.stringValue?.count == 500)
    }

    @Test func whatCanNotBeAskedIsSaidBeforeAModelRuns() throws {
        let model = FakeAssistant()
        let s = try server(model)
        defer { s.stop() }
        var (status, answer) = post(s, .object([("kind", .string("ask")), ("question", .string("   "))]))
        #expect(status == 400 && answer["error"] == .string("Type a question first."))
        (status, answer) = post(s, .object([("kind", .string("summary"))]))
        #expect(status == 400 && (answer["error"]?.stringValue ?? "").hasPrefix("Unknown kind of ask"))
        try Data("[]".utf8).write(to: s.app.outputDir.appendingPathComponent(MEETING).appendingPathComponent("transcript.json"))
        (status, answer) = post(s, CATCH_UP)
        #expect(status == 400 && answer["error"] == .string("Nothing has been said yet. Ask again once the meeting has started."))
        #expect(model.inputs.isEmpty && kept(s) == nil)
    }

    /// The notes' model answers, not the best next question's; a meeting kept on this Mac stays local.
    @Test func itRunsOnTheNotesModelAndAMeetingKeptOnThisMacStaysLocal() throws {
        let model = FakeAssistant()
        let s = try server(model)
        defer { s.stop() }
        try choose(s, [("coach", .string("anthropic"))])
        #expect(s.get("/api/meetings/\(MEETING)/assistant").json?["info"]?["model"] == .string("Gemma, on this Mac"))
        try choose(s, [("coach", .string("local")), ("notes", .string("anthropic"))])
        let info = s.get("/api/meetings/\(MEETING)/assistant").json?["info"]
        #expect(info?["model"] == .string("Claude Opus 5.5, cloud") && info?["local"] == .bool(false))
        try LocalOnly.set(s.app.outputDir.appendingPathComponent(MEETING, isDirectory: true), on: true)
        let local = s.get("/api/meetings/\(MEETING)/assistant").json?["info"]
        #expect(local?["model"] == .string("Gemma, on this Mac") && local?["local"] == .bool(true))
    }

    /// The local model during a call: its memory first, then a second click. A cloud model needs neither.
    @Test func theLocalModelDuringACallNeedsItsMemoryAndASecondClick() throws {
        let model = FakeAssistant()
        let s = try server(model, free: 64.0, recording: true)
        defer { s.stop() }
        var (status, answer) = post(s, CATCH_UP)
        #expect(status == 409 && (answer["error"]?.stringValue ?? "").hasPrefix("Runs Gemma on this Mac during the call"))
        #expect(model.inputs.isEmpty)
        (status, _) = post(s, .object([("kind", .string("catchup")), ("confirmed", .bool(true))]))
        #expect(status == 200 && model.inputs.count == 1)

        let low = try server(model, free: 1.0, recording: true)
        defer { low.stop() }
        (status, answer) = post(low, .object([("kind", .string("catchup")), ("confirmed", .bool(true))]))
        #expect(status == 400 && (answer["error"]?.stringValue ?? "").hasPrefix("Not enough free memory for the local model during the call"))
        #expect(model.inputs.count == 1)
        try choose(low, [("notes", .string("anthropic"))])
        #expect(post(low, CATCH_UP).0 == 200 && model.inputs.count == 2)
    }

    @Test func offOrWithoutAModelItSaysWhy() throws {
        let off = try server(notes: false)
        defer { off.stop() }
        let (status, answer) = post(off, CATCH_UP)
        #expect(status == 503 && (answer["error"]?.stringValue ?? "").contains("turned off"))
        let model = FakeAssistant()
        let s = try server(model)
        defer { s.stop() }
        try choose(s, [("notes", .string(ModelChoice.PENDING))])
        let info = s.get("/api/meetings/\(MEETING)/assistant").json?["info"]
        #expect(info?["ready"] == .bool(false))
        #expect(info?["reason"] == .string("No model yet: choose one for Notes in Settings → Language model."))
        #expect(post(s, CATCH_UP).0 == 400 && model.inputs.isEmpty)
    }

    @Test func aModelThatFailsSaysWhyAndNothingIsKept() throws {
        let s = try server(FakeAssistant(.failure(BadGateway("Anthropic API: the key was refused"))))
        defer { s.stop() }
        let (status, answer) = post(s, CATCH_UP)
        #expect(status == 502 && answer["error"] == .string("Anthropic API: the key was refused"))
        #expect(kept(s) == nil)
    }

    /// `palaver-lm … assistant <folder>`, faked by a shell script: the inputs on stdin, the answer's last line read.
    @Test func theAppAsksInAHelperProcess() throws {
        let dir = tempFolder("assistant")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("Meetings", isDirectory: true)
        try pageMeeting(out)
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
        let ask = LMLiveAssistant(outputDir: out, lm: script.path, cliOptions: ["--config", "/c.toml"], recording: rec,
                                  taskpolicy: dir.appendingPathComponent("no-taskpolicy").path)
        let answer: JSONValue = .object([("kind", .string("catchup")), ("bullets", .strings(["x"])), ("engine", .string("Fake"))])
        try Data(("loading…\n" + PythonJSON.dumps(answer) + "\n").utf8).write(to: dir.appendingPathComponent("answer"))
        try Data("0".utf8).write(to: dir.appendingPathComponent("end"))
        #expect(dumps(try ask.ask(meetingId: MEETING, inputs: CATCH_UP)) == dumps(answer))
        #expect(try String(contentsOf: dir.appendingPathComponent("argv"), encoding: .utf8)
                == "--config /c.toml --no-notify assistant \(out.appendingPathComponent(MEETING).path)\n")
        #expect(PythonJSON.read(dir.appendingPathComponent("input")) == CATCH_UP)
        #expect(rec.watched.count == 1 && rec.watched.first?.ownGroup == true)  // the app watches its memory
        try Data(PythonJSON.dumps(.object([("error", .string("Type a question first."))])).utf8).write(to: dir.appendingPathComponent("answer"))
        try Data("1".utf8).write(to: dir.appendingPathComponent("end"))
        do {
            _ = try ask.ask(meetingId: MEETING, inputs: CATCH_UP)
            Issue.record("no error")
        } catch let e as BadGateway {
            #expect(e.text == "Type a question first.")
        }
    }
}
