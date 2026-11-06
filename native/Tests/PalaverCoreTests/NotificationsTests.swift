import Foundation
import Testing
@testable import PalaverCore

final class FakeCenter: NotificationCenterLike, @unchecked Sendable {
    let lock = NSLock()
    var posts: [(String, String, [String: String])] = []
    var status: NotifyPermission = .notAsked
    var postError: Error?
    var requested = 0
    func post(title: String, body: String, userInfo: [String: String], completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock(); posts.append((title, body, userInfo)); lock.unlock()
        completion(postError)
    }
    func authorizationStatus(completion: @escaping @Sendable (NotifyPermission) -> Void) { completion(status) }
    func requestAuthorization(completion: @escaping @Sendable (Bool) -> Void) { requested += 1; completion(status == .allowed) }
}

final class Box<T>: @unchecked Sendable {
    let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}

private func shortTmp() -> String {
    let d = "/tmp/pn-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

@Suite struct NotificationsTests {
    func make(_ c: FakeCenter, dir: String, opened: Box<[String?]> = Box([]), shown: Box<[String]> = Box([]),
              logs: Box<[String]> = Box([])) -> Notifications {
        Notifications(center: c, directory: dir, pid: 4242,
                      opener: { opened.value.append($0) },
                      fallback: { t, b in shown.value.append("\(t)|\(b)") },
                      log: { logs.value.append($0) })
    }

    @Test func datagramBecomesNotification() {
        let c = FakeCenter()
        let n = make(c, dir: shortTmp())
        n.handleDatagram(Data(#"{"title":"Done","message":"Notes are ready","open":"2026-10-21T16-29-29"}"#.utf8))
        #expect(c.posts.count == 1)
        #expect(c.posts[0].0 == "Done" && c.posts[0].1 == "Notes are ready")
        #expect(c.posts[0].2 == ["open": "2026-10-21T16-29-29"])
    }

    @Test func garbageIsIgnoredAndMissingFieldsDefault() {
        let c = FakeCenter()
        let n = make(c, dir: shortTmp())
        n.handleDatagram(Data("nope".utf8))
        n.handleDatagram(Data("[1]".utf8))
        #expect(c.posts.isEmpty)
        n.handleDatagram(Data(#"{"title":"T"}"#.utf8))
        #expect(c.posts[0].1 == "" && c.posts[0].2 == ["open": ""])
    }

    @Test(arguments: [(NotifyPermission.allowed, "allowed"), (.denied, "denied"), (.notAsked, "not_asked")])
    func stateFile(status: NotifyPermission, text: String) throws {
        let c = FakeCenter(); c.status = status
        let n = make(c, dir: shortTmp())
        n.writeState()
        #expect(try String(contentsOfFile: n.statePath, encoding: .utf8) == text)
        #expect(!FileManager.default.fileExists(atPath: n.statePath + ".tmp"))
    }

    @Test func clickOpensMeetingThroughOpener() {
        let opened = Box<[String?]>([])
        let n = make(FakeCenter(), dir: shortTmp(), opened: opened)
        n.didClick(userInfo: ["open": "2026-10-21T16-29-29"])
        n.didClick(userInfo: ["open": ""])
        n.didClick(userInfo: [:])
        #expect(opened.value == ["2026-10-21T16-29-29", nil, nil])
    }

    @Test func refusalFallsBackToOsascriptAndLogsOnce() {
        let c = FakeCenter(); c.postError = NSError(domain: "UN", code: 1, userInfo: [NSLocalizedDescriptionKey: "Notifications are not allowed"])
        let shown = Box<[String]>([]); let logs = Box<[String]>([])
        let n = make(c, dir: shortTmp(), shown: shown, logs: logs)
        n.handleDatagram(Data(#"{"title":"A","message":"1","open":""}"#.utf8))
        n.handleDatagram(Data(#"{"title":"B","message":"2","open":""}"#.utf8))
        #expect(shown.value == ["A|1", "B|2"])
        #expect(logs.value.count == 1 && logs.value[0].contains("refused by macOS"))
    }

    @Test func socketRoundTripAndPermissions() async throws {
        let c = FakeCenter(); c.status = .allowed
        let dir = shortTmp()
        let n = make(c, dir: dir)
        #expect(n.start())
        defer { n.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: n.socketPath)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(c.requested == 1)
        #expect(try String(contentsOfFile: n.statePath, encoding: .utf8) == "allowed")

        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(n.socketPath.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { r in for (i, b) in bytes.enumerated() { r[i] = UInt8(bitPattern: b) } }
        let msg = Array(#"{"title":"Hi","message":"there","open":"x"}"#.utf8)
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        for _ in 0..<100 where c.posts.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(c.posts.first?.0 == "Hi" && c.posts.first?.2 == ["open": "x"])
        n.stop()
        #expect(!FileManager.default.fileExists(atPath: n.socketPath))
    }

    @Test func tooLongSocketPathFailsToStart() {
        let n = make(FakeCenter(), dir: "/tmp/" + String(repeating: "a", count: 120))
        #expect(!n.start())
    }
}
