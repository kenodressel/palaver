// The Swift side of the `glossary`, `glossary-suggest` and `render` parity ops (tools/parity/ops.py, section
// "text (Task 9)").
import Foundation
import PalaverCore
import PalaverDomain

/// A ValueError of the glossary: the window's server answers 400 (ops.error_kind: bad_request).
private struct GlossaryRefused: ParityErrorKind, CustomStringConvertible {
    let description: String
    var parityKind: String { "bad_request" }
}

extension ParityOps {
    static let text: [String: Op] = ["glossary": glossaryOp, "glossary-suggest": glossarySuggestOp, "render": renderOp]

    static func glossaryOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        do { return try glossaryAction(side, args) }
        catch let e as GlossaryValueError { throw GlossaryRefused(description: e.description) }
    }

    private static func glossaryAction(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let action = args["action"]?.stringValue
        let g = Glossary(path: side.stores.glossary)
        func string(_ key: String) throws -> String {
            guard let s = args[key]?.stringValue else { throw BadArgs(description: "glossary \(action ?? "") needs \(key)") }
            return s
        }
        var tid = args["id"]?.stringValue
        if tid == nil, let of = args["of"]?.stringValue {
            guard let found = g.find(of) else { throw GlossaryLookupError(id: of) }
            tid = found
        }
        func term() throws -> String {
            guard let tid else { throw BadArgs(description: "glossary \(action ?? "") needs of or id") }
            return tid
        }
        var answer: [(String, JSONValue)] = []
        switch action {
        case "add":
            guard let id = args["new_id"]?.stringValue, !id.isEmpty else {
                throw BadArgs(description: "glossary add needs new_id (random ids would differ)")
            }
            g.makeId = { id }
            let variants = (args["variants"]?.arrayValue ?? []).compactMap(\.stringValue)
            answer.append(("id", .string(try g.add(term: try string("term"), variants: variants, note: args["note"]?.stringValue ?? ""))))
        case "update":
            try g.update(try term(), term: args["term"]?.stringValue, note: args["note"]?.stringValue)
        case "remove-variant":
            try g.removeVariant(try term(), try string("variant"))
        case "delete":
            try g.delete(try term())
        case "reject":
            g.reject(try string("key"))
        case "apply":
            let (text, marks) = g.applyMarked(try string("text"))
            answer.append(("text", .string(text)))
            answer.append(("marks", .array(marks.map { .array([.int($0.start), .int($0.end), .string($0.heard)]) })))
        case "show":
            break
        default:
            throw BadArgs(description: "glossary: unknown action \(action ?? "nil")")
        }
        if action != "apply" && action != "show" { try g.save() }
        answer.append(("terms", g.terms.json))
        answer.append(("rejected", .strings(g.rejected())))
        return .object(answer)
    }

    /// The glossary's suggestions: corpus, unsure (by word, sorted), known (sorted), occurrences or suggest, with
    /// `transcripts`, `unsure` (an object, or a list: every time) and `known` given or read from the side.
    static func glossarySuggestOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        func lines(_ corpus: PyDict<[(Double, String)]>) -> JSONValue {
            .object(corpus.map { ($0.key, .array($0.value.map { .array([.double($0.0), .string($0.1)]) })) })
        }
        let action = args["action"]?.stringValue
        let out = side.recordings
        switch action {
        case "corpus":
            return lines(GlossarySuggest.corpus(outputDir: out, stores: side.stores))
        case "unsure":
            let words = GlossarySuggest.unsureWords(outputDir: out)
            return .object(Py.stableSorted(words.map { ($0.key, JSONValue.int($0.value)) }) { Py.less($0.0, $1.0) })
        case "known":
            return .strings(try GlossarySuggest.knownSpellings(outputDir: out, userName: side.userName, stores: side.stores))
        case "occurrences", "suggest":
            break
        default:
            throw BadArgs(description: "glossary-suggest: unknown action \(action ?? "nil")")
        }
        var transcripts = PyDict<[(Double, String)]>()
        if case .object(let meetings)? = args["transcripts"] {
            for (meeting, given) in meetings {
                transcripts[meeting] = try (given.arrayValue ?? []).map { line in
                    guard let pair = line.arrayValue, pair.count == 2, let start = pair[0].doubleValue,
                          let text = pair[1].stringValue else {
                        throw BadArgs(description: "glossary-suggest: a line is [start, text]")
                    }
                    return (start, text)
                }
            }
        } else {
            transcripts = GlossarySuggest.corpus(outputDir: out, stores: side.stores)
        }
        let unsure: PyDict<Int>
        switch args["unsure"] {
        case .object(let counts)?:
            unsure = PyDict(try counts.map { word, n in
                guard case .int(let times) = n else { throw BadArgs(description: "glossary-suggest: unsure counts are ints") }
                return (word, times)
            })
        case .array(let words)?: unsure = GlossarySuggest.everyTime(words.compactMap(\.stringValue))
        default: unsure = GlossarySuggest.unsureWords(outputDir: out)
        }
        if action == "occurrences" {
            return .object(GlossarySuggest.occurrences(transcripts, unsure: unsure).map { word, o in
                (word, .object([("count", .int(o.count)), ("meetings", .strings(Py.stableSorted(o.meetings, by: Py.less))),
                                ("examples", .array(o.examples)), ("rare", .bool(o.rare))]))
            })
        }
        let known = try args["known"]?.arrayValue?.compactMap(\.stringValue)
            ?? GlossarySuggest.knownSpellings(outputDir: out, userName: side.userName, stores: side.stores)
        return .array(GlossarySuggest.suggest(transcripts, known: known, glossary: Glossary(path: side.stores.glossary), unsure: unsure))
    }

    private static func shown(_ utterances: [Utterance], start: Date, duration: Double, gaps: [JSONValue]?, zone: TimeZone) throws -> JSONValue {
        let glossary = Glossary.current()
        let markdown = try Render.markdown(utterances, start: start, duration: duration, gaps: gaps, timeZone: zone, glossary: glossary)
        let glossed = Readable.readable(utterances, glossary: glossary).map { u -> JSONValue in
            .array([.double(u.start), .string(u.text), .array(u.glossed.map { .array([.int($0.start), .int($0.end), .string($0.heard)]) })])
        }
        return .object([("markdown", .string(markdown)), ("glossed", .array(glossed))])
    }

    /// transcript.md of every meeting with a transcript and a meta (written into the folder), and what the
    /// glossary respelled in each line; `gaps` replaces meta.json's, `texts` are rendered as one more meeting.
    static func renderOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        var out: [(String, JSONValue)] = []
        let explicitGaps = args["gaps"]?.arrayValue
        for folder in meetingFolders(side) {
            let p = RecordingPaths(folder)
            guard let items = PythonJSON.read(p.transcriptJson)?.arrayValue, let utterances = try? items.map({ try Utterance(json: $0) }),
                  let meta = PythonJSON.read(p.meta), let iso = meta["start_time"]?.stringValue,
                  let start = WallTime.parse(iso), let duration = meta["duration_seconds"]?.doubleValue else { continue }
            let zone = Lifecycle.offsetZone(iso) ?? .current
            let result = try shown(utterances, start: start, duration: duration, gaps: explicitGaps ?? meta["gaps"]?.arrayValue, zone: zone)
            try (result["markdown"]?.stringValue ?? "").write(to: p.transcriptMd, atomically: false, encoding: .utf8)
            out.append((folder.lastPathComponent, result))
        }
        if let texts = args["texts"]?.arrayValue {
            let iso = "2026-10-28T09:00:00+01:00"
            let utterances = try texts.map { try Utterance(json: $0) }
            out.append(("texts", try shown(utterances, start: WallTime.parse(iso)!, duration: args["duration"]?.doubleValue ?? 600,
                                       gaps: explicitGaps, zone: Lifecycle.offsetZone(iso)!)))
        }
        return .object(out)
    }
}

