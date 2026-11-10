// What a route throws, and what the window gets for it (webapp/server.py:305-311, :537-551): the
// one table every route's errors go through. A route never builds an error answer itself.
import Foundation
import PalaverCore
import PalaverDomain

/// `api.NotFound`: 404 `not found: <what>`.
public struct NotFound: Error, CustomStringConvertible {
    public let what: String
    public init(_ what: String) { self.what = what }
    public var description: String { what }
}

/// `api.Refused`: 400 with its text, which the page shows.
public struct Refused: Error, CustomStringConvertible {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var description: String { text }
}

/// `KeyError`/`ValueError` of a request: 400 `bad request: <text>`.
public struct BadRequest: Error, CustomStringConvertible {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var description: String { text }
}

/// 409 with its text.
public struct Conflict: Error, CustomStringConvertible {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var description: String { text }
}

/// 409 `{"error": text, "document": document}`: a save on an old revision gets the document as it is.
public struct ConflictDocument: Error, CustomStringConvertible {
    public let text: String
    public let document: JSONValue
    public init(_ text: String, document: JSONValue) {
        self.text = text
        self.document = document
    }
    public var description: String { text }
}

/// The language model is in use (server.py:706-741): 409.
public struct ModelBusy: Error, CustomStringConvertible {
    public static let text = "the language model is busy; try again in a minute"
    public init() {}
    public var description: String { ModelBusy.text }
}

/// 502 with its text: a helper (the language model) failed.
public struct BadGateway: Error, CustomStringConvertible {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var description: String { text }
}

/// 503 with its text: what is asked for is turned off or not there.
public struct Unavailable: Error, CustomStringConvertible {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var description: String { text }
}

/// The page let go of the request (`ConnectionError`): nobody to answer, no error.
public struct ClientGone: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "the page let go of the request" }
}

public enum ErrorTable {
    /// The status and the JSON body for `error`; nil for `ClientGone` (no answer at all).
    /// `UndoGone`, `UndoChanged` are the domain's (undo.py's `Gone`, `Changed`); anything not in the
    /// table (`GlossaryLookupError`, `ProjectLookupError` among them) is a 500 with its description.
    public static func answer(_ error: Error) -> (status: Int, body: JSONValue)? {
        func text(_ status: Int, _ message: String) -> (Int, JSONValue) { (status, .object([("error", .string(message))])) }
        switch error {
        case is ClientGone: return nil
        case let e as NotFound: return text(404, "not found: \(e.what)")
        case let e as Refused: return text(400, e.text)
        case let e as BadRequest: return text(400, "bad request: \(e.text)")
        case let e as Conflict: return text(409, e.text)
        case let e as ConflictDocument: return (409, .object([("error", .string(e.text)), ("document", e.document)]))
        case is ModelBusy: return text(409, ModelBusy.text)
        case let e as BadGateway: return text(502, e.text)
        case let e as Unavailable: return text(503, e.text)
        case is UndoGone: return text(404, "can't undo this any more")
        case is UndoChanged: return text(409, "the meeting changed since")
        default: return text(500, String(describing: error))
        }
    }

    /// A 500: logged with the request (server.py's `LOGGER.exception`); the others are the page's.
    public static func isFailure(_ error: Error) -> Bool { answer(error)?.status == 500 }
}
