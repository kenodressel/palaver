// The setup assistant's test recording (onboarding.TestRecording, inventory §2 "Test recording"):
// only started by the user's click, stopped by it, after `maxSeconds` or by a meeting starting;
// never while a meeting is recorded. The audio goes into a temp folder and is never kept; what
// is learned from it (levels, the mic's words) comes from `palaver onboarding analyze`.
import Foundation
import PalaverCapture
import PalaverCore

public final class TestRecorder: @unchecked Sendable {
    public static let maxSeconds = 20.0
    public static let busyText = "a meeting is being recorded; try the test after it"
    public static let abortedText = "A call started, so the test stopped; nothing was kept. Try again after the call."

    /// Stops the capture, returns (mic WAV, system WAV): nil for a track that was not written.
    public typealias Stop = () throws -> (mic: URL?, system: URL?)
    /// Looks at the two tracks (`mode`: whether and how it may transcribe), returns the checks the
    /// page shows: [{name, status, detail, fix}].
    public typealias Analyze = (URL?, URL?, [String: Any]) throws -> [[String: Any]]

    private let maxSeconds: Double
    private let capture: (URL) throws -> Stop
    private let analyze: Analyze
    private let clock: () -> Double
    /// A meeting starting holds this; a test starts only when it can take it at once.
    private let gate = NSLock()
    private let lock = NSLock()
    private var state = "idle"
    private var started = 0.0
    private var stopCapture: Stop?
    private var folder: URL?
    private var mode: [String: Any] = [:]
    private var checks: [[String: Any]]?
    private var error: String?
    private var timer: DispatchWorkItem?

    static let prefix = "palaver-test-recording-"
    private let tempRoot: URL
    private let ownerPid: Int32
    static let marker = "owner.pid"

