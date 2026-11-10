// One request as the routes see it (BaseHTTPRequestHandler's `command`, `path`, `headers`, the
// body): the target as sent (never unquoted: routes match it as Python's `re.fullmatch` does),
// `urlparse`'s path and query, and Python's `parse_qs`/`parse_qsl`/`urlencode`.
import Foundation
import PalaverCore
import PalaverDomain

public struct Request {
    public let method: String
    /// `self.path`: the request target as sent.
    public let target: String
    /// `urlparse(self.path).path`, still quoted.
    public let path: String
    /// `urlparse(self.path).query`.
    public let query: String
    /// Names as sent; `header(_:)` looks them up as `email.message` does (any case, the first one).
    public let headers: [(String, String)]
    /// A JSON route's body (`{}` when empty); `.null` for a file route.
    public let json: JSONValue
    /// A file route's body, streamed to a temporary file (removed after the route ran).
    public let bodyFile: URL?

    public init(method: String, target: String, headers: [(String, String)] = [], json: JSONValue = .object([]),
                bodyFile: URL? = nil) {
        self.method = method
        self.target = target
        let parts = PyURL.split(target)
        path = parts.path
        query = parts.query
        self.headers = headers
        self.json = json
        self.bodyFile = bodyFile
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    /// `parse_qs(url.query)`: each name's values, blank ones left out.
    public var queryValues: PyDict<[String]> { PyURL.parseQS(query) }

    /// The first value of `name` (`query.get(name, [default])[0]`).
    public func queryValue(_ name: String) -> String? { queryValues[name]?.first }
}

/// The parts of `urllib.parse` the server uses.
public enum PyURL {
    /// `urlparse(target)`'s path and query for a request target: the fragment and query split off,
    /// then `;params` after the last `/` (`_splitparams`).
    public static func split(_ target: String) -> (path: String, query: String) {
        var rest = Substring(target)
        if rest.hasPrefix("//") {  // a netloc: up to the next / ? #
            let after = rest.dropFirst(2)
            rest = after[(after.firstIndex { "/?#".contains($0) } ?? after.endIndex)...]
        }
        if let h = rest.firstIndex(of: "#") { rest = rest[..<h] }
        var query = Substring("")
        if let q = rest.firstIndex(of: "?") {
            query = rest[rest.index(after: q)...]
            rest = rest[..<q]
        }
        var path = rest
        let lastSlash = path.lastIndex(of: "/") ?? path.startIndex
        if let semi = path[lastSlash...].firstIndex(of: ";") { path = path[..<semi] }
        return (String(path), String(query))
    }

    /// `parse_qsl(query)` (keep_blank_values=False): `&`-separated, `+` is a space, unquoted.
    public static func parseQSL(_ query: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let value = pair[pair.index(after: eq)...]
            guard !value.isEmpty else { continue }
            out.append((unquotePlus(String(pair[..<eq])), unquotePlus(String(value))))
        }
        return out
    }

    /// `parse_qs(query)`.
    public static func parseQS(_ query: String) -> PyDict<[String]> {
        var d = PyDict<[String]>()
        for (k, v) in parseQSL(query) { d[k] = (d[k] ?? []) + [v] }
        return d
    }

    /// `unquote(s.replace("+", " "))`: UTF-8, a bad sequence becomes U+FFFD (`errors="replace"`).
    public static func unquotePlus(_ s: String) -> String { unquote(s.replacingOccurrences(of: "+", with: " ")) }

    public static func unquote(_ s: String) -> String {
        guard s.contains("%") else { return s }
        var bytes: [UInt8] = []
        let u = Array(s.utf8)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x41...0x46: return b - 0x41 + 10
            case 0x61...0x66: return b - 0x61 + 10
            default: return nil
            }
        }
        while i < u.count {
            if u[i] == 0x25, i + 2 < u.count, let a = hex(u[i + 1]), let b = hex(u[i + 2]) {
                bytes.append(a << 4 | b)
                i += 3
            } else {
                bytes.append(u[i])
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `quote_plus(s)` (safe=""): letters, digits and `_.-~` stay, a space is `+`, the rest `%XX` of UTF-8.
    public static func quotePlus(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x5F, 0x2E, 0x2D, 0x7E: out.unicodeScalars.append(Unicode.Scalar(b))
            case 0x20: out += "+"
            default: out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// `urlencode(pairs)`.
    public static func urlencode(_ pairs: [(String, String)]) -> String {
        pairs.map { quotePlus($0.0) + "=" + quotePlus($0.1) }.joined(separator: "&")
    }
}
