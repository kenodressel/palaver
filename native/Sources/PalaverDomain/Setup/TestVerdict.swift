// A check as `palaver doctor` and the setup assistant show it (doctor.py `Check`), and the test recording's verdict
// (onboarding.py `SPEECH_DB`, `QUIET_DB`, `_heard`, `test_verdict`). Here, below the server, so the worker's
// `test-analyze` (the setup assistant's test recording) and the window's server answer with the same words.
import PalaverCore

/// doctor.Check.
public struct SetupCheck: Equatable, Sendable {
    public var name: String
    /// ok | warn | fail
    public var status: String
    public var detail: String
    public var fix: String

    public init(_ name: String, _ status: String, _ detail: String, _ fix: String = "") {
        self.name = name; self.status = status; self.detail = detail; self.fix = fix
    }

    public var json: JSONValue {
        .object([("name", .string(name)), ("status", .string(status)), ("detail", .string(detail)), ("fix", .string(fix))])
    }
}

public enum TestVerdict {
    /// louder than this on the mic track: someone spoke
    public static let SPEECH_DB = -50.0
    /// quieter than this on the system track: nothing played
    public static let QUIET_DB = -60.0
    /// What to do when a track was not recorded (onboarding `_FIXES[...]["denied"]`).
    public static let MIC_DENIED = "System Settings → Privacy & Security → Microphone → allow Palaver"
    public static let SYSTEM_AUDIO_DENIED = "System Settings → Privacy & Security → Screen & System Audio Recording → "
        + "under System Audio Recording Only, allow Palaver"

    /// `test_verdict`: what the test recording found on each track. `result`: {"mic": {...}, "system": {...}}, as
    /// `test-analyze` (Python's `onboarding._analyze`) writes it.
    public static func checks(_ result: PyDict<JSONValue>) -> [SetupCheck] {
        func track(_ key: String) -> PyDict<JSONValue> {
            guard let v = result[key], v.truthy, let d = PyDict<JSONValue>(v) else { return PyDict() }
            return d
        }
        let mic = track("mic"), system = track("system")
        let micCheck: SetupCheck
        if !(mic["recorded"]?.truthy ?? false) {
            micCheck = SetupCheck("Microphone", "fail", "nothing was recorded", MIC_DENIED)
        } else if (mic["level_db"].flatMap { $0.truthy ? number($0) : nil } ?? -120.0) > SPEECH_DB
                    || (mic["text"]?.truthy ?? false) {
            micCheck = heard(mic)
        } else {
            micCheck = SetupCheck("Microphone", "warn", "the microphone track is silent",
                                  "check the input device in System Settings → Sound → Input, then try again")
        }
        let sysCheck: SetupCheck
        if !(system["recorded"]?.truthy ?? false) {
            sysCheck = SetupCheck("System audio", "fail", "not recorded", SYSTEM_AUDIO_DENIED)
        } else if system["level_db"] == nil || system["level_db"] == .null || (number(system["level_db"]) ?? 0) < QUIET_DB {
            sysCheck = SetupCheck("System audio", "ok", "recorded; quiet, as nothing played")
        } else {
            sysCheck = SetupCheck("System audio", "ok", "recorded, with sound from other apps")
        }
        return [micCheck, sysCheck]
    }

    private static func heard(_ mic: PyDict<JSONValue>) -> SetupCheck {
        let text = Py.strip(mic["text"].flatMap { $0.truthy ? ($0.stringValue ?? Py.str($0)) : nil } ?? "")
        let how = mic["transcript"]?.stringValue
        if !text.isEmpty { return SetupCheck("Microphone", "ok", "heard you: “\(text)”") }
        if let how, Py.same(how, "not_downloaded") {
            return SetupCheck("Microphone", "ok",
                              "heard you (levels only: the speech models are not downloaded yet, so no words)",
                              "download the speech models in the Downloads step to see the words next time")
        }
        if let how, Py.same(how, "cloud") {
            let service = mic["service"].flatMap { $0.truthy ? ($0.stringValue ?? Py.str($0)) : nil } ?? "your transcription service"
            return SetupCheck("Microphone", "ok", "heard you (levels only: \(service) "
                + "transcribes your calls, and transcription is skipped in the test)")
        }
        return SetupCheck("Microphone", "ok", "heard you")
    }

    private static func number(_ v: JSONValue?) -> Double? {
        switch v {
        case .int(let i)?: return Double(i)
        case .double(let d)?: return d
        case .bool(let b)?: return b ? 1 : 0
        default: return nil
        }
    }
}
