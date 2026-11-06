// Updates from inside the app (updater.py's Updater state machine and menubar.py's Updates class, #60).
// The state machine, the timing, the idle gate and update.json are here; the network, the staging and
// the text of swap.sh are the Python commands behind `UpdateBackend` (palaver/app_update.py), faked in
// tests. Checks and downloads run off the main thread (`background`), the swap on the main thread's tick:
// `tick()` says when the app must quit for it. The idle gate is asked right before the swap script
// starts; the app quits in that same tick, so no recording can start while an update installs. A call
// that began before is recorded and the update waits: recording wins.
import Foundation
import PalaverCore

/// What an update downloads (updater.Plan, as `app update check` reports it).
public struct UpdatePlan: Equatable, Sendable {
    public var version: String
    public var notes: String?
    public var downloadBytes: Int
    public var runtime: Bool
    public var models: [String]
    public init(version: String, notes: String? = nil, downloadBytes: Int = 0, runtime: Bool = false, models: [String] = []) {
        self.version = version; self.notes = notes; self.downloadBytes = downloadBytes
        self.runtime = runtime; self.models = models
    }
}

public enum UpdateCheck: Equatable, Sendable {
    case upToDate
    case plan(UpdatePlan)
}

/// The running release and update.json as the app before this start left it.
public struct UpdateInstalled: Equatable, Sendable {
    public var version: String
    public var runtime: String?
    public init(version: String, runtime: String? = nil) { self.version = version; self.runtime = runtime }
}

/// The Python side of updating. Every call blocks (it starts a process): never on the main thread,
/// except `commit`/`prepare` in the swap's tick, as the Python app did.
public protocol UpdateBackend: Sendable {
    /// nil: a checkout, nothing to update. `previous`: update.json from before this start.
    func status() throws -> (installed: UpdateInstalled?, previous: JSONValue?)
    func check() throws -> UpdateCheck
    /// Downloads and checks `version` into the staging folder; `progress` gets the bytes so far.
    func download(version: String, progress: @escaping @Sendable (Int) -> Void) throws
    /// The models in, swap.sh written (its path). `waitFor`: the pids that must have quit first.
    func prepare(waitFor: [Int32]) throws -> String
    /// The swap is certain: permissions asked again at the restart, the runtime in use remembered.
    func commit() throws
    /// Runs swap.sh on its own (`/bin/sh`, a session of its own: it outlives the app).
    func spawnSwap(script: String) throws
    /// Writes and starts uninstall.py's script, which waits for `waitFor` to quit; what it removes.
    func uninstallStart(models: Bool, recordings: Bool, waitFor: [Int32]) throws -> [String]
}

/// The idle gate (menubar.update_busy): the daemon's reasons, the window's language model jobs, the
/// setup assistant's test recording and its model downloads. nil: idle.
public enum UpdateBusy {
    public static func reason(daemon status: JSONValue, jobs: [String], testState: String?, downloading: Bool) -> String? {
        if let r = busyReason(status) { return r }
        if !jobs.isEmpty { return jobs.contains("notes") ? "writing notes" : "sorting projects" }
        if !["idle", "done", "failed"].contains(testState ?? "idle") { return "a test recording" }
        if downloading { return "downloading models" }
        return nil
    }

