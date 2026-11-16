// Meeting series Palaver remembers itself (#24; the start of #39, series of Palaver's own): a recurring meeting
// organized outside the company is often in no calendar on this Mac, or its event goes away after the meeting.
//
// A series is learned two ways: the user links a recording by hand (Change Event) to a recurring calendar event, or
// the title the call window showed (call-window.json, #24) repeats in another recording. It keeps its name, the
// calendar series it follows (if any), the call title it is recognized by, its slot (weekday and time of day) and its
// meetings. The next recording joins it by itself: the same call title, or the slot with an occurrence of its calendar
// series that day; it is then linked to that occurrence. A meeting stays in its series whatever its calendar does
// later, and takes the series' name when it has no better title (Titles.resolve).
//
// series.json: {"series": {"<id>": {"name", "project", "calendar_series", "call_title", "weekday", "minutes",
// "learned", "meetings"}}}. `project` is for #39 (a series of a project) and not set yet.
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
    /// What it is called: the event's title, the call's.
    public var name: String
    /// #39: the project the series belongs to (not set yet).
    public var project: String?
    /// The calendar series it follows ("" none).
    public var calendarSeries: String
    /// The call window's title it is recognized by, folded ("" none).
    public var callTitle: String
    /// ISO weekday (Monday 1) and minutes after midnight of the meeting it was learned from.
    public var weekday: Int?
    public var minutes: Int?
    /// "event" (linked by hand) or "call-window" (a call title that repeated); #39 would add "you".
    public var learned: String
    public var meetings: [String]

    var json: JSONValue {
        .object([("name", .string(name)), ("project", .str(project)), ("calendar_series", .string(calendarSeries)),
                 ("call_title", .string(callTitle)), ("weekday", weekday.map { .int($0) } ?? .null),
                 ("minutes", minutes.map { .int($0) } ?? .null), ("learned", .string(learned)),
                 ("meetings", .strings(meetings))])
    }

    init(id: String, name: String, project: String? = nil, calendarSeries: String = "", callTitle: String = "",
         weekday: Int?, minutes: Int?, learned: String, meetings: [String]) {
        self.id = id; self.name = name; self.project = project; self.calendarSeries = calendarSeries
        self.callTitle = callTitle; self.weekday = weekday; self.minutes = minutes; self.learned = learned; self.meetings = meetings
    }

    init?(id: String, json d: JSONValue) {
        guard case .object = d, let name = d["name"]?.stringValue, !name.isEmpty else { return nil }
        func int(_ k: String) -> Int? { d[k]?.doubleValue.map { Int($0) } }
        self.init(id: id, name: name, project: d["project"]?.stringValue, calendarSeries: d["calendar_series"]?.stringValue ?? "",
                  callTitle: d["call_title"]?.stringValue ?? "", weekday: int("weekday"), minutes: int("minutes"),
                  learned: d["learned"]?.stringValue ?? "", meetings: (d["meetings"]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    /// Why a recording was linked to it, as the event chip says.
    func reason(byTitle: Bool) -> String {
        if byTitle { return "remembered series: the same title in the call" }
        return "remembered series: \(MeetingSeries.slotText(weekday, minutes))"
    }

    /// For the window: name, how it was learned, the slot.
    public var page: JSONValue {
        .object([("id", .string(id)), ("name", .string(name)), ("learned", .string(learned)),
                 ("calendar", .bool(!calendarSeries.isEmpty)), ("when", .string(MeetingSeries.slotText(weekday, minutes))),
                 ("meetings", .int(meetings.count))])
    }
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
    public static let LEARNED_EVENT = "event", LEARNED_CALL = "call-window"

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

    /// The series is forgotten: no recording joins it any more (its meetings keep their events and titles).
    public static func forget(_ id: String, stores: StorePaths = .current()) throws {
        try update(stores: stores) { $0.removeAll { $0.id == id } }
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

    /// The user linked `paths`' recording by hand to `event` (nil: to none): it leaves any other series; a recurring
    /// event's series is remembered with the recording's slot and call title, or the call title's series learns
    /// which calendar series it is.
    public static func linkedByHand(_ paths: RecordingPaths, event: CalendarEvent?, stores: StorePaths = .current()) throws {
        let id = paths.id
        let series = event.flatMap { $0.series && !$0.seriesId.isEmpty ? $0.seriesId : nil }
        let call = CallWindowFile.title(paths).map(CallWindowFile.fold) ?? ""
        let start = try? CalendarEvents.recordingSpan(paths).0
        try update(stores: stores) { entries in
            for i in entries.indices where series == nil || entries[i].calendarSeries != series! {
                entries[i].meetings.removeAll { $0 == id }
            }
            guard let series, let event else { return }
            let i = entries.firstIndex { $0.calendarSeries == series }
                ?? entries.firstIndex { $0.calendarSeries.isEmpty && !call.isEmpty && $0.callTitle == call }
            if let i {
                entries[i].calendarSeries = series
                if entries[i].callTitle.isEmpty { entries[i].callTitle = call }
                if !entries[i].meetings.contains(id) { entries[i].meetings.append(id) }
                return
            }
            let s = start.map(slot)
            entries.append(MeetingSeriesEntry(id: newId(), name: event.title, calendarSeries: series, callTitle: call,
                                              weekday: s?.weekday, minutes: s?.minutes, learned: LEARNED_EVENT, meetings: [id]))
        }
    }

    /// The recording's call title was shown in another recording too (and no series knows it): a series of the two.
    @discardableResult
    static func learnCallTitle(_ paths: RecordingPaths, start: PyDateTime, stores: StorePaths) throws -> MeetingSeriesEntry? {
        guard let title = CallWindowFile.title(paths) else { return nil }
        let folded = CallWindowFile.fold(title)
        guard !folded.isEmpty, !all(stores: stores).contains(where: { $0.callTitle == folded }) else { return nil }
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
            if !entries.contains(where: { $0.callTitle == folded }) { entries.append(entry) }
        }
        return entry
    }

    // MARK: - joining

    /// The series a recording starting at `start` belongs to, and the occurrence of its calendar series to link
    /// (nil: none in the calendar, the series alone), with how sure that is. Only one series may fit (a call title
    /// first); two fitting as well is no guess.
    public static func match(_ paths: RecordingPaths, start: PyDateTime, events: [CalendarEvent], evidence: Evidence?,
                             entries: [MeetingSeriesEntry]) -> (entry: MeetingSeriesEntry, event: CalendarEvent?, link: Link)? {
        let call = CallWindowFile.title(paths).map(CallWindowFile.fold)
        var hits: [(entry: MeetingSeriesEntry, event: CalendarEvent?, byTitle: Bool)] = []
        for e in entries {
            let byTitle = !e.callTitle.isEmpty && call == e.callTitle
            if e.calendarSeries.isEmpty {
                if byTitle { hits.append((e, nil, true)) }
                continue
            }
            let occurrence = events.filter { !$0.allDay && $0.seriesId == e.calendarSeries
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
            guard !stored.seriesId.isEmpty, let found = entries.first(where: { $0.calendarSeries == stored.seriesId }) else { return nil }
            try join(found)
            return found
        }
        guard let start = (try? CalendarEvents.recordingSpan(paths))?.0 else { return nil }
        if let learned = try learnCallTitle(paths, start: start, stores: stores) { return learned }
        var events: [CalendarEvent] = []
        if let provider, entries.contains(where: { !$0.calendarSeries.isEmpty }) {
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
