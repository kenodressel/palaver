// The Swift side of the `speakers`, `voices` (Task 12), `people`, `inference` and `hints` (Task 13) parity ops
// (tools/parity/ops.py, section "speakers"); `shared-mic` is Task 14's.
import Foundation
import PalaverCore
import PalaverDomain

/// What Python raises as ValueError for a speaker change (a label merged into itself): the window answers 400.
struct SpeakersBadRequest: ParityErrorKind, CustomStringConvertible {
    let description: String
    var parityKind: String { "bad_request" }
}

extension ParityOps {
    static let speakers: [String: Op] = ["speakers": speakersOp, "voices": voicesOp, "people": peopleOp, "inference": inferenceOp,
                                         "hints": hintsOp, "shared-mic": sharedMicOp]

    private static func text(_ args: JSONValue, _ key: String) throws -> String {
        guard let s = args[key]?.stringValue else { throw BadArgs(description: "speakers: \(key) is missing") }
        return s
    }

    /// A voice a step names: a list of numbers, or `{"folder", "label"}`: that speaker's in speaker_embeddings.json.
    private static func voice(_ side: ParitySide, _ ref: JSONValue?) throws -> [Double] {
        func numbers(_ v: JSONValue?) throws -> [Double] {
            guard let items = v?.arrayValue else { throw BadArgs(description: "speakers: no voice") }
            return try items.map { guard let d = $0.doubleValue else { throw BadArgs(description: "speakers: no voice") }; return d }
        }
        if case .array? = ref { return try numbers(ref) }
        guard let ref, let label = ref["label"]?.stringValue else { throw BadArgs(description: "speakers: no voice") }
        let paths = try calendarFolder(side, ref)
        return try numbers(PythonJSON.read(paths.speakerEmbeddings)?[label])
    }

    private static func strings(_ d: PyDict<String>) -> JSONValue { .object(d.map { ($0.key, .string($0.value)) }) }
    private static func speakerState(_ paths: RecordingPaths) throws -> JSONValue {
        let turns = FileManager.default.fileExists(atPath: paths.systemTurns.path)
            ? try (PythonJSON.read(paths.systemTurns)?.arrayValue ?? []).map { try SpeakerTurn(json: $0) } : []
        var shown: JSONValue = .null, corrected: JSONValue = .null
        if FileManager.default.fileExists(atPath: paths.transcriptJson.path) {
            let utterances = try (PythonJSON.read(paths.transcriptJson)?.arrayValue ?? []).map { try Utterance(json: $0) }
            shown = .strings(SharedMic.shown(paths, try Speakers.withoutIgnored(paths, utterances)).map(\.speaker))
            corrected = .array(try Speakers.withLineSpeakers(paths, utterances).map { u in
                .array([.string(u.speaker), .str(u.label), .str(u.saidBy),
                        u.heardAs.map { .array([.string($0.track), .str($0.label)]) } ?? .null])
            })
        }
        let merges = Speakers.loadMerges(paths)
        return .object([
            ("names", strings(try Speakers.loadSpeakerNames(paths))),
            ("merges", strings(merges)),
            ("ignored", .strings(Speakers.loadIgnored(paths))),
            ("unknown", .strings(Speakers.loadUnknown(paths))),
            ("rejected", .object(Speakers.loadRejectedNames(paths).map { ($0.key, .strings($0.value)) })),
            ("inferred", strings(try Speakers.loadInferredNames(paths))),
            ("recognized", .object(try Speakers.loadRecognizedNames(paths).map { ($0.key, .array([.string($0.value.0), .double($0.value.1)])) })),
            ("in_effect", strings(try Speakers.namesInEffect(paths))),
            ("live", .array(Speakers.loadLiveNames(paths))),
            ("talk", .object(Speakers.talkSeconds(Speakers.mergedTurns(turns, merges)).map { ($0.key, .double($0.value)) })),
            ("longest", .object(Speakers.longestTurns(turns).map { ($0.key, $0.value.json) })),
            ("shared", .object([
                ("display", strings(SharedMic.display(paths))),
                ("rooms", strings(SharedMic.roomNames(paths))),
                ("meeting", .bool(SharedMic.meetingMarked(paths))),
                ("from_series", .bool(SharedMic.fromSeries(paths))),
                ("mic_room", .str(SharedMic.micRoom(paths))),
                ("mic_display", .str(SharedMic.micDisplay(paths))),
                ("marked", .bool(SharedMic.marked(paths))),
                ("system_speech", .bool(SharedMic.systemSpeech(paths))),
            ])),
            ("shown", shown),
            ("lines", .array(Speakers.loadLineSpeakers(paths))),
            ("corrected", corrected),
        ])
    }

