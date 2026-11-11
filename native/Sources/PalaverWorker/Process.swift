// `palaver-worker process <folder>` (cli.py `_cmd_process`, `_process`): a recording made whole (promoted tracks,
// the parts of a continued meeting joined, meta.json rebuilt), echo-cancelled, both tracks transcribed and the
// system track diarized by the speech engine in this process, the segments cleaned and merged, the calendar event
// attached, the voices recognized, the names inferred, then transcript.json and transcript.md. Every step skips
// what an earlier run (or the live worker) left on disk, so a run killed half-way picks up where it stopped.
//
// Failures leave the meeting as Python's do: failed.json "error" (with the short reason) or "models" (exit 4, the
// app transcribes it once the speech models are downloaded), no transcript written half.
import Darwin
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

/// What the worker's cloud steps work with (the system track through a transcription service, the Notion upload): the
/// keys (the Keychain), the HTTP transport, and config.toml for the Notion token and the providers' defaults.
public struct CloudServices {
    public var keys: KeyStore
    public var http: HTTPClient
    public var configToml: URL
    public var env: [String: String]
    /// What the service hears, in place of asking it (debug builds: the parity runs' `"cloud"` of PALAVER_TEST_ENGINE,
    /// as tools/parity/worker_python.py patches Python's `transcription._cloud`); nil: the service is asked.
    public var heard: ((RecordingPaths, String) throws -> CloudTranscription.Outcome)?

    public init(keys: KeyStore, http: HTTPClient = HTTPClient(), configToml: URL,
                env: [String: String] = ProcessInfo.processInfo.environment) {
        self.keys = keys
        self.http = http
        self.configToml = configToml
        self.env = env
    }

    /// The providers' settings and keys for `config`.
    func settings(_ config: Config, stores: StorePaths) -> ProviderSettings {
        ProviderSettings(config: config, stores: stores, keys: keys, env: env)
    }
}

/// A helper program the worker runs and waits for (palaver-lm for the notes), with the app's options, its stdout this process's, its stderr passed through (the last line kept: a helper's reason
/// for failing).
public struct HelperProgram: Sendable {
    public var program: String
    /// The global options the worker got, passed on: `--config F`, `--dictionary F`, `--no-notify`.
    public var options: [String]
    public var env: [String: String]

    public init(program: String, options: [String] = [], env: [String: String] = ProcessInfo.processInfo.environment) {
        self.program = program
        self.options = options
        self.env = env
    }

    public struct Finished: Sendable {
        /// The exit code; a negative one is the signal that ended it.
        public let code: Int32
        /// The last line it wrote to stderr that was not blank.
        public let lastError: String?
    }

    /// `<program> <argv…>`, waited for. Throws when it can't be started. The helper stays in this worker's process
    /// group, so the daemon's `killpg` stops it with the worker; a
    /// SIGTERM or SIGINT sent to the worker alone is passed on to it, and once it ended the worker stops the same way.
    /// Its stderr is read until it exits, then for at most `DRAIN_SECONDS` more: something it left running that keeps
    /// stderr open does not hold the worker.
    public func run(_ argv: [String]) throws -> Finished {
        fflush(stdout)
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw WorkerError("cannot start \(program): \(String(cString: strerror(errno)))") }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }  // the child gets its dup only
        let child: PalaverCore.Process
        do {
            child = try spawnChild([Self.resolve(program, env: env)] + argv, env: env, errors: fds[1], newSession: false)
        } catch {
            close(fds[0])
            close(fds[1])
            throw WorkerError("cannot start \(program): \(error)")
        }
        close(fds[1])
        let forwarding = SignalForwarding(to: child)
        let tail = StderrTail(fd: fds[0])
        child.waitUntilExit()
        let received = forwarding.stop()
        let last = tail.finish(within: Self.DRAIN_SECONDS)
        if let received {  // the worker was asked to stop: now that its helper has, it does
            signal(received, SIG_DFL)
            raise(received)
        }
        return Finished(code: child.poll() ?? -1, lastError: last)
    }

    /// How long stderr is still read after the helper exited.
    static let DRAIN_SECONDS = 2.0

    /// `program` as posix_spawn needs it: a path, else found on `PATH`.
    static func resolve(_ program: String, env: [String: String]) -> String {
        if program.contains("/") { return program }
        for dir in (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
            let candidate = "\(dir)/\(program)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return program
    }
}

