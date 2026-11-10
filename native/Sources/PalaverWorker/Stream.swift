// `palaver-worker stream <folder>` (palaver/stream.py, cli.py `_cmd_stream`): the realtime stream of a recording in
// progress (#42). It runs next to the recorder and the live worker; every step it feeds what the recorder wrote
// since the last step to one `StreamEngine` per track (the system track and the raw mic, without echo cancellation).
// Settled words join into sentences. A mic sentence that is the other side heard through the speakers is dropped by
// its words, once the system track has heard the same moment. System sentences that end in "?" make the question
// list. It writes only stream.json (through `stream.json.tmp` and a rename: the window and the coach read it while it
// is rewritten every second).
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

/// The stream's loop as `StreamWorker.run` drives it (`RealtimeProcessor`; tests stand in their own).
public protocol StreamProcessing: AnyObject {
    func step() async throws -> Bool
    func write() throws
    func finish() async throws
}

public enum StreamWorker {
    public static let SAMPLE_RATE = 16_000
    /// How often the stream reads the tracks.
    public static let STEP_SECONDS = 1.0
    /// A pause this long ends a sentence.
    public static let SENTENCE_GAP = 1.0
    /// A sentence never runs longer.
    public static let MAX_SENTENCE = 15.0
    /// A mic sentence waits at most this long for the system track ...
    public static let ECHO_WAIT_SECONDS = 2.0
    /// ... to have been fed this far past the sentence's end.
    public static let ECHO_LOOKAHEAD = 0.5
    /// Louder than this over the last SPEAKING_SECONDS is speech.
    public static let SPEAKING_DBFS = -45.0
    public static let SPEAKING_SECONDS = 0.5
    /// The engine gets slices at least this long (R5).
    public static let MIN_FEED_SECONDS = 0.5
    /// The stream ends itself when this process passes this many times its budget (memory.py `DEFAULT_STREAM_GB`,
    /// or `[memory] stream_gb`): a backstop when the daemon's watchdog does not act.
    public static let STREAM_MEMORY_FACTOR = 2
    /// memory.py `DEFAULT_STREAM_GB` (the daemon's `MemoryRules.defaultStreamGB`).
    public static let DEFAULT_STREAM_GB = 1.5
    static let GB = 1_073_741_824.0
    /// The default budget's cap.
    public static let STREAM_MEMORY_LIMIT = Int(Double(STREAM_MEMORY_FACTOR) * DEFAULT_STREAM_GB * GB)
    /// ... checked every this many steps.
    public static let MEMORY_CHECK_STEPS = 10
    static let SENTENCE_END: [Character] = [".", "?", "!"]

    /// `memory_limit_for`: the cap for the budget the user configured.
    public static func memoryLimit(_ config: Config) -> Int {
        Int(Double(STREAM_MEMORY_FACTOR) * (config.memory["stream_gb"] ?? DEFAULT_STREAM_GB) * GB)
    }

    /// `load_engines`: the system and the mic engine, sharing the one engine of this process (its calls run one at a
    /// time). The engine applies the dictionary to the words.
    public static func loadEngines(_ engine: EngineCalls) -> (system: WindowEngine, mic: WindowEngine) {
        let transcribe: WindowEngine.Transcribe = { [engine] in try await engine.transcribeWindow($0) }
        return (WindowEngine(transcribe), WindowEngine(transcribe))
    }

