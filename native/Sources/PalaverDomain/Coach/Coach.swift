// The speaker coach's numbers (coach.py, issue #41): how the user talks in a meeting. Everything on the microphone is
// the user's; the others' lines carry their speaker. Per meeting: talk share against a fair share, monologues, pace,
// filler words, questions and the quiet after them, interruptions both ways, invitees who barely spoke. Where several
// people shared one microphone (#56) what is about people is left out. `baseline` averages the last meetings (1:1s
// and groups apart), `trends` per week and per kind; the baseline is saved for the live coach.
//
// The numbers are Python's: float arithmetic in coach.py's order, `round` as Python rounds (`Py.round`; an int stays an
// int), `statistics.mean` exact (`PyStatistics`), results as ordered JSON objects with coach.py's keys.
import Foundation
import PalaverCore

/// What coach.py raises: a KeyError (the message is Python's `str(KeyError)`, the key quoted), a TypeError, an
/// unreadable transcript.
public struct CoachError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }

    static func key(_ key: String) -> CoachError { CoachError("'\(key)'") }
}

public enum Coach {
    // coach.py:39-58.
    /// My speech with gaps up to this long, and no one else speaking, is one stretch.
    public static let STRETCH_GAP = 3.0
    public static let MONOLOGUE_SECONDS = 90.0
    /// Others' speech shorter than this ("Mhm", "Ja") does not end a stretch or count as an interruption: a backchannel.
    public static let BACKCHANNEL_SECONDS = 1.5
    public static let INTERRUPT_OVERLAP = 1.0  // talking over someone for at least this long
    public static let INTERRUPT_MIN_SECONDS = 2.5  // ... with more than a quick word
    public static let CUT_OFF_SECONDS = 3.0  // ... and the one talking stops within this
    public static let PACE_WINDOW = 120.0
    public static let QUIET_INVITEE_SECONDS = 30.0

