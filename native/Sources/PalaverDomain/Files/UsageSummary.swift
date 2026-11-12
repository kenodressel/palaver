// What a problem report says about the usage log (usage.py `catalog`, `MENUBAR_FEATURES`, `summary`): every feature
// there is, and per feature how often it was used over 7 and 30 days, the features never used, recordings, notes and
// process runs, errors.
import Foundation
import PalaverCore

extension Usage {
    /// What the menu bar icon's menu counts itself.
    public static let MENUBAR_FEATURES: [(String, [String])] = [("action", ["menubar.reportProblem"])]

    /// The `palaver` command's commands (the Swift CLI's, `CLIMain.commandNames`; cli.py `command_names` had more): the
    /// catalog's "cli" kind, so a report says which of them a tester never typed.
    public static let CLI_COMMANDS = ["app", "daemon", "doctor", "export", "import", "index", "list", "mcp", "notes", "process",
                                      "projects", "prune", "report", "run", "sync", "voices"]

    private static func sortedUnique(_ items: [String]) -> [String] {
        var seen = Set<[Unicode.Scalar]>(), out: [String] = []
        for s in items where seen.insert(Array(s.unicodeScalars)).inserted { out.append(s) }
        return out.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    /// `catalog()`: every feature there is: the window's (its last start's `usage-features.json`), the CLI's
    /// commands, the settings, the menu bar's.
    public static func catalog(path: URL? = nil, cliCommands: [String] = CLI_COMMANDS) -> [(String, [String])] {
        var out: [(String, [String])] = []
        func set(_ kind: String, _ ids: [String]) {
            if let i = out.firstIndex(where: { Py.same($0.0, kind) }) { out[i].1 = ids } else { out.append((kind, ids)) }
        }
        func get(_ kind: String) -> [String] { out.first { Py.same($0.0, kind) }?.1 ?? [] }
        if case .object(let saved)? = PythonJSON.read(path ?? StorePaths.current().usageFeatures) {
            for (kind, v) in saved where isOne(kind, of: FEATURE_KINDS) {
                if case .array(let items) = v { set(kind, items.map { $0.stringValue ?? Py.str($0) }) }
            }
        }
        set("cli", cliCommands)
        var settings: [String] = []
        if case .object(let known) = SettingsValues().json { settings = known.map(\.0) }
        set("setting", sortedUnique(get("setting") + settings))
        for (kind, ids) in MENUBAR_FEATURES { set(kind, sortedUnique(get(kind) + ids)) }
        return out
    }

    /// The catalog as JSON (`{kind: [ids]}`).
    public static func catalogJSON(_ catalog: [(String, [String])]) -> JSONValue {
        .object(catalog.map { ($0.0, .strings($0.1)) })
    }

    /// When an event happened (its `ts`; one without a zone is this Mac's local time).
    static func when(_ e: Event, timeZone: TimeZone) -> Date? { WallTime.parse(e["ts"]?.stringValue, timeZone) }

    /// `summary(events, catalog, now)`: counts per feature over 7 and 30 days and in all, the features never used (and
    /// not in 30 days), recordings, notes and process runs, errors.
    public static func summary(_ events: [Event], catalog: [(String, [String])], now: Date = Date(),
                               timeZone: TimeZone = .current) -> JSONValue {
        let week = now.addingTimeInterval(-7 * 86400), month = now.addingTimeInterval(-30 * 86400)
        let dated = events.map { ($0, when($0, timeZone: timeZone)) }
        var features: [String: (week: Int, month: Int, all: Int)] = [:]
        for (e, at) in dated {
            guard let name = feature(e) else { continue }
            var c = features[name] ?? (0, 0, 0)
            c.all += 1
            if let at, at >= week { c.week += 1 }
            if let at, at >= month { c.month += 1 }
            features[name] = c
        }
        let known = Set(catalog.flatMap { kind, ids in ids.map { "\(kind):\($0)" } })
        let recent = dated.filter { $0.1.map { $0 >= month } ?? false }.map(\.0)
        func runs(_ kind: String) -> [Event] { recent.filter { $0["kind"]?.stringValue == kind } }
        func ok(_ e: Event) -> Bool { e["ok"]?.truthy ?? false }
        func seconds(_ rows: [Event]) -> [Double] {
            rows.compactMap { e in
                switch e["seconds"] { case .int(let i)?: return Double(i); case .double(let d)?: return d; default: return nil }
            }
        }
        func median(_ values: [Double]) -> JSONValue { .num(PyStatistics.median(values).map { Py.round($0, 1) }) }
        func counts(_ values: [String]) -> JSONValue {
            var c: [String: Int] = [:]
            for v in values { c[v, default: 0] += 1 }
            return .object(c.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { ($0.key, .int($0.value)) })
        }
        func text(_ v: JSONValue?) -> String? { v.flatMap { $0.truthy ? ($0.stringValue ?? Py.str($0)) : nil } }
        let stops = runs("recording_stop"), notes = runs("notes"), process = runs("process"), errors = runs("error")
        let times = dated.compactMap(\.1)
        let iso = { (d: Date) in WallTime.iso(d, timeZone, seconds: true) }
        let minutes = stops.map { e -> Double in
            switch e["seconds"] {
            case .int(let i)?: return Double(i)
            case .double(let d)?: return d
            case .string(let s)?: return Double(s) ?? 0
            default: return 0
            }
        }.reduce(0, +) / 60
        let names = features.keys.sorted()
        // In typed parts: one literal of all of it is more than the type checker manages on a slower Mac (CI).
        let since: JSONValue = times.min().map { JSONValue.string(iso($0)) } ?? .null
        let featureFields: [(String, JSONValue)] = names.map { n -> (String, JSONValue) in
            let c = features[n]!
            return (n, .object([("7d", .int(c.week)), ("30d", .int(c.month)), ("all", .int(c.all))]))
        }
        let triggers: [String] = stops.map { text($0["trigger"]) ?? "unknown" }
        let recordings: [(String, JSONValue)] = [
            ("count", .int(stops.count)),
            ("minutes", .double(Py.round(minutes, 1))),
            ("by_trigger", counts(triggers)),
        ]
        let models: [String] = notes.map { n -> String in "\(text(n["engine"]) ?? "?") \(text(n["model"]) ?? "?")" }
        let notesFields: [(String, JSONValue)] = [
            ("runs", .int(notes.count)),
            ("ok", .int(notes.filter(ok).count)),
            ("failed", .int(notes.filter { !ok($0) }.count)),
            ("median_seconds", median(seconds(notes))),
            ("by_model", counts(models)),
        ]
        let processFields: [(String, JSONValue)] = [
            ("runs", .int(process.count)),
            ("ok", .int(process.filter(ok).count)),
            ("failed", .int(process.filter { !ok($0) }.count)),
            ("median_seconds", median(seconds(process))),
        ]
        let lastErrors: [JSONValue] = errors.suffix(20).map { e -> JSONValue in
            .object([("ts", e["ts"] ?? .null), ("text", e["text"] ?? .null)])
        }
        let fields: [(String, JSONValue)] = [
            ("generated", .string(iso(now))),
            ("events", .int(events.count)),
            ("since", since),
            ("features", .object(featureFields)),
            ("never_used", .strings(known.subtracting(names).sorted())),
            ("unused_30d", .strings(known.subtracting(names.filter { features[$0]!.month > 0 }).sorted())),
            ("recordings", .object([("30d", .object(recordings))])),
            ("notes", .object([("30d", .object(notesFields))])),
            ("process", .object([("30d", .object(processFields))])),
            ("errors", .object([("30d", .int(errors.count)), ("last", .array(lastErrors))])),
        ]
        return .object(fields)
    }
}
