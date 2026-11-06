// A recording cut by a Palaver restart and the parts that continue it (palaver/continuation.py,
// issue #47): the parts are listed in the first part's `parts.json`; `process` joins them. Here
// only what the daemon does: list a part (`add_part`), read the list, and the held-back `cut`.
import Foundation

public enum Continuation {
    static func file(_ head: URL) -> URL { head.appendingPathComponent("parts.json") }

    static func read(_ head: URL) -> [(String, JSONValue)] {
        guard let data = try? Data(contentsOf: file(head)), case .object(let fields)? = JSONValue.parse(data) else { return [] }
        return fields
    }

    /// The folders that continue the recording `head`, in order.
    public static func parts(_ head: URL) -> [URL] {
        let names = read(head).first { $0.0 == "parts" }?.1.arrayValue?.compactMap(\.stringValue) ?? []
        return names.map { head.deletingLastPathComponent().appendingPathComponent($0, isDirectory: true) }
    }

    /// Lists `part` in `head`'s parts.json (once), keeping what else it says. Throws when it can't.
    public static func addPart(_ head: URL, _ part: URL) throws {
        let names = parts(head).map(\.lastPathComponent)
        guard !names.contains(part.lastPathComponent) else { return }
        var fields = read(head).filter { $0.0 != "parts" }
        fields.append(("parts", .strings(names + [part.lastPathComponent])))
        let tmp = head.appendingPathComponent("parts.json.tmp")
        try Data(JSONValue.object(fields).encoded(indent: 2).utf8).write(to: tmp)
        guard rename(tmp.path, file(head).path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file(head).path])
        }
    }
}

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