    public static let HESITATIONS = ["äh", "ähm", "öhm", "ehm", "uh", "uhm", "umm", "erm"]
    public static let TICS = ["irgendwie", "halt", "quasi", "sozusagen", "eigentlich", "genau", "basically", "actually",
                              "you know", "kind of", "sort of"]
    static let OPEN = try! PyRegex(
        #"^(wer|wen|wem|was|wie|wieso|warum|weshalb|wo|wohin|woher|wann|welche[rsmn]?|wofür|womit|"#
            + #"worauf|worüber|how|what|why|where|when|which|who|whom)\b"#, ignoreCase: true)
    public static let GERMAN = ["und", "ich", "das", "ist", "nicht", "wir", "aber", "auch"]
    public static let ENGLISH = ["and", "the", "is", "not", "we", "but", "also", "that"]
    static let WORDS = try! PyRegex(#"[^\W\d_]+(?:['’-][^\W\d_]+)*"#)

    /// What is usual: the last this many meetings, so it follows how the user talks now.
    public static let BASELINE_MEETINGS = 30
    public static let TREND_WEEKS = 12

    private static let hesitations = Set(HESITATIONS.map(ScalarKey.init))
    /// `_count`'s pattern of each phrase it is asked for.
    private static let phrases: [ScalarKey: PyRegex] = Dictionary(uniqueKeysWithValues: (TICS + GERMAN + ENGLISH).map {
        (ScalarKey($0), try! PyRegex(#"(?<![\w-])"# + PyRegex.escape($0) + #"(?![\w-])"#, ignoreCase: true))
    })

    // MARK: - one meeting

    /// (my lines, the others' lines): removed voices left out, merged labels as the label they joined. An earlier
    /// name of the user still means the user (#55).
    static func lanes(_ paths: RecordingPaths, userName: String, stores: StorePaths) throws -> ([Utterance], [Utterance]) {
        let data: Data
        do { data = try Data(contentsOf: paths.transcriptJson) } catch { throw CoachError("\(error)") }
        guard case .array(let items) = try PythonJSON.parse(data) else { throw CoachError("transcript.json is no list") }
        let raw = try Speakers.withoutIgnored(paths, try items.map { try Utterance(json: $0) })
        let merges = Speakers.loadMerges(paths)
        let names = Set(([userName] + SettingsFile.userAliases(stores: stores)).filter { !$0.isEmpty }
            .map { ScalarKey(Py.casefold($0)) })
        var mine: [Utterance] = [], theirs: [Utterance] = []
        for u in raw {
            if names.contains(ScalarKey(Py.casefold(u.speaker))) && (u.label ?? "").isEmpty {
                mine.append(u)
            } else {
                let label = (u.label ?? "").isEmpty ? u.speaker : u.label!
                let merged = merges[label] ?? label
                theirs.append(Utterance(speaker: merged, start: u.start, end: u.end, text: u.text, label: merged))
            }
        }
        return (mine, theirs)
    }

    /// `max(0.0, x)`: 0.0 unless x is above it.
    private static func positive(_ x: Double) -> Double { x > 0.0 ? x : 0.0 }

    /// `_seconds`: Python's `sum()`, compensated (`Py.sum`).
    private static func seconds(_ lines: [Utterance]) -> Double {
        Py.sum(lines.map { positive($0.end - $0.start) })
    }

    /// How many words `text` has (`len(_WORDS.findall(text))`).
    public static func words(_ text: String) -> Int { WORDS.matches(in: text).count }

    /// Python's `round(x)` of a float: an int, half to even; throws for NaN, infinity or a number past Int (a
    /// hand-edited file), where Python raises too.
    static func roundInt(_ x: Double) throws -> Int { try Py.roundInt(x) }

    private static func rounded(_ x: Double, _ digits: Int) -> JSONValue { .double(Py.round(x, digits)) }

    private struct Stretch {
        var start: Double
        var end: Double
        var words: Int
    }

    /// My speech joined across short gaps, broken by someone else speaking.
    private static func stretches(_ mine: [Utterance], _ theirs: [Utterance]) -> [Stretch] {
        let interjections = theirs.filter { $0.end - $0.start >= BACKCHANNEL_SECONDS }.map(\.start)
        var out: [Stretch] = []
        for u in Py.stableSorted(mine, by: { $0.start < $1.start }) {
            if let last = out.last, u.start - last.end <= STRETCH_GAP,
               !interjections.contains(where: { last.end - 0.2 < $0 && $0 < u.start }) {
                out[out.count - 1].end = max(last.end, u.end)
                out[out.count - 1].words += words(u.text)
            } else {
                out.append(Stretch(start: u.start, end: u.end, words: words(u.text)))
            }
        }
        return out
    }

    /// `_count`: how often `phrase` stands as a word of its own in `text`, any case.
    public static func count(_ text: String, _ phrase: String) -> Int {
        let regex = phrases[ScalarKey(phrase)]
            ?? (try! PyRegex(#"(?<![\w-])"# + PyRegex.escape(phrase) + #"(?![\w-])"#, ignoreCase: true))
        return regex.matches(in: text).count
    }

    private static func rstripped(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let last = scalars.lastIndex(where: { !Py.isSpace($0) }) else { return "" }
        return String(scalars[...last])
    }

    /// `s.lstrip(chars)`.
    private static func lstripped(_ s: String, _ chars: Set<Unicode.Scalar>) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !chars.contains($0) }) else { return "" }
        return String(scalars[first...])
    }

    /// The coach's numbers for one meeting. `invited`: invitees as named in the meeting; `names`: label → name of
    /// the others.
    public static func analyze(_ paths: RecordingPaths, userName: String, invited: [String] = [],
                               names: PyDict<String> = PyDict(), stores: StorePaths = .current()) throws -> JSONValue {
        let (mine, theirs) = try lanes(paths, userName: userName, stores: stores)
        let atMic = SharedMic.micRoom(paths) != nil && !mine.isEmpty  // my track is several people's
        let sharedLabels = SharedMic.sharedLabels(paths)
        let shared = theirs.contains { sharedLabels.contains(ScalarKey($0.speaker)) } || atMic
        let me = seconds(mine)
        var bySpeaker = PyDict<Double>()
        for u in theirs { bySpeaker[u.speaker] = (bySpeaker[u.speaker] ?? 0.0) + positive(u.end - u.start) }
        let others = Py.sum(bySpeaker.values)  // sum(), compensated; the per-speaker `+=` above is plain
        let people = 1 + bySpeaker.values.filter { $0 >= 10 }.count
        let minutes = me / 60

        let stretches = stretches(mine, theirs)
        var monologues: [JSONValue] = try Py.stableSorted(
            stretches.filter { $0.end - $0.start >= MONOLOGUE_SECONDS }.map { s in
                (start: Py.round(s.start, 1), seconds: try roundInt(s.end - s.start))
            }, by: { -$0.seconds < -$1.seconds }
        ).map { .object([("start", .double($0.start)), ("seconds", .int($0.seconds))]) }

        let words = mine.reduce(0) { $0 + Self.words($1.text) }
        var fastest: (start: Double, wpm: Int)?
        for s in stretches {
            let span = s.end - s.start
            if span >= 30 {
                let wpm = Double(s.words) / span * 60
                // Against the fastest so far as rounded, as coach.py compares.
                if fastest == nil || wpm > Double(fastest!.wpm) { fastest = (Py.round(s.start, 1), try roundInt(wpm)) }
            }
        }

        let text = mine.map(\.text).joined(separator: " ")
        var tics: [(String, Int)] = Py.stableSorted(TICS.map { ($0, count(text, $0)) }, by: { -$0.1 < -$1.1 })
        var hesitationCount: Int? = WORDS.matches(in: Py.casefold(text))
            .filter { hesitations.contains(ScalarKey($0.group() ?? "")) }.count

        // Questions: everyone's lines by start, mine before theirs where they start together.
        let everyone = Py.stableSorted(mine.map { ($0, true) } + theirs.map { ($0, false) }, by: { $0.0.start < $1.0.start })
        var questions: [(start: Double, text: String, open: Bool, keptTalking: Bool, wait: Double?)] = []
        for (i, (u, isMine)) in everyone.enumerated() where isMine && rstripped(u.text).hasSuffix("?") {
            let next = everyone[(i + 1)...].first { $0.0.start >= u.end - 0.1 }
            let mineNext = next?.1 ?? false
            let stripped = Py.strip(u.text)
            questions.append((
                Py.round(u.start, 1), stripped,
                OPEN.firstMatch(in: lstripped(stripped, ["„", "\"", "'"])) != nil,
                mineNext,
                // I went on talking myself, or how long I left it quiet for an answer.
                next != nil && !mineNext ? Py.round(positive(next!.0.start - u.end), 1) : nil))
        }

        // An interruption: one starts while the other talks, and the other stops soon after while the first goes
        // on. Overlap alone is mostly backchannels and timing noise.
        func cutOff(_ a: [Utterance], _ b: [Utterance]) -> [JSONValue] {
            var found: [JSONValue] = []
            for u in a where !(u.end - u.start < INTERRUPT_MIN_SECONDS) {
                for v in b {
                    if v.end - v.start >= BACKCHANNEL_SECONDS && v.start < u.start && u.start < v.end - INTERRUPT_OVERLAP
                        && v.end - u.start <= CUT_OFF_SECONDS && u.end > v.end + 1.0
                        && Fuzz.partialRatio(Py.casefold(u.text), Py.casefold(v.text)) < 70 {  // not an echo
                        found.append(.object([("start", rounded(u.start, 1)), ("who", .string(names[v.speaker] ?? v.speaker))]))
                        break
                    }
                }
            }
            return found
        }
        let byMe = cutOff(mine, theirs), ofMe = cutOff(theirs, mine)

        var spoke = PyDict<Double>()
        for (label, t) in bySpeaker { spoke[Py.casefold(names[label] ?? label)] = t }
        var quiet: [JSONValue] = try invited.compactMap { n in
            let t = spoke[Py.casefold(n)] ?? 0.0
            return t < QUIET_INVITEE_SECONDS ? .object([("name", .string(n)), ("seconds", .int(try roundInt(t)))]) : nil
        }
        if shared { monologues = []; quiet = [] }  // one voice is several people: who talked how much is unknown
        if atMic { fastest = nil; tics = []; hesitationCount = nil }  // not my pace, not my filler words

        let waits = questions.compactMap(\.wait)
        let talk: JSONValue = .object([
            ("me", .int(try roundInt(me))), ("others", .int(try roundInt(others))),
            ("share", me + others != 0 && !shared ? rounded(me / (me + others), 3) : .null),
            ("fair", shared ? .null : rounded(1 / Double(people), 3)), ("people", .int(people)),
            ("shared", .bool(shared)), ("at_mic", .bool(atMic)),
        ])
        let fillerSum = tics.reduce(0) { $0 + $1.1 }
        let all = me + others
        return .object([
            ("talk", talk),
            ("monologues", .array(monologues)),
            ("pace", .object([
                ("wpm", minutes >= 1 && !atMic ? .int(try roundInt(Double(words) / minutes)) : .null),
                ("fastest", fastest.map { .object([("start", .double($0.start)), ("wpm", .int($0.wpm))]) } ?? .null),
            ])),
            ("fillers", .object([
                ("per_minute", minutes >= 1 && !atMic ? rounded(Double(fillerSum) / minutes, 2) : .null),
                ("top", .array(tics.filter { $0.1 != 0 }.prefix(5).map {
                    .object([("word", .string($0.0)), ("count", .int($0.1))])
                })),
                ("hesitations", hesitationCount.map { .int($0) } ?? .null),
            ])),
            ("questions", .object([
                ("count", .int(questions.count)), ("open", .int(questions.filter(\.open).count)),
                ("per_hour", all >= 600 ? rounded(Double(questions.count) / (all / 3600), 1) : .null),
                ("wait", PyStatistics.median(waits).map { rounded($0, 1) } ?? .null),
                ("kept_talking", .int(questions.filter(\.keptTalking).count)),
                ("list", .array(questions.map { q in
                    .object([("start", .double(q.start)), ("text", .string(q.text)), ("open", .bool(q.open)),
                             ("kept_talking", .bool(q.keptTalking)), ("wait", q.wait.map { .double($0) } ?? .null)])
                })),
            ])),
            ("interruptions", .object([
                ("by_me", .int(byMe.count)), ("of_me", .int(ofMe.count)),
                ("by_me_at", .array(Array(byMe.prefix(5)))), ("of_me_at", .array(Array(ofMe.prefix(5)))),
            ])),
            ("language", .string(GERMAN.reduce(0) { $0 + count(text, $1) } >= ENGLISH.reduce(0) { $0 + count(text, $1) }
                ? "de" : "en")),
            ("quiet_invitees", .array(quiet)),
            ("minutes_talked", rounded(minutes, 1)),
        ])
    }

    // MARK: - over meetings

    /// A field of a result row: Python's KeyError when it is missing.
    private static func field(_ v: JSONValue, _ keys: String...) throws -> JSONValue {
        var cur = v
        for key in keys {
            guard case .object = cur else { throw CoachError("'\(cur)' is not a dict") }
            guard let next = cur[key] else { throw CoachError.key(key) }
            cur = next
        }
        return cur
    }

    /// A number or None.
    private static func number(_ v: JSONValue) throws -> PyNum? {
        if case .null = v { return nil }
        guard let n = PyNum(v) else { throw CoachError("TypeError: \(v) is not a number") }
        return n
    }

    /// `values[-n:]` (all of them for 0, as Python slices).
    static func tail<T>(_ values: [T], _ n: Int) -> [T] {
        n >= 0 ? Array(values.suffix(n == 0 ? values.count : n)) : Array(values.dropFirst(-n))
    }

    /// `_avg`: the mean of the values that are not None, rounded; None when there are none.
    static func avg(_ values: [JSONValue], _ digits: Int = 3) throws -> JSONValue {
        let numbers = try values.compactMap(number)
        return PyStatistics.mean(numbers)?.rounded(digits).json ?? .null
    }

    /// What is usual across the last BASELINE_MEETINGS meetings (`results` oldest first): 1:1s and groups apart for
    /// talk share.
    public static func baseline(_ results: [JSONValue]) throws -> JSONValue {
        let results = tail(results, BASELINE_MEETINGS)
        func people(_ r: JSONValue) throws -> PyNum? { try number(field(r, "talk", "people")) }
        let one = try results.filter { try people($0).map { $0 == 2 } ?? false }
        let group = try results.filter {
            guard let p = try people($0) else { throw CoachError("TypeError: '>' not supported for None") }
            return p > 2
        }
        let long = try results.filter {
            guard let m = try number(field($0, "minutes_talked")) else { throw CoachError("TypeError: '>=' not supported for None") }
            return m >= 3
        }
        return .object([
            ("meetings", .int(results.count)),
            ("share_1on1", try avg(one.map { try field($0, "talk", "share") })),
            ("share_group", try avg(group.map { try field($0, "talk", "share") })),
            ("wpm", try avg(long.map { try field($0, "pace", "wpm") })),
            // Filler words depend on the language: compare German with German.
            ("fillers_per_minute", .object(try ["de", "en"].map { lang in
                (lang, try avg(long.filter { Py.same(try field($0, "language").stringValue ?? "", lang) }
                    .map { try field($0, "fillers", "per_minute") }))
            })),
            ("questions_per_hour", try avg(long.map { try field($0, "questions", "per_hour") })),
        ])
    }

    /// `week_of`: the Monday of the start's day as written: the date of `datetime.fromisoformat(start)`, else of
    /// `date.fromisoformat(start[:10])`. Both are the first ten characters in the `YYYY-MM-DD` forms Palaver writes.
    static func weekOf(_ start: String) throws -> String {
        let head = String(String.UnicodeScalarView(start.unicodeScalars.prefix(10)))
        guard let day = PyDate(iso: head), let monday = day.adding(days: -day.weekday) else {
            throw CoachError("Invalid isoformat string: '\(head)'")
        }
        return monday.iso
    }

    /// Talk share, pace and filler words per week (the last `weeks` with meetings) and per kind of meeting, from
    /// `history` rows. Pace and fillers only from meetings where the user talked 3 minutes or more.
    public static func trends(_ rows: [JSONValue], weeks: Int = TREND_WEEKS) throws -> JSONValue {
        func numbers(_ group: [JSONValue]) throws -> [(String, JSONValue)] {
            let long = try group.filter {
                guard let m = try number($0["minutes_talked"] ?? .int(0)) else { throw CoachError("TypeError: '>=' not supported for None") }
                return m >= 3
            }
            let wpm = try avg(long.map { try field($0, "pace", "wpm") }, 1)
            let rounded: JSONValue
            switch wpm {
            case .double(let d): rounded = .int(try roundInt(d))
            default: rounded = wpm
            }
            return [("meetings", .int(group.count)), ("share", try avg(group.map { try field($0, "talk", "share") })),
                    ("wpm", rounded), ("fillers", try avg(long.map { try field($0, "fillers", "per_minute") }, 2))]
        }
        var byWeek = PyDict<[JSONValue]>()
        for r in rows {
            guard let start = try field(r, "start").stringValue else { throw CoachError("TypeError: start is not text") }
            let week = try weekOf(start)
            byWeek[week] = (byWeek[week] ?? []) + [r]
        }
        var byKind = PyDict<[JSONValue]>()
        for r in rows {
            guard let kind = try field(r, "kind").stringValue else { throw CoachError("TypeError: kind is not text") }
            byKind[kind] = (byKind[kind] ?? []) + [r]
        }
        let shown = tail(Py.stableSorted(byWeek.keys, by: Py.less), weeks)
        return .object([
            ("weeks", .array(try shown.map { w in .object([("week", .string(w))] + (try numbers(byWeek[w]!))) })),
            ("kinds", .array(try ["1:1", "group"].compactMap { k in
                try byKind[k].map { .object([("kind", .string(k))] + (try numbers($0))) }
            })),
        ])
    }

    /// Python's truth of a number or None.
    private static func truthy(_ n: PyNum?) -> Bool { n.map { $0.double != 0 } ?? false }

    /// `round(100 * x)` as Python writes it.
    private static func percent(_ x: PyNum) throws -> String {
        switch x {
        case .int(let i):
            let (n, over) = i.multipliedReportingOverflow(by: 100)
            guard !over else { throw Py.IntError(description: "the number \(i) is too large") }
            return String(n)
        case .float(let d): return String(try roundInt(100 * d))
        }
    }

    /// `str(v)` of a JSON value as an f-string shows it.
    private static func shown(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return Py.repr(d)
        case .bool(let b): return b ? "True" : "False"
        case .null: return "None"
        default: return "\(v)"
        }
    }

    /// The few things worth saying about one meeting, against the baseline.
    public static func highlights(_ r: JSONValue, _ base: JSONValue) throws -> [String] {
        var out: [String] = []
        let share = try number(field(r, "talk", "share"))
        let isOne = try number(field(r, "talk", "people")).map { $0 == 2 } ?? false
        let kind = isOne ? "1:1s" : "group meetings"
        let usual = try number(field(base, isOne ? "share_1on1" : "share_group"))
        if let share, truthy(usual), share.double > usual!.double + 0.15 {
            out.append("You talked \(try percent(share)) % of the time; in \(kind) you usually talk \(try percent(usual!)) %.")
        } else if let share, truthy(usual), share.double < usual!.double - 0.2 {
            out.append("You talked \(try percent(share)) % of the time — quieter than your usual \(try percent(usual!)) %.")
        }
        if let monologues = try field(r, "monologues").arrayValue, let m = monologues.first {
            guard case .int(let s) = try field(m, "seconds") else { throw CoachError("TypeError: seconds is not an int") }
            let minutes = Int((Double(s) / 60).rounded(.down)), rest = s - 60 * minutes
            out.append("Longest stretch without anyone else: \(minutes):\(String(format: "%02d", rest))"
                + (monologues.count > 1 ? " (\(monologues.count) over 1:30)" : "") + ".")
        }
        let fpm = try number(field(r, "fillers", "per_minute"))
        let language = try field(r, "language")
        let perLanguage = try field(base, "fillers_per_minute")
        guard case .object = perLanguage else { throw CoachError("AttributeError: fillers_per_minute has no get") }
        let usualFpm = try number(PyDict(perLanguage)?[language.stringValue ?? ""] ?? .null)
        let top = try field(r, "fillers", "top").arrayValue ?? []
        if let fpm, truthy(fpm), let first = top.first, !truthy(usualFpm) || fpm.double > usualFpm!.double * 1.25 {
            out.append("“\(shown(try field(first, "word")))” \(shown(try field(first, "count")))× — "
                + String(format: "%.1f", fpm.double) + " filler words a minute"
                + (truthy(usualFpm) ? " (usual " + String(format: "%.1f", usualFpm!.double) + ")." : "."))
        }
        if let byMe = try number(field(r, "interruptions", "by_me")), byMe >= 5 {
            out.append("You started while someone was still talking \(byMe) times.")
        }
        if let quiet = try field(r, "quiet_invitees").arrayValue, !quiet.isEmpty {
            let names = try quiet.prefix(3).map { shown(try field($0, "name")) }.joined(separator: ", ")
            out.append("Barely heard: \(names).")
        }
        return Array(out.prefix(4))
    }

    /// The recording folders of `outputDir` that have a transcript, in name order.
    public static func meetings(_ outputDir: URL) -> [RecordingPaths] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: outputDir.path) else { return [] }
        return Py.stableSorted(names, by: Py.less).compactMap { name in
            let folder = outputDir.appendingPathComponent(name, isDirectory: true)
            guard RecordingPaths.isRecordingFolderName(name),
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.json").path) else { return nil }
            return RecordingPaths(folder)
        }
    }

