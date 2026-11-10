// The transport (webapp/server.py, webapp/process.py Inflight): the Host check, the sign-in and the
// key, the body limits, the page's files, the error table, the drain. Ports the transport tests of
// tests/test_webapp.py and the Inflight test of tests/test_web_process.py; a server in this process,
// fake collaborators, temporary folders only.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let MEETING = "2026-10-27T16-03-07"

@Suite(.serialized) struct TransportTests {
    // MARK: - Host and key

    @Test func test_http_rejects_other_hosts_and_non_json_posts() throws {
        let s = try TestServer()
        defer { s.stop() }
        let other = Wire.send(port: s.port, Wire.request("GET", "/api/ping", headers: [("Host", "evil.example:8765")]))
        #expect(other.status == 403 && other.error == "wrong host")
        let posted = Wire.send(port: s.port, Wire.request("POST", "/api/meetings/\(MEETING)/speakers",
                                                          headers: [s.host, ("Content-Type", "application/x-www-form-urlencoded")],
                                                          body: Data("label=SPEAKER_00&name=X".utf8)))
        #expect(posted.status == 415 && posted.error == "JSON only")
        // A JSON type with parameters is JSON; another port of this host is another host.
        #expect(s.post("/api/nope", headers: [("Content-Type", "application/json; charset=utf-8")]).status == 404)
        #expect(Wire.send(port: s.port, Wire.request("GET", "/api/ping", headers: [("Host", "127.0.0.1:\(s.port + 1)")])).status == 403)
        #expect(Wire.send(port: s.port, Wire.request("GET", "/api/ping", headers: [("Host", "localhost:\(s.port)")])).status == 200)
        #expect(Wire.send(port: s.port, Wire.request("GET", "/api/ping", headers: [])).status == 403)
    }

    @Test func test_a_keyed_server_answers_nothing_without_the_key() throws {
        let s = try TestServer(key: "s3cret-key")
        defer { s.stop() }
        #expect(s.get("/").status == 403)
        #expect(s.get("/api/ping").error == "open Palaver from its menu bar icon")
        #expect(s.get("/api/meetings/\(MEETING)/audio?track=mix").status == 403)
        #expect(s.post("/api/meetings").status == 403)
        let wrong = s.get("/?key=wrong")
        #expect(wrong.status == 403 && wrong.error == "wrong key")
        #expect(s.get("/api/ping", headers: [("Cookie", "\(Auth.cookieName(port: s.port))=wrong")]).status == 403)
        #expect(s.get("/api/ping", headers: [("Cookie", "\(Auth.cookieName(port: s.port + 1))=s3cret-key")]).status == 403)
        #expect(s.post("/api/ping", headers: [("Cookie", "\(Auth.cookieName(port: s.port))=s3cret-ke")]).status == 403)
        // The key never goes into the log, not even a wrong one.
        #expect(!s.log.contains("wrong") && !s.log.contains("s3cret"))
    }

    @Test func test_the_window_signs_in_with_the_key_once_and_then_uses_its_cookie() throws {
        let s = try TestServer(key: "s3cret-key", meetings: { try pageMeeting($0, MEETING) })
        defer { s.stop() }
        let signIn = s.get(Auth.withKey("/", key: "s3cret-key"))
        #expect(signIn.status == 302)
        #expect(signIn.header("Location") == "/")  // the key leaves the address; the #route stays (the browser keeps it)
        let cookie = try #require(signIn.header("Set-Cookie"))
        #expect(cookie == "\(Auth.cookieName(port: s.port))=s3cret-key; Path=/; HttpOnly; SameSite=Strict")
        #expect(signIn.header("Cache-Control") == "no-store" && signIn.header("Content-Length") == "0")
        let signed = ("Cookie", String(cookie.split(separator: ";")[0]))
        #expect(s.get("/", headers: [signed]).status == 200)
        let ping = s.get("/api/ping", headers: [signed])
        #expect(ping.status == 200 && ping.text == #"{"ok": true}"#)
        #expect(s.post("/api/meetings/\(MEETING)/trash", headers: [signed]).status == 200)
        // Other parameters stay; the key's own (any of them) go; the path stays as sent.
        #expect(s.get("/x%20y?a=1&key=s3cret-key&b=%C3%9F+z&key=other").header("Location") == "/x%20y?a=1&b=%C3%9F+z")
        // An empty key is no sign-in: the cookie is asked for.
        #expect(s.get("/?key=").error == "open Palaver from its menu bar icon")
        // Among other cookies, quoted or not.
        #expect(s.get("/api/ping", headers: [("Cookie", "a=b; \(Auth.cookieName(port: s.port))=\"s3cret-key\"; c=d")]).status == 200)
        #expect(!s.log.contains("s3cret"))
    }

