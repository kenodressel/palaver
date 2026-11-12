// The meeting page (api.py:332-472, :680-892): a finished meeting as the window shows it — its title and
// calendar event, the speakers with their names and how they got them, the transcript as read, the notes
// with names, what was recorded and what went wrong, the neighbours to join with, the suggestions, the
// projects — and each person's organization. A meeting being recorded goes to `LivePage.meeting`.
import Foundation
import PalaverCore
import PalaverDomain

extension MeetingsAPI {
    /// api.get_meeting. `calendar` false: `calendar=None` (server.py's `/speakers`, `/merge` and `/remove` answers):
    /// the cut suggestion reads the neighbours' stored events, not `app.calendar`.
    public static func getMeeting(app: ServerApp, id: String, calendar: Bool = true) throws -> JSONValue {
        let paths = try meetingPaths(outputDir: app.outputDir, id: id)
        let page = exists(paths.live) && state(paths) == "recording"
            ? try LivePage.meeting(app: app, paths: paths)
            : try meeting(app, paths, id, calendar: calendar)
        return try withOrgs(page, app).json
    }

    /// `_meeting`: the finished shape.
    static func meeting(_ app: ServerApp, _ paths: RecordingPaths, _ id: String, calendar useCalendar: Bool = true) throws -> PyDict<JSONValue> {
        let userName = app.userName
        let meta = try meta(paths)
        let names = try Speakers.namesInEffect(paths)
        let display = try displayNames(paths)
        let raw = try Speakers.withoutIgnored(paths, try utterances(paths))
        let glossary = Glossary.current(stores: app.stores)
        let utterances = Readable.readable(Speakers.applySpeakerNames(raw, display), glossary: glossary)
        let merges = Speakers.loadMerges(paths)

        /// The speaker lane an utterance belongs to; nil for the user.
        func lane(_ u: Utterance) -> String? {
            let label = u.label.flatMap { $0.isEmpty ? nil : $0 } ?? (Py.same(u.speaker, userName) ? nil : u.speaker)
            guard let label, !label.isEmpty else { return nil }
            return merges[label] ?? label
        }

        let notes = Notes.load(paths)
        let event = CalendarEvents.load(paths)
        let stale = !raw.isEmpty && notes != nil ? Notes.staleReason(paths, raw) : nil
        let mic = SharedMic.micDisplay(paths)  // the room's, while several people sat at the microphone (#56)

        /// The voice a corrected line was heard as (#12): its lane (null: the user's microphone) and what that shows.
        func fixed(_ u: Utterance) -> JSONValue {
            guard let heardAs = u.heardAs else { return .null }
            let heard = heardAs.label.map { merges[$0] ?? $0 }
            let was: String
            if let heard {
                was = display[heard].flatMap { $0.isEmpty ? nil : $0 } ?? labelDisplay(heard)
            } else {
                was = mic.flatMap { $0.isEmpty ? nil : $0 } ?? userName
            }
            return .object([("was", .string(was)), ("from", .str(heard))])
        }
        let (title, titleFrom) = Titles.resolve(paths, event: .known(event), meetingNotes: .known(notes), stores: app.stores)
        let status = state(paths)
        let used = Set(names.values.map(ScalarKey.init))
        let transcript: [JSONValue] = utterances.map { u in
            let l = lane(u)
            let shownMic = mic.flatMap { $0.isEmpty ? nil : $0 }
            return .object([
                ("speaker", .string(shownMic != nil && l == nil ? shownMic! : u.speaker)),
                ("label", .str(l)),
                ("start", .double(Py.round(u.start, 2))),
                ("end", .double(Py.round(u.end, 2))),
                ("text", .string(u.text)),
                ("glossed", glossed(u)),
                ("edited", .bool(u.heard != nil)),
                ("heard", .str(u.heard)),
                ("unsure", .strings(u.heard != nil ? [] : u.unsure)),
                ("fixed", fixed(u)),
                ("track", .string(u.heardAs?.track ?? (l == nil ? "mic" : "others"))),
            ])
        }
        // A typed literal: untyped, the type checker gives up on a slower Mac (CI).
        let fields: [(String, JSONValue)] = [
            ("id", .string(id)),
            ("title", .str(title)),
            ("title_from", .str(titleFrom)),
            ("calendar", try calendar(app, event, used: used, link: CalendarEvents.loadLink(paths))),
            ("event_question", eventQuestion(paths)),
            // The calendar is on: a meeting without an event offers to pick one (#30).
            ("calendar_on", .bool(app.calendar != nil)),
            ("start", try start(paths, meta)),
            ("duration", meta["duration_seconds"] ?? .null),
            ("status", .string(status)),
            ("finishing", .bool(finishing(paths, status))),
            // Not transcribed (failed.json): why, for Transcribe Again; "failure" below is the log's, for a report.
            ("untranscribed", exists(paths.transcriptJson) ? .null : ProcessState.read(paths) ?? .null),
            // The notes model wrote from the transcript as heard: spell names right.
            ("notes", notes.map { n -> JSONValue in n.truthy ? glossary.applyTo(Notes.withNames(n, display)) : .null } ?? .null),
            ("notes_stale", .bool(stale != nil)),
            ("notes_stale_reason", .str(stale)),
            // Written with the user's own notes in the prompt (#44): an export asks before they go (#58).
            ("notes_from_my_notes", .bool(try get(notes, "my_notes_hash").truthy)),
            ("my_notes_revision", .string(MyNotes.revision(paths.folder))),
            ("speakers", .array(try speakers(app, paths, names: names, display: display, utterances: raw, notes: notes))),
            ("transcript", .array(transcript)),
            ("has_audio", .bool(exists(paths.systemWav))),
            ("audio_deleted", Storage.deleted(paths) ?? .null),  // #9: its transcript stays, the audio went
            ("reviewed", try get(PythonJSON.read(paths.review) ?? .object([]), "reviewed")),
            ("local_only", .bool(exists(paths.localOnly))),
            ("imported", try imported(paths)),
            ("transcribed_by", transcribedBy(paths)),
            ("failure", lastFailure(paths) ?? .null),  // a failed run, offered for a report (#59)
            ("neighbours", try neighbours(app, paths)),
            ("cut_suggestion", cutSuggestion(app, paths, status, calendar: useCalendar)),
            ("silence", status == "ready" ? .array(try Cutting.suggestTrim(paths)) : .array([])),
            ("shared", shared(app, paths, event)),
            ("shared_suggestion", try SharedMic.suggestion(paths, event: event, userName: userName)
                .map { why -> JSONValue in .object([("why", .string(why))]) } ?? .null),
            ("removed", .array(Speakers.loadIgnored(paths).map { label -> JSONValue in
                .object([("label", .string(label)), ("display", .string(labelDisplay(label)))])
            })),
        ]
        var page = PyDict<JSONValue>(fields)
        for (k, v) in try recorded(paths, meta) { page[k] = v }
        for (k, v) in try meetingProjects(app, id) { page[k] = v }
        return page
    }

