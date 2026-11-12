// The server's own background work (api.py:1953-1992 `warm_search_cache`, `busy_recording`, `start_warming`,
// :1994-2007 `searcher`, :2453-2508 `_cut_later`; server.py `sweep_leftovers`; process.py `warm_up`): the search made
// ready before it is asked (never while a recording or its processing runs), what an import cut short left behind, the
// glossary's suggestions, the cut suggestions looked up off the request, and the one searcher by meaning.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

public final class Background: @unchecked Sendable {
    /// After the window's server starts: the app launches first.
    public static let WARM_DELAY_SECONDS = 20.0
    /// While a recording or processing runs.
    public static let WARM_RETRY_SECONDS = 30.0
    /// Between meetings: others go first.
    public static let WARM_PAUSE_SECONDS = 0.05
    /// The cut suggestion asks the calendar, which may be slow or hang: a lookup slower than this counts as failed.
    public static let CUT_LOOKUP_SECONDS = 10.0
    /// A cut suggestion is looked up again after this (a failed or stale answer is retried then).
    public static let CUT_FRESH_SECONDS = 600.0
    public static let CUT_LOOKUPS_AT_ONCE = 4

    /// The server this works for (set by `ServerApp.init`).
    weak var app: ServerApp?

    // What tests replace before the server serves (Python's tests monkeypatch `api._clock`, `cutting.suggest_cut`,
    // `embeddings.model_folder`, and pass their own searcher).
    /// Seconds since 1970 (`api._clock`, `time.time`).
    public var clock: () -> Double = { Date().timeIntervalSince1970 }
    /// The cut suggestion of a ready meeting (`_cut_suggestion` with the app's calendar). One that throws keeps the
    /// last answer (`look()`'s `except`); `MeetingsAPI.cutSuggestion` itself answers null for what it can't read.
    public var cutLookup: (ServerApp, RecordingPaths) throws -> JSONValue = { app, paths in
        MeetingsAPI.cutSuggestion(app, paths, MeetingsAPI.state(paths))
    }
    /// Where the e5 model is on this Mac (never downloaded); nil when it is not.
    public var modelFolder: (ServerApp) -> URL? = { E5Encoder.modelFolder(stores: $0.stores) }
    /// The searcher by meaning, made at the first search by meaning.
    public var makeSearcher: (ServerApp) -> Searcher = { app in
        Searcher(outputDir: app.outputDir, encoderFactory: { [weak app] in
            guard let app, let folder = app.background.modelFolder(app) else { return nil }
            return try E5Encoder(folder: folder)
        })
    }

    private let lock = NSLock()
    private var made: Searcher?
    private var warmingThread: Thread?
    private var cutCache: [ScalarKey: (key: CutKey, value: JSONValue?)] = [:]
    private var cutPending: [ScalarKey: (key: CutKey, started: Double)] = [:]
    private let lookups = DispatchGroup()

    public init() {}

    // MARK: - the searcher

    /// The window's searcher by meaning (`api.searcher`): one per server, its model loaded on demand.
    public func searcher() -> Searcher {
        lock.withLock {
            if let made { return made }
            let s = makeSearcher(app!)
            made = s
            return s
        }
    }

    // MARK: - warming the search

    /// The warming thread, once `startWarming` started it.
    public var warming: Thread? { lock.withLock { warmingThread } }

    /// `busy_recording`: whether the menu bar app records or processes a recording now. Without the menu bar app (tests),
    /// daemon.json of a `palaver daemon` beside it says; one that can't be read counts as busy.
    public static func busyRecording(_ app: ServerApp) -> Bool {
        if let recording = app.recording { return recording.busy() }
        let file = app.stores.daemonJson
        guard MeetingsAPI.exists(file) else { return false }
        guard let state = PythonJSON.read(file), state.isObject else { return true }
        return state["state"]?.stringValue == "recording" || (state["transcribing"]?.truthy ?? false)
    }

    /// `warm_search_cache`: every finished meeting made ready for the search (names, notes, readable lines), so the first
    /// search after a start is as quick as the rest. Waits `delay` first; never while a recording or processing runs
    /// (`busy`), stops when one starts and goes on after it.
    public static func warmSearchCache(_ app: ServerApp, busy: () -> Bool, sleep: (Double) -> Void,
                                       delay: Double = WARM_DELAY_SECONDS) throws {
        sleep(delay)
        while true {
            if busy() {
                sleep(WARM_RETRY_SECONDS)
                continue
            }
            var stopped = false
            for m in try MeetingsAPI.listMeetings(app: app) where m["status"]?.stringValue == "ready" {
                if busy() {
                    stopped = true
                    break
                }
                // A meeting that can't be read is left for the search to say so (Python logs it at DEBUG, which
                // daemon.log leaves out).
                _ = try? SearchAPI.Found(app, m, score: 0).lines(app)
                sleep(WARM_PAUSE_SECONDS)
            }
            if !stopped { return }
        }
    }

