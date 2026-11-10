// Taking in a meeting a colleague sent (exchange.py:520-828, 853-864, 900-1200, issue #58; its audio is
// ExchangeAudio's): `readPackage` (`_consistent`), `findMatch`, `stage`, `place`, `importPackage`, `settle`,
// `decideVoices`, `fittingVoices`, `confirmedProjects`.
//
// The file is untrusted. `readPackage` takes nothing but the fixed layout (ExchangeZip), checks every JSON against its
// schema and every file against the manifest, all before anything is written. `stage` builds the meeting in a folder
// of its own under `<recordings>/.importing`; `place` moves it among the recordings in one rename. Entry names are
// never paths: only the fixed file names of a meeting are written, and the new folder's name is made from the start.
//
// What comes in is the colleague's word, not the user's: names are hints (stored like inferred names), voices wait in
// imported_voices.json until the user says yes (`decideVoices`), projects are worked out here again (`settle`).
import Darwin
import Foundation
import PalaverCore

/// A meeting here the import is the same meeting as (`exchange.Match`).
public struct ExchangeMatch: Equatable, Sendable {
    public let id: String
    /// "event" (the same calendar occurrence) | "overlap" (the same time, the same people)
    public let how: String
    /// The user's own recording, not an earlier import.
    public let own: Bool

    public init(_ id: String, _ how: String, _ own: Bool) { self.id = id; self.how = how; self.own = own }

    public static func == (a: Self, b: Self) -> Bool { Py.same(a.id, b.id) && a.how == b.how && a.own == b.own }
}

/// An exported meeting's zip, checked (`exchange.Package`): everything but the audio read and validated.
public struct ExchangePackage {
    public let url: URL
    public let manifest: JSONValue
    public let meta: JSONValue
    public let transcript: [JSONValue]
    public let turns: [JSONValue]
    public let speakers: [JSONValue]
    public let calendar: JSONValue?
    public let notes: JSONValue?
    /// label → {label, name, embedding}, in the zip's order.
    public var voices: PyDict<JSONValue>
    /// The entry names under audio/, sorted.
    public let audio: [String]
    /// The one folder everything is in, in a zip compressed again in Finder ("" otherwise).
    public let root: String

    public var sender: String { manifest["exported_by"]?.stringValue ?? "" }

    public func start() throws -> ExchangeTime { try JSONSchemaCheck.time(meta["start"]?.stringValue ?? "", where: "meta.json start") }
    public func end() throws -> ExchangeTime { try JSONSchemaCheck.time(meta["end"]?.stringValue ?? "", where: "meta.json end") }

    /// `float(meta["duration"])`: a number (the schema says so).
    var duration: Double { meta["duration"]?.doubleValue ?? 0 }

    /// The exporter's event, seen from here: the user, if invited, is "self".
    public func event(userName: String = "") throws -> CalendarEvent? {
        guard let c = calendar else { return nil }
        let me = Py.strip(userName).isEmpty ? "" : Py.casefold(CalendarEvents.personName(userName))
        let attendees = (c["attendees"]?.arrayValue ?? []).map { a -> Attendee in
            let raw = a["name"]?.stringValue ?? ""
            let name = CalendarEvents.personName(raw)
            return Attendee(name: name, email: a["email"]?.stringValue, organizer: a["organizer"]?.truthy ?? false,
                            response: a["response"]?.stringValue ?? "unknown",
                            isSelf: !me.isEmpty && Py.same(Py.casefold(name), me),
                            isRoom: (a["room"]?.truthy ?? false) || CalendarEvents.looksLikeRoom(raw))
        }
        let start = try JSONSchemaCheck.time(c["start"]?.stringValue ?? "", where: "calendar.json start")
        let end = try JSONSchemaCheck.time(c["end"]?.stringValue ?? "", where: "calendar.json end")
        return CalendarEvent(title: c["title"]?.stringValue ?? "", start: Exchange.pyTime(start), end: Exchange.pyTime(end),
                             attendees: attendees, source: ExchangeHints.IMPORTED, uid: c["uid"]?.stringValue ?? "",
                             series: c["series"]?.truthy ?? false)
    }
}

/// A meeting imported (`exchange.Imported`).
public struct ExchangeImported {
    public let id: String
    public let sender: String
    /// The meeting it was imported beside, as a separate meeting.
    public let matched: ExchangeMatch?
    /// [{label, name}] waiting for the user's yes.
    public let voices: [JSONValue]
    /// label → name hinted.
    public let names: PyDict<String>
    /// What was left out, in words for the user.
    public let warnings: [String]
}

