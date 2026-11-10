// Attribution (attribution.py:1-270): why Palaver linked two things and how sure it is (`Link`), what the user's
// corrections taught across meetings (`Evidence`, attributions.json), and what needs the user (`Attribution.questions`).
import Foundation
import PalaverCore

/// Python's `str(x)` of a JSON value, for the values a hand-edited file may hold where a string belongs.
func pyStr(_ v: JSONValue) -> String {
    switch v {
    case .string(let s): return s
    case .int(let i): return String(i)
    case .double(let d): return Py.repr(d)
    case .bool(let b): return b ? "True" : "False"
    case .null: return "None"
    default: return PythonJSON.dumps(v)
    }
}

public struct Link: Equatable, Sendable {
    /// "event" | "project" | "speaker" | "org"
    public var kind: String
    /// What it links to, as shown: "Northwind", "Tom", "Contoso".
    public var target: String
    /// See `SOURCE_TEXT`.
    public var source: String
    public var confidence: Double?
    public var reason: String

    public init(_ kind: String, _ target: String, _ source: String = "unknown", _ confidence: Double? = nil, _ reason: String = "") {
        self.kind = kind; self.target = target; self.source = source; self.confidence = confidence; self.reason = reason
    }

    /// Set (or confirmed) by the user: final, automation leaves it alone.
    public var byYou: Bool { source == "you" }

    public var unsure: Bool {
        if byYou { return false }
        if kind == "project" { return true }  // rules and the model only propose projects (#29); the user decides
        return confidence.map { $0 < Attribution.UNSURE_BELOW } ?? false
    }

    public var why: String { reason.isEmpty ? (Attribution.SOURCE_TEXT[source] ?? "") : reason }

    /// "Event: Northwind (time match, 2 events overlapped)".
    public var label: String {
        let head = "\(Attribution._KIND_TEXT[kind] ?? Py.strTitle(kind)): \(target)"
        return why.isEmpty ? head : "\(head) (\(why))"
    }

    /// What a store keeps (the target is the thing itself, stored beside it).
    public func stored() -> JSONValue {
        var out: [(String, JSONValue)] = [("source", .string(source))]
        if let confidence { out.append(("confidence", .double(confidence))) }
        if !reason.isEmpty { out.append(("reason", .string(reason))) }
        return .object(out)
    }

    /// For the window: everything, with how to show it.
    public func toDict() -> JSONValue {
        .object([("kind", .string(kind)), ("target", .string(target)), ("source", .string(source)),
                 ("confidence", .num(confidence)), ("reason", .string(reason)), ("unsure", .bool(unsure)),
                 ("label", .string(label))])
    }

    /// As stored; missing fields (older files) mean an unknown source.
    public static func from(kind: String, target: String, _ d: JSONValue?) -> Link {
        let d = d ?? .null
        guard case .object = d else { return Link(kind, target) }
        var confidence: Double?
        switch d["confidence"] {
        case .int(let i)?: confidence = Double(i)
        case .double(let x)?: confidence = x
        default: break
        }
        let source = d["source"].flatMap { $0.truthy ? pyStr($0) : nil } ?? "unknown"
        return Link(kind, target, source, confidence, d["reason"].flatMap { $0.truthy ? pyStr($0) : nil } ?? "")
    }

    /// A project assignment as projects.py stores it: {"by", "why", "confidence"?}.
    public static func fromProject(_ name: String, _ how: JSONValue) -> Link {
        let by = how["by"]?.stringValue
        return from(kind: "project", target: name, .object([
            ("source", .string(by.flatMap { Attribution._PROJECT_SOURCES[$0] } ?? "unknown")),
            ("confidence", how["confidence"] ?? .null), ("reason", how["why"] ?? .null)]))
    }
}

/// One rule the corrections made, for the window to show.
public struct EvidenceRule: Equatable, Sendable {
    public let series: String
    public let title: String
    public let rejected: Int
    public let accepted: Int
    public let rule: String

    public var json: JSONValue {
        .object([("kind", .string("event")), ("series", .string(series)), ("title", .string(title)),
                 ("rejected", .int(rejected)), ("accepted", .int(accepted)), ("rule", .string(rule))])
    }
}

/// What the user's corrections taught, beyond one meeting: which event series recordings were said not to be (and
/// which they were chosen for). One small JSON file next to the projects. `outputDir`: the recordings, whose stored
/// events count as kept (accepted) links.
public final class Evidence {
    public let path: URL
    public let outputDir: URL?
    private var linked: [ScalarKey: Set<String>]?
    /// The file's own top-level keys; "events" is rebuilt from `events` at the save.
    private var top: PyDict<JSONValue>
    private var events: PyDict<PyDict<JSONValue>>

