// The glossary store and its applying (palaver/glossary.py:51-222): terms and their variants in
// glossary.json, written as Python writes it (indent 2, ensure_ascii off, no trailing newline, via
// glossary.json.tmp, under glossary.json.lock). The suggestions are GlossarySuggest's.
import Foundation
import PalaverCore

/// What `_term` raises (`LookupError`): the window's server answers 500 for it.
public struct GlossaryLookupError: Error, CustomStringConvertible {
    public let id: String
    public init(id: String) { self.id = id }
    public var description: String { id }
}

/// A `ValueError` of the store ("a term is needed", "<term> is already in the glossary"): 400.
public struct GlossaryValueError: Error, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
}

public final class Glossary: @unchecked Sendable {
    public let path: URL
    /// id → {"term", "variants": [...], "note"}, in file order. Change it through the methods below.
    public private(set) var terms = PyDict<JSONValue>()
    private var rejectedKeys: [String] = []
    /// The file's top-level keys in order ("terms" and "rejected" stand for the two stores above), and
    /// any key Python's dict kept besides them.
    private var top = PyDict<JSONValue>()
    /// New ids; `uuid4().hex[:8]` in Python. Replaceable for deterministic runs (parity).
    public var makeId: () -> String = { String(format: "%08x", UInt32.random(in: 0...UInt32.max)) }

    private struct Compiled {
        let regex: PyRegex?
        let replacements: PyDict<String>
    }
    private let lock = NSLock()
    private var compiled: Compiled?

    public init(path: URL? = nil) {
        self.path = path ?? StorePaths.current().glossary
        reload()
    }

    public func reload() {
        top = PyDict()
        terms = PyDict()
        rejectedKeys = []
        if let data = PythonJSON.read(path), let fields = PyDict<JSONValue>(data) {
            top = fields
            if let t = fields["terms"], let entries = PyDict<JSONValue>(t) { terms = entries }
            if let r = fields["rejected"]?.arrayValue { rejectedKeys = r.compactMap(\.stringValue) }
        }
        if top["terms"] == nil { top["terms"] = .object([]) }
        if top["rejected"] == nil { top["rejected"] = .array([]) }
        invalidate()
    }

    public func save() throws {
        try StoreLock.with(path) {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            var out = top
            out["terms"] = terms.json
            out["rejected"] = .strings(rejectedKeys)
            try PythonJSON.write(out.json, to: path, indent: 2, ensureAscii: false, via: Self.tmpName(path))
            Self.clearCurrent(path)
        }
    }

    /// `path.with_suffix(".json.tmp")`'s name.
    private static func tmpName(_ path: URL) -> String {
        let name = path.lastPathComponent
        if let dot = name.lastIndex(of: "."), dot != name.startIndex { return String(name[..<dot]) + ".json.tmp" }
        return name + ".json.tmp"
    }

    // MARK: - entries

    private func variants(_ entry: JSONValue) -> [String] { (entry["variants"]?.arrayValue ?? []).compactMap(\.stringValue) }
    private func termText(_ entry: JSONValue) -> String { entry["term"]?.stringValue ?? "" }

    /// The entry with `key` set (in its place when it has one, else last).
    private func with(_ entry: JSONValue, _ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = entry else { return .object([(key, value)]) }
        if let i = fields.firstIndex(where: { Py.same($0.0, key) }) { fields[i].1 = value } else { fields.append((key, value)) }
        return .object(fields)
    }

    private func entry(_ tid: String) throws -> JSONValue {
        guard let e = terms[tid] else { throw GlossaryLookupError(id: tid) }
        return e
    }

    private func invalidate() { lock.withLock { compiled = nil } }

    public func find(_ term: String) -> String? {
        let want = Py.casefold(Py.strip(term))
        return terms.first { Py.same(Py.casefold(termText($0.value)), want) }?.key
    }

    /// The term a variant already maps to.
    public func owner(_ variant: String) -> String? {
        let want = Py.casefold(Py.strip(variant))
        return terms.first { variants($0.value).contains { Py.same(Py.casefold($0), want) } }?.key
    }

    /// Adds a term, or variants to an existing one. A variant moves from any other term; the term's own
    /// spelling is never a variant. Returns the term's id (8 lowercase hex for a new one).
    @discardableResult
    public func add(term: String, variants newVariants: [String] = [], note: String = "") throws -> String {
        let term = Py.strip(term)
        if term.isEmpty { throw GlossaryValueError(description: "a term is needed") }
        let tid: String
        if let found = find(term) {
            tid = found
        } else {
            var fresh = makeId()
            while terms[fresh] != nil { fresh = makeId() }
            tid = fresh
            terms[tid] = .object([("term", .string(term)), ("variants", .array([])), ("note", .string(Py.strip(note)))])
        }
        for v in newVariants {
            let v = Py.strip(v)
            if v.isEmpty || Py.same(Py.casefold(v), Py.casefold(term)) { continue }
            if let other = owner(v), other != tid { try removeVariant(other, v) }
            var mine = variants(terms[tid]!)
            if !mine.contains(where: { Py.same(Py.casefold($0), Py.casefold(v)) }) {
                mine.append(v)
                terms[tid] = with(terms[tid]!, "variants", .strings(mine))
            }
        }
        if let wrong = owner(term) { try removeVariant(wrong, term) }  // the right spelling was listed as a variant
        invalidate()
        return tid
    }

