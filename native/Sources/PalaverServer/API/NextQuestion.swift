// The best next question (#41): on the user's click during a call, one to three questions to ask next, from the
// language model the user chose for it (api.py `next_question_info`, `next_question_problem`, `next_question_inputs`,
// `_event_of`, `_my_notes`; server.py `_next_question` and the GET branch; next_question.py `FEATURE`, `model_name`,
// `memory_problem` and `build_prompt`'s "nothing said yet").
//
// The question itself comes from a helper process (`app.nextQuestion`, LMNextQuestion: palaver-lm builds the prompt and
// runs the model). The local model runs only on a click, only with the free memory the notes need, and during a call
// only after a second click; a meeting kept on this Mac never goes to a cloud model.
import Foundation
import PalaverCore
import PalaverDomain

public enum NextQuestionAPI {
    /// next_question.py `FEATURE`.
    public static let FEATURE = "coach"
    static let LABEL = "Best next question"
    static let OFF = "Notes are turned off, and with them the language model."
    static let PENDING = "No model yet: choose one for Best next question in Settings → Language model."
    static let NOTHING_YET = "Nothing has been said yet. Ask again once the meeting has started."

    static let CLAUDE = try! PyRegex(#"claude-([a-z]+)-(\d+)(?:-(\d))?(?:-\d{8})?"#)

    /// `str.capitalize()` of a word of ASCII letters (all it is asked of here).
    private static func capitalize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for (i, u) in s.unicodeScalars.enumerated() {
            let lower = (97...122).contains(u.value), upper = (65...90).contains(u.value)
            if i == 0 && lower { out.append(Unicode.Scalar(u.value - 32)!) } else if i > 0 && upper {
                out.append(Unicode.Scalar(u.value + 32)!)
            } else { out.append(u) }
        }
        return String(out)
    }

    /// `model_name`: "claude-opus-5-5" → "Claude Opus 5.5", "sonnet" → "Claude Sonnet"; any other model as it is named.
    public static func modelName(_ model: String) -> String {
        if let m = CLAUDE.fullMatch(model) {
            return "Claude \(capitalize(m.group(1)!)) \(m.group(2)!)" + (m.group(3).map { ".\($0)" } ?? "")
        }
        if ["opus", "sonnet", "haiku"].contains(where: { Py.same($0, model) }) { return "Claude \(capitalize(model))" }
        return model
    }

    /// `memory_problem`: why the local model can't start now, said plainly; nil when it can (or a cloud model answers).
    public static func memoryProblem(local: Bool, freeGB: Double, needGB: Double, recording: Bool) -> String? {
        if !local || freeGB >= needGB { return nil }
        if recording {
            return "Not enough free memory for the local model during the call; choose a cloud model in "
                + "Settings → Language model, or ask after the call"
        }
        return "Not enough free memory for the local model right now (\(String(format: "%.0f", freeGB)) GB free, it needs "
            + "\(String(format: "%.0f", needGB)) GB); choose a cloud model in Settings → Language model, or try again later"
    }

    static func choice(_ app: ServerApp, _ paths: RecordingPaths) -> String {
        ModelChoice.choiceFor(feature: FEATURE, folders: [paths.folder], config: app.config, stores: app.stores)
    }

    /// `next_question_info`: the button — which model answers and where ("Best next question (Gemma, on this Mac)"),
    /// whether it can (`reason` when not), and the warning a local model during the call needs a second click for.
    public static func info(_ app: ServerApp, id: String) throws -> JSONValue {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        func off(_ reason: String) -> JSONValue {
            .object([("ready", .bool(false)), ("label", .string(LABEL)), ("local", .bool(false)), ("warning", .null),
                     ("reason", .string(reason))])
        }
        guard app.notesEnabled else { return off(OFF) }
        let choice = choice(app, paths)
        if Py.same(choice, ModelChoice.PENDING) { return off(PENDING) }
        if Py.same(choice, ModelChoice.LOCAL) {
            let repo = ModelChoice.localModel(config: app.config, stores: app.stores)
            let info = ModelChoice.localModelInfo(repo)
            // `info.get("label", repo.rsplit("/", 1)[-1]).split()[0]`
            let label = info?.label ?? String(String.UnicodeScalarView(repo.unicodeScalars.split(separator: "/",
                omittingEmptySubsequences: false).last ?? []))
            guard let short = Py.split(label).first else { throw PageError("list index out of range") }
            var warning: JSONValue = .null
            if app.meetingStatus(paths) == "recording" {
                warning = .string("Runs \(short) on this Mac during the call (about \(info?.runningGB ?? 10) GB, may slow the call)")
            }
            return .object([("ready", .bool(true)), ("reason", .null), ("label", .string("\(LABEL) (\(short), on this Mac)")),
                            ("local", .bool(true)), ("warning", warning)])
        }
        let settings = try ModelChoice.settingsOf(choice, defaults: ModelChoice.providerDefaults(config: app.config, pid: choice),
                                                  stores: app.stores)
        let model = settings["model"].flatMap { $0.truthy ? Py.str($0) : nil } ?? ModelChoice.provider(choice)?.label ?? choice
        return .object([("ready", .bool(true)), ("reason", .null), ("label", .string("\(LABEL) (\(modelName(model)), cloud)")),
                        ("local", .bool(false)), ("warning", .null)])
    }

