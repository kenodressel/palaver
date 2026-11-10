// Claude access (#45): which MCP clients run, what they read, and whether Claude starts Palaver's server (api.py
// `mcp_status`, `mcp_reads`, `clear_mcp_log`, `restore_mcp_log`, `install_mcp`; server.py's branches for them). The
// log and the config files are read here (McpLog), as the window polls them; adding Palaver to Claude Code or Claude
// Desktop is done here too (McpSetup: `bin/palaver` with the server's CLI options, `--config`).
import Foundation
import PalaverCore
import PalaverDomain

public enum McpAPI {
    /// `mcp_status`: the running `palaver mcp` clients, the newest access log entries (newest first) and whether
    /// Claude Code and Claude Desktop start the server.
    public static func status(_ app: ServerApp) throws -> JSONValue {
        .object([("clients", .array(McpLog.clients(stores: app.stores))),
                 ("log", .array(try McpLog.read(stores: app.stores))),
                 ("registered", try McpLog.registered(stores: app.stores)),
                 ("desktop", try McpLog.desktopRegistered(stores: app.stores, app: app.claudeDesktopApp))])
    }

    /// `mcp_reads`: what MCP clients read of one meeting, newest first.
    public static func reads(_ app: ServerApp, meeting: String) throws -> JSONValue {
        .object([("reads", .array(try McpLog.read(meeting: meeting, stores: app.stores)))])
    }

    /// `clear_mcp_log`: empties the access log; `cleared`: how many calls it held, `undo`: the token for `restore`
    /// (null when it was empty).
    public static func clear(_ app: ServerApp) throws -> JSONValue {
        let cleared = try McpLog.read(limit: 1 << 30, stores: app.stores).count
        let token = try McpLog.clear(stores: app.stores)
        guard case .object(var fields) = try status(app) else { return .null }
        fields.append(("cleared", .int(cleared)))
        fields.append(("undo", .str(token)))
        return .object(fields)
    }

    /// `restore_mcp_log`: the cleared log back; `UndoGone` (404) when its undo time is over or it came back already.
    public static func restore(_ app: ServerApp, token: String) throws -> JSONValue {
        guard try McpLog.restore(token, stores: app.stores) else { throw UndoGone(token) }
        return try status(app)
    }

    /// `install_mcp`: adds the server to Claude Code (`target` "code", `claude mcp add`) or Claude Desktop ("desktop",
    /// its config file); its failure (no `claude` command, a broken Claude Desktop config) is a 500 with its text.
    public static func install(_ app: ServerApp, target: String) throws -> JSONValue {
        if target == "desktop" { try app.mcpSetup.installDesktop() } else { try app.mcpSetup.install() }
        return try status(app)
    }
}

extension Router {
    static func addMcpRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/mcp") { req, _ in
            if let meeting = req.queryValue("meeting") { return .json(try McpAPI.reads(app, meeting: meeting)) }
            return .json(try McpAPI.status(app))
        }
        r.post("/api/mcp/clear") { _, _ in .json(try McpAPI.clear(app)) }
        r.post("/api/mcp/restore") { req, _ in
            .json(try McpAPI.restore(app, token: Py.str(try PyBody.required(req.json, "token"))))
        }
        r.post("/api/mcp/install") { req, _ in
            // `str(body.get("target") or "code")`
            let given = try PyBody.get(req.json, "target")
            return .json(try McpAPI.install(app, target: given.flatMap { $0.truthy ? Py.str($0) : nil } ?? "code"))
        }
    }
}