    public func update(_ tid: String, term: String? = nil, note: String? = nil) throws {
        var e = try entry(tid)
        if let term {
            let term = Py.strip(term)
            if term.isEmpty { throw GlossaryValueError(description: "a term is needed") }
            if let other = find(term), other != tid { throw GlossaryValueError(description: "\(term) is already in the glossary") }
            e = with(e, "term", .string(term))
            e = with(e, "variants", .strings(variants(e).filter { !Py.same(Py.casefold($0), Py.casefold(term)) }))
        }
        if let note { e = with(e, "note", .string(Py.strip(note))) }
        terms[tid] = e
        invalidate()
    }

    /// Drops the variants equal to `variant` by casefold (not stripped).
    public func removeVariant(_ tid: String, _ variant: String) throws {
        let e = try entry(tid)
        let gone = Py.casefold(variant)
        terms[tid] = with(e, "variants", .strings(variants(e).filter { !Py.same(Py.casefold($0), gone) }))
        invalidate()
    }

    public func delete(_ tid: String) throws {
        _ = try entry(tid)
        terms.removeValue(forKey: tid)
        invalidate()
    }

    /// Never suggest this again (a suggestion's key). Keys compare by code points, as Python's.
    public func reject(_ key: String) {
        if !isRejected(key) { rejectedKeys.append(key) }
    }

    public func isRejected(_ key: String) -> Bool { rejectedKeys.contains { Py.same($0, key) } }

    /// The rejected keys, each once by code points, in code point order (Python: a set).
    public func rejected() -> [String] {
        var seen = Set<ScalarKey>()
        return Py.stableSorted(rejectedKeys.filter { seen.insert(ScalarKey($0)).inserted }, by: Py.less)
    }

    // MARK: - applying

    private func compile() -> Compiled {
        lock.withLock {
            if let compiled { return compiled }
            var replacements = PyDict<String>()
            for (_, e) in terms { for v in variants(e) { replacements[Py.casefold(v)] = termText(e) } }
            var regex: PyRegex?
            if !replacements.isEmpty {
                // Longest first: "Unit zu14" before "Unit". A part of a compound is respelled too: "Atterkring-Raum".
                let alternatives = Py.stableSorted(replacements.keys) { $0.unicodeScalars.count > $1.unicodeScalars.count }
                regex = try? PyRegex(#"(?<!\w)("# + alternatives.map(PyRegex.escape).joined(separator: "|") + #")(?!\w)"#,
                                     ignoreCase: true)
            }
            let c = Compiled(regex: regex, replacements: replacements)
            compiled = c
            return c
        }
    }

    /// `text` with every variant written as its term.
    public func apply(_ text: String) -> String { applyMarked(text).0 }

    /// `apply`, and where it respelled: (start, end) of each term in the new text, in scalars, with the
    /// variant that was heard there.
    public func applyMarked(_ text: String) -> (String, [(start: Int, end: Int, heard: String)]) {
        let c = compile()
        guard let regex = c.regex else { return (text, []) }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var marks: [(start: Int, end: Int, heard: String)] = []
        var last = 0, length = 0
        for m in regex.matches(in: text) {
            guard let span = m.span(1), let heard = m.group(1), let term = c.replacements[Py.casefold(heard)] else { continue }
            out.append(contentsOf: scalars[last..<span.lowerBound])
            length += span.lowerBound - last
            let n = term.unicodeScalars.count
            marks.append((length, length + n, heard))
            out.append(contentsOf: term.unicodeScalars)
            length += n
            last = span.upperBound
        }
        out.append(contentsOf: scalars[last...])
        return (String(out), marks)
    }

    /// `texts.map(apply)`, with one search over them all: a meeting's lines mostly have no variant, and a search per
    /// line costs more than the search (#29). Lines are joined with a line break, which no variant has and which is no
    /// word letter, so each line matches as it does alone.
    public func apply(lines texts: [String]) -> [String] {
        let c = compile()
        guard c.regex != nil else { return texts }
        let breaks = { (s: String) in s.unicodeScalars.contains("\n") }
        guard let regex = c.regex, !c.replacements.keys.contains(where: breaks), !texts.contains(where: breaks) else {
            return texts.map(apply)
        }
        var ends: [Int] = []  // where each line ends in the joined text, in scalars
        var at = 0
        for t in texts {
            at += t.unicodeScalars.count
            ends.append(at)
            at += 1
        }
        var respelled = Set<Int>(), line = 0
        for m in regex.matches(in: texts.joined(separator: "\n")) {
            while line < ends.count, ends[line] < m.range.lowerBound { line += 1 }
            respelled.insert(line)
        }
        return texts.enumerated().map { respelled.contains($0.offset) ? apply($0.element) : $0.element }
    }

    /// `apply` on every text in `value` (notes: objects and lists of texts).
    public func applyTo(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s): return .string(apply(s))
        case .array(let items): return .array(items.map(applyTo))
        case .object(let fields): return .object(fields.map { ($0.0, applyTo($0.1)) })
        default: return value
        }
    }

    // MARK: - the user's glossary

    private static let currentLock = NSLock()
    nonisolated(unsafe) private static var cached: [String: (mtime: Double, glossary: Glossary)] = [:]

    /// A saved file is read again by the next `current()` (Python keeps one entry and clears it; the app has one path).
    private static func clearCurrent(_ url: URL) { currentLock.withLock { _ = cached.removeValue(forKey: url.path) } }

    private static func mtime(_ url: URL) -> Double {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return 0 }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    }

    /// The user's glossary, read again when the file changes.
    public static func current(stores: StorePaths = .current()) -> Glossary {
        let url = stores.glossary
        let stamp = mtime(url)
        return currentLock.withLock {
            if let c = cached[url.path], c.mtime == stamp { return c.glossary }
            let g = Glossary(path: url)
            cached[url.path] = (stamp, g)
            return g
        }
    }
}
