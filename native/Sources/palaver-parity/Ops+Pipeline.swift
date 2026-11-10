// The Swift side of the `pipeline` parity op (tools/parity/ops.py, section "pipeline"): the merger and the cleanup
// filters.
import Foundation
import PalaverCore
import PalaverDomain

extension ParityOps {
    static let pipeline: [String: Op] = ["pipeline": pipelineOp]

    /// `action` is merge, assign, silent, bleed, echoes, echo or plant-wav (ops.py's `pipeline_op` says what each takes).
    static func pipelineOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        func segments(_ key: String) throws -> [Segment] { try (args[key]?.arrayValue ?? []).map { try Segment(json: $0) } }
        func turns(_ key: String) throws -> [SpeakerTurn] { try (args[key]?.arrayValue ?? []).map { try SpeakerTurn(json: $0) } }
        func track(_ paths: RecordingPaths) throws -> URL {
            switch args["track"]?.stringValue {
            case "system": return paths.systemWav
            case "mic_raw": return paths.micRawWav
            case "mic": return paths.micWav
            default: throw BadArgs(description: "pipeline: track is system, mic_raw or mic")
            }
        }
        func number(_ key: String) throws -> Double {
            guard let d = args[key]?.doubleValue else { throw BadArgs(description: "pipeline: \(key) is no number") }
            return d
        }
        func folder() throws -> RecordingPaths { try calendarFolder(side, .object([("folder", args["folder"] ?? .null)])) }

        switch args["action"]?.stringValue {
        case "plant-wav":
            guard let name = args["folder"]?.stringValue else { throw BadArgs(description: "pipeline: plant-wav needs a folder") }
            let paths = RecordingPaths(side.recordings.appendingPathComponent(name, isDirectory: true))
            try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
            var rate = 16_000
            if case .int(let r)? = args["rate"] { rate = r }
            var x = [Int16](repeating: 0, count: Int(try number("seconds") * Double(rate)))
            for region in args["regions"]?.arrayValue ?? [] {
                guard let r = region.arrayValue, r.count == 4, let start = r[0].doubleValue, let end = r[1].doubleValue,
                      case .int(let amp) = r[2], case .int(let period) = r[3], period > 1 else {
                    throw BadArgs(description: "pipeline: a region is [start, end, amplitude, period]")
                }
                for i in Int(start * Double(rate))..<max(Int(start * Double(rate)), min(x.count, Int(end * Double(rate)))) {
                    x[i] = Int16((i % period) * 2 * amp / (period - 1) - amp)
                }
            }
            try Wav16.write(x, rate: rate, to: try track(paths))
            return .object([("frames", .int(x.count))])
        case "merge":
            let mic: [Segment], system: [Segment], given: [SpeakerTurn]
            if args["folder"] != nil {
                let paths = try folder()
                func read(_ url: URL) throws -> [JSONValue] {
                    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
                    guard let list = try PythonJSON.parse(try Data(contentsOf: url)).arrayValue else {
                        throw BadArgs(description: "pipeline: \(url.lastPathComponent) is no list")
                    }
                    return list
                }
                mic = try read(paths.micSegments).map { try Segment(json: $0) }
                system = try read(paths.systemSegments).map { try Segment(json: $0) }
                given = try read(paths.systemTurns).map { try SpeakerTurn(json: $0) }
            } else {
                (mic, system, given) = (try segments("mic"), try segments("system"), try turns("turns"))
            }
            return .array(Merger.merge(mic: mic, system: system, turns: given).map(\.json))
        case "assign":
            return .array(Merger.assignSpeakersToWords(try segments("segments"), try turns("turns")).map {
                .array([.double($0.start), .double($0.end), .string($0.text), .string($0.speaker)])
            })
        case "silent":
            let wav = try track(try folder())
            let db = args["min_peak_dbfs"] == nil ? Cleanup.MIC_MIN_PEAK_DBFS : try number("min_peak_dbfs")
            return .array(try Cleanup.dropSilentSegments(try segments("segments"), wav: wav, minPeakDbfs: db).map(\.json))
        case "bleed":
            var minWords = 3
            if let w = args["min_words"] { guard case .int(let n) = w else { throw BadArgs(description: "pipeline: min_words") }; minWords = n }
            let window = args["window"] == nil ? 2.0 : try number("window")
            let minOverlap = args["min_overlap"] == nil ? 0.6 : try number("min_overlap")
            return .array(Cleanup.dropBleedDuplicates(try segments("mic"), try segments("system"), window: window,
                                                      minWords: minWords, minOverlap: minOverlap).map(\.json))
        case "echoes":
            guard let mic = args["mic"], let remote = args["remote"]?.arrayValue else { throw BadArgs(description: "pipeline: echoes needs mic and remote") }
            return .bool(Cleanup.echoesRemote(try Segment(json: mic), try remote.map { try Word(json: $0) }))
        case "echo":
            let paths = try folder()
            return .array(try Cleanup.dropEcho(try segments("mic"), try segments("system"), micWav: paths.micWav,
                                               micRawWav: paths.micRawWav).map(\.json))
        default:
            throw BadArgs(description: "pipeline: unknown action \(args["action"].map { PythonJSON.dumps($0) } ?? "None")")
        }
    }
}
