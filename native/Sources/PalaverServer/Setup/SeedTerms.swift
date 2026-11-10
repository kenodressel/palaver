// Glossary terms the calendar suggests, so names are spelled right from the first meeting (palaver/onboarding.py
// `_TITLE_STOP`, `_TITLE_WORD`, `TITLE_ZIPF`, `MAX_SEED_TERMS`, `own_organization`, `seed_terms`).
import PalaverCore
import PalaverDomain

public struct SeedTerm: Equatable {
    public var term: String
    /// "person", "organization" or "title"
    public var kind: String
    public var count: Int

    public var json: JSONValue { .object([("term", .string(term)), ("kind", .string(kind)), ("count", .int(count))]) }
}

extension Recommendations {
    /// Words in meeting titles that are no names, however rare.
    public static let TITLE_STOP: Set<ScalarKey> = Set([
        "standup", "stand-up", "weekly", "daily", "sync", "jour", "fixe", "meeting", "call", "review",
        "planning", "retro", "kickoff", "kick-off", "intro", "onboarding", "workshop", "update", "lunch",
        "abstimmung", "besprechung", "termin", "teams",
    ].map(ScalarKey.init))
    static let TITLE_WORD = try! PyRegex(#"\b[A-ZÄÖÜ][\wÄÖÜäöüß-]{3,}\b"#)
    /// A title word this rare is likely a name (a customer, a project).
    public static let TITLE_ZIPF = 3.0
    public static let MAX_SEED_TERMS = 30

    /// `own_organization`: the user's organization, from their own address in the calendar.
    public static func ownOrganization(_ events: [CalendarEvent]) -> String? {
        for e in events {
            for a in e.attendees {
                let key = a.isSelf ? Orgs.orgKey(a.email) : nil
                if let key, !key.isEmpty, !Py.same(key, "extern") { return Orgs.defaultName(key) }
            }
        }
        return nil
    }

    /// `seed_terms`: invitees, their organizations (from the email domain) and rare words in event titles. The user, their own
    /// organization and terms already known are left out.
    public static func seedTerms(_ events: [CalendarEvent], userName: String, known: [String] = []) -> [SeedTerm] {
        var skip = Set(known.map { ScalarKey(Py.casefold($0)) })
        skip.insert(ScalarKey(Py.casefold(userName)))
        // `next(org_key(a.email) for ... if a.is_self and a.email, None)`: the first self address, even when it has no key.
        var own: String?
        search: for e in events {
            for a in e.attendees where a.isSelf && !(a.email ?? "").isEmpty {
                own = Orgs.orgKey(a.email)
                break search
            }
        }
        var found = PyDict<SeedTerm>()

        func add(_ term: String, _ kind: String, _ seen: inout Set<ScalarKey>) {
            let key = Py.casefold(term)
            if skip.contains(ScalarKey(key)) || seen.contains(ScalarKey(key)) { return }
            seen.insert(ScalarKey(key))
            var entry = found[key] ?? SeedTerm(term: term, kind: kind, count: 0)
            entry.count += 1
            found[key] = entry
        }

        for e in events {
            var seen = Set<ScalarKey>()
            for a in e.attendees {
                if a.isSelf || a.isRoom || (a.email ?? "").isEmpty || CalendarEvents.looksLikeRoom(a.name) { continue }
                if Py.split(a.name).count >= 2 && !a.name.unicodeScalars.contains("@") {
                    add(Py.strip(a.name), "person", &seen)
                }
                if let key = Orgs.orgKey(a.email), !key.isEmpty, !Py.same(key, "extern"), own == nil || !Py.same(key, own!) {
                    add(Orgs.defaultName(key), "organization", &seen)
                }
            }
            for m in TITLE_WORD.matches(in: e.title) {
                let word = m.group(0)!, folded = Py.casefold(word)
                if !TITLE_STOP.contains(ScalarKey(folded)) && found[folded] == nil && Zipf.zipf(word) < TITLE_ZIPF {
                    add(word, "title", &seen)
                }
            }
        }
        func order(_ kind: String) -> Int { Py.same(kind, "person") ? 0 : (Py.same(kind, "organization") ? 1 : 2) }
        let sorted = Py.stableSorted(Array(found.values)) { a, b in
            if a.count != b.count { return a.count > b.count }
            if order(a.kind) != order(b.kind) { return order(a.kind) < order(b.kind) }
            return Py.less(a.term, b.term)
        }
        return Array(sorted.prefix(MAX_SEED_TERMS))
    }
}
