// `palaver doctor` (palaver/doctor.py): check the setup and say exactly what to fix. The checks live here, in the
// server's library, so the problem report, the `palaver` command and later the window show the same words.
// Everything asked of this Mac or the network goes through a `DoctorProbe` (`MacDoctorProbe` for real, fakes in the
// tests): nothing here records, plays or downloads anything.
//
// Permission checks describe the process that runs them: the terminal when run from a shell, the app when run from
// Palaver.app.
import AVFoundation
import CoreAudio
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

/// What the doctor asks of this Mac and the network.
public protocol DoctorProbe {
    /// "15.1", "26.0.1".
    func macOSVersion() -> String
    /// The status of a GET of `url` with `headers` (10 s); throws when the server is not reachable.
    func httpStatus(_ url: String, headers: [String: String]) throws -> Int
    /// The Notion token when it is only in the Keychain (config.toml's and $NOTION_TOKEN come first).
    func keychainNotionToken() -> String?
    /// The speech engine's answer to `hello`; nil when the engine is not built (no binary), throws when it does not run.
    func engineHello() throws -> JSONValue?
    /// Whether the speech models' files are all there (`ModelCatalog.speechFilesHere`).
    func speechFilesHere() -> Bool
    /// Whether this runs from an installed app (the fixes say "reinstall Palaver"), not a checkout ("make engine").
    var inBundle: Bool { get }
    /// `AVCaptureDevice.authorizationStatus(for: .audio)`'s raw value; never asks.
    func microphoneStatus() -> Int
    /// The default input and output device: (name, sample rate), nil for none.
    func defaultDevices() throws -> (input: (String, Double)?, output: (String, Double)?)
    /// The processes Core Audio knows (Teams detection).
    func audioProcesses() throws -> [AudioProcess]
    /// Whether /Applications/Microsoft Teams.app is there.
    func teamsInstalled() -> Bool
    /// Free bytes on the volume of `url`.
    func freeBytes(_ url: URL) -> Int
    /// This Mac's memory in GB.
    func ramGB() -> Double
    /// The running Palaver's memory (daemon.json's "memory"); nil when it does not run.
    func runningMemory() -> JSONValue?
}

public enum Doctor {
    static let SETTINGS = "System Settings → Privacy & Security → "
    static let MARK = ["ok": "✓", "warn": "!", "fail": "✗"]
    public static let NOTION_API = "https://api.notion.com/v1"

    // MARK: - the run

    /// doctor.run_checks: every check, in doctor.py's order. `offline`: no Notion check (`--offline`).
    public static func run(configURL: URL, stores: StorePaths = .current(),
                           env: [String: String] = ProcessInfo.processInfo.environment,
                           offline: Bool = false, probe: DoctorProbe, timeZone: TimeZone = .current) -> [SetupCheck] {
        var checks = [checkMacOS(probe.macOSVersion())]
        let (configCheck, config) = checkConfig(configURL, env: env)
        checks.append(configCheck)
        if let config {
            if !offline, let token = notionToken(configURL, env: env, probe: probe) {
                checks.append(checkNotion(token: token, mode: config.notionMode, parentPageId: config.notionParentPageId,
                                          databaseId: config.notionDatabaseId, probe: probe))
            }
            checks.append(checkSpeechModels(probe))
            let notes = ModelChoice.notesRunMemoryGB(config: config, stores: stores)
            checks.append(checkMemory(MemoryBudgets(config: config.memory, notes: notes), ramGB: probe.ramGB(),
                                      running: probe.runningMemory()))
        }
        checks += [checkAEC(), checkMicrophone(probe.microphoneStatus())]
        let outputDir = config?.outputDir ?? stores.home.appendingPathComponent("Meetings/Recordings", isDirectory: true)
        checks += [checkSystemAudio(outputDir, timeZone: timeZone), checkAudioDevices(probe),
                   checkRecentAudio(outputDir, timeZone: timeZone), checkTeams(probe),
                   Recommendations.checkDisk(freeBytes: probe.freeBytes(FileManager.default.fileExists(atPath: outputDir.path)
                                                                           ? outputDir : stores.home))]
        return checks
    }

    /// doctor.format_report: "✓ name: detail", and "    → fix" under one that is not ok.
    public static func format(_ checks: [SetupCheck]) -> String {
        var lines: [String] = []
        for c in checks {
            lines.append("\(MARK[c.status] ?? "?") \(c.name): \(c.detail)")
            if !c.fix.isEmpty && c.status != "ok" { lines.append("    → \(c.fix)") }
        }
        return lines.joined(separator: "\n")
    }

