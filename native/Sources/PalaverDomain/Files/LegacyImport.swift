// Meetings from before Palaver (issue #4): a Notion AI meeting note — title, start, attendees, Notion's own summary
// and its transcript — taken in as a meeting folder like a recording's, without audio. Palaver never talks to Notion
// for this: Claude (with the user's Notion connector) fetches the note and hands it over, through the MCP tool
// `import_meeting` or a JSON file for `palaver import`.
//
// What is written is what a recording leaves, so the rest of the app needs few special cases:
// - meta.json: the start (on this Mac's clock), end, duration, trigger "import".
// - transcript.json and system_turns.json: one line per paragraph, its times spread over the meeting by word count
//   (Notion's transcript has no times), all of one voice, SPEAKER_00, marked "Don't Know Who This Is"
//   (speakers_unknown.json): there is nothing to tell the speakers apart by, and no audio for voice actions.
// - notes.json: Notion's summary in the notes' shape, with `"source": "notion"` and the transcript's hash, so the notes
//   are current and no model run redoes them unless the user asks.
// - calendar.json: only with attendees (that is how a meeting's people are known), names without emails.
// - source.json: where it came from and a hash of its content, for the mark in the window and for dedupe.
//
// The same note twice (its id, or its content) and a note of a call Palaver recorded itself are not imported.
import CryptoKit
import Darwin
import Foundation
import PalaverCore

/// A meeting note from another app, as Claude or a JSON file hands it over.
public struct LegacyNote: Equatable, Sendable {
    public var title: String
    public var start: ExchangeTime
    public var end: ExchangeTime?
    /// Names, as the source lists them (no emails).
    public var attendees: [String]
    /// The source's summary as Markdown (Notion: "### Action Items" with "- [ ] …", then topic sections of bullets).
    public var summary: String
    /// Plain paragraphs separated by blank lines.
    public var transcript: String
    /// "notion".
    public var sourceKind: String
    public var sourceURL: String
    public var sourceId: String

    public init(title: String = "", start: ExchangeTime, end: ExchangeTime? = nil, attendees: [String] = [],
                summary: String = "", transcript: String = "", sourceKind: String = LegacyImport.NOTION,
                sourceURL: String = "", sourceId: String = "") {
        self.title = title; self.start = start; self.end = end; self.attendees = attendees; self.summary = summary
        self.transcript = transcript; self.sourceKind = sourceKind; self.sourceURL = sourceURL; self.sourceId = sourceId
    }

    /// One note from JSON (a file's, or the MCP tool's arguments): `title`, `start` and `end` (ISO 8601 with an
    /// offset), `attendees` (names), `summary`, `transcript`, and `source` {kind, url, id} (or `source_kind`,
    /// `source_url`, `source_id`). Throws `ExchangeRejected` with what is wrong, in words for the user.
    public init(json: JSONValue) throws {
        guard case .object = json else { throw ExchangeRejected("A meeting note is a JSON object.") }
        func text(_ key: String, in value: JSONValue = json) throws -> String {
            switch value[key] {
            case nil, .null?: return ""
            case .string(let s)?: return s
            default: throw ExchangeRejected("\(key) is not text.")
            }
        }
        let startText = Py.strip(try text("start"))
        guard !startText.isEmpty else { throw ExchangeRejected("start is missing (the note's created time, e.g. 2026-03-04T10:00:00+01:00).") }
        start = try JSONSchemaCheck.time(startText, where: "start")
        let endText = Py.strip(try text("end"))
        end = endText.isEmpty ? nil : try JSONSchemaCheck.time(endText, where: "end")
        title = Titles.clean(try text("title"))
        switch json["attendees"] {
        case nil, .null?: attendees = []
        case .array(let items)?:
            attendees = try items.compactMap { item -> String? in
                guard case .string(let name) = item else { throw ExchangeRejected("attendees are names (text).") }
                let clean = Py.split(name).joined(separator: " ")
                return clean.isEmpty ? nil : clean
            }
        default: throw ExchangeRejected("attendees is a list of names.")
        }
        summary = try text("summary")
        transcript = try text("transcript")
        let source = json["source"] ?? .null
        switch source {
        case .null:
            sourceKind = Py.strip(try text("source_kind"))
            sourceURL = Py.strip(try text("source_url"))
            sourceId = Py.strip(try text("source_id"))
        case .object:
            sourceKind = Py.strip(try text("kind", in: source))
            sourceURL = Py.strip(try text("url", in: source))
            sourceId = Py.strip(try text("id", in: source))
        default: throw ExchangeRejected("source is an object {kind, url, id}.")
        }
        if sourceKind.isEmpty { sourceKind = LegacyImport.NOTION }
        try LegacyImport.check(self)
    }
}

