// Report a Problem (#59, report.py `create`): one zip on the Desktop with everything the maintainer needs to analyse
// a tester's problem (or wish), so nobody has to ask back. Testing is internal: completeness wins over privacy, with
// one exception, secrets: settings go in with every key that names a token, key, secret or password replaced by
// "(set)" / "(not set)", and every secret value is scrubbed from every file before it goes into the zip.
//
// The layout and the manifest are report.py's, so the maintainer's `palaver report open` and `report usage` read a
// Swift report as they read a Python one. Everything asked of this Mac goes through a `ReportProbe`.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

public enum Report {
    static let CRASH_DAYS = 30.0
    static let TIMELINE_DAYS = 7.0
    /// Every meeting's small files: what happened while recording and processing it.
    static let SMALL_FILES = ["session.log", "meta.json", "audio_problems.json", "stream.json", "calendar.json"]
    static let AUDIO_SUFFIXES = [".wav", ".wav.part", ".m4a", ".mp3", ".flac", ".caf", ".aif", ".aiff"]
    static let MAX_TEXT = 20_000

    /// What the tester said: a bug or a wish, what happened, the meeting it is about (nil: none) and whether that
    /// meeting's audio goes in.
    public struct Form: Equatable {
        public var kind = "bug"
        public var text = ""
        public var meeting: String?
        public var audio = false

        public init(kind: String = "bug", text: String = "", meeting: String? = nil, audio: Bool = false) {
            self.kind = kind; self.text = text; self.meeting = meeting; self.audio = audio
        }

        /// `Form.from_dict`: the form as the page posts it; a bad one is a `BadRequest`.
        public init(json body: JSONValue) throws {
            guard case .object = body else { throw BadRequest("the report form is no object") }
            let kind = body["kind"] ?? .string("bug")
            guard kind == .string("bug") || kind == .string("wish") else { throw BadRequest("kind is bug or wish") }
            let text = body["text"] ?? .string("")
            let meeting = body["meeting"] ?? .null
            guard case .string(let t) = text, meeting.isNull || meeting.stringValue != nil else {
                throw BadRequest("text and meeting are text")
            }
            let audio = body["audio"] ?? .bool(false)
            guard case .bool(let a) = audio else { throw BadRequest("audio is true or false") }
            self.init(kind: kind.stringValue!, text: String(String.UnicodeScalarView(t.unicodeScalars.prefix(MAX_TEXT))),
                      meeting: meeting.stringValue.flatMap { $0.isEmpty ? nil : $0 }, audio: a)
        }

        var json: JSONValue {
            .object([("kind", .string(kind)), ("text", .string(text)), ("meeting", .str(meeting)), ("audio", .bool(audio))])
        }
    }

    /// Where a report is written and what it reads.
    public struct Place {
        public var stores: StorePaths
        public var configURL: URL
        public var outputDir: URL
        public var env: [String: String]
        /// The secrets the Keychain holds, by account (`NOTION_TOKEN`, `HF_TOKEN`, `<provider>.api_key`;
        /// `ReportSecrets.keychain`): scrubbed like config.toml's, and a token there counts as set (config.py `_token`).
        public var keychainSecrets: () -> [String: String]

        public init(stores: StorePaths, configURL: URL, outputDir: URL, env: [String: String] = ProcessInfo.processInfo.environment,
                    keychainSecrets: @escaping () -> [String: String] = { [:] }) {
            self.stores = stores; self.configURL = configURL; self.outputDir = outputDir; self.env = env
            self.keychainSecrets = keychainSecrets
        }