    /// `run_stream`: steps and writes every `step` seconds until the recording stops, then finishes. Returns false
    /// when the recorder stopped growing without finishing, or once `memory()` (bytes, read every
    /// MEMORY_CHECK_STEPS steps) passes `memoryLimit`: the stream gives up, the recording goes on.
    public static func run(_ processor: StreamProcessing, paths: RecordingPaths, step: Double = STEP_SECONDS,
                           stall: Double = Live.STALL_SECONDS, clock: () -> Double = Live.monotonic,
                           sleep: (Double) async throws -> Void = Live.sleep, memory: (() -> Int)? = nil,
                           memoryLimit: Int = STREAM_MEMORY_LIMIT, log: SessionLog? = nil) async throws -> Bool {
        var lastGrowth = clock()
        var steps = 0
        while !Live.recordingFinished(paths) {
            if try await processor.step() {
                lastGrowth = clock()
            } else if clock() - lastGrowth > stall {
                return false
            }
            try processor.write()
            steps += 1
            if let memory, steps % MEMORY_CHECK_STEPS == 0 {
                let used = memory()
                if used > memoryLimit {
                    Stage.event("stream_memory_cap", log: log, [("mb", .int(mb(used))), ("limit_mb", .int(mb(memoryLimit)))])
                    return false
                }
            }
            try await sleep(step)
        }
        try await processor.finish()
        return true
    }

    static func mb(_ bytes: Int) -> Int { Int((Double(bytes) / 1_048_576).rounded(.toNearestOrEven)) }

    static func text(_ words: [Word]) -> String { words.map(\.text).joined(separator: " ") }
}

/// A closed sentence and when it got where it is.
struct StreamSentence {
    var segment: Segment
    /// Clock time its last word settled.
    var settledAt: Double
    /// Clock time it closed.
    var closedAt = 0.0
    /// Clock time it joined its track's list (a mic one after the echo wait).
    var publishedAt = 0.0

    func json(words: Bool = true) -> JSONValue {
        guard case .object(var fields) = segment.json else { return segment.json }
        fields += [("settled_at", .double(settledAt)), ("published_at", .double(publishedAt))]
        if !words { fields.removeAll { $0.0 == "words" } }
        return .object(fields)
    }
}

/// One track's audio and text so far.
final class StreamTrack {
    let track: GrowingTrack
    let engine: StreamEngine
    /// Clock time the track last grew.
    var grewAt: Double
    /// Samples read from the track.
    var read: Int
    /// Samples given to the engine.
    var fed: Int
    var unfed: [Int16] = []
    /// The open sentence.
    var words: [Word] = []
    /// Clock time its last word settled.
    var wordsAt = 0.0
    var draft: [Word] = []
    var sentences: [StreamSentence] = []

    init(_ track: GrowingTrack, _ engine: StreamEngine, now: Double) {
        self.track = track
        self.engine = engine
        grewAt = now
        // A stream that starts late (the app or the stream restarted mid-call) begins one window before the end
        // instead of reading the backlog (R7). Samples and seconds stay counted from the track's start.
        let rate = StreamWorker.SAMPLE_RATE
        let start = max(0, track.available() - Int(WindowEngine.WINDOW_SECONDS * Double(rate)))
        if start > 0 { engine.startAt(Double(start) / Double(rate)) }
        read = start
        fed = start
    }

    /// Reads what the recorder wrote since the last call.
    func pull() throws -> Bool {
        let available = track.available()
        if available <= read { return false }
        unfed += try track.readInt16(read, available)
        read = available
        return true
    }

    func feed(minimum: Int) async throws -> (settled: [Word], draft: [Word])? {
        if unfed.isEmpty || unfed.count < minimum { return nil }
        let audio = unfed
        unfed = []
        fed += audio.count
        return try await engine.add(audio.map { Float($0) / 32768 })
    }

    /// Whether the SPEAKING_SECONDS before sample `end` hold speech. What the track has not written up to `end`
    /// counts as silence.
    func loud(_ end: Int) throws -> Bool {
        let start = max(0, end - Int(StreamWorker.SPEAKING_SECONDS * Double(StreamWorker.SAMPLE_RATE)))
        if end <= start { return false }
        let audio = try track.readInt16(start, end)
        let power = audio.reduce(0.0) { $0 + Double($1) * Double($1) } / (32768.0 * 32768.0) / Double(audio.count)
        return 10 * log10(power + 1e-20) > StreamWorker.SPEAKING_DBFS
    }
}

