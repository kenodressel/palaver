// Sorting meetings into projects by rules (projects.py:204-374): what a meeting is about (its people, title words and
// customer), how alike two meetings are, and putting a meeting into the project it clearly resembles. The language
// model's part (projects.py:377 on) stays Python until phase 4.
import Foundation
import PalaverCore

/// What a meeting is about (projects.py `Facts`). The sets are lists of distinct strings (by code points), in code-point
/// order (Python's `sorted` of the frozenset).
public struct ProjectFacts: Sendable {
    public var meeting: String
    public var title: String
    public var start: String
    /// Casefolded names: who spoke and who was invited.
    public var people: [String]
    /// Customers: invitees' email domains other than the user's.
    public var orgs: [String]
    /// Title words.
    public var words: [String]
    public var summary: String
    /// The calendar event's series id: the same on every occurrence.
    public var series: String

    public init(meeting: String, title: String, start: String, people: [String], orgs: [String], words: [String],
                summary: String = "", series: String = "") {
        self.meeting = meeting; self.title = title; self.start = start
        self.people = ProjectRules.distinct(people); self.orgs = ProjectRules.distinct(orgs)
        self.words = ProjectRules.distinct(words); self.summary = summary; self.series = series
    }
}

/// How alike two meetings are. Rare things count more: sharing a customer's people says more than sharing a colleague
/// who is in every meeting.
public struct Similarity {
    private enum Kind: Int { case people, orgs, words }
    /// `log(1 + n / count)` by kind, then by value.
    private var idf: [[ScalarKey: Double]] = [[:], [:], [:]]

    public init(_ all: PyDict<ProjectFacts>) {
        let n = Double(max(all.count, 1))
        for kind in [Kind.people, .orgs, .words] {
            var counts: [ScalarKey: Int] = [:]
            for f in all.values {
                for x in Self.values(f, kind) { counts[ScalarKey(x), default: 0] += 1 }
            }
            for (x, c) in counts { idf[kind.rawValue][x] = log(1 + n / Double(c)) }
        }
    }

    private static func values(_ f: ProjectFacts, _ kind: Kind) -> [String] {
        switch kind {
        case .people: return f.people
        case .orgs: return f.orgs
        case .words: return f.words
        }
    }

    /// Dice over idf weights: "Sync" is not "Foundry Sync".
    private func overlap(_ kind: Kind, _ a: [String], _ b: [String]) -> Double {
        if a.isEmpty || b.isEmpty { return 0.0 }
        func weight(_ xs: [String]) -> Double { Py.sum(xs.map { idf[kind.rawValue][ScalarKey($0)] ?? 1.0 }) }
        let inB = Set(b.map(ScalarKey.init))
        return 2 * weight(a.filter { inB.contains(ScalarKey($0)) }) / (weight(a) + weight(b))
    }

    /// Score in 0...1 and the strongest reason ("people", "title", "customer", or "series"). One signal in full is
    /// enough to assign (the same recurring title, the same people); together they add up. The same calendar series
    /// is the same project.
    public func callAsFunction(_ a: ProjectFacts, _ b: ProjectFacts) -> (score: Double, why: String) {
        if !a.series.isEmpty && Py.same(a.series, b.series) { return (1.0, "series") }
        let parts: [(String, Double)] = [
            ("people", ProjectRules.WEIGHTS[0].1 * overlap(.people, a.people, b.people)),
            ("title", ProjectRules.WEIGHTS[1].1 * overlap(.words, a.words, b.words)),
            ("customer", ProjectRules.WEIGHTS[2].1 * overlap(.orgs, a.orgs, b.orgs)),
        ]
        var product = 1.0
        for (_, p) in parts { product *= 1 - p }
        var best = parts[0]  // max(parts, key=parts.get): the first of equals
        for part in parts.dropFirst() where part.1 > best.1 { best = part }
        return (1 - product, best.0)
    }
}

public enum ProjectRules {
    /// Similarity to a project's closest meeting needed to put a meeting in it without asking, and to suggest it.
    public static let ASSIGN_SCORE = 0.6
    public static let SUGGEST_SCORE = 0.35
    /// `WEIGHTS`, in Python's dict order.
    public static let WEIGHTS: [(String, Double)] = [("people", 0.6), ("title", 0.6), ("customer", 0.35)]

