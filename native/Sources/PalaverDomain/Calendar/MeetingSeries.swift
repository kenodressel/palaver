// Meeting series Palaver remembers itself (#24, #39): a recurring meeting organized outside the company is often in no
// calendar on this Mac, or its event goes away after the meeting; and what belongs together is the user's to say.
//
// A series is learned three ways: the user links a recording by hand (Change Event) to a recurring calendar event, the
// title the call window showed (call-window.json, #24) repeats in another recording, or the user puts a recording into
// a series of their own (#39, "Add to Series…"). It keeps its name, the project it belongs to (free text, the user's),
// the calendar series it follows (if any), the call title it is recognized by, its slot (weekday and time of day) and
// its meetings. The next recording joins it by itself: the same call title, or the slot with an occurrence of its
// calendar series that day; it is then linked to that occurrence. A meeting is in one series at most, stays in it
// whatever its calendar does later, and takes the series' name when it has no better title (Titles.resolve). One the
// user took out never joins it again by itself.
//
// Two series merged keep every calendar series and call title of both: the first of each in `calendar_series` and
// `call_title`, the others in `also_calendar_series` and `also_call_titles`.
//
// series.json: {"series": {"<id>": {"name", "project", "calendar_series", "call_title", "weekday", "minutes",
// "learned", "meetings", "removed", "also_calendar_series", "also_call_titles"}}}.
import Foundation
import PalaverCore

/// The call window's reading of a recording (call-window.json, written while it was recorded).
public enum CallWindowFile {
    public struct Reading: Equatable, Sendable {
        public var app: String
        public var title: String?
        public var participants: [String]
    }

    public static func load(_ paths: RecordingPaths) -> Reading? {
        guard let d = PythonJSON.read(paths.callWindow), case .object = d else { return nil }
        let title = d["title"]?.stringValue.map { Titles.clean($0) }.flatMap { $0.isEmpty ? nil : $0 }
        let people = (d["participants"]?.arrayValue ?? []).compactMap(\.stringValue).map { Titles.clean($0) }.filter { !$0.isEmpty }
        return Reading(app: d["app"]?.stringValue ?? "teams", title: title, participants: people)
    }

    /// The meeting's title as its call window showed it, or nil.
    public static func title(_ paths: RecordingPaths) -> String? { load(paths)?.title }

    /// A title as compared: case and spacing don't count.
    public static func fold(_ title: String) -> String { Py.casefold(Py.split(title).joined(separator: " ")) }
}

public struct MeetingSeriesEntry: Equatable, Sendable {
    public var id: String
    /// What it is called: the event's title, the call's, or the user's.
    public var name: String
    /// The project (a customer, an initiative) the series belongs to, as the user wrote it; nil none.
    public var project: String?
    /// The calendar series it follows ("" none).
    public var calendarSeries: String
    /// The call window's title it is recognized by, folded ("" none).
    public var callTitle: String
    /// ISO weekday (Monday 1) and minutes after midnight of the meeting it was learned from.
    public var weekday: Int?
    public var minutes: Int?
    /// "event" (linked by hand to a recurring event), "call-window" (a call title that repeated) or "you" (made by hand).
    public var learned: String
    public var meetings: [String]
    /// Meetings the user took out: they never join it again by themselves.
    public var removed: [String]
    /// More calendar series and call titles, from series merged into it.
    public var alsoCalendarSeries: [String]
    public var alsoCallTitles: [String]

    var json: JSONValue {
        .object([("name", .string(name)), ("project", .str(project)), ("calendar_series", .string(calendarSeries)),
                 ("call_title", .string(callTitle)), ("weekday", weekday.map { .int($0) } ?? .null),
                 ("minutes", minutes.map { .int($0) } ?? .null), ("learned", .string(learned)),
                 ("meetings", .strings(meetings)), ("removed", .strings(removed)),
                 ("also_calendar_series", .strings(alsoCalendarSeries)), ("also_call_titles", .strings(alsoCallTitles))])
    }

