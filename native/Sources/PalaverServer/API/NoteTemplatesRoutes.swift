// Note templates in the window (#13): Settings lists the built-in templates, the user's own (added, edited, deleted)
// and the calendar series a template is remembered for; a meeting's page shows the template its notes are written with
// and lets the user choose another one, for the meeting and, when it has one, for its calendar series. Choosing does
// not write the notes: the page asks for that next (POST /api/meetings/<id>/notes), so the wait shows as any rewrite.
import Foundation
import PalaverCore
import PalaverDomain

public enum NoteTemplatesAPI {
    /// The domain's refusals are the page's to show (400 with the text).
    static func refused<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let e as NoteTemplateError {
            throw Refused(e.description)
        }
    }

    /// Every template (built in first) and the series remembered, with their template's name.
    public static func page(_ app: ServerApp) -> JSONValue {
        let all = NoteTemplates.all(stores: app.stores)
        let series: [JSONValue] = NoteTemplates.rememberedSeries(stores: app.stores).compactMap { s in
            guard let t = all.first(where: { Py.same($0.id, s.template) }) else { return nil }  // a deleted one's
            return .object([("series", .string(s.series)), ("title", .string(s.title)), ("template", .string(t.id)),
                            ("template_name", .string(t.name))])
        }
        return .object([("templates", .array(all.map(\.json))), ("series", .array(series))])
    }

    /// The meeting page's "template": the one its notes are written with next, where that comes from, and whether its
    /// series (its calendar's, else its meeting series, #39) can remember one (and which it remembers).
    static func meetingTemplate(_ app: ServerApp, _ paths: RecordingPaths, event: CalendarEvent?, notes: JSONValue?) -> JSONValue {
        let (template, from) = NoteTemplates.pick(paths, event: .known(event), notes: .known(notes), stores: app.stores)
        let series = NoteTemplates.seriesChoice(paths, event: event, stores: app.stores)
        let can = NoteTemplates.seriesKey(paths, event: event, stores: app.stores) != nil
        return .object([("id", .string(template.id)), ("name", .string(template.name)), ("from", .string(from)),
                        ("series", .object([("can", .bool(can)), ("template", .str(series))]))])
    }

    /// What wrote the notes there are (#13): null for notes from before templates, or from elsewhere.
    static func notesTemplate(_ notes: JSONValue?) -> JSONValue {
        guard let id = notes?["template"]?.stringValue, !id.isEmpty else { return .null }
        return .object([("id", .string(id)), ("name", .string(notes?["template_name"]?.stringValue ?? id))])
    }

    /// The user chose `template` for meeting `id` (nil: no choice of their own); `series`: and for its calendar series.
    public static func choose(_ app: ServerApp, id: String, template: String?, series: Bool) throws -> JSONValue {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        try refused {
            try NoteTemplates.choose(paths, template, stores: app.stores)
            if series { try NoteTemplates.rememberSeries(paths, event: CalendarEvents.load(paths), template, stores: app.stores) }
        }
        return try MeetingsAPI.getMeeting(app: app, id: id)
    }
}

extension Router {
    static func addNoteTemplateRoutes(_ r: Router, app: ServerApp) {
        func text(_ body: JSONValue, _ key: String) throws -> String {
            guard case .string(let s) = try PyBody.required(body, key) else { throw Refused("\(key) is text") }
            return s
        }
        r.get("/api/note-templates") { _, _ in .json(NoteTemplatesAPI.page(app)) }
        r.post("/api/note-templates") { req, _ in
            let made = try NoteTemplatesAPI.refused {
                try NoteTemplates.add(name: try text(req.json, "name"), instructions: try text(req.json, "instructions"),
                                      stores: app.stores)
            }
            var out = PyDict<JSONValue>(NoteTemplatesAPI.page(app))!
            out["id"] = .string(made.id)
            return .json(out.json)
        }
        // A series forgotten: before the template routes, whose id it would otherwise be.
        r.post("/api/note-templates/series") { req, _ in
            try NoteTemplates.forgetSeries(try text(req.json, "series"), stores: app.stores)
            return .json(NoteTemplatesAPI.page(app))
        }
        r.post("/api/note-templates/([^/]+)") { req, m in
            let id = m.group(1)!
            try NoteTemplatesAPI.refused {
                if try PyBody.get(req.json, "delete")?.truthy == true {
                    try NoteTemplates.delete(id, stores: app.stores)
                } else {
                    try NoteTemplates.update(id, name: try text(req.json, "name"), instructions: try text(req.json, "instructions"),
                                             stores: app.stores)
                }
            }
            return .json(NoteTemplatesAPI.page(app))
        }
        r.post("/api/meetings/([^/]+)/template") { req, m in
            let chosen = try PyBody.required(req.json, "template")
            let template: String?
            switch chosen {
            case .null: template = nil
            case .string(let s): template = s
            default: throw Refused("template is text or null")
            }
            return .json(try NoteTemplatesAPI.choose(app, id: m.group(1)!, template: template,
                                                     series: try PyBody.get(req.json, "series")?.truthy == true))
        }
    }
}
