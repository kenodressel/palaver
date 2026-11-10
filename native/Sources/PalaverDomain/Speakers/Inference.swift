// Speakers named by inference (inference.py, issue #38). With the calendar and enough meetings, many voices can be named
// without anyone typing a name:
// - calendar: a 1:1 — one other person invited, one other voice that talks;
// - elimination: five invited, four of them named; the one voice left is the one person left;
// - intersection: a voice that recurs in several meetings; the only invitee all of those meetings share;
// - voice: a voice like one named by the rules above, in another meeting (among its invitees first).
// Each inferred name records the rule, why, how sure it is, and which other names it rests on. Inferences are
// recomputed from the facts every time (names given by hand, voices the bank recognizes, calendars, the voices
// themselves), so correcting or rejecting a name takes back everything built on it. Inferred voices never enter the
// voice bank. Stored per meeting in `speakers_inferred.json`, written under the meeting's lock, which is let go before
// the names are saved (that takes the voice bank's).
import Foundation
import PalaverCore

public enum Inference {
    /// A voice must talk this much to be inferred from the calendar: short stretches are often a split-off part of
    /// someone else.
    public static let INFER_MIN_TALK = 30.0
    /// Other unnamed voices may talk at most this share of the inferred one.
    public static let MINOR_SHARE = 0.2
    /// How sure each rule is on its own, and the least a chain may end with.
    public static let CONFIDENCE = PyDict<Double>([("calendar", 0.9), ("elimination", 0.85), ("intersection", 0.75)])
    /// A clear voice match, or only among the invitees.
    public static let VOICE_CONFIDENCE: [Bool: Double] = [true: 0.9, false: 0.8]
    /// imported: a name the sender gave (#58).
    public static let FACT_CONFIDENCE = PyDict<Double>([("you", 1.0), ("voice", 0.95), ("imported", 0.9)])
    public static let MIN_CONFIDENCE = 0.5
    public static let ROUNDS = 6

    /// An inferred name (Python's `Inference`).
    public struct Entry {
        public let name: String
        public let rule: String
        public let why: String
        public let confidence: Double
        /// "meeting:label" of the names it rests on.
        public let depends: [String]

        /// `asdict`, as stored.
        public var json: JSONValue {
            .object([("name", .string(name)), ("rule", .string(rule)), ("why", .string(why)),
                     ("confidence", .double(confidence)), ("depends", .strings(depends))])
        }
    }

    /// `_Meeting`: what the rules know of one meeting.
    struct Meeting {
        let id: String
        let title: String
        /// Unit length; merged-away labels left out.
        let embeddings: PyDict<[Double]>
        let talk: PyDict<Double>
        /// Invitees as named elsewhere; nil: no event, or a room on it.
        let candidates: [String]?
        /// label → (name, "you" | "voice" | "imported")
        let fixed: PyDict<(String, String)>
        /// Labels whose recognized or inferred name the user rejected.
        let blocked: Set<ScalarKey>
        /// label → casefolded names it is not (each once).
        let rejected: PyDict<[String]>

        func isRejected(_ label: String, _ name: String) -> Bool {
            let key = Py.casefold(name)
            return (rejected[label] ?? []).contains { Py.same($0, key) }
        }
    }

    /// "meeting:label" split at its first colon.
    private static func split(_ key: String) -> (String, String) {
        let scalars = Array(key.unicodeScalars)
        guard let colon = scalars.firstIndex(of: ":") else { return (key, "") }
        var a = String.UnicodeScalarView(), b = String.UnicodeScalarView()
        a.append(contentsOf: scalars[..<colon])
        b.append(contentsOf: scalars[(colon + 1)...])
        return (String(a), String(b))
    }

    /// Each casefolded name once, in order (Python's set of casefolded names; only membership is used).
    private static func casefoldedSet(_ names: [String]) -> [String] {
        var seen = Set<ScalarKey>(), out: [String] = []
        for n in names {
            let key = Py.casefold(n)
            if seen.insert(ScalarKey(key)).inserted { out.append(key) }
        }
        return out
    }