    init(id: String, name: String, project: String? = nil, calendarSeries: String = "", callTitle: String = "",
         weekday: Int?, minutes: Int?, learned: String, meetings: [String], removed: [String] = [],
         alsoCalendarSeries: [String] = [], alsoCallTitles: [String] = []) {
        self.id = id; self.name = name; self.project = project; self.calendarSeries = calendarSeries
        self.callTitle = callTitle; self.weekday = weekday; self.minutes = minutes; self.learned = learned; self.meetings = meetings
        self.removed = removed; self.alsoCalendarSeries = alsoCalendarSeries; self.alsoCallTitles = alsoCallTitles
    }

    init?(id: String, json d: JSONValue) {
        guard case .object = d, let name = d["name"]?.stringValue, !name.isEmpty else { return nil }
        func int(_ k: String) -> Int? { d[k]?.doubleValue.map { Int($0) } }
        func strings(_ k: String) -> [String] { (d[k]?.arrayValue ?? []).compactMap(\.stringValue) }
        let project = d["project"]?.stringValue.map(Py.strip)
        self.init(id: id, name: name, project: project?.isEmpty == false ? project : nil,
                  calendarSeries: d["calendar_series"]?.stringValue ?? "", callTitle: d["call_title"]?.stringValue ?? "",
                  weekday: int("weekday"), minutes: int("minutes"), learned: d["learned"]?.stringValue ?? "",
                  meetings: strings("meetings"), removed: strings("removed"),
                  alsoCalendarSeries: strings("also_calendar_series"), alsoCallTitles: strings("also_call_titles"))
    }

    /// Every calendar series it follows, and every call title it knows (folded).
    public var allCalendarSeries: [String] { ([calendarSeries] + alsoCalendarSeries).filter { !$0.isEmpty } }
    public var allCallTitles: [String] { ([callTitle] + alsoCallTitles).filter { !$0.isEmpty } }

    public func follows(_ series: String) -> Bool { !series.isEmpty && allCalendarSeries.contains(series) }
    public func knows(callTitle folded: String) -> Bool { !folded.isEmpty && allCallTitles.contains(folded) }

    /// Learns a calendar series (and the slot it was seen in, when it has none).
    mutating func learn(calendarSeries series: String, slot: (weekday: Int, minutes: Int)?) {
        guard !series.isEmpty, !follows(series) else { return }
        if calendarSeries.isEmpty { calendarSeries = series } else { alsoCalendarSeries.append(series) }
        if weekday == nil, let slot { weekday = slot.weekday; minutes = slot.minutes }
    }

    mutating func learn(callTitle folded: String) {
        guard !folded.isEmpty, !knows(callTitle: folded) else { return }
        if callTitle.isEmpty { callTitle = folded } else { alsoCallTitles.append(folded) }
    }

    /// Why a recording was linked to it, as the event chip says.
    func reason(byTitle: Bool) -> String {
        if byTitle { return "remembered series: the same title in the call" }
        return "remembered series: \(MeetingSeries.slotText(weekday, minutes))"
    }

    /// For the window: name, project, how it was learned, the slot.
    public var page: JSONValue {
        .object([("id", .string(id)), ("name", .string(name)), ("project", .str(project)), ("learned", .string(learned)),
                 ("calendar", .bool(!calendarSeries.isEmpty)), ("call_title", .bool(!allCallTitles.isEmpty)),
                 ("when", .string(MeetingSeries.slotText(weekday, minutes))), ("meetings", .int(meetings.count))])
    }
}

/// A change to a series the user can't make (the page shows the text).
public struct MeetingSeriesError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum MeetingSeries {
    public static let SOURCE = "remembered"
    /// The same call title; the slot alone (with its calendar series' occurrence that day) is asked about.
    public static let BY_TITLE = 0.8
    public static let BY_SLOT = 0.7
    /// How far from the series' time of day a recording may start.
    public static let SLOT_MINUTES = 30
    /// How far from the recording an occurrence of the series may lie (a meeting moved by a few hours).
    public static let OCCURRENCE_HOURS = 18.0
    public static let LEARNED_EVENT = "event", LEARNED_CALL = "call-window", LEARNED_YOU = "you"
    /// A series' name and project, at most this long (as a meeting's title).
    public static let MAX_NAME = Titles.maxLength

    // MARK: - the store

