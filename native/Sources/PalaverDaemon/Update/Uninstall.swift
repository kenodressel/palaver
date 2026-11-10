// Uninstall Palaver… (uninstall.py, #60): what goes, decided here, and a small script that removes it once
// Palaver has quit (the app can't delete itself while it runs).
//
// Always: the app, an old Python runtime folder, the login item, the `palaver` command (only when the link is
// Palaver's) and a pending update. On request: the models. Recordings stay unless the user ticks to delete them
// too; then only what Palaver made goes (a recordings folder may hold the user's own files): the meeting folders,
// those in its trash, its jobs, and Palaver's data: voices, glossary, settings, logs. The models stay unless ticked.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

public enum Uninstall {
    static let trash = ".trash", jobs = ".jobs"

    /// The paths to remove (only those that exist), in order.
    public static func plan(paths: Paths, outputDir: URL, models: Bool, recordings: Bool) -> [URL] {
        let home = paths.home, support = paths.support
        let app = home.appendingPathComponent("Applications/Palaver.app", isDirectory: true)
        var out: [URL] = [app, support.appendingPathComponent("runtime", isDirectory: true),
                          home.appendingPathComponent("Library/LaunchAgents/com.kenodressel.meeting-transcribe.plist"),
                          support.appendingPathComponent("updates", isDirectory: true), support.appendingPathComponent("update.json")]
        let link = home.appendingPathComponent(".local/bin/palaver")
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
           target.hasPrefix(app.path) || target.hasPrefix(support.path) {
            out.append(link)
        }
        if models { out.append(support.appendingPathComponent("models", isDirectory: true)) }
        if recordings {
            if models {
                out.append(support)
            } else if let names = try? FileManager.default.contentsOfDirectory(atPath: support.path) {
                out += names.sorted().filter { $0 != "models" }.map { support.appendingPathComponent($0) }
            }
            out += [paths.configDir, paths.logs]
            if let rec = recordingsDir(home: home, outputDir: outputDir) {
                out += meetings(in: rec) + meetings(in: rec.appendingPathComponent(trash)) + [rec.appendingPathComponent(jobs)]
            }
        }
        var seen = Set<String>(), result: [URL] = []
        for p in out where !seen.contains(p.path) && exists(p) {
            seen.insert(p.path)
            result.append(p)
        }
        return result
    }

    /// Folders to remove after the plan when nothing else is left in them.
    public static func emptied(paths: Paths, outputDir: URL) -> [URL] {
        var out = [paths.support]
        if let rec = recordingsDir(home: paths.home, outputDir: outputDir) { out += [rec.appendingPathComponent(trash), rec] }
        return out
    }

    /// The recordings folder; nil when it is the home folder or holds it (a recordings folder set to ~ or /):
    /// nothing is taken from there.
    static func recordingsDir(home: URL, outputDir: URL) -> URL? {
        let rec = outputDir.resolvingSymlinksInPath().standardizedFileURL.path
        var h = home.resolvingSymlinksInPath().standardizedFileURL.path
        var holdsHome = false
        while true {
            if rec == h { holdsHome = true; break }
            let parent = (h as NSString).deletingLastPathComponent
            if parent == h { break }
            h = parent
        }
        var isDir: ObjCBool = false
        guard !holdsHome, FileManager.default.fileExists(atPath: outputDir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return outputDir
    }

    static func meetings(in folder: URL) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.sorted().filter(RecordingPaths.isRecordingFolderName).map { folder.appendingPathComponent($0) }.filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    public static func script(_ paths: [URL], waitFor: [Int32], thenIfEmpty: [URL] = []) -> String {
        var lines = ["#!/bin/sh", "# Palaver's uninstall: once Palaver has quit, remove what the user chose."]
        lines += waitFor.map { "while kill -0 \($0) 2>/dev/null; do sleep 0.2; done" }
        lines += paths.map { "rm -rf \(UpdateSwap.sh($0.path))" }
        lines += thenIfEmpty.map { "rmdir \(UpdateSwap.sh($0.path)) 2>/dev/null || :" }  // only when empty
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the script outside what it removes (`work`) and runs it on its own (`run`), so it outlives the app.
    @discardableResult
    public static func start(_ paths: [URL], waitFor: [Int32], work: URL, thenIfEmpty: [URL] = [],
                             run: (String) throws -> Void) throws -> URL {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let path = work.appendingPathComponent("palaver-uninstall.sh")
        try (script(paths, waitFor: waitFor, thenIfEmpty: thenIfEmpty) + "rm -f \(UpdateSwap.sh(path.path))\n")
            .write(to: path, atomically: true, encoding: .utf8)
        try run(path.path)
        return path
    }
}
