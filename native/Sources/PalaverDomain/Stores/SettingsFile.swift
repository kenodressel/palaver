// settings.json next to config.toml (palaver/settings.py): what the app changes itself.
import Foundation
import PalaverCore

/// The Settings dataclass: one flag per field, in the dataclass's order.
public struct SettingsValues: Equatable, Sendable {
    public var realtime = true
    public var recordTeams = true
    public var recordSlack = true
    public var searchMeaning = true
    public var liveProcessing = true
    public var nudgeTalkShare = true
    public var nudgeMonologue = true
    public var nudgeQuietInvitee = true
    public var nudgePace = false
    public var nudgeFillers = false
    /// Each nudge also as a notification, without sound (#19).
    public var nudgeNotify = true
    public var checkUpdates = true

    public init() {}

    private static let keys: [(String, WritableKeyPath<SettingsValues, Bool>)] = [
        ("realtime", \.realtime), ("record_teams", \.recordTeams), ("record_slack", \.recordSlack),
        ("search_meaning", \.searchMeaning), ("live_processing", \.liveProcessing),
        ("nudge_talk_share", \.nudgeTalkShare), ("nudge_monologue", \.nudgeMonologue),
        ("nudge_quiet_invitee", \.nudgeQuietInvitee), ("nudge_pace", \.nudgePace),
        ("nudge_fillers", \.nudgeFillers), ("nudge_notify", \.nudgeNotify), ("check_updates", \.checkUpdates),
    ]

    /// `settings.load`: a key that is missing or not a bool takes `defaults`' value.
    public init(json: JSONValue?, defaults: SettingsValues = SettingsValues()) {
        self = defaults
        guard case .object? = json else { return }
        for (key, path) in Self.keys {
            if case .bool(let b)? = json?[key] { self[keyPath: path] = b }
        }
    }

    public var json: JSONValue {
        .object(Self.keys.map { ($0.0, .bool(self[keyPath: $0.1])) })
    }
}

public enum SettingsFile {
    public static func load(defaults: SettingsValues = SettingsValues(), stores: StorePaths = .current()) -> SettingsValues {
        SettingsValues(json: PythonJSON.read(stores.settings), defaults: defaults)
    }

    /// The whole file; an empty object when it is missing or broken.
    public static func readRaw(stores: StorePaths = .current()) -> JSONValue {
        if let v = PythonJSON.read(stores.settings), case .object = v { return v }
        return .object([])
    }

    /// Merges `changes` into the file as it is (a changed key keeps its place, a new one goes last),
    /// read and written under `settings.json.lock`.
    public static func update(_ changes: [(String, JSONValue)], stores: StorePaths = .current()) throws {
        try StoreLock.with(stores.settings) {
            guard case .object(var fields) = readRaw(stores: stores) else { return }
            for (k, v) in changes {
                if let i = fields.firstIndex(where: { $0.0 == k }) { fields[i].1 = v } else { fields.append((k, v)) }
            }
            try write(.object(fields), stores: stores)
        }
    }

    public static func save(_ values: SettingsValues, stores: StorePaths = .current()) throws {
        try StoreLock.with(stores.settings) { try write(values.json, stores: stores) }
    }

    /// The name chosen in the app, which wins over config.toml's [user].name; nil when never chosen.
    public static func userName(stores: StorePaths = .current()) -> String? {
        guard let s = readRaw(stores: stores)["user_name"]?.stringValue else { return nil }
        let t = Py.strip(s)
        return t.isEmpty ? nil : t
    }

    public static func currentUserName(default name: String, stores: StorePaths = .current()) -> String {
        userName(stores: stores) ?? name
    }

    /// The user's earlier names, stripped, empty ones dropped.
    public static func userAliases(stores: StorePaths = .current()) -> [String] {
        guard let items = readRaw(stores: stores)["user_aliases"]?.arrayValue else { return [] }
        return items.compactMap { $0.stringValue.map(Py.strip) }.filter { !$0.isEmpty }
    }

    /// Every name of the user, casefolded: the current one and the aliases.
    public static func me(userName: String, stores: StorePaths = .current()) -> Set<String> {
        Set(([userName] + userAliases(stores: stores)).filter { !$0.isEmpty }.map { Py.casefold($0) })
    }

    /// Atomically, as settings.py `_write`: a 0600 temp file (fsynced), renamed over the file;
    /// indent 2 and a newline.
    private static func write(_ value: JSONValue, stores: StorePaths) throws {
        let target = stores.settings
        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent("\(target.lastPathComponent).\(UUID().uuidString.prefix(8).lowercased()).tmp").path
        func fail() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw fail() }
        do {
            let bytes = Array((PythonJSON.dumps(value, indent: 2) + "\n").utf8)
            var done = 0
            while done < bytes.count {
                let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + done, bytes.count - done) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { if n == 0 { errno = EIO }; throw fail() }
                done += n
            }
            if fsync(fd) != 0 { throw fail() }
        } catch {
            close(fd)
            unlink(tmp)
            throw error
        }
        guard close(fd) == 0 else { let e = fail(); unlink(tmp); throw e }
        guard rename(tmp, target.path) == 0 else {
            let e = fail()
            unlink(tmp)
            throw e
        }
    }
}
