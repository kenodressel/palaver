// Transcript cleanup filters applied between transcription and merge (cleanup.py): segments over near-silence
// (Whisper's hallucinations), mic segments that repeat remote speech (bleed), and mic segments that are remote speech
// heard through the speakers (echo). Levels as numpy computes them: the silence gate on float32 (pairwise sums, then
// the threshold cast to float32, as numpy 2 compares a float32 with a Python float), the echo's power in float64.
// Audio is read per segment from the 16-bit WAV, never the whole track.
import Foundation

public enum Cleanup {
    // Loudest-100 ms-frame gates. Real speech on the AEC'd mic peaks at -23 dBFS
    // or louder (1st percentile over two real meetings); Whisper's hallucinations
    // over near-silence ("Thank you.", "Yeah.") peak at -37 dBFS or lower.
    public static let MIC_MIN_PEAK_DBFS = -35.0
    // The system track only gets a near-silence gate: remote speakers' levels vary
    // far more than the local mic.
    public static let SYSTEM_MIN_PEAK_DBFS = -50.0

    static let FRAME_SECONDS = 0.1

    // Speaker echo that survives AEC, transcribed on the mic. Its words land at the
    // same moment as on the system track (the acoustic path is ~30 ms); 95 % of
    // them within 0.5 s in real meetings. The user repeating or answering remote
    // words does so seconds later.
    static let ECHO_ALIGN_SECONDS = 0.5
    static let ECHO_MIN_SHARE = 0.5
    // From three such words on, text alone decides; a "Genau." both sides say at
    // once also needs AEC to have found echo there.
    static let ECHO_MIN_WORDS = 3
    static let ECHO_SHORT_REMOVED_DB = 3.0
    // AEC took this much out of what the mic heard: it heard the speakers, not the
    // user. The user's own speech comes through AEC at -4 ... +10 dB.
    static let ECHO_REMOVED_DB = 10.0
    // Word timings of short segments run up to ~0.3 s early; measure around them.
    static let ECHO_PAD_BEFORE = 0.3, ECHO_PAD_AFTER = 0.5, ECHO_MIN_SECONDS = 0.5

    /// What Python raises where a time is no number `int()` takes (inf, nan).
    public struct TimeError: Error, CustomStringConvertible {
        public let description: String
    }

    /// A WAV file and what `sf.info` says of it.
    struct Track {
        let url: URL
        let info: Wav16.Info
        init(_ url: URL) throws { self.url = url; info = try Wav16.info(url) }
    }

    // MARK: - Silence

    /// `drop_silent_segments`: the segments whose loudest 100 ms frame of `wav` reaches `minPeakDbfs`.
    public static func dropSilentSegments(_ segments: [Segment], wav: URL, minPeakDbfs: Double) throws -> [Segment] {
        let track = try Track(wav)
        let threshold = Float(pow(10, minPeakDbfs / 20))  // numpy 2 compares a float32 with a Python float as float32
        var kept: [Segment] = []
        for seg in segments {
            guard let peak = try loudestFrame(track, seg) else { continue }
            if peak >= threshold { kept.append(seg) }
        }
        return kept
    }

