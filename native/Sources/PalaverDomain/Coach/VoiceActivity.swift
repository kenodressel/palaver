// Who is talking now, from the levels of the two tracks (palaver/voice_activity.py, #42, the < 1 s tier).
//
// No model: the recorder's raw mic and system tracks are read as they grow, in 100 ms frames. A frame is speech when
// it is clearly above its track's noise floor (the quietest frame of the last half minute) and above an absolute
// level. The mic track is the user; the system track is everyone else.
//
// Without headphones the others come back on the mic through the speakers. Mic activity while the others talk counts
// as the user only when the mic is clearly louder than the echo would be: the echo's level is learned as the median
// of (mic − system) over frames where only the others talk, and starts out as loud as the system track itself (0 dB)
// until there is enough to learn from. So with speakers the user talking over someone is seen only when clearly
// louder than the echo: it errs towards "not me", never towards counting the others' voices as the user's.
//
// From the frames it keeps, for the last ten minutes: who talks now, the talk share, the current monologue (stretches
// of the user's speech across pauses up to 3 s, ended by someone else talking for 1.5 s or more), the interruptions
// (one starts while the other talks, and both go on together for more than 0.5 s) and, for the user's questions (from
// the stream's text, `questions`), how long it stayed quiet until someone answered.
//
// `VoiceMonitor` reads the growing tracks of a recording on its own thread (never the recorder's) through
// `GrowingTrack`, and keeps a snapshot for the status.
import Accelerate
import Foundation
import PalaverCore

public final class VoiceActivity {
    // voice_activity.py:47-71.
    public static let SAMPLE_RATE = 16_000
    public static let FRAME_SECONDS = 0.1
    public static let FRAME = Int(FRAME_SECONDS * Double(SAMPLE_RATE))
    public static let SUBFRAMES = 5
    /// Talk share over the last ten minutes.
    public static let WINDOW_SECONDS = 600.0
    /// Segments older than this are dropped.
    public static let KEEP_SECONDS = 900.0
    /// Speech is never quieter than this ...
    public static let SPEECH_DBFS = -50.0
    /// ... and this far above its track's noise floor.
    public static let ABOVE_FLOOR_DB = 12.0
    /// The floor: the quietest 20 ms of the last 30 s ...
    public static let FLOOR_FRAMES = 300
    /// ... at most this: a quiet room is quieter, and speech from the start is not the floor.
    public static let FLOOR_CAP_DBFS = -42.0
    /// The system track this loud can come back on the mic.
    public static let AUDIBLE_DBFS = -60.0
    /// The echo comes back within 0.5 s (Bluetooth speakers ~0.3 s).
    public static let ECHO_FRAMES = 5
    /// The user is this much louder than the echo would be.
    public static let ECHO_MARGIN_DB = 10.0
    /// Before it is learned: as loud as the system track.
    public static let ECHO_DEFAULT_DB = 0.0
    /// Learned from 3 s of only the others talking.
    public static let ECHO_LEARN_FRAMES = 30
    public static let ECHO_KEEP_FRAMES = 600
    /// 0.2 s of speech starts a turn.
    public static let ONSET_FRAMES = 2
    /// 0.5 s without ends it.
    public static let HANGOVER_FRAMES = 5
    /// Talking over the other this long is an interruption.
    public static let OVERLAP_SECONDS = 0.5
    /// A talk share needs this much talk in the window.
    public static let SHARE_MIN_SECONDS = 30.0
    /// Decided questions kept for the median wait.
    public static let QUESTIONS_KEPT = 50
    /// My speech starting this long after my question is me going on.
    public static let QUESTION_OWN_SECONDS = 0.3
    /// An answer may start this much before the question's last word ends.
    public static let ANSWER_EARLY_SECONDS = 0.5
    /// The status says how a question went for this long.
    public static let QUESTION_SHOWN_SECONDS = 60.0

    /// One question of mine and how it went.
    struct Question {
        let at: Double
        let wait: Double
        let answered: Bool
        let keptTalking: Bool

        var json: JSONValue {
            .object([("at", .double(at)), ("wait", .double(wait)), ("answered", .bool(answered)), ("kept_talking", .bool(keptTalking))])
        }
    }

