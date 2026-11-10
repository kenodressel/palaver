// A meeting sent to a colleague as one zip (exchange.py:1-132, 283-400, 416-519, issue #58; its audio is encoded by
// ExchangeAudio): `fileName`, `exportMeeting` (`_lanes`, `_notes`, `_calendar`), `sweep` and `freeName`.
//
// The export is written from the exporter's side but not in it: their microphone becomes a lane like any other, named
// after them. Only the fixed layout goes in (manifest.json, meeting/*.json, voices/<label>.json); never their own notes
// (#44), the coach, the review, search indexes or undo data, nor items of the notes taken from their own notes.
// Every JSON is `json.dumps(value, ensure_ascii=False, indent=1)` (exchange.py:292) and deflated; the manifest lists
// each file's sha256 and size. The zip is written into a `.palaver-export-*` folder beside the destination and renamed
// into place, so a half-written file is never seen.
import CryptoKit
import Darwin
import Foundation
import PalaverCore

/// What Python's export raises where it does not guard (KeyError, ValueError; TypeError and AttributeError as `type`,
/// OverflowError): a meeting whose files are not what the export reads.
public struct ExchangeExportError: Error, CustomStringConvertible {
    public enum Kind: Sendable { case key, value, type, overflow }
    public let kind: Kind
    public let description: String
    public init(_ kind: Kind, _ description: String) { self.kind = kind; self.description = description }
}