    /// `_load`: every recording folder with voices, as the rules see it. `known`: names to resolve invitees to.
    static func loadMeetings(_ outputDir: URL, userName: String, known: [String], stores: StorePaths) throws -> [Meeting] {
        var out: [Meeting] = []
        for name in People.sortedNames(outputDir) {
            let paths = RecordingPaths(outputDir.appendingPathComponent(name, isDirectory: true))
            guard RecordingPaths.isRecordingFolderName(name), People.exists(paths.speakerEmbeddings) else { continue }
            guard let raw = PythonJSON.read(paths.speakerEmbeddings), let turnList = PythonJSON.read(paths.systemTurns) else { continue }
            guard let turnItems = turnList.arrayValue else { throw SpeakerFileError(description: "system_turns.json is not a list") }
            var turns: [SpeakerTurn] = []
            var unreadable = false
            for item in turnItems {
                do { turns.append(try SpeakerTurn(json: item)) } catch let e as ModelError where e.description.hasPrefix("ValueError") {
                    unreadable = true  // Python skips the meeting on ValueError (a time that is no number)
                    break
                }
            }
            if unreadable { continue }
            let merges = Speakers.loadMerges(paths)
            let manual = try Speakers.loadSpeakerNames(paths)
            let blocked = Set(manual.filter { Py.same($0.value, $0.key) }.map { ScalarKey($0.key) })
            let rejectedNames = Speakers.loadRejectedNames(paths)
            let notNames = PyDict(rejectedNames.map { ($0.key, casefoldedSet($0.value)) })
            // Names an imported meeting came with (#58) are known here: no rule gives them to another voice.
            var fixed = PyDict<(String, String)>()
            for (label, hint) in ExchangeHints.hints(paths) where !blocked.contains(ScalarKey(label)) && merges[label] == nil {
                guard case .string(let hinted)? = hint["name"] else { throw SpeakerFileError(description: "an imported name is not text") }
                let key = Py.casefold(hinted)
                if (notNames[label] ?? []).contains(where: { Py.same($0, key) }) { continue }
                fixed[label] = (hinted, "imported")
            }
            for (label, hit) in try Speakers.loadRecognizedNames(paths) where !blocked.contains(ScalarKey(label)) && merges[label] == nil {
                fixed[label] = (hit.0, "voice")
            }
            for (label, given) in manual where !Py.same(given, label) && merges[label] == nil { fixed[label] = (given, "you") }
            let event = CalendarEvents.load(paths)
            var candidates: [String]?
            // Several people on one voice (#56): any invitee may have been among them, so who is left by elimination is
            // not known.
            if let event, !event.attendees.contains(where: \.isRoom), !SharedMic.marked(paths) {
                candidates = CalendarEvents.candidates(event, userName: userName).map { a in
                    if let resolved = CalendarEvents.resolve(a.name, known), !resolved.isEmpty { return resolved }
                    return a.name
                }
            }
            // Noise: as if nobody spoke. Several people on one voice (#56): no one to infer.
            let ignored = Set(Speakers.loadIgnored(paths).map(ScalarKey.init)).union(SharedMic.sharedLabels(paths))
            guard case .object(let fields) = raw else { throw SpeakerFileError(description: "speaker_embeddings.json is not an object") }
            var embeddings = PyDict<[Double]>()
            for (label, value) in fields where merges[label] == nil && !ignored.contains(ScalarKey(label)) {
                let v = try VoiceMath.vector(value, "a voice of speaker_embeddings.json")
                guard v.allSatisfy(\.isFinite), v.contains(where: { $0 != 0 }) else { continue }
                embeddings[label] = VoiceMath.unit(v)
            }
            let talk = PyDict(Speakers.talkSeconds(Speakers.mergedTurns(turns, merges)).filter { !ignored.contains(ScalarKey($0.key)) }
                .map { ($0.key, $0.value) })
            fixed = PyDict(fixed.filter { !ignored.contains(ScalarKey($0.key)) }.map { ($0.key, $0.value) })
            let title = Titles.resolve(paths, event: .known(event), stores: stores).title
            out.append(Meeting(id: name, title: (title?.isEmpty ?? true) ? name : title!, embeddings: embeddings, talk: talk,
                               candidates: candidates, fixed: fixed, blocked: blocked, rejected: notNames))
        }
        return out
    }

