// `mic_muted.json` next to a call's recording: the stretches of the raw mic that were silenced after they
// were written (a mute told late: Teams' log), so what the live workers made of them must be made again, and
// whether more may still come (the capture keeps reading Teams' log after the stop). `process` waits for it to
// settle, then redoes the mic track when any stretch is listed (CallMute, MicMuteGate).
import Darwin
import Foundation
import PalaverCore

public enum MicMuted {
    public static let fileName = "mic_muted.json"
    /// How long `process` waits for a pending file (the capture's wait is Teams' log hold, 30 s).
    public static let waitSeconds = 45.0

    public struct State: Equatable, Sendable {
        public var pending: Bool
        /// Seconds from the track's start.
        public var late: [ClosedRange<Double>]
        public init(pending: Bool, late: [ClosedRange<Double>]) { self.pending = pending; self.late = late }
    }

    public static func url(_ folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    public static func write(_ state: State, folder: URL) throws {
        let late = JSONValue.array(state.late.map { .array([.double(($0.lowerBound * 1000).rounded() / 1000),
                                                             .double(($0.upperBound * 1000).rounded() / 1000)]) })
        try PythonJSON.write(.object([("pending", .bool(state.pending)), ("late", late)]), to: url(folder), indent: nil,
                             ensureAscii: true)
    }

    /// nil when there is no file (or it can't be read).
    public static func read(_ folder: URL) -> State? {
        guard let v = PythonJSON.read(url(folder)), case .object = v else { return nil }
        let late = (v["late"]?.arrayValue ?? []).compactMap { r -> ClosedRange<Double>? in
            guard let a = r.arrayValue, a.count == 2, let lo = a[0].doubleValue, let hi = a[1].doubleValue, lo <= hi else { return nil }
            return lo...hi
        }
        return State(pending: v["pending"]?.truthy ?? false, late: late)
    }

    /// The state once it is no longer pending, waiting up to `waitSeconds` (then taken as it is).
    public static func settled(_ folder: URL, clock: () -> Double = { ProcessInfo.processInfo.systemUptime },
                               sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> State? {
        let deadline = clock() + waitSeconds
        var state = read(folder)
        while let s = state, s.pending, clock() < deadline {
            sleep(0.5)
            state = read(folder)
        }
        return state
    }
}