    @Test func test_with_key_keeps_the_route() {
        #expect(Auth.withKey("http://127.0.0.1:5/", key: "k") == "http://127.0.0.1:5/?key=k")
        #expect(Auth.withKey("http://127.0.0.1:5/#/settings", key: "k") == "http://127.0.0.1:5/?key=k#/settings")
        #expect(Auth.withKey("http://127.0.0.1:5/#/settings", key: nil) == "http://127.0.0.1:5/#/settings")
    }

    @Test func theKeyIsComparedByItsBytes() {
        #expect(Auth.same("s3cret-key", "s3cret-key"))
        #expect(!Auth.same("s3cret-ke", "s3cret-key") && !Auth.same("s3cret-keyy", "s3cret-key") && !Auth.same("", "k"))
        #expect(!Auth.same("Straße", "Strasse") && !Auth.same("e\u{301}", "\u{e9}"))
    }

    // MARK: - one request, one answer

    @Test func answersAreHTTP10AndCloseTheConnection() throws {
        let s = try TestServer()
        defer { s.stop() }
        let r = Wire.send(port: s.port, Wire.request("GET", "/api/ping", headers: [s.host, ("Connection", "keep-alive")]))
        #expect(r.status == 200 && r.header("Server") == "palaver" && r.header("Content-Type") == "application/json")
        #expect(r.header("Content-Length") == "12" && r.header("Cache-Control") == "no-store" && r.header("Date") != nil)
        let head = s.get("/api/ping", method: "HEAD")
        #expect(head.status == 200 && head.header("Content-Length") == "12" && head.body.isEmpty)
        for method in ["PUT", "DELETE", "OPTIONS", "PATCH"] {
            let r = s.get("/api/ping", method: method)
            #expect(r.status == 501 && r.text.contains("Unsupported method ('\(method)')"))
        }
        // URLSession, as a page would ask.
        let url = URL(string: "http://127.0.0.1:\(s.port)/api/ping")!
        let done = Latch()
        final class Box: @unchecked Sendable { var status = 0; var body = Data() }
        let box = Box()
        URLSession.shared.dataTask(with: url) { data, response, _ in
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.body = data ?? Data()
            done.open()
        }.resume()
        done.wait(10)
        #expect(box.status == 200 && String(decoding: box.body, as: UTF8.self) == #"{"ok": true}"#)
    }

    @Test func jsonAnswersKeepUnicodeAsIs() throws {
        let s = try TestServer { r, _ in r.get("/t") { _, _ in .json(.object([("name", .string("Timo Strauß"))])) } }
        defer { s.stop() }
        let r = s.get("/t")
        #expect(r.text == #"{"name": "Timo Strauß"}"# && r.header("Content-Length") == String(r.body.count))
    }

    @Test func aSlowRouteHoldsUpNoOther() throws {
        let release = Latch(), started = Latch()
        let s = try TestServer { r, _ in
            r.get("/slow") { _, _ in started.open(); release.wait(10); return .json(.bool(true)) }
        }
        defer { s.stop() }
        final class Box: @unchecked Sendable { var reply: Reply? }
        let box = Box()
        let t = Thread { box.reply = s.get("/slow") }
        t.start()
        started.wait()
        #expect(s.get("/api/ping").status == 200)  // while /slow still runs
        #expect(box.reply == nil)
        release.open()
        #expect(until { box.reply != nil } && box.reply?.status == 200)
    }

