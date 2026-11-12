// People across meetings (people.py, issue #22). Every diarized speaker has a voice embedding per meeting; named
// speakers teach the voice bank, and this applies what the bank knows to all meetings:
// - `refreshRecognition` recognizes the bank's voices in every meeting, so naming someone once names their voice in
//   earlier meetings too ("recognized by voice", which a name given by hand always overrides), then infers names;
// - `directory` lists the named people with their meetings, and voices that recur in several meetings unnamed;
// - `nameVoices` and `renamePerson` change names in all meetings at once.
// Locks as Task 7's Python: speakers_auto.json and speakers_rejected.json are written under the meeting's lock, which
// is let go before anything takes the voice bank's (saving names learns voices): never two locks at once.
import Foundation
import PalaverCore

/// A speaker with enough talk for their voice to be compared.
public struct Voice {
    public let meeting: String
    public let label: String
    public let talkSeconds: Double
    /// Unit length.
    public let embedding: [Double]
    public let name: String?
    /// "you" | "voice" | "inferred" | nil
    public let namedBy: String?

    public init(meeting: String, label: String, talkSeconds: Double, embedding: [Double], name: String?, namedBy: String?) {
        self.meeting = meeting; self.label = label; self.talkSeconds = talkSeconds; self.embedding = embedding
        self.name = name; self.namedBy = namedBy
    }
}

public enum People {
    /// Unnamed voices this similar (average over the group) count as one person.
    public static let GROUP_THRESHOLD = 0.75

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The names in `dir`, as `sorted(dir.iterdir())` orders them (by code points); none when it is no folder.
    static func sortedNames(_ dir: URL) -> [String] {
        guard isDirectory(dir), let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return Py.stableSorted(names, by: Py.less)
    }

    /// `_meetings`: the recording folders with speaker turns, by name.
    static func meetings(_ outputDir: URL) -> [RecordingPaths] {
        sortedNames(outputDir).compactMap { name in
            let folder = outputDir.appendingPathComponent(name, isDirectory: true)
            let paths = RecordingPaths(folder)
            guard isDirectory(folder), RecordingPaths.isRecordingFolderName(name), exists(paths.systemTurns) else { return nil }
            return paths
        }
    }

    /// `_turns`: the meeting's speaker turns, merged labels under the label they were merged into; none while a meeting
    /// has just started (no system_turns.json). A broken file is an error, as in Python.
    static func turns(_ paths: RecordingPaths) throws -> [SpeakerTurn] {
        guard exists(paths.systemTurns) else { return [] }
        let parsed: JSONValue
        do { parsed = try PythonJSON.parse(Data(contentsOf: paths.systemTurns)) } catch let e as PythonJSON.ParseError {
            throw SpeakerFileError(description: "system_turns.json: \(e)")
        }
        guard let items = parsed.arrayValue else { throw SpeakerFileError(description: "system_turns.json is not a list") }
        return Speakers.mergedTurns(try items.map { try SpeakerTurn(json: $0) }, Speakers.loadMerges(paths))
    }

    /// The labels whose voices don't count: merged away, removed as noise, several people's (#56).
    static func skipped(_ paths: RecordingPaths) -> Set<ScalarKey> {
        Set(Speakers.loadMerges(paths).keys.map(ScalarKey.init))
            .union(Speakers.loadIgnored(paths).map(ScalarKey.init))
            .union(SharedMic.sharedLabels(paths))
    }

    /// `_embeddings`: voice per label as stored; merged-away labels have none of their own, and removed voices and
    /// rooms don't count. None when the file is missing or not JSON; one that is not an object is an error.
    static func embeddings(_ paths: RecordingPaths) throws -> PyDict<JSONValue> {
        guard let raw = PythonJSON.read(paths.speakerEmbeddings) else { return PyDict() }
        guard case .object(let fields) = raw else { throw SpeakerFileError(description: "speaker_embeddings.json is not an object") }
        let skip = skipped(paths)
        return PyDict(fields.filter { !skip.contains(ScalarKey($0.0)) })
    }

    /// `_naming`: label → (name, "you" | "voice" | "inferred"); a name given by hand wins, then one recognized by voice.
    /// Merged-away labels are left out: they count as the label they joined.
    static func naming(_ paths: RecordingPaths) throws -> PyDict<(String, String)> {
        var out = PyDict(try Speakers.loadInferredNames(paths).map { ($0.key, ($0.value, "inferred")) })
        for (label, hit) in try Speakers.loadRecognizedNames(paths) { out[label] = (hit.0, "voice") }
        for (label, name) in try Speakers.loadSpeakerNames(paths) {
            if Py.same(name, label) {  // a recognized name rejected by hand
                out[label] = nil
            } else {
                out[label] = (name, "you")
            }
        }
        let skip = skipped(paths)
        return PyDict(out.filter { !skip.contains(ScalarKey($0.key)) }.map { ($0.key, $0.value) })
    }