    // MARK: - every meeting, cached

    /// `result`'s memory: per folder (and user name), the numbers and the signature of the files they came from.
    public final class Cache: @unchecked Sendable {
        public static let shared = Cache()
        private let lock = NSLock()
        private var results: [ScalarKey: (signature: [Int64], result: JSONValue)] = [:]
        /// The folders analyzed, in order (tests count them).
        private(set) var analyzed: [String] = []

        public init() {}

        func get(_ key: ScalarKey, _ signature: [Int64]) -> JSONValue? {
            lock.lock(); defer { lock.unlock() }
            guard let hit = results[key], hit.signature == signature else { return nil }
            return hit.result
        }

        func put(_ key: ScalarKey, _ signature: [Int64], _ result: JSONValue, folder: String) {
            lock.lock(); defer { lock.unlock() }
            results[key] = (signature, result)
            analyzed.append(folder)
        }
    }

    /// The files a result depends on: each one's modification time (ns), size and inode; zeros when it is missing.
    /// coach.py compares the times only; size and inode also catch a file replaced within the clock's resolution.
    /// A modification time beyond Int's nanoseconds (year 2262+): a signature holding it is never cached.
    static let unknownTime = Int64.min

    static func signature(_ paths: RecordingPaths) -> [Int64] {
        let files = [paths.meta, paths.transcriptJson, paths.calendar, paths.speakers, paths.speakersAuto,
                     paths.speakersMerged, paths.speakersIgnored, paths.speakersInferred, paths.speakersRejected,
                     paths.speakersShared, paths.speakersLines]
        return files.flatMap { url -> [Int64] in
            var st = stat()
            guard stat(url.path, &st) == 0 else { return [0, 0, 0] }
            return [FileTimes.mtimeNs(st).map(Int64.init) ?? unknownTime, Int64(st.st_size),
                    Int64(bitPattern: UInt64(st.st_ino))]
        }
    }

