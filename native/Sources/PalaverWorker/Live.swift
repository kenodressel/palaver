// `palaver-worker live <folder>` (palaver/live.py, diarizer.py `LiveEngineDiarizer`, cli.py `_cmd_live`): runs next to
// the recorder (the daemon starts it at background QoS) and does the heavy work as audio arrives — echo cancellation,
// transcription in ~1 min blocks cut at pauses, and the speakers. When the recording stops it finishes the last block
// and writes the files `process` writes (mic.wav, *_segments.json, system_turns.json, speaker_embeddings.json), so the
// `run` that follows only merges and uploads. If this worker dies, `process` does everything as before.
//
// It never disturbs the recording: the growing tracks are read as raw bytes past the header (`GrowingTrack`), in
// blocks of at most a minute whatever the backlog, no lock the recorder takes is held, and live.json (which the
// window reads while it is written) goes through `live.json.tmp` and a rename.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

/// A track's samples `start..<end` (int16, silence past what is written).
public typealias TrackRead = (_ start: Int, _ end: Int) throws -> [Int16]

/// What transcribes a block of the live worker (transcriber.py's transcribers).
public protocol LiveTranscriber: AnyObject {
    /// The segments of `wav`, times from its start.
    func transcribe(wav: URL, language: String?) async throws -> [Segment]
    /// The language the last call heard (Whisper's); nil when the model does not say (Parakeet).
    var lastLanguage: String? { get }
}

/// The speakers of the system track while it grows (diarizer.py `LiveEngineDiarizer`'s interface).
public protocol LiveDiarizer: AnyObject {
    /// A voice per label, from the last diarization.
    var lastEmbeddings: PyDict<[Double]> { get }
    /// Diarizations so far (live.json is rewritten when it changes).
    var chunksDone: Int { get }
    /// Diarizes again when there is enough new audio up to `available`; how many runs it made.
    func advance(read: TrackRead, available: Int) async throws -> Int
    /// The turns of the last diarization.
    func provisional() -> [SpeakerTurn]
    /// The turns of the whole track, `0..<until`.
    func finish(read: TrackRead, until: Int) async throws -> [SpeakerTurn]
}

/// The echo canceller over the two growing tracks (`AecStream`).
public protocol EchoCanceller: AnyObject {
    func process(mic: [Int16], system: [Int16]) throws -> [Int16]
}

extension AecStream: EchoCanceller {}

/// The worker's loop as `Live.run` drives it (`LiveProcessor`; tests stand in their own).
public protocol LiveProcessing: AnyObject {
    func step() async throws -> Bool
    func snapshot() throws -> Bool
    func finalUntil() -> Int
    func finish() async throws
    func abort()
}

public enum Live {
    public static let SAMPLE_RATE = 16_000
    /// What a live worker writes for a moment in the recording folder: the diarizer's copy of the system track and
    /// each track's block on its way to the transcriber.
    static let SCRATCH = [".live-diarize.wav", "live-system.wav", "live-mic.wav"]

    /// Removes a live worker's scratch files (SIGTERM ended it, or `process` finds a killed one's).
    static func removeScratch(_ folder: URL) {
        for name in SCRATCH { unlink(folder.appendingPathComponent(name).path) }
    }

    /// Transcribe about this much audio at a time, cut at the quietest moment near the end so no sentence is split.
    public static let BLOCK_SECONDS = 60.0
    public static let CUT_SEARCH_SECONDS = 15.0
    /// Stay this far behind the newest written sample: the recorder writes a track only when audio arrives and
    /// zero-pads gaps afterwards, so anything older than a few seconds is final.
    public static let MARGIN_SECONDS = 3.0
    public static let POLL_SECONDS = 5.0
    /// .part files that stop growing without meta.json appearing: the recorder died. Leave the folder to `process`.
    public static let STALL_SECONDS = 120.0
    /// Shorter remainders hold no speech worth a model call.
    public static let MIN_BLOCK_SECONDS = 0.5
    /// diarizer.py `LIVE_DIARIZE_EVERY`: the whole system track so far is diarized again at most this often (seconds
    /// of new audio): the engine has no incremental mode.
    public static let LIVE_DIARIZE_EVERY = 120.0
    /// The echo canceller and the diarizer's scratch file read the tracks this much at a time, so a worker that
    /// starts late (an hour of backlog) holds no whole track in memory.
    static let READ_BLOCK = 60 * SAMPLE_RATE