    /// A stored voice as numbers, unit length; nil when it is empty, zero or not finite (it is not compared).
    static func unitVoice(_ value: JSONValue) throws -> [Double]? {
        let v = try VoiceMath.vector(value, "a voice of speaker_embeddings.json")
        guard !v.isEmpty, v.allSatisfy(\.isFinite), v.contains(where: { $0 != 0 }) else { return nil }
        return VoiceMath.unit(v)
    }

    /// Speakers with enough talk for their voice to be compared.
    public static func voices(_ outputDir: URL) throws -> [Voice] {
        var out: [Voice] = []
        for paths in meetings(outputDir) {
            let talk = Speakers.talkSeconds(try turns(paths))
            let naming = try naming(paths)
            for (label, vector) in try embeddings(paths) {
                let seconds = talk[label] ?? 0.0
                // As Python: the voice is read (and may fail) before the talk is checked.
                let unit = try unitVoice(vector)
                guard seconds >= Voices.MIN_TALK_SECONDS, let unit else { continue }
                let named = naming[label]
                out.append(Voice(meeting: paths.id, label: label, talkSeconds: seconds, embedding: unit,
                                 name: named?.0, namedBy: named?.1))
            }
        }
        return out
    }

    /// `_groups`: average-linkage clusters of voices at least `threshold` similar, in the order of their first voice.
    static func groups(_ items: [Voice], _ threshold: Double) throws -> [[Voice]] {
        if items.count < 2 { return items.isEmpty ? [] : [items] }
        let clusters = try Upgma.fcluster(items.map(\.embedding), threshold: 1 - threshold)
        var order: [Int] = [], found: [Int: [Voice]] = [:]
        for (voice, cluster) in zip(items, clusters) {
            if found[cluster] == nil { order.append(cluster) }
            found[cluster, default: []].append(voice)
        }
        return order.map { found[$0]! }
    }

    /// Named people with the meetings they spoke in, and unnamed voices that recur in more than one meeting, most talk
    /// first: `{"people": [...], "unknown": [...]}`. `me`: the user's names, casefolded (an earlier one too, #55):
    /// their entry says "you". `bank` nil: the voice bank of `stores`.
    public static func directory(outputDir: URL, me: Set<String> = [], bank: VoiceBank? = nil,
                                 stores: StorePaths = .current()) throws -> JSONValue {
        let bank = bank ?? VoiceBank(directory: stores.voices)
        var people = PyDict<(name: String, meetings: [JSONValue], talk: Double)>()
        for paths in meetings(outputDir) {
            let talk = Speakers.talkSeconds(try turns(paths))
            let naming = try naming(paths)
            for label in Py.stableSorted(naming.keys, by: Py.less) {
                let (name, by) = naming[label]!
                let key = Py.casefold(name)
                var person = people[key] ?? (name: name, meetings: [], talk: 0.0)
                let seconds = talk[label] ?? 0.0
                person.meetings.append(.object([("id", .string(paths.id)), ("label", .string(label)),
                                                ("talk_seconds", .double(Py.round(seconds, 1))), ("named_by", .string(by))]))
                person.talk = Py.round(person.talk + seconds, 1)
                people[key] = person
            }
        }
        let samples = PyDict(try bank.names().map { (Py.casefold($0.key), $0.value) })
        let mine = Set(me.map(ScalarKey.init))
        let listed: [(talk: Double, json: JSONValue)] = people.map { key, person in
            (person.talk, .object([("name", .string(person.name)), ("meetings", .array(person.meetings)),
                                   ("talk_seconds", .double(person.talk)), ("voice_samples", .int(samples[key] ?? 0)),
                                   ("you", .bool(mine.contains(ScalarKey(key))))]))
        }

        var unknown: [(talk: Double, json: JSONValue)] = []
        for group in try groups(try voices(outputDir).filter { $0.name == nil }, GROUP_THRESHOLD) {
            if Set(group.map { ScalarKey($0.meeting) }).count < 2 { continue }
            let total = Py.round(Py.sum(group.map(\.talkSeconds)), 1)  // sum(), compensated
            let voices = Py.stableSorted(group) { Py.less($0.meeting, $1.meeting) }.map { v -> JSONValue in
                .object([("meeting", .string(v.meeting)), ("label", .string(v.label)),
                         ("talk_seconds", .double(Py.round(v.talkSeconds, 1)))])
            }
            unknown.append((total, .object([("voices", .array(voices)), ("talk_seconds", .double(total))])))
        }
        return .object([
            ("people", .array(Py.stableSorted(listed) { $0.talk > $1.talk }.map(\.json))),
            ("unknown", .array(Py.stableSorted(unknown) { $0.talk > $1.talk }.map(\.json))),
        ])
    }

