// Muted in the call: while the user is muted in the Teams call or Slack huddle being recorded,
// their microphone is not kept (the capture writes silence instead, PalaverCapture's MicMuteGate).
// Teams keeps the mic open while muted: its mic button says the state (Accessibility,
// TeamsMuteFollower), its SlimCore log says it late (the fallback). Slack lets go of the mic. Each
// source sets a `MuteTimeline` by the moment the change happened (host time, the clock of the
// audio's timestamps), not by when Palaver noticed it.
//
// Rules: unknown is not muted (recorded as always); a Teams event from before the call began does not
// count; a source that cannot be read says so once in session.log and leaves the recording as it is.
import CoreAudio
import Darwin
import Foundation

/// Host time in nanoseconds: the clock of the capture's PTS (CLOCK_UPTIME_RAW, mach_absolute_time),
/// and of `ProcessInfo.systemUptime`.
public func hostNanos() -> Int64 { Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) }

/// When the user was muted in the recorded call, as a sorted list of changes on the host clock.
/// Before the first change: not muted. Sources call `set` from any thread; the capture's writer
/// thread reads `mutedRanges`.
public final class MuteTimeline: @unchecked Sendable {
    public let app: CallApp
    private var _delay: Double
    /// The earliest moment a change was placed at since the capture last asked (`takeChangedFrom`).
    private var changedFrom: Int64?
    private let host: @Sendable () -> Int64
    private let wall: @Sendable () -> Date
    private let timeZone: TimeZone
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var changes: [(at: Int64, muted: Bool)] = []
    private var closed = false

    public init(app: CallApp, delay: Double, host: @escaping @Sendable () -> Int64 = hostNanos,
                wall: @escaping @Sendable () -> Date = Date.init, timeZone: TimeZone = .current,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.app = app
        _delay = delay
        self.host = host
        self.wall = wall
        self.timeZone = timeZone
        self.log = log
    }

    public var appName: String { app == .teams ? "Teams" : "Slack" }

    /// How long the capture holds the microphone before it writes it, so that a change that reaches
    /// Palaver late still cuts at its own moment. The source may change it (Teams: short while its
    /// button is read, long while only its log is).
    public var delay: Double {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }

    /// The earliest moment a change was placed at since the last call; the capture silences what it
    /// already wrote from there (a change told later than the hold).
    public func takeChangedFrom() -> Int64? {
        lock.withLock { defer { changedFrom = nil }; return changedFrom }
    }

    /// Muted (or not) from host time `at` on. A change out of order is placed in order; one that
    /// changes nothing is dropped. An unmute logs the interval it closes.
    public func set(_ muted: Bool, at: Int64) {
        var ended: (Int64, Int64)?
        lock.withLock {
            guard !closed else { return }
            let i = changes.firstIndex { $0.at > at } ?? changes.count
            let before = i > 0 ? changes[i - 1].muted : false
            guard before != muted else { return }
            changedFrom = min(changedFrom ?? at, at)
            if i < changes.count, changes[i].muted == muted {
                changes[i].at = at  // the same change, seen earlier
                return
            }
            changes.insert((at, muted), at: i)
            if !muted, i > 0, i == changes.count - 1 { ended = (changes[i - 1].at, at) }
        }
        if let (from, to) = ended { log("muted in \(appName) \(clockTime(from))–\(clockTime(to)): microphone not kept") }
    }

    /// Muted at host time `t`.
    public func muted(at t: Int64) -> Bool {
        lock.withLock { changes.last { $0.at <= t }?.muted ?? false }
    }

    public var mutedNow: Bool { muted(at: host()) }

    /// The muted stretches within [from, to), each clipped to it.
    public func mutedRanges(from: Int64, to: Int64) -> [Range<Int64>] {
        guard from < to else { return [] }
        return lock.withLock {
            var out: [Range<Int64>] = []
            var start: Int64? = (changes.last { $0.at <= from }?.muted ?? false) ? from : nil
            for c in changes where c.at > from && c.at < to {
                if c.muted, start == nil { start = c.at } else if !c.muted, let s = start { out.append(s..<c.at); start = nil }
            }
            if let s = start { out.append(s..<to) }
            return out
        }
    }