    public init(path: URL? = nil, outputDir: URL? = nil) {
        self.path = path ?? StorePaths.current().attributions
        self.outputDir = outputDir
        var top = PyDict<JSONValue>()
        if let read = PythonJSON.read(self.path), let d = PyDict<JSONValue>(read) { top = d }
        var events = PyDict<PyDict<JSONValue>>()
        for (series, entry) in PyDict<JSONValue>(top["events"] ?? .null) ?? PyDict() {
            events[series] = PyDict<JSONValue>(entry) ?? PyDict()
        }
        self.top = top
        self.events = events
    }

    private var json: JSONValue {
        var out = top
        out["events"] = .object(events.map { ($0.key, $0.value.json) })
        return out.json
    }

    /// Under the store's lock (`attributions.json.lock`), through `attributions.json.tmp`.
    public func save() throws {
        try StoreLock.with(path) {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PythonJSON.write(json, to: path, indent: 2, ensureAscii: false, via: Self.tmpName(path.lastPathComponent))
        }
    }

    /// `path.with_suffix(".json.tmp")`.
    static func tmpName(_ name: String) -> String {
        var stem = name
        if let dot = name.lastIndex(of: "."), dot != name.startIndex { stem = String(name[..<dot]) }
        return stem + ".json.tmp"
    }

    static func series(_ event: CalendarEvent) -> String { event.seriesId.isEmpty ? event.title : event.seriesId }

    private func strings(_ entry: PyDict<JSONValue>?, _ key: String) -> [String] {
        (entry?[key]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    private func entry(_ event: CalendarEvent) -> PyDict<JSONValue> {
        var e = events[Self.series(event)] ?? PyDict()
        if e["rejected"] == nil { e["rejected"] = .array([]) }
        if e["chosen"] == nil { e["chosen"] = .array([]) }
        e["title"] = .string(event.title)
        return e
    }

    private func move(_ event: CalendarEvent, _ meeting: String, from: String, to: String) {
        var e = entry(event)
        var out = e[from]?.arrayValue ?? []
        if let i = out.firstIndex(of: .string(meeting)) { out.remove(at: i) }
        e[from] = .array(out)
        var into = e[to]?.arrayValue ?? []
        if !into.contains(.string(meeting)) { into.append(.string(meeting)) }
        e[to] = .array(into)
        events[Self.series(event)] = e
    }

    /// The user said recording `meeting` is not `event`.
    public func rejectEvent(_ event: CalendarEvent, _ meeting: String) { move(event, meeting, from: "chosen", to: "rejected") }

    /// The user chose `event` for recording `meeting`.
    public func confirmEvent(_ event: CalendarEvent, _ meeting: String) { move(event, meeting, from: "rejected", to: "chosen") }

    /// Link this series by time again: its rejections are forgotten.
    public func forgetRule(_ series: String) {
        guard var e = events[series] else { return }
        e["rejected"] = .array([])
        events[series] = e
    }

    /// series → recordings whose stored event is of it (read once).
    private func linkedMeetings() -> [ScalarKey: Set<String>] {
        if let linked { return linked }
        var out: [ScalarKey: Set<String>] = [:]
        var isDir: ObjCBool = false
        if let dir = outputDir, FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
           let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in names where RecordingPaths.isRecordingFolderName(name) {
                let file = dir.appendingPathComponent(name).appendingPathComponent("calendar.json")
                guard let d = PythonJSON.read(file), case .object = d else { continue }
                var series = ""
                if let uid = d["uid"], uid.truthy { series = pyStr(uid) }
                if let r = series.range(of: "/RID=") { series = String(series[..<r.lowerBound]) }
                if series.isEmpty {
                    guard let title = d["title"]?.stringValue else { continue }
                    series = title
                }
                out[ScalarKey(series), default: []].insert(name)
            }
        }
        linked = out
        return out
    }

    /// (rejections, acceptances) of one series: recordings said not to be it; recordings chosen for it, or linked
    /// to it and kept.
    private func counts(_ series: String) -> (Int, Int) {
        let e = events[series]
        let rejected = Set(strings(e, "rejected"))
        let accepted = Set(strings(e, "chosen")).union(linkedMeetings()[ScalarKey(series)] ?? []).subtracting(rejected)
        return (rejected.count, accepted.count)
    }

    public func eventRejections(_ event: CalendarEvent) -> Int { counts(Self.series(event)).0 }
    public func acceptances(_ event: CalendarEvent) -> Int { counts(Self.series(event)).1 }

    /// How often the user said no to this series, when that is more often than they kept it; else 0 (a weekly
    /// meeting kept every week is not in doubt because an ad-hoc call took its slot twice).
    public func doubted(_ event: CalendarEvent) -> Int {
        let (rejected, accepted) = counts(Self.series(event))
        return rejected > accepted ? rejected : 0
    }

    private func isRule(_ series: String) -> Bool {
        let (rejected, accepted) = counts(series)
        return rejected >= Attribution.RULE_AFTER && rejected > accepted
    }

    /// A rule: the user said no to this series often, and more often than not.
    public func neverByTime(_ event: CalendarEvent) -> Bool { isRule(Self.series(event)) }

    /// The rule about this event's series, for the event picker.
    public func rule(_ event: CalendarEvent) -> EvidenceRule? {
        let series = Self.series(event)
        return rules().first { $0.series == series }
    }

    /// The rules corrections made, for the window to show (by series name).
    public func rules() -> [EvidenceRule] {
        Py.stableSorted(events.keys, by: Py.less).compactMap { series in
            guard isRule(series) else { return nil }
            let (rejected, accepted) = counts(series)
            let title = events[series]?["title"]?.stringValue ?? series
            return EvidenceRule(series: series, title: title, rejected: rejected, accepted: accepted,
                                rule: "Not linked by time any more: \(title) — rejected \(rejected)×")
        }
    }
}

public enum Attribution {
    /// Below this a link gets the "unsure" look (a dotted chip) and is asked about.
    public static let UNSURE_BELOW = 0.75
    /// Rejections of one event series that make a rule (when they also outnumber the recordings linked to it):
    /// recordings are no longer linked to it by time.
    public static let RULE_AFTER = 2