    public static func pidFile(_ folder: URL) -> URL { folder.appendingPathComponent("live.pid") }

    /// `recording_finished`: meta.json is there and neither track is still a `.part`.
    public static func recordingFinished(_ paths: RecordingPaths) -> Bool {
        exists(paths.meta) && ![paths.micRawWav, paths.systemWav].contains { exists(URL(fileURLWithPath: $0.path + ".part")) }
    }

    static func exists(_ url: URL) -> Bool { access(url.path, F_OK) == 0 }

    /// The monotonic clock in seconds (`time.monotonic`).
    public static func monotonic() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    public static func sleep(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9)) }

    /// `run_live`: steps until the recording stops, then finishes. Returns false (and leaves everything to
    /// `process`) when the recorder stopped without finishing the recording, or the folder went away.
    public static func run(_ processor: LiveProcessing, paths: RecordingPaths, poll: Double = POLL_SECONDS,
                           stall: Double = STALL_SECONDS, clock: () -> Double = monotonic,
                           sleep: (Double) async throws -> Void = sleep, log: SessionLog? = nil) async throws -> Bool {
        var lastSize = -1
        var lastGrowth = clock()
        while !recordingFinished(paths) {
            let progressed: Bool
            do {
                progressed = try await processor.step()
            } catch {
                if !exists(paths.folder) {  // dropped as too short, or moved away: nothing left to do
                    log?.message("the recording's folder is gone; the live worker stops", logger: "palaver.live")
                    return false
                }
                throw error
            }
            if progressed { continue }
            do {
                _ = try processor.snapshot()
            } catch {  // showing it live is extra; the recording goes on
                log?.message("live snapshot failed: \(error)", level: "ERROR", logger: "palaver.live")
            }
            let size = processor.finalUntil()
            if size != lastSize {
                lastSize = size
                lastGrowth = clock()
            } else if clock() - lastGrowth > stall {
                log?.message("recording stopped growing without finishing; leaving it to `process`", level: "WARNING",
                             logger: "palaver.live")
                processor.abort()
                return false
            }
            try await sleep(poll)
        }
        try await Stage.with("live_finish", log: log) { _ in try await processor.finish() }
        return true
    }
}

// MARK: - the transcriber and the diarizer through the engine

/// transcriber.py `EngineTranscriber` for the live worker: Parakeet ignores `language` and never names one.
public final class EngineLiveTranscriber: LiveTranscriber {
    private let engine: EngineCalls
    public init(_ engine: EngineCalls) { self.engine = engine }
    public var lastLanguage: String? { nil }
    public func transcribe(wav: URL, language: String?) async throws -> [Segment] { try await engine.transcribe(wav: wav) }
}

/// diarizer.py `LiveEngineDiarizer`: the engine diarizes whole files, so every `LIVE_DIARIZE_EVERY` seconds of new
/// audio the system track so far is written to a scratch file (`.live-diarize.wav`, a block at a time) and diarized
/// again.
public final class LiveEngineDiarizer: LiveDiarizer {
    private let scratch: URL
    private let engine: EngineCalls
    private var turns: [SpeakerTurn] = []
    private var lastAt = 0
    public private(set) var chunksDone = 0
    public private(set) var lastEmbeddings = PyDict<[Double]>()

    public init(folder: URL, engine: EngineCalls) {
        scratch = folder.appendingPathComponent(".live-diarize.wav")
        unlink(scratch.path)  // a killed worker's
        self.engine = engine
    }