/// SIGTERM and SIGINT, while a helper runs, passed on to it; which one came (the first) is kept.
final class SignalForwarding: @unchecked Sendable {
    private static let SIGNALS = [SIGTERM, SIGINT]
    private var sources: [DispatchSourceSignal] = []
    private var previous: [(Int32, sigaction)] = []
    private let lock = NSLock()
    private var got: Int32?

    init(to child: PalaverCore.Process) {
        for sig in Self.SIGNALS {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [weak self] in
                self?.lock.withLock { if self?.got == nil { self?.got = sig } }
                child.signal(sig)
            }
            source.resume()  // first: a signal from here on is seen
            sources.append(source)
            var old = sigaction()
            sigaction(sig, nil, &old)
            previous.append((sig, old))
            signal(sig, SIG_IGN)  // the source handles it; the worker waits for its helper
        }
    }

    /// Ends the forwarding, the signals' handling as before; the signal that came, if one did.
    func stop() -> Int32? {
        for source in sources { source.cancel() }
        for (sig, old) in previous {
            var action = old
            sigaction(sig, &action, nil)
        }
        return lock.withLock { got }
    }
}

/// A helper's stderr, passed through to the worker's and its last non-blank line kept.
final class StderrTail: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var last: String?
    private var deadline: Date?
    private let done = DispatchSemaphore(value: 0)

    init(fd: Int32) {
        self.fd = fd
        Thread { [self] in read() }.start()
    }

    private func take(_ line: Data) {
        let text = Py.strip(String(decoding: line, as: UTF8.self))
        if !text.isEmpty { lock.withLock { last = text } }
    }

    private func read() {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            if let end = lock.withLock({ deadline }), Date() >= end { break }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 100)
            if ready < 0 { if errno == EINTR { continue } else { break } }
            if ready == 0 { continue }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            let chunk = Data(buffer[0..<n])
            FileHandle.standardError.write(chunk)
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 0x0A) {
                take(pending[pending.startIndex..<nl])
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
        take(pending)
        close(fd)
        done.signal()
    }

    /// The last line, once the pipe is closed or `seconds` have passed from now.
    func finish(within seconds: Double) -> String? {
        lock.withLock { deadline = Date().addingTimeInterval(seconds) }
        done.wait()
        return lock.withLock { last }
    }
}

public enum Pipeline {
    /// What a run of the pipeline works with.
    public struct Setup {
        public var config: Config
        /// The user's name (settings.json's, else config.toml's): the speaker of the microphone's lines.
        public var userName: String
        public var dictionary: TranscriberDictionary
        /// `--dictionary` as given (session.log's process_start names it), nil without.
        public var dictionaryPath: String?
        public var engine: EngineCalls
        public var helper: HelperProgram
        /// palaver-lm, which writes the notes (with `helper`'s options); nil: none, the notes are not written.
        public var lm: String?
        /// Whether the calendar is on, and its events (nil: off or not allowed).
        public var calendar: (enabled: Bool, provider: CalendarProvider?)
        public var stores: StorePaths
        /// The transcription service and Notion: keys, transport, config.toml.
        public var cloud: CloudServices
        /// Where the lines `_process` prints go (stdout).
        public var say: (String) -> Void

        /// `cloud` nil: the Keychain, URLSession and `stores`' config.toml.
        public init(config: Config, userName: String, dictionary: TranscriberDictionary = TranscriberDictionary(),
                    dictionaryPath: String? = nil, engine: EngineCalls, helper: HelperProgram,
                    calendar: (enabled: Bool, provider: CalendarProvider?) = (false, nil), stores: StorePaths = .current(),
                    cloud: CloudServices? = nil, say: @escaping (String) -> Void = Pipeline.printLine) {
            self.config = config
            self.userName = userName
            self.dictionary = dictionary
            self.dictionaryPath = dictionaryPath
            self.engine = engine
            self.helper = helper
            self.calendar = calendar
            self.stores = stores
            self.cloud = cloud ?? CloudServices(keys: KeyStores.make(), configToml: stores.configToml)
            self.say = say
        }
    }

