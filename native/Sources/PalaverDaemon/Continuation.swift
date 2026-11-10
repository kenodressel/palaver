// A recording cut by a Palaver restart and the parts that continue it (issue #47): the held-back `cut` the daemon
// keeps in daemon.json. The parts.json listing and the join are the domain's (PalaverDomain `Continuation`).
import Foundation
import PalaverCore

/// A recording held back when Palaver quit during a call, to be continued by the next start of a
/// call in the same app within `continueWithin` (daemon.json's `cut`).
public struct Cut: Equatable, Sendable {
    public var folders: [String]
    public var trigger: String
    /// When it was cut and when the meeting began: isoformat, kept as written.
    public var at: String
    public var since: String
    public var seconds: Double

    public init(folders: [String], trigger: String, at: String, since: String, seconds: Double) {
        self.folders = folders
        self.trigger = trigger
        self.at = at
        self.since = since
        self.seconds = seconds
    }

    /// `_restore_cut`: from daemon.json's "cut"; nil when it is not a whole one. Times without an
    /// offset are in `timeZone` (the daemon's).
    public init?(_ v: JSONValue?, timeZone: TimeZone) {
        guard let v, let at = v["at"]?.stringValue, let since = v["since"]?.stringValue,
              WallTime.parse(at, timeZone) != nil, WallTime.parse(since, timeZone) != nil,
              let list = v["folders"]?.arrayValue, !list.isEmpty else { return nil }
        let folders = list.compactMap(\.stringValue)
        guard folders.count == list.count else { return nil }
        self.init(folders: folders, trigger: v["trigger"]?.stringValue ?? "", at: at, since: since,
                  seconds: v["seconds"]?.doubleValue ?? 0)
    }

    public var json: JSONValue {
        .object([("folders", .strings(folders)), ("trigger", .string(trigger)), ("at", .string(at)),
                 ("since", .string(since)), ("seconds", .double(seconds))])
    }
}
