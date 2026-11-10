// Split a recording that ran into the next meeting, and join two that belong together (cutting.py, issue #40).
//
// Back-to-back calls run into each other: the recording of one meeting goes on into the next. `split` cuts a recording
// at a moment; the part after becomes a recording of its own. `join` puts two recordings together: the part that
// belongs to the next meeting, or a meeting split by a dropped call. They undo each other. Both work on the files a
// processed recording has: the three audio tracks, segments, speaker turns, the transcript, and per-label names, merges
// and voices. The calendar event, names given by hand and projects stay with the recording that keeps the meeting's
// identity. A recording joined into another is moved to `.trash` in the recordings folder, never deleted. And the
// suggestions: where a recording seems to run into the next meeting (`suggestCut`), long silence at either end
// (`suggestTrim`).
//
// Times read from the files keep Python's int or float (`PyNum`), so what is written back is what Python writes. The
// speaker files a split or join writes are written under both meetings' locks (`StoreLock.both`, pair order); the
// user's own notes then take their own (`MyNotes`).
import Darwin
import Foundation
import PalaverCore

/// What cutting.py raises: ValueError (a cut out of range, a side that is neither), KeyError (a file without a key it
/// needs), TypeError (a file of another shape).
public struct CuttingError: Error, CustomStringConvertible {
    public enum Kind: Sendable { case value, key, type }
    public let kind: Kind
    public let description: String
    public init(_ kind: Kind, _ description: String) {
        self.kind = kind
        self.description = description
    }
}

public enum Cutting {
    public static let SAMPLE_RATE = 16_000
    /// A recording this soon after another one ended is "the next" one (`timedelta(minutes=30)`), in seconds.
    public static let NEXT_WITHIN = 30.0 * 60
    /// A voice in the joined part this alike to one in the kept part is the same person.
    public static let SAME_VOICE = 0.75
    public static let TRASH = ".trash"
    /// Silence before the first word or after the last worth offering to remove (a call joined early, a recording
    /// left running), and what is kept of it.
    public static let SILENCE_TRIM = 120.0
    public static let SILENCE_PAD = 2.0
    // Around the next event's start: where to look for voices that come or go, and for a pause to cut at.
    public static let BOUNDARY_WINDOW = 300.0
    /// Seconds after the boundary: a voice of the next meeting ...
    public static let NEW_VOICE_TALK = 20.0
    /// ... with less than this before it.
    public static let OLD_VOICE_TALK = 5.0