    static func speakersOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        do { return try speakersAction(side, args) }
        catch let e as SpeakersValueError { throw SpeakersBadRequest(description: e.description) }
    }

    private static func speakersAction(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let action = args["action"]?.stringValue
        let paths = try calendarFolder(side, args)
        let on = args["on"]?.boolValue ?? true
        var answer: [(String, JSONValue)] = []
        switch action {
        case "save-names":
            let names = PyDict((args["names"].flatMap { PyDict<JSONValue>($0) } ?? PyDict()).map { ($0.key, $0.value.stringValue ?? "") })
            let enrolled = try Speakers.saveSpeakerNames(paths, names, learn: args["learn"]?.boolValue ?? true, stores: side.stores)
            answer.append(("enrolled", .int(enrolled)))
        case "merge":
            try Speakers.mergeSpeakers(paths, try text(args, "label"), into: args["into"]?.stringValue, stores: side.stores)
        case "ignore": try Speakers.setIgnored(paths, try text(args, "label"), on)
        case "unknown": try Speakers.setUnknown(paths, try text(args, "label"), on)
        case "reject": try Speakers.setRejectedName(paths, try text(args, "label"), try text(args, "name"), on)
        case "save-shared":
            try SharedMic.save(paths, args["marks"].flatMap { PyDict<JSONValue>($0) } ?? PyDict())
        case "plant-live":
            var live = PythonJSON.read(paths.live).flatMap { PyDict<JSONValue>($0) } ?? PyDict()
            let source = args["from"].map(\.truthy) == true ? try calendarFolder(side, .object([("folder", args["from"]!)])) : paths
            let embeddings = PythonJSON.read(source.speakerEmbeddings)
            let voices = args["voices"].flatMap { PyDict<JSONValue>($0) } ?? PyDict()
            live["embeddings"] = .object(voices.map { ($0.key, embeddings?[$0.value.stringValue ?? ""] ?? .null) })
            try PythonJSON.write(live.json, to: paths.live, indent: nil, ensureAscii: true)
        case "name-live": try Speakers.nameLiveSpeaker(paths, try text(args, "label"), try text(args, "name"))
        case "adopt-live": answer.append(("adopted", strings(try Speakers.adoptLiveNames(paths))))
        case "plant-lines": try Data(try text(args, "text").utf8).write(to: paths.speakersLines)
        case "set-line":
            let lines = try (PythonJSON.read(paths.transcriptJson)?.arrayValue ?? []).map { try Utterance(json: $0) }
            guard case .int(let i)? = args["line"], lines.indices.contains(i) else { throw BadArgs(description: "speakers: line") }
            let to = args["to"].flatMap { $0.isNull ? nil : PyDict<JSONValue>($0) }.map { $0.map { ($0.key, $0.value) } }
            try Speakers.setLineSpeaker(paths, lines[i], to)
        case "state": break
        default: throw BadArgs(description: "speakers: unknown action \(action.map { "'\($0)'" } ?? "None")")
        }
        answer.append(("state", try speakerState(paths)))
        return .object(answer)
    }

    static func voicesOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let bank = VoiceBank(directory: side.stores.voices)
        let result: JSONValue
        switch args["action"]?.stringValue {
        case "names": result = .object(try bank.names().map { ($0.key, .int($0.value)) })
        case "add": result = .bool(try bank.add(try text(args, "name"), try voice(side, args["voice"]), source: try text(args, "source")))
        case "owner": result = .str(try bank.owner(try text(args, "source")))
        case "remove-source": result = .bool(try bank.removeSource(try text(args, "source")))
        case "remove-meeting": result = .int(try bank.removeMeeting(try text(args, "meeting")))
        case "forget": result = .bool(try bank.forget(try text(args, "name")))
        case "rename": result = .bool(try bank.rename(try text(args, "old"), try text(args, "new")))
        case "size": result = try bank.size().map { .int($0) } ?? .null
        case "slug": result = .strings((args["names"]?.arrayValue ?? []).map { Voices.slug($0.stringValue ?? "") })
        case "scores": result = .array(try bank.scores(try voice(side, args["voice"])).map { .array([.double($0.0), .string($0.1)]) })
        case "match": result = try bank.match(try voice(side, args["voice"])).map { .array([.string($0.0), .double($0.1)]) } ?? .null
        case "recognize":
            let paths = try calendarFolder(side, args)
            let turns = try (PythonJSON.read(paths.systemTurns)?.arrayValue ?? []).map { try SpeakerTurn(json: $0) }
            let embeddings = PyDict(try (PythonJSON.read(paths.speakerEmbeddings).flatMap { PyDict<JSONValue>($0) } ?? PyDict())
                .map { ($0.key, try voice(side, $0.value)) })
            let rejected = try (args["rejected"]?.arrayValue ?? []).map { pair -> (String, [Double]) in
                guard let p = pair.arrayValue, p.count == 2, let name = p[0].stringValue else { throw BadArgs(description: "voices: rejected pairs") }
                return (name, try voice(side, p[1]))
            }
            let found = try Voices.recognize(embeddings, talk: Speakers.talkSeconds(turns), bank: bank,
                                             invited: args["invited"]?.arrayValue?.compactMap(\.stringValue), rejected: rejected)
            result = .object(found.map { ($0.key, .array([.string($0.value.0), .double($0.value.1)])) })
        default: throw BadArgs(description: "voices: unknown action \(args["action"]?.stringValue.map { "'\($0)'" } ?? "None")")
        }
        return .object([("result", result), ("names", .object(try bank.names().map { ($0.key, .int($0.value)) }))])
    }

    static func peopleOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let bank = VoiceBank(directory: side.stores.voices)
        let userName = args["user_name"]?.stringValue ?? side.userName
        let result: JSONValue
        switch args["action"]?.stringValue {
        case "directory":
            result = try People.directory(outputDir: side.recordings, me: Set((args["me"]?.arrayValue ?? []).compactMap(\.stringValue)),
                                          bank: bank, stores: side.stores)
        case "voices":
            result = .array(try People.voices(side.recordings).map { v in
                .object([("meeting", .string(v.meeting)), ("label", .string(v.label)), ("talk_seconds", .double(v.talkSeconds)),
                         ("name", .str(v.name)), ("named_by", .str(v.namedBy))])
            })
        case "rejected-voices":
            result = .array(try People.rejectedVoices(side.recordings).map { .array([.string($0.0), .array($0.1.map { .double($0) })]) })
        case "refresh":
            result = .int(try People.refreshRecognition(outputDir: side.recordings, bank: bank, userName: userName, stores: side.stores))
        case "name-voices":
            let members = try (args["members"]?.arrayValue ?? []).map { pair -> (String, String) in
                guard let p = pair.arrayValue, p.count == 2, let meeting = p[0].stringValue, let label = p[1].stringValue else {
                    throw BadArgs(description: "people: members are [meeting, label] pairs")
                }
                return (meeting, label)
            }
            try People.nameVoices(outputDir: side.recordings, members: members, name: try text(args, "name"), bank: bank, stores: side.stores)
            result = .null
        case "rename-person":
            try People.renamePerson(outputDir: side.recordings, old: try text(args, "old"), new: try text(args, "new"), bank: bank,
                                    stores: side.stores)
            result = .null
        case "suggestions":
            let found = try People.suggestions(try calendarFolder(side, args), bank: bank, stores: side.stores)
            result = .object(found.map { ($0.key, .array($0.value.map { .array([.string($0.0), .double($0.1)]) })) })
        case "plant":
            let paths = try calendarFolder(side, args)
            let refs = args["voices"].flatMap { PyDict<JSONValue>($0) } ?? PyDict()
            let voices = JSONValue.object(try refs.map { ($0.key, .array(try voice(side, $0.value).map { .double($0) })) })
            if let turns = args["turns"]?.arrayValue {
                let written = try turns.map { t -> JSONValue in
                    guard let p = t.arrayValue, p.count == 3 else { throw BadArgs(description: "people: turns are [label, start, end]") }
                    return .object([("speaker", p[0]), ("start", p[1]), ("end", p[2])])
                }
                try PythonJSON.write(.array(written), to: paths.systemTurns, indent: nil, ensureAscii: true)
            }
            try PythonJSON.write(voices, to: paths.speakerEmbeddings, indent: nil, ensureAscii: true)
            result = .null
        default: throw BadArgs(description: "people: unknown action \(args["action"]?.stringValue.map { "'\($0)'" } ?? "None")")
        }
        return .object([("result", result)])
    }

    static func inferenceOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let result: JSONValue
        switch args["action"]?.stringValue {
        case "refresh":
            result = .int(try Inference.refresh(outputDir: side.recordings, userName: args["user_name"]?.stringValue ?? side.userName,
                                                bank: VoiceBank(directory: side.stores.voices), stores: side.stores))
        case "load": result = Inference.load(try calendarFolder(side, args)).json
        default: throw BadArgs(description: "inference: unknown action \(args["action"]?.stringValue.map { "'\($0)'" } ?? "None")")
        }
        return .object([("result", result)])
    }

    static func hintsOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let paths = try calendarFolder(side, args)
        return .object([("record", ExchangeHints.loadRecord(paths) ?? .null), ("hints", ExchangeHints.hints(paths).json)])
    }
}

