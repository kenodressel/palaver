// The Swift side of the `coach` parity op (tools/parity/ops.py, section "coach").
import Foundation
import PalaverCore
import PalaverDomain

extension ParityOps {
    static let coach: [String: Op] = ["coach": coachOp]

    /// The coach's numbers: `action` is plant, analyze, result, meetings, history, baseline, trends, highlights,
    /// refresh or load (ops.py's `coach_op` says what each takes).
    static func coachOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let action = args["action"]?.stringValue
        let user = args["user"]?.stringValue ?? side.userName
        func int(_ key: String) -> Int? { if case .int(let n)? = args[key] { return n } else { return nil } }
        func rows() throws -> [JSONValue] {
            if let given = args["rows"] {
                guard let list = given.arrayValue else { throw BadArgs(description: "coach: rows is no list") }
                return list
            }
            return Coach.history(side.recordings, userName: user, stores: side.stores)
        }
        switch action {
        case "plant":
            guard let name = args["folder"]?.stringValue, let lines = args["lines"]?.arrayValue else {
                throw BadArgs(description: "coach: plant needs folder and lines")
            }
            let folder = side.recordings.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let paths = RecordingPaths(folder)
            try PythonJSON.write(.object([("start_time", args["start_time"] ?? .string("2026-10-27T10:00:00+01:00")),
                                          ("duration_seconds", .int(900))]), to: paths.meta, indent: 2, ensureAscii: true)
            let utterances: [JSONValue] = try lines.map { line in
                guard let l = line.arrayValue, l.count == 4, let who = l[0].stringValue else {
                    throw BadArgs(description: "coach: a line is [speaker, start, end, text]")
                }
                var fields: [(String, JSONValue)] = [("speaker", l[0]), ("start", l[1]), ("end", l[2]), ("text", l[3])]
                if who.hasPrefix("SPEAKER") { fields.append(("label", l[0])) }
                return .object(fields)
            }
            try PythonJSON.write(.array(utterances), to: paths.transcriptJson, indent: 2, ensureAscii: true)
            return .object([])
        case "analyze":
            let names = PyDict((args["names"].flatMap { PyDict<JSONValue>($0) } ?? PyDict()).compactMap { key, value in
                value.stringValue.map { (key, $0) }
            })
            return try Coach.analyze(try calendarFolder(side, args), userName: user,
                                     invited: args["invited"]?.arrayValue?.compactMap(\.stringValue) ?? [], names: names,
                                     stores: side.stores)
        case "result":
            return try Coach.result(try calendarFolder(side, args), userName: user, stores: side.stores)
        case "meetings":
            return .strings(Coach.meetings(side.recordings).map(\.id))
        case "history":
            return .array(Coach.history(side.recordings, userName: user, limit: int("limit"), stores: side.stores))
        case "baseline":
            return try Coach.baseline(try rows())
        case "trends":
            return try Coach.trends(try rows(), weeks: int("weeks") ?? Coach.TREND_WEEKS)
        case "highlights":
            guard let base = args["base"] ?? Coach.loadBaseline(stores: side.stores) else {
                throw BadArgs(description: "coach: highlights needs a base or a saved baseline")
            }
            return .strings(try Coach.highlights(try Coach.result(try calendarFolder(side, args), userName: user,
                                                                  stores: side.stores), base))
        case "refresh":
            return try Coach.refreshBaseline(side.recordings, userName: user, stores: side.stores)
        case "load":
            return Coach.loadBaseline(stores: side.stores) ?? .null
        default:
            throw BadArgs(description: "coach: unknown action \(action.map { "'\($0)'" } ?? "None")")
        }
    }
}