    public func advance(read: TrackRead, available: Int) async throws -> Int {
        if Double(available) < Double(lastAt) + Live.LIVE_DIARIZE_EVERY * Double(Live.SAMPLE_RATE) { return 0 }
        turns = try await diarize(read, until: available)
        lastAt = available
        chunksDone += 1
        return 1
    }

    public func provisional() -> [SpeakerTurn] { turns }

    public func finish(read: TrackRead, until: Int) async throws -> [SpeakerTurn] {
        turns = try await diarize(read, until: until)
        chunksDone += 1
        return turns
    }

    private func diarize(_ read: TrackRead, until: Int) async throws -> [SpeakerTurn] {
        defer { unlink(scratch.path) }
        // EngineDiarizer.diarize: a track that got nothing needs no engine.
        if Double(until) < EngineAudio.MIN_AUDIO_SECONDS * Double(Live.SAMPLE_RATE) {
            lastEmbeddings = PyDict()
            return []
        }
        let w = try Wav16.Writer(scratch, rate: Live.SAMPLE_RATE)
        defer { w.close() }
        var at = 0
        while at < until {
            let end = min(at + Live.READ_BLOCK, until)
            try w.append(try read(at, end))
            at = end
        }
        try w.finish()
        let (found, voices) = try await engine.diarize(wav: scratch)
        lastEmbeddings = voices
        return found
    }
}

// MARK: - a growing track, block by block

/// `TrackTranscriber`: transcribes a growing track block by block; segments keep absolute times.
final class TrackTranscriber {
    let name: String
    private let transcriber: LiveTranscriber
    private let scratch: URL
    private let speaker: String?
    var done = 0
    var segments: [Segment] = []

    init(_ name: String, _ transcriber: LiveTranscriber, scratch: URL, speaker: String? = nil) {
        self.name = name
        self.transcriber = transcriber
        self.scratch = scratch
        self.speaker = speaker
    }

    /// Transcribes the next block if one is complete (or, with `last`, everything up to `finalUntil`). Returns
    /// whether it did.
    func advance(_ read: TrackRead, finalUntil: Int, last: Bool = false, language: String? = nil) async throws -> Bool {
        let rate = Live.SAMPLE_RATE
        let block = Int(Live.BLOCK_SECONDS * Double(rate))
        let end: Int
        if last {
            end = finalUntil
        } else if finalUntil - done >= block {
            let search = Int(Live.CUT_SEARCH_SECONDS * Double(rate))
            let latest = min(finalUntil, done + block + search)
            let audio = try read(done, latest).map(Float.init)
            end = done + GrowingTrack.quietestCut(audio, earliest: latest - done - search, latest: latest - done)
        } else {
            return false
        }
        if Double(end - done) < Live.MIN_BLOCK_SECONDS * Double(rate) {
            done = max(done, end)
            return false
        }
        let audio = try read(done, end)
        if audio.contains(where: { $0 != 0 }) {
            segments += try await transcribe(audio, offset: Double(done) / Double(rate), language: language)
        }
        done = end
        return true
    }

    private func transcribe(_ audio: [Int16], offset: Double, language: String?) async throws -> [Segment] {
        let wav = scratch.appendingPathComponent("live-\(name).wav")
        defer { unlink(wav.path) }
        try Wav16.write(audio, rate: Live.SAMPLE_RATE, to: wav)
        return try await transcriber.transcribe(wav: wav, language: language).map { s in
            var s = s
            s.start += offset
            s.end += offset
            s.words = s.words.map { Word(text: $0.text, start: $0.start + offset, end: $0.end + offset, confidence: $0.confidence) }
            if let speaker { s.speaker = speaker }
            return s
        }
    }
}

