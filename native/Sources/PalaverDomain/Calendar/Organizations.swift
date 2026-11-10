// Which organization people belong to (organizations.py): "Timo Strauß (KLOUD)", "Stefan D (Extern)". The calendar
// knows everyone's email address and the domain says the organization (contoso.es, contoso.com and contoso.de are all
// Contoso); private addresses count as "Extern". Organizations get a name derived from the domain, which the user can
// change, and a person can be given one by hand. Stored in `organizations.json` next to the voice bank.
import Foundation
import PalaverCore

/// The names and hand-given organizations of `organizations.json` (`names`: key → name, `people`: casefolded person →
/// organization), written like Python's `json.dumps(indent=2, ensure_ascii=False)` through `organizations.json.tmp`
/// under `organizations.json.lock`.
public final class Organizations {
    public let path: URL
    private var top = PyDict<JSONValue>()
    private var names = PyDict<JSONValue>()
    private var people = PyDict<JSONValue>()

    public init(path: URL? = nil) {
        self.path = path ?? StorePaths.current().organizations
        if let data = PythonJSON.read(self.path), let fields = PyDict<JSONValue>(data) { top = fields }
        names = top["names"].flatMap { PyDict<JSONValue>($0) } ?? PyDict()
        people = top["people"].flatMap { PyDict<JSONValue>($0) } ?? PyDict()
        top["names"] = names.json
        top["people"] = people.json
    }

    public func save() throws {
        try StoreLock.with(path) {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            var out = top
            out["names"] = names.json
            out["people"] = people.json
            // `path.with_suffix(".json.tmp")`: "organizations.json.tmp".
            try PythonJSON.write(out.json, to: path, indent: 2, ensureAscii: false, via: path.lastPathComponent + ".tmp")
        }
    }

    /// The name of organization `key`: the one given, else the one the key suggests.
    public func name(_ key: String) -> String {
        if let given = names[key]?.stringValue, !given.isEmpty { return given }
        return Orgs.defaultName(key)
    }

    public func rename(_ key: String, _ name: String) {
        let name = Py.strip(name)
        if !name.isEmpty && !Py.same(name, Orgs.defaultName(key)) { names[key] = .string(name) } else { names[key] = nil }
    }

    /// The organization given to `person` by hand.
    public func person(_ person: String) -> String? {
        guard let given = people[Py.casefold(Py.strip(person))]?.stringValue, !given.isEmpty else { return nil }
        return given
    }

    public func setPerson(_ person: String, _ org: String?) {
        let key = Py.casefold(Py.strip(person))
        if let org, !Py.strip(org).isEmpty { people[key] = .string(Py.strip(org)) } else { people[key] = nil }
    }
}

public enum Orgs {
    public static let EXTERN = "Extern"
    /// Mail providers anyone can use: their domain says nothing about an organization.
    public static let PERSONAL_DOMAINS: Set<String> = [
        "gmail.com", "googlemail.com", "gmx.at", "gmx.de", "gmx.net", "web.de", "outlook.com", "hotmail.com",
        "live.com", "icloud.com", "me.com", "yahoo.com", "yahoo.de", "proton.me", "protonmail.com", "aon.at",
        "chello.at", "a1.net", "t-online.de",
    ]

    private static let personalKeys = Set(PERSONAL_DOMAINS.map(ScalarKey.init))

    /// contoso.es → "contoso"; a private address → "extern"; nil when there is no domain (note: `a@.com` is "", as
    /// in Python; callers treat it as no key).
    public static func orgKey(_ email: String?) -> String? {
        guard let email, !email.isEmpty, let at = email.unicodeScalars.lastIndex(of: "@") else { return nil }
        let domain = Py.strLower(String(email.unicodeScalars[email.unicodeScalars.index(after: at)...]))
        if personalKeys.contains(ScalarKey(domain)) { return "extern" }
        let labels = domain.unicodeScalars.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 ? String(String.UnicodeScalarView(labels[labels.count - 2])) : nil
    }

    /// "kloud" → KLOUD (short ones look like acronyms), "contoso" → Contoso.
    public static func defaultName(_ key: String) -> String {
        if Py.same(key, "extern") { return EXTERN }
        return key.unicodeScalars.count <= 5 ? Py.strUpper(key) : Py.strTitle(key)
    }

    // MARK: - the index of invitees

    private struct Person {
        var name = "", email = "", isSelf = false
        var emails = PyDict<Int>()
    }

