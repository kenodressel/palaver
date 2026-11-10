// The permission states the setup assistant shows (palaver/onboarding.py `_microphone`, `notifications_permission`,
// `CALENDAR_SETTINGS`, `Probe.permissions`; palaver/doctor.py `check_system_audio`, `meeting_name`). Read-only: nothing
// here asks for a permission. The calendar's comes from the menu bar app (app.sock), which reads the calendar.
import AVFoundation
import Foundation
import PalaverCore
import PalaverDomain

public enum SetupPermissions {
    /// System Settings at Calendars: where the app sends the user once the calendar was refused (macOS asks only once).
    public static let CALENDAR_SETTINGS = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    /// doctor.py `_SETTINGS`.
    static let SETTINGS = "System Settings → Privacy & Security → "
    static let MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func state(_ s: String, _ detail: String) -> JSONValue { .object([("state", .string(s)), ("detail", .string(detail))]) }

    /// The microphone as AVFoundation has it for this process (never requested): `status` is
    /// `AVCaptureDevice.authorizationStatus(for: .audio).rawValue`, nil when it could not be read.
    public static func microphone(status: Int? = AVCaptureDevice.authorizationStatus(for: .audio).rawValue) -> JSONValue {
        switch status {
        case nil: return state("unknown", "could not check")
        case 0?: return state("not_asked", "not asked yet")
        case 3?: return state("granted", "allowed")
        default: return state("denied", "not allowed")
        }
    }

    /// Whether macOS lets Palaver notify, as the app's launcher last wrote it to `statePath` ($PALAVER_NOTIFY_STATE).
    public static func notifications(statePath: String?) -> JSONValue {
        var text: String?
        if let statePath, !statePath.isEmpty, let data = FileManager.default.contents(atPath: statePath),
           let s = String(data: data, encoding: .utf8) {
            text = Py.strip(s)
        }
        switch text {
        case "allowed": return state("granted", "allowed")
        case "denied": return state("denied", "not allowed")
        case "not_asked": return state("not_asked", "not asked yet")
        default: return state("unknown", "Palaver can't check this itself")
        }
    }

    /// The system audio permission: there is no preflight API for it, so it is judged by how the most recent recording
    /// (with a session.log) captured system audio (doctor.check_system_audio, as the probe words it).
    public static func systemAudio(outputDir: URL, timeZone: TimeZone = .current) -> JSONValue {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []).filter { name in
            var dir: ObjCBool = false
            let folder = outputDir.appendingPathComponent(name)
            return RecordingPaths.isRecordingFolderName(name)
                && FileManager.default.fileExists(atPath: folder.path, isDirectory: &dir) && dir.boolValue
                && FileManager.default.fileExists(atPath: folder.appendingPathComponent("session.log").path)
        }
        let sorted = Py.stableSorted(names) { Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes($1.unicodeScalars.map(\.value)) }
        for name in sorted.reversed() {
            let folder = outputDir.appendingPathComponent(name)
            let text = String(decoding: FileManager.default.contents(atPath: folder.appendingPathComponent("session.log").path) ?? Data(),
                              as: UTF8.self)
            for line in ModelJobs.splitlines(text) {
                guard let row = try? PythonJSON.parse(Data(line.utf8)), case .object = row else { continue }  // a line cut short
                guard row["event"] == .string("record_start"), let source = row["system_source"], source.truthy else { continue }
                let meeting = meetingName(folder, timeZone: timeZone)
                if source == .string("process-tap") {
                    return state("granted", "Process Tap worked in \(meeting)")
                }
                // It recorded, through ScreenCaptureKit.
                return .object([("state", .string("fallback")),
                                ("detail", .string("works with a fallback (fell back to ScreenCaptureKit in \(meeting))")),
                                ("fix", .string(SETTINGS + "Screen & System Audio Recording → under System Audio "
                                                + "Recording Only, allow Palaver / your terminal"))])
            }
        }
        return .object([("state", .string("unverified")), ("detail", .string("not verified yet")),
                        ("fix", .string("checked on the first recording"))])
    }

    /// A recording as a person reads it, not its folder id: “Weekly” on 29 Oct, 16:07, or the meeting on 29 Oct, 16:07
    /// without a title (doctor.meeting_name).
    static func meetingName(_ folder: URL, timeZone: TimeZone = .current) -> String {
        guard let when = start(folder, timeZone: timeZone) else { return folder.lastPathComponent }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.day, .month, .hour, .minute], from: when)
        // A no-break space: "29 Oct" stays on one line.
        let stamp = "\(c.day!)\u{00a0}\(MONTHS[c.month! - 1]), " + String(format: "%02d:%02d", c.hour!, c.minute!)
        let title = title(folder)
        return title.isEmpty ? "the meeting on \(stamp)" : "“\(title)” on \(stamp)"
    }

    /// The title the user gave the recording, else its calendar event's, else the one its notes gave it; "" when none.
    private static func title(_ folder: URL) -> String {
        for name in ["title.json", "calendar.json", "notes.json"] {
            guard let data = PythonJSON.read(folder.appendingPathComponent(name)), case .object = data,
                  let title = data["title"]?.stringValue else { continue }
            let stripped = Py.strip(title)
            if !stripped.isEmpty { return stripped }
        }
        return ""
    }

    /// When the recording started (meta.json), else its folder's time (local).
    private static func start(_ folder: URL, timeZone: TimeZone) -> Date? {
        if let meta = PythonJSON.read(folder.appendingPathComponent("meta.json")), let s = meta["start_time"]?.stringValue,
           let date = Py.fromIso(s, timeZone: timeZone) {
            return date
        }
        guard let stamp = RecordingPaths.recordingFolderTimestamp(folder.lastPathComponent),
              stamp.unicodeScalars.count == folder.lastPathComponent.unicodeScalars.count else { return nil }
        let n = stamp.split(whereSeparator: { $0 == "-" || $0 == "T" }).compactMap { Int($0) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        guard n.count == 6 else { return nil }
        return cal.date(from: DateComponents(year: n[0], month: n[1], day: n[2], hour: n[3], minute: n[4], second: n[5]))
    }
}