    private var t: Double  // time of the next frame
    private var start: Double
    private var pending: (mic: [Int16], system: [Int16]) = ([], [])
    private var floors: (mic: Window, system: Window) = (Window(FLOOR_FRAMES), Window(FLOOR_FRAMES))
    private var recentSystem = Window(ECHO_FRAMES)
    private var echo = Window(ECHO_KEEP_FRAMES)
    private var echoDb = ECHO_DEFAULT_DB
    let me = Party(), others = Party()
    /// Monologues: my stretch now [start, end], broken by the others.
    private var stretch: (start: Double, end: Double)?
    private var broken = false
    private var longest = 0.0
    /// Turns started over the other's, to time the overlap.
    private var watch: [(who: String, since: Double)] = []
    private var interruptions = (byMe: 0, ofMe: 0)
    /// My questions (their end times): waiting for an answer, and decided (answered or I went on), kept with their
    /// wait so pruned turns never change it.
    private(set) var waitingQuestions: [Double] = []
    private var decided: [Question] = []
    private var seen: Set<Double> = []

    public init(start: Double = 0.0) {
        t = start
        self.start = start
    }

    // MARK: frames

    /// `frame_db`: dBFS of each whole 100 ms frame of `samples`, and of its quietest 20 ms (what the noise floor is
    /// taken from: speech has short dips even without a pause).
    public static func frameDb(_ samples: ArraySlice<Int16>) -> (db: [Double], low: [Double]) {
        let n = samples.count / FRAME
        guard n > 0 else { return ([], []) }
        let sub = FRAME / SUBFRAMES
        // Each 20 ms subframe's mean power (samples / 32768), through Accelerate.
        var x = [Float](repeating: 0, count: n * FRAME)
        samples.withUnsafeBufferPointer { s in vDSP_vflt16(s.baseAddress!, 1, &x, 1, vDSP_Length(n * FRAME)) }
        var scale: Float = 1 / 32768
        vDSP_vsmul(x, 1, &scale, &x, 1, vDSP_Length(x.count))
        var db = [Double](), low = [Double]()
        db.reserveCapacity(n)
        low.reserveCapacity(n)
        x.withUnsafeBufferPointer { p in
            for f in 0..<n {
                var total = 0.0, least = Double.infinity
                for k in 0..<SUBFRAMES {
                    var squares: Float = 0
                    vDSP_svesq(p.baseAddress! + f * FRAME + k * sub, 1, &squares, vDSP_Length(sub))
                    let power = Double(squares) / Double(sub)
                    total += power
                    least = Swift.min(least, power)
                }
                db.append(10 * log10(total / Double(SUBFRAMES) + 1e-12))
                low.append(10 * log10(least + 1e-12))
            }
        }
        return (db, low)
    }

    /// The next samples of both tracks, from the same moment on (the shorter one is silence for the rest).
    public func add(mic: [Int16], system: [Int16]) {
        let n = max(mic.count, system.count)
        let micAll = pending.mic + mic + repeatElement(0, count: n - mic.count)
        let systemAll = pending.system + system + repeatElement(0, count: n - system.count)
        let whole = micAll.count / Self.FRAME * Self.FRAME
        pending = (Array(micAll[whole...]), Array(systemAll[whole...]))
        let (micDb, micLow) = Self.frameDb(micAll[..<whole])
        let (systemDb, systemLow) = Self.frameDb(systemAll[..<whole])
        for i in micDb.indices {
            frame(micDb: micDb[i], micLow: micLow[i], systemDb: systemDb[i], systemLow: systemLow[i])
        }
    }

    /// Starts (or goes on) at `t` without frames before it: a monitor that starts late reads only the last minutes.
    public func skipTo(_ t: Double) {
        self.t = max(self.t, t)
        start = self.t
    }

    private static func active(_ db: Double, _ low: Double, _ floor: inout Window) -> Bool {
        floor.append(low)
        return db > max(SPEECH_DBFS, min(floor.min, FLOOR_CAP_DBFS) + ABOVE_FLOOR_DB)
    }