/// What became of a note: imported as a meeting, there already (an earlier import of it), or recorded by Palaver.
public struct LegacyImported: Equatable, Sendable {
    public enum Outcome: String, Sendable { case imported, already, recorded }
    public let outcome: Outcome
    /// The meeting: the new one, the earlier import or the recording.
    public let id: String
    public let title: String

    public init(outcome: Outcome, id: String, title: String) { self.outcome = outcome; self.id = id; self.title = title }

    /// One line for the user: "imported 2026-03-04T10-00-00 (Weekly sync)".
    public var line: String {
        let named = title.isEmpty ? "" : " (\(title))"
        switch outcome {
        case .imported: return "imported \(id)\(named)"
        case .already: return "already there: \(id)\(named)"
        case .recorded: return "recorded by Palaver: \(id)\(named) — not imported again"
        }
    }

    /// The answer for Claude: what happened, and the meeting id.
    public var json: JSONValue {
        .object([("status", .string(outcome.rawValue)), ("meeting_id", .string(id)), ("title", .string(title)),
                 ("message", .string(line))])
    }
}

public enum LegacyImport {
    public static let NOTION = "notion"
    /// The one voice of an imported transcript.
    public static let LABEL = "SPEAKER_00"
    /// What its lane shows while it has no name.
    public static let SPEAKERS = "Unknown speakers"
    public static let TRIGGER = "import"
    /// Words a minute, to estimate how long a meeting without an end took.
    public static let WORDS_PER_MINUTE = 150.0
    /// A recording that started this close to a note's start is the same call (the calendar match's slack).
    public static let SAME_CALL_SECONDS = 300.0
    /// A meeting lasts at most this long (an exported one too).
    static let MAX_SECONDS = Double(JSONSchemaCheck.MAX_SECONDS)

    // MARK: - reading what is stored

    /// source.json of an imported meeting; nil for a recording.
    public static func source(_ paths: RecordingPaths) -> JSONValue? {
        guard let v = PythonJSON.read(paths.source), case .object = v else { return nil }
        return v
    }

    public static func isLegacy(_ paths: RecordingPaths) -> Bool { FileManager.default.fileExists(atPath: paths.source.path) }

    /// The source as the window shows it: {kind, url} (a url only when it is a web link), nil for a recording.
    public static func brief(_ paths: RecordingPaths) -> JSONValue? {
        guard let s = source(paths) else { return nil }
        return .object([("kind", .string(s["kind"]?.stringValue ?? NOTION)), ("url", .str(webLink(s["url"]?.stringValue))),
                        ("imported_at", s["imported_at"] ?? .null)])
    }

    /// `url` when it is an http(s) link, else nil: nothing else is offered to open.
    static func webLink(_ url: String?) -> String? {
        guard let url, let scheme = URL(string: url)?.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    // MARK: - checking a note

    static func check(_ note: LegacyNote) throws {
        if let end = note.end {
            let seconds = Double(end.epochMicroseconds - note.start.epochMicroseconds) / 1e6
            if seconds <= 0 { throw ExchangeRejected("end is not after start.") }
            if seconds > MAX_SECONDS { throw ExchangeRejected("The meeting lasts longer than \(JSONSchemaCheck.MAX_SECONDS / 3600) hours.") }
        }
        if Py.strip(note.transcript).isEmpty && Py.strip(note.summary).isEmpty {
            throw ExchangeRejected("The note has neither a transcript nor a summary.")
        }
        if !note.sourceURL.isEmpty && webLink(note.sourceURL) == nil {
            throw ExchangeRejected("source url is not a web link.")
        }
    }

    // MARK: - the transcript

    /// The transcript's paragraphs: separated by blank lines, each on one line.
    public static func paragraphs(_ transcript: String) -> [String] {
        var out: [String] = [], current: [String] = []
        func flush() {
            let joined = current.flatMap(Py.split).joined(separator: " ")
            if !joined.isEmpty { out.append(joined) }
            current = []
        }
        for line in transcript.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if Py.strip(line).isEmpty { flush() } else { current.append(line) }
        }
        flush()
        return out
    }

    /// How long the meeting took: its end when given, else its words at WORDS_PER_MINUTE (a minute at least).
    static func duration(_ note: LegacyNote, words: Int) -> Double {
        if let end = note.end { return Double(end.epochMicroseconds - note.start.epochMicroseconds) / 1e6 }
        return min(MAX_SECONDS, max(60, (Double(words) / WORDS_PER_MINUTE * 60).rounded()))
    }

