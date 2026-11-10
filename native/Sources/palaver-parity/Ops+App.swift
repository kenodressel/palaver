// The Swift side of the `app-state` parity op (tools/parity/ops.py, section "the menu bar app's files").
import Foundation
import PalaverCore
import PalaverDomain

extension ParityOps {
    static let app: [String: Op] = ["app-state": appStateOp]

    static let appFiles = ["daemon.json", "update.json"]

    /// The menu bar app's files the window's server reads: `files` ({name: JSON value, or null to remove it}) written
    /// into the side's Application Support/palaver; the string "<now>" anywhere in a value is the time now.
    static func appStateOp(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        guard case .object(let files)? = args["files"], files.allSatisfy({ name, _ in appFiles.contains { $0.unicodeScalars.elementsEqual(name.unicodeScalars) } }) else {
            throw BadArgs(description: "app-state: files is {name: value} with names from \(appFiles)")
        }
        let now = Py.isoNow(timespec: "seconds")
        func fill(_ v: JSONValue) -> JSONValue {
            switch v {
            case .string(let s) where s.unicodeScalars.elementsEqual("<now>".unicodeScalars): return .string(now)
            case .object(let o): return .object(o.map { ($0.0, fill($0.1)) })
            case .array(let a): return .array(a.map(fill))
            default: return v
            }
        }
        let root = side.stores.support
        for (name, value) in files {
            let url = root.appendingPathComponent(name)
            if value == .null {
                try? FileManager.default.removeItem(at: url)
            } else {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data(PythonJSON.dumps(fill(value)).utf8).write(to: url)
            }
        }
        return .object([("written", .strings(Py.stableSorted(files.map(\.0), by: Py.less)))])
    }
}