/// `RealtimeProcessor`: sentences, the echo filter, questions and who is speaking, from the two engines. `step`
/// takes in what the recorder wrote; `write` writes stream.json; `finish` settles everything once the recording
/// stopped.
public final class RealtimeProcessor: StreamProcessing {
    private let paths: RecordingPaths
    private let clock: () -> Double
    private let system: StreamTrack
    private let mic: StreamTrack
    /// Every settled system word, for the echo filter.
    private var remote: [Word] = []
    /// Closed mic sentences the echo filter has not decided.
    private var waiting: [StreamSentence] = []
    private var questions: [JSONValue] = []
    private var speaking = (others: false, me: false)

    public init(paths: RecordingPaths, systemEngine: StreamEngine, micEngine: StreamEngine,
                clock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.paths = paths
        self.clock = clock
        system = StreamTrack(GrowingTrack(final: paths.systemWav), systemEngine, now: clock())
        mic = StreamTrack(GrowingTrack(final: paths.micRawWav), micEngine, now: clock())
    }

    /// Reads the tracks up to what is written and feeds the engines. Returns whether new audio arrived.
    public func step() async throws -> Bool {
        var arrived = false
        let now = clock()
        for track in [system, mic] {
            if try track.pull() {
                arrived = true
                track.grewAt = now
            }
            advance(track, try await track.feed(minimum: Int(StreamWorker.MIN_FEED_SECONDS * Double(StreamWorker.SAMPLE_RATE))))
            // The recorder writes a track only when audio arrives: in a silence nothing comes that would settle the
            // last words. They settle once the track has not grown for MAX_AGE.
            if now - track.grewAt >= WindowEngine.MAX_AGE && (!track.draft.isEmpty || !track.unfed.isEmpty) {
                advance(track, try await track.feed(minimum: 1))
                advance(track, (track.engine.flush(), []))
            }
        }
        decideEcho()
        try judgeSpeaking()
        return arrived
    }

    /// Feeds what is left, settles the drafts and decides every mic sentence.
    public func finish() async throws {
        for track in [system, mic] {
            _ = try track.pull()
            advance(track, try await track.feed(minimum: 1))
        }
        for track in [system, mic] {
            advance(track, (track.engine.flush(), []))
            close(track)
        }
        decideEcho(final: true)
        speaking = (false, false)  // nobody speaks after the stop
        try write()
    }

    public func write() throws {
        let rate = Double(StreamWorker.SAMPLE_RATE)
        let state: JSONValue = .object([
            ("until", .double(Py.round(Double(min(system.fed, mic.fed)) / rate, 2))),
            // System words stay out (R6): they are most of the bytes of a file rewritten every second. The bench
            // needs the mic's, for echo.
            ("system", .array(system.sentences.map { $0.json(words: false) })),
            ("mic", .array(mic.sentences.map { $0.json() })),
            // The open sentence's settled words are in no sentence yet: they show with the draft.
            ("draft", .object([("system", .string(StreamWorker.text(system.words + system.draft))),
                               ("mic", .string(StreamWorker.text(mic.words + mic.draft)))])),
            ("questions", .array(questions)),
            ("speaking", .object([("others", .bool(speaking.others)), ("me", .bool(speaking.me))])),
            ("updated_at", .double(clock())),
        ])
        try PythonJSON.write(state, to: paths.stream, indent: nil, ensureAscii: true, via: paths.stream.lastPathComponent + ".tmp")
    }

    /// Both tracks over the same last moment: the recorder writes a track only when audio arrives, so a stalled
    /// track's own end is stale.
    private func judgeSpeaking() throws {
        let end = max(system.fed, mic.fed)
        let others = try system.loud(end)
        // The raw mic hears the others too: while they speak it can't tell.
        speaking = (others, try mic.loud(end) && !others)
    }

