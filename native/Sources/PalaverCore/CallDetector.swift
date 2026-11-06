// Is Teams or Slack in a call? Answered from Core Audio's per-process audio objects (macOS 14.4+),
// as palaver/teams_detector.py does. Read-only property queries; nothing is captured and no
// permission is asked.
import CoreAudio
import Foundation

public struct AudioProcess: Equatable, Sendable {
    public var bundleId: String
    public var pid: Int32
    public var runningInput: Bool
    public var runningOutput: Bool
    public init(bundleId: String, pid: Int32 = 1, runningInput: Bool, runningOutput: Bool = false) {
        self.bundleId = bundleId
        self.pid = pid
        self.runningInput = runningInput
        self.runningOutput = runningOutput
    }
}

/// Lists the processes Core Audio knows. Throws when the list cannot be read.
public protocol ProcessLister: Sendable {
    func processes() throws -> [AudioProcess]
}

public struct CoreAudioProcessLister: ProcessLister {
    public init() {}

    struct ListError: Error, CustomStringConvertible {
        var status: OSStatus
        var description: String { "Core Audio process list failed (status \(status))" }
    }

    static let global = AudioObjectPropertyScope(0x676C6F62)  // 'glob'

    private func address(_ selector: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: Self.global, mElement: 0)
    }

    private func uint32(_ obj: AudioObjectID, _ selector: UInt32) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == 0 ? value : nil
    }

    private func string(_ obj: AudioObjectID, _ selector: UInt32) -> String {
        var addr = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
        }
        guard status == 0, let ref else { return "" }
        return ref.takeRetainedValue() as String
    }

    public func processes() throws -> [AudioProcess] {
        var addr = address(0x70727323)  // 'prs#'
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard status == 0 else { throw ListError(status: status) }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, $0.baseAddress!)
        }
        guard status == 0 else { throw ListError(status: status) }
        return ids.map { obj in
            AudioProcess(bundleId: string(obj, 0x70626964),  // 'pbid'
                         pid: Int32(truncatingIfNeeded: uint32(obj, 0x70706964) ?? 0),  // 'ppid'
                         runningInput: (uint32(obj, 0x70697269) ?? 0) != 0,  // 'piri'
                         runningOutput: (uint32(obj, 0x7069726F) ?? 0) != 0)  // 'piro'
        }
    }
}

public enum CallApp: String, Sendable, CaseIterable {
    case teams, slack
}

public let teamsBundlePrefixes = ["com.microsoft.teams"]
public let slackBundlePrefixes = ["com.tinyspeck.slackmacgap"]
/// An ignored app's hold ends once it let go this long (#7).
public let releasedSeconds: Double = 10

private func isApp(_ p: AudioProcess, _ prefixes: [String]) -> Bool {
    let id = p.bundleId.lowercased()
    return prefixes.contains { id.hasPrefix($0) }
}

/// Which app is in a call right now: teams, slack or nil. When both hold the mic, the one that
/// took it last (Teams may keep it after a hang-up while the huddle that follows is the call).
public final class CallDetector: @unchecked Sendable {
    private let lister: ProcessLister
    private let teamsOn: @Sendable () -> Bool
    private let slackOn: @Sendable () -> Bool
    private let clock: @Sendable () -> Double
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var inHuddle = false
    private var audio: String?
    private var micSince: [CallApp: Double] = [:]
    private var ignoredApps: [CallApp: Double?] = [:]
    private var failing = false
    private var last: CallApp?

    public init(lister: ProcessLister = CoreAudioProcessLister(),
                teams: @escaping @Sendable () -> Bool = { true },
                slack: @escaping @Sendable () -> Bool = { true },
                clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.lister = lister
        self.teamsOn = teams
        self.slackOn = slack
        self.clock = clock
        self.log = log
    }

    public var ignored: Set<CallApp> {
        lock.lock(); defer { lock.unlock() }
        return Set(ignoredApps.keys)
    }

    /// `app`'s hold on the microphone is no call, until it lets go.
    public func ignore(_ app: CallApp) {
        lock.lock(); defer { lock.unlock() }
        log("ignoring \(app.rawValue)'s hold on the microphone until it lets go")
        ignoredApps[app] = .some(nil)
    }

    /// For names that may not be an app ("zoom" is nothing).
    public func ignore(named name: String) {
        if let app = CallApp(rawValue: name) { ignore(app) }
    }

    public func callAsFunction() -> CallApp? { detect() }

    public func detect() -> CallApp? {
        lock.lock(); defer { lock.unlock() }
        let processes: [AudioProcess]
        do {
            processes = try lister.processes()
            if failing { log("call detection works again"); failing = false }
        } catch {
            if !failing { log("call detection failed: \(error)"); failing = true }
            return last  // keep the last state
        }
        last = evaluate(processes)
        return last
    }

    private func evaluate(_ processes: [AudioProcess]) -> CallApp? {
        logChanges(processes)
        let slackEnabled = slackOn()
        let slack = slackEnabled ? processes.filter { isApp($0, slackBundlePrefixes) } : []
        var holding = Set<CallApp>()
        if teamsOn(), processes.contains(where: { $0.runningInput && isApp($0, teamsBundlePrefixes) }) {
            holding.insert(.teams)
        }
        if slack.contains(where: { $0.runningInput }) { holding.insert(.slack) }
        let now = clock()
        for (app, since) in ignoredApps {
            if holding.contains(app) {
                ignoredApps[app] = .some(nil)
            } else if let since {
                if now - since >= releasedSeconds {
                    log("\(app.rawValue) let go of the microphone")
                    ignoredApps[app] = nil
                }
            } else {
                ignoredApps[app] = .some(now)
            }
        }
        holding.subtract(ignoredApps.keys)
        micSince = Dictionary(uniqueKeysWithValues: holding.map { ($0, micSince[$0] ?? now) })
        if holding.contains(.slack) { inHuddle = true }
        if !holding.isEmpty {
            // Last taker wins; a tie goes to Teams.
            return holding.max { a, b in
                let (sa, sb) = (micSince[a]!, micSince[b]!)
                return sa != sb ? sa < sb : (a == .slack && b == .teams)
            }
        }
        if !slackEnabled { return nil }
        if inHuddle, ignoredApps[.slack] == nil, slack.contains(where: { $0.runningOutput }) {
            return .slack  // muted: the others still play
        }
        inHuddle = false
        return nil
    }

    private func logChanges(_ processes: [AudioProcess]) {
        let text = processes
            .filter { (isApp($0, teamsBundlePrefixes) || isApp($0, slackBundlePrefixes)) && ($0.runningInput || $0.runningOutput) }
            .map { p in
                "\(p.bundleId) " + [(p.runningInput, "mic"), (p.runningOutput, "speaker")].filter { $0.0 }.map { $0.1 }.joined(separator: "+")
            }
            .sorted().joined(separator: ", ")
        let state = text.isEmpty ? "none" : text
        if state != audio {
            log("call apps' audio: \(state)")
            audio = state
        }
    }
}
