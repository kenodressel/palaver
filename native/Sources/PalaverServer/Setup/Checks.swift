// The setup assistant's summary (`palaver doctor` in the window) and the test recording's verdict (palaver/onboarding.py
// `_PERMISSIONS`, `_PRIVACY`, `_FIXES`, `_STATUS`, `_model_check`, `_provider_check`, `summary`, `SPEECH_DB`, `QUIET_DB`,
// `_heard`, `test_verdict`; doctor.py `Check`, `check_disk`).
import PalaverCore
import PalaverDomain

// `SetupCheck` (doctor.Check) and the test recording's verdict are in PalaverDomain (Setup/TestVerdict.swift).

extension Recommendations {
    public static let PERMISSIONS = [("Microphone", "microphone"), ("System audio", "system_audio"),
                                     ("Calendar", "calendar"), ("Notifications", "notifications")]
    public static let PRIVACY = "System Settings → Privacy & Security → "
    public static let FIXES: PyDict<PyDict<String>> = PyDict([
        ("microphone", PyDict([("not_asked", "macOS asks on the first recording, or when you run the test recording"),
                               ("denied", PRIVACY + "Microphone → allow Palaver")])),
        ("system_audio", PyDict([("unverified", "checked on the first recording, or run the test recording"),
                                 ("denied", PRIVACY + "Screen & System Audio Recording → under System Audio Recording Only, "
                                     + "allow Palaver")])),
        ("calendar", PyDict([("not_asked", "Connect Calendar in Settings or in the setup assistant"),
                             ("denied", PRIVACY + "Calendars → allow Palaver (full access)")])),
        ("notifications", PyDict([("unknown", "System Settings → Notifications → Palaver: allow notifications"),
                                  ("not_asked", "macOS asks when Palaver starts; or System Settings → Notifications → Palaver"),
                                  ("denied", "System Settings → Notifications → Palaver: allow notifications")])),
    ])
    public static let STATUS: PyDict<String> = PyDict([("granted", "ok"), ("denied", "fail"), ("fallback", "warn")])

    /// louder than this on the mic track: someone spoke
    public static let SPEECH_DB = TestVerdict.SPEECH_DB
    /// quieter than this on the system track: nothing played
    public static let QUIET_DB = TestVerdict.QUIET_DB

    private static func modelCheck(_ m: ModelInfo, here: Bool) -> SetupCheck {
        if here { return SetupCheck(m.label, "ok", "downloaded (\(m.purpose))") }
        return SetupCheck(m.label, "warn", "not downloaded yet (\(m.purpose))",
                          "download it in the setup assistant (\(gb(m.diskGB))), or it downloads when first needed")
    }

    private static func providerCheck(_ name: String, _ cur: SetupCurrent, _ pid: String) -> SetupCheck {
        guard let p = cur.registry.providers[pid] else {
            return SetupCheck(name, "fail", "\(pid): not a provider", "choose again in Settings")
        }
        if p.ready { return SetupCheck(name, "ok", "\(p.label) (cloud)") }
        return SetupCheck(name, "fail", "\(p.label): \(p.problem.flatMap { $0.isEmpty ? nil : $0 } ?? "not set up")",
                          "Settings → Language model")
    }

    /// doctor.check_disk with `free_bytes` given.
    public static func checkDisk(freeBytes: Int) -> SetupCheck {
        let gigabytes = Double(freeBytes) / Double(1 << 30)
        let detail = "\(fixed(gigabytes, 0)) GB free"
        if gigabytes < 2 { return SetupCheck("Disk space", "fail", detail, "a 1 h meeting needs ~250 MB of audio; free up space") }
        if gigabytes < 10 { return SetupCheck("Disk space", "warn", detail, "`palaver prune` deletes old synced recordings") }
        return SetupCheck("Disk space", "ok", detail)
    }

