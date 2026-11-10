// The read side of the notes (notes.py: load, transcript_hash, shared_lanes, meeting_language, stale_reason,
// backed_name_guesses, with_names). Generation and parsing come in phase 4. The hashes are byte-identical to
// Python's, or every meeting shows "notes out of date".
import CryptoKit
import Foundation
import PalaverCore

public enum Notes {
    /// notes.json as stored, or nil when there is none or it is not JSON.
    public static func load(_ paths: RecordingPaths) -> JSONValue? { NotesFile.load(paths) }

    // MARK: - hashes

    /// Python's `f"{x:.2f}"`: C's `%.2f` rounds the exact binary value half to even, as Python does; only the
    /// spelling of nan and inf differs.
    static func fixed2(_ x: Double) -> String {
        if x.isNaN { return "nan" }
        if x.isInfinite { return x < 0 ? "-inf" : "inf" }
        return String(format: "%.2f", x)
    }

    /// Changes with the words, not with the names given to speakers: sha256 over `label or speaker`, start and
    /// text of each line, the first 16 hex digits.
    public static func transcriptHash(_ utterances: [Utterance]) -> String {
        var h = SHA256()
        for u in utterances {
            let who = (u.label?.isEmpty == false) ? u.label! : u.speaker  // Python's `u.label or u.speaker`
            h.update(data: Data("\(who)\t\(fixed2(u.start))\t\(u.text)\n".utf8))
        }
        return h.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Changes with the user's notes as the model reads them; "" for none.
    public static func myNotesHash(_ text: String) -> String { MyNotes.promptHash(text) }

    // MARK: - shared lanes and language

    private static let speakerLabel = try! PyRegex(#"SPEAKER_\d+"#)

    /// A line of the user's microphone: no diarization label, named or not; not a line the user said is a person's
    /// (#12).
    private static func isMic(_ u: Utterance) -> Bool {
        u.label == nil && u.saidBy == nil && speakerLabel.fullMatch(u.speaker) == nil
    }

    /// The labels of `shared` that have lines here, and "mic" when the microphone's lines are several people's
    /// (`mic`: what they show). Labels in code-point order.
    public static func sharedLanes(_ utterances: [Utterance], shared: PyDict<String>, mic: String? = nil) -> [String] {
        var seen = Set<ScalarKey>(), found: [String] = []
        for u in utterances {
            guard let label = u.label, shared[label] != nil, seen.insert(ScalarKey(label)).inserted else { continue }
            found.append(label)
        }
        let out = Py.stableSorted(found, by: Py.less)
        return (mic.map { !$0.isEmpty } ?? false) && utterances.contains(where: isMic) ? out + ["mic"] : out
    }

    private static let germanWords = Set(Readable.german.map(ScalarKey.init))
    private static let englishWords = Set(Readable.english.map(ScalarKey.init))

    /// "de" or "en": whichever of the two has more of its common words in the meeting. nil when too few words
    /// are either's: another language, or too little said to tell.
    public static func meetingLanguage(_ utterances: [Utterance]) -> String? {
        let words = utterances.flatMap { Py.split($0.text) }.map { ScalarKey(Readable.core($0)) }
        let german = words.filter(germanWords.contains).count
        let english = words.filter(englishWords.contains).count
        if german + english < 3 || Double(german + english) < 0.1 * Double(words.count) || german == english { return nil }
        return german > english ? "de" : "en"
    }

    // MARK: - staleness

    /// Why the notes are out of date: "missing", "transcript" (its words changed), "my_notes" (the user's own
    /// notes changed) or "shared" (voices were said to be several people, or one again); nil when they are up to
    /// date. notes.json that is not an object counts as missing (Python raises there).
    public static func staleReason(_ paths: RecordingPaths, _ utterances: [Utterance]) -> String? {
        guard let current = load(paths), case .object = current else { return "missing" }
        func same(_ v: JSONValue?, _ want: String) -> Bool { v?.stringValue.map { Py.same($0, want) } ?? false }
        if !same(current["transcript_hash"], transcriptHash(utterances)) { return "transcript" }
        let mine = myNotesHash(MyNotes.promptText(paths.folder))
        if !(current["my_notes_hash"] == nil ? mine.isEmpty : same(current["my_notes_hash"], mine)) { return "my_notes" }
        let lanes = sharedLanes(utterances, shared: SharedMic.display(paths), mic: SharedMic.micDisplay(paths))
        let stored = current["shared_lanes"] ?? .array([])
        let matches = stored.arrayValue.map { items in
            items.count == lanes.count && zip(items, lanes).allSatisfy { same($0, $1) }
        } ?? false
        return matches ? nil : "shared"
    }

    public static func isStale(_ paths: RecordingPaths, _ utterances: [Utterance]) -> Bool {
        staleReason(paths, utterances) != nil
    }

    // MARK: - name guesses

    private static let selfIntro = #"(?:i'm|i am|my name is|this is|ich bin|mein name ist|hier ist|hier spricht)\s+"#
    private static let greeting = #"(?:hi|hey|hallo|hello|servus|moin|ciao|danke|thanks|thank you|merci"#
        + #"|over to you|back to you|go ahead|übergebe(?: ich)? an|weiter an)"#
    private static let nameParticles: Set<ScalarKey> = Set(
        ["von", "van", "der", "den", "de", "del", "della", "da", "di", "du", "le", "la",
         "zu", "zum", "zur", "ter", "ten", "y", "bin", "al", "el"].map(ScalarKey.init))
    private static let maxNameWords = 2
    private static let nameWord = try! PyRegex(#"[^\W\d_]+(?:['’-][^\W\d_]+)*"#)

    /// A guessed name, judged by itself: German capitalizes nouns ("ich bin Anna Huber Projektleiterin").
    static func looksLikeAName(_ name: String) -> Bool {
        let words = Py.split(name).filter { !nameParticles.contains(ScalarKey(Py.strLower($0))) }
        return !words.isEmpty && words.count <= maxNameWords
            && words.allSatisfy { Py.strIsUpper(String($0.unicodeScalars.first!)) && nameWord.fullMatch($0) != nil }
    }

    private static func pyEqual(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
        if let x = a?.stringValue, let y = b?.stringValue { return Py.same(x, y) }
        return a == b
    }

    /// The model's name guesses (objects with "label" and "name") that the transcript supports: someone else
    /// addresses the label by the name and the label answers next ("Hi Rico." then Rico replies), or the label
    /// introduces itself ("ich bin Andrea"). The name has to come right after the introduction or the greeting,
    /// as whole words, and look like a first and last name at most.
    public static func backedNameGuesses(_ guesses: [JSONValue], _ utterances: [Utterance], glossary: Glossary? = nil) -> [JSONValue] {
        let lines = Readable.readable(utterances, glossary: glossary)
        func speaker(_ u: Utterance) -> String { (u.label?.isEmpty == false) ? u.label! : u.speaker }
        var kept: [JSONValue] = []
        for guess in guesses {
            guard case .object = guess else { continue }
            let label = guess["label"] ?? .string("")
            let name: String
            switch guess["name"] {  // `str(guess.get("name") or "").strip()`
            case .string(let s)?: name = Py.strip(s)
            case .bool(true)?: name = "True"
            default: name = ""
            }
            guard looksLikeAName(name) else { continue }
            let escaped = PyRegex.escape(name)
            guard let said = try? PyRegex(#"\b"# + escaped + #"\b"#, ignoreCase: true),
                  let intro = try? PyRegex(selfIntro + escaped + #"\b"#, ignoreCase: true),
                  let address = try? PyRegex(
                    #"(?:\b"# + greeting + #"\s+"# + escaped + #"\b|(?:^|[,;:]\s*)"# + escaped + #"\b(?=\s*(?:[,.?!;:]|$)))"#,
                    ignoreCase: true) else { continue }
            var backed = false
            for (i, u) in lines.enumerated() {
                let who = speaker(u)
                guard said.firstMatch(in: u.text) != nil else { continue }
                if pyEqual(.string(who), label) {
                    if intro.firstMatch(in: u.text) != nil { backed = true; break }
                } else if address.firstMatch(in: u.text) != nil {
                    let reply = lines[(i + 1)..<min(i + 4, lines.count)].first { !Py.same(speaker($0), who) }
                    if let reply, pyEqual(.string(speaker(reply)), label) { backed = true; break }
                }
            }
            guard backed else { continue }
            if !kept.contains(where: { pyEqual($0["label"], label) && pyEqual($0["name"], .string(name)) }) { kept.append(guess) }
        }
        return kept
    }

    // MARK: - with names

    /// `value` (notes or any part of them) with the labels of `names` replaced as whole words, longest first.
    public static func withNames(_ value: JSONValue, _ names: PyDict<String>) -> JSONValue {
        if names.isEmpty { return value }
        let longest = Py.stableSorted(names.keys, by: { $0.unicodeScalars.count > $1.unicodeScalars.count })
        let pattern = try! PyRegex(#"\b("# + longest.map(PyRegex.escape).joined(separator: "|") + #")\b"#)
        func sub(_ v: JSONValue) -> JSONValue {
            switch v {
            case .string(let s): return .string(pattern.sub(in: s) { names[$0.group(1) ?? ""] ?? "" })
            case .array(let items): return .array(items.map(sub))
            case .object(let fields): return .object(fields.map { ($0.0, sub($0.1)) })
            default: return v
            }
        }
        return sub(value)
    }
}
