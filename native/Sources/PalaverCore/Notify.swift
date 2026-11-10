// Notifications on pipeline events (palaver/notify.py): one datagram to the app's socket ($PALAVER_NOTIFY), which
// posts it as Palaver, so a click opens the meeting. Without the socket (not under the app) nothing is shown;
// `--no-notify` mutes them. A failure to notify is never an error.
import Darwin
import Foundation

public enum Notify {
    public static let ENV = "PALAVER_NOTIFY"
    /// notify.py `_MAX_MESSAGE`.
    public static let MAX_MESSAGE = 200

    /// `--no-notify`.
    nonisolated(unsafe) public static var muted = false

    /// Sends `{title, message, open}` (plus `quiet`, `expires` seconds when given); whether a datagram went out.
    /// `meeting`: the recording a click opens.
    @discardableResult
    public static func send(title: String, message: String, meeting: String? = nil, quiet: Bool = false,
                            expires: Double? = nil, env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard !muted, let socketPath = env[ENV], !socketPath.isEmpty else { return false }
        return deliver(datagram(title: title, message: message, meeting: meeting, quiet: quiet, expires: expires), to: socketPath)
    }

    /// The datagram's bytes: `{title, message, open}` (the message cut at MAX_MESSAGE), `quiet` and `expires` only when
    /// given.
    public static func datagram(title: String, message: String, meeting: String? = nil, quiet: Bool = false,
                                expires: Double? = nil) -> [UInt8] {
        var fields: [(String, JSONValue)] = [("title", .string(title)), ("message", .string(String(message.prefix(MAX_MESSAGE)))),
                                             ("open", .string(meeting ?? ""))]
        if quiet { fields.append(("quiet", .bool(true))) }
        if let expires { fields.append(("expires", .double(expires))) }
        return Array(JSONValue.object(fields).encoded(indent: nil).utf8)
    }

    /// Sends `bytes` to the app's socket at `socketPath`; whether all of it went out.
    public static func deliver(_ bytes: [UInt8], to socketPath: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return sent == bytes.count
    }
}
