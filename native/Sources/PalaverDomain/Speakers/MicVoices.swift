// Voices told apart on the microphone: a call held over a phone's or the Mac's speaker, or people around the table,
// leave the call's track empty and every voice on the microphone. Then the microphone is diarized like the others'
// track; the voices that sound like the user (OwnVoice) stay the user's lines, the others become speakers that can be
// named, recognized and taught to the voice bank like anyone on a call.
//
// On disk: system_turns.json and speaker_embeddings.json hold the others heard on the microphone (the call's track had
// nobody), mic_turns.json the user's own turns, which the merge needs to tell the microphone's words apart. Only
// numbers stay on this Mac.
import Foundation
import PalaverCore

public enum MicVoices {
    /// A microphone voice at least this alike to one of the user's own samples is the user. The owner's meetings
    /// (`make eval-voices`, 2026-11): the user's own microphone across meetings median 0.88, two different people
    /// 99th percentile 0.52; on the speakerphone call that asked for this the user's voice scored 0.91, the others
    /// 0.23 and 0.26.
    public static let OWNER_SIMILARITY = 0.65
    /// The user's label in mic_turns.json: never a diarizer's, so cutting and joining leave it alone.
    public static let OWNER = "me"

    /// Whether the microphone was told apart by voice, with others on it: mic_turns.json holds the user's turns.
    public static func split(_ paths: RecordingPaths) -> Bool {
        !(PythonJSON.read(paths.micTurns)?.arrayValue ?? []).isEmpty
    }

    /// The track the others' voices were heard on: the microphone when it was told apart, else the call's.
    public static func othersWav(_ paths: RecordingPaths) -> URL { split(paths) ? paths.micWav : paths.systemWav }

    /// The microphone's labels that are the user: each voice as alike as OWNER_SIMILARITY to one of `profile` (the
    /// diarizer may split the user in two).
    public static func ownerLabels(_ voices: PyDict<[Double]>, profile: [[Double]]) throws -> Set<String> {
        var owner = Set<String>()
        for (label, voice) in voices where !voice.isEmpty {
            let best = try profile.filter { $0.count == voice.count }.map { try VoiceMath.cosine(voice, $0) }.max() ?? -1
            if best >= OWNER_SIMILARITY { owner.insert(label) }
        }
        return owner
    }

    /// The microphone's segments told apart word by word: each word goes to the turn it overlaps most (else the
    /// nearest), the user's (`owner`) or the others'. Runs of the user's words stay the microphone's segments (their
    /// speaker kept), runs of the others' become segments without a speaker, which the merge gives the others' labels
    /// by `others`. A segment without words goes whole. Without the user's turns nothing is split.
    public static func split(_ segments: [Segment], owner: [SpeakerTurn], others: [SpeakerTurn]) -> (mine: [Segment], theirs: [Segment]) {
        guard !owner.isEmpty, !others.isEmpty else { return (segments, []) }
        let mineLabels = Set(owner.map { ScalarKey($0.speaker) })
        let all = owner + others
        func isMine(_ start: Double, _ end: Double) -> Bool {
            mineLabels.contains(ScalarKey(Merger.speakerForInterval(start, end, all)))
        }
        var mine: [Segment] = [], theirs: [Segment] = []
        for seg in segments {
            guard !seg.words.isEmpty else {
                if isMine(seg.start, seg.end) { mine.append(seg) } else { theirs.append(Segment(start: seg.start, end: seg.end, text: seg.text)) }
                continue
            }
            var runs: [(mine: Bool, words: [Word])] = []
            for w in seg.words {
                let m = isMine(w.start, w.end)
                if let last = runs.indices.last, runs[last].mine == m { runs[last].words.append(w) } else { runs.append((m, [w])) }
            }
            if runs.count == 1 && runs[0].mine {
                mine.append(seg)
                continue
            }
            for run in runs {
                let text = Py.strip(run.words.map(\.text).joined(separator: " "))
                let part = Segment(start: run.words.first!.start, end: run.words.last!.end, text: text,
                                   speaker: run.mine ? seg.speaker : nil, words: run.words)
                if run.mine { mine.append(part) } else { theirs.append(part) }
            }
        }
        return (mine, theirs)
    }
}

