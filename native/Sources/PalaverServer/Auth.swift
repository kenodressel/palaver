// Who may ask (webapp/server.py:46-57, :171-195): only this Mac's browser at the server's own
// address (the Host header, against DNS rebinding), and only the window, which got the app's key
// once (`/?key=…`) and keeps it as a cookie. The key is compared in constant time and never put
// into a log line, an error or an answer other than its own cookie.
import Foundation

public enum Auth {
    /// `key_cookie`: cookies are per host, not per port; the port in the name keeps two servers apart.
    public static func cookieName(port: Int) -> String { "palaver_key_\(port)" }

    /// `with_key`: `url` with the key, before its #route (what the window opens first).
    public static func withKey(_ url: String, key: String?) -> String {
        guard let key, !key.isEmpty else { return url }
        let base: Substring, rest: Substring
        if let hash = url.firstIndex(of: "#") {
            base = url[..<hash]
            rest = url[hash...]
        } else {
            base = Substring(url)
            rest = ""
        }
        return "\(base)?\(PyURL.urlencode([("key", key)]))\(rest)"
    }

    /// `hmac.compare_digest` over the UTF-8 bytes: the time depends on the lengths only.
    public static func same(_ given: String, _ key: String) -> Bool {
        let a = Array(given.utf8), b = Array(key.utf8)
        var diff: UInt8 = a.count == b.count ? 0 : 1
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x: UInt8 = i < a.count ? a[i] : 0
            let y: UInt8 = i < b.count ? b[i] : 0
            diff |= x ^ y
        }
        return diff == 0
    }

    /// The value of cookie `name` in a `Cookie` header (`SimpleCookie(header).get(name)`): pairs
    /// split at `;`, a quoted value unquoted; nil when it isn't there.
    public static func cookie(_ header: String?, name: String) -> String? {
        guard let header else { return nil }
        var found: String?
        for part in header.split(separator: ";") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let k = part[..<eq].trimmingCharacters(in: .whitespaces)
            var v = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
            if k == name { found = v }  // SimpleCookie keeps the last one
        }
        return found
    }

    /// The `Set-Cookie` of a sign-in.
    static func setCookie(port: Int, key: String) -> String {
        "\(cookieName(port: port))=\(key); Path=/; HttpOnly; SameSite=Strict"
    }
}

/// The checks every request goes through first, in server.py's order.
struct Gate {
    let port: Int
    let key: String?

    /// `_host_ok`: exactly `127.0.0.1:<port>` or `localhost:<port>`.
    func hostOK(_ host: String?) -> Bool {
        let h = host ?? ""
        return h == "127.0.0.1:\(port)" || h == "localhost:\(port)"
    }

    /// `_key_ok`: without a key (tests) everyone on this Mac may.
    func keyOK(cookieHeader: String?) -> Bool {
        guard let key else { return true }
        guard let given = Auth.cookie(cookieHeader, name: Auth.cookieName(port: port)) else { return false }
        return Auth.same(given, key)
    }

    /// `_sign_in` for a GET whose query has `key`: a 302 to the same path without it, with the
    /// cookie; 403 `wrong key` otherwise.
    func signIn(_ request: Request, given: String) -> Response {
        guard let key, Auth.same(given, key) else { return .error(403, "wrong key") }
        let rest = PyURL.urlencode(PyURL.parseQSL(request.query).filter { $0.0 != "key" })
        let location = (request.path.isEmpty ? "/" : request.path) + (rest.isEmpty ? "" : "?\(rest)")
        return Response(status: 302, headers: [("Location", location), ("Set-Cookie", Auth.setCookie(port: port, key: key)),
                                               ("Content-Length", "0"), ("Cache-Control", "no-store")], body: Data())
    }
}
