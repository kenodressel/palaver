// What a problem report asks this Mac (report.py `Probe`, `QuietProbe`), and the settings it takes with every secret
// redacted (`redact`, `settings_snapshot`, `scrub`). Each question that fails says so in the zip instead of failing
// the report.
import Darwin
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

/// What a report asks this Mac.
public protocol ReportProbe {
    /// `palaver doctor`'s text, with its last line ("N problem(s) to fix." / "All set.").
    func doctor(configURL: URL) throws -> String
    func hardware() throws -> JSONValue
    /// The Hugging Face cache: each repo, its size and files.
    func models() throws -> JSONValue
    func audioDevices() throws -> JSONValue
    func permissions(outputDir: URL) throws -> JSONValue
    func memory(config: Config) throws -> JSONValue
    /// Palaver's processes now (`ps`).
    func processes() throws -> String
    /// The checkout's commit, whether it has changes, its branch; {} for an installed app.
    func git() throws -> JSONValue
}

/// The probe of the tests: fixed answers, nothing asked of the Mac (report.py `QuietProbe`).
public struct QuietReportProbe: ReportProbe {
    public init() {}
    public func doctor(configURL: URL) throws -> String { "✓ macOS: (not asked in tests)" }
    public func hardware() throws -> JSONValue {
        .object([("chip", .string("Test chip")), ("model", .string("Mac")), ("ram_gb", .double(16.0)), ("macos", .string("15.0")),
                 ("macos_build", .string("")), ("arch", .string("arm64"))])
    }
    public func models() throws -> JSONValue { .array([]) }
    public func audioDevices() throws -> JSONValue {
        .object([("default", .object([("input", .array([.string("Test Mic"), .double(48000.0)])),
                                      ("output", .array([.string("Test Speakers"), .double(48000.0)]))]))])
    }
    public func permissions(outputDir: URL) throws -> JSONValue { .object([("microphone", .object([("status", .string("ok"))]))]) }
    public func memory(config: Config) throws -> JSONValue { .object([("available_gb", .double(8.0))]) }
    public func processes() throws -> String { "" }
    public func git() throws -> JSONValue { .object([]) }
}

/// This Mac's answers.
public struct MacReportProbe: ReportProbe {
    let stores: StorePaths
    let env: [String: String]
    let doctorProbe: DoctorProbe

    public init(stores: StorePaths = .current(), env: [String: String] = ProcessInfo.processInfo.environment,
                doctorProbe: DoctorProbe? = nil) {
        self.stores = stores
        self.env = env
        self.doctorProbe = doctorProbe ?? MacDoctorProbe(stores: stores, env: env)
    }

    public func doctor(configURL: URL) throws -> String {
        Doctor.text(Doctor.run(configURL: configURL, stores: stores, env: env, offline: false, probe: doctorProbe))
    }