    private func frame(micDb: Double, micLow: Double, systemDb: Double, systemLow: Double) {
        let t = self.t
        let othersTalk = Self.active(systemDb, systemLow, &floors.system)
        let micSpeech = Self.active(micDb, micLow, &floors.mic)
        recentSystem.append(systemDb)
        let echoWindow = recentSystem.max
        let mine: Bool
        if echoWindow > Self.AUDIBLE_DBFS {
            // The call played within the echo's delay: the mic is mine only when clearly louder than its echo would be.
            mine = micSpeech && micDb > echoWindow + echoDb + Self.ECHO_MARGIN_DB
            if !mine && recentSystem.min > Self.SPEECH_DBFS {
                echo.append(micDb - echoWindow)
                if echo.count >= Self.ECHO_LEARN_FRAMES { echoDb = PyStatistics.median(echo.values) ?? echoDb }
            }
        } else {
            mine = micSpeech
        }
        me.take(mine, t)
        others.take(othersTalk, t)
        self.t = t + Self.FRAME_SECONDS
        follow(t)
    }

    private func follow(_ t: Double) {
        // Interruptions: a turn that starts while the other's runs, timed until both have talked together for
        // OVERLAP_SECONDS.
        for (who, party, other) in [("me", me, others), ("others", others, me)] {
            if party.started, other.talking, let theirs = other.openStart, let mine = party.openStart, theirs < mine {
                watch.append((who, mine))
            }
        }
        var still: [(who: String, since: Double)] = []
        for (who, since) in watch {
            let (party, other) = who == "me" ? (me, others) : (others, me)
            if party.openStart != since || !other.talking { continue }
            if min(party.lastEnd, other.lastEnd) - since > Self.OVERLAP_SECONDS {
                if who == "me" { interruptions.byMe += 1 } else { interruptions.ofMe += 1 }
            } else {
                still.append((who, since))
            }
        }
        watch = still
        // My stretch: my turns across pauses up to STRETCH_GAP; someone else talking BACKCHANNEL_SECONDS or more ends it.
        if me.started, let open = me.openStart {
            if let s = stretch, !broken, open - s.end <= Coach.STRETCH_GAP {
                // goes on
            } else {
                stretch = (open, me.lastEnd)
                broken = false
            }
        }
        if var s = stretch, !broken {
            if me.talking { s.end = me.lastEnd }
            if let theirs = others.openStart, others.lastEnd - theirs >= Coach.BACKCHANNEL_SECONDS, others.lastEnd > s.end {
                broken = true
            }
            stretch = s
            longest = max(longest, s.end - s.start)
        }
        if Int((t / Self.FRAME_SECONDS).rounded()) % 100 == 0 {
            me.prune(before: t - Self.KEEP_SECONDS)
            others.prune(before: t - Self.KEEP_SECONDS)
        }
    }

    // MARK: questions

    /// When each of the user's questions ended (from the stream's text); one already seen is not taken again.
    public func questions(_ ends: [Double]) {
        let new = Set(ends.map { Py.round($0, 2) }).subtracting(seen)
        seen.formUnion(new)
        waitingQuestions = Set(waitingQuestions).union(new).sorted()
        decide()
    }

    /// Questions answered (or followed by more of mine) are decided once, with their wait; one never answered is
    /// dropped with the old turns.
    private func decide() {
        var still: [Double] = []
        for at in waitingQuestions {
            let q = question(at)
            if q.answered || q.keptTalking {
                decided.append(q)
                if decided.count > Self.QUESTIONS_KEPT { decided.removeFirst() }
            } else if t - at <= Self.KEEP_SECONDS {
                still.append(at)
            }
        }
        waitingQuestions = still
        seen = seen.filter { t - $0 <= 2 * Self.KEEP_SECONDS }.union(waitingQuestions)
    }

    private func question(_ at: Double) -> Question {
        let mine = me.all().first { $0.start > at + Self.QUESTION_OWN_SECONDS }?.start
        let answer = others.all().first { $0.start >= at - Self.ANSWER_EARLY_SECONDS }?.start
        if let answer, mine == nil || answer <= mine! {
            return Question(at: at, wait: Py.round(max(0.0, answer - at), 1), answered: true, keptTalking: false)
        }
        if let mine {
            return Question(at: at, wait: Py.round(mine - at, 1), answered: false, keptTalking: true)
        }
        return Question(at: at, wait: Py.round(max(0.0, t - at), 1), answered: false, keptTalking: false)
    }

