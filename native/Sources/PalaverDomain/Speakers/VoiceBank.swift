// The voice bank and automatic speaker recognition (voices.py, issue #13). Voice embeddings are biometric data: they
// live only on this Mac, in `<config>/palaver/voices/` (one JSON file per person), are added only when a speaker is
// named, and removed with `forget`. Recognition compares a diarized speaker's embedding with every stored sample
// (cosine similarity, best sample per person); a wrong name is worse than none, so the thresholds are conservative.
import Darwin
import Foundation
import PalaverCore

/// A voice file or an embedding Python's voice code would raise on: not JSON, not an object, a missing key, a value
/// of the wrong kind, or vectors of two lengths (numpy's shape error).
public struct VoiceError: Error, CustomStringConvertible {
    public let description: String
}

/// numpy's vector math as voices.py and speakers.py use it, number for number.
enum VoiceMath {
    private typealias DDot = @convention(c) (Int, UnsafePointer<Double>?, Int, UnsafePointer<Double>?, Int) -> Double

    /// The `cblas_ddot` numpy calls for `a @ b` and `np.linalg.norm` on float64 vectors: numpy is built against
    /// Accelerate's ILP64 interface (`cblas_ddot$NEWLAPACK$ILP64`). Found by name, as numpy links it; Swift's own
    /// `cblas_ddot` is the deprecated LP64 entry point.
    private static let ddot: DDot? = {
        guard let lib = dlopen("/System/Library/Frameworks/Accelerate.framework/Accelerate", RTLD_NOW),
              let symbol = dlsym(lib, "cblas_ddot$NEWLAPACK$ILP64") else { return nil }
        return unsafeBitCast(symbol, to: DDot.self)
    }()

    /// `float(a @ b)`; vectors of two lengths are numpy's ValueError.
    static func dot(_ a: [Double], _ b: [Double]) throws -> Double {
        guard a.count == b.count else {
            throw VoiceError(description: "matmul: Input operand 1 has a mismatch in its core dimension 0 (size \(b.count) is different from \(a.count))")
        }
        guard let ddot else {
            // Never on macOS 15: Accelerate has the symbol. Without it the sums are no longer numpy's to the bit.
            Blas.fellBack("cblas_ddot$NEWLAPACK$ILP64")
            assertionFailure("VoiceMath: Accelerate's cblas_ddot$NEWLAPACK$ILP64 is missing")
            return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        }
        return a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in ddot(a.count, pa.baseAddress, 1, pb.baseAddress, 1) } }
    }

    /// `_unit`: `v / np.linalg.norm(v)`, or `v` when its norm is 0.
    static func unit(_ v: [Double]) -> [Double] {
        let norm = (try? dot(v, v)).map { $0.squareRoot() } ?? 0
        return norm != 0 ? v.map { $0 / norm } : v
    }

    /// `float(_unit(a) @ _unit(b))`.
    static func cosine(_ a: [Double], _ b: [Double]) throws -> Double { try dot(unit(a), unit(b)) }

    /// Python's `float(value)` of a JSON value: a number, a bool or a numeric string; nil where it raises.
    static func pyFloat(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let d)?: return d
        case .int(let i)?: return Double(i)
        case .bool(let b)?: return b ? 1 : 0
        case .string(let s)?: return Double(Py.strip(s))
        default: return nil
        }
    }

    /// `np.asarray(value, dtype=float)` of a stored list: ints, floats and booleans.
    static func vector(_ value: JSONValue?, _ what: String) throws -> [Double] {
        guard let items = value?.arrayValue else { throw VoiceError(description: "\(what) is not a list of numbers") }
        return try items.map { item in
            switch item {
            case .double(let d): return d
            case .int(let i): return Double(i)
            case .bool(let b): return b ? 1 : 0
            default: throw VoiceError(description: "\(what) is not a list of numbers")
            }
        }
    }
}

