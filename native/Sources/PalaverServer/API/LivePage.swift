// A meeting while it is recorded (api.py `_live_meeting`, `live_stream`, :473-590): the page from what the
// live worker has so far (live.json), and the realtime stream's newest lines (stream.json, #42). Both
// files are rewritten by other processes while they are read here (atomically, through `<name>.tmp`);
// they are read once, without a lock, and a file that is no JSON reads as Python's `_read_json` default.
import Foundation
import PalaverCore
import PalaverDomain

public enum LivePage {
    /// A stream.json not rewritten for this long is a stream gone.
    public static let STREAM_STALE_SECONDS = 10.0

    // MARK: - the page

    /// `_live_meeting`: text, provisional speakers, names by voice (the voice bank, or given while recording).
    static func meeting(app: ServerApp, paths: RecordingPaths) throws -> PyDict<JSONValue> {
        let userName = app.userName
        let live = PythonJSON.read(paths.live) ?? .object([])
        guard case .object = live else { throw PageError("'\(PyBody.typeName(live))' object has no attribute 'get'") }
        func items(_ key: String) throws -> [JSONValue] { try live[key].map(MeetingsAPI.iterate) ?? [] }
        let turns = try items("turns").map { try SpeakerTurn(json: $0) }
        let raw = Merger.merge(mic: try items("mic").map { try Segment(json: $0) },
                               system: try items("system").map { try Segment(json: $0) }, turns: turns)
        let embeddings = live["embeddings"] ?? .object([])
        guard case .object(let voices) = embeddings else {
            throw PageError("'\(PyBody.typeName(embeddings))' object has no attribute 'items'")
        }
        let talk = Speakers.talkSeconds(turns)
        let bank = VoiceBank(directory: app.stores.voices)
        let invited = CalendarEvents.invitedNames(paths, try bank.names().keys, userName: userName)
        var recognized = PyDict<(String, Double)>()
        if embeddings.truthy {  // a short talker's voice is never read (recognize skips it first)
            let vectors = PyDict(try voices.map { v in
                (v.0, (talk[v.0] ?? 0.0) < Voices.MIN_TALK_SECONDS ? [] : try vector(v.1))
            })
            recognized = try Voices.recognize(vectors, talk: talk, bank: bank, invited: invited)
        }
        let given = Speakers.loadLiveNames(paths)
        let named = given.isEmpty ? PyDict<String>() : try Speakers.matchLiveNames(
            PyDict(try voices.map { ($0.0, try vector($0.1)) }), given)
        var names = PyDict<String>()
        for (label, hit) in recognized { names[label] = hit.0 }
        for (label, name) in named { names[label] = name }

        var labels: [String] = [], seen = Set<ScalarKey>()
        for label in talk.keys + raw.map(\.speaker).filter({ !Py.same($0, userName) })
            where seen.insert(ScalarKey(label)).inserted { labels.append(label) }
        labels = Py.stableSorted(labels) { a, b in
            let ta = talk[a] ?? 0.0, tb = talk[b] ?? 0.0
            return ta != tb ? -ta < -tb : Py.less(a, b)
        }
        var display = PyDict<String>()
        for label in labels { display[label] = names[label].flatMap { $0.isEmpty ? nil : $0 } ?? MeetingsAPI.labelDisplay(label) }
        let glossary = Glossary.current(stores: app.stores)
        let utterances = Readable.readable(Speakers.applySpeakerNames(raw, display), glossary: glossary)

        let mine = utterances.filter { Py.same($0.speaker, userName) && ($0.label ?? "").isEmpty }
        var speakers: [JSONValue] = [.object([
            ("label", .null), ("name", .string(userName)), ("display", .string(userName)), ("is_user", .bool(true)),
            ("clips", .array([])),
            ("talk_seconds", mine.isEmpty ? .int(0) : .double(Py.round(Py.sum(mine.map { $0.end - $0.start }), 1))),
        ])]
        for label in labels {
            let auto = recognized[label]
            speakers.append(.object([
                ("label", .string(label)), ("name", .str(names[label])), ("display", .string(display[label]!)),
                ("is_user", .bool(false)),
                ("named_by", named[label] != nil ? .string("you") : auto != nil ? .string("voice") : .null),
                ("recognized", auto.map { .object([("name", .string($0.0)), ("similarity", .double(Py.round($0.1, 2)))]) } ?? .null),
                ("guesses", .array([])), ("maybe", .array([])), ("merged", .array([])), ("clips", .array([])),
                ("talk_seconds", .double(Py.round(talk[label] ?? 0.0, 1))),
            ]))
        }
        let event = CalendarEvents.load(paths)
        let (title, titleFrom) = Titles.resolve(paths, event: .known(event), meetingNotes: .known(nil), stores: app.stores)
        let transcript: [JSONValue] = utterances.map { u in
            let label = u.label.flatMap { $0.isEmpty ? nil : $0 } ?? (Py.same(u.speaker, userName) ? nil : u.speaker)
            return .object([
                ("speaker", .string(u.speaker)), ("label", .str(label)),
                ("start", .double(Py.round(u.start, 2))), ("end", .double(Py.round(u.end, 2))),
                ("text", .string(u.text)), ("glossed", MeetingsAPI.glossed(u)),
            ])
        }
        var page = PyDict<JSONValue>([
            ("id", .string(paths.id)),
            ("title", .str(title)),
            ("title_from", .str(titleFrom)),
            ("calendar", try MeetingsAPI.calendar(app, event, used: Set(names.values.map(ScalarKey.init)), link: nil)),
            ("start", try MeetingsAPI.start(paths, try MeetingsAPI.meta(paths))),
            ("duration", .null),
            ("status", .string("recording")),
            ("live", .object([("until", live["until"] ?? .int(0))])),
            ("notes", .null),
            ("notes_stale", .bool(false)),
            ("notes_stale_reason", .null),
            ("my_notes_revision", .string(MyNotes.revision(paths.folder))),
            ("speakers", .array(speakers)),
            ("transcript", .array(transcript)),
            ("has_audio", .bool(false)),
        ])
        for (k, v) in try MeetingsAPI.meetingProjects(app, paths.id) { page[k] = v }
        return page
    }

