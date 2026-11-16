// Draft Recap Email (#18): a recap of the meeting from its notes (the summary, the decisions, the next steps with whose
// they are), addressed to the calendar event's invitees, opened as a new message in the user's mail app. Palaver never
// sends it and has no mail account: the draft is an .eml with `X-Unsent: 1` (Mail and Outlook for Mac open it as a
// message to edit and send), written to a temporary folder and opened; a mailto: link only when that file can't be
// written. Plain text, in the meeting's language: the notes are in it already, the few fixed words (greeting,
// headings, the closing) German or English by the transcript (`Notes.meetingLanguage`). Nothing leaves the Mac until
// the user sends it, so a meeting kept on this Mac may draft one too.
import Foundation
import PalaverCore
import PalaverDomain

public enum RecapEmail {
    struct Draft: Equatable {
        var to: [Recipient]
        var subject: String
        var body: String
    }

    struct Recipient: Equatable {
        let name: String
        let email: String
    }

    /// The fixed words, by language.
    static let WORDS: [String: [String: String]] = [
        "en": ["all": "Hi all,", "one": "Hi %@,", "intro": "here is a short recap of “%@” on %@.", "summary": "Summary",
               "decisions": "Decisions", "steps": "Next steps", "bye": "Best regards"],
        "de": ["all": "Hallo zusammen,", "one": "Hallo %@,", "intro": "hier eine kurze Zusammenfassung von „%@“ am %@.",
               "summary": "Zusammenfassung", "decisions": "Entscheidungen", "steps": "Nächste Schritte", "bye": "Viele Grüße"],
    ]

    /// The event's invitees with an email address: not the user (the calendar's own attendee, or one of the user's
    /// names), not a room, each address once.
    static func recipients(_ event: CalendarEvent?, me: Set<String>) -> [Recipient] {
        var seen = Set<String>(), out: [Recipient] = []
        for a in event?.attendees ?? [] where !a.isSelf && !a.isRoom && !me.contains(Py.casefold(Py.strip(a.name))) {
            guard let email = a.email.map(Py.strip), isAddress(email), seen.insert(email.lowercased()).inserted else { continue }
            out.append(Recipient(name: Py.strip(a.name), email: email))
        }
        return out
    }

    /// One plain address: something@something, nothing a header could be broken with.
    static func isAddress(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
            && !s.unicodeScalars.contains { $0.value < 0x21 || $0.value > 0x7E || "<>,;\"()[]\\".unicodeScalars.contains($0) }
    }

    /// The draft of the meeting page `page` (its notes with names), to `to`, in `language` ("de" or "en").
    static func draft(page: JSONValue, to: [Recipient], userName: String, language: String) -> Draft {
        let words = WORDS[language] ?? WORDS["en"]!
        let start = page["start"]?.stringValue ?? ""
        let title = (page["title"]?.stringValue).flatMap { $0.isEmpty ? nil : $0 } ?? Titles.fallback(start)
        let notes = page["notes"] ?? .null
        let firstName = { (name: String) in Py.split(name).first ?? name }
        var lines: [String] = []
        if to.count == 1, !to[0].name.isEmpty, !to[0].name.contains("@") {
            lines.append(String(format: words["one"]!, firstName(to[0].name)))
        } else {
            lines.append(words["all"]!)
        }
        lines += ["", String(format: words["intro"]!, oneLine(title), day(start, language: language))]
        if let summary = notes["summary"]?.stringValue, !Py.strip(summary).isEmpty {
            lines += ["", words["summary"]!, Py.strip(summary)]
        }
        let decisions = (notes["decisions"]?.arrayValue ?? []).compactMap { $0.stringValue ?? $0["text"]?.stringValue }
            .map(oneLine).filter { !$0.isEmpty }
        if !decisions.isEmpty { lines += ["", words["decisions"]!] + decisions.map { "- \($0)" } }
        let steps: [String] = (notes["next_steps"]?.arrayValue ?? []).compactMap { s in
            let task = oneLine(s["task"]?.stringValue ?? s.stringValue ?? "")
            guard !task.isEmpty else { return nil }
            let owner = oneLine(s["owner"]?.stringValue ?? "")
            return owner.isEmpty ? "- \(task)" : "- \(owner): \(task)"
        }
        if !steps.isEmpty { lines += ["", words["steps"]!] + steps }
        lines += ["", words["bye"]!]
        if !userName.isEmpty { lines.append(firstName(userName)) }
        return Draft(to: to, subject: "Recap: \(oneLine(title))", body: lines.joined(separator: "\n") + "\n")
    }

