// Note templates (#13): a 1:1, a customer call, an interview or a stand-up want different sections. A template is a
// name and plain-language instructions that go into the notes' prompt; the notes' JSON stays the same (sections are
// free headings already), so everything that reads notes keeps working. A few are built in, the user adds their own.
//
// Which template writes a meeting's notes, in this order: the one the user chose for the meeting (template.json in its
// folder), the one its notes were written with (so a rewrite never silently switches), the one remembered for its
// calendar series or else its meeting series of Palaver's own (#39), the calendar title's (rules below), else Default. The user's own templates and the series' choices
// are in templates.json in the config dir, written under its lock like the other small stores.
import Foundation
import PalaverCore

public struct NoteTemplate: Equatable, Sendable {
    public let id: String
    public let name: String
    /// What goes into the prompt; "" for Default (the notes as they always were).
    public let instructions: String
    public let builtin: Bool

    public init(id: String, name: String, instructions: String, builtin: Bool = false) {
        self.id = id; self.name = name; self.instructions = instructions; self.builtin = builtin
    }

    public var json: JSONValue {
        .object([("id", .string(id)), ("name", .string(name)), ("instructions", .string(instructions)),
                 ("builtin", .bool(builtin))])
    }
}

/// A change the user can't make (the page shows the text).
public struct NoteTemplateError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum NoteTemplates {
    public static let DEFAULT = "default"
    /// Where the pick came from: the user's choice for the meeting, the notes it has, its series, its title, none.
    public static let FROM_MEETING = "meeting", FROM_NOTES = "notes", FROM_SERIES = "series", FROM_TITLE = "title",
                      FROM_DEFAULT = "default"
    public static let MAX_NAME = 60
    public static let MAX_INSTRUCTIONS = 4000

    public static let builtin: [NoteTemplate] = [
        NoteTemplate(id: DEFAULT, name: "Default", instructions: "", builtin: true),
        NoteTemplate(id: "one-on-one", name: "1:1", instructions: """
            A one-on-one between two people. Sections: the topics each of them brought up; feedback, in both \
            directions (who to whom); how the other person is doing (workload, growth, mood) where it was talked \
            about; the agreements. Next steps: what each of the two agreed to do, with the date when one was said.
            """, builtin: true),
        NoteTemplate(id: "customer-call", name: "Customer call", instructions: """
            A call with a customer or a prospect. Sections: the customer's situation and needs; their questions and \
            objections, and how they were answered; scope, price and timeline where they came up; what is still \
            open. Next steps: the next step agreed with the customer and its date first, then who on either side \
            does what.
            """, builtin: true),
        NoteTemplate(id: "interview", name: "Interview", instructions: """
            A job interview. Sections: the candidate (background, current role, what they are looking for); \
            strengths that showed; concerns and gaps; the candidate's own questions; the recommendation, only as the \
            interviewers said it (hire, no hire, another round), never your own. Next steps: the hiring process \
            (next round, references, offer) and who does it.
            """, builtin: true),
        NoteTemplate(id: "workshop", name: "Workshop", instructions: """
            A workshop: several people working on one topic. Sections: the goal; the ideas and options that came \
            up, grouped by theme; what was prioritized, voted on or chosen; open questions. Next steps: who takes \
            what forward, with deadlines.
            """, builtin: true),
        NoteTemplate(id: "standup", name: "Stand-up", instructions: """
            A short stand-up. One section per person who spoke, headed with their name or label: what they did, \
            what they do next, what blocks them; leave out what they did not say. Next steps: only what someone \
            took on, such as unblocking someone else.
            """, builtin: true),
    ]

    // MARK: - the calendar title

