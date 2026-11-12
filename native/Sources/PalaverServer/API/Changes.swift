// What changes a meeting from its page (api.py `set_meeting_event`, `forget_rule`, `_undoable`, `_store_paths`,
// `_after_cut`, `set_title`, `edit_line`, `_rerender`, `trash_meeting`, `split_meeting`, `join_meetings`,
// `delete_audio`, `dismiss_cut`, `mark_reviewed`, `set_local_only`; server.py's POST branches for them).
//
// A change that can be undone runs in `undoable`: a snapshot first (Undo.take), then the change; when it throws,
// the snapshot puts everything back and the error goes on; done, it is sealed and the old snapshots pruned. Where
// api.py holds `_PROJECTS_LOCK`, the change and its rollback hold `app.projectsLock` (in-process locks are always
// taken before any StoreLock; `Undo.restore` takes the store locks itself and is called holding none of those).
import Foundation
import PalaverCore
import PalaverDomain

/// What the meeting changes do through the domain, as values a test may replace (Python's tests monkeypatch
/// `cutting.split`, `undo.restore`, `api.trash_meeting`). Set before the server serves.
public struct ChangeOps {
    public var split: (RecordingPaths, PyNum) throws -> RecordingPaths = { try Cutting.split($0, at: $1) }
    public var trash: (RecordingPaths) throws -> URL = { try Cutting.trash($0) }
    /// `Undo.restore(outputDir, token, check:)`.
    public var restore: (URL, String, Bool) throws -> [String] = { try Undo.restore($0, $1, check: $2) }
    public init() {}
}

public enum ChangesAPI {
    /// The stores `_store_paths` names ("projects", "glossary", "organizations", "prepared", "attributions",
    /// "voices", "shared_series"): where an undo may need to put one back.
    public static func storePaths(_ app: ServerApp, _ names: String...) -> [URL] {
        names.map { name in
            switch name {
            case "projects": return app.stores.projects
            case "glossary": return app.stores.glossary
            case "organizations": return app.stores.organizations
            case "prepared": return app.stores.prepared
            case "attributions": return app.stores.attributions
            case "voices": return app.stores.voices
            case "shared_series": return app.stores.sharedSeries
            default: preconditionFailure("no store \(name)")
            }
        }
    }

    // MARK: - undoable

    /// `_undoable`: a snapshot of `meetings` (`audio` with their audio, `speakerFilesOfAll` the speaker files of every
    /// other meeting) and `stores`, then `body` with the snapshot's token; on any error rolled back from the snapshot
    /// (a rollback that fails keeps the snapshot) and the error rethrown; done, sealed and pruned. `projectsLock`:
    /// the change runs holding `app.projectsLock` (api.py's `with _PROJECTS_LOCK, _undoable(...)`). Answers what
    /// `body` answered (an object) with `"undo": token` added.
    @discardableResult
    public static func undoable(_ app: ServerApp, label: String, meetings: [String] = [], audio: Bool = false,
                                speakerFilesOfAll: Bool = false, stores: [URL] = [], projectsLock: Bool = false,
                                _ body: (String) throws -> JSONValue) throws -> JSONValue {
        // What the last change started after its answer is done first (#31); before the projects' lock, which it takes.
        app.background.settle(FOLLOW_UP_WAIT)
        func change() throws -> (String, JSONValue) {
            let token = try Undo.take(app.outputDir, label, meetings: meetings, audio: audio,
                                      speakerFilesOfAll: speakerFilesOfAll, stores: stores)
            let answer: JSONValue
            do {
                answer = try body(token)
            } catch {
                rollBack(app, label, token)  // still holding the projects lock, as Python's `with` exits inside out
                throw error
            }
            try Undo.sealed(app.outputDir, token)
            Undo.prune(app.outputDir)
            return (token, answer)
        }
        let (token, answer) = projectsLock ? try app.projectsLock.withLock { try change() } : try change()
        return (answer.isObject ? answer : .object([])).adding("undo", .string(token))
    }