    public static func all(stores: StorePaths = .current()) -> [MeetingSeriesEntry] {
        guard let d = PythonJSON.read(stores.meetingSeries), case .object(let fields)? = d["series"] else { return [] }
        return fields.compactMap { MeetingSeriesEntry(id: $0.0, json: $0.1) }
    }

    /// Read, changed and written under the store's lock.
    static func update(stores: StorePaths, _ body: (inout [MeetingSeriesEntry]) throws -> Void) throws {
        let path = stores.meetingSeries
        try StoreLock.with(path) {
            var entries = all(stores: stores)
            let before = entries
            try body(&entries)
            guard entries != before else { return }
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let json = JSONValue.object([("series", .object(entries.map { ($0.id, $0.json) }))])
            try PythonJSON.write(json, to: path, indent: 2, ensureAscii: false, via: path.lastPathComponent + ".tmp")
        }
    }

    static func newId() -> String { "s" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased() }

    /// The series `meeting` is in, or nil.
    public static func of(meeting: String, stores: StorePaths = .current()) -> MeetingSeriesEntry? {
        all(stores: stores).first { $0.meetings.contains(meeting) }
    }

    /// The series with this id, or nil.
    public static func find(_ id: String, stores: StorePaths = .current()) -> MeetingSeriesEntry? {
        all(stores: stores).first { $0.id == id }
    }

    /// The series is forgotten: no recording joins it any more (its meetings keep their events and titles).
    public static func forget(_ id: String, stores: StorePaths = .current()) throws {
        try update(stores: stores) { $0.removeAll { $0.id == id } }
    }

    // MARK: - by hand (#39)

    /// A name or project as typed: trimmed, one line; nil when nothing is left.
    public static func cleaned(_ text: String?) -> String? {
        let t = Py.split(text ?? "").joined(separator: " ")
        return t.isEmpty ? nil : t
    }

    static func named(_ name: String) throws -> String {
        guard let name = cleaned(name) else { throw MeetingSeriesError("A series needs a name") }
        guard name.unicodeScalars.count <= MAX_NAME else { throw MeetingSeriesError("A series' name is at most \(MAX_NAME) characters") }
        return name
    }

    static func index(_ entries: [MeetingSeriesEntry], _ id: String) throws -> Int {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { throw MeetingSeriesError("There is no series \(id)") }
        return i
    }

    /// `paths`' recording goes into series `id` (out of any other: a meeting is in one at most). The series learns what
    /// brings the next ones by themselves, where no other series knows it yet: the recording's call title, and its
    /// event's calendar series.
    public static func put(_ paths: RecordingPaths, into id: String, stores: StorePaths = .current()) throws {
        let meeting = paths.id
        let call = CallWindowFile.title(paths).map(CallWindowFile.fold) ?? ""
        let event = CalendarEvents.load(paths)
        let calendarSeries = event.flatMap { $0.series && !$0.seriesId.isEmpty ? $0.seriesId : nil } ?? ""
        let seen = (try? CalendarEvents.recordingSpan(paths).0).map(slot)
        try update(stores: stores) { entries in
            let i = try index(entries, id)
            for k in entries.indices where k != i && entries[k].meetings.contains(meeting) {
                entries[k].meetings.removeAll { $0 == meeting }
                if !entries[k].removed.contains(meeting) { entries[k].removed.append(meeting) }
            }
            if !entries[i].meetings.contains(meeting) { entries[i].meetings.append(meeting) }
            entries[i].removed.removeAll { $0 == meeting }
            if !entries.contains(where: { $0.knows(callTitle: call) }) { entries[i].learn(callTitle: call) }
            if !entries.contains(where: { $0.follows(calendarSeries) }) { entries[i].learn(calendarSeries: calendarSeries, slot: seen) }
            if entries[i].weekday == nil, let seen { entries[i].weekday = seen.weekday; entries[i].minutes = seen.minutes }
        }
    }

