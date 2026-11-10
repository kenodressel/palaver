// The Swift side of the `stores` parity ops (tools/parity/ops.py).
import Foundation
import PalaverCore
import PalaverDomain

extension ParityOps {
    static let stores: [String: Op] = ["hold-lock": holdLock]

    /// Takes the lock of `args["target"]` (a store path, relative to the side's root unless absolute; `args["meeting"]: true` means a recording
    /// folder), holds it for 0.5 s and answers `{"held": true}`: a writer started meanwhile must wait.
    static func holdLock(_ side: ParitySide, _ args: JSONValue) throws -> JSONValue {
        guard let target = args["target"]?.stringValue else { throw BadArgs(description: "hold-lock needs target") }
        let url = URL(fileURLWithPath: target, relativeTo: side.root).absoluteURL
        let hold = { usleep(500_000) }
        if args["meeting"]?.boolValue == true { try StoreLock.meeting(RecordingPaths(url), hold) } else { try StoreLock.with(url, hold) }
        return .object([("held", .bool(true))])
    }
}