    // MARK: the snapshot

    /// Seconds of the recording taken in so far.
    public var until: Double { Py.round(t, 2) }

    /// Who talks and for how long (the status's `talk`, voice_activity.py's keys).
    public func snapshot() -> JSONValue {
        let now = t
        let since = max(start, now - Self.WINDOW_SECONDS)
        let mySeconds = me.seconds(since: since), theirSeconds = others.seconds(since: since)
        let speaking: JSONValue
        switch (me.talking, others.talking) {
        case (true, true): speaking = .string("both")
        case (true, false): speaking = .string("me")
        case (false, true): speaking = .string("others")
        case (false, false): speaking = .null
        }
        let ongoing = stretch.map { !broken && (me.talking || now - $0.end <= Coach.STRETCH_GAP) } ?? false
        decide()
        let answered = decided.filter(\.answered)
        let last = (decided + waitingQuestions.suffix(1).map(question)).max { $0.at < $1.at }
        let talk = mySeconds + theirSeconds
        return .object([
            ("until", .double(until)),
            ("speaking", speaking),
            ("window", .double(Py.round(now - since, 1))),
            ("me", .double(Py.round(mySeconds, 1))),
            ("others", .double(Py.round(theirSeconds, 1))),
            ("share", talk >= Self.SHARE_MIN_SECONDS ? .double(Py.round(mySeconds / talk, 3)) : .null),
            ("monologue", ongoing ? .double(Py.round(stretch!.end - stretch!.start, 1)) : .int(0)),
            ("longest", .double(Py.round(longest, 1))),
            ("interruptions", .object([("by_me", .int(interruptions.byMe)), ("of_me", .int(interruptions.ofMe))])),
            ("question", last?.json ?? .null),
            ("questions", .int(decided.count + waitingQuestions.count)),
            ("median_wait", PyStatistics.median(answered.map(\.wait)).map { .double(Py.round($0, 1)) } ?? .null),
            ("echo_db", echo.count >= Self.ECHO_LEARN_FRAMES ? .double(Py.round(echoDb, 1)) : .null),
        ])
    }

    // MARK: the status line

    /// `talk_text`: "You 62 % of the last 10 min · talking for 2:10", or nil when there is nothing to say.
    public static func talkText(_ s: JSONValue?) -> String? {
        guard let s, s.truthy else { return nil }
        var parts: [String] = []
        if let share = s["share"]?.doubleValue {
            let window = s["window"]?.doubleValue ?? 0
            parts.append("You \(Int((100 * share).rounded(.toNearestOrEven))) % of the last \(max(1, Int((window / 60).rounded(.toNearestOrEven)))) min")
        }
        if let speaking = s["speaking"]?.stringValue, speaking == "me" || speaking == "both",
           let monologue = s["monologue"]?.doubleValue, monologue >= 60 {
            parts.append("talking for \(mmss(monologue))")
        }
        let byMe = Int(s["interruptions"]?["by_me"]?.doubleValue ?? 0)
        if byMe != 0 { parts.append("\(byMe) interruption\(byMe != 1 ? "s" : "") by you") }
        if let q = s["question"], q.truthy, let at = q["at"]?.doubleValue, let wait = q["wait"]?.doubleValue {
            let shown = s["until"]?.doubleValue.map { $0 - at <= QUESTION_SHOWN_SECONDS + wait } ?? true
            if shown {
                if q["answered"]?.truthy == true {
                    parts.append("answered \(Int(wait + 0.5)) s after your question")
                } else if q["kept_talking"]?.truthy != true && wait >= 2 {
                    parts.append("quiet for \(Int(wait + 0.5)) s since your question")
                }
            }
        }
        guard !parts.isEmpty else { return nil }
        let text = parts.joined(separator: " · ")
        // The first letter capitalized: the parts start with ASCII ("You", "talking", a digit, "answered", "quiet").
        guard let first = text.unicodeScalars.first, ("a"..."z").contains(first) else { return text }
        return String(Character(Unicode.Scalar(first.value - 32)!)) + String(text.unicodeScalars.dropFirst())
    }