    public static func printLine(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    /// A step that failed as `_process` says itself: its line is printed, the meeting is marked "error".
    struct Refused: Error { let code: Int32 }

    /// `_cmd_process` after its checks: the pipeline under session.log, then failed.json, the engine's proof, the
    /// coach's baseline, the "Transcript ready" notification (not in `runMode`: `run` uploads next) and the usage line.
    /// `notes`: run the notes helper at the end (`--no-notes` and `run` say no). An error the pipeline does not
    /// expect is rethrown after the meeting is marked, as Python's traceback ends the command.
    public static func process(_ folder: URL, _ setup: Setup, notes: Bool = true, runMode: Bool = false) async throws -> Int32 {
        let paths = RecordingPaths(folder)
        let log = SessionLog(url: paths.sessionLog, logger: "palaver")
        let started = DispatchTime.now()
        var rc: Int32 = 1
        var error: String?
        defer {
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
            Usage.record("process", fields: [("seconds", .double(seconds)), ("ok", .bool(rc == 0)),
                                             ("transcriber", .string(setup.config.transcriber))], path: setup.stores.usage)
            noteEngineRun(rc, setup)
            if rc == 0 {
                ProcessState.clear(paths)
            } else if rc == ProcessState.exitModels {
                try? ProcessState.mark(paths, reason: ProcessState.models, missing: [ProcessState.speechModelsLabel])
            } else {
                try? ProcessState.mark(paths, reason: ProcessState.error, error: error)
            }
        }
        do {
            Stage.event("process_start", log: log, [("dictionary", .str(setup.dictionaryPath))])
            rc = try await run(paths, setup, log: log, notes: notes)
            Stage.event("process_done", log: log, [("rc", .int(Int(rc)))])
        } catch let missing as ModelsMissing {  // the engine has no models (yet): the meeting waits for the download
            rc = ProcessState.exitModels
            setup.say("error: \(missing); \(folder.lastPathComponent) is transcribed once the speech models are downloaded.")
        } catch let refused as Refused {
            rc = refused.code
            Stage.event("process_done", log: log, [("rc", .int(Int(rc)))])
        } catch let failure {
            error = failureReason(failure)
            log.message("command failed: \(failure)", level: "ERROR", logger: "palaver")
            throw failure
        }
        if rc == 0 {
            do {
                _ = try Coach.refreshBaseline(setup.config.outputDir, userName: setup.userName, stores: setup.stores)
            } catch {
                setup.say("warning: could not update the coach's baseline: \(error)")
            }
            if !runMode { Notify.send(title: "Transcript ready", message: folder.lastPathComponent, meeting: folder.lastPathComponent) }
        }
        return rc
    }

    /// `_failure_reason`: the short reason failed.json shows, the last line of the message.
    public static func failureReason(_ error: Error) -> String {
        let text = Py.strip("\(error)")
        return text.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? "\(type(of: error))"
    }

    /// `_note_engine_run`: a run that went well through the engine (it transcribed and diarized) proves the speech
    /// models work; Storage then offers to delete the old ones.
    static func noteEngineRun(_ rc: Int32, _ setup: Setup) {
        guard rc == 0, setup.engine.succeeded.isSuperset(of: ["transcribe", "diarize"]) else { return }
        let marker = setup.stores.engineProvenMarker
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((Py.isoNow(timespec: "seconds") + "\n").utf8).write(to: marker)
    }

    // MARK: - the pipeline (`_process`)

    static func run(_ head: RecordingPaths, _ setup: Setup, log: SessionLog, notes: Bool) async throws -> Int32 {
        let say = setup.say
        let fm = FileManager.default
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        // Crash recovery: a recorder killed before it finished leaves .part tracks (playable as they are) and no
        // meta.json; a recording continued after a restart is one meeting from here on.
        try Recovery.promoteParts(head)
        Recovery.foldAudioProblems(head)
        let continuationLog: Continuation.Log = { level, text in
            log.message(text, level: level, logger: "palaver.continuation")
            if level == "WARNING" || level == "ERROR" { FileHandle.standardError.write(Data((text + "\n").utf8)) }
        }
        let paths = try Continuation.recoverHead(head, log: continuationLog)
        let folder = paths.folder
        try Continuation.joinParts(paths, log: continuationLog)

        if !exists(paths.meta) {
            if Recovery.synthesizeMeta(paths) {
                say("warning: \(paths.meta.lastPathComponent) was missing — reconstructed from folder name and WAV duration. "
                    + "Likely a crashed recording.")
            } else {
                say("error: \(paths.meta.path) not found. This folder was not closed cleanly by `record` (likely killed "
                    + "mid-recording) and no audio was found to reconstruct session timestamps from.")
                throw Refused(code: 2)
            }
        }

        if !exists(paths.micWav) {
            say("Running AEC (mic_raw.wav + system.wav → mic.wav)…")
            if !exists(paths.micRawWav) {
                say("error: \(paths.micRawWav.lastPathComponent) not found. This recording was made before V2 and has no pre-AEC mic track.")
                throw Refused(code: 2)
            }
            if !exists(paths.systemWav) {
                say("error: \(paths.systemWav.lastPathComponent) not found — capture was broken.")
                throw Refused(code: 2)
            }
            try Stage.with("aec", log: log) { _ in try Aec.process(micRaw: paths.micRawWav, system: paths.systemWav, out: paths.micWav) }
        } else {
            say("Skipping AEC (mic.wav already present)")
        }
        // A live worker stopped or killed during the call leaves its own, unfinished mic.wav; the one above is final.
        unlink(paths.micWav.path + ".part")
        Live.removeScratch(folder)  // the live worker's scratch files

        // What a service could not delete before (`sweep_pending`), retried first; then a transcription service chosen
        // in Settings takes the system track (#54).
        if CloudChoice.deletionsPending(root: folder.deletingLastPathComponent(), stores: setup.stores) {
            await sweepPending(folder, setup)
        }
        let cloud = CloudChoice.provider(folder: folder, stores: setup.stores)

        // The tap can deliver nothing for a whole call: a valid recording, transcribed from the mic alone.
        let systemEmpty = !EngineAudio.holdsAudio(paths.systemWav)
        if systemEmpty {
            say("System track holds no audio; transcribing the microphone only")
            Stage.event("system_track_empty", log: log)
        }

        // The system track first: a language it had (the live worker's) is the mic's too.
        try await systemTrack(paths, setup, log: log, systemEmpty: systemEmpty, cloud: cloud)

        if !exists(paths.micSegments) {
            var micLanguage: String?
            if setup.config.language == "auto", let text = try? String(contentsOf: paths.language, encoding: .utf8) {
                micLanguage = Py.strip(text).isEmpty ? nil : Py.strip(text)
            }
            say("Transcribing mic track\(micLanguage.map { " (\($0))" } ?? "")…")
            var mic = try await Stage.with("transcribe", log: log, fields: [("track", .string("mic")), ("language", .str(micLanguage))]) { info in
                let segments = try await setup.engine.transcribe(wav: paths.micWav)
                info["segments"] = .int(segments.count)
                return segments
            }
            for i in mic.indices { mic[i].speaker = setup.userName }
            try saveSegments(paths.micSegments, mic)
        } else {
            say("Skipping mic transcription (already done)")
        }

        await setup.engine.release()  // both tracks are done: one model at a time lowers the peak

        // The voices feed recognition; a recording diarized before they were kept is diarized again (the engine's
        // diarization is deterministic: the same turns).
        if systemEmpty {
            try Data("{}".utf8).write(to: paths.speakerEmbeddings)
            try Data("[]".utf8).write(to: paths.systemTurns)
        } else if !exists(paths.systemTurns) || !exists(paths.speakerEmbeddings) {
            say("Diarizing system track…")
            let (turns, voices) = try await Stage.with("diarize", log: log) { info in
                let found = try await setup.engine.diarize(wav: paths.systemWav)
                info["turns"] = .int(found.turns.count)
                info["speakers"] = .int(Set(found.turns.map { ScalarKey($0.speaker) }).count)
                return found
            }
            try PythonJSON.write(.object(voices.map { ($0.key, .array($0.value.map(JSONValue.double))) }), to: paths.speakerEmbeddings,
                                 indent: nil, ensureAscii: true)
            try PythonJSON.write(.array(turns.map(\.json)), to: paths.systemTurns, indent: 2, ensureAscii: true)
        } else {
            say("Skipping diarization (already done)")
        }

        await setup.engine.release()  // nothing else needs the engine: the notes' model gets the memory

        say("Merging…")
        var micSegs = try readList(paths.micSegments).map { try Segment(json: $0) }
        var sysSegs = try readList(paths.systemSegments).map { try Segment(json: $0) }
        let turns = try readList(paths.systemTurns).map { try SpeakerTurn(json: $0) }
        micSegs = micSegs.filter { !Py.strip($0.text).isEmpty }
        sysSegs = sysSegs.filter { !Py.strip($0.text).isEmpty }
        let (nMic, nSys) = (micSegs.count, sysSegs.count)
        micSegs = try Cleanup.dropSilentSegments(micSegs, wav: paths.micWav, minPeakDbfs: Cleanup.MIC_MIN_PEAK_DBFS)
        sysSegs = try Cleanup.dropSilentSegments(sysSegs, wav: paths.systemWav, minPeakDbfs: Cleanup.SYSTEM_MIN_PEAK_DBFS)
        let nSilentMic = nMic - micSegs.count
        micSegs = Cleanup.dropBleedDuplicates(micSegs, sysSegs)
        micSegs = try Cleanup.dropEcho(micSegs, sysSegs, micWav: paths.micWav, micRawWav: paths.micRawWav)
        let droppedSilent = nSilentMic + nSys - sysSegs.count
        let droppedBleed = nMic - nSilentMic - micSegs.count
        say("Dropped \(droppedSilent) segments over silence (likely hallucinations) and \(droppedBleed) mic segments that "
            + "were remote speech heard through the speakers.")

        let meetingEvent = attachCalendar(paths, setup, log: log)
        if let meetingEvent { say("Calendar: \(meetingEvent.title) (\(meetingEvent.attendees.count) invited)") }
        // The hints that one microphone was shared (#56), to calibrate them later: a line in the log, never a reason
        // for the transcript to fail.
        do {
            let signals = try SharedMic.signals(paths, event: meetingEvent, userName: setup.userName)
            var fields: [(String, JSONValue)] = []
            if case .object(let items) = signals.json { fields = items }
            Stage.event("shared_mic_signals", log: log, fields + [("marked", .bool(SharedMic.meetingMarked(paths)))])
        } catch {
            say("warning: the shared-microphone signals could not be read: \(error)")
            Stage.event("shared_mic_signals_failed", log: log, [("error", .string("\(error)"))])
        }
        let shared = SharedMic.sharedLabels(paths)  // several people: no one to recognize
        let bank = VoiceBank(directory: setup.stores.voices)
        var voices = PyDict<[Double]>()
        guard case .object(let stored) = PythonJSON.read(paths.speakerEmbeddings) ?? .null else {
            throw WorkerError("\(paths.speakerEmbeddings.lastPathComponent) is not an object")
        }
        for (label, value) in stored where !shared.contains(ScalarKey(label)) {
            voices[label] = (value.arrayValue ?? []).compactMap(\.doubleValue)
        }
        let outputDir = folder.deletingLastPathComponent()
        let recognized = try Voices.recognize(
            voices, talk: Speakers.talkSeconds(turns), bank: bank,
            invited: CalendarEvents.invitedNames(paths, try bank.names().keys, userName: setup.userName),
            rejected: try People.rejectedVoices(outputDir))  // "Not Tom", here and for voices like it (#48)
        try StoreLock.meeting(paths) {
            try PythonJSON.write(.object(recognized.map { label, hit in
                (label, .object([("name", .string(hit.0)), ("similarity", .double(Py.round(hit.1, 3)))]))
            }), to: paths.speakersAuto, indent: 2, ensureAscii: false)
        }
        for (label, hit) in recognized { say("Recognized \(label) as \(hit.0) (voice similarity \(String(format: "%.2f", hit.1)))") }
        for (label, name) in try Speakers.adoptLiveNames(paths) { say("Named \(label) \(name) (named while recording)") }
        var names = PyDict<String>()
        for (label, hit) in try Speakers.loadRecognizedNames(paths) { names[label] = hit.0 }  // without rejected names
        for (label, name) in try Speakers.loadSpeakerNames(paths) { names[label] = name }
        names = Speakers.followMerges(names, Speakers.loadMerges(paths))
        names = PyDict(names.filter { !shared.contains(ScalarKey($0.key)) }.map { ($0.key, $0.value) })
        for (label, name) in SharedMic.display(paths) { names[label] = name }
        var utterances = Speakers.applySpeakerNames(Merger.merge(mic: micSegs, system: sysSegs, turns: turns), names)
        Stage.event("merge_done", log: log, [("utterances", .int(utterances.count)), ("dropped_silent", .int(droppedSilent)),
                                             ("dropped_bleed_duplicates", .int(droppedBleed))])
        try PythonJSON.write(.array(utterances.map(\.json)), to: paths.transcriptJson, indent: 2, ensureAscii: true)

        // Names that follow from the calendar and other meetings, here and in earlier meetings this one tells about.
        if try Inference.refresh(outputDir: outputDir, userName: setup.userName, bank: bank, stores: setup.stores) > 0 {
            for (label, i) in Inference.load(paths) {
                say("Inferred \(label) = \(text(i["name"])): \(text(i["why"]))")
            }
            utterances = try readList(paths.transcriptJson).map { try Utterance(json: $0) }
        }

        guard let meta = PythonJSON.read(paths.meta), case .object = meta, let iso = meta["start_time"]?.stringValue, let start = Py.fromIso(iso),
              let duration = meta["duration_seconds"]?.doubleValue else {
            throw WorkerError("\(paths.meta.lastPathComponent) has no start_time or duration_seconds")
        }
        let markdown = try Render.markdown(SharedMic.shown(paths, try Speakers.withoutIgnored(paths, utterances)), start: start,
                                       duration: duration, gaps: meta["gaps"]?.arrayValue,
                                       timeZone: Lifecycle.offsetZone(iso) ?? .current, glossary: Glossary.current(stores: setup.stores))
        try Data(markdown.utf8).write(to: paths.transcriptMd)
        say("Wrote \(paths.transcriptMd.path)")
        if notes && setup.config.notesEnabled { writeNotes(paths, utterances, setup, log: log) }
        return 0
    }

    // MARK: - the system track

    /// `transcription.system_track`: system_segments.json (and who made it, transcription.json) unless it is there.
    /// With a service chosen (`cloud`), the track goes there unless this Mac or the service made it already; without
    /// one, one the live worker made, or this Mac after a service failed, is marked as this Mac's: a service chosen
    /// later never sends it.
    static func systemTrack(_ paths: RecordingPaths, _ setup: Setup, log: SessionLog, systemEmpty: Bool,
                            cloud: String? = nil) async throws {
        if let cloud {
            guard TranscriptionMarker.wantsCloud(paths) else {
                setup.say("Skipping system transcription (already done)")
                return
            }
            _ = attachCalendar(paths, setup, log: log)  // the invitees' names are keyterms
            try await cloudTranscribe(paths, setup, log: log, pid: cloud, systemEmpty: systemEmpty)
            return
        }
        if FileManager.default.fileExists(atPath: paths.systemSegments.path) {
            let system = TranscriptionMarker.read(paths)["system"]
            if system?["engine"]?.stringValue == "live" || system?["fallback_from"]?.truthy == true {
                try TranscriptionMarker.write(paths, track: "system", info: [("engine", .string("local"))])
            }
            setup.say("Skipping system transcription (already done)")
            return
        }
        let segments = try await localSystem(paths, setup, log: log, systemEmpty: systemEmpty)
        try writeSystem(paths, segments, language: nil, marker: [("engine", .string("local"))])
    }

    /// The system track through this Mac's engine (nothing for a track without audio).
    static func localSystem(_ paths: RecordingPaths, _ setup: Setup, log: SessionLog, systemEmpty: Bool) async throws -> [Segment] {
        guard !systemEmpty else { return [] }
        setup.say("Transcribing system track…")
        return try await Stage.with("transcribe", log: log, fields: [("track", .string("system"))]) { info in
            let found = try await setup.engine.transcribe(wav: paths.systemWav)
            info["segments"] = .int(found.count)
            info["language"] = .null  // the engine's Parakeet detects none
            return found
        }
    }

    /// The language (language.txt), then who transcribed it, then the segments: a kill never leaves segments nobody
    /// vouches for.
    static func writeSystem(_ paths: RecordingPaths, _ segments: [Segment], language: String?,
                            marker: [(String, JSONValue)]) throws {
        if let language, !language.isEmpty { try Data((language + "\n").utf8).write(to: paths.language) }
        try TranscriptionMarker.write(paths, track: "system", info: marker)
        try saveSegments(paths.systemSegments, segments)
    }

    /// The system track through the chosen service (PalaverCloud's CloudTranscription), in this process. When the
    /// service fails, this Mac's engine transcribes it (it is not loaded before: the engine's gate and its release
    /// keep one model at a time), that is said in session.log, transcription.json (`fallback_from`, `error`) and a
    /// notification; never another service. Text the live worker kept is this Mac's already and stays. The engine's
    /// ModelsMissing passes on: the meeting waits for the speech models.
    static func cloudTranscribe(_ paths: RecordingPaths, _ setup: Setup, log: SessionLog, pid: String,
                                systemEmpty: Bool) async throws {
        let label = ModelChoice.provider(pid)?.label ?? pid
        let previous = TranscriptionMarker.read(paths)["system"]
        let settings = setup.cloud.settings(setup.config, stores: setup.stores)
        setup.say("Transcribing system track with \(label)…")
        let out: CloudTranscription.Outcome
        do {
            out = try await Stage.with("transcribe", log: log, fields: [("track", .string("system")), ("engine", .string(pid))]) { info in
                let found: CloudTranscription.Outcome
                if let heard = setup.cloud.heard {
                    found = try heard(paths, pid)
                } else {
                    let terms = CloudTranscription.keyterms(paths, userName: setup.userName, stores: setup.stores)
                    found = try await CloudTranscription.transcribe(
                        paths, pid: pid, settings: settings, language: setup.config.language, dictionary: setup.dictionary,
                        keyterms: terms, http: setup.cloud.http, stores: setup.stores) { provider, count in
                        Stage.event("cloud_delete_pending", log: log, [("provider", .string(provider)), ("count", .int(count))])
                    }
                }
                info["segments"] = .int(found.segments.count)
                info["language"] = .str(found.language)
                info["sent_seconds"] = .double(Py.round(found.sentSeconds, 1))
                return found
            }
        } catch {
            if error is CancellationError { throw error }
            let message = CloudTranscription.message(error)
            if !(error is CloudError || error is JobFailed || error is EngineUnavailable) {
                // An unexpected error's description may carry a request's URL or body: the key and anything key-like out.
                log.message("cloud transcription failed: \(HTTPClient.redactedDescription(error, key: settings.apiKey(pid)))", level: "ERROR",
                            logger: "palaver.transcription")
            }
            Stage.event("cloud_transcription_failed", log: log, [("provider", .string(pid)), ("error", .string(message))])
            setup.say("\(label) failed (\(message)); transcribing on this Mac instead")
            let fallback: [(String, JSONValue)] = [("fallback_from", .string(pid)), ("error", .string(message))]
            if previous?["engine"]?.stringValue == "live" && FileManager.default.fileExists(atPath: paths.systemSegments.path) {
                try TranscriptionMarker.write(paths, track: "system", info: [("engine", .string("live"))] + fallback)
            } else {
                let segments = try await localSystem(paths, setup, log: log, systemEmpty: systemEmpty)
                try writeSystem(paths, segments, language: nil, marker: [("engine", .string("local"))] + fallback)
            }
            Notify.send(title: "Transcribed on this Mac", message: "\(paths.folder.lastPathComponent): \(label) failed: \(message)",
                        meeting: paths.folder.lastPathComponent)
            return
        }
        try writeSystem(paths, out.segments, language: out.language, marker: [
            ("engine", .string(pid)), ("model", .string(out.model)), ("sent_seconds", .double(Py.round(out.sentSeconds, 1))),
            ("usd", CloudTranscription.cost(pid, seconds: out.sentSeconds).map(JSONValue.double) ?? .null),
        ])
    }

    /// The deletions a service still owes (cloud-pending.json of the meetings and the Test button's), tried again with
    /// the services' keys. Never fails the run.
    static func sweepPending(_ folder: URL, _ setup: Setup) async {
        let settings = setup.cloud.settings(setup.config, stores: setup.stores)
        _ = await TranscriptionPending.sweep(root: folder.deletingLastPathComponent(), global: setup.stores.cloudPending,
                                             key: { settings.apiKey($0) }, http: setup.cloud.http)
    }

    /// `_save_segments`: whole or not at all (`<name>.tmp`, renamed): a run skips a track whose segments file exists.
    static func saveSegments(_ url: URL, _ segments: [Segment]) throws {
        try PythonJSON.write(.array(segments.map(\.json)), to: url, indent: 2, ensureAscii: true, via: url.lastPathComponent + ".tmp")
    }

    static func readList(_ url: URL) throws -> [JSONValue] {
        let parsed = try PythonJSON.parse(Data(contentsOf: url))
        guard let items = parsed.arrayValue else { throw WorkerError("\(url.lastPathComponent) is not a list") }
        return items
    }

    private static func text(_ value: JSONValue?) -> String {
        if case .string(let s)? = value { return s }
        return value.map { PythonJSON.dumps($0) } ?? "None"
    }

    // MARK: - the calendar

    /// `_attach_calendar`: the recording's event, stored or looked up once in the calendar. Never fails processing: no
    /// calendar access means no event.
    static func attachCalendar(_ paths: RecordingPaths, _ setup: Setup, log: SessionLog) -> CalendarEvent? {
        if FileManager.default.fileExists(atPath: paths.calendar.path) || !setup.calendar.enabled {
            return CalendarEvents.load(paths)
        }
        guard let provider = setup.calendar.provider else { return nil }
        do {
            let (start, end) = try CalendarEvents.recordingSpan(paths)
            return try Stage.with("calendar", log: log) { _ in
                try CalendarEvents.attach(paths, provider: provider, start: start, end: end, stores: setup.stores)
            }
        } catch {
            setup.say("warning: calendar lookup failed: \(error)")
            Stage.event("calendar_failed", log: log, [("error", .string("\(error)"))])
            return nil
        }
    }

    // MARK: - notes

    /// The notes of the transcript, unless they are up to date: the notes helper (`palaver-lm notes <folder>`: the
    /// language model, then the projects it sorts the meeting into), its exit code only logged — the transcript is
    /// there either way, and notes can be retried.
    static func writeNotes(_ paths: RecordingPaths, _ utterances: [Utterance], _ setup: Setup, log: SessionLog) {
        let shown = (try? Speakers.withoutIgnored(paths, utterances)) ?? utterances
        if !Notes.isStale(paths, shown) {
            setup.say("Notes are up to date")
            return
        }
        runNotesHelper(paths.folder, setup, log: log)
    }

    /// `palaver-lm <options> notes <folder>`; whether it wrote them.
    @discardableResult
    static func runNotesHelper(_ folder: URL, _ setup: Setup, log: SessionLog) -> Bool {
        guard let lm = setup.lm, FileManager.default.isExecutableFile(atPath: lm) else {
            let looked = setup.lm.map { " (looked for \($0))" } ?? ""
            log.message("palaver-lm is missing\(looked): no notes", level: "WARNING", logger: "palaver.worker")
            FileHandle.standardError.write(Data("warning: notes failed: palaver-lm is missing\(looked)\n".utf8))
            return false
        }
        do {
            let helper = HelperProgram(program: lm, options: setup.helper.options, env: setup.helper.env)
            let done = try helper.run(helper.options + ["notes", folder.path])
            if done.code == 0 { return true }
            log.message("the notes helper exited with \(done.code)", level: "WARNING", logger: "palaver.worker")
            FileHandle.standardError.write(Data("warning: notes failed (exit \(done.code))\n".utf8))
        } catch {
            log.message("the notes helper did not start: \(error)", level: "WARNING", logger: "palaver.worker")
            FileHandle.standardError.write(Data("warning: notes failed: \(error)\n".utf8))
        }
        return false
    }
}
