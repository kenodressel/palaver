// The opt-in usage numbers (#6): what a ping holds, where it goes, and the two small files it keeps in the support
// folder. The app sends it (PalaverDaemon's StatsPing), the window shows it (palaver-server's UsageStatsAPI): both
// build it here, so Settings shows exactly what is sent. Off by default (settings.json `share_usage`).
import Foundation

public enum UsageStats {
    /// Where pings go: the Worker in stats/ (its README says how it is deployed). `PALAVER_STATS_URL` names another
    /// endpoint (the tests' stub). While the placeholder is in, nothing is sent.
    public static let defaultEndpoint = "https://palaver-stats.<placeholder>.workers.dev/ping"

    public static func endpoint(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let given = environment["PALAVER_STATS_URL"], !given.isEmpty { return given }
        return defaultEndpoint
    }

    /// The endpoint is a real one: https, or plain http to this Mac (a test's stub); never the placeholder.
    public static func sendable(_ endpoint: String) -> URL? {
        guard !endpoint.contains("<placeholder>"), let url = URL(string: endpoint), let host = url.host else { return nil }
        if url.scheme == "https" { return url }
        if url.scheme == "http", host == "127.0.0.1" || host == "localhost" { return url }
        return nil
    }

    /// The public page with the totals: the endpoint's site.
    public static func page(endpoint: String) -> String {
        guard let r = endpoint.range(of: "/ping", options: [.anchored, .backwards]) else { return endpoint }
        return String(endpoint[..<r.lowerBound]) + "/"
    }

    // MARK: - what is sent

    /// The body of a ping, byte for byte: `{"install": …, "version": …, "macos": …}`.
    public static func body(install: String, version: String, macos: String) -> String {
        JSONValue.object([("install", .string(install)), ("version", .string(version)), ("macos", .string(macos))])
            .encoded(indent: nil)
    }

    /// macOS as major.minor ("15.5", "26.1"): the patch level would only narrow a Mac down.
    public static func macOS(_ v: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        "\(v.majorVersion).\(v.minorVersion)"
    }

    /// The UTC day of `date` (YYYY-MM-DD), the day the Worker counts a ping under.
    public static func utcDay(_ date: Date) -> String { dayFormat.string(from: date) }

    /// Asked each second by the app's tick: made once (ISO8601DateFormatter is safe to share across threads).
    private static let dayFormat: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - the install id

    /// `<support>/install-id`: a random UUID v4, made the first time it is needed, replaced by "New ID".
    public static func installFile(support: URL) -> URL { support.appendingPathComponent("install-id") }
    /// `<support>/stats-sent`: the UTC day of the last ping the endpoint took.
    public static func sentFile(support: URL) -> URL { support.appendingPathComponent("stats-sent") }

    public static func isInstallID(_ s: String) -> Bool {
        s.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }

    /// This install's id; made now when there is none (or the file holds something else). The app and the window's
    /// server may both make it at once: the first file wins, the other one reads it.
    public static func installID(support: URL) throws -> String {
        let file = installFile(support: support)
        #if DEBUG
        TestIsolation.checkOutsideHome(file, "the install id")
        #endif
        if let id = readID(file) { return id }
        let tmp = try writeTemp(newID(), beside: file)
        defer { unlink(tmp.path) }
        if link(tmp.path, file.path) == 0 || errno == EEXIST, let id = readID(file) { return id }
        // Something that is not an id is in the way: replaced.
        return try newInstallID(support: support)
    }

    /// "New ID": a fresh id replaces the old one; the next ping (tomorrow at the earliest) sends it.
    @discardableResult
    public static func newInstallID(support: URL) throws -> String {
        let file = installFile(support: support)
        #if DEBUG
        TestIsolation.checkOutsideHome(file, "the install id")
        #endif
        let id = newID()
        let tmp = try writeTemp(id, beside: file)
        guard rename(tmp.path, file.path) == 0 else {
            let e = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            unlink(tmp.path)
            throw e
        }
        return id
    }

    /// The UTC day the last ping was taken, nil when never.
    public static func lastSent(support: URL) -> String? {
        let text = (try? String(contentsOf: sentFile(support: support), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? text : nil
    }

    public static func markSent(day: String, support: URL) throws {
        let file = sentFile(support: support)
        #if DEBUG
        TestIsolation.checkOutsideHome(file, "the usage numbers' day")
        #endif
        let tmp = try writeTemp(day, beside: file)
        guard rename(tmp.path, file.path) == 0 else {
            let e = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            unlink(tmp.path)
            throw e
        }
    }

    private static func newID() -> String { UUID().uuidString.lowercased() }  // Foundation's UUID() is a random v4

    private static func readID(_ file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isInstallID(id) ? id : nil
    }

    /// `text` and a newline in a new 0600 file next to `file`.
    private static func writeTemp(_ text: String, beside file: URL) throws -> URL {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString.prefix(8).lowercased()).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: Data((text + "\n").utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw POSIXError(.EIO)
        }
        return tmp
    }
}