    /// A permission's text field: Python reads `p.get(key)` and takes a falsy value as missing.
    private static func text(_ p: PyDict<JSONValue>, _ key: String) -> String? {
        guard let v = p[key], truthy(v) else { return nil }
        return v.stringValue ?? Py.str(v)
    }

    /// `summary`: what is set up, what is missing, and the fix for each. `permissions`: permission key → the probe's
    /// {state, detail, fix} object.
    public static func summary(_ hw: Hardware, _ permissions: PyDict<JSONValue>, _ installed: Installed,
                               _ cur: SetupCurrent) -> [SetupCheck] {
        var out: [SetupCheck] = []
        let mac = "\(hw.short), \(gb(hw.memoryGB)) of memory"
        if hw.appleSilicon {
            out.append(SetupCheck("This Mac", "ok", mac))
        } else {
            out.append(SetupCheck("This Mac", "fail", mac, "local models need Apple Silicon; choose cloud services in Settings"))
        }
        for (name, key) in PERMISSIONS {
            guard let raw = permissions[key], case .object = raw, let p = PyDict<JSONValue>(raw) else { continue }
            let state = p["state"].map { $0.stringValue ?? Py.str($0) } ?? "unknown"
            let detail = text(p, "detail") ?? state.unicodeScalars.map { $0 == "_" ? " " : String($0) }.joined()
            out.append(SetupCheck(name, STATUS[state] ?? "warn", detail, text(p, "fix") ?? FIXES[key]?[state] ?? ""))
        }
        if hw.appleSilicon {
            let tr = cur.registry.featuresOf(TRANSCRIPTION)
            let chosen = tr.first.flatMap { cur.choices[$0] } ?? LOCAL
            if !Py.same(chosen, LOCAL) { out.append(providerCheck("Transcription", cur, chosen)) }
            out.append(modelCheck(ModelCatalog.model("speech")!, here: cur.has("speech")))
        }
        let lm = cur.registry.featuresOf(LANGUAGE_MODEL)
        let chosen = cur.choices[lm.first ?? "notes"] ?? LOCAL
        if Py.same(chosen, LOCAL) {
            if let mid = ModelCatalog.notesModels[cur.localModel] {
                let m = ModelCatalog.model(mid)!
                if cur.has(mid) {
                    out.append(SetupCheck("Notes and projects", "ok", "\(m.label) on this Mac"))
                } else {
                    out.append(SetupCheck("Notes and projects", "warn", "\(m.label) on this Mac, not downloaded yet",
                                          "download it in the setup assistant (\(gb(m.diskGB)))"))
                }
            } else {
                out.append(SetupCheck("Notes and projects", "ok", "\(cur.localModel) on this Mac (set in config.toml)"))
            }
        } else if Py.same(chosen, PENDING) {
            out.append(SetupCheck("Notes and projects", "warn", "none yet: notes are off until a cloud model is set up",
                                  "Settings → Language model"))
        } else {
            out.append(providerCheck("Notes and projects", cur, chosen))
        }
        for (target, there) in [("code", installed.claudeCode), ("desktop", installed.claudeDesktop)] where there {
            let added = cur.mcp[target] ?? false
            let name = CLAUDE.first { Py.same($0.0, target) }!.1
            out.append(SetupCheck("\(name) access", added ? "ok" : "warn",
                                  added ? "can read your meetings" : "Palaver is not added yet",
                                  added ? "" : "Settings → Claude access → Add"))
        }
        // An unreadable probe (NaN, infinity) counts as no free space rather than trapping.
        out.append(checkDisk(freeBytes: (try? Py.int(hw.freeDiskGB * Double(1 << 30))) ?? 0))
        return out
    }

    // MARK: - the test recording

    /// `test_verdict`: what the test recording found on each track (`TestVerdict.checks`).
    public static func testVerdict(_ result: PyDict<JSONValue>) -> [SetupCheck] { TestVerdict.checks(result) }
}
