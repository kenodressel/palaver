// daemon.json (inventory §4): the daemon's status, written atomically through `.tmp` on every
// tick, in the key order and value shapes of daemon.py's `Daemon.status()`; its readers are the
// window's server (webapp/remote.py), `process` (continuation.being_recorded), doctor and report.
import Foundation
import PalaverCore

// MARK: - the file

public enum DaemonStateFile {
    /// daemon.json as a dictionary; empty when it is missing, broken or not an object.
    public static func read(_ url: URL) -> JSONValue {
        guard let data = try? Data(contentsOf: url), let v = JSONValue.parse(data), case .object = v else { return .object([]) }
        return v
    }

    /// Writes `status` through `<name>.tmp` and a rename, as `_write_state` does. False when it failed.
    @discardableResult
    public static func write(_ status: JSONValue, to url: URL) -> Bool {
        let tmp = url.deletingPathExtension().appendingPathExtension("tmp")
        let data = Data(status.encoded(indent: 2).utf8)
        if (try? data.write(to: tmp)) == nil {  // the folder is made once, when it is missing
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: tmp)) != nil else { return false }
        }
        return rename(tmp.path, url.path) == 0
    }
}
