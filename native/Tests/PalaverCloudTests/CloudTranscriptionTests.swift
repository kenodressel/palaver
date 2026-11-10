// The system track through a service (transcription.py `_cloud`, `test`): only the trimmed system track goes, the
// words come back on the recording's clock, every upload is in the access log (seconds of audio, track), and a
// deletion the service owes lands in the meeting's cloud-pending.json.
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverCloud

private let SONIOX = "https://api.eu.soniox.com"

@Suite struct CloudTranscriptionTests {
    private func setUp(_ home: Home) throws -> RecordingPaths {
        try home.settings.setKey("soniox", .string(ASR_KEY))
        let paths = RecordingPaths(home.dir.appendingPathComponent("Meetings/2026-10-20T14-30-00"))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        // Speech 3–5 s and 12–14 s; the silence between is cut (0.5 s kept each side).
        try toneWav(paths.systemWav, seconds: 20, loud: [(3.0, 5.0), (12.0, 14.0)])
        try toneWav(paths.micWav, seconds: 20, loud: [(0.0, 20.0)])  // never sent
        return paths
    }

    private func soniox(tokens: String, deleteFile: Routes.Answer = .ok("")) -> Routes {
        Routes(["POST \(SONIOX)/v1/files": [.ok(#"{"id": "f1"}"#)],
                "POST \(SONIOX)/v1/transcriptions": [.ok(#"{"id": "j1"}"#)],
                "GET \(SONIOX)/v1/transcriptions/j1": [.ok(#"{"status": "completed", "audio_duration_ms": 5000}"#)],
                "GET \(SONIOX)/v1/transcriptions/j1/transcript": [.ok(tokens)],
                "DELETE \(SONIOX)/v1/transcriptions/j1": [.ok("")],
                "DELETE \(SONIOX)/v1/files/f1": [deleteFile]])
    }

    @Test func theTrimmedSystemTrackGoesAndTheWordsComeBackOnTheRecordingsClock() async throws {
        let home = Home()
        let paths = try setUp(home)
        // On the trimmed clock: 2.5–5.5 s is 0–3 s, 11.5–14.5 s is 3–6 s.
        let fake = soniox(tokens: """
            {"tokens": [{"text": "Guten", "start_ms": 600, "end_ms": 900, "language": "de"},
                        {"text": " Morgen.", "start_ms": 950, "end_ms": 1400, "language": "de"},
                        {"text": " Kontoso", "start_ms": 3600, "end_ms": 4100, "language": "de"}]}
            """)
        var kept: [(String, Int)] = []
        let out = try await CloudTranscription.transcribe(
            paths, pid: "soniox", settings: home.settings, language: "auto",
            dictionary: TranscriberDictionary(replacements: PyDict([("Kontoso", "Contoso")])), keyterms: ["Northwind"],
            http: fake.client, stores: home.stores) { kept.append(($0, $1)) }
        #expect(out.segments.map(\.text) == ["Guten Morgen.", "Contoso"])
        #expect(out.segments[0].start == 3.1 && out.segments[1].start == 12.1 && out.segments[1].end == 12.6)
        let model = try home.settings.settingsOf("soniox")["model"]?.stringValue
        #expect(out.language == "de" && out.model == model)
        #expect(abs(out.sentSeconds - 6.0) < 0.01 && kept.isEmpty)
        let file = multipartFields(fake.requests[0])["file"]?.first as? (String, String, Data)
        #expect(file?.2.prefix(4) == Data("fLaC".utf8))
        #expect(fake.requests.allSatisfy { $0.url?.host == "api.eu.soniox.com" })
        let log = AccessLog.recent(nil, stores: home.stores)
        #expect(log.count == 1 && log[0]["feature"] == .string("transcription") && log[0]["track"] == .string("system"))
        #expect(log[0]["audio_seconds"] == .double(6.0) && log[0]["meetings"] == .strings(["2026-10-20T14-30-00"]))
        #expect(log[0]["ok"] == .bool(true) && log[0]["chars"] == .int(0))
        #expect(!((try? String(contentsOf: home.stores.accessLog, encoding: .utf8)) ?? "").contains(ASR_KEY))
    }

    @Test func aDeletionTheServiceRefusedIsKeptInTheMeeting() async throws {
        let home = Home()
        let paths = try setUp(home)
        let fake = soniox(tokens: #"{"tokens": []}"#, deleteFile: .json(500, "{}"))
        var kept: [(String, Int)] = []
        _ = try await CloudTranscription.transcribe(paths, pid: "soniox", settings: home.settings, language: "de", dictionary: nil,
                                                    keyterms: [], http: fake.client, stores: home.stores) { kept.append(($0, $1)) }
        #expect(kept.count == 1 && kept[0] == ("soniox", 1))
        let pending = PythonJSON.read(paths.cloudPending)?.arrayValue
        #expect(pending?.count == 1 && pending?[0]["url"] == .string("\(SONIOX)/v1/files/f1") && pending?[0]["what"] == .string("file"))
    }

    @Test func aFailedUploadIsLoggedWithoutTheKey() async throws {
        let home = Home()
        let paths = try setUp(home)
        let fake = Routes(["POST \(SONIOX)/v1/files": [.json(401, #"{"error": "bad \#(ASR_KEY)"}"#)]])
        let e = await thrown {
            try await CloudTranscription.transcribe(paths, pid: "soniox", settings: home.settings, language: "auto", dictionary: nil,
                                                    keyterms: [], http: fake.client, stores: home.stores)
        }
        #expect(CloudTranscription.message(e!) == "Soniox refused the API key (HTTP 401); check or replace it in Settings")
        let log = AccessLog.recent(nil, stores: home.stores)
        #expect(log.first?["ok"] == .bool(false) && (log.first?["error"]?.stringValue ?? "").contains("refused the API key"))
        #expect(!((try? String(contentsOf: home.stores.accessLog, encoding: .utf8)) ?? "").contains(ASR_KEY))
    }

    @Test func aServiceThatIsNotSetUpSendsNothing() async throws {
        let home = Home()
        let paths = try setUp(home)
        try home.settings.removeKey("soniox")
        let fake = Routes()
        let e = await thrown {
            try await CloudTranscription.transcribe(paths, pid: "soniox", settings: home.settings, language: "auto", dictionary: nil,
                                                    keyterms: [], http: fake.client, stores: home.stores)
        }
        #expect((e as? EngineUnavailable)?.message == "Soniox: Add the API key" && fake.requests.isEmpty)
    }

    @Test func keytermsAreTheGlossaryAndTheInvitees() throws {
        let home = Home()
        let paths = try setUp(home)
        let glossary = Glossary.current(stores: home.stores)
        _ = try glossary.add(term: "Northwind")
        try glossary.save()
        let event = CalendarEvent(title: "Sync", start: try PyDateTime.parse("2026-10-20T14:30:00+02:00"),
                                  end: try PyDateTime.parse("2026-10-20T15:00:00+02:00"),
                                  attendees: [Attendee(name: "Valerie"), Attendee(name: "Timo Strauß")], uid: "sync")
        try CalendarEvents.save(paths, event)
        let terms = CloudTranscription.keyterms(paths, userName: "Timo Strauß", stores: home.stores)
        #expect(terms == ["Northwind", "Valerie"])  // not the user
    }

    @Test func theTestSendsTwoSecondsOfAToneAndNoMeeting() async throws {
        let home = Home()
        _ = try setUp(home)
        let fake = soniox(tokens: #"{"tokens": [{"text": "Hm", "start_ms": 0, "end_ms": 100}]}"#)
        let answer = try await CloudTranscription.test("soniox", settings: home.settings, http: fake.client)
        #expect(answer["usd_per_hour"] == .double(0.10) && answer["heard"] == .string("Hm") && answer["seconds"]?.doubleValue != nil)
        let log = AccessLog.recent(nil, stores: home.stores)
        #expect(log.first?["feature"] == .string("test") && log.first?["meetings"] == .array([]) && log.first?["audio_seconds"] == .double(2.0))
        let e = await thrown { try await CloudTranscription.test("anthropic", settings: home.settings, http: fake.client) }
        #expect((e as? SettingRefused)?.text == "no transcription service 'anthropic'")
    }
}
