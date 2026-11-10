// Speaker naming (speakers.py, issues #12, #30, #48): names given to diarization labels (`speakers.json`), labels
// merged into another (`speakers_merged.json`, one person the diarizer split), voices removed as noise
// (`speakers_ignored.json`), voices nobody can name (`speakers_unknown.json`), names a voice is not
// (`speakers_rejected.json`), names given while recording (`speakers_live.json`) and single lines said to be someone
// else's (`speakers_lines.json`, #12: applied wherever the transcript is read, never written into transcript.json; a
// line is found by its time and track, so the correction stays when the meeting is processed again). Saving names learns their voices
// and rewrites transcript.json and transcript.md. Every writer holds the meeting's lock (`<folder>/.speakers.lock`),
// never together with the voice bank's: `saveSpeakerNames` is two meeting-locked sections around the learning.
// The terminal wizard (`run_wizard`, `play_clip`) stays Python's.
import Foundation
import PalaverCore

/// What Python raises as ValueError for a speaker change it refuses: the window answers 400.
public struct SpeakersValueError: Error, CustomStringConvertible {
    public let description: String
}

/// `LookupError(label)`: no voice of that label while recording.
public struct NoLiveVoice: Error, CustomStringConvertible {
    public let label: String
    public var description: String { label }
}

/// A speaker file Python's speaker code raises on (one it does not guard): not JSON, not the shape it reads.
public struct SpeakerFileError: Error, CustomStringConvertible {
    public let description: String
}

public enum Speakers {
    /// A clip played to name a voice is at most this long (the wizard's).
    public static let MAX_SAMPLE_SECONDS = 8.0
    /// A voice named while recording is the same as a speaker's voice this alike. Provisional labels change between
    /// snapshots; voices don't.
    public static let LIVE_MATCH = 0.7

    // MARK: - reading and writing the files

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private static func unlink(_ url: URL) throws {
        if exists(url) { try FileManager.default.removeItem(at: url) }
    }

    /// `json.loads(path.read_text())`: a file that can't be read throws its I/O error (Python's OSError), one that is
    /// not JSON a `SpeakerFileError` (Python's ValueError).
    private static func json(_ url: URL) throws -> JSONValue {
        let data = try Data(contentsOf: url)
        do { return try PythonJSON.parse(data) } catch { throw SpeakerFileError(description: "\(url.lastPathComponent): \(error)") }
    }

    /// Python's iteration of a JSON value: a list's items, an object's keys, a string's characters; nil for a
    /// number, a bool or null (TypeError).
    private static func items(_ v: JSONValue) -> [JSONValue]? {
        switch v {
        case .array(let a): return a
        case .object(let o): return o.map { .string($0.0) }
        case .string(let s): return s.unicodeScalars.map { .string(String($0)) }
        default: return nil
        }
    }

    private static func object(_ d: PyDict<String>) -> JSONValue { .object(d.map { ($0.key, .string($0.value)) }) }

    /// A set of labels as `sorted(labels)`: each once (by code points), in code-point order.
    static func sortedUnique(_ labels: [String]) -> [String] {
        var seen = Set<ScalarKey>()
        return Py.stableSorted(labels.filter { seen.insert(ScalarKey($0)).inserted }, by: Py.less)
    }

    /// `u.label or u.speaker`.
    public static func labelOf(_ u: Utterance) -> String {
        if let label = u.label, !label.isEmpty { return label }
        return u.speaker
    }

    /// Python's `==` on two name maps: the same labels with the same names, by code points.
    static func sameNames(_ a: PyDict<String>, _ b: PyDict<String>) -> Bool {
        a.count == b.count && a.allSatisfy { label, name in b[label].map { Py.same($0, name) } ?? false }
    }

    // MARK: - names

    /// label → name given by hand (`speakers.json`); none without the file. A file that is not a JSON object is an
    /// error, as in Python.
    public static func loadSpeakerNames(_ paths: RecordingPaths) throws -> PyDict<String> {
        guard exists(paths.speakers) else { return PyDict() }
        guard case .object(let fields) = try json(paths.speakers) else {
            throw SpeakerFileError(description: "speakers.json is not an object")
        }
        return PyDict(fields.map { ($0.0, pyStr($0.1)) })
    }