public enum Voices {
    public static let MATCH_THRESHOLD = 0.75
    public static let MATCH_MARGIN = 0.1
    /// Below MATCH_THRESHOLD but this close: offered as a suggestion, not applied.
    public static let SUGGEST_THRESHOLD = 0.65
    /// A voice the user said is not someone counts against that person for voices at least this alike (and more
    /// alike than the person's own samples): the same person in two meetings scores 0.80-0.96, different people up
    /// to 0.76.
    public static let REJECT_SIMILAR = 0.75
    /// Embeddings of speakers with less talk time than this are too noisy to enrol or to recognize.
    public static let MIN_TALK_SECONDS = 10.0
    public static let MAX_SAMPLES_PER_PERSON = 20

    /// `_slug`: `re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "speaker"` (Python's `lower`, Unicode 15.1).
    public static func slug(_ name: String) -> String {
        var out = String.UnicodeScalarView()
        var dash = false
        for u in Py.strLower(name).unicodeScalars {
            if ("a"..."z").contains(u) || ("0"..."9").contains(u) {
                out.append(u)
                dash = false
            } else if !dash {
                out.append("-")
                dash = true
            }
        }
        let text = String(out).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return text.isEmpty ? "speaker" : text
    }

    /// `said_not`: the user said a voice like `embedding` is not `name`: one of the `rejected` voices (name,
    /// embedding) given that name is at least REJECT_SIMILAR alike, and more alike than `alike` (how close the voice
    /// is to the person's own samples).
    public static func saidNot(_ name: String, _ embedding: [Double], _ rejected: [(String, [Double])], alike: Double = 0.0) throws -> Bool {
        let query = VoiceMath.unit(embedding)
        let key = Py.casefold(name)
        for (n, v) in rejected where Py.same(Py.casefold(n), key) {
            if try VoiceMath.dot(VoiceMath.unit(v), query) >= max(REJECT_SIMILAR, alike) { return true }
        }
        return false
    }

    /// `recognize`: label → (name, similarity) for the speakers the bank recognizes, labels in sorted order.
    /// `invited` (names as the bank knows them) are the people the calendar says were there: among them
    /// SUGGEST_THRESHOLD is enough, since the voice only has to be told apart from a few; otherwise, or when none of
    /// them matches, MATCH_THRESHOLD against everyone. `rejected`: voices the user said are not someone (`saidNot`).
    /// That leaves no guess by elimination: the next best must clear MATCH_THRESHOLD and beat everyone, the rejected
    /// name included, by MATCH_MARGIN; the invitees' easier threshold no longer applies to this voice.
    public static func recognize(_ embeddings: PyDict<[Double]>, talk: PyDict<Double>, bank: some VoiceScoring,
                                 invited: [String]? = nil, rejected: [(String, [Double])] = []) throws -> PyDict<(String, Double)> {
        let allowed = Set((invited ?? []).map { ScalarKey(Py.casefold($0)) })
        var found = PyDict<(String, Double)>()
        for label in Py.stableSorted(embeddings.keys, by: Py.less) {
            let embedding = embeddings[label]!
            if (talk[label] ?? 0.0) < MIN_TALK_SECONDS { continue }
            let everyone = try bank.scores(embedding)
            var scores: [(Double, String)] = []
            for (sim, name) in everyone {
                if !rejected.isEmpty, try saidNot(name, embedding, rejected, alike: sim) { continue }
                scores.append((sim, name))
            }
            let saidNo = scores.count < everyone.count
            var hit: (String, Double)?
            if !allowed.isEmpty && !saidNo {
                let among = scores.filter { allowed.contains(ScalarKey(Py.casefold($0.1))) }
                if let first = among.first, first.0 >= SUGGEST_THRESHOLD,
                   among.count == 1 || first.0 - among[1].0 >= MATCH_MARGIN {
                    hit = (first.1, first.0)
                }
            }
            if hit == nil, let top = scores.first, top.0 >= MATCH_THRESHOLD {
                let (bestSim, best) = top
                let rivals = everyone.filter { !Py.same($0.1, best) }.map(\.0)
                if rivals.isEmpty || bestSim - rivals.max()! >= MATCH_MARGIN { hit = (best, bestSim) }
            }
            if let hit { found[label] = hit }
        }
        return found
    }
}

/// What `recognize` asks of a bank: (similarity, name) per person, best first. The voice bank, and inference's voices
/// named by the rules (`_InferredVoices`).
public protocol VoiceScoring {
    func scores(_ embedding: [Double]) throws -> [(Double, String)]
}