    /// `paths`' recording goes into the series called `name` (any case), a new one of the user's when there is none.
    /// Returns the series.
    @discardableResult
    public static func put(_ paths: RecordingPaths, intoNamed name: String, stores: StorePaths = .current()) throws -> MeetingSeriesEntry {
        let name = try named(name)
        var id = all(stores: stores).first { Py.same(Py.casefold($0.name), Py.casefold(name)) }?.id
        if id == nil { id = try create(name: name, stores: stores).id }
        try put(paths, into: id!, stores: stores)
        return find(id!, stores: stores)!
    }

    /// A new series of the user's, without meetings yet.
    @discardableResult
    public static func create(name: String, project: String? = nil, stores: StorePaths = .current()) throws -> MeetingSeriesEntry {
        let entry = MeetingSeriesEntry(id: newId(), name: try named(name), project: cleaned(project), weekday: nil, minutes: nil,
                                       learned: LEARNED_YOU, meetings: [])
        try update(stores: stores) { $0.append(entry) }
        return entry
    }

    /// The user took `meeting` out of its series: it never joins it again by itself. False when it was in none.
    @discardableResult
    public static func takeOut(_ meeting: String, stores: StorePaths = .current()) throws -> Bool {
        var found = false
        try update(stores: stores) { entries in
            for i in entries.indices where entries[i].meetings.contains(meeting) {
                found = true
                entries[i].meetings.removeAll { $0 == meeting }
                if !entries[i].removed.contains(meeting) { entries[i].removed.append(meeting) }
            }
        }
        return found
    }

    public static func rename(_ id: String, to name: String, stores: StorePaths = .current()) throws {
        let name = try named(name)
        try update(stores: stores) { entries in entries[try index(entries, id)].name = name }
    }

    /// The series' project; nil or "" takes it away.
    public static func setProject(_ id: String, _ project: String?, stores: StorePaths = .current()) throws {
        let project = cleaned(project)
        if let project, project.unicodeScalars.count > MAX_NAME {
            throw MeetingSeriesError("A project's name is at most \(MAX_NAME) characters")
        }
        try update(stores: stores) { entries in entries[try index(entries, id)].project = project }
    }

    /// Series `id` goes into `into`: its meetings, calendar series and call titles; `into` keeps its name, and its
    /// project and slot unless it has none.
    public static func merge(_ id: String, into: String, stores: StorePaths = .current()) throws {
        guard id != into else { throw MeetingSeriesError("A series can't be merged into itself") }
        try update(stores: stores) { entries in
            let from = entries[try index(entries, id)]
            let i = try index(entries, into)
            var target = entries[i]
            for meeting in from.meetings where !target.meetings.contains(meeting) { target.meetings.append(meeting) }
            for meeting in from.removed where !target.removed.contains(meeting) && !target.meetings.contains(meeting) {
                target.removed.append(meeting)
            }
            target.removed.removeAll { from.meetings.contains($0) }
            for series in from.allCalendarSeries { target.learn(calendarSeries: series, slot: nil) }
            for title in from.allCallTitles { target.learn(callTitle: title) }
            if target.project == nil { target.project = from.project }
            if target.weekday == nil { (target.weekday, target.minutes) = (from.weekday, from.minutes) }
            entries[i] = target
            entries.removeAll { $0.id == id }
        }
    }

    /// Projects of series, each once (any case), for the page to offer.
    public static func projects(stores: StorePaths = .current()) -> [String] {
        var seen = Set<ScalarKey>()
        return Py.stableSorted(all(stores: stores).compactMap(\.project), by: { Py.less(Py.casefold($0), Py.casefold($1)) })
            .filter { seen.insert(ScalarKey(Py.casefold($0))).inserted }
    }

    // MARK: - the slot

    /// The ISO weekday and minutes after midnight of `t`, in its own offset.
    static func slot(_ t: PyDateTime) -> (weekday: Int, minutes: Int) {
        let perDay: Int64 = 86_400 * 1_000_000
        let local = t.micros + Int64(t.offset ?? 0) * 1_000_000
        var days = local / perDay, rest = local % perDay
        if rest < 0 { days -= 1; rest += perDay }
        let weekday = Int(((days + 3) % 7 + 7) % 7) + 1  // 1970-01-01 was a Thursday (4)
        return (weekday, Int(rest / 60_000_000))
    }

    static let weekdays = ["Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"]