    /// Half-changed: the snapshot is the way back (a restore removes it). A rollback that fails keeps the snapshot and
    /// says so in daemon.log (api.py's `LOGGER.exception`).
    private static func rollBack(_ app: ServerApp, _ label: String, _ token: String) {
        do {
            _ = try app.changeOps.restore(app.outputDir, token, false)
        } catch {
            app.log?.message("rolling back \(label) failed; the snapshot \(token) is kept: \(error)", level: "ERROR",
                             logger: "palaver.webapp.api")
        }
    }

    /// How long a change waits for the follow-ups of the one before (`Background.settle`).
    public static let FOLLOW_UP_WAIT = 30.0

    /// `undoable` for a change whose answer is only its token.
    @discardableResult
    public static func undoToken(_ app: ServerApp, label: String, meetings: [String] = [], audio: Bool = false,
                                 speakerFilesOfAll: Bool = false, stores: [URL] = [], projectsLock: Bool = false,
                                 _ body: (String) throws -> Void) throws -> String {
        let answer = try undoable(app, label: label, meetings: meetings, audio: audio, speakerFilesOfAll: speakerFilesOfAll,
                                  stores: stores, projectsLock: projectsLock) { token in
            try body(token)
            return .object([])
        }
        return answer["undo"]?.stringValue ?? ""
    }

    // MARK: - what follows a change

    /// `_after_cut`: everything that depends on the transcripts brought up to date — the meetings `gone` leave the
    /// projects; each of `changed` gets its event (`calendar`: looked up when it has none; a calendar that fails is no
    /// reason to fail) and its names written again; then the voices are recognized everywhere and the changed
    /// meetings in no project put into the one they resemble.
    static func afterCut(_ app: ServerApp, changed: [RecordingPaths], gone: [String], calendar: Bool = false) throws {
        let store = ProjectStore(path: app.stores.projects)
        try store.locked {
            store.reload()
            for id in gone { store.forgetMeeting(id) }
            try store.save()
        }
        for paths in changed {
            if calendar, let provider = app.calendar, !MeetingsAPI.exists(paths.calendar) {
                let (start, duration) = try Cutting.span(paths)
                _ = try? CalendarEvents.attach(paths, provider: provider, start: start, end: try start.adding(seconds: duration),
                                               stores: app.stores)
            }
            try Speakers.saveSpeakerNames(paths, try Speakers.loadSpeakerNames(paths), stores: app.stores)
        }
        try People.refreshRecognition(outputDir: app.outputDir, userName: app.userName, stores: app.stores)
        try ProjectRules.assignByRules(outputDir: app.outputDir, userName: app.userName, meetings: changed.map(\.id),
                                       stores: app.stores)
    }

    /// `_rerender`: transcript.md, where there is one, with the glossary as it is now (under the meeting's lock, as
    /// the speaker names write it): as shown, corrected lines and the room included, removed voices left out.
    static func rerender(_ app: ServerApp, _ ids: [String]) throws {
        for id in ids {
            let paths = RecordingPaths(app.outputDir.appendingPathComponent(id, isDirectory: true))
            let meta = try MeetingsAPI.meta(paths)
            guard let given = meta["start_time"], given.truthy, let seconds = meta["duration_seconds"], seconds != .null,
                  MeetingsAPI.exists(paths.transcriptMd) else { continue }
            guard case .string(let iso) = given, let start = Py.fromIso(iso) else {
                throw PageError("Invalid isoformat string: \(Py.repr(given))")
            }
            let duration = try pyFloat(seconds)
            try StoreLock.meeting(paths) {
                let shown = SharedMic.shown(paths, try Speakers.withoutIgnored(paths, try MeetingsAPI.utterances(paths)))
                let text = try Render.markdown(shown, start: start, duration: duration,
                                           gaps: meta["gaps"]?.arrayValue, timeZone: Lifecycle.offsetZone(iso) ?? .current,
                                           glossary: Glossary.current(stores: app.stores))
                try text.write(to: paths.transcriptMd, atomically: false, encoding: .utf8)
            }
        }
    }

    // MARK: - the calendar event