    /// `next_question_problem`: why the question can't be asked now (the local model without its memory), or nil. A
    /// meeting kept on this Mac stays local (`ModelChoice.choiceFor`).
    public static func problem(_ app: ServerApp, id: String, freeGB: Double) throws -> String? {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        return memoryProblem(local: Py.same(choice(app, paths), ModelChoice.LOCAL), freeGB: freeGB,
                             needGB: ModelChoice.memoryGB(feature: FEATURE, folder: paths.folder, config: app.config,
                                                          stores: app.stores),
                             recording: app.meetingStatus(paths) == "recording")
    }

    // MARK: - what the question is asked from

    /// `_event_of`: the recording's calendar event — the one stored, else the one the calendar has on while it was
    /// recorded (a calendar that fails is logged and no event).
    public static func eventOf(_ app: ServerApp, _ paths: RecordingPaths) -> CalendarEvent? {
        if let event = CalendarEvents.load(paths) { return event }
        guard let calendar = app.calendar else { return nil }
        do {
            let (start, duration) = try Cutting.span(paths)
            let now = Date()
            let nowDT = PyDateTime(now, offset: TimeZone.current.secondsFromGMT(for: now))
            let end = max(try start.adding(seconds: duration), nowDT)
            return CalendarEvents.match(try calendar(try start.adding(seconds: -CalendarEvents.SEARCH_MARGIN).date, end.date), start, end)
        } catch {
            app.log?.message("calendar lookup failed: \(error)", level: "ERROR", logger: "palaver.webapp.api")
            return nil
        }
    }

    /// `_my_notes`: the user's own notes (#44) as the notes model reads them, and the notes written before the meeting
    /// for its event that were not adopted into the recording yet.
    static func myNotes(_ app: ServerApp, _ paths: RecordingPaths, _ event: CalendarEvent?) -> [String] {
        var texts = [MyNotes.promptText(paths.folder)]
        if let event, !event.key.isEmpty { texts.append(MyNotes.promptText(MyNotes.prepFolder(event.key, stores: app.stores))) }
        return texts.filter { !Py.strip($0).isEmpty }
    }

    /// `max(values, default=0.0)` of JSON numbers, the largest as it was given (an int stays an int).
    private static func largest(_ values: [JSONValue]) throws -> JSONValue {
        var best: JSONValue?
        for v in values {
            guard let b = best else { best = v; continue }
            if try ChangesAPI.pyFloat(v) > ChangesAPI.pyFloat(b) { best = v }
        }
        return best ?? .double(0.0)
    }

