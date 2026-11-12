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

    public func processes() throws -> [AudioProcess] { try objects().map(\.process) }

    /// The processes with their Core Audio objects (CallMute listens on them).
    func objects() throws -> [(id: AudioObjectID, process: AudioProcess)] {
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
            (obj, AudioProcess(bundleId: string(obj, 0x70626964),  // 'pbid'
                         pid: Int32(truncatingIfNeeded: uint32(obj, 0x70706964) ?? 0),  // 'ppid'
                         runningInput: (uint32(obj, 0x70697269) ?? 0) != 0,  // 'piri'
                         runningOutput: (uint32(obj, 0x7069726F) ?? 0) != 0))  // 'piro'
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

func isApp(_ p: AudioProcess, _ prefixes: [String]) -> Bool {
    let id = p.bundleId.lowercased()
    return prefixes.contains { id.hasPrefix($0) }
}

/// Which app is in a call right now: teams, slack or nil. The call being recorded stays the call
/// while its app is in it, whatever another app does meanwhile (a Slack call ringing or answered
/// during a Teams call). Otherwise, when both hold the mic, the one that took it last (Teams may
/// keep it after a hang-up while the huddle that follows is the call). A recorded call whose app
/// held the mic with its speaker and now holds the mic alone has hung up: that hold is no call
/// until the app plays again or lets go of the mic.
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
    /// The apps whose call, recorded, played through the process that holds the mic (Teams'
    /// modulehost: mic+speaker), until they let go of the mic.
    private var played: Set<CallApp> = []
    private var hungUp: Set<CallApp> = []
    /// Slack's huddle UI says the user left (SlackHuddleFollower): its speaker alone is no huddle any more.
    public var huddleLeft: @Sendable () -> Bool = { false }

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

    /// Since when (host ns) `app` has held the mic without a break, as the last detection saw it.
    public func callSince(_ app: CallApp) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return micSince[app].map { Int64(($0 * 1e9).rounded()) }
    }

    /// `recording`: the app whose call is recorded now (nil: none, or a manual recording).
    public func detect(recording: CallApp? = nil) -> CallApp? {
        lock.lock(); defer { lock.unlock() }
        let processes: [AudioProcess]
        do {
            processes = try lister.processes()
            if failing { log("call detection works again"); failing = false }
        } catch {
            if !failing { log("call detection failed: \(error)"); failing = true }
            return last  // keep the last state
        }
        last = evaluate(processes, recording: recording)
        return last
    }

    private func evaluate(_ processes: [AudioProcess], recording: CallApp?) -> CallApp? {
        logChanges(processes)
        let slackEnabled = slackOn()
        let slack = slackEnabled ? processes.filter { isApp($0, slackBundlePrefixes) } : []
        let mics: [CallApp: [AudioProcess]] = [
            .teams: teamsOn() ? processes.filter { $0.runningInput && isApp($0, teamsBundlePrefixes) } : [],
            .slack: slack.filter { $0.runningInput },
        ]
        var holding = Set<CallApp>()
        for (app, held) in mics {
            if held.isEmpty { played.remove(app); hungUp.remove(app); continue }
            // A call plays through the process that holds the mic; at a hang-up its speaker goes
            // while Teams keeps the mic ~9 s (daemon.log, 2026-11-10). Mid-call it drops to mic
            // only for 1-2 s: the trigger's grace (5 s) covers that, and counts the hang-up from here.
            if held.contains(where: { $0.runningOutput }) {
                if recording == app { played.insert(app) }
                hungUp.remove(app)
            } else if played.contains(app) {
                if hungUp.insert(app).inserted { log("\(app.rawValue) holds the mic without its call's speaker: hung up, if it lasts") }
                continue
            }
            holding.insert(app)
        }
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
        if inHuddle, !holding.contains(.slack), huddleLeft() { inHuddle = false }  // left, not muted
        // Muted in a huddle: the others still play.
        let huddle = holding.contains(.slack)
            || (inHuddle && ignoredApps[.slack] == nil && slack.contains(where: { $0.runningOutput }))
        switch recording {
        case .teams? where holding.contains(.teams): return .teams
        case .slack? where huddle: return .slack
        default: break
        }
        if !holding.isEmpty {
            // Last taker wins; a tie goes to Teams.
            return holding.max { a, b in
                let (sa, sb) = (micSince[a]!, micSince[b]!)
                return sa != sb ? sa < sb : (a == .slack && b == .teams)
            }
        }
        if huddle { return .slack }
        if !slackEnabled { return nil }
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
