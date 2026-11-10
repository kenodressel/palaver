// What is left at a service (transcription.py `_keep_pending`, `retry_pending`, `sweep_pending`; cloud_asr.py
// `delete_pending`): what a service could not delete yet (a job that had not ended) is kept in the meeting's
// cloud-pending.json (the Test button's: in the config folder) and deleted at the start of the next `process`, until the
// service says it is gone. A list of objects: provider, host, what, url (null: nothing to call, the service deletes it
// by `until`), since, error, tries.
import Foundation
import PalaverCore
import PalaverDomain

public enum TranscriptionPending {
    /// Where a pending deletion may be sent, by service: its own hosts and paths only, so a changed file can't send a key
    /// anywhere else.
    static let deletable: [String: (bases: [String], path: NSRegularExpression)] = [
        "assemblyai": (Array(AssemblyAI.BASES.values), try! NSRegularExpression(pattern: #"^/v2/transcript/[\w-]+$"#)),
        "soniox": (Array(Soniox.BASES.values), try! NSRegularExpression(pattern: #"^/v1/(transcriptions|files)/[\w-]+$"#)),
    ]

    static func auth(_ pid: String, _ key: String) -> (String, String) {
        pid == "assemblyai" ? ("authorization", key) : ("authorization", "Bearer \(key)")
    }

    /// Tries once more to delete what `entry` names. True when it is done with: deleted, gone already, nothing to call
    /// that is past its date, or not a deletion Palaver would send; false to keep it and try again later.
    public static func delete(_ entry: JSONValue, key: String?, http: HTTPClient, now: Date = Date()) async -> Bool {
        guard let url = entry["url"]?.stringValue, !url.isEmpty else {  // nothing to call: the service deletes it by itself
            guard let until = entry["until"]?.stringValue, let date = Py.fromIso(until) else { return true }
            return now >= date
        }
        let pid = entry["provider"]?.stringValue ?? ""
        guard let rule = deletable[pid], let parts = URLComponents(string: url), let scheme = parts.scheme, let host = parts.host,
              rule.bases.contains("\(scheme)://\(host)\(parts.port.map { ":\($0)" } ?? "")"),
              parts.query == nil, parts.fragment == nil,
              rule.path.firstMatch(in: parts.path, range: NSRange(parts.path.startIndex..., in: parts.path)) != nil,
              let target = URL(string: url) else {
            return true  // dropped: not a deletion Palaver would send
        }
        guard let key, !key.isEmpty else { return false }  // no key now: kept until there is one again
        var request = URLRequest(url: target, timeoutInterval: TranscriptionAdapter.REQUEST_TIMEOUT_SECONDS)
        request.httpMethod = "DELETE"
        let (k, v) = auth(pid, key)
        request.setValue(v, forHTTPHeaderField: k)
        do {
            _ = try await http.send(request, name: pid, key: key, attempts: 1)
        } catch {
            return (error as? CloudError)?.status == 404
        }
        return true
    }

    static func read(_ file: URL) -> [JSONValue] {
        guard let data = PythonJSON.read(file)?.arrayValue else { return [] }
        return data.filter { if case .object = $0 { return true } else { return false } }
    }

    /// The entries written whole (`<name>.tmp`, renamed); none: the file is removed.
    static func write(_ file: URL, _ entries: [JSONValue]) throws {
        if entries.isEmpty {
            unlink(file.path)
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PythonJSON.write(.array(entries), to: file, indent: 2, ensureAscii: true, via: file.lastPathComponent + ".tmp")
    }

    /// What `adapter` could not delete, added to `file`: retried later. Returns how many were added.
    @discardableResult
    public static func keep(_ adapter: TranscriptionAdapter, in file: URL) -> Int {
        let left = adapter.pending
        guard !left.isEmpty else { return 0 }
        adapter.pending = []
        try? write(file, read(file) + left)
        return left.count
    }

    /// Deletes what `file` lists; returns how many are still left. `key`: the provider's key (nil: none now).
    public static func retry(_ file: URL, key: (String) -> String?, http: HTTPClient) async -> Int {
        let entries = read(file)
        if entries.isEmpty { return 0 }
        var left: [JSONValue] = []
        for e in entries {
            let pid = e["provider"]?.stringValue ?? ""
            let done = await delete(e, key: ModelChoice.provider(pid) != nil ? key(pid) : nil, http: http)
            if !done {
                var fields = PyDict<JSONValue>(e) ?? PyDict()
                fields["tries"] = .int((e["tries"]?.doubleValue).map { Int($0) }.map { $0 + 1 } ?? 1)
                left.append(fields.json)
            }
        }
        try? write(file, left)
        return left.count
    }

    /// Retries the pending deletions of every meeting in `root`, and the Test button's (`global`); never fails. Returns
    /// how many are still left.
    public static func sweep(root: URL, global: URL, key: (String) -> String?, http: HTTPClient) async -> Int {
        var files = [global]
        let name = RecordingPaths(root).cloudPending.lastPathComponent
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        for f in folders {
            let file = root.appendingPathComponent(f).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { files.append(file) }
        }
        var left = 0
        for f in files { left += await retry(f, key: key, http: http) }
        return left
    }
}
