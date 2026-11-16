// Notion in the window (#34): where uploads go (Settings → Notion), a meeting's page opened in Notion, and Upload to
// Notion / Upload to Notion Again from the ⋯ menu. A changed target in config.toml leaves the meetings uploaded before
// where they are: their notion.json says where they went, and their page says it is in the earlier target. Uploading
// one again is the user's explicit action, never done by itself.
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

public enum NotionAPI {
    static let NOT_UPLOADED = "This meeting isn't in Notion."
    static let NOT_NOTION = "Its Notion link isn't a Notion page, so it wasn't opened."
    static let KEPT_HERE = "This meeting is kept on this Mac, so it isn't uploaded to Notion."
    static let FROM_NOTION = "This meeting came from Notion: it is there already."
    static let NOT_READY = "Only a transcribed meeting can be uploaded to Notion."
    static let NOT_SET_UP = "Notion isn't set up: Settings → Notion says how."
    static let NO_TARGET = "Notion gave no link to where uploads go."

    /// Settings → Notion: `{set_up: false}` without a token, else where uploads go (or what is wrong with it).
    static func target(_ app: ServerApp) -> JSONValue {
        guard case .object(let fields)? = app.notion.target() else { return .object([("set_up", .bool(false))]) }
        return .object([("set_up", .bool(true))] + fields)
    }

    /// The meeting page's `notion`: its page and when it went there, and whether that was another page or database
    /// than uploads go to today (`elsewhere`); null when it isn't in Notion.
    static func meetingField(_ paths: RecordingPaths, now: NotionTarget?) -> JSONValue {
        guard let info = NotionSync.info(paths) else { return .null }
        return .object([("url", .string(info.url)), ("uploaded_at", .str(info.uploadedAt)), ("workspace", .str(info.workspace)),
                        ("elsewhere", .bool(info.wentElsewhere(than: now)))])
    }

    /// Only Notion's own pages are opened (https on notion.so, notion.site, app.notion.com): notion.json is a file on
    /// disk, and `open` would start whatever it named.
    static func isNotionPage(_ url: String) -> Bool {
        guard let u = URLComponents(string: url), u.scheme?.lowercased() == "https", let host = u.host?.lowercased(),
              u.user == nil, u.password == nil, u.port == nil else { return false }
        return ["notion.so", "notion.site"].contains { host == $0 || host.hasSuffix(".\($0)") } || host == "app.notion.com"
    }

    /// Open in Notion: the page the meeting was uploaded to, and only that.
    static func open(_ app: ServerApp, id: String) throws -> JSONValue {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        guard let info = NotionSync.info(paths) else { throw Refused(NOT_UPLOADED) }
        guard isNotionPage(info.url) else { throw Refused(NOT_NOTION) }
        app.openURL(info.url)
        return .object([("opened", .string(info.url))])
    }

    /// Settings' Open in Notion: the page or database uploads go to, as Notion gave its link.
    static func openTarget(_ app: ServerApp) throws -> JSONValue {
        guard let url = app.notion.target()?["url"]?.stringValue, isNotionPage(url) else { throw Refused(NO_TARGET) }
        app.openURL(url)
        return .object([("opened", .string(url))])
    }

    /// Upload to Notion (Again): the meeting goes to today's target as a new page; one uploaded before keeps its
    /// earlier page, which the user removes in Notion if it is not wanted. Not for a meeting kept on this Mac (#53),
    /// nor for one imported from Notion (#4).
    static func upload(_ app: ServerApp, id: String) throws -> JSONValue {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        guard !LocalOnly.isLocalOnly(paths.folder) else { throw Refused(KEPT_HERE) }
        // A Notion AI meeting note imported as a meeting (#4) would come back as a second copy.
        guard LegacyImport.brief(paths)?["kind"]?.stringValue != LegacyImport.NOTION else { throw Refused(FROM_NOTION) }
        guard MeetingsAPI.state(paths) == "ready" else { throw Refused(NOT_READY) }
        guard let now = app.notion.configured() else { throw Refused(NOT_SET_UP) }
        do {
            _ = try app.notion.upload(paths)
        } catch let e as NotionError {
            throw BadGateway(e.description)
        } catch let e where e is Conflict || e is Unavailable || e is Refused {
            throw e
        } catch {
            // Notion could not be reached, or took too long: what happened, never the token (it is not in it).
            throw BadGateway(HTTPClient.redactedDescription(error, key: nil))
        }
        return .object([("notion", meetingField(paths, now: now))])
    }
}

extension Router {
    static func addNotionRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/notion") { _, _ in .json(NotionAPI.target(app)) }
        r.post("/api/notion/open") { _, _ in .json(try NotionAPI.openTarget(app)) }
        r.post("/api/meetings/([^/]+)/notion/open") { _, m in .json(try NotionAPI.open(app, id: m.group(1)!)) }
        r.post("/api/meetings/([^/]+)/notion/upload") { _, m in .json(try NotionAPI.upload(app, id: m.group(1)!)) }
    }
}