    /// The RMS of the loudest 100 ms frame of `seg` (numpy float32: the channels' mean, squares summed pairwise,
    /// / the frame, sqrt); nil when the segment holds no samples. A segment shorter than a frame is one frame.
    static func loudestFrame(_ track: Track, _ seg: Segment) throws -> Float? {
        let sr = track.info.rate, channels = track.info.channels
        let frame = Swift.max(1, try pyInt(FRAME_SECONDS * Double(sr)))
        let clip = pySlice(try pyInt(seg.start * Double(sr)), try pyInt(seg.end * Double(sr)), track.info.frames)
        let size = clip.count
        if size == 0 { return nil }
        let raw = try Wav16.read(track.url, start: clip.lowerBound, frames: size)
        var mono = [Float](repeating: 0, count: size)
        raw.withUnsafeBufferPointer { r in
            if channels == 1 {
                for i in 0..<size { mono[i] = Float(r[i]) / 32768 }
            } else {
                for i in 0..<size {
                    var s: Float = 0
                    for c in 0..<channels { s += Float(r[i * channels + c]) / 32768 }
                    mono[i] = s / Float(channels)
                }
            }
        }
        let n = Swift.max(1, size / frame), length = size >= frame ? frame : size
        var loudest = -Float.infinity
        mono.withUnsafeBufferPointer { m in
            for k in 0..<n {
                let rms = (NumpyReduce.sumOfSquares(m, from: k * length, count: length) / Float(length)).squareRoot()
                if rms > loudest { loudest = rms }
            }
        }
        return loudest
    }

    // MARK: - Bleed

    /// `_bigrams`: the pairs of neighbouring `\w+` words of `text.lower()`, keyed by code points.
    static func bigrams(_ text: String) -> Set<[UInt32]> {
        var words: [[UInt32]] = []
        var word: [UInt32] = []
        for u in Py.strLower(text).unicodeScalars {
            if Py.isWordScalar(u) { word.append(u.value) } else if !word.isEmpty { words.append(word); word = [] }
        }
        if !word.isEmpty { words.append(word) }
        var pairs = Set<[UInt32]>()
        for i in words.indices.dropLast() { pairs.insert(words[i] + [0] + words[i + 1]) }  // \w has no NUL
        return pairs
    }

    /// `drop_bleed_duplicates`: the mic segments kept, all but those (of `minWords` words or more) at least
    /// `minOverlap` of whose word pairs the system segments within `window` seconds say too.
    public static func dropBleedDuplicates(_ micSegments: [Segment], _ systemSegments: [Segment], window: Double = 2.0,
                                           minWords: Int = 3, minOverlap: Double = 0.6) -> [Segment] {
        var kept: [Segment] = []
        for mic in micSegments {
            let pairs = bigrams(mic.text)
            if pairs.count < minWords - 1 || pairs.isEmpty {  // empty: Python divides by zero (minWords <= 1 only)
                kept.append(mic)
                continue
            }
            var nearby = Set<[UInt32]>()
            for s in systemSegments where s.start <= mic.end + window && s.end >= mic.start - window {
                nearby.formUnion(bigrams(s.text))
            }
            if Double(pairs.intersection(nearby).count) / Double(pairs.count) < minOverlap { kept.append(mic) }
        }
        return kept
    }

    // MARK: - Echo

    /// `_norm`: the word lower-cased, without its non-word characters.
    static func norm(_ word: String) -> String {
        var out = String.UnicodeScalarView()
        for u in Py.strLower(word).unicodeScalars where Py.isWordScalar(u) { out.append(u) }
        return String(out)
    }

    /// `_aligned_words`: (words of `mic`, how many of them are remote words said at the same moment), matched as
    /// difflib's SequenceMatcher (autojunk off) matches the normalised words.
    static func alignedWords(_ mic: Segment, _ remote: [Word]) -> (words: Int, aligned: Int) {
        let words = mic.words.filter { !norm($0.text).isEmpty }
        let near = remote.filter { $0.end > mic.start - 3 && $0.start < mic.end + 3 }
        let matcher = SequenceMatcher(words.map { norm($0.text) }, near.map { norm($0.text) })
        var aligned = 0
        for block in matcher.matchingBlocks() {
            for k in 0..<block.size where abs(words[block.a + k].start - near[block.b + k].start) < ECHO_ALIGN_SECONDS {
                aligned += 1
            }
        }
        return (words.count, aligned)
    }