    /// `_InferredVoices`: voices named by inference, shaped like the voice bank for `Voices.recognize`.
    struct InferredVoices: VoiceScoring {
        /// (name, unit embedding, "meeting:label")
        let samples: [(String, [Double], String)]

        /// name → (best similarity, the sample's "meeting:label"), the first of equally good samples.
        func best(_ embedding: [Double]) throws -> PyDict<(Double, String)> {
            let query = VoiceMath.unit(embedding)
            var best = PyDict<(Double, String)>()
            for (name, vector, key) in samples {
                let sim = try VoiceMath.dot(vector, query)
                if let current = best[name], !(sim > current.0) { continue }
                best[name] = (sim, key)
            }
            return best
        }

        func scores(_ embedding: [Double]) throws -> [(Double, String)] {
            let found = try best(embedding).map { ($0.value.0, $0.key) }
            // sorted(reverse=True) on (similarity, name) tuples.
            return Py.stableSorted(found) { a, b in a.0 > b.0 || (a.0 == b.0 && Py.less(b.1, a.1)) }
        }
    }

    /// meeting id → label → inferred name, from the facts in `meetings`.
    static func infer(_ meetings: [Meeting]) throws -> PyDict<PyDict<Entry>> {
        var inferred = PyDict(meetings.map { ($0.id, PyDict<Entry>()) })
        let byId = PyDict(meetings.map { ($0.id, $0) })

        func named(_ m: Meeting) -> PyDict<String> {
            var out = PyDict(m.fixed.map { ($0.key, $0.value.0) })
            for (label, i) in inferred[m.id]! { out[label] = i.name }
            return out
        }

        func confidence(_ key: String) -> Double {
            let (mid, label) = split(key)
            let m = byId[mid]!
            if let fact = m.fixed[label] { return FACT_CONFIDENCE[fact.1]! }
            return inferred[mid]![label]!.confidence
        }

        func remaining(_ m: Meeting) -> [String] {
            let used = Set(named(m).values.map { ScalarKey(Py.casefold($0)) })
            var seen = Set<ScalarKey>(), out: [String] = []
            for c in m.candidates ?? [] where seen.insert(ScalarKey(c)).inserted {
                if !used.contains(ScalarKey(Py.casefold(c))) { out.append(c) }
            }
            return out
        }

        // Voices the user said are not someone: neither they nor voices like them get that name.
        var saidNo: [(String, [Double])] = []
        for m in meetings {
            for (label, names) in m.rejected {
                guard let voice = m.embeddings[label] else { continue }
                saidNo += names.map { ($0, voice) }
            }
        }

        /// `alike`: how alike the voice is to the person's (the voice rule's similarity): a rejected voice must be more
        /// alike than that to block it.
        func add(_ m: Meeting, _ label: String, _ inference: Entry, alike: Double = 0.0) throws -> Bool {
            if inference.confidence < MIN_CONFIDENCE || inferred[m.id]![label] != nil { return false }
            if m.isRejected(label, inference.name) { return false }
            if let voice = m.embeddings[label], try Voices.saidNot(inference.name, voice, saidNo, alike: alike) { return false }
            let key = Py.casefold(inference.name)
            if named(m).values.contains(where: { Py.same(Py.casefold($0), key) }) { return false }
            inferred[m.id]![label] = inference
            return true
        }

        for _ in 0..<ROUNDS {
            var added = false
            for m in meetings {
                guard let candidates = m.candidates else { continue }
                let names = named(m)
                let talking = Py.stableSorted(m.talk.keys, by: Py.less).filter { m.talk[$0]! >= INFER_MIN_TALK }
                let unnamed = talking.filter { names[$0] == nil && !m.blocked.contains(ScalarKey($0)) }
                let left = remaining(m)
                if unnamed.count != 1 || left.count != 1 || talking.count > Set(candidates.map(ScalarKey.init)).count { continue }
                let label = unnamed[0]
                let minor = Py.sum(m.talk.filter { other, t in  // Python's sum(), compensated, in the dict's order
                    !Py.same(other, label) && names[other] == nil && Voices.MIN_TALK_SECONDS <= t && t < INFER_MIN_TALK
                }.map(\.value))
                if minor > MINOR_SHARE * m.talk[label]! { continue }  // another voice might be the same person, or someone uninvited
                let invited = Set(candidates.map { ScalarKey(Py.casefold($0)) })
                let depends = Py.stableSorted(names.filter { invited.contains(ScalarKey(Py.casefold($0.value))) }
                    .map { "\(m.id):\($0.key)" }, by: Py.less)
                let inference: Entry
                if depends.isEmpty {
                    let minutes = try Py.roundInt(m.talk[label]! / 60)
                    inference = Entry(name: left[0], rule: "calendar",
                                      why: "Only \(left[0]) was invited besides you, and this is the only other voice (\(minutes) min).",
                                      confidence: CONFIDENCE["calendar"]!, depends: [])
                } else {
                    let others = depends.map { names[split($0).1]! }.joined(separator: ", ")
                    let conf = CONFIDENCE["elimination"]! * depends.map(confidence).min()!
                    inference = Entry(name: left[0], rule: "elimination",
                                      why: "\(left[0]) is the one invitee left: \(others) \(depends.count == 1 ? "is" : "are") known here.",
                                      confidence: Py.round(conf, 3), depends: depends)
                }
                added = try add(m, label, inference) || added
            }

            // Voices like an inferred one, in other meetings.
            var samples: [(String, [Double], String)] = []
            for (mid, labels) in inferred {
                let source = byId[mid]!
                for (label, i) in labels {
                    guard let voice = source.embeddings[label], (source.talk[label] ?? 0) >= INFER_MIN_TALK else { continue }
                    samples.append((i.name, voice, "\(mid):\(label)"))
                }
            }
            if !samples.isEmpty {
                for m in meetings {
                    let names = named(m)
                    let pool = InferredVoices(samples: samples.filter { !$0.2.hasPrefixScalars("\(m.id):") })
                    let open = PyDict(m.embeddings.filter { names[$0.key] == nil && !m.blocked.contains(ScalarKey($0.key)) }
                        .map { ($0.key, $0.value) })
                    for (label, hit) in try Voices.recognize(open, talk: m.talk, bank: pool, invited: m.candidates, rejected: saidNo) {
                        let (name, sim) = hit
                        let key = try pool.best(m.embeddings[label]!)[name]!.1
                        let source = byId[split(key).0]!
                        let conf = confidence(key) * VOICE_CONFIDENCE[sim >= Voices.MATCH_THRESHOLD]!
                        let why = "Same voice as \(name) in “\(source.title)” (\(String(format: "%.2f", sim)))."
                        added = try add(m, label, Entry(name: name, rule: "voice", why: why, confidence: Py.round(conf, 3), depends: [key]),
                                        alike: sim) || added
                    }
                }
            }

            // A recurring voice and the one invitee its meetings share.
            added = try intersections(meetings, byId, named, remaining, add) || added
            if !added { break }
        }
        return PyDict(inferred.filter { !$0.value.isEmpty }.map { ($0.key, $0.value) })
    }