    public static let STOP_WORDS: [String] = """
    a an and at for from in of on or the to with x re fw aw wg
    bei das der die ein eine für im in mit und von zu zum zur
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    private static let stopKeys = Set(STOP_WORDS.map(ScalarKey.init))

    /// `sorted(set(xs))`: each string once (by code points), in code-point order.
    static func distinct(_ xs: [String]) -> [String] {
        var seen = Set<ScalarKey>(), out: [String] = []
        for x in xs where seen.insert(ScalarKey(x)).inserted { out.append(x) }
        return Py.stableSorted(out, by: Py.less)
    }

    /// `settings.me(user_name)`: every name of the user, casefolded (the current one and the earlier ones, #55).
    public static func me(_ userName: String, stores: StorePaths = .current()) -> [String] {
        distinct(([userName] + SettingsFile.userAliases(stores: stores)).filter { !$0.isEmpty }.map(Py.casefold))
    }

    /// contoso.com, contoso.es → contoso.
    static func org(_ email: String?) -> String? {
        guard let email, let at = email.unicodeScalars.lastIndex(of: "@") else { return nil }
        let domain = Py.strLower(String(email.unicodeScalars[email.unicodeScalars.index(after: at)...]))
        let parts = domain.unicodeScalars.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 ? String(String.UnicodeScalarView(parts[parts.count - 2])) : nil
    }

    /// Title words: `re.findall(r"[^\W\d_]{3,}", title.casefold())` (runs of three or more letters), without stop words
    /// and the words of the user's names (`me`: casefolded).
    static func words(_ title: String, me: [String]) -> [String] {
        var skip = stopKeys
        for name in me { for w in Py.split(name) { skip.insert(ScalarKey(w)) } }
        var out: [String] = []
        var run = String.UnicodeScalarView()
        func flush() {
            if run.count >= 3, !skip.contains(ScalarKey(String(run))) { out.append(String(run)) }
            run = String.UnicodeScalarView()
        }
        for u in Py.casefold(title).unicodeScalars {
            if Py.isWordScalar(u) && !Py.isDecimal(u) && u != "_" { run.append(u) } else { flush() }
        }
        flush()
        return out
    }

    /// The invitees (people and customers) of `event`, as `facts` and `event_facts` gather them.
    private static func invited(_ event: CalendarEvent, userName: String) -> (people: [String], orgs: [String]) {
        let own = Set(event.attendees.filter(\.isSelf).compactMap { org($0.email) }.map(ScalarKey.init))
        var people: [String] = [], orgs: [String] = []
        for a in CalendarEvents.candidates(event, userName: userName) {
            people.append(Py.casefold(a.name))
            if let o = org(a.email), !o.isEmpty, !own.contains(ScalarKey(o)) { orgs.append(o) }
        }
        return (people, orgs)
    }

    /// What a recorded meeting is about. Throws where Python raises (a speaker file it can't read).
    public static func facts(_ paths: RecordingPaths, userName: String, stores: StorePaths = .current()) throws -> ProjectFacts {
        try facts(paths, userName: userName, me: me(userName, stores: stores), stores: stores)
    }

    static func facts(_ paths: RecordingPaths, userName: String, me: [String], stores: StorePaths) throws -> ProjectFacts {
        let event = CalendarEvents.load(paths)
        let notes = NotesFile.load(paths).flatMap { $0.truthy ? $0 : nil } ?? .object([])  // `notes.load(paths) or {}`
        var people = try Speakers.namesInEffect(paths).values.map(Py.casefold)
        var orgs: [String] = []
        if let event {
            let found = invited(event, userName: userName)
            people += found.people
            orgs = found.orgs
        }
        let mine = Set(me.map(ScalarKey.init))
        people = people.filter { !mine.contains(ScalarKey($0)) }  // an earlier name of the user too (#55)
        let title = Titles.resolve(paths, event: .known(event), meetingNotes: .known(notes), stores: stores).title ?? ""
        return ProjectFacts(meeting: paths.folder.lastPathComponent, title: title,
                            start: PythonJSON.read(paths.meta)?["start_time"]?.stringValue ?? "", people: people, orgs: orgs,
                            words: words(title, me: me), summary: notes["summary"]?.stringValue ?? "",
                            series: event?.seriesId ?? "")
    }

    /// What a meeting that has not happened yet is about: its calendar event.
    public static func eventFacts(_ event: CalendarEvent, userName: String, stores: StorePaths = .current()) -> ProjectFacts {
        let found = invited(event, userName: userName)
        return ProjectFacts(meeting: event.key.isEmpty ? event.title : event.key, title: event.title, start: event.start.iso,
                            people: found.people, orgs: found.orgs, words: words(event.title, me: me(userName, stores: stores)),
                            series: event.seriesId)
    }

    /// Facts of every processed meeting (one with a transcript), by folder name in order.
    public static func allFacts(outputDir: URL, userName: String, stores: StorePaths = .current()) throws -> PyDict<ProjectFacts> {
        var out = PyDict<ProjectFacts>()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: outputDir.path, isDirectory: &isDir), isDir.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: outputDir.path) else { return out }
        let mine = me(userName, stores: stores)
        for name in Py.stableSorted(names, by: Py.less) where RecordingPaths.isRecordingFolderName(name) {
            let paths = RecordingPaths(outputDir.appendingPathComponent(name, isDirectory: true))
            guard FileManager.default.fileExists(atPath: paths.transcriptJson.path) else { continue }
            out[name] = try facts(paths, userName: userName, me: mine, stores: stores)
        }
        return out
    }

    /// (project id, score, why) for every project, best first. A project is represented by its meetings that the user
    /// or the model put there.
    public static func scores(_ meeting: ProjectFacts, _ store: ProjectStore, _ all: PyDict<ProjectFacts>,
                              _ similarity: Similarity) -> [(pid: String, score: Double, why: String)] {
        var out: [(pid: String, score: Double, why: String)] = []
        for pid in store.projects.keys {
            var best = 0.0, why = ""
            for (other, how) in store.meetingsOf(pid) {
                guard !Py.same(other, meeting.meeting), how["by"]?.stringValue.map({ Py.same($0, "auto") }) != true,
                      let facts = all[other] else { continue }
                let (score, reason) = similarity(meeting, facts)
                if score > best { best = score; why = "\(reason) like “\(facts.title)”" }
            }
            if best > 0 { out.append((pid, best, why)) }
        }
        return Py.stableSorted(out) { $0.score > $1.score }
    }

    /// Put meetings that are in no project yet (`meetings`, else every processed one) into the project they clearly
    /// resemble. The meetings are read first; then, under `projects.json.lock`, the store is read afresh, the rules
    /// applied and the store saved. Answers that store and the (meeting, project id) pairs added. It takes no caller's
    /// store, so no unsaved change can be dropped: save yours before (and change it again under the lock after).
    @discardableResult
    public static func assignByRules(outputDir: URL, userName: String, meetings: [String]? = nil,
                                     stores: StorePaths = .current()) throws -> (store: ProjectStore, added: [(String, String)]) {
        let every = try allFacts(outputDir: outputDir, userName: userName, stores: stores)
        let similarity = Similarity(every)
        let store = ProjectStore(path: stores.projects)
        let added = try store.locked {
            store.reload()
            var added: [(String, String)] = []
            for mid in meetings ?? every.keys {
                guard let facts = every[mid], store.ofMeeting(mid).isEmpty else { continue }
                for (pid, score, why) in scores(facts, store, every, similarity) {
                    if score >= ASSIGN_SCORE,
                       try store.assign(mid, pid, by: "auto", why: why, confidence: Py.round(score, 2)) {
                        added.append((mid, pid))
                        break  // a second project is the user's or the model's call
                    }
                }
            }
            try store.save()
            return added
        }
        return (store, added)
    }

    /// Projects a meeting might belong to, for the user to confirm: at most three `{"id", "name", "score", "why"}`.
    public static func suggestions(_ meeting: String, store: ProjectStore, every: PyDict<ProjectFacts>,
                                   similarity: Similarity? = nil) -> [JSONValue] {
        guard let facts = every[meeting] else { return [] }
        let taken = Set((store.ofMeeting(meeting).keys + store.rejected(meeting)).map(ScalarKey.init))
        return offered(scores(facts, store, every, similarity ?? Similarity(every)), store, taken: taken)
    }

    /// The scores above `SUGGEST_SCORE` of projects not `taken`, at most three, as the window shows them.
    static func offered(_ scores: [(pid: String, score: Double, why: String)], _ store: ProjectStore,
                        taken: Set<ScalarKey>) -> [JSONValue] {
        scores.filter { !taken.contains(ScalarKey($0.pid)) && $0.score >= SUGGEST_SCORE }.prefix(3).map { s in
            .object([("id", .string(s.pid)), ("name", store.projects[s.pid]?["name"] ?? .null),
                     ("score", .double(Py.round(s.score, 2))), ("why", .string(s.why))])
        }
    }
}
