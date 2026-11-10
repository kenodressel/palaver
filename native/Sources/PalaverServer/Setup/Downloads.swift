// The model downloads the user agreed to, one after the other, in the background (palaver/onboarding.py `Downloads`,
// `SPEECH_SHARE`, `SPEECH_PHASES`, `_fetch`), and the speech engine as a child process (palaver/engine.py `Engine`,
// `engine_path`): the speech models come from `palaver-engine prepare`, the others from Hugging Face in this process
// (PalaverCloud's HubDownloader, at the revision and with the files HubModels pins).
import Darwin
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

/// Model downloads, one after the other, in a thread of their own. `fetch(model, downloads)` downloads one (throws on
/// failure; the speech models report their progress through `setFraction`); `done(model)` says whether every file of it
/// is there (else it failed: "incomplete"); `progress(repo)` how many bytes are there; `repoOf(model)` its repo. A failed
/// model is tried again by starting it again. While it downloads, `marker` holds this process's pid (for the updater,
/// #60), and is removed when the queue is empty.
public final class SetupDownloads: @unchecked Sendable {
    /// The speech models' download as one progress: each model's share of it.
    public static let SPEECH_SHARE: [(name: String, weight: Double)] = [("asr", 0.95), ("diarizer", 0.05)]
    /// Where each phase of a model's own progress falls in that model's share.
    public static let SPEECH_PHASES = PyDict<(Double, Double)>([
        ("downloading", (0.0, 0.8)), ("compiling", (0.8, 0.95)), ("loading", (0.95, 1.0)),
    ])
    public static let INCOMPLETE = "incomplete: some files are missing"

    public typealias Fetch = (ModelInfo, SetupDownloads) throws -> Void

    struct Job {
        var state: String
        var error: String?
        var fraction: Double
    }

    let fetch: Fetch
    let progress: (String) -> Int
    let done: (ModelInfo) -> Bool
    let repoOf: (ModelInfo) -> String
    let marker: URL?
    private let lock = NSLock()
    private var jobs = PyDict<Job>()
    private var running = false

    public init(fetch: @escaping Fetch, progress: @escaping (String) -> Int, done: @escaping (ModelInfo) -> Bool,
                repoOf: @escaping (ModelInfo) -> String = { $0.repo }, marker: URL? = nil) {
        self.fetch = fetch
        self.progress = progress
        self.done = done
        self.repoOf = repoOf
        self.marker = marker
    }

    /// The real downloads: the speech models through `engine` (`prepare`, then `speech.clear()`), the others from
    /// Hugging Face through `hub` (`token()` is asked when one starts: the Keychain may ask the user); done when
    /// `ModelCatalog.modelHere` says so (the engine for the speech models).
    public convenience init(stores: StorePaths, hub: HubDownloader, token: @escaping () -> String?, speech: SpeechCheck,
                            engine: @escaping () -> EngineProcess) {
        self.init(fetch: { m, downloads in
            #if DEBUG
            if TestIsolation.isTestProcess { throw DownloadFailed(description: "no real model download in a test") }
            #endif
            if Py.same(m.id, "speech") {
                try SetupDownloads.fetchSpeech(engine: engine(), setFraction: { downloads.setFraction(m.id, $0) },
                                               finally: speech.clear)
            } else {
                try SetupDownloads.fetchFromHub(repo: ModelCatalog.repoFor(m), hub: hub, token: token)
            }
        }, progress: { ModelCatalog.downloadProgress($0, stores: stores) },
        done: { m in ModelCatalog.modelHere(m, repo: ModelCatalog.repoFor(m), speechHere: speech.here, stores: stores) },
        repoOf: ModelCatalog.repoFor, marker: stores.downloadingModels)
    }

    static func model(_ id: String) -> ModelInfo? { ModelCatalog.models.first { Py.same($0.id, id) } }

    /// Queues `ids` (one already queued, downloading or done stays as it is) and starts the thread if none runs; the
    /// status. Throws `Refused("no model 'x'")` for an id that is no model (the ones before it are queued).
    @discardableResult
    public func start(_ ids: [String]) throws -> JSONValue {
        try lock.withLock {
            for mid in ids {
                guard Self.model(mid) != nil else { throw Refused("no model \(Py.repr(.string(mid)))") }
                if !["queued", "downloading", "done"].contains(jobs[mid]?.state ?? "") {
                    jobs[mid] = Job(state: "queued", error: nil, fraction: 0.0)
                }
            }
            if !running {
                running = true
                let t = Thread { [self] in run() }
                t.name = "model-downloads"
                t.start()
            }
        }
        return status()
    }

