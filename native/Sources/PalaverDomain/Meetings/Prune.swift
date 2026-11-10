// Retention (palaver/prune.py, #3): `palaver prune` deletes recording folders older than `retention_days`. Only
// folders named as `newRecordingFolder` names them count. By default only synced recordings go (their transcript is
// safe in Notion); old unsynced ones are reported and kept.
import Darwin
import Foundation
import PalaverCore

public enum Prune {
    /// What a run deletes, and the old recordings it keeps because they were never uploaded.
    public struct Plan: Equatable {
        public var delete: [URL] = []
        public var keptUnsynced: [URL] = []
    }

    /// When a recording started: meta.json's `start_time` (one without an offset is local time), else its folder
    /// name's stamp in local time.
    static func start(_ folder: URL, stamp: String, timeZone: TimeZone) -> Date? {
        if let meta = PythonJSON.read(RecordingPaths(folder).meta), let text = meta["start_time"]?.stringValue,
           let date = WallTime.parse(text, timeZone) {
            return date
        }
        let digits = stamp.split(whereSeparator: { $0 == "-" || $0 == "T" }).compactMap { Int($0) }
        guard digits.count == 6 else { return nil }
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (digits[0], digits[1], digits[2], digits[3], digits[4], digits[5])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: c)
    }

    /// `plan_prune`: the recording folders of `outputDir` (not links) that started more than `retentionDays` ago.
    public static func plan(_ outputDir: URL, retentionDays: Int, now: Date = Date(), includeUnsynced: Bool = false,
                            timeZone: TimeZone = .current) -> Plan {
        var plan = Plan()
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: outputDir.path) else { return plan }
        for name in names.sorted(by: { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }) {
            guard let stamp = RecordingPaths.recordingFolderTimestamp(name) else { continue }
            let folder = outputDir.appendingPathComponent(name, isDirectory: true)
            var st = stat()
            guard lstat(folder.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }  // no links, no files
            guard let started = start(folder, stamp: stamp, timeZone: timeZone), started < cutoff else { continue }
            if includeUnsynced || FileManager.default.fileExists(atPath: RecordingPaths(folder).notionInfo.path) {
                plan.delete.append(folder)
            } else {
                plan.keptUnsynced.append(folder)
            }
        }
        return plan
    }

    /// The size of the files under `folder`, in MB (10⁶ bytes).
    static func sizeMB(_ folder: URL) -> Double {
        var total = 0
        if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
            }
        }
        return Double(total) / 1e6
    }

    /// `prune`: applies the plan (with `dryRun` only says it), one line per folder and a total; the folders deleted.
    @discardableResult
    public static func run(_ outputDir: URL, retentionDays: Int, now: Date = Date(), dryRun: Bool = false,
                           includeUnsynced: Bool = false, timeZone: TimeZone = .current,
                           say: (String) -> Void = { print($0) }) throws -> [URL] {
        let plan = plan(outputDir, retentionDays: retentionDays, now: now, includeUnsynced: includeUnsynced, timeZone: timeZone)
        let verb = dryRun ? "would delete" : "deleted"
        var freed = 0.0
        for folder in plan.delete {
            let size = sizeMB(folder)
            if !dryRun { try FileManager.default.removeItem(at: folder) }
            freed += size
            say("\(verb) \(folder.lastPathComponent) (\(String(format: "%.0f", size)) MB)")
        }
        for folder in plan.keptUnsynced {
            say("kept \(folder.lastPathComponent): older than \(retentionDays) days but not synced (use --include-unsynced to delete)")
        }
        if plan.delete.isEmpty {
            say("nothing older than \(retentionDays) days to delete")
        } else {
            say("\(verb) \(plan.delete.count) recording(s), \(String(format: "%.0f", freed)) MB")
        }
        return dryRun ? [] : plan.delete
    }
}
