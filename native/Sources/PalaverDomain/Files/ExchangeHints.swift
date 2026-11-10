// The names an imported meeting came with (exchange.py:824-851, issue #58): the sender's word, not the user's. They
// are stored like inferred names ("named by Anna"), which the user confirms or rejects; inference keeps them unless a
// rule is surer. The import itself comes with Tasks 24 and 25.
import Foundation
import PalaverCore

public enum ExchangeHints {
    /// How sure a name from the export is, by how it was named there.
    public static let HINT_CONFIDENCE = PyDict<Double>([("exporter", 1.0), ("hand", 0.9), ("voice", 0.8), ("inferred", 0.6)])
    public static let HOWS = ["exporter", "hand", "voice", "inferred"]
    /// The rule of an inferred name that came with an import.
    public static let IMPORTED = "imported"

    /// What came with an imported meeting (imported.json, a JSON object), or nil.
    public static func loadRecord(_ paths: RecordingPaths) -> JSONValue? {
        guard let record = PythonJSON.read(paths.imported), case .object = record else { return nil }
        return record
    }

    /// label → the inferred-name entry (as inference stores them: name, rule, why, confidence, depends, by, how) of a
    /// name that came with the import. A `names` that is not an object counts as none.
    public static func hints(_ paths: RecordingPaths) -> PyDict<JSONValue> {
        guard let record = loadRecord(paths), record.truthy else { return PyDict() }
        let from = record["from"]
        let sender = from.map { $0.truthy } == true ? pyStr(from!) : "the sender"
        var out = PyDict<JSONValue>()
        guard case .object(let names)? = record["names"] else { return out }
        for (label, hint) in names {
            guard case .object = hint, let name = hint["name"], name.truthy else { continue }
            var how = "inferred"
            if case .string(let given)? = hint["how"], HOWS.contains(where: { Py.same($0, given) }) { how = given }
            out[label] = .object([
                ("name", name), ("rule", .string(IMPORTED)), ("why", .string(why(how, sender))),
                ("confidence", .double(HINT_CONFIDENCE[how]!)), ("depends", .array([])), ("by", .string(sender)),
                ("how", .string(how)),
            ])
        }
        return out
    }

    /// `_why`: in words, how the sender knew the name.
    static func why(_ how: String, _ sender: String) -> String {
        switch how {
        case "exporter": return "\(sender)'s own microphone in their recording."
        case "hand": return "Named by \(sender) in their recording."
        case "voice": return "\(sender)'s Palaver recognized the voice."
        default: return "\(sender)'s Palaver inferred the name."
        }
    }
}
