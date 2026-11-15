// `mic_muted.json` next to a call's recording: the stretches of the raw mic that were silenced after they
// were written (a mute told late: Teams' log), so what the live workers made of them must be made again, and
// whether more may still come (the capture keeps reading Teams' log after the stop). `process` waits for it to
// settle, then redoes the mic track when any stretch is listed (CallMute, MicMuteGate). `muted`: every stretch
// the mic was not kept in, written while the call is recorded too, so the meeting shows where (`app`: the call app).
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
        /// Every stretch the mic was not kept in (seconds from the track's start); the last one ends now while muted.
        public var muted: [ClosedRange<Double>]
        /// "teams" / "slack".
        public var app: String?
        /// While recording: the last stretch of `muted` goes on (it ends where it was written).
        public var open: Bool
        public init(pending: Bool, late: [ClosedRange<Double>], muted: [ClosedRange<Double>] = [], app: String? = nil,
                    open: Bool = false) {
            self.pending = pending
            self.late = late
            self.muted = muted
            self.app = app
            self.open = open
        }
    }

    public static func url(_ folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    public static func write(_ state: State, folder: URL) throws {
        func ranges(_ rs: [ClosedRange<Double>]) -> JSONValue {
            .array(rs.map { .array([.double(($0.lowerBound * 1000).rounded() / 1000), .double(($0.upperBound * 1000).rounded() / 1000)]) })
        }
        var fields: [(String, JSONValue)] = [("pending", .bool(state.pending)), ("late", ranges(state.late))]
        if !state.muted.isEmpty || state.app != nil {
            fields += [("muted", ranges(state.muted)), ("app", .str(state.app)), ("open", .bool(state.open))]
        }
        try PythonJSON.write(.object(fields), to: url(folder), indent: nil, ensureAscii: true)
    }

    /// nil when there is no file (or it can't be read).
    public static func read(_ folder: URL) -> State? {
        guard let v = PythonJSON.read(url(folder)), case .object = v else { return nil }
        func ranges(_ key: String) -> [ClosedRange<Double>] {
            (v[key]?.arrayValue ?? []).compactMap { r -> ClosedRange<Double>? in
                guard let a = r.arrayValue, a.count == 2, let lo = a[0].doubleValue, let hi = a[1].doubleValue, lo <= hi else { return nil }
                return lo...hi
            }
        }
        return State(pending: v["pending"]?.truthy ?? false, late: ranges("late"), muted: ranges("muted"), app: v["app"]?.stringValue,
                     open: v["open"]?.truthy ?? false)
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