    /// Every voice the user said is not someone ("Not Tom"): (name, unit voice). Negative evidence for recognition and
    /// inference in all meetings.
    public static func rejectedVoices(_ outputDir: URL) throws -> [(String, [Double])] {
        var out: [(String, [Double])] = []
        for paths in meetings(outputDir) {
            let rejected = Speakers.loadRejectedNames(paths)
            if rejected.isEmpty { continue }
            let embeddings = try embeddings(paths)
            for (label, names) in rejected {
                guard let unit = try unitVoice(embeddings[label] ?? .array([])) else { continue }
                out += names.map { ($0, unit) }
            }
        }
        return out
    }

    /// Recognizes the bank's voices in every meeting, then infers the names that follow (`Inference.refresh`);
    /// rewrites the transcripts whose names changed. Returns how many changed. `bank` nil: the voice bank of `stores`,
    /// whose glossary spells transcript.md.
    @discardableResult
    public static func refreshRecognition(outputDir: URL, bank: VoiceBank? = nil, userName: String = "",
                                          stores: StorePaths = .current()) throws -> Int {
        let bank = bank ?? VoiceBank(directory: stores.voices)
        var changed = 0
        let rejected = try rejectedVoices(outputDir)
        for paths in meetings(outputDir) {
            if try recognize(paths, bank: bank, rejected: rejected, stores: stores) { changed += 1 }
        }
        return changed + (try Inference.refresh(outputDir: outputDir, userName: userName, bank: bank, stores: stores))
    }

    /// Recognizes the bank's voices in one meeting (#31: the meeting whose event changed, at once; every other one
    /// after the answer). True when its names changed. `bank`, `rejected`: as `refreshRecognition` has them.
    @discardableResult
    public static func recognize(_ paths: RecordingPaths, bank: VoiceBank? = nil, rejected: [(String, [Double])]? = nil,
                                 stores: StorePaths = .current()) throws -> Bool {
        let bank = bank ?? VoiceBank(directory: stores.voices)
        let rejected = try rejected ?? rejectedVoices(paths.folder.deletingLastPathComponent())
        let raw = try embeddings(paths)
        if raw.isEmpty || !exists(paths.transcriptJson) { return false }
        let invited = CalendarEvents.invitedNames(paths, try bank.names().keys)
        let talk = Speakers.talkSeconds(try turns(paths))
        // A short talker's voice is never read (recognize skips it first).
        let vectors = PyDict(try raw.map { label, value in
            (label, (talk[label] ?? 0.0) < Voices.MIN_TALK_SECONDS ? [] : try VoiceMath.vector(value, "a voice of speaker_embeddings.json"))
        })
        let found = try Voices.recognize(vectors, talk: talk, bank: bank, invited: invited, rejected: rejected)
        let auto = JSONValue.object(found.map { label, hit in
            (label, .object([("name", .string(hit.0)), ("similarity", .double(Py.round(hit.1, 3)))]))
        })
        let wrote = try StoreLock.meeting(paths) { () throws -> Bool in
            var before: JSONValue = .object([])
            if let data = try? Data(contentsOf: paths.speakersAuto), let parsed = try? PythonJSON.parse(data) { before = parsed }
            guard case .object(let stored) = before else { throw SpeakerFileError(description: "speakers_auto.json is not an object") }
            let was = try stored.map { label, hit -> (String, JSONValue) in
                guard case .object = hit, let name = hit["name"] else {
                    throw SpeakerFileError(description: "speakers_auto.json: \(label) has no name")
                }
                return (label, name)
            }
            let now = found.map { ($0.key, JSONValue.string($0.value.0)) }
            if PythonJSON.equal(.object(now), .object(was)) { return false }
            try PythonJSON.write(auto, to: paths.speakersAuto, indent: 2, ensureAscii: false)
            return true
        }
        guard wrote else { return false }
        // Outside the meeting's lock: saving the names learns voices, which takes the bank's.
        try Speakers.saveSpeakerNames(paths, try Speakers.loadSpeakerNames(paths), bank: bank, stores: stores)
        return true
    }

