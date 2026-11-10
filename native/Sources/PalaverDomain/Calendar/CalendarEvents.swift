// The calendar event a recording belongs to (calendar_events.py): matching a recording to the events that overlap it,
// how sure that is, the question when two fit, calendar.json, and storing a recording's event with what was prepared
// for it (`assign`, `attach`, `attachAll`).
import Foundation
import PalaverCore

/// What the calendar says about a recording: an event and how it was linked, or a question (the events it might
/// be), or neither.
public struct Decision: Equatable, Sendable {
    public var event: CalendarEvent?
    public var link: Link?
    public var question: [CalendarEvent]?

    public init(event: CalendarEvent? = nil, link: Link? = nil, question: [CalendarEvent]? = nil) {
        self.event = event; self.link = link; self.question = question
    }
}

public enum CalendarEvents {
    /// How far around the recording to look for its event: calls start early or late (seconds: 45 minutes).
    public static let SEARCH_MARGIN: TimeInterval = 45 * 60
    /// Overlap needed, as a share of the shorter of recording and event.
    public static let MIN_OVERLAP_SHARE = 0.3
    /// A rival overlapping at least this share of the best one's overlap makes it a question, unless only one of
    /// the two has people invited.
    public static let AMBIGUOUS_SHARE = 0.7
    /// How sure a time match is: the only event in the slot, one of several, and how much a rejection of the event
    /// (in another recording) takes off.
    public static let TIME_MATCH = 0.9
    public static let TIME_MATCH_OVERLAPPED = 0.6
    /// The other events have no invitees: blockers, focus time.
    public static let TIME_MATCH_NO_RIVAL = 0.8
    public static let REJECTED_ONCE = 0.6

    // MARK: - names

