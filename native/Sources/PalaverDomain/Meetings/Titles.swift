// A meeting's title, decided in one place (titles.py): the one the user gave it (title.json), else the one a colleague
// gave the meeting they sent (imported.json), else its calendar event's, else the one the notes model wrote; without
// any, "Meeting at 12:04". title.json is a file of its own, written by nothing else, so a meeting can be renamed while
// it is still being recorded.
import Foundation
import PalaverCore

/// What Python raises as `ValueError`.
public struct TitleError: Error, CustomStringConvertible {
    public let description: String
}

public enum Titles {
    public static let maxLength = 200
    public static let YOU = "you", IMPORTED = "imported", CALENDAR = "calendar", NOTES = "notes"

    /// What the caller has read already (`known(nil)`: there is none), so nothing is read twice; `unread` reads it here.
    public enum Known<T> {
        case unread
        case known(T?)
    }

    /// A title as typed, on one line, at most `maxLength` characters; "" says: no title of the user's own.
    public static func clean(_ title: String) -> String {
        // The words are joined by single spaces, so only a cut can leave a space at the end.
        let one = Py.split(title).joined(separator: " ")
        return Py.strip(String(String.UnicodeScalarView(one.unicodeScalars.prefix(maxLength))))
    }

    /// `clean` of a JSON value: anything but text is "a title is text".
    public static func clean(_ title: JSONValue?) throws -> String {
        guard case .string(let s)? = title else { throw TitleError(description: "a title is text") }
        return clean(s)
    }

    /// The user's own title, or nil.
    public static func load(_ paths: RecordingPaths) -> String? {
        guard let title = PythonJSON.read(paths.title)?["title"]?.stringValue else { return nil }
        let t = Py.strip(title)
        return t.isEmpty ? nil : t
    }

    /// Keep the user's title; "" removes it.
    public static func save(_ paths: RecordingPaths, _ title: String) throws {
        if title.isEmpty {
            if unlink(paths.title.path) != 0 && errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return
        }
        try PythonJSON.write(.object([("title", .string(title))]), to: paths.title, indent: nil, ensureAscii: false,
                             via: paths.title.lastPathComponent + ".tmp")
    }

    /// The title the sender of an imported meeting gave it, or nil.
    public static func imported(_ paths: RecordingPaths) -> String? {
        guard let title = PythonJSON.read(paths.imported)?["title"]?.stringValue else { return nil }
        let t = clean(title)
        return t.isEmpty ? nil : t
    }

    /// The title and where it came from ("you", "imported", "calendar", "notes"), or (nil, nil). `event` and
    /// `meetingNotes`: what the caller read already.
    public static func resolve(_ paths: RecordingPaths, event: Known<CalendarEvent> = .unread,
                               meetingNotes: Known<JSONValue> = .unread,
                               stores: StorePaths = .current()) -> (title: String?, source: String?) {
        if let own = load(paths) { return (own, YOU) }
        if let theirs = imported(paths) { return (theirs, IMPORTED) }
        let found: CalendarEvent?
        if case .known(let e) = event { found = e } else { found = CalendarEvents.load(paths) }
        if let found, !found.title.isEmpty { return (found.title, CALENDAR) }
        let notes: JSONValue?
        if case .known(let n) = meetingNotes { notes = n } else { notes = NotesFile.load(paths) }
        let written = Glossary.current(stores: stores).apply(notes?["title"]?.stringValue ?? "")
        return written.isEmpty ? (nil, nil) : (written, NOTES)
    }

    /// What a meeting without any title is called: "Meeting at 12:04" (on this Mac's clock).
    public static func fallback(_ start: String?, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        guard let start, !start.isEmpty, let when = try? PyDateTime.parse(start) else { return "Meeting" }
        let minutes: Int
        if when.offset == nil {
            // A time without a zone is on this Mac's clock already: `astimezone()` keeps it.
            let day: Int64 = 86_400 * 1_000_000
            minutes = Int(((when.micros % day) + day) % day / 60_000_000)
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let c = calendar.dateComponents([.hour, .minute], from: when.date)
            minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
        return String(format: "Meeting at %02d:%02d", minutes / 60, minutes % 60)
    }
}