    /// The checks, then "N problem(s) to fix." or "All set." after an empty line (`palaver doctor`'s output).
    public static func text(_ checks: [SetupCheck]) -> String {
        let failed = checks.filter { $0.status == "fail" }.count
        return format(checks) + (failed > 0 ? "\n\n\(failed) problem(s) to fix." : "\n\nAll set.")
    }

    /// `palaver doctor`'s exit code: 1 when something must be fixed.
    public static func exitCode(_ checks: [SetupCheck]) -> Int32 { checks.contains { $0.status == "fail" } ? 1 : 0 }

    // MARK: - the checks

    public static func checkMacOS(_ version: String) -> SetupCheck {
        let parts = version.split(separator: ".").prefix(2).compactMap { Int($0) }
        if let major = parts.first, major < 15 { return SetupCheck("macOS", "fail", version, "Palaver needs macOS 15+") }
        return SetupCheck("macOS", "ok", version.isEmpty ? "unknown" : version)
    }

    /// The config as Palaver reads it; a file that is there but can't be read is the one failure (the app takes the
    /// defaults for anything else it does not understand).
    public static func checkConfig(_ url: URL, env: [String: String]) -> (SetupCheck, Config?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (SetupCheck("Config", "ok", "none: the defaults"), Config.load(url, environment: env))
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return (SetupCheck("Config", "fail", "\(url.path) is not readable", "check the file's permissions"), nil)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            return (SetupCheck("Config", "fail", "\(url.path) is not UTF-8 text", "edit \(url.path)"), nil)
        }
        return (SetupCheck("Config", "ok", url.path), Config.load(url, environment: env))
    }

    /// $NOTION_TOKEN, then config.toml's `[notion].token`, then the Keychain (config._token's order); nil: Notion is
    /// not used.
    static func notionToken(_ configURL: URL, env: [String: String], probe: DoctorProbe) -> String? {
        if let t = env["NOTION_TOKEN"], !t.isEmpty { return t }
        if let data = FileManager.default.contents(atPath: configURL.path),
           case .string(let t)? = Toml.parse(String(decoding: data, as: UTF8.self))["notion.token"], !t.isEmpty { return t }
        return probe.keychainNotionToken().flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The token works (`/users/me`) and the page or database it writes to is shared with it.
    public static func checkNotion(token: String, mode: String, parentPageId: String?, databaseId: String?,
                                   probe: DoctorProbe) -> SetupCheck {
        let headers = ["Authorization": "Bearer \(token)", "Notion-Version": "2022-06-28"]
        let me: Int
        do { me = try probe.httpStatus("\(NOTION_API)/users/me", headers: headers) } catch {
            return SetupCheck("Notion", "warn", "not reachable (\(type(of: error)))", "check the network")
        }
        if me == 401 { return SetupCheck("Notion", "fail", "token rejected", "create a new internal integration token") }
        if me != 200 { return SetupCheck("Notion", "warn", "unexpected status \(me)") }
        let (kind, target) = mode == "database" ? ("database", databaseId) : ("page", parentPageId)
        let status = (try? probe.httpStatus("\(NOTION_API)/\(kind)s/\(target ?? "None")", headers: headers)) ?? 0
        if status != 200 {
            return SetupCheck("Notion", "fail", "\(kind) \(target ?? "None") not accessible (\(status))",
                              "share the \(kind) with your integration (••• → Connections)")
        }
        return SetupCheck("Notion", "ok", "token valid, \(kind) accessible")
    }

    /// Parakeet and the diarizer, asked of the engine itself (`hello`), which knows when its models are complete.
    /// Without the engine built, the files say.
    public static func checkSpeechModels(_ probe: DoctorProbe) -> SetupCheck {
        let name = "Speech models"
        let hello: JSONValue?
        do { hello = try probe.engineHello() } catch {
            let text = Py.strip("\(error)")
            let first = text.isEmpty ? "no answer" : String(text.split(separator: "\n").first ?? "")
            return SetupCheck(name, "fail", "the speech engine does not run (\(first))",
                              probe.inBundle ? "reinstall Palaver" : "run `palaver doctor` again after `make engine`")
        }
        guard let hello else {  // not built: the files say
            if probe.speechFilesHere() { return SetupCheck(name, "ok", "downloaded (the engine is not built, files checked)") }
            let missing = probe.inBundle ? "reinstall Palaver" : "run `make engine`"
            return SetupCheck(name, "warn", "not downloaded yet (the speech engine is missing: \(missing))",
                              "download them in the setup assistant (about 0.5 GB), or "
                                + (probe.inBundle ? "reinstall Palaver" : "run `make engine` first"))
        }
        guard case .object(let models)? = hello["models"] else {
            return SetupCheck(name, "warn", "not downloaded yet (unknown)",
                              "download them in the setup assistant (about 0.5 GB); meetings recorded before wait for them")
        }
        let words = ["asr": "transcription", "diarizer": "speakers"]
        let missing = models.filter { !$0.1.truthy }.map { words[$0.0] ?? $0.0 }
        if models.isEmpty || !missing.isEmpty {
            return SetupCheck(name, "warn", "not downloaded yet (\(missing.isEmpty ? "unknown" : missing.joined(separator: " and ")))",
                              "download them in the setup assistant (about 0.5 GB); meetings recorded before wait for them")
        }
        return SetupCheck(name, "ok", "downloaded")
    }

    /// The echo canceller is linked into palaver-worker: there is nothing to build or load any more.
    public static func checkAEC() -> SetupCheck { SetupCheck("Echo cancellation library", "ok", "built in") }

    public static func checkMicrophone(_ status: Int) -> SetupCheck {
        if status == 3 { return SetupCheck("Microphone permission", "ok", "granted") }
        if status == 0 { return SetupCheck("Microphone permission", "warn", "not asked yet", "macOS asks on the first recording") }
        return SetupCheck("Microphone permission", "fail", "denied", SETTINGS + "Microphone → enable this app/terminal")
    }

    /// There is no preflight API for the audio-capture permission: the most recent recording says how it captured
    /// system audio (`SetupPermissions.systemAudio`, the setup assistant's words).
    public static func checkSystemAudio(_ outputDir: URL, timeZone: TimeZone = .current) -> SetupCheck {
        let p = SetupPermissions.systemAudio(outputDir: outputDir, timeZone: timeZone)
        let state = p["state"]?.stringValue ?? "unverified"
        return SetupCheck("System audio capture", state == "granted" ? "ok" : "warn", p["detail"]?.stringValue ?? "",
                          p["fix"]?.stringValue ?? "")
    }

    /// The devices a recording would use now, with their rates (#50). Any of them works; this only says which.
    public static func checkAudioDevices(_ probe: DoctorProbe) -> SetupCheck {
        let name = "Audio devices"
        let devices: (input: (String, Double)?, output: (String, Double)?)
        do { devices = try probe.defaultDevices() } catch {
            return SetupCheck(name, "warn", "could not read them (\(error))")
        }
        var found: [String] = [], missing: [String] = []
        for (scope, device) in [("input", devices.input), ("output", devices.output)] {
            guard let (label, rate) = device, !label.isEmpty else { missing.append(scope); continue }
            found.append(rate > 0 ? "\(scope) \(label) (\(khz(rate)) kHz)" : "\(scope) \(label)")
        }
        if !missing.isEmpty {
            return SetupCheck(name, "warn", (found + missing.map { "no \($0) device" }).joined(separator: ", "),
                              "pick one in System Settings → Sound")
        }
        return SetupCheck(name, "ok", found.joined(separator: ", "))
    }

    /// `f"{rate / 1000:g}"`: 48, 44.1.
    static func khz(_ rate: Double) -> String {
        let k = rate / 1000
        return k == k.rounded() ? String(Int(k)) : String(format: "%g", k)
    }

    /// Whether the latest recording's audio went wrong (#50).
    public static func checkRecentAudio(_ outputDir: URL, timeZone: TimeZone = .current) -> SetupCheck {
        let name = "Last recording's audio"
        let folders = recordingFolders(outputDir).filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
        }
        guard let folder = folders.last else { return SetupCheck(name, "ok", "no recordings yet") }
        guard let meta = PythonJSON.read(folder.appendingPathComponent("meta.json")), case .object = meta,
              let start = WallTime.parse(meta["start_time"]?.stringValue, timeZone) else {
            return SetupCheck(name, "ok", "nothing known about \(folder.lastPathComponent)")
        }
        let problems = meta["audio_problems"]?.arrayValue ?? []
        guard let first = problems.first else { return SetupCheck(name, "ok", "no problems in \(folder.lastPathComponent)") }
        var detail = "\(folder.lastPathComponent): \(Lifecycle.problemText(first, start: start, timeZone: timeZone))"
        if problems.count > 1 { detail += " (and \(problems.count - 1) more)" }
        return SetupCheck(name, "warn", detail, "its session.log has the details: \(folder.appendingPathComponent("session.log").path)")
    }

    public static func checkTeams(_ probe: DoctorProbe) -> SetupCheck {
        let processes: [AudioProcess]
        do { processes = try probe.audioProcesses() } catch {
            return SetupCheck("Teams detection", "fail", "CoreAudio process list unavailable (\(error))", "needs macOS 14.4+")
        }
        guard probe.teamsInstalled() else {
            return SetupCheck("Teams detection", "warn", "Microsoft Teams not installed in /Applications")
        }
        let teams = processes.contains { $0.bundleId.lowercased().hasPrefix("com.microsoft.teams") }
        return SetupCheck("Teams detection", "ok",
                          "works (\(processes.count) audio processes; Teams \(teams ? "running" : "not running right now"))")
    }

    /// The memory budgets per worker (#49) against this Mac's memory, and what the running Palaver uses (`running`:
    /// daemon.json's "memory").
    public static func checkMemory(_ b: MemoryBudgets, ramGB: Double, running: JSONValue?) -> SetupCheck {
        func gb(_ value: Double) -> String { MemoryRules.sizeText(value * MemoryRules.gb) }
        var detail = "live \(gb(b.live)), realtime \(gb(b.stream)), transcription \(gb(b.process)), notes \(gb(b.notes)), "
            + "search index \(gb(b.index))"
        if let total = running?["total"]?.doubleValue { detail += "; Palaver uses \(MemoryRules.sizeText(total)) now" }
        let name = "Memory budgets"
        let over = (running?["workers"]?.arrayValue ?? []).first { w in
            guard let used = w["used"]?.doubleValue, let budget = w["budget"]?.doubleValue, budget > 0 else { return false }
            return used > budget * MemoryRules.gb
        }
        if let w = over {
            let label = w["label"]?.stringValue ?? "a worker"
            return SetupCheck(name, "warn", "\(label) uses \(MemoryRules.sizeText(w["used"]?.doubleValue)), over its "
                                + "\(gb(w["budget"]?.doubleValue ?? 0)) budget",
                              "Palaver restarts live and realtime transcription on its own, and stops notes or a "
                                + "transcription only when the Mac runs low on memory; raise the budget under [memory] in "
                                + "config.toml if this happens often")
        }
        let call = b.live + b.stream
        if call >= ramGB / 2 {
            return SetupCheck(name, "warn", "live and realtime transcription may use \(gb(call)) during a call, "
                                + "half or more of this Mac's \(gb(ramGB))",
                              "lower live_gb / stream_gb under [memory] in config.toml, or turn realtime off in Settings")
        }
        if b.notes > ramGB * 0.75 {
            return SetupCheck(name, "warn", "notes may use \(gb(b.notes)); this Mac has \(gb(ramGB))",
                              "write notes with a cloud model (Settings → Language model) or a smaller local model")
        }
        if b.process > ramGB * 0.75 {
            return SetupCheck(name, "warn", "a transcription may use \(gb(b.process)); this Mac has \(gb(ramGB))",
                              "lower process_gb under [memory] in config.toml")
        }
        return SetupCheck(name, "ok", detail)
    }

    /// The recording folders of `outputDir` by name.
    static func recordingFolders(_ outputDir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
        return names.filter(RecordingPaths.isRecordingFolderName).sorted().map {
            outputDir.appendingPathComponent($0, isDirectory: true)
        }.filter { var dir: ObjCBool = false; return FileManager.default.fileExists(atPath: $0.path, isDirectory: &dir) && dir.boolValue }
    }
}

