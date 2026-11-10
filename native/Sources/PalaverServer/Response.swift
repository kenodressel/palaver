// One answer (webapp/server.py `_send`, `_json`, `_error`): `HTTP/1.0`, the connection closed after
// it, `Server: palaver`; every body with `Content-Type`, `Content-Length` and `Cache-Control: no-store`.
import Foundation
import PalaverCore
import PalaverDomain

public struct Response {
    public var status: Int
    /// In order, after `Server` and `Date`.
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// `_send`: the body with its type, length and `Cache-Control: no-store`, then `extra`.
    public static func send(_ status: Int, _ body: Data, contentType: String, extra: [(String, String)] = []) -> Response {
        Response(status: status, headers: [("Content-Type", contentType), ("Content-Length", String(body.count)),
                                           ("Cache-Control", "no-store")] + extra, body: body)
    }

    /// `_json`: `json.dumps(value, ensure_ascii=False)`.
    public static func json(_ value: JSONValue, status: Int = 200) -> Response {
        send(status, Data(PythonJSON.dumps(value, ensureAscii: false).utf8), contentType: "application/json")
    }

    /// `_error`: `{"error": message}`.
    public static func error(_ status: Int, _ message: String) -> Response {
        json(.object([("error", .string(message))]), status: status)
    }

    /// What `error` answers (Errors.swift); nil: no answer, the page let go.
    public static func from(_ error: Error) -> Response? {
        ErrorTable.answer(error).map { json($0.body, status: $0.status) }
    }

    /// `BaseHTTPRequestHandler.send_error` for a method it has no `do_` for: its HTML page.
    static func unsupportedMethod(_ method: String) -> Response {
        let message = "Unsupported method (\(pyRepr(method)))"
        let page = """
            <!DOCTYPE HTML>
            <html lang="en">
                <head>
                    <meta charset="utf-8">
                    <title>Error response</title>
                </head>
                <body>
                    <h1>Error response</h1>
                    <p>Error code: 501</p>
                    <p>Message: \(htmlEscape(message)).</p>
                    <p>Error code explanation: 501 - Server does not support this operation.</p>
                </body>
            </html>

            """
        let body = Data(page.utf8)
        return Response(status: 501, headers: [("Connection", "close"), ("Content-Type", "text/html;charset=utf-8"),
                                               ("Content-Length", String(body.count))], body: body)
    }

    /// The reason phrases Python's `http.HTTPStatus` gives the statuses this server sends.
    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Request Entity Too Large"
        case 415: return "Unsupported Media Type"
        case 416: return "Requested Range Not Satisfiable"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return ""
        }
    }

    /// The bytes on the wire; `head`: without the body (HEAD, `_send` skips the write).
    func encoded(head: Bool, date: Date = Date()) -> Data {
        var text = "HTTP/1.0 \(status) \(Response.reason(status))\r\nServer: palaver\r\nDate: \(Response.httpDate(date))\r\n"
        for (k, v) in headers { text += "\(k): \(v)\r\n" }
        text += "\r\n"
        var out = Data(text.utf8)
        if !head { out.append(body) }
        return out
    }

    /// `email.utils.formatdate(usegmt=True)`.
    static func httpDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: date)
    }

    /// `html.escape(s, quote=False)`.
    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// `repr()` of a method name: the request line's token, so plain ASCII.
    private static func pyRepr(_ s: String) -> String { s.contains("'") && !s.contains("\"") ? "\"\(s)\"" : "'\(s)'" }
}
