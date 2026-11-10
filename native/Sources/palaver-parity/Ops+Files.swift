// The Swift side of the `cutting`, `growing-track`, `wav`, `undo` and `exchange` parity ops (tools/parity/ops.py,
// section "files (Task 21, 22)" and `exchange_op`: export, Task 24; import, Task 25; audio, Task 27), and the
// `storage` and `model-choice` ops (section "storage (Task 28)").
import Foundation
import PalaverCore
import PalaverDomain

extension CuttingError: ParityErrorKind {
    /// ValueError and KeyError are the window's 400; a TypeError its 500 (ops.error_kind).
    var parityKind: String { kind == .type ? "other" : "bad_request" }
}

extension WavError: ParityErrorKind {
    var parityKind: String { "other" }
}

extension UndoGone: ParityErrorKind {
    /// The window's 404 "can't undo this any more".
    var parityKind: String { "gone" }
}

extension UndoChanged: ParityErrorKind {
    /// The window's 409.
    var parityKind: String { "changed" }
}

extension ExchangeExportError: ParityErrorKind {
    /// KeyError and ValueError are the window's 400; TypeError, AttributeError and OverflowError its 500.
    var parityKind: String { kind == .key || kind == .value ? "bad_request" : "other" }
}

extension Exchange.NotReady: ParityErrorKind {
    /// A ValueError: the window's 400.
    var parityKind: String { "bad_request" }
}

extension Exchange.KeptOnThisMac: ParityErrorKind {
    /// Not a ValueError: the window asks the user instead (ops.error_kind says other).
    var parityKind: String { "other" }
}

extension ExchangeRejected: ParityErrorKind {
    /// A ValueError: the window's 400.
    var parityKind: String { "bad_request" }
}

extension Exchange.Collision: ParityErrorKind {
    /// Not a ValueError: the window asks the user instead (ops.error_kind says other).
    var parityKind: String { "other" }
}

extension StorageError: ParityErrorKind {
    /// A ValueError is the window's 400; a TypeError its 500.
    var parityKind: String { kind == .value ? "bad_request" : "other" }
}

extension ModelChoice.NoProvider: ParityErrorKind {
    /// A ValueError: the window's 400.
    var parityKind: String { "bad_request" }
}

extension ParityOps {
    static let files: [String: Op] = ["cutting": cuttingOp, "growing-track": growingTrackOp, "wav": wavOp, "undo": undoOp,
                                      "exchange": exchangeOp, "storage": storageOp, "model-choice": modelChoiceOp]

    private static func recording(_ side: ParitySide, _ args: JSONValue, _ key: String) throws -> RecordingPaths {
        try calendarFolder(side, .object([("folder", args[key] ?? .null)]))
    }

    /// A path under the output dir, relative to it.
    private static func relative(_ side: ParitySide, _ url: URL) -> String {
        let root = side.recordings.path.hasSuffix("/") ? side.recordings.path : side.recordings.path + "/"
        return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
    }

    private static func at(_ args: JSONValue) throws -> PyNum {
        guard let at = PyNum(args["at"]) else { throw BadArgs(description: "cutting: at is no number") }
        return at
    }

