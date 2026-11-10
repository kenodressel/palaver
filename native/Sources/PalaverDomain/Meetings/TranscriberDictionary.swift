// The dictionary (palaver/dictionary.py `Dictionary`): an initial_prompt hint for the transcriber and
// replacements applied to what it wrote. Named apart from Swift's `Dictionary`.
import Foundation
import PalaverCore

public struct TranscriberDictionary {
    public let initialPrompt: String
    /// Source → replacement, in the file's order.
    public let replacements: PyDict<String>
    /// Each source as a case-insensitive literal pattern, longest source first (equal ones in file order),
    /// built once: compiling a PyRegex is expensive.
    private let rules: [(pattern: PyRegex, replacement: String)]

    public init(initialPrompt: String = "", replacements: PyDict<String> = PyDict()) {
        self.initialPrompt = initialPrompt
        self.replacements = replacements
        let longestFirst = Py.stableSorted(Array(replacements)) { $0.key.unicodeScalars.count > $1.key.unicodeScalars.count }
        rules = longestFirst.compactMap { source, replacement in
            (try? PyRegex(PyRegex.escape(source), ignoreCase: true)).map { ($0, replacement) }
        }
    }

    /// Case-insensitive find-and-replace. Longest match first to avoid overlap. A replacement is
    /// `re`'s template (`\\`, `\g<0>`, `\n`); one `re` would reject is put in as it is.
    public func apply(_ text: String) -> String {
        var text = text
        for (pattern, replacement) in rules {
            text = (try? pattern.sub(replacement, in: text)) ?? pattern.sub(in: text) { _ in replacement }
        }
        return text
    }

    /// `load_dictionary`: the file at `url` (default: the config dir's dictionary.toml); an empty
    /// dictionary when it is not there. Values are `str(v)`; arrays and tables are not replacements.
    public static func load(_ url: URL? = nil) -> TranscriberDictionary {
        let file = url ?? StorePaths.current().dictionary
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else {
            return TranscriberDictionary()
        }
        let toml = Toml.parseOrdered(text)
        var initial = ""
        if case .string(let s)? = toml.values["initial_prompt.text"] { initial = s }
        var pairs: [(String, String)] = []
        let prefix = "replacements."
        for key in toml.order where key.hasPrefix(prefix) {
            let value: String
            switch toml.values[key]! {
            case .string(let s): value = s
            case .int(let i): value = String(i)
            case .double(let d): value = Py.repr(d)
            case .bool(let b): value = b ? "True" : "False"
            case .other: continue
            }
            pairs.append((String(key.dropFirst(prefix.count)), value))
        }
        return TranscriberDictionary(initialPrompt: initial, replacements: PyDict(pairs))
    }
}