    /// Names the speakers (meeting, label), e.g. one recurring voice in several meetings, then recognizes the voice
    /// everywhere else.
    public static func nameVoices(outputDir: URL, members: [(String, String)], name: String, bank: VoiceBank? = nil,
                                  stores: StorePaths = .current()) throws {
        let bank = bank ?? VoiceBank(directory: stores.voices)
        var byMeeting = PyDict<[String]>()
        for (meeting, label) in members { byMeeting[meeting] = (byMeeting[meeting] ?? []) + [label] }
        for (meeting, labels) in byMeeting {
            let paths = RecordingPaths(outputDir.appendingPathComponent(meeting, isDirectory: true))
            var names = try Speakers.loadSpeakerNames(paths)
            for label in labels { names[label] = name }
            try Speakers.saveSpeakerNames(paths, names, bank: bank, stores: stores)
        }
        try refreshRecognition(outputDir: outputDir, bank: bank, stores: stores)
    }

    /// `old` is called `new` from now on, in every meeting and in the voice bank; renaming onto an existing name merges
    /// the two people.
    public static func renamePerson(outputDir: URL, old: String, new: String, bank: VoiceBank? = nil,
                                    stores: StorePaths = .current()) throws {
        let bank = bank ?? VoiceBank(directory: stores.voices)
        try bank.rename(old, new)
        let oldKey = Py.casefold(old)
        for paths in meetings(outputDir) {
            try StoreLock.meeting(paths) {
                let rejected = Speakers.loadRejectedNames(paths)
                var moved = PyDict<[String]>()
                for (label, names) in rejected {
                    var seen = Set<ScalarKey>(), kept: [String] = []
                    for n in names {
                        let name = Py.same(Py.casefold(n), oldKey) ? new : n
                        if seen.insert(ScalarKey(name)).inserted { kept.append(name) }
                    }
                    moved[label] = kept
                }
                let same = moved.count == rejected.count && moved.allSatisfy { label, names in
                    rejected[label].map { $0.count == names.count && zip($0, names).allSatisfy { Py.same($0, $1) } } ?? false
                }
                if !same {  // "not Tom" is "not Thomas Berg" now
                    try PythonJSON.write(.object(moved.map { ($0.key, .strings($0.value)) }), to: paths.speakersRejected,
                                         indent: 2, ensureAscii: false)
                }
            }
            let names = try Speakers.loadSpeakerNames(paths)
            let renamed = PyDict(names.map { ($0.key, Py.same(Py.casefold($0.value), oldKey) ? new : $0.value) })
            if !Speakers.sameNames(renamed, names) {
                try Speakers.saveSpeakerNames(paths, renamed, bank: bank, stores: stores)
            }
        }
        try refreshRecognition(outputDir: outputDir, bank: bank, stores: stores)
    }

    /// For speakers without a name: people whose voice is close, but not close enough to name them automatically
    /// (label → at most two (name, similarity to 2 digits)).
    public static func suggestions(_ paths: RecordingPaths, bank: VoiceBank? = nil,
                                   stores: StorePaths = .current()) throws -> PyDict<[(String, Double)]> {
        let bank = bank ?? VoiceBank(directory: stores.voices)
        let talk = Speakers.talkSeconds(try turns(paths))
        let naming = try naming(paths)
        let notThem = Speakers.loadRejectedNames(paths)
        let rejected = try rejectedVoices(paths.folder.deletingLastPathComponent())  // this voice, or one like it elsewhere
        var out = PyDict<[(String, Double)]>()
        for (label, value) in try embeddings(paths) {
            if naming[label] != nil || (talk[label] ?? 0.0) < Voices.MIN_TALK_SECONDS { continue }
            let no = Set((notThem[label] ?? []).map { ScalarKey(Py.casefold($0)) })
            let vector = try VoiceMath.vector(value, "a voice of speaker_embeddings.json")
            var close: [(String, Double)] = []
            for (sim, name) in try bank.scores(vector) {
                guard Voices.SUGGEST_THRESHOLD <= sim, sim < Voices.MATCH_THRESHOLD, !no.contains(ScalarKey(Py.casefold(name))) else { continue }
                if try Voices.saidNot(name, vector, rejected, alike: sim) { continue }
                close.append((name, Py.round(sim, 2)))
            }
            if !close.isEmpty { out[label] = Array(close.prefix(2)) }
        }
        return out
    }
}