    private func run() {
        if let marker {
            try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("\(getpid())\n".utf8).write(to: marker)
        }
        while true {
            let next: (String, ModelInfo)? = lock.withLock {
                guard let i = jobs.values.firstIndex(where: { $0.state == "queued" }) else {
                    // Under the lock: a start after this point starts a new thread, whose marker this can't remove.
                    running = false
                    if let marker { try? FileManager.default.removeItem(at: marker) }
                    return nil
                }
                let mid = jobs.keys[i]
                jobs[mid]!.state = "downloading"
                return (mid, Self.model(mid)!)
            }
            guard let (mid, m) = next else { return }
            var state = "done", error: String?
            do {
                try fetch(m, self)
                if !done(m) { (state, error) = ("failed", Self.INCOMPLETE) }
            } catch let e {
                let text = "\(e)"
                (state, error) = ("failed", text.isEmpty ? String(describing: type(of: e)) : text)
            }
            lock.withLock {
                jobs[mid]!.state = state
                jobs[mid]!.error = error
            }
        }
    }

    /// The speech model's progress (0…1); it never goes back.
    public func setFraction(_ mid: String, _ fraction: Double) {
        lock.withLock {
            guard var job = jobs[mid] else { return }
            job.fraction = max(job.fraction, min(1.0, fraction))
            jobs[mid] = job
        }
    }

    /// A job as a test arranges it (Python's tests set `_jobs` directly).
    func setJob(_ mid: String, state: String) {
        lock.withLock { jobs[mid] = Job(state: state, error: nil, fraction: 0.0) }
    }

    /// `{"running", "models": [{id, label, disk_gb, state, done_gb, error}]}`, in the order they were first started.
    public func status() -> JSONValue {
        let now = lock.withLock { jobs }
        var out: [JSONValue] = []
        for (mid, job) in now {
            let m = Self.model(mid)!
            let got: Double
            if job.state == "done" {
                got = m.diskGB
            } else if Py.same(m.id, "speech") {  // not a repo in the cache: what prepare reported
                got = m.diskGB * job.fraction
            } else {
                got = min(m.diskGB, Double(progress(repoOf(m))) / 1_073_741_824.0)  // disk_gb is GiB
            }
            out.append(.object([("id", .string(mid)), ("label", .string(m.label)), ("disk_gb", .double(m.diskGB)),
                                ("state", .string(job.state)), ("done_gb", .double(Py.round(got, 2))),
                                ("error", .str(job.error))]))
        }
        let running = now.values.contains { $0.state == "queued" || $0.state == "downloading" }
        return .object([("running", .bool(running)), ("models", .array(out))])
    }

    // MARK: - the real fetches

    /// The engine's `prepare`, one model after the other so each one's progress is known: the speech model is nearly all
    /// of the bytes, the diarizer's few MB the rest. Within a model, downloading is most of the time, then compiling,
    /// then loading. What the page shows can't go back (`setFraction` keeps the highest). `finally` runs once it ended
    /// either way (the speech check's cache).
    static func fetchSpeech(engine: EngineProcess, setFraction: @escaping (Double) -> Void, finally: () -> Void) throws {
        defer {
            engine.close()
            finally()
        }
        var done = 0.0
        for (name, weight) in SPEECH_SHARE {
            let offset = done
            _ = try engine.call("prepare", [("models", .array([.string(name)]))]) { fraction, phase in
                let (lo, hi) = SPEECH_PHASES[phase] ?? (0.0, 1.0)
                let inside = lo + (hi - lo) * min(1.0, max(0.0, fraction))
                setFraction(offset + weight * inside)
            }
            done += weight
            setFraction(done)
        }
    }

    public struct DownloadFailed: Error, CustomStringConvertible {
        public let description: String
    }

    /// A model from Hugging Face (onboarding `_fetch`): its pinned revision and files (HubModels) into the cache, in
    /// this thread; a failure is one line (HubError), which the page shows.
    public static func fetchFromHub(repo: String, hub: HubDownloader, token: () -> String?) throws {
        try hub.fetchPinned(repo, token: token())
    }
}

// MARK: - the speech engine

/// Where palaver-engine is (engine.py `engine_path`): `$PALAVER_ENGINE` as given; else beside this program in a release's
/// `Contents/MacOS`; else the checkout's `native/.build/release/palaver-engine`.
public enum EnginePath {
    public static let MISSING_REASON = "the speech engine is missing"

