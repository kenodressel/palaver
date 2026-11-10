// The end-to-end tests' language model (debug builds only, `$PALAVER_TEST_LM`: a control folder the test arranges).
// It stands in for whichever model the user chose, which is still named and checked as chosen:
//
// - `calls.jsonl`: one JSON line per ask, written once the ask is let through: `{"kind": "notes" | "projects" |
//   "model", …details, "token", "prompt"}`;
// - `hold-<kind>`: while it exists, an ask of that kind waits (30 s at most);
// - `on-model-run`: while it exists, a "projects" ask waits until the test has made its changes and written
//   `ran-<token>`;
// - `answer-<kind>.json`: what an ask of that kind answers: the model's JSON, or `{"error": "…"}` for a model that
//   fails with that message. Without one it answers what leaves things as they are (`ControlFallback`).
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

/// What the end-to-end tests' model answers when the test gave no answer: the meeting's notes as they are, no new
/// projects, a description as it is, no questions.
public enum ControlFallback {
    public static func notes(_ paths: RecordingPaths) -> JSONValue {
        var out = PyDict<JSONValue>([("title", .string("Notes")), ("summary", .string("")), ("sections", .array([])),
                                     ("next_steps", .array([])), ("decisions", .array([])), ("speaker_names", .array([]))])
        if let now = NotesFile.load(paths).flatMap({ PyDict<JSONValue>($0) }) {
            for key in out.keys { if let v = now[key] { out[key] = v } }
        }
        return out.json
    }

    public static let suggest = JSONValue.object([("new_projects", .array([])), ("assignments", .array([]))])

    public static func describe(_ store: ProjectStore, _ targets: [String]) -> JSONValue {
        .object([("description", targets.first.flatMap { store.projects[$0]?["description"] } ?? .string(""))])
    }
}

#if DEBUG
public final class ControlModel: LanguageModel {
    public static let ENV = "PALAVER_TEST_LM"
    static let HOLD_SECONDS = 30.0

    let folder: URL
    let kind: String
    let details: [(String, JSONValue)]
    let fallback: JSONValue

    public init(folder: URL, kind: String, details: [(String, JSONValue)], fallback: JSONValue) {
        self.folder = folder; self.kind = kind; self.details = details; self.fallback = fallback
    }

    private func waitWhile(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(Self.HOLD_SECONDS)
        while condition() && Date() < deadline { usleep(20_000) }
    }

    private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }

    private func record(_ line: JSONValue) {
        let fd = open(folder.appendingPathComponent("calls.jsonl").path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        let bytes = Array((PythonJSON.dumps(line, ensureAscii: false) + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        flock(fd, LOCK_UN)
    }

    public func generate(prompt: String, schema: JSONValue, parse: @escaping AnswerParser) async throws -> JSONValue {
        waitWhile { exists("hold-\(kind)") }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        record(.object([("kind", .string(kind))] + details + [("token", .string(token)), ("prompt", .string(prompt))]))
        if kind == "projects" && exists("on-model-run") { waitWhile { !exists("ran-\(token)") } }
        let answer = PythonJSON.read(folder.appendingPathComponent("answer-\(kind).json")) ?? fallback
        if let error = answer["error"] { throw LMError(Py.str(error)) }
        do {
            return try parse(PythonJSON.dumps(answer, ensureAscii: false))
        } catch {
            throw LMError("the test's model did not return a valid answer: \(error)")
        }
    }
}
#endif
