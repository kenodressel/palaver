// ⌘Z in the window (api.py `undo_change`, `_undo_own_file`, `_undo_shared`, `_derive_shared`, `_undo_my_notes`):
// the change a token stands for rolled back, then what depends on the files put back made again.
//
// `Undo.restore` takes the store locks of what it puts back itself and is called holding none of them; it runs under
// the in-process locks api.py holds around it (`_PROJECTS_LOCK`, `_GLOSSARY_LOCK`, `_MY_NOTES_LOCK`), as does what
// follows it (names, projects, transcript.md, the notes' paragraphs).
import Foundation
import PalaverCore
import PalaverDomain

public enum UndoRoute {
    /// `undo_change`: roll back the change `token` stands for; the meetings it touched. `UndoGone` (404) when there is
    /// no such snapshot, `UndoChanged` (409) when something changed since.
    public static func undoChange(_ app: ServerApp, token: String) throws -> [String] {
        app.background.settle(ChangesAPI.FOLLOW_UP_WAIT)  // what the change started after its answer is done first (#31)
        let out = app.outputDir
        let label = try Undo.label(out, token)
        if label.hasPrefix("my-notes") {  // the user's own notes: nothing depends on them
            try undoMyNotes(app, token)
            return []
        }
        if label == "shared" { return try undoShared(app, token) }
        if label == "title" || label == "unknown" { return try undoOwnFile(app, token) }  // nothing depends on them but what reads them
        if label == "line speaker" {  // and transcript.md, made from it
            return try app.projectsLock.withLock {
                let ids = try undoOwnFile(app, token)
                for id in ids {
                    let paths = RecordingPaths(out.appendingPathComponent(id, isDirectory: true))
                    if [paths.systemTurns, paths.transcriptJson, paths.meta].allSatisfy(MeetingsAPI.exists) {
                        try Speakers.saveSpeakerNames(paths, try Speakers.loadSpeakerNames(paths), learn: false, stores: app.stores)
                    }
                }
                return ids
            }
        }
        let imported = label == "import" ? try Undo.createdIds(out, token) : []
        return try app.projectsLock.withLock {
            try app.glossaryLock.withLock {
                let glossaryBack = try Undo.stores(out, token).contains { samePath($0, app.stores.glossary) }
                let ids = try Undo.restore(out, token)
                if !imported.isEmpty {
                    let bank = VoiceBank(directory: app.stores.voices)
                    for id in imported { _ = try bank.removeMeeting(id) }  // what the bank learned from it goes with it (#58)
                }
                let there = ids.filter { MeetingsAPI.isDirectory(out.appendingPathComponent($0, isDirectory: true)) }
                // A recording still being processed has no names to redo.
                let ready = there.map { RecordingPaths(out.appendingPathComponent($0, isDirectory: true)) }
                    .filter { MeetingsAPI.exists($0.systemTurns) && MeetingsAPI.exists($0.transcriptJson) }
                let thereKeys = Set(there.map(ScalarKey.init))
                try ChangesAPI.afterCut(app, changed: ready, gone: ids.filter { !thereKeys.contains(ScalarKey($0)) })
                if glossaryBack {
                    try ChangesAPI.rerender(app, try MeetingsAPI.listMeetings(app: app).compactMap { $0["id"]?.stringValue })
                }
                Undo.prune(out)
                return ids
            }
        }
    }

    /// `Path ==`: the same path, spelled by code points.
    static func samePath(_ a: URL, _ b: URL) -> Bool { Py.same(a.standardizedFileURL.path, b.standardizedFileURL.path) }

    /// `_undo_own_file`: the title (or the voices nobody knows) as it was, unless the meeting is gone (to the trash,
    /// into another): then there is no folder to put it back in.
    static func undoOwnFile(_ app: ServerApp, _ token: String) throws -> [String] {
        let id = meetingOf(try Undo.extra(app.outputDir, token))
        guard !id.isEmpty, MeetingsAPI.isDirectory(app.outputDir.appendingPathComponent(id, isDirectory: true)) else {
            throw UndoChanged(id)
        }
        _ = try Undo.restore(app.outputDir, token)
        Undo.prune(app.outputDir)
        return [id]
    }

    /// `str(extra.get("meeting") or "")`.
    static func meetingOf(_ extra: PyDict<JSONValue>) -> String {
        guard let v = extra["meeting"], v.truthy else { return "" }
        return Py.str(v)
    }

    /// `_undo_shared`: a meeting's marks of a shared microphone (#56) as they were, and what follows from them derived
    /// again (`_derive_shared`).
    static func undoShared(_ app: ServerApp, _ token: String) throws -> [String] {
        let extra = try Undo.extra(app.outputDir, token)
        let id = meetingOf(extra)
        let folder = app.outputDir.appendingPathComponent(id, isDirectory: true)
        try app.projectsLock.withLock {
            // Looked at under the lock, as api.py does: a trash or cut that held it may have just taken the folder.
            guard !id.isEmpty, MeetingsAPI.isDirectory(folder) else { throw UndoChanged(id) }  // gone to the trash, or cut away
            _ = try Undo.restore(app.outputDir, token)
            let paths = RecordingPaths(folder)
            let derive = extra["derive"]?.truthy ?? true
            if [paths.transcriptJson, paths.systemTurns, paths.meta].allSatisfy(MeetingsAPI.exists) {
                try Speakers.saveSpeakerNames(paths, try Speakers.loadSpeakerNames(paths), learn: derive, stores: app.stores)
            }
            if derive { try People.refreshRecognition(outputDir: app.outputDir, userName: app.userName, stores: app.stores) }
            Undo.prune(app.outputDir)
        }
        return [id]
    }

    /// `_undo_my_notes`: an image deleted or the notes cleared — the files back, and the paragraphs taken out merged
    /// into the notes as they are now.
    static func undoMyNotes(_ app: ServerApp, _ token: String) throws {
        let extra = try Undo.extra(app.outputDir, token)
        guard let given = extra["folder"], given.truthy else { throw UndoGone(token) }
        let folder = URL(fileURLWithPath: Py.str(given), isDirectory: true)
        guard MeetingsAPI.isDirectory(folder) else { throw UndoGone(token) }  // the meeting went (to the trash, into another)
        try app.myNotesLock.withLock {
            _ = try Undo.restore(app.outputDir, token)
            let paragraphs = extra["paragraphs"].flatMap { $0.truthy ? $0.arrayValue : nil } ?? []
            try MyNotes.putBack(folder, paragraphs, after: extra["after"])
        }
        Undo.prune(app.outputDir)
    }
}
