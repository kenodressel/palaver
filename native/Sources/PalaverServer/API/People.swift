// Who speaks in a meeting and who they are across meetings (api.py `name_speaker`, `_automatic_name`, `remove_speaker`,
// `set_unknown`, `merge_speaker`, `set_shared`, `_derive_shared`, `remember_series`, `dismiss_shared_suggestion`,
// `decide_imported_voices`, `directory`, `_clip`, `rename_organization`, `set_person_org`, `rename_person`,
// `_undoable_names`, `name_voices`, `known_names`; server.py's GET and POST branches for them).
//
// A change to names may touch every meeting's speaker files, the voice bank and the organizations: it is undone from
// a snapshot of all of them (`undoableNames`, holding `app.projectsLock` as api.py holds `_PROJECTS_LOCK`). The domain
// writers take the meeting's lock themselves and let it go before the voice bank's (Speakers, People).
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

public enum PeopleAPI {
    static let NOT_TRANSCRIBED = "Voices can be marked once the meeting is transcribed."
    static let ONLY_RECURRING = "Only a meeting of a recurring calendar event can be remembered for its series."

    // MARK: - what the changes share

    /// `{d["speaker"] for d in _read_json(paths.system_turns, [])}`: the meeting's speaker labels (by code points).
    static func labels(_ paths: RecordingPaths) throws -> Set<ScalarKey> {
        var out = Set<ScalarKey>()
        for d in try MeetingsAPI.turnItems(paths) {
            let speaker = try ChangesAPI.item(d, "speaker")
            switch speaker {
            case .string(let label): out.insert(ScalarKey(label))
            case .array, .object: throw PyBody.TypeError(description: "unhashable type: '\(PyBody.typeName(speaker))'")
            default: continue  // a number never equals a label
            }
        }
        return out
    }

    /// `people.refresh_recognition(output_dir)`: the voices recognized everywhere again (api.py passes no user name).
    static func refresh(_ app: ServerApp) throws {
        try People.refreshRecognition(outputDir: app.outputDir, stores: app.stores)
    }

    /// `_undoable_names`: run `change` (it touches the speaker files of every meeting, the voices and the
    /// organizations) so that it can be undone; returns the undo token.
    static func undoableNames(_ app: ServerApp, label: String, _ change: () throws -> Void) throws -> String {
        try ChangesAPI.undoToken(app, label: label, speakerFilesOfAll: true,
                                 stores: ChangesAPI.storePaths(app, "voices", "organizations"), projectsLock: true) { _ in
            try change()
        }
    }