    /// The meeting's day in words: "29 October 2026", "29. Oktober 2026".
    static func day(_ start: String, language: String) -> String {
        let parts = start.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return start }
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        guard let date = c.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return start }
        let f = DateFormatter()
        f.calendar = c
        f.timeZone = c.timeZone
        f.locale = Locale(identifier: language == "de" ? "de_DE" : "en_GB")
        f.dateFormat = language == "de" ? "d. MMMM yyyy" : "d MMMM yyyy"
        return f.string(from: date)
    }

    private static func oneLine(_ s: String) -> String {
        Py.strip(s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))
    }

    // MARK: - the draft as a file

    /// The draft as an unsent message (RFC 5322, CRLF): `X-Unsent: 1`, To, Subject, the body as UTF-8 plain text in
    /// base64 (no line is too long, whatever the notes hold).
    static func eml(_ d: Draft) -> String {
        var headers = ["X-Unsent: 1"]
        if !d.to.isEmpty {
            headers.append("To: " + d.to.map { r in
                r.name.isEmpty || r.name == r.email ? r.email : "\(encodedWord(r.name, phrase: true)) <\(r.email)>"
            }.joined(separator: ",\r\n "))
        }
        headers += ["Subject: \(encodedWord(d.subject))", "MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8",
                    "Content-Transfer-Encoding: base64"]
        let body = Data(d.body.replacingOccurrences(of: "\n", with: "\r\n").utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return headers.joined(separator: "\r\n") + "\r\n\r\n" + body + "\r\n"
    }

    /// A header's text: as it is when it is plain ASCII, else RFC 2047 encoded words (UTF-8, base64),
    /// each short enough for a header line, never splitting a character.
    /// `phrase`: a name in an address list, where a comma would split "Strauß, Timo" in two and quotes or brackets
    /// mean something too.
    static func encodedWord(_ text: String, phrase: Bool = false) -> String {
        let specials = phrase ? "\"=?,;:<>@()[]\\" : ""
        if !text.contains("=?"), text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F && !specials.unicodeScalars.contains($0) }) {
            return text
        }
        var words: [String] = [], chunk = Data()
        for ch in text {
            let bytes = Data(String(ch).utf8)
            if chunk.count + bytes.count > 45 {
                words.append("=?utf-8?B?\(chunk.base64EncodedString())?=")
                chunk = Data()
            }
            chunk.append(bytes)
        }
        if !chunk.isEmpty { words.append("=?utf-8?B?\(chunk.base64EncodedString())?=") }
        return words.joined(separator: "\r\n ")
    }

    /// The fallback: a mailto: link with the addresses, the subject and the body (shortened: links are limited).
    static func mailto(_ d: Draft, maxBody: Int = 1800) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#,;/:@")
        let body = d.body.count > maxBody ? String(d.body.prefix(maxBody)) + "…" : d.body
        let to = d.to.map { $0.email.addingPercentEncoding(withAllowedCharacters: allowed.union(CharacterSet(charactersIn: "@"))) ?? "" }
        return "mailto:" + to.joined(separator: ",")
            + "?subject=" + (d.subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
            + "&body=" + (body.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }

    // MARK: - the button

    /// The meeting's recap as a draft in the mail app: `{"opened": "draft" | "mailto", "to": n}`. Refused without notes.
    public static func open(_ app: ServerApp, id: String) throws -> JSONValue {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        let page = try MeetingsAPI.getMeeting(app: app, id: id, calendar: false)
        guard page["notes"]?.truthy ?? false else { throw Refused("This meeting has no notes yet: write them first.") }
        let me = SettingsFile.me(userName: app.userName, stores: app.stores)
        let utterances = (page["transcript"]?.arrayValue ?? []).map { t in
            Utterance(speaker: "", start: 0, end: 0, text: t["text"]?.stringValue ?? "")
        }
        let d = draft(page: page, to: recipients(CalendarEvents.load(paths), me: me), userName: app.userName,
                      language: Notes.meetingLanguage(utterances) ?? "en")
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: app.draftsDir, withIntermediateDirectories: true)
            // Yesterday's drafts are in the mail app by now (or were thrown away).
            for old in (try? fm.contentsOfDirectory(at: app.draftsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where old.pathExtension == "eml" {
                let made = (try? old.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                if made < Date(timeIntervalSinceNow: -86_400) { try? fm.removeItem(at: old) }
            }
            // A file of its own each time: the mail app may still be reading the last one.
            let file = app.draftsDir.appendingPathComponent("Recap \(id) \(UUID().uuidString.prefix(8)).eml")
            try Data(eml(d).utf8).write(to: file, options: .atomic)
            app.openDraft(file.path)
            return .object([("opened", .string("draft")), ("to", .int(d.to.count))])
        } catch {
            app.log?.message("recap draft not written (\(error)); opening a mailto: link", level: "WARNING", logger: "palaver.follow-ups")
            app.openDraft(mailto(d))
            return .object([("opened", .string("mailto")), ("to", .int(d.to.count))])
        }
    }
}