    /// This program's place.
    public static var location: AppLocation {
        AppLocation(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? ""))
    }

    public static func find(env: [String: String], location: AppLocation = EnginePath.location) throws -> URL {
        if let given = env["PALAVER_ENGINE"], !given.isEmpty { return URL(fileURLWithPath: given) }  // reported if it can't start
        if let app = location.bundle {
            let bundled = app.appendingPathComponent("Contents/MacOS/palaver-engine")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        if let checkout = location.checkout {
            let built = checkout.appendingPathComponent("native/.build/release/palaver-engine")
            if FileManager.default.fileExists(atPath: built.path) { return built }
        }
        if location.bundle != nil { throw EngineProcess.Failure("\(MISSING_REASON): reinstall Palaver") }
        throw EngineProcess.Failure("\(MISSING_REASON): run `make engine`")
    }
}

/// palaver-engine as a child process speaking JSON lines (engine.py `Engine`): one request per line on its stdin, zero
/// or more progress lines and exactly one reply per request on its stdout, log lines on its stderr (the last
/// `STDERR_KEEP` are kept for error messages). Started at the first call, in a session of its own; `close()` ends it
/// (its stdin closed, then killed after `CLOSE_WAIT`) and reaps it. One call at a time.
public final class EngineProcess: @unchecked Sendable {
    public static let STDERR_KEEP = 20
    public static let CLOSE_WAIT = 5.0
    /// Seconds without any stdout line before the child is declared hung.
    public static let ENGINE_IDLE_TIMEOUT = 600.0
    /// Seconds a dead child's stderr is given to be read to its end.
    public static let DRAIN_WAIT = 1.0

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// What one child sends, line by line, until it closes its end (nil).
    private final class Lines: @unchecked Sendable {
        private let cond = NSCondition()
        private var queue: [Data?] = []

        func put(_ line: Data?) { cond.withLock { queue.append(line); cond.signal() } }

        /// The next line (nil: the end), or `.timedOut` after `timeout` seconds without one.
        func get(timeout: Double) -> Data?? {
            let deadline = Date().addingTimeInterval(timeout)
            cond.lock(); defer { cond.unlock() }
            while queue.isEmpty {
                if !cond.wait(until: deadline) { break }
            }
            return queue.isEmpty ? .none : .some(queue.removeFirst())
        }
    }

    private final class Tail: @unchecked Sendable {
        private let cond = NSCondition()
        private var lines: [String] = []
        private var ended = false

        func add(_ line: String) {
            cond.withLock {
                lines.append(line)
                if lines.count > EngineProcess.STDERR_KEEP { lines.removeFirst() }
            }
        }

        func end() { cond.withLock { ended = true; cond.broadcast() } }

        func text(waiting: Double) -> String {
            let deadline = Date().addingTimeInterval(waiting)
            cond.lock(); defer { cond.unlock() }
            while !ended { if !cond.wait(until: deadline) { break } }
            return lines.joined(separator: "\n")
        }
    }

    let path: () throws -> URL
    let models: URL
    let version: String
    let env: [String: String]
    let idle: Double
    private let lock = NSLock()
    private var process: PalaverCore.Process?
    private var stdinFD: Int32 = -1
    private var lines = Lines()
    private var tail = Tail()
    private var nextID = 0

    /// `path`: the engine (asked at the start, so a missing one fails the first call); `models`: its model folder.
    public init(path: @escaping () throws -> URL, models: URL, version: String, env: [String: String],
                idle: Double = EngineProcess.ENGINE_IDLE_TIMEOUT) {
        self.path = path
        self.models = models
        self.version = version
        self.env = env
        self.idle = idle
    }

    deinit { close() }

    private func start() throws -> PalaverCore.Process {
        let exe = try path()
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        func fail(_ why: String) -> Failure { Failure("the speech engine could not start (\(exe.path)): \(why)") }
        guard pipe(&input) == 0 else { throw fail(String(cString: strerror(errno))) }
        guard pipe(&output) == 0 else {
            input.forEach { Darwin.close($0) }
            throw fail(String(cString: strerror(errno)))
        }
        guard pipe(&errors) == 0 else {
            (input + output).forEach { Darwin.close($0) }
            throw fail(String(cString: strerror(errno)))
        }
        for fd in input + output + errors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
        let child: PalaverCore.Process
        do {
            child = try spawnChild([exe.path, "--models", models.path, "--version", version], env: env,
                                   stdin: input[0], output: output[1], errors: errors[1])
        } catch {
            (input + output + errors).forEach { Darwin.close($0) }
            throw fail("\(error)")
        }
        Darwin.close(input[0])
        Darwin.close(output[1])
        Darwin.close(errors[1])
        stdinFD = input[1]
        let lines = Lines(), tail = Tail()
        self.lines = lines
        self.tail = tail
        let out = output[0], err = errors[0]
        Thread {
            Self.eachLine(out) { lines.put($0) }
            lines.put(nil)
        }.start()
        Thread {
            Self.eachLine(err) { tail.add(String(decoding: $0, as: UTF8.self)) }
            tail.end()
        }.start()
        process = child
        return child
    }