    /// The utterances with each label's name (`label` keeps the label it came from); unnamed labels stay.
    public static func applySpeakerNames(_ utterances: [Utterance], _ names: PyDict<String>) -> [Utterance] {
        utterances.map { u in
            let label = labelOf(u)
            let name = names[label].flatMap { $0.isEmpty ? nil : $0 }
            return Utterance(speaker: name ?? label, start: u.start, end: u.end, text: u.text,
                             label: name != nil ? label : nil, heard: u.heard, unsure: u.unsure, saidBy: u.saidBy,
                             heardAs: u.heardAs)
        }
    }

    // MARK: - merges

    /// label → the label it was merged into; none when the file is missing or broken.
    public static func loadMerges(_ paths: RecordingPaths) -> PyDict<String> {
        guard case .object(let fields)? = PythonJSON.read(paths.speakersMerged) else { return PyDict() }
        return PyDict(fields.map { ($0.0, pyStr($0.1)) })
    }

    /// `names` with each merged label named as the label it was merged into (or called by that label, while it has
    /// no name).
    public static func followMerges(_ names: PyDict<String>, _ merges: PyDict<String>) -> PyDict<String> {
        var out = PyDict(names.filter { merges[$0.key] == nil }.map { ($0.key, $0.value) })
        for (label, into) in merges { out[label] = out[into] ?? into }
        return out
    }

    // MARK: - removed voices, unknown voices

    /// `set(json.loads(...))` of a label file: its labels (strings only); none when it is missing or broken.
    private static func labelSet(_ url: URL) -> [String] {
        guard let v = PythonJSON.read(url), let all = items(v) else { return [] }
        return all.compactMap(\.stringValue)
    }

    /// Labels removed as noise; their lines are left out wherever the meeting is shown, searched or summarized
    /// (transcript.json keeps them). Python's set, as its sorted list (each label once, by code points).
    public static func loadIgnored(_ paths: RecordingPaths) -> [String] { sortedUnique(labelSet(paths.speakersIgnored)) }

    /// `labels | {label}` or `labels - {label}`, written as `json.dumps(sorted(labels))`; none left removes the file.
    private static func setLabel(_ url: URL, _ label: String, _ on: Bool, _ read: [String]) throws {
        let labels = sortedUnique(read.filter { !Py.same($0, label) } + (on ? [label] : []))
        if labels.isEmpty { return try unlink(url) }
        try PythonJSON.write(.strings(labels), to: url, indent: nil, ensureAscii: true)
    }

    public static func setIgnored(_ paths: RecordingPaths, _ label: String, _ ignored: Bool = true) throws {
        try StoreLock.meeting(paths) { try setLabel(paths.speakersIgnored, label, ignored, labelSet(paths.speakersIgnored)) }
    }

    /// Labels the user can't name ("Don't Know"): still unnamed lanes, but no to-do, so a voice nobody knows isn't
    /// asked about forever. Python's set, as its sorted list.
    public static func loadUnknown(_ paths: RecordingPaths) -> [String] { sortedUnique(unknownList(paths)) }

    private static func unknownList(_ paths: RecordingPaths) -> [String] {
        guard let v = PythonJSON.read(paths.speakersUnknown), let all = items(v) else { return [] }
        return all.map(pyStr)
    }

    public static func setUnknown(_ paths: RecordingPaths, _ label: String, _ unknown: Bool = true) throws {
        try StoreLock.meeting(paths) { try setLabel(paths.speakersUnknown, label, unknown, unknownList(paths)) }
    }