    /// The kinds of the model jobs running now (`<recordings>/.jobs/<kind>-<key>.json`, model_jobs.running):
    /// state running and its pid alive.
    public static func runningJobKinds(root: URL, alive: (Int32) -> Bool = pidAlive) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var kinds: [String] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let stem = String(name.dropLast(5))
            guard let dash = stem.firstIndex(of: "-") else { continue }
            let kind = String(stem[..<dash])
            guard ["notes", "projects"].contains(kind),
                  let data = try? Data(contentsOf: root.appendingPathComponent(name)),
                  let job = JSONValue.parse(data), job["state"]?.stringValue == "running" else { continue }
            let pid = job["pid"]?.doubleValue.map { Int32($0) }
            if let pid, alive(pid) { kinds.append(kind) }  // a pid gone: stale, not busy
        }
        return kinds
    }

    /// The window's server downloads models now: its marker holds a live pid (onboarding.downloads_running).
    public static func downloadsRunning(marker: URL, alive: (Int32) -> Bool = pidAlive) -> Bool {
        guard let text = try? String(contentsOf: marker, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return alive(pid)
    }

    public static func pidAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

public final class Updates: @unchecked Sendable {
    public static let checkEvery = 3600.0
    /// Opening the window looks too, when the last look is this old: a release seen within minutes.
    public static let windowCheckAfter = 10.0 * 60
    public static let retryCheck = 3600.0  // after a failed check (offline, rate-limited)

    public struct Deps: @unchecked Sendable {
        public var backend: UpdateBackend
        public var busy: @Sendable () -> String?
        public var enabled: @Sendable () -> Bool
        public var now: @Sendable () -> Double
        /// update.json, for the window's server.
        public var save: @Sendable (JSONValue) -> Void
        /// Runs work off the main thread (tests run it at once).
        public var background: @Sendable (@escaping @Sendable () -> Void) -> Void
        /// What must have quit before the app is replaced: this process.
        public var appPids: @Sendable () -> [Int32]
        public var startedOk: URL
        /// The bundle's own version (AppLocation.releaseVersion: runtime.json, what `app update status`
        /// reports too): started-ok is written from it even when Python never answers. nil: a development build.
        public var bundleVersion: String?
        public var log: @Sendable (String) -> Void
        public init(backend: UpdateBackend, busy: @escaping @Sendable () -> String? = { nil },
                    enabled: @escaping @Sendable () -> Bool = { true },
                    now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                    save: @escaping @Sendable (JSONValue) -> Void = { _ in },
                    background: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { work in
                        DispatchQueue.global(qos: .utility).async(execute: work) },
                    appPids: @escaping @Sendable () -> [Int32] = { [getpid()] },
                    startedOk: URL, bundleVersion: String? = nil, log: @escaping @Sendable (String) -> Void = { _ in }) {
            self.backend = backend; self.busy = busy; self.enabled = enabled; self.now = now; self.save = save
            self.background = background; self.appPids = appPids; self.startedOk = startedOk
            self.bundleVersion = bundleVersion; self.log = log
        }
    }

    private struct NotIdle: Error { let reason: String }

    private let deps: Deps
    private let lock = NSRecursiveLock()
    private(set) var state = "unsupported"
    private var loaded = false
    private var installed: UpdateInstalled?
    private var plan: UpdatePlan?
    private var error: String?
    private var checkError: String?
    private var checkedAt: Double?
    private var lastTry: Double?
    private var doneBytes = 0
    private var wanted = false  // the user asked for it: install at the next idle moment
    private var waitingFor: String?
    private var failedVersion: String?
    private var announced: String?
    private var workerRunning = false
    private var checkAsked = false
    private(set) var startedWritten = false
    /// The user uninstalled: the app quits at the next tick.
    public private(set) var quitNow = false

    public init(_ deps: Deps) { self.deps = deps }

    // MARK: - start

    /// Asks the Python side what runs and what the last start left in update.json (on a worker: it
    /// starts a process). Until then nothing is due. A swap that failed says so again. false: no answer.
    @discardableResult
    public func load() -> Bool {
        let status: (installed: UpdateInstalled?, previous: JSONValue?)
        do { status = try deps.backend.status() } catch {
            deps.log("could not ask for the installed release: \(error)")
            return false
        }
        lock.lock()
        installed = status.installed
        state = installed == nil ? "unsupported" : "idle"
        announced = status.previous?["announced"]?.stringValue
        if state != "unsupported", let previous = status.previous, previous["state"]?.stringValue == "failed",
           previous["from_swap"]?.truthy == true {
            state = "failed"
            error = previous["error"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "The update failed."
            failedVersion = previous["available"]?["version"]?.stringValue
        }
        loaded = true
        lock.unlock()
        changed()  // update.json says what this version is
        return true
    }

    /// `load()` until Python answers, waiting 2 s, 4 s, 8 s … up to `maxDelay` between tries (a worker
    /// thread: it blocks). The updater stays off until then; started-ok does not wait for it.
    public func loadUntilAnswered(sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }, maxDelay: Double = 300) {
        var delay = 2.0
        while !load() {
            sleep(min(delay, maxDelay))
            delay = min(delay * 2, maxDelay)
        }
    }

    /// The app is up (its first tick ran): the swap that installed it may drop the version before (#60).
    /// Call it on every tick until `startedWritten`: it writes the bundle's version at once, or, without
    /// one, the installed version once load() knows it; again on the next tick when the write failed. A
    /// checkout never writes. The swap (0.3.14's too, frozen) restores the version before without it.
    public func started() {
        lock.lock()
        let version = deps.bundleVersion ?? installed?.version
        let done = startedWritten
        lock.unlock()
        guard !done, let version else { return }
        do {
            try FileManager.default.createDirectory(at: deps.startedOk.deletingLastPathComponent(), withIntermediateDirectories: true)
            try version.write(to: deps.startedOk, atomically: true, encoding: .utf8)
        } catch {
            deps.log("could not write \(deps.startedOk.path)")  // tried again on the next tick
            return
        }
        lock.lock(); startedWritten = true; lock.unlock()
    }

    /// started-ok is written (or this is a checkout that needs none after load()): stop calling `started()`.
    public var startedDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return startedWritten || (deps.bundleVersion == nil && loaded && installed == nil)
    }

    // MARK: - checking

    /// Time for an automatic check: at start, then every hour (`every`: when the last one is older than
    /// that, as the window opening asks); an hour after a failed one.
    public func due(every: Double? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !loaded || ["unsupported", "checking", "downloading", "ready", "installing"].contains(state) || !deps.enabled() { return false }
        guard let last = lastTry else { return true }
        let wait = every ?? (checkError != nil ? Self.retryCheck : Self.checkEvery)
        return deps.now() - last >= wait
    }

    /// Asks the latest release. A failed check changes nothing but says why.
    @discardableResult
    public func runCheck() -> JSONValue {
        lock.lock()
        if ["unsupported", "downloading", "ready", "installing"].contains(state) { defer { lock.unlock() }; return status() }
        let before = state
        state = "checking"
        lastTry = deps.now()
        lock.unlock()
        let result: UpdateCheck
        do { result = try deps.backend.check() } catch {
            lock.lock()
            state = before != "checking" ? before : "idle"
            checkError = Self.why(error)
            lock.unlock()
            return changed()
        }
        lock.lock()
        checkError = nil
        checkedAt = deps.now()
        switch result {
        case .upToDate:
            state = "up_to_date"; plan = nil; error = nil
        case .plan(let p):
            if before == "failed" && p.version == failedVersion {  // the error stays until the user tries again
                state = "failed"; plan = p
            } else {
                state = "available"; plan = p; error = nil
            }
        }
        lock.unlock()
        return changed()
    }

    /// The release a notification should tell about: an available one not told about yet, once
    /// (update.json keeps it across restarts).
    public func announce() -> String? {
        lock.lock()
        guard state == "available", let plan, plan.version != announced else { lock.unlock(); return nil }
        announced = plan.version
        let version = plan.version
        lock.unlock()
        changed()
        return version
    }

    // MARK: - installing

    /// The user's click on "Update available": download now (the caller runs `runDownload` off the main
    /// thread). False: nothing to update.
    func request() -> Bool {
        lock.lock()
        guard plan != nil, ["available", "failed"].contains(state) else { lock.unlock(); return false }  // a failed one: after a check
        wanted = true; state = "downloading"; error = nil; doneBytes = 0
        lock.unlock()
        changed()
        return true
    }

    @discardableResult
    public func runDownload() -> JSONValue {
        lock.lock()
        guard state == "downloading", let plan else { defer { lock.unlock() }; return status() }
        lock.unlock()
        do {
            try deps.backend.download(version: plan.version) { [weak self] done in
                guard let self else { return }
                self.lock.lock(); self.doneBytes = done; self.lock.unlock()
            }
        } catch {
            lock.lock()
            state = "failed"
            self.error = "Download failed: \(Self.why(error)). Palaver \(current) stays."
            failedVersion = plan.version
            lock.unlock()
            return changed()
        }
        lock.lock(); state = "ready"; lock.unlock()
        return changed()
    }

    /// Each second on the main thread: swap a downloaded update in when Palaver is idle. True: it is
    /// applied, the app must quit now.
    public func tick() -> Bool {
        lock.lock()
        guard state == "ready", wanted else { lock.unlock(); return false }
        if let reason = deps.busy() {
            let changedReason = reason != waitingFor
            waitingFor = reason
            lock.unlock()
            if changedReason { changed() }
            return false
        }
        state = "installing"; waitingFor = nil
        let version = plan?.version ?? "?"
        lock.unlock()
        do {
            try apply()
        } catch let idle as NotIdle {  // a call began in between: it is recorded, the update waits
            lock.lock(); state = "ready"; waitingFor = idle.reason; lock.unlock()
            changed()
            return false
        } catch {
            lock.lock()
            state = "failed"
            self.error = "Installing failed: \(Self.why(error)). Palaver \(current) stays."
            failedVersion = version
            lock.unlock()
            changed()
            return false
        }
        changed()
        return true
    }

    /// updater.Installer.apply: the models in and swap.sh written, the idle gate once more, then the
    /// swap is certain and starts.
    private func apply() throws {
        let script = try deps.backend.prepare(waitFor: deps.appPids())
        if let reason = deps.busy() { throw NotIdle(reason: reason) }  // asked last
        try deps.backend.commit()
        try deps.backend.spawnSwap(script: script)
    }

    // MARK: - what the app and the window call

    /// The menu's click, the window's `update_check`: a check in the background; the status now.
    @discardableResult
    public func check() -> JSONValue {
        _ = background { [self] in runCheck() }
        return status()
    }

    /// The user's click: download in the background, install when idle.
    @discardableResult
    public func install() -> JSONValue {
        if request() { _ = background { [self] in runDownload() } }
        return status()
    }

    /// The window opens: a look for a new release, unless one was just made.
    public func windowOpened() {
        if due(every: Self.windowCheckAfter) { _ = background { [self] in runCheck() } }
    }

    /// The menu's update item: install what there is; with none known, check now (the notification
    /// says what the check found).
    public func menuClicked() {
        let state = status()["state"]?.stringValue
        if state == "available" || state == "failed" {
            install()
        } else {
            lock.lock(); checkAsked = true; lock.unlock()
            check()
        }
    }

    /// Each second, main thread: start a due check; true when the app must quit now (an update is
    /// swapped in, or the user uninstalled).
    public func mainTick() -> Bool {
        if due() { _ = background { [self] in runCheck() } }
        lock.lock(); let quit = quitNow; lock.unlock()
        return quit || tick()
    }

    /// The notification the status calls for, once: what a check the user asked for found, else the
    /// announcement of a new release (its click opens settings/update).
    public func pendingNotification() -> (title: String, body: String, meeting: String?)? {
        let s = status()
        var said: (title: String, body: String)?
        lock.lock(); let asked = checkAsked; lock.unlock()
        if asked, let result = MenuText.checkResult(s) {
            lock.lock(); checkAsked = false; lock.unlock()
            said = result
        }
        let announced = announce()  // a new release, once; a check asked for said it already
        if let said { return (said.title, said.body, nil) }
        if let announced {
            let a = MenuText.announcement(announced)
            return (a.title, a.body, "settings/update")
        }
        return nil
    }

    /// `uninstall` (app.sock): start uninstall.py's script, then the app quits at the next tick.
    public func uninstall(models: Bool, recordings: Bool) throws -> [String: Any] {
        let removing = try deps.backend.uninstallStart(models: models, recordings: recordings, waitFor: deps.appPids())
        lock.lock(); quitNow = true; lock.unlock()
        return ["removing": removing]
    }

    // MARK: - what it says

    private var current: String { installed?.version ?? "?" }

    private func background(_ work: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        if workerRunning { lock.unlock(); return false }
        workerRunning = true
        lock.unlock()
        deps.background { [self] in
            work()
            lock.lock(); workerRunning = false; lock.unlock()
        }
        return true
    }

    /// updater.Updater.status(): the keys and their order are update.json's.
    public func status() -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        var available: JSONValue = .null
        if let plan {
            available = .object([("version", .string(plan.version)), ("notes", .str(plan.notes)),
                                 ("download_bytes", .int(plan.downloadBytes)), ("runtime", .bool(plan.runtime)),
                                 ("models", .strings(plan.models))])
        } else if state == "failed", let v = failedVersion, !v.isEmpty {
            available = .object([("version", .string(v)), ("notes", .null), ("download_bytes", .int(0)),
                                 ("runtime", .bool(false)), ("models", .array([]))])
        }
        return .object([
            ("state", .string(state)),
            ("current", state != "unsupported" ? .str(installed?.version ?? "?") : .null),
            ("available", available),
            ("done_bytes", .int(doneBytes)),
            ("waiting_for", .str(waitingFor)),
            ("error", .str(error)),
            ("check_error", .str(checkError)),
            ("checked_at", .num(checkedAt)),
            ("automatic", .bool(deps.enabled())),
            ("announced", .str(announced)),
        ])
    }

    @discardableResult
    private func changed() -> JSONValue {
        let s = status()
        deps.save(s)
        return s
    }

    private static func why(_ error: Error) -> String {
        let text = ((error as? LocalizedError)?.errorDescription ?? "\(error)")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? String(describing: type(of: error)) : text
    }
}