    /// `_chosen_event`: the event `key` names — "current" (the stored one), one of the question's ("question|<i>"
    /// without an id), or one of the choices around the recording.
    static func chosenEvent(_ app: ServerApp, _ paths: RecordingPaths, key: String) throws -> CalendarEvent {
        if key == "current" {
            guard let current = CalendarEvents.load(paths) else { throw NotFound(key) }
            return current
        }
        for (i, e) in (CalendarEvents.loadQuestion(paths) ?? []).enumerated() where Py.same(key, e.key.isEmpty ? "question|\(i)" : e.key) {
            return e
        }
        // The picker's keys (`EventsAPI.meetingEvents`), from one look at the calendar (#31).
        for (i, e) in try EventsAPI.candidateEvents(app, paths).enumerated() where Py.same(e.key.isEmpty ? "stored|\(i)" : e.key, key) {
            return e
        }
        throw NotFound(key)
    }

    /// `set_meeting_event`: which calendar event the recording was (nil: none of them). The user's choice is final;
    /// the event it replaces is negative evidence. Then what processing did with the event follows (names, projects).
    /// Undoable with the meeting's files (no audio), the projects, what was prepared for the event and the evidence.
    public static func setMeetingEvent(_ app: ServerApp, id: String, key: String?) throws -> String {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        let event = try key.map { try chosenEvent(app, paths, key: $0) }
        let previous = CalendarEvents.load(paths)
        // What was prepared for the event (its waiting notes, #44) comes back on undo too.
        let prepared = event.map { $0.key.isEmpty ? [] : [MyNotes.prepFolder($0.key, stores: app.stores)] } ?? []
        return try undoToken(app, label: "event", meetings: [id],
                             stores: storePaths(app, "projects", "prepared", "attributions") + prepared, projectsLock: true) { _ in
            let evidence = Evidence(path: app.stores.attributions)
            if let previous, event.map({ !EventsAPI.same(previous, $0) }) ?? true { evidence.rejectEvent(previous, id) }
            if let event {
                try CalendarEvents.assign(paths, event, link: Link("event", event.title, "you"), stores: app.stores)
                evidence.confirmEvent(event, id)
            } else {
                try CalendarEvents.dismiss(paths)
            }
            try evidence.save()
            if [paths.systemTurns, paths.transcriptJson, paths.meta].allSatisfy(MeetingsAPI.exists) {
                try afterEvent(app, paths)
            }
        }
    }

    /// What follows a change of event (#31). At once, for the answer: the meeting's names written again, its voices
    /// recognized with the new invitees, its project by the rules. After the answer: every meeting's voices and the
    /// names inferred across meetings (seconds on a large library), then the meeting's project by the rules again,
    /// with the names inference found.
    static func afterEvent(_ app: ServerApp, _ paths: RecordingPaths) throws {
        try Speakers.saveSpeakerNames(paths, try Speakers.loadSpeakerNames(paths), stores: app.stores)
        try People.recognize(paths, stores: app.stores)
        try ProjectRules.assignByRules(outputDir: app.outputDir, userName: app.userName, meetings: [paths.id], stores: app.stores)
        let id = paths.id
        app.background.followUp("recognition") { app in
            try People.refreshRecognition(outputDir: app.outputDir, userName: app.userName, stores: app.stores)
            let paths = RecordingPaths(app.outputDir.appendingPathComponent(id, isDirectory: true))
            guard MeetingsAPI.exists(paths.transcriptJson) else { return }  // gone meanwhile
            // Not under the projects' lock: a change holding it may wait for this (the store's own lock is enough).
            try ProjectRules.assignByRules(outputDir: app.outputDir, userName: app.userName, meetings: [id], stores: app.stores)
        }
    }

    /// `forget_rule`: recordings are linked to this event series by time again. Returns the undo token.
    public static func forgetRule(_ app: ServerApp, series: String) throws -> String {
        try undoToken(app, label: "forget rule", stores: storePaths(app, "attributions")) { _ in
            let evidence = Evidence(path: app.stores.attributions)
            evidence.forgetRule(series)
            try evidence.save()
        }
    }

    // MARK: - title and lines

    /// `set_title`: the user's own title, over its event's and its notes'; "" gives the title back to them. Also while
    /// the meeting is recorded (title.json is a file nothing else writes). Returns the undo token.
    public static func setTitle(_ app: ServerApp, id: String, title: JSONValue?) throws -> String {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        let title = try python { try Titles.clean(title) }
        return try undoToken(app, label: "title", stores: [paths.title]) { token in
            try Titles.save(paths, title)
            try Undo.note(app.outputDir, token, PyDict([("meeting", .string(id))]))
        }
    }