extension ParityOps {
    private static func sharedState(_ paths: RecordingPaths, _ event: CalendarEvent?, _ side: ParitySide) -> JSONValue {
        func strings(_ d: PyDict<String>) -> JSONValue { .object(d.map { ($0.key, .string($0.value)) }) }
        return .object([
            ("display", strings(SharedMic.display(paths))),
            ("rooms", strings(SharedMic.roomNames(paths))),
            ("marks", SharedMic.load(paths).json),
            ("meeting", .bool(SharedMic.meetingMarked(paths))),
            ("from_series", .bool(SharedMic.fromSeries(paths))),
            ("mic_room", .str(SharedMic.micRoom(paths))),
            ("marked", .bool(SharedMic.marked(paths))),
            ("series", .object([("can", .bool(SharedMic.canRemember(event))),
                                ("remembered", .bool(SharedMic.remembered(event, stores: side.stores)))])),
        ])
    }

    /// shared_mic_op: the marks' setters, the series memory and the suggestion.
    static func sharedMicOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        do { return try sharedMicAction(side, args) }
        catch let e as SpeakersValueError { throw SpeakersBadRequest(description: e.description) }
    }

    private static func sharedMicAction(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        func event() throws -> CalendarEvent? {
            guard let ref = args["event"], !ref.isNull, ref.truthy else { return nil }
            return try calendarEvent(side, ref)
        }
        func raw(_ paths: RecordingPaths) -> PyDict<JSONValue> {
            PythonJSON.read(paths.speakersShared).flatMap { PyDict<JSONValue>($0) } ?? PyDict()
        }
        let action = args["action"]?.stringValue
        let paths = try calendarFolder(side, args)
        let on = args["on"]?.boolValue ?? true
        var result: JSONValue = .null
        switch action {
        case "set-meeting": try SharedMic.setMeeting(paths, on)
        case "set-lane":
            guard let label = args["label"]?.stringValue else { throw BadArgs(description: "shared-mic: label is missing") }
            try SharedMic.setLane(paths, label, on, name: args["name"]?.stringValue)
        case "forget-lanes": try SharedMic.forgetLanes(paths)
        case "remember": try SharedMic.remember(try event(), on, stores: side.stores)
        case "apply-series": result = .bool(try SharedMic.applySeries(paths, event: try event(), stores: side.stores))
        case "signals": result = try SharedMic.signals(paths, event: try event(), userName: args["user"]?.stringValue ?? "").json
        case "suggestion":
            result = try SharedMic.suggestion(paths, event: try event(), userName: args["user"]?.stringValue ?? "")
                .map { .object([("why", .string($0))]) } ?? .null
        case "dismiss": try SharedMic.dismissSuggestion(paths, on)
        case "split":
            let labels = Set((args["labels"]?.arrayValue ?? []).compactMap(\.stringValue).map(ScalarKey.init))
            let part = SharedMic.splitPart(raw(paths), labels: labels, head: args["head"]?.boolValue ?? true)
            result = part.json
            if args["write"]?.truthy == true { try SharedMic.save(paths, part) }
        case "join":
            let from = try calendarFolder(side, .object([("folder", args["from"] ?? .null)]))
            let relabel = PyDict((args["relabel"].flatMap { PyDict<JSONValue>($0) } ?? PyDict()).map { ($0.key, $0.value.stringValue ?? "") })
            try SharedMic.joinFrom(paths, raw(from), relabel: relabel)
        case "state": break
        default: throw BadArgs(description: "shared-mic: unknown action \(action.map { "'\($0)'" } ?? "None")")
        }
        return .object([("result", result), ("shared", sharedState(paths, try event(), side))])
    }
}
