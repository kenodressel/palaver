// The page itself (webapp/server.py:37-40, :838-843): `/` and every path without a suffix are
// `index.html` (the page routes by its #route); any other path is a file under the static folder,
// resolved (symlinks too) and refused unless it stays inside. The path is the request's as sent:
// `%2F` is no slash here, as in Python.
import Darwin
import Foundation

public enum Static {
    static let contentTypes = [".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
                               ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml", ".woff2": "font/woff2"]

    /// `_static(path)`.
    public static func serve(_ path: String, staticDir: URL) -> Response {
        let name = path == "/" || path.isEmpty || suffix(path).isEmpty ? "index.html" : String(path.drop { $0 == "/" })
        guard !name.contains("\0"), let root = realPath(staticDir.path),
              let file = realPath(root + "/" + name), file.hasPrefix(root + "/"), isFile(file),
              let body = FileManager.default.contents(atPath: file) else {
            return .error(404, "not found")
        }
        return .send(200, body, contentType: contentTypes[suffix(file)] ?? "application/octet-stream")
    }

    /// `PurePosixPath(path).suffix`: of the last part (empty and `.` parts dropped), from its last
    /// dot when that dot is neither its first nor its last character.
    static func suffix(_ path: String) -> String {
        guard let last = path.split(separator: "/").last(where: { $0 != "." }) else { return "" }
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex, last.index(after: dot) != last.endIndex else { return "" }
        return String(last[dot...])
    }

    /// realpath(3); nil when the file isn't there.
    private static func realPath(_ p: String) -> String? {
        guard let r = Darwin.realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    private static func isFile(_ p: String) -> Bool {
        var st = stat()
        return stat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }
}
