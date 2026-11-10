// Local usage metrics (#59), usage.py:1-136: one append-only JSON line per event in `usage.jsonl`, never leaving the
// Mac except inside a problem report. `record` is the one way in and never fails: counting must not break what is
// counted. `summary`, `catalog` and `MENUBAR_FEATURES` (usage.py:136-238) are in UsageSummary.swift (the problem report).
import Darwin
import Foundation
import PalaverCore

public struct UsageError: Error, CustomStringConvertible {
    public let description: String
}

public enum Usage {
    public static let MAX_TEXT = 200
    public static let FEATURE_KINDS = ["action", "view", "tab", "palette", "setting", "cli"]
    /// What the page may post: its own feature kinds, and the errors it showed.
    public static let PAGE_KINDS = ["action", "view", "tab", "palette", "error"]

    public typealias Event = PyDict<JSONValue>

    private static func cut(_ s: String, _ n: Int) -> String { String(String.UnicodeScalarView(s.unicodeScalars.prefix(n))) }

    static func isOne(_ s: String, of kinds: [String]) -> Bool { kinds.contains { Py.same($0, s) } }

    /// `str(x)` of a JSON value.
    private static func str(_ v: JSONValue) -> String { v.stringValue ?? MyNotes.pyRepr(v) }

    /// `_small`: texts cut to `MAX_TEXT` code points, floats to one decimal, lists to 20 items.
    static func small(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s): return .string(cut(s, MAX_TEXT))
        case .double(let d): return .double(Py.round(d, 1))
        case .array(let items): return .array(items.prefix(20).map(small))
        default: return value
        }
    }

    /// `record(kind, id, **fields)`: appends one event; never fails. The line is one `write` of a short line to a file
    /// opened for appending (`O_APPEND`), as Python does: processes don't interleave, and nothing is locked.
    public static func record(_ kind: String, _ id: String? = nil, fields: [(String, JSONValue)] = [],
                              path: URL? = nil, now: Date = Date(), timeZone: TimeZone = .current) {
        var row = PyDict<JSONValue>()
        row["ts"] = .string(Py.isoNow(timespec: "seconds", now: now, timeZone: timeZone))
        row["kind"] = .string(kind)
        if let id { row["id"] = small(.string(id)) }
        for (k, v) in fields { row[k] = small(v) }
        let url = path ?? StorePaths.current().usage
        let line = Array((PythonJSON.dumps(row.json, ensureAscii: false) + "\n").utf8)
        do { try Undo.makedirs(url.deletingLastPathComponent().path) } catch { return }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        while write(fd, line, line.count) < 0 && errno == EINTR {}
    }

    /// `read(path)`: the events, skipping lines that are not one (cut short, edited); none when the file is not there.
    public static func read(_ path: URL? = nil) -> [Event] {
        guard let data = try? Data(contentsOf: path ?? StorePaths.current().usage) else { return [] }
        return readLines(String(decoding: data, as: UTF8.self))
    }

    public static func readLines(_ text: String) -> [Event] {
        var out: [Event] = []
        for line in ModelJobs.splitlines(text) {
            guard let row = try? PythonJSON.parse(Data(line.utf8)), case .object(let fields) = row,
                  case .string? = row["kind"], case .string? = row["ts"] else { continue }
            out.append(PyDict(fields))
        }
        return out
    }

    /// `feature(e)`: the feature an event is a use of (`kind:id`), or nil (a run, an error, a command the app ran).
    public static func feature(_ e: Event) -> String? {
        guard case .string(let kind)? = e["kind"], isOne(kind, of: FEATURE_KINDS), let id = e["id"], id.truthy else { return nil }
        if Py.same(kind, "cli"), !(e["by"]?.stringValue.map { Py.same($0, "user") } ?? false) { return nil }
        return "\(kind):\(str(id))"
    }

    // MARK: - Settings changed

    /// `setting_events(path, body)`: what a settings change of the window records: the keys, a switch's or a
    /// choice's value, never a key, endpoint or other free text.
    public static func settingEvents(path: String, body: JSONValue) -> [JSONValue] {
        guard case .object(let fields) = body else { return [] }
        func has(_ k: String) -> Bool { body[k] != nil }
        func event(_ pairs: [(String, JSONValue)]) -> JSONValue { .object(pairs) }
        if path.unicodeScalars.suffix(4).elementsEqual("/key".unicodeScalars) {
            let provider = body["provider"].map(str) ?? "None"
            return [event([("id", .string("key.\(provider)")), ("removed", .bool(body["remove"]?.truthy ?? false))])]
        }
        if Py.same(path, "/api/settings") {
            guard case .object(let known) = SettingsValues().json else { return [] }
            return fields.compactMap { k, v in
                guard known.contains(where: { Py.same($0.0, k) }), case .bool = v else { return nil }
                return event([("id", .string(k)), ("value", v)])
            }
        }
        var out: [JSONValue] = []
        switch body["use"] {
        case .object(let use)?:
            out += use.map { k, v in event([("id", .string("use.\(k)")), ("value", .string(cut(str(v), 80)))]) }
        case .string(let use)?:
            out.append(event([("id", .string("use")), ("value", .string(cut(use, 80)))]))
        default: break
        }
        if let provider = body["provider"] {
            let changed = Py.stableSorted(fields.map(\.0).filter { !Py.same($0, "provider") && !Py.same($0, "use") }) {
                $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars)
            }
            out.append(event([("id", .string("provider.\(str(provider))")), ("fields", .array(changed.map { .string($0) }))]))
        }
        if let model = body["local_model"] {
            out.append(event([("id", .string("local_model")), ("value", .string(cut(str(model), 120)))]))
        }
        return out
    }

    // MARK: - The catalog

    /// `save_catalog(catalog)`: the window's features (its action registry, views, tabs), as the page posts them,
    /// into `usage-features.json` (`json.dumps(indent=1)`, through `<name>.<pid>.tmp`). An unwritable place is
    /// ignored, as Python ignores `OSError`; a catalog that is no object raises there (`.items()`), so it throws here.
    public static func saveCatalog(_ catalog: JSONValue?, path: URL? = nil) throws {
        var clean: [(String, JSONValue)] = []
        if let catalog, catalog.truthy {
            guard case .object(let entries) = catalog else { throw UsageError(description: "the catalog is no object") }
            for (k, v) in entries {
                guard isOne(k, of: FEATURE_KINDS), case .array(let items) = v else { continue }
                var seen = Set<[Unicode.Scalar]>(), ids: [String] = []
                for case .string(let s) in items {
                    let id = cut(s, 80)
                    if seen.insert(Array(id.unicodeScalars)).inserted { ids.append(id) }
                }
                ids = Py.stableSorted(ids) { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
                clean.append((k, .array(ids.prefix(500).map { .string($0) })))
            }
        }
        let url = path ?? StorePaths.current().usageFeatures
        do {
            try Undo.makedirs(url.deletingLastPathComponent().path)
            try PythonJSON.write(.object(clean), to: url, indent: 1, ensureAscii: true,
                                 via: "\(url.lastPathComponent).\(getpid()).tmp")
        } catch {}
    }
}