    /// `utterances` as the user corrected them: single lines with the speaker they were said to be
    /// (speakers_lines.json), then without the lines of removed voices. Throws what reading the names throws (a
    /// speaker file Python raises on), only while there are corrections.
    public static func withoutIgnored(_ paths: RecordingPaths, _ utterances: [Utterance]) throws -> [Utterance] {
        let utterances = try withLineSpeakers(paths, utterances)
        let ignored = Set(loadIgnored(paths).map(ScalarKey.init))
        if ignored.isEmpty { return utterances }
        let merges = loadMerges(paths)
        return utterances.filter { u in
            let label = labelOf(u)
            return !ignored.contains(ScalarKey(merges[label] ?? label))
        }
    }

    // MARK: - names a voice is not

    /// label → names the user said this voice is not ("Not Tom", #48): no recognition or inference gives them to it
    /// again. None when the file is missing or broken.
    public static func loadRejectedNames(_ paths: RecordingPaths) -> PyDict<[String]> {
        guard case .object(let fields)? = PythonJSON.read(paths.speakersRejected) else { return PyDict() }
        var out = PyDict<[String]>()
        for (label, names) in fields where names.truthy {
            guard let all = items(names) else { return PyDict() }
            out[label] = all.map(pyStr)
        }
        return out
    }

    static func isRejected(_ rejected: PyDict<[String]>, _ label: String, _ name: String) -> Bool {
        let key = Py.casefold(name)
        return (rejected[label] ?? []).contains { Py.same(Py.casefold($0), key) }
    }

    /// "`label` is not `name`", or (`rejected: false`) it may be after all.
    public static func setRejectedName(_ paths: RecordingPaths, _ label: String, _ name: String, _ rejected: Bool = true) throws {
        try StoreLock.meeting(paths) {
            var names = loadRejectedNames(paths)
            let key = Py.casefold(name)
            let kept = (names[label] ?? []).filter { !Py.same(Py.casefold($0), key) }
            names[label] = rejected ? kept + [name] : kept
            names = PyDict(names.filter { !$0.value.isEmpty }.map { ($0.key, $0.value) })
            if names.isEmpty { return try unlink(paths.speakersRejected) }
            try PythonJSON.write(.object(names.map { ($0.key, .strings($0.value)) }), to: paths.speakersRejected,
                                 indent: 2, ensureAscii: false)
        }
    }

    /// label → name inferred from the calendar and other meetings, but not one the user said the voice is not. A
    /// broken entry leaves none; a file that is not an object, or a name that is not text, is an error (Python's
    /// AttributeError).
    public static func loadInferredNames(_ paths: RecordingPaths) throws -> PyDict<String> {
        guard let v = PythonJSON.read(paths.speakersInferred) else { return PyDict() }
        guard case .object(let fields) = v else { throw SpeakerFileError(description: "speakers_inferred.json is not an object") }
        var inferred: [(String, JSONValue)] = []
        for (label, entry) in fields {
            guard case .object = entry, let name = entry["name"] else { return PyDict() }  // KeyError, TypeError
            inferred.append((label, name))
        }
        let rejected = loadRejectedNames(paths)
        var out = PyDict<String>()
        for (label, value) in inferred {
            guard case .string(let name) = value else { throw SpeakerFileError(description: "an inferred name is not text") }
            if !isRejected(rejected, label, name) { out[label] = name }
        }
        return out
    }

    /// label → (name, similarity) recognized by voice (`speakers_auto.json`), but not a name the user said the voice
    /// is not. A file that is not the shape Python reads is an error.
    public static func loadRecognizedNames(_ paths: RecordingPaths) throws -> PyDict<(String, Double)> {
        guard exists(paths.speakersAuto) else { return PyDict() }
        let rejected = loadRejectedNames(paths)
        guard case .object(let fields) = try json(paths.speakersAuto) else {
            throw SpeakerFileError(description: "speakers_auto.json is not an object")
        }
        var out = PyDict<(String, Double)>()
        for (label, hit) in fields {
            // As Python's comprehension: the name is checked against the rejected ones before the similarity is read.
            guard case .string(let name)? = hit["name"] else { throw SpeakerFileError(description: "speakers_auto.json: \(label) has no name") }
            if isRejected(rejected, label, name) { continue }
            out[label] = (name, try similarity(hit["similarity"], label))
        }
        return out
    }

