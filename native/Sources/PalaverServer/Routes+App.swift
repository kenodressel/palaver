// The routes that pass through to the menu bar app (inventory §3.1; server.py's GET and POST
// branches, api.py `recording_question`, `memory_status`, `live_coach`, `search_status`,
// `answer_recording_question`, `record`, `transcribe_again`, `update_status`, `update_action`,
// `uninstall_palaver`, `notifications_status`, `open_notification_settings`). Outside the app
// (`app.recording` nil) the page still shows, without the live bits, and an action says why.
import Foundation
import PalaverCore
import PalaverDomain

public enum AppAPI {
    /// api._ANSWERED: what the page gets back for an answered stop question.
    public static let ANSWERED = ["stop": "stopped", "keep": "kept"]
    public static let NOT_IN_THE_APP = "Recordings are started and stopped by the Palaver menu bar app."
    public static let NOT_TRANSCRIBED_HERE = "Recordings are transcribed by the Palaver menu bar app."
    public static let NO_LONGER_RUNNING = "This recording is no longer running."
    public static let NO_LONGER_ASKED = "This recording is no longer running, or nothing is asked about it any more."
    public static let TRANSCRIBED_ALREADY = "This meeting is transcribed already, or being transcribed."
    public static let NEEDS_CONFIRMATION = "uninstalling needs the user's confirmation"
    /// notify.SETTINGS_URL: System Settings at Palaver's notifications.
    public static let SETTINGS_URL = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.kenodressel.meeting-transcribe"

    // MARK: - the running recording (daemon.json)

    /// `{"question", "recording"}`: the open question about the running recording (#52) and why it records (#47).
    public static func recordingQuestion(_ recording: RecordingRemote?) -> JSONValue {
        guard let recording else { return .object([("question", .null), ("recording", .null)]) }
        return .object([("question", recording.question() ?? .null), ("recording", recording.recording() ?? .null)])
    }

    /// "stop" or "keep" the manual recording `meeting`.
    public static func answerRecordingQuestion(_ recording: RecordingRemote?, choice: String, meeting: String) throws -> JSONValue {
        guard let recording else { throw Refused(NOT_IN_THE_APP) }
        guard try recording.answer(choice: choice, meeting: meeting) else {
            throw Refused(choice == "stop" ? NO_LONGER_RUNNING : NO_LONGER_ASKED)
        }
        return .object([(ANSWERED[choice] ?? choice, .string(meeting))])
    }

    /// Start Recording / Stop Recording in the window (#11). Stopping a recording that has stopped already (from the
    /// menu, a moment ago) is no error: it is stopped.
    public static func record(_ app: ServerApp, action: String, meeting: String?) throws -> JSONValue {
        guard let recording = app.recording else { throw Refused(NOT_IN_THE_APP) }
        do {
            return try recording.record(action: action, meeting: meeting)
        } catch let refused as Refused {
            if action == "stop", let meeting, !meeting.isEmpty, stopped(app.outputDir, meeting) {
                return .object([("stopped", .string(meeting))])
            }
            throw refused
        }
    }

    /// `_stopped`: the meeting's recorder is done (meta.json written, no recording running into it).
    static func stopped(_ outputDir: URL, _ id: String) -> Bool {
        guard let paths = try? MeetingsAPI.meetingPaths(outputDir: outputDir, id: id) else { return false }
        return FileManager.default.fileExists(atPath: paths.meta.path) && MeetingStatus.status(paths) != "recording"
    }

    // MARK: - Transcribe Again

    /// Transcribe Again, for a meeting `palaver process` failed on or that waits for its models: the menu bar app
    /// transcribes it next. False when it does so already. A missing speech model starts downloading.
    @discardableResult
    public static func transcribeAgain(_ app: ServerApp, _ id: String) throws -> Bool {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        let state = MeetingsAPI.state(paths)
        guard state == "failed" || state == "waiting" else { throw Refused(TRANSCRIBED_ALREADY) }
        let missing = ProcessState.missingModels(transcriber: app.config.transcriber, paths: paths,
                                                 speechModelsHere: app.speechHere)
        if !missing.isEmpty {
            app.probe.fetchMissingSpeech()
            throw Refused("Waiting for \(missing.joined(separator: " and ")): not downloaded yet. "
                          + "Palaver downloads it now; the meeting is transcribed once it is done.")
        }
        guard let recording = app.recording else { throw Refused(NOT_TRANSCRIBED_HERE) }
        return try recording.transcribe(folder: paths.folder)
    }

    // MARK: - updates and uninstalling (#60): the menu bar app does both

    /// What the menu bar app's updater knows (update.json), for Settings, with whether it checks by itself.
    public static func updateStatus(_ app: ServerApp) -> JSONValue {
        var fields: [(String, JSONValue)] = [("state", .string("unsupported"))]
        if case .object(let read)? = PythonJSON.read(app.stores.updateJson), !read.isEmpty { fields = read }
        let checks = JSONValue.bool(SettingsFile.load(stores: app.stores).checkUpdates)
        if let i = fields.firstIndex(where: { $0.0.unicodeScalars.elementsEqual("check_updates".unicodeScalars) }) {
            fields[i].1 = checks
        } else {
            fields.append(("check_updates", checks))
        }
        return .object(fields)
    }

    /// "check": look for a release now; "install": download it and install it at the next idle moment.
    public static func updateAction(_ app: ServerApp, _ action: String) throws -> JSONValue {
        guard action == "check" || action == "install" else { throw Refused("no update action \(Py.repr(.string(action)))") }
        guard let recording = app.recording else { throw Refused(Remote.APP_GONE) }
        return action == "check" ? try recording.updateCheck() : try recording.updateInstall()
    }