    /// `echoes_remote`: at least half of `mic`'s words, and at least three, are `remote` words said at the same moment.
    public static func echoesRemote(_ mic: Segment, _ remote: [Word]) -> Bool {
        let (words, aligned) = alignedWords(mic, remote)
        return words > 0 && Double(aligned) / Double(words) >= ECHO_MIN_SHARE && aligned >= ECHO_MIN_WORDS
    }

    /// `_aec_removed_db`: how much quieter `out` (the AEC'd mic) is than `raw` around `seg`, in dB (float64 powers,
    /// + 1e-12 each); 0 without the raw mic or when either track ends before the measured span.
    static func aecRemovedDb(raw: Track?, out: Track, sr: Int, seg: Segment) throws -> Double {
        guard let raw else { return 0.0 }
        let start = Swift.max(0, try pyInt((seg.start - ECHO_PAD_BEFORE) * Double(sr)))
        let end = Swift.max(try pyInt((seg.end + ECHO_PAD_AFTER) * Double(sr)), start + (try pyInt(ECHO_MIN_SECONDS * Double(sr))))
        if Swift.min(raw.info.frames, out.info.frames) <= start { return 0.0 }
        func power(_ t: Track) throws -> Double {
            let samples = try Wav16.read(t.url, start: start, frames: Swift.min(end, t.info.frames) - start)
            let total = samples.withUnsafeBufferPointer { s in NumpyReduce.sumOfSquares(s, from: 0, count: s.count) }
            return total / Double(samples.count) + 1e-12
        }
        return 10 * log10(try power(raw) / power(out))
    }

    /// `drop_echo`: the mic segments kept, all but those AEC took most of the sound out of (`micRawWav` against
    /// `micWav`) and those whose words are remote words said at the same moment (three or more; or at least half of
    /// them where AEC found some echo). Without the raw mic (or at another rate) only the words decide.
    public static func dropEcho(_ micSegments: [Segment], _ systemSegments: [Segment], micWav: URL, micRawWav: URL) throws
        -> [Segment] {
        let out = try Track(micWav)
        var raw: Track?
        if FileManager.default.fileExists(atPath: micRawWav.path) {  // Path.exists: symlinks followed
            let r = try Track(micRawWav)
            if r.info.rate == out.info.rate { raw = r }
        }
        let remote = systemSegments.flatMap(\.words).filter { !norm($0.text).isEmpty }
        var kept: [Segment] = []
        for seg in micSegments {
            let removed = try aecRemovedDb(raw: raw, out: out, sr: out.info.rate, seg: seg)
            let (words, aligned) = alignedWords(seg, remote)
            let echoText: Bool
            if removed < ECHO_SHORT_REMOVED_DB {
                echoText = echoesRemote(seg, remote)
            } else {  // AEC found some echo too, so a few aligned words are enough
                echoText = words > 0 && Double(aligned) / Double(words) >= ECHO_MIN_SHARE
            }
            if removed < ECHO_REMOVED_DB && !echoText { kept.append(seg) }
        }
        return kept
    }

    // MARK: - Python's numbers

    /// `int(x)` of a time in samples: truncated toward zero; inf and nan raise as in Python. Beyond ±2^62 it is
    /// clamped, which no slice of a track can tell apart.
    static func pyInt(_ x: Double) throws -> Int {
        guard x.isFinite else { throw TimeError(description: x.isNaN ? "ValueError: cannot convert float NaN to integer"
                                                                   : "OverflowError: cannot convert float infinity to integer") }
        let limit = Double(1 << 62)
        return Int(Swift.min(Swift.max(x, -limit), limit).rounded(.towardZero))
    }

    /// `a[lo:hi]` of `n` items as Python slices them (negative bounds count from the end).
    static func pySlice(_ lo: Int, _ hi: Int, _ n: Int) -> Range<Int> {
        let a = lo < 0 ? Swift.max(lo + n, 0) : Swift.min(lo, n)
        let b = hi < 0 ? Swift.max(hi + n, 0) : Swift.min(hi, n)
        return a..<Swift.max(a, b)
    }
}