/// The echo-cancelled mic as it is made: `<mic.wav>.part` (a 44-byte header, then samples appended, each visible to
/// readers at once), finished to its length and renamed, or left with a header stating what it holds
/// (capture_recorder.py `_IncrementalTrackWriter`).
final class PartWriter {
    let finalURL: URL
    let partURL: URL
    private var fd: Int32
    private(set) var framesWritten = 0

    init(final: URL) throws {
        finalURL = final
        partURL = URL(fileURLWithPath: final.path + ".part")
        fd = open(partURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw PartWriter.error("cannot open \(partURL.lastPathComponent)") }
        try header(frames: 0)
    }

    deinit { if fd >= 0 { close(fd) } }

    func append(_ samples: [Int16]) throws {
        guard fd >= 0, !samples.isEmpty else { return }
        let le = samples.map(\.littleEndian)
        try le.withUnsafeBytes { try put($0, at: GrowingTrack.HEADER_BYTES + 2 * framesWritten) }
        framesWritten += samples.count
    }

    /// `finalize_to`: cut (or extend with silence) to `frames`, the header patched, renamed to the final name.
    func finalize(to frames: Int) throws {
        guard fd >= 0 else { return }
        guard ftruncate(fd, off_t(GrowingTrack.HEADER_BYTES + 2 * frames)) == 0 else { throw PartWriter.error("cannot cut \(partURL.lastPathComponent)") }
        try header(frames: frames)
        close(fd)
        fd = -1
        guard rename(partURL.path, finalURL.path) == 0 else { throw PartWriter.error("cannot rename \(partURL.lastPathComponent)") }
    }

    /// `abort`: closed without the rename, its header saying what was written.
    func abort() {
        guard fd >= 0 else { return }
        try? header(frames: framesWritten)
        close(fd)
        fd = -1
    }

    private func header(frames: Int) throws {
        try Wav16.header(dataBytes: 2 * frames, rate: Live.SAMPLE_RATE, channels: 1).withUnsafeBytes { try put($0, at: 0) }
    }

    private func put(_ bytes: UnsafeRawBufferPointer, at offset: Int) throws {
        var done = 0
        while done < bytes.count {
            let n = pwrite(fd, bytes.baseAddress! + done, bytes.count - done, off_t(offset + done))
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw PartWriter.error("cannot write \(partURL.lastPathComponent)") }
            done += n
        }
    }

    private static func error(_ what: String) -> WorkerError { WorkerError("\(what): \(String(cString: strerror(errno)))") }
}

// MARK: - the processor

/// `LiveProcessor`: echo cancellation, transcription and diarization of a recording in progress. `step` processes
/// what is final so far; `finish` completes the stopped recording and writes the pipeline's output files.
public final class LiveProcessor: LiveProcessing {
    private let paths: RecordingPaths
    private let mic: GrowingTrack
    private let system: GrowingTrack
    private let aec: EchoCanceller
    private var aecIn = 0  // raw mic samples fed to the canceller
    private let micOut: PartWriter
    private let aecTrack: GrowingTrack
    private let language: String
    private let transcriber: LiveTranscriber
    let systemText: TrackTranscriber
    let micText: TrackTranscriber
    public let diarizer: LiveDiarizer
    private var snapshotKey: [Int]?

    public init(paths: RecordingPaths, transcriber: LiveTranscriber, diarizer: LiveDiarizer, userName: String,
                language: String = "auto", aec: () throws -> EchoCanceller = { try AecStream() }) throws {
        self.paths = paths
        mic = GrowingTrack(final: paths.micRawWav)
        system = GrowingTrack(final: paths.systemWav)
        self.aec = try aec()
        micOut = try PartWriter(final: paths.micWav)
        aecTrack = GrowingTrack(final: paths.micWav)
        self.language = language
        self.transcriber = transcriber
        systemText = TrackTranscriber("system", transcriber, scratch: paths.folder)
        micText = TrackTranscriber("mic", transcriber, scratch: paths.folder, speaker: userName)
        self.diarizer = diarizer
    }