    /// `_glossed`: where the glossary respelled a line: [start, end, the variant heard].
    static func glossed(_ u: Utterance) -> JSONValue {
        .array(u.glossed.map { .array([.int($0.start), .int($0.end), .string($0.heard)]) })
    }

    // MARK: - speakers

    /// `_speakers`: the user's lane (none in an imported meeting the user said nothing in, #58), then each voice by
    /// talk time: its name and how it got it, what the notes and similar voices suggest, and its clips to listen to.
    static func speakers(_ app: ServerApp, _ paths: RecordingPaths, names: PyDict<String>, display: PyDict<String>,
                         utterances: [Utterance], notes: JSONValue?) throws -> [JSONValue] {
        let userName = app.userName
        let turns = try turns(paths)
        let talk = Speakers.talkSeconds(turns)
        let merges = Speakers.loadMerges(paths)
        let recognized = try Speakers.loadRecognizedNames(paths)
        let inferred = Inference.load(paths)
        let manual = try Speakers.loadSpeakerNames(paths)
        let rejected = Speakers.loadRejectedNames(paths)
        var guesses = PyDict<[JSONValue]>()
        let said = try get(notes, "speaker_names")
        let offered = said.isNull ? [] : try iterate(said)
        for g in Notes.backedNameGuesses(offered, utterances, glossary: Glossary.current(stores: app.stores)) {
            guard case .string(let label) = try key(g, "label") else { continue }  // never a lane's label
            guesses[label] = (guesses[label] ?? []) + [.object([("name", try key(g, "name")), ("evidence", try key(g, "evidence"))])]
        }
        let spoken = Set(utterances.map { u -> ScalarKey in
            let who = u.label.flatMap { $0.isEmpty ? nil : $0 } ?? u.speaker
            return ScalarKey(merges[who] ?? who)
        })
        let maybe = try People.suggestions(paths, stores: app.stores)
        let shared = SharedMic.display(paths)
        let rooms = SharedMic.roomNames(paths)

        let mic = SharedMic.micRoom(paths)  // several people at the user's microphone (#56)
        let mine = utterances.filter { Py.same($0.speaker, userName) && ($0.label ?? "").isEmpty }
        // An imported meeting the user said nothing in has no lane of theirs (#58).
        let you = !exists(paths.imported) || !mine.isEmpty
        let hasAudio = exists(paths.systemWav)
        var out: [JSONValue] = []
        if you {
            let seconds: JSONValue = mine.isEmpty ? .int(0) : .double(Py.round(Py.sum(mine.map { $0.end - $0.start }), 1))
            out.append(.object([
                ("label", .null),
                ("name", .string(userName)),
                ("display", mic == nil ? .string(userName) : .str(SharedMic.micDisplay(paths))),
                ("is_user", .bool(true)),
                ("shared", mic == nil ? .null : .string(SharedMic.load(paths)["mic"] != nil ? "mic" : "meeting")),
                ("room", .string(mic ?? "")),
                ("talk_seconds", seconds),
                ("clips", .array([])),
            ]))
        }
        let ignored = Set(Speakers.loadIgnored(paths).map(ScalarKey.init))
        let unknown = Set(Speakers.loadUnknown(paths).map(ScalarKey.init))
        let byTalk = Py.stableSorted(talk.keys) { talk[$0]! > talk[$1]! }
        func merged(into label: String) -> JSONValue {
            .array(Py.stableSorted(merges.keys, by: Py.less).filter { Py.same(merges[$0]!, label) }.map {
                .object([("label", .string($0)), ("display", .string(labelDisplay($0)))])
            })
        }
        for label in byTalk {
            guard spoken.contains(ScalarKey(label)), !ignored.contains(ScalarKey(label)) else { continue }
            let own = Py.stableSorted(turns.filter { Py.same($0.speaker, label) }) { $0.start - $0.end < $1.start - $1.end }
            let clips: [JSONValue] = hasAudio
                ? Py.stableSorted(Array(own.prefix(CLIPS_PER_SPEAKER))) { $0.start < $1.start }.map {
                    .object([("start", .double($0.start)), ("end", .double(min($0.end, $0.start + CLIP_SECONDS)))])
                }
                : []
            let seconds = JSONValue.double(Py.round(talk[label]!, 1))
            guard let shown = display[label] else { throw PageError(Py.repr(.string(label))) }
            if shared[label] != nil {  // several people: no name, no guess (#56)
                out.append(.object([
                    ("label", .string(label)), ("name", .null), ("display", .string(shown)),
                    ("is_user", .bool(false)),
                    ("shared", .string(SharedMic.meetingMarked(paths) ? "meeting" : "room")),
                    ("room", .string(rooms[label] ?? "")),
                    ("named_by", .null), ("link", .null), ("rejected", .array([])), ("recognized", .null),
                    ("inferred", .null), ("guesses", .array([])), ("maybe", .array([])), ("talk_seconds", seconds),
                    ("merged", merged(into: label)),
                    ("clips", .array(clips)),
                ]))
                continue
            }
            let auto = recognized[label]
            var guess: JSONValue? = manual[label] == nil && auto == nil ? inferred[label] : nil
            let notThem = Set((rejected[label] ?? []).map { ScalarKey(Py.casefold($0)) })
            if let g = guess, g.truthy {
                let name = try get(g, "name")
                if notThem.contains(ScalarKey(Py.casefold(name.stringValue ?? ""))) { guess = nil }  // "Not Carla"
            }
            let guessed = guess.map(\.truthy) ?? false
            let namedBy: String?
            if let given = manual[label], !Py.same(given, label) {
                namedBy = "you"
            } else if auto != nil && manual[label] == nil {
                namedBy = "voice"
            } else {
                namedBy = guessed ? "inferred" : nil
            }
            var inferredShown: JSONValue = .null
            if guessed, let g = guess {
                inferredShown = .object([("rule", try key(g, "rule")), ("why", try key(g, "why")),
                                         ("confidence", try key(g, "confidence")), ("by", g["by"] ?? .null),
                                         ("how", g["how"] ?? .null)])
            }
            out.append(.object([
                ("label", .string(label)),
                ("name", .str(names[label])),
                ("display", .string(shown)),
                ("is_user", .bool(false)),
                ("named_by", .str(namedBy)),
                ("link", try speakerLink(names[label], namedBy, auto, guessed ? guess : nil)),
                ("rejected", .strings(rejected[label] ?? [])),
                ("recognized", auto.map { .object([("name", .string($0.0)), ("similarity", .double(Py.round($0.1, 2)))]) } ?? .null),
                ("inferred", inferredShown),
                ("guesses", .array((guesses[label] ?? []).filter { !notThem.contains(ScalarKey(Py.casefold($0["name"]?.stringValue ?? ""))) })),
                ("maybe", .array((maybe[label] ?? []).map { .object([("name", .string($0.0)), ("similarity", .double($0.1))]) })),
                ("talk_seconds", seconds),
                ("merged", merged(into: label)),
                ("shared", .null),
                ("unknown", .bool(unknown.contains(ScalarKey(label)))),  // "Don't Know Who This Is": no to-do while unnamed
                ("clips", .array(clips)),
            ]))
        }
        return out
    }