/// The user's own voice: one sample per recent call, from their microphone lines there (a call's microphone is the
/// user's), kept in `own-voice.json` so a call's voice is embedded once. Biometric data: only on this Mac.
public enum OwnVoice {
    /// The newest calls the samples come from (`make eval-voices`: the misses fall from 7% with one call to 2% with
    /// ten, then stay).
    public static let MEETINGS = 10
    /// Lines shorter than this are left out of a sample.
    public static let MIN_LINE_SECONDS = 2.0
    /// At most this much of a call's talk goes into its sample, the longest lines first.
    public static let SAMPLE_SECONDS = 120.0

    public struct Sample: Equatable {
        public var meeting: String
        public var embedding: [Double]
    }

    /// The samples kept; a missing or broken file is none.
    public static func load(_ stores: StorePaths) -> [Sample] {
        (PythonJSON.read(stores.ownVoice)?["samples"]?.arrayValue ?? []).compactMap { item in
            guard let meeting = item["meeting"]?.stringValue, let values = item["embedding"]?.arrayValue else { return nil }
            let embedding = values.compactMap(\.doubleValue)
            return embedding.isEmpty || embedding.count != values.count ? nil : Sample(meeting: meeting, embedding: embedding)
        }
    }

    static func save(_ stores: StorePaths, _ samples: [Sample]) throws {
        let path = stores.ownVoice
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try StoreLock.with(path) {
            try PythonJSON.write(.object([("samples", .array(samples.map {
                .object([("meeting", .string($0.meeting)), ("embedding", .array($0.embedding.map(JSONValue.double)))])
            }))]), to: path, indent: nil, ensureAscii: true, via: path.lastPathComponent + ".tmp")
        }
    }

    /// Whether `paths` is a call whose microphone was the user's alone: transcribed, someone spoke on the call's
    /// track, no voice marked as several people, the microphone not told apart.
    public static func isOwnCall(_ paths: RecordingPaths) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.transcriptJson.path), fm.fileExists(atPath: paths.micWav.path),
              !fm.fileExists(atPath: paths.micTurns.path) else { return false }
        return SharedMic.systemSpeech(paths) && !SharedMic.marked(paths)
    }

    /// The spans (seconds on mic.wav) of the user's lines in `paths`: lines of MIN_LINE_SECONDS or more, the longest
    /// first, up to SAMPLE_SECONDS, in time order.
    public static func spans(_ paths: RecordingPaths) -> [Range<Double>] {
        let lines = (PythonJSON.read(paths.transcriptJson)?.arrayValue ?? []).compactMap { try? Utterance(json: $0) }
        let long = lines.filter { Speakers.isMicLine($0) && $0.end - $0.start >= MIN_LINE_SECONDS }
        var total = 0.0, out: [Range<Double>] = []
        for u in Py.stableSorted(long, by: { $0.end - $0.start > $1.end - $1.start }) where total < SAMPLE_SECONDS {
            out.append(u.start..<u.end)
            total += u.end - u.start
        }
        return out.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// The user's own voice: a sample from each of the MEETINGS newest calls in `outputDir` (not `excluding`), each
    /// embedded once (`embed`: one voice for the spans of a track) and kept. Calls without lines to learn from are
    /// passed over. Empty when there is none yet.
    public static func profile(outputDir: URL, stores: StorePaths, excluding: String,
                               embed: (URL, [Range<Double>]) async throws -> [Double]?) async throws -> [[Double]] {
        let kept = load(stores)
        var known = PyDict<[Double]>()
        for s in kept { known[s.meeting] = s.embedding }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? [])
            .filter { RecordingPaths.isRecordingFolderName($0) && $0 != excluding }
            .sorted(by: >)
        var samples: [Sample] = []
        for name in names where samples.count < MEETINGS {
            let paths = RecordingPaths(outputDir.appendingPathComponent(name, isDirectory: true))
            guard isOwnCall(paths) else { continue }
            if let have = known[name] {
                samples.append(Sample(meeting: name, embedding: have))
                continue
            }
            let spans = spans(paths)
            guard !spans.isEmpty, let voice = try await embed(paths.micWav, spans), !voice.isEmpty else { continue }
            samples.append(Sample(meeting: name, embedding: voice))
        }
        if samples != kept { try save(stores, samples) }
        return samples.map(\.embedding)
    }
}