    /// What `except (KeyError, ValueError)` turns into a 400 among the domain's errors these changes meet: a speaker
    /// merged into itself, a series that can't be remembered, a voice file of the wrong shape.
    static func python<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let e as SpeakersValueError {
            throw BadRequest(e.description)
        } catch let e as ExchangeExportError where e.kind == .key || e.kind == .value {
            throw BadRequest(e.description)
        }
    }

    // MARK: - naming a speaker

    /// `_automatic_name`: the name recognition or inference gives `label` now, if any.
    static func automaticName(_ paths: RecordingPaths, _ label: String) throws -> String? {
        if let hit = try Speakers.loadRecognizedNames(paths)[label] { return hit.0 }
        return try Speakers.loadInferredNames(paths)[label]
    }

    /// `name_speaker`: give `label` a name; an empty name leaves it unnamed. Emptying a name recognized by voice or
    /// inferred says "this voice is not Tom": the name is rejected for this voice (and voices like it elsewhere).
    /// Returns the undo token of such a change (not Tom, it was Tom after all, the guess confirmed); nil for a name
    /// typed, which the page sets back itself. While the meeting is recorded the name follows the live voice.
    public static func nameSpeaker(_ app: ServerApp, id: String, label given: String, name typed: String) throws -> String? {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        if MeetingsAPI.exists(paths.live) && MeetingsAPI.state(paths) == "recording" {
            do {
                try Speakers.nameLiveSpeaker(paths, given, typed)  // follows the voice; labels change while recording
            } catch is NoLiveVoice {
                throw NotFound(given)
            }
            return nil
        }
        guard try labels(paths).contains(ScalarKey(given)) else { throw NotFound(given) }
        let label = Speakers.loadMerges(paths)[given] ?? given  // naming a merged label names the person
        var names = try Speakers.loadSpeakerNames(paths)
        let name = Py.strip(typed)
        let automatic = names[label] == nil ? try automaticName(paths, label) : nil

        func known() throws { try Speakers.setUnknown(paths, label, false) }  // a voice nobody knew: asked about again if it loses the name
        func with(_ name: String) -> PyDict<String> {
            var out = names
            out[label] = name
            return out
        }

        if name.isEmpty, let automatic, !automatic.isEmpty {
            return try undoableNames(app, label: "not") {
                try Speakers.setRejectedName(paths, label, automatic)
                try Speakers.saveSpeakerNames(paths, names, stores: app.stores)
                try refresh(app)
            }
        }
        let key = Py.casefold(name)
        if !name.isEmpty && (Speakers.loadRejectedNames(paths)[label] ?? []).contains(where: { Py.same(Py.casefold($0), key) }) {
            return try undoableNames(app, label: "after all") {  // it was them after all; its undo brings the rejection back
                try Speakers.setRejectedName(paths, label, name, false)
                try known()
                try Speakers.saveSpeakerNames(paths, with(name), stores: app.stores)
                try refresh(app)
            }
        }
        if !name.isEmpty, let automatic, !automatic.isEmpty, Py.same(key, Py.casefold(automatic)) {
            return try undoableNames(app, label: "confirm") {  // the guess was right; its undo makes it a guess again
                try known()
                try Speakers.saveSpeakerNames(paths, with(name), stores: app.stores)
                try refresh(app)
            }
        }
        if !name.isEmpty {
            names[label] = name
            try known()
        } else if try Speakers.loadRecognizedNames(paths)[label] != nil || Inference.load(paths)[label] != nil {
            names[label] = label  // not who the voice or the calendar suggested
        } else {
            names.removeValue(forKey: label)
        }
        try Speakers.saveSpeakerNames(paths, names, stores: app.stores)
        try refresh(app)  // the voice may be in other meetings too
        return nil
    }

    // MARK: - removing, not knowing, merging

    /// `remove_speaker`: a voice removed as noise (a few words, a fragment of someone) with its lines, or brought back.
    public static func removeSpeaker(_ app: ServerApp, id: String, label: String, removed: Bool) throws {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        guard try labels(paths).contains(ScalarKey(label)) else { throw NotFound(label) }
        try Speakers.setIgnored(paths, Speakers.loadMerges(paths)[label] ?? label, removed)
        try Speakers.saveSpeakerNames(paths, try Speakers.loadSpeakerNames(paths), stores: app.stores)  // transcript.md, voice samples
        try refresh(app)
    }

    /// `set_unknown`: "Don't Know Who This Is" (`on`) or "Ask Me Again" for one voice. The undo token keeps only this
    /// meeting's list: nothing else follows from it.
    public static func setUnknown(_ app: ServerApp, id: String, label given: String, on: Bool) throws -> String {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        guard MeetingsAPI.state(paths) == "ready" else { throw Refused(NOT_TRANSCRIBED) }
        guard try labels(paths).contains(ScalarKey(given)) else { throw NotFound(given) }
        let label = Speakers.loadMerges(paths)[given] ?? given  // a merged voice is the lane it joined
        return try ChangesAPI.undoToken(app, label: "unknown", stores: [paths.speakersUnknown]) { token in
            try Speakers.setUnknown(paths, label, on)
            try Undo.note(app.outputDir, token, PyDict([("meeting", .string(id))]))
        }
    }

    /// `merge_speaker`: fold `label` into `into` (the diarizer split one person in two) or, `into` nil, split it off
    /// again. A merge returns the undo token (its snapshot has the voices: the merge may teach the bank); a split none.
    public static func mergeSpeaker(_ app: ServerApp, id: String, label: String, into: String?) throws -> String? {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        let labels = try labels(paths)
        guard labels.contains(ScalarKey(label)) else { throw NotFound(label) }
        guard let into else {
            try Speakers.mergeSpeakers(paths, label, into: nil, stores: app.stores)
            try refresh(app)
            return nil
        }
        guard labels.contains(ScalarKey(into)) else { throw NotFound(into) }
        if Py.same(Speakers.loadMerges(paths)[into] ?? into, label) { throw BadRequest("a speaker cannot be merged into itself") }
        return try ChangesAPI.undoToken(app, label: "merge speakers", meetings: [id], stores: ChangesAPI.storePaths(app, "voices")) { _ in
            try Speakers.mergeSpeakers(paths, label, into: into, stores: app.stores)
            try refresh(app)
        }
    }

    // MARK: - voices that can't be told apart (#56)

    /// `set_shared`: the whole meeting's voices (`label` nil) or one lane's (a room; `name`: the room's) can't be told
    /// apart; `on` false takes it back. `series`: remember the whole-meeting mark for the event's series, or forget it.
    /// The undo token keeps only what the user said (the marks, the series); what follows is derived again on undo.
    public static func setShared(_ app: ServerApp, id: String, on: Bool, label given: String?, name: String?,
                                 series: Bool?) throws -> String {
        if series != nil && (given != nil || !on) { throw BadRequest("a series is remembered with the whole meeting marked") }
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        guard MeetingsAPI.state(paths) == "ready" else { throw Refused(NOT_TRANSCRIBED) }
        var label = given
        if let given, !Py.same(given, SharedMic.MIC) {  // MIC: the user's microphone
            guard try labels(paths).contains(ScalarKey(given)) else { throw NotFound(given) }
            label = Speakers.loadMerges(paths)[given] ?? given  // a merged voice is the lane it joined
        }
        let event = CalendarEvents.load(paths)
        if series != nil && !SharedMic.canRemember(event) { throw Refused(ONLY_RECURRING) }

        func voices() -> (Set<ScalarKey>, Bool) { (SharedMic.sharedLabels(paths), SharedMic.micRoom(paths) == nil) }

        let stores = [paths.speakersShared] + (series != nil ? ChangesAPI.storePaths(app, "shared_series") : [])
        return try ChangesAPI.undoToken(app, label: "shared", stores: stores, projectsLock: true) { token in
            let before = voices()
            if let label { try SharedMic.setLane(paths, label, on, name: name) } else { try SharedMic.setMeeting(paths, on) }
            if let series { try SharedMic.remember(event, series, stores: app.stores) }
            let after = voices()
            let derive = after.0 != before.0 || after.1 != before.1
            try Undo.note(app.outputDir, token, PyDict([("meeting", .string(id)), ("derive", .bool(derive))]))
            try deriveShared(app, paths, derive: derive)
        }
    }

    /// `_derive_shared` (api.py's default user name ""): the meeting's transcript; when which voices are several
    /// people changed, the voice bank and the names recognized and inferred in every meeting.
    static func deriveShared(_ app: ServerApp, _ paths: RecordingPaths, derive: Bool) throws {
        if [paths.transcriptJson, paths.systemTurns, paths.meta].allSatisfy(MeetingsAPI.exists) {
            try Speakers.saveSpeakerNames(paths, try Speakers.loadSpeakerNames(paths), learn: derive, stores: app.stores)
        }
        if derive { try refresh(app) }
    }

    /// `remember_series`: whether the next meetings of this meeting's event series start out marked; this meeting's
    /// own mark stays as it is. Returns the undo token.
    public static func rememberSeries(_ app: ServerApp, id: String, remember: Bool) throws -> String {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        let event = CalendarEvents.load(paths)
        guard SharedMic.canRemember(event) else { throw Refused(ONLY_RECURRING) }
        return try ChangesAPI.undoToken(app, label: "shared", stores: ChangesAPI.storePaths(app, "shared_series")) { token in
            try SharedMic.remember(event, remember, stores: app.stores)
            try Undo.note(app.outputDir, token, PyDict([("meeting", .string(id)), ("derive", .bool(false))]))
        }
    }

    /// `dismiss_shared_suggestion`: "No, each voice is one person": not suggested again; false: its undo.
    public static func dismissSharedSuggestion(_ app: ServerApp, id: String, dismiss: Bool) throws {
        try SharedMic.dismissSuggestion(try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id), dismiss)
    }

    // MARK: - an import's voices (#58)

    /// `decide_imported_voices`: yes or no to the voices that came with an import; undoable (a yes recognizes voices
    /// in every meeting again).
    public static func decideImportedVoices(_ app: ServerApp, id: String, add: Bool) throws -> String {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        return try ChangesAPI.undoToken(app, label: "voices", meetings: [id], speakerFilesOfAll: true,
                                        stores: ChangesAPI.storePaths(app, "voices", "organizations"), projectsLock: true) { _ in
            try Exchange.decideVoices(paths, add: add, userName: app.userName, stores: app.stores)
        }
    }

    // MARK: - people across meetings

    /// `_clip`: the voice's longest turn (the first of equally long ones), at most CLIP_SECONDS; null without one.
    static func clip(_ paths: RecordingPaths, _ label: String) throws -> JSONValue {
        let turns = try MeetingsAPI.turns(paths).filter { Py.same($0.speaker, label) }
        guard var best = turns.first else { return .null }
        for t in turns.dropFirst() where t.end - t.start > best.end - best.start { best = t }
        return .object([("start", .double(best.start)), ("end", .double(min(best.end, best.start + MeetingsAPI.CLIP_SECONDS)))])
    }

    /// `directory`: people across meetings, and recurring voices without a name, with each meeting's title, projects
    /// and a clip of the voice there; each person's organization and the organizations. The user, by any of their
    /// names, is marked "you" (`userName`: server.py passes none after a change).
    public static func directory(_ app: ServerApp, userName: String) throws -> JSONValue {
        var listed = PyDict<JSONValue>()
        for m in try MeetingsAPI.listMeetings(app: app) { if case .string(let id)? = m["id"] { listed[id] = m } }

        func entry(_ id: JSONValue, _ label: JSONValue, _ own: JSONValue) throws -> (id: String, json: JSONValue) {
            guard case .string(let meeting) = id, case .string(let lane) = label else { throw PageError("a voice's meeting is no id") }
            let m = listed[meeting] ?? .object([])
            let projects = try MeetingsAPI.iterate(m["projects"] ?? .array([])).map { p in
                JSONValue.object([("id", try MeetingsAPI.key(p, "id")), ("name", try MeetingsAPI.key(p, "name"))])
            }
            var out = PyDict<JSONValue>([
                ("id", .string(meeting)), ("title", m["title"] ?? .null), ("start", m["start"] ?? .null),
                ("projects", .array(projects)),
                ("clip", try clip(RecordingPaths(app.outputDir.appendingPathComponent(meeting, isDirectory: true)), lane)),
            ])
            guard case .object(let fields) = own else { throw PageError("a voice is no object") }
            for (k, v) in fields { out[k] = v }
            return (Py.str(out["id"] ?? .null), out.json)
        }
        func newestFirst(_ entries: [(id: String, json: JSONValue)]) -> JSONValue {
            .array(Py.stableSorted(entries) { Py.less($1.id, $0.id) }.map(\.json))
        }

        let found = try People.directory(outputDir: app.outputDir, me: SettingsFile.me(userName: userName, stores: app.stores),
                                         stores: app.stores)
        let index = Orgs.peopleIndex(outputDir: app.outputDir)
        let orgs = Organizations(path: app.stores.organizations)
        let people = try (found["people"]?.arrayValue ?? []).map { person -> JSONValue in
            guard var d = PyDict<JSONValue>(person), case .string(let name)? = d["name"] else { throw PageError("a person is no object") }
            d["meetings"] = newestFirst(try (d["meetings"]?.arrayValue ?? []).map { try entry($0["id"] ?? .null, $0["label"] ?? .null, $0) })
            d["org"] = .str(Orgs.orgOf(name, index, orgs))
            d["org_given"] = .bool(orgs.person(name) != nil)
            return d.json
        }
        let unknown = try (found["unknown"]?.arrayValue ?? []).map { group -> JSONValue in
            guard var d = PyDict<JSONValue>(group) else { throw PageError("a group is no object") }
            d["voices"] = newestFirst(try (d["voices"]?.arrayValue ?? []).map { try entry($0["meeting"] ?? .null, $0["label"] ?? .null, $0) })
            return d.json
        }
        return .object([("people", .array(people)), ("unknown", .array(unknown)),
                        ("organizations", .array(Orgs.summary(index, orgs)))])
    }

    /// `rename_organization`.
    public static func renameOrganization(_ app: ServerApp, key: String, name: String) throws {
        let orgs = Organizations(path: app.stores.organizations)
        orgs.rename(key, name)
        try orgs.save()
    }

    /// `set_person_org`: `person`'s organization given by hand; empty takes it back to the email's.
    public static func setPersonOrg(_ app: ServerApp, person: String, org: String?) throws {
        if Py.strip(person).isEmpty { throw BadRequest("a person is needed") }
        let orgs = Organizations(path: app.stores.organizations)
        orgs.setPerson(person, org)
        try orgs.save()
    }

    /// `rename_person`: `old` is `new` from now on, everywhere. Returns the undo token.
    public static func renamePerson(_ app: ServerApp, old: String, new typed: String) throws -> String {
        let new = Py.strip(typed)
        if new.isEmpty { throw BadRequest("a name is needed") }
        return try undoableNames(app, label: "rename") {
            try People.renamePerson(outputDir: app.outputDir, old: old, new: new, stores: app.stores)
        }
    }

    /// `name_voices`: name the voices (meeting, label), e.g. one recurring voice in several meetings. Returns the undo
    /// token.
    public static func nameVoices(_ app: ServerApp, members: [(String, String)], name typed: String) throws -> String {
        let name = Py.strip(typed)
        if name.isEmpty || members.isEmpty { throw BadRequest("a name and at least one voice are needed") }
        for (meeting, label) in members {
            let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: meeting)
            guard try labels(paths).contains(ScalarKey(label)) else { throw NotFound("\(meeting) \(label)") }
        }
        return try undoableNames(app, label: "name") {
            try People.nameVoices(outputDir: app.outputDir, members: members, name: name, stores: app.stores)
        }
    }

    /// `known_names`: names to suggest — the user's, the voice bank's and every name in effect in a meeting, sorted
    /// by `str.casefold` (Python's set: names alike when casefolded come in code point order here).
    public static func knownNames(_ app: ServerApp) throws -> [String] {
        var found = [app.userName] + (try VoiceBank(directory: app.stores.voices).names().keys)
        if MeetingsAPI.isDirectory(app.outputDir) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: app.outputDir.path)) ?? [] {
                let folder = app.outputDir.appendingPathComponent(name, isDirectory: true)
                guard MeetingsAPI.isDirectory(folder), RecordingPaths.isRecordingFolderName(name) else { continue }
                found += try Speakers.namesInEffect(RecordingPaths(folder)).values
            }
        }
        var seen = Set<ScalarKey>()
        let unique = Py.stableSorted(found, by: Py.less).filter { seen.insert(ScalarKey($0)).inserted }
        return Py.stableSorted(unique) { Py.less(Py.casefold($0), Py.casefold($1)) }
    }
}