    /// `_speaker_link`: how a lane got its name, for the window: by you, by voice, inferred.
    static func speakerLink(_ name: String?, _ namedBy: String?, _ auto: (String, Double)?, _ guess: JSONValue?) throws -> JSONValue {
        guard let name, !name.isEmpty, let namedBy else { return .null }
        if namedBy == "voice", let auto {
            let percent = try Py.roundInt(auto.1 * 100)
            return Link("speaker", name, "voice", Py.round(auto.1, 2), "voice \(percent)% alike").toDict()
        }
        if namedBy == "inferred", let guess {
            return Link.from(kind: "speaker", target: name, .object([
                ("source", .string("inferred")), ("confidence", guess["confidence"] ?? .null), ("reason", guess["why"] ?? .null),
            ])).toDict()
        }
        return Link("speaker", name, "you").toDict()
    }

    // MARK: - the calendar event

    /// `_calendar`: the event's title and people; `invited`: invitees (as names already in use where they resolve)
    /// not yet given to a speaker of this meeting.
    static func calendar(_ app: ServerApp, _ event: CalendarEvent?, used: Set<ScalarKey>, link: Link?) throws -> JSONValue {
        guard let event else { return .null }
        var attendees: [JSONValue] = [], seen = Set<ScalarKey>()
        for a in event.attendees where !a.isRoom && !a.isSelf {
            guard seen.insert(ScalarKey(Py.casefold(a.name))).inserted else { continue }
            attendees.append(.object([("name", .string(a.name)), ("organizer", .bool(a.organizer)), ("response", .string(a.response))]))
        }
        let known = try bankNames(app)
        var invited: [String] = []
        for a in CalendarEvents.candidates(event, userName: app.userName) {
            let found = CalendarEvents.resolve(a.name, known)
            let name = found.flatMap { $0.isEmpty ? nil : $0 } ?? a.name
            if !used.contains(ScalarKey(name)) && !invited.contains(where: { Py.same($0, name) }) { invited.append(name) }
        }
        return .object([
            ("title", .string(event.title)),
            ("attendees", .array(attendees)),
            ("invited", .strings(invited)),
            ("link", (link ?? Link("event", event.title)).toDict()),
        ])
    }