    /// Samples that will not change any more on either track.
    public func finalUntil() -> Int {
        max(0, max(mic.available(), system.available()) - Int(Live.MARGIN_SECONDS * Double(Live.SAMPLE_RATE)))
    }

    /// Processes one slice of what is final so far; false when caught up.
    public func step() async throws -> Bool {
        let until = finalUntil()
        // The raw mic may trail the system track (held back while a call's mute is followed): echo-cancelled only
        // as far as it is written, never its silence-to-come.
        var progressed = try runAec(mic.exists ? min(until, mic.available()) : until)
        progressed = try await diarizer.advance(read: system.readInt16, available: until) > 0 || progressed
        progressed = try await systemText.advance(system.readInt16, finalUntil: until) || progressed
        progressed = try await micText.advance(aecTrack.readInt16, finalUntil: micOut.framesWritten, language: micLanguage) || progressed
        return progressed
    }

    public func finish() async throws {
        let micEnd = mic.available(), systemEnd = system.available()
        _ = try runAec(micEnd)
        try micOut.finalize(to: micEnd)
        systemText.segments = systemText.segments.filter { $0.start < Double(systemEnd) / Double(Live.SAMPLE_RATE) }
        while try await systemText.advance(system.readInt16, finalUntil: systemEnd) {}
        _ = try await systemText.advance(system.readInt16, finalUntil: systemEnd, last: true)
        let micLanguage = micLanguage
        while try await micText.advance(aecTrack.readInt16, finalUntil: micEnd, language: micLanguage) {}
        _ = try await micText.advance(aecTrack.readInt16, finalUntil: micEnd, last: true, language: micLanguage)
        let turns = try await diarizer.finish(read: system.readInt16, until: systemEnd)

        if let language = transcriber.lastLanguage, !language.isEmpty {
            try writeText(language + "\n", paths.language)
        }
        try write(.array(systemText.segments.map(\.json)), paths.systemSegments, indent: 2)
        try write(.array(micText.segments.map(\.json)), paths.micSegments, indent: 2)
        try write(embeddings(diarizer.lastEmbeddings), paths.speakerEmbeddings, indent: nil)
        try write(.array(turns.map(\.json)), paths.systemTurns, indent: 2)
        // Says the system text is the live worker's: with a cloud service chosen (#54), `process` replaces it.
        try TranscriptionMarker.write(paths, track: "system", info: [("engine", .string("live"))])
        unlink(paths.live.path)  // the files above say it all now
    }

    /// Writes live.json — the text so far and speakers clustered from the voices so far — when there is something
    /// new. Labels may change between snapshots; their voices (embeddings) say who is who.
    public func snapshot() throws -> Bool {
        let key = [systemText.done, micText.done, diarizer.chunksDone]
        if key == snapshotKey { return false }
        snapshotKey = key
        let turns = diarizer.provisional()
        let until = Py.round(Double(min(systemText.done, micText.done)) / Double(Live.SAMPLE_RATE), 2)
        try write(.object([("until", .double(until)), ("system", .array(systemText.segments.map(\.json))),
                           ("mic", .array(micText.segments.map(\.json))), ("turns", .array(turns.map(\.json))),
                           ("embeddings", turns.isEmpty ? .object([]) : embeddings(diarizer.lastEmbeddings))]),
                  paths.live, indent: nil)
        return true
    }

    public func abort() {
        micOut.abort()
        unlink(micOut.partURL.path)
    }

    private var micLanguage: String? {
        if language != "auto" { return language }
        return transcriber.lastLanguage  // as in `process`: the language heard on the system track
    }

    /// The raw mic up to `until` through the canceller into mic.wav.part, a block at a time.
    private func runAec(_ until: Int) throws -> Bool {
        if until <= aecIn { return false }
        while aecIn < until {
            let end = min(aecIn + Live.READ_BLOCK, until)
            try micOut.append(try aec.process(mic: try mic.readInt16(aecIn, end), system: try system.readInt16(aecIn, end)))
            aecIn = end
        }
        return true
    }

