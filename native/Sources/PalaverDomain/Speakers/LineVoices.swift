// The voices of corrected lines (#35): a line the user said someone else said ("This line is…", #12) teaches the
// voice bank that person's voice, so a person diarization put into another speaker is recognized next time. A
// correction only puts its meeting on a waiting list (`voices-pending.json`); the voices are worked out by the speech
// engine in the background, when nothing else runs (the index worker), and replace what the meeting's lines taught
// before: a correction undone or changed takes its voice back.
import Foundation
import PalaverCore

public enum LineVoices {
    /// Less talk than this, over one person's corrected lines in a meeting, teaches nothing.
    public static let MIN_SECONDS = 4.0
    /// A line shorter than this is left out of the voice.
    public static let MIN_LINE_SECONDS = 1.0

    /// The bank's source of the voice a meeting's lines taught for one person: `<meeting>:lines:<name>`.
    public static func source(_ meetingId: String, _ name: String) -> String { sourcePrefix(meetingId) + Py.casefold(name) }

    static func sourcePrefix(_ meetingId: String) -> String { "\(meetingId):lines:" }

    // MARK: - the waiting list

    /// Puts a meeting on the waiting list (once).
    public static func mark(_ stores: StorePaths, _ meetingId: String) throws {
        try StoreLock.with(stores.voicesPending) {
            var ids = read(stores)
            if !ids.contains(meetingId) { ids.append(meetingId) }
            try write(stores, ids)
        }
    }

    /// The meetings waiting, oldest first.
    public static func pending(_ stores: StorePaths) -> [String] { read(stores) }

    /// Takes a meeting off the waiting list.
    public static func done(_ stores: StorePaths, _ meetingId: String) throws {
        try StoreLock.with(stores.voicesPending) { try write(stores, read(stores).filter { $0 != meetingId }) }
    }

    private static func read(_ stores: StorePaths) -> [String] {
        (PythonJSON.read(stores.voicesPending)?.arrayValue ?? []).compactMap(\.stringValue)
    }

    private static func write(_ stores: StorePaths, _ ids: [String]) throws {
        if ids.isEmpty {
            if FileManager.default.fileExists(atPath: stores.voicesPending.path) { try FileManager.default.removeItem(at: stores.voicesPending) }
            return
        }
        try FileManager.default.createDirectory(at: stores.voicesPending.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PythonJSON.write(.array(ids.map(JSONValue.string)), to: stores.voicesPending, indent: 2, ensureAscii: false)
    }

    // MARK: - what a meeting teaches

    /// Name → the spans (seconds on the others' track) of the lines corrected to that person. Only lines heard on the
    /// others' track (the microphone's are the user's), said by a named voice or by a person without a voice of their
    /// own; never the user, a room or a voice without a name. Lines under MIN_LINE_SECONDS are left out, and people
    /// with less than MIN_SECONDS in all.
    public static func spans(_ paths: RecordingPaths) throws -> PyDict<[Range<Double>]> {
        let fixes = Speakers.loadLineSpeakers(paths)
        guard !fixes.isEmpty, let items = PythonJSON.read(paths.transcriptJson)?.arrayValue else { return PyDict() }
        let names = try Speakers.transcriptNames(paths)
        let rooms = SharedMic.sharedLabels(paths)
        let merges = Speakers.loadMerges(paths)
        var found = PyDict<[Range<Double>]>()
        for item in items {
            let u = try Utterance(json: item)
            guard !Speakers.isMicLine(u), u.end - u.start >= MIN_LINE_SECONDS, let i = Speakers.lineFix(u, fixes) else { continue }
            let fix = fixes[i]
            if fix["me"]?.truthy ?? false { continue }
            let name: String
            if case .string(let label)? = fix["label"] {
                let into = merges[label] ?? label
                if rooms.contains(ScalarKey(label)) || rooms.contains(ScalarKey(into)) { continue }
                guard let given = names[label], !given.isEmpty, !Py.same(given, label) else { continue }
                name = given
            } else {
                name = Py.strip(fix["name"].flatMap { $0.truthy ? Py.str($0) : nil } ?? "")
                if name.isEmpty { continue }
            }
            found[name] = (found[name] ?? []) + [u.start..<u.end]
        }
        return PyDict(found.filter { $0.value.reduce(0.0) { $0 + $1.upperBound - $1.lowerBound } >= MIN_SECONDS }
            .map { ($0.key, $0.value) })
    }

    /// Teaches `bank` the voices of the meeting's corrected lines, in place of what its lines taught before. `embed`
    /// gives one voice per name for its spans (the speech engine on the others' track). The names taught.
    @discardableResult
    public static func learn(_ paths: RecordingPaths, bank: VoiceBank,
                             embed: (PyDict<[Range<Double>]>) async throws -> PyDict<[Double]>) async throws -> [String] {
        let wanted = try spans(paths)
        let voices = wanted.isEmpty ? PyDict<[Double]>() : try await embed(wanted)
        try bank.removeSources(prefix: sourcePrefix(paths.id))  // only now: a failed embedding keeps the old voices
        var taught: [String] = []
        for (name, vector) in voices where !vector.isEmpty && wanted[name] != nil {
            if try bank.add(name, vector, source: source(paths.id, name)) { taught.append(name) }
        }
        return taught
    }
}