    /// The recording stopped: a stretch still open is logged as lasting to the end.
    public func close() {
        let open: Int64? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            return changes.last?.muted == true ? changes.last!.at : nil
        }
        if let open { log("muted in \(appName) \(clockTime(open)) to the end: microphone not kept") }
    }

    /// Host time → the wall clock's HH:mm:ss.
    func clockTime(_ t: Int64) -> String {
        let date = wall().addingTimeInterval(-Double(host() - t) / 1e9)
        let c = WallTime.calendar(timeZone, at: date).dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour!, c.minute!, c.second!)
    }
}

/// A source of mute changes for one recording; started with the capture, stopped after it.
public protocol CallMuteSource: AnyObject {
    func start()
    /// Reads what is new at once (before the recording's last audio is written).
    func refresh()
    func stop()
    /// Its changes come late (Teams' log): the stop keeps following it for the timeline's hold.
    var tellsLate: Bool { get }
}

extension CallMuteSource {
    public var tellsLate: Bool { false }
}

// MARK: - Teams: its SlimCore log

/// Lines of new Teams' `MSTeamsNM_SlimCore_<date>.log` that say the microphone was muted or unmuted.
public enum TeamsMuteLog {
    public struct Event: Equatable, Sendable {
        /// The line's digits read as UTC: what new Teams writes, whatever offset it appends
        /// (`19:13:00+01:00` was 20:13 CET; live test 2026-11-11).
        public var time: Date
        /// The line's time read as it states it, offset included.
        public var stated: Date
        public var muted: Bool
        public init(time: Date, stated: Date? = nil, muted: Bool) {
            self.time = time; self.stated = stated ?? time; self.muted = muted
        }

        /// When it happened: the reading that is not in the future, the later one if both are not
        /// (a Teams that writes its offset right makes the UTC reading lie ahead).
        public func moment(now: Date) -> Date {
            let past = [time, stated].filter { $0 <= now.addingTimeInterval(60) }
            return past.max() ?? min(time, stated)
        }
    }

    public enum Line: Equatable, Sendable {
        case event(Event)
        /// A mute line whose time or value is not in the shape known: Teams changed its log.
        case unreadable
    }

    /// Each marker and the words after it that mean muted / unmuted. Several lines may tell one
    /// change; the timeline keeps the first.
    public static let markers: [(marker: String, muted: [String: Bool])] = [
        ("AirPodsService: Input mute event received: ", ["mute": true, "unmute": false]),
        ("InputMuteStateChangeNotification received with value: ", ["true": true, "false": false]),
    ]

    /// Where new Teams writes its logs.
    public static func directory(home: URL) -> URL {
        home.appendingPathComponent(
            "Library/Group Containers/UBF8T346G9.com.microsoft.teams/Library/Application Support/Logs", isDirectory: true)
    }

    public static let filePrefix = "MSTeamsNM_SlimCore_"