    /// kill(pid, 0): alive, or alive but not ours (EPERM).
    public static let processAlive: @Sendable (Int32) -> Bool = { pid in
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// Creating the recorder (the app starting) sweeps what an earlier run left behind: its own
    /// `palaver-test-recording-*` folders in `tempRoot`, owned by this user, nothing else. A folder
    /// carries `owner.pid`, the process that records into it: while that lives (another app or a
    /// debug daemon, a test in its "checking" step) the folder is left alone.
    public init(maxSeconds: Double = TestRecorder.maxSeconds, tempRoot: URL = FileManager.default.temporaryDirectory,
                ownerPid: Int32 = getpid(), processAlive: @Sendable (Int32) -> Bool = TestRecorder.processAlive,
                capture: @escaping (URL) throws -> Stop, analyze: @escaping Analyze,
                clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.tempRoot = tempRoot
        self.ownerPid = ownerPid
        Self.sweep(tempRoot, alive: processAlive)
        self.maxSeconds = maxSeconds
        self.capture = capture
        self.analyze = analyze
        self.clock = clock
    }

    /// Removes stale test folders (a crash or kill left them: the audio must not stay).
    static func sweep(_ root: URL, alive: @Sendable (Int32) -> Bool) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            let url = root.appendingPathComponent(name, isDirectory: true)
            let owner = (try? String(contentsOf: url.appendingPathComponent(marker), encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard !(owner.map(alive) ?? false),
                  let attrs = try? fm.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType == .typeDirectory,  // not a symlink, not a file
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { continue }
            try? fm.removeItem(at: url)
        }
    }

    // MARK: the gate

    /// Held around a meeting recording's start (`deps.beforeRecord`): a running test is stopped
    /// (its audio discarded) first, and none starts until the meeting records.
    public func meetingStarting<T>(_ body: () throws -> T) rethrows -> T {
        gate.lock(); defer { gate.unlock() }
        abort()  // the app has one recorder (Python's module-level registry held at most that one)
        return try body()
    }

    // MARK: start, stop

    @discardableResult
    public func start(busy: () -> Bool, mode: [String: Any]) throws -> [String: Any] {
        guard gate.try() else { throw CallRefused(Self.busyText) }  // a meeting is starting right now
        defer { gate.unlock() }
        lock.lock(); defer { lock.unlock() }
        if busy() { throw CallRefused(Self.busyText) }
        if state == "recording" || state == "checking" { return statusLocked() }
        let dir = tempRoot.appendingPathComponent("\(Self.prefix)\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "\(ownerPid)".write(to: dir.appendingPathComponent(Self.marker), atomically: true, encoding: .utf8)  // before anything is recorded
        do {
            stopCapture = try capture(dir)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            state = "failed"; self.error = "could not start recording: \(Self.text(error))"; checks = nil
            return statusLocked()
        }
        folder = dir
        state = "recording"; started = clock(); checks = nil; error = nil
        self.mode = mode
        let item = DispatchWorkItem { [weak self] in _ = self?.stop() }
        timer = item
        DispatchQueue.global().asyncAfter(deadline: .now() + maxSeconds, execute: item)
        return statusLocked()
    }

    /// Leaves "recording" for `next`: the stop function and folder, or nil when not recording.
    private func take(_ next: String) -> (Stop, URL)? {
        lock.lock(); defer { lock.unlock() }
        guard state == "recording", let stop = stopCapture, let folder else { return nil }
        timer?.cancel()
        state = next
        return (stop, folder)
    }

    @discardableResult
    public func stop() -> [String: Any] {
        if let (stop, folder) = take("checking") {
            let t = Thread { [self] in finish(stop, folder) }
            t.name = "palaver.test-recording"
            t.start()
        }
        return status()
    }

    /// A meeting starts, or the app quits (the app calls this): stop at once, check nothing,
    /// keep nothing.
    public func abort() {
        guard let (stop, folder) = take("aborted") else { return }
        _ = try? stop()
        try? FileManager.default.removeItem(at: folder)
        lock.lock(); error = Self.abortedText; lock.unlock()
    }

    private func finish(_ stop: Stop, _ folder: URL) {
        var result: [[String: Any]]?, failure: String?
        do {
            let (mic, system) = try stop()
            lock.lock(); let mode = self.mode; lock.unlock()
            result = try analyze(mic, system, mode)
        } catch {
            failure = "the test failed: \(Self.text(error))"
        }
        try? FileManager.default.removeItem(at: folder)  // the test's audio is never kept
        lock.lock(); defer { lock.unlock() }
        state = failure != nil ? "failed" : "done"
        checks = result; error = failure
    }

    // MARK: status

    /// {"state", "max_seconds", "seconds" (recording), "checks" (done), "error"}: as onboarding's.
    private func statusLocked() -> [String: Any] {
        var out: [String: Any] = ["state": state, "max_seconds": maxSeconds]
        if state == "recording" { out["seconds"] = ((clock() - started) * 10).rounded() / 10 }
        if let checks { out["checks"] = checks }
        if let error, !error.isEmpty { out["error"] = error }
        return out
    }

    public func status() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return statusLocked() }

    /// app.sock's `test` call: start | stop | (anything else) status.
    public func testRecording(action: String?, mode: [String: Any], busy: () -> Bool) throws -> Any? {
        switch action {
        case "start": return try start(busy: busy, mode: mode)
        case "stop": return stop()
        default: return status()
        }
    }

    static func text(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? "\(error)" }
}

// MARK: - the real thing

extension TestRecorder {
    /// A capture of both tracks into the folder the way a meeting is recorded, without a
    /// session.log (its lines never mix with a meeting's), and `palaver onboarding analyze` for the
    /// rest. `sources`: the real ones, or fakes in tests.
    public static func live(sources: @escaping () -> CaptureSources, python: String, cliOptions: [String],
                            env: [String: String] = [:], maxSeconds: Double = TestRecorder.maxSeconds) -> TestRecorder {
        TestRecorder(maxSeconds: maxSeconds, capture: { folder in
            let mic = folder.appendingPathComponent("mic_raw.wav"), system = folder.appendingPathComponent("system.wav")
            let recorder = CaptureRecorder(micURL: mic, systemURL: system, sources: sources())
            try recorder.start()
            return {
                try recorder.stop()
                let fm = FileManager.default
                return (fm.fileExists(atPath: mic.path) ? mic : nil, fm.fileExists(atPath: system.path) ? system : nil)
            }
        }, analyze: { mic, system, mode in
            try analyzeWithPython(mic: mic, system: system, mode: mode, python: python, cliOptions: cliOptions, env: env)
        })
    }

    /// `palaver onboarding analyze <mic> [--system <wav>] [--mode <json>] --checks` → its checks.
    public static func analyzeWithPython(mic: URL?, system: URL?, mode: [String: Any], python: String, cliOptions: [String],
                                         env: [String: String] = [:], timeout: TimeInterval = 180) throws -> [[String: Any]] {
        // "-": no microphone track was written (the verdict says so).
        var args = ["-m", "palaver"] + cliOptions + ["onboarding", "analyze", mic?.path ?? "-", "--checks"]
        if let system { args += ["--system", system.path] }
        if !mode.isEmpty, let data = try? JSONSerialization.data(withJSONObject: mode), let text = String(data: data, encoding: .utf8) {
            args += ["--mode", text]
        }
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = args
        var merged = ProcessInfo.processInfo.environment
        for (k, v) in env { merged[k] = v }
        p.environment = merged
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw WorkerError(description: "cannot start \(python): \(error.localizedDescription)") }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { p.terminate() }
        timer.resume()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let checks = obj["checks"] as? [[String: Any]] else {
            throw WorkerError(description: "palaver onboarding analyze: no answer (exit \(p.terminationStatus))")
        }
        return checks
    }
}