extension ParityOps {
    static let notes: [String: Op] = ["notes-stale": notesStaleOp]

    /// The notes' read side on `folder`'s transcript.json (see ops.py's notes_stale_op).
    static func notesStaleOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        let paths = try calendarFolder(side, args)
        guard let items = PythonJSON.read(paths.transcriptJson)?.arrayValue else { throw BadArgs(description: "notes-stale: no transcript") }
        let utterances = try items.map { try Utterance(json: $0) }
        let lanes = Notes.sharedLanes(utterances, shared: SharedMic.display(paths), mic: SharedMic.micDisplay(paths))
        let mine = Notes.myNotesHash(MyNotes.promptText(paths.folder))
        if let raw = args["raw"]?.stringValue {
            try raw.write(to: paths.notes, atomically: false, encoding: .utf8)
        } else if case .object(var data)? = args["write"] {
            if args["stamp"] == .bool(true) {
                for (key, value) in [("transcript_hash", JSONValue.string(Notes.transcriptHash(utterances))),
                                     ("my_notes_hash", .string(mine)), ("shared_lanes", .strings(lanes))] {
                    if let i = data.firstIndex(where: { $0.0 == key }) { data[i].1 = value } else { data.append((key, value)) }
                }
            }
            // notes.save: tmp.write_text(json.dumps(notes, indent=2, ensure_ascii=False)); tmp.replace(path)
            try PythonJSON.write(.object(data), to: paths.notes, indent: 2, ensureAscii: false, via: "notes.json.tmp")
        }
        let reason = Notes.staleReason(paths, utterances)
        var out: [(String, JSONValue)] = [
            ("transcript_hash", .string(Notes.transcriptHash(utterances))), ("my_notes_hash", .string(mine)),
            ("shared_lanes", .strings(lanes)), ("language", Notes.meetingLanguage(utterances).map { .string($0) } ?? .null),
            ("reason", reason.map { .string($0) } ?? .null), ("is_stale", .bool(reason != nil)),
        ]
        if let guesses = args["guesses"]?.arrayValue { out.append(("backed", .array(Notes.backedNameGuesses(guesses, utterances)))) }
        if let names = args["names"], let value = names["value"] {
            var map = PyDict<String>()
            if case .object(let fields)? = names["names"] { for (k, v) in fields { map[k] = v.stringValue ?? "" } }
            out.append(("named", Notes.withNames(value, map)))
        }
        return .object(out)
    }
}