extension Router {
    /// The speakers, people, voices and organizations (server.py's GET and POST branches).
    static func addPeopleRoutes(_ r: Router, app: ServerApp) {
        func page(_ id: String, calendar: Bool = true) throws -> JSONValue {
            try MeetingsAPI.getMeeting(app: app, id: id, calendar: calendar)
        }
        func withUndo(_ page: JSONValue, _ token: String?) -> JSONValue { token.map { page.adding("undo", .string($0)) } ?? page }
        func post(_ pattern: String, _ handler: @escaping Handler) {
            r.post(pattern) { req, m in try PeopleAPI.python { try handler(req, m) } }
        }
        /// `isinstance(body.get(key), bool)`, else a ValueError with `text`.
        func bool(_ body: JSONValue, _ key: String, _ text: String) throws -> Bool {
            guard case .bool(let b)? = try PyBody.get(body, key) else { throw BadRequest(text) }
            return b
        }
        /// `None if v is None else str(v)` of `body.get(key)`.
        func optionalText(_ body: JSONValue, _ key: String) throws -> String? {
            try PyBody.get(body, key).flatMap { $0 == .null ? nil : Py.str($0) }
        }

        r.get("/api/names") { _, _ in .json(.strings(try PeopleAPI.knownNames(app))) }
        r.get("/api/people") { _, _ in .json(try PeopleAPI.directory(app, userName: app.userName)) }

        post("/api/meetings/([^/]+)/speakers") { req, m in
            let id = m.group(1)!
            let label = Py.str(try PyBody.required(req.json, "label"))
            let token = try PeopleAPI.nameSpeaker(app, id: id, label: label, name: try PyBody.get(req.json, "name").map(Py.str) ?? "")
            return .json(withUndo(try page(id, calendar: false), token))
        }
        post("/api/meetings/([^/]+)/shared") { req, m in
            let id = m.group(1)!
            let series = try PyBody.get(req.json, "series")
            var remember: Bool?
            switch series {
            case nil, .null?: remember = nil
            case .bool(let b)?: remember = b
            default: throw BadRequest("'on' and 'series' are true or false")
            }
            guard case .bool(let on)? = try PyBody.get(req.json, "on") else { throw BadRequest("'on' and 'series' are true or false") }
            let name = try PyBody.get(req.json, "name")
            guard name == nil || name == .null || name!.stringValue != nil else { throw BadRequest("a room's name is text") }
            let token = try PeopleAPI.setShared(app, id: id, on: on, label: try optionalText(req.json, "label"),
                                                name: name?.stringValue, series: remember)
            return .json(try page(id).adding("undo", .string(token)))
        }
        post("/api/meetings/([^/]+)/shared-series") { req, m in
            let remember = try bool(req.json, "remember", "'remember' is true or false")
            let token = try PeopleAPI.rememberSeries(app, id: m.group(1)!, remember: remember)
            return .json(try page(m.group(1)!).adding("undo", .string(token)))
        }
        post("/api/meetings/([^/]+)/shared-suggestion") { req, m in
            try PeopleAPI.dismissSharedSuggestion(app, id: m.group(1)!, dismiss: try ChangesAPI.flag(req.json, "dismiss", default: true))
            return .json(try page(m.group(1)!))
        }
        post("/api/meetings/([^/]+)/imported-voices") { req, m in
            let add = try bool(req.json, "add", "'add' is true or false")
            let token = try PeopleAPI.decideImportedVoices(app, id: m.group(1)!, add: add)
            return .json(try page(m.group(1)!).adding("undo", .string(token)))
        }
        post("/api/meetings/([^/]+)/remove") { req, m in
            try PeopleAPI.removeSpeaker(app, id: m.group(1)!, label: Py.str(try PyBody.required(req.json, "label")),
                                        removed: try ChangesAPI.flag(req.json, "removed", default: true))
            return .json(try page(m.group(1)!, calendar: false))
        }
        post("/api/meetings/([^/]+)/unknown") { req, m in
            let on = try bool(req.json, "on", "'on' is true or false")
            let token = try PeopleAPI.setUnknown(app, id: m.group(1)!, label: Py.str(try PyBody.required(req.json, "label")), on: on)
            return .json(try page(m.group(1)!).adding("undo", .string(token)))
        }
        post("/api/meetings/([^/]+)/merge") { req, m in
            let into = try optionalText(req.json, "into")
            let token = try PeopleAPI.mergeSpeaker(app, id: m.group(1)!, label: Py.str(try PyBody.required(req.json, "label")), into: into)
            return .json(withUndo(try page(m.group(1)!, calendar: false), token))
        }
        // After a change server.py answers `api.directory(app.output_dir)`: no user name, nobody marked "you".
        post("/api/organizations") { req, _ in
            try PeopleAPI.renameOrganization(app, key: Py.str(try PyBody.required(req.json, "key")),
                                             name: try PyBody.get(req.json, "name").map(Py.str) ?? "")
            return .json(try PeopleAPI.directory(app, userName: ""))
        }
        post("/api/people/org") { req, _ in
            let org = try optionalText(req.json, "org")
            try PeopleAPI.setPersonOrg(app, person: Py.str(try PyBody.required(req.json, "name")), org: org)
            return .json(try PeopleAPI.directory(app, userName: ""))
        }
        post("/api/people/rename") { req, _ in
            let token = try PeopleAPI.renamePerson(app, old: Py.str(try PyBody.required(req.json, "old")),
                                                   new: Py.str(try PyBody.required(req.json, "new")))
            return .json(try PeopleAPI.directory(app, userName: "").adding("undo", .string(token)))
        }
        post("/api/voices/name") { req, _ in
            let members = try MeetingsAPI.iterate(try PyBody.required(req.json, "voices")).map { pair -> (String, String) in
                let items: [JSONValue]
                switch pair {
                case .array, .object, .string: items = try MeetingsAPI.iterate(pair)
                default: throw PyBody.TypeError(description: "cannot unpack non-iterable \(PyBody.typeName(pair)) object")
                }
                if items.count < 2 { throw BadRequest("not enough values to unpack (expected 2, got \(items.count))") }
                if items.count > 2 { throw BadRequest("too many values to unpack (expected 2)") }
                return (Py.str(items[0]), Py.str(items[1]))
            }
            let token = try PeopleAPI.nameVoices(app, members: members, name: Py.str(try PyBody.required(req.json, "name")))
            return .json(try PeopleAPI.directory(app, userName: "").adding("undo", .string(token)))
        }
    }
}