    /// `edit_line`: the user's wording of one transcript line, found by when it starts; what the transcriber heard
    /// is kept ("heard"); `text` nil puts it back. Read and written under the meeting's lock (the speaker names write
    /// transcript.json too).
    public static func editLine(_ app: ServerApp, id: String, start: Double, text: String?) throws {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        guard MeetingsAPI.state(paths) == "ready" else { throw BadRequest("only a finished transcript can be edited") }
        if let text, Py.strip(text).isEmpty { throw BadRequest("a line needs words") }
        try StoreLock.meeting(paths) {
            var lines = try MeetingsAPI.iterate(PythonJSON.read(paths.transcriptJson) ?? .array([]))
            var at: Int?
            for (i, d) in lines.enumerated() {
                if abs(try pyFloat(try item(d, "start")) - start) < 0.01 {
                    at = i
                    break
                }
            }
            guard let at, var line = PyDict<JSONValue>(lines[at]) else { throw NotFound("\(id) at \(Py.str(.double(start)))") }
            let said = try item(lines[at], "text")
            let heard = line["heard"] ?? said
            if let text, !(heard.stringValue.map { Py.same($0, Py.strip(text)) } ?? false) {
                line["heard"] = heard
                line["text"] = .string(Py.strip(text))
            } else {
                line["text"] = heard
                _ = line.removeValue(forKey: "heard")
            }
            lines[at] = line.json
            try PythonJSON.write(.array(lines), to: paths.transcriptJson, indent: 2, ensureAscii: false,
                                 via: "transcript.json.tmp")
        }
        try rerender(app, [id])
    }