// MARK: - this Mac

/// The doctor's questions answered by this Mac and the network.
public struct MacDoctorProbe: DoctorProbe {
    let stores: StorePaths
    let env: [String: String]
    let keychain: () -> String?

    /// `keychain`: the Notion token from the Keychain (the key store's); none by default.
    public init(stores: StorePaths = .current(), env: [String: String] = ProcessInfo.processInfo.environment,
                keychain: @escaping () -> String? = { nil }) {
        self.stores = stores; self.env = env; self.keychain = keychain
    }

    public func macOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }

    public func httpStatus(_ url: String, headers: [String: String]) throws -> Int {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: u, timeoutInterval: 10)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        final class Answer: @unchecked Sendable { var status: Int?; var failure: Error? }
        let done = DispatchSemaphore(value: 0)
        let answer = Answer()
        URLSession.shared.dataTask(with: request) { _, response, error in
            answer.status = (response as? HTTPURLResponse)?.statusCode
            answer.failure = error
            done.signal()
        }.resume()
        done.wait()
        if let failure = answer.failure { throw failure }
        guard let status = answer.status else { throw URLError(.badServerResponse) }
        return status
    }

    public func keychainNotionToken() -> String? { keychain() }

    public func engineHello() throws -> JSONValue? {
        guard let engine = try? EnginePath.find(env: env), FileManager.default.fileExists(atPath: engine.path) else { return nil }
        return try SpeechCheck.hello(engine: engine, stores: stores, env: env)
    }

    public func speechFilesHere() -> Bool { ModelCatalog.speechFilesHere(stores: stores) }

    public var inBundle: Bool { EnginePath.location.bundle != nil }

    public func microphoneStatus() -> Int { AVCaptureDevice.authorizationStatus(for: .audio).rawValue }

    public func defaultDevices() throws -> (input: (String, Double)?, output: (String, Double)?) {
        (CoreAudioDevices.defaultDevice(input: true), CoreAudioDevices.defaultDevice(input: false))
    }

    public func audioProcesses() throws -> [AudioProcess] { try CoreAudioProcessLister().processes() }

    public func teamsInstalled() -> Bool { FileManager.default.fileExists(atPath: "/Applications/Microsoft Teams.app") }

    public func freeBytes(_ url: URL) -> Int {
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return 0 }
        return Int(s.f_bavail) * Int(s.f_bsize)
    }

    public func ramGB() -> Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }

    public func runningMemory() -> JSONValue? { DaemonFile.runningMemory(stores.daemonJson) }
}

