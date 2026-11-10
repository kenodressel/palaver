// `palaver-lm projects`: the model's assignments and new projects, its descriptions (never over the user's), meetings
// kept on this Mac left out of a cloud model's prompt and all-private projects hidden from it, the store read again
// once the model is done; and one model at a time: a run that would not wait gets 75 while another process holds it.
import Foundation
import Testing
import PalaverCloud
import PalaverCore
import PalaverDomain
@testable import PalaverLM

private let A = "2026-10-20T09-00-00", B = "2026-10-21T10-00-00", SECRET = "2026-10-22T11-00-00"

@Suite struct ProjectsRunTests {
    func meetings(_ home: Home) {
        home.meeting(A, [utterance("Timo Strauß", 0, "Wir planen den Release für Northwind.")], start: "2026-10-20T09:00:00+02:00")
        home.meeting(B, [utterance("Timo Strauß", 0, "Das Angebot für Contoso ist fertig.")], start: "2026-10-21T10:00:00+02:00")
        home.meeting(SECRET, [utterance("Timo Strauß", 0, "Geheime Personalfragen.")], start: "2026-10-22T11:00:00+02:00")
        try! Titles.save(RecordingPaths(home.outputDir.appendingPathComponent(SECRET)), "Personalgespräch")
        try! LocalOnly.set(home.outputDir.appendingPathComponent(SECRET), on: true)
    }

    @Test func suggestAssignsCreatesAndDropsEmptyNewProjects() async throws {
        let home = Home()
        meetings(home)
        let store = ProjectStore(path: home.stores.projects)
        let mine = try store.create("Northwind", description: "Mein Text.", by: "you")
        try store.save()
        let fake = FakeModel(json: .object([
            ("new_projects", .array([.object([("key", .string("new1")), ("name", .string("Contoso")), ("description", .string("Angebote."))]),
                                     .object([("key", .string("new2")), ("name", .string("Leer")), ("description", .string(""))])])),
            ("assignments", .array([.object([("meeting", .string(A)), ("projects", .strings([mine]))]),
                                    .object([("meeting", .string(B)), ("projects", .strings(["new1", "nope"]))]),
                                    .object([("meeting", .string("2026-01-01T00-00-00")), ("projects", .strings([mine]))])])),
            ("descriptions", .array([.object([("project", .string(mine)), ("description", .string("Überschrieben?"))])])),
        ]))
        #expect(try await run(["projects", "--no-wait", "suggest"], home.context(fake)) == 0)
        store.reload()
        let contoso = try #require(store.find("Contoso"))
        #expect(store.find("Leer") == nil)  // proposed, nothing put in
        #expect(store.ofMeeting(A)[mine]?["by"] == .string("model") && store.ofMeeting(B)[contoso]?["why"] == .string("suggested by the model"))
        #expect(store.projects[mine]?["description"] == .string("Mein Text.") && store.projects[mine]?["description_by"] == .string("you"))
        #expect(store.projects[contoso]?["description_by"] == .string("model"))
        #expect(home.said.contains("Asking Gemma 4 12B on this Mac…") && home.said.contains("\(B): Contoso"))
        // The local model reads every meeting, the one kept on this Mac too.
        let prompt = try #require(fake.asked.first?.prompt)
        #expect(prompt.contains("- id \(mine): Northwind — Mein Text.\n") && prompt.contains("- id \(SECRET): “Personalgespräch”"))
        for part in ["You sort the meetings Timo Strauß recorded into projects", ProjectsPrompt.DESCRIPTION_RULES, "Meetings to sort:"] {
            #expect(prompt.contains(part))
        }
    }

    @Test func aCloudModelNeverReadsMeetingsKeptOnThisMacNorTheirProjects() async throws {
        let home = Home()
        meetings(home)
        let store = ProjectStore(path: home.stores.projects)
        let hr = try store.create("Personal", description: "Aus dem geheimen Gespräch.", by: "model")
        _ = try store.assign(SECRET, hr, by: "you")
        try store.save()
        try home.keys.write("anthropic.api_key", KEY)
        try home.settings.choose("projects", .string("anthropic"))
        let fake = FakeModel(json: .object([
            ("new_projects", .array([])),
            ("assignments", .array([.object([("meeting", .string(A)), ("projects", .strings([hr]))])])),
            ("descriptions", .array([.object([("project", .string(hr)), ("description", .string("verraten"))])])),
        ]))
        #expect(try await run(["projects", "--no-wait", "suggest"], home.context(fake)) == 0)
        let prompt = try #require(fake.asked.first?.prompt)
        #expect(!prompt.contains(SECRET) && !prompt.contains("Personal") && !prompt.contains("geheim") && prompt.contains(A))
        store.reload()
        #expect(store.ofMeeting(A).isEmpty && store.projects[hr]?["description"] == .string("Aus dem geheimen Gespräch."))
        #expect(home.said.contains("Asking Anthropic API…"))
        let log = AccessLog.recent(stores: home.stores)
        #expect(log.first?["feature"] == .string("projects") && log.first?["ok"] == .bool(true) && log.first?["meetings"] == .array([]))
    }

