// Which route answers (webapp/server.py do_GET, do_POST): patterns tried in the order they were
// added, each a `re.fullmatch`. A GET matches `urlparse(self.path).path`, a POST `self.path` as sent
// (query included, as server.py's POST routes do). A GET nothing matches is the page
// (`Static.serve`); a POST nothing matches is 404 `not found` (`_projects_post`'s last branch).
import Foundation
import PalaverCore
import PalaverDomain

public final class Router: @unchecked Sendable {
    public typealias Handler = (Request, PyMatch) throws -> Response

    /// A POST body that is no JSON: streamed to a temporary file (an exported meeting's zip, #58),
    /// with its own type and texts (server.py `_import`).
    public struct FileBody {
        public let contentType: String
        public let wrongType: String
        public let tooLarge: String
        public let missing: String
        /// Its Content-Length must be above 0 and at most this.
        public let limit: Int

        public init(contentType: String, wrongType: String, tooLarge: String, missing: String, limit: Int) {
            self.limit = limit
            self.contentType = contentType
            self.wrongType = wrongType
            self.tooLarge = tooLarge
            self.missing = missing
        }
    }

    struct Route {
        let pattern: PyRegex
        let file: FileBody?
        let handler: Handler
    }

    private(set) var gets: [Route] = []
    private(set) var posts: [Route] = []

    public init() {}

    public func get(_ pattern: String, _ handler: @escaping Handler) {
        gets.append(Route(pattern: try! PyRegex(pattern), file: nil, handler: handler))
    }

    public func post(_ pattern: String, file: FileBody? = nil, _ handler: @escaping Handler) {
        posts.append(Route(pattern: try! PyRegex(pattern), file: file, handler: handler))
    }

    /// The first route of `routes` whose pattern matches all of `text`.
    func find(_ routes: [Route], _ text: String) -> (Route, PyMatch)? {
        for r in routes { if let m = r.pattern.fullMatch(text) { return (r, m) } }
        return nil
    }

    /// The file route a POST to `target` goes to; nil: a JSON body.
    func fileBody(forPost target: String) -> FileBody? { find(posts, target)?.0.file }

    func answer(_ request: Request, staticDir: URL) throws -> Response {
        if request.method == "POST" {
            guard let (route, m) = find(posts, request.target) else { return .error(404, "not found") }
            return try route.handler(request, m)
        }
        guard let (route, m) = find(gets, request.path) else { return Static.serve(request.path, staticDir: staticDir) }
        return try route.handler(request, m)
    }

    // MARK: - the body limits (server.py:64-78)

    /// A note's pasted image (base64) may be large; nothing else is.
    public static let MAX_IMAGE_BODY = 35 * 1024 * 1024
    public static let MAX_BODY = 2 * 1024 * 1024
    /// An exported meeting's zip to import (#58): exchange.MAX_FILE_BYTES.
    public static let MAX_IMPORT_BODY = 1400 * 1024 * 1024

    static let imagePath = try! PyRegex(#"/api/(meetings|upcoming)/[^/]+/my-notes/images"#)

    /// `_body_limit(self.path)`: a JSON body's (a file route has its own).
    public static func bodyLimit(_ target: String) -> Int {
        imagePath.fullMatch(target) != nil ? MAX_IMAGE_BODY : MAX_BODY
    }
}

extension Router {
    /// Every route of the window's server.
    public static func palaver(app: ServerApp) -> Router {
        let r = Router()
        // The page's heartbeat: "Reconnecting…" while there is no answer.
        r.get("/api/ping") { _, _ in .json(.object([("ok", .bool(true))])) }
        addMeetingRoutes(r, app: app)
        addChangeRoutes(r, app: app)
        addPeopleRoutes(r, app: app)
        addModelRoutes(r, app: app)
        addNextQuestionRoutes(r, app: app)
        addUpcomingRoutes(r, app: app)
        addProjectRoutes(r, app: app)
        addGlossaryRoutes(r, app: app)
        addReviewRoutes(r, app: app)
        addSearchRoutes(r, app: app)
        addAppRoutes(r, app: app)
        addProviderRoutes(r, app: app)
        addMyNotesRoutes(r, app: app)
        addExchangeRoutes(r, app: app)
        addSettingsRoutes(r, app: app)
        addMcpRoutes(r, app: app)
        addSetupRoutes(r, app: app)
        addMiscRoutes(r, app: app)
        return r
    }
}