/// The default audio devices, as Core Audio names them (read-only property queries; nothing is captured).
enum CoreAudioDevices {
    static func defaultDevice(input: Bool) -> (String, Double)? {
        var addr = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let label = AudioObjectGetPropertyData(device, &nameAddr, 0, nil, &nameSize, &name) == noErr
            ? (name?.takeRetainedValue() as String?) ?? "" : ""
        var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(device, &rateAddr, 0, nil, &rateSize, &rate) != noErr { rate = 0 }
        return (label, rate)
    }
}

/// daemon.json as the problem report and the doctor read it (daemon.py `read_status`, doctor `_running_memory`).
public enum DaemonFile {
    /// The state written there, nil when there is none (or it is not JSON).
    public static func read(_ url: URL) -> JSONValue? {
        guard let v = PythonJSON.read(url), case .object = v else { return nil }
        return v
    }

    /// kill(pid, 0): it lives (or lives and is not ours).
    static func alive(_ pid: JSONValue?) -> Bool {
        guard let n = pid?.doubleValue, n > 0, n < Double(Int32.max) else { return false }
        return kill(Int32(n), 0) == 0 || errno == EPERM
    }

    /// One line, as `palaver daemon status` says it.
    public static func status(_ url: URL) -> String {
        guard let state = read(url) else { return "daemon has never run" }
        func str(_ v: JSONValue?) -> String { v.map { $0.stringValue ?? Py.str($0) } ?? "None" }
        guard alive(state["pid"]), let s = state["state"], s != .string("stopped") else {
            return "daemon not running (last update \(str(state["updated"])))"
        }
        var line = "daemon running (pid \(str(state["pid"]))): \(str(s)) since \(str(state["since"]))"
        if let folder = state["folder"], folder.truthy { line += " → \(str(folder))" }
        if state["transcribing"]?.truthy == true || state["queued"]?.truthy == true {
            line += "; transcribing, \(state["queued"]?.arrayValue?.count ?? 0) queued"
        }
        if let talk = state["talk_text"], talk.truthy { line += "\n  \(str(talk))" }
        if let nudge = state["nudge"]?["text"], nudge.truthy { line += "\n  Coach: \(str(nudge))" }
        return line
    }

    /// The running Palaver's memory (daemon.json's "memory"), nil when it does not run.
    public static func runningMemory(_ url: URL) -> JSONValue? {
        guard let state = read(url), let s = state["state"], s != .string("stopped"), alive(state["pid"]) else { return nil }
        return state["memory"]
    }
}
