// What Palaver keeps on this Mac and the space it takes (palaver/storage.py, #9): the meetings, their audio and the
// models. A transcribed meeting's audio can go, for one meeting or on its own after some days; its transcript and notes
// stay. Deleting never follows a symlink: an audio file that is a link loses the link, a model folder that is a link is
// left alone, and links inside a model folder are removed, never what they point to.
import Foundation
import os
import PalaverCore

/// storage.py's ValueError (the window's 400) or, where Python's arithmetic fails on a broken marker, its TypeError.
public struct StorageError: Error, CustomStringConvertible {
    public enum Kind: Sendable { case value, type }
    public let kind: Kind
    public let description: String
}

public enum Storage {
    /// The tracks a meeting's audio is (RecordingPaths' mic_raw_wav, mic_wav, system_wav).
    public static let AUDIO = ["mic_raw_wav", "mic_wav", "system_wav"]
    /// How long a transcribed meeting keeps its audio; 0: always.
    public static let DAYS = [0, 7, 14, 30, 90]
    /// In settings.json.
    public static let KEY = "audio_days"
    public static let DELETED = "audio_deleted.json"
    public static let CLEANUP_EVERY = 3600.0
    /// The live diarizer's copy of the system track, gone when its worker ends.
    public static let LIVE_SCRATCH = ".live-diarize.wav"

    private static let log = Logger(subsystem: "com.kenodressel.palaver", category: "storage")

    /// A line for the storage log (Console.app, com.kenodressel.palaver/storage).
    public static func logError(_ message: String) { log.error("\(message, privacy: .public)") }

    private static func tracks(_ p: RecordingPaths) -> [URL] { [p.micRawWav, p.micWav, p.systemWav] }

    /// The meeting's audio files that are there (links followed), the live scratch last.
    public static func audioFiles(_ paths: RecordingPaths) -> [URL] {
        let files = tracks(paths).filter { Undo.exists($0.path) }
        let scratch = paths.folder.appendingPathComponent(LIVE_SCRATCH)
        return Undo.exists(scratch.path) ? files + [scratch] : files
    }

    public static func audioBytes(_ paths: RecordingPaths) -> Int { audioFiles(paths).reduce(0) { $0 + size($1.path) } }

    /// `{"at", "bytes"}` once the meeting's audio was deleted; nil before (or when the file is no object).
    public static func deleted(_ paths: RecordingPaths) -> JSONValue? {
        guard let v = PythonJSON.read(paths.folder.appendingPathComponent(DELETED)), case .object = v else { return nil }
        return v
    }

    /// Only a finished, transcribed meeting: never one still being written.
    public static func canDrop(_ paths: RecordingPaths) -> Bool {
        let parts = tracks(paths).contains { Undo.exists($0.path + ".part") }
        return Undo.exists(paths.transcriptJson.path) && !parts && !audioFiles(paths).isEmpty
    }