    /// nil: no mute line. A line starts with its time (`2026-11-11T11:13:36.557903+01:00`).
    public static func parse<S: StringProtocol>(_ line: S) -> Line? {
        for (marker, values) in markers {
            guard let r = line.range(of: marker) else { continue }
            let word = line[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let stamp = String(line.prefix { !$0.isWhitespace })
            guard let muted = values[word], let stated = WallTime.parse(stamp),
                  let utc = WallTime.parse(String(stamp.prefix(while: { $0 != "+" && $0 != "Z" })).replacingOccurrences(
                    of: #"-\d\d:\d\d$"#, with: "", options: .regularExpression), TimeZone(secondsFromGMT: 0)!)
            else { return .unreadable }
            return .event(Event(time: utc, stated: stated, muted: muted))
        }
        return nil
    }

    /// The log Teams writes now: the newest by name (its date), then by modification time.
    public static func current(in dir: URL, fm: FileManager = .default) throws -> URL? {
        let all: [String] = try fm.contentsOfDirectory(atPath: dir.path)
        let names: [String] = all.filter { (n: String) -> Bool in n.hasPrefix(filePrefix) && n.hasSuffix(".log") }
        func mtime(_ n: String) -> Date {
            let attributes = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(n).path)
            return (attributes?[.modificationDate] as? Date) ?? .distantPast
        }
        let dated: [(name: String, time: Date)] = names.map { (n: String) -> (name: String, time: Date) in (n, mtime(n)) }
        let newest = dated.max { (a, b) -> Bool in a.name != b.name ? a.name < b.name : a.time < b.time }
        return newest.map { dir.appendingPathComponent($0.name) }
    }
}

/// Follows Teams' log during a Teams recording and sets the timeline by each line's own time.
public final class TeamsMuteWatcher: CallMuteSource, @unchecked Sendable {
    /// An event this much before the call's start still counts: the detector notices the mic up to
    /// a tick (1 s) late, and joining muted may be logged as the mic opens.
    public static let callStartSlack = 2.0
    /// What is read of the log at the start, from its end: the call's earlier changes are in it.
    public static let tailBytes = 4 << 20
    public static let pollSeconds = 0.2
    /// How often the folder is looked at for a newer log (Teams restarted).
    public static let rotationSeconds = 2.0

    private let directory: URL
    private let timeline: MuteTimeline
    private let callStart: Int64
    private let host: @Sendable () -> Int64
    private let wall: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var file: URL?
    private var offset: UInt64 = 0
    private var partial = Data()
    /// Reading starts mid-file: its first line is cut.
    private var skipLine = false
    private var lastRotationCheck: Int64?
    private var toldUnreadable = false
    private var toldFormat = false
    private var timer: DispatchSourceTimer?
    private let poll: Double?

    /// Where each change goes instead of the timeline (TeamsMuteFollower decides): (muted, at).
    private let sink: (@Sendable (Bool, Int64) -> Void)?

    /// `callStart`: when Teams took the mic for this call (host ns). `poll`: nil reads only on `refresh` (tests).
    public init(directory: URL, timeline: MuteTimeline, callStart: Int64,
                host: @escaping @Sendable () -> Int64 = hostNanos, wall: @escaping @Sendable () -> Date = Date.init,
                poll: Double? = TeamsMuteWatcher.pollSeconds, sink: (@Sendable (Bool, Int64) -> Void)? = nil,
                log: @escaping @Sendable (String) -> Void) {
        self.poll = poll
        self.sink = sink
        self.directory = directory
        self.timeline = timeline
        self.callStart = callStart
        self.host = host
        self.wall = wall
        self.log = log
    }

    /// The first read is on the watcher's own queue: macOS may ask the user whether Palaver may read
    /// another app's data, and the recording does not wait for that answer.
    public func start() {
        startedAt = host()
        guard let poll else { lock.withLock { open(tail: true) }; return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "palaver.teams-mute"))
        t.schedule(deadline: .now(), repeating: poll, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private var opened = false
    /// When the recording began: a change before it is no audio of ours.
    private var startedAt = Int64.max

    private func tick() {
        lock.withLock { opened ? follow() : open(tail: true) }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Reads what is new; skipped while a read is under way (never waits on one).
    public func refresh() {
        guard lock.try() else { return }
        defer { lock.unlock() }
        if opened { follow() }
    }

    // MARK: - private (lock held)

    /// What is new in the log, or a newer log (Teams restarted), looked for every `rotationSeconds`.
    private func follow() {
        let now = host()
        if file == nil || lastRotationCheck.map({ Double(now - $0) / 1e9 >= Self.rotationSeconds }) ?? true {
            lastRotationCheck = now
            if let newer = try? TeamsMuteLog.current(in: directory), newer != file {
                if file != nil { log("Teams started a new log: following \(newer.lastPathComponent)") }
                open(tail: file == nil)
                return
            }
        }
        read()
    }

    /// The current log; `tail`: from its last `tailBytes` (the call so far), else whole (a new log).
    private func open(tail: Bool) {
        opened = true
        lastRotationCheck = host()
        let found: URL?
        do { found = try TeamsMuteLog.current(in: directory) } catch {
            unreadable("\(error.localizedDescription)")
            return
        }
        guard let found else { unreadable("no Teams log in its folder"); return }
        file = found
        partial = Data()
        offset = 0
        if tail, let size = size(found), size > UInt64(Self.tailBytes) {
            offset = size - UInt64(Self.tailBytes)
            skipLine = true
        }
        read()
    }

    private func size(_ url: URL) -> UInt64? {
        var st = stat()
        return stat(url.path, &st) == 0 ? UInt64(st.st_size) : nil
    }

    private func read() {
        guard let file else { return }
        let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { unreadable(String(cString: strerror(errno))); return }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return }
        let size = UInt64(st.st_size)
        if size < offset { offset = 0; partial = Data() }  // cut back: read it again
        guard size > offset else { return }
        let count = Int(min(size - offset, UInt64(Self.tailBytes)))
        var buffer = [UInt8](repeating: 0, count: count)
        let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        guard n > 0 else { if n < 0 { unreadable(String(cString: strerror(errno))) }; return }
        offset += UInt64(n)
        partial.append(contentsOf: buffer[0..<n])
        guard let end = partial.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = partial[partial.startIndex...end]
        partial = Data(partial[partial.index(after: end)...])
        var lines = String(decoding: complete, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        if skipLine { skipLine = false; if !lines.isEmpty { lines.removeFirst() } }
        for line in lines { take(line) }
    }

    private func take(_ line: Substring) {
        switch TeamsMuteLog.parse(line) {
        case nil: return
        case .unreadable?:
            if !toldFormat {
                toldFormat = true
                log("⚠ Teams' log has a mute line Palaver can't read (did Teams change it?); "
                    + "your microphone is recorded while muted in Teams")
            }
        case .event(let e)?:
            // Teams' times are in microseconds; a Date holds them only to about 0.1 µs.
            let now = wall()
            let at = host() - Int64((now.timeIntervalSince(e.moment(now: now)) * 1e6).rounded()) * 1000
            guard at >= callStart - Int64(Self.callStartSlack * 1e9) else { return }  // an earlier call's
            if let sink { sink(e.muted, at); return }
            let late = Double(host() - at) / 1e9
            if late > timeline.delay, at >= startedAt, timeline.muted(at: at) != e.muted {
                // A mute: what was written meanwhile is silenced afterwards (MicMuteGate); an unmute: left silent.
                log("Teams logged a\(e.muted ? " mute" : "n unmute") \(String(format: "%.1f", late)) s late"
                    + (e.muted ? "" : ": \(String(format: "%.1f", late - timeline.delay)) s of microphone after it stay silent"))
            }
            timeline.set(e.muted, at: at)
        }
    }

    private func unreadable(_ why: String) {
        guard !toldUnreadable else { return }
        toldUnreadable = true
        log("⚠ can't read Teams' log (\(why)); your microphone is recorded while muted in Teams")
    }
}

// MARK: - Slack: the mic is let go

/// Tells when Core Audio's processes change their audio (the mic taken or let go), at once.
public protocol AudioProcessEvents: AnyObject {
    func start(_ changed: @escaping @Sendable () -> Void) throws
    func stop()
}

/// While a Slack huddle is the recorded call, Slack holding no mic is the user muted.
public final class SlackMuteWatcher: CallMuteSource, @unchecked Sendable {
    /// A fallback look in case a change was not told.
    public static let pollSeconds = 1.0

    private let lister: ProcessLister
    private let events: AudioProcessEvents?
    private let timeline: MuteTimeline
    private let host: @Sendable () -> Int64
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var failing = false
    private var timer: DispatchSourceTimer?
    private let poll: Double?
    private var held: Bool?
    /// Where each look goes instead of the timeline (SlackHuddleFollower decides): (muted, at).
    private let sink: (@Sendable (Bool, Int64) -> Void)?

    /// `poll`: nil looks only when told or refreshed (tests).
    public init(lister: ProcessLister, events: AudioProcessEvents?, timeline: MuteTimeline,
                host: @escaping @Sendable () -> Int64 = hostNanos, poll: Double? = SlackMuteWatcher.pollSeconds,
                sink: (@Sendable (Bool, Int64) -> Void)? = nil, log: @escaping @Sendable (String) -> Void) {
        self.poll = poll
        self.sink = sink
        self.lister = lister
        self.events = events
        self.timeline = timeline
        self.host = host
        self.log = log
    }

    public func start() {
        check()
        do { try events?.start { [weak self] in self?.check() } } catch {
            log("Slack's mute is followed once a second only: \(error)")
        }
        guard let poll else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "palaver.slack-mute"))
        t.schedule(deadline: .now() + poll, repeating: poll, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    public func refresh() { check() }

    public func stop() {
        events?.stop()
        timer?.cancel()
        timer = nil
    }

    /// Whether Slack held the mic at the last look; nil when it couldn't be read.
    public var micHeld: Bool? { lock.withLock { held } }

    /// One look: muted when none of Slack's processes holds the mic.
    public func check() {
        let (muted, at) = lock.withLock { () -> (Bool, Int64) in
            let at = host()
            do {
                let held = try lister.processes().contains { $0.runningInput && isApp($0, slackBundlePrefixes) }
                if failing { failing = false; log("Slack's mute state can be read again") }
                self.held = held
                return (!held, at)
            } catch {
                if !failing { failing = true; log("⚠ can't read whether Slack holds the mic (\(error)); recording as if unmuted") }
                self.held = nil
                return (false, at)
            }
        }
        if let sink { sink(muted, at) } else { timeline.set(muted, at: at) }
    }
}

/// Core Audio's property listeners: the process list ('prs#') and each Slack process's "running
/// input" ('piri'). Read-only; nothing is captured.
public final class CoreAudioProcessEvents: AudioProcessEvents, @unchecked Sendable {
    private let prefixes: [String]
    /// Where Core Audio calls the listeners.
    private let queue = DispatchQueue(label: "palaver.audio-process-events")
    /// Where listeners are added and removed: never from inside a listener, never waiting on `queue`.
    private let control = DispatchQueue(label: "palaver.audio-process-listeners")
    private var changed: (@Sendable () -> Void)?
    private var listBlock: AudioObjectPropertyListenerBlock?
    private var watched: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    public init(bundlePrefixes: [String]) { prefixes = bundlePrefixes }

    private static func address(_ selector: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: CoreAudioProcessLister.global, mElement: 0)
    }

    public func start(_ changed: @escaping @Sendable () -> Void) throws {
        try control.sync {
            self.changed = changed
            var addr = Self.address(0x70727323)  // 'prs#'
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.control.async { self?.rewatch() }
                changed()
            }
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
            guard status == 0 else { throw CoreAudioProcessLister.ListError(status: status) }
            listBlock = block
            rewatch()
        }
    }

    public func stop() {
        control.sync {
            if let block = listBlock {
                var addr = Self.address(0x70727323)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
            }
            listBlock = nil
            for (obj, block) in watched {
                var addr = Self.address(0x70697269)
                AudioObjectRemovePropertyListenerBlock(obj, &addr, queue, block)
            }
            watched = [:]
            changed = nil
        }
    }

    /// On `control`: a listener on each of the apps' process objects, none on gone ones.
    private func rewatch() {
        guard let changed, let objects = try? CoreAudioProcessLister().objects() else { return }
        let wanted = Set(objects.filter { isApp($0.process, prefixes) }.map(\.id))
        for (obj, block) in watched where !wanted.contains(obj) {
            var addr = Self.address(0x70697269)
            AudioObjectRemovePropertyListenerBlock(obj, &addr, queue, block)
            watched[obj] = nil
        }
        for obj in wanted where watched[obj] == nil {
            var addr = Self.address(0x70697269)  // 'piri'
            let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
            if AudioObjectAddPropertyListenerBlock(obj, &addr, queue, block) == 0 { watched[obj] = block }
        }
    }
}

// MARK: - one recording's mute

/// The timeline and its source for one recording of a call; nil for anything else.
public enum CallMute {
    /// How long the mic is held before it is written at first: Teams' follower shortens it once it
    /// reads the mic button (TeamsMuteFollower). Slack's: a look every 0.5 s at its mic button (a mute dated to
    /// the look before), or its mic release, told at once.
    public static func delay(_ app: CallApp) -> Double { app == .teams ? TeamsMuteFollower.logDelay : 1.0 }

    /// `huddle`: where a Slack recording's follower says the user left the huddle.
    public static func make(app: CallApp, callStart: Int64?, home: URL, huddle: SlackHuddleState = SlackHuddleState(),
                            lister: ProcessLister = CoreAudioProcessLister(),
                            log: @escaping @Sendable (String) -> Void) -> (MuteTimeline, CallMuteSource) {
        let timeline = MuteTimeline(app: app, delay: delay(app), log: log)
        switch app {
        case .teams:
            let start = callStart ?? hostNanos()
            return (timeline, TeamsMuteFollower(
                button: AXTeamsMuteButton(), timeline: timeline,
                watcher: { sink in
                    TeamsMuteWatcher(directory: TeamsMuteLog.directory(home: home), timeline: timeline, callStart: start,
                                     sink: sink, log: log)
                }, log: log))
        case .slack:
            return (timeline, SlackHuddleFollower(
                reader: AXSlackHuddle(), timeline: timeline, state: huddle,
                audio: { sink in
                    SlackMuteWatcher(lister: lister, events: CoreAudioProcessEvents(bundlePrefixes: slackBundlePrefixes),
                                     timeline: timeline, sink: sink, log: log)
                }, log: log))
        }
    }
}
