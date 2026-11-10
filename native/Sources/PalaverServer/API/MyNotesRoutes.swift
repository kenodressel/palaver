// The user's own notes (#44) of a meeting or of one still to come (api.py `my_notes_folder`, `prep_notes_folder`,
// `adopt_prepared_notes`, `get_my_notes`, `save_my_notes`, `add_my_notes_image`, `my_notes_image`,
// `delete_my_notes_image`, `clear_my_notes`; server.py `_MY_NOTES`, `_notes_folder`, `_my_notes_get`, `_my_notes_post`).
//
// Each set of notes lives in a folder: a meeting's recording folder, or, before the meeting, the waiting folder of its
// calendar event (`MyNotes.prepFolder`). A change takes `app.myNotesLock` (api.py `_MY_NOTES_LOCK`) before the undo
// snapshot and the notes' own flock. The text in a pasted image is read on a thread of its own, never on the request's.
import Foundation
import PalaverCore
import PalaverDomain

/// The calendar keys already looked up (api.py `_KNOWN_EVENTS`), compared by code points.
public final class KnownEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var keys = Set<ScalarKey>()

    public init() {}

    func contains(_ key: String) -> Bool { lock.withLock { keys.contains(ScalarKey(key)) } }
    func insert(_ key: String) { _ = lock.withLock { keys.insert(ScalarKey(key)) } }
}

public enum MyNotesAPI {
    /// server.py `_MY_NOTES`: the document, its images (one, or its deletion), clearing it.
    static let MY_NOTES = #"/api/(meetings|upcoming)/([^/]+)/my-notes(?:/(images|clear)(?:/([^/]+)(/delete)?)?)?"#

