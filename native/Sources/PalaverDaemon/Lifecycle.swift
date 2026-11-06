// The words for why Palaver records and why a recording stopped (palaver/lifecycle.py), as far as
// the daemon writes them into daemon.json (`why_text`, `warnings`, `hints`, `last_stop.text`).
import Foundation
import PalaverCapture

public enum Lifecycle {
    public static let stopReasons = [
        "by_you": "Stopped by you",
        "restart": "Palaver restarted",
        "auto_off": "Automatic recording turned off",
        "max_length": "Reached the maximum length",
        "silence": "Silent on this Mac for 30 minutes",  // a call taken on another device (#7)
    ]

    static func khz(_ rate: Double) -> String { String(format: "%g kHz", rate / 1000) }

    /// "mic AirPods (24 kHz)", or as much of it as is known.
    static func mic(_ mic: JSONValue?) -> String? {
        let device = mic?["device"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let rate = mic?["rate"]?.doubleValue.flatMap { $0 == 0 ? nil : $0 }
        if let device, let rate { return "mic \(device) (\(khz(rate)))" }
        if let device { return "mic \(device)" }
        if let rate { return "mic \(khz(rate))" }
        return nil
    }

    /// "output AirPods (24 kHz)": the device system audio is recorded from, once its name is known.
    static func output(_ system: JSONValue?) -> String? {
        guard let device = system?["device"]?.stringValue, !device.isEmpty else { return nil }
        if let rate = system?["rate"]?.doubleValue, rate != 0 { return "output \(device) (\(khz(rate)))" }
        return "output \(device)"
    }

    /// "Recording · Teams call since 12:06 · mic AirPods (24 kHz) · output AirPods (24 kHz)".
    public static func recordingText(_ why: JSONValue, timeZone: TimeZone) -> String {
        let trigger = why["trigger"]?.stringValue ?? ""
        let sinceText = why["since"]?.stringValue
        let since = WallTime.parse(sinceText, timeZone).map { date -> String in
            // In the offset the time was written with, as Python's fromisoformat keeps it.
            WallTime.hm(date, offsetZone(sinceText) ?? timeZone)
        } ?? ""
        var what = callNames[trigger].map { "\($0) since \(since)" } ?? "started by you at \(since)"
        if why["restarts"]?.truthy == true { what += ", continued after a Palaver restart" }
        return ["Recording", what, mic(why["mic"]), output(why["system"])].compactMap { $0 }.joined(separator: " · ")
    }

    static func offsetZone(_ iso: String?) -> TimeZone? {
        guard let iso, iso.count >= 6 else { return nil }
        let tail = iso.suffix(6)
        guard tail.first == "+" || tail.first == "-", tail.dropFirst(3).first == ":",
              let h = Int(tail.dropFirst().prefix(2)), let m = Int(tail.suffix(2)) else { return nil }
        return TimeZone(secondsFromGMT: (h * 3600 + m * 60) * (tail.first == "-" ? -1 : 1))
    }

    public static func stoppedText(trigger: String?, reason: String?) -> String? {
        if reason == "call_ended" { return "\(callNames[trigger ?? ""] ?? "Call") ended" }
        return stopReasons[reason ?? ""]
    }

    public static func problemWarning(kind: String, track: String) -> String {
        ProblemWords.warning(kind: kind, track: track)
    }

    /// The running recording's open audio problems, in words.
    public static func recordingWarnings(_ why: JSONValue?) -> [String] {
        (why?["problems"]?.arrayValue ?? []).map {
            problemWarning(kind: $0["kind"]?.stringValue ?? "", track: $0["track"]?.stringValue ?? "")
        }
    }

    static let hintWords = ["silent": "Your mic sends nothing — muted?"]

    /// Soft hints about the running recording ("Your mic sends nothing — muted?").
    public static func recordingHints(_ why: JSONValue?) -> [String] {
        (why?["hints"]?.arrayValue ?? []).compactMap { hintWords[$0["kind"]?.stringValue ?? ""] }
    }

    // MARK: - the rest of lifecycle.py: recordings afterwards (meeting page, doctor, report)

    /// "12:06" for an ISO time, in the offset it was written with (else `timeZone`), as Python's `_hm` keeps it.
    static func hm(_ iso: String?, _ timeZone: TimeZone) -> String {
        guard let date = WallTime.parse(iso, timeZone) else { return "" }
        return WallTime.hm(date, offsetZone(iso) ?? timeZone)
    }

    /// "12:13:05" for `start` plus `seconds`, in `timeZone`.
    private static func hms(_ start: Date, plus seconds: Double, _ timeZone: TimeZone) -> String {
        let date = start.addingTimeInterval(Double(Int(seconds)))
        let c = WallTime.calendar(timeZone, at: date).dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour!, c.minute!, c.second!)
    }

