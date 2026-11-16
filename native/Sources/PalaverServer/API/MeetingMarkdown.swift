// A meeting as one Markdown file (#17): its title, when and who, the notes, then the transcript, spelled as the window
// shows them (names, merges, the glossary). Saved to Downloads from the ⋯ menu, put into every exported .zip as
// `meeting.md` so the zip is readable without Palaver, and mirrored into a folder of the user's choice (an Obsidian
// vault, say), one file per meeting, rewritten when the meeting changes. The folder is a local target: a meeting kept
// on this Mac goes there too.
import Foundation
import PalaverCore
import PalaverDomain

public enum MeetingMarkdown {
    /// The zip's readable copy (Exchange's import skips it).
    public static let ZIP_NAME = Exchange.READABLE_COPY
    /// settings.json's key: the mirrored folder's path; missing or empty: no mirror.
    public static let SETTING = "markdown_folder"
    /// In the mirrored folder: which file is which meeting's, and what it was written from.
    public static let INDEX = ".palaver-markdown.json"
    /// Between two looks at the meetings.
    public static let MIRROR_SECONDS = 60.0

    // MARK: - one meeting

    /// The meeting page's JSON (`MeetingsAPI.getMeeting`) as Markdown.
    public static func render(_ m: JSONValue) -> String {
        let start = m["start"]?.stringValue ?? ""
        let title = (m["title"]?.stringValue).flatMap { $0.isEmpty ? nil : $0 } ?? Titles.fallback(start)
        var out = ["# \(oneLine(title))", ""]
        var facts: [String] = []
        if start.count >= 16 { facts.append(String(start.prefix(10)) + " " + String(start.dropFirst(11).prefix(5))) }
        if let seconds = m["duration"]?.doubleValue, seconds.isFinite, seconds > 0 { facts.append("\(Int((seconds / 60).rounded())) min") }
        let people = speakers(m)
        if !people.isEmpty { facts.append(people.joined(separator: ", ")) }
        if !facts.isEmpty { out += [facts.joined(separator: " · "), ""] }

        let notes = m["notes"] ?? .null
        if let summary = notes["summary"]?.stringValue, !summary.isEmpty { out += ["## Summary", "", summary, ""] }
        for section in notes["sections"]?.arrayValue ?? [] {
            let points = section["points"]?.arrayValue ?? []
            guard let heading = section["heading"]?.stringValue, !points.isEmpty else { continue }
            out += ["## \(oneLine(heading))", ""]
            for p in points {
                out.append("- \(oneLine(p["text"]?.stringValue ?? ""))")
                for d in p["details"]?.arrayValue ?? [] { out.append("  - \(oneLine(d.stringValue ?? Py.str(d)))") }
            }
            out.append("")
        }
        let steps = notes["next_steps"]?.arrayValue ?? []
        if !steps.isEmpty {
            out += ["## Next steps", ""]
            for s in steps {
                let task = oneLine(s["task"]?.stringValue ?? s.stringValue ?? "")
                let owner = s["owner"]?.stringValue.map(oneLine) ?? ""
                out.append(owner.isEmpty ? "- [ ] \(task)" : "- [ ] **\(owner)**: \(task)")
            }
            out.append("")
        }
        let decisions = (notes["decisions"]?.arrayValue ?? []).compactMap { d in d.stringValue ?? d["text"]?.stringValue }
        if !decisions.isEmpty { out += ["## Decisions", ""] + decisions.map { "- \(oneLine($0))" } + [""] }

        let lines = m["transcript"]?.arrayValue ?? []
        if !lines.isEmpty {
            out += ["## Transcript", ""]
            for t in lines {
                let at = clock(start, offset: t["start"]?.doubleValue ?? 0)
                out += ["**\(oneLine(t["speaker"]?.stringValue ?? ""))** [\(at)]  \(oneLine(t["text"]?.stringValue ?? ""))", ""]
            }
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }

    /// The file's name: "2026-11-13 14-35 Title.md", without what a file name can't hold.
    public static func fileName(_ m: JSONValue) -> String {
        let start = m["start"]?.stringValue ?? ""
        let title = (m["title"]?.stringValue).flatMap { $0.isEmpty ? nil : $0 } ?? Titles.fallback(start)
        var stamp = ""
        if start.count >= 16 {
            stamp = String(start.prefix(10)) + " " + String(start.dropFirst(11).prefix(5)).replacingOccurrences(of: ":", with: "-") + " "
        }
        let clean = String(title.unicodeScalars.map { "/\\:*?\"<>|\n\r\t".unicodeScalars.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stamp + String(clean.prefix(120)).trimmingCharacters(in: CharacterSet(charactersIn: " .")) + ".md"
    }

    /// The meeting `id` as Markdown, as the window shows it now.
    public static func markdown(_ app: ServerApp, id: String) throws -> (name: String, text: String) {
        let m = try MeetingsAPI.getMeeting(app: app, id: id, calendar: false)
        return (fileName(m), render(m))
    }

    /// Save as Markdown: the file in Downloads, never over an earlier one.
    public static func save(_ app: ServerApp, id: String) throws -> JSONValue {
        let (name, text) = try markdown(app, id: id)
        try FileManager.default.createDirectory(at: app.downloads, withIntermediateDirectories: true)
        var dest = app.downloads.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = app.downloads.appendingPathComponent("\(name.dropLast(3)) \(n).md")
            n += 1
        }
        try Data(text.utf8).write(to: dest, options: .withoutOverwriting)
        return .object([("saved", .string(dest.path)), ("name", .string(dest.lastPathComponent)),
                        ("folder", .string(dest.deletingLastPathComponent().lastPathComponent))])
    }

    // MARK: - the mirrored folder

    /// The folder chosen in Settings (a leading "~" is the home), nil when none.
    public static func folder(stores: StorePaths) -> URL? {
        guard let raw = SettingsFile.readRaw(stores: stores)[SETTING]?.stringValue else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Settings → Export: the folder, or "" for none. Refused when it isn't an absolute path or "~/…".
    public static func setFolder(_ app: ServerApp, _ value: String) throws -> JSONValue {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("~/") && path != "~" {
            throw BadRequest("a folder's full path, like ~/Documents/Meetings")
        }
        try SettingsFile.update([(SETTING, .string(path))], stores: app.stores)
        if !path.isEmpty { _ = mirror(app) }
        return .object([(SETTING, .string(path))])
    }

    /// One look at the meetings: a file written for each transcribed meeting that is new or changed, renamed when its
    /// title changed, and deleted when its meeting is gone. Files Palaver didn't write are never touched. Counts what
    /// changed; nothing when no folder is chosen.
    @discardableResult
    public static func mirror(_ app: ServerApp) -> (written: Int, removed: Int) {
        guard let dir = folder(stores: app.stores) else { return (0, 0) }
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            app.log?.message("markdown folder \(dir.path): \(error)", level: "WARNING", logger: "palaver.markdown")
            return (0, 0)
        }
        let indexFile = dir.appendingPathComponent(INDEX)
        var index: [String: (file: String, made: [Int])] = [:]
        for (id, v) in PyDict<JSONValue>(PythonJSON.read(indexFile) ?? .null) ?? PyDict() {
            guard let file = v["file"]?.stringValue, !file.contains("/") else { continue }
            index[id] = (file, (v["made"]?.arrayValue ?? []).compactMap { n -> Int? in if case .int(let i) = n { return i }; return nil })
        }
        var written = 0, removed = 0
        var seen = Set<String>()
        let taken = { (name: String, id: String) in index.contains { $0.key != id && $0.value.file == name } }
        for name in GlossaryAPI.recordingNames(app.outputDir) {
            let paths = RecordingPaths(app.outputDir.appendingPathComponent(name, isDirectory: true))
            guard FileManager.default.fileExists(atPath: paths.transcriptJson.path) else { continue }
            seen.insert(name)
            // What its file is made from (the list entry's files): a change to one of them writes it again.
            let made = SignatureCache<Int>.signature(MeetingsAPI.signatureFiles(paths, app)) ?? []
            let before = index[name]
            if let before, before.made == made, FileManager.default.fileExists(atPath: dir.appendingPathComponent(before.file).path) {
                continue
            }
            guard let (file, text) = try? markdown(app, id: name) else { continue }
            var target = file
            if target != before?.file {  // a new name: never another meeting's file, nor one Palaver didn't write
                var n = 2
                while taken(target, name) || (FileManager.default.fileExists(atPath: dir.appendingPathComponent(target).path)) {
                    target = String(file.dropLast(3)) + " (\(n)).md"
                    n += 1
                }
            }
            do {
                try Data(text.utf8).write(to: dir.appendingPathComponent(target), options: .atomic)
            } catch {
                app.log?.message("markdown folder: \(target): \(error)", level: "WARNING", logger: "palaver.markdown")
                continue
            }
            if let old = before?.file, old != target { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
            index[name] = (target, made)
            written += 1
        }
        for (id, entry) in index where !seen.contains(id) {  // the meeting was deleted, merged or split
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(entry.file))
            index[id] = nil
            removed += 1
        }
        if written + removed > 0 {
            let json = JSONValue.object(index.keys.sorted().map { id in
                (id, .object([("file", .string(index[id]!.file)), ("made", .array(index[id]!.made.map { .int($0) }))]))
            })
            try? PythonJSON.write(json, to: indexFile, indent: 1, ensureAscii: false, via: "\(INDEX).\(getpid()).tmp")
        }
        return (written, removed)
    }

    // MARK: - helpers

    /// Speakers by the names the page shows, without the unnamed ones twice.
    private static func speakers(_ m: JSONValue) -> [String] {
        var out: [String] = []
        for s in m["speakers"]?.arrayValue ?? [] {
            let name = (s["name"]?.stringValue).flatMap { $0.isEmpty ? nil : $0 } ?? s["display"]?.stringValue ?? ""
            if !name.isEmpty && !out.contains(name) { out.append(name) }
        }
        return out
    }

    /// A line's wall-clock time: the meeting's start ("…T14:35:46…") plus the line's offset, as "14:48:15"; the
    /// offset alone ("12:59") when the start can't be read.
    static func clock(_ start: String, offset: Double) -> String {
        let s = Array(start)
        let off = offset.isFinite ? Int(offset) : 0
        if s.count >= 19, let h = Int(String(s[11...12])), let mi = Int(String(s[14...15])), let se = Int(String(s[17...18])) {
            let t = ((h * 3600 + mi * 60 + se + off) % 86400 + 86400) % 86400
            return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
        }
        return String(format: "%d:%02d", off / 60, off % 60)
    }

    /// Text on one line: a newline would end a list item or heading.
    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}