    public static func myNotesFolder(_ app: ServerApp, id: String) throws -> URL {
        try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id).folder
    }

    /// `prep_notes_folder`: the waiting folder of an upcoming meeting's notes; only for events still to come in the
    /// calendar (else NotFound).
    public static func prepNotesFolder(_ app: ServerApp, key: String, now: PyDateTime? = nil) throws -> URL {
        if !app.knownEvents.contains(key) {
            _ = try UpcomingAPI.event(app, key, now)
            app.knownEvents.insert(key)
        }
        return MyNotes.prepFolder(key, stores: app.stores)
    }

    /// `adopt_prepared_notes`: while a meeting is recorded, the notes written for its calendar event beforehand join
    /// it, so they are there to go through during the call (once it is processed, `Prep.apply` does the same).
    @discardableResult
    public static func adoptPreparedNotes(_ app: ServerApp, id: String, now: PyDateTime? = nil) throws -> Bool {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        guard let provider = app.calendar, MyNotes.hasPrepared(stores: app.stores), MeetingsAPI.state(paths) == "recording" else {
            return false
        }
        let start = try MeetingsAPI.start(paths, try MeetingsAPI.meta(paths))
        if !start.truthy { return false }
        guard case .string(let text) = start else {
            throw PageError("fromisoformat: argument must be str")
        }
        let startAt = try PyDateTime.parse(text)
        let now = now ?? UpcomingAPI.now()
        let event: CalendarEvent?
        do {
            let events = try provider(try startAt.adding(seconds: -CalendarEvents.SEARCH_MARGIN).date,
                                      try now.adding(seconds: CalendarEvents.SEARCH_MARGIN).date)
            if startAt.offset == nil { return false }  // `max(now, start_at)`: naive and aware don't compare (TypeError)
            event = CalendarEvents.match(events, startAt, startAt > now ? startAt : now)
        } catch {  // no calendar is no reason to fail the notes
            return false
        }
        guard let event, !event.key.isEmpty else { return false }
        return try app.myNotesLock.withLock { try MyNotes.adopt(MyNotes.prepFolder(event.key, stores: app.stores), paths.folder) }
    }

    public static func getMyNotes(_ folder: URL) -> JSONValue { MyNotes.document(folder) }

    /// `save_my_notes`: save on the revision the editor read; `ConflictDocument` (409 with the notes as they are) when
    /// they changed since.
    public static func saveMyNotes(_ folder: URL, body: JSONValue) throws -> JSONValue {
        if !(try contains(body, "paragraphs")) { throw BadRequest("no paragraphs") }
        guard case .string(let revision)? = try PyBody.get(body, "revision") else {
            throw BadRequest("no revision: a save says which notes it was based on")
        }
        let saved: JSONValue
        do {
            saved = try python { try MyNotes.save(folder, paragraphs: body["paragraphs"] ?? .null, base: revision) }
        } catch let e as MyNotesConflict {  // changed elsewhere: the editor merges
            throw ConflictDocument(e.description, document: e.document)
        }
        return .object([("saved", .int(saved["paragraphs"]?.arrayValue?.count ?? 0)), ("revision", saved["revision"] ?? .null)])
    }

    /// `add_my_notes_image`: a pasted or dropped image (base64 in JSON: the server takes JSON only). Stored in the
    /// folder, never uploaded anywhere; its text is read on this Mac in the background.
    public static func addMyNotesImage(_ app: ServerApp, _ folder: URL, body: JSONValue) throws -> JSONValue {
        guard let data = base64Strict(Py.str(try PyBody.required(body, "data"))) else { throw BadRequest("the image is not base64") }
        let name = try app.myNotesLock.withLock { try python { try MyNotes.addImage(folder, data: data) } }
        _ = MyNotes.readInBackground(folder, name, recognize: app.recognizeText)
        return .object([("name", .string(name))])
    }

    /// `my_notes_image`: the image's bytes and type; NotFound for anything that is no image of these notes.
    public static func myNotesImage(_ folder: URL, name: String) throws -> (Data, String) {
        let url: URL
        do {
            url = try MyNotes.imagePath(folder, name)
        } catch is MyNotesError {
            throw NotFound(name)
        }
        return (try Data(contentsOf: url), MyNotes.contentType(name))
    }

    /// `delete_my_notes_image`: an image out of the notes, undoably. Its files come back as they were; its paragraph
    /// is put back into the notes as they are then (`MyNotes.putBack`), so what was typed since stays.
    public static func deleteMyNotesImage(_ app: ServerApp, _ folder: URL, name: String) throws -> JSONValue {
        let token: String = try app.myNotesLock.withLock {
            let files: [URL]
            do {
                files = try MyNotes.imageFiles(folder, name)
            } catch is MyNotesError {
                throw NotFound(name)
            }
            return try ChangesAPI.undoToken(app, label: "my-notes image", stores: files) { token in
                let (removed, before) = try python { try MyNotes.removeImage(folder, name) }
                try Undo.note(app.outputDir, token, PyDict([("folder", .string(folder.path)),
                                                            ("paragraphs", .array(removed.map { [$0.json] } ?? [])),
                                                            ("after", before?.json ?? .null)]))
            }
        }
        return MyNotes.document(folder).adding("undo", .string(token))
    }

    /// `clear_my_notes`: no notes any more, undoably (the paragraphs come back beside what was written since).
    public static func clearMyNotes(_ app: ServerApp, _ folder: URL) throws -> JSONValue {
        let token: String = try app.myNotesLock.withLock {
            let paragraphs = MyNotes.load(folder)
            let images = MyNotes.files(folder).filter { !Py.same($0.lastPathComponent, MyNotes.fileName) }
            return try ChangesAPI.undoToken(app, label: "my-notes clear", stores: images) { token in
                try MyNotes.clear(folder)
                try Undo.note(app.outputDir, token, PyDict([("folder", .string(folder.path)),
                                                            ("paragraphs", .array(paragraphs.map(\.json)))]))
            }
        }
        return MyNotes.document(folder).adding("undo", .string(token))
    }

    // MARK: - Python's ways

    /// `key in body`: a dict's keys, a list's items, a text's substrings; TypeError for the rest.
    static func contains(_ body: JSONValue, _ key: String) throws -> Bool {
        switch body {
        case .object: return body[key] != nil
        case .array(let items): return items.contains { $0.stringValue.map { Py.same($0, key) } ?? false }
        case .string(let s):
            let hay = Array(s.unicodeScalars), needle = Array(key.unicodeScalars)
            return hay.count >= needle.count && (0...(hay.count - needle.count)).contains { Array(hay[$0..<$0 + needle.count]) == needle }
        default: throw PyBody.TypeError(description: "argument of type '\(PyBody.typeName(body))' is not iterable")
        }
    }

    /// my_notes.py's ValueError is the server's 400 (`bad request: …`).
    static func python<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MyNotesError.invalid(let message) {
            throw BadRequest(message)
        }
    }

    /// `base64.b64decode(text, validate=True)`: only the alphabet, then exactly the padding the data needs (none for a
    /// whole number of quads); nil where Python raises (`binascii.Error`, or a text that is no ASCII).
    /// Decoded over the text's UTF-8 bytes in place: a 35 MiB paste needs its output and nothing more.
    static func base64Strict(_ text: String) -> Data? {
        var text = text
        return text.withUTF8 { bytes -> Data? in
            func value(_ b: UInt8) -> UInt32? {
                switch b {
                case 0x41...0x5A: return UInt32(b - 0x41)
                case 0x61...0x7A: return UInt32(b - 0x61 + 26)
                case 0x30...0x39: return UInt32(b - 0x30 + 52)
                case 0x2B: return 62
                case 0x2F: return 63
                default: return nil  // also every byte of a non-ASCII character
                }
            }
            let end = bytes.firstIndex(of: UInt8(ascii: "=")) ?? bytes.count
            guard bytes[end...].allSatisfy({ $0 == UInt8(ascii: "=") }) else { return nil }
            let rest = end % 4
            guard rest != 1, bytes.count - end == (4 - rest) % 4 else { return nil }
            var out = Data(count: end / 4 * 3 + (rest == 0 ? 0 : rest - 1))
            let ok = out.withUnsafeMutableBytes { raw -> Bool in
                let o = raw.bindMemory(to: UInt8.self)
                var i = 0, j = 0
                while i + 4 <= end {
                    guard let a = value(bytes[i]), let b = value(bytes[i + 1]), let c = value(bytes[i + 2]),
                          let d = value(bytes[i + 3]) else { return false }
                    let n = a << 18 | b << 12 | c << 6 | d
                    o[j] = UInt8(n >> 16 & 0xFF); o[j + 1] = UInt8(n >> 8 & 0xFF); o[j + 2] = UInt8(n & 0xFF)
                    i += 4; j += 3
                }
                if rest == 2 {
                    guard let a = value(bytes[i]), let b = value(bytes[i + 1]) else { return false }
                    o[j] = UInt8((a << 2 | b >> 4) & 0xFF)
                } else if rest == 3 {
                    guard let a = value(bytes[i]), let b = value(bytes[i + 1]), let c = value(bytes[i + 2]) else { return false }
                    let n = a << 12 | b << 6 | c
                    o[j] = UInt8(n >> 10 & 0xFF); o[j + 1] = UInt8(n >> 2 & 0xFF)
                }
                return true
            }
            return ok ? out : nil
        }
    }
}