    static func eventChoice(_ e: CalendarEvent, key: String, current: CalendarEvent? = nil) -> JSONValue {
        .object([("key", .string(key)), ("title", .string(e.title)), ("start", .string(e.start.iso)),
                 ("end", .string(e.end.iso)), ("invited", .int(e.attendees.count)), ("current", .bool(current.map { EventsAPI.same(e, $0) } ?? false))])
    }

    /// `_event_question`: which event, when several overlapped the recording — asked, not guessed.
    static func eventQuestion(_ paths: RecordingPaths) -> JSONValue {
        guard let question = CalendarEvents.loadQuestion(paths), !question.isEmpty else { return .null }
        return .object([
            ("reason", .string("\(question.count) events overlapped the recording")),
            ("choices", .array(question.enumerated().map { i, e in eventChoice(e, key: e.key.isEmpty ? "question|\(i)" : e.key) })),
        ])
    }

    /// `_bank_names`: the names the voice bank knows; invitees resolve to these ("Freddy").
    static func bankNames(_ app: ServerApp) throws -> [String] {
        try VoiceBank(directory: app.stores.voices).names().keys
    }

    // MARK: - organizations

    /// `_with_orgs`: each speaker's and invitee's organization ("Stefan D (Extern)").
    static func withOrgs(_ meeting: PyDict<JSONValue>, _ app: ServerApp) throws -> PyDict<JSONValue> {
        let index = Orgs.peopleIndex(outputDir: app.outputDir)
        let orgs = Organizations(path: app.stores.organizations)
        func linked(_ link: Link?, _ org: String?) -> JSONValue {
            guard let link, let org, Py.same(link.target, org) else { return .null }
            return link.toDict()
        }
        var page = meeting
        if let speakers = page["speakers"]?.arrayValue {
            page["speakers"] = .array(try speakers.map { s in
                guard var d = PyDict<JSONValue>(s) else { throw PageError("a speaker is no object") }
                let name = d["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                let isUser = d["is_user"]?.truthy ?? false
                let org = isUser ? Orgs.ownOrg(index, orgs, userName: app.userName) : name.flatMap { Orgs.orgOf($0, index, orgs) }
                d["org"] = .str(org)
                d["org_link"] = linked(name != nil && !isUser ? Orgs.orgLink(name!, index, orgs) : nil, org)
                return d.json
            })
        }
        if var calendar = page["calendar"].flatMap({ PyDict<JSONValue>($0) }), let attendees = calendar["attendees"]?.arrayValue {
            calendar["attendees"] = .array(try attendees.map { a in
                guard var d = PyDict<JSONValue>(a), let name = d["name"]?.stringValue else { throw PageError("an attendee is no object") }
                let org = Orgs.orgOf(name, index, orgs)
                d["org"] = .str(org)
                d["org_link"] = linked(Orgs.orgLink(name, index, orgs), org)
                return d.json
            })
            page["calendar"] = calendar.json
        }
        return page
    }

    // MARK: - how it was recorded

    /// `_recorded`: how the recording started and stopped, where it paused (#47), and when its audio went wrong (#50).
    static func recorded(_ paths: RecordingPaths, _ meta: JSONValue) throws -> [(String, JSONValue)] {
        guard case .string(let iso)? = meta["start_time"], let start = WallTime.parse(iso, .current) else {
            return [("recorded", .null), ("gaps", .array([])), ("audio_problems", .array([]))]
        }
        let zone = Lifecycle.offsetZone(iso) ?? .current  // `start + timedelta(...)` keeps the start's own offset
        let recorded = Lifecycle.recordedText(meta, continued: exists(paths.parts), timeZone: .current)
        func listed(_ key: String) throws -> [JSONValue] {
            guard let v = meta[key], v.truthy else { return [] }
            return try iterate(v)
        }
        let gaps: [JSONValue] = try listed("gaps").map { g in
            .object([("start", try key(g, "start")), ("end", try key(g, "end")),
                     ("text", .string(try Lifecycle.gapText(g, start: start, timeZone: zone)))])
        }
        let problems: [JSONValue] = try listed("audio_problems").map { p in
            .object([("start", try key(p, "start")), ("end", p["end"] ?? .null),
                     ("text", .string(Lifecycle.problemText(p, start: start, timeZone: zone)))])
        }
        return [("recorded", .str(recorded)), ("gaps", .array(gaps)), ("audio_problems", .array(problems))]
    }

    /// api.last_failure: the meeting's last run that failed and was not done right since, from its session.log
    /// (#59): transcribing (`{"step": "process"}`) or writing the notes (`{"step": "notes"}`), with what it said;
    /// nil when all went well.
    public static func lastFailure(_ paths: RecordingPaths) -> JSONValue? {
        guard let data = try? Data(contentsOf: paths.sessionLog) else { return nil }
        var failed = PyDict<JSONValue>()
        var running: String?  // the run the lines belong to: process or notes (others, e.g. live, are not shown)
        func cut(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.prefix(300))) }
        func failure(_ step: String, _ error: String, _ row: JSONValue) -> JSONValue {
            .object([("step", .string(step)), ("error", .string(cut(error))), ("at", row["ts"] ?? .null)])
        }
        for line in ModelJobs.splitlines(String(decoding: data, as: UTF8.self)) {
            if !line.contains("\"event\"") && !line.contains("\"ERROR\"") { continue }
            guard let row = try? PythonJSON.parse(Data(line.utf8)), case .object = row else { continue }
            let name = row["event"]?.stringValue
            if name == "process_start" || name == "notes_start" {
                running = String(name!.dropLast(6))
                failed[running!] = nil
            } else if ["live_start", "stream_start", "record_start", "notion_upload_start"].contains(name ?? "") {
                running = nil
            } else if name == "notes_failed" {
                let error = row["error"].flatMap { $0.truthy ? Py.str($0) : nil } ?? ""
                failed["notes"] = failure("notes", error, row)
            } else if name == "process_done", let rc = row["rc"], !(rc.isNull || rc == .int(0) || rc == .bool(false)) {
                failed["process"] = failure("process", "exit code \(Py.str(rc))", row)
            } else if row["level"]?.stringValue == "ERROR", row["message"]?.stringValue == "command failed", let step = running {
                let traceback = row["traceback"].flatMap { $0.truthy ? Py.str($0) : nil } ?? ""
                let lines = ModelJobs.splitlines(traceback).filter { !Py.strip($0).isEmpty }
                failed[step] = failure(step, lines.last.map(Py.strip) ?? "it stopped", row)
            }
        }
        return failed["process"] ?? failed["notes"]
    }

    /// `_transcribed_by`: who transcribed the system track (#54), with the services' names; null: not said.
    static func transcribedBy(_ paths: RecordingPaths) -> JSONValue {
        guard let system = TranscriptionMarker.read(paths)["system"], var out = PyDict<JSONValue>(system) else { return .null }
        let labels = ModelChoice.providerLabels
        for (key, label) in [("engine", "label"), ("fallback_from", "fallback_label")] {
            if let id = out[key]?.stringValue, let name = labels[id] { out[label] = .string(name) }
        }
        return out.json
    }

    /// `_imported`: what the page says about an import — from whom, when, the exporter's projects (a hint) and the
    /// voices waiting for a yes.
    static func imported(_ paths: RecordingPaths) throws -> JSONValue {
        guard let record = ExchangeHints.loadRecord(paths), record.truthy else { return .null }
        var hinted = PyDict<JSONValue>()
        for (label, hint) in ExchangeHints.hints(paths) { hinted[label] = try key(hint, "name") }
        func listed(_ key: String) throws -> [JSONValue] {
            guard let v = record[key], v.truthy else { return [] }
            return try iterate(v)
        }
        return .object([
            ("from", .string(fromText(record))),
            ("at", record["imported_at"] ?? .null),
            ("title", .str(Titles.imported(paths))),
            ("projects", .array(try listed("projects").map { .string(Py.str($0)) })),
            ("beside", try get(record["beside"], "meeting")),
            ("voices", .array(try listed("voices_pending").map { label in
                .object([("label", label), ("name", label.stringValue.flatMap { hinted[$0] } ?? label)])
            })),
        ])
    }

    // MARK: - neighbours, suggestions, sharing, projects

    /// `_neighbours`: the recordings right before and after, to join with.
    static func neighbours(_ app: ServerApp, _ paths: RecordingPaths) throws -> JSONValue {
        let found: (previous: String?, next: String?)
        do { found = try Cutting.neighbours(paths) } catch is CuttingError {
            return .object([("previous", .null), ("next", .null)])
        }
        let any = [found.previous, found.next].contains { !($0 ?? "").isEmpty }
        var listed = PyDict<JSONValue>()
        if any { for m in try listMeetings(app: app) { if let id = m["id"]?.stringValue { listed[id] = m } } }
        func side(_ mid: String?) -> JSONValue {
            guard let mid, !mid.isEmpty else { return .null }
            return .object([("id", .string(mid)), ("title", listed[mid]?["title"] ?? .null), ("start", listed[mid]?["start"] ?? .null)])
        }
        return .object([("previous", side(found.previous)), ("next", side(found.next))])
    }

    /// `_events_during`: calendar events while the recording ran — from the calendar, or else the events stored with
    /// the recordings around it.
    static func eventsDuring(_ app: ServerApp, _ paths: RecordingPaths, calendar useCalendar: Bool = true) throws -> [CalendarEvent] {
        let (start, duration) = try Cutting.span(paths)
        if useCalendar, let calendar = app.calendar, let events = try? calendar(start.date, try start.adding(seconds: duration).date) {
            return events
        }
        let found = try Cutting.neighbours(paths)
        return [found.previous, found.next].compactMap { mid in
            guard let mid, !mid.isEmpty else { return nil }
            return CalendarEvents.load(RecordingPaths(app.outputDir.appendingPathComponent(mid, isDirectory: true)))
        }
    }

    /// `_cut_suggestion`: where a ready meeting seems to run into the next one; null when nothing looks like it, or
    /// what it is made of can't be read.
    static func cutSuggestion(_ app: ServerApp, _ paths: RecordingPaths, _ status: String, calendar: Bool = true) -> JSONValue {
        guard status == "ready" else { return .null }
        return (try? Cutting.suggestCut(paths, events: eventsDuring(app, paths, calendar: calendar))) ?? .null
    }

    /// `_shared`: whether voices here can't be told apart (#56) — the whole meeting, lanes that are rooms, the user's
    /// microphone; `line` is the quiet sentence the page shows while a voice of the meeting is marked.
    static func shared(_ app: ServerApp, _ paths: RecordingPaths, _ event: CalendarEvent?) -> JSONValue {
        .object([
            ("meeting", .bool(SharedMic.meetingMarked(paths))),
            ("rooms", .object(SharedMic.roomNames(paths).map { ($0.key, .string($0.value)) })),
            ("mic", .str(SharedMic.micRoom(paths))),
            ("from_series", .bool(SharedMic.fromSeries(paths))),
            ("line", SharedMic.marked(paths) ? .string(SharedMic.LINE) : .null),
            ("series", .object([("can", .bool(SharedMic.canRemember(event))),
                                ("remembered", .bool(SharedMic.remembered(event, stores: app.stores)))])),
        ])
    }

    /// `_meeting_projects`: the meeting's projects, the ones it might belong to, and every project to choose from.
    static func meetingProjects(_ app: ServerApp, _ id: String) throws -> [(String, JSONValue)] {
        let store = ProjectStore(path: app.stores.projects)
        let every = try ProjectRules.allFacts(outputDir: app.outputDir, userName: app.userName, stores: app.stores)
        var all: [(name: String, row: JSONValue)] = []
        for (pid, project) in store.projects {
            guard case .string(let name) = try key(project, "name") else { throw PageError("a project's name is no text") }
            all.append((name, .object([("id", .string(pid)), ("name", .string(name))])))
        }
        return [
            ("projects", try projectsOf(store, id)),
            ("project_suggestions", .array(ProjectRules.suggestions(id, store: store, every: every))),
            ("all_projects", .array(Py.stableSorted(all) { Py.less(Py.casefold($0.name), Py.casefold($1.name)) }.map(\.row))),
        ]
    }
}

extension Router {
    /// The meeting list and the meeting page (server.py's GET branches).
    static func addMeetingRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/meetings") { _, _ in .json(.array(try MeetingsAPI.listMeetings(app: app))) }
        r.get("/api/meetings/([^/]+)") { _, m in .json(try MeetingsAPI.getMeeting(app: app, id: m.group(1)!)) }
        addLiveRoutes(r, app: app)
        addAudioEventRoutes(r, app: app)
    }
}