    static let gapWhy = ["restart": "Palaver restarted"]

    /// "Recording paused 12:13:05–12:13:14 (Palaver restarted)".
    public static func gapText(_ gap: JSONValue, start: Date, timeZone: TimeZone) -> String {
        let zone = timeZone
        let from = hms(start, plus: gap["start"]?.doubleValue ?? 0, zone)
        let to = hms(start, plus: gap["end"]?.doubleValue ?? 0, zone)
        let why = gapWhy[gap["why"]?.stringValue ?? ""]
        return "Recording paused \(from)–\(to)" + (why.map { " (\($0))" } ?? "")
    }

    static func times(_ n: Int) -> String {
        switch n { case 1: return ""; case 2: return " twice"; default: return " \(n) times" }
    }

    /// How a finished recording started and stopped: "Teams call detected 12:06 · Teams call ended 13:02 ·
    /// Palaver restarted — continued". `continued`: a part cut by a restart whose continuation is not
    /// joined on yet. nil for recordings from before this was kept.
    public static func recordedText(_ meta: JSONValue, continued: Bool = false, timeZone: TimeZone) -> String? {
        let trigger = meta["trigger"]?.stringValue, reason = meta["stop_reason"]?.stringValue
        if trigger == nil && reason == nil { return nil }
        var parts: [String] = []
        if let trigger, let name = callNames[trigger] {
            parts.append("\(name) detected \(hm(meta["start_time"]?.stringValue, timeZone))")
        } else if trigger == "manual" {
            parts.append("Started by you \(hm(meta["start_time"]?.stringValue, timeZone))")
        }
        if let stopped = stoppedText(trigger: trigger, reason: reason) {
            if let end = meta["end_time"], end.truthy { parts.append("\(stopped) \(hm(end.stringValue, timeZone))") } else { parts.append(stopped) }
            if reason == "restart" && continued { parts[parts.count - 1] += " — continued" }
        }
        let restarts = (meta["gaps"]?.arrayValue ?? []).filter { $0["why"]?.stringValue == "restart" }.count
        if restarts > 0 { parts.append("Palaver restarted\(times(restarts)) — continued") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Audio problem at 12:14 (system audio played at the wrong speed)": at the wall-clock time taken when
    /// it happened, else `start` plus its offset.
    public static func problemText(_ problem: JSONValue, start: Date, timeZone: TimeZone) -> String {
        let at = problem["at"]?.stringValue
        let clock: String
        if let at, WallTime.parse(at, timeZone) != nil {
            clock = hm(at, timeZone)
        } else {
            let offset = Int(problem["start"]?.doubleValue ?? 0)
            clock = WallTime.hm(start.addingTimeInterval(Double(offset)), timeZone)
        }
        let what = ProblemWords.happened(kind: problem["kind"]?.stringValue ?? "", track: problem["track"]?.stringValue ?? "")
        return "Audio problem at \(clock)" + (what.map { " (\($0))" } ?? "")
    }
}