public enum Exchange {
    public static let FORMAT = 1
    public static let SUFFIX = ".zip"
    public static let NOT_EXPORTED = ExchangeZip.NOT_EXPORTED
    /// Beside the recordings: where an import is built before it moves in.
    public static let STAGING = ".importing"
    /// The folder beside an export the zip is written in (`tempfile.TemporaryDirectory(prefix=)`).
    public static let EXPORT_PREFIX = ".palaver-export-"
    /// Notes keys that travel; anything else (hashes of the exporter's files) stays home.
    public static let NOTES_KEYS = ["title", "summary", "sections", "next_steps", "decisions", "speaker_names"]
    static let LABEL = try! PyRegex(#"SPEAKER_\d{1,3}"#)
    static let ANY_LABEL = try! PyRegex(#"SPEAKER_\d+"#)

    /// The file can't be imported; the message says why, in words for the user.
    public typealias Rejected = ExchangeRejected

    /// The meeting is marked "Keep on this Mac": the user is asked before it leaves. The message is the folder's name.
    public struct KeptOnThisMac: Error, CustomStringConvertible {
        public let description: String
    }

    /// Only a finished, transcribed meeting can be exported.
    public struct NotReady: Error, CustomStringConvertible {
        public let description = "Only a finished, transcribed meeting can be exported."
    }

    /// `palaver.__version__`: the bundle's or the checkout's version (AppLocation).
    public static let palaverVersion: String = {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        return AppLocation(executable: exe).version()
    }()

    // MARK: - the file's name

    private static let unsafeInName: Set<UInt32> = Set(0...0x1F).union("/\\:*?\"<>|".unicodeScalars.map(\.value))

    /// `<date> <title>.zip`, safe as a file name anywhere it is sent: the start's day on this Mac's clock (`timeZone`),
    /// the title without control characters or `/\:*?"<>|`, on one line, at most 80 characters.
    public static func fileName(_ paths: RecordingPaths, timeZone: TimeZone = .autoupdatingCurrent,
                                stores: StorePaths = .current()) -> String {
        var day: String?
        if case .string(let text)? = PythonJSON.read(paths.meta)?["start_time"], let start = try? PyDateTime.parse(text) {
            day = localDay(start, timeZone)
        }
        var title = ""
        var inRun = false
        for u in (Titles.resolve(paths, stores: stores).title ?? "").unicodeScalars {  // re.sub(r"[...]+", " ", title)
            if unsafeInName.contains(u.value) {
                if !inRun { title.unicodeScalars.append(" ") }
                inRun = true
            } else {
                title.unicodeScalars.append(u)
                inRun = false
            }
        }
        if title.isEmpty { title = "Meeting" }  // `title or "Meeting"` (a title of control characters is " " here)
        let cut = Py.split(title).joined(separator: " ").unicodeScalars.prefix(80)
        var scalars = Array(cut)
        while let first = scalars.first, first == " " || first == "." { scalars.removeFirst() }
        while let last = scalars.last, last == " " || last == "." { scalars.removeLast() }
        title = scalars.isEmpty ? "Meeting" : String(String.UnicodeScalarView(scalars))
        return day.map { "\($0) \(title)\(SUFFIX)" } ?? "\(title)\(SUFFIX)"
    }

    /// `f"{start.astimezone():%Y-%m-%d}"`: a naive time is on this Mac's clock already.
    static func localDay(_ start: PyDateTime, _ timeZone: TimeZone) -> String {
        if start.offset == nil { return start.dayISO }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: start.date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `folder/name`, or `name 2`, `name 3` … when that is taken (anything there, a link followed).
    public static func freeName(_ folder: URL, _ name: String) -> URL {
        let scalars = Array(name.unicodeScalars), suffix = Array(SUFFIX.unicodeScalars)
        let zip = scalars.count >= suffix.count && Array(scalars.suffix(suffix.count)) == suffix
        let stem = zip ? String(String.UnicodeScalarView(scalars.dropLast(suffix.count))) : name
        var target = folder.appendingPathComponent(name)
        var n = 2
        while Undo.exists(target.path) {
            target = folder.appendingPathComponent("\(stem) \(n)\(zip ? SUFFIX : "")")
            n += 1
        }
        return target
    }

    // MARK: - what goes in

    /// The meeting can be exported: processed or synced, and no live worker on it.
    static func statusReady(_ paths: RecordingPaths) -> Bool {
        ["processed", "synced"].contains(MeetingStatus.status(paths)) && !WorkerPids.liveRunning(paths.folder)
    }

    /// Python's iteration of a JSON value: a list's items, an object's keys, a string's characters; TypeError
    /// otherwise.
    static func items(_ v: JSONValue, _ what: String) throws -> [JSONValue] {
        switch v {
        case .array(let a): return a
        case .object(let o): return o.map { .string($0.0) }
        case .string(let s): return s.unicodeScalars.map { .string(String($0)) }
        default: throw ExchangeExportError(.type, "\(what) is not iterable")
        }
    }

    /// `d.get(key, default)` of a value that must be a dict (AttributeError otherwise).
    static func get(_ d: JSONValue, _ key: String, _ fallback: JSONValue, _ what: String) throws -> JSONValue {
        guard case .object = d else { throw ExchangeExportError(.type, "\(what) is not an object") }
        return d[key] ?? fallback
    }

    /// `json.loads(path.read_text())`, `fallback` when it can't be read or is no JSON.
    static func read(_ url: URL, _ fallback: JSONValue) -> JSONValue { PythonJSON.read(url) ?? fallback }

    /// `int(s)` of the digits after "SPEAKER_" (any Unicode decimal digits, as `\d` and `int` take them).
    static func number<S: Sequence>(_ digits: S) -> Int where S.Element == Unicode.Scalar {
        digits.reduce(0) { n, u in
            let range = UnicodeTables.digitRanges.first { $0.0 <= u.value && u.value <= $0.1 }
            return n * 10 + Int((u.value - (range?.0 ?? u.value)) % 10)
        }
    }

    /// `notes._is_mic`: no diarization label, not a line said to be a person's (#12).
    static func isMic(_ u: Utterance) -> Bool { u.label == nil && u.saidBy == nil && ANY_LABEL.fullMatch(u.speaker) == nil }

    static func time(_ x: Double) -> JSONValue { .double(Py.round(x, 3)) }

    /// The transcript, turns and speakers as the export has them, the exporter's microphone a lane of its own; and that
    /// lane's label.
    static func lanes(_ paths: RecordingPaths, userName: String) throws -> (transcript: [JSONValue], turns: [JSONValue],
                                                                            speakers: [JSONValue], mic: String) {
        let merges = Speakers.loadMerges(paths)
        let ignored = Speakers.loadIgnored(paths)
        func isIgnored(_ label: String) -> Bool { ignored.contains { Py.same($0, label) } }
        let utterances = try list(paths.transcriptJson, "transcript.json").map { try Utterance(json: $0) }
        let turns = try list(paths.systemTurns, "system_turns.json").map { try SpeakerTurn(json: $0) }
        let labels = turns.map(\.speaker) + utterances.filter { !isMic($0) }.map(Speakers.labelOf)
        let numbers = labels.filter { LABEL.fullMatch($0) != nil }.map { label -> Int in
            let tail = label.unicodeScalars.split(separator: "_", omittingEmptySubsequences: false).last!
            return number(tail)
        }
        let mic = "SPEAKER_" + String(format: "%02d", (numbers.max() ?? -1) + 1)
        func lane(_ label: String) -> String { merges[label] ?? label }

        let names = try Speakers.namesInEffect(paths)
        let manual = try Speakers.loadSpeakerNames(paths).filter { !Py.same($0.value, $0.key) }.map(\.key)
        let recognized = try Speakers.loadRecognizedNames(paths)
        let inferred = try Speakers.loadInferredNames(paths)
        func shown(_ label: String) -> String { names[label].flatMap { $0.isEmpty ? nil : $0 } ?? label }
        let exporter: String? = SharedMic.micRoom(paths) != nil ? nil : userName
        let exporterNamed = exporter.map { !$0.isEmpty } ?? false

        // Lines said to be someone else's (#12): the user's go with the microphone, a person without a voice of their
        // own gets a lane after it.
        let fixes = Speakers.loadLineSpeakers(paths)
        var people = PyDict<String>()  // name → its lane in the export
        let micNumber = (numbers.max() ?? -1) + 1

        var transcript: [JSONValue] = [], micTurns: [(speaker: String, start: Double, end: Double)] = []
        for u in utterances {
            let fix = fixes.isEmpty ? nil : Speakers.lineFix(u, fixes).map { fixes[$0] }
            let fixLabel: String? = { if case .string(let l)? = fix?["label"] { return l } else { return nil } }()
            if let fix, !(fix["me"]?.truthy ?? false), fixLabel == nil, let given = fix["name"], given.truthy {
                let name = Py.str(given)
                let label = people[name] ?? "SPEAKER_" + String(format: "%02d", micNumber + 1 + people.count)
                if people[name] == nil { people[name] = label }
                transcript.append(.object([("start", time(u.start)), ("end", time(u.end)), ("text", .string(u.text)),
                                           ("label", .string(label)), ("speaker", .string(name))]))
                micTurns.append((label, Py.round(u.start, 3), Py.round(u.end, 3)))
                continue
            }
            let mine = fix.map { $0["me"]?.truthy ?? false } ?? isMic(u)
            if mine {
                transcript.append(.object([("start", time(u.start)), ("end", time(u.end)), ("text", .string(u.text)),
                                           ("label", .string(mic)),
                                           ("speaker", .string(exporterNamed ? exporter! : "Several people"))]))
                micTurns.append((mic, Py.round(u.start, 3), Py.round(u.end, 3)))
                continue
            }
            let label = lane(fixLabel ?? Speakers.labelOf(u))
            if isIgnored(label) || LABEL.fullMatch(label) == nil { continue }
            transcript.append(.object([("start", time(u.start)), ("end", time(u.end)), ("text", .string(u.text)),
                                       ("label", .string(label)), ("speaker", .string(shown(label)))]))
        }
        let laneTurns = turns.compactMap { t -> (speaker: String, start: Double, end: Double)? in
            let label = lane(t.speaker)
            guard !isIgnored(label), LABEL.fullMatch(label) != nil else { return nil }
            return (label, Py.round(t.start, 3), Py.round(t.end, 3))
        }
        let sortedTurns = Py.stableSorted(laneTurns + micTurns) { a, b in
            a.start != b.start ? a.start < b.start : Py.less(a.speaker, b.speaker)
        }
        let outTurns: [JSONValue] = sortedTurns.map {
            .object([("speaker", .string($0.speaker)), ("start", .double($0.start)), ("end", .double($0.end))])
        }

        var speakers: [JSONValue] = []
        let transcriptLabels = transcript.compactMap { $0["label"]?.stringValue }
        for label in Speakers.sortedUnique(sortedTurns.map(\.speaker) + transcriptLabels) {
            if Py.same(label, mic) {
                speakers.append(.object([("label", .string(mic)), ("name", .str(exporter)),
                                         ("how", exporterNamed ? .string("exporter") : .null)]))
                continue
            }
            if let person = people.first(where: { Py.same($0.value, label) }) {
                speakers.append(.object([("label", .string(label)), ("name", .string(person.key)), ("how", .string("hand"))]))
                continue
            }
            let name = names[label]
            var how: String?
            if let name, !name.isEmpty {
                how = manual.contains { Py.same($0, label) } ? "hand" : recognized[label] != nil ? "voice"
                    : inferred[label] != nil ? "inferred" : "hand"  // a merged label: named as its person
            }
            speakers.append(.object([("label", .string(label)), ("name", .str(name)), ("how", .str(how))]))
        }
        return (transcript, outTurns, speakers, mic)
    }

    /// `[X.from_dict(d) for d in _read(path, [])]`: the file's items; none when it can't be read.
    private static func list(_ url: URL, _ what: String) throws -> [JSONValue] {
        let v = read(url, .array([]))
        if case .null = v { throw ExchangeExportError(.type, "\(what): 'NoneType' object is not iterable") }
        return try items(v, what)
    }

    /// Python's `i in set(...)` of a decision's index: numbers equal to it (True is 1); text never.
    private static func contains(_ mine: [JSONValue], _ i: Int) -> Bool {
        mine.contains { m in
            switch m {
            case .int(let n): return n == i
            case .double(let d): return d == Double(i)
            case .bool(let b): return (b ? 1 : 0) == i
            default: return false
            }
        }
    }

    /// The notes as they travel: without what came from the exporter's own notes (#44), and without the hashes of
    /// their files.
    static func notes(_ paths: RecordingPaths) throws -> JSONValue? {
        guard let current = NotesFile.load(paths), current.truthy else { return nil }
        guard case .object = current else { throw ExchangeExportError(.type, "notes.json is not an object") }
        let mineValue = current["decisions_mine"] ?? .null
        let mine = mineValue.truthy ? try items(mineValue, "decisions_mine") : []
        if mine.contains(where: { if case .array = $0 { return true }; if case .object = $0 { return true }; return false }) {
            throw ExchangeExportError(.type, "unhashable type in decisions_mine")
        }
        var out = PyDict<JSONValue>()
        for key in NOTES_KEYS { if let v = current[key] { out[key] = v } }
        out["sections"] = .array(try items(current["sections"] ?? .array([]), "sections").map { s in
            let points = try items(try get(s, "points", .array([]), "a section"), "points").compactMap { p -> JSONValue? in
                if try get(p, "mine", .null, "a point").truthy { return nil }
                let details = try get(p, "details", .null, "a point")
                return .object([("text", try get(p, "text", .string(""), "a point")),
                                ("details", .array(details.truthy ? try items(details, "details") : []))])
            }
            return .object([("heading", try get(s, "heading", .string(""), "a section")), ("points", .array(points))])
        })
        out["next_steps"] = .array(try items(current["next_steps"] ?? .array([]), "next_steps").compactMap { s in
            if try get(s, "mine", .null, "a next step").truthy { return nil }
            return .object([("owner", try get(s, "owner", .string(""), "a next step")),
                            ("task", try get(s, "task", .string(""), "a next step"))])
        })
        out["decisions"] = .array(try items(current["decisions"] ?? .array([]), "decisions").enumerated()
            .filter { !contains(mine, $0.offset) }.map(\.element))
        out["speaker_names"] = .array(try items(current["speaker_names"] ?? .array([]), "speaker_names").map { g in
            .object([("label", try get(g, "label", .string(""), "a speaker name")),
                     ("name", try get(g, "name", .string(""), "a speaker name")),
                     ("evidence", try get(g, "evidence", .string(""), "a speaker name"))])
        })
        if out["summary"] == nil { out["summary"] = .string("") }
        return out.json
    }

    /// The event as it travels: where it was held stays home.
    static func calendar(_ paths: RecordingPaths) -> JSONValue? {
        guard let event = CalendarEvents.load(paths) else { return nil }
        return .object([("uid", .string(event.uid)), ("start", .string(event.start.iso)), ("end", .string(event.end.iso)),
                        ("title", .string(event.title)), ("series", .bool(event.series)),
                        ("attendees", .array(event.attendees.map { a in
                            .object([("name", .string(a.name)), ("email", .str(a.email)), ("organizer", .bool(a.organizer)),
                                     ("response", .string(a.response)), ("room", .bool(a.isRoom))])
                        }))])
    }

    /// `json.dumps(value, ensure_ascii=False, indent=1).encode()`.
    static func bytes(_ value: JSONValue) -> Data { Data(PythonJSON.dumps(value, indent: 1, ensureAscii: false).utf8) }

    /// `start + timedelta(seconds=duration)`: ValueError for NaN, OverflowError for infinity and beyond datetime's
    /// years (0001 to 9999).
    static func end(_ start: PyDateTime, _ duration: Double) throws -> PyDateTime {
        if duration.isNaN { throw ExchangeExportError(.value, "cannot convert float NaN to integer") }
        if duration.isInfinite { throw ExchangeExportError(.overflow, "cannot convert float infinity to integer") }
        // About 3.2e11 seconds span datetime's range: far beyond it the microseconds would overflow here.
        guard abs(duration) < 4e11 else { throw ExchangeExportError(.overflow, "date value out of range") }
        let end = try start.adding(seconds: duration)
        guard let year = Int(end.iso.prefix(4)), (1...9999).contains(year) else {
            throw ExchangeExportError(.overflow, "date value out of range")
        }
        return end
    }

    // MARK: - export

    /// Writes the meeting to `dest` (a `.zip` file; written beside it first, then renamed, so a half-written file is
    /// never seen). A meeting kept on this Mac throws `KeptOnThisMac` unless the user said yes (`confirmLocal`).
    /// `projects`: the exporter's project names, a hint for the importer. `audio`: the tracks too, compressed
    /// (`ExchangeAudio.encodeTrack`), stored after the JSON files.
    @discardableResult
    public static func exportMeeting(_ paths: RecordingPaths, dest: URL, userName: String, notes withNotes: Bool = true,
                                     voices: Bool = false, audio: Bool = false, confirmLocal: Bool = false,
                                     projects: [String] = [], stores: StorePaths = .current(), now: Date = Date(),
                                     timeZone: TimeZone = .current, version: String = palaverVersion) throws -> URL {
        guard statusReady(paths) else { throw NotReady() }
        let keptHere = LocalOnly.isLocalOnly(paths.folder)
        if keptHere && !confirmLocal { throw KeptOnThisMac(description: paths.folder.lastPathComponent) }
        let meta = read(paths.meta, .object([]))
        guard case .object = meta else { throw ExchangeExportError(.type, "meta.json is not an object") }
        guard let startValue = meta["start_time"] else { throw ExchangeExportError(.key, "'start_time'") }
        guard case .string(let startText) = startValue else {
            throw ExchangeExportError(.type, "fromisoformat: argument must be str")
        }
        let start: PyDateTime
        do { start = try PyDateTime.parse(startText) } catch { throw ExchangeExportError(.value, "\(error)") }
        let durationValue = meta["duration_seconds"] ?? .null
        let duration: Double
        if !durationValue.truthy {
            duration = 0
        } else if let d = VoiceMath.pyFloat(durationValue) {
            duration = d
        } else if case .string = durationValue {
            throw ExchangeExportError(.value, "could not convert string to float")
        } else {
            throw ExchangeExportError(.type, "float() argument must be a string or a real number")
        }
        let (transcript, turns, speakers, _) = try lanes(paths, userName: userName)
        let title = Titles.resolve(paths, stores: stores).title
        var language: String?
        if Undo.exists(paths.language.path) {
            let data = try Data(contentsOf: paths.language)
            guard let text = String(data: data, encoding: .utf8) else {
                throw ExchangeExportError(.value, "language.txt is not UTF-8")
            }
            // read_text's universal newlines, then `.strip()[:16]`.
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let cut = String(String.UnicodeScalarView(Py.strip(lines).unicodeScalars.prefix(16)))
            language = cut.isEmpty ? nil : cut
        }
        var uniqueProjects: [String] = []
        for p in projects where !uniqueProjects.contains(where: { Py.same($0, p) }) { uniqueProjects.append(p) }
        var files = PyDict<Data>()
        files["meeting/meta.json"] = bytes(.object([
            ("start", .string(start.iso)), ("end", .string(try end(start, duration).iso)), ("duration", .double(duration)),
            ("title", .str(title)), ("language", .str(language)),
            ("projects", .strings(Py.stableSorted(uniqueProjects, by: Py.less))), ("kept_on_this_mac", .bool(keptHere)),
        ]))
        files["meeting/transcript.json"] = bytes(.array(transcript))
        files["meeting/turns.json"] = bytes(.array(turns))
        files["meeting/speakers.json"] = bytes(.array(speakers))
        if let event = calendar(paths) { files["meeting/calendar.json"] = bytes(event) }
        if withNotes, let meetingNotes = try notes(paths) { files["meeting/notes.json"] = bytes(meetingNotes) }
        if voices {
            let stored = read(paths.speakerEmbeddings, .object([]))
            let embeddings = stored.truthy ? stored : .object([])
            let merges = Speakers.loadMerges(paths)
            for s in speakers {
                guard let how = s["how"]?.stringValue, how == "hand" || how == "voice", let label = s["label"]?.stringValue
                else { continue }  // a guess teaches no voice; the exporter's own microphone has none
                guard case .object = embeddings else { throw ExchangeExportError(.type, "speaker_embeddings.json is not an object") }
                var vector = embeddings[label]
                if !(vector?.truthy ?? false) {
                    vector = merges.first { Py.same($0.value, label) && embeddings[$0.key] != nil }.flatMap { embeddings[$0.key] }
                }
                guard let vector, vector.truthy else { continue }
                let floats = try items(vector, "an embedding").map { x -> JSONValue in
                    guard let d = VoiceMath.pyFloat(x) else { throw ExchangeExportError(.value, "an embedding holds no number") }
                    return .double(d)
                }
                files["voices/\(label).json"] = bytes(.object([("label", .string(label)), ("name", s["name"] ?? .null),
                                                               ("embedding", .array(floats))]))
            }
        }
        let parent = dest.deletingLastPathComponent().path
        try Undo.makedirs(parent)
        let tmp = try temporaryFolder(in: parent)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        var tracks: [(name: String, file: URL)] = []
        if audio {
            let mic = Undo.exists(paths.micWav.path) ? paths.micWav : paths.micRawWav
            for (track, wav) in [("system", paths.systemWav), ("mic", mic)] where Undo.exists(wav.path) {
                let out = try ExchangeAudio.encodeTrack(wav, destDir: URL(fileURLWithPath: tmp), track: track)
                tracks.append(("audio/\(out.lastPathComponent)", out))
            }
        }
        var listed: [(String, JSONValue)] = []
        for (name, content) in files {
            let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
            listed.append((name, .object([("sha256", .string(digest)), ("bytes", .int(content.count))])))
        }
        for (name, file) in tracks {
            let (digest, size) = try sha256(file)
            listed.append((name, .object([("sha256", .string(digest)), ("bytes", .int(size))])))
        }
        let manifest = JSONValue.object([
            ("format", .int(FORMAT)), ("palaver_version", .string(version)),
            ("exported_at", .string(Py.isoNow(timespec: "seconds", now: now, timeZone: timeZone))),
            ("exported_by", .string(userName)), ("files", .object(listed)),
        ])
        let part = tmp + "/out.zip"
        let zip = try ZipWriter(url: URL(fileURLWithPath: part))
        try zip.add(name: "manifest.json", data: bytes(manifest), deflate: true)
        for (name, content) in files { try zip.add(name: name, data: content, deflate: true) }
        // Compressed audio: deflating it again gains nothing.
        for (name, file) in tracks { try zip.add(name: name, file: file, stored: true) }
        try zip.finish()
        guard rename(part, dest.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return dest
    }

    /// `_sha256`: a file's digest (hex) and size, read in 1 MiB pieces.
    static func sha256(_ url: URL) throws -> (String, Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var size = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            digest.update(data: chunk)
            size += chunk.count
        }
        return (digest.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }

    /// `tempfile.mkdtemp(dir=parent, prefix=EXPORT_PREFIX)`: a new folder (0700) with eight random characters.
    private static func temporaryFolder(in parent: String) throws -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyz0123456789_")
        for _ in 0..<100 {
            let name = EXPORT_PREFIX + String((0..<8).map { _ in characters.randomElement()! })
            let path = parent + "/" + name
            if mkdir(path, 0o700) == 0 { return path }
            if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw POSIXError(.EEXIST)
    }

    // MARK: - leftovers

    /// What imports and exports left behind when the server stopped half-way through one: staging folders (beside the
    /// recordings), and temporary folders beside exports (in `downloads`), older than `olderThan` seconds.
    public static func sweep(_ outputDir: URL, downloads: URL? = nil, olderThan: Double = 3600, now: Date = Date()) {
        let old = now.timeIntervalSince1970 - olderThan
        let staging = outputDir.appendingPathComponent(STAGING).path
        var leftovers = names(in: staging).map { staging + "/" + $0 }
        if let downloads {
            let prefix = Array(EXPORT_PREFIX.unicodeScalars)
            leftovers += names(in: downloads.path).filter { Array($0.unicodeScalars.prefix(prefix.count)) == prefix }
                .map { downloads.path + "/" + $0 }
        }
        for path in leftovers {
            var st = stat()
            // A real folder (not a link to one), last changed before `old`.
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
            let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            if mtime < old { try? FileManager.default.removeItem(atPath: path) }
        }
    }

    /// The names in a folder (hidden ones too), as `readdir` gives them; none when it can't be read.
    static func names(in folder: String) -> [String] {
        guard let dir = opendir(folder) else { return [] }
        defer { closedir(dir) }
        var out: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { out.append(name) }
        }
        return out
    }
}