/// A meeting built from a file, beside the recordings, not yet among them (`exchange.Staged`).
public final class ExchangeStaged {
    public internal(set) var package: ExchangePackage
    public let match: ExchangeMatch?
    public let staging: URL
    public internal(set) var names = PyDict<String>()
    public internal(set) var warnings: [String] = []

    init(_ package: ExchangePackage, _ match: ExchangeMatch?, _ staging: URL) {
        self.package = package; self.match = match; self.staging = staging
    }

    public var folder: URL { staging.appendingPathComponent("meeting", isDirectory: true) }

    /// The staging folder removed, and `.importing` too once it is empty; errors ignored.
    public func discard() {
        try? FileManager.default.removeItem(at: staging)
        _ = rmdir(staging.deletingLastPathComponent().path)
    }
}

extension Exchange {
    public typealias Match = ExchangeMatch
    /// What decoding an import's audio leaves free at least.
    public static let MIN_FREE_BYTES = 2 * 1024 * 1024 * 1024
    /// `_REQUIRED`: the files an exported meeting can't do without.
    static let REQUIRED = ["meeting/meta.json", "meeting/transcript.json", "meeting/turns.json", "meeting/speakers.json"]

    /// The same meeting is here already; the user decides (keep theirs, or import as a separate meeting).
    public struct Collision: Error, CustomStringConvertible {
        public let match: ExchangeMatch
        public let sender: String
        public var description: String { "\(match.id) is the same meeting" }
    }

    /// An aware time of the file as a calendar time.
    static func pyTime(_ t: ExchangeTime) -> PyDateTime { PyDateTime(micros: t.epochMicroseconds, offset: t.utcOffset) }

    // MARK: - reading a file

    /// `read_package`: open and check an exported meeting's zip (all but the audio's content). Throws
    /// `ExchangeRejected`.
    public static func readPackage(_ url: URL, caps: ExchangeZip.Caps = .standard) throws -> ExchangePackage {
        let zip = try ExchangeZip.open(url, caps: caps)
        var (root, entries) = try ExchangeZip.entries(zip, caps: caps)
        guard let manifestEntry = entries.removeValue(forKey: "manifest.json") else { throw ExchangeRejected(NOT_EXPORTED) }
        if manifestEntry.size > UInt64(caps.maxJSONBytes) { throw ExchangeRejected("The manifest is too large.") }
        let raw: Data
        do {
            raw = try zip.data(manifestEntry, limit: caps.maxJSONBytes)
        } catch ZipError.overLimit {
            throw ExchangeRejected("The manifest is too large.")
        } catch let error as ZipError {
            throw ExchangeRejected("The manifest is damaged (\(error)).")
        }
        let manifest = try JSONSchemaCheck.json(raw, where: "manifest.json")
        if case .object = manifest, let format = manifest["format"] {
            // `format != FORMAT and isinstance(format, int)`: True is 1; False is an int that is not 1.
            var shown: String?, newer = false
            if case .int(let n) = format, n != FORMAT { shown = String(n); newer = n > FORMAT }
            if case .bool(false) = format { shown = "False" }
            if let shown {
                throw ExchangeRejected("This file has format \(shown); this Palaver reads format \(FORMAT)."
                                       + (newer ? " Update Palaver to import it." : ""))
            }
        }
        try JSONSchemaCheck.check(manifest, schema: JSONSchemaCheck.MANIFEST, where: "manifest.json")
        _ = try JSONSchemaCheck.time(manifest["exported_at"]?.stringValue ?? "", where: "manifest.json exported_at")
        let listed = PyDict<JSONValue>(manifest["files"] ?? .null) ?? PyDict()
        let listedKeys = Set(listed.keys.map(ScalarKey.init)), entryKeys = Set(entries.keys.map(ScalarKey.init))
        if listedKeys != entryKeys {
            let missing = Py.stableSorted(listed.keys.filter { !entryKeys.contains(ScalarKey($0)) }, by: Py.less)
            let extra = Py.stableSorted(entries.keys.filter { !listedKeys.contains(ScalarKey($0)) }, by: Py.less)
            throw ExchangeRejected("The file does not match its manifest: "
                                   + (missing.first.map { "\(ExchangeZip.repr($0)) is missing" } ?? "\(ExchangeZip.repr(extra[0])) is not listed")
                                   + ".")
        }
        if let lacking = Py.stableSorted(REQUIRED.filter { !entryKeys.contains(ScalarKey($0)) }, by: Py.less).first {
            throw ExchangeRejected("The file lacks \(ExchangeZip.repr(lacking)).")
        }
        var docs = PyDict<JSONValue>()
        var voices = PyDict<JSONValue>()
        for (name, entry) in entries {
            if name.unicodeScalars.starts(with: "audio/".unicodeScalars) { continue }
            let data = try ExchangeZip.readEntry(zip, name, entry, expected: listed[name] ?? .null, caps: caps)
            let doc = try JSONSchemaCheck.json(data, where: name)
            if name.unicodeScalars.starts(with: "voices/".unicodeScalars) {
                try JSONSchemaCheck.check(doc, schema: JSONSchemaCheck.VOICE, where: name)
                let label = doc["label"]?.stringValue ?? ""
                if !Py.same("voices/\(label).json", name) { throw ExchangeRejected("\(ExchangeZip.repr(name)) is the voice of \(label).") }
                voices[label] = doc
            } else {
                guard let schema = JSONSchemaCheck.SCHEMAS[name] else { throw ExchangeRejected("The zip has \(ExchangeZip.repr(name)), which is not part of an exported meeting.") }
                try JSONSchemaCheck.check(doc, schema: schema, where: name)
                docs[name] = doc
            }
        }
        let package = ExchangePackage(
            url: url, manifest: manifest, meta: docs["meeting/meta.json"] ?? .object([]),
            transcript: docs["meeting/transcript.json"]?.arrayValue ?? [], turns: docs["meeting/turns.json"]?.arrayValue ?? [],
            speakers: docs["meeting/speakers.json"]?.arrayValue ?? [], calendar: docs["meeting/calendar.json"],
            notes: docs["meeting/notes.json"], voices: voices,
            audio: Py.stableSorted(entries.keys.filter { $0.unicodeScalars.starts(with: "audio/".unicodeScalars) }, by: Py.less),
            root: root)
        try consistent(package)
        return package
    }