    /// `set_line_speaker`: who said one transcript line, found by when it starts and its track ("mic" or "others";
    /// either, when not given) (#12): another voice (`{"label": …}`), a person without a voice of their own
    /// (`{"name": …}`), the user (`{"me": true}`), or null: the voice it was heard as. Undoable with
    /// speakers_lines.json; transcript.md written again. Returns the undo token.
    public static func setLineSpeaker(_ app: ServerApp, id: String, start: Double, to: JSONValue?, track: String?) throws -> String {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        guard MeetingsAPI.state(paths) == "ready" else {
            throw Refused("A line's speaker can be corrected once the meeting is transcribed.")
        }
        if let track, track != "mic" && track != "others" { throw BadRequest(#"'track' is "mic" or "others""#) }
        let found = try MeetingsAPI.utterances(paths).filter {
            abs($0.start - start) < 0.01 && (track == nil || track == Speakers.lineTrack($0))
        }
        guard let line = found.first else { throw NotFound("\(id) at \(Py.str(.double(start)))") }
        if found.count > 1 { throw BadRequest("lines on both tracks start then: say which ('track')") }
        // Names and voices change under this lock (naming, Not Tom): transcript.md is written from them.
        return try app.projectsLock.withLock {
            var target = try lineTarget(app, paths, to)
            let merges = Speakers.loadMerges(paths)
            let heard: String? = Speakers.isMicLine(line) ? nil : merges[Speakers.labelOf(line)] ?? Speakers.labelOf(line)
            if let given = target {
                let me = given.first { $0.0 == "me" }?.1.truthy ?? false
                let label = given.first { $0.0 == "label" }?.1.stringValue
                if me && heard == nil || label.map({ l in heard.map { Py.same(merges[l] ?? l, $0) } ?? false }) ?? false {
                    target = nil  // the voice it was heard as: nothing to correct
                }
            }
            return try undoToken(app, label: "line speaker", stores: [paths.speakersLines]) { token in
                try Speakers.setLineSpeaker(paths, line, target)
                try Speakers.saveSpeakerNames(paths, try Speakers.loadSpeakerNames(paths), learn: false, stores: app.stores)
                try Undo.note(app.outputDir, token, PyDict([("meeting", .string(id))]))
            }
        }
    }

    /// `_line_target`: `to` as speakers_lines.json keeps it; a name a voice of the meeting has is that voice, the
    /// user's own name is the user.
    static func lineTarget(_ app: ServerApp, _ paths: RecordingPaths, _ to: JSONValue?) throws -> [(String, JSONValue)]? {
        guard let to, !to.isNull else { return nil }
        let shape = #"'to' is {"label": …}, {"name": …}, {"me": true} or null"#
        guard let fields = PyDict<JSONValue>(to), fields.count == 1 else { throw BadRequest(shape) }
        if let me = fields["me"] {
            guard case .bool(true) = me else { throw BadRequest("'me' is true") }
            return [("me", .bool(true)), ("name", .string(app.userName))]
        }
        let merges = Speakers.loadMerges(paths), ignored = Speakers.loadIgnored(paths)
        func removed(_ label: String) throws {
            let into = merges[label] ?? label
            if ignored.contains(where: { Py.same($0, into) }) {
                throw Refused("\(MeetingsAPI.labelDisplay(into)) was removed as not a speaker. Restore it first to give it lines.")
            }
        }
        if let given = fields["label"] {
            let label = Py.str(given)
            let voices = try MeetingsAPI.turnItems(paths).map { try item($0, "speaker") }
            guard voices.contains(where: { $0.stringValue.map { Py.same($0, label) } ?? false }) else { throw NotFound(label) }
            try removed(label)
            return [("label", .string(label))]
        }
        if let given = fields["name"] {
            let name = Py.split(Py.str(given)).joined(separator: " ")
            if name.isEmpty { throw BadRequest("a name is needed") }
            if name.unicodeScalars.count > 200 { throw BadRequest("that name is too long") }
            let userName = app.userName
            if !userName.isEmpty && Py.same(Py.casefold(name), Py.casefold(userName)) {
                return [("me", .bool(true)), ("name", .string(userName))]
            }
            let names = try Speakers.namesInEffect(paths)
            for (label, known) in Py.stableSorted(Array(names), by: { Py.less($0.key, $1.key) })
            where merges[label] == nil && Py.same(Py.casefold(known), Py.casefold(name)) {
                try removed(label)
                return [("label", .string(label))]
            }
            return [("name", .string(name))]
        }
        throw BadRequest(shape)
    }

    // MARK: - the trash and the audio

    /// `trash_meeting`: the whole recording to `.trash` in the recordings folder (it can be moved back). Not while it
    /// is recorded or the pipeline still writes into it. Returns the undo token.
    public static func trashMeeting(_ app: ServerApp, id: String) throws -> String {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        let status = MeetingsAPI.state(paths)
        if status == "recording" {
            throw Refused("This meeting is being recorded. It can go to the trash once the recording has stopped.")
        }
        if status == "processing" { throw Refused(MeetingsAPI.stillProcessing("go to the trash")) }  // the pipeline writes there
        return try undoToken(app, label: "trash", stores: storePaths(app, "projects"), projectsLock: true) { token in
            let target = try app.changeOps.trash(paths)
            try Undo.moved(app.outputDir, token, src: paths.folder, dst: target)
            try afterCut(app, changed: [], gone: [id])
        }
    }

    /// `delete_audio` (#9): the meeting's audio goes, its transcript and notes stay; the bytes freed.
    public static func deleteAudio(_ app: ServerApp, id: String) throws -> Int {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        return try python { try Storage.dropAudio(paths) }
    }

    /// `set_local_only` (#53): kept on this Mac, or not.
    public static func setLocalOnly(_ app: ServerApp, id: String, on: Bool) throws {
        try LocalOnly.set(try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id).folder, on: on)
    }

    // MARK: - cutting

    /// `split_meeting`: cut the meeting `at` seconds; the rest becomes a meeting of its own, or (`joinNext`) the start
    /// of the recording that follows. With `discard` ("after"/"before") that part goes to the trash instead.
    public static func splitMeeting(_ app: ServerApp, id: String, at: Double, joinNext: Bool, discard: String?) throws -> JSONValue {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        guard MeetingsAPI.state(paths) == "ready" else { throw BadRequest("only a finished, transcribed meeting can be cut") }
        return try python {
            if let discard, !discard.isEmpty {
                let token = try undoToken(app, label: "cut", meetings: [id], audio: true, stores: storePaths(app, "projects"),
                                          projectsLock: true) { _ in
                    try Cutting.discard(paths, at: .float(at), side: discard)
                    try afterCut(app, changed: [paths], gone: [])
                }
                return .object([("id", .string(id)), ("rest", .null), ("joined", .bool(false)), ("discarded", .string(discard)),
                                ("undo", .string(token))])
            }
            let following = joinNext ? try Cutting.neighbours(paths).next : nil
            if joinNext && following == nil { throw BadRequest("no recording follows this one") }
            var rest = "", joined = false
            let answer = try undoable(app, label: "split", meetings: [id] + (following.map { [$0] } ?? []), audio: true,
                                      stores: storePaths(app, "projects"), projectsLock: true) { token in
                let tail = try app.changeOps.split(paths, .float(at))
                try Undo.created(app.outputDir, token, [tail.id])  // when it is joined on, restore trashes what is left
                if let following {
                    let kept = try Cutting.join(tail, RecordingPaths(app.outputDir.appendingPathComponent(following, isDirectory: true)))
                    let gone = kept.folder.path != tail.folder.path ? [tail.id] : [following]
                    try afterCut(app, changed: [paths, kept], gone: gone, calendar: true)
                    (rest, joined) = (kept.id, true)
                } else {
                    try afterCut(app, changed: [paths, tail], gone: [], calendar: true)
                    (rest, joined) = (tail.id, false)
                }
                return .object([])
            }
            return .object([("id", .string(id)), ("rest", .string(rest)), ("joined", .bool(joined)), ("undo", answer["undo"] ?? .null)])
        }
    }

    /// `join_meetings`: two recordings of one meeting become one; answers the one that remains (`id`) and `undo`.
    public static func joinMeetings(_ app: ServerApp, id: String, other otherId: String) throws -> JSONValue {
        let a = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        let b = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: otherId)
        guard MeetingsAPI.state(a) == "ready" && MeetingsAPI.state(b) == "ready" else {
            throw BadRequest("only finished, transcribed meetings can be joined")
        }
        return try python {
            let keeper = try Cutting.keeper(a, b).id
            let other = Py.same(keeper, id) ? otherId : id
            var kept = ""
            let answer = try undoable(app, label: "join", meetings: [keeper], audio: true, stores: storePaths(app, "projects"),
                                      projectsLock: true) { token in
                let bin = app.outputDir.appendingPathComponent(Cutting.TRASH, isDirectory: true)
                let before = Set(trashNames(bin).map(ScalarKey.init))
                let joined = try Cutting.join(a, b)
                for name in Py.stableSorted(trashNames(bin), by: Py.less) where !before.contains(ScalarKey(name)) {
                    // where the other recording went
                    try Undo.moved(app.outputDir, token, src: app.outputDir.appendingPathComponent(other, isDirectory: true),
                                   dst: bin.appendingPathComponent(name, isDirectory: true))
                }
                try afterCut(app, changed: [joined], gone: [other])
                kept = joined.id
                return .object([])
            }
            return .object([("id", .string(kept)), ("undo", answer["undo"] ?? .null)])
        }
    }