    private static func mmss(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.toNearestOrEven))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

/// One side's turns (`_Party`): a turn starts after ONSET_FRAMES of speech and ends after HANGOVER_FRAMES without.
final class Party {
    /// Closed turns, oldest first.
    private(set) var segments: [(start: Double, end: Double)] = []
    private(set) var openStart: Double?
    /// End of the last frame of speech.
    private(set) var lastEnd = 0.0
    private var run = 0  // frames of speech in a row
    private var runStart = 0.0
    private var silent = 0
    /// A turn started with the frame just taken.
    private(set) var started = false

    func take(_ active: Bool, _ t: Double) {
        started = false
        if active {
            if run == 0 { runStart = t }
            run += 1
            silent = 0
            if openStart == nil && run >= VoiceActivity.ONSET_FRAMES {
                openStart = runStart
                started = true
            }
            if openStart != nil { lastEnd = t + VoiceActivity.FRAME_SECONDS }
        } else {
            run = 0
            silent += 1
            if let open = openStart, silent >= VoiceActivity.HANGOVER_FRAMES {
                segments.append((open, lastEnd))
                openStart = nil
            }
        }
    }

    var talking: Bool { openStart != nil }

    func all() -> [(start: Double, end: Double)] { segments + (openStart.map { [($0, lastEnd)] } ?? []) }

    func seconds(since: Double) -> Double { all().reduce(0.0) { $0 + max(0.0, $1.end - max($1.start, since)) } }

    func prune(before: Double) {
        let gone = segments.prefix { $0.end < before }.count
        if gone > 0 { segments.removeFirst(gone) }
    }
}

/// The last `capacity` values (a `deque(maxlen=…)`).
struct Window {
    let capacity: Int
    private(set) var values: [Double] = []
    init(_ capacity: Int) { self.capacity = capacity }
    var count: Int { values.count }
    var min: Double { values.min() ?? .infinity }
    var max: Double { values.max() ?? -.infinity }
    mutating func append(_ v: Double) {
        values.append(v)
        if values.count > capacity { values.removeFirst() }
    }
}

// MARK: - the monitor

/// Reads a recording's growing tracks and keeps `VoiceActivity` up to date: `poll` once, or `start` a thread that
/// polls every 0.25 s. The tracks are read through `GrowingTrack` (raw bytes past the header, never a header the
/// recorder is still writing), at most a minute per poll.
public final class VoiceMonitor: @unchecked Sendable {
    // voice_activity.py:336-340.
    /// Read up to this far behind what the older track has written ...
    public static let LAG_SECONDS = 0.3
    /// ... unless it has written nothing this long: then it is silent (the tap writes nothing then).
    public static let STALE_SECONDS = 0.8
    public static let POLL_SECONDS = 0.25
    public static let STREAM_CHECK_SECONDS = 2.0
    /// Read at most this much per poll.
    public static let MAX_READ_SECONDS = 60.0

