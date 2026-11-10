// A meeting saved as a `.zip` for a colleague, and one taken in from theirs (#58) (api.py `export_meeting`,
// `import_meeting`; server.py's `/export` branch and `_import`). The import's transport (application/octet-stream, at
// most `MAX_IMPORT_BODY`, streamed to `palaver-import-*/import.zip`) is the router's file route (Task 36).
import Foundation
import PalaverCore
import PalaverDomain

public enum ExchangeAPI {
    /// `export_meeting`: the meeting as a `.zip` in Downloads (the window can't download in its web view; the server
    /// is on this Mac anyway), never over an earlier one. A meeting kept on this Mac answers with a question first.
    public static func exportMeeting(_ app: ServerApp, id: String, notes: Bool = true, voices: Bool = false,
                                     audio: Bool = false, confirmLocal: Bool = false) throws -> JSONValue {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        // What an export cut short left there; not at a start (Background's sweep).
        Exchange.sweep(app.outputDir, downloads: app.downloads)
        let dest = Exchange.freeName(app.downloads, Exchange.fileName(paths))
        do {
            try Exchange.exportMeeting(paths, dest: dest, userName: app.userName, notes: notes, voices: voices, audio: audio,
                                       confirmLocal: confirmLocal, projects: Exchange.confirmedProjects(id, stores: app.stores),
                                       stores: app.stores)
        } catch is Exchange.KeptOnThisMac {
            return .object([("question", .string("local_only"))])
        } catch let e as Exchange.NotReady {
            throw Refused(e.description)
        } catch let e as ExchangeExportError where e.kind == .key || e.kind == .value {
            throw BadRequest(e.description)  // server.py's `except (KeyError, ValueError)`
        }
        var st = stat()
        guard stat(dest.path, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return .object([("saved", .string(dest.path)), ("name", .string(dest.lastPathComponent)),
                        ("folder", .string(dest.deletingLastPathComponent().lastPathComponent)), ("bytes", .int(Int(st.st_size)))])
    }

    /// `import_meeting`: an exported meeting's zip as a meeting, undone by trashing it again. The same meeting here
    /// already answers with a question (keep mine, or import as a separate meeting) and writes nothing. The meeting is
    /// built before the projects are held; placing it and what follows (`Exchange.settle`) run under them.
    public static func importMeeting(_ app: ServerApp, file: URL, separate: Bool = false) throws -> JSONValue {
        let out = app.outputDir
        let package: ExchangePackage
        let match: ExchangeMatch?
        do {
            package = try Exchange.readPackage(file)
            match = try Exchange.findMatch(out, package)
        } catch let e as ExchangeRejected {
            throw Refused("Not imported: \(e.message)")
        }
        if let match, !separate {
            let there = RecordingPaths(out.appendingPathComponent(match.id, isDirectory: true))
            let start = try MeetingsAPI.start(there, try MeetingsAPI.meta(there))
            let title = Titles.resolve(there, stores: app.stores).title.flatMap { $0.isEmpty ? nil : $0 }
                ?? Titles.fallback(start.stringValue)
            return .object([("question", .string("collision")), ("from", .string(package.sender)), ("how", .string(match.how)),
                            ("own", .bool(match.own)),
                            ("meeting", .object([("id", .string(match.id)), ("title", .string(title)), ("start", start)]))])
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)  // output_dir.mkdir(parents=True, exist_ok=True)
        let staged: ExchangeStaged
        do {  // the slow part, before the projects are held
            staged = try Exchange.stage(out, package, userName: app.userName, separate: separate, calendar: app.calendar,
                                        stores: app.stores)
        } catch let e as ExchangeRejected {
            throw Refused("Not imported: \(e.message)")
        }
        defer { staged.discard() }
        return try ChangesAPI.undoable(app, label: "import", stores: ChangesAPI.storePaths(app, "projects"), projectsLock: true) { token in
            let result = try Exchange.place(out, staged, after: { id in
                try Undo.created(out, token, [id])
                try Exchange.settle(out, id, userName: app.userName, stores: app.stores)
            })
            return .object([("imported", .string(result.id)), ("from", .string(result.sender)), ("voices", .array(result.voices)),
                            ("warnings", .strings(result.warnings)), ("beside", .str(result.matched?.id))])
        }
    }
}

extension Router {
    /// server.py's `/api/meetings/{id}/export` branch and `_import`.
    static func addExchangeRoutes(_ r: Router, app: ServerApp) {
        r.post("/api/meetings/([^/]+)/export") { req, m in
            .json(try ExchangeAPI.exportMeeting(app, id: m.group(1)!, notes: try ChangesAPI.flag(req.json, "notes", default: true),
                                                voices: try ChangesAPI.flag(req.json, "voices", default: false),
                                                audio: try ChangesAPI.flag(req.json, "audio", default: false),
                                                confirmLocal: try ChangesAPI.flag(req.json, "confirm_local", default: false)))
        }
        // An exported meeting's zip, as the bytes it is (not JSON: it may be large). A foreign page can't send this
        // type without a CORS preflight, which this server never answers. `_import` answers its own errors: a refusal
        // is 400 with its text, anything else 500 `Not imported: …` (logged).
        r.post(#"/api/import(\?.*)?"#, file: FileBody(contentType: "application/octet-stream",
                                                       wrongType: "an exported meeting's .zip only",
                                                       tooLarge: "Not imported: the file is too large.",
                                                       missing: "no file", limit: MAX_IMPORT_BODY)) { req, _ in
            guard let file = req.bodyFile else { return .error(400, "no file") }
            do {
                return .json(try ExchangeAPI.importMeeting(app, file: file, separate: req.queryValue("separate") == "1"))
            } catch let e as Refused {
                throw e
            } catch let e as ClientGone {
                throw e
            } catch {
                app.log?.message("import failed: \(error)", level: "ERROR", logger: HTTPServer.logger)
                return .error(500, "Not imported: \(error)")
            }
        }
    }
}