    /// The names in `.trash` (none when there is no such folder).
    private static func trashNames(_ bin: URL) -> [String] {
        MeetingsAPI.isDirectory(bin) ? (try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? [] : []
    }

    // MARK: - suggestions and the review

    /// `dismiss_cut`: the suggested cut (`what` "cut") or removing the silence at the start or end ("silence") is
    /// wrong; not suggested again. `dismiss` false: its undo, suggested again.
    public static func dismissCut(_ app: ServerApp, id: String, dismiss: Bool, what: String) throws {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        guard what == "cut" || what == "silence" else { throw BadRequest("no suggestion \(Py.repr(.string(what)))") }
        let marker = what == "cut" ? paths.cutDismissed : paths.silenceDismissed
        if !dismiss {
            try unlinkMissingOK(marker)
            return
        }
        try PythonJSON.write(.object([("dismissed", .string(Py.isoNow(timespec: "seconds")))]), to: marker, indent: nil,
                             ensureAscii: true)
    }

    /// `mark_reviewed`'s refusal: a meeting still being transcribed is not put back in the review.
    static func refuseReviewAgain(_ app: ServerApp, id: String, done: Bool) throws -> RecordingPaths {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        if !done && MeetingsAPI.state(paths) == "processing" { throw Refused(MeetingsAPI.stillProcessing("be reviewed again")) }
        return paths
    }

    /// `mark_reviewed`: reviewed, with the items open now (`seen`, the ids of `_meeting_needs` other than "review",
    /// asked only for a finished meeting): they stay answered. `done` false: in the review again.
    public static func markReviewed(_ app: ServerApp, id: String, done: Bool, seen: (JSONValue) throws -> [String]) throws {
        let paths = try refuseReviewAgain(app, id: id, done: done)
        guard done else { return try unlinkMissingOK(paths.review) }
        let entry = try MeetingsAPI.listMeetings(app: app).first { $0["id"] == .string(id) && $0["status"] == .string("ready") }
        let ids = try entry.map(seen) ?? []
        try PythonJSON.write(.object([("reviewed", .string(Py.isoNow(timespec: "seconds"))), ("seen", .strings(ids))]),
                             to: paths.review, indent: nil, ensureAscii: true)
    }

    // MARK: - Python's ways

    /// What `except (KeyError, ValueError)` turns into a 400 (`bad request: <text>`) among the domain's errors: a
    /// cut out of range or a file missing a key, a title that is no text, audio that can't be deleted.
    static func python<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let e as CuttingError where e.kind != .type {
            throw BadRequest(e.description)
        } catch let e as StorageError where e.kind == .value {
            throw BadRequest(e.description)
        } catch let e as TitleError {
            throw BadRequest(e.description)
        }
    }

