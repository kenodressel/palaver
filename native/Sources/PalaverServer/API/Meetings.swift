// The meeting list (api.py:130-296, :297-331): which folders are meetings, their status, and a meeting
// as the list shows it (what it was, who was in it, what is still to do), kept in `ServerApp.meetingList`
// until one of its files changes. The status, "finishing" and the projects are read every time.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

/// What Python raises reading a meeting's files of an unexpected shape (KeyError, TypeError, AttributeError, a
/// strptime ValueError): the page's 500, with Python's kind of text.
struct PageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

public enum MeetingsAPI {
    public static let CLIPS_PER_SPEAKER = 3
    public static let CLIP_SECONDS = 8.0
    /// api._STILL_PROCESSING; `{}` is what the meeting can do once it is transcribed.
    public static let STILL_PROCESSING = "This meeting is still being transcribed. It can {} once that is done."

    /// `_STILL_PROCESSING.format(what)`.
    public static func stillProcessing(_ what: String) -> String {
        STILL_PROCESSING.replacingOccurrences(of: "{}", with: what)
    }

    // MARK: - folders

    /// api.meeting_paths: the folder of `id`; only names of recording folders, so a request can never reach outside
    /// the recordings directory (no "/", no "..", no hidden folder).
    public static func meetingPaths(outputDir: URL, id: String) throws -> RecordingPaths {
        let folder = outputDir.appendingPathComponent(id, isDirectory: true)
        guard RecordingPaths.isRecordingFolderName(id), isDirectory(folder) else { throw NotFound(id) }
        return RecordingPaths(folder)
    }