    /// `analyze` with the meeting's names and invitees, kept until one of its files changes (the window and the live
    /// coach share it).
    public static func result(_ paths: RecordingPaths, userName: String, stores: StorePaths = .current(),
                              cache: Cache = .shared) throws -> JSONValue {
        let signature = signature(paths)
        let key = ScalarKey(paths.folder.path + "\u{0}" + userName)
        let cacheable = !signature.contains(unknownTime)
        if cacheable, let hit = cache.get(key, signature) { return hit }
        let names = try Speakers.namesInEffect(paths)
        let voices = try VoiceBank(directory: stores.voices).names()
        var seen = Set<ScalarKey>(), known: [String] = []
        for name in names.values + voices.keys where seen.insert(ScalarKey(name)).inserted { known.append(name) }
        let invited = CalendarEvents.invitedNames(paths, Py.stableSorted(known, by: Py.less), userName: userName) ?? []
        // Who was cut off: a room shows as the room, not as SPEAKER_xx (#56).
        var all = names
        for (label, shown) in SharedMic.display(paths) { all[label] = shown }
        let r = try analyze(paths, userName: userName, invited: invited, names: all, stores: stores)
        if cacheable { cache.put(key, signature, r, folder: paths.folder.lastPathComponent) }
        return r
    }

    /// The meeting's start: meta.json's start_time, else the folder name's time, else the folder name.
    static func start(_ paths: RecordingPaths) -> String {
        if let s = PythonJSON.read(paths.meta)?["start_time"]?.stringValue, !s.isEmpty { return s }
        let name = paths.folder.lastPathComponent
        return RecordingPaths.recordingFolderTimestamp(name) ?? name
    }