    /// `float(value)` of a JSON value: a ValueError (400) for text that is no number, a TypeError (500) for the rest.
    static func pyFloat(_ value: JSONValue) throws -> Double {
        switch value {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .string(let s):
            guard let d = Py.float(s) else { throw BadRequest("could not convert string to float: \(Py.repr(value))") }
            return d
        default:
            throw PyBody.TypeError(description: "float() argument must be a string or a real number, not '\(PyBody.typeName(value))'")
        }
    }

    /// `d[key]` of a value read from a file, in a POST: a missing key is a KeyError (400).
    static func item(_ d: JSONValue, _ key: String) throws -> JSONValue {
        switch d {
        case .object: break
        case .string: throw PyBody.TypeError(description: "string indices must be integers, not 'str'")
        case .array: throw PyBody.TypeError(description: "list indices must be integers or slices, not str")
        default: throw PyBody.TypeError(description: "'\(PyBody.typeName(d))' object is not subscriptable")
        }
        guard let v = d[key] else { throw BadRequest(Py.repr(.string(key))) }
        return v
    }

    /// `body.get(key, default)` made a bool.
    static func flag(_ body: JSONValue, _ key: String, default value: Bool) throws -> Bool {
        try PyBody.get(body, key).map(\.truthy) ?? value
    }