    /// One of my sentences from the stream.
    public struct Sentence: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let text: String
    }

    public let paths: RecordingPaths
    private let micTrack: GrowingTrack
    private let systemTrack: GrowingTrack
    private let clock: () -> Double
    /// After each poll, on the same thread (the nudges).
    private let onPoll: ((VoiceMonitor) -> Void)?
    private let lock = NSLock()
    private var _activity: VoiceActivity?
    private var done = 0
    private var _readSamples = 0
    private var streamKey: [Int]?
    private var streamChecked = -1e9
    private var _mine: [Sentence] = []
    private var _snapshot: JSONValue?
    private var stopping = false
    private var wake: DispatchSemaphore?
    private var ended: DispatchSemaphore?

    public init(folder: URL, clock: @escaping () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 },
                onPoll: ((VoiceMonitor) -> Void)? = nil) {
        paths = RecordingPaths(folder)
        micTrack = GrowingTrack(final: paths.micRawWav)
        systemTrack = GrowingTrack(final: paths.systemWav)
        self.clock = clock
        self.onPoll = onPoll
    }

    /// Samples read from each track so far.
    public var readSamples: Int { lock.withLock { _readSamples } }
    /// My sentences from the stream: start, end, text.
    public var mine: [Sentence] { lock.withLock { _mine } }

    /// Takes in what was written since the last poll; whether anything was.
    @discardableResult
    public func poll() -> Bool {
        let rate = VoiceActivity.SAMPLE_RATE, frame = VoiceActivity.FRAME
        let written = (micTrack.available(), systemTrack.available())
        // A track flushed late is not silence: wait for it, but not longer than STALE_SECONDS.
        var frontier = max(0, min(written.0, written.1) - Int(Self.LAG_SECONDS * Double(rate)),
                           max(written.0, written.1) - Int(Self.STALE_SECONDS * Double(rate)))
        frontier -= frontier % frame
        let activity: VoiceActivity = lock.withLock {
            if let a = _activity { return a }
            var start = max(0, frontier - Int(VoiceActivity.WINDOW_SECONDS * Double(rate)))
            start -= start % frame
            let a = VoiceActivity(start: Double(start) / Double(rate))
            _activity = a
            done = start
            return a
        }
        var progressed = false
        while done < frontier {
            let end = min(frontier, done + Int(Self.MAX_READ_SECONDS * Double(rate)))
            let mic = (try? micTrack.readInt16(done, end)) ?? [Int16](repeating: 0, count: end - done)
            let system = (try? systemTrack.readInt16(done, end)) ?? [Int16](repeating: 0, count: end - done)
            lock.withLock {
                activity.add(mic: mic, system: system)
                _readSamples += end - done
            }
            done = end
            progressed = true
        }
        readStream(activity)
        lock.withLock { _snapshot = activity.snapshot() }
        onPoll?(self)
        return progressed
    }

    private func readStream(_ activity: VoiceActivity) {
        let now = clock()
        if now - streamChecked < Self.STREAM_CHECK_SECONDS { return }
        streamChecked = now
        var st = stat()
        guard stat(paths.stream.path, &st) == 0 else { return }
        let key = [Int(st.st_mtimespec.tv_sec), Int(st.st_mtimespec.tv_nsec), Int(st.st_size)]
        if key == streamKey { return }
        streamKey = key
        guard let data = PythonJSON.read(paths.stream) else { return }
        let mine: [Sentence] = (data["mic"]?.arrayValue ?? []).compactMap { s in
            guard case .object = s, let text = s["text"]?.stringValue,
                  let start = s["start"]?.doubleValue, let end = s["end"]?.doubleValue else { return nil }
            return Sentence(start: start, end: end, text: text)
        }
        lock.withLock {
            _mine = mine
            activity.questions(mine.filter { $0.text.trimmingTrailingWhitespace().hasSuffix("?") }.map(\.end))
        }
    }

    /// The last poll's snapshot (nil before the first).
    public func snapshot() -> JSONValue? { lock.withLock { _snapshot } }

    /// Polls every `interval` seconds on a thread of its own until `stop`.
    public func start(interval: Double = POLL_SECONDS) {
        let wake = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
        lock.withLock {
            stopping = false
            self.wake = wake
            self.ended = ended
        }
        let thread = Thread { [self] in
            // The wait ends early when `stop` signals.
            while wake.wait(timeout: .now() + interval) == .timedOut && !lock.withLock({ stopping }) {
                poll()
            }
            ended.signal()
        }
        thread.name = "voice-activity"
        thread.start()
    }

    /// Asks the thread to end; waits at most `wait` seconds for it.
    public func stop(wait: Double = 2.0) {
        let (wake, ended) = lock.withLock { () -> (DispatchSemaphore?, DispatchSemaphore?) in
            stopping = true
            return (self.wake, self.ended)
        }
        wake?.signal()
        if let ended, ended.wait(timeout: .now() + wait) == .success {
            lock.withLock {
                self.wake = nil
                self.ended = nil
            }
        }
    }
}

private extension String {
    /// `rstrip()`: without trailing whitespace (Python's definition).
    func trimmingTrailingWhitespace() -> String {
        let scalars = unicodeScalars
        guard let last = scalars.lastIndex(where: { !Py.isSpace($0) }) else { return "" }
        return String(scalars[...last])
    }
}