/// The voice bank: `<config>/palaver/voices/<slug>.json`, `{"name", "samples": [{"embedding", "source", "added"}]}`
/// written like Python's `json.dumps(ensure_ascii=False)`. Every writer holds `voices.lock` beside the folder.
public final class VoiceBank: VoiceScoring {
    public let directory: URL
    private let now: () -> Date

    /// `directory` nil: the user's (`StorePaths.current().voices`). `now` stamps a sample's `added`.
    public init(directory: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.directory = directory ?? StorePaths.current().voices
        self.now = now
    }

    private struct Person {
        let file: URL
        let data: PyDict<JSONValue>
        let samples: [JSONValue]
    }

    /// `_people`: name → (file, data), the files `*.json` in sorted order (a later file of the same name wins, in
    /// the first one's place). A file that is not a person (not JSON, no name or samples) is an error, as in Python.
    private func people() throws -> PyDict<Person> {
        var people = PyDict<Person>()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else { return people }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffixScalars(".json") }
        for name in Py.stableSorted(names, by: Py.less) {
            let file = directory.appendingPathComponent(name)
            let parsed: JSONValue
            do { parsed = try PythonJSON.parse(Data(contentsOf: file)) } catch {
                throw VoiceError(description: "\(file.path): \(error)")
            }
            guard let data = PyDict<JSONValue>(parsed), let person = data["name"]?.stringValue,
                  let samples = data["samples"]?.arrayValue else {
                throw VoiceError(description: "\(file.path) is no voice file")
            }
            people[person] = Person(file: file, data: data, samples: samples)
        }
        return people
    }

    private func find(_ name: String) throws -> Person? {
        let key = Py.casefold(name)
        return try people().first { Py.same(Py.casefold($0.key), key) }?.value
    }

    private static func source(_ sample: JSONValue) throws -> JSONValue {
        guard let source = sample["source"] else { throw VoiceError(description: "KeyError: 'source'") }
        return source
    }

    private static func isSource(_ sample: JSONValue, _ source: String) throws -> Bool {
        guard case .string(let s) = try Self.source(sample) else { return false }
        return Py.same(s, source)
    }

    private func write(_ data: PyDict<JSONValue>, _ file: URL) throws {
        try PythonJSON.write(data.json, to: file, indent: nil, ensureAscii: false)
    }

    /// Enrolled people and their number of voice samples.
    public func names() throws -> PyDict<Int> {
        PyDict(try people().map { ($0.key, $0.value.samples.count) })
    }

    /// Stores a voice sample; `source` (recording:label) dedupes repeats. The oldest samples beyond
    /// MAX_SAMPLES_PER_PERSON go.
    @discardableResult
    public func add(_ name: String, _ embedding: [Double], source: String) throws -> Bool {
        try StoreLock.with(directory) {
            var file: URL, data: PyDict<JSONValue>, samples: [JSONValue]
            if let found = try find(name) {
                (file, data, samples) = (found.file, found.data, found.samples)
            } else {
                file = directory.appendingPathComponent(Voices.slug(name) + ".json")
                data = PyDict([("name", .string(name)), ("samples", .array([]))])
                samples = []
                while FileManager.default.fileExists(atPath: file.path) {
                    file = file.deletingLastPathComponent().appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-1.json")
                }
            }
            if try samples.contains(where: { try Self.isSource($0, source) }) { return false }
            samples.append(.object([("embedding", .array(embedding.map { .double($0) })), ("source", .string(source)),
                                    ("added", .string(Py.isoNow(timespec: "seconds", now: now())))]))
            data["samples"] = .array(Array(samples.suffix(Voices.MAX_SAMPLES_PER_PERSON)))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try write(data, file)
            return true
        }
    }

    /// Whose sample came from `source` (recording:label).
    public func owner(_ source: String) throws -> String? {
        for (name, person) in try people() {
            if try person.samples.contains(where: { try Self.isSource($0, source) }) { return name }
        }
        return nil
    }

    /// Takes back the samples `gone` picks; a person left without samples is removed. Returns how many went.
    private func removeSamples(where gone: (JSONValue) throws -> Bool) throws -> Int {
        var removed = 0
        for (_, person) in try people() {
            let kept = try person.samples.filter { try !gone($0) }
            if kept.count == person.samples.count { continue }
            removed += person.samples.count - kept.count
            if kept.isEmpty {
                try FileManager.default.removeItem(at: person.file)
            } else {
                var data = person.data
                data["samples"] = .array(kept)
                try write(data, person.file)
            }
        }
        return removed
    }

    /// Takes back a sample, e.g. when a speaker was named wrongly. A person left without samples is removed.
    @discardableResult
    public func removeSource(_ source: String) throws -> Bool {
        try StoreLock.with(directory) { try removeSamples { try Self.isSource($0, source) } > 0 }
    }

    /// How many numbers a stored voice has (the voice model's); nil when the bank is empty.
    public func size() throws -> Int? {
        for (_, person) in try people() {
            for sample in person.samples {
                guard let embedding = sample["embedding"]?.arrayValue else { throw VoiceError(description: "KeyError: 'embedding'") }
                return embedding.count
            }
        }
        return nil
    }

    /// Takes back every sample learned from one meeting (an import undone).
    @discardableResult
    public func removeMeeting(_ meetingId: String) throws -> Int {
        try StoreLock.with(directory) {
            try removeSamples { pyStr(try Self.source($0)).hasPrefixScalars(meetingId + ":") }
        }
    }

    @discardableResult
    public func forget(_ name: String) throws -> Bool {
        try StoreLock.with(directory) {
            guard let found = try find(name) else { return false }
            try FileManager.default.removeItem(at: found.file)
            return true
        }
    }

    /// Gives `old`'s samples to `new`; merges when `new` exists.
    @discardableResult
    public func rename(_ old: String, _ new: String) throws -> Bool {
        try StoreLock.with(directory) {
            guard let found = try find(old) else { return false }
            if let target = try find(new), Py.same(target.file.path, found.file.path) {  // only the spelling changes
                var data = found.data
                data["name"] = .string(new)
                try write(data, found.file)
                return true
            }
            for sample in found.samples {
                guard case .string(let source) = try Self.source(sample) else { throw VoiceError(description: "a sample's source is not text") }
                try add(new, try VoiceMath.vector(sample["embedding"], "a sample's embedding"), source: source)
            }
            try FileManager.default.removeItem(at: found.file)
            return true
        }
    }

    /// (similarity, name) per person with samples, best first: the best of the person's samples.
    public func scores(_ embedding: [Double]) throws -> [(Double, String)] {
        let query = VoiceMath.unit(embedding)
        var out: [(Double, String)] = []
        for (name, person) in try people() where !person.samples.isEmpty {
            var best = -Double.infinity
            for (i, sample) in person.samples.enumerated() {
                let sim = try VoiceMath.dot(VoiceMath.unit(VoiceMath.vector(sample["embedding"], "a sample's embedding")), query)
                if i == 0 || sim > best { best = sim }
            }
            out.append((best, name))
        }
        // sorted(reverse=True) on (similarity, name) tuples.
        return Py.stableSorted(out) { a, b in a.0 > b.0 || (a.0 == b.0 && Py.less(b.1, a.1)) }
    }

    /// The best-matching person, if clearly above the threshold and the runner-up.
    public func match(_ embedding: [Double]) throws -> (String, Double)? {
        let scores = try scores(embedding)
        guard let first = scores.first, first.0 >= Voices.MATCH_THRESHOLD else { return nil }
        if scores.count > 1 && first.0 - scores[1].0 < Voices.MATCH_MARGIN { return nil }
        return (first.1, first.0)
    }
}

extension String {
    /// `str.startswith`: by code points.
    func hasPrefixScalars(_ prefix: String) -> Bool { unicodeScalars.starts(with: prefix.unicodeScalars) }

    /// `str.endswith` (and a `*.json` glob's suffix): by code points.
    func hasSuffixScalars(_ suffix: String) -> Bool { unicodeScalars.reversed().starts(with: suffix.unicodeScalars.reversed()) }
}
