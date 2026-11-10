// The Swift side of the parity ops (tools/parity/ops.py is the Python side): each op runs on one
// side of a parity run and answers a JSON value. Later tasks add `Ops+<Area>.swift` files and a
// `merging` line each in `table`.
import Foundation
import PalaverCore
import PalaverDomain

/// A side of a parity run (tools/parity/corpus.py), seen through the environment run.py sets:
/// `XDG_CONFIG_HOME` is its config/, `PALAVER_HOME` its home/.
struct ParitySide {
    let root: URL
    /// config.toml's output_dir.
    let recordings: URL
    let stores: StorePaths
    /// settings.json's user_name, else config.toml's [user] name (palaver.config.load_config).
    let userName: String
    /// events.json: the fake calendar.
    let events: [JSONValue]

    static func load(root: URL, env: [String: String] = ProcessInfo.processInfo.environment) -> ParitySide {
        let stores = StorePaths.current(env: env)
        let config = Config.load(stores.configToml, environment: env)
        var name = config.userName
        if let chosen = PythonJSON.read(stores.settings)?["user_name"]?.stringValue, !Py.strip(chosen).isEmpty {
            name = Py.strip(chosen)
        }
        let events = PythonJSON.read(root.appendingPathComponent("events.json"))?.arrayValue ?? []
        return ParitySide(root: root, recordings: config.outputDir, stores: stores, userName: name, events: events)
    }
}

/// What kind of failure an error is, as tools/parity/ops.py's `error_kind` names Python's:
/// refused, not_found, gone, changed, bad_request (what the server answers 400/404/409 for), or
/// bad_args (the harness's). Errors that don't say are "other" (500).
protocol ParityErrorKind: Error {
    var parityKind: String { get }
}

/// The scenario gave an op args it can't use.
struct BadArgs: ParityErrorKind, CustomStringConvertible {
    let description: String
    var parityKind: String { "bad_args" }
}

enum ParityOps {
    typealias Op = (ParitySide, JSONValue) throws -> JSONValue

    static let table: [String: Op] = json.merging(meetings) { a, _ in a }.merging(stores) { a, _ in a }.merging(myNotes) { a, _ in a }.merging(text) { a, _ in a }.merging(calendar) { a, _ in a }
        .merging(speakers) { a, _ in a }.merging(projects) { a, _ in a }.merging(search) { a, _ in a }.merging(notes) { a, _ in a }.merging(files) { a, _ in a }.merging(coach) { a, _ in a }.merging(pipeline) { a, _ in a }.merging(app) { a, _ in a }

    // MARK: - json (Task 4)

    static let json: [String: Op] = ["json-roundtrip": jsonRoundtrip]

    /// Every `*.json` under the side read and written again through PythonJSON, in its file's
    /// format: `args["formats"]` (ops.JSON_FORMATS) by file name, else by "<folder>/".
    static func jsonRoundtrip(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        guard let formats = args["formats"], case .object = formats else {
            throw BadArgs(description: "json-roundtrip needs formats")
        }
        var rewritten = 0
        for url in jsonFiles(under: side.root) {
            guard let data = try? Data(contentsOf: url), let value = try? PythonJSON.parse(data) else { continue }
            let format = formats[url.lastPathComponent]
                ?? formats[url.deletingLastPathComponent().lastPathComponent + "/"] ?? .object([])
            var indent: Int?
            if case .int(let n)? = format["indent"] { indent = n }
            try PythonJSON.write(value, to: url, indent: indent, ensureAscii: format["ensure_ascii"]?.boolValue ?? true,
                                 newline: format["newline"]?.boolValue ?? false)
            rewritten += 1
        }
        return .object([("rewritten", .int(rewritten))])
    }

    /// `root.rglob("*.json")`, files only: hidden ones too, symlinked folders not followed.
    static func jsonFiles(under root: URL) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        return walk.compactMap { $0 as? URL }.filter {
            $0.lastPathComponent.hasSuffix(".json") && (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }
}
