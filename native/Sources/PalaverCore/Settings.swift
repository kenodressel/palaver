import Foundation

/// settings.json (`~/.config/palaver/settings.json`), re-read when its mtime changes (the window's
/// server writes it from another process). Missing file, broken JSON, a missing key or a value of
/// the wrong type take the default; config.toml's values are the defaults for two keys.
public final class Settings: @unchecked Sendable {
    public static let audioDayChoices = [0, 7, 14, 30, 90]

    private let url: URL
    private let defaults: Config
    private let lock = NSLock()
    private var cachedStamp: Date?
    private var cached: [String: Any] = [:]

    public init(url: URL, defaults: Config = Config()) {
        self.url = url
        self.defaults = defaults
    }

    private func data() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if stamp == nil { cachedStamp = nil; cached = [:]; return cached }
        if stamp != cachedStamp {
            cachedStamp = stamp
            if let raw = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                cached = obj
            } else { cached = [:] }
        }
        return cached
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        // JSONSerialization makes NSNumber of 0/1 too: only a real boolean counts.
        if let n = data()[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return fallback
    }

    public var realtime: Bool { bool("realtime", true) }
    public var recordTeams: Bool { bool("record_teams", true) }
    public var recordSlack: Bool { bool("record_slack", defaults.recordSlack) }
    /// Don't keep the microphone while muted in the recorded call (CallMute).
    public var respectCallMute: Bool { bool("respect_call_mute", defaults.respectCallMute) }
    public var liveProcessing: Bool { bool("live_processing", defaults.processingLive) }
    public var searchMeaning: Bool { bool("search_meaning", true) }
    public var checkUpdates: Bool { bool("check_updates", true) }
    public var nudgeTalkShare: Bool { bool("nudge_talk_share", true) }
    public var nudgeMonologue: Bool { bool("nudge_monologue", true) }
    public var nudgeQuietInvitee: Bool { bool("nudge_quiet_invitee", true) }
    public var nudgePace: Bool { bool("nudge_pace", false) }
    public var nudgeFillers: Bool { bool("nudge_fillers", false) }
    /// Each nudge also as a quiet notification (#19).
    public var nudgeNotify: Bool { bool("nudge_notify", true) }

    /// The setup assistant was finished or skipped (the window's finish_setup writes
    /// `"setup": {"done"|"skipped": <time>, "hardware": …}`).
    public var setupFinished: Bool {
        guard let setup = data()["setup"] as? [String: Any] else { return false }
        return setup["done"] is String || setup["skipped"] is String
    }

    /// How long a transcribed meeting keeps its audio, in days; 0: always.
    public var audioDays: Int {
        if let n = data()["audio_days"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
           Settings.audioDayChoices.contains(n.intValue), Double(n.intValue) == n.doubleValue { return n.intValue }
        return 0
    }

    /// The name chosen in the app, which wins over config.toml's; nil when never chosen.
    public var userName: String? {
        guard let s = data()["user_name"] as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