    /// Everyone the calendars invited: casefolded name → {"emails" (each with how often it was invited), "self", "name",
    /// "email" (the latest)}.
    public static func peopleIndex(outputDir: URL) -> PyDict<JSONValue> {
        var found = PyDict<Person>()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: outputDir.path, isDirectory: &isDir), isDir.boolValue,
           let names = try? FileManager.default.contentsOfDirectory(atPath: outputDir.path) {
            for name in Py.stableSorted(names, by: Py.less) where RecordingPaths.isRecordingFolderName(name) {
                let event = CalendarEvents.load(RecordingPaths(outputDir.appendingPathComponent(name)))
                for a in event?.attendees ?? [] where !a.isRoom {
                    guard let email = a.email, !email.isEmpty else { continue }
                    let key = Py.casefold(a.name)
                    var entry = found[key] ?? Person()
                    entry.name = a.name
                    entry.email = email
                    entry.isSelf = entry.isSelf || a.isSelf
                    entry.emails[email] = (entry.emails[email] ?? 0) + 1
                    found[key] = entry
                }
            }
        }
        var out = PyDict<JSONValue>()
        for (key, p) in found {
            out[key] = .object([("emails", .object(zip(p.emails.keys, p.emails.values).map { ($0, .int($1)) })),
                                ("self", .bool(p.isSelf)), ("name", .string(p.name)), ("email", .string(p.email))])
        }
        return out
    }

    /// An index entry's addresses with how often each was invited (an entry without `emails`: its one `email`).
    private static func emails(_ entry: JSONValue) -> [(String, Int)] {
        if let e = entry["emails"], case .object(let fields) = e {
            return fields.map { field in
                if case .int(let n) = field.1 { return (field.0, n) }
                return (field.0, 1)
            }
        }
        return [(entry["email"]?.stringValue ?? "", 1)]
    }

    /// `person` in the index: by full name, or by first name when that is unambiguous.
    private static func entry(_ person: String, _ index: PyDict<JSONValue>) -> JSONValue? {
        let key = Py.casefold(Py.strip(person))
        if let e = index[key] { return e }
        if key.unicodeScalars.contains(" ") || key.isEmpty { return nil }
        // An entry keyed by only whitespace has no first name (Python's `k.split()[0]` raises there): never a hit.
        let hits = index.filter { entry in Py.split(entry.key).first.map { Py.same($0, key) } ?? false }
        return hits.count == 1 ? hits[0].value : nil
    }

    private static func ownKey(_ index: PyDict<JSONValue>) -> String? {
        guard let mine = index.first(where: { $0.value["self"]?.truthy == true }) else { return nil }
        return orgKey(mine.value["email"]?.stringValue)
    }

    /// The organization an invitee's emails say. A colleague placed at a client is often invited with the client's
    /// address: any address in the user's own organization makes them one. Otherwise the organization they were invited
    /// with most often.
    private static func keyOf(_ entry: JSONValue, _ own: String?) -> String? {
        var counts = PyDict<Int>()
        for (email, n) in emails(entry) {
            if let key = orgKey(email), !key.isEmpty { counts[key] = (counts[key] ?? 0) + n }
        }
        if let own, !own.isEmpty, !Py.same(own, "extern"), counts[own] != nil { return own }
        let latest = orgKey(entry["email"]?.stringValue)
        // max(counts, key=lambda k: (counts[k], k == latest)): the first of equals.
        var best: (key: String, n: Int, isLatest: Bool)?
        for (k, n) in counts {
            let isLatest = latest.map { Py.same(k, $0) } ?? false
            if let b = best, !(n > b.n || (n == b.n && isLatest && !b.isLatest)) { continue }
            best = (k, n, isLatest)
        }
        return best?.key
    }

    /// The organization of `person`: given by hand, else from their emails.
    public static func orgOf(_ person: String, _ index: PyDict<JSONValue>, _ orgs: Organizations) -> String? {
        if let given = orgs.person(person) { return given }
        guard let e = entry(person, index), let key = keyOf(e, ownKey(index)) else { return nil }
        return orgs.name(key)
    }

    /// `person`'s organization and why: given by hand, or the email addresses they were invited with (unsure when those
    /// say two organizations, or when only a first name matched).
    public static func orgLink(_ person: String, _ index: PyDict<JSONValue>, _ orgs: Organizations) -> Link? {
        if let given = orgs.person(person) { return Link("org", given, "you") }
        guard let e = entry(person, index) else { return nil }
        let own = ownKey(index)
        guard let key = keyOf(e, own) else { return nil }
        var keys = Set<ScalarKey>()
        for (email, _) in emails(e) { if let k = orgKey(email), !k.isEmpty { keys.insert(ScalarKey(k)) } }
        var confidence: Double
        var reason: String
        if keys.count > 1 && own.map { Py.same(key, $0) && !Py.same($0, "extern") } == true {
            confidence = 0.9; reason = "has an address of your organization"  // a colleague at a client: settled
        } else if keys.count > 1 {
            confidence = 0.6; reason = "invited with addresses of \(keys.count) organizations"
        } else {
            confidence = 0.9; reason = "invited as \(e["email"]?.stringValue ?? "")"
        }
        if index[Py.casefold(Py.strip(person))] == nil {
            confidence = min(confidence, 0.6); reason += "; matched by first name"
        }
        return Link("org", orgs.name(key), "email", confidence, reason)
    }

    /// The user's organization: given by hand, else from their own address.
    public static func ownOrg(_ index: PyDict<JSONValue>, _ orgs: Organizations, userName: String) -> String? {
        if let given = orgs.person(userName) { return given }
        guard let key = ownKey(index), !key.isEmpty else { return nil }
        return orgs.name(key)
    }

    /// Organizations with how many invitees each, most first, for editing: {"key", "name", "default", "people"}.
    public static func summary(_ index: PyDict<JSONValue>, _ orgs: Organizations) -> [JSONValue] {
        var counts = PyDict<Int>()
        let own = ownKey(index)
        for (_, e) in index { if let key = keyOf(e, own), !key.isEmpty { counts[key] = (counts[key] ?? 0) + 1 } }
        let sorted = Py.stableSorted(Array(counts)) { a, b in a.value != b.value ? a.value > b.value : Py.less(a.key, b.key) }
        return sorted.map { k, n in
            .object([("key", .string(k)), ("name", .string(orgs.name(k))), ("default", .string(defaultName(k))), ("people", .int(n))])
        }
    }
}
