// tests/test_menubar.py's pure helpers (the menu bar's texts, layout, click routing, progress), and
// updater.menu_title / check_result / announcement as text functions.
import Foundation
import Testing
import PalaverCore
@testable import PalaverDaemon

private let utc = TimeZone(secondsFromGMT: 0)!
private let now = WallTime.parse("2026-10-20T15:00:00+00:00")!

private func ago(_ seconds: Double) -> String { WallTime.iso(now.addingTimeInterval(-seconds), utc) }

/// The daemon's status with the defaults of test_menubar.py's `_status`.
private func status(_ extra: [(String, JSONValue)] = []) -> JSONValue {
    var fields: [(String, JSONValue)] = [
        ("state", .string("idle")), ("auto", .bool(true)), ("manual", .bool(false)), ("since", .string(ago(0))),
        ("folder", .null), ("queued", .array([])), ("transcribing", .bool(false))]
    for (k, v) in extra {
        if let i = fields.firstIndex(where: { $0.0 == k }) { fields[i].1 = v } else { fields.append((k, v)) }
    }
    return .object(fields)
}

private func rec(_ extra: [(String, JSONValue)] = []) -> JSONValue { status([("state", .string("recording"))] + extra) }

private typealias Levels = [(label: String, db: Double?, silentFor: Double)]

@Suite struct MenuTextsTests {
    @Test func menuTitlePerState() {
        #expect(MenuText.title(status()) == "")  // the icon alone
        #expect(MenuText.title(rec()) == "🔴")
        #expect(MenuText.title(status([("transcribing", .bool(true))])) == "⏳")
        #expect(MenuText.title(status([("state", .string("paused"))])) == "⏸")
        #expect(MenuText.title(rec([("transcribing", .bool(true))])) == "🔴")  // recording wins
        #expect(MenuText.title(status(), error: true) == "⚠️")
        #expect(MenuText.title(status(), update: true) == "↑")  // a release to install: not only a notification
        #expect(MenuText.title(rec(), update: true) == "🔴")  // what happens now wins
    }

    @Test func startStopItemDoesWhatItSaid() {
        #expect(MenuText.manualAction(shown: MenuText.startTitle, recording: false) == .start)
        #expect(MenuText.manualAction(shown: MenuText.stopTitle, recording: true) == .stop)
        // The call ended (or one began) while the menu was open: nothing happens.
        #expect(MenuText.manualAction(shown: MenuText.stopTitle, recording: false) == nil)
        #expect(MenuText.manualAction(shown: MenuText.startTitle, recording: true) == nil)
    }

    @Test func statusLine() {
        let since = ago(12 * 60)
        #expect(MenuText.statusLine(status(), now: now) == "Waiting for a Teams call or Slack huddle")
        #expect(MenuText.statusLine(status([("state", .string("paused"))]), now: now) == "Not recording calls automatically")
        let line = MenuText.statusLine(rec([("since", .string(since)), ("folder", .string("/r/2026-10-20T14-48-00"))]), now: now)
        #expect(line.hasPrefix("Recording for 12 min"))
        #expect(line == "Recording for 12 min → 2026-10-20T14-48-00")
        #expect(MenuText.statusLine(rec([("since", .string(since)), ("manual", .bool(true))]), now: now) == "Recording for 12 min (manual)")
        // Why it records, when the daemon says (issue #47).
        let why = "Recording · Teams call since 14:48 · mic AirPods (24 kHz)"
        #expect(MenuText.statusLine(rec([("since", .string(since)), ("why_text", .string(why))]), now: now) == why)
        #expect(MenuText.statusLine(status([("transcribing", .bool(true)), ("queued", .strings(["a"]))]), now: now) == "Transcribing (1 more queued)")
    }