    /// `float(hit["similarity"])`.
    private static func similarity(_ value: JSONValue?, _ label: String) throws -> Double {
        guard let d = VoiceMath.pyFloat(value) else { throw SpeakerFileError(description: "speakers_auto.json: \(label) has no similarity") }
        return d
    }

    /// label → name in effect: inferred, recognized by voice, given by hand (each overriding the one before); a merged
    /// label has the name of the label it was merged into; a room of several people has none (#56).
    public static func namesInEffect(_ paths: RecordingPaths) throws -> PyDict<String> {
        var names = try loadInferredNames(paths)
        for (label, hit) in try loadRecognizedNames(paths) { names[label] = hit.0 }
        for (label, name) in try loadSpeakerNames(paths) { names[label] = name }
        let merges = loadMerges(paths)
        names = PyDict(names.filter { !Py.same($0.value, $0.key) && merges[$0.key] == nil }.map { ($0.key, $0.value) })
        let fromInto = merges.compactMap { label, into in names[into].map { (label, $0) } }
        for (label, name) in fromInto { names[label] = name }
        let shared = SharedMic.sharedLabels(paths)
        return PyDict(names.filter { !shared.contains(ScalarKey($0.key)) }.map { ($0.key, $0.value) })
    }

    // MARK: - turns

    public static func mergedTurns(_ turns: [SpeakerTurn], _ merges: PyDict<String>) -> [SpeakerTurn] {
        turns.map { SpeakerTurn(speaker: merges[$0.speaker] ?? $0.speaker, start: $0.start, end: $0.end) }
    }

    /// Seconds each label talks, summed in turn order.
    public static func talkSeconds(_ turns: [SpeakerTurn]) -> PyDict<Double> {
        var totals = PyDict<Double>()
        for t in turns { totals[t.speaker] = (totals[t.speaker] ?? 0.0) + (t.end - t.start) }
        return totals
    }

    /// Each label's longest turn (the first of equally long ones).
    public static func longestTurns(_ turns: [SpeakerTurn]) -> PyDict<SpeakerTurn> {
        var best = PyDict<SpeakerTurn>()
        for t in turns {
            if let current = best[t.speaker], !(t.end - t.start > current.end - current.start) { continue }
            best[t.speaker] = t
        }
        return best
    }

    // MARK: - merging and saving

    /// Folds `label` into `into` (one person the diarizer split in two); `into` nil splits it off again. A name given
    /// only to `label` moves to `into`, and so do the names it is not. Rewrites the transcript.
    public static func mergeSpeakers(_ paths: RecordingPaths, _ label: String, into: String?, bank: VoiceBank? = nil,
                                     stores: StorePaths = .current()) throws {
        // The meeting's lock is let go before saveSpeakerNames: it takes the voice bank's (never two at once).
        let names = try StoreLock.meeting(paths) { () throws -> PyDict<String> in
            var merges = loadMerges(paths)
            var names = try loadSpeakerNames(paths)
            if let target = into {
                let into = merges[target] ?? target
                if Py.same(into, label) { throw SpeakersValueError(description: "a speaker cannot be merged into itself") }
                merges = PyDict(merges.map { ($0.key, Py.same($0.value, label) ? into : $0.value) })
                merges[label] = into
                let own = names.removeValue(forKey: label)
                if let own, !own.isEmpty, !Py.same(own, label), names[into] == nil { names[into] = own }
                // What the user said the merged voice is not, the person is not either.
                for name in loadRejectedNames(paths)[label] ?? [] { try setRejectedName(paths, into, name) }
            } else {
                merges.removeValue(forKey: label)
            }
            if merges.isEmpty {
                try unlink(paths.speakersMerged)
            } else {
                try PythonJSON.write(object(merges), to: paths.speakersMerged, indent: 2, ensureAscii: false)
            }
            try SharedMic.followMerges(paths)  // a room merged into a voice: the room wins (#56)
            return names
        }
        try saveSpeakerNames(paths, names, bank: bank, stores: stores)
    }

