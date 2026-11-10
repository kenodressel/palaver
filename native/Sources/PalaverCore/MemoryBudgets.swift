// The memory budgets per worker (palaver/memory.py, issue #49): the daemon's watchdog judges by them, `palaver doctor`
// and the problem report show them.
import Foundation

public enum MemoryRules {
    public static let gb = 1_073_741_824.0
    /// A worker must stay over its budget this long, and this many samples, before it is acted on.
    public static let overSeconds = 10.0
    public static let overSamples = 3
    public static let maxRestarts = 2
    public static let maxRequeues = 2
    /// The Mac is low on memory below this much free: only then are notes, `process` and the index stopped.
    public static let pressureGB = 1.5
    public static let tries = maxRequeues + 1
    /// palaver-lm's exit code when its own watchdog stopped a local model because the Mac ran low on memory while it was
    /// over its budget (the same rule as the daemon's): the daemon queues the notes again, as for its own stop.
    public static let lowMemoryExit: Int32 = 74
    public static let defaultLiveGB = 2.0
    public static let defaultStreamGB = 1.5
    public static let defaultProcessGB = 4.0
    public static let defaultNotesGB = 14.0
    public static let defaultIndexGB = 1.0
    /// Notes written by a cloud model: the model runs elsewhere.
    public static let cloudNotesGB = 2.0
    public static let labels: [String: String] = [
        "live": "Live transcription", "stream": "Realtime transcription", "process": "Transcription",
        "notes": "Notes", "index": "Search index", "question": "Best next question"]
    /// The index worker is about no one meeting.
    public static let indexFolder = "search index"

    /// "5.4 GB", "12 GB", "317 MB", "—" (memory.py `size_text`).
    public static func sizeText(_ used: Double?) -> String {
        guard let used else { return "—" }
        if used < gb { return String(format: "%.0f MB", used / 1_048_576) }
        let g = used / gb
        return g >= 10 || abs(g - g.rounded()) < 0.05 ? String(format: "%.0f GB", g) : String(format: "%.1f GB", g)
    }
}

// MARK: - budgets

/// GB of phys_footprint each kind of worker may use.
public struct MemoryBudgets: Equatable, Sendable {
    public var live = MemoryRules.defaultLiveGB
    public var stream = MemoryRules.defaultStreamGB
    public var process = MemoryRules.defaultProcessGB
    public var notes = MemoryRules.defaultNotesGB
    public var index = MemoryRules.defaultIndexGB

    public init() {}

    /// `[memory]` of config.toml (Config.memory: `live_gb` ... in GB); `notes` is what the notes
    /// model needs (`budgets_for`: 0 for a cloud model → 2 GB), used unless `notes_gb` is set.
    public init(config: [String: Double], notes need: Double? = nil) {
        if let need { notes = need > 0 ? need : MemoryRules.cloudNotesGB }
        for (key, value) in config where value > 0 {
            switch key {
            case "live_gb": live = value
            case "stream_gb": stream = value
            case "process_gb": process = value
            case "notes_gb": notes = value
            case "index_gb": index = value
            default: break
            }
        }
    }

    /// The best next question (#41) runs the notes' model: the notes' budget.
    public func of(_ kind: String) -> Double {
        switch kind {
        case "live": return live
        case "stream": return stream
        case "process": return process
        case "index": return index
        default: return notes
        }
    }

    public var json: JSONValue {
        .object([("live", .double(live)), ("stream", .double(stream)), ("process", .double(process)),
                 ("notes", .double(notes)), ("index", .double(index))])
    }
}
