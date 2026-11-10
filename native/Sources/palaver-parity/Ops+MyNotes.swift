// The Swift side of the `my-notes` parity op (tools/parity/ops.py, section "my_notes (Task 8)").
import Foundation
import PalaverCore
import PalaverDomain

/// The kinds the window's server tells apart (ops.error_kind): a stale save is `changed`, a refused
/// paragraph or image `bad_request`, a missing image `other` (Python's FileNotFoundError).
private struct NotesFailure: ParityErrorKind, CustomStringConvertible {
    let description: String
    let parityKind: String
}

extension ParityOps {
    static let myNotes: [String: Op] = ["my-notes": myNotesOp]

    /// The notes folder an op names: a recording of the side (`key`) or the folder prepared for a calendar
    /// event (`prep`: its key).
    private static func notesFolder(_ side: ParitySide, _ args: JSONValue, key: String = "folder", prep: String = "in_prep") throws -> URL {
        if let event = args[prep]?.stringValue { return MyNotes.prepFolder(event, stores: side.stores) }
        if let name = args[key]?.stringValue, !name.isEmpty { return URL(fileURLWithPath: name, relativeTo: side.recordings).absoluteURL }
        throw BadArgs(description: "my-notes needs \(key) or \(prep)")
    }

    static func myNotesOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        do { return try myNotesAction(side, args) }
        catch let e as MyNotesConflict { throw NotesFailure(description: e.description, parityKind: "changed") }
        catch let e as MyNotesError {
            if case .invalid = e { throw NotesFailure(description: e.description, parityKind: "bad_request") }
            throw NotesFailure(description: e.description, parityKind: "other")
        }
    }

    private static func myNotesAction(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        guard let action = args["action"]?.stringValue else { throw BadArgs(description: "my-notes: unknown action") }
        let folder = try notesFolder(side, args)
        var answer: [(String, JSONValue)] = []
        let fm = FileManager.default
        func string(_ key: String) throws -> String {
            guard let s = args[key]?.stringValue else { throw BadArgs(description: "my-notes \(action) needs \(key)") }
            return s
        }
        func number(_ key: String) throws -> Double {
            guard let d = args[key]?.doubleValue else { throw BadArgs(description: "my-notes \(action) needs \(key)") }
            return d
        }
        switch action {
        case "plant":
            let name = try string("name")
            try fm.createDirectory(at: folder.appendingPathComponent("my-notes"), withIntermediateDirectories: true)
            try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: folder.appendingPathComponent("my-notes/\(name)"))
            if let text = args["text"]?.stringValue {
                try text.write(to: folder.appendingPathComponent("my-notes/\(name).txt"), atomically: false, encoding: .utf8)
            }
        case "add-image":
            let hex = try string("hex")
            let bytes = stride(from: 0, to: hex.count, by: 2).compactMap { UInt8(hex.dropFirst($0).prefix(2), radix: 16) }
            let name = try MyNotes.addImage(folder, data: Data(bytes))
            answer.append(("ext", .string(String(name.split(separator: ".").last!))))
            try fm.removeItem(at: folder.appendingPathComponent("my-notes/\(name)"))
        case "save":
            answer.append(("saved", try MyNotes.save(folder, paragraphs: args["paragraphs"] ?? .null, base: args["base"]?.stringValue)))
        case "put-back":
            guard let items = args["paragraphs"]?.arrayValue else { throw BadArgs(description: "my-notes put-back needs paragraphs") }
            try MyNotes.putBack(folder, items, after: args["after"])
        case "remove-image":
            let (removed, before) = try MyNotes.removeImage(folder, try string("name"))
            answer.append(("removed", removed?.json ?? .null))
            answer.append(("before", before?.json ?? .null))
        case "clear":
            try MyNotes.clear(folder)
        case "adopt":
            answer.append(("adopted", .bool(try MyNotes.adopt(MyNotes.prepFolder(try string("from_prep"), stores: side.stores), folder))))
        case "join":
            let other = try notesFolder(side, args, key: "other", prep: "other_in_prep")
            let keep = (args["keep"]?.stringValue ?? "first") == "first" ? folder : other
            try MyNotes.join(folder, other, keep: keep, offset: try number("offset"))
        case "split":
            try MyNotes.split(folder, try notesFolder(side, args, key: "tail", prep: "tail_in_prep"), at: try number("at"))
        case "document":
            answer.append(("document", MyNotes.document(folder)))
        case "prompt":
            let text = MyNotes.promptText(folder)
            answer.append(("text", .string(text)))
            answer.append(("hash", .string(MyNotes.promptHash(text))))
        default:
            throw BadArgs(description: "my-notes: unknown action '\(action)'")
        }
        answer.append(("paragraphs", .array(MyNotes.load(folder).map(\.json))))
        var files: [String] = []
        if let walk = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) {
            let base = folder.resolvingSymlinksInPath().path + "/"
            for case let url as URL in walk where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(String(url.resolvingSymlinksInPath().path.dropFirst(base.count)))
            }
        }
        answer.append(("files", .strings(files.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })))
        return .object(answer)
    }
}
