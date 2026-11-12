// A meeting taken in from a colleague's zip (exchange.py:520-828, 853-864, 900-1200): the import tests of
// test_exchange.py (those of the audio are ExchangeAudioTests'), and the eight Task 23 left to `readPackage` and the
// whole import.
// Fictional people only: Valerie exports, Timo imports; Timo Strauß is named by hand, Carla by voice.
import Darwin
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct ExchangeImportTests {
    static let ID = "2026-10-29T10-00-00"
    static let START = "2026-10-29T10:00:00+01:00"
    static let SENDER = "Valerie"
    static let ME = "Timo"
    static let berlin = TimeZone(identifier: "Europe/Berlin")!

    static func attendee(_ name: String, _ email: String?, organizer: Bool = false, isSelf: Bool = false) -> JSONValue {
        var fields: [(String, JSONValue)] = [("name", .string(name)), ("email", .str(email)), ("response", .string("accepted"))]
        if organizer { fields.append(("organizer", .bool(true))) }
        if isSelf { fields.append(("is_self", .bool(true))) }
        return .object(fields)
    }

    static func event(title: String = "Budget review", start: String = "2026-10-29T10:00:00+01:00",
                      end: String = "2026-10-29T10:30:00+01:00", uid: String = "ABC-123",
                      attendees: [JSONValue]? = nil) -> JSONValue {
        .object([
            ("title", .string(title)), ("start", .string(start)), ("end", .string(end)), ("uid", .string(uid)),
            ("series", .bool(true)), ("location", .string("Teams")),
            ("attendees", .array(attendees ?? [
                attendee("Valerie", "valerie@northwind.example", organizer: true, isSelf: true),
                attendee("Timo Strauß", "timo.s@contoso.example"), attendee("Timo", "timo@contoso.example"),
            ])),
            ("link", .object([("source", .string("calendar")), ("confidence", .double(0.9)), ("reason", .string("time match"))])),
        ])
    }

    /// 64 numbers, a direction of its own per seed (`_vector`).
    static func vector(_ seed: Int) -> [Double] { (0..<64).map { sin(Double(seed * 64 + $0) * 0.7) } }

    static func write(_ v: JSONValue, _ url: URL, indent: Int? = nil) throws {
        try PythonJSON.write(v, to: url, indent: indent, ensureAscii: true)
    }

    /// `make_meeting`: `user`'s recording: Timo Strauß named by hand, Carla recognized by voice, SPEAKER_02 merged into
    /// Timo Strauß, SPEAKER_03 removed as noise. `audio`: seconds of its tracks (Python's has 60; none without), at
    /// 16 kHz, `3000 * sin(t / 7)` and `2000 * sin(t / 3)`.
    @discardableResult
    static func makeMeeting(_ root: URL, _ name: String = ID, start: String = START, event: JSONValue? = event(),
                            user: String = SENDER, size: Int = 64, audio: Int = 0) throws -> RecordingPaths {
        let paths = RecordingPaths(root.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        if audio > 0 {
            let n = 16_000 * audio
            var system = [Int16](repeating: 0, count: n), mic = [Int16](repeating: 0, count: n)
            for t in 0..<n {
                system[t] = Int16(3000 * sin(Double(t) / 7))
                mic[t] = Int16(2000 * sin(Double(t) / 3))
            }
            try Wav16.write(system, rate: 16_000, to: paths.systemWav)
            try Wav16.write(mic, rate: 16_000, to: paths.micWav)
        }
        try write(.object([("start_time", .string(start)), ("duration_seconds", .int(60))]), paths.meta)
        try "de".write(to: paths.language, atomically: false, encoding: .utf8)
        try write(.array([
            SpeakerTurn(speaker: "SPEAKER_00", start: 2, end: 20).json, SpeakerTurn(speaker: "SPEAKER_01", start: 21, end: 40).json,
            SpeakerTurn(speaker: "SPEAKER_02", start: 41, end: 44).json, SpeakerTurn(speaker: "SPEAKER_03", start: 45, end: 45.5).json,
        ]), paths.systemTurns)
        let utterances = [
            Utterance(speaker: user, start: 0, end: 2, text: "Hallo zusammen."),
            Utterance(speaker: "Timo Strauß", start: 2, end: 20, text: "Das Budget steht.", label: "SPEAKER_00"),
            Utterance(speaker: "Carla", start: 21, end: 40, text: "Wir brauchen mehr Zeit.", label: "SPEAKER_01"),
            Utterance(speaker: "SPEAKER_02", start: 41, end: 44, text: "Genau."),
            Utterance(speaker: "SPEAKER_03", start: 45, end: 45.5, text: "Hm."),
            Utterance(speaker: user, start: 50, end: 55, text: "Dann machen wir das so."),
        ]
        try write(.array(utterances.map(\.json)), paths.transcriptJson)
        try write(.object([("SPEAKER_00", .string("Timo Strauß"))]), paths.speakers)
        try write(.object([("SPEAKER_01", .object([("name", .string("Carla")), ("similarity", .double(0.9))]))]), paths.speakersAuto)
        try write(.object([("SPEAKER_02", .string("SPEAKER_00"))]), paths.speakersMerged)
        try write(.strings(["SPEAKER_03"]), paths.speakersIgnored)
        try write(.object((0..<4).map { ("SPEAKER_0\($0)", .array((vector($0) + vector($0 + 10)).prefix(size).map { .double($0) })) }),
                  paths.speakerEmbeddings)
        if let event { try write(event, paths.calendar) }
        try NotesFile.save(paths, .object([
            ("title", .string("Budget review")), ("summary", .string("SPEAKER_00 presented the budget.")),
            ("sections", .array([.object([("heading", .string("Budget")), ("points", .array([
                .object([("text", .string("It is fixed")), ("details", .array([]))]),
                .object([("text", .string("From my own notes")), ("details", .array([])), ("mine", .bool(true))]),
            ]))])])),
            ("next_steps", .array([.object([("owner", .string("Timo Strauß")), ("task", .string("Send the numbers"))])])),
            ("decisions", .strings(["Budget approved"])), ("speaker_names", .array([])),
            ("transcript_hash", .string(Notes.transcriptHash(utterances))),
        ]))
        return paths
    }

    /// A temporary root with its stores; Valerie's recording is `anna`'s counterpart, `timo` the importer's recordings.
    struct Root {
        let t = TempFolder("exchange-import")
        let stores: StorePaths
        var mine: URL { t.url.appendingPathComponent("timo", isDirectory: true) }

        init() { stores = StorePaths(configDir: t.url.appendingPathComponent("cfg/palaver"), home: t.url) }

        var bank: VoiceBank { VoiceBank(directory: stores.voices) }

        func export(_ paths: RecordingPaths, _ name: String, voices: Bool = false, audio: Bool = false,
                    confirmLocal: Bool = false, projects: [String] = []) throws -> URL {
            try Exchange.exportMeeting(paths, dest: t.url.appendingPathComponent(name), userName: SENDER, voices: voices,
                                       audio: audio, confirmLocal: confirmLocal, projects: projects, stores: stores)
        }

        /// The `exported` fixture: Valerie's recording, exported.
        func exported() throws -> URL { try export(try makeMeeting(t.url.appendingPathComponent("valerie")), "out/budget.zip") }

        @discardableResult
        func importInto(_ root: URL, _ file: URL, separate: Bool = false, calendar: CalendarProvider? = nil,
                        after: ((String) throws -> Void)? = nil,
                        freeBytes: (URL) throws -> Int = Exchange.freeBytes) throws -> ExchangeImported {
            try Exchange.importPackage(root, file, userName: ME, separate: separate, calendar: calendar, after: after,
                                       stores: stores, timeZone: berlin, freeBytes: freeBytes)
        }

        func here(_ id: String = ID) -> RecordingPaths { RecordingPaths(mine.appendingPathComponent(id, isDirectory: true)) }

        /// `rejected`: the file is refused with `match` in the message, and nothing is written, no staging left.
        func rejected(_ file: URL, _ match: String, freeBytes: (URL) throws -> Int = Exchange.freeBytes,
                      sourceLocation: SourceLocation = #_sourceLocation) throws {
            let root = t.url.appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            do {
                try importInto(root, file, freeBytes: freeBytes)
                Issue.record("imported, want \(match)", sourceLocation: sourceLocation)
            } catch let e as ExchangeRejected {
                #expect(e.message.contains(match), "want \(match), got \(e.message)", sourceLocation: sourceLocation)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [], sourceLocation: sourceLocation)
        }

        /// `repack`: `src` with entries changed (nil: left out), checksums made to fit (`fix`), the manifest changed,
        /// and raw extra entries after the rest.
        func repack(_ src: URL, _ name: String, change: [String: Data?] = [:], manifest: [(String, JSONValue)] = [],
                    fix: Bool = true, extra: [(String, Data)] = []) throws -> URL {
            let zip = try ZipReader(url: src, maxDirectoryBytes: 1 << 20)
            var files = PyDict<Data>()
            var man = PyDict<JSONValue>()
            for entry in zip.entries {
                let data = try zip.data(entry, limit: 1 << 24)
                if entry.name == "manifest.json" { man = PyDict(try PythonJSON.parse(data))! } else { files[entry.name] = data }
            }
            var listed = PyDict<JSONValue>(man["files"]!)!
            for (name, data) in change {
                if let data { files[name] = data } else { files[name] = nil; listed[name] = nil }
            }
            if fix {
                listed = PyDict(files.map { ($0.key, .object([("sha256", .string(sha256Hex($0.value))), ("bytes", .int($0.value.count))])) })
            }
            man["files"] = listed.json
            for (k, v) in manifest { man[k] = v }
            var b = ZipBuilder()
            b.add("manifest.json", PythonJSON.dumps(man.json))
            for (n, d) in files { b.add(n, d) }
            for (n, d) in extra { b.add(n, d) }
            let dst = t.url.appendingPathComponent(name)
            try b.write(dst)
            return dst
        }

        func remove() { t.remove() }
    }

    static func doc(_ url: URL, _ name: String) throws -> JSONValue {
        let zip = try ZipReader(url: url, maxDirectoryBytes: 1 << 20)
        let entry = try #require(zip.entries.first { $0.name == name })
        return try PythonJSON.parse(try zip.data(entry, limit: 1 << 24))
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The keys of a JSON object file; none when it is missing or no object.
    static func keys(_ url: URL) -> [String] { PythonJSON.read(url).flatMap { PyDict<JSONValue>($0) }?.keys ?? [] }

    // MARK: - import

    /// Ported in part: what the window shows of it (`api.get_meeting`, `list_meetings`) is the server's.
    @Test func test_an_import_is_a_meeting_with_the_names_as_hints_named_by_the_exporter() throws {
        let r = Root(); defer { r.remove() }
        let result = try r.importInto(r.mine, try r.exported())
        #expect(result.id == Self.ID && result.sender == Self.SENDER && result.matched == nil)
        let here = r.here()
        #expect(MeetingStatus.status(here) == "processed")
        #expect(Titles.resolve(here, stores: r.stores).title == "Budget review")
        let inferred = Inference.load(here)
        let tom = try #require(inferred["SPEAKER_00"])
        #expect(tom["name"] == .string("Timo Strauß") && tom["rule"] == .string("imported") && tom["by"] == .string(Self.SENDER))
        #expect(tom["why"] == .string("Named by Valerie in their recording."))
        #expect(inferred["SPEAKER_04"]?["name"] == .string(Self.SENDER) && inferred["SPEAKER_04"]?["how"] == .string("exporter"))
        #expect(result.names.keys == ["SPEAKER_00", "SPEAKER_01", "SPEAKER_04"])
        #expect(result.names.values == ["Timo Strauß", "Carla", Self.SENDER])
        // The transcript shows the hinted names; nothing is named by the user.
        let lines = try #require(PythonJSON.read(here.transcriptJson)?.arrayValue)
        #expect(lines.prefix(2).map { $0["speaker"]?.stringValue } == [Self.SENDER, "Timo Strauß"])
        #expect(lines.prefix(2).map { $0["label"]?.stringValue } == ["SPEAKER_04", "SPEAKER_00"])
        #expect(try Speakers.loadSpeakerNames(here).isEmpty)
        // The notes are of this transcript: not out of date.
        let notes = try #require(NotesFile.load(here))
        #expect(notes["transcript_hash"] == .string(Notes.transcriptHash(try lines.map { try Utterance(json: $0) })))
        #expect(notes["summary"] == .string("SPEAKER_00 presented the budget."))
        #expect(ExchangeHints.loadRecord(here)?["from"] == .string(Self.SENDER))
        let event = try #require(CalendarEvents.load(here))
        #expect(event.title == "Budget review" && CalendarEvents.loadLink(here)?.source == "imported")
        #expect(!Self.exists(r.mine.appendingPathComponent(".importing")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: r.mine.path) == [Self.ID])
        #expect(!Self.exists(here.speakerEmbeddings) && !Self.exists(here.importedVoices))
    }

    @Test func test_the_importer_invited_is_themselves_in_the_event() throws {
        let r = Root(); defer { r.remove() }
        try r.importInto(r.mine, try r.exported())
        let event = try #require(CalendarEvents.load(r.here()))
        #expect(event.attendees.filter(\.isSelf).map(\.name) == [Self.ME])
    }

    /// Ported in part: `api.get_meeting`'s `imported.title` is the server's.
    @Test func test_the_exporters_own_title_comes_along_but_is_not_the_users() throws {
        let r = Root(); defer { r.remove() }
        let paths = try Self.makeMeeting(r.t.url.appendingPathComponent("valerie"))
        try Self.write(.object([("title", .string("Budget with Timo Strauß"))]), paths.folder.appendingPathComponent("title.json"))
        try r.importInto(r.mine, try r.export(paths, "x.zip"))
        let here = r.here()
        #expect(Titles.resolve(here, stores: r.stores).title == "Budget with Timo Strauß")
        #expect(Titles.resolve(here, stores: r.stores).source == "imported")
        #expect(Titles.load(here) == nil && Titles.imported(here) == "Budget with Timo Strauß")
        try Titles.save(here, "My budget")
        #expect(Titles.resolve(here, stores: r.stores).title == "My budget" && Titles.resolve(here, stores: r.stores).source == "you")
        try Titles.save(here, "")
        #expect(Titles.resolve(here, stores: r.stores).source == "imported")
    }

    @Test func test_voices_go_into_the_voice_bank_only_after_a_yes() throws {
        let r = Root(); defer { r.remove() }
        let out = try r.export(try Self.makeMeeting(r.t.url.appendingPathComponent("valerie")), "x.zip", voices: true)
        let result = try r.importInto(r.mine, out)
        #expect(PythonJSON.dumps(.array(result.voices)) == PythonJSON.dumps(.array([
            .object([("label", .string("SPEAKER_00")), ("name", .string("Timo Strauß"))]),
            .object([("label", .string("SPEAKER_01")), ("name", .string("Carla"))]),
        ])))
        #expect(try r.bank.names().isEmpty)
        let paths = r.here()
        let learned = try Exchange.decideVoices(paths, add: true, userName: Self.ME, stores: r.stores)
        #expect(Py.stableSorted(learned, by: Py.less) == ["Carla", "Timo Strauß"])
        #expect(Set(try r.bank.names().keys) == ["Timo Strauß", "Carla"])
        #expect(ExchangeHints.loadRecord(paths)?["voices_pending"] == .array([]))
        #expect(ExchangeHints.loadRecord(paths)?["voices"] == .string("added"))
        #expect(Set(Self.keys(paths.speakerEmbeddings)) == ["SPEAKER_00", "SPEAKER_01"])
        #expect(!Self.exists(paths.importedVoices))
    }

    @Test func test_pending_voices_are_kept_apart_where_nothing_reads_them() throws {
        let r = Root(); defer { r.remove() }
        try r.importInto(r.mine, try r.export(try Self.makeMeeting(r.t.url.appendingPathComponent("valerie")), "x.zip", voices: true))
        let paths = r.here()
        #expect(!Self.exists(paths.speakerEmbeddings))
        #expect(Self.keys(paths.importedVoices) == ["SPEAKER_00", "SPEAKER_01"])
    }

    /// `api.name_speaker(…, "SPEAKER_01", "")` is the server's: here its two steps, the name rejected for the voice and
    /// the names saved, then voices recognized again.
    @Test func test_yes_to_the_voices_skips_a_name_the_user_rejected() throws {
        let r = Root(); defer { r.remove() }
        try r.importInto(r.mine, try r.export(try Self.makeMeeting(r.t.url.appendingPathComponent("valerie")), "x.zip", voices: true))
        let paths = r.here()
        try Speakers.setRejectedName(paths, "SPEAKER_01", "Carla")  // "No, not Carla"
        try Speakers.saveSpeakerNames(paths, try Speakers.loadSpeakerNames(paths), stores: r.stores)
        try People.refreshRecognition(outputDir: r.mine, userName: Self.ME, stores: r.stores)
        #expect(try Exchange.decideVoices(paths, add: true, userName: Self.ME, stores: r.stores) == ["Timo Strauß"])
        #expect(try Speakers.loadSpeakerNames(paths)["SPEAKER_01"] == nil)
        #expect(try r.bank.names()["Carla"] == nil)
        #expect(Self.keys(paths.speakerEmbeddings) == ["SPEAKER_00"])
    }

    @Test func test_voices_said_no_to_are_deleted_from_the_meeting() throws {
        let r = Root(); defer { r.remove() }
        try r.importInto(r.mine, try r.export(try Self.makeMeeting(r.t.url.appendingPathComponent("valerie")), "x.zip", voices: true))
        let paths = r.here()
        #expect(try Exchange.decideVoices(paths, add: false, stores: r.stores) == [])
        #expect(!Self.exists(paths.importedVoices) && !Self.exists(paths.speakerEmbeddings))
        #expect(try r.bank.names().isEmpty)
        #expect(ExchangeHints.loadRecord(paths)?["voices"] == .string("declined"))
        #expect(try Exchange.decideVoices(paths, add: true, stores: r.stores) == [])  // asked once
    }

    // MARK: - the same meeting here

    @Test func test_the_same_calendar_occurrence_here_is_a_collision() throws {
        let r = Root(); defer { r.remove() }
        let exported = try r.exported()
        try Self.makeMeeting(r.mine, "2026-10-29T10-01-12", start: "2026-10-29T10:01:12+01:00",
                             event: Self.event(attendees: []), user: Self.ME)
        do {
            try r.importInto(r.mine, exported)
            Issue.record("imported")
        } catch let c as Exchange.Collision {
            #expect(c.match == ExchangeMatch("2026-10-29T10-01-12", "event", true) && c.sender == Self.SENDER)
            #expect(c.description == "2026-10-29T10-01-12 is the same meeting")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: r.mine.path) == ["2026-10-29T10-01-12"])  // nothing written
    }

    @Test func test_another_occurrence_of_the_series_is_no_match() throws {
        let r = Root(); defer { r.remove() }
        let exported = try r.exported()
        try Self.makeMeeting(r.mine, "2026-10-22T10-00-00", start: "2026-10-22T10:00:00+02:00",
                             event: Self.event(start: "2026-10-22T10:00:00+02:00", end: "2026-10-22T10:30:00+02:00", attendees: []),
                             user: Self.ME)
        #expect(try r.importInto(r.mine, exported).matched == nil)
    }

    @Test func test_more_than_half_overlap_and_a_shared_attendee_is_a_collision() throws {
        let r = Root(); defer { r.remove() }
        let exported = try r.exported()
        try Self.makeMeeting(r.mine, "2026-10-29T10-00-20", start: "2026-10-29T10:00:20+01:00",
                             event: Self.event(title: "Budget (my calendar)", uid: "OTHER",
                                               attendees: [Self.attendee("Timo Strauß", "TIMO.S@contoso.example")]),
                             user: Self.ME)
        #expect(throws: Exchange.Collision.self) { try r.importInto(r.mine, exported) }
        let package = try Exchange.readPackage(exported)
        #expect(try Exchange.findMatch(r.mine, package) == ExchangeMatch("2026-10-29T10-00-20", "overlap", true))
    }

    @Test func test_overlap_without_shared_attendees_is_no_match() throws {
        let r = Root(); defer { r.remove() }
        let exported = try r.exported()
        try Self.makeMeeting(r.mine, "2026-10-29T10-00-20", start: "2026-10-29T10:00:20+01:00",
                             event: Self.event(uid: "OTHER", attendees: [Self.attendee("Anna", "anna@northwind.example")]))
        #expect(try r.importInto(r.mine, exported).matched == nil)
    }

    @Test func test_import_as_a_separate_meeting_goes_beside_mine_with_the_same_event() throws {
        let r = Root(); defer { r.remove() }
        let exported = try r.exported()
        try Self.makeMeeting(r.mine, event: Self.event(title: "Budget review (mine)", attendees: []), user: Self.ME)
        let result = try r.importInto(r.mine, exported, separate: true)
        #expect(result.id == "\(Self.ID)-2" && result.matched?.id == Self.ID)
        #expect(CalendarEvents.load(r.here(result.id))?.title == "Budget review (mine)")
        #expect(CalendarEvents.loadLink(r.here(result.id))?.reason == "the event of your own recording")
        #expect(PythonJSON.dumps(ExchangeHints.loadRecord(r.here(result.id))?["beside"] ?? .null)
                == PythonJSON.dumps(.object([("meeting", .string(Self.ID)), ("how", .string("event"))])))
    }

    @Test func test_an_earlier_import_of_it_is_a_collision_that_is_not_mine() throws {
        let r = Root(); defer { r.remove() }
        let exported = try r.exported()
        try r.importInto(r.mine, exported)
        do {
            try r.importInto(r.mine, exported)
            Issue.record("imported twice")
        } catch let c as Exchange.Collision {
            #expect(c.match == ExchangeMatch(Self.ID, "event", false))
        }
    }

    @Test func test_a_calendar_here_links_its_own_copy_of_the_event() throws {
        let r = Root(); defer { r.remove() }
        let mine = try CalendarEvent(json: Self.event(title: "Budget review (Timo's calendar)"))
        var asked: [(Date, Date)] = []
        try r.importInto(r.mine, try r.exported(), calendar: { start, end in asked.append((start, end)); return [mine] })
        #expect(CalendarEvents.load(r.here())?.title == "Budget review (Timo's calendar)")
        let start = try PyDateTime.parse("2026-10-29T10:00:00+01:00").date
        #expect(asked.count == 1 && asked[0].0 == start.addingTimeInterval(-300) && asked[0].1 == start.addingTimeInterval(1800 + 300))
        // A calendar that fails is no reason to fail the import.
        let other = Root(); defer { other.remove() }
        try other.importInto(other.mine, try other.exported(), calendar: { _, _ in throw POSIXError(.EIO) })
        #expect(CalendarEvents.load(other.here())?.title == "Budget review")
    }

    @Test func test_the_exporters_project_is_a_hint_kept_with_the_import() throws {
        let r = Root(); defer { r.remove() }
        let out = try r.export(try Self.makeMeeting(r.t.url.appendingPathComponent("valerie")), "x.zip", projects: ["Northwind"])
        try r.importInto(r.mine, out)
        #expect(ExchangeHints.loadRecord(r.here())?["projects"] == .strings(["Northwind"]))
        #expect(ProjectStore(path: r.stores.projects).ofMeeting(Self.ID).isEmpty)  // sorted here, not taken over
    }

    // MARK: - the file is untrusted (deferred from Task 23)

    @Test func test_an_unknown_format_version_is_rejected_with_a_clear_message() throws {
        let r = Root(); defer { r.remove() }
        try r.rejected(try r.repack(try r.exported(), "x.zip", manifest: [("format", .int(2))]),
                       "format 2; this Palaver reads format 1. Update Palaver")
        try r.rejected(try r.repack(try r.exported(), "y.zip", manifest: [("format", .int(0))]),
                       "This file has format 0; this Palaver reads format 1.")
    }

    @Test func test_a_damaged_manifest_is_rejected() throws {
        let r = Root(); defer { r.remove() }
        let exported = try r.exported()
        let zip = try ZipReader(url: exported, maxDirectoryBytes: 1 << 20)
        let info = try #require(zip.entries.first { $0.name == "manifest.json" })
        var data = [UInt8](try Data(contentsOf: exported))
        let at = Int(info.headerOffset)
        let start = at + 30 + (Int(data[at + 26]) | Int(data[at + 27]) << 8) + (Int(data[at + 28]) | Int(data[at + 29]) << 8)
        for i in start + 5..<start + 25 { data[i] = 0xFF }
        let damaged = r.t.url.appendingPathComponent("x.zip")
        try Data(data).write(to: damaged)
        try r.rejected(damaged, "damaged")
    }

    @Test func test_a_missing_required_file_is_rejected() throws {
        let r = Root(); defer { r.remove() }
        try r.rejected(try r.repack(try r.exported(), "x.zip", change: ["meeting/turns.json": nil]), "lacks 'meeting/turns.json'")
    }

    @Test func test_a_file_the_manifest_does_not_list_is_rejected() throws {
        let r = Root(); defer { r.remove() }
        let out = try r.repack(try r.exported(), "x.zip", change: ["meeting/notes.json": nil], fix: false,
                               extra: [("meeting/notes.json", Data("{}".utf8))])
        try r.rejected(out, "'meeting/notes.json' is not listed")
    }

    @Test func test_a_voice_of_someone_not_named_is_rejected() throws {
        let r = Root(); defer { r.remove() }
        let voice = JSONValue.object([("label", .string("SPEAKER_00")), ("name", .string("Anna")),
                                      ("embedding", .array(Self.vector(5).map { .double($0) }))])
        try r.rejected(try r.repack(try r.exported(), "x.zip", change: ["voices/SPEAKER_00.json": Data(PythonJSON.dumps(voice).utf8)]),
                       "voices/SPEAKER_00.json is not the voice of a person named in speakers.json.")
    }

    @Test func test_times_outside_the_meeting_are_rejected() throws {
        let r = Root(); defer { r.remove() }
        let turns = Data(#"[{"speaker": "SPEAKER_00", "start": 1, "end": 5000}]"#.utf8)
        try r.rejected(try r.repack(try r.exported(), "x.zip", change: ["meeting/turns.json": turns]),
                       "turns.json[0] is not within the meeting.")
    }

    @Test func test_a_zip_unpacked_and_compressed_again_in_finder_imports() throws {
        let r = Root(); defer { r.remove() }
        let out = try r.export(try Self.makeMeeting(r.t.url.appendingPathComponent("valerie"), audio: 2), "x.zip",
                               voices: true, audio: true)
        let again = try ZipTests.inFolder(out, r.t.url.appendingPathComponent("again.zip"), "2026-10-29 Q3 budget plan")
        let result = try r.importInto(r.mine, again)
        #expect(result.id == Self.ID && result.sender == Self.SENDER && result.voices.count == 2)
        #expect(Self.exists(r.here().systemWav))  // the audio, read under the folder
    }

    @Test func test_a_folder_compressed_by_finder_imports() throws {
        let r = Root(); defer { r.remove() }
        let out = try r.export(try Self.makeMeeting(r.t.url.appendingPathComponent("valerie"), audio: 2), "x.zip", audio: true)
        let unpacked = r.t.url.appendingPathComponent("unpacked/2026-10-29 Q3 budget plan")
        func run(_ tool: String, _ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "\(tool) \(args)")
        }
        try run("/usr/bin/ditto", ["-x", "-k", out.path, unpacked.path])
        try Data([0, 0, 0, 1] + Array("Bud1".utf8)).write(to: unpacked.appendingPathComponent(".DS_Store"))
        // An attribute becomes a ._ file in __MACOSX/.
        try run("/usr/bin/xattr", ["-w", "com.apple.metadata:kMDItemWhereFroms", "x", unpacked.appendingPathComponent("manifest.json").path])
        let again = r.t.url.appendingPathComponent("again.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", unpacked.path, again.path])
        let names = try ZipReader(url: again, maxDirectoryBytes: 1 << 20).entries.map(\.name)
        #expect(names.contains { $0.hasPrefix("__MACOSX/") })
        #expect(try r.importInto(r.mine, again).id == Self.ID)
    }

    // MARK: - voices and what follows

    @Test func test_voices_of_another_size_than_here_are_left_out_and_said_so() throws {
        let r = Root(); defer { r.remove() }
        let valerie = try Self.makeMeeting(r.t.url.appendingPathComponent("valerie"), size: 128)  // 128, here 64
        let out = try r.export(valerie, "x.zip", voices: true)
        try Self.makeMeeting(r.mine, "2026-10-01T10-00-00", start: "2026-10-01T10:00:00+01:00", event: nil, user: Self.ME)
        try r.bank.add("Anna", Array(repeating: 1.0, count: 64), source: "x:1")
        let result = try r.importInto(r.mine, out)
        #expect(result.voices.isEmpty)
        #expect(result.warnings == ["2 voices were left out: they were made by another voice model than this Mac's."])
        #expect(!Self.exists(r.here().importedVoices))
        #expect(ExchangeHints.loadRecord(r.here())?["voices_pending"] == .array([]))
        try People.refreshRecognition(outputDir: r.mine, userName: Self.ME, stores: r.stores)  // nothing here it can't compare
    }

    @Test func test_an_import_whose_follow_up_fails_is_taken_out_again() throws {
        let r = Root(); defer { r.remove() }
        struct Broken: Error {}
        let exported = try r.exported()
        var called: [String] = []
        #expect(throws: Broken.self) {
            try r.importInto(r.mine, exported, after: { called.append($0); throw Broken() })
        }
        #expect(called == [Self.ID])
        #expect(!Self.exists(r.here().folder) && !Self.exists(r.mine.appendingPathComponent(".importing")))
        #expect(Self.exists(r.mine.appendingPathComponent(".trash/\(Self.ID)/transcript.json")))
    }

    /// Without voices of a known size here, the size most of the file's voices have; a voice of another one is left
    /// out (`fitting_voices`).
    @Test func voicesFitTheSizeMostOfThemHaveWhenNothingIsHere() throws {
        let r = Root(); defer { r.remove() }
        func voice(_ n: Int) -> JSONValue { .object([("embedding", .array(Array(repeating: .double(0.5), count: n)))]) }
        let voices = PyDict<JSONValue>([("SPEAKER_00", voice(32)), ("SPEAKER_01", voice(16)), ("SPEAKER_02", voice(16))])
        let (kept, out) = try Exchange.fittingVoices(r.mine, voices, bank: r.bank)
        #expect(kept.keys == ["SPEAKER_01", "SPEAKER_02"] && out == 1)
        try r.bank.add("Anna", Array(repeating: 1.0, count: 32), source: "x:1")
        let (fit, left) = try Exchange.fittingVoices(r.mine, voices, bank: r.bank)
        #expect(fit.keys == ["SPEAKER_00"] && left == 2)
    }

    /// `settle`: no rule fits, so the exporter's project of the same name here is a suggestion (by "auto").
    @Test func settlingFilesAnImportUnderTheSendersProjectOfThatName() throws {
        let r = Root(); defer { r.remove() }
        let store = ProjectStore(path: r.stores.projects)
        store.makeId = { "4e6f7274" }
        let pid = try store.locked { () throws -> String in
            store.reload()
            let pid = try store.create("Northwind", description: "")
            try store.save()
            return pid
        }
        let out = try r.export(try Self.makeMeeting(r.t.url.appendingPathComponent("valerie")), "x.zip", projects: ["Contoso", "northwind "])
        try r.importInto(r.mine, out)
        try Exchange.settle(r.mine, Self.ID, userName: Self.ME, stores: r.stores)
        let assigned = ProjectStore(path: r.stores.projects).ofMeeting(Self.ID)
        #expect(PythonJSON.dumps(assigned.json) == PythonJSON.dumps(.object([(pid, .object([
            ("by", .string("auto")), ("why", .string("Valerie filed it under northwind ")), ("confidence", .double(0.6))]))])))
        #expect(Exchange.confirmedProjects(Self.ID, stores: r.stores) == [])
    }

    /// The file's start on this Mac's clock names the folder; a taken name gets `-2`.
    @Test func theFolderIsNamedByTheStartOnThisMacsClock() throws {
        let r = Root(); defer { r.remove() }
        let start = try JSONSchemaCheck.time("2026-10-29T09:00:00.75Z", where: "x")
        try FileManager.default.createDirectory(at: r.mine.appendingPathComponent("2026-10-29T10-00-00"), withIntermediateDirectories: true)
        #expect(Exchange.newFolder(r.mine, start, timeZone: Self.berlin) == "2026-10-29T10-00-00-2")
        #expect(Exchange.newFolder(r.mine, start, timeZone: TimeZone(identifier: "America/New_York")!) == "2026-10-29T05-00-00")
    }

    // MARK: - against Python

}