    /// `{"confirm": true, "models": bool, "recordings": bool}`: Palaver quits and is removed; recordings only when ticked.
    public static func uninstall(_ app: ServerApp, _ body: JSONValue) throws -> JSONValue {
        guard try PyBody.get(body, "confirm") == .bool(true) else { throw Refused(NEEDS_CONFIRMATION) }
        let args = JSONValue.object([("models", .bool(try PyBody.get(body, "models") == .bool(true))),
                                     ("recordings", .bool(try PyBody.get(body, "recordings") == .bool(true)))])
        guard let recording = app.recording else { throw Refused(Remote.APP_GONE) }
        return try recording.uninstall(args)
    }

    // MARK: - notifications

    /// Whether macOS lets Palaver notify ("granted", "denied", "not_asked", "unknown" outside the app), as the app's
    /// launcher last wrote it to `$PALAVER_NOTIFY_STATE` (notify.permission, onboarding.notifications_permission).
    public static func notificationsStatus(_ app: ServerApp) -> JSONValue {
        SetupPermissions.notifications(statePath: app.notifyState)
    }

    /// System Settings at Accessibility, where Palaver is allowed to read Teams' mic button (respect_call_mute).
    public static let ACCESSIBILITY_URL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    /// Whether the app may use Accessibility: "allowed", "denied", or "unknown" (outside the app).
    public static func accessibilityStatus(_ app: ServerApp) -> JSONValue {
        .object([("state", .string(AccessibilityStateFile.read(app.accessibilityState)))])
    }

    /// System Settings at Accessibility; then the state as GET answers it.
    public static func openAccessibilitySettings(_ app: ServerApp) -> JSONValue {
        app.openURL(ACCESSIBILITY_URL)
        return accessibilityStatus(app)
    }

    /// System Settings at Palaver's notifications; then the state as GET answers it.
    public static func openNotificationSettings(_ app: ServerApp) -> JSONValue {
        app.openURL(SETTINGS_URL)
        return notificationsStatus(app)
    }
}

/// A request body as Python's handler reads it: `body[key]` and `body.get(key)` on whatever JSON came.
enum PyBody {
    /// What Python raises reading a key of a body that is no object: a 500 with its text.
    struct TypeError: Error, CustomStringConvertible {
        let description: String
    }

    static func typeName(_ v: JSONValue) -> String {
        switch v {
        case .null: return "NoneType"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "float"
        case .string: return "str"
        case .array: return "list"
        case .object: return "dict"
        }
    }

    /// `body.get(key)`: nil when missing.
    static func get(_ body: JSONValue, _ key: String) throws -> JSONValue? {
        guard case .object = body else { throw TypeError(description: "'\(typeName(body))' object has no attribute 'get'") }
        return body[key]
    }

    /// `body[key]`: a missing key is a KeyError (400 `bad request: 'key'`).
    static func required(_ body: JSONValue, _ key: String) throws -> JSONValue {
        switch body {
        case .object:
            guard let v = body[key] else { throw BadRequest(Py.repr(.string(key))) }
            return v
        case .array: throw TypeError(description: "list indices must be integers or slices, not str")
        case .string: throw TypeError(description: "string indices must be integers, not 'str'")
        default: throw TypeError(description: "'\(typeName(body))' object is not subscriptable")
        }
    }
}

extension Router {
    /// The menu bar app's routes (server.py's order within GET and POST).
    static func addAppRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/recording/question") { _, _ in .json(AppAPI.recordingQuestion(app.recording)) }
        r.get("/api/recording/coach") { _, _ in .json(.object([("coach", app.recording?.coach() ?? .null)])) }
        r.get("/api/memory") { _, _ in .json(.object([("memory", app.recording?.memory() ?? .null)])) }
        r.get("/api/update") { _, _ in .json(AppAPI.updateStatus(app)) }  // #60
        r.get("/api/notifications") { _, _ in .json(AppAPI.notificationsStatus(app)) }
        r.get("/api/search/status") { _, _ in
            let status = app.recording?.indexing() ?? .object([])
            return .json(.object([("indexing", .bool(status["indexing"]?.truthy ?? false)),
                                  ("downloading", .bool(status["downloading"]?.truthy ?? false))]))
        }

        r.post("/api/meetings/([^/]+)/transcribe") { _, m in
            let id = m.group(1)!
            try AppAPI.transcribeAgain(app, id)
            return .json(try MeetingsAPI.getMeeting(app: app, id: id))
        }
        r.post("/api/recording/(start|end)") { req, m in
            var meeting: String?
            if case .object = req.json, let v = req.json["meeting"], v != .null { meeting = Py.str(v) }
            return .json(try AppAPI.record(app, action: m.group(1) == "start" ? "start" : "stop", meeting: meeting))
        }
        r.post("/api/recording/(stop|keep)") { req, m in
            let meeting = Py.str(try PyBody.required(req.json, "meeting"))
            return .json(try AppAPI.answerRecordingQuestion(app.recording, choice: m.group(1)!, meeting: meeting))
        }
        r.post("/api/update/(check|install)") { _, m in .json(try AppAPI.updateAction(app, m.group(1)!)) }
        r.post("/api/notifications/open") { _, _ in .json(AppAPI.openNotificationSettings(app)) }
        r.get("/api/accessibility") { _, _ in .json(AppAPI.accessibilityStatus(app)) }
        r.post("/api/accessibility/open") { _, _ in .json(AppAPI.openAccessibilitySettings(app)) }
        r.post("/api/uninstall") { req, _ in .json(try AppAPI.uninstall(app, req.json)) }
    }
}
