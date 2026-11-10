// What left the Mac, where to and when (palaver/access_log.py): one line per call to a cloud model (provider, host,
// model, feature, meetings, how many characters, how it went) and per upload to a transcription service (which track
// and how many seconds of audio). Never the content and never a key. Shown on the Settings page; never trimmed while
// testing is internal (#59), so a problem report gets all of it. The MCP access log may write here too.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

public enum AccessLog {
    public struct Entry {
        public var provider: String
        public var host: String
        public var model: String
        public var feature: String
        public var meetings: [String]
        public var chars: Int
        public var ok: Bool
        /// How long the call took.
        public var seconds: Double
        public var error: String?
        /// How much audio it sent, and which track.
        public var audioSeconds: Double?
        public var track: String?

        public init(provider: String, host: String, model: String, feature: String, meetings: [String], chars: Int, ok: Bool,
                    seconds: Double, error: String? = nil, audioSeconds: Double? = nil, track: String? = nil) {
            self.provider = provider; self.host = host; self.model = model; self.feature = feature
            self.meetings = meetings; self.chars = chars; self.ok = ok; self.seconds = seconds
            self.error = error; self.audioSeconds = audioSeconds; self.track = track
        }

        /// The line's object, in access_log.record's order.
        public func json(time: Date = Date()) -> JSONValue {
            var fields: [(String, JSONValue)] = [
                ("time", .string(AccessLog.isoSeconds(time))), ("provider", .string(provider)), ("host", .string(host)),
                ("model", .string(model)), ("feature", .string(feature)), ("meetings", .strings(meetings)),
                ("chars", .int(chars)), ("ok", .bool(ok)), ("seconds", .double(AccessLog.round1(seconds))),
            ]
            if let audioSeconds { fields.append(("audio_seconds", .double(AccessLog.round1(audioSeconds)))) }
            if let track, !track.isEmpty { fields.append(("track", .string(track))) }
            if let error, !error.isEmpty { fields.append(("error", .string(error))) }
            return .object(fields)
        }
    }

    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    /// The local time with its offset, to the second (`isoformat(timespec="seconds")`).
    static func isoSeconds(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withFullDate, .withFullTime, .withColonSeparatorInTimeZone]
        let s = f.string(from: date)
        return s.hasSuffix("Z") ? String(s.dropLast()) + "+00:00" : s
    }

    /// Appends `entry` to access-log.jsonl (0600, created with its folder).
    public static func record(_ entry: Entry, stores: StorePaths, now: Date = Date()) throws {
        let target = stores.accessLog
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(target.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let line = Array((PythonJSON.dumps(entry.json(time: now), ensureAscii: false) + "\n").utf8)
        var done = 0
        while done < line.count {
            let n = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + done, line.count - done) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            done += n
        }
    }

    /// The newest entries first; `limit` nil: all of them. Broken lines are skipped; no log reads as empty.
    public static func recent(_ limit: Int? = 50, stores: StorePaths) -> [JSONValue] {
        guard let data = try? Data(contentsOf: stores.accessLog) else { return [] }
        var out: [JSONValue] = []
        for line in ModelJobs.splitlines(String(decoding: data, as: UTF8.self)).reversed() {
            guard let entry = try? PythonJSON.parse(Data(line.utf8)), case .object = entry else { continue }
            out.append(entry)
            if let limit, out.count >= limit { break }
        }
        return out
    }

    /// `transcription.month`: what was sent for transcription this month — seconds of audio, meetings, and the
    /// estimated cost at list prices.
    public static func month(stores: StorePaths, now: Date = Date(), calendar: Calendar = .current) -> JSONValue {
        let since = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        var seconds = 0.0, usd = 0.0
        var meetings = Set<ScalarKey>()
        for e in recent(nil, stores: stores) {
            guard e["feature"]?.stringValue == ModelChoice.TRANSCRIPTION, e["ok"]?.truthy == true,
                  let time = e["time"]?.stringValue, let when = parseISO(time), when >= since else { continue }
            let audio = e["audio_seconds"]?.doubleValue ?? 0
            seconds += audio
            if let pid = e["provider"]?.stringValue, let price = ProviderRegistry.info[pid]?.usdPerHour {
                usd += (audio / 3600 * price * 10_000).rounded() / 10_000
            }
            for m in e["meetings"]?.arrayValue ?? [] { if let id = m.stringValue { meetings.insert(ScalarKey(id)) } }
        }
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.timeZone = calendar.timeZone
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return .object([("since", .string(day.string(from: since))), ("seconds", .double(round1(seconds))),
                        ("usd", .double((usd * 100).rounded() / 100)), ("meetings", .int(meetings.count))])
    }

    /// An ISO time with an offset (as record writes it), or without one (taken as local time).
    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withFullTime, .withColonSeparatorInTimeZone]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate, .withFullTime, .withColonSeparatorInTimeZone, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: s)
    }
}
