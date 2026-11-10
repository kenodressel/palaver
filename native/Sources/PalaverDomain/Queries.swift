// The small facts the app asks of the pipeline's side (palaver/app_query.py: `missing-models`, `index-stale`,
// `next-event`, `event-key`), answered by `palaver-worker query <what> [arg] --json`, plus `resources` (whether
// the domain's resources are found). Each answer is one JSON object.
import Foundation
import PalaverCore

public enum Queries {
    /// What `query` answers (app_query.py's `WHATS` the pipeline owns, and `resources`).
    public static let WHATS = ["missing-models", "index-stale", "notes-memory", "next-event", "event-key", "resources"]
    /// The queries that need an argument (a folder, a time).
    static let needs = ["missing-models": 1, "notes-memory": 1, "event-key": 1]

    public static let usage = "usage: palaver-worker query {\(WHATS.joined(separator: "|"))} [folder|time] --json"

    public struct QueryError: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// `{"missing": [labels]}`: the models `process` still needs for `folder` that are not on this Mac.
    public static func missingModels(folder: URL, config: Config,
                                     speechModelsHere: () -> Bool = { ModelCatalog.speechFilesHere() }) -> JSONValue {
        let missing = ProcessState.missingModels(transcriber: config.transcriber, paths: RecordingPaths(folder),
                                                 speechModelsHere: speechModelsHere)
        return .object([("missing", .strings(missing))])
    }

    /// `{"stale": [folders], "model_ready": bool}`: the meetings the search by meaning has not indexed yet, and
    /// whether its model is on this Mac (its first run downloads it otherwise).
    public static func indexStale(outputDir: URL, modelReady: () -> Bool = { E5Encoder.modelFolder() != nil }) -> JSONValue {
        .object([("stale", .strings(SearchIndex.stale(outputDir: outputDir).map(\.folder.path))),
                 ("model_ready", .bool(modelReady()))])
    }

    /// `{"event": {title, start, end, key} | null}`: the first timed event of the next 24 hours still to come.
    /// `calendar` nil: the calendar is off or not allowed.
    public static func nextEvent(calendar: CalendarProvider?, now: PyDateTime = localNow()) throws -> JSONValue {
        guard let calendar else { return .object([("event", .null)]) }
        let events = try calendar(now.date, try now.adding(seconds: 24 * 3600).date)
        let upcoming = Py.stableSorted(events.filter { !$0.allDay && $0.start > now }) { $0.start < $1.start }
        guard let e = upcoming.first else { return .object([("event", .null)]) }
        return .object([("event", .object([("title", .string(e.title)), ("start", .string(e.start.iso)),
                                           ("end", .string(e.end.iso)), ("key", .string(e.key))]))])
    }

    /// `{"key": text | null}`: the key of the event at `at` (isoformat; without an offset it is local time).
    public static func eventKey(at text: String, calendar: CalendarProvider?) throws -> JSONValue {
        var when = try PyDateTime.parse(text)
        if when.offset == nil { when = localized(when) }
        guard let calendar else { return .object([("key", .null)]) }
        let events = try calendar(try when.adding(seconds: -2 * 3600).date, try when.adding(seconds: 2 * 3600).date)
        return .object([("key", events.isEmpty ? .null : .str(CalendarEvents.eventKeyAt(events, when)))])
    }

    /// `{"gb": float}`: the free memory the notes of `folder` wait for (llm.notes_memory_gb): the local model's need,
    /// none for a cloud model.
    public static func notesMemory(folder: URL, config: Config, stores: StorePaths = .current()) -> JSONValue {
        .object([("gb", .double(ModelChoice.memoryGB(feature: "notes", folder: folder, config: config, stores: stores)))])
    }

    /// `{"zipf": bool}`: whether the glossary's word frequencies are found (a bundling check).
    public static func resources() -> JSONValue {
        .object([("zipf", .bool(DomainResources.url("zipf.bin") != nil))])
    }

    /// The answer to `what`; throws what becomes `{"error": …}` (exit 1).
    public static func answer(_ what: String, args: [String], config: Config, calendar: CalendarProvider?) throws -> JSONValue {
        switch what {
        case "missing-models": return missingModels(folder: URL(fileURLWithPath: args[0]), config: config)
        case "index-stale": return indexStale(outputDir: config.outputDir)
        case "notes-memory": return notesMemory(folder: URL(fileURLWithPath: args[0]), config: config)
        case "next-event": return try nextEvent(calendar: calendar)
        case "event-key": return try eventKey(at: args[0], calendar: calendar)
        case "resources": return resources()
        default: throw QueryError(what)
        }
    }

    /// The one JSON line and the exit code: 0 an answer, 1 `{"error"}` when it failed, 2 `{"error": usage}`.
    public static func run(_ what: String?, args: [String], config: () throws -> Config,
                           calendar: (Config) -> CalendarProvider?) -> (line: String, code: Int32) {
        guard let what, WHATS.contains(what), args.count >= needs[what, default: 0] else {
            return (JSONValue.object([("error", .string(usage))]).encoded(indent: nil), 2)
        }
        do {
            let cfg = try config()
            return (try answer(what, args: args, config: cfg, calendar: calendar(cfg)).encoded(indent: nil), 0)
        } catch {
            let text = "\(error)".trimmingCharacters(in: .whitespacesAndNewlines)
            return (JSONValue.object([("error", .string(text.isEmpty ? "\(type(of: error))" : text))]).encoded(indent: nil), 1)
        }
    }

    /// `datetime.now().astimezone()`.
    public static func localNow(_ zone: TimeZone = .current) -> PyDateTime {
        let now = Date()
        return PyDateTime(now, offset: zone.secondsFromGMT(for: now))
    }

    /// `naive.astimezone()`: a wall time read in `zone`.
    static func localized(_ naive: PyDateTime, zone: TimeZone = .current) -> PyDateTime {
        let guess = naive.date
        var offset = zone.secondsFromGMT(for: guess)
        offset = zone.secondsFromGMT(for: guess.addingTimeInterval(-Double(offset)))
        return PyDateTime(micros: naive.micros - Int64(offset) * 1_000_000, offset: offset)
    }
}
