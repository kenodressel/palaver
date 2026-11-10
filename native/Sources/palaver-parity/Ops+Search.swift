// The Swift side of the `search-parse`, `e5-encode` and `index` parity ops (tools/parity/ops.py, section "search (Tasks 19, 34,
// 35)").
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

extension ParityOps {
    static let search: [String: Op] = ["search-parse": searchParseOp, "e5-encode": e5EncodeOp, "index": indexOp]

    /// SearchParser.parse of each of `texts` with `vocab` ({people, projects: {id: name}, orgs}; empty when left out)
    /// on `today` (an ISO date, required).
    static func searchParseOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        guard let today = args["today"]?.stringValue.flatMap(PyDate.init(iso:)), let texts = args["texts"]?.arrayValue else {
            throw BadArgs(description: "search-parse needs today and texts")
        }
        let v = args["vocab"] ?? .null
        let projects = v["projects"].flatMap { PyDict($0) } ?? PyDict()
        let vocab = Vocabulary(people: v["people"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                               projects: PyDict(projects.map { ($0.key, $0.value.stringValue ?? "") }),
                               orgs: v["orgs"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let queries = try texts.map { text -> JSONValue in
            guard let text = text.stringValue else { throw BadArgs(description: "search-parse: texts are strings") }
            return SearchParser.parse(text, vocab: vocab, today: today).json
        }
        return .object([("queries", .array(queries))])
    }

    /// The checkout (palaver-parity is a test helper, run from it): relative model folders are the tiny fixtures.
    private static let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../..").standardizedFileURL

    /// E5Encoder on `folder` (absolute, or relative to the checkout; only read): the `ids` of each of `texts` with the
    /// passage prefix in front (`"kind": "query"`: the query prefix), and their `vectors` (`passages(texts)`, or
    /// `query` of each), every number rounded to `round` places when given. `prefix_query` and `prefix_passage`
    /// replace the encoder's defaults.
    static func e5EncodeOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let kind = args["kind"]?.stringValue ?? "passages"
        guard let folder = args["folder"]?.stringValue, let items = args["texts"]?.arrayValue, kind == "passages" || kind == "query"
        else { throw BadArgs(description: "e5-encode needs folder, texts and kind passages or query") }
        let texts = try items.map { item -> String in
            guard let text = item.stringValue else { throw BadArgs(description: "e5-encode: texts are strings") }
            return text
        }
        let url = folder.hasPrefix("/") ? URL(fileURLWithPath: folder, isDirectory: true)
            : checkout.appendingPathComponent(folder, isDirectory: true)
        let encoder = try E5Encoder(folder: url, prefixQuery: args["prefix_query"]?.stringValue ?? "query: ",
                                    prefixPassage: args["prefix_passage"]?.stringValue ?? "passage: ")
        let prefix = kind == "query" ? encoder.prefixQuery : encoder.prefixPassage
        let vectors = kind == "query" ? try texts.map { try encoder.query($0) } : try encoder.passages(texts)
        var digits: Int?
        if let r = args["round"], !r.isNull {
            guard case .int(let n) = r else { throw BadArgs(description: "e5-encode: round is an int") }
            digits = n
        }
        func number(_ v: Float) -> JSONValue { .double(digits.map { Py.round(Double(v), $0) } ?? Double(v)) }
        return .object([("ids", .array(texts.map { .array(encoder.ids(prefix + $0).map { .int($0) }) })),
                        ("vectors", .array(vectors.map { .array($0.map(number)) }))])
    }

    private static let indexSources = ["transcript.json", "notes.json", "speakers_ignored.json", "speakers_lines.json"]

    /// The search-by-meaning index (SearchIndex) under the model string `model` ("tiny-bert-fixture" by default) with
    /// the tiny embedder in `folder` (checkout-relative, the `bert` fixture by default). `action`: `run` (indexStale,
    /// or `only` these folders: the number indexed and the folders stale after), `stale`, `chunks` (`folder`'s
    /// pieces), `plant` (`text`, when given, written as `folder`'s `file`, one of the index's sources, then its times
    /// set to `ns`) or `floor` (of `scores` as float32).
    static func indexOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let model = args["model"]?.stringValue ?? "tiny-bert-fixture"
        func stale() -> JSONValue {
            .array(SearchIndex.stale(outputDir: side.recordings, model: model).map { .string($0.folder.lastPathComponent) })
        }
        switch args["action"]?.stringValue ?? "run" {
        case "run":
            let folder = args["folder"]?.stringValue ?? "tests/fixtures/tiny_embedder/bert"
            let url = checkout.appendingPathComponent(folder, isDirectory: true)
            var only: [RecordingPaths]?
            if let names = args["only"], !names.isNull {
                guard let list = names.arrayValue else { throw BadArgs(description: "index: only is a list") }
                only = try list.map { name in
                    guard let name = name.stringValue else { throw BadArgs(description: "index: only lists folder names") }
                    return RecordingPaths(side.recordings.appendingPathComponent(name, isDirectory: true))
                }
            }
            let done = try SearchIndex.indexStale(outputDir: side.recordings, encoder: { try E5Encoder(folder: url) },
                                                  model: model, only: only)
            return .object([("done", .int(done)), ("stale", stale())])
        case "stale":
            return .object([("stale", stale())])
        case "chunks":
            return .object([("chunks", .array(try SearchIndex.chunks(try calendarFolder(side, args))))])
        case "plant":
            let paths = try calendarFolder(side, args)
            guard let file = args["file"]?.stringValue, indexSources.contains(where: { $0.unicodeScalars.elementsEqual(file.unicodeScalars) }),
                  case .int(let ns)? = args["ns"] else {
                throw BadArgs(description: "index plant needs ns and a file of \(indexSources)")
            }
            let url = paths.folder.appendingPathComponent(file)
            if let text = args["text"]?.stringValue {
                try Data(text.utf8).write(to: url)
            }
            let time = timespec(tv_sec: ns / 1_000_000_000, tv_nsec: ns % 1_000_000_000)
            let times = [time, time]
            guard utimensat(AT_FDCWD, url.path, times, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return .object([])
        case "floor":
            guard let scores = args["scores"]?.arrayValue else { throw BadArgs(description: "index floor needs scores") }
            return .object([("floor", .double(SearchIndex.floor(scores.map { Float($0.doubleValue ?? .nan) })))])
        case let action:
            throw BadArgs(description: "index: unknown action '\(action)'")
        }
    }
}