    /// Stores the names given to labels, re-learns their voices (unless `learn` is false: nothing about them
    /// changed), and rewrites transcript.json and transcript.md. Names recognized by voice stay unless `names`
    /// overrides them; mapping a label to itself rejects a recognized name. Returns the number of voice samples
    /// added. `bank` nil: the voice bank of `stores`, whose glossary spells transcript.md.
    @discardableResult
    public static func saveSpeakerNames(_ paths: RecordingPaths, _ names: PyDict<String>, bank: VoiceBank? = nil,
                                        learn: Bool = true, stores: StorePaths = .current()) throws -> Int {
        // Unchanged names keep their file as it is: an undo taken before still finds it unchanged.
        try StoreLock.meeting(paths) {
            // Python catches ValueError and AttributeError here (not JSON, not an object); an I/O error goes up.
            var same = false
            if exists(paths.speakers) {
                do { same = sameNames(try loadSpeakerNames(paths), names) } catch is SpeakerFileError { same = false }
            }
            if !same { try PythonJSON.write(object(names), to: paths.speakers, indent: 2, ensureAscii: false) }
        }
        // Learning voices takes the voice bank's lock, so not under the meeting's: one lock at a time.
        guard let turnList = try json(paths.systemTurns).arrayValue else { throw SpeakerFileError(description: "system_turns.json is not a list") }
        let turns = try turnList.map { try SpeakerTurn(json: $0) }
        let merges = loadMerges(paths)
        let ignored = Set(loadIgnored(paths).map(ScalarKey.init))
        let shared = SharedMic.display(paths)  // for who learns; the transcript reads it again under the lock
        // A merged-away label teaches no voice: it is often the odd part the diarizer split off, not a good sample of
        // the person. Nor does noise, nor a room of several people (#56).
        var enrolled = 0
        if learn {
            let learners = PyDict(names.filter { merges[$0.key] == nil && !ignored.contains(ScalarKey($0.key)) && shared[$0.key] == nil }
                .map { ($0.key, $0.value) })
            enrolled = try rememberVoices(paths, learners, talkSeconds(turns), bank ?? VoiceBank(directory: stores.voices))
        }
        try StoreLock.meeting(paths) {
            let effective = try transcriptNames(paths)  // as stored now (read again under the lock), not the caller's copy
            guard let items = try json(paths.transcriptJson).arrayValue else {
                throw SpeakerFileError(description: "transcript.json is not a list")
            }
            let renamed = applySpeakerNames(try items.map { try Utterance(json: $0) }, effective)
            try PythonJSON.write(.array(renamed.map(\.json)), to: paths.transcriptJson, indent: 2, ensureAscii: true)
            let meta = try json(paths.meta)
            guard let iso = meta["start_time"]?.stringValue, let start = Py.fromIso(iso) else {
                throw SpeakerFileError(description: "meta.json has no start_time")
            }
            guard let duration = meta["duration_seconds"]?.doubleValue else {
                throw SpeakerFileError(description: "meta.json has no duration_seconds")
            }
            let markdown = try Render.markdown(SharedMic.shown(paths, try withoutIgnored(paths, renamed)), start: start, duration: duration,
                                           gaps: meta["gaps"]?.arrayValue, timeZone: Lifecycle.offsetZone(iso) ?? .current,
                                           glossary: Glossary.current(stores: stores))
            try markdown.write(to: paths.transcriptMd, atomically: false, encoding: .utf8)
        }
        return enrolled
    }

    /// label → the name transcript.json gives its lines: inferred, recognized by voice, given by hand (`names`, else
    /// speakers.json), merged labels as their person, rooms as the room (#56).
    public static func transcriptNames(_ paths: RecordingPaths, _ names: PyDict<String>? = nil) throws -> PyDict<String> {
        var effective = try loadInferredNames(paths)
        for (label, hit) in try loadRecognizedNames(paths) { effective[label] = hit.0 }
        for (label, name) in try names ?? loadSpeakerNames(paths) { effective[label] = name }
        effective = followMerges(effective, loadMerges(paths))
        for (label, room) in SharedMic.display(paths) { effective[label] = room }
        return effective
    }

