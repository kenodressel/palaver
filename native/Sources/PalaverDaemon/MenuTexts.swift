// The menu bar's words and rules (palaver/menubar.py's pure helpers, updater.menu_title/check_result/
// announcement): fed the daemon's status snapshot (the daemon.json content), the live levels and the
// update status, they return the exact strings. No AppKit: the status item in the app target only binds them.
import Foundation
import PalaverCore
import PalaverDomain
import PalaverCapture

public enum MenuText {
    public static let processSteps = 7
    /// Audio warnings shown in the menu while recording; the rest as "+N more".
    public static let menuWarnings = 2
    /// Lines the menu has for a running recording; the coach's one line only fits in what is left.
    public static let menuLines = 8

    public static let startTitle = "Start recording now"
    public static let stopTitle = "Stop recording"
    public static let keepTitle = "Keep recording"
    public static let openTitle = "Open Meetings"
    public static let updateItemTitle = "Check for Updates…"  // #60: with the version; "Update available (0.3.1)" when there is one
    public static let settingsTitle = "Settings…"  // the window's Settings: the record switches, the calendar and the rest
    public static let reportTitle = "Report a Problem…"  // #59: the window's report form
    public static let quitTitle = "Quit Palaver"

    /// Which calls start a recording: the same two switches as the window's Settings page, one item each.
    public static let autoRecord: [(key: String, title: String)] = [
        ("record_teams", "Record Teams calls automatically"),
        ("record_slack", "Record Slack huddles automatically"),
    ]

    /// The menu under the status line and the live lines, by first title (nil: a separator).
    public static let layout: [String?] = [startTitle, keepTitle, nil, openTitle, settingsTitle, reportTitle, nil, updateItemTitle, quitTitle]

    static let sources = ["process-tap": "Process Tap", "scstream": "ScreenCaptureKit"]

    public static func bar(_ db: Double?) -> String { levelBar(db) }

    // MARK: - the title next to the icon

    /// "1:02:03" or "12:34".
    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = s % 3600 / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func elapsed(_ status: JSONValue, _ now: Date) -> Double {
        guard let since = WallTime.parse(status["since"]?.stringValue) else { return 0 }
        return now.timeIntervalSince(since)
    }

    public struct Progress: Equatable {
        public var step: Int, total: Int, label: String
        public init(step: Int, total: Int, label: String) { self.step = step; self.total = total; self.label = label }
    }

    static func truthy(_ status: JSONValue, _ key: String) -> Bool { status[key]?.truthy ?? false }

    /// Menu bar text next to the icon: what is happening, if anything; `update`: a new release is there to install.
    public static func title(_ status: JSONValue, error: Bool = false, now: Date? = nil, progress: Progress? = nil,
                             update: Bool = false) -> String {
        if error { return "⚠️" }
        let state = status["state"]?.stringValue
        if state == "recording" {
            var icon = truthy(status, "missing") || truthy(status, "warnings") ? "🔴⚠" : "🔴"  // never for a hint
            if mutedIn(status) != nil { icon += "🔇" }  // the mic is not kept now (the icon gets its badge too)
            return icon + (now.map { " " + clock(elapsed(status, $0)) } ?? "")
        }
        if truthy(status, "transcribing") {
            if let progress, progress.step != 0 { return "⏳ \(progress.step)/\(progress.total)" }
            return "⏳"
        }
        if state == "paused" { return "⏸" }
        if update { return "↑" }  // a new release, until it is installed: the icon says so too, not only a notification
        return ""
    }

    // MARK: - muted in the call

    /// The call app the user is muted in while recording ("Teams"): their mic is not kept now. The menu bar
    /// icon gets a mic-slash badge, the title a 🔇, the status line says so.
    public static func mutedIn(_ status: JSONValue) -> String? {
        guard status["state"]?.stringValue == "recording", let app = status["muted"]?.stringValue else { return nil }
        return app == "slack" ? "Slack" : "Teams"
    }

    public static func mutedLine(_ app: String) -> String { "Mic muted in \(app) — not recorded" }

    /// The call app whose mute can't be followed (no Accessibility, no readable log): the mic is recorded.
    public static func muteUnfollowed(_ status: JSONValue) -> String? {
        guard status["state"]?.stringValue == "recording", let app = status["why"]?["mute_unfollowed"]?.stringValue else { return nil }
        return app == "slack" ? "Slack" : "Teams"
    }