    /// Every transcribed meeting's numbers (only the last `limit`: no other is read), oldest first, with its start
    /// and kind ("1:1": one other person spoke, else "group"). A meeting that can't be read is left out.
    public static func history(_ outputDir: URL, userName: String, limit: Int? = nil, stores: StorePaths = .current(),
                               cache: Cache = .shared) -> [JSONValue] {
        let found = meetings(outputDir)
        var out: [JSONValue] = []
        for paths in limit.map({ tail(found, $0) }) ?? found {
            guard let r = try? result(paths, userName: userName, stores: stores, cache: cache),
                  case .object(let fields) = r else { continue }
            let one = r["talk"]?["people"].flatMap { PyNum($0) }.map { $0 == 2 } ?? false
            out.append(.object([("id", .string(paths.folder.lastPathComponent)), ("start", .string(start(paths))),
                                ("kind", .string(one ? "1:1" : "group"))] + fields))
        }
        return out
    }

    // MARK: - the baseline on disk: computed after `process`, read by the live coach

    public static func baselinePath(stores: StorePaths = .current()) -> URL { stores.coachBaseline }

    /// What is usual over the last BASELINE_MEETINGS meetings, saved for the live coach (`coach-baseline.json`, indent
    /// 2, through `coach-baseline.json.tmp`). It runs after `process`, never during a call.
    @discardableResult
    public static func refreshBaseline(_ outputDir: URL, userName: String, stores: StorePaths = .current(),
                                       cache: Cache = .shared, now: Date = Date()) throws -> JSONValue {
        let base = try baseline(history(outputDir, userName: userName, limit: BASELINE_MEETINGS, stores: stores, cache: cache))
        let path = baselinePath(stores: stores)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PythonJSON.write(.object([("computed_at", .string(Py.isoNow(timespec: "seconds", now: now))), ("baseline", base)]),
                             to: path, indent: 2, ensureAscii: true, via: path.lastPathComponent + ".tmp")
        return base
    }

    /// The saved baseline; nil before the first `process` wrote one.
    public static func loadBaseline(stores: StorePaths = .current()) -> JSONValue? {
        guard let base = PythonJSON.read(baselinePath(stores: stores))?["baseline"], case .object = base else { return nil }
        return base
    }
}