    static let _DATA: [KeyPath<RecordingPaths, URL>] = [\.micSegments, \.systemSegments, \.systemTurns, \.transcriptJson]
    // `_LABEL`, built once.
    static let _LABEL = try! PyRegex(#"^SPEAKER_(\d+)$"#)
    /// What a recording consists of, as opposed to what makes it a meeting (calendar event, the user's title, notes,
    /// review, Notion page, project assignments by folder name), which stays in its folder.
    static let _CONTENT: [KeyPath<RecordingPaths, URL>] = [
        \.micRawWav, \.micWav, \.systemWav, \.meta, \.language, \.transcriptMd, \.speakerEmbeddings, \.speakers,
        \.speakersAuto, \.speakersMerged, \.speakersIgnored, \.speakersInferred, \.speakersRejected, \.speakersUnknown,
        \.transcription, _LINES,
    ] + _DATA
    /// Lines said to be someone else's (#12): by time like the data, kept only while there are any.
    static let _LINES: KeyPath<RecordingPaths, URL> = \.speakersLines
    // While a join rewrites the kept recording, what it was is kept here; a join that dies half-way is undone (or,
    // past "done", finished) the next time.
    static let _BACKUP = ".join-backup"
    static let _DONE = "done"
    /// What `_backup` keeps of the kept recording.
    static let BACKED_UP: [KeyPath<RecordingPaths, URL>] = _CONTENT + [\.calendar, \.title, \.review, \.myNotes, \.speakersShared]

    static func tracks(_ paths: RecordingPaths) -> [URL] { [paths.micRawWav, paths.micWav, paths.systemWav] }

    // MARK: - span

    /// When the recording started, and how long it is (seconds), from meta.json. A duration that is no finite number
    /// is a `CuttingError(.value)`.
    public static func span(_ paths: RecordingPaths) throws -> (start: PyDateTime, duration: Double) {
        let meta = try object(PythonJSON.read(paths.meta) ?? .object([]), "meta.json")
        guard let startValue = meta["start_time"] else { throw CuttingError(.key, "'start_time'") }
        guard case .string(let startText) = startValue else { throw CuttingError(.type, "fromisoformat: argument must be str") }
        let start: PyDateTime
        do { start = try PyDateTime.parse(startText) } catch { throw CuttingError(.value, "\(error)") }
        guard let durationValue = meta["duration_seconds"] else { throw CuttingError(.key, "'duration_seconds'") }
        guard let duration = VoiceMath.pyFloat(durationValue) else {
            if case .string = durationValue { throw CuttingError(.value, "could not convert string to float") }
            throw CuttingError(.type, "float() argument must be a string or a real number")
        }
        // NaN or infinity: Python fails later, converting a time to an int; here, before anything is computed from it.
        guard duration.isFinite else {
            throw CuttingError(.value, "cannot convert float \(duration.isNaN ? "NaN" : "infinity") to integer")
        }
        return (start, duration)
    }

    // MARK: - split

    /// Cut the recording `at` seconds; returns the new recording of what came after. What came before stays where it
    /// is. `at` as the caller got it: an int stays one in what is written (as in Python).
    @discardableResult
    public static func split(_ paths: RecordingPaths, at: PyNum) throws -> RecordingPaths {
        let (start, duration) = try span(paths)
        guard 1.0 <= at.double && at.double <= duration - 1.0 else {
            let minutes = Int(((duration - pyMod(duration, 60)) / 60).rounded())
            throw CuttingError(.value, "cut between 0:01 and \(minutes):\(String(format: "%02d", Int(pyMod(duration, 60)) - 1))")
        }
        let cutAt = try start.adding(seconds: at.double)
        // Named by the cut's wall time in its own offset (`strftime` of the aware datetime).
        let wall = PyDateTime(micros: cutAt.micros + Int64(cutAt.offset ?? 0) * 1_000_000, offset: 0)
        let tail = RecordingPaths(try RecordingPaths.newRecordingFolder(
            root: paths.folder.deletingLastPathComponent(), now: wall.date, timeZone: TimeZone(secondsFromGMT: 0)!))
        for (src, dst) in zip(tracks(paths), tracks(tail)) where exists(src) {
            let info = try Wav16.info(src)
            let cut = Int((at.double * Double(info.rate)).rounded(.toNearestOrEven))
            let w = try Wav16.Writer(dst, rate: info.rate, channels: info.channels)
            defer { w.close() }
            try w.append(from: src, start: cut)
            try w.finish()
            try Wav16.keepFront(src, frames: cut)
        }
        try StoreLock.both(speakersLock(paths), speakersLock(tail)) {
            for name in _DATA {
                guard let items = PythonJSON.read(paths[keyPath: name]), !items.isNull else { continue }
                try write(tail[keyPath: name], .array(try slice(items, at, .float(.infinity), -at)))
                try write(paths[keyPath: name], .array(try slice(items, .float(0), at, .float(0))))
            }
            if exists(paths.speakersLines) {
                let fixes = JSONValue.array(Speakers.loadLineSpeakers(paths))
                try writeLines(tail, try slice(fixes, at, .float(.infinity), -at))
                try writeLines(paths, try slice(fixes, .float(0), at, .float(0)))
            }
            let files = try labelFiles(paths)
            try keepLabels(paths, files, head: true)
            try keepLabels(tail, files, head: false)
        }
        var meta = try object(PythonJSON.read(paths.meta) ?? .object([]), "meta.json")
        let gaps = try list(meta.removeValue(forKey: "gaps"), "gaps")
        let problems = try problemSpans(meta, .float(duration))
        let cutTime = JSONValue.string(cutAt.iso)
        var tailMeta = meta
        tailMeta["start_time"] = cutTime
        tailMeta["duration_seconds"] = PyNum.float(duration - at.double).rounded(3).json
        tailMeta["trigger"] = .string("split")
        try write(tail.meta, withGaps(tailMeta, try movedGaps(gaps, at, .float(.infinity), -at),
                                      try movedProblems(problems, at, .float(.infinity), -at)).json)
        var head = meta
        head.removeValue(forKey: "stop_reason")  // it did not stop: it goes on in the tail
        head["end_time"] = cutTime
        head["duration_seconds"] = at.rounded(3).json
        try write(paths.meta, withGaps(head, try movedGaps(gaps, .float(0), at, .float(0)),
                                       try movedProblems(problems, .float(0), at, .float(0))).json)
        try MyNotes.split(paths.folder, tail.folder, at: at.double)  // what the user wrote after the cut goes along
        // A meeting kept on this Mac: both parts are; who transcribed it (#54): both parts.
        for carried in [\RecordingPaths.language, \.localOnly, \.transcription] where exists(paths[keyPath: carried]) {
            try copy2(paths[keyPath: carried], tail[keyPath: carried])
        }
        for stale in [paths.review, paths.speakersInferred] { try unlink(stale) }
        return tail
    }

    /// `_keep_labels`: the per-label files of the original (`files`), for the labels this part's turns have.
    private static func keepLabels(_ paths: RecordingPaths, _ files: LabelFiles, head: Bool) throws {
        let labels = Set(try turnSpeakers(paths).map(ScalarKey.init))
        func kept(_ d: PyDict<JSONValue>) -> PyDict<JSONValue> {
            PyDict(d.filter { labels.contains(ScalarKey($0.key)) }.map { ($0.key, $0.value) })
        }
        try write(paths.speakerEmbeddings, kept(files.embeddings).json)
        try writeOrRemove(paths.speakers, kept(files.speakers))
        try writeOrRemove(paths.speakersAuto, kept(files.speakersAuto))
        try writeOrRemove(paths.speakersMerged, PyDict(files.merged.filter { k, v in
            guard case .string(let into) = v else { return false }
            return labels.contains(ScalarKey(k)) && labels.contains(ScalarKey(into))
        }.map { ($0.key, $0.value) }))
        for (url, all) in [(paths.speakersIgnored, files.ignored), (paths.speakersUnknown, files.unknown)] {
            let some = sortedSet(all.filter { labels.contains(ScalarKey($0)) })
            if some.isEmpty { try unlink(url) } else { try write(url, .strings(some)) }
        }
        try writeOrRemove(paths.speakersRejected, kept(files.rejected))
        try unlink(paths.speakersShared)
        try SharedMic.save(paths, SharedMic.splitPart(files.shared, labels: labels, head: head))
    }

    // MARK: - trash, discard

    /// Move a recording to `.trash` in the recordings folder (`-2`, `-3`, … if the name is taken); returns where it
    /// went.
    @discardableResult
    public static func trash(_ paths: RecordingPaths) throws -> URL {
        let bin = paths.folder.deletingLastPathComponent().appendingPathComponent(TRASH, isDirectory: true)
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: bin.path, isDirectory: &isDir) || !isDir.boolValue {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        }
        let name = paths.folder.lastPathComponent
        var target = bin.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while exists(target) {  // an earlier one with this name is still in there
            target = bin.appendingPathComponent("\(name)-\(n)", isDirectory: true)
            n += 1
        }
        if Darwin.rename(paths.folder.path, target.path) != 0 {
            guard errno == EXDEV else { throw posixError(paths.folder.path) }
            try FileManager.default.moveItem(at: paths.folder, to: target)  // another volume: copied, then removed
        }
        return target
    }

    /// Throw away what came `"after"` or `"before"` the moment `at`; the meeting keeps the rest. Returns where the
    /// discarded part went.
    @discardableResult
    public static func discard(_ paths: RecordingPaths, at: PyNum, side: String) throws -> URL {
        guard side == "after" || side == "before" else {
            throw CuttingError(.value, "discard 'after' or 'before', not \(MyNotes.pyRepr(.string(side)))")
        }
        let tail = try split(paths, at: at)
        if side == "before" {
            // The meeting is what came after: its files go to the meeting's folder, the rooms among its voices too; the
            // meeting's own marks stay.
            try StoreLock.both(speakersLock(paths), speakersLock(tail)) {
                var marks = SharedMic.load(paths)
                marks["lanes"] = SharedMic.load(tail)["lanes"]
                try SharedMic.save(paths, marks)
                for name in _CONTENT {
                    let mine = paths[keyPath: name], theirs = tail[keyPath: name]
                    let swap = theirs.deletingLastPathComponent().appendingPathComponent(theirs.lastPathComponent + ".swap")
                    if exists(mine) { try rename(mine, swap) }
                    if exists(theirs) { try rename(theirs, mine) }
                    if exists(swap) { try rename(swap, theirs) }
                }
            }
        }
        return try trash(tail)
    }

