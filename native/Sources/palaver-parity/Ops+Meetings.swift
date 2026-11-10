// The Swift side of the `meetings` parity ops (tools/parity/ops.py, section "meetings").
import Foundation
import PalaverCore
import PalaverDomain

/// What the window's server answers 404 for (ops.error_kind: not_found).
struct NotFound: ParityErrorKind, CustomStringConvertible {
    let description: String
    var parityKind: String { "not_found" }
}

extension ParityOps {
    static let meetings: [String: Op] = [
        "models-roundtrip": modelsRoundtrip, "meeting-status": meetingStatus, "meeting-markers": meetingMarkers,
    ]

    /// The recording folders of the side's output dir, by name.
    static func meetingFolders(_ side: ParitySide) -> [URL] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: side.recordings.path)) ?? []
        return names.sorted().compactMap { name -> URL? in
            var isDir: ObjCBool = false
            let url = side.recordings.appendingPathComponent(name, isDirectory: true)
            guard RecordingPaths.isRecordingFolderName(name), fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue
            else { return nil }
            return url
        }
    }

    /// Every meeting's segments, turns and utterances read into the models and written again
    /// (indent 2); a file the models can't read is left as it is.
    static func modelsRoundtrip(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        typealias Convert = (JSONValue) throws -> JSONValue
        let segment: Convert = { try Segment(json: $0).json }
        let turn: Convert = { try SpeakerTurn(json: $0).json }
        let utterance: Convert = { try Utterance(json: $0).json }
        var rewritten = 0, skipped = 0
        for folder in meetingFolders(side) {
            let p = RecordingPaths(folder)
            for (file, convert) in [(p.micSegments, segment), (p.systemSegments, segment), (p.systemTurns, turn),
                                    (p.transcriptJson, utterance)] {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                guard let data = PythonJSON.read(file), let items = data.arrayValue,
                      let converted = try? items.map(convert) else { skipped += 1; continue }
                try PythonJSON.write(.array(converted), to: file, indent: 2, ensureAscii: true)
                rewritten += 1
            }
        }
        return .object([("rewritten", .int(rewritten)), ("skipped", .int(skipped))])
    }

    /// Each meeting's status (`later` seconds from now), whether it stays on this Mac, why it has no
    /// transcript, whether its system track still wants the cloud.
    static func meetingStatus(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let now = Date().addingTimeInterval(args["later"]?.doubleValue ?? 0)
        return .object(meetingFolders(side).map { folder in
            let p = RecordingPaths(folder)
            return (folder.lastPathComponent, .object([
                ("status", .string(MeetingStatus.status(p, now: now))),
                ("local_only", .bool(LocalOnly.isLocalOnly(folder))),
                ("failed", ProcessState.read(p)?["reason"] ?? .null),
                ("wants_cloud", .bool(TranscriptionMarker.wantsCloud(p))),
            ]))
        })
    }

    /// The small marker files: local_only.json, failed.json, transcription.json of one meeting.
    static func meetingMarkers(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let name = args["folder"]?.stringValue ?? ""
        let folder = side.recordings.appendingPathComponent(name, isDirectory: true)
        var isDir: ObjCBool = false
        guard !name.isEmpty, FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw NotFound(description: "no meeting \(name)")
        }
        let p = RecordingPaths(folder)
        if let on = args["local_only"] { try LocalOnly.set(folder, on: on.truthy) }
        if let failed = args["failed"] {
            if failed.isNull { ProcessState.clear(p) } else {
                try ProcessState.mark(p, reason: failed["reason"]?.stringValue ?? "",
                                      missing: (failed["missing"]?.arrayValue ?? []).compactMap(\.stringValue),
                                      error: failed["error"]?.stringValue)
            }
        }
        if let marker = args["transcription"] {
            var info: [(String, JSONValue)] = []
            if case .object(let fields)? = marker["info"] { info = fields }
            try TranscriptionMarker.write(p, track: marker["track"]?.stringValue ?? "", info: info)
        }
        return .object([("wants_cloud", .bool(TranscriptionMarker.wantsCloud(p)))])
    }
}