    private func advance(_ track: StreamTrack, _ result: (settled: [Word], draft: [Word])?) {
        guard let (settled, draft) = result else { return }
        track.draft = draft
        let now = clock()
        for word in settled {
            if let first = track.words.first, let last = track.words.last,
               word.start - last.end >= StreamWorker.SENTENCE_GAP || word.end - first.start > StreamWorker.MAX_SENTENCE {
                close(track)
            }
            track.words.append(Word(text: word.text, start: Py.round(word.start, 2), end: Py.round(word.end, 2),
                                    confidence: word.confidence))
            track.wordsAt = now
            if track === system { remote.append(word) }
            if let mark = word.text.last, StreamWorker.SENTENCE_END.contains(mark) { close(track) }
        }
        // A pause after the last settled word, with nothing heard yet in it.
        if let last = track.words.last {
            let heard = track.draft.first?.start ?? Double(track.fed) / Double(StreamWorker.SAMPLE_RATE)
            if heard - last.end >= StreamWorker.SENTENCE_GAP { close(track) }
        }
    }

    private func close(_ track: StreamTrack) {
        guard let first = track.words.first, let last = track.words.last else { return }
        let words = track.words
        track.words = []
        let text = StreamWorker.text(words)
        var sentence = StreamSentence(segment: Segment(start: first.start, end: last.end, text: text, words: words),
                                      settledAt: track.wordsAt, closedAt: clock())
        if track === mic {
            waiting.append(sentence)
            return
        }
        sentence.publishedAt = sentence.closedAt
        track.sentences.append(sentence)
        if text.hasSuffix("?") {
            questions.append(.object([("start", .double(first.start)), ("end", .double(last.end)), ("text", .string(text))]))
        }
    }

    /// Keeps or drops the waiting mic sentences, oldest first, once the system track has heard their moment or they
    /// waited long enough.
    private func decideEcho(final: Bool = false) {
        let heard = Double(system.fed) / Double(StreamWorker.SAMPLE_RATE)
        let now = clock()
        while var sentence = waiting.first {
            guard final || heard >= sentence.segment.end + StreamWorker.ECHO_LOOKAHEAD
                    || now - sentence.closedAt >= StreamWorker.ECHO_WAIT_SECONDS else { break }
            waiting.removeFirst()
            if !Cleanup.echoesRemote(sentence.segment, remote + system.draft) {
                sentence.publishedAt = now
                mic.sentences.append(sentence)
            }
        }
    }
}

// MARK: - the command

extension WorkerMain {
    /// `stream <folder>` (cli.py `_cmd_stream`): one stream per folder (a second leaves the first alone), stream.pid
    /// while it runs, stream_start/stream_done (with the peak memory) in session.log. Exit 0 when it followed the
    /// recording to its end, 1 when it gave up (the recorder died, or over its memory cap).
    static func stream(_ o: Options, env: [String: String]) async throws -> Int32 {
        let folder = try folderArgument(o)
        let config = loadConfig(o, env: env)
        let paths = RecordingPaths(folder)
        let log = SessionLog(url: paths.sessionLog, logger: "palaver")
        if let other = WorkerPids.streamPid(folder), other != Int(getpid()) {
            // Two streams would both load the model and rewrite stream.json.
            Stage.event("stream_already_running", log: log, [("pid", .int(other))])
            return 0
        }
        try Data(String(getpid()).utf8).write(to: paths.streamPid)
        defer { unlink(paths.streamPid.path) }
        let terminated = TerminationHandler { unlink(paths.streamPid.path) }
        defer { terminated.cancel() }
        do {
            Stage.event("stream_start", log: log)
            let engine = makeEngine(config: config, dictionary: dictionary(o, env: env), env: env, log: log)
            let (system, mic) = StreamWorker.loadEngines(engine)
            let processor = RealtimeProcessor(paths: paths, systemEngine: system, micEngine: mic)
            let meter = MemoryMeter()
            let finished = try await StreamWorker.run(processor, paths: paths, memory: { meter() }, memoryLimit: StreamWorker.memoryLimit(config),
                                                log: log)
            Stage.event("stream_done", log: log, [("finished", .bool(finished)), ("peak_mb", .int(meter.peakMB))])
            return finished ? 0 : 1
        } catch {
            log.message("command failed: \(error)", level: "ERROR", logger: "palaver")
            throw error
        }
    }
}