    /// Delete the meeting's audio; the bytes freed. A ValueError when it has no transcript yet (or no audio). The marker
    /// adds up what every delete freed; `at` is now's ISO time to the second.
    public static func dropAudio(_ paths: RecordingPaths, now: Date = Date(), timeZone: TimeZone = .current) throws -> Int {
        guard canDrop(paths) else {
            throw StorageError(kind: .value, description: "only a transcribed meeting's audio can be deleted")
        }
        var freed = 0
        for f in audioFiles(paths) {
            let n = size(f.path)
            if unlink(f.path) != 0 && errno != ENOENT {  // a link loses the link, never its target
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            freed += n
        }
        let total: JSONValue
        switch deleted(paths)?["bytes"] ?? .int(0) {
        case .int(let before): total = .int(before + freed)
        case .bool(let before): total = .int((before ? 1 : 0) + freed)
        case .double(let before): total = .double(before + Double(freed))
        case .string:
            throw StorageError(kind: .type, description: #"can only concatenate str (not "int") to str"#)
        case .array:
            throw StorageError(kind: .type, description: #"can only concatenate list (not "int") to list"#)
        case .null:
            throw StorageError(kind: .type, description: "unsupported operand type(s) for +: 'NoneType' and 'int'")
        case .object:
            throw StorageError(kind: .type, description: "unsupported operand type(s) for +: 'dict' and 'int'")
        }
        let marker = JSONValue.object([("at", .string(Py.isoNow(timespec: "seconds", now: now, timeZone: timeZone))),
                                       ("bytes", total)])
        try PythonJSON.write(marker, to: paths.folder.appendingPathComponent(DELETED), indent: 2, ensureAscii: true)
        return freed
    }

    /// The days from settings.json: an int (not a bool) of `DAYS`, else 0.
    public static func audioDays(stores: StorePaths = .current()) -> Int {
        if case .int(let d)? = SettingsFile.readRaw(stores: stores)[KEY], DAYS.contains(d) { return d }
        return 0
    }

    /// Save the days: one of `DAYS` (Python's `in`: 7.0 is one and is saved as 7.0, which `audioDays` then reads as 0).
    public static func setAudioDays(_ days: JSONValue, stores: StorePaths = .current()) throws {
        let ok: Bool
        switch days {
        case .int(let d): ok = DAYS.contains(d)
        case .double(let d): ok = DAYS.contains { Double($0) == d }
        default: ok = false
        }
        guard ok else {
            throw StorageError(kind: .value, description: "\(KEY) must be one of \(DAYS.map(String.init).joined(separator: ", "))")
        }
        try SettingsFile.update([(KEY, days)], stores: stores)
    }

    /// The recording folders of `outputDir` (folders, links followed), by name; none when it can't be read.
    public static func meetings(_ outputDir: URL) -> [RecordingPaths] {
        let root = Undo.pyPath(outputDir.path)
        guard let names = try? Undo.listdir(root) else { return [] }
        return Py.stableSorted(names, by: Py.less)
            .filter { Undo.isDir(root + "/" + $0) && RecordingPaths.isRecordingFolderName($0) }
            .map { RecordingPaths(URL(fileURLWithPath: root + "/" + $0, isDirectory: true)) }
    }

    /// The meetings started more than `days` ago (`now` as a local time in `timeZone`) whose audio can go.
    public static func olderThan(_ outputDir: URL, days: Int, now: Date = Date(), timeZone: TimeZone = .current) -> [RecordingPaths] {
        let cutoff = naive(now, timeZone) - Double(days) * 86_400
        return meetings(outputDir).filter { started($0) < cutoff && canDrop($0) }
    }

    /// Delete the audio of the meetings older than `days` (none for 0): (meetings, bytes). A meeting that fails with a
    /// ValueError or an OSError is skipped; Python's TypeError is not.
    public static func dropOldAudio(_ outputDir: URL, days: Int, now: Date = Date(),
                                    timeZone: TimeZone = .current) throws -> (meetings: Int, bytes: Int) {
        var count = 0, freed = 0
        for p in days > 0 ? olderThan(outputDir, days: days, now: now, timeZone: timeZone) : [] {
            do {
                freed += try dropAudio(p, now: now, timeZone: timeZone)
                count += 1
            } catch let e as StorageError where e.kind == .type {
                throw e
            } catch {
                continue
            }
        }
        return (count, freed)
    }

    /// The Settings page's Storage section.
    public static func summary(outputDir: URL, config: Config = Config(), now: Date = Date(), timeZone: TimeZone = .current,
                               stores: StorePaths = .current()) -> JSONValue {
        var total = 0, audio = 0, withAudio = 0, count = 0
        let ages = DAYS.filter { $0 != 0 }
        var olds = ages.map { _ in (0, 0) }
        let current = naive(now, timeZone)
        for p in meetings(outputDir) {
            count += 1
            total += treeSize(p.folder.path)
            let mine = audioBytes(p)
            audio += mine
            withAudio += mine != 0 ? 1 : 0
            if mine != 0 && canDrop(p) {
                let age = current - started(p)
                for (i, d) in ages.enumerated() where age > Double(d) * 86_400 {
                    olds[i].0 += 1
                    olds[i].1 += mine
                }
            }
        }
        return .object([
            ("folder", .string(Undo.pyPath(outputDir.path))),
            ("meetings", .int(count)),
            ("bytes", .int(total)),
            ("audio_bytes", .int(audio)),
            ("audio_meetings", .int(withAudio)),
            ("audio_days", .int(audioDays(stores: stores))),
            ("days", .array(DAYS.map { .int($0) })),
            ("older", .object(zip(ages, olds).map { d, o in (String(d), .object([("meetings", .int(o.0)), ("bytes", .int(o.1))])) })),
            ("models", .array(models(config: config, stores: stores))),
        ])
    }

    // MARK: - Models

    /// A folder of Palaver's own models that holds `m` (or an old copy of it).
    private static func localFolder(_ m: ModelInfo, _ stores: StorePaths) -> String? {
        m.localFolder.isEmpty ? nil : Undo.pyPath(stores.modelsDir.path) + "/" + m.localFolder
    }

    /// The downloaded models, their size, and whether one can be deleted: only a notes model Palaver doesn't use now, or
    /// one no longer offered (the old Parakeet MLX and Whisper caches and the pyannote copy, once a meeting went through
    /// the engine), never one config.toml's transcriber still uses.
    public static func models(config: Config = Config(), stores: StorePaths = .current()) -> [JSONValue] {
        let local = ModelChoice.localModel(config: config, stores: stores)
        let proven = Undo.exists(stores.engineProvenMarker.path)
        var out: [JSONValue] = []
        for m in ModelCatalog.models + ModelCatalog.retired {
            let repo = ModelCatalog.repoFor(m)
            let size = ModelCatalog.cachedBytes(repo, stores: stores) + (localFolder(m, stores).map(treeSize) ?? 0)
            if size == 0 { continue }
            var spare = (ModelCatalog.notesModels.values.contains { Py.same($0, m.id) } || ModelCatalog.isRetired(m.id))
                && !Py.same(repo, local)
            if m.manual { spare = spare && proven }  // only once the models that replaced it did a meeting's work
            if !m.transcriber.isEmpty && Py.same(config.transcriber, m.transcriber) { spare = false }  // config.toml still uses it
            out.append(.object([("id", .string(m.id)), ("label", .string(m.label)), ("purpose", .string(m.purpose)),
                                ("bytes", .int(size)), ("deletable", .bool(spare))]))
        }
        return out
    }

    /// Delete a model `models` says can go: its Hugging Face cache folder and its folder of Palaver's own models; the
    /// bytes it listed. A ValueError for any other id.
    public static func deleteModel(_ id: String, config: Config = Config(), stores: StorePaths = .current()) throws -> Int {
        guard let entry = models(config: config, stores: stores).first(where: { $0["id"]?.stringValue.map { Py.same($0, id) } == true }),
              entry["deletable"] == .bool(true), let model = ModelCatalog.model(id) else {
            throw StorageError(kind: .value, description: "only a notes model Palaver doesn't use can be deleted")
        }
        removeTree(Undo.pyPath(ModelCatalog.cacheDir(model.repo, stores: stores).path))
        if let folder = localFolder(model, stores) { removeTree(folder) }
        if case .int(let n)? = entry["bytes"] { return n }
        return 0
    }

    /// At start: delete the models no longer offered (Qwen3 30B A3B), unless config.toml still names one; the bytes
    /// freed. The manual ones (Parakeet MLX, pyannote, Whisper) wait for the user.
    @discardableResult
    public static func dropRetired(config: Config = Config(), stores: StorePaths = .current()) -> Int {
        var freed = 0
        let local = ModelChoice.localModel(config: config, stores: stores)
        for m in ModelCatalog.retired {
            let folder = Undo.pyPath(ModelCatalog.cacheDir(m.repo, stores: stores).path)
            if m.manual || Py.same(m.repo, local) || !Undo.exists(folder) { continue }
            let size = ModelCatalog.cachedBytes(m.repo, stores: stores)
            removeTree(folder)
            log.info("deleted \(m.label, privacy: .public), no longer offered: \(String(format: "%.1f", Double(size) / 1e9), privacy: .public) GB free again")
            freed += size
        }
        return freed
    }

    // MARK: - Files

    /// The meeting's start from its folder name, as a naive local time in seconds (`datetime.strptime(stamp,
    /// "%Y-%m-%dT%H-%M-%S")`); infinity (`datetime.max`) when that fails.
    static func started(_ p: RecordingPaths) -> Double {
        guard let stamp = RecordingPaths.recordingFolderTimestamp(p.id) else { return .infinity }
        let u = Array(stamp.unicodeScalars)  // \d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}, any script's digits
        func digit(_ i: Int) -> Int? {
            guard Py.isDecimal(u[i]), let v = u[i].properties.numericValue else { return nil }
            return Int(v)
        }
        func ascii(_ i: Int) -> Int? { u[i].isASCII ? digit(i) : nil }
        // strptime's patterns: %m 1[0-2]|0[1-9]; %d 3[01]|[12]\d|0[1-9]; %H 2[0-3]|[0-1]\d; %M [0-5]\d; %S 6[0-1]|[0-5]\d.
        func two(_ i: Int, first: ClosedRange<Int>, second: (Int) -> Int?) -> Int? {
            guard let a = ascii(i), first.contains(a), let b = second(a) else { return nil }
            return a * 10 + b
        }
        guard let y0 = digit(0), let y1 = digit(1), let y2 = digit(2), let y3 = digit(3),
              let month = two(5, first: 0...1, second: { a in a == 1 ? ascii(6).flatMap { (0...2).contains($0) ? $0 : nil }
                                                                      : ascii(6).flatMap { (1...9).contains($0) ? $0 : nil } }),
              let day = two(8, first: 0...3, second: { a in
                  switch a {
                  case 3: return ascii(9).flatMap { (0...1).contains($0) ? $0 : nil }
                  case 1, 2: return digit(9)
                  default: return ascii(9).flatMap { (1...9).contains($0) ? $0 : nil }
                  }
              }),
              let hour = two(11, first: 0...2, second: { a in a == 2 ? ascii(12).flatMap { (0...3).contains($0) ? $0 : nil } : digit(12) }),
              let minute = two(14, first: 0...5, second: { _ in digit(15) }),
              let second = two(17, first: 0...6, second: { a in a == 6 ? ascii(18).flatMap { (0...1).contains($0) ? $0 : nil } : digit(18) }),
              second < 60,  // strptime reads 60 and 61, datetime refuses them
              let date = PyDate(y0 * 1000 + y1 * 100 + y2 * 10 + y3, month, day) else { return .infinity }
        return Double(date.ordinal) * 86_400 + Double(hour * 3600 + minute * 60 + second)
    }

    /// `now` as Python's naive `datetime.now()` (the local wall time in `timeZone`), in seconds.
    static func naive(_ now: Date, _ timeZone: TimeZone) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        guard let date = PyDate(c.year!, c.month!, c.day!) else { return 0 }
        let whole = now.timeIntervalSince1970.rounded(.down)
        return Double(date.ordinal) * 86_400 + Double(c.hour! * 3600 + c.minute! * 60 + c.second!)
            + (now.timeIntervalSince1970 - whole)
    }

    /// `Path.stat().st_size`, links followed; 0 when it can't be read.
    static func size(_ path: String) -> Int { Undo.statOf(path).map { Int($0.st_size) } ?? 0 }

    /// The files under `folder` (`rglob("*")`, files with links followed, linked folders not entered).
    static func treeSize(_ folder: String) -> Int {
        var total = 0
        ModelCatalog.walk(folder) { path, _ in
            if let st = Undo.statOf(path), ModelCatalog.isRegular(st) { total += Int(st.st_size) }
        }
        return total
    }

    /// `shutil.rmtree(path, ignore_errors=True)`: nothing when `path` is a link or no folder; inside, every link and file
    /// is unlinked and every folder emptied and removed, by file descriptor (`openat` with `O_NOFOLLOW`), so a link is
    /// never followed out of the folder.
    static func removeTree(_ path: String) {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        removeContents(fd)
        rmdir(path)
    }

    /// Empties the folder open at `fd` and closes it.
    private static func removeContents(_ fd: Int32) {
        guard let dir = fdopendir(fd) else { close(fd); return }
        defer { closedir(dir) }
        var names: [[CChar]] = []
        while let e = readdir(dir) {
            let length = Int(e.pointee.d_namlen)
            let name = withUnsafeBytes(of: e.pointee.d_name) { Array($0.prefix(length)).map { CChar(bitPattern: $0) } }
            if name != [46] && name != [46, 46] { names.append(name + [0]) }
        }
        for name in names {
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if st.st_mode & S_IFMT == S_IFDIR {
                let sub = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard sub >= 0 else { continue }
                removeContents(sub)
                unlinkat(fd, name, AT_REMOVEDIR)
            } else {
                unlinkat(fd, name, 0)
            }
        }
    }
}

/// In the app: once an hour, in the background, delete the audio older than Settings say (storage.Cleanup).
public final class StorageCleanup: @unchecked Sendable {
    private let outputDir: URL
    private let every: Double
    private let days: () -> Int
    private let clock: () -> Double
    private let drop: (URL, Int) throws -> Void
    private let log: (String) -> Void
    private let lock = NSLock()
    private var last: Double?
    private var running: DispatchGroup?

    /// `drop` runs on its own thread; by default `Storage.dropOldAudio`. A failure only skips a turn, said in `log`.
    public init(outputDir: URL, every: Double = Storage.CLEANUP_EVERY, days: @escaping () -> Int = { Storage.audioDays() },
                clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
                drop: @escaping (URL, Int) throws -> Void = { root, d in _ = try Storage.dropOldAudio(root, days: d) },
                log: @escaping (String) -> Void = Storage.logError) {
        self.outputDir = outputDir
        self.every = every
        self.days = days
        self.clock = clock
        self.drop = drop
        self.log = log
    }

    public func tick() {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        if let last, now - last < every { return }
        if let running, running.wait(timeout: .now()) == .timedOut { return }
        last = now
        let d = days()
        guard d != 0 else { return }
        let group = DispatchGroup()
        group.enter()
        running = group
        let root = outputDir, drop = drop, log = log
        let thread = Thread {
            do { try drop(root, d) } catch { log("deleting the audio older than \(d) days failed: \(error)") }
            group.leave()
        }
        thread.name = "audio-cleanup"
        thread.start()
    }

    /// Waits for a cleanup that is running.
    public func wait() {
        lock.lock()
        let group = running
        lock.unlock()
        group?.wait()
    }
}