    /// `_consistent`: what a schema can't say. Times that fit the meeting, one entry per label, voices only of named
    /// people, one audio file per track.
    static func consistent(_ p: ExchangePackage) throws {
        let start = try p.start(), end = try p.end()
        if end < start || end.epochMicroseconds - start.epochMicroseconds > Int64(JSONSchemaCheck.MAX_SECONDS) * 1_000_000 {
            throw ExchangeRejected("meta.json: the meeting ends before it starts, or lasts too long.")
        }
        let limit = p.duration + 60
        for (what, items) in [("transcript.json", p.transcript), ("turns.json", p.turns)] {
            for (i, x) in items.enumerated() {
                let s = x["start"]?.doubleValue ?? 0, e = x["end"]?.doubleValue ?? 0
                if !(s <= e && e <= limit) { throw ExchangeRejected("\(what)[\(i)] is not within the meeting.") }
            }
        }
        if let c = p.calendar {
            _ = try JSONSchemaCheck.time(c["start"]?.stringValue ?? "", where: "calendar.json start")
            _ = try JSONSchemaCheck.time(c["end"]?.stringValue ?? "", where: "calendar.json end")
        }
        let labels = p.speakers.map { $0["label"]?.stringValue ?? "" }
        if Set(labels.map(ScalarKey.init)).count != labels.count { throw ExchangeRejected("speakers.json names a label twice.") }
        var named = PyDict<String>()
        for s in p.speakers {
            if let name = s["name"]?.stringValue, !name.isEmpty { named[s["label"]?.stringValue ?? ""] = name }
        }
        for (label, voice) in p.voices {
            guard let name = named[label], let given = voice["name"]?.stringValue, Py.same(name, given) else {
                throw ExchangeRejected("voices/\(label).json is not the voice of a person named in speakers.json.")
            }
        }
        let tracks = p.audio.map { name -> String in
            let file = ExchangeZip.parts(name).dropFirst().first ?? ""
            return String(String.UnicodeScalarView(file.unicodeScalars.prefix { $0 != "." }))
        }
        if Set(tracks.map(ScalarKey.init)).count != tracks.count { throw ExchangeRejected("The file has a track twice.") }
    }

    // MARK: - matching

    /// `datetime` arithmetic between an aware time and one that may be naive: Python raises TypeError.
    private static func aware(_ t: PyDateTime) throws -> PyDateTime {
        guard t.offset != nil else {
            throw ExchangeExportError(.type, "can't compare offset-naive and offset-aware datetimes")
        }
        return t
    }

    /// `_span`: a recording's start and end, nil when meta.json has no readable start.
    static func span(_ paths: RecordingPaths) throws -> (PyDateTime, PyDateTime)? {
        let meta = read(paths.meta, .object([]))
        guard case .object = meta, case .string(let text)? = meta["start_time"], let start = try? PyDateTime.parse(text) else {
            return nil
        }
        let value = meta["duration_seconds"] ?? .null
        let duration: Double
        if !value.truthy {
            duration = 0
        } else if let d = VoiceMath.pyFloat(value) {
            duration = d
        } else if case .string = value {
            throw ExchangeExportError(.value, "could not convert string to float")
        } else {
            throw ExchangeExportError(.type, "float() argument must be a string or a real number")
        }
        return (start, try end(start, duration))
    }