    @Test func describeWritesTheModelsDescriptionButNeverOverTheUsers() async throws {
        let home = Home()
        meetings(home)
        let store = ProjectStore(path: home.stores.projects)
        let empty = try store.create("Contoso")
        let written = try store.create("Northwind", description: "Von mir.", by: "you")
        _ = try store.assign(B, empty, by: "you")
        _ = try store.assign(A, written, by: "you")
        try store.save()
        let fake = FakeModel(json: .object([("description", .string("Angebote für Contoso."))]))
        #expect(try await run(["projects", "describe"], home.context(fake)) == 0)  // every project without one
        store.reload()
        #expect(store.projects[empty]?["description"] == .string("Angebote für Contoso.") && store.projects[empty]?["description_by"] == .string("model"))
        #expect(store.projects[written]?["description"] == .string("Von mir.") && fake.asked.count == 1)
        #expect(fake.asked[0].prompt.hasPrefix("Describe the project “Contoso” from the meetings Timo Strauß recorded in it."))
        #expect(home.said == ["Contoso: Angebote für Contoso."])
        #expect(try await run(["projects", "describe", "abcdef12"], home.context(fake)) == 2)
        #expect(home.said.last == "error: no project abcdef12")
    }

    @Test func theStoreIsReadAgainOnceTheModelIsDone() async throws {
        let home = Home()
        meetings(home)
        let path = home.stores.projects
        final class Changing: LanguageModel {
            let path: URL
            init(_ path: URL) { self.path = path }
            func generate(prompt: String, schema: JSONValue, parse: @escaping AnswerParser) async throws -> JSONValue {
                // While the model thinks, the window adds a project.
                let window = ProjectStore(path: path)
                try window.locked { window.reload(); _ = try window.create("Aus dem Fenster"); try window.save() }
                return try parse(#"{"new_projects": [{"key": "n", "name": "Neu", "description": ""}], "assignments": [{"meeting": "\#(A)", "projects": ["n"]}]}"#)
            }
        }
        #expect(try await run(["projects", "--no-wait", "suggest", home.outputDir.appendingPathComponent(A).path],
                              home.context(Changing(path))) == 0)
        let store = ProjectStore(path: path)
        #expect(store.find("Aus dem Fenster") != nil && store.find("Neu") != nil)
    }

    @Test func aRunThatWouldNotWaitGets75WhileAnotherProcessHoldsTheModel() async throws {
        let home = Home()
        meetings(home)
        try FileManager.default.createDirectory(at: home.stores.notesLock.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Another process (as Python's palaver notes would) holds notes.lock.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-e", #"use Fcntl ":flock"; open(F, ">>", $ARGV[0]) or die; flock(F, LOCK_EX) or die; $| = 1; print "locked\n"; sleep 30"#,
                            home.stores.notesLock.path]
        let out = Pipe()
        holder.standardOutput = out
        try holder.run()
        defer { holder.terminate(); holder.waitUntilExit() }
        let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        try #require(line == "locked\n")
        let fake = FakeModel(json: ControlFallback.suggest)
        #expect(try await run(["projects", "--no-wait", "suggest"], home.context(fake)) == ModelLock.EXIT_MODEL_BUSY)
        #expect(home.said == ["the language model is busy"] && fake.asked.isEmpty)
        // The best next question on the local model too (a cloud model would not need the lock).
        var ctx = home.context(fake)
        ctx.readInput = { Data(#"{"lines": [{"speaker": "Valerie", "start": 1, "text": "Hallo"}]}"#.utf8) }
        #expect(try await run(["next-question", home.outputDir.appendingPathComponent(B).path], ctx) == ModelLock.EXIT_MODEL_BUSY)
        #expect(home.said.last == #"{"error": "The language model is busy; try again in a minute."}"#)
        holder.terminate()
        holder.waitUntilExit()
        #expect(try await run(["projects", "--no-wait", "suggest"], home.context(fake)) == 0)
    }
}