    /// "Mondays around 10:00".
    public static func slotText(_ weekday: Int?, _ minutes: Int?) -> String {
        guard let weekday, (1...7).contains(weekday), let minutes else { return "" }
        return "\(weekdays[weekday - 1]) around \(String(format: "%02d:%02d", minutes / 60, minutes % 60))"
    }

    static func inSlot(_ e: MeetingSeriesEntry, _ start: PyDateTime) -> Bool {
        let (weekday, minutes) = slot(start)
        guard e.weekday == weekday, let m = e.minutes else { return false }
        return abs(m - minutes) <= SLOT_MINUTES
    }

    // MARK: - learning

    /// The user linked `paths`' recording by hand to `event` (nil: to none). A recurring event's series is remembered
    /// with the recording's slot and call title: the series following it already, else the call title's series or the
    /// series the recording is in (when it follows no calendar series) learns which calendar series it is. The
    /// recording leaves any other series that follows a calendar; one of the user's or a call title's keeps it.
    public static func linkedByHand(_ paths: RecordingPaths, event: CalendarEvent?, stores: StorePaths = .current()) throws {
        let id = paths.id
        let series = event.flatMap { $0.series && !$0.seriesId.isEmpty ? $0.seriesId : nil }
        let call = CallWindowFile.title(paths).map(CallWindowFile.fold) ?? ""
        let start = try? CalendarEvents.recordingSpan(paths).0
        try update(stores: stores) { entries in
            guard let series, let event else {
                for i in entries.indices where !entries[i].allCalendarSeries.isEmpty { entries[i].meetings.removeAll { $0 == id } }
                return
            }
            let s = start.map(slot)
            let i = entries.firstIndex { $0.follows(series) }
                ?? entries.firstIndex { $0.allCalendarSeries.isEmpty && $0.knows(callTitle: call) }
                ?? entries.firstIndex { $0.allCalendarSeries.isEmpty && $0.meetings.contains(id) }
            for k in entries.indices where k != i { entries[k].meetings.removeAll { $0 == id } }
            if let i {
                entries[i].learn(calendarSeries: series, slot: s)
                if !entries.contains(where: { $0.knows(callTitle: call) }) { entries[i].learn(callTitle: call) }
                if !entries[i].meetings.contains(id) { entries[i].meetings.append(id) }
                entries[i].removed.removeAll { $0 == id }
                return
            }
            entries.append(MeetingSeriesEntry(id: newId(), name: event.title, calendarSeries: series,
                                              callTitle: entries.contains { $0.knows(callTitle: call) } ? "" : call,
                                              weekday: s?.weekday, minutes: s?.minutes, learned: LEARNED_EVENT, meetings: [id]))
        }
    }

    /// The recording's call title was shown in another recording too (and no series knows it): a series of the two.
    @discardableResult
    static func learnCallTitle(_ paths: RecordingPaths, start: PyDateTime, stores: StorePaths) throws -> MeetingSeriesEntry? {
        guard let title = CallWindowFile.title(paths) else { return nil }
        let folded = CallWindowFile.fold(title)
        guard !folded.isEmpty, !all(stores: stores).contains(where: { $0.knows(callTitle: folded) }) else { return nil }
        let outputDir = paths.folder.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
        let others = Py.stableSorted(names, by: Py.less).filter { name in
            guard name != paths.id, RecordingPaths.isRecordingFolderName(name) else { return false }
            let other = RecordingPaths(outputDir.appendingPathComponent(name, isDirectory: true))
            return CallWindowFile.title(other).map(CallWindowFile.fold) == folded
        }
        guard !others.isEmpty else { return nil }
        let s = slot(start)
        let entry = MeetingSeriesEntry(id: newId(), name: title, callTitle: folded, weekday: s.weekday, minutes: s.minutes,
                                       learned: LEARNED_CALL, meetings: others + [paths.id])
        try update(stores: stores) { entries in
            if !entries.contains(where: { $0.knows(callTitle: folded) }) { entries.append(entry) }
        }
        return entry
    }

    // MARK: - joining