    /// `Path.is_dir()`: links followed.
    static func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        return stat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return stat(url.path, &st) == 0
    }

    // MARK: - status

    /// api._status: "recording", "ready", "waiting", "failed", "processing" or "incomplete".
    public static func state(_ paths: RecordingPaths) -> String {
        let status = MeetingStatus.status(paths)
        if status == "recording" || WorkerPids.liveRunning(paths.folder) { return "recording" }
        if status == "processed" || status == "synced" { return "ready" }
        if status == "recorded" {
            guard let failed = ProcessState.read(paths) else { return "processing" }
            return failed["reason"] == .string(ProcessState.models) ? "waiting" : "failed"
        }
        return "incomplete"
    }

    /// `_finishing`: stopped, while the live worker still finishes it — shown live a little longer, nothing to stop.
    static func finishing(_ paths: RecordingPaths, _ status: String) -> Bool {
        status == "recording" && MeetingStatus.status(paths) != "recording"
    }

    // MARK: - reading the meeting's files

    /// `_read_json(paths.meta, {})`, on which Python calls `.get`.
    static func meta(_ paths: RecordingPaths) throws -> JSONValue {
        let meta = PythonJSON.read(paths.meta) ?? .object([])
        guard case .object = meta else { throw PageError("'\(PyBody.typeName(meta))' object has no attribute 'get'") }
        return meta
    }

    /// `for d in value`: a list's items, a dict's keys, a text's characters.
    static func iterate(_ value: JSONValue) throws -> [JSONValue] {
        switch value {
        case .array(let items): return items
        case .object(let fields): return fields.map { .string($0.0) }
        case .string(let s): return s.unicodeScalars.map { .string(String($0)) }
        default: throw PageError("'\(PyBody.typeName(value))' object is not iterable")
        }
    }

    /// `d[key]` of a value read from a file.
    static func key(_ d: JSONValue, _ key: String) throws -> JSONValue {
        guard case .object = d else { throw PageError("'\(PyBody.typeName(d))' object is not subscriptable") }
        guard let v = d[key] else { throw PageError(Py.repr(.string(key))) }
        return v
    }

    /// `(value or {}).get(key)`.
    static func get(_ value: JSONValue?, _ key: String) throws -> JSONValue {
        guard let value, value.truthy else { return .null }
        guard case .object = value else { throw PageError("'\(PyBody.typeName(value))' object has no attribute 'get'") }
        return value[key] ?? .null
    }

    /// system_turns.json's entries (`_read_json(paths.system_turns, [])`).
    static func turnItems(_ paths: RecordingPaths) throws -> [JSONValue] {
        try PythonJSON.read(paths.systemTurns).map(iterate) ?? []
    }

    /// `_turns`: speaker turns, merged labels under the label they were merged into.
    static func turns(_ paths: RecordingPaths) throws -> [SpeakerTurn] {
        Speakers.mergedTurns(try turnItems(paths).map { try SpeakerTurn(json: $0) }, Speakers.loadMerges(paths))
    }

    /// `_utterances`: transcript.json as it is (none when it is missing or no JSON).
    static func utterances(_ paths: RecordingPaths) throws -> [Utterance] {
        try (PythonJSON.read(paths.transcriptJson).map(iterate) ?? []).map { try Utterance(json: $0) }
    }

    /// `_start`: meta.json's start, else the folder's name as local time (`strptime(...).astimezone().isoformat()`).
    static func start(_ paths: RecordingPaths, _ meta: JSONValue) throws -> JSONValue {
        if let given = meta["start_time"], given.truthy { return given }
        guard let stamp = RecordingPaths.recordingFolderTimestamp(paths.id) else { return .null }
        return .string(try localStart(stamp))
    }

    /// `datetime.strptime(stamp, "%Y-%m-%dT%H-%M-%S").astimezone().isoformat()`, in this Mac's zone.
    static func localStart(_ stamp: String, timeZone: TimeZone = .current) throws -> String {
        let u = Array(stamp.unicodeScalars)  // \d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}, any script's digits
        func number(_ r: Range<Int>) -> Int? {
            var n = 0
            for i in r {
                guard Py.isDecimal(u[i]), let v = u[i].properties.numericValue else { return nil }
                n = n * 10 + Int(v)
            }
            return n
        }
        let bad = PageError("time data \(Py.repr(.string(stamp))) does not match format '%Y-%m-%dT%H-%M-%S'")
        guard u.count == 19, let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              year >= 1, (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { throw bad }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: parts), calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else {
            throw PageError("day is out of range for month")
        }
        return WallTime.iso(date, timeZone)
    }

    /// `_label_display`: "Speaker 2" for SPEAKER_01 (any label ending in "_<digits>").
    public static func labelDisplay(_ label: String) -> String {
        let scalars = Array(label.unicodeScalars)
        let tail = scalars.lastIndex(of: "_").map { Array(scalars[($0 + 1)...]) } ?? scalars
        guard !tail.isEmpty, tail.allSatisfy(Py.isDecimal) else { return label }
        // int(number) + 1, at any length: the digits as ASCII, one added from the right.
        var digits = tail.map { Int($0.properties.numericValue ?? 0) }
        var i = digits.count - 1
        while i >= 0 {
            if digits[i] < 9 { digits[i] += 1; break }
            digits[i] = 0
            i -= 1
        }
        if i < 0 { digits.insert(1, at: 0) }
        let text = String(digits.map { Character(String($0)) }).drop { $0 == "0" }
        return "Speaker \(text.isEmpty ? "0" : String(text))"
    }

    /// `_display_names`: every label → what to show: a room or "Several people" (#56), its name, or "Speaker 2" for
    /// SPEAKER_01; a merged label shows as the label it was merged into.
    static func displayNames(_ paths: RecordingPaths) throws -> PyDict<String> {
        let names = try Speakers.namesInEffect(paths)
        let merges = Speakers.loadMerges(paths)
        var labels: [String] = [], seen = Set<ScalarKey>()
        func add(_ label: String) { if seen.insert(ScalarKey(label)).inserted { labels.append(label) } }
        for d in try turnItems(paths) {
            let speaker = try key(d, "speaker")
            guard case .string(let label) = speaker else { throw PageError("a turn's speaker is no label") }
            add(label)
        }
        names.keys.forEach(add)
        let shared = SharedMic.display(paths, labels: labels)
        var out = PyDict<String>()
        for label in labels {
            out[label] = [shared[label], names[label]].compactMap { $0 }.first { !$0.isEmpty }
                ?? labelDisplay(merges[label] ?? label)
        }
        return out
    }

    /// `_seen`: the items open when the meeting was reviewed (`_need_id`); nil while it is not reviewed.
    static func seen(_ paths: RecordingPaths) throws -> Set<ScalarKey>? {
        guard let review = PythonJSON.read(paths.review), case .object = review else { return nil }
        let items = review["seen"].map { $0.truthy ? $0 : .array([]) } ?? .array([])
        return Set(try iterate(items).compactMap(\.stringValue).map(ScalarKey.init))
    }

    /// `_imported_brief`: for the list, who a meeting was imported from.
    static func importedBrief(_ paths: RecordingPaths) -> JSONValue {
        guard let record = ExchangeHints.loadRecord(paths), record.truthy else { return .null }
        return .object([("from", .string(fromText(record)))])
    }

    /// `str(record.get("from") or "")`.
    static func fromText(_ record: JSONValue) -> String {
        guard let from = record["from"], from.truthy else { return "" }
        return Py.str(from)
    }

    // MARK: - the list

    /// The files a list entry is made of (`_signature`): it is made again when one of them changes.
    static func signatureFiles(_ paths: RecordingPaths, _ app: ServerApp) -> [URL] {
        [paths.meta, paths.transcriptJson, paths.calendar, paths.title, paths.speakers, paths.speakersAuto,
         paths.speakersMerged, paths.speakersIgnored, paths.speakersInferred, paths.speakersRejected,
         paths.speakersShared, paths.speakersUnknown, paths.speakersLines, paths.systemTurns, paths.imported, paths.review, paths.notes,
         paths.myNotes, paths.myNotesImages, app.stores.glossary]
    }

    /// `_list_entry`: a meeting as the list shows it — what it was, who was in it, and what is still to do (speakers
    /// without a name, notes missing or out of date).
    static func listEntry(_ app: ServerApp, _ paths: RecordingPaths) throws -> PyDict<JSONValue> {
        let notes = Notes.load(paths)
        let meta = try meta(paths)
        let event = CalendarEvents.load(paths)
        let raw = try Speakers.withoutIgnored(paths, try utterances(paths))
        let talk = Speakers.talkSeconds(try turns(paths))
        let names = try Speakers.namesInEffect(paths)
        // Speakers worth a name: a few words from someone are no to-do, nor is a room of several people (#56).
        let ignored = Set(Speakers.loadIgnored(paths).map(ScalarKey.init)).union(SharedMic.sharedLabels(paths))
        let lanes = Py.stableSorted(talk.keys.filter { talk[$0]! >= Voices.MIN_TALK_SECONDS && !ignored.contains(ScalarKey($0)) },
                                    by: { talk[$0]! > talk[$1]! })
        var people: [String] = [], named = Set<ScalarKey>()
        for label in lanes {
            if let name = names[label], named.insert(ScalarKey(name)).inserted { people.append(name) }
        }
        let nameless = lanes.filter { names[$0] == nil }
        // No to-do: a voice the user can't name, nor one left unnamed in the review (as in Needs you).
        let unknown = Set(Speakers.loadUnknown(paths).map(ScalarKey.init))
        let seen = try seen(paths) ?? []
        let (title, titleFrom) = Titles.resolve(paths, event: .known(event), meetingNotes: .known(notes), stores: app.stores)
        let status = state(paths)
        let glossary = Glossary.current(stores: app.stores)
        let unnamed = nameless.filter { !unknown.contains(ScalarKey($0)) && !seen.contains(ScalarKey("unnamed|\($0)")) }
        return PyDict([
            ("id", .string(paths.id)),
            ("start", try start(paths, meta)),
            ("duration", meta["duration_seconds"] ?? .null),
            ("status", .string(status)),
            ("finishing", .bool(finishing(paths, status))),
            ("title", .str(title)),
            ("title_from", .str(titleFrom)),
            ("summary", glossary.applyTo(try get(notes, "summary"))),
            ("people", .strings(people)),
            ("unnamed", .int(unnamed.count)),
            ("nameless", .int(nameless.count)),
            ("invited", .strings(event.map { CalendarEvents.candidates($0, userName: "").map(\.name) } ?? [])),
            ("has_notes", .bool(notes != nil)),
            ("imported", importedBrief(paths)),
            ("notes_stale", .bool(!raw.isEmpty && notes != nil && Notes.isStale(paths, raw))),
        ])
    }

    /// api.list_meetings: newest first. The entries come from `app.meetingList` while their files are unchanged; the
    /// status changes without a file changing (a live worker), so it and the projects are read every time.
    public static func listMeetings(app: ServerApp) throws -> [JSONValue] {
        guard isDirectory(app.outputDir) else { return [] }
        let store = ProjectStore(path: app.stores.projects)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: app.outputDir.path)) ?? []
        var out: [JSONValue] = []
        for name in Py.stableSorted(names, by: Py.less).reversed() {
            let folder = app.outputDir.appendingPathComponent(name, isDirectory: true)
            guard RecordingPaths.isRecordingFolderName(name), isDirectory(folder) else { continue }
            let paths = RecordingPaths(folder)
            var entry = try app.meetingList.get(key: folder.path, files: signatureFiles(paths, app)) {
                try listEntry(app, paths)
            }
            let status = state(paths)
            entry["status"] = .string(status)
            entry["finishing"] = .bool(finishing(paths, status))
            entry["projects"] = try projectsOf(store, name)
            out.append(entry.json)
        }
        return out
    }

    /// `_projects_of`: the meeting's projects with how each was given, by name.
    static func projectsOf(_ store: ProjectStore, _ meeting: String) throws -> JSONValue {
        let named = store.projects
        var rows: [(name: String, row: JSONValue)] = []
        for (pid, how) in store.ofMeeting(meeting) {
            guard let project = named[pid] else { continue }
            guard case .string(let name) = try key(project, "name") else { throw PageError("a project's name is no text") }
            guard case .object(let fields) = how else { throw PageError("'\(PyBody.typeName(how))' object is not a mapping") }
            var row = PyDict<JSONValue>([("id", .string(pid)), ("name", .string(name))])
            for (k, v) in fields { row[k] = v }
            row["link"] = Link.fromProject(name, how).toDict()
            rows.append((name, row.json))
        }
        return .array(Py.stableSorted(rows) { Py.less(Py.casefold($0.name), Py.casefold($1.name)) }.map(\.row))
    }
}