    /// One line per paragraph, its start and end where its words fall in the meeting.
    public static func utterances(_ paragraphs: [String], duration: Double) -> [Utterance] {
        let counts = paragraphs.map { max(1, Py.split($0).count) }
        let total = Double(counts.reduce(0, +))
        var before = 0, out: [Utterance] = []
        for (text, n) in zip(paragraphs, counts) {
            let start = Py.round(duration * Double(before) / total, 2)
            before += n
            let end = Py.round(duration * Double(before) / total, 2)
            out.append(Utterance(speaker: LABEL, start: start, end: end, text: text))
        }
        return out
    }

    // MARK: - the summary

    private static let citation = try! PyRegex(#"\s*\[\^[^\]]*\]"#)
    private static let tag = try! PyRegex(#"</?[A-Za-z][^>]*>"#)
    private static let heading = try! PyRegex(#"^\s*#{1,6}\s+(.*)$"#)
    private static let bullet = try! PyRegex(#"^(\s*)(?:[-*+]|\d+[.)])\s+(.*)$"#)
    private static let checkbox = try! PyRegex(#"^\[[ xX]\]\s*(.*)$"#)
    /// "Valerie: send the offer", "Timo Strauß: …": an owner of one to four capitalized words.
    private static let ownerFirst = try! PyRegex(#"^((?:[A-ZÄÖÜ][\w'.-]*)(?:\s+[A-ZÄÖÜ][\w'.-]*){0,3})\s*:\s+(.+)$"#)
    /// "Send the offer (Valerie)".
    private static let ownerLast = try! PyRegex(#"^(.+?)\s+\(((?:[A-ZÄÖÜ][\w'.-]*)(?:\s+[A-ZÄÖÜ][\w'.-]*){0,2})\)$"#)
    /// Headings whose items are next steps.
    static let ACTION_HEADINGS: Set<String> = ["action items", "action item", "next steps", "to-dos", "todos", "to do",
                                               "to-do", "tasks", "aufgaben", "nächste schritte", "action points"]

    /// A line of the summary as text: Notion's citations (` [^https://…]`), tags (`<b>`) and Markdown emphasis out.
    static func clean(_ line: String) -> String {
        var s = (try? citation.sub("", in: line)) ?? line
        s = (try? tag.sub("", in: s)) ?? s
        s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return Py.split(s).joined(separator: " ")
    }

    /// A next step's owner and task: "Valerie: send the offer" and "Send the offer (Valerie)" name an owner.
    static func step(_ text: String) -> JSONValue {
        if let m = ownerFirst.fullMatch(text), let owner = m.group(1), let task = m.group(2) {
            return .object([("owner", .string(owner)), ("task", .string(task))])
        }
        if let m = ownerLast.fullMatch(text), let task = m.group(1), let owner = m.group(2) {
            return .object([("owner", .string(owner)), ("task", .string(task))])
        }
        return .object([("owner", .string("")), ("task", .string(text))])
    }

    /// The source's summary in the notes' shape: the lead text (else the topics) as the summary, each heading a section
    /// of points (nested bullets their details), checkboxes and the items under "Action Items" as next steps.
    public static func notes(fromSummary markdown: String) -> (summary: String, sections: [JSONValue], nextSteps: [JSONValue]) {
        struct Section { var heading: String; var points: [(text: String, details: [String])] = [] }
        var lead: [String] = [], sections: [Section] = [], steps: [JSONValue] = []
        var inActions = false
        var pointIndent = Int.max  // the indent of the current section's points: deeper bullets are details
        var stepIndent = Int.max
        func addPoint(_ text: String, indent: Int) {
            if sections.isEmpty { sections.append(Section(heading: "")) }
            if indent > pointIndent, !sections[sections.count - 1].points.isEmpty {
                sections[sections.count - 1].points[sections[sections.count - 1].points.count - 1].details.append(text)
            } else {
                pointIndent = min(pointIndent, indent)
                sections[sections.count - 1].points.append((text, []))
            }
        }
        func addStep(_ text: String, indent: Int) {
            if indent > stepIndent, case .object(var fields)? = steps.last {  // a detail of the step above
                let task = fields.first { $0.0 == "task" }?.1.stringValue ?? ""
                fields = fields.map { $0.0 == "task" ? ("task", .string("\(task) — \(text)")) : $0 }
                steps[steps.count - 1] = .object(fields)
                return
            }
            stepIndent = min(stepIndent, indent)
            steps.append(step(text))
        }
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let expanded = raw.replacingOccurrences(of: "\t", with: "    ")
            if let h = heading.fullMatch(expanded) {
                let title = clean(h.group(1) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                inActions = ACTION_HEADINGS.contains(Py.casefold(title))
                pointIndent = Int.max
                stepIndent = Int.max
                if !inActions && !title.isEmpty { sections.append(Section(heading: title)) }
                continue
            }
            if let b = bullet.fullMatch(expanded) {
                let indent = (b.group(1) ?? "").count
                var text = b.group(2) ?? ""
                var isCheckbox = false
                if let c = checkbox.fullMatch(text) {
                    text = c.group(1) ?? ""
                    isCheckbox = true
                }
                text = clean(text)
                if text.isEmpty { continue }
                if inActions || isCheckbox { addStep(text, indent: indent) } else { addPoint(text, indent: indent) }
                continue
            }
            let text = clean(expanded)
            if text.isEmpty || text == "---" { continue }
            if sections.isEmpty && !inActions {
                lead.append(text)
            } else if inActions {
                addStep(text, indent: 0)
            } else {
                addPoint(text, indent: 0)
            }
        }
        let kept = sections.filter { !$0.points.isEmpty }
        var summary = lead.joined(separator: " ")
        if summary.isEmpty {
            let topics = kept.map(\.heading).filter { !$0.isEmpty }
            if !topics.isEmpty { summary = "Topics: " + topics.joined(separator: ", ") + "." }
        }
        let json: [JSONValue] = kept.map { s in
            .object([("heading", .string(s.heading)),
                     ("points", .array(s.points.map { .object([("text", .string($0.text)), ("details", .strings($0.details))]) }))])
        }
        return (summary, json, steps)
    }

    // MARK: - dedupe

    /// A hash of what the note says (its transcript and summary, spacing aside): the same note fetched again has it.
    public static func contentHash(_ note: LegacyNote) -> String {
        let text = Py.split(note.transcript).joined(separator: " ") + "\n\u{1F}\n" + Py.split(note.summary).joined(separator: " ")
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The note's identity at its source: its id, else its url ("" when it has neither).
    static func identity(kind: String, id: String, url: String) -> String {
        let key = id.isEmpty ? url : id
        return key.isEmpty ? "" : "\(Py.casefold(kind))|\(key)"
    }

    /// The meeting that is this note already: an earlier import of it (`.already`), or a recording that started within
    /// SAME_CALL_SECONDS of it, or that it started in the middle of (`.recorded`). nil: a meeting of its own.
    public static func existing(_ outputDir: URL, _ note: LegacyNote) -> (LegacyImported.Outcome, String)? {
        let wanted = identity(kind: note.sourceKind, id: note.sourceId, url: note.sourceURL)
        let hash = contentHash(note)
        let start = Double(note.start.epochMicroseconds) / 1e6
        var recorded: String?
        for name in Exchange.recordingFolders(outputDir) {
            let paths = RecordingPaths(outputDir.appendingPathComponent(name, isDirectory: true))
            if let s = source(paths) {
                let theirs = identity(kind: s["kind"]?.stringValue ?? "", id: s["id"]?.stringValue ?? "",
                                      url: s["url"]?.stringValue ?? "")
                if (!wanted.isEmpty && Py.same(theirs, wanted)) || s["content_hash"]?.stringValue == hash { return (.already, name) }
                continue
            }
            guard recorded == nil, let meta = PythonJSON.read(paths.meta), let iso = meta["start_time"]?.stringValue,
                  let began = WallTime.parse(iso, .current)?.timeIntervalSince1970 else { continue }
            let length = meta["duration_seconds"]?.doubleValue ?? 0
            if abs(began - start) <= SAME_CALL_SECONDS
                || (began + SAME_CALL_SECONDS <= start && start <= began + length - SAME_CALL_SECONDS) {
                recorded = name
            }
        }
        return recorded.map { (.recorded, $0) }
    }

    // MARK: - import

    /// Takes in `note` as a meeting of `outputDir`, unless it is there already or Palaver recorded the call; answers
    /// which meeting it is. The meeting is built beside the recordings (`.importing`) and moved among them in one
    /// rename. `sortIntoProjects`: the projects' rules sort it right away (an import of many sorts once, at the end).
    @discardableResult
    public static func importNote(_ note: LegacyNote, outputDir: URL, userName: String, sortIntoProjects: Bool = true,
                                  stores: StorePaths = .current(), now: Date = Date(),
                                  timeZone: TimeZone = .current) throws -> LegacyImported {
        try check(note)
        if let (outcome, id) = existing(outputDir, note) {
            let title = Titles.resolve(RecordingPaths(outputDir.appendingPathComponent(id, isDirectory: true)), stores: stores).title
            return LegacyImported(outcome: outcome, id: id, title: title ?? "")
        }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let root = outputDir.appendingPathComponent(Exchange.STAGING, isDirectory: true)
        try Undo.makedirs(root.path)
        let staging = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let folder = staging.appendingPathComponent("meeting", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: staging)
            _ = rmdir(root.path)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(note, RecordingPaths(folder), userName: userName, stores: stores, now: now, timeZone: timeZone)
        var id = Exchange.newFolder(outputDir, note.start, timeZone: timeZone)
        while rename(folder.path, outputDir.path + "/" + id) != 0 {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            if !Undo.exists(outputDir.path + "/" + id) { throw failure }
            id = Exchange.newFolder(outputDir, note.start, timeZone: timeZone)
        }
        if sortIntoProjects { try sort(outputDir, [id], userName: userName, stores: stores) }
        return LegacyImported(outcome: .imported, id: id, title: note.title)
    }

    /// Imported meetings into the projects they clearly resemble, by the projects' rules (as after a recording's notes;
    /// the model sorts the rest when asked: `palaver projects suggest`).
    public static func sort(_ outputDir: URL, _ ids: [String], userName: String, stores: StorePaths = .current()) throws {
        guard !ids.isEmpty else { return }
        try ProjectRules.assignByRules(outputDir: outputDir, userName: userName, meetings: ids, stores: stores)
    }

    /// The meeting's files in `paths` (its staging folder).
    static func write(_ note: LegacyNote, _ paths: RecordingPaths, userName: String, stores: StorePaths, now: Date,
                      timeZone: TimeZone) throws {
        let lines = paragraphs(note.transcript)
        let length = duration(note, words: lines.reduce(0) { $0 + Py.split($1).count })
        let start = note.start.date
        let end = start.addingTimeInterval(length)
        try PythonJSON.write(.object([
            ("start_time", .string(WallTime.iso(start, timeZone))), ("end_time", .string(WallTime.iso(end, timeZone))),
            ("duration_seconds", .double(length)), ("trigger", .string(TRIGGER)),
        ]), to: paths.meta, indent: 2, ensureAscii: true)
        let utterances = utterances(lines, duration: length)
        try PythonJSON.write(.array(utterances.map(\.json)), to: paths.transcriptJson, indent: 2, ensureAscii: true)
        try PythonJSON.write(.array(utterances.map { SpeakerTurn(speaker: LABEL, start: $0.start, end: $0.end).json }),
                             to: paths.systemTurns, indent: nil, ensureAscii: true)
        if !utterances.isEmpty { try Speakers.setUnknown(paths, LABEL) }
        try Speakers.saveSpeakerNames(paths, PyDict(), learn: false, stores: stores)  // speakers.json and transcript.md
        if !note.attendees.isEmpty {
            let me = Py.casefold(CalendarEvents.personName(userName))
            let attendees = note.attendees.map { raw -> Attendee in
                let name = CalendarEvents.personName(raw)
                return Attendee(name: name, isSelf: !me.isEmpty && Py.same(Py.casefold(name), me))
            }
            let event = CalendarEvent(title: note.title, start: Exchange.pyTime(note.start),
                                      end: PyDateTime(end, offset: note.start.utcOffset), attendees: attendees,
                                      source: note.sourceKind)
            try CalendarEvents.save(paths, event, Link("event", note.title, ExchangeHints.IMPORTED, nil,
                                                       "from the \(sourceName(note.sourceKind)) meeting note"))
        }
        let (summary, sections, steps) = notes(fromSummary: note.summary)
        try NotesFile.save(paths, .object([
            ("title", .string(note.title)), ("summary", .string(summary)), ("sections", .array(sections)),
            ("next_steps", .array(steps)), ("decisions", .array([])), ("speaker_names", .array([])),
            ("source", .string(note.sourceKind)),
            ("transcript_hash", .string(Notes.transcriptHash(utterances))),
            ("generated_at", .string(Py.isoNow(timespec: "seconds", now: now, timeZone: timeZone))),
        ]))
        try PythonJSON.write(.object([
            ("kind", .string(note.sourceKind)), ("url", .string(note.sourceURL)), ("id", .string(note.sourceId)),
            ("title", .string(note.title)), ("content_hash", .string(contentHash(note))),
            ("imported_at", .string(Py.isoNow(timespec: "seconds", now: now, timeZone: timeZone))),
        ]), to: paths.source, indent: 2, ensureAscii: false)
    }

    /// "Notion" for "notion".
    public static func sourceName(_ kind: String) -> String {
        Py.same(Py.casefold(kind), NOTION) ? "Notion" : kind
    }
}