    /// The series a recording starting at `start` belongs to, and the occurrence of its calendar series to link
    /// (nil: none in the calendar, the series alone), with how sure that is. Only one series may fit (a call title
    /// first); two fitting as well is no guess. A series the user took the recording out of is none.
    public static func match(_ paths: RecordingPaths, start: PyDateTime, events: [CalendarEvent], evidence: Evidence?,
                             entries: [MeetingSeriesEntry]) -> (entry: MeetingSeriesEntry, event: CalendarEvent?, link: Link)? {
        let call = CallWindowFile.title(paths).map(CallWindowFile.fold)
        var hits: [(entry: MeetingSeriesEntry, event: CalendarEvent?, byTitle: Bool)] = []
        for e in entries where !e.removed.contains(paths.id) {
            let byTitle = call.map { e.knows(callTitle: $0) } ?? false
            if e.allCalendarSeries.isEmpty {
                if byTitle { hits.append((e, nil, true)) }
                continue
            }
            let occurrence = events.filter { !$0.allDay && e.follows($0.seriesId)
                && abs($0.start.seconds(since: start)) <= OCCURRENCE_HOURS * 3600 }
                .min { abs($0.start.seconds(since: start)) < abs($1.start.seconds(since: start)) }
            if let occurrence {
                if (evidence?.doubted(occurrence) ?? 0) > 0 { continue }  // the user said no to it more than yes
                if byTitle || inSlot(e, start) { hits.append((e, occurrence, byTitle)) }
            } else if byTitle {
                hits.append((e, nil, true))  // its event is gone (or not in this Mac's calendars): the series still
            }
        }
        let byTitle = hits.filter(\.byTitle)
        let fitting = byTitle.isEmpty ? hits : byTitle
        guard fitting.count == 1, let hit = fitting.first else { return nil }
        let target = hit.event?.title ?? hit.entry.name
        return (hit.entry, hit.event, Link("event", target, SOURCE, hit.byTitle ? BY_TITLE : BY_SLOT,
                                           hit.entry.reason(byTitle: hit.byTitle)))
    }

    /// A processed recording joins its series: one its event belongs to, or, without an event, the one its call title
    /// or slot fits (learning a series from a call title that repeats); an occurrence of the series' calendar series
    /// is then its event. Not after the user said "none of these", nor while asked which event it was. Returns the
    /// series.
    @discardableResult
    public static func attach(_ paths: RecordingPaths, provider: CalendarProvider?, stores: StorePaths = .current()) throws
        -> MeetingSeriesEntry? {
        if CalendarEvents.dismissed(paths) || CalendarEvents.storedButUnreadable(paths) || CalendarEvents.loadQuestion(paths) != nil {
            return nil
        }
        let entries = all(stores: stores)
        if let member = entries.first(where: { $0.meetings.contains(paths.id) }) { return member }
        let join: (MeetingSeriesEntry) throws -> Void = { found in
            try update(stores: stores) { entries in
                if let i = entries.firstIndex(where: { $0.id == found.id }), !entries[i].meetings.contains(paths.id) {
                    entries[i].meetings.append(paths.id)
                }
            }
        }
        if let stored = CalendarEvents.load(paths) {
            guard let found = entries.first(where: { $0.follows(stored.seriesId) && !$0.removed.contains(paths.id) }) else { return nil }
            try join(found)
            return found
        }
        guard let start = (try? CalendarEvents.recordingSpan(paths))?.0 else { return nil }
        if let learned = try learnCallTitle(paths, start: start, stores: stores) { return learned }
        var events: [CalendarEvent] = []
        if let provider, entries.contains(where: { !$0.allCalendarSeries.isEmpty }) {
            events = (try? provider(try start.startOfDay.adding(seconds: -86_400).date,
                                    try start.startOfDay.adding(seconds: 2 * 86_400).date)) ?? []
        }
        let evidence = Evidence(path: stores.attributions, outputDir: paths.folder.deletingLastPathComponent())
        guard let hit = match(paths, start: start, events: events, evidence: evidence, entries: entries) else { return nil }
        if let event = hit.event { try CalendarEvents.assign(paths, event, link: hit.link, stores: stores) }
        try join(hit.entry)
        return hit.entry
    }
}
