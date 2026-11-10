// Stitching overlapping chunks by word, and the words as segments (transcription.py `stitch`, `segments_from_words`).
import Foundation
import PalaverCore
import PalaverDomain

public enum Stitch {
    /// The same word this close on both sides of a seam is one word.
    public static let SEAM_DUPLICATE_SECONDS = 0.5
    /// Two words sharing this much of the shorter one's time are one word.
    public static let SEAM_SHARED = 0.5
    /// Segments as Parakeet makes them: cut at a sentence end or a 1 s pause, at most 15 s.
    public static let PAUSE_SECONDS = 1.0
    public static let MAX_SEGMENT_SECONDS = 15.0

    static func norm(_ text: String) -> String { OpenAITranscribe.norm(text) }

    /// Two chunks' versions of one spoken word: the same word close together, or any two that share most of their time.
    static func sameWord(_ a: Word, _ b: Word) -> Bool {
        if norm(a.text) == norm(b.text) && abs(a.start - b.start) <= SEAM_DUPLICATE_SECONDS { return true }
        let shared = min(a.end, b.end) - max(a.start, b.start)
        let shorter = min(a.end - a.start, b.end - b.start)
        return shorter > 0 && shared >= SEAM_SHARED * shorter
    }

    /// The words of overlapping chunks (start, end, words on the shared clock), each once. Each word belongs to exactly
    /// one chunk: the one whose share of the overlap holds its middle, the middle of the overlap being the seam (a word
    /// whose middle is the seam goes to the later chunk). A word the later chunk heard as one the earlier chunk already
    /// kept is left out.
    public static func stitch(_ chunks: [(start: Double, end: Double, words: [Word])]) -> [Word] {
        var out: [Word] = []
        for (i, chunk) in chunks.enumerated() {
            let lo = i > 0 ? (chunk.start + chunks[i - 1].end) / 2 : -Double.infinity
            let hi = i + 1 < chunks.count ? (chunks[i + 1].start + chunk.end) / 2 : Double.infinity
            var kept = Py.stableSorted(chunk.words) { ($0.start, $0.end) < ($1.start, $1.end) }
                .filter { lo <= ($0.start + $0.end) / 2 && ($0.start + $0.end) / 2 < hi }
            let tail = out.suffix(3)
            while let first = kept.first, tail.contains(where: { sameWord(first, $0) }) { kept.removeFirst() }
            out += kept
        }
        return out
    }

    /// Sentences, as Parakeet cuts them: at a sentence end or a pause, at most MAX_SEGMENT_SECONDS.
    public static func segments(_ words: [Word]) -> [Segment] {
        var segments: [Segment] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(Segment(start: first.start, end: last.end, text: current.map(\.text).joined(separator: " "),
                                    speaker: nil, words: current))
            current = []
        }
        for w in words {
            if let last = current.last, let first = current.first,
               w.start - last.end > PAUSE_SECONDS || last.text.hasSuffix(".") || last.text.hasSuffix("?") || last.text.hasSuffix("!")
                || w.end - first.start > MAX_SEGMENT_SECONDS {
                flush()
            }
            current.append(w)
        }
        flush()
        return segments
    }
}