    // MARK: - a recording, where the menu bar icon may be out of sight (#23)

    /// The notification as a recording starts: (title, message). A click on it opens the meeting.
    public static func recordingStarted(trigger: String?) -> (title: String, message: String) {
        switch trigger {
        case "teams": return ("Recording the Teams call", "Palaver records until the call ends.")
        case "slack": return ("Recording the Slack huddle", "Palaver records until the huddle ends.")
        default: return ("Recording started", "Palaver records until you stop it.")
        }
    }

    /// The window's title: "Palaver", and what records while something does.
    public static func windowTitle(_ status: JSONValue) -> String {
        guard status["state"]?.stringValue == "recording" else { return WindowPage.title }
        let what = status["why"]?["trigger"]?.stringValue.flatMap { callNames[$0] }.map { "Recording the \($0)" } ?? "Recording"
        return "\(WindowPage.title) — 🔴 \(what)"
    }

    /// The Dock icon's badge (shown while the window is open, as is the icon): "REC" while recording.
    public static func dockBadge(_ status: JSONValue) -> String? {
        status["state"]?.stringValue == "recording" ? "REC" : nil
    }

    // MARK: - the start/stop item

    /// The start/stop item: it asks to stop when a manual recording ran on after its call ended or went silent (#52).
    public static func manualTitle(_ status: JSONValue) -> String {
        guard status["state"]?.stringValue == "recording" else { return startTitle }
        guard let q = status["stop_question"], q.truthy else { return stopTitle }
        if q["reason"]?.stringValue == "silence" {
            let minutes = q["minutes"].map { $0.doubleValue.map { String(Int($0)) } ?? $0.description } ?? ""
            return "Silent for \(minutes) min — \(stopTitle)"
        }
        return "Call ended — \(stopTitle)"
    }

    public enum ManualAction: Equatable { case start, stop }

    /// What a click on the start/stop item does: what it said. A call that ended while the menu was open
    /// makes "Stop recording" do nothing, not start a new recording.
    public static func manualAction(shown: String, recording: Bool) -> ManualAction? {
        if shown != startTitle { return recording ? .stop : nil }  // one of the stop titles
        return recording ? nil : .start
    }

    /// "Keep recording" is shown only while the daemon has an open stop question.
    public static func keepVisible(_ status: JSONValue) -> Bool { status["stop_question"]?.truthy ?? false }

    // MARK: - the status line and the live lines