    /// `_intersections`: a voice heard in several meetings (one voice per meeting), the only invitee left in all of them.
    private static func intersections(_ meetings: [Meeting], _ byId: PyDict<Meeting>, _ named: (Meeting) -> PyDict<String>,
                                      _ remaining: (Meeting) -> [String],
                                      _ add: (Meeting, String, Entry, Double) throws -> Bool) throws -> Bool {
        var voices: [Voice] = []
        for m in meetings where m.candidates != nil {
            for (label, embedding) in m.embeddings
            where (m.talk[label] ?? 0) >= INFER_MIN_TALK && named(m)[label] == nil && !m.blocked.contains(ScalarKey(label)) {
                voices.append(Voice(meeting: m.id, label: label, talkSeconds: m.talk[label]!, embedding: embedding, name: nil, namedBy: nil))
            }
        }
        var added = false
        for group in try People.groups(voices, People.GROUP_THRESHOLD) {
            // The group's meetings in the order of their voices (Python iterates a set: see the ledger).
            var meetingIds: [String] = [], seen = Set<ScalarKey>()
            for v in group where seen.insert(ScalarKey(v.meeting)).inserted { meetingIds.append(v.meeting) }
            if meetingIds.count < 2 || group.count != meetingIds.count { continue }  // one voice per meeting, in several meetings
            var shared: PyDict<String>?
            for mid in meetingIds {
                var left = PyDict<String>()
                for c in remaining(byId[mid]!) { left[Py.casefold(c)] = c }
                shared = shared.map { PyDict($0.filter { left[$0.key] != nil }.map { ($0.key, $0.value) }) } ?? left
            }
            guard let shared, shared.count == 1 else { continue }
            let name = shared.values[0]
            let why = "A voice heard in \(meetingIds.count) meetings; \(name) is the only invitee they all share."
            for v in group {
                added = try add(byId[v.meeting]!, v.label, Entry(name: name, rule: "intersection", why: why,
                                                                  confidence: CONFIDENCE["intersection"]!, depends: []), 0.0) || added
            }
        }
        return added
    }