    /// `start_warming`: `warmSearchCache` on a thread of its own at background QoS (the efficiency cores, behind
    /// everything else). `clock`: how it waits (seconds).
    @discardableResult
    public func startWarming(clock sleep: @escaping (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
                             qos: QualityOfService = .background) -> Thread {
        let t = Thread { [weak self] in
            guard let app = self?.app else { return }
            // A failure ends the warming quietly (Python logs it at DEBUG, which daemon.log leaves out).
            try? Background.warmSearchCache(app, busy: { Background.busyRecording(app) }, sleep: sleep)
        }
        t.name = "search-warm"
        t.qualityOfService = qos
        lock.withLock { warmingThread = t }
        t.start()
        return t
    }

    // MARK: - at a start, after the ready line

    /// `sweep_leftovers`: what an import cut short by a stop left behind (#58). Not Downloads: macOS may ask the user
    /// before the server may look there, and a start would wait on the answer; the next export sweeps it.
    public func sweep() {
        guard let app else { return }
        Exchange.sweep(app.outputDir)
    }

    /// `warm_up`: what the window's first visits would otherwise wait for — the glossary's suggestions read every
    /// transcript (seconds the first time), and so do Review and Needs you (#29). Needs you without the calendar:
    /// its cuts are looked up when the window asks.
    public func warmUp() {
        guard let app else { return }
        do {
            _ = try GlossaryAPI.page(app, userName: app.userName)
            for m in try MeetingsAPI.listMeetings(app: app) where m["status"]?.stringValue == "ready" {
                _ = try ReviewAPI.meetingNeeds(app, m, calendar: false)
            }
        } catch {
            app.log?.message("could not prepare the glossary's suggestions and Needs you: \(error)", level: "WARNING", logger: "palaver.webapp.process")
        }
    }

    /// The sweep and the warm-up, each on a thread of its own (process.py starts them after the ready line: they never
    /// delay it).
    public func afterReady() {
        let sweeping = Thread { [weak self] in self?.sweep() }
        sweeping.name = "sweep"
        sweeping.start()
        let warm = Thread { [weak self] in self?.warmUp() }
        warm.name = "warm-up"
        warm.start()
    }

    // MARK: - what follows a change

    private let followUps = DispatchQueue(label: "palaver.follow-up", qos: .userInitiated)
    private let following = DispatchGroup()
    private var queued = Set<String>()

    /// Work a change starts that its answer does not wait for (#31: after a change of event, every meeting's voices
    /// recognized again and the names inferred across meetings), one after the other on a queue of its own. Work of
    /// a `kind` already waiting to start is not queued again: that run sees this change too. A stop waits for it as
    /// for a change (`inflight`); a failure is logged.
    public func followUp(_ kind: String, _ work: @escaping (ServerApp) throws -> Void) {
        guard let app else { return }
        let fresh = lock.withLock { queued.insert(kind).inserted }
        guard fresh else { return }
        let ticket = app.inflight.enter()
        following.enter()
        followUps.async { [weak self, weak app] in
            defer {
                ticket.leave()
                self?.following.leave()
            }
            _ = self?.lock.withLock { self?.queued.remove(kind) }
            guard let app else { return }
            do { try work(app) } catch {
                app.log?.message("\(kind) failed: \(error)", level: "ERROR", logger: "palaver.webapp.api")
            }
        }
    }

    /// Until the follow-ups started so far are done, at most `timeout` seconds; true when they are. A change waits
    /// for them first, so it never meets one half done; the page asks (`/api/settled`) to show what they found.
    @discardableResult
    public func settle(_ timeout: Double) -> Bool {
        following.wait(timeout: .now() + timeout) == .success
    }

    // MARK: - the cut suggestions

    struct CutKey: Equatable {
        let files: [Int]
        let slot: Int
    }

    /// `_cut_later`: the cut suggestion as last looked up for these files (`files`: their times); when that is not fresh
    /// (`CUT_FRESH_SECONDS`), a lookup starts in the background — the answer shows next time. A lookup slower than
    /// `CUT_LOOKUP_SECONDS` counts as failed and is asked again once the key moves on; at most `CUT_LOOKUPS_AT_ONCE` run.
    func cutLater(_ app: ServerApp, _ paths: RecordingPaths, files: [Int]) -> JSONValue? {
        let now = clock()
        let key = CutKey(files: files, slot: Int((now / Self.CUT_FRESH_SECONDS).rounded(.down)))
        let folder = ScalarKey(paths.folder.path)
        return lock.withLock { () -> JSONValue? in
            let cached = cutCache[folder]
            if let cached, cached.key == key { return cached.value }
            let last = cached.flatMap { $0.key.files == files ? $0.value : nil }  // stale, but about these files
            if let pending = cutPending[folder] {
                if now - pending.started < Self.CUT_LOOKUP_SECONDS { return last }
                cutPending[folder] = nil  // too slow: failed; asked again once the key moves on
                cutCache[folder] = (pending.key, last)
                if pending.key == key { return last }
            }
            if cutPending.count >= Self.CUT_LOOKUPS_AT_ONCE { return last }
            cutPending[folder] = (key, now)
            lookups.enter()
            let t = Thread { [self] in
                var found: JSONValue?
                do {
                    let answer = try cutLookup(app, paths)
                    found = answer.isNull ? nil : answer
                } catch {
                    app.log?.message("looking up a cut for \(paths.folder.path) failed: \(error)", level: "ERROR",
                                     logger: "palaver.webapp.api")
                    found = last
                }
                lock.withLock {
                    if cutPending[folder]?.key == key {
                        cutPending[folder] = nil
                        cutCache[folder] = (key, found)
                    }
                }
                lookups.leave()
            }
            t.name = "cut-lookup"
            t.start()
            return last
        }
    }

    /// For tests (`wait_for_cut_lookups`): until the background lookups are done, at most `timeout` seconds.
    public func waitForCutLookups(_ timeout: Double) {
        _ = lookups.wait(timeout: .now() + timeout)
    }
}