    /// What a source is called where no reason was kept.
    public static let SOURCE_TEXT: [String: String] = [
        "you": "you", "calendar": "time match", "voice": "voice", "inferred": "inferred", "rules": "rules",
        "model": "the model", "email": "email address", "unknown": "",
    ]
    public static let _KIND_TEXT: [String: String] = ["event": "Event", "project": "Project", "speaker": "Speaker", "org": "Organization"]
    /// projects.py says "auto" for its rules.
    static let _PROJECT_SOURCES: [String: String] = ["you": "you", "auto": "rules", "model": "model"]

    public struct MissingKey: Error, CustomStringConvertible {
        public let key: String
        public init(key: String) { self.key = key }
        public var description: String { "'\(key)'" }
    }

    /// What to ask the user about one meeting (the meeting as the window gets it): which event, when events
    /// overlapped, and every unsure link. For the "Needs you" page; one item per question, in the order of the page.
    public static func questions(_ meeting: JSONValue) throws -> [JSONValue] {
        func need(_ v: JSONValue?, _ key: String) throws -> JSONValue {
            guard let v else { throw MissingKey(key: key) }
            return v
        }
        let base: [(String, JSONValue)] = [("meeting", try need(meeting["id"], "id")), ("title", meeting["title"] ?? .null),
                                           ("start", meeting["start"] ?? .null)]
        var out: [JSONValue] = []
        if let question = meeting["event_question"], question.truthy {
            out.append(.object(base + [("kind", .string("event")), ("question", .string("Which calendar event was this recording?")),
                                       ("reason", question["reason"] ?? .string("")), ("choices", question["choices"] ?? .array([]))]))
        }
        if let calendar = meeting["calendar"], calendar.truthy, let link = calendar["link"], link.truthy, link["unsure"]?.truthy == true {
            out.append(.object(base + [("kind", .string("event")),
                                       ("question", .string("Was this recording “\(pyStr(try need(link["target"], "target")))”?")),
                                       ("link", link)]))
        }
        for s in meeting["speakers"]?.arrayValue ?? [] {
            if let link = s["link"], link.truthy, link["unsure"]?.truthy == true {
                out.append(.object(base + [("kind", .string("speaker")), ("label", try need(s["label"], "label")),
                                           ("question", .string("Is this \(pyStr(try need(link["target"], "target")))?")), ("link", link)]))
            }
        }
        for p in meeting["projects"]?.arrayValue ?? [] {
            if let link = p["link"], link.truthy, link["unsure"]?.truthy == true {
                out.append(.object(base + [("kind", .string("project")), ("project", p["id"] ?? .null),
                                           ("question", .string("Is this meeting part of \(pyStr(try need(link["target"], "target")))?")),
                                           ("link", link)]))
            }
        }
        return out
    }
}