    // MARK: - join

    /// The one of two recordings that `join` keeps: the longer one (the earlier one if they are as long).
    public static func keeper(_ first: RecordingPaths, _ second: RecordingPaths) throws -> RecordingPaths {
        var (first, second) = (first, second)
        let (aStart, aLength) = try span(first), (bStart, bLength) = try span(second)
        var (aLen, bLen) = (aLength, bLength)
        if try earlier(bStart, aStart) {
            swap(&first, &second)
            swap(&aLen, &bLen)
        }
        return aLen >= bLen ? first : second
    }

    /// Put two recordings together, in the order they were recorded. The longer one keeps the meeting (its folder,
    /// calendar event, notes, names), or `keep`; the other is moved to the trash. With `gapWhy` the stretch between
    /// them is marked in meta.json as a gap nothing was recorded in (e.g. "restart"). Returns the joined recording.
    /// What the kept recording was is backed up first (`.join-backup`): a failure puts it back, and a join killed
    /// half-way is undone, or finished, by the next `finishUnfinishedJoin`.
    @discardableResult
    public static func join(_ first: RecordingPaths, _ second: RecordingPaths, keep chosen: RecordingPaths? = nil,
                            gapWhy: String? = nil) throws -> RecordingPaths {
        for paths in [first, second] { try finishUnfinishedJoin(paths) }
        var (first, second) = (first, second)
        var (aStart, aLen) = try span(first), (bStart, bLen) = try span(second)
        if try earlier(bStart, aStart) {
            swap(&first, &second)
            swap(&aStart, &bStart)
            swap(&aLen, &bLen)
        }
        let offset = bStart.seconds(since: aStart)
        let aKeep = offset < aLen ? offset : aLen  // an overlap: the second recording has that part
        let gap = offset - aKeep
        let keepsFirst: Bool
        if let chosen { keepsFirst = same(chosen.folder, first.folder) } else { keepsFirst = same(try keeper(first, second).folder, first.folder) }
        let (keep, other) = keepsFirst ? (first, second) : (second, first)
        let backup = try makeBackup(keep, other)
        do {
            for (aTrack, bTrack, kTrack) in zip3(tracks(first), tracks(second), tracks(keep)) where exists(aTrack) || exists(bTrack) {
                let aInfo = try exists(aTrack) ? Wav16.info(aTrack) : nil, bInfo = try exists(bTrack) ? Wav16.info(bTrack) : nil
                guard (aInfo?.channels ?? 1) == 1 && (bInfo?.channels ?? 1) == 1 else {
                    throw CuttingError(.value, "all the input arrays must have same number of dimensions")
                }
                let n = Int((aKeep * Double(SAMPLE_RATE)).rounded(.toNearestOrEven))
                let tmp = kTrack.deletingLastPathComponent().appendingPathComponent(kTrack.lastPathComponent + ".joining")
                let w = try Wav16.Writer(tmp, rate: SAMPLE_RATE)
                defer { w.close() }
                let fromA = min(n, aInfo?.frames ?? 0)
                if aInfo != nil { try w.append(from: aTrack, frames: fromA) }
                try w.appendZeros(n - fromA)  // a track that ended early
                try w.appendZeros(Int((gap * Double(SAMPLE_RATE)).rounded(.toNearestOrEven)))
                if bInfo != nil { try w.append(from: bTrack) }
                try w.finish()
                try rename(tmp, kTrack)  // a track is the old one or the joined one, never half of it
            }

            try StoreLock.both(speakersLock(first), speakersLock(second)) {
                let relabel = relabeling(try labels(other), try labels(keep))
                for name in _DATA {
                    var aItems = try slice(PythonJSON.read(first[keyPath: name]) ?? .array([]), .float(0), .float(aKeep), .float(0))
                    var bItems = try slice(PythonJSON.read(second[keyPath: name]) ?? .array([]), .float(0), .float(.infinity), .float(offset))
                    if same(other.folder, first.folder) { aItems = aItems.map { renamed($0, relabel) } } else { bItems = bItems.map { renamed($0, relabel) } }
                    let all = try Py.stableSorted(aItems + bItems) { try num($0["start"], "start") < num($1["start"], "start") }
                    try write(keep[keyPath: name], .array(all))
                }
                var aFixes = try slice(.array(Speakers.loadLineSpeakers(first)), .float(0), .float(aKeep), .float(0))
                var bFixes = try slice(.array(Speakers.loadLineSpeakers(second)), .float(0), .float(.infinity), .float(offset))
                if same(other.folder, first.folder) { aFixes = aFixes.map { renamed($0, relabel) } } else { bFixes = bFixes.map { renamed($0, relabel) } }
                try writeLines(keep, aFixes + bFixes)
                try joinLabels(keep, other, relabel)
            }

            var meta = try object(PythonJSON.read(keep.meta) ?? .object([]), "meta.json")
            let aMeta = try object(PythonJSON.read(first.meta) ?? .object([]), "meta.json")
            let bMeta = try object(PythonJSON.read(second.meta) ?? .object([]), "meta.json")
            var gaps = try movedGaps(list(aMeta["gaps"], "gaps"), .float(0), .float(aKeep), .float(0))
                + movedGaps(list(bMeta["gaps"], "gaps"), .float(0), .float(.infinity), .float(offset))
            if let gapWhy, !gapWhy.isEmpty, gap > 0 {
                gaps.append(PyDict([("start", .double(Py.round(aKeep, 3))), ("end", .double(Py.round(offset, 3))), ("why", .string(gapWhy))]))
            }
            let problems = try movedProblems(problemSpans(aMeta, .float(aKeep)), .float(0), .float(aKeep), .float(0))
                + movedProblems(problemSpans(bMeta, .float(bLen)), .float(0), .float(.infinity), .float(offset))
            // How the meeting ended is how its later part ended.
            meta.removeValue(forKey: "stop_reason")
            meta["start_time"] = .string(aStart.iso)
            meta["duration_seconds"] = .double(Py.round(offset + bLen, 3))
            for key in ["end_time", "stop_reason"] { if let v = bMeta[key], v.truthy { meta[key] = v } }
            try write(keep.meta, withGaps(meta, gaps, problems).json)
            // The other's calendar decision, unless the kept one has a calendar.json this code cannot read: never
            // overwritten (Python may read it as the user's own decision).
            if exists(other.calendar) && !CalendarEvents.storedButUnreadable(keep) && theirEventWins(keep, other) {
                try copy2(other.calendar, keep.calendar)
            }
            if !exists(keep.localOnly) && exists(other.localOnly) { try copy2(other.localOnly, keep.localOnly) }  // kept on this Mac if either part was
            if !exists(keep.title) && exists(other.title) { try copy2(other.title, keep.title) }  // the user's title, whichever part had it
            // The user's own notes of both parts (#44), on the joined clock.
            try MyNotes.join(first.folder, second.folder, keep: keep.folder, offset: offset)
            if let joined = try joinedTranscription(first, second) { try write(keep.transcription, joined) }
            for stale in [keep.review, keep.speakersInferred] { try unlink(stale) }
            try writeText("", backup.appendingPathComponent(_DONE))
        } catch {
            if !exists(backup.appendingPathComponent(_DONE)) {
                try restore(backup, keep)  // the kept recording as it was; the other one untouched
            }
            throw error
        }
        try trash(other)
        try? FileManager.default.removeItem(at: backup)
        return keep
    }

