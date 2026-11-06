// Notifications: the notify socket and the permission state file, as the ObjC launcher did
// (app_bundle.py). Processes under the app find the socket through $PALAVER_NOTIFY and send one
// datagram JSON {title, message, open}; palaver/notify.py speaks exactly that. The state file
// ($PALAVER_NOTIFY_STATE) says allowed|denied|not_asked, refreshed every 10 s.
// A click is handled in-process: the opener gets the meeting id/route (no PALAVER_LAUNCHER_FD).
// No AppKit here: the center, the opener and the osascript fallback are injected.
import Foundation

public enum NotifyPermission: String, Sendable {
    case allowed, denied
    case notAsked = "not_asked"
}

/// What UNUserNotificationCenter offers, as far as Palaver needs it. The real adapter lives in the
/// app target; tests use a fake.
public protocol NotificationCenterLike: AnyObject, Sendable {
    func post(title: String, body: String, userInfo: [String: String], completion: @escaping @Sendable (Error?) -> Void)
    func authorizationStatus(completion: @escaping @Sendable (NotifyPermission) -> Void)
    func requestAuthorization(completion: @escaping @Sendable (Bool) -> Void)
}

public final class Notifications: @unchecked Sendable {
    public let socketPath: String
    public let statePath: String
    private let center: NotificationCenterLike
    private let opener: @Sendable (String?) -> Void
    private let fallback: @Sendable (String, String) -> Void
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "palaver.notifications")
    private let lock = NSLock()
    private var told = false
    private var sock: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?

    /// `directory`: where the socket and state file live ($TMPDIR). `opener`: a click on a
    /// notification (nil: no particular meeting). `fallback(title, body)`: shows it through osascript.
    public init(center: NotificationCenterLike, directory: String, pid: Int32 = getpid(),
                opener: @escaping @Sendable (String?) -> Void,
                fallback: @escaping @Sendable (String, String) -> Void,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        let dir = directory.hasSuffix("/") ? directory : directory + "/"
        self.socketPath = "\(dir)palaver-\(pid).sock"
        self.statePath = "\(dir)palaver-\(pid).notifications"
        self.center = center
        self.opener = opener
        self.fallback = fallback
        self.log = log
    }

    /// Binds the socket (0600), asks for authorization, writes the state file now and every 10 s.
    /// False when the socket could not be bound (the app then falls back to osascript everywhere).
    @discardableResult
    public func start(requestAuthorization: Bool = true) -> Bool {
        guard bind() else { return false }
        let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        let fd = sock
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 { self?.handleDatagram(Data(buffer[0..<n])) }
        }
        source.resume()
        readSource = source
        if requestAuthorization {
            center.requestAuthorization { [weak self] _ in self?.writeState() }
        } else {
            writeState()
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.writeState() }
        t.resume()
        timer = t
        return true
    }

    public func stop() {
        timer?.cancel(); timer = nil
        readSource?.cancel(); readSource = nil
        if sock >= 0 { close(sock); sock = -1 }
        unlink(socketPath)
        unlink(statePath)
    }

    private func bind() -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { close(fd); return false }
        chmod(socketPath, 0o600)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        sock = fd
        return true
    }

    /// One datagram: JSON {title, message, open}. Anything else is ignored.
    public func handleDatagram(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let title = (obj["title"] as? String) ?? ""
        let body = (obj["message"] as? String) ?? ""
        let open = (obj["open"] as? String) ?? ""
        center.post(title: title, body: body, userInfo: ["open": open]) { [weak self] error in
            guard let self, let error else { return }
            // macOS doesn't let this app notify (a managed Mac may refuse every app it doesn't know):
            // said once in the log, then shown through osascript; better than none.
            self.lock.lock()
            let first = !self.told
            self.told = true
            self.lock.unlock()
            if first {
                self.log("notifications refused by macOS (\(error.localizedDescription)); showing them through osascript")
            }
            self.fallback(title, body)
        }
    }

    /// The user clicked a notification: its userInfo carries `open`.
    public func didClick(userInfo: [AnyHashable: Any]) {
        let open = (userInfo["open"] as? String) ?? ""
        opener(open.isEmpty ? nil : open)
    }

    /// Writes the state file (through .tmp) from the center's current status.
    public func writeState(completion: (@Sendable () -> Void)? = nil) {
        center.authorizationStatus { [statePath] status in
            let tmp = statePath + ".tmp"
            if (try? status.rawValue.write(toFile: tmp, atomically: false, encoding: .utf8)) != nil {
                rename(tmp, statePath)
            }
            completion?()
        }
    }
}