        var desktop: URL { stores.home.appendingPathComponent("Desktop", isDirectory: true) }
        var crashDir: URL { stores.home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true) }
    }

    /// The zip's place and what it holds.
    public struct Written: Equatable {
        public let path: URL
        public let size: Int
        public let files: Int
    }

    // MARK: - create

    /// "Palaver report 2026-10-30 14-05.zip".
    public static func name(_ now: Date, timeZone: TimeZone = .current) -> String {
        "Palaver report \(stamp(now, timeZone, "%04d-%02d-%02d %02d-%02d")).zip"
    }

    static func stamp(_ date: Date, _ timeZone: TimeZone, _ format: String) -> String {
        let c = WallTime.calendar(timeZone, at: date).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: format, c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// The Desktop's next free name for now's report: "… (2).zip" when one of this minute is there.
    static func target(_ desktop: URL, _ now: Date, _ timeZone: TimeZone) -> URL {
        let base = name(now, timeZone: timeZone)
        var target = desktop.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = desktop.appendingPathComponent("\(base.dropLast(4)) (\(n)).zip")
            n += 1
        }
        return target
    }

    /// Writes the report to the Desktop, atomically (a zip appears whole or not at all), and counts it in the usage
    /// log. A meeting that is not a recording folder of `outputDir` is a `BadRequest`.
    public static func create(_ form: Form, place: Place, via: String = "window", now: Date = Date(),
                              timeZone: TimeZone = .current, probe: ReportProbe) throws -> Written {
        if let meeting = form.meeting {
            var dir: ObjCBool = false
            guard RecordingPaths.isRecordingFolderName(meeting),
                  FileManager.default.fileExists(atPath: place.outputDir.appendingPathComponent(meeting).path, isDirectory: &dir),
                  dir.boolValue else { throw BadRequest("no meeting \(meeting)") }
        }
        let (settings, secrets) = ReportSecrets.snapshot(configURL: place.configURL, stores: place.stores, env: place.env,
                                                         keychain: place.keychainSecrets())
        try FileManager.default.createDirectory(at: place.desktop, withIntermediateDirectories: true)
        let target = Self.target(place.desktop, now, timeZone)
        let tmp = place.desktop.appendingPathComponent(".\(target.lastPathComponent).\(getpid()).tmp")
        let zip: ReportZip
        do {
            zip = try ReportZip(url: tmp, secrets: secrets)
            try fill(zip, form, place: place, via: via, now: now, timeZone: timeZone, probe: probe, settings: settings)
            try zip.finish()
            let fd = open(tmp.path, O_RDONLY | O_CLOEXEC)
            if fd >= 0 { fsync(fd); close(fd) }
            guard rename(tmp.path, target.path) == 0 else { throw ZipError.io(errno) }
        } catch {
            unlink(tmp.path)
            throw error
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
        Usage.record("report", fields: [("what", .string(form.kind)), ("audio", .bool(form.audio)),
                                        ("meeting", .bool(form.meeting != nil)), ("via", .string(via)),
                                        ("mb", .double(Double(size) / 1e6))], path: place.stores.usage)
        return Written(path: target, size: size, files: zip.manifest.count + 1)
    }

    // MARK: - what goes in

    static func fill(_ z: ReportZip, _ form: Form, place: Place, via: String, now: Date, timeZone: TimeZone,
                     probe: ReportProbe, settings: JSONValue) throws {
        let stores = place.stores, outputDir = place.outputDir
        let git = safely { try probe.git() }
        let status = DaemonFile.status(stores.daemonJson), state = DaemonFile.read(stores.daemonJson)
        let folders = Doctor.recordingFolders(outputDir)
        let since = now.addingTimeInterval(-TIMELINE_DAYS * 86400)

        // Logs, complete; the sources of the timeline as they go in.
        var sources: [(String, String)] = []
        for (rel, url) in files(under: stores.logs) {
            z.addFile("logs/\(rel)", url, "Palaver's log, complete (app, window's server, daemon, crashes)")
            sources.append((rel, readText(url)))
        }
        for url in crashReports(place.crashDir, now: now) {
            z.addFile("crash-reports/\(url.lastPathComponent)", url, "macOS crash report of a Palaver process")
        }
        let mcpOld = stores.mcpAccess.deletingLastPathComponent().appendingPathComponent("mcp-access.1.jsonl")
        for (url, what) in [(stores.accessLog, "what left the Mac: calls to cloud models and services"),
                            (stores.mcpAccess, "what MCP clients read"), (mcpOld, "what MCP clients read, from before")]
        where isFile(url) {
            z.addFile("data/\(url.lastPathComponent)", url, what)
        }

        // Every meeting's small files; the chosen one complete, its audio when asked.
        for folder in folders {
            for name in SMALL_FILES where isFile(folder.appendingPathComponent(name)) {
                z.addFile("meetings/\(folder.lastPathComponent)/\(name)", folder.appendingPathComponent(name),
                          "every meeting's log and state")
            }
            let log = folder.appendingPathComponent("session.log")
            if isFile(log) { sources.append(("meetings/\(folder.lastPathComponent)", readText(log))) }
        }
        if let meeting = form.meeting {
            for (rel, url) in files(under: outputDir.appendingPathComponent(meeting, isDirectory: true)) {
                if isAudio(url.lastPathComponent) {
                    if form.audio { z.addFile("meetings/\(meeting)/\(rel)", url, "the chosen meeting's audio", audio: true) }
                    continue
                }
                z.addFile("meetings/\(meeting)/\(rel)", url, "the chosen meeting, complete")
            }
        }
        z.addText("meetings/LISTING.txt", listing(folders), "every meeting's files and their sizes")
        for (rel, url) in files(under: outputDir.appendingPathComponent(".jobs", isDirectory: true)) {
            z.addFile("jobs/\(rel)", url, "the language model's job records")
        }

        let lines = ReportTimeline.timeline(sources, since: since, timeZone: timeZone)
        z.addText("timeline.txt", lines.joined(separator: "\n") + "\n",
                  "warnings, errors and events of the last \(Int(TIMELINE_DAYS)) days across the logs, by time")

        // Settings, this Mac, the usage.
        z.addJSON("settings.json", settings, "settings (config loader, config.toml, settings.json); secrets redacted")
        z.addText("doctor.txt", textOrError { try probe.doctor(configURL: place.configURL) }, "`palaver doctor`")
        let hardware = safely { try probe.hardware() }
        z.addJSON("system/audio-devices.json", safely { try probe.audioDevices() },
                  "audio devices: the defaults and every device macOS lists")
        z.addJSON("system/permissions.json", safely { try probe.permissions(outputDir: outputDir) },
                  "microphone, system audio, calendar")
        let config = Config.load(place.configURL, environment: place.env)
        z.addJSON("system/memory.json", safely { try probe.memory(config: config) }, "free memory and the workers' budgets")
        if let state { z.addJSON("system/daemon.json", state, "the running app's state: recording, warnings, memory") }
        z.addText("system/processes.txt", textOrError { try probe.processes() }, "Palaver's processes now")
        let events = Usage.read(stores.usage)
        if isFile(stores.usage) { z.addFile("usage/usage.jsonl", stores.usage, "the raw usage log") }
        z.addJSON("usage-summary.json",
                  Usage.summary(events, catalog: Usage.catalog(path: stores.usageFeatures), now: now, timeZone: timeZone),
                  "features used over 7 and 30 days, never used, recordings and notes")

        var palaver: [(String, JSONValue)] = [("version", .string(Exchange.palaverVersion))]
        if case .object = git, git["error"] == nil {
            for k in ["commit", "dirty", "branch"] { palaver.append((k, git[k] ?? .null)) }
        }
        let report: JSONValue = .object([
            ("form", form.json),
            ("created", .string(WallTime.iso(now, timeZone, seconds: true))),
            ("via", .string(via)),
            ("user", settings["config"]?["user_name"] ?? .null),
            ("host", .string(hostName())),
            ("palaver", .object(palaver)),
            ("build", .string("swift")),
            ("executable", .string(Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? "")),
            ("hardware", hardware),
            ("disk", safely { try disk(outputDir, home: stores.home) }),
            ("models", safely { try probe.models() }),
            ("daemon", .string(status)),
            ("recordings", .object([("folder", .string(outputDir.path)), ("meetings", .int(folders.count))])),
            ("last_errors", .strings(Array(ReportTimeline.collapseRepeats(lines.filter { !$0.contains("  EVENT ") }).suffix(30)))),
        ])
        z.addJSON("report.json", report, "the form, versions, this Mac, models, the daemon, the last errors")
        z.addText("MANIFEST.txt", manifest(z.manifest, form: form, now: now, timeZone: timeZone), "this list")
    }

    /// MANIFEST.txt: every file in the zip, its size and what it is, by name; itself last.
    static func manifest(_ entries: [(String, Int, String)], form: Form, now: Date, timeZone: TimeZone) -> String {
        var lines = ["Palaver report, \(stamp(now, timeZone, "%04d-%02d-%02d %02d:%02d")) — \(form.kind)", ""]
        let width = max(entries.map { $0.0.count }.max() ?? 0, 12)
        let sorted = entries.sorted { a, b in
            if a.0 != b.0 { return a.0.unicodeScalars.lexicographicallyPrecedes(b.0.unicodeScalars) }
            if a.1 != b.1 { return a.1 < b.1 }
            return a.2 < b.2
        }
        lines += sorted.map { "\(pad($0.0, width))  \(leftPad(grouped($0.1), 12)) B  \($0.2)" }
        lines.append("\(pad("MANIFEST.txt", width))  \(leftPad("", 14))  this list")
        return lines.joined(separator: "\n") + "\n"
    }

    static func pad(_ s: String, _ width: Int) -> String { s.count >= width ? s : s + String(repeating: " ", count: width - s.count) }
    static func leftPad(_ s: String, _ width: Int) -> String { s.count >= width ? s : String(repeating: " ", count: width - s.count) + s }

    /// `f"{n:,}"`: 1,234,567.
    static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }

    /// Every meeting's files with their sizes.
    static func listing(_ folders: [URL]) -> String {
        var lines: [String] = []
        for folder in folders {
            lines.append("\(folder.lastPathComponent)/")
            for (rel, url) in files(under: folder) {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
                lines.append("  \(rel)  \(grouped(size)) B")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// macOS crash reports of Palaver's processes from the last `CRASH_DAYS`: named after it, or one that mentions it
    /// (a Python's of the fallback, a helper's).
    static func crashReports(_ dir: URL, now: Date) -> [URL] {
        let since = now.addingTimeInterval(-CRASH_DAYS * 86400)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted().map { dir.appendingPathComponent($0) }.filter { url in
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  v.isRegularFile == true, let m = v.contentModificationDate, m >= since else { return false }
            if url.lastPathComponent.lowercased().contains("palaver") { return true }
            guard let data = FileManager.default.contents(atPath: url.path) else { return false }
            return Data(data.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }).range(of: Data("palaver".utf8)) != nil
        }
    }

    /// The disk the recordings are on (the home when the folder is not there).
    static func disk(_ outputDir: URL, home: URL) throws -> JSONValue {
        let probe = FileManager.default.fileExists(atPath: outputDir.path) ? outputDir : home
        var s = statfs()
        guard statfs(probe.path, &s) == 0 else { throw ZipError.io(errno) }
        let gb = { (blocks: UInt64) in (Double(blocks) * Double(s.f_bsize) / 1_073_741_824 * 10).rounded() / 10 }
        return .object([("path", .string(probe.path)), ("free_gb", .double(gb(s.f_bavail))), ("total_gb", .double(gb(s.f_blocks)))])
    }

    static func hostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        return String(cString: buffer)
    }

    // MARK: - helpers

    static func isAudio(_ name: String) -> Bool {
        let lower = name.lowercased()
        return AUDIO_SUFFIXES.contains { lower.hasSuffix($0) }
    }

    static func isFile(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && !dir.boolValue
    }

    /// Every file under `root` (links followed as `rglob` does not: they are listed, not entered), by relative path.
    static func files(under root: URL) -> [(String, URL)] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let base = root.standardizedFileURL.path
        var out: [(String, URL)] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }
            out.append((String(full.dropFirst(base.count + 1)), url))
        }
        return out.sorted { $0.0.unicodeScalars.lexicographicallyPrecedes($1.0.unicodeScalars) }
    }

    static func readText(_ url: URL) -> String {
        FileManager.default.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// What went wrong, as the zip says it: {"error": "Kind: text"}.
    static func failure(_ error: Error) -> JSONValue { .object([("error", .string("\(type(of: error)): \(error)"))]) }

    /// `body()`, or what went wrong: one question failing never fails the report.
    static func safely(_ body: () throws -> JSONValue) -> JSONValue {
        do { return try body() } catch { return failure(error) }
    }

    static func textOrError(_ body: () throws -> String) -> String {
        do { return try body() + "\n" } catch { return "(failed: \(type(of: error)): \(error))\n" }
    }

    /// A command's stdout, killed after `timeout` seconds; `check`: a non-zero exit throws.
    static func command(_ argv: [String], timeout: Double, check: Bool = false) throws -> String {
        let done = try HelperChild.run(argv, env: ProcessInfo.processInfo.environment, input: Data(), timeout: timeout)
        if check && done.code != 0 { throw CommandFailed(description: "\(argv[0]) exited with \(done.code)") }
        return String(decoding: done.stdout, as: UTF8.self)
    }

    struct CommandFailed: Error, CustomStringConvertible { let description: String }

    /// `size_text`: "3.2 MB", "84 KB".
    public static func sizeText(_ size: Int) -> String {
        let mb = Double(size) / 1e6
        return mb >= 0.1 ? String(format: "%.1f MB", mb) : "\(max(1, Int((Double(size) / 1e3).rounded(.toNearestOrEven)))) KB"
    }
}