    /// Teaches the bank the named voices of this meeting (`speaker_embeddings.json`); a voice now named otherwise
    /// (or not at all) is taken back from whoever had it. Short talkers teach nothing.
    private static func rememberVoices(_ paths: RecordingPaths, _ names: PyDict<String>, _ talk: PyDict<Double>,
                                       _ bank: VoiceBank) throws -> Int {
        guard exists(paths.speakerEmbeddings) else { return 0 }
        guard case .object(let embeddings) = try json(paths.speakerEmbeddings) else {
            throw SpeakerFileError(description: "speaker_embeddings.json is not an object")
        }
        var added = 0
        for (label, vector) in embeddings {
            let source = "\(paths.folder.lastPathComponent):\(label)"
            let name = names[label]
            if let owner = try bank.owner(source), !(name.map { Py.same(owner, $0) } ?? false) {
                try bank.removeSource(source)  // renamed: the voice was someone else's
            }
            guard let name, !Py.same(name, label), (talk[label] ?? 0.0) >= Voices.MIN_TALK_SECONDS else { continue }
            if try bank.add(name, VoiceMath.vector(vector, "a voice of speaker_embeddings.json"), source: source) { added += 1 }
        }
        return added
    }

    // MARK: - names given while recording (#30)

    /// The names given while recording, each with its voice (`speakers_live.json`); none when missing or broken.
    public static func loadLiveNames(_ paths: RecordingPaths) -> [JSONValue] {
        PythonJSON.read(paths.speakersLive)?.arrayValue ?? []
    }

    /// label → name, pairing each named voice with its most alike label (each at most once, LIVE_MATCH at least).
    public static func matchLiveNames(_ embeddings: PyDict<[Double]>, _ named: [JSONValue]) throws -> PyDict<String> {
        var pairs: [(Double, String, String)] = []
        for (label, v) in embeddings {
            for n in named {
                guard case .string(let name)? = n["name"] else { throw SpeakerFileError(description: "a live name is not text") }
                pairs.append((try VoiceMath.cosine(v, VoiceMath.vector(n["embedding"], "a live name's voice")), label, name))
            }
        }
        // sorted(reverse=True) on (similarity, label, name): equal tuples keep their order.
        pairs = Py.stableSorted(pairs) { a, b in
            if a.0 != b.0 { return a.0 > b.0 }
            if !Py.same(a.1, b.1) { return Py.less(b.1, a.1) }
            return Py.less(b.2, a.2)
        }
        var out = PyDict<String>()
        var taken = Set<ScalarKey>()
        for (sim, label, name) in pairs {
            if sim < LIVE_MATCH || out[label] != nil || taken.contains(ScalarKey(name)) { continue }
            out[label] = name
            taken.insert(ScalarKey(name))
        }
        return out
    }

    /// Names the voice behind a provisional label of live.json; an empty name forgets it.
    public static func nameLiveSpeaker(_ paths: RecordingPaths, _ label: String, _ name: String) throws {
        let live = try json(paths.live)
        guard case .object = live else { throw SpeakerFileError(description: "live.json is not an object") }
        guard let voice = live["embeddings"]?[label], !voice.isNull else { throw NoLiveVoice(label: label) }
        let vector = try VoiceMath.vector(voice, "a live voice")
        let typed = Py.strip(name)
        try StoreLock.meeting(paths) {
            let current = try matchLiveNames(PyDict([(label, vector)]), loadLiveNames(paths))[label]
            var named = try loadLiveNames(paths).filter { n in
                guard case .string(let given)? = n["name"] else { throw SpeakerFileError(description: "a live name is not text") }
                return !(current.map { Py.same(given, $0) } ?? false) && !Py.same(given, typed)
            }
            if !typed.isEmpty { named.append(.object([("name", .string(typed)), ("embedding", voice)])) }
            try PythonJSON.write(.array(named), to: paths.speakersLive, indent: nil, ensureAscii: false)
        }
    }