    /// Reads `fd` to its end, line by line (the last one without its newline too), then closes it.
    private static func eachLine(_ fd: Int32, _ line: (Data) -> Void) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            pending.append(contentsOf: buffer[0..<n])
            while let nl = pending.firstIndex(of: 0x0A) {
                line(Data(pending[pending.startIndex..<nl]))
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
        if !pending.isEmpty { line(pending) }
        Darwin.close(fd)
    }

    /// One request; the reply (`ok` true). `progress(fraction, phase)` gets its progress lines. Throws `Failure` with the
    /// engine's error, or when it died, hung or never started.
    @discardableResult
    public func call(_ cmd: String, _ args: [(String, JSONValue)] = [],
                     progress: ((Double, String) -> Void)? = nil) throws -> JSONValue {
        try lock.withLock {
            var child = process
            if let p = child, p.poll() != nil { throw died(p) }
            if child == nil { child = try start() }
            let p = child!
            nextID += 1
            let rid = nextID
            let request = Data((PythonJSON.dumps(.object(args + [("id", .int(rid)), ("cmd", .string(cmd))])) + "\n").utf8)
            let written = request.withUnsafeBytes { raw -> Bool in
                var done = 0
                while done < raw.count {
                    let n = Darwin.write(stdinFD, raw.baseAddress! + done, raw.count - done)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { return false }
                    done += n
                }
                return true
            }
            if !written { throw died(p) }
            while true {
                guard let raw = lines.get(timeout: idle) else {
                    throw died(p, why: "the speech engine stopped answering (\(Self.seconds(idle)) s without a line)")
                }
                guard let raw else { throw died(p) }
                let text = String(decoding: raw, as: UTF8.self)  // errors="replace"
                guard let msg = try? PythonJSON.parse(Data(text.utf8)), case .object = msg,
                      Self.isID(msg["id"], rid) else { continue }
                guard let ok = msg["ok"] else {
                    if let progress, let value = msg["progress"] {
                        guard let fraction = Self.float(value) else {
                            kill(p)
                            throw Failure("could not convert to float: \(Py.repr(value))")
                        }
                        progress(fraction, Py.str(msg["phase"] ?? .string("")))
                    }
                    continue
                }
                if ok.truthy { return msg }
                throw Failure(Py.str(msg["error"] ?? .string("unknown error")))
            }
        }
    }

    /// `msg.get("id") in (rid, -1)`.
    private static func isID(_ v: JSONValue?, _ rid: Int) -> Bool {
        guard let v, let d = (v.boolValue.map { $0 ? 1.0 : 0.0 } ?? v.doubleValue) else { return false }
        return d == Double(rid) || d == -1
    }

    /// `float(value)`: a number, or a number's text.
    private static func float(_ v: JSONValue) -> Double? {
        if let b = v.boolValue { return b ? 1 : 0 }
        if let d = v.doubleValue { return d }
        if let s = v.stringValue { return Double(Py.strip(s)) }
        return nil
    }

    /// `f"{x:g}"` for the timeouts this uses (whole seconds, or a fraction).
    static func seconds(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e15 ? String(Int(x)) : String(x)
    }

    private func reap(_ p: PalaverCore.Process) -> Int32 {
        if p.waitUntilExit(timeout: Self.CLOSE_WAIT) == nil {
            p.signalGroup(SIGKILL)
            p.waitUntilExit()
        }
        return p.poll() ?? -1
    }

    private func died(_ p: PalaverCore.Process, why: String? = nil) -> Failure {
        if why != nil { p.signalGroup(SIGKILL) }
        let code = reap(p)
        let tail = self.tail.text(waiting: Self.DRAIN_WAIT)
        drop(p)
        let message = why ?? "the speech engine died (exit \(code))"
        return Failure("\(message):\n\(tail)")
    }

    private func kill(_ p: PalaverCore.Process) {
        p.signalGroup(SIGKILL)
        p.waitUntilExit()
        drop(p)
    }

    private func drop(_ p: PalaverCore.Process) {
        if process === p { process = nil }
        if stdinFD >= 0 {
            Darwin.close(stdinFD)
            stdinFD = -1
        }
    }

    /// Ends the child: its stdin closed, so it finishes its last request and exits (killed after `CLOSE_WAIT`), reaped.
    public func close() {
        lock.withLock {
            guard let p = process else { return }
            if p.poll() == nil {
                if stdinFD >= 0 {
                    Darwin.close(stdinFD)
                    stdinFD = -1
                }
                _ = reap(p)
            }
            drop(p)
        }
    }
}