    /// `next_question_inputs`: what the question is asked from — the text so far with speaker names (while recording,
    /// the live text and the stream's newer lines), the calendar event, the last meetings with the same people, who
    /// hasn't spoken (`coach`, the live coach) and the user's notes. With a cloud model, no earlier meeting kept on this
    /// Mac is in it (#53). `meetings`: every meeting whose content it holds, for the access log. `context` and `eventOf`
    /// are prep.context and `_event_of` (a test may give its own).
    public static func inputs(_ app: ServerApp, id: String, coach: JSONValue?,
                              context: ((CalendarEvent) throws -> [JSONValue])? = nil,
                              eventOf: ((RecordingPaths) -> CalendarEvent?)? = nil) throws -> JSONValue {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        let chosen = choice(app, paths)
        let cloud = !Py.same(chosen, ModelChoice.LOCAL) && !Py.same(chosen, ModelChoice.PENDING)
        let m = try MeetingsAPI.getMeeting(app: app, id: id, calendar: false)
        func line(_ t: JSONValue, speaker: JSONValue) throws -> JSONValue {
            .object([("speaker", speaker), ("start", try MeetingsAPI.key(t, "start")), ("end", try MeetingsAPI.key(t, "end")),
                     ("text", try MeetingsAPI.key(t, "text"))])
        }
        var lines = try (m["transcript"].flatMap { $0.truthy ? $0 : nil }.map(MeetingsAPI.iterate) ?? []).map { t in
            try line(t, speaker: try MeetingsAPI.key(t, "speaker"))
        }
        if m["status"].map({ PythonJSON.equal($0, .string("recording")) }) ?? false {
            // `(m.get("live") or {}).get("until", 0)`
            let live = m["live"].flatMap { $0.truthy ? $0 : nil }
            let until = try live.map { try PyBody.get($0, "until") ?? .int(0) } ?? .int(0)
            let stream = try LivePage.stream(app: app, id: id, since: try ChangesAPI.pyFloat(until))
            for l in try (stream["lines"].flatMap { $0.truthy ? $0 : nil }.map(MeetingsAPI.iterate) ?? []) {
                let label = try MeetingsAPI.key(l, "label")
                lines.append(try line(l, speaker: label.truthy ? .string("Others") : try MeetingsAPI.key(l, "speaker")))
            }
        }
        let event = eventOf.map { $0(paths) } ?? NextQuestionAPI.eventOf(app, paths)
        var lastTime: [JSONValue] = []
        if let event {
            do {
                lastTime = try (context ?? { try Prep.context($0, outputDir: app.outputDir, userName: app.userName,
                                                              stores: app.stores) })(event)
            } catch {
                app.log?.message("could not find the meetings before this one: \(error)", level: "ERROR",
                                 logger: "palaver.webapp.api")
            }
        }
        if cloud {
            lastTime = try lastTime.filter { t in
                !LocalOnly.isLocalOnly(app.outputDir.appendingPathComponent(Py.str(try MeetingsAPI.key(t, "id")), isDirectory: true))
            }
        }
        // `list((coach or {}).get("quiet") or [])`
        var quiet: [JSONValue] = []
        let q = try MeetingsAPI.get(coach, "quiet")
        if q.truthy { quiet = try MeetingsAPI.iterate(q) }
        var meetings: [JSONValue] = [.string(id)]
        for t in lastTime {
            let other = try MeetingsAPI.key(t, "id")
            if !PythonJSON.equal(other, .string(id)) { meetings.append(other) }
        }
        return .object([
            ("user", .string(app.userName)),
            ("now", try largest(lines.map { try MeetingsAPI.key($0, "end") })),
            ("lines", .array(lines)),
            ("title", .str(Titles.resolve(paths, event: .known(event), stores: app.stores).title)),
            ("invitees", .strings(event.map { CalendarEvents.candidates($0, userName: app.userName).map(\.name) } ?? [])),
            ("quiet", .array(quiet)),
            ("last_time", .array(lastTime)),
            ("my_notes", .strings(myNotes(app, paths, event))),
            ("meetings", .array(meetings)),
        ])
    }

    /// `build_prompt`'s NothingYet: no line of the inputs says anything (the prompt itself is the helper's).
    static func nothingSaid(_ inputs: JSONValue) -> Bool {
        !(inputs["lines"]?.arrayValue ?? []).contains { line in
            line["text"].map { $0.truthy && !Py.strip(Py.str($0)).isEmpty } ?? false
        }
    }

    /// `_next_question`: one to three questions to ask next, on the user's click. The local model during a call needs a
    /// second click (`confirmed`).
    public static func ask(_ app: ServerApp, id: String, confirmed: Bool) throws -> JSONValue {
        let info = try info(app, id: id)
        let reason = info["reason"].map(Py.str) ?? ""
        guard app.notesEnabled else { throw Unavailable(reason) }
        guard info["ready"]?.truthy ?? false else { throw Refused(reason) }
        if let problem = try problem(app, id: id, freeGB: app.freeMemoryGB()) { throw Refused(problem) }
        if let warning = info["warning"], warning.truthy, !confirmed { throw Conflict(Py.str(warning)) }
        let coach = app.recording?.coach()
        let inputs = try inputs(app, id: id, coach: coach)
        if nothingSaid(inputs) { throw Refused(NOTHING_YET) }  // nothing said yet: say so before a model starts
        guard app.notesLock.try() else { throw ModelBusy() }
        defer { app.notesLock.unlock() }
        return try app.nextQuestion.ask(meetingId: id, inputs: inputs)
    }
}

extension Router {
    /// The best next question (server.py's GET and POST branches).
    static func addNextQuestionRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/meetings/([^/]+)/next-question") { _, m in .json(try NextQuestionAPI.info(app, id: m.group(1)!)) }
        r.post("/api/meetings/([^/]+)/next-question") { req, m in
            // `body.get("confirmed") is not True`
            var confirmed = false
            if case .bool(true)? = try PyBody.get(req.json, "confirmed") { confirmed = true }
            return .json(try NextQuestionAPI.ask(app, id: m.group(1)!, confirmed: confirmed))
        }
    }
}