    /// The calendar title's words for a template, in English and German, case-insensitive; the first that matches
    /// wins (an interview is no 1:1, a customer workshop is a workshop).
    static let titleRules: [(id: String, pattern: PyRegex)] = [
        ("interview", #"interview|vorstellungsgespräch|bewerbungsgespräch|\bbewerber|\bcandidate\b|\bkandidat"#),
        ("one-on-one", #"(?<!\d)1\s*[:/-]\s*1(?!\d)|\b1\s*on\s*1\b|\bone[\s-]on[\s-]one\b|einzelgespräch|mitarbeitergespräch"#),
        ("standup", #"\bstand[\s-]?up\b|\bdaily\b|\bstandup|tagesbesprechung"#),
        ("workshop", #"workshop|brainstorm|\bretro\b|retrospekt|retrospect|ideation"#),
        ("customer-call", #"\bcustomer\b|\bclient\b|\bsales\b|kundengespräch|kundentermin|kundencall|kundenmeeting|"#
            + #"verkaufsgespräch|\bkunde\b"#),
    ].map { ($0.0, try! PyRegex($0.1, ignoreCase: true)) }

    /// The built-in template a calendar title asks for, or nil.
    public static func byTitle(_ title: String) -> String? {
        titleRules.first { $0.pattern.firstMatch(in: title) != nil }?.id
    }

    // MARK: - templates.json

    /// templates.json: {"templates": [{"id", "name", "instructions"}], "series": {series id: {"template", "title"}}}.
    static func read(_ stores: StorePaths) -> PyDict<JSONValue> {
        PythonJSON.read(stores.noteTemplates).flatMap { PyDict<JSONValue>($0) } ?? PyDict()
    }

    static func write(_ data: PyDict<JSONValue>, _ stores: StorePaths) throws {
        let path = stores.noteTemplates
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PythonJSON.write(data.json, to: path, indent: 2, ensureAscii: false, via: path.lastPathComponent + ".tmp")
    }

    /// Reads, changes and writes templates.json under its lock.
    static func change<T>(_ stores: StorePaths, _ body: (inout PyDict<JSONValue>) throws -> T) throws -> T {
        try StoreLock.with(stores.noteTemplates) {
            var data = read(stores)
            let out = try body(&data)
            try write(data, stores)
            return out
        }
    }

    /// The user's own templates, as stored; entries that are not a template are skipped.
    public static func own(stores: StorePaths) -> [NoteTemplate] {
        (read(stores)["templates"]?.arrayValue ?? []).compactMap { t in
            guard let id = t["id"]?.stringValue, !id.isEmpty, let name = t["name"]?.stringValue else { return nil }
            return NoteTemplate(id: id, name: name, instructions: t["instructions"]?.stringValue ?? "")
        }
    }

    /// Every template: the built-in ones, then the user's.
    public static func all(stores: StorePaths) -> [NoteTemplate] { builtin + own(stores: stores) }

    public static func find(_ id: String?, stores: StorePaths) -> NoteTemplate? {
        guard let id, !id.isEmpty else { return nil }
        return all(stores: stores).first { Py.same($0.id, id) }
    }

    /// A name on one line, at most `MAX_NAME` characters; instructions stripped. Both are needed.
    static func cleaned(name: String, instructions: String) throws -> (String, String) {
        let one = Py.split(name).joined(separator: " ")
        let name = Py.strip(String(String.UnicodeScalarView(one.unicodeScalars.prefix(MAX_NAME))))
        let text = Py.strip(instructions)
        guard !name.isEmpty else { throw NoteTemplateError("a template needs a name") }
        guard !text.isEmpty else { throw NoteTemplateError("a template needs instructions") }
        guard text.unicodeScalars.count <= MAX_INSTRUCTIONS else {
            throw NoteTemplateError("the instructions are too long (at most \(MAX_INSTRUCTIONS) characters)")
        }
        return (name, text)
    }

    /// A template of the user's own; its id is new ("my-…"), never a built-in's.
    @discardableResult
    public static func add(name: String, instructions: String, stores: StorePaths) throws -> NoteTemplate {
        let (name, text) = try cleaned(name: name, instructions: instructions)
        let id = "my-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        let made = NoteTemplate(id: id, name: name, instructions: text)
        try change(stores) { data in
            data["templates"] = .array((data["templates"]?.arrayValue ?? []) + [stored(made)])
        }
        return made
    }

    private static func stored(_ t: NoteTemplate) -> JSONValue {
        .object([("id", .string(t.id)), ("name", .string(t.name)), ("instructions", .string(t.instructions))])
    }

    /// A template of the user's renamed or reworded; a built-in one can't be changed.
    @discardableResult
    public static func update(_ id: String, name: String, instructions: String, stores: StorePaths) throws -> NoteTemplate {
        try ownOnly(id)
        let (name, text) = try cleaned(name: name, instructions: instructions)
        let changed = NoteTemplate(id: id, name: name, instructions: text)
        try change(stores) { data in
            var list = data["templates"]?.arrayValue ?? []
            guard let at = list.firstIndex(where: { $0["id"]?.stringValue.map { Py.same($0, id) } ?? false }) else {
                throw NoteTemplateError("no template \(id)")
            }
            list[at] = stored(changed)
            data["templates"] = .array(list)
        }
        return changed
    }

    /// A template of the user's deleted, and the series that used it forgotten. Meetings that chose it, and notes it
    /// wrote, keep its id: they fall back to the next template in line.
    public static func delete(_ id: String, stores: StorePaths) throws {
        try ownOnly(id)
        try change(stores) { data in
            let list = data["templates"]?.arrayValue ?? []
            let kept = list.filter { !($0["id"]?.stringValue.map { Py.same($0, id) } ?? false) }
            guard kept.count < list.count else { throw NoteTemplateError("no template \(id)") }
            data["templates"] = .array(kept)
            if var series = data["series"].flatMap({ PyDict<JSONValue>($0) }) {
                for key in series.keys where series[key]?["template"]?.stringValue.map({ Py.same($0, id) }) ?? false {
                    _ = series.removeValue(forKey: key)
                }
                data["series"] = series.json
            }
        }
    }

    private static func ownOnly(_ id: String) throws {
        if builtin.contains(where: { Py.same($0.id, id) }) { throw NoteTemplateError("a built-in template can't be changed") }
    }

    // MARK: - a calendar series

    /// The series a template can be remembered for: a recurring event with an id (as the shared microphone's).
    public static func seriesId(_ event: CalendarEvent?) -> String? {
        guard let event, event.series, !event.seriesId.isEmpty else { return nil }
        return event.seriesId
    }

    /// The template remembered for `event`'s series (its id, as stored), or nil.
    public static func seriesChoice(_ event: CalendarEvent?, stores: StorePaths) -> String? {
        guard let series = seriesId(event) else { return nil }
        return read(stores)["series"]?[series]?["template"]?.stringValue
    }

    /// The series' next meetings use template `id`; nil forgets the series.
    public static func rememberSeries(_ event: CalendarEvent?, _ id: String?, stores: StorePaths) throws {
        guard let series = seriesId(event) else { throw NoteTemplateError("only a recurring calendar event has a series") }
        try remember(series, title: event?.title ?? "", id, stores: stores)
    }

    static func remember(_ series: String, title: String, _ id: String?, stores: StorePaths) throws {
        if let id, find(id, stores: stores) == nil { throw NoteTemplateError("no template \(id)") }
        try change(stores) { data in
            var all = data["series"].flatMap { PyDict<JSONValue>($0) } ?? PyDict()
            if let id { all[series] = .object([("template", .string(id)), ("title", .string(title))]) }
            else { _ = all.removeValue(forKey: series) }
            data["series"] = all.json
        }
    }

    // MARK: - a meeting series of Palaver's own (#39)

    /// A meeting series of Palaver's own is remembered under this key, beside the calendar series' ids.
    public static func meetingSeriesKey(_ id: String) -> String { "palaver:" + id }

    /// Where the meeting's next ones remember a template: its calendar series, else the meeting series it is in;
    /// with the title Settings lists it by. nil: neither.
    public static func seriesKey(_ paths: RecordingPaths, event: CalendarEvent?, stores: StorePaths) -> (key: String, title: String)? {
        if let series = seriesId(event) { return (series, event?.title ?? "") }
        guard let own = MeetingSeries.of(meeting: paths.id, stores: stores) else { return nil }
        return (meetingSeriesKey(own.id), own.name)
    }

    /// The template remembered for the meeting's calendar series, else for its meeting series; nil none.
    public static func seriesChoice(_ paths: RecordingPaths, event: CalendarEvent?, stores: StorePaths) -> String? {
        let remembered = read(stores)["series"]
        if let series = seriesId(event), let id = remembered?[series]?["template"]?.stringValue { return id }
        guard let own = MeetingSeries.of(meeting: paths.id, stores: stores) else { return nil }
        return remembered?[meetingSeriesKey(own.id)]?["template"]?.stringValue
    }

    /// The next meetings of the meeting's series (its calendar's, else its own) use template `id`; nil forgets it.
    public static func rememberSeries(_ paths: RecordingPaths, event: CalendarEvent?, _ id: String?, stores: StorePaths) throws {
        guard let key = seriesKey(paths, event: event, stores: stores) else {
            throw NoteTemplateError("only a meeting of a series can remember a template for it")
        }
        try remember(key.key, title: key.title, id, stores: stores)
    }

    /// Forgets a series by its id (from the Settings list).
    public static func forgetSeries(_ series: String, stores: StorePaths) throws {
        try change(stores) { data in
            var all = data["series"].flatMap { PyDict<JSONValue>($0) } ?? PyDict()
            _ = all.removeValue(forKey: series)
            data["series"] = all.json
        }
    }

    /// The remembered series: (series id, the event's title, the template's id), in the stored order.
    public static func rememberedSeries(stores: StorePaths) -> [(series: String, title: String, template: String)] {
        guard let all = read(stores)["series"].flatMap({ PyDict<JSONValue>($0) }) else { return [] }
        return all.compactMap { key, value in
            guard let template = value["template"]?.stringValue else { return nil }
            return (key, value["title"]?.stringValue ?? "", template)
        }
    }

    // MARK: - a meeting's own choice

    public static func meetingChoice(_ paths: RecordingPaths) -> String? {
        guard let id = PythonJSON.read(paths.noteTemplate)?["template"]?.stringValue, !id.isEmpty else { return nil }
        return id
    }

    /// The user's choice for the meeting; nil takes it back.
    public static func choose(_ paths: RecordingPaths, _ id: String?, stores: StorePaths) throws {
        guard let id else {
            if unlink(paths.noteTemplate.path) != 0 && errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return
        }
        guard find(id, stores: stores) != nil else { throw NoteTemplateError("no template \(id)") }
        try PythonJSON.write(.object([("template", .string(id))]), to: paths.noteTemplate, indent: nil, ensureAscii: false,
                             via: paths.noteTemplate.lastPathComponent + ".tmp")
    }

    // MARK: - the pick

    /// The template for the meeting's notes and where it came from (`FROM_…`). A choice whose template is gone (the
    /// user deleted it) counts as none. `event`, `notes`: what the caller read already.
    public static func pick(_ paths: RecordingPaths, event: Titles.Known<CalendarEvent> = .unread,
                            notes: Titles.Known<JSONValue> = .unread,
                            stores: StorePaths) -> (template: NoteTemplate, from: String) {
        let every = all(stores: stores)
        func found(_ id: String?) -> NoteTemplate? {
            guard let id, !id.isEmpty else { return nil }
            return every.first { Py.same($0.id, id) }
        }
        if let t = found(meetingChoice(paths)) { return (t, FROM_MEETING) }
        let written: JSONValue?
        if case .known(let n) = notes { written = n } else { written = NotesFile.load(paths) }
        if let t = found(written?["template"]?.stringValue) { return (t, FROM_NOTES) }
        let calendar: CalendarEvent?
        if case .known(let e) = event { calendar = e } else { calendar = CalendarEvents.load(paths) }
        if let t = found(seriesChoice(paths, event: calendar, stores: stores)) { return (t, FROM_SERIES) }
        if let title = calendar?.title, let t = found(byTitle(title)) { return (t, FROM_TITLE) }
        return (builtin[0], FROM_DEFAULT)
    }
}