extension Router {
    /// server.py's `_MY_NOTES` branches: a GET matches the path, a POST the target as sent; an upcoming meeting's key is
    /// unquoted, a meeting's id and an image's name are not.
    static func addMyNotesRoutes(_ r: Router, app: ServerApp) {
        /// `_notes_folder`: a meeting's, or an upcoming meeting's (prep).
        func folder(_ m: PyMatch) throws -> URL {
            if m.group(1) == "meetings" { return try MyNotesAPI.myNotesFolder(app, id: m.group(2)!) }
            return try MyNotesAPI.prepNotesFolder(app, key: PyURL.unquote(m.group(2)!))
        }
        r.get(MyNotesAPI.MY_NOTES) { _, m in
            if m.group(1) == "meetings" && m.group(3) == nil { try MyNotesAPI.adoptPreparedNotes(app, id: m.group(2)!) }
            let notes = try folder(m)
            if m.group(3) == "images", let name = m.group(4), m.group(5) == nil {
                let (data, type) = try MyNotesAPI.myNotesImage(notes, name: name)
                return .send(200, data, contentType: type)
            }
            if m.group(3) != nil { return .error(404, "not found") }
            return .json(MyNotesAPI.getMyNotes(notes))
        }
        r.post(MyNotesAPI.MY_NOTES) { req, m in
            let notes = try folder(m)
            let (what, name, delete) = (m.group(3), m.group(4), m.group(5))
            if what == nil { return .json(try MyNotesAPI.saveMyNotes(notes, body: req.json)) }
            if what == "images" && name == nil { return .json(try MyNotesAPI.addMyNotesImage(app, notes, body: req.json)) }
            if what == "images", let name, delete != nil { return .json(try MyNotesAPI.deleteMyNotesImage(app, notes, name: name)) }
            if what == "clear" && name == nil { return .json(try MyNotesAPI.clearMyNotes(app, notes)) }
            return .error(404, "not found")
        }
    }
}
