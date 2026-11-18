// The anonymous usage numbers (#6): one ping a day and one after each update (the day's version, now the new one), from
// the app's tick, beside the update check. Only while
// the user shares them (`share_usage`, on unless turned off) and lets Palaver look for updates (`check_updates`: the switch that allows
// automatic network calls at all), and only from a release: a development build never sends. The ping is the one
// UsageStats builds; Settings shows the same bytes.
import Foundation
import PalaverCore

public final class StatsPing: @unchecked Sendable {
    /// After a failed ping (offline, the endpoint down) the next try waits this long: never a loop.
    public static let retryAfter = 3600.0
    /// Seconds a ping may take in all: it is small, and nothing waits for it.
    public static let timeout = 15.0

    public struct Deps: @unchecked Sendable {
        /// Where the install id and the day of the last ping are kept (Application Support/palaver).
        public var support: URL
        /// share_usage and check_updates, read at each tick.
        public var enabled: @Sendable () -> Bool
        /// The bundle's release; nil: a development build, which never sends.
        public var version: String?
        public var macos: String
        public var endpoint: String
        /// POSTs the body; throws when it was not taken (StatsPing.post).
        public var send: @Sendable (URL, Data) throws -> Void
        public var now: @Sendable () -> Date
        /// Runs the ping off the main thread (tests run it at once).
        public var background: @Sendable (@escaping @Sendable () -> Void) -> Void
        public var log: @Sendable (String) -> Void

        public init(support: URL, enabled: @escaping @Sendable () -> Bool, version: String?,
                    macos: String = UsageStats.macOS(), endpoint: String = UsageStats.endpoint(),
                    send: @escaping @Sendable (URL, Data) throws -> Void = { try StatsPing.post($0, $1) },
                    now: @escaping @Sendable () -> Date = { Date() },
                    background: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { work in
                        DispatchQueue.global(qos: .utility).async(execute: work) },
                    log: @escaping @Sendable (String) -> Void = { _ in }) {
            self.support = support; self.enabled = enabled; self.version = version; self.macos = macos
            self.endpoint = endpoint; self.send = send; self.now = now; self.background = background; self.log = log
        }
    }

    private let deps: Deps
    private let lock = NSLock()
    private var running = false
    private var lastTry: Date?
    private var sentDay: String?
    private var sentVersion: String?
    private var sentDayRead = false
    private var failureSaid = false
    private var placeholderSaid = false

    public init(_ deps: Deps) { self.deps = deps }

    /// A ping is due: shared, from a release, to a real endpoint, none taken this UTC day or none since this version
    /// (an update: the day's row gets the new version), none running, and the last failed one an hour ago or more.
    public func due() -> Bool {
        guard deps.version != nil, deps.enabled() else { return false }
        guard UsageStats.sendable(deps.endpoint) != nil else {
            lock.withLock {
                if !placeholderSaid { deps.log("usage numbers: no endpoint set up (\(deps.endpoint)), nothing sent") }
                placeholderSaid = true
            }
            return false
        }
        let now = deps.now()
        return lock.withLock {
            if running { return false }
            if let lastTry, now.timeIntervalSince(lastTry) < Self.retryAfter { return false }
            if !sentDayRead {
                sentDay = UsageStats.lastSent(support: deps.support)
                sentVersion = UsageStats.lastSentVersion(support: deps.support)
                sentDayRead = true
            }
            // A clock set back never sends a day twice for one version: only a later day is due, or a new version.
            return sentDay.map { UsageStats.utcDay(now) > $0 } ?? true || sentVersion != deps.version
        }
    }

    /// Each second, main thread: a due ping goes off in the background.
    public func tick() {
        guard due() else { return }
        lock.withLock { running = true }
        deps.background { [self] in attempt() }
    }

    /// One ping, blocking. True when the endpoint took it; then nothing more is sent this UTC day.
    @discardableResult
    public func attempt() -> Bool {
        let now = deps.now()
        defer { lock.withLock { running = false; lastTry = now } }
        guard let version = deps.version, let url = UsageStats.sendable(deps.endpoint) else { return false }
        let day = UsageStats.utcDay(now)
        do {
            let install = try UsageStats.installID(support: deps.support)
            let body = UsageStats.body(install: install, version: version, macos: deps.macos)
            try deps.send(url, Data(body.utf8))
        } catch {
            // Said once until a ping gets through: an offline Mac must not fill the log.
            let say = lock.withLock { () -> Bool in defer { failureSaid = true }; return !failureSaid }
            if say { deps.log("usage numbers not sent (tried again in an hour): \(error)") }
            return false
        }
        lock.withLock { sentDay = day; sentVersion = version; sentDayRead = true; failureSaid = false }
        do { try UsageStats.markSent(day: day, version: version, support: deps.support) } catch {
            deps.log("could not note the usage numbers' day: \(error)")  // kept in memory: not sent again until a restart
        }
        return true
    }

    // MARK: - the request

    public struct Refused: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    /// One POST of `body` as JSON: an ephemeral session (no cookies, no cache, nothing kept), a short timeout, no
    /// redirect followed. Throws unless the endpoint answers 2xx. Blocks: never on the main thread.
    public static func post(_ url: URL, _ body: Data) throws {
        #if DEBUG
        if TestIsolation.isTestProcess && url.host != "127.0.0.1" && url.host != "localhost" {
            fatalError("TestIsolation: a usage ping to \(url) in a test; point PALAVER_STATS_URL at a stub on 127.0.0.1")
        }
        #endif
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = NoRedirect()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Palaver", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        let done = DispatchSemaphore(value: 0)
        let result = Box()
        session.dataTask(with: request) { _, response, error in
            if let error {
                result.error = Refused(description: error.localizedDescription)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result.error = Refused(description: "the endpoint answered \(http.statusCode)")
            }
            done.signal()
        }.resume()
        if done.wait(timeout: .now() + timeout + 5) == .timedOut { throw Refused(description: "no answer in time") }
        if let error = result.error { throw error }
    }

    private final class Box: @unchecked Sendable { var error: Error? }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)  // the 3xx itself is the answer: not 2xx, not taken
        }
    }
}
