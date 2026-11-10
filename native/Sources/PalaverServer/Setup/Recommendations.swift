// The setup assistant's recommendations, pure (palaver/onboarding.py: the constants and `_gb`, `parse_chip`, `Hardware`,
// `Installed`, `ProviderInfo`, `Registry`, `Current`, `Option`, `Recommendation`, `recommend`, `profile_table`, `offer`,
// `missing_models`, `download_note`). No I/O and no hardware probing: the inputs are the structs (SetupProbe, Task 50, fills
// them). Model data comes from `ModelCatalog` and `ModelChoice`.
import Foundation
import PalaverCore
import PalaverDomain

/// A value the page shows or sets: a switch, a choice or a number of GB (Python's `Any`).
public enum SetupValue: Equatable {
    case string(String)
    case bool(Bool)
    case number(Double)

    public static func == (a: SetupValue, b: SetupValue) -> Bool {
        switch (a, b) {
        case let (.string(x), .string(y)): return Py.same(x, y)
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        default: return false
        }
    }

    public var json: JSONValue {
        switch self {
        case .string(let s): return .string(s)
        case .bool(let b): return .bool(b)
        case .number(let d): return .double(d)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var numberValue: Double? { if case .number(let d) = self { return d } else { return nil } }
}

/// What was detected about this Mac (`Hardware`).
public struct Hardware: Equatable {
    /// The CPU's brand string: "Apple M4 Pro".
    public var chip: String
    public var memoryGB: Double
    public var freeDiskGB: Double

    public init(chip: String, memoryGB: Double, freeDiskGB: Double) {
        self.chip = chip; self.memoryGB = memoryGB; self.freeDiskGB = freeDiskGB
    }

    public var appleSilicon: Bool { Recommendations.parseChip(chip) != nil }
    public var generation: Int? { Recommendations.parseChip(chip)?.generation }
    public var tier: String? { Recommendations.parseChip(chip)?.tier }

    /// "M4 Pro", or the brand string of an Intel Mac.
    public var short: String {
        let scalars = Array(chip.unicodeScalars), prefix = Array("Apple ".unicodeScalars)
        let rest = scalars.starts(with: prefix) ? scalars[prefix.count...] : scalars[...]
        let text = Py.strip(String(String.UnicodeScalarView(rest)))
        return text.isEmpty ? "this Mac" : text
    }

    /// What a change of Mac changes: the chip and the memory, not the free disk.
    public var fingerprint: String { "\(chip), \(Recommendations.fixed(memoryGB, 0)) GB" }
}

/// Which apps are installed (`Installed`).
public struct Installed: Equatable {
    public var teams = false
    public var slack = false
    public var claudeCode = false
    public var claudeDesktop = false

    public init(teams: Bool = false, slack: Bool = false, claudeCode: Bool = false, claudeDesktop: Bool = false) {
        self.teams = teams; self.slack = slack; self.claudeCode = claudeCode; self.claudeDesktop = claudeDesktop
    }
}

public struct SetupProviderInfo {
    public var label: String
    public var uses: [String]
    public var ready: Bool
    public var problem: String?

    public init(label: String, uses: [String], ready: Bool, problem: String? = nil) {
        self.label = label; self.uses = uses; self.ready = ready; self.problem = problem
    }
}

/// `providers.FEATURES` x `providers.PROVIDERS`, as the recommendations read them.
public struct SetupRegistry {
    /// feature → the kind of provider it uses
    public var features: PyDict<String>
    public var providers: PyDict<SetupProviderInfo>

    public init(features: PyDict<String> = PyDict(), providers: PyDict<SetupProviderInfo> = PyDict()) {
        self.features = features; self.providers = providers
    }

    public func featuresOf(_ kind: String) -> [String] {
        zip(features.keys, features.values).filter { Py.same($0.1, kind) }.map(\.0)
    }

    public func providersOf(_ kind: String) -> [String] {
        zip(providers.keys, providers.values).filter { $0.1.uses.contains { Py.same($0, kind) } }.map(\.0)
    }

    public func readyOf(_ kind: String) -> [String] { providersOf(kind).filter { providers[$0]!.ready } }
}

/// What is set now (`Current`).
public struct SetupCurrent {
    /// settings.json's switches
    public var settings: PyDict<Bool>
    /// feature → "local" or a provider id
    public var choices: PyDict<String>
    public var localModel: String
    /// MODELS on this Mac
    public var downloaded: [String]
    public var registry: SetupRegistry
    /// "code" / "desktop" → starts Palaver's MCP server
    public var mcp: PyDict<Bool>
    /// recommendation ids the user set on purpose (settings.json, config.toml)
    public var chosen: [String]

    public init(settings: PyDict<Bool> = PyDict(), choices: PyDict<String> = PyDict(),
                localModel: String = ModelCatalog.GEMMA, downloaded: [String] = [], registry: SetupRegistry = SetupRegistry(),
                mcp: PyDict<Bool> = PyDict(), chosen: [String] = []) {
        self.settings = settings; self.choices = choices; self.localModel = localModel; self.downloaded = downloaded
        self.registry = registry; self.mcp = mcp; self.chosen = chosen
    }

    func has(_ model: String) -> Bool { downloaded.contains { Py.same($0, model) } }
}

public struct SetupOption {
    public var value: SetupValue
    public var label: String
    public var note: String
    /// false: can't run here, or not set up (the note says why)
    public var available: Bool

    public init(_ value: SetupValue, _ label: String, _ note: String = "", available: Bool = true) {
        self.value = value; self.label = label; self.note = note; self.available = available
    }

    var json: JSONValue {
        .object([("value", value.json), ("label", .string(label)), ("note", .string(note)), ("available", .bool(available))])
    }
}

public struct Recommendation {
    public var id: String
    /// the assistant's step it belongs to
    public var step: String
    public var title: String
    /// recommended
    public var value: SetupValue
    public var label: String
    public var reason: String
    public var current: SetupValue
    public var options: [SetupOption] = []
    /// the recommended choice needs something set up first (a cloud model's key)
    public var needsSetup = false
    /// MODELS the recommended choice needs that are not here yet
    public var downloads: [String] = []
    /// the provider features this choice sets
    public var features: [String] = []
    /// the current value was set on purpose: re-opening the assistant keeps it
    public var chosen = false

    public var matches: Bool { current == value }

    /// `to_dict()`: the dataclass fields in order, then `matches`.
    public func toDict() -> JSONValue {
        .object([("id", .string(id)), ("step", .string(step)), ("title", .string(title)), ("value", value.json),
                 ("label", .string(label)), ("reason", .string(reason)), ("current", current.json),
                 ("options", .array(options.map(\.json))), ("needs_setup", .bool(needsSetup)),
                 ("downloads", .strings(downloads)), ("features", .strings(features)), ("chosen", .bool(chosen)),
                 ("matches", .bool(matches))])
    }
}

public enum Recommendations {
    public static let LOCAL = ModelChoice.LOCAL
    /// notes wait for a cloud model the user has not set up yet (providers.PENDING)
    public static let PENDING = ModelChoice.PENDING
    public static let UNSUPPORTED = "Not supported on this Mac"
    /// `INTEL.format(short=...)`
    public static func INTEL(short: String) -> String {
        "Apple Silicon is required for local processing, and this Mac has \(short): Palaver doesn't support "
            + "Intel Macs yet."
    }

    public static let LANGUAGE_MODEL = ModelChoice.LANGUAGE_MODEL
    public static let TRANSCRIPTION = ModelChoice.TRANSCRIPTION
    public static let GEMMA = ModelCatalog.GEMMA
    /// What a local model can't count on: macOS, Teams, a browser and an IDE. 24 GB leaves 14 GB, what Gemma 4 12B waits for.
    public static let OTHER_APPS_GB = 10.0
    /// Left free after downloads: recordings (about 250 MB per hour) and the system.
    public static let DISK_RESERVE_GB = 5.0
    public static let LIVE_WORKER_GB = 3.6
    public static let STREAM_GB = "1.9–2.5"
    public static let REALTIME_MIN_MEMORY_GB = 16
    public static let LIVE_MIN_MEMORY_GB = 24
    public static let PENDING_LABEL = "None yet: set up a cloud model"

    static let ON_OFF = [SetupOption(.bool(true), "On"), SetupOption(.bool(false), "Off")]

    private static var speech: ModelInfo { ModelCatalog.model("speech")! }
    private static var gemmaModel: ModelInfo { ModelCatalog.model("gemma")! }
    private static var e5: ModelInfo { ModelCatalog.model("e5")! }

    // MARK: - formatting

    /// `f"{x:.<digits>f}"`: C's `%.nf` rounds the exact binary value half to even, as Python does.
    static func fixed(_ x: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", x) }

    /// `_gb`.
    public static func gb(_ x: Double) -> String {
        x < 10 && x != x.rounded(.towardZero) ? "\(fixed(x, 1)) GB" : "\(fixed(x, 0)) GB"
    }

    /// `download_size`: `sum` of the downloads' sizes.
    public static func downloadSize(_ ids: [String]) -> Double {
        Py.sum(ids.map { ModelCatalog.model($0)!.diskGB })
    }

    // MARK: - what was detected

    /// `parse_chip`: "Apple M4 Pro" → (4, "pro"); nil for an Intel Mac.
    public static func parseChip(_ brand: String) -> (generation: Int, tier: String)? {
        guard let m = chip.firstMatch(in: brand), let digits = m.group(1) else { return nil }
        return (ModelCatalog.pyInt(digits) ?? Int.max, Py.casefold(m.group(2) ?? "base"))
    }

    private static let chip = try! PyRegex(#"\bApple M(\d+)(?:\s+(Pro|Max|Ultra))?\b"#, ignoreCase: true)

    // MARK: - recommendations

    private static func pickCloud(_ ready: [String], _ current: String) -> String? {
        if ready.contains(where: { Py.same($0, current) }) { return current }
        if ready.contains(where: { Py.same($0, "claude-cli") }) { return "claude-cli" }
        return ready.first
    }

    private static func providerOptions(_ reg: SetupRegistry, _ kind: String) -> [SetupOption] {
        reg.providersOf(kind).map { pid in
            let p = reg.providers[pid]!
            let note = p.ready ? "Ready" : (p.problem.flatMap { $0.isEmpty ? nil : $0 } ?? "Not set up")
            return SetupOption(.string(pid), p.label, note, available: p.ready)
        }
    }

    private static func transcription(_ hw: Hardware, _ cur: SetupCurrent) -> Recommendation {
        let reg = cur.registry
        let features = reg.featuresOf(TRANSCRIPTION)
        let now = features.first.flatMap { cur.choices[$0] } ?? LOCAL
        let local = SetupOption(.string(LOCAL), "Parakeet on this Mac",
                                hw.appleSilicon ? "Nothing leaves the Mac. A \(gb(speech.diskGB)) download." : "Needs Apple Silicon.",
                                available: hw.appleSilicon)
        let options = [local] + providerOptions(reg, TRANSCRIPTION)
        let needed = hw.appleSilicon && !cur.has("speech") ? ["speech"] : []
        if hw.appleSilicon {
            return Recommendation(
                id: "transcription", step: "models", title: "Transcription", value: .string(LOCAL), label: local.label,
                reason: "Parakeet runs on any Apple Silicon Mac (about a minute per hour of audio for each track on an "
                    + "M4 Pro), with under 1 GB of memory while it runs. The same download tells the speakers apart. "
                    + "Nothing leaves the Mac.",
                current: .string(now), options: options, downloads: needed, features: features)
        }
        return Recommendation(id: "transcription", step: "models", title: "Transcription", value: .string(now),
                              label: UNSUPPORTED, reason: INTEL(short: hw.short), current: .string(now), options: options,
                              features: features)
    }

    private static func localOption(_ hw: Hardware, _ repo: String, _ cur: SetupCurrent) -> SetupOption {
        let info = ModelChoice.localModelInfo(repo)
        let model = ModelCatalog.model(ModelCatalog.notesModels[repo]!)!
        let free = ModelChoice.notesMemoryGB(repo)
        let label = "\(info?.label ?? model.label) on this Mac"
        let value = SetupValue.string("\(LOCAL):\(repo)")
        if !hw.appleSilicon { return SetupOption(value, label, "Needs Apple Silicon.", available: false) }
        if hw.memoryGB < free {
            return SetupOption(value, label,
                               "Needs \(gb(free)) of free memory; this Mac has \(gb(hw.memoryGB)) in all.", available: false)
        }
        var note = "Uses \(model.memory); notes wait until \(gb(free)) are free."
        if hw.memoryGB - OTHER_APPS_GB < free { note += " With \(gb(hw.memoryGB)), that means closing most other apps." }
        if !cur.has(model.id) { note += " A \(gb(model.diskGB)) download." }
        if let extra = info?.note, !extra.isEmpty { note += " \(extra)" }
        return SetupOption(value, label, note)
    }

    /// `download_note`: the catch of a local notes model on a Mac too small for it.
    public static func downloadNote(_ mid: String, _ hw: Hardware) -> String {
        guard let repo = zip(ModelCatalog.notesModels.keys, ModelCatalog.notesModels.values)
            .first(where: { Py.same($0.1, mid) })?.0 else { return "" }
        let free = ModelChoice.notesMemoryGB(repo)
        if hw.memoryGB - OTHER_APPS_GB >= free { return "" }
        return "needs \(gb(free)) free while writing; this Mac has \(gb(hw.memoryGB))"
    }

    private static func languageModel(_ hw: Hardware, _ cur: SetupCurrent, _ roomGB: Double) -> Recommendation {
        let reg = cur.registry
        let found = reg.featuresOf(LANGUAGE_MODEL)
        let features = found.isEmpty ? ["notes", "projects"] : found
        let chosen = cur.choices[features[0]] ?? LOCAL
        let now = Py.same(chosen, LOCAL) ? "\(LOCAL):\(cur.localModel)" : chosen
        let options = ModelCatalog.notesModels.keys.map { localOption(hw, $0, cur) } + providerOptions(reg, LANGUAGE_MODEL)
            + [SetupOption(.string(PENDING), PENDING_LABEL, "Notes are off until you set up a cloud model in Settings.")]
        let gemma = gemmaModel
        let free = ModelChoice.MODEL_MEMORY_GB.first { Py.same($0.0, GEMMA) }!.1
        let fits = hw.appleSilicon && hw.memoryGB - OTHER_APPS_GB >= free
        let onDisk = cur.has("gemma") || roomGB >= gemma.diskGB + DISK_RESERVE_GB
        if fits && onDisk {
            return Recommendation(
                id: LANGUAGE_MODEL, step: "models", title: "Notes and projects", value: .string("\(LOCAL):\(GEMMA)"),
                label: "Gemma 4 12B on this Mac",
                reason: "With \(gb(hw.memoryGB)) of memory, Gemma 4 12B fits next to your other apps: it uses about "
                    + "10 GB while writing (up to 12 GB), and notes are written after the call once \(gb(free)) are free. "
                    + "It was the most accurate model on German meetings, and nothing leaves the Mac.",
                current: .string(now), options: options, downloads: cur.has("gemma") ? [] : ["gemma"], features: features)
        }
        if !hw.appleSilicon {
            return Recommendation(id: LANGUAGE_MODEL, step: "models", title: "Notes and projects", value: .string(now),
                                  label: UNSUPPORTED, reason: INTEL(short: hw.short), current: .string(now), options: options,
                                  features: features)
        }
        let cloud = pickCloud(reg.readyOf(LANGUAGE_MODEL), chosen)
        let why: String
        if !fits {
            why = "Your Mac has \(gb(hw.memoryGB)) of memory. Gemma 4 12B uses about 10 GB while writing (up to "
                + "12 GB) and waits for \(gb(free)) free, so notes would wait for memory that rarely frees up next "
                + "to your other apps. Small local models wrote clearly worse notes in our tests, so we don't offer "
                + "one."
        } else {
            why = "Gemma 4 12B is an \(gb(gemma.diskGB)) download, and this Mac has \(fixed(hw.freeDiskGB, 0)) GB free "
                + "(Palaver keeps \(gb(DISK_RESERVE_GB)) for recordings). Free up space first, or use a cloud model."
        }
        var then = " A cloud model writes them right after the call; it gets the transcript, and a meeting you keep "
            + "on this Mac never goes there."
        let label = cloud.map { reg.providers[$0]!.label } ?? PENDING_LABEL
        if cloud == nil {
            then += " None is set up yet: until you set one up in Settings → Language model, notes are off "
                + "(no model on this Mac writes them)."
        }
        return Recommendation(id: LANGUAGE_MODEL, step: "models", title: "Notes and projects",
                              value: .string(cloud ?? PENDING), label: label, reason: why + then, current: .string(now),
                              options: options, needsSetup: cloud == nil, features: features)
    }

    private static func fast(_ hw: Hardware) -> Bool {
        guard let gen = hw.generation else { return false }
        return gen >= 3 || (gen == 2 && !Py.same(hw.tier ?? "", "base"))
    }

    private static func realtime(_ hw: Hardware, _ cur: SetupCurrent) -> Recommendation {
        let now = cur.settings["realtime"] ?? true
        let value: Bool, why: String
        if !hw.appleSilicon {
            (value, why) = (false, "Realtime transcription runs Parakeet on this Mac, which needs Apple Silicon.")
        } else if hw.memoryGB < Double(REALTIME_MIN_MEMORY_GB) {
            (value, why) = (false, "Your Mac has \(gb(hw.memoryGB)) of memory: realtime transcription adds about "
                + "\(STREAM_GB) GB during calls, next to the call itself. Text then appears about a "
                + "minute after it is said instead of a few seconds.")
        } else if !fast(hw) {
            (value, why) = (false, "The \(hw.short) is below an M2 Pro: realtime transcription keeps a CPU core busy "
                + "during calls and would compete with the call. Text then appears about a minute "
                + "after it is said instead of a few seconds.")
        } else {
            (value, why) = (true, "The \(hw.short) with \(gb(hw.memoryGB)) has room for it: realtime transcription "
                + "adds about \(STREAM_GB) GB and a CPU core during calls, and text appears a few "
                + "seconds after it is said.")
        }
        return Recommendation(id: "realtime", step: "calls", title: "Realtime transcription", value: .bool(value),
                              label: value ? "On" : "Off", reason: why, current: .bool(now), options: ON_OFF)
    }

    private static func live(_ hw: Hardware, _ cur: SetupCurrent) -> Recommendation {
        let now = cur.settings["live_processing"] ?? true
        let value: Bool, why: String
        if hw.appleSilicon && hw.memoryGB >= Double(LIVE_MIN_MEMORY_GB) {
            (value, why) = (true, "Transcribes and tells speakers apart during the call, in the background (about "
                + "\(Py.repr(LIVE_WORKER_GB)) GB), so a meeting is ready seconds after it ends instead of "
                + "minutes. \(gb(hw.memoryGB)) has room for that.")
        } else {
            (value, why) = (false, "With \(gb(hw.memoryGB)) of memory, the \(Py.repr(LIVE_WORKER_GB)) GB it needs during a "
                + "call would compete with the call. Meetings are transcribed after the call "
                + "instead: about 6 minutes per hour of meeting.")
        }
        return Recommendation(id: "live_processing", step: "calls", title: "Processing during calls", value: .bool(value),
                              label: value ? "During the call" : "After the call", reason: why, current: .bool(now),
                              options: [SetupOption(.bool(true), "During the call"), SetupOption(.bool(false), "After the call")])
    }

    private static func search(_ cur: SetupCurrent, _ roomGB: Double) -> Recommendation {
        let now = cur.settings["search_meaning"] ?? true
        let model = e5
        let here = cur.has("e5")
        if here || roomGB >= model.diskGB + DISK_RESERVE_GB {
            return Recommendation(
                id: "search_meaning", step: "models", title: "Search by meaning", value: .bool(true), label: "On",
                reason: "Finds meetings about what you search for in other words or another language. Meetings are "
                    + "indexed in the background when no call is recorded\(here ? "" : "; its model is a 470 MB download").",
                current: .bool(now), options: ON_OFF, downloads: here ? [] : ["e5"])
        }
        return Recommendation(id: "search_meaning", step: "models", title: "Search by meaning", value: .bool(false),
                              label: "Off",
                              reason: "There is not enough free disk for its 470 MB model; turn it on after freeing space.",
                              current: .bool(now), options: ON_OFF)
    }

    private static let APPS = [("teams", "Microsoft Teams"), ("slack", "Slack")]

    private static func record(_ app: String, _ installed: Bool, _ cur: SetupCurrent) -> Recommendation {
        let key = "record_\(app)"
        let now = cur.settings[key] ?? true
        let what = Py.same(app, "teams") ? "calls" : "huddles"
        let name = APPS.first { Py.same($0.0, app) }!.1
        let value: Bool, why: String
        if installed {
            (value, why) = (true, "\(name) is installed: Palaver starts recording when a \(String(what.dropLast())) starts and "
                + "stops when it ends. You can also start a recording yourself in the menu bar.")
        } else {
            (value, why) = (now, "\(name) is not installed on this Mac; this applies once it is.")
        }
        return Recommendation(id: key, step: "record", title: "Record \(name) \(what) automatically", value: .bool(value),
                              label: value ? "On" : "Off", reason: why, current: .bool(now), options: ON_OFF)
    }

    static let CLAUDE = [("code", "Claude Code"), ("desktop", "Claude Desktop")]

    private static func claude(_ target: String, _ installed: Bool, _ cur: SetupCurrent) -> Recommendation {
        let now = cur.mcp[target] ?? false
        let name = CLAUDE.first { Py.same($0.0, target) }!.1
        let why = installed
            ? "\(name) is installed. With Palaver added, Claude can search and read your meetings, notes and "
                + "transcripts, except meetings kept on this Mac. Every read is in the access log in Settings."
            : "\(name) is not installed on this Mac."
        return Recommendation(id: "claude_\(target)", step: "claude", title: "Add Palaver to \(name)",
                              value: .bool(installed || now), label: installed ? "Add" : "Not installed", reason: why,
                              current: .bool(now),
                              options: [SetupOption(.bool(true), "Add", available: installed || now),
                                        SetupOption(.bool(false), "Leave out")])
    }

    /// What to choose on this Mac, and why; one Recommendation per choice.
    public static func recommend(_ hw: Hardware, _ installed: Installed, _ cur: SetupCurrent) -> [Recommendation] {
        let tr = transcription(hw, cur)
        var room = hw.freeDiskGB - downloadSize(tr.downloads)
        let lm = languageModel(hw, cur, room)
        room -= downloadSize(lm.downloads)
        let search = search(cur, room)
        var out = [tr, lm, search, realtime(hw, cur), live(hw, cur), record("teams", installed.teams, cur),
                   record("slack", installed.slack, cur), claude("code", installed.claudeCode, cur),
                   claude("desktop", installed.claudeDesktop, cur)]
        var wantedModels: [String] = []  // a set in Python: each model once
        for r in out { for m in r.downloads where !wantedModels.contains(where: { Py.same($0, m) }) { wantedModels.append(m) } }
        let wanted = downloadSize(wantedModels) + DISK_RESERVE_GB
        if hw.freeDiskGB < wanted {
            let short = Py.round(wanted - hw.freeDiskGB, 1)
            out.append(Recommendation(
                id: "disk", step: "models", title: "Free disk space", value: .number(short), label: "Free \(gb(short))",
                reason: "The models above need \(gb(wanted - DISK_RESERVE_GB)) and Palaver keeps \(gb(DISK_RESERVE_GB)) "
                    + "free for recordings; this Mac has \(fixed(hw.freeDiskGB, 0)) GB free. Free up \(gb(short)), e.g. with "
                    + "`palaver prune` or by emptying the Trash.",
                current: .number(0.0)))
        }
        return out.map { r in
            var r = r
            r.chosen = cur.chosen.contains { Py.same($0, r.id) }
            return r
        }
    }

    /// `profile_table`: one line per (chip, memory GB, free disk GB): what is recommended.
    public static func profileTable(_ profiles: [(String, Double, Double)], _ cur: SetupCurrent,
                                    _ installed: Installed = Installed()) -> [String] {
        profiles.map { chip, memory, disk in
            let all = recommend(Hardware(chip: chip, memoryGB: memory, freeDiskGB: disk), installed, cur)
            func rec(_ id: String) -> Recommendation? { all.first { Py.same($0.id, id) } }
            let lm = rec(LANGUAGE_MODEL)!, tr = rec("transcription")!
            let notesText = lm.value == .string("\(LOCAL):\(GEMMA)")
                ? "Gemma local" : (lm.needsSetup ? "none yet: set up a cloud model" : "cloud: \(lm.label)")
            func onOff(_ id: String) -> String { rec(id)!.value == .bool(true) ? "on" : "off" }
            var parts = ["transcription \(tr.value == .string(LOCAL) ? "Parakeet local" : tr.label)", "notes \(notesText)",
                         "realtime \(onOff("realtime"))", "live processing \(onOff("live_processing"))",
                         "search \(onOff("search_meaning"))"]
            if let disk = rec("disk") { parts.append("free \(gb(disk.value.numberValue!))") }
            return "\(chip), \(fixed(memory, 0)) GB, \(fixed(disk, 0)) GB free: " + parts.joined(separator: " · ")
        }
    }

    // MARK: - when to offer the assistant

    /// `offer`: whether the window opens the assistant: on the first start (no meetings yet: an existing user opens it from
    /// Settings), when this is another Mac than the one it was set up on, or when a model the choices need is missing.
    /// `state` is settings.json's "setup".
    public static func offer(_ state: PyDict<JSONValue>?, _ fingerprint: String, hasMeetings: Bool,
                             missing: [String]) -> PyDict<JSONValue>? {
        guard let state, !state.isEmpty else {
            if !hasMeetings { return PyDict([("why", .string("first"))]) }
            // An existing user who never ran the assistant is not asked to; but their meetings wait for the speech
            // models, which they must be told about (the others stay as they were).
            let speech = missing.filter { Py.same($0, "speech") }
            return speech.isEmpty ? nil : PyDict([("why", .string("missing")), ("models", .strings(speech))])
        }
        if let hardware = state["hardware"], truthy(hardware) {
            if case .string(let s) = hardware, Py.same(s, fingerprint) {} else {
                return PyDict([("why", .string("changed")), ("was", hardware), ("now", .string(fingerprint))])
            }
        }
        if let done = state["done"], truthy(done), !missing.isEmpty {
            return PyDict([("why", .string("missing")), ("models", .strings(missing))])
        }
        return nil
    }

    /// `missing_models`: the models the current choices need that are not downloaded (the search model downloads by itself).
    public static func missingModels(_ cur: SetupCurrent, _ hw: Hardware) -> [String] {
        if !hw.appleSilicon { return [] }
        var need = ["speech"]  // transcription and the speakers: with a cloud service, the speakers still
        let lm = cur.registry.featuresOf(LANGUAGE_MODEL)
        let feature = lm.first ?? "notes"
        if Py.same(cur.choices[feature] ?? LOCAL, LOCAL), let mid = ModelCatalog.notesModels[cur.localModel] { need.append(mid) }
        return need.filter { !cur.has($0) }
    }

    static func truthy(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }
}
