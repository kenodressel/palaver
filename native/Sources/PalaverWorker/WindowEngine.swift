// The live stream's speech engine (palaver/stream_engine.py): a sliding window with local agreement. Every step the
// last `WINDOW_SECONDS` of a track are transcribed in full, so the model always sees context on both sides of a
// word. A word settles once two passes in a row agree on it, or once it is older than `MAX_AGE` seconds (so a word
// that never agrees cannot leave the window unsaid). The words that have not settled yet are the draft: they change
// from pass to pass.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

/// What the stream feeds a track to (stream_engine.py `Engine`).
public protocol StreamEngine: AnyObject {
    /// Feeds 16 kHz samples (/ 32768) that continue the track. Returns the newly settled whole words and the current
    /// draft; times are seconds from the track's start.
    func add(_ audio: [Float]) async throws -> (settled: [Word], draft: [Word])
    /// The draft as settled words, at the end.
    func flush() -> [Word]
    /// The first sample fed is this far into the track (a late start).
    func startAt(_ seconds: Double)
}

public final class WindowEngine: StreamEngine {
    public static let SAMPLE_RATE = 16_000
    /// How much audio each pass transcribes.
    public static let WINDOW_SECONDS = 10.0
    /// A pass starts this far before the settled end.
    public static let REHEAR_SECONDS = 1.0
    /// A word older than this settles without agreement.
    public static let MAX_AGE = 3.0
    /// How sure Parakeet was moves that age: on recorded meetings, words below 0.85 differed from the final
    /// transcript 50–100 % of the time and those of 0.95 and up 3–12 %. Unsure words wait for more context; sure
    /// ones settle sooner.
    public static let SURE = 0.95, UNSURE = UNSURE_CONFIDENCE
    public static let SURE_AGE = 2.0, UNSURE_AGE = 6.0

    public typealias Transcribe = ([Float]) async throws -> [Word]

    private let transcribe: Transcribe
    private let window: Double
    private let rehear: Double
    private let maxAge: Double
    private let dictionary: TranscriberDictionary?
    private var audio: [Float] = []  // the last window + rehear seconds
    private var audioStart = 0  // sample index of audio[0] in the track
    private var settledEnd = 0.0
    private var previous: [Word] = []

    /// `dictionary`: applied to each word here; nil when `transcribe` applies it (the engine's words do).
    public init(_ transcribe: @escaping Transcribe, window: Double = WINDOW_SECONDS, rehear: Double = REHEAR_SECONDS,
                maxAge: Double = MAX_AGE, dictionary: TranscriberDictionary? = nil) {
        self.transcribe = transcribe
        self.window = window
        self.rehear = rehear
        self.maxAge = maxAge
        self.dictionary = dictionary
    }

    /// Samples held for the next pass (never more than window + rehear seconds).
    var bufferedSamples: Int { audio.count }

    public func add(_ new: [Float]) async throws -> (settled: [Word], draft: [Word]) {
        let rate = Double(Self.SAMPLE_RATE)
        audio += new
        let fed = Double(audioStart + audio.count) / rate
        // Only the last window + rehear seconds stay in memory: a pass never begins before fed - window.
        let keep = Int((window + rehear) * rate)
        if audio.count > keep {
            audioStart += audio.count - keep
            audio.removeFirst(audio.count - keep)
        }
        let begin = max(0.0, settledEnd - rehear, fed - window)
        // A jump past the window (the recorder wrote nothing in a silence, then the whole gap at once): the last
        // draft's words this pass can't hear again settle as they were.
        var carried: [Word] = []
        while let first = previous.first, first.start < begin {
            carried.append(previous.removeFirst())
        }
        if let last = carried.last { settledEnd = last.end }
        let offset = min(audio.count, max(0, Int((begin * rate).rounded(.toNearestOrEven)) - audioStart))
        let words = try await transcribe(Array(audio[offset...]))
        // The pass starts where the audio slice starts, not at `begin` exactly.
        let shift = Double(audioStart + offset) / rate
        let hyp = words.filter { shift + $0.start >= settledEnd - 0.05 }.map {
            Word(text: text($0.text), start: shift + $0.start, end: shift + $0.end, confidence: $0.confidence)
        }
        // Local agreement: the longest common prefix with the last pass settles.
        var n = 0
        while n < min(hyp.count, previous.count) && Py.same(Self.key(hyp[n]), Self.key(previous[n])) { n += 1 }
        // A word that has been heard long enough settles regardless.
        while n < hyp.count && hyp[n].end < fed - ageLimit(hyp[n]) { n += 1 }
        let settled = carried + hyp[..<n]
        previous = Array(hyp[n...])
        if let last = settled.last { settledEnd = last.end }
        return (settled, previous)
    }

    public func startAt(_ seconds: Double) {
        audioStart = Int((seconds * Double(Self.SAMPLE_RATE)).rounded(.toNearestOrEven))
        settledEnd = seconds
    }

    public func flush() -> [Word] {
        let settled = previous
        previous = []
        if let last = settled.last { settledEnd = last.end }
        return settled
    }

    private func ageLimit(_ word: Word) -> Double {
        guard let c = word.confidence, !(Self.SURE > c && c >= Self.UNSURE) else { return maxAge }
        return c >= Self.SURE ? Self.SURE_AGE : Self.UNSURE_AGE
    }

    private func text(_ text: String) -> String { dictionary?.apply(text) ?? text }

    /// `_key`: the word without the punctuation around it, casefolded.
    static func key(_ word: Word) -> String {
        let marks: Set<Unicode.Scalar> = [".", ",", "?", "!"]
        let scalars = word.text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !marks.contains($0) }),
              let last = scalars.lastIndex(where: { !marks.contains($0) }) else { return "" }
        return Py.casefold(String(scalars[first...last]))
    }
}

/// The stream's memory (stream_engine.py `MemoryMeter`): the model lives in this process (the in-process engine),
/// so its phys_footprint is what the stream costs. Called, it returns the bytes now and remembers the most.
public final class MemoryMeter {
    private let pid: Int32
    private let sample: (Int32) -> Int?
    private var peak = 0

    public init(pid: Int32 = getpid(), sample: @escaping (Int32) -> Int? = MemoryMeter.footprint) {
        self.pid = pid
        self.sample = sample
    }

    public func callAsFunction() -> Int {
        let used = sample(pid) ?? 0
        peak = max(peak, used)
        return used
    }

    /// The most it held at once, in MB.
    public var peakMB: Int { Int((Double(peak) / 1_048_576).rounded(.toNearestOrEven)) }

    /// The phys_footprint of `pid` in bytes (`proc_pid_rusage`); nil when it can't be read.
    public static func footprint(_ pid: Int32) -> Int? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? Int(info.ri_phys_footprint) : nil
    }
}