    /// `_people`: who was invited, by email where there is one, else by name (rooms aside).
    static func people(_ event: CalendarEvent?) -> Set<ScalarKey> {
        Set((event?.attendees ?? []).filter { !$0.isRoom }.map { a in
            ScalarKey(Py.strip(Py.casefold((a.email?.isEmpty == false ? a.email! : a.name))))
        })
    }

    /// The recording folders of `outputDir` (folders, links followed), in code-point order.
    static func recordingFolders(_ outputDir: URL) -> [String] {
        Py.stableSorted(names(in: outputDir.path).filter {
            RecordingPaths.isRecordingFolderName($0) && Undo.isDir(outputDir.path + "/" + $0)
        }, by: Py.less)
    }

    /// `find_match`: the meeting here that is the one in the file: the same calendar occurrence (iCal UID and start);
    /// else one that overlaps it by more than half, with someone invited to both. nil: a meeting of its own.
    public static func findMatch(_ outputDir: URL, _ package: ExchangePackage) throws -> ExchangeMatch? {
        let theirs = try package.event()
        let span = (pyTime(try package.start()), pyTime(try package.end()))
        var byOverlap: [(Double, String)] = []
        guard Undo.isDir(outputDir.path) else { return nil }
        for name in recordingFolders(outputDir) {
            let paths = RecordingPaths(outputDir.appendingPathComponent(name, isDirectory: true))
            let mine = CalendarEvents.load(paths)
            let own = !Undo.exists(paths.imported.path)
            if let theirs, let mine, !theirs.uid.isEmpty, !mine.uid.isEmpty, Py.same(mine.seriesId, theirs.seriesId),
               abs(try aware(mine.start).seconds(since: theirs.start)) < 60 {
                return ExchangeMatch(name, "event", own)
            }
            guard let here = try self.span(paths), !people(theirs).isDisjoint(with: people(mine)) else { continue }
            let (a, b) = (try aware(here.0), try aware(here.1))
            let overlap = min(b, span.1).seconds(since: max(a, span.0))
            let shorter = min(b.seconds(since: a), span.1.seconds(since: span.0))
            if shorter > 0 && overlap > 0.5 * shorter { byOverlap.append((overlap, name)) }
        }
        guard let best = byOverlap.max(by: { $0.0 != $1.0 ? $0.0 < $1.0 : Py.less($0.1, $1.1) })?.1 else { return nil }
        let there = RecordingPaths(outputDir.appendingPathComponent(best, isDirectory: true))
        return ExchangeMatch(best, "overlap", !Undo.exists(there.imported.path))
    }

    // MARK: - import