    // MARK: - the stream

    /// api.live_stream: settled sentences starting at `since` or later, both tracks by time, read the way the
    /// transcript is (fillers out, glossary applied), plus the drafts. Without a stream `{"stream": false}`, with
    /// `"starting": true` while a stream runs but has not written yet (its model loads), or `"stale": true` once
    /// stream.json has not been rewritten for STREAM_STALE_SECONDS (the stream died). `now`: seconds since 1970.
    public static func stream(app: ServerApp, id: String, since: Double, now: Double? = nil) throws -> JSONValue {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        guard let stream = PythonJSON.read(paths.stream), case .object = stream else {
            if !MeetingsAPI.exists(paths.stream) && WorkerPids.streamRunning(paths.folder) {
                return .object([("stream", .bool(false)), ("starting", .bool(true))])
            }
            return .object([("stream", .bool(false))])
        }
        if let updated = number(stream["updated_at"]),
           (now ?? Date().timeIntervalSince1970) - updated > STREAM_STALE_SECONDS {
            return .object([("stream", .bool(false)), ("stale", .bool(true))])
        }
        let userName = app.userName
        let glossary = Glossary.current(stores: app.stores)
        // Each line with its start and end as stream.json has them: `round` keeps an int an int.
        var raw: [(u: Utterance, start: JSONValue, end: JSONValue)] = []
        for track in ["mic", "system"] {
            guard case .array(let found)? = stream[track] else { continue }
            for d in found {
                guard case .object = d, let start = number(d["start"]), let end = number(d["end"]),
                      case .string(let text)? = d["text"], start >= since else { continue }
                let u = track == "mic"
                    ? Utterance(speaker: userName, start: start, end: end, text: text)
                    : Utterance(speaker: "Others", start: start, end: end, text: text, label: "stream")
                raw.append((u, d["start"]!, d["end"]!))
            }
        }
        func rounded(_ v: JSONValue) -> JSONValue {
            if case .double(let x) = v { return .double(Py.round(x, 2)) }
            return v
        }
        var lines: [JSONValue] = []
        for line in Py.stableSorted(raw, by: { ($0.u.start, $0.u.end) < ($1.u.start, $1.u.end) }) {
            guard let u = Readable.readable([line.u], glossary: glossary).first else { continue }  // filler only
            lines.append(.object([
                ("speaker", .string(u.speaker)), ("label", .str(u.label)), ("start", rounded(line.start)),
                ("end", rounded(line.end)), ("text", .string(u.text)), ("glossed", MeetingsAPI.glossed(u)),
            ]))
        }
        let draft = stream["draft"].flatMap { d -> JSONValue? in if case .object = d { return d } else { return nil } }
        func clean(_ text: JSONValue?) -> JSONValue {
            guard case .string(let t)? = text else { return .string("") }
            return .string(Readable.readable([Utterance(speaker: "", start: 0, end: 0, text: t)], glossary: glossary).first?.text ?? "")
        }
        let until = stream["until"].flatMap { number($0) != nil ? $0 : nil } ?? .int(0)
        let speaking = stream["speaking"].flatMap { s -> JSONValue? in if case .object = s { return s } else { return nil } }
        let questions = stream["questions"].flatMap { q -> JSONValue? in if case .array = q { return q } else { return nil } }
        return .object([
            ("stream", .bool(true)),
            ("until", until),
            ("lines", .array(lines)),
            ("draft", .object([("system", clean(draft?["system"])), ("mic", clean(draft?["mic"]))])),
            ("speaking", speaking ?? .object([])),
            ("questions", questions ?? .array([])),
        ])
    }

    /// `np.asarray(value, dtype=float)` of a live voice: a list of ints, floats and booleans.
    static func vector(_ value: JSONValue) throws -> [Double] {
        guard case .array(let items) = value else { throw PageError("a live voice is not a list of numbers") }
        return try items.map { item in
            switch item {
            case .double(let d): return d
            case .int(let i): return Double(i)
            case .bool(let b): return b ? 1 : 0
            default: throw PageError("a live voice is not a list of numbers")
            }
        }
    }

    /// `_is_number`: an int or a float, never a bool.
    static func number(_ v: JSONValue?) -> Double? {
        switch v {
        case .int(let i)?: return Double(i)
        case .double(let x)?: return x
        default: return nil
        }
    }

    /// The `since=` of a stream request: Python's `float()` of the first value, 0 where that raises.
    static func since(_ request: Request) -> Double {
        Py.float(request.queryValue("since") ?? "0") ?? 0.0
    }
}

extension Router {
    /// The realtime stream's tail (server.py's `/api/meetings/{id}/stream`).
    static func addLiveRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/meetings/([^/]+)/stream") { request, m in
            .json(try LivePage.stream(app: app, id: m.group(1)!, since: LivePage.since(request)))
        }
    }
}