/// The zip being written, and its manifest; text goes in scrubbed of secrets.
final class ReportZip {
    let writer: ZipWriter
    let secrets: [String]
    private(set) var manifest: [(String, Int, String)] = []
    private var names = Set<[Unicode.Scalar]>()

    init(url: URL, secrets: [String]) throws {
        writer = try ZipWriter(url: url)
        self.secrets = secrets
    }

    func finish() throws { try writer.finish() }

    private func taken(_ name: String) -> Bool { !names.insert(Array(name.unicodeScalars)).inserted }

    func addBytes(_ name: String, _ data: Data, _ what: String) {
        guard !taken(name) else { return }
        let clean = ReportSecrets.scrub(data, secrets)
        do {
            try writer.add(name: name, data: clean, deflate: true)
            manifest.append((name, clean.count, what))
        } catch {
            manifest.append((name, 0, "\(what) — not written: \(error)"))
        }
    }

    func addText(_ name: String, _ text: String, _ what: String) { addBytes(name, Data(text.utf8), what) }

    func addJSON(_ name: String, _ value: JSONValue, _ what: String) {
        addText(name, PythonJSON.dumps(value, indent: 2, ensureAscii: false) + "\n", what)
    }

    /// A file as it is; audio (large and binary) streamed and stored, not compressed, and not scrubbed.
    func addFile(_ name: String, _ url: URL, _ what: String, audio: Bool = false) {
        if audio {
            guard !taken(name) else { return }
            do {
                try writer.add(name: name, file: url, stored: true)
                manifest.append((name, (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0, what))
            } catch {
                manifest.append((name, 0, "\(what) — not readable: \(error)"))
            }
            return
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            manifest.append((name, 0, "\(what) — not readable"))
            return
        }
        addBytes(name, data, what)
    }
}

// MARK: - the window's maker

/// Report a Problem in the window's server: the form as the page posts it, the report written to the Desktop and
/// shown in Finder; the answer `{path, name, size, files, size_text, shown}` (cli.py `_report_json`'s).
public final class SwiftReport: ReportMaker, @unchecked Sendable {
    let place: Report.Place
    let probe: () -> ReportProbe
    let reveal: (URL) -> Void

    public init(place: Report.Place, probe: @escaping () -> ReportProbe, reveal: @escaping (URL) -> Void = SwiftReport.showInFinder) {
        self.place = place; self.probe = probe; self.reveal = reveal
    }

    /// `open -R`: the zip selected in Finder, ready to drag into Slack or Mail.
    public static let showInFinder: (URL) -> Void = { url in
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-R", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    public func create(_ body: JSONValue) throws -> JSONValue {
        let form = try Report.Form(json: body)
        let written = try Report.create(form, place: place, via: "window", probe: probe())
        reveal(written.path)
        let path = written.path.path, home = place.stores.home.path
        let shown = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        return .object([("path", .string(path)), ("name", .string(written.path.lastPathComponent)), ("size", .int(written.size)),
                        ("files", .int(written.files)), ("size_text", .string(Report.sizeText(written.size))),
                        ("shown", .string(String(shown)))])
    }
}