    /// `Path.unlink(missing_ok=True)`.
    static func unlinkMissingOK(_ url: URL) throws {
        if unlink(url.path) != 0 && errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

extension JSONValue {
    var isObject: Bool { if case .object = self { return true } else { return false } }

    /// `{**self, key: value}` of an object.
    func adding(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(let fields) = self else { return self }
        guard fields.contains(where: { $0.0 == key }) else { return .object(fields + [(key, value)]) }
        return .object(fields.map { $0.0 == key ? (key, value) : $0 })
    }
}

extension Router {
    /// The meeting changes (server.py's POST branches, in its order among them).
    static func addChangeRoutes(_ r: Router, app: ServerApp) {
        func page(_ id: String) throws -> JSONValue { try MeetingsAPI.getMeeting(app: app, id: id) }
        // server.py's `except (KeyError, ValueError)`: 400 for the domain's errors of those kinds too.
        func post(_ pattern: String, _ handler: @escaping Handler) {
            r.post(pattern) { req, m in try ChangesAPI.python { try handler(req, m) } }
        }
        post("/api/meetings/([^/]+)/split") { req, m in
            let id = m.group(1)!
            let discard = try PyBody.get(req.json, "discard")
            return .json(try ChangesAPI.splitMeeting(app, id: id, at: try ChangesAPI.pyFloat(try PyBody.required(req.json, "at")),
                                                     joinNext: try ChangesAPI.flag(req.json, "join_next", default: false),
                                                     discard: discard.flatMap { $0 == .null ? nil : Py.str($0) }))
        }
        post("/api/meetings/([^/]+)/join") { req, m in
            .json(try ChangesAPI.joinMeetings(app, id: m.group(1)!, other: Py.str(try PyBody.required(req.json, "with"))))
        }
        post("/api/meetings/([^/]+)/cut-suggestion") { req, m in
            let what = try PyBody.get(req.json, "what").map(Py.str) ?? "cut"
            try ChangesAPI.dismissCut(app, id: m.group(1)!, dismiss: try ChangesAPI.flag(req.json, "dismiss", default: true), what: what)
            return .json(try page(m.group(1)!))
        }
        post("/api/meetings/([^/]+)/line") { req, m in
            let text = try PyBody.get(req.json, "text")
            try ChangesAPI.editLine(app, id: m.group(1)!, start: try ChangesAPI.pyFloat(try PyBody.required(req.json, "start")),
                                    text: text.flatMap { $0 == .null ? nil : Py.str($0) })
            return .json(try page(m.group(1)!))
        }
        post("/api/meetings/([^/]+)/line-speaker") { req, m in
            let track = try PyBody.get(req.json, "track")
            let token = try ChangesAPI.setLineSpeaker(app, id: m.group(1)!,
                                                      start: try ChangesAPI.pyFloat(try PyBody.required(req.json, "start")),
                                                      to: try PyBody.get(req.json, "to"),
                                                      track: track.flatMap { $0 == .null ? nil : Py.str($0) })
            return .json(try page(m.group(1)!).adding("undo", .string(token)))
        }
        post("/api/meetings/([^/]+)/title") { req, m in
            let token = try ChangesAPI.setTitle(app, id: m.group(1)!, title: try PyBody.required(req.json, "title"))
            return .json(try page(m.group(1)!).adding("undo", .string(token)))
        }
        post("/api/meetings/([^/]+)/delete-audio") { _, m in
            let freed = try ChangesAPI.deleteAudio(app, id: m.group(1)!)
            return .json(try page(m.group(1)!).adding("freed", .int(freed)))
        }
        post("/api/meetings/([^/]+)/trash") { _, m in
            let token = try ChangesAPI.trashMeeting(app, id: m.group(1)!)
            return .json(.object([("trashed", .string(m.group(1)!)), ("undo", .string(token))]))
        }
        // After a change: once what it started after its answer is done (#31), at most 10 s.
        r.get("/api/settled") { _, _ in .json(.object([("settled", .bool(app.background.settle(10)))])) }
        post("/api/undo") { req, _ in
            let ids = try UndoRoute.undoChange(app, token: Py.str(try PyBody.required(req.json, "token")))
            return .json(.object([("restored", .strings(ids))]))
        }
        post("/api/meetings/([^/]+)/event") { req, m in
            let key = try PyBody.get(req.json, "key")
            let token = try ChangesAPI.setMeetingEvent(app, id: m.group(1)!, key: key.flatMap { $0 == .null ? nil : Py.str($0) })
            return .json(try page(m.group(1)!).adding("undo", .string(token)))
        }
        post("/api/rules/forget") { req, _ in
            .json(.object([("undo", .string(try ChangesAPI.forgetRule(app, series: Py.str(try PyBody.required(req.json, "series")))))]))
        }
        post("/api/meetings/([^/]+)/reviewed") { req, m in
            try ReviewAPI.markReviewed(app, id: m.group(1)!, done: try ChangesAPI.flag(req.json, "done", default: true))
            return .json(.array(try ReviewAPI.queue(app, userName: app.userName)))
        }
        post("/api/meetings/([^/]+)/local-only") { req, m in
            try ChangesAPI.setLocalOnly(app, id: m.group(1)!, on: try ChangesAPI.flag(req.json, "on", default: true))
            return .json(try page(m.group(1)!))
        }
    }
}