    @Test func menuLayoutStartsStopsAndLeavesSettingsToTheWindow() {
        let layout = MenuText.layout
        #expect(layout == [MenuText.startTitle, "Keep recording", nil, "Open Meetings", "Settings…", "Report a Problem…", nil,
                           "Check for Updates…", "Quit Palaver"])
        for gone in ["Open latest transcript in Notion", "Open latest recording folder", "Open log",
                     "Record Teams calls and Slack huddles automatically", "Record Teams calls automatically",
                     "Record Slack huddles automatically", "Connect Calendar…"] {
            #expect(!layout.contains(gone))
        }
        #expect(MenuText.autoRecord.map(\.key) == ["record_teams", "record_slack"])  // the Settings page's switches
    }

    private func writeLog(_ events: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session.log")
        try events.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func processingProgressFromSessionLog() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)/missing.log")
        #expect(MenuText.processingProgress(missing) == MenuText.Progress(step: 0, total: 7, label: "Starting"))
        var log = try writeLog([#"{"event": "record_stop"}"#, #"{"event": "process_start"}"#,
                                #"{"event": "aec_start"}"#, #"{"event": "aec_done"}"#,
                                #"{"event": "transcribe_start", "track": "system"}"#,
                                #"{"event": "transcribe_done", "track": "system"}"#,
                                #"{"event": "transcribe_start", "track": "mic"}"#])
        #expect(MenuText.processingProgress(log) == MenuText.Progress(step: 3, total: 7, label: "Transcribing your microphone"))
        log = try writeLog([#"{"event": "process_start"}"#, #"{"event": "diarize_start"}"#])
        #expect(MenuText.processingProgress(log) == MenuText.Progress(step: 4, total: 7, label: "Identifying speakers"))
        log = try writeLog([#"{"event": "process_done", "rc": 0}"#, #"{"event": "notion_upload_start"}"#])
        #expect(MenuText.processingProgress(log) == MenuText.Progress(step: 7, total: 7, label: "Uploading to Notion"))
        // The other steps, and lines that are not JSON or carry another track.
        log = try writeLog(["not json", #"{"event": "aec_start"}"#])
        #expect(MenuText.processingProgress(log).step == 1)
        log = try writeLog([#"{"event": "transcribe_start", "track": "system"}"#])
        #expect(MenuText.processingProgress(log) == MenuText.Progress(step: 2, total: 7, label: "Transcribing the other side"))
        log = try writeLog([#"{"event": "merge_done"}"#])
        #expect(MenuText.processingProgress(log) == MenuText.Progress(step: 5, total: 7, label: "Writing the transcript"))
        log = try writeLog([#"{"event": "notes_start"}"#])
        #expect(MenuText.processingProgress(log) == MenuText.Progress(step: 6, total: 7, label: "Writing notes"))
    }

    @Test func processingProgressReadsOnlyTheTailOfALongLog() throws {
        let filler = String(repeating: "x", count: 300)
        let lines = [#"{"event": "aec_start"}"#] + Array(repeating: #"{"message": "\#(filler)"}"#, count: 2000)
            + [#"{"event": "diarize_start"}"#]
        #expect(MenuText.processingProgress(try writeLog(lines)).step == 4)
    }

    @Test func aProgressEventBeforeALongStretchOfOtherLinesIsStillFound() throws {
        let filler = String(repeating: "x", count: 300)
        let lines = [#"{"event": "transcribe_start", "track": "mic"}"#] + Array(repeating: #"{"message": "\#(filler)"}"#, count: 2000)
        #expect(MenuText.processingProgress(try writeLog(lines)) == MenuText.Progress(step: 3, total: 7, label: "Transcribing your microphone"))
    }

    @Test func titleShowsElapsedTimeAndProgress() {
        #expect(MenuText.title(rec([("since", .string(ago(12 * 60 + 34)))]), now: now) == "🔴 12:34")
        #expect(MenuText.title(rec([("since", .string(ago(3600 + 2 * 60 + 3)))]), now: now) == "🔴 1:02:03")
        #expect(MenuText.title(status([("transcribing", .bool(true))]),
                               now: now, progress: MenuText.Progress(step: 3, total: 7, label: "x")) == "⏳ 3/7")
        // No step known yet: no counter.
        #expect(MenuText.title(status([("transcribing", .bool(true))]),
                               now: now, progress: MenuText.Progress(step: 0, total: 7, label: "Starting")) == "⏳")
    }

    @Test func recordingLines() {
        let lines = MenuText.recordingLines(
            rec([("since", .string(ago(300))), ("folder", .string("/r/2026-10-20T14-55-00")),
                 ("system_source", .string("process-tap")), ("teams_active", .bool(true))]),
            levels: [("mic", -24.0, 0.0), ("system", nil, 12.0)], now: now)
        // The status item above says why it records; the clock is in the menu bar.
        #expect(lines[0].hasPrefix("Mic") && lines[0].contains("-24 dB"))
        #expect(lines[1].hasPrefix("System") && lines[1].contains("silent 12 s"))
        #expect(lines[2] == "System audio via Process Tap · Call active")
        let withRate = MenuText.recordingLines(
            rec([("since", .string(ago(300))), ("system_source", .string("process-tap")), ("teams_active", .bool(true)),
                 ("why", .object([("system", .object([("rate", .double(48000)), ("source", .string("process-tap"))]))]))]),
            levels: [], now: now)
        #expect(withRate.last == "System audio via Process Tap (48 kHz) · Call active")
        // The columns line up: a label padded to 7, then the bar, then the level.
        #expect(lines[0] == "Mic     " + levelBarFor(-24) + " -24 dB")
        #expect(lines[1] == "System  " + levelBarFor(nil) + " -- dB (silent 12 s)")
    }

    private func levelBarFor(_ db: Double?) -> String { MenuText.bar(db) }

    @Test func recordingLinesWarnAboutAMissingTrack() {
        let lines = MenuText.recordingLines(
            rec([("since", .string(ago(60))), ("folder", .string("/r/x")), ("system_source", .string("process-tap")),
                 ("mic_source", .string("avcapture")), ("teams_active", .bool(true)), ("missing", .strings(["system audio"]))]),
            levels: [("mic", -24.0, 0.0), ("system", nil, 60.0)], now: now)
        #expect(lines.contains { $0.hasPrefix("⚠ Not recording: system audio") })
        #expect(lines.contains("⚠ Not recording: system audio — see `palaver doctor`"))
    }

    @Test func titleFlagsAMissingTrack() {
        #expect(MenuText.title(rec([("since", .string(ago(120))), ("missing", .strings(["microphone"]))]), now: now) == "🔴⚠ 2:00")
    }

    @Test func startStopItemAsksWhenAManualRecordingOutlivedItsCall() {
        #expect(MenuText.manualTitle(status()) == MenuText.startTitle)
        #expect(MenuText.manualTitle(rec()) == MenuText.stopTitle)
        let asked: [(String, JSONValue)] = [("meeting", .string("m")), ("reason", .string("teams")), ("minutes", .int(10)), ("message", .string("…"))]
        #expect(MenuText.manualTitle(rec([("stop_question", .object(asked))])) == "Call ended — Stop recording")
        let silent: [(String, JSONValue)] = [("meeting", .string("m")), ("reason", .string("silence")), ("minutes", .int(30)), ("message", .string("…"))]
        #expect(MenuText.manualTitle(rec([("stop_question", .object(silent))])) == "Silent for 30 min — Stop recording")
        // Whatever it says, a click on it while recording stops.
        #expect(MenuText.manualAction(shown: "Call ended — Stop recording", recording: true) == .stop)
        #expect(MenuText.manualAction(shown: "Silent for 30 min — Stop recording", recording: false) == nil)
    }

    @Test func keepRecordingIsShownOnlyWithAnOpenStopQuestion() {
        #expect(!MenuText.keepVisible(status()))
        #expect(!MenuText.keepVisible(rec()))
        #expect(!MenuText.keepVisible(rec([("stop_question", .null)])))
        #expect(MenuText.keepVisible(rec([("stop_question", .object([("reason", .string("teams")), ("minutes", .int(10))]))])))
    }

    // --- audio problems (issue #50) ---

    private static let warning = "System audio is playing at the wrong speed; Palaver is correcting it"
    private static let hint = "Your mic sends nothing — muted?"

    @Test func recordingLinesShowAudioWarningsAndHints() throws {
        let lines = MenuText.recordingLines(
            rec([("since", .string(ago(60))), ("folder", .string("/r/x")), ("system_source", .string("process-tap")),
                 ("teams_active", .bool(true)), ("warnings", .strings([Self.warning])), ("hints", .strings([Self.hint]))]),
            levels: [("mic", -24.0, 0.0), ("system", -30.0, 0.0)], now: now)
        #expect(lines.contains("⚠ \(Self.warning)") && lines.contains(Self.hint) && !lines.contains("⚠ \(Self.hint)"))
        let w = try #require(lines.firstIndex(of: "⚠ \(Self.warning)"))
        let s = try #require(lines.firstIndex { $0.hasPrefix("System audio via") })
        let h = try #require(lines.firstIndex(of: Self.hint))
        #expect(w < s && s < h)
    }

    @Test func recordingLinesShowTwoWarningsAtMostAndNeverDropTheSourceLine() {
        let lines = MenuText.recordingLines(
            rec([("since", .string(ago(60))), ("folder", .string("/r/x")), ("system_source", .string("process-tap")),
                 ("teams_active", .bool(true)), ("missing", .strings(["microphone"])),
                 ("warnings", .strings(["a", "b", "c", "d"])), ("hints", .strings([Self.hint]))]),
            levels: [("mic", -24.0, 0.0), ("system", -30.0, 0.0)], now: now)
        #expect(lines.filter { $0.hasPrefix("⚠ ") && !$0.contains("Not recording") } == ["⚠ a", "⚠ b"])
        #expect(lines.contains("+2 more — open Palaver for all"))
        #expect(lines.contains { $0.hasPrefix("System audio via") } && lines.last == Self.hint)  // hints after it (#41)
        #expect(lines.count <= 8)  // the menu's live lines
    }

    @Test func titleFlagsAnAudioProblemButNotAHint() {
        let since = ago(120)
        #expect(MenuText.title(rec([("since", .string(since)), ("warnings", .strings([Self.warning]))]), now: now) == "🔴⚠ 2:00")
        #expect(MenuText.title(rec([("since", .string(since)), ("warnings", .array([])), ("hints", .strings([Self.hint]))]), now: now) == "🔴 2:00")
    }

    @Test func statusLineWhileTheSearchIndexIsBuilt() {
        #expect(MenuText.statusLine(status([("indexing", .bool(true)), ("index_downloading", .bool(true))]), now: now)
                == "Downloading the search model (470 MB)")
        #expect(MenuText.statusLine(status([("indexing", .bool(true))]), now: now) == "Indexing meetings for search")
        #expect(MenuText.statusLine(status([("indexing", .bool(true)), ("transcribing", .bool(true))]), now: now).hasPrefix("Transcribing"))
    }

    @Test func statusLineWithProgress() {
        let line = MenuText.statusLine(status([("transcribing", .bool(true)), ("queued", .strings(["a"]))]), now: now,
                                       progress: MenuText.Progress(step: 3, total: 7, label: "Transcribing your microphone"))
        #expect(line == "Transcribing your microphone (3/7, 1 more queued)")
    }

    @Test func theCoachInTheMenuBar() throws {
        let nudge: JSONValue = .object([("kind", .string("monologue")), ("text", .string("4-min monologue"))])
        let st = rec([("since", .string(ago(12 * 60))), ("folder", .string("/r/x")), ("system_source", .string("process-tap")),
                      ("teams_active", .bool(false)), ("warnings", .strings([Self.warning])), ("hints", .strings([Self.hint])),
                      ("talk_text", .string("You 62 % of the last 10 min")), ("nudge", nudge)])
        #expect(MenuText.title(st, now: now) == "🔴⚠ 12:00")
        let levels: Levels = [("mic", -24.0, 0.0), ("system", -30.0, 0.0)]
        let lines = MenuText.recordingLines(st, levels: levels, now: now)
        let order = [try #require(lines.firstIndex(of: "⚠ \(Self.warning)")), try #require(lines.firstIndex { $0.contains("Call ended") }),
                     try #require(lines.firstIndex(of: Self.hint)), try #require(lines.firstIndex(of: "Coach: 4-min monologue"))]
        #expect(order == order.sorted() && lines.last == "Coach: 4-min monologue")
        #expect(!lines.contains("You 62 % of the last 10 min"))  // one coach line: the nudge wins
        let noNudge = MenuText.recordingLines(with(st, "nudge", .null), levels: [("mic", -24.0, 0.0)], now: now)
        #expect(noNudge.last == "You 62 % of the last 10 min")
        let full = MenuText.recordingLines(
            with(with(with(st, "warnings", .strings(Array(repeating: Self.warning, count: 5))), "hints", .strings(Array(repeating: Self.hint, count: 3))),
                 "missing", .strings(["microphone"])), levels: levels, now: now)
        #expect(full.count <= MenuText.menuLines && !full.contains { $0.hasPrefix("Coach") })  // no room: the coach waits
    }

    private func with(_ s: JSONValue, _ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = s else { return s }
        if let i = fields.firstIndex(where: { $0.0 == key }) { fields[i].1 = value } else { fields.append((key, value)) }
        return .object(fields)
    }

    @Test func bothRecordSwitchesOffIsPaused() {
        let off = ["record_teams": false, "record_slack": false]
        #expect(MenuText.withRecordSwitches(status(), off).stringValueOf("state") == "paused")
        #expect(MenuText.title(MenuText.withRecordSwitches(status(), off)) == "⏸")
        #expect(MenuText.withRecordSwitches(status(), ["record_teams": true, "record_slack": false]).stringValueOf("state") == "idle")
        #expect(MenuText.withRecordSwitches(rec(), off).stringValueOf("state") == "recording")  // a manual one keeps running
    }

    @Test func theRecordSwitchesAreTheSettingsPages() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        var config = Config()
        config.recordSlack = false  // config.toml said no Slack
        let settings = Settings(url: file, defaults: config)
        #expect(MenuText.autoRecordStates(settings) == ["record_teams": true, "record_slack": false])
        try #"{"record_teams": false}"#.write(to: file, atomically: true, encoding: .utf8)  // switched in the window's Settings
        #expect(MenuText.autoRecordStates(settings) == ["record_teams": false, "record_slack": false])
    }

    // --- click routing (Clicker, click_action, event_action, show_menu_once) ---

    @Test func leftClickOpensRightAndCtrlShowTheMenu() {
        #expect(MenuText.clickAction(rightMouseUp: false, control: false) == .open)
        #expect(MenuText.clickAction(rightMouseUp: true, control: false) == .menu)
        #expect(MenuText.clickAction(rightMouseUp: false, control: true) == .menu)
        #expect(MenuText.clickAction(nil) == .open)  // no event: the button was triggered without one
    }

    private struct NoWindowServer: Error {}

    @Test func theMenuIsTakenOffAgainEvenWhenShowingItFails() {
        var menus: [Bool] = []
        MenuText.showMenuOnce(setMenu: { menus.append($0) }, click: {})
        #expect(menus == [true, false])
        menus = []
        #expect(throws: NoWindowServer.self) {
            try MenuText.showMenuOnce(setMenu: { menus.append($0) }, click: { throw NoWindowServer() })
        }
        #expect(menus == [true, false])
    }

    // --- the update item (updater.menu_title, check_result, announcement) ---

    private func upd(_ fields: [(String, JSONValue)]) -> JSONValue { .object(fields) }

    @Test func theUpdateItemSaysWhatACheckFinds() {
        #expect(MenuText.updateTitle(upd([("state", .string("unsupported"))])) == nil)  // a checkout: nothing to update
        #expect(MenuText.updateTitle(upd([("state", .string("checking")), ("current", .string("0.1.0"))])) == "Checking for updates…")
        #expect(MenuText.updateTitle(upd([("state", .string("up_to_date")), ("current", .string("0.1.0"))])) == "Check for Updates… (Palaver 0.1.0)")
        #expect(MenuText.updateTitle(upd([("state", .string("idle"))])) == "Check for Updates…")
        let available: JSONValue = .object([("version", .string("0.2.0")), ("download_bytes", .int(5))])
        #expect(MenuText.updateTitle(upd([("state", .string("available")), ("available", available)])) == "Update available (0.2.0)")
        #expect(MenuText.updateTitle(upd([("state", .string("installing")), ("available", available)])) == "Installing update 0.2.0…")
        #expect(MenuText.updateTitle(upd([("state", .string("failed")), ("available", available)])) == "Update 0.2.0 failed — try again")
        #expect(MenuText.updateTitle(upd([("state", .string("failed")), ("current", .string("0.1.0"))])) == "Check for Updates… (Palaver 0.1.0)")
        #expect(MenuText.updateTitle(upd([("state", .string("ready")), ("available", available), ("waiting_for", .string("recording"))]))
                == "Update 0.2.0 installs when Palaver is idle (recording)")
        #expect(MenuText.updateTitle(upd([("state", .string("ready")), ("available", available)])) == "Installing update 0.2.0…")
        let big: JSONValue = .object([("version", .string("0.2.0")), ("download_bytes", .int(200))])
        #expect(MenuText.updateTitle(upd([("state", .string("downloading")), ("available", big), ("done_bytes", .int(50))]))
                == "Downloading update 0.2.0… 25 %")
        #expect(MenuText.updateTitle(upd([("state", .string("downloading")), ("available", big), ("done_bytes", .int(200))]))
                == "Downloading update 0.2.0… 99 %")  // never 100 before it is done
        #expect(MenuText.updateTitle(upd([("state", .string("downloading")), ("available", .object([("version", .string("0.2.0"))]))]))
                == "Downloading update 0.2.0…")
    }

    @Test func theMenuBarShowsTheUpdateArrowOnlyForAnAvailableReleaseNotInstalledYet() {
        let available: JSONValue = .object([("version", .string("0.2.0"))])
        #expect(MenuText.updateArrow(upd([("state", .string("available")), ("available", available)])))
        #expect(MenuText.updateArrow(upd([("state", .string("failed")), ("available", available)])))
        #expect(!MenuText.updateArrow(upd([("state", .string("available"))])))
        #expect(!MenuText.updateArrow(upd([("state", .string("ready")), ("available", available)])))
        #expect(!MenuText.updateArrow(upd([("state", .string("up_to_date"))])))
    }

    @Test func checkResultAndAnnouncementAreTheNotificationsTexts() {
        #expect(MenuText.checkResult(upd([("state", .string("checking"))])) == nil)
        let a = MenuText.checkResult(upd([("state", .string("up_to_date")), ("current", .string("0.1.0"))]))
        #expect(a?.title == "Palaver is up to date" && a?.body == "Palaver 0.1.0 is the latest version.")
        let e = MenuText.checkResult(upd([("state", .string("idle")), ("check_error", .string("offline")), ("current", .string("0.1.0"))]))
        #expect(e?.title == "Could not check for updates" && e?.body == "offline")
        let n = MenuText.checkResult(upd([("state", .string("available")), ("available", .object([("version", .string("0.2.0"))]))]))
        #expect(n?.title == "Palaver 0.2.0 is available")
        #expect(n?.body == "Choose “Update available” in Palaver's menu to install it.")
        let ann = MenuText.announcement("0.2.0")
        #expect(ann.title == "Palaver 0.2.0 is available" && ann.body == "Click to see what's new and install it.")
    }
}

private extension JSONValue {
    func stringValueOf(_ key: String) -> String? { self[key]?.stringValue }
}