    // Meetingroom, Conference Room, Besprechungsraum
    private static let room = try! PyRegex(#"(room|raum)\b"#, ignoreCase: true)
    private static let external = try! PyRegex(#"\s+(ext\.?|extern)$"#, ignoreCase: true)
    private static let parenthetical = try! PyRegex(#"\s*\([^)]*\)\s*$"#)

    /// A directory name as people say it: "Kralek, Karel (Contoso Services)" → "Karel Kralek",
    /// "GARCIA LOPEZ, JOSE MIGUEL EXT." → "Jose Miguel Garcia Lopez".
    public static func personName(_ raw: String) -> String {
        var name = (try? parenthetical.sub("", in: Py.strip(raw))) ?? Py.strip(raw)
        func dropExternal(_ s: String) -> String { (try? external.sub("", in: s)) ?? s }
        let parts = name.split(separator: ",", omittingEmptySubsequences: false)
        if parts.count == 2 {
            let last = Py.strip(String(parts[0])), first = Py.strip(String(parts[1]))
            name = Py.strip("\(dropExternal(first)) \(last)")
        }
        name = dropExternal(name)
        if Py.strIsUpper(name) { name = Py.strTitle(name) }
        return name.isEmpty ? Py.strip(raw) : name
    }

    /// Exchange often lists rooms as people: "16 - Attakring | Conferenceroom".
    public static func looksLikeRoom(_ name: String) -> Bool { room.firstMatch(in: name) != nil }

    /// Calendars stored before names were cleaned up.
    static func tidy(_ a: Attendee) -> Attendee {
        Attendee(name: personName(a.name), email: a.email, organizer: a.organizer, response: a.response, isSelf: a.isSelf,
                 isRoom: a.isRoom || looksLikeRoom(a.name))
    }

    // MARK: - matching

    private static func overlap(_ event: CalendarEvent, _ start: PyDateTime, _ end: PyDateTime) -> Double {
        max(0.0, min(event.end, end).seconds(since: max(event.start, start)))
    }

    /// Events overlapping the recording enough, best first: most overlap; among equals, one with people invited,
    /// then the closest start.
    private static func fitting(_ events: [CalendarEvent], _ start: PyDateTime, _ end: PyDateTime) -> [CalendarEvent] {
        var out: [CalendarEvent] = []
        for event in events where !event.allDay {
            let o = overlap(event, start, end)
            let shorter = min(end.seconds(since: start), event.end.seconds(since: event.start))
            if o <= 0 || o < MIN_OVERLAP_SHARE * shorter { continue }
            out.append(event)
        }
        func key(_ e: CalendarEvent) -> (Double, Bool, Double) {
            (overlap(e, start, end), !e.attendees.isEmpty, -abs(e.start.seconds(since: start)))
        }
        // sorted(..., reverse=True): the best first, equal keys in their order.
        return Py.stableSorted(out) { a, b in
            let x = key(a), y = key(b)
            if x.0 != y.0 { return x.0 > y.0 }
            if x.1 != y.1 { return x.1 && !y.1 }
            return x.2 > y.2
        }
    }

    /// The event the recording `start`..`end` overlaps most, if any.
    public static func match(_ events: [CalendarEvent], _ start: PyDateTime, _ end: PyDateTime) -> CalendarEvent? {
        fitting(events, start, end).first
    }

    /// Someone besides the user is invited: a meeting, not a blocker.
    private static func invites(_ event: CalendarEvent) -> Bool { event.attendees.contains { !$0.isSelf && !$0.isRoom } }

    /// Which event the recording `start`..`end` was, how sure that is, and why. Events overlapping it about as much
    /// make a question, unless only one of them has people invited (the others are blockers). `evidence`: what the
    /// user's corrections taught: an event series said no to often is not linked by time at all; one said no to once
    /// comes after any other, unsure.
    public static func decide(_ events: [CalendarEvent], _ start: PyDateTime, _ end: PyDateTime,
                              evidence: Evidence? = nil) -> Decision {
        let all = fitting(events, start, end)
        let doubt = all.map { evidence?.doubted($0) ?? 0 }
        var found = Array(all.indices)  // positions in `all`: two equal events are two events
        if let evidence {
            found = found.filter { !evidence.neverByTime(all[$0]) }
            found = Py.stableSorted(found) { doubt[$0] == 0 && doubt[$1] > 0 }  // stable: by overlap otherwise
        }
        guard let bestIndex = found.first else { return Decision() }
        var best = bestIndex
        let bestOverlap = overlap(all[bestIndex], start, end)
        let close = [bestIndex] + found.dropFirst().filter {
            doubt[$0] == 0 && overlap(all[$0], start, end) >= AMBIGUOUS_SHARE * bestOverlap
        }
        if close.count > 1 {
            let invited = close.filter { invites(all[$0]) }
            if invited.count != 1 {
                return Decision(question: sortedByStart(close.map { all[$0] }))
            }
            best = invited[0]
        }
        let rivals = found.filter { $0 != best }
        var confidence: Double
        var reason: String
        if rivals.isEmpty {
            confidence = TIME_MATCH; reason = "time match"
        } else if rivals.contains(where: { invites(all[$0]) }) || !invites(all[best]) {
            confidence = TIME_MATCH_OVERLAPPED; reason = "time match, \(found.count) events overlapped"
        } else {
            confidence = TIME_MATCH_NO_RIVAL
            let others = rivals.count > 1 ? "the others have" : "the other has"
            reason = "time match, \(found.count) events overlapped; \(others) no invitees"
        }
        if doubt[best] > 0 {
            confidence *= REJECTED_ONCE
            let n = doubt[best]
            reason += "; you said a recording was not this event " + (n == 1 ? "once" : "\(n) times")
        }
        let event = all[best]
        return Decision(event: event, link: Link("event", event.title, "calendar", Py.round(confidence, 2), reason))
    }

    /// `sorted(events, key=lambda e: (e.start, e.title))`.
    static func sortedByStart(_ events: [CalendarEvent]) -> [CalendarEvent] {
        Py.stableSorted(events) { a, b in a.start != b.start ? a.start < b.start : Py.less(a.title, b.title) }
    }

    /// The event on at `when` (as `match` picks it), by its key.
    public static func eventKeyAt(_ events: [CalendarEvent], _ when: PyDateTime) -> String? {
        guard let event = match(events, when, when.adding(micros: 1_000_000)) else { return nil }
        return event.key.isEmpty ? "\(event.title)|\(event.start.iso)" : event.key
    }

    // MARK: - invitees

    /// Invitees who may have spoken on the other side: not the user, not a room, not someone who declined.
    public static func candidates(_ event: CalendarEvent, userName: String) -> [Attendee] {
        let user = Py.casefold(userName)
        var out: [Attendee] = [], seen = Set<ScalarKey>()
        for a in event.attendees {
            let key = Py.casefold(a.name)
            let first = Py.split(a.name).first.map(Py.casefold)
            if a.isSelf || a.isRoom || a.response == "declined" || seen.contains(ScalarKey(key)) || Py.same(key, user) || first.map { Py.same($0, user) } == true { continue }
            seen.insert(ScalarKey(key))
            out.append(a)
        }
        return out
    }

    /// The name already used for `invitee` ("Freddy" for "Freddy Schmidt"), or nil. First names count only when
    /// unambiguous.
    public static func resolve(_ invitee: String, _ known: [String]) -> String? {
        let folded = Py.casefold(invitee)
        for name in known where Py.same(Py.casefold(name), folded) { return name }
        let first = Py.split(invitee).first.map(Py.casefold) ?? ""
        let hits = known.filter { Py.same(Py.casefold($0), first) }
        return hits.count == 1 ? hits[0] : nil
    }

    /// The invitees of the recording's event, as `known` names where they resolve; nil when the recording has no event.
    public static func invitedNames(_ paths: RecordingPaths, _ known: [String], userName: String = "") -> [String]? {
        guard let event = load(paths) else { return nil }
        return candidates(event, userName: userName).map { resolve($0.name, known) ?? $0.name }
    }

    // MARK: - calendar.json

    private static func stored(_ paths: RecordingPaths) -> JSONValue {
        guard let d = PythonJSON.read(paths.calendar), case .object = d else { return .object([]) }
        return d
    }

    public static func load(_ paths: RecordingPaths) -> CalendarEvent? {
        guard let d = PythonJSON.read(paths.calendar) else { return nil }
        return try? CalendarEvent(json: d)
    }

    /// calendar.json exists but is neither an event this code can read, a question nor "none": a file Python may read
    /// differently (see the ledger). Nothing automatic may overwrite it.
    public static func storedButUnreadable(_ paths: RecordingPaths) -> Bool {
        FileManager.default.fileExists(atPath: paths.calendar.path)
            && load(paths) == nil && loadQuestion(paths) == nil && !dismissed(paths)
    }

    /// How the stored event was linked; an unknown source for files stored before links had one. nil without an event.
    public static func loadLink(_ paths: RecordingPaths) -> Link? {
        guard let event = load(paths) else { return nil }
        return Link.from(kind: "event", target: event.title, stored(paths)["link"])
    }

    /// The events the recording might be, while the user has not said which.
    public static func loadQuestion(_ paths: RecordingPaths) -> [CalendarEvent]? {
        guard let items = stored(paths)["question"]?.arrayValue else { return nil }
        return try? items.map { try CalendarEvent(json: $0) }
    }

    private static func write(_ paths: RecordingPaths, _ v: JSONValue, indent: Int?, ensureAscii: Bool) throws {
        try PythonJSON.write(v, to: paths.calendar, indent: indent, ensureAscii: ensureAscii)
    }

    public static func save(_ paths: RecordingPaths, _ event: CalendarEvent, _ link: Link? = nil) throws {
        guard case .object(var d) = event.json else { return }
        if let link { d.append(("link", link.stored())) }
        try write(paths, .object(d), indent: 2, ensureAscii: false)
    }

    /// Several events fit the recording: store them as a question, no event. An unchanged question is not
    /// rewritten (the file and its time stay).
    public static func ask(_ paths: RecordingPaths, _ events: [CalendarEvent]) throws {
        let d = JSONValue.object([("question", .array(sortedByStart(events).map(\.json)))])
        if stored(paths) != d { try write(paths, d, indent: 2, ensureAscii: false) }
    }

    /// The matched event is not this meeting (an ad-hoc call in its slot): forget it, and don't match one again.
    public static func dismiss(_ paths: RecordingPaths) throws {
        try write(paths, .object([("none", .bool(true)), ("link", .object([("source", .string("you"))]))]),
                  indent: nil, ensureAscii: true)
    }

    public static func dismissed(_ paths: RecordingPaths) -> Bool { stored(paths)["none"]?.boolValue == true }

    // MARK: - attaching events

    /// Store `event` as the recording's, with how it was linked, what was prepared for it (`Prep.apply`: projects and
    /// notes) and whether its series shares one microphone (`SharedMic.applySeries`, #56).
    public static func assign(_ paths: RecordingPaths, _ event: CalendarEvent, link: Link? = nil,
                              stores: StorePaths = .current()) throws {
        try save(paths, event, link)
        try Prep.apply(paths, event: event, stores: stores)  // what was prepared for this event before it happened
        _ = try SharedMic.applySeries(paths, event: event, stores: stores)  // an All Hands remembered for its series
    }

    /// Find and store the recording's event, or the question which one it was. A calendar decision already made stays:
    /// an event the user chose, "none of these", and any stored event (an event stored before events had an id only
    /// gets its id, when the calendar has the same occurrence; its invitees stay). Only a recording without a decision
    /// may get a question. A calendar.json this code cannot read (`storedButUnreadable`) is left alone: nil, nothing
    /// asked or stored.
    @discardableResult
    public static func attach(_ paths: RecordingPaths, provider: CalendarProvider, start: PyDateTime, end: PyDateTime,
                              evidence: Evidence? = nil, stores: StorePaths = .current()) throws -> CalendarEvent? {
        if dismissed(paths) || storedButUnreadable(paths) { return nil }
        let events = try provider(try start.adding(seconds: -SEARCH_MARGIN).date, try end.adding(seconds: SEARCH_MARGIN).date)
        if let stored = load(paths) {
            if stored.uid.isEmpty,
               var found = events.first(where: { !$0.uid.isEmpty && Py.same($0.title, stored.title) && $0.start == stored.start }) {
                if !stored.attendees.isEmpty && found.attendees.isEmpty { found.attendees = stored.attendees }
                try save(paths, found, loadLink(paths))
                return found
            }
            return stored
        }
        let decision = decide(events, start, end, evidence: evidence
                              ?? Evidence(path: stores.attributions, outputDir: paths.folder.deletingLastPathComponent()))
        if let question = decision.question, !question.isEmpty {
            try ask(paths, question)
        } else if let event = decision.event {
            try assign(paths, event, link: decision.link, stores: stores)
        }
        return decision.event
    }

    /// Look up the event of every finished recording (started at `since` or later) that has none stored yet, e.g. those
    /// made before the calendar was connected, or one without an id. Returns how many found one.
    @discardableResult
    public static func attachAll(outputDir: URL, provider: CalendarProvider, since: PyDateTime? = nil,
                                 stores: StorePaths = .current()) throws -> Int {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: outputDir.path, isDirectory: &isDir), isDir.boolValue else { return 0 }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
        let evidence = Evidence(path: stores.attributions, outputDir: outputDir)
        var found = 0
        for name in Py.stableSorted(names, by: Py.less) where RecordingPaths.isRecordingFolderName(name) {
            let paths = RecordingPaths(outputDir.appendingPathComponent(name, isDirectory: true))
            // Look again for events stored before they had an id (series, prep); an open question too: the calendar
            // may have changed since.
            if let stored = load(paths), !stored.uid.isEmpty { continue }
            if dismissed(paths) || storedButUnreadable(paths) { continue }
            guard let (start, end) = try? recordingSpan(paths) else { continue }  // still recording, or not a recording
            if let since, start < since { continue }
            if try attach(paths, provider: provider, start: start, end: end, evidence: evidence, stores: stores) != nil {
                found += 1
            }
        }
        return found
    }

    public struct SpanError: Error, CustomStringConvertible {
        public let description: String
        public init(description: String) { self.description = description }
    }

    /// When the recording started and ended, from its meta.json.
    public static func recordingSpan(_ paths: RecordingPaths) throws -> (PyDateTime, PyDateTime) {
        guard let meta = PythonJSON.read(paths.meta), case .object = meta else { throw SpanError(description: "no meta.json") }
        guard let startText = meta["start_time"]?.stringValue else { throw SpanError(description: "'start_time'") }
        let start = try PyDateTime.parse(startText)
        if let end = meta["end_time"], end.truthy {
            guard let text = end.stringValue else { throw SpanError(description: "end_time is not a string") }
            return (start, try PyDateTime.parse(text))
        }
        guard let seconds = meta["duration_seconds"]?.doubleValue else { throw SpanError(description: "'duration_seconds'") }
        return (start, try start.adding(seconds: seconds))
    }
}