    /// The per-label files of `other` (relabeled) joined into `keep`'s; the same voice in both parts merged.
    private static func joinLabels(_ keep: RecordingPaths, _ other: RecordingPaths, _ relabel: PyDict<String>) throws {
        let kept = try labelFiles(keep), theirs = try labelFiles(other)
        func moved(_ k: String) -> String { relabel[k] ?? k }
        var embeddings = kept.embeddings
        for (k, v) in theirs.embeddings { if let label = relabel[k] { embeddings[label] = v } }
        try write(keep.speakerEmbeddings, embeddings.json)
        for (url, mine, their) in [(keep.speakers, kept.speakers, theirs.speakers), (keep.speakersAuto, kept.speakersAuto, theirs.speakersAuto)] {
            // label → name; a label mapped to itself is a rejected name and moves along.
            var all = mine, any = false
            for (k, v) in their {
                if case .string(let s) = v, Py.same(s, k) { all[moved(k)] = .string(moved(k)) } else { all[moved(k)] = v }
                any = true
            }
            if !mine.isEmpty || any { try write(url, all.json) }
        }
        var merges = kept.merged
        for (k, v) in theirs.merged {
            if case .string(let into) = v { merges[moved(k)] = .string(moved(into)) } else { merges[moved(k)] = v }
        }
        // The same person in both parts is one speaker: merge by voice.
        var keptVoices: [(String, [Double])] = []
        for (k, v) in kept.embeddings where kept.merged[k] == nil { keptVoices.append((k, VoiceMath.unit(try vector(v)))) }
        for label in relabel.values {
            guard merges[label] == nil, let voice = embeddings[label], !keptVoices.isEmpty else { continue }
            let unit = VoiceMath.unit(try vector(voice))
            var best: (sim: Double, label: String)?
            for (k, v) in keptVoices {
                let sim = try VoiceMath.dot(unit, v)
                // max() over (sim, label) tuples: a higher similarity, or as high and a later label.
                if let b = best, !(sim > b.sim || (sim == b.sim && Py.less(b.label, k))) { continue }
                best = (sim, k)
            }
            if let best, best.sim >= SAME_VOICE { merges[label] = .string(best.label) }
        }
        if !merges.isEmpty { try write(keep.speakersMerged, merges.json) }
        for (url, mine, their) in [(keep.speakersIgnored, kept.ignored, theirs.ignored), (keep.speakersUnknown, kept.unknown, theirs.unknown)] {
            let all = sortedSet(mine + their.map(moved))
            if !all.isEmpty { try write(url, .strings(all)) }
        }
        var rejected = kept.rejected
        for (k, v) in theirs.rejected { rejected[moved(k)] = v }
        if !rejected.isEmpty { try write(keep.speakersRejected, rejected.json) }
        try SharedMic.joinFrom(keep, theirs.shared, relabel: relabel)
        try SharedMic.followMerges(keep)  // a room merged into a voice by its voice makes that voice the room
    }

    /// `_backup`: what `keep` is now, in `.join-backup` (a track hard-linked: it is replaced by a rename, never
    /// written into), and last `files.json` naming them and the other recording.
    static func makeBackup(_ keep: RecordingPaths, _ other: RecordingPaths) throws -> URL {
        let backup = keep.folder.appendingPathComponent(_BACKUP, isDirectory: true)
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        var files: [String] = []
        let trackNames = Set(tracks(keep).map(\.lastPathComponent))
        try StoreLock.meeting(keep) {
            for name in BACKED_UP {
                let f = keep[keyPath: name]
                guard exists(f) else { continue }
                let copy = backup.appendingPathComponent(f.lastPathComponent)
                // A track is replaced by a rename, never written into: a link keeps the old one.
                let linked = trackNames.contains(f.lastPathComponent) && Darwin.link(f.path, copy.path) == 0
                if !linked { try copy2(f, copy) }
                files.append(f.lastPathComponent)
            }
        }
        // Written last: a backup without it is incomplete, and nothing was changed yet.
        try PythonJSON.write(.object([("files", .strings(files)), ("other", .string(other.folder.lastPathComponent))]),
                             to: backup.appendingPathComponent("files.json"), indent: nil, ensureAscii: true, via: "files.json.tmp")
        return backup
    }

    /// `_restore`: the backed-up files put back, the ones the recording did not have removed (and any half-written
    /// `.joining` track), the backup gone.
    private static func restore(_ backup: URL, _ paths: RecordingPaths) throws {
        let record = try backupRecord(backup)
        let kept = Set(try list(record["files"], "files").compactMap(\.stringValue).map(ScalarKey.init))
        try StoreLock.meeting(paths) {
            for name in BACKED_UP {
                let f = paths[keyPath: name]
                if kept.contains(ScalarKey(f.lastPathComponent)) {
                    try rename(backup.appendingPathComponent(f.lastPathComponent), f)
                } else {
                    try unlink(f)
                }
                try unlink(f.deletingLastPathComponent().appendingPathComponent(f.lastPathComponent + ".joining"))
            }
        }
        try? FileManager.default.removeItem(at: backup)
    }

