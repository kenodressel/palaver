// What every language model Palaver runs looks like to the features (notes, projects, the best next question): a prompt
// and a JSON schema in, the answer's JSON object out (notes.py's `Runner`). The model's text goes through the feature's
// `parse`, which repairs what small models get wrong and refuses what can't be repaired; a refused answer is asked for
// again once, then the run fails with a message that is safe to show.
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

/// A language model's run failed (notes.py `NotesError`): the message says why, safe to show and to log.
public struct LMError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// The model's answer could not be read (Python's ValueError from a parser): the runner asks again.
public struct BrokenAnswer: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Turns the model's text into the feature's answer, or throws `BrokenAnswer`.
public typealias AnswerParser = (String) throws -> JSONValue

public protocol LanguageModel {
    /// The answer to `prompt`, a JSON object that `parse` accepted. `schema` is the answer's JSON schema; its
    /// "description" (the notes' language) is said first in the system text.
    func generate(prompt: String, schema: JSONValue, parse: @escaping AnswerParser) async throws -> JSONValue
}

public enum Asking {
    /// How often a model is asked for one answer: once more when the first does not parse.
    public static let ATTEMPTS = 2

    /// `ask` until `parse` takes the answer, at most `ATTEMPTS` times; then `fail(problem)`.
    public static func parsed(parse: AnswerParser, fail: (String) -> Error,
                              ask: () async throws -> String) async throws -> JSONValue {
        var problem = ""
        for _ in 0..<ATTEMPTS {
            let text = try await ask()
            do { return try parse(text) } catch { problem = String(describing: error) }
        }
        throw fail(problem)
    }

    /// The system text a model that is not given the schema separately reads (notes.py `local_runner`): the schema's
    /// description (the notes' language) said plainly first, then the schema.
    public static func system(_ schema: JSONValue) -> String {
        var system = "Answer with a single JSON object that follows this JSON schema, and nothing else:\n"
            + PythonJSON.dumps(schema)
        if let description = schema["description"]?.stringValue, !description.isEmpty {
            system = description + "\n\n" + system
        }
        return system
    }

    /// A message for a failed call that is safe to show: the error's own words for the errors that are written to be
    /// shown, else only its kind.
    public static func message(_ error: Error) -> String {
        switch error {
        case is LMError, is CloudError, is EngineUnavailable, is ContextTooLong: return String(describing: error)
        default: return String(describing: type(of: error))
        }
    }
}

extension JSONValue {
    /// A JSON object (Python's `isinstance(x, dict)`).
    var isDict: Bool { if case .object = self { return true } else { return false } }
}
