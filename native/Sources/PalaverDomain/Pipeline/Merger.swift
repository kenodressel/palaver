// Merge mic + diarized-system segments into a chronological utterance stream (merger.py): every system word gets
// the diarization turn it overlaps most (else the nearest), runs of one speaker's words become one utterance, and
// the mic's segments join them in time order.
import Foundation

public enum Merger {
    /// `assign_speakers_to_words`: (start, end, text, speaker) of every word of `systemSegments`.
    public static func assignSpeakersToWords(_ systemSegments: [Segment], _ systemTurns: [SpeakerTurn])
        -> [(start: Double, end: Double, text: String, speaker: String)] {
        var result: [(start: Double, end: Double, text: String, speaker: String)] = []
        for seg in systemSegments {
            for w in seg.words {
                result.append((w.start, w.end, w.text, speakerForInterval(w.start, w.end, systemTurns)))
            }
        }
        return result
    }

    static func overlap(_ aStart: Double, _ aEnd: Double, _ bStart: Double, _ bEnd: Double) -> Double {
        Swift.max(0.0, Swift.min(aEnd, bEnd) - Swift.max(aStart, bStart))
    }

    static func distanceToTurn(_ point: Double, _ turn: SpeakerTurn) -> Double {
        if point < turn.start { return turn.start - point }
        if point > turn.end { return point - turn.end }
        return 0.0
    }

    /// `_speaker_for_interval`: the turn overlapping [start, end] most (the earlier-starting of equal ones), else the
    /// nearest to `start` (ties: the earlier start, then the first); "SPEAKER_00" without turns.
    static func speakerForInterval(_ start: Double, _ end: Double, _ turns: [SpeakerTurn]) -> String {
        guard let first = turns.first else { return "SPEAKER_00" }
        var bestOverlap = 0.0
        var bestTurn: SpeakerTurn?
        for t in turns {
            let o = overlap(start, end, t.start, t.end)
            if o > bestOverlap || (o == bestOverlap && bestTurn != nil && t.start < bestTurn!.start) {
                bestOverlap = o
                bestTurn = t
            }
        }
        if let bestTurn, bestOverlap > 0.0 { return bestTurn.speaker }
        // min(turns, key=(distance, start)): the first of equal keys.
        var nearest = first
        var key = (distanceToTurn(start, first), first.start)
        for t in turns.dropFirst() {
            let k = (distanceToTurn(start, t), t.start)
            if k < key { nearest = t; key = k }
        }
        return nearest.speaker
    }

    /// `_unsure`: the words the transcriber was less sure of than UNSURE_CONFIDENCE.
    static func unsure(_ words: [Word]) -> [String] {
        words.compactMap { w in w.confidence.flatMap { $0 < UNSURE_CONFIDENCE ? w.text : nil } }
    }

    static func systemSegmentsToUtterances(_ segments: [Segment], _ turns: [SpeakerTurn]) -> [Utterance] {
        var utterances: [Utterance] = []
        for seg in segments {
            if seg.words.isEmpty {
                let speaker = speakerForInterval(seg.start, seg.end, turns)
                utterances.append(Utterance(speaker: speaker, start: seg.start, end: seg.end, text: Py.strip(seg.text)))
                continue
            }
            var chunks: [(speaker: String, start: Double, end: Double, words: [Word])] = []
            for w in seg.words {
                let speaker = speakerForInterval(w.start, w.end, turns)
                if let last = chunks.indices.last, Py.same(chunks[last].speaker, speaker) {
                    chunks[last].end = w.end
                    chunks[last].words.append(w)
                } else {
                    chunks.append((speaker, w.start, w.end, [w]))
                }
            }
            for c in chunks {
                utterances.append(Utterance(speaker: c.speaker, start: c.start, end: c.end,
                                            text: Py.strip(c.words.map(\.text).joined(separator: " ")),
                                            unsure: unsure(c.words)))
            }
        }
        return utterances
    }

    /// `merge`: the mic's segments (speaker "User" when they have none) and the system's utterances, those with text,
    /// by (start, end), stably.
    public static func merge(mic micSegments: [Segment], system systemSegments: [Segment], turns systemTurns: [SpeakerTurn])
        -> [Utterance] {
        let mic = micSegments.map { s in
            Utterance(speaker: (s.speaker?.isEmpty ?? true) ? "User" : s.speaker!, start: s.start, end: s.end,
                      text: Py.strip(s.text), unsure: unsure(s.words))
        }
        let combined = (mic + systemSegmentsToUtterances(systemSegments, systemTurns)).filter { !$0.text.isEmpty }
        return Py.stableSorted(combined) { ($0.start, $0.end) < ($1.start, $1.end) }
    }
}