    /// Names given while recording, onto the final speakers (as if given afterwards); a name given afterwards wins.
    /// Returns what was adopted.
    @discardableResult
    public static func adoptLiveNames(_ paths: RecordingPaths) throws -> PyDict<String> {
        try StoreLock.meeting(paths) {
            let named = loadLiveNames(paths)
            guard !named.isEmpty, exists(paths.speakerEmbeddings) else { return PyDict() }
            guard case .object(let fields) = try json(paths.speakerEmbeddings) else {
                throw SpeakerFileError(description: "speaker_embeddings.json is not an object")
            }
            let embeddings = PyDict(try fields.map { ($0.0, try VoiceMath.vector($0.1, "a voice of speaker_embeddings.json")) })
            let found = try matchLiveNames(embeddings, named)
            var names = try loadSpeakerNames(paths)
            let adopted = PyDict(found.filter { names[$0.key] == nil }.map { ($0.key, $0.value) })
            if !adopted.isEmpty {
                for (label, name) in adopted { names[label] = name }
                try PythonJSON.write(object(names), to: paths.speakers, indent: 2, ensureAscii: false)
            }
            try unlink(paths.speakersLive)
            return adopted
        }
    }

    // MARK: - the speaker of single lines (#12)

    private static let diarized = try! PyRegex(#"SPEAKER_\d+"#)
    /// A correction is a line's when it covers at least this much of it.
    public static let LINE_COVERED = 0.5

    /// A line of the user's microphone, as transcript.json has it: no diarization label, named or not, and not a line
    /// said to be a person's (#12).
    public static func isMicLine(_ u: Utterance) -> Bool {
        u.label == nil && u.saidBy == nil && diarized.fullMatch(u.speaker) == nil
    }

    /// "mic" or "others": the track a line of transcript.json is on.
    public static func lineTrack(_ u: Utterance) -> String { isMicLine(u) ? "mic" : "others" }

    /// `isinstance(v, (int, float))`: a bool is an int in Python.
    private static func isNumber(_ v: JSONValue?) -> Bool {
        switch v {
        case .int?, .double?, .bool?: return true
        default: return false
        }
    }

    /// A number of a correction (checked by `loadLineSpeakers`) as Python computes with it.
    static func number(_ v: JSONValue?) -> Double {
        switch v {
        case .int(let i)?: return Double(i)
        case .double(let d)?: return d
        case .bool(let b)?: return b ? 1 : 0
        default: return 0
        }
    }

    /// The corrections of single lines, by time: the entries of speakers_lines.json that are objects with a number
    /// `start` (no bool) and `end`; none when the file is missing, broken or not a list.
    public static func loadLineSpeakers(_ paths: RecordingPaths) -> [JSONValue] {
        guard case .array(let data)? = PythonJSON.read(paths.speakersLines) else { return [] }
        return data.filter { d in
            guard case .object = d else { return false }
            if case .bool? = d["start"] { return false }
            return isNumber(d["start"]) && isNumber(d["end"])
        }
    }

    /// `sorted(fixes, key=lambda d: (d["start"], d["end"]))`, written with `indent=2, ensure_ascii=False` through
    /// `speakers_lines.json.tmp`; none left removes the file.
    private static func saveLineSpeakers(_ paths: RecordingPaths, _ fixes: [JSONValue]) throws {
        if fixes.isEmpty { return try unlink(paths.speakersLines) }
        let sorted = Py.stableSorted(fixes) { a, b in
            let (sa, sb) = (number(a["start"]), number(b["start"]))
            return sa != sb ? sa < sb : number(a["end"]) < number(b["end"])
        }
        try PythonJSON.write(.array(sorted), to: paths.speakersLines, indent: 2, ensureAscii: false,
                             via: paths.speakersLines.lastPathComponent + ".tmp")
    }

    /// The index in `fixes` of the correction of line `u`: one of its track (the microphone, or the others) covering
    /// most of it; transcribed again, a line's times move a little and its voice may get another label.
    public static func lineFix(_ u: Utterance, _ fixes: [JSONValue]) -> Int? {
        let mic = isMicLine(u)
        var length = max(u.end - u.start, 0.0)
        var best: Int?, covered = 0.0
        for (i, f) in fixes.enumerated() {
            let fromNone: Bool
            switch f["from"] {
            case nil, .null?: fromNone = true
            default: fromNone = false
            }
            if fromNone != mic { continue }
            let (start, end) = (number(f["start"]), number(f["end"]))
            if abs(start - u.start) < 0.01 && abs(end - u.end) < 0.01 { return i }
            var overlap = min(u.end, end) - max(u.start, start)
            if length == 0.0 {
                overlap = start <= u.start && u.start <= end ? 1.0 : 0.0
                length = 1.0
            }
            if overlap >= LINE_COVERED * length && overlap > covered { (best, covered) = (i, overlap) }
        }
        return best
    }

    /// `_said_by`: line `u` said by whom correction `fix` says.
    private static func saidBy(_ u: Utterance, _ fix: JSONValue, _ names: PyDict<String>, _ me: String?) -> Utterance {
        var out = u
        if fix["me"]?.truthy ?? false {
            if let me, !me.isEmpty {
                out.speaker = me
            } else {
                out.speaker = fix["name"].flatMap { $0.truthy ? Py.str($0) : nil } ?? "Me"
            }
            out.label = nil
            return out
        }
        if case .string(let label)? = fix["label"] {
            if let name = names[label], !name.isEmpty {
                (out.speaker, out.label) = (name, label)
            } else {
                (out.speaker, out.label) = (label, nil)
            }
            return out
        }
        let name = Py.strip(fix["name"].flatMap { $0.truthy ? Py.str($0) : nil } ?? "")
        guard !name.isEmpty else { return u }
        (out.speaker, out.label, out.saidBy) = (name, nil, name)
        return out
    }

    /// `utterances` (as transcript.json has them) with each corrected line said by whom the user said: a voice as its
    /// name in `names` (label → name), a person by name, the user as `me` (by default the name on the microphone's
    /// lines).
    public static func correctedLines(_ utterances: [Utterance], _ fixes: [JSONValue], names: PyDict<String>,
                                      me: String? = nil) -> [Utterance] {
        if fixes.isEmpty { return utterances }
        let me = me ?? utterances.first(where: isMicLine)?.speaker
        return utterances.map { u in
            guard let i = lineFix(u, fixes) else { return u }
            var out = saidBy(u, fixes[i], names, me)
            out.heardAs = isMicLine(u) ? ("mic", nil) : ("others", labelOf(u))
            return out
        }
    }

    /// `utterances` with the corrections of speakers_lines.json.
    public static func withLineSpeakers(_ paths: RecordingPaths, _ utterances: [Utterance]) throws -> [Utterance] {
        let fixes = loadLineSpeakers(paths)
        if fixes.isEmpty { return utterances }
        return correctedLines(utterances, fixes, names: try transcriptNames(paths))
    }

    /// Says who said `line` (as transcript.json has it): `[("label", …)]`, `[("name", …)]` or
    /// `[("me", true), ("name", …)]`; nil: the voice it was heard as. One correction per line: a new one replaces the
    /// old. Under the meeting's lock, like the other speaker files.
    public static func setLineSpeaker(_ paths: RecordingPaths, _ line: Utterance, _ to: [(String, JSONValue)]?) throws {
        try StoreLock.meeting(paths) {
            var fixes = loadLineSpeakers(paths)
            if let current = lineFix(line, fixes) { fixes.remove(at: current) }
            if let to {
                let from: JSONValue = isMicLine(line) ? .null : .string(labelOf(line))
                var fields: [(String, JSONValue)] = [("start", .double(Py.round(line.start, 3))),
                                                     ("end", .double(Py.round(line.end, 3))), ("from", from)]
                for (key, value) in to {  // {**base, **to}: a key of `to` already there keeps its place
                    if let at = fields.firstIndex(where: { $0.0 == key }) { fields[at].1 = value } else { fields.append((key, value)) }
                }
                fixes.append(.object(fields))
            }
            try saveLineSpeakers(paths, fixes)
        }
    }
}