    /// `_new_folder`: the start on this Mac's clock (`%Y-%m-%dT%H-%M-%S`), `-2`, `-3` … when that is taken.
    static func newFolder(_ outputDir: URL, _ start: ExchangeTime, timeZone: TimeZone) -> String {
        var seconds = start.epochMicroseconds / 1_000_000
        if start.epochMicroseconds % 1_000_000 < 0 { seconds -= 1 }  // floor
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                        from: Date(timeIntervalSince1970: Double(seconds)))
        let base = String(format: "%04d-%02d-%02dT%02d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0,
                          c.minute ?? 0, c.second ?? 0)
        var name = base, n = 2
        while Undo.exists(outputDir.path + "/" + name) {
            name = "\(base)-\(n)"
            n += 1
        }
        return name
    }

    /// `_free_bytes`: what the volume holding `url` has free.
    public static func freeBytes(_ url: URL) throws -> Int {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Int(fs.f_bavail) * Int(fs.f_bsize)
    }

    /// `_write_audio`: the audio's tracks decoded into the meeting's system track (`ExchangeAudio.writeSystemTrack`).
    static func writeAudio(_ staged: ExchangeStaged, freeBytes: (URL) throws -> Int) throws {
        try ExchangeAudio.writeSystemTrack(package: staged.package, staging: staged.staging, folder: staged.folder,
                                           freeBytes: freeBytes)
    }

    /// `_event_here`: the event to link: the same occurrence in this Mac's calendar, when it can be asked; else the
    /// exporter's, seen from here.
    static func eventHere(_ package: ExchangePackage, userName: String, calendar: CalendarProvider?) throws -> (CalendarEvent, Link)? {
        guard let theirs = try package.event(userName: userName) else { return nil }
        let link = { (title: String) in Link("event", title, ExchangeHints.IMPORTED, nil, "the event of \(package.sender)'s recording") }
        if let calendar, !theirs.uid.isEmpty {
            // No calendar is no reason to fail the import.
            let found = (try? calendar(try theirs.start.adding(seconds: -300).date, try theirs.end.adding(seconds: 300).date)) ?? []
            for event in found where !event.uid.isEmpty && Py.same(event.seriesId, theirs.seriesId) {
                if abs(try aware(event.start).seconds(since: theirs.start)) < 60 { return (event, link(event.title)) }
            }
        }
        return (theirs, link(theirs.title))
    }

    /// `_title_of_their_own`: the exporter's title, when it is neither the event's nor the notes': one they gave it.
    static func titleOfTheirOwn(_ package: ExchangePackage) -> String? {
        let title = Py.strip(package.meta["title"]?.stringValue ?? "")
        let known = [package.calendar?["title"], package.notes?["title"]].compactMap { $0?.stringValue }
        return !title.isEmpty && !known.contains(where: { Py.same($0, title) }) ? title : nil
    }

    /// `stage`: build the meeting of `package` in `<outputDir>/.importing`, the slow part, before anything else is held.
    /// The same meeting here already throws `Collision` unless `separate` (then it goes beside it, linked to the same
    /// event). `calendar`: this Mac's calendar.
    public static func stage(_ outputDir: URL, _ package: ExchangePackage, userName: String, separate: Bool = false,
                             calendar: CalendarProvider? = nil, stores: StorePaths = .current(), now: Date = Date(),
                             timeZone: TimeZone = .current,
                             freeBytes: (URL) throws -> Int = Exchange.freeBytes) throws -> ExchangeStaged {
        let match = try findMatch(outputDir, package)
        if let match, !separate { throw Collision(match: match, sender: package.sender) }
        let root = outputDir.appendingPathComponent(STAGING, isDirectory: true)
        try Undo.makedirs(root.path)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()  // uuid4().hex
        let staged = ExchangeStaged(package, match, root.appendingPathComponent(token, isDirectory: true))
        let (kept, leftOut) = try fittingVoices(outputDir, package.voices, bank: VoiceBank(directory: stores.voices))
        staged.package.voices = kept
        if leftOut > 0 {
            staged.warnings.append("\(leftOut) voice\(leftOut > 1 ? "s were" : " was") left out: they were made "
                                   + "by another voice model than this Mac's.")
        }
        guard mkdir(staged.staging.path, 0o777) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            guard mkdir(staged.folder.path, 0o777) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try writeAudio(staged, freeBytes: freeBytes)
            staged.names = try writeMeeting(RecordingPaths(staged.folder), staged.package, userName: userName,
                                            calendar: calendar, beside: match, outputDir: outputDir, stores: stores,
                                            now: now, timeZone: timeZone)
        } catch {
            staged.discard()
            throw error
        }
        return staged
    }

    /// `place`: move a staged meeting among the recordings in one rename (the list sees all of it or nothing);
    /// `after(id)` then works out what follows here (projects, names). If that fails, the meeting goes to the trash.
    public static func place(_ outputDir: URL, _ staged: ExchangeStaged, after: ((String) throws -> Void)? = nil,
                             timeZone: TimeZone = .current) throws -> ExchangeImported {
        let package = staged.package
        let start = try package.start()
        var meetingId = newFolder(outputDir, start, timeZone: timeZone)
        while rename(staged.folder.path, outputDir.path + "/" + meetingId) != 0 {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            if !Undo.exists(outputDir.path + "/" + meetingId) { throw failure }
            meetingId = newFolder(outputDir, start, timeZone: timeZone)
        }
        let paths = RecordingPaths(outputDir.appendingPathComponent(meetingId, isDirectory: true))
        if let after {
            do {
                try after(meetingId)
            } catch {
                // Never a meeting among the recordings that what follows chokes on.
                try Cutting.trash(paths)
                throw error
            }
        }
        guard let record = ExchangeHints.loadRecord(paths) else {
            throw ExchangeExportError(.type, "'NoneType' object has no attribute 'get'")
        }
        var voices: [JSONValue] = []
        for label in try items(record["voices_pending"] ?? .array([]), "voices_pending") {
            let key = label.stringValue ?? ""
            guard let voice = package.voices[key] else { throw ExchangeExportError(.key, MyNotes.pyRepr(label)) }
            voices.append(.object([("label", label), ("name", voice["name"] ?? .null)]))
        }
        return ExchangeImported(id: meetingId, sender: package.sender, matched: staged.match, voices: voices,
                                names: staged.names, warnings: staged.warnings)
    }

    /// `import_package`: `stage` and `place` in one; the meeting in `file` as a meeting of its own.
    @discardableResult
    public static func importPackage(_ outputDir: URL, _ file: URL, userName: String, separate: Bool = false,
                                     calendar: CalendarProvider? = nil, package: ExchangePackage? = nil,
                                     after: ((String) throws -> Void)? = nil, stores: StorePaths = .current(),
                                     now: Date = Date(), timeZone: TimeZone = .current,
                                     freeBytes: (URL) throws -> Int = Exchange.freeBytes) throws -> ExchangeImported {
        let staged = try stage(outputDir, try package ?? readPackage(file), userName: userName, separate: separate,
                               calendar: calendar, stores: stores, now: now, timeZone: timeZone, freeBytes: freeBytes)
        defer { staged.discard() }
        return try place(outputDir, staged, after: after, timeZone: timeZone)
    }

    /// `_write_meeting`: the meeting's files in `paths` (the staging folder); answers the names hinted.
    static func writeMeeting(_ paths: RecordingPaths, _ package: ExchangePackage, userName: String,
                             calendar: CalendarProvider?, beside: ExchangeMatch?, outputDir: URL, stores: StorePaths,
                             now: Date, timeZone: TimeZone) throws -> PyDict<String> {
        let start = pyTime(try package.start())
        let duration = package.duration
        try PythonJSON.write(.object([("start_time", .string(start.iso)), ("duration_seconds", .double(duration))]),
                             to: paths.meta, indent: 2, ensureAscii: true)
        if let language = package.meta["language"], language.truthy, let text = language.stringValue {
            try Data(text.utf8).write(to: paths.language)
        }
        try PythonJSON.write(.array(package.turns), to: paths.systemTurns, indent: nil, ensureAscii: true)
        // `Utterance(label, start, end, text).to_dict()`: the numbers as the file has them.
        let utterances: [JSONValue] = package.transcript.map { s in
            .object([("speaker", s["label"] ?? .null), ("start", s["start"] ?? .null), ("end", s["end"] ?? .null),
                     ("text", s["text"] ?? .null)])
        }
        try PythonJSON.write(.array(utterances), to: paths.transcriptJson, indent: 2, ensureAscii: true)
        var named = PyDict<JSONValue>()
        for s in package.speakers {
            guard let name = s["name"], name.truthy else { continue }
            let how = s["how"].flatMap { $0.truthy ? $0 : nil } ?? .string("hand")
            named[s["label"]?.stringValue ?? ""] = .object([("name", name), ("how", how)])
        }
        if !package.voices.isEmpty {  // apart, until the user says yes (decideVoices)
            try PythonJSON.write(.object(package.voices.map { ($0.key, $0.value["embedding"] ?? .null) }),
                                 to: paths.importedVoices, indent: nil, ensureAscii: true)
        }
        let file = String(String.UnicodeScalarView(package.url.lastPathComponent.unicodeScalars.prefix(200)))
        let record = JSONValue.object([
            ("from", .string(package.sender)), ("format", package.manifest["format"] ?? .null),
            ("palaver_version", package.manifest["palaver_version"] ?? .null),
            ("exported_at", package.manifest["exported_at"] ?? .null),
            ("imported_at", .string(Py.isoNow(timespec: "seconds", now: now, timeZone: timeZone))),
            ("file", .string(file)), ("projects", .array(package.meta["projects"]?.arrayValue ?? [])),
            ("names", named.json), ("voices_pending", .strings(Py.stableSorted(package.voices.keys, by: Py.less))),
            ("beside", beside.map { .object([("meeting", .string($0.id)), ("how", .string($0.how))]) } ?? .null),
            ("title", .str(titleOfTheirOwn(package))),  // theirs, not the user's: under a title the user gives it
        ])
        try PythonJSON.write(record, to: paths.imported, indent: 2, ensureAscii: false)
        if package.meta["kept_on_this_mac"]?.truthy == true {  // the sender kept it on their Mac: so does this one, until lifted
            try LocalOnly.set(paths.folder, on: true, now: now, timeZone: timeZone)
        }
        // The names are hints: stored as inferred names (inference keeps them), confirmed by the user.
        let hinted = ExchangeHints.hints(paths)
        if !hinted.isEmpty {
            try StoreLock.meeting(paths) {
                try PythonJSON.write(hinted.json, to: paths.speakersInferred, indent: 2, ensureAscii: false)
            }
        }
        var linked: (CalendarEvent, Link)?
        if let beside {  // beside the user's own: the event as it is linked there
            let there = RecordingPaths(outputDir.appendingPathComponent(beside.id, isDirectory: true))
            if let event = CalendarEvents.load(there) {
                linked = (event, Link("event", event.title, ExchangeHints.IMPORTED, nil, "the event of your own recording"))
            }
        }
        if linked == nil { linked = try eventHere(package, userName: userName, calendar: calendar) }
        if let (event, link) = linked { try CalendarEvents.save(paths, event, link) }
        try Speakers.saveSpeakerNames(paths, PyDict(), learn: false, stores: stores)
        if let notes = package.notes {
            let lines = PythonJSON.read(paths.transcriptJson)?.arrayValue ?? []
            let final = try lines.map { try Utterance(json: $0) }
            var merged = PyDict<JSONValue>(notes) ?? PyDict()
            merged["transcript_hash"] = .string(Notes.transcriptHash(final))
            try NotesFile.save(paths, merged.json)
        }
        var out = PyDict<String>()
        for (label, hint) in named { out[label] = hint["name"]?.stringValue ?? "" }
        return out
    }

    // MARK: - what follows here

    /// `confirmed_projects`: the projects the user put the meeting in (not the rules' or the model's proposals), the
    /// exporter's hint for the importer. Names that are no text are left out.
    public static func confirmedProjects(_ meetingId: String, stores: StorePaths = .current()) -> [String] {
        let store = ProjectStore(path: stores.projects)
        let named = store.projects
        let names = store.ofMeeting(meetingId).compactMap { pid, how -> String? in
            guard named[pid] != nil, case .string(let by)? = how["by"], Py.same(by, "you") else { return nil }
            return named[pid]?["name"]?.stringValue
        }
        return Py.stableSorted(names, by: Py.less)
    }

    /// `settle`: what is worked out here for an imported meeting: its projects, by the rules, else the exporter's
    /// project of the same name here as a suggestion to confirm; voices the bank knows and the names that follow.
    public static func settle(_ outputDir: URL, _ meetingId: String, userName: String, stores: StorePaths = .current()) throws {
        let (_, added) = try ProjectRules.assignByRules(outputDir: outputDir, userName: userName, meetings: [meetingId],
                                                        stores: stores)
        if added.isEmpty {
            let record = ExchangeHints.loadRecord(RecordingPaths(outputDir.appendingPathComponent(meetingId, isDirectory: true)))
                ?? .object([])
            let store = ProjectStore(path: stores.projects)
            try store.locked {
                store.reload()
                let projects = record["projects"] ?? .null
                for name in projects.truthy ? try items(projects, "projects") : [] {
                    let text = pyStr(name)
                    if let pid = store.find(text),
                       try store.assign(meetingId, pid, by: "auto", why: "\(pyStr(record["from"] ?? .null)) filed it under \(text)",
                                        confidence: 0.6) {
                        break
                    }
                }
                try store.save()
            }
        }
        try People.refreshRecognition(outputDir: outputDir, userName: userName, stores: stores)
    }

    /// Python's `len(x)` of a JSON value; TypeError for a number, a bool or null.
    private static func length(_ v: JSONValue) throws -> Int {
        switch v {
        case .array(let a): return a.count
        case .object(let o): return o.count
        case .string(let s): return s.unicodeScalars.count
        default: throw ExchangeExportError(.type, "object has no len()")
        }
    }

    /// `_voice_size`: how many numbers a voice has here: the voice bank's, else a meeting's.
    static func voiceSize(_ outputDir: URL, _ bank: VoiceBank) throws -> Int? {
        let size = try bank.size()
        if (size ?? 0) != 0 || !Undo.isDir(outputDir.path) { return size }
        for name in recordingFolders(outputDir) {
            let vectors = read(RecordingPaths(outputDir.appendingPathComponent(name, isDirectory: true)).speakerEmbeddings, .object([]))
            guard case .object(let fields) = vectors else { continue }
            for (_, vector) in fields {
                if case .array(let a) = vector, !a.isEmpty { return a.count }
            }
        }
        return nil
    }

    /// `fitting_voices`: the voices comparable with the ones here (made by the same voice model: as many numbers), and
    /// how many were left out. With none here, those of the size most of them have (a tie: the first voice's size).
    public static func fittingVoices(_ outputDir: URL, _ voices: PyDict<JSONValue>, bank: VoiceBank) throws
        -> (PyDict<JSONValue>, Int) {
        func count(_ v: JSONValue) -> Int { v["embedding"]?.arrayValue?.count ?? 0 }
        var size = try voiceSize(outputDir, bank)
        if size == nil && !voices.isEmpty {
            let sizes = voices.values.map(count)
            var best: (size: Int, n: Int)?
            for s in sizes where best.map({ sizes.filter { $0 == s }.count > $0.n }) ?? true {
                best = (s, sizes.filter { $0 == s }.count)
            }
            size = best?.size
        }
        let kept = PyDict(voices.filter { count($0.value) == size }.map { ($0.key, $0.value) })
        return (kept, voices.count - kept.count)
    }

    /// `decide_voices`: the user's answer about the voices that came with an import. Yes: they join the meeting's own
    /// voices, and the names they came with count as given by the user here, which teaches the voice bank (as naming a
    /// speaker by hand does), then voices are recognized everywhere again; a name the user said a voice is not is
    /// skipped, voice and all. No: they are deleted. Answers the names whose voices were learned.
    @discardableResult
    public static func decideVoices(_ paths: RecordingPaths, add: Bool, userName: String = "", bank: VoiceBank? = nil,
                                    stores: StorePaths = .current()) throws -> [String] {
        guard let stored = ExchangeHints.loadRecord(paths), stored.truthy, let waiting = stored["voices_pending"],
              waiting.truthy else { return [] }
        func isPending(_ label: String) throws -> Bool {  // `label in record["voices_pending"]`
            switch waiting {
            case .array(let a): return a.contains { $0.stringValue.map { Py.same($0, label) } ?? false }
            case .object(let o): return o.contains { Py.same($0.0, label) }
            case .string(let s):
                let hay = Array(s.unicodeScalars), needle = Array(label.unicodeScalars)
                return needle.isEmpty || (0...max(-1, hay.count - needle.count)).contains { Array(hay[$0..<$0 + needle.count]) == needle }
            default: throw ExchangeExportError(.type, "argument is not iterable")
            }
        }
        let file = read(paths.importedVoices, .object([]))
        let voices = file.truthy ? file : .object([])
        guard case .object(let fields) = voices else { throw ExchangeExportError(.type, "imported_voices.json is not an object") }
        var pending = PyDict<JSONValue>()
        for (label, vector) in fields {
            if try isPending(label) { pending[label] = vector }
        }
        var learned: [String] = []
        let bank = bank ?? VoiceBank(directory: stores.voices)
        if add {
            var names = try Speakers.loadSpeakerNames(paths)
            let hinted = ExchangeHints.hints(paths)
            let rejected = Speakers.loadRejectedNames(paths)
            let size = try voiceSize(paths.folder.deletingLastPathComponent(), bank)  // the bank may have changed since
            var taken = PyDict<JSONValue>()
            for (label, vector) in Py.stableSorted(Array(pending), by: { Py.less($0.key, $1.key) }) {
                if let size, try length(vector) != size { continue }
                let given = names[label] ?? label
                let name: JSONValue? = !Py.same(given, label) ? .string(given) : hinted[label]?["name"]
                guard let name, name.truthy else { continue }
                guard case .string(let text) = name else { throw ExchangeExportError(.type, "a hinted name is not text") }
                let key = Py.casefold(text)
                if (rejected[label] ?? []).contains(where: { Py.same(Py.casefold($0), key) }) { continue }
                taken[label] = vector
                if Py.same(names[label] ?? label, label) { names[label] = text }
                learned.append(text)
            }
            if !taken.isEmpty {
                try StoreLock.meeting(paths) {
                    let own = read(paths.speakerEmbeddings, .object([]))
                    var merged = PyDict<JSONValue>()
                    if own.truthy {
                        guard let fields = PyDict<JSONValue>(own) else {
                            throw ExchangeExportError(.type, "speaker_embeddings.json is not an object")
                        }
                        merged = fields
                    }
                    for (label, vector) in taken { merged[label] = vector }
                    try PythonJSON.write(merged.json, to: paths.speakerEmbeddings, indent: nil, ensureAscii: true)
                }
            }
            try Speakers.saveSpeakerNames(paths, names, bank: bank, stores: stores)
        }
        try StoreLock.meeting(paths) {
            if unlink(paths.importedVoices.path) != 0 && errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var record = PyDict<JSONValue>(stored) ?? PyDict()
            record["voices_pending"] = .array([])
            record["voices"] = .string(add ? "added" : "declined")
            try PythonJSON.write(record.json, to: paths.imported, indent: 2, ensureAscii: false, via: "imported.json.tmp")
        }
        if add {
            try People.refreshRecognition(outputDir: paths.folder.deletingLastPathComponent(), bank: bank, userName: userName,
                                          stores: stores)
        }
        return learned
    }
}