    private static func backupRecord(_ backup: URL) throws -> PyDict<JSONValue> {
        let url = backup.appendingPathComponent("files.json")
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw posixError(url.path, ENOENT) }
        do { return try object(try PythonJSON.parse(data), "files.json") } catch let e as PythonJSON.ParseError {
            throw CuttingError(.value, e.description)
        }
    }

    /// A join into `paths` that was killed: undo it, or (when all was written and only the other recording was not
    /// moved to the trash yet) finish it.
    public static func finishUnfinishedJoin(_ paths: RecordingPaths) throws {
        let backup = paths.folder.appendingPathComponent(_BACKUP, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: backup.path, isDirectory: &isDir), isDir.boolValue else { return }
        guard exists(backup.appendingPathComponent("files.json")) else {
            try? FileManager.default.removeItem(at: backup)  // killed while backing up: nothing changed
            return
        }
        if exists(backup.appendingPathComponent(_DONE)) {
            guard case .string(let name)? = try backupRecord(backup)["other"] else { throw CuttingError(.key, "'other'") }
            let other = paths.folder.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: other.path, isDirectory: &isDir), isDir.boolValue {
                try trash(RecordingPaths(other))
            }
            try? FileManager.default.removeItem(at: backup)
            return
        }
        try restore(backup, paths)
    }

    /// `_joined_transcription`: who transcribed the joined meeting, track by track (#54): who did both parts, or
    /// "mixed" (never sent to a service again). nil when neither part says.
    private static func joinedTranscription(_ first: RecordingPaths, _ second: RecordingPaths) throws -> JSONValue? {
        func marker(_ p: RecordingPaths) throws -> PyDict<JSONValue> {
            guard let v = PythonJSON.read(p.transcription), v.truthy else { return PyDict() }
            return try object(v, "transcription.json")
        }
        let a = try marker(first), b = try marker(second)
        let now = JSONValue.string(Py.isoNow(timespec: "seconds"))
        var out: [(String, JSONValue)] = []
        for track in sortedSet(a.keys + b.keys) {
            func part(_ d: PyDict<JSONValue>) throws -> PyDict<JSONValue> {
                guard let v = d[track], v.truthy else { return PyDict() }
                return try object(v, "a track's marker")
            }
            let x = try part(a), y = try part(b)
            var joined = PyDict<JSONValue>()
            if let engine = x["engine"], engine.truthy, PythonJSON.equal(engine, y["engine"] ?? .null), !PythonJSON.equal(engine, .string("mixed")) {
                joined["engine"] = engine
                if let model = x["model"], model.truthy, PythonJSON.equal(model, y["model"] ?? .null) { joined["model"] = model }
                for n in ["sent_seconds", "usd"] {
                    if let p = PyNum(x[n]), let q = PyNum(y[n]) { joined[n] = (p + q).rounded(4).json }
                }
                if let from = x["fallback_from"], from.truthy, PythonJSON.equal(from, y["fallback_from"] ?? .null) { joined["fallback_from"] = from }
            } else {
                joined["engine"] = .string("mixed")
                joined["parts"] = .array([x["engine"] ?? .null, y["engine"] ?? .null])
            }
            joined["at"] = now
            out.append((track, joined.json))
        }
        return out.isEmpty ? nil : .object(out)
    }

    /// `_by_you`: the recording's calendar decision is the user's: an event chosen, or none.
    private static func byYou(_ paths: RecordingPaths) -> Bool {
        CalendarEvents.dismissed(paths) || CalendarEvents.loadLink(paths)?.byYou == true
    }

    /// The other recording's calendar decision goes to the joined one: when the kept one has none, or the other's is
    /// the user's and the kept one's is not (an open question, a time match).
    private static func theirEventWins(_ keep: RecordingPaths, _ other: RecordingPaths) -> Bool {
        !exists(keep.calendar) || (byYou(other) && !byYou(keep))
    }

    // MARK: - neighbours

    /// The recordings just before and just after this one (ended or started within NEXT_WITHIN, a minute of overlap
    /// allowed), by folder name; only processed ones (with a transcript).
    public static func neighbours(_ paths: RecordingPaths) throws -> (previous: String?, next: String?) {
        let (start, duration) = try span(paths)
        let end = try start.adding(seconds: duration)
        var before: String?, after: String?
        let root = paths.folder.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in Py.stableSorted(names, by: Py.less) {
            guard !Py.same(name, paths.folder.lastPathComponent), RecordingPaths.isRecordingFolderName(name) else { continue }
            let other = RecordingPaths(root.appendingPathComponent(name, isDirectory: true))
            guard let (oStart, oLen) = try? span(other) else { continue }
            guard exists(other.transcriptJson) else { continue }
            let window = -60_000_000...Int64(NEXT_WITHIN * 1_000_000)
            if try window.contains(micros(oStart, minus: end)) && after == nil { after = name }
            let oEnd = try oStart.adding(seconds: oLen)
            if try window.contains(micros(start, minus: oEnd)) { before = name }
        }
        return (before, after)
    }

    // MARK: - suggestions

    /// Long silence before the first word or after the last: where to cut it off ("start": everything before `at`
    /// goes; "end": everything after). [] when there is none, or the user said no before.
    public static func suggestTrim(_ paths: RecordingPaths) throws -> [JSONValue] {
        let lines = PythonJSON.read(paths.transcriptJson) ?? .array([])
        if exists(paths.silenceDismissed) || !lines.truthy { return [] }
        let (_, duration) = try span(paths)
        var first: PyNum?, last: PyNum?
        for d in try iterate(lines) {
            let item = try object(d, "a transcript line")
            let s = try num(item["start"], "start"), e = try num(item["end"], "end")
            if first == nil || s < first! { first = s }
            if last == nil || e > last! { last = e }
        }
        var out: [JSONValue] = []
        if let first, first.double - SILENCE_PAD >= SILENCE_TRIM {
            let at = Py.round(first.double - SILENCE_PAD, 2)
            out.append(.object([("edge", .string("start")), ("at", .double(at)), ("seconds", .double(at))]))
        }
        if let last, duration - last.double - SILENCE_PAD >= SILENCE_TRIM {
            let at = Py.round(last.double + SILENCE_PAD, 2)
            out.append(.object([("edge", .string("end")), ("at", .double(at)), ("seconds", .double(Py.round(duration - at, 2)))]))
        }
        return out
    }

    private struct Turn {
        let speaker: String
        let start: PyNum
        let end: Double
    }

    /// `_talk`: seconds each voice talks in [lo, hi], in order of first appearance.
    private static func talk(_ turns: [Turn], _ lo: Double, _ hi: Double) -> PyDict<Double> {
        var out = PyDict<Double>()
        for t in turns {
            let overlap = min(t.end, hi) - max(t.start.double, lo)
            if overlap > 0 { out[t.speaker] = (out[t.speaker] ?? 0) + overlap }
        }
        return out
    }

    /// `_longest_pause`: the middle of the longest stretch in [lo, hi] when nobody spoke.
    private static func longestPause(_ spans: [(Double, Double)], _ lo: Double, _ hi: Double) -> Double? {
        var clipped: [(Double, Double)] = []
        for (s, e) in spans where e > lo && s < hi { clipped.append((max(s, lo), min(e, hi))) }
        let inside = Py.stableSorted(clipped) { (a: (Double, Double), b: (Double, Double)) -> Bool in
            a.0 < b.0 || (a.0 == b.0 && a.1 < b.1)
        }
        var best = 0.0, at: Double?, cursor = lo
        for (s, e) in inside {
            if s - cursor > best { (best, at) = (s - cursor, (cursor + s) / 2) }
            cursor = max(cursor, e)
        }
        if hi - cursor > best { at = (cursor + hi) / 2 }
        return at
    }

    /// Where the recording seems to run into another meeting: an event that starts while it records, around which
    /// voices come or go. nil if nothing looks like it, or the user said no before, or its calendar.json is one this
    /// code cannot read (its own event unknown, any event could look like the next).
    public static func suggestCut(_ paths: RecordingPaths, events: [CalendarEvent]) throws -> JSONValue? {
        if exists(paths.cutDismissed) || CalendarEvents.storedButUnreadable(paths) { return nil }
        let (start, duration) = try span(paths)
        let own = CalendarEvents.load(paths)
        let merges = Speakers.loadMerges(paths), ignored = Set(Speakers.loadIgnored(paths).map(ScalarKey.init))
        var turnItems: [(speaker: String, item: PyDict<JSONValue>)] = []
        for t in try iterate(PythonJSON.read(paths.systemTurns) ?? .array([])) {
            let d = try object(t, "a turn")
            guard let raw = d["speaker"] else { throw CuttingError(.key, "'speaker'") }
            guard case .string(let label) = raw else { throw CuttingError(.type, "a turn's speaker is no label") }
            let speaker = merges[label] ?? label
            if !ignored.contains(ScalarKey(speaker)) { turnItems.append((speaker, d)) }
        }
        let names = try Speakers.namesInEffect(paths)
        var later: [CalendarEvent] = []
        for e in events where !e.allDay {
            if let own, !(!Py.same(e.key, own.key) || e.key.isEmpty) { continue }
            if let own, !(try earlier(own.start, e.start)) { continue }
            guard e.attendees.contains(where: { !$0.isSelf && !$0.isRoom }) else { continue }
            let b = Double(try micros(e.start, minus: start)) / 1_000_000
            if 60 < b && b < duration - 60 { later.append(e) }
        }
        if later.isEmpty { return nil }
        // Times are read where Python reads them: the turns' for the first event, the rest when a cut needs them.
        let turns = try turnItems.map { Turn(speaker: $0.speaker, start: try num($0.item["start"], "start"), end: try num($0.item["end"], "end").double) }
        func spans() throws -> [(Double, Double)] {
            try turns.map { ($0.start.double, $0.end) } + iterate(PythonJSON.read(paths.micSegments) ?? .array([])).map {
                let d = try object($0, "a segment")
                return (try num(d["start"], "start").double, try num(d["end"], "end").double)
            }
        }
        func lineStarts() throws -> [PyNum] {
            try iterate(PythonJSON.read(paths.transcriptJson) ?? .array([])).map { try num(object($0, "a line")["start"], "start") }
        }
        for event in Py.stableSorted(later, by: { $0.start < $1.start }) {
            let b = Double(try micros(event.start, minus: start)) / 1_000_000
            let before = talk(turns, 0, b - BOUNDARY_WINDOW / 2)
            let after = talk(turns, b - BOUNDARY_WINDOW / 2, duration)
            let new = after.filter { $0.value >= NEW_VOICE_TALK && (before[$0.key] ?? 0) < OLD_VOICE_TALK }.map(\.key)
            let afterwards = talk(turns, b + 60, duration)
            let gone = before.filter { $0.value >= NEW_VOICE_TALK && (afterwards[$0.key] ?? 0) < OLD_VOICE_TALK }.map(\.key)
            if new.isEmpty && gone.isEmpty { continue }
            let firsts = new.compactMap { s in firstMin(turns.filter { Py.same($0.speaker, s) }.map(\.start)) }
                .filter { b - BOUNDARY_WINDOW <= $0.double && $0.double <= b + 2 * BOUNDARY_WINDOW }
            guard var at = try firstMin(firsts) ?? longestPause(spans(), b - BOUNDARY_WINDOW, b + BOUNDARY_WINDOW).map(PyNum.float)
            else { continue }
            // At the start of a transcript line, where the window can cut.
            if let first = firstMin(try lineStarts().filter { $0.double >= (at - 5).double }) { at = first }
            if at.double < 30 || duration - at.double < 30 { continue }
            func who(_ labels: [String]) -> String {
                labels.map { s in
                    if let name = names[s], !name.isEmpty { return name }
                    if let digits = _LABEL.firstMatch(in: s)?.group(1), let n = decimal(digits) { return "Speaker \(n + 1)" }
                    return s
                }.joined(separator: ", ")
            }
            var why: [String] = []
            if !new.isEmpty { why.append("new \(new.count == 1 ? "voice" : "voices") from then on: \(who(new))") }
            if !gone.isEmpty { why.append("\(who(gone)) stopped talking") }
            return .object([("at", at.rounded(2).json), ("event", .string(event.title)), ("event_start", .string(event.start.iso)),
                            ("why", .string(why.joined(separator: "; ")))])
        }
        return nil
    }

    // MARK: - The per-label files

    private struct LabelFiles {
        var embeddings, speakers, speakersAuto, merged, rejected, shared: PyDict<JSONValue>
        var ignored, unknown: [String]
    }

    /// `_per_label_files`.
    private static func labelFiles(_ paths: RecordingPaths) throws -> LabelFiles {
        func dict(_ url: URL) throws -> PyDict<JSONValue> { try object(PythonJSON.read(url) ?? .object([]), url.lastPathComponent) }
        func labels(_ url: URL) throws -> [String] {
            switch PythonJSON.read(url) ?? .array([]) {
            case .array(let items): return items.compactMap(\.stringValue)
            case .object(let fields): return fields.map(\.0)
            default: throw CuttingError(.type, "\(url.lastPathComponent) is no list of labels")
            }
        }
        return LabelFiles(embeddings: try dict(paths.speakerEmbeddings), speakers: try dict(paths.speakers),
                          speakersAuto: try dict(paths.speakersAuto), merged: try dict(paths.speakersMerged),
                          rejected: try dict(paths.speakersRejected), shared: SharedMic.load(paths),
                          ignored: try labels(paths.speakersIgnored), unknown: try labels(paths.speakersUnknown))
    }

    /// The labels of the system track's turns.
    private static func turnSpeakers(_ paths: RecordingPaths) throws -> [String] {
        try iterate(PythonJSON.read(paths.systemTurns) ?? .array([])).compactMap { t in
            let d = try object(t, "a turn")
            guard let speaker = d["speaker"] else { throw CuttingError(.key, "'speaker'") }
            return speaker.stringValue
        }
    }

    /// `_labels`: the turns' labels and the voices'.
    private static func labels(_ paths: RecordingPaths) throws -> [String] {
        try turnSpeakers(paths) + object(PythonJSON.read(paths.speakerEmbeddings) ?? .object([]), "speaker_embeddings.json").keys
    }

    /// `_relabel`: new labels for `other`'s speakers, numbered after the kept recording's.
    static func relabeling(_ other: [String], _ kept: [String]) -> PyDict<String> {
        let numbers = kept.compactMap { _LABEL.firstMatch(in: $0)?.group(1).flatMap(decimal) }
        let first = (numbers.max() ?? -1) + 1
        return PyDict(sortedSet(other).enumerated().map { ($0.element, "SPEAKER_" + String(format: "%02d", first + $0.offset)) })
    }

    /// `_write_lines`: the corrections of single lines by start, or no file when there are none.
    private static func writeLines(_ paths: RecordingPaths, _ fixes: [JSONValue]) throws {
        if fixes.isEmpty { return try unlink(paths.speakersLines) }
        try write(paths.speakersLines, .array(try Py.stableSorted(fixes) { try num($0["start"], "start") < num($1["start"], "start") }))
    }

    /// `_renamed`: an item's `speaker`, `label` and `from` (a corrected line's voice) relabeled.
    private static func renamed(_ item: JSONValue, _ relabel: PyDict<String>) -> JSONValue {
        guard var d = PyDict<JSONValue>(item) else { return item }
        for key in ["speaker", "label", "from"] {
            if case .string(let s)? = d[key], let to = relabel[s] { d[key] = .string(to) }
        }
        return d.json
    }

    /// `int(digits)` of a run of Unicode decimal digits (each its place in its run of ten); nil past Int.
    static func decimal(_ digits: String) -> Int? {
        var v = 0
        for u in digits.unicodeScalars {
            guard Py.isDecimal(u) else { return nil }
            var zero = u.value
            while zero > 0, let p = Unicode.Scalar(zero - 1), Py.isDecimal(p) { zero -= 1 }
            let (m, o1) = v.multipliedReportingOverflow(by: 10)
            let (s, o2) = m.addingReportingOverflow(Int((u.value - zero) % 10))
            if o1 || o2 { return nil }
            v = s
        }
        return v
    }

    private static func writeOrRemove(_ url: URL, _ d: PyDict<JSONValue>) throws {
        if d.isEmpty { try unlink(url) } else { try write(url, d.json) }
    }

    // MARK: - Times in the files

    /// `_slice`: segments, turns or utterances starting in [lo, hi), moved by `shift` (their words too, cut at hi).
    static func slice(_ items: JSONValue, _ lo: PyNum, _ hi: PyNum, _ shift: PyNum) throws -> [JSONValue] {
        var out: [JSONValue] = []
        for item in try iterate(items) {
            var d = try object(item, "an item")
            let start = try num(d["start"], "start")
            guard lo <= start && start < hi else { continue }
            let end = try num(d["end"], "end")
            d["start"] = (start + shift).rounded(3).json
            d["end"] = (PyNum.min(end, hi) + shift).rounded(3).json
            if let words = d["words"], words.truthy {
                var moved: [JSONValue] = []
                for word in try iterate(words) {
                    var w = try object(word, "a word")
                    let ws = try num(w["start"], "start")
                    guard ws < hi else { continue }
                    let we = try num(w["end"], "end")
                    w["start"] = (ws + shift).rounded(3).json
                    w["end"] = (PyNum.min(we, hi) + shift).rounded(3).json
                    moved.append(w.json)
                }
                d["words"] = .array(moved)
            }
            out.append(d.json)
        }
        return out
    }

    /// `_moved_gaps`: the part of each gap (a stretch nothing was recorded) in [lo, hi), moved by `shift`.
    static func movedGaps(_ gaps: [JSONValue], _ lo: PyNum, _ hi: PyNum, _ shift: PyNum) throws -> [PyDict<JSONValue>] {
        var out: [PyDict<JSONValue>] = []
        for g in gaps {
            var d = try object(g, "a gap")
            let start = PyNum.max(try num(d["start"], "start"), lo), end = PyNum.min(try num(d["end"], "end"), hi)
            if start < end {
                d["start"] = (start + shift).rounded(3).json
                d["end"] = (end + shift).rounded(3).json
                out.append(d)
            }
        }
        return out
    }

    /// `_problem_spans`: a recording's audio problems as spans; one still open when it was written lasted to its end.
    static func problemSpans(_ meta: PyDict<JSONValue>, _ atStop: PyNum) throws -> [JSONValue] {
        guard let problems = meta["audio_problems"], problems.truthy else { return [] }
        return try iterate(problems).map { p in
            var d = try object(p, "an audio problem")
            if d["end"] == nil || d["end"]!.isNull { d["end"] = atStop.json }
            return d.json
        }
    }

    /// `_moved_problems`: `movedGaps` for audio problems, keeping a zero-length one (a moment) in [lo, hi).
    static func movedProblems(_ problems: [JSONValue], _ lo: PyNum, _ hi: PyNum, _ shift: PyNum) throws -> [PyDict<JSONValue>] {
        var moments: [PyDict<JSONValue>] = [], spans: [JSONValue] = []
        for p in problems {
            var d = try object(p, "an audio problem")
            let start = try num(d["start"], "start"), end = try num(d["end"], "end")
            if start == end && lo <= start && start < hi {
                d["start"] = (start + shift).rounded(3).json
                d["end"] = (end + shift).rounded(3).json
                moments.append(d)
            }
            if start != end { spans.append(p) }
        }
        return try movedGaps(spans, lo, hi, shift) + moments
    }

    /// `_with_gaps`: `meta` with these gaps and audio problems (sorted by start), each left out when there is none.
    static func withGaps(_ meta: PyDict<JSONValue>, _ gaps: [PyDict<JSONValue>], _ problems: [PyDict<JSONValue>]) throws -> PyDict<JSONValue> {
        var out = meta
        out.removeValue(forKey: "gaps")
        out.removeValue(forKey: "audio_problems")
        func sorted(_ items: [PyDict<JSONValue>]) throws -> JSONValue {
            .array(try Py.stableSorted(items) { try num($0["start"], "start") < num($1["start"], "start") }.map(\.json))
        }
        if !gaps.isEmpty { out["gaps"] = try sorted(gaps) }
        if !problems.isEmpty { out["audio_problems"] = try sorted(problems) }
        return out
    }

    // MARK: - Small helpers

    private static func speakersLock(_ paths: RecordingPaths) -> URL { paths.folder.appendingPathComponent(".speakers") }

    private static func object(_ v: JSONValue, _ what: String) throws -> PyDict<JSONValue> {
        guard let d = PyDict<JSONValue>(v) else { throw CuttingError(.type, "\(what) is no JSON object") }
        return d
    }

    /// What `for x in v` goes through: a list's items; nothing for an empty object or string.
    private static func iterate(_ v: JSONValue) throws -> [JSONValue] {
        switch v {
        case .array(let items): return items
        case .object(let f) where f.isEmpty: return []
        case .string(let s) where s.isEmpty: return []
        default: throw CuttingError(.type, "\(PythonJSON.dumps(v).prefix(40)) is no list")
        }
    }

    /// `d.get(key, [])` iterated: a missing key is none.
    private static func list(_ v: JSONValue?, _ what: String) throws -> [JSONValue] {
        guard let v else { return [] }
        return try iterate(v)
    }

    private static func num(_ v: JSONValue?, _ key: String) throws -> PyNum {
        guard let v else { throw CuttingError(.key, "'\(key)'") }
        guard let n = PyNum(v) else { throw CuttingError(.type, "\(key) is no number") }
        return n
    }

    /// The first of the smallest (Python's `min`).
    private static func firstMin(_ values: [PyNum]) -> PyNum? {
        values.reduce(nil) { best, v in best.map { v < $0 ? v : $0 } ?? v }
    }

    /// Python's set of labels, sorted: each once, by code points.
    private static func sortedSet(_ labels: [String]) -> [String] {
        var seen = Set<ScalarKey>()
        return Py.stableSorted(labels.filter { seen.insert(ScalarKey($0)).inserted }, by: Py.less)
    }

    private static func vector(_ v: JSONValue) throws -> [Double] {
        guard case .array(let items) = v else { throw CuttingError(.type, "a voice is no list of numbers") }
        return try items.map { x in
            guard let d = VoiceMath.pyFloat(x) else { throw CuttingError(.value, "a voice is no list of numbers") }
            return d
        }
    }

    /// `a < b` of two datetimes: Python refuses to order a naive one against an aware one.
    private static func earlier(_ a: PyDateTime, _ b: PyDateTime) throws -> Bool {
        guard (a.offset == nil) == (b.offset == nil) else { throw CuttingError(.type, "can't compare offset-naive and offset-aware datetimes") }
        return a < b
    }

    /// `a - b` in microseconds (Python's timedelta).
    private static func micros(_ a: PyDateTime, minus b: PyDateTime) throws -> Int64 {
        guard (a.offset == nil) == (b.offset == nil) else { throw CuttingError(.type, "can't subtract offset-naive and offset-aware datetimes") }
        return a.micros - b.micros
    }

    /// Python's float `%`: the sign of the divisor.
    private static func pyMod(_ x: Double, _ y: Double) -> Double {
        let r = fmod(x, y)
        return r != 0 && (r < 0) != (y < 0) ? r + y : r
    }

    private static func same(_ a: URL, _ b: URL) -> Bool { a.standardizedFileURL.path == b.standardizedFileURL.path }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// `_write`: `json.dumps(data, indent=2, ensure_ascii=False)`, in place.
    private static func write(_ url: URL, _ v: JSONValue) throws { try PythonJSON.write(v, to: url, indent: 2, ensureAscii: false) }

    private static func writeText(_ text: String, _ url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8)) else { throw posixError(url.path) }
    }

    /// `unlink(missing_ok=True)`.
    private static func unlink(_ url: URL) throws {
        if Darwin.unlink(url.path) != 0 && errno != ENOENT { throw posixError(url.path) }
    }

    /// `os.replace`.
    private static func rename(_ from: URL, _ to: URL) throws {
        if Darwin.rename(from.path, to.path) != 0 { throw posixError(from.path) }
    }

    /// `shutil.copy2`: the data, then mode, times, flags and extended attributes; an existing target overwritten.
    private static func copy2(_ from: URL, _ to: URL) throws {
        if copyfile(from.path, to.path, nil, copyfile_flags_t(COPYFILE_ALL)) != 0 { throw posixError(from.path) }
    }

    private static func posixError(_ path: String, _ code: Int32 = errno) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: "[Errno \(code)] \(String(cString: strerror(code))): '\(path)'"])
    }
}

private func zip3<A, B, C>(_ a: [A], _ b: [B], _ c: [C]) -> [(A, B, C)] {
    (0..<min(a.count, b.count, c.count)).map { (a[$0], b[$0], c[$0]) }
}