    private func embeddings(_ voices: PyDict<[Double]>) -> JSONValue {
        .object(voices.map { ($0.key, .array($0.value.map { .double($0) })) })
    }

    /// `_write_atomic(path, json.dumps(value, indent=…))`: `<name>.tmp`, then renamed over the file.
    private func write(_ value: JSONValue, _ url: URL, indent: Int?) throws {
        try PythonJSON.write(value, to: url, indent: indent, ensureAscii: true, via: url.lastPathComponent + ".tmp")
    }

    private func writeText(_ text: String, _ url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".tmp")
        try Data(text.utf8).write(to: tmp)
        guard rename(tmp.path, url.path) == 0 else { throw WorkerError("cannot rename \(tmp.lastPathComponent)") }
    }
}

// MARK: - stop when told

/// SIGTERM (the daemon's watchdog, or its stop of a stuck worker): `cleanup` runs, then the process ends as the
/// signal would have ended it. Without this the default action would kill the worker as Python's did, leaving its
/// pid file and scratch files to the next reader.
final class TerminationHandler {
    private let source: DispatchSourceSignal

    init(_ cleanup: @escaping () -> Void) {
        signal(SIGTERM, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            cleanup()
            signal(SIGTERM, SIG_DFL)
            kill(getpid(), SIGTERM)
        }
        source.resume()
    }

    func cancel() {
        source.cancel()
        signal(SIGTERM, SIG_DFL)
    }
}

// MARK: - the command

extension WorkerMain {
    /// `live <folder>` (cli.py `_cmd_live`): live.pid while it runs, live_start/live_done in session.log, the engine's
    /// proof when it transcribed and diarized. Exit 0 when it finished the recording, 1 when it left it to `process`.
    static func live(_ o: Options, env: [String: String]) async throws -> Int32 {
        let folder = try folderArgument(o)
        let config = loadConfig(o, env: env)
        let stores = stores(env)
        let paths = RecordingPaths(folder)
        let pid = Live.pidFile(folder)
        try Data(String(getpid()).utf8).write(to: pid)
        defer { unlink(pid.path) }
        let log = SessionLog(url: paths.sessionLog, logger: "palaver")
        Stage.event("live_start", log: log)
        let engine = makeEngine(config: config, dictionary: dictionary(o, env: env), env: env, log: log)
        let processor: LiveProcessor
        do {
            processor = try LiveProcessor(paths: paths, transcriber: EngineLiveTranscriber(engine),
                                          diarizer: LiveEngineDiarizer(folder: folder, engine: engine),
                                          userName: SettingsFile.currentUserName(default: config.userName, stores: stores),
                                          language: config.language)
        } catch {
            log.message("command failed: \(error)", level: "ERROR", logger: "palaver")
            throw error
        }
        let terminated = TerminationHandler {
            processor.abort()
            unlink(pid.path)
            Live.removeScratch(folder)
        }
        defer { terminated.cancel() }
        let finished: Bool
        do {
            finished = try await Live.run(processor, paths: paths, log: log)
        } catch {
            processor.abort()
            log.message("command failed: \(error)", level: "ERROR", logger: "palaver")
            throw error
        }
        Stage.event("live_done", log: log, [("finished", .bool(finished))])
        // Live transcribed and diarized through the engine: the later `run` skips both.
        Pipeline.noteEngineRun(finished ? 0 : 1, engine: engine, stores: stores)
        return finished ? 0 : 1
    }
}

extension Pipeline {
    /// `_note_engine_run` for a worker without a pipeline setup (live).
    static func noteEngineRun(_ rc: Int32, engine: EngineCalls, stores: StorePaths) {
        guard rc == 0, engine.succeeded.isSuperset(of: ["transcribe", "diarize"]) else { return }
        let marker = stores.engineProvenMarker
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((Py.isoNow(timespec: "seconds") + "\n").utf8).write(to: marker)
    }
}
