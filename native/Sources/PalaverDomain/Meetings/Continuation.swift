// A recording cut by a Palaver restart and the parts that continue it (palaver/continuation.py, issue #47). The
// parts are listed in the first part's `parts.json`; nothing is processed until the call ends, then `process`
// joins them into the first one (gaps marked, Cutting.join) and transcribes the whole meeting.
//
// What a live worker derived (mic.wav, segments, turns, voices) is kept only when it finished every part: a
// worker stopped with the app leaves its part without them, and a meeting stitched from some parts' text would
// miss the rest — so then everything is derived again from the joined audio.
import Darwin
import Foundation
import PalaverCore

public enum Continuation {
    /// What a live worker writes when it finishes a part (live.LiveProcessor.finish).
    static let _LIVE: [KeyPath<RecordingPaths, URL>] = [\.micWav, \.micSegments, \.systemSegments, \.systemTurns,
                                                        \.speakerEmbeddings]
    /// Derived from those, label by label: stale once they are derived again.
    static let _BY_LABEL: [KeyPath<RecordingPaths, URL>] = [\.speakers, \.speakersAuto, \.speakersMerged, \.speakersIgnored,
                                                            \.speakersInferred, \.speakersUnknown]
    /// `process` writes these anew from the joined parts.
    static let _MERGED: [KeyPath<RecordingPaths, URL>] = [\.transcriptJson, \.transcriptMd, \.review]

    /// A line for the session's log: (level, text).
    public typealias Log = (String, String) -> Void

    static func read(_ head: URL) -> PyDict<JSONValue> {
        PythonJSON.read(RecordingPaths(head).parts).flatMap { PyDict($0) } ?? PyDict()
    }

    static func write(_ head: URL, _ data: PyDict<JSONValue>) throws {
        try PythonJSON.write(data.json, to: RecordingPaths(head).parts, indent: 2, ensureAscii: true, via: "parts.json.tmp")
    }

    /// The folders that continue the recording `head`, in order.
    public static func parts(_ head: URL) -> [URL] {
        (read(head)["parts"]?.arrayValue ?? []).compactMap(\.stringValue).map {
            head.deletingLastPathComponent().appendingPathComponent($0, isDirectory: true)
        }
    }

    /// Lists `part` in `head`'s parts.json (once), keeping what else it says. Throws when it can't.
    public static func addPart(_ head: URL, _ part: URL) throws {
        let names = parts(head).map(\.lastPathComponent)
        guard !names.contains(where: { Py.same($0, part.lastPathComponent) }) else { return }
        var data = read(head)
        data["parts"] = .strings(names + [part.lastPathComponent])
        try write(head, data)
    }

    /// Whether `folder` is still being recorded: a running Palaver records into it (daemon.json), or its audio still
    /// grows (the .part files).
    public static func beingRecorded(_ folder: URL, stores: StorePaths = .current()) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { return false }
        return MeetingStatus.status(RecordingPaths(folder)) == "recording" || WorkerPids.recordingInto(folder, stateFile: stores.daemonJson)
    }

    /// `head` and those of its parts still being recorded.
    public static func stillRecording(_ head: URL, stores: StorePaths = .current()) -> [URL] {
        ([head] + parts(head)).filter { beingRecorded($0, stores: stores) }
    }

    /// The meeting's first part, made whole if the app died recording it. One with no audio at all hands the meeting
    /// to its first readable part (and is left as it is, to be seen and trashed).
    public static func recoverHead(_ head: RecordingPaths, log: Log = { _, _ in }) throws -> RecordingPaths {
        if parts(head.folder).isEmpty { return head }
        if try recover(head) { return head }
        let listed = parts(head.folder)
        for (i, folder) in listed.enumerated() {
            var isDir: ObjCBool = false
            let part = RecordingPaths(folder)
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue, try recover(part) else {
                continue
            }
            let rest = listed[(i + 1)...].map(\.lastPathComponent)
            if !rest.isEmpty { try write(folder, PyDict([("parts", .strings(rest))])) }
            unlink(head.parts.path)
            log("WARNING", "\(head.id) has no audio; \(folder.lastPathComponent) is the meeting now")
            return part
        }
        return head
    }

    /// A part the app died recording, made whole as `process` would: the .part files promoted, meta.json rebuilt from
    /// the audio. False when there is nothing to read.
    static func recover(_ part: RecordingPaths) throws -> Bool {
        try Recovery.promoteParts(part)
        if FileManager.default.fileExists(atPath: part.meta.path) {
            Recovery.foldAudioProblems(part)  // a crash after meta.json, before they were folded in
            return true
        }
        return Recovery.synthesizeMeta(part)
    }

    static func liveDone(_ paths: RecordingPaths) -> Bool {
        _LIVE.allSatisfy { FileManager.default.fileExists(atPath: paths[keyPath: $0].path) }
    }

    /// Joins the parts listed in `head` into it; how many. A part that is gone is dropped; one that can't be read
    /// stays listed (and its folder stays), so a later `process` can join it once it is recovered.
    @discardableResult
    public static func joinParts(_ head: RecordingPaths, log: Log = { _, _ in }) throws -> Int {
        try Cutting.finishUnfinishedJoin(head)
        var data = read(head.folder)
        guard data["parts"]?.truthy ?? false else { return 0 }
        guard try recover(head) else {
            log("WARNING", "\(head.id) has no audio to join the parts into")
            return 0
        }
        var found: [RecordingPaths] = [], unreadable: [String] = []
        for folder in parts(head.folder) {
            let part = RecordingPaths(folder)
            var isDir: ObjCBool = false
            if !(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue) {
                log("WARNING", "\(folder.lastPathComponent), a part of \(head.id), is gone")
            } else if try recover(part) {
                found.append(part)
            } else {
                log("WARNING", "\(folder.lastPathComponent), a part of \(head.id), has no audio to join; left for later")
                unreadable.append(folder.lastPathComponent)
            }
        }
        // Decided once, before anything is joined: a join killed half-way and run again must not take what the first
        // one wrote for a live worker's output.
        let complete: Bool
        if let decided = data["complete"], !decided.isNull {
            complete = decided.truthy
        } else {
            complete = ([head] + found).allSatisfy(liveDone)
            data["complete"] = .bool(complete)
            try write(head.folder, data)
        }
        var liveNames: [JSONValue] = [], seen = Set<String>()
        for p in [head] + found {  // the head may hold them all already: a join run again
            guard let named = PythonJSON.read(p.speakersLive)?.arrayValue else { continue }
            for n in named where seen.insert(PythonJSON.dumps(n, sortKeys: true)).inserted { liveNames.append(n) }
        }
        if !liveNames.isEmpty {
            try PythonJSON.write(.array(liveNames), to: head.speakersLive, indent: nil, ensureAscii: false)
        }
        for part in found { try Cutting.join(head, part, keep: head, gapWhy: "restart") }
        let stale = complete ? _MERGED : _MERGED + _LIVE + _BY_LABEL
        for name in stale { unlink(head[keyPath: name].path) }
        if !complete { try SharedMic.forgetLanes(head) }  // rooms were lanes of labels that are gone; a whole-meeting mark stays
        if unreadable.isEmpty {
            unlink(head.parts.path)
        } else {
            try write(head.folder, PyDict([("parts", .strings(unreadable))]))
        }
        if !found.isEmpty {
            log("INFO", "joined \(found.count) part(s) into \(head.id)\(complete ? "" : "; transcribing it whole")")
        }
        return found.count
    }
}