    @Test func test_a_page_that_lets_go_mid_answer_is_no_error() throws {
        let s = try TestServer { r, _ in r.get("/t/gone") { _, _ in throw ClientGone() } }
        defer { s.stop() }
        let r = Wire.send(port: s.port, Wire.request("GET", "/t/gone", headers: [s.host]), timeout: 2)
        #expect(r.empty && r.body.isEmpty)  // closed without an answer
        // A page that closes before a slow answer is written: no error either.
        let release = Latch(), started = Latch()
        let s2 = try TestServer { r, _ in r.get("/slow") { _, _ in started.open(); release.wait(); return .json(.null) } }
        defer { s2.stop() }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(s2.port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        let req = Wire.request("GET", "/slow", headers: [s2.host])
        _ = req.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        started.wait()
        close(fd)
        release.open()
        #expect(s2.get("/api/ping").status == 200)  // still serving
        #expect(!s.log.contains("failed") && !s2.log.contains("failed"))
    }

    // MARK: - bodies

    @Test func test_http_bodies_are_capped_before_they_are_read() throws {
        let s = try TestServer()
        defer { s.stop() }
        for (target, size) in [("/api/meetings/\(MEETING)/my-notes", 3 * 1024 * 1024),
                               ("/api/meetings/\(MEETING)/my-notes/images", 40 * 1024 * 1024),
                               ("/api/upcoming/x/my-notes/images", 40 * 1024 * 1024)] {
            let head = "POST \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(s.port)\r\nContent-Type: application/json\r\nContent-Length: \(size)\r\n\r\n{}"
            let r = Wire.send(port: s.port, Data(head.utf8))
            #expect(r.status == 413 && r.error == "too large")
        }
        #expect(Router.bodyLimit("/api/meetings/x/my-notes") == 2 * 1024 * 1024)
        #expect(Router.bodyLimit("/api/meetings/x/my-notes/images") == 35 * 1024 * 1024)
        #expect(Router.bodyLimit("/api/meetings/x/my-notes/images?x=1") == 2 * 1024 * 1024)  // server.py matches self.path
    }

    @Test func aBodyWithoutALengthIsCappedAsItArrives() throws {
        let s = try TestServer { r, _ in r.post("/api/echo") { req, _ in .json(req.json) } }
        defer { s.stop() }
        func chunked(_ target: String, _ payload: Data, chunk: Int) -> Data {
            var out = Data("POST \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(s.port)\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
            var at = 0
            while at < payload.count {
                let n = min(chunk, payload.count - at)
                out.append(Data(String(n, radix: 16).utf8) + Data("\r\n".utf8) + payload[at..<at + n] + Data("\r\n".utf8))
                at += n
            }
            return out + Data("0\r\n\r\n".utf8)
        }
        let small = chunked("/api/echo", Data(#"{"a": [1, 2]}"#.utf8), chunk: 4)
        #expect(Wire.send(port: s.port, small).text == #"{"a": [1, 2]}"#)
        let big = chunked("/api/echo", Data(repeating: 0x20, count: 2 * 1024 * 1024 + 1), chunk: 64 * 1024)
        let r = Wire.send(port: s.port, big)
        #expect(r.status == 413 && r.error == "too large")
        #expect(s.get("/api/ping").status == 200)
    }

    @Test func aBodyThatIsNoJSONIsABadRequest() throws {
        let s = try TestServer { r, _ in r.post("/api/echo") { req, _ in .json(req.json) } }
        defer { s.stop() }
        #expect(Wire.send(port: s.port, Wire.request("POST", "/api/echo", headers: [s.host, ("Content-Type", "application/json")])).text == "{}")
        let bad = Wire.send(port: s.port, Wire.request("POST", "/api/echo", headers: [s.host, ("Content-Type", "application/json")],
                                                      body: Data("{nope".utf8)))
        #expect(bad.status == 400 && bad.error?.hasPrefix("bad request: ") == true)
        #expect(s.post("/api/nope").status == 404 && s.post("/api/nope").error == "not found")
    }

    @Test func anImportIsStreamedToAFileWithinItsLimit() throws {
        final class Seen: @unchecked Sendable { var bytes: Data?; var file: URL? }
        let seen = Seen()
        let s = try TestServer { r, _ in
            r.post(#"/api/test-import(\?.*)?"#, file: .init(contentType: "application/octet-stream", wrongType: "zip only",
                                                            tooLarge: "too big", missing: "no file", limit: 10 << 20)) { req, _ in
                seen.file = req.bodyFile
                seen.bytes = req.bodyFile.flatMap { FileManager.default.contents(atPath: $0.path) }
                return .json(.object([("size", .int(seen.bytes?.count ?? -1))]))
            }
        }
        defer { s.stop() }
        let payload = Data((0..<(9 << 20)).map { UInt8($0 % 251) })
        let r = Wire.send(port: s.port, Wire.request("POST", "/api/test-import?separate=1",
                                                    headers: [s.host, ("Content-Type", "application/octet-stream")], body: payload))
        #expect(r.status == 200 && r.json?["size"] == .int(payload.count))
        #expect(seen.bytes == payload)
        #expect(until { seen.file.map { !FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path) } ?? false })
        let over = Wire.send(port: s.port, Wire.request("POST", "/api/test-import", headers: [s.host, ("Content-Type", "application/octet-stream")],
                                                        body: Data(count: (10 << 20) + 1)))
        #expect(over.status == 413 && over.error == "too big")
        let json = s.post("/api/test-import")
        #expect(json.status == 415 && json.error == "zip only")
        let none = Wire.send(port: s.port, Wire.request("POST", "/api/test-import", headers: [s.host, ("Content-Type", "application/octet-stream")]))
        #expect(none.status == 400 && none.error == "no file")
        let big = "POST /api/import HTTP/1.1\r\nHost: 127.0.0.1:\(s.port)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(1400 * 1024 * 1024 + 1)\r\n\r\nPK"
        let tooBig = Wire.send(port: s.port, Data(big.utf8))
        #expect(tooBig.status == 413 && tooBig.error == "Not imported: the file is too large.")
    }

    // MARK: - the page's files

    @Test func test_http_api_and_page() throws {
        // The meeting list, a meeting id that would leave the recordings; `/` is index.html; a file outside static/ is not served, however it is asked for.
        let root = tempFolder("static")
        defer { try? FileManager.default.removeItem(at: root) }
        let site = root.appendingPathComponent("static", isDirectory: true)
        try FileManager.default.createDirectory(at: site.appendingPathComponent("fonts"), withIntermediateDirectories: true)
        try Data("<html>page</html>".utf8).write(to: site.appendingPathComponent("index.html"))
        try Data("let x = 1".utf8).write(to: site.appendingPathComponent("app.js"))
        try Data("font".utf8).write(to: site.appendingPathComponent("fonts/a.woff2"))
        try Data("raw".utf8).write(to: site.appendingPathComponent("data.bin"))
        try Data("secret".utf8).write(to: root.appendingPathComponent("server.py"))
        try FileManager.default.createSymbolicLink(at: site.appendingPathComponent("out.py"),
                                                   withDestinationURL: root.appendingPathComponent("server.py"))
        try FileManager.default.createSymbolicLink(at: site.appendingPathComponent("up"), withDestinationURL: root)
        let s = try TestServer(staticDir: site, meetings: { try pageMeeting($0) })
        defer { s.stop() }
        let list = s.get("/api/meetings")
        #expect(list.status == 200 && list.json?.arrayValue?.first?["id"] == .string("2026-10-27T16-03-07"))
        let outside = s.get("/api/meetings/..%2F..%2Fetc")
        #expect(outside.status == 404 && outside.error == "not found: ..%2F..%2Fetc")
        let page = s.get("/")
        #expect(page.status == 200 && page.header("Content-Type") == "text/html; charset=utf-8" && page.text.contains("<html"))
        for path in ["/meetings", "/api/whatever", "/a.b/c", "/.hidden", "/x."] {
            #expect(s.get(path).text == "<html>page</html>", "\(path)")
        }
        #expect(s.get("/app.js").header("Content-Type") == "text/javascript; charset=utf-8")
        #expect(s.get("/fonts/a.woff2").header("Content-Type") == "font/woff2")
        #expect(s.get("/data.bin").header("Content-Type") == "application/octet-stream")
        for path in ["/../server.py", "/out.py", "/up/server.py", "/..%2Fserver.py", "/%2E%2E/server.py", "/fonts/../../server.py",
                     "/nope.js"] {
            let r = s.get(path)
            #expect(r.status == 404 && r.error == "not found", "\(path)")
        }
        #expect(Static.serve("/app.js\0.js", staticDir: site).status == 404)
        #expect(!s.log.contains("failed"))
    }

    @Test func test_index_has_settings_entry() throws {
        let s = try TestServer()
        defer { s.stop() }
        let r = s.get("/")
        #expect(r.status == 200 && r.text.contains(#"aria-label="Settings""#))
    }

    // MARK: - errors and collaborators

    @Test func everyErrorMapsToItsStatus() throws {
        let cases: [(Error, Int, String)] = [
            (NotFound("meeting x"), 404, #"{"error": "not found: meeting x"}"#),
            (Refused("Nicht möglich."), 400, #"{"error": "Nicht möglich."}"#),
            (BadRequest("'label'"), 400, #"{"error": "bad request: 'label'"}"#),
            (Conflict("taken"), 409, #"{"error": "taken"}"#),
            (ConflictDocument("changed", document: .object([("revision", .string("r2"))])), 409,
             #"{"error": "changed", "document": {"revision": "r2"}}"#),
            (ModelBusy(), 409, #"{"error": "the language model is busy; try again in a minute"}"#),
            (BadGateway("the language model failed; see the log"), 502, #"{"error": "the language model failed; see the log"}"#),
            (Unavailable("the language model is turned off"), 503, #"{"error": "the language model is turned off"}"#),
            (UndoGone("x"), 404, #"{"error": "can't undo this any more"}"#),
            (UndoChanged("x"), 409, #"{"error": "the meeting changed since"}"#),
            (GlossaryLookupError(id: "t1"), 500, ""), (ProjectLookupError("p1"), 500, ""),
            (ServerError("boom"), 500, #"{"error": "boom"}"#),
        ]
        let s = try TestServer { r, _ in
            for (i, c) in cases.enumerated() {
                r.get("/e/\(i)") { _, _ in throw c.0 }
                r.post("/e/\(i)") { _, _ in throw c.0 }
            }
        }
        defer { s.stop() }
        for (i, c) in cases.enumerated() {
            for r in [s.get("/e/\(i)"), s.post("/e/\(i)")] {
                #expect(r.status == c.1, "\(c.0)")
                if c.2.isEmpty {
                    #expect(r.json?["error"]?.stringValue == String(describing: c.0))
                } else {
                    #expect(r.text == c.2)
                }
            }
        }
        #expect(s.log.contains("GET /e/12 failed: boom") && !s.log.contains("/e/0 failed"))
    }

    @Test func stubCollaboratorsAnswer503NotACrash() throws {
        let s = try TestServer { r, app in
            r.post("/t/helper") { _, _ in .json(.int(Int(try app.helpers.run(kind: "notes", key: "k", args: []) ?? -1))) }
            r.post("/t/ask") { _, _ in .json(try app.nextQuestion.ask(meetingId: MEETING, inputs: .object([]))) }
            r.post("/t/provider") { _, _ in .json(try app.provider.call("test", body: .object([]), timeout: 1)) }
            r.get("/api/import-get") { _, _ in .json(.null) }
        }
        defer { s.stop() }
        for path in ["/t/helper", "/t/ask", "/t/provider"] {
            let r = s.post(path)
            #expect(r.status == 503 && r.error == "not wired", "\(path)")
        }
        #expect(s.get("/api/ping").status == 200)
    }

    // MARK: - the drain

    @Test func test_inflight_changes_drain_but_model_waits_do_not() {
        let inflight = Inflight()
        #expect(inflight.waitIdle(timeout: 0.1))
        let done = Latch()
        let t = Thread { inflight.change { done.wait(5) } }
        t.start()
        #expect(until(2) { inflight.count == 1 })
        let started = Date()
        #expect(!inflight.waitIdle(timeout: 0.3))  // a change still runs
        #expect(Date().timeIntervalSince(started) >= 0.3)
        done.open()
        #expect(inflight.waitIdle(timeout: 1))

        let hold = Latch()
        let t2 = Thread { inflight.change { inflight.detached { hold.wait(5) } } }
        t2.start()
        usleep(100_000)
        #expect(inflight.waitIdle(timeout: 0.2))  // the job is the app's: the server need not wait for it
        hold.open()
        #expect(until { inflight.count == 0 })
    }

    @Test func aStopLetsAChangeWhoseBodyStillArrivesFinish() throws {
        final class Seen: @unchecked Sendable { var file: URL? }
        let seen = Seen()
        let s = try TestServer { r, _ in
            r.post("/t/upload", file: .init(contentType: "application/octet-stream", wrongType: "zip only", tooLarge: "too big",
                                            missing: "no file", limit: 64 << 20)) { req, _ in
                seen.file = req.bodyFile
                return .json(.int(req.bodyFile.flatMap { FileManager.default.contents(atPath: $0.path)?.count } ?? -1))
            }
            r.post("/t/json") { req, _ in .json(req.json) }
        }
        defer { s.stop() }
        let payload = Data(repeating: 7, count: 12 << 20)
        let upload = RawClient(port: s.port)
        upload.send(Wire.request("POST", "/t/upload", headers: [s.host, ("Content-Type", "application/octet-stream")], body: payload)
            .prefix(1 << 20))
        let json = RawClient(port: s.port)
        let body = Data(#"{"words": "Northwind"}"#.utf8)
        let jsonRequest = Wire.request("POST", "/t/json", headers: [s.host, ("Content-Type", "application/json")], body: body)
        json.send(jsonRequest.dropLast(5))
        #expect(until { s.app.inflight.count == 2 })  // both counted while their bodies arrive
        s.server.shutdown()  // a stop (SIGTERM, the app gone): no new requests
        let started = Date()
        #expect(!s.server.waitIdle(timeout: 0.3))
        #expect(Date().timeIntervalSince(started) >= 0.3)
        json.send(jsonRequest.suffix(5))
        #expect(json.reply().text == #"{"words": "Northwind"}"#)
        upload.send(Wire.request("POST", "/t/upload", headers: [s.host, ("Content-Type", "application/octet-stream")], body: payload)
            .dropFirst(1 << 20))
        let r = upload.reply()
        #expect(r.status == 200 && r.json == .int(payload.count))
        #expect(s.server.waitIdle(timeout: 5))
        let folder = try #require(seen.file).deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: folder.path))  // gone before the drain ended
    }

    @Test func anUploadThePageGivesUpLeavesNothingBehind() throws {
        let tmp = FileManager.default.temporaryDirectory.path
        func spools() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? []).filter { $0.hasPrefix("palaver-import-") })
        }
        let before = spools()
        let s = try TestServer { r, _ in
            r.post("/t/upload", file: .init(contentType: "application/octet-stream", wrongType: "zip only", tooLarge: "too big",
                                            missing: "no file", limit: 64 << 20)) { _, _ in .json(.null) }
        }
        defer { s.stop() }
        let upload = RawClient(port: s.port)
        upload.send(Wire.request("POST", "/t/upload", headers: [s.host, ("Content-Type", "application/octet-stream")],
                                 body: Data(count: 8 << 20)).prefix(2 << 20))
        #expect(until { s.app.inflight.count == 1 && spools().count > before.count })
        upload.hangUp()
        #expect(s.server.waitIdle(timeout: 5))
        #expect(spools() == before)
    }

    @Test func aTicketHandedToAnotherThreadIsDetachedThere() {
        let inflight = Inflight()
        let ticket = inflight.enter()
        #expect(inflight.count == 1)
        let inside = Latch(), go = Latch()
        Thread {
            inflight.adopt(ticket) { inflight.detached { inside.open(); go.wait() } }
            ticket.leave()
        }.start()
        inside.wait()
        #expect(inflight.count == 0)  // a model wait
        go.open()
        #expect(until { !ticket.isCounted } && inflight.waitIdle(timeout: 1))
        ticket.leave()  // once only
        #expect(inflight.count == 0)
    }

    @Test func test_restart_waits_for_a_running_change_not_for_a_model_wait() throws {
        let change = Latch(), changing = Latch(), model = Latch(), waiting = Latch()
        let s = try TestServer { r, app in
            r.post("/t/change") { _, _ in changing.open(); change.wait(10); return .json(.string("changed")) }
            r.post("/t/model") { _, _ in app.inflight.detached { waiting.open(); model.wait(10); return .json(.string("noted")) } }
        }
        defer { s.stop() }
        final class Box: @unchecked Sendable { var change: Reply?; var model: Reply? }
        let box = Box()
        Thread { box.model = s.post("/t/model") }.start()
        waiting.wait()
        Thread { box.change = s.post("/t/change") }.start()
        changing.wait()
        s.server.shutdown()  // a restart: no new requests from now on
        let started = Date()
        #expect(!s.server.waitIdle(timeout: 0.3))  // the change runs
        #expect(Date().timeIntervalSince(started) >= 0.3)
        change.open()
        #expect(s.server.waitIdle(timeout: 5))  // the model's run is no reason to wait
        #expect(until { box.change != nil } && box.change?.text == #""changed""#)  // its answer still goes out
        #expect(box.model == nil)
        model.open()
        #expect(until { box.model != nil } && box.model?.status == 200)
    }
}
