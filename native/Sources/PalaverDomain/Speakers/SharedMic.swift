// Speakers that can't be separated (shared_mic.py, #56): an All Hands on one room microphone, a meeting room joined
// to the call through one device, an in-person meeting recorded with the laptop's microphone. The whole meeting's
// system-track voices are "Several people"; a lane can be a room ("Room", "Room (Raum 3.12)"); the microphone can be a
// room with the user ("Room (with you)"). Such a lane gets no name, teaches the voice bank nothing. The marks live in
// `speakers_shared.json`. The marks as speakers, transcripts and the voice bank read them; the setters, the part and join
// of cut recordings, the series memory (`shared-series.json`) and the suggestion (shared_mic.py:97-161, 286-396).
import Foundation
import PalaverCore

public enum SharedMic {
    public static let ROOM = "Room"
    public static let SEVERAL = "Several people"
    public static let WITH_YOU = "with you"
    /// The label of the microphone's lane in the marks and the API.
    public static let MIC = "mic"
    public static let LINE = "Several people shared one microphone here, so lines aren't assigned to people."
    /// A room's name, at most.
    public static let NAME_LENGTH = 80
    /// Events where one microphone is usually shared by many.
    private static let GATHERING = try! PyRegex(#"\b(all[\s-]?hands|town[\s-]?halls?|all[\s-]?staff|company[\s-]meeting|betriebsversammlung|(?:mitarbeiter|belegschafts|voll)versammlung)\b"#, ignoreCase: true)
    /// A location that is a meeting room ("Raum 3.12", "Besprechungsraum", "Conference Room").
    private static let ROOM_LOCATION = try! PyRegex(#"(room|raum)\b|\bmeeting ?room|\bkonferenz"#, ignoreCase: true)
    /// Many invitees but few voices: at least this many invited ...
    public static let MANY_INVITEES = 8
    /// ... and at most this share of them heard as voices of their own.
    public static let FEW_VOICES_SHARE = 0.25

    /// `room_text`: "Room (name)", or "Room" when the name is blank.
    public static func roomText(_ name: String = "") -> String {
        Py.strip(name).isEmpty ? ROOM : "\(ROOM) (\(name))"
    }

    /// `_names`: a JSON object as label → text (`str(v or "")`); anything else is empty.
    private static func names(_ value: JSONValue?) -> PyDict<String> {
        guard case .object(let fields)? = value else { return PyDict() }
        return PyDict(fields.map { ($0.0, $0.1.truthy ? pyStr($0.1) : "") })
    }

    private static func object(_ d: PyDict<String>) -> JSONValue { .object(d.map { ($0.key, .string($0.value)) }) }

    /// The marks: `meeting`, `lanes` (label → room name), `mic` (the room's name, present while marked), `names` (the
    /// names of rooms marked before, for when they are marked again) and the suggestion `dismissed`. A missing or
    /// broken file is no marks; `lanes` and `names` are always there (appended when the file had none).
    public static func load(_ paths: RecordingPaths) -> PyDict<JSONValue> {
        var data = PythonJSON.read(paths.speakersShared).flatMap { PyDict<JSONValue>($0) } ?? PyDict()
        data["lanes"] = object(names(data["lanes"]))
        data["names"] = object(names(data["names"]))
        if let mic = data["mic"] { data["mic"] = .string(mic.truthy ? pyStr(mic) : "") }
        return data
    }

    /// `save`: the marks without empty objects, nulls and `dismissed: false`, through `speakers_shared.json.tmp`
    /// (`json.dumps(indent=2, ensure_ascii=False)`); no marks left removes the file.
    public static func save(_ paths: RecordingPaths, _ data: PyDict<JSONValue>) throws {
        let kept = PyDict(data.filter { key, value in
            if value.isNull || value == .object([]) { return false }
            return !(key == "dismissed" && value == .bool(false))
        }.map { ($0.key, $0.value) })
        guard !kept.isEmpty else {
            if FileManager.default.fileExists(atPath: paths.speakersShared.path) { try FileManager.default.removeItem(at: paths.speakersShared) }
            return
        }
        try PythonJSON.write(kept.json, to: paths.speakersShared, indent: 2, ensureAscii: false,
                             via: paths.speakersShared.lastPathComponent + ".tmp")
    }

    /// The marks' lanes (label → room name).
    static func lanes(_ data: PyDict<JSONValue>) -> PyDict<String> {
        guard case .object(let fields)? = data["lanes"] else { return PyDict() }
        return PyDict(fields.map { ($0.0, $0.1.stringValue ?? "") })
    }

    public static func meetingMarked(_ paths: RecordingPaths) -> Bool { load(paths)["meeting"] == .bool(true) }

    /// Marked because the event's series is remembered, not by hand here.
    public static func fromSeries(_ paths: RecordingPaths) -> Bool {
        let data = load(paths)
        return data["meeting"] == .bool(true) && data["from_series"] == .bool(true)
    }

    // MARK: - setting the marks (each under the meeting's `.speakers.lock`, reload-change-save)

    /// The whole meeting's voices can't be told apart, or (`on` false) they can after all; that stays so, also for a
    /// series that is remembered.
    public static func setMeeting(_ paths: RecordingPaths, _ on: Bool) throws {
        try StoreLock.meeting(paths) {
            var data = load(paths)
            data["meeting"] = .bool(on)
            _ = data.removeValue(forKey: "from_series")
            try save(paths, data)
        }
    }

    /// `label` (or MIC, the microphone) is a room of several people, or one voice after all. Without a `name` a room
    /// marked again gets the name it had; a name is stripped and cut to NAME_LENGTH scalars.
    public static func setLane(_ paths: RecordingPaths, _ label: String, _ on: Bool, name: String? = nil) throws {
        try StoreLock.meeting(paths) {
            var data = load(paths)
            var lanes = Self.lanes(data), names = Self.names(data["names"])
            let current: String?
            if label == MIC { current = data.removeValue(forKey: "mic")?.stringValue } else { current = lanes.removeValue(forKey: label) }
            if on {
                let stale = names.removeValue(forKey: label)
                let given = Py.strip(name ?? stale ?? "")
                let room = String(String.UnicodeScalarView(given.unicodeScalars.prefix(NAME_LENGTH)))
                _ = names.removeValue(forKey: label)
                if label == MIC { data["mic"] = .string(room) } else { lanes[label] = room }
            } else if let current, !current.isEmpty {
                names[label] = current
            }
            data["lanes"] = object(lanes)
            data["names"] = object(names)
            try save(paths, data)
        }
    }

    /// The lanes' labels mean other voices now (diarized again); the microphone is still the microphone.
    public static func forgetLanes(_ paths: RecordingPaths) throws {
        try StoreLock.meeting(paths) {
            var data = load(paths)
            let kept = names(data["names"]).filter { $0.key == MIC }
            data["lanes"] = .object([])
            data["names"] = object(PyDict(kept.map { ($0.key, $0.value) }))
            try save(paths, data)
        }
    }

    /// The marks of one part of a split recording (`data`: the whole's): each part keeps the rooms among its own
    /// voices. The rest is the meeting's: the head keeps it; the tail starts without (its own event decides a series
    /// mark).
    public static func splitPart(_ data: PyDict<JSONValue>, labels: Set<ScalarKey>, head: Bool) -> PyDict<JSONValue> {
        func fields(_ key: String) -> [(String, JSONValue)] {
            if case .object(let f)? = data[key] { return f } else { return [] }
        }
        let lanes = JSONValue.object(fields("lanes").filter { labels.contains(ScalarKey($0.0)) })
        let names = JSONValue.object(fields("names").filter { labels.contains(ScalarKey($0.0)) || (head && $0.0 == MIC) })
        guard head else { return PyDict([("lanes", lanes), ("names", names)]) }
        var out = data
        out["lanes"] = lanes
        out["names"] = names
        return out
    }

    /// Another recording's marks (`data`) joined into this one, its labels `relabel`-ed. A room in either part stays a
    /// room.
    public static func joinFrom(_ paths: RecordingPaths, _ data: PyDict<JSONValue>, relabel: PyDict<String>) throws {
        func fields(_ key: String) -> [(String, JSONValue)] {
            if case .object(let f)? = data[key] { return f } else { return [] }
        }
        try StoreLock.meeting(paths) {
            var own = load(paths)
            var lanes = PyDict<JSONValue>(own["lanes"]!) ?? PyDict(), names = PyDict<JSONValue>(own["names"]!) ?? PyDict()
            for (k, v) in fields("lanes") { lanes[relabel[k] ?? k] = v }
            own["lanes"] = lanes.json
            for (k, v) in fields("names") where names[relabel[k] ?? k] == nil { names[relabel[k] ?? k] = v }
            own["names"] = names.json
            if let mic = data["mic"], own["mic"] == nil { own["mic"] = mic }
            for key in ["meeting", "from_series", "dismissed"] where own[key] == nil {
                if let v = data[key] { own[key] = v }
            }
            try save(paths, own)
        }
    }

    /// A room merged into a voice makes that voice the room: degrading honestly beats a wrong name. The room's name
    /// goes along when the voice's room has none. (No lock of its own: `Speakers.mergeSpeakers` holds the meeting's.)
    public static func followMerges(_ paths: RecordingPaths) throws {
        var data = load(paths)
        var lanes = lanes(data)
        var changed = false
        for (label, into) in Speakers.loadMerges(paths) {
            guard let room = lanes[label] else { continue }
            if lanes[into] == nil || (lanes[into]!.isEmpty && !room.isEmpty) {
                lanes[into] = room
                changed = true
            }
        }
        if changed {
            data["lanes"] = object(lanes)
            try save(paths, data)
        }
    }

    /// label → the room's name ("" when it has none), for lanes marked by hand.
    public static func roomNames(_ paths: RecordingPaths) -> PyDict<String> { lanes(load(paths)) }

    /// `_turns`: system_turns.json as a list, or none.
    private static func turns(_ paths: RecordingPaths) -> [JSONValue] {
        PythonJSON.read(paths.systemTurns)?.arrayValue ?? []
    }

    /// `_labels`: the system track's labels, from its turns and its voices (each once, by code points).
    static func labelList(_ paths: RecordingPaths) -> [String] {
        var out: [String] = [], seen = Set<ScalarKey>()
        func add(_ label: String) { if seen.insert(ScalarKey(label)).inserted { out.append(label) } }
        for d in turns(paths) {
            if case .object = d, let speaker = d["speaker"] { add(pyStr(speaker)) }
        }
        switch PythonJSON.read(paths.speakerEmbeddings) {
        case .object(let fields)?: fields.forEach { add($0.0) }
        case .array(let items)?: items.forEach { add(pyStr($0)) }
        case .string(let s)?: s.unicodeScalars.forEach { add(String($0)) }
        default: break
        }
        return out
    }

    static func labels(_ paths: RecordingPaths) -> Set<ScalarKey> { Set(labelList(paths).map(ScalarKey.init)) }

    /// label → what to show instead of a person, for every voice of the system track that can't be told apart
    /// (`labels`, else the track's own). A label merged into a room is that room, and a room merged into a voice keeps
    /// it a room. Labels in code-point order (Python's come in set order; only lookups use them).
    public static func display(_ paths: RecordingPaths, labels given: [String]? = nil) -> PyDict<String> {
        guard FileManager.default.fileExists(atPath: paths.speakersShared.path) else { return PyDict() }
        let data = load(paths)
        let merges = Speakers.loadMerges(paths)
        let lanes = lanes(data)
        let all = given ?? labelList(paths)
        var out = PyDict<String>()
        for label in Py.stableSorted(all, by: Py.less) {
            let into = merges[label] ?? label
            let sources = merges.filter { Py.same($0.value, into) && lanes[$0.key] != nil }.map(\.key)
            if data["meeting"] == .bool(true) {
                out[label] = SEVERAL
            } else if lanes[into] != nil || lanes[label] != nil || !sources.isEmpty {
                let names = [lanes[into] ?? "", lanes[label] ?? ""] + sources.map { lanes[$0]! }
                out[label] = roomText(names.first { !$0.isEmpty } ?? "")
            }
        }
        return out
    }

    /// The labels `display` covers.
    public static func sharedLabels(_ paths: RecordingPaths) -> Set<ScalarKey> { Set(display(paths).keys.map(ScalarKey.init)) }

    /// Whether anyone spoke on the system track (at least MIN_TALK_SECONDS, removed voices aside): a call. Without it
    /// the recording is of the room around the Mac (in person).
    public static func systemSpeech(_ paths: RecordingPaths) -> Bool {
        let ignored = Set(Speakers.loadIgnored(paths).map(ScalarKey.init))
        var spans: [Double] = []
        for d in turns(paths) {
            guard case .object = d else { continue }
            if case .string(let s)? = d["speaker"], ignored.contains(ScalarKey(s)) { continue }
            spans.append((VoiceMath.pyFloat(d["end"]) ?? 0) - (VoiceMath.pyFloat(d["start"]) ?? 0))
        }
        return Py.sum(spans) >= Voices.MIN_TALK_SECONDS  // Python's sum(), compensated
    }

    /// The room's name when several people sat at the microphone ("" when it has none): marked so, or the whole
    /// meeting marked in person. nil: the microphone is the user's.
    public static func micRoom(_ paths: RecordingPaths) -> String? {
        guard FileManager.default.fileExists(atPath: paths.speakersShared.path) else { return nil }
        let data = load(paths)
        if let mic = data["mic"] { return mic.stringValue ?? "" }
        if data["meeting"] == .bool(true) && !systemSpeech(paths) { return "" }
        return nil
    }

    /// What the microphone's lines show instead of the user's name: "Room (with you)", or the room's name; nil while
    /// they are the user's.
    public static func micDisplay(_ paths: RecordingPaths) -> String? {
        micRoom(paths).map { roomText($0.isEmpty ? WITH_YOU : $0) }
    }

    /// Whether any voice of the meeting is marked as several people now.
    public static func marked(_ paths: RecordingPaths) -> Bool { !display(paths).isEmpty || micRoom(paths) != nil }

    /// `utterances` as they are shown and summarized: the microphone's lines as the room, while several people sat at
    /// it (transcript.json keeps the user's name on them, so they stay the microphone's lines).
    public static func shown(_ paths: RecordingPaths, _ utterances: [Utterance]) -> [Utterance] {
        micLines(utterances, micDisplay(paths), labels(paths))
    }

    /// `utterances` with the microphone's lines (no diarization label) shown as `displayName`: lines kept, speaker
    /// replaced.
    public static func micLines(_ utterances: [Utterance], _ displayName: String?, _ labels: Set<ScalarKey>) -> [Utterance] {
        guard let displayName else { return utterances }
        return utterances.map { u in
            // A line said to be a person's (#12) is no microphone line, though it has no label.
            guard u.label == nil, u.saidBy == nil, !labels.contains(ScalarKey(u.speaker)) else { return u }
            return Utterance(speaker: displayName, start: u.start, end: u.end, text: u.text, heard: u.heard, unsure: u.unsure,
                             heardAs: u.heardAs)
        }
    }

    // MARK: - a recurring event remembered (shared-series.json: event series id → {"title"})

    /// The remembered series: the store's object, or empty when it is missing, broken or not an object.
    private static func series(_ stores: StorePaths) -> PyDict<JSONValue> {
        PythonJSON.read(stores.sharedSeries).flatMap { PyDict<JSONValue>($0) } ?? PyDict()
    }

    /// Only a recurring event with an id has next meetings to mark.
    public static func canRemember(_ event: CalendarEvent?) -> Bool {
        guard let event else { return false }
        return event.series && !event.seriesId.isEmpty
    }

    public static func remembered(_ event: CalendarEvent?, stores: StorePaths = .current()) -> Bool {
        guard let event, canRemember(event) else { return false }
        return series(stores)[event.seriesId] != nil
    }

    /// Every next meeting of `event`'s series starts out marked (or no longer does). Under the store's lock.
    public static func remember(_ event: CalendarEvent?, _ on: Bool, stores: StorePaths = .current()) throws {
        guard let event, canRemember(event) else { throw SpeakersValueError(description: "only a recurring calendar event can be remembered") }
        let path = stores.sharedSeries
        try StoreLock.with(path) {
            var data = series(stores)
            if on { data[event.seriesId] = .object([("title", .string(event.title))]) } else { _ = data.removeValue(forKey: event.seriesId) }
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PythonJSON.write(data.json, to: path, indent: 2, ensureAscii: false, via: path.lastPathComponent + ".tmp")
        }
    }

    /// Mark a meeting whose event is of a remembered series, unless the user already said for this meeting; a mark
    /// that came from a series goes when the meeting's event is no longer of a remembered one. Returns whether the
    /// meeting is marked from its series now.
    public static func applySeries(_ paths: RecordingPaths, event: CalendarEvent?, stores: StorePaths = .current()) throws -> Bool {
        try StoreLock.meeting(paths) {
            var data = load(paths)
            let known = remembered(event, stores: stores)
            if data["from_series"]?.truthy == true && !known {
                _ = data.removeValue(forKey: "meeting")
                _ = data.removeValue(forKey: "from_series")
                try save(paths, data)
                return false
            }
            if data["meeting"] != nil || !known { return data["from_series"]?.truthy == true }
            data["meeting"] = .bool(true)
            data["from_series"] = .bool(true)
            try save(paths, data)
            return true
        }
    }

    // MARK: - suggesting the mark

    /// The cheap hints that one microphone was shared: logged for every meeting, to calibrate the thresholds on real
    /// recordings later.
    public struct Signals: Equatable {
        public var gathering: Bool
        public var room: Bool
        public var invitees: Int
        public var voices: Int
        public var fewVoices: Bool

        /// The log's / API's object, in Python's key order.
        public var json: JSONValue {
            .object([("gathering", .bool(gathering)), ("room", .bool(room)), ("invitees", .int(invitees)),
                     ("voices", .int(voices)), ("few_voices", .bool(fewVoices))])
        }
    }

    /// `signals`. A missing or unparsable system_turns.json is no turns; turns it can't read (Python's KeyError,
    /// TypeError) throw, as the processing step logs "shared_mic_signals_failed" for.
    public static func signals(_ paths: RecordingPaths, event: CalendarEvent?, userName: String = "") throws -> Signals {
        var turns: [SpeakerTurn] = []
        if let raw = PythonJSON.read(paths.systemTurns) {
            guard case .array(let items) = raw else { throw SpeakersValueError(description: "system_turns.json is not a list") }
            turns = try items.map { try SpeakerTurn(json: $0) }
        }
        let ignored = Set(Speakers.loadIgnored(paths).map(ScalarKey.init))
        let talk = Speakers.talkSeconds(Speakers.mergedTurns(turns, Speakers.loadMerges(paths)))
        let voices = talk.filter { $0.value >= Voices.MIN_TALK_SECONDS && !ignored.contains(ScalarKey($0.key)) }.count
        let invitees = event.map { CalendarEvents.candidates($0, userName: userName).count } ?? 0
        let room = event.map { e in e.attendees.contains { $0.isRoom } || ROOM_LOCATION.firstMatch(in: e.location) != nil } ?? false
        return Signals(gathering: event.map { GATHERING.firstMatch(in: $0.title) != nil } ?? false, room: room,
                       invitees: invitees, voices: voices,
                       fewVoices: invitees >= MANY_INVITEES && Double(voices) <= Double(invitees) * FEW_VOICES_SHARE)
    }

    /// "No, each voice is one person" (`dismissed` true), or its undo.
    public static func dismissSuggestion(_ paths: RecordingPaths, _ dismissed: Bool = true) throws {
        try StoreLock.meeting(paths) {
            var data = load(paths)
            data["dismissed"] = .bool(dismissed)
            try save(paths, data)
        }
    }

    /// Why the meeting may be one where voices can't be told apart, when the hints are strong: an All Hands or Town
    /// Hall, or a meeting room with many invitees but few voices. A meeting room alone is not (rooms are booked for
    /// calls everyone joins on their own), nor are many quiet invitees (a webinar). nil once the user marked anything
    /// or said no.
    public static func suggestion(_ paths: RecordingPaths, event: CalendarEvent?, userName: String = "") throws -> String? {
        let data = load(paths)
        if data["dismissed"]?.truthy == true || data["meeting"] != nil || !lanes(data).isEmpty { return nil }
        let found = try signals(paths, event: event, userName: userName)
        if found.gathering, let event { return "The calendar calls it \u{201C}\(event.title)\u{201D}." }
        if found.room && found.fewVoices {
            return "A meeting room was booked, and \(found.invitees) people were invited but only \(found.voices) voices were heard."
        }
        return nil
    }
}
