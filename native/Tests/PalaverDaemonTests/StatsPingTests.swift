// The opt-in usage numbers (#6) from the app's tick: when a ping goes, what it holds, and the request itself against
// a stub on 127.0.0.1. Never the real endpoint, never the real support folder.
import Darwin
import Foundation
import Testing
import PalaverCore
@testable import PalaverDaemon

private let STUB = "https://palaver-stats.contoso.workers.dev/ping"

/// A StatsPing with a clock, a switch and a recorded `send` (fails while `fail` is set).
private final class PingRig: @unchecked Sendable {
    let support = tempDir()
    var now = Date(timeIntervalSince1970: 1_794_830_400)  // 2026-11-16 12:00 UTC
    var on = true
    var fail: Error?
    var sent: [(URL, String)] = []
    var tries = 0
    var logged: [String] = []
    var version: String? = "0.6.8"
    var endpoint = STUB
    lazy var ping = make()

    func make() -> StatsPing {
        StatsPing(.init(support: support, enabled: { [unowned self] in on }, version: version, macos: "15.5",
                        endpoint: endpoint,
                        send: { [unowned self] url, body in
                            tries += 1
                            if let fail { throw fail }
                            sent.append((url, String(decoding: body, as: UTF8.self)))
                        },
                        now: { [unowned self] in now }, background: { $0() }, log: { [unowned self] in logged.append($0) }))
    }

    func later(hours: Double) { now = now.addingTimeInterval(hours * 3600) }
}

@Suite struct StatsPingTests {
    @Test func oneTickSendsTheShownPingOnceThatDay() throws {
        let r = PingRig()
        r.ping.tick()
        let id = try UsageStats.installID(support: r.support)
        #expect(r.sent.map(\.0.absoluteString) == [STUB])
        #expect(r.sent.first?.1 == #"{"install": "\#(id)", "version": "0.6.8", "macos": "15.5"}"#)
        #expect(UsageStats.lastSent(support: r.support) == "2026-11-16")
        for hours in [0.0, 1, 5, 5.9] {  // the rest of the UTC day, up to 23:54: nothing more
            r.later(hours: hours)
            r.ping.tick()
        }
        #expect(r.sent.count == 1)
        r.later(hours: 0.2)  // past midnight UTC
        r.ping.tick()
        #expect(r.sent.count == 2)
    }

    @Test func aRestartTheSameDaySendsNothingMore() {
        let r = PingRig()
        r.ping.tick()
        let again = r.make()  // the app started again: the day is read from stats-sent
        r.later(hours: 2)
        again.tick()
        #expect(r.sent.count == 1)
    }

    @Test func offDevelopmentBuildOrPlaceholderSendNothing() {
        let off = PingRig()
        off.on = false
        off.ping.tick()
        #expect(off.sent.isEmpty && !FileManager.default.fileExists(atPath: UsageStats.installFile(support: off.support).path))

        let dev = PingRig()
        dev.version = nil  // a development build
        dev.ping.tick()
        #expect(dev.sent.isEmpty)

        let unset = PingRig()
        unset.endpoint = UsageStats.defaultEndpoint
        unset.ping.tick()
        unset.later(hours: 30)
        unset.ping.tick()
        #expect(unset.sent.isEmpty)
        #expect(unset.logged.count == 1 && unset.logged[0].contains("no endpoint set up"))
    }

    @Test func turnedOnLaterItSendsAtTheNextTick() {
        let r = PingRig()
        r.on = false
        r.ping.tick()
        r.on = true
        r.ping.tick()
        #expect(r.sent.count == 1)
    }

    @Test func aFailedPingIsTriedAgainAnHourLaterAndSaidOnce() {
        let r = PingRig()
        r.fail = StatsPing.Refused(description: "offline")
        r.ping.tick()
        r.later(hours: 0.5)
        r.ping.tick()  // not before an hour
        #expect(r.tries == 1)
        r.later(hours: 0.6)
        r.ping.tick()
        #expect(r.tries == 2 && r.sent.isEmpty)
        #expect(r.logged.count == 1 && r.logged[0].contains("offline"))
        #expect(UsageStats.lastSent(support: r.support) == nil)
        r.fail = nil
        r.later(hours: 1)
        r.ping.tick()
        #expect(r.sent.count == 1)
        #expect(UsageStats.lastSent(support: r.support) == "2026-11-16")
    }