    public func hardware() throws -> JSONValue {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var machine = utsname()
        uname(&machine)
        let arch = withUnsafeBytes(of: &machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let memory = Double(Self.sysctlInt("hw.memsize") ?? 0)
        return .object([("chip", .string(Self.sysctlString("machdep.cpu.brand_string") ?? "")),
                        ("model", .string(Self.sysctlString("hw.model") ?? "")),
                        ("ram_gb", .double((memory / 1_073_741_824 * 10).rounded() / 10)),
                        ("macos", .string(os.patchVersion > 0 ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
                                          : "\(os.majorVersion).\(os.minorVersion)")),
                        ("macos_build", .string(Self.sysctlString("kern.osversion") ?? "")), ("arch", .string(arch))])
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    /// The Hugging Face cache as `scan_cache_dir` sees it: per repo its type, size on disk, files and last change.
    public func models() throws -> JSONValue {
        try Self.hubCache(stores.hubCache)
    }

    static func hubCache(_ hub: URL) throws -> JSONValue {
        let fm = FileManager.default
        var repos: [(String, JSONValue)] = []
        for name in try fm.contentsOfDirectory(atPath: hub.path) {
            let kinds = [("models--", "model"), ("datasets--", "dataset"), ("spaces--", "space")]
            guard let (prefix, kind) = kinds.first(where: { name.hasPrefix($0.0) }) else { continue }
            let repo = String(name.dropFirst(prefix.count)).replacingOccurrences(of: "--", with: "/")
            let blobs = hub.appendingPathComponent(name).appendingPathComponent("blobs")
            var bytes = 0, files = 0
            var newest = Date.distantPast
            for blob in (try? fm.contentsOfDirectory(at: blobs, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [] {
                guard let v = try? blob.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      v.isRegularFile == true else { continue }
                bytes += v.fileSize ?? 0
                files += 1
                if let m = v.contentModificationDate, m > newest { newest = m }
            }
            repos.append((repo, .object([
                ("repo", .string(repo)), ("type", .string(kind)),
                ("gb", .double((Double(bytes) / 1_073_741_824 * 100).rounded() / 100)), ("files", .int(files)),
                ("last_modified", newest == .distantPast ? .null : .string(WallTime.iso(newest, .current, seconds: true).dropOffset)),
            ])))
        }
        return .array(repos.sorted { $0.0 < $1.0 }.map(\.1))
    }

    public func audioDevices() throws -> JSONValue {
        let defaults: JSONValue
        do {
            let d = try doctorProbe.defaultDevices()
            func pair(_ p: (String, Double)?) -> JSONValue { p.map { .array([.string($0.0), .double($0.1)]) } ?? .null }
            defaults = .object([("input", pair(d.input)), ("output", pair(d.output))])
        } catch {
            defaults = Report.failure(error)
        }
        let listed = (try? Report.command(["/usr/sbin/system_profiler", "SPAudioDataType", "-json"], timeout: 30))
            .flatMap { try? PythonJSON.parse(Data($0.utf8)) } ?? .object([])
        return .object([("default", defaults), ("system_profiler", listed)])
    }

    public func permissions(outputDir: URL) throws -> JSONValue {
        .object([("microphone", Doctor.checkMicrophone(doctorProbe.microphoneStatus()).json),
                 ("system_audio", Doctor.checkSystemAudio(outputDir).json),
                 ("calendar", .bool(EventKitCalendar().hasAccess()))])
    }

    public func memory(config: Config) throws -> JSONValue {
        let notes = ModelChoice.notesRunMemoryGB(config: config, stores: stores)
        return .object([("available_gb", .double((FreeMemory.availableGB() * 10).rounded() / 10)),
                        ("budgets_gb", MemoryBudgets(config: config.memory, notes: notes).json)])
    }

    public func processes() throws -> String {
        let rows = ModelJobs.splitlines(Py.strip(try Report.command(["/bin/ps", "-axo", "pid,ppid,rss,etime,command"], timeout: 20)))
        return (rows.prefix(1) + rows.dropFirst().filter { $0.lowercased().contains("palaver") }).joined(separator: "\n")
    }

    public func git() throws -> JSONValue {
        guard let checkout = EnginePath.location.checkout,
              FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git").path) else { return .object([]) }
        func git(_ args: String...) throws -> String {
            Py.strip(try Report.command(["/usr/bin/git", "-C", checkout.path] + args, timeout: 5, check: true))
        }
        do {
            let commit = try git("rev-parse", "HEAD")
            let dirty = !(try git("status", "--porcelain", "--untracked-files=no")).isEmpty
            let branch = try git("rev-parse", "--abbrev-ref", "HEAD")
            return .object([("commit", .string(commit)), ("dirty", .bool(dirty)), ("branch", .string(branch))])
        } catch {
            return .object([])
        }
    }
}

private extension String {
    /// "2026-10-30T14:05:30" of "2026-10-30T14:05:30+01:00" (`datetime.fromtimestamp(...).isoformat()`: naive).
    var dropOffset: String { String(prefix(19)) }
}

// MARK: - secrets

/// The settings a report takes: every key that names a token, key, secret or password is "(set)" / "(not set)", and
/// the values taken out are scrubbed from every file that goes in.
public enum ReportSecrets {
    static let WORDS = ["token", "key", "secret", "password"]
    /// What a secret in a file is replaced with.
    public static let SCRUBBED = Data("(secret removed)".utf8)
    /// Shorter values are not scrubbed (they would match everywhere).
    static let MIN_LENGTH = 6

    /// The secrets in `keys` (the Keychain): the Notion and Hugging Face tokens and every provider's API key, by
    /// account. Only items that are there are read (`has` first); a read may ask the user, as config.py's did for a
    /// report. Python's report scrubbed only the tokens; a provider key printed into a log is scrubbed too now.
    public static func keychain(_ keys: KeyStore) -> [String: String] {
        let accounts = [Tokens.NOTION, Tokens.HF]
            + ModelChoice.providers.filter { $0.key != "none" }.map { ProviderSettings.keyAccount($0.id) }
        var out: [String: String] = [:]  // fixed ASCII account names
        for account in accounts where keys.has(account) {
            if let value = (try? keys.read(account)) ?? nil, !value.isEmpty { out[account] = value }
        }
        return out
    }

    public static func isSecret(_ name: String) -> Bool {
        let lower = name.lowercased()
        return WORDS.contains { lower.contains($0) }
    }

    /// `redact(value, secrets)`: `value` with every secret-named key's value replaced by "(set)" or "(not set)"; the
    /// texts taken out go into `secrets`.
    public static func redact(_ value: JSONValue, _ secrets: inout [String]) -> JSONValue {
        switch value {
        case .object(let pairs):
            return .object(pairs.map { k, v in
                guard isSecret(k) else { return (k, redact(v, &secrets)) }
                secrets += strings(v)
                let empty: Bool
                switch v {
                case .null: empty = true
                case .string(let s): empty = s.isEmpty
                case .object(let o): empty = o.isEmpty
                case .array(let a): empty = a.isEmpty
                default: empty = false
                }
                return (k, .string(empty ? "(not set)" : "(set)"))
            })
        case .array(let items): return .array(items.map { redact($0, &secrets) })
        default: return value
        }
    }

    static func strings(_ value: JSONValue) -> [String] {
        switch value {
        case .string(let s): return [s]
        case .object(let pairs): return pairs.flatMap { strings($0.1) }
        case .array(let items): return items.flatMap(strings)
        default: return []
        }
    }

    /// config.toml as written: its sections as objects (`[a.b] c = 1` is `{"a": {"b": {"c": 1}}}`); arrays and inline
    /// tables, which the app does not read, as "(not read)".
    static func tomlTree(_ text: String) -> JSONValue {
        let (values, order) = Toml.parseOrdered(text)
        var root: [(String, JSONValue)] = []
        func insert(_ path: ArraySlice<String>, _ value: JSONValue, into pairs: inout [(String, JSONValue)]) {
            guard let head = path.first else { return }
            let i = pairs.firstIndex { $0.0 == head }
            if path.count == 1 {
                if let i { pairs[i].1 = value } else { pairs.append((head, value)) }
                return
            }
            var inner: [(String, JSONValue)] = []
            if let i, case .object(let existing) = pairs[i].1 { inner = existing }
            insert(path.dropFirst(), value, into: &inner)
            if let i { pairs[i].1 = .object(inner) } else { pairs.append((head, .object(inner))) }
        }
        for key in order {
            let value: JSONValue
            switch values[key] {
            case .string(let s)?: value = .string(s)
            case .int(let n)?: value = .int(n)
            case .double(let d)?: value = .double(d)
            case .bool(let b)?: value = .bool(b)
            default: value = .string("(not read)")
            }
            insert(ArraySlice(key.split(separator: ".").map(String.init)), value, into: &root)
        }
        return .object(root)
    }

    /// The config as the app reads it, under config.py's names.
    static func configJSON(_ c: Config, notionToken: Bool, hfToken: Bool) -> JSONValue {
        .object([
            ("user_name", .string(c.userName)), ("notion_token", .string(notionToken ? "(set)" : "(not set)")),
            ("notion_parent_page_id", .str(c.notionParentPageId)), ("hf_token", .string(hfToken ? "(set)" : "(not set)")),
            ("output_dir", .string(c.outputDir.path)), ("retention_days", .int(c.retentionDays)),
            ("max_session_hours", .int(c.maxSessionHours)), ("grace_period_seconds", .int(c.gracePeriodSeconds)),
            ("transcriber", .string(c.transcriber)), ("language", .string(c.language)), ("notion_mode", .string(c.notionMode)),
            ("notion_database_id", .str(c.notionDatabaseId)), ("live_processing", .bool(c.processingLive)),
            ("record_slack", .bool(c.recordSlack)), ("notion_auto_sync", .bool(c.notionAutoSyncSetting)),
            ("notes_enabled", .bool(c.notesEnabled)), ("notes_engine", .string(c.notesEngine)),
            ("notes_local_model", .string(c.notesLocalModel)), ("notes_model", .string(c.notesModel)),
            ("claude_path", .str(c.claudePath)), ("calendar_enabled", .bool(c.calendarEnabled)),
            ("memory", .object(c.memory.sorted { $0.key < $1.key }.map { ($0.key, .double($0.value)) })),
        ])
    }

    /// `settings_snapshot`: the settings as Palaver reads them, config.toml as written and settings.json, all
    /// redacted, the names of the secrets in the environment; and the secret values (`keychain`: the Keychain's, by
    /// account), longest first.
    public static func snapshot(configURL: URL, stores: StorePaths, env: [String: String],
                                keychain: [String: String] = [:]) -> (JSONValue, [String]) {
        var secrets: [String] = []
        var out: [(String, JSONValue)] = [("config_path", .string(configURL.path))]
        let text = FileManager.default.contents(atPath: configURL.path).map { String(decoding: $0, as: UTF8.self) }
        let toml = Toml.parse(text ?? "")
        func has(_ key: String, _ envName: String) -> Bool {
            if case .string(let s)? = toml[key], !s.isEmpty { return true }
            return !(env[envName] ?? "").isEmpty
        }
        let config = Config.load(configURL, environment: env)
        out.append(("config", configJSON(config, notionToken: has("notion.token", "NOTION_TOKEN") || keychain[Tokens.NOTION] != nil,
                                         hfToken: has("hf.token", "HF_TOKEN") || keychain[Tokens.HF] != nil)))
        if let text {
            out.append(("config_toml", redact(tomlTree(text), &secrets)))
        } else {
            out.append(("config_toml_error", .string("FileNotFoundError: no file \(configURL.path)")))
        }
        out.append(("settings_json", redact(SettingsFile.readRaw(stores: stores), &secrets)))
        let names = env.keys.filter { isSecret($0) && $0 == $0.uppercased() && $0 != $0.lowercased() }.sorted()
        secrets += names.compactMap { env[$0] }
        secrets += keychain.keys.sorted().compactMap { keychain[$0] }
        out.append(("secret_environment", .object(names.map { ($0, .string("(set)")) })))
        var seen = Set<[UInt8]>()
        let unique = secrets.filter { $0.unicodeScalars.count >= MIN_LENGTH && seen.insert(Array($0.utf8)).inserted }
        return (.object(out), unique.sorted { $0.utf8.count > $1.utf8.count })
    }

    /// `scrub`: every secret replaced with `SCRUBBED`.
    public static func scrub(_ data: Data, _ secrets: [String]) -> Data {
        var data = data
        for secret in secrets {
            let needle = Data(secret.utf8)
            guard !needle.isEmpty else { continue }
            var out = Data()
            var from = data.startIndex
            while let r = data.range(of: needle, in: from..<data.endIndex) {
                out.append(data[from..<r.lowerBound])
                out.append(SCRUBBED)
                from = r.upperBound
            }
            if from == data.startIndex { continue }  // not in it
            out.append(data[from..<data.endIndex])
            data = out
        }
        return data
    }
}