    /// speakers_inferred.json as stored, or nil when it is missing or not JSON.
    private static func stored(_ paths: RecordingPaths) -> JSONValue? { PythonJSON.read(paths.speakersInferred) }

    /// label → the inference (as stored) for one meeting; none when the file is missing, broken or not an object.
    public static func load(_ paths: RecordingPaths) -> PyDict<JSONValue> {
        stored(paths).flatMap { PyDict<JSONValue>($0) } ?? PyDict()
    }

    /// Infers names in every meeting again; rewrites the transcripts whose inferred names changed. Returns how many
    /// changed. `bank` nil: the voice bank of `stores`, whose glossary spells transcript.md.
    @discardableResult
    public static func refresh(outputDir: URL, userName: String = "", bank: VoiceBank? = nil,
                               stores: StorePaths = .current()) throws -> Int {
        let bank = bank ?? VoiceBank(directory: stores.voices)
        var meetings = try loadMeetings(outputDir, userName: userName, known: try bank.names().keys, stores: stores)
        var seen = Set<ScalarKey>(), names: [String] = []
        for name in meetings.flatMap({ $0.fixed.values.map(\.0) }) + (try bank.names().keys) where seen.insert(ScalarKey(name)).inserted {
            names.append(name)
        }
        meetings = try loadMeetings(outputDir, userName: userName, known: Py.stableSorted(names, by: Py.less), stores: stores)
        let result = try infer(meetings)
        var changed = 0
        for m in meetings {
            let paths = RecordingPaths(outputDir.appendingPathComponent(m.id, isDirectory: true))
            var new = PyDict<JSONValue>()
            if let found = result[m.id] {
                for label in Py.stableSorted(found.keys, by: Py.less) { new[label] = found[label]!.json }
            }
            // Names that came with an import (#58) are facts of the file, not of the rules: kept, unless a rule is surer.
            for (label, hint) in ExchangeHints.hints(paths) {
                if let current = new[label], let mine = current["confidence"]?.doubleValue, let theirs = hint["confidence"]?.doubleValue,
                   !(mine < theirs) { continue }
                new[label] = hint
            }
            new = PyDict(Py.stableSorted(Array(new)) { Py.less($0.key, $1.key) }.map { ($0.key, $0.value) })
            let wrote = try StoreLock.meeting(paths) { () throws -> Bool in
                if PythonJSON.equal(new.json, stored(paths) ?? .object([])) { return false }
                if !new.isEmpty {
                    try PythonJSON.write(new.json, to: paths.speakersInferred, indent: 2, ensureAscii: false)
                } else if People.exists(paths.speakersInferred) {
                    try FileManager.default.removeItem(at: paths.speakersInferred)
                }
                return true
            }
            guard wrote else { continue }
            // Outside the meeting's lock: saving the names learns voices, which takes the bank's.
            if People.exists(paths.transcriptJson) && People.exists(paths.meta) {
                try Speakers.saveSpeakerNames(paths, try Speakers.loadSpeakerNames(paths), bank: bank, stores: stores)
            }
            changed += 1
        }
        return changed
    }
}