    static func cuttingOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let action = args["action"]?.stringValue
        switch action {
        case "plant":
            guard let name = args["folder"]?.stringValue, case .object(let files)? = args["files"] else {
                throw BadArgs(description: "cutting plant: folder and files")
            }
            let folder = side.recordings.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (file, value) in files {
                try PythonJSON.write(value, to: folder.appendingPathComponent(file), indent: nil, ensureAscii: true)
            }
            return .object([("planted", .strings(Py.stableSorted(files.map(\.0), by: Py.less)))])
        case "keeper", "join":
            let first = try recording(side, args, "first"), second = try recording(side, args, "second")
            if action == "keeper" { return .object([("keeper", .string(try Cutting.keeper(first, second).id))]) }
            let keep = args["keep"]?.truthy == true ? try recording(side, args, "keep") : nil
            let kept = try Cutting.join(first, second, keep: keep, gapWhy: args["gap_why"]?.stringValue)
            return .object([("kept", .string(kept.id))])
        default: break
        }
        let paths = try recording(side, args, "folder")
        switch action {
        case "span":
            let (start, duration) = try Cutting.span(paths)
            return .object([("start", .string(start.iso)), ("duration", .double(duration))])
        case "neighbours":
            let (previous, next) = try Cutting.neighbours(paths)
            return .object([("previous", .str(previous)), ("next", .str(next))])
        case "split":
            return .object([("tail", .string(try Cutting.split(paths, at: at(args)).id))])
        case "discard":
            guard let which = args["side"]?.stringValue else { throw BadArgs(description: "cutting discard: side") }
            return .object([("gone", .string(relative(side, try Cutting.discard(paths, at: at(args), side: which))))])
        case "trash":
            return .object([("to", .string(relative(side, try Cutting.trash(paths))))])
        case "finish-join":
            try Cutting.finishUnfinishedJoin(paths)
            return .object([])
        case "suggest-trim":
            let trim = try Cutting.suggestTrim(paths)
            return .object([("trim", .array(trim)), ("trim_at", .array(trim.map { $0["at"] ?? .null }))])
        case "suggest-cut":
            let events = try (args["events"]?.arrayValue ?? side.events).map { try CalendarEvent(json: $0) }
            let cut = try Cutting.suggestCut(paths, events: events)
            return .object([("cut", cut ?? .null), ("cut_at", cut?["at"] ?? .null)])
        default:
            throw BadArgs(description: "cutting: unknown action \(args["action"].map { PythonJSON.dumps($0) } ?? "None")")
        }
    }

    private static func track(_ paths: RecordingPaths, _ args: JSONValue) throws -> URL {
        switch args["track"]?.stringValue {
        case "system": return paths.systemWav
        case "mic_raw": return paths.micRawWav
        case "mic": return paths.micWav
        default: throw BadArgs(description: "track: system, mic_raw or mic")
        }
    }

    static func growingTrackOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let paths = try recording(side, args, "folder")
        guard case .int(let start)? = args["start"], case .int(let end)? = args["end"] else { throw BadArgs(description: "growing-track: start, end") }
        let track = GrowingTrack(final: try track(paths, args))
        return .object([("available", .int(track.available())), ("samples", .array(try track.readInt16(start, end).map { .int(Int($0)) }))])
    }

    static func wavOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let url = try track(try recording(side, args, "folder"), args)
        let info = try Wav16.info(url)
        var start = 0, frames = 0
        if case .int(let s)? = args["start"] { start = s }
        if case .int(let n)? = args["frames"] { frames = n }
        let samples = try Wav16.read(url, start: start, frames: frames)
        return .object([("frames", .int(info.frames)), ("rate", .int(info.rate)), ("channels", .int(info.channels)),
                        ("samples", .array(samples.map { .int(Int($0)) }))])
    }

    // MARK: - undo (Task 22)

    /// `rel` (relative to the side, no "..") under the side's root.
    private static func sidePath(_ side: ParitySide, _ value: JSONValue?) throws -> URL {
        guard let rel = value?.stringValue, !rel.isEmpty, !rel.hasPrefix("/"), !rel.split(separator: "/").contains("..") else {
            throw BadArgs(description: "not a path in the side: \(value.map { PythonJSON.dumps($0) } ?? "None")")
        }
        return URL(fileURLWithPath: side.root.path + "/" + rel)
    }

    /// The snapshot a step means: `token` as given; `of`: the one with that label; `broken`: the one whose manifest is
    /// no JSON (ops.py `_undo_token`).
    private static func undoToken(_ side: ParitySide, _ args: JSONValue) throws -> String {
        if let token = args["token"]?.stringValue { return token }
        let root = side.recordings.appendingPathComponent(".trash/.undo")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in Py.stableSorted(names, by: Py.less) {
            guard let data = FileManager.default.contents(atPath: root.path + "/" + name + "/manifest.json"),
                  let manifest = try? PythonJSON.parse(data) else {
                if args["broken"]?.truthy == true { return name }
                continue
            }
            if let of = args["of"], let label = manifest["label"], PythonJSON.equal(label, of) { return name }
        }
        throw BadArgs(description: "undo: no snapshot \(args["of"].map { PythonJSON.dumps($0) } ?? "None")")
    }

    static func undoOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let action = args["action"]?.stringValue, out = side.recordings
        switch action {
        case "take":
            let token = try Undo.take(out, args["label"]?.stringValue ?? "", meetings: (args["meetings"]?.arrayValue ?? []).compactMap(\.stringValue),
                                      audio: args["audio"]?.truthy ?? false, speakerFilesOfAll: args["speaker_files_of_all"]?.truthy ?? false,
                                      stores: try (args["stores"]?.arrayValue ?? []).map { try sidePath(side, $0) })
            return .object([("token", .string(token))])
        case "edit":
            let url = try sidePath(side, args["path"])
            if let text = args["text"]?.stringValue {
                guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8)) else { throw BadArgs(description: "edit: \(url.path)") }
            } else {
                try FileManager.default.removeItem(at: url)
            }
            return .object([])
        case "prune":
            var keep = Undo.KEEP, hours = 24.0
            if case .int(let k)? = args["keep"] { keep = k }
            if let h = args["max_age_hours"]?.doubleValue { hours = h }
            Undo.prune(out, keep: keep, maxAge: hours * 3600)
            let left = (try? FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent(".trash/.undo").path)) ?? []
            return .object([("left", .int(left.count))])
        case "fingerprint":
            let url = try sidePath(side, args["path"])
            if args["store"]?.truthy == true { return .object([("fingerprint", .string(try Undo.storeFingerprint(url)))]) }
            return .object([("fingerprint", .string(try Undo.fingerprint(url, partial: args["partial"]?.truthy ?? false)))])
        default: break
        }
        let token = try undoToken(side, args)
        switch action {
        case "break":
            let manifest = out.appendingPathComponent(".trash/.undo/\(token)/manifest.json")
            guard FileManager.default.createFile(atPath: manifest.path, contents: Data("{not json".utf8)) else { throw BadArgs(description: "break") }
            return .object([])
        case "note":
            guard let extra = args["extra"].flatMap(PyDict<JSONValue>.init) else { throw BadArgs(description: "undo note: extra") }
            try Undo.note(out, token, extra)
            return .object([])
        case "extra": return .object([("extra", try Undo.extra(out, token).json)])
        case "label": return .object([("label", .string(try Undo.label(out, token)))])
        case "stores": return .object([("stores", .strings(try Undo.stores(out, token).map(\.path)))])
        case "sealed":
            try Undo.sealed(out, token)
            return .object([])
        case "moved":
            try Undo.moved(out, token, src: try sidePath(side, args["src"]), dst: try sidePath(side, args["dst"]))
            return .object([])
        case "created":
            try Undo.created(out, token, (args["ids"]?.arrayValue ?? []).compactMap(\.stringValue))
            return .object([])
        case "created-ids": return .object([("created", .strings(try Undo.createdIds(out, token)))])
        case "restore":
            return .object([("ids", .strings(try Undo.restore(out, token, check: args["check"]?.truthy ?? true)))])
        default:
            throw BadArgs(description: "undo: unknown action \(args["action"].map { PythonJSON.dumps($0) } ?? "None")")
        }
    }

    // MARK: - exchange (Tasks 24, 25)

    private static func matchJSON(_ m: ExchangeMatch?) -> JSONValue {
        m.map { .object([("id", .string($0.id)), ("how", .string($0.how)), ("own", .bool($0.own))]) } ?? .null
    }

    /// ops.py `exchange_op`: `export`, `file-name`, `free-name`, `sweep` and `leftover`; `import`, `match`, `settle`
    /// and `decide-voices`.
    static func exchangeOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let action = args["action"]?.stringValue
        switch action {
        case "leftover":
            let path = try sidePath(side, args["path"]).path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try "x".write(toFile: path + "/part", atomically: false, encoding: .utf8)
            let hours = args["hours_ago"]?.doubleValue ?? 0
            let when = Date().addingTimeInterval(-hours * 3600)
            try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: path)
            return .object([])
        case "sweep":
            let downloads = args["downloads"]?.truthy == true ? side.root.appendingPathComponent("home/Downloads") : nil
            Exchange.sweep(side.recordings, downloads: downloads, olderThan: args["older_than"]?.doubleValue ?? 3600)
            return .object([])
        case "free-name":
            guard let name = args["name"]?.stringValue else { throw BadArgs(description: "exchange free-name: name") }
            return .object([("name", .string(Exchange.freeName(try sidePath(side, args["in"]), name).lastPathComponent))])
        case "plant-golden":
            // The goldens of the Swift domain tests, beside this source in the checkout.
            let goldens = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Tests/PalaverDomainTests/Goldens")
            guard let name = args["name"]?.stringValue, !name.contains("/"),
                  let data = FileManager.default.contents(atPath: goldens.appendingPathComponent(name).path) else {
                throw BadArgs(description: "exchange plant-golden: no golden \(args["name"].map { PythonJSON.dumps($0) } ?? "None")")
            }
            let dest = try sidePath(side, args["dest"])
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest)
            return .object([])
        default: break
        }
        let user = args["user_name"]?.stringValue ?? side.userName
        switch action {
        case "match":
            let package = try Exchange.readPackage(try sidePath(side, args["file"]))
            return .object([("match", matchJSON(try Exchange.findMatch(side.recordings, package)))])
        case "import":
            let stores = side.stores, recordings = side.recordings
            let done = try Exchange.importPackage(
                recordings, try sidePath(side, args["file"]), userName: user, separate: args["separate"]?.truthy ?? false,
                calendar: args["calendar"]?.truthy == true ? try provider(side) : nil,
                after: args["settle"]?.truthy == true ? { try Exchange.settle(recordings, $0, userName: user, stores: stores) } : nil,
                stores: stores)
            return .object([("id", .string(done.id)), ("from", .string(done.sender)), ("matched", matchJSON(done.matched)),
                            ("voices", .array(done.voices)), ("names", .object(done.names.map { ($0.key, .string($0.value)) })),
                            ("warnings", .strings(done.warnings))])
        default: break
        }
        let paths = try recording(side, args, "folder")
        switch action {
        case "settle":
            try Exchange.settle(side.recordings, paths.folder.lastPathComponent, userName: user, stores: side.stores)
            return .object([])
        case "decide-voices":
            guard let add = args["add"]?.boolValue else { throw BadArgs(description: "exchange decide-voices: add") }
            return .object([("learned", .strings(try Exchange.decideVoices(paths, add: add, userName: user, stores: side.stores)))])
        case "file-name":
            return .object([("name", .string(Exchange.fileName(paths, stores: side.stores)))])
        case "export":
            let projects = try (args["projects"]?.arrayValue ?? []).map { p -> String in
                guard let s = p.stringValue else { throw BadArgs(description: "exchange export: projects are names") }
                return s
            }
            let out = try Exchange.exportMeeting(
                paths, dest: try sidePath(side, args["dest"]), userName: args["user_name"]?.stringValue ?? side.userName,
                notes: args["notes"]?.truthy ?? true, voices: args["voices"]?.truthy ?? false,
                audio: args["audio"]?.truthy ?? false, confirmLocal: args["confirm_local"]?.truthy ?? false,
                projects: projects, stores: side.stores)
            let zip = try ZipReader(url: out, maxDirectoryBytes: ExchangeZip.MAX_DIRECTORY_BYTES)
            var entries: [JSONValue] = [], contents: [(String, JSONValue)] = []
            for entry in zip.entries {
                if entry.name.hasPrefix("audio/") {
                    // The encoders differ (ops.py): what the audio holds, as read here.
                    entries.append(.array([.string(entry.name), .int(Int(entry.method)), .string("<audio>")]))
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("parity-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: file) }
                    try zip.data(entry, limit: ExchangeZip.MAX_AUDIO_BYTES).write(to: file)
                    let source = try ExchangeAudio.open(file)
                    defer { source.close() }
                    contents.append((entry.name, .object([("rate", .int(source.rate)), ("channels", .int(source.channels)),
                                                          ("frames", .int(source.frames))])))
                    continue
                }
                entries.append(.array([.string(entry.name), .int(Int(entry.method)), .int(Int(entry.size))]))
                var value = try PythonJSON.parse(try zip.data(entry, limit: ExchangeZip.MAX_JSON_BYTES))
                if entry.name == "manifest.json", case .object(var fields) = value {
                    if let i = fields.firstIndex(where: { $0.0 == "exported_at" }) { fields[i].1 = .bool(fields[i].1.truthy) }
                    if let i = fields.firstIndex(where: { $0.0 == "files" }), case .object(var files) = fields[i].1 {
                        for j in files.indices where files[j].0.hasPrefix("audio/") {
                            if case .object(var listed) = files[j].1 {
                                for k in listed.indices where listed[k].0 == "sha256" || listed[k].0 == "bytes" {
                                    listed[k].1 = .bool(listed[k].1.truthy)
                                }
                                files[j].1 = .object(listed)
                            }
                        }
                        fields[i].1 = .object(files)
                    }
                    value = .object(fields)
                }
                contents.append((entry.name, value))
            }
            return .object([("name", .string(out.lastPathComponent)), ("entries", .array(entries)),
                            ("contents", .object(contents))])
        default:
            throw BadArgs(description: "exchange: unknown action \(args["action"].map { PythonJSON.dumps($0) } ?? "None")")
        }
    }

    // MARK: - storage (Task 28)

    private static func config(_ side: ParitySide) -> Config { Config.load(side.stores.configToml) }

    /// `now`: a naive local ISO time ("2026-11-04T09:00:00"), read in this process's time zone (the side's TZ); else now.
    private static func naiveNow(_ args: JSONValue) throws -> Date {
        guard let text = args["now"]?.stringValue else { return Date() }
        let n = text.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        guard n.count == 6, let date = cal.date(from: DateComponents(year: n[0], month: n[1], day: n[2], hour: n[3],
                                                                    minute: n[4], second: n[5])) else {
            throw BadArgs(description: "now: YYYY-MM-DDTHH:MM:SS")
        }
        return date
    }

    private static func plantRoot(_ side: ParitySide, _ where_: JSONValue?) throws -> URL {
        let w = where_?.stringValue ?? ""
        if w.hasPrefix("cache:") { return ModelCatalog.cacheDir(String(w.dropFirst("cache:".count)), stores: side.stores) }
        if w == "models" { return side.stores.modelsDir }
        if w == "support" { return side.stores.support }
        throw BadArgs(description: "storage plant: where is cache:<repo>, models or support")
    }

    private static func int(_ args: JSONValue, _ key: String) throws -> Int {
        guard case .int(let n)? = args[key] else { throw BadArgs(description: "\(key) is no int") }
        return n
    }

    static func storageOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let action = args["action"]?.stringValue
        switch action {
        case "plant":
            let root = try plantRoot(side, args["where"])
            guard case .object(let files)? = args["files"] else { throw BadArgs(description: "storage plant: files") }
            for (rel, size) in files {
                guard !rel.isEmpty, !rel.hasPrefix("/"), !rel.split(separator: "/").contains(".."), case .int(let n) = size else {
                    throw BadArgs(description: "storage plant: not a relative path: \(rel)")
                }
                let url = root.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(count: n).write(to: url)
            }
            return .object([("planted", .strings(Py.stableSorted(files.map(\.0), by: Py.less)))])
        case "summary":
            return Storage.summary(outputDir: side.recordings, config: config(side), now: try naiveNow(args), stores: side.stores)
        case "models":
            return .array(Storage.models(config: config(side), stores: side.stores))
        case "delete-model":
            guard let id = args["id"]?.stringValue else { throw BadArgs(description: "delete-model: id") }
            return .object([("freed", .int(try Storage.deleteModel(id, config: config(side), stores: side.stores)))])
        case "drop-retired":
            return .object([("freed", .int(Storage.dropRetired(config: config(side), stores: side.stores)))])
        case "audio-days":
            return .object([("days", .int(Storage.audioDays(stores: side.stores)))])
        case "set-audio-days":
            try Storage.setAudioDays(args["days"] ?? .null, stores: side.stores)
            return .object([("days", .int(Storage.audioDays(stores: side.stores)))])
        case "older-than":
            return .strings(Storage.olderThan(side.recordings, days: try int(args, "days"), now: try naiveNow(args)).map(\.id))
        case "drop-old-audio":
            let (count, freed) = try Storage.dropOldAudio(side.recordings, days: try int(args, "days"), now: try naiveNow(args))
            return .object([("meetings", .int(count)), ("bytes", .int(freed))])
        default: break
        }
        let paths = try recording(side, args, "folder")
        switch action {
        case "meeting":
            return .object([("audio", .strings(Storage.audioFiles(paths).map(\.lastPathComponent))),
                            ("audio_bytes", .int(Storage.audioBytes(paths))), ("can_drop", .bool(Storage.canDrop(paths))),
                            ("deleted", Storage.deleted(paths)?["bytes"] ?? .null)])
        case "drop-audio":
            return .object([("freed", .int(try Storage.dropAudio(paths)))])
        default:
            throw BadArgs(description: "storage: unknown action \(args["action"].map { PythonJSON.dumps($0) } ?? "None")")
        }
    }

    static func modelChoiceOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let cfg = config(side)
        switch args["action"]?.stringValue {
        case "save":
            guard case .object(let changes)? = args["settings"] else { throw BadArgs(description: "save: settings") }
            try SettingsFile.update(changes, stores: side.stores)
            return .object([])
        case "keep-local":
            try LocalOnly.set(try recording(side, args, "folder").folder, on: args["on"]?.truthy == true)
            return .object([])
        case "choice-for":
            let folders = try (args["folders"]?.arrayValue ?? []).map { try recording(side, .object([("folder", $0)]), "folder").folder }
            guard let feature = args["feature"]?.stringValue else { throw BadArgs(description: "choice-for: feature") }
            return .object([("choice", .string(ModelChoice.choiceFor(feature: feature, folders: folders, config: cfg,
                                                                     stores: side.stores)))])
        case "local-model":
            return .object([("model", .string(ModelChoice.localModel(config: cfg, stores: side.stores)))])
        case "memory-gb":
            guard let feature = args["feature"]?.stringValue else { throw BadArgs(description: "memory-gb: feature") }
            let folder = args["folder"]?.truthy == true ? try recording(side, args, "folder").folder : nil
            return .object([("gb", .double(ModelChoice.memoryGB(feature: feature, folder: folder, config: cfg, stores: side.stores)))])
        case "settings-of":
            guard let pid = args["provider"]?.stringValue else { throw BadArgs(description: "settings-of: provider") }
            return try ModelChoice.settingsOf(pid, defaults: ModelChoice.providerDefaults(config: cfg, pid: pid), stores: side.stores).json
        case "labels":
            return .object(ModelChoice.providerLabels.map { ($0.key, .string($0.value)) })
        default:
            throw BadArgs(description: "model-choice: unknown action \(args["action"].map { PythonJSON.dumps($0) } ?? "None")")
        }
    }
}