    public static func statusLine(_ status: JSONValue, now: Date, progress: Progress? = nil) -> String {
        let state = status["state"]?.stringValue
        if state == "recording" {
            if let app = mutedIn(status) { return mutedLine(app) }  // what matters most while it lasts
            if let why = status["why_text"]?.stringValue, !why.isEmpty { return why }  // "Recording · Teams call since 12:06 · mic AirPods (24 kHz)" (#47)
            let minutes = Int((elapsed(status, now) / 60).rounded(.down))
            let folder = status["folder"]?.stringValue ?? ""
            let name = folder.isEmpty ? "" : URL(fileURLWithPath: folder).lastPathComponent
            let how = truthy(status, "manual") ? " (manual)" : ""
            var line = "Recording for \(minutes) min\(how) → \(name)"
            while let last = line.last, last == " " || last == "→" { line.removeLast() }  // .rstrip(" →")
            return line
        }
        if truthy(status, "transcribing") {
            let queued = status["queued"]?.arrayValue?.count ?? 0
            var details = progress.flatMap { $0.step != 0 ? ["\($0.step)/\($0.total)"] : nil } ?? []
            if queued > 0 { details.append("\(queued) more queued") }
            let label = progress.flatMap { $0.step != 0 ? $0.label : nil } ?? "Transcribing"
            return label + (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))")
        }
        if truthy(status, "indexing") {  // #46, in the background when nothing else runs
            return truthy(status, "index_downloading") ? "Downloading the search model (470 MB)" : "Indexing meetings for search"
        }
        if state == "paused" { return "Not recording calls automatically" }
        return "Waiting for a Teams call or Slack huddle"
    }

    /// Live details shown in the menu while recording, under the status item that says why it records.
    public static func recordingLines(_ status: JSONValue, levels: [(label: String, db: Double?, silentFor: Double)],
                                      now: Date) -> [String] {
        var lines: [String] = []
        for (label, db, silentFor) in levels {
            let level = db.map { String(format: "%.0f dB", $0) } ?? "-- dB"
            let name = label.prefix(1).uppercased() + label.dropFirst().lowercased()  // str.capitalize()
            var line = name.padding(toLength: max(7, name.count), withPad: " ", startingAt: 0) + " \(levelBar(db)) \(level)"
            if silentFor >= 5 { line += String(format: " (silent %.0f s)", silentFor) }
            lines.append(line)
        }
        if let missing = status["missing"], missing.truthy {
            let names = (missing.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
            lines.append("⚠ Not recording: \(names) — see `palaver doctor`")
        }
        let warnings = (status["warnings"]?.arrayValue ?? []).compactMap(\.stringValue)  // issue #50: two at most, the window has them all
        lines += warnings.prefix(menuWarnings).map { "⚠ \($0)" }
        if warnings.count > menuWarnings { lines.append("+\(warnings.count - menuWarnings) more — open Palaver for all") }
        if let app = muteUnfollowed(status) {
            lines.append("⚠ Can't see whether you're muted in \(app): your mic is recorded (allow Accessibility in Settings)")
        }
        var source = sources[status["system_source"]?.stringValue ?? ""] ?? "unknown"
        if let rate = status["why"]?["system"]?["rate"]?.doubleValue, rate != 0 { source += " (\(Lifecycle.khz(rate)))" }
        let trigger = truthy(status, "manual") ? "manual recording" : (truthy(status, "teams_active") ? "Call active" : "Call ended — stopping soon")
        lines.append("System audio via \(source) · \(trigger)")
        lines += (status["hints"]?.arrayValue ?? []).compactMap(\.stringValue)
        // The live coach (#41): one line, last, only with room left; the nudge before the talk line.
        let nudge = status["nudge"]?["text"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let talk = status["talk_text"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if let coach = nudge.map({ "Coach: \($0)" }) ?? talk, lines.count < menuLines { lines.append(coach) }
        return Array(lines.prefix(menuLines))
    }

    // MARK: - processing progress from session.log

    /// session.log event (and track) → (step, label) of the processing pipeline.
    static let stepEvents: [String: Progress] = [
        "aec_start": Progress(step: 1, total: processSteps, label: "Removing speaker echo"),
        "transcribe_start/system": Progress(step: 2, total: processSteps, label: "Transcribing the other side"),
        "transcribe_start/mic": Progress(step: 3, total: processSteps, label: "Transcribing your microphone"),
        "diarize_start": Progress(step: 4, total: processSteps, label: "Identifying speakers"),
        "diarize_done": Progress(step: 5, total: processSteps, label: "Writing the transcript"),
        "merge_done": Progress(step: 5, total: processSteps, label: "Writing the transcript"),
        "notes_start": Progress(step: 6, total: processSteps, label: "Writing notes"),
        "process_done": Progress(step: 7, total: processSteps, label: "Uploading to Notion"),
        "notion_upload_start": Progress(step: 7, total: processSteps, label: "Uploading to Notion"),
    ]

    static let logTailBytes = 256 * 1024

    static func lastStep(in data: Data) -> Progress? {
        var found: Progress?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let row = JSONValue.parse(Data(line.utf8)), let event = row["event"]?.stringValue else { continue }
            let track = row["track"]?.stringValue
            if let hit = track.flatMap({ stepEvents["\(event)/\($0)"] }) ?? stepEvents[event] { found = hit }
        }
        return found
    }

    /// (step, total, label) of a recording's processing, from its session.log; the last 256 KiB first, the whole file when that holds no step.
    public static func processingProgress(_ sessionLog: URL) -> Progress {
        var current = Progress(step: 0, total: processSteps, label: "Starting")
        guard let handle = try? FileHandle(forReadingFrom: sessionLog) else { return current }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return current }
        let tail = UInt64(logTailBytes)
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        if let data = try? handle.readToEnd(), let hit = lastStep(in: data) { return hit }
        if size > tail {  // a long stage wrote more than the tail since its start event: the whole file, last match wins
            try? handle.seek(toOffset: 0)
            if let data = try? handle.readToEnd(), let hit = lastStep(in: data) { return hit }
        }
        return current
    }

    // MARK: - the record switches

    /// Each record switch as Settings has it now.
    public static func autoRecordStates(_ settings: Settings) -> [String: Bool] {
        ["record_teams": settings.recordTeams, "record_slack": settings.recordSlack]
    }

    /// The status as the menu shows it: with every record switch off and nothing recording, paused.
    public static func withRecordSwitches(_ status: JSONValue, _ switches: [String: Bool]) -> JSONValue {
        guard status["state"]?.stringValue == "idle", !switches.values.contains(true), case .object(var fields) = status else { return status }
        if let i = fields.firstIndex(where: { $0.0 == "state" }) { fields[i].1 = .string("paused") }
        return .object(fields)
    }

    // MARK: - clicks on the icon

    public enum ClickAction: Equatable { case open, menu }

    /// What a click on the menu bar icon does: a right click (or ctrl-click) shows the menu, any other opens the window.
    public static func clickAction(rightMouseUp: Bool, control: Bool) -> ClickAction { rightMouseUp || control ? .menu : .open }

    /// The click being handled; no event (the button was triggered without one) opens the window.
    public static func clickAction(_ event: (rightMouseUp: Bool, control: Bool)?) -> ClickAction {
        guard let event else { return .open }
        return clickAction(rightMouseUp: event.rightMouseUp, control: event.control)
    }

    /// The status item's menu for this one click, then off again even when showing it fails: else every left
    /// click would open the menu.
    public static func showMenuOnce(setMenu: (Bool) -> Void, click: () throws -> Void) rethrows {
        setMenu(true)
        defer { setMenu(false) }
        try click()
    }

    // MARK: - the update item (updater.py menu_title, check_result, announcement)

    static func version(_ status: JSONValue) -> String? { status["available"]?["version"]?.stringValue }

    /// The menu's update line, always there in an installed Palaver (with its version, so the menu says which
    /// one runs); nil from a checkout.
    public static func updateTitle(_ status: JSONValue) -> String? {
        let state = status["state"]?.stringValue
        let v = version(status) ?? ""
        switch state {
        case "unsupported": return nil
        case "checking": return "Checking for updates…"
        case "available": return "Update available (\(v))"
        case "downloading":
            let total = status["available"]?["download_bytes"]?.doubleValue ?? 0
            let done = status["done_bytes"]?.doubleValue ?? 0
            let share = total != 0 ? " \(min(99, Int(100 * done / total))) %" : ""
            return "Downloading update \(v)…\(share)"
        case "ready":
            if let waiting = status["waiting_for"]?.stringValue, !waiting.isEmpty {
                return "Update \(v) installs when Palaver is idle (\(waiting))"
            }
            return "Installing update \(v)…"
        case "installing": return "Installing update \(v)…"
        case "failed" where !v.isEmpty: return "Update \(v) failed — try again"
        default: break
        }
        if let current = status["current"]?.stringValue, !current.isEmpty { return "\(updateItemTitle) (Palaver \(current))" }
        return updateItemTitle
    }

    /// The icon's ↑: a release to install, known and not yet installed.
    public static func updateArrow(_ status: JSONValue) -> Bool {
        ["available", "failed"].contains(status["state"]?.stringValue ?? "") && status["available"]?.truthy == true
    }

    /// What a check the user asked for found, for a notification; nil while it still runs.
    public static func checkResult(_ status: JSONValue) -> (title: String, body: String)? {
        let state = status["state"]?.stringValue
        if state == "checking" { return nil }
        if let err = status["check_error"], err.truthy { return ("Could not check for updates", err.stringValue ?? err.description) }
        if state == "available" || state == "failed", let v = version(status), !v.isEmpty {
            return ("Palaver \(v) is available", "Choose “Update available” in Palaver's menu to install it.")
        }
        return ("Palaver is up to date", "Palaver \(status["current"]?.stringValue ?? "None") is the latest version.")
    }

    /// The notification an automatic check sends for a new release; a click opens the window's Settings at Updates.
    public static func announcement(_ version: String) -> (title: String, body: String) {
        ("Palaver \(version) is available", "Click to see what's new and install it.")
    }
}