    @Test func aClockSetBackSendsNoDayTwice() {
        let r = PingRig()
        r.ping.tick()
        r.later(hours: -48)
        r.ping.tick()
        #expect(r.sent.count == 1)
    }

    @Test func aNewIdGoesWithTheNextDaysPing() throws {
        let r = PingRig()
        r.ping.tick()
        let old = try UsageStats.installID(support: r.support)
        let new = try UsageStats.newInstallID(support: r.support)
        r.later(hours: 1)
        r.ping.tick()
        #expect(r.sent.count == 1)  // not the same day under a new id
        r.later(hours: 12)
        r.ping.tick()
        #expect(r.sent.count == 2)
        #expect(r.sent[1].1.contains(new) && !r.sent[1].1.contains(old))
    }

    // MARK: - the request

    @Test func thePostIsJsonToTheEndpointAndA2xxIsTaken() throws {
        let stub = try PingStub(status: 204)
        defer { stub.stop() }
        let body = #"{"install": "3f2a9c4e-8b1d-4e6f-9a2b-7c5d1e0f4a3b", "version": "0.6.8", "macos": "15.5"}"#
        try StatsPing.post(URL(string: "\(stub.url)/ping")!, Data(body.utf8))
        let got = try #require(stub.requests.first)
        #expect(got.head.hasPrefix("POST /ping HTTP/1.1\r\n"))
        #expect(got.head.lowercased().contains("content-type: application/json"))
        #expect(!got.head.lowercased().contains("cookie"))
        #expect(got.body == body)
    }

    @Test func anythingButA2xxThrowsAndARedirectIsNotFollowed() throws {
        let refused = try PingStub(status: 400)
        defer { refused.stop() }
        #expect(throws: StatsPing.Refused.self) { try StatsPing.post(URL(string: "\(refused.url)/ping")!, Data("{}".utf8)) }
        let moved = try PingStub(status: 307, location: "http://127.0.0.1:9/elsewhere")
        defer { moved.stop() }
        #expect(throws: StatsPing.Refused.self) { try StatsPing.post(URL(string: "\(moved.url)/ping")!, Data("{}".utf8)) }
        #expect(moved.requests.count == 1)
    }

    @Test func nobodyListeningThrowsAtOnce() throws {
        let gone = try PingStub(status: 204)
        let url = URL(string: "\(gone.url)/ping")!
        gone.stop()
        let started = Date()
        #expect(throws: StatsPing.Refused.self) { try StatsPing.post(url, Data("{}".utf8)) }
        #expect(Date().timeIntervalSince(started) < StatsPing.timeout)
    }
}

/// A one-answer HTTP server on 127.0.0.1: every request gets `status` (and `location`), and is kept.
private final class PingStub: @unchecked Sendable {
    private let fd: Int32
    let port: Int
    private let lock = NSLock()
    private var seen: [(head: String, body: String)] = []
    let status: Int
    let location: String?

    init(status: Int, location: String? = nil) throws {
        self.status = status
        self.location = location
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.fd = fd
        port = Int(UInt16(bigEndian: got.sin_port))
        Thread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { return }
                var noSigpipe: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 5, tv_usec: 0)  // a client that never finishes cannot hang the test
                setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                Thread { [self] in handle(c) }.start()
            }
        }.start()
    }

    var url: String { "http://127.0.0.1:\(port)" }
    var requests: [(head: String, body: String)] { lock.withLock { seen } }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    private func handle(_ c: Int32) {
        defer { close(c) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        func more() -> Bool {
            let n = read(c, &buffer, buffer.count)
            guard n > 0 else { return false }
            data.append(contentsOf: buffer[0..<n])
            return true
        }
        while data.range(of: Data("\r\n\r\n".utf8)) == nil { if !more() { return } }
        let split = data.range(of: Data("\r\n\r\n".utf8))!
        let head = String(decoding: data[..<split.upperBound], as: UTF8.self)
        let length = head.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        while data.count - split.upperBound < length { if !more() { break } }
        let body = String(decoding: data[split.upperBound...], as: UTF8.self)
        lock.withLock { seen.append((head, body)) }
        var answer = "HTTP/1.1 \(status) X\r\nContent-Length: 0\r\nConnection: close\r\n"
        if let location { answer += "Location: \(location)\r\n" }
        answer += "\r\n"
        _ = answer.withCString { write(c, $0, strlen($0)) }
    }
}
