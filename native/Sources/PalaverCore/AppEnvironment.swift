// Where the app runs and what it starts with (the global options, tools/app_bundle.py's layout): the
// bundle or a development build, its version, the programs it starts, and the leftovers of an earlier
// run it sweeps. Pure enough to test without starting anything.
import Darwin
import Foundation

/// The app's own options, forwarded to every worker (`--config`, `--dictionary`, `--no-notify`).
public struct AppOptions: Equatable, Sendable {
    public var config: String?
    public var dictionary: String?
    public var noNotify = false

    public init(config: String? = nil, dictionary: String? = nil, noNotify: Bool = false) {
        self.config = config; self.dictionary = dictionary; self.noNotify = noNotify
    }

    /// `Palaver [--config FILE] [--dictionary FILE] [--no-notify]`; anything else (macOS may add
    /// `-psn_…` or `-NSDocumentRevisionsDebugMode YES`) is ignored.
    public static func parse(_ args: [String]) -> AppOptions {
        var o = AppOptions()
        var i = 0
        while i < args.count {
            let a = args[i]
            func value() -> String? { i + 1 < args.count ? args[i + 1] : nil }
            if a == "--config", let v = value() { o.config = v; i += 2; continue }
            if a.hasPrefix("--config=") { o.config = String(a.dropFirst("--config=".count)) }
            if a == "--dictionary", let v = value() { o.dictionary = v; i += 2; continue }
            if a.hasPrefix("--dictionary=") { o.dictionary = String(a.dropFirst("--dictionary=".count)) }
            if a == "--no-notify" { o.noNotify = true }
            i += 1
        }
        return o
    }
}

/// The app's place: inside Palaver.app (a release) or a development build in a checkout.
public struct AppLocation: Equatable, Sendable {
    /// Palaver.app, when the executable is its `Contents/MacOS/<name>`.
    public let bundle: URL?
    /// The checkout (the folder with `VERSION` and `native/Package.swift`) a development build lives in.
    public let checkout: URL?

    /// The bundle is found from its `Contents/MacOS/<name>` and from `Contents/Resources/bin/palaver` (the `palaver`
    /// command, which `~/.local/bin/palaver` links to).
    public init(executable: URL, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        let exe = executable.resolvingSymlinksInPath().standardizedFileURL
        let macos = exe.deletingLastPathComponent()
        let contents = macos.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        if macos.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", app.pathExtension == "app" {
            bundle = app
            checkout = nil
            return
        }
        // Contents/Resources/bin/<name>: `macos` is bin, `contents` Resources, `app` Contents.
        let binApp = app.deletingLastPathComponent()
        if macos.lastPathComponent == "bin", contents.lastPathComponent == "Resources", app.lastPathComponent == "Contents",
           binApp.pathExtension == "app" {
            bundle = binApp
            checkout = nil
            return
        }
        bundle = nil
        var dir = macos
        var found: URL?
        while dir.path != "/" && !dir.path.isEmpty {
            if fileExists(dir.appendingPathComponent("VERSION").path),
               fileExists(dir.appendingPathComponent("native/Package.swift").path) { found = dir; break }
            dir = dir.deletingLastPathComponent()
        }
        checkout = found
    }

    /// The version this is: the bundle's runtime.json (what the updater compares), else the checkout's
    /// `VERSION` file; "?" when neither says.
    public func version() -> String {
        if let bundle {
            let runtime = bundle.appendingPathComponent("Contents/Resources/runtime.json")
            if let data = try? Data(contentsOf: runtime),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let v = obj["version"] as? String {
                return v
            }
            let plist = bundle.appendingPathComponent("Contents/Info.plist")
            if let info = NSDictionary(contentsOf: plist), let v = info["CFBundleShortVersionString"] as? String { return v }
            return "?"
        }
        if let checkout, let text = try? String(contentsOf: checkout.appendingPathComponent("VERSION"), encoding: .utf8) {
            let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v }
        }
        return "?"
    }
}

extension AppLocation {
    /// The environment variable that names another build of `name` (a development override).
    public static func binaryOverride(_ name: String) -> String? {
        ["palaver-server": "PALAVER_SERVER_BIN", "palaver-worker": "PALAVER_WORKER_BIN", "palaver-lm": "PALAVER_LM_BIN"][name]
    }

    /// palaver-lm, the language model's worker, as palaver-server and palaver-worker start it: `$PALAVER_LM_BIN` when
    /// set, else the one beside `executable` (the bundle's Contents/MacOS, a build folder). The path beside it even
    /// when it is not there: starting it then fails and says where it was looked for.
    public static func languageModelWorker(beside executable: URL,
                                           environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let given = environment["PALAVER_LM_BIN"], !given.isEmpty { return given }
        return executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("palaver-lm").path
    }

    /// The Swift program `name` (`palaver-server`, `palaver-worker`) the app starts: `PALAVER_SERVER_BIN` /
    /// `PALAVER_WORKER_BIN` when set, else the bundle's `Contents/MacOS/<name>`, else the checkout's
    /// `native/.build/<debug|release>/<name>` (this build's own configuration first). nil when it is not there.
    public func binary(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                       fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        binaryCandidates(name, environment: environment).first(where: fileExists)
    }

    /// Where `name` is looked for, in order (`binary`); the first is where it should be.
    public func binaryCandidates(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        if let key = Self.binaryOverride(name), let given = environment[key], !given.isEmpty { return [given] }
        if let bundle { return [bundle.appendingPathComponent("Contents/MacOS/\(name)").path] }
        if let checkout {
            #if DEBUG
            let configurations = ["debug", "release"]
            #else
            let configurations = ["release", "debug"]
            #endif
            return configurations.map { checkout.appendingPathComponent("native/.build/\($0)/\(name)").path }
        }
        return []
    }

    /// The bundle's folder of the window's page files (Contents/Resources/web).
    public static let WEB_RESOURCES = "Contents/Resources/web"

    /// The window's page files palaver-server serves (`--static`): the bundle's `WEB_RESOURCES` or the checkout's
    /// `web`; nil outside both.
    public func staticDir() -> URL? {
        if let bundle { return bundle.appendingPathComponent(Self.WEB_RESOURCES, isDirectory: true) }
        if let checkout { return checkout.appendingPathComponent("web", isDirectory: true) }
        return nil
    }
}

/// The programs the app starts: palaver-server, palaver-worker and palaver-lm, each where it should be (`AppLocation.binary`),
/// also when it is missing: starting it then fails and says where. `said`: one line for app.log per missing program.
public enum AppPrograms {
    public static func find(location: AppLocation, environment: [String: String],
                            isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
        -> (server: String, worker: String, lm: String, said: [String]) {
        var said: [String] = []
        func program(_ name: String) -> String {
            if let found = location.binary(name, environment: environment, fileExists: isExecutable) { return found }
            let expected = location.binaryCandidates(name, environment: environment).first ?? name
            said.append("\(name) is missing (\(expected))")
            return expected
        }
        return (program("palaver-server"), program("palaver-worker"), program("palaver-lm"), said)
    }
}

/// What an earlier run left in $TMPDIR: the notify socket and state file of a launcher or app that
/// is gone (`palaver-<pid>.sock`, `palaver-<pid>.notifications`, its `.tmp`). The pid's own files and
/// those of a live process stay.
public enum TempSweep {
    public static func sweep(_ dir: URL, myPid: Int32 = getpid(),
                             alive: (Int32) -> Bool = { $0 > 0 && (kill($0, 0) == 0 || errno == EPERM) }) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var removed: [String] = []
        for name in names where name.hasPrefix("palaver-") {
            let rest = name.dropFirst("palaver-".count)
            let digits = rest.prefix(while: \.isNumber)
            let suffix = rest.dropFirst(digits.count)
            guard !digits.isEmpty, let pid = Int32(digits),
                  [".sock", ".notifications", ".notifications.tmp"].contains(String(suffix)) else { continue }
            if pid == myPid || alive(pid) { continue }
            let path = dir.appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { continue }
            if unlink(path) == 0 { removed.append(name) }
        }
        return removed.sorted()
    }
}

/// The single-instance rule (daemon.py, `DaemonRunning`): daemon.json names a live Palaver that is
/// not this process. Asked before anything is bound (app.sock, the notify socket, the window's port).
public enum RunningApp {
    public static func other(stateFile: URL, myPid: Int32 = getpid(), alive: (Int32?) -> Bool) -> Int32? {
        guard let data = try? Data(contentsOf: stateFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let state = obj["state"] as? String, state != "stopped" else { return nil }
        guard let n = obj["pid"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let pid = Int32(clamping: n.intValue)
        guard pid != myPid, alive(pid) else { return nil }
        return pid
    }
}

extension AppLocation {
    /// The release this bundle is, as the swap that installed it waits to read in started-ok: its
    /// runtime.json's version (what `app update status` calls the installed one), else Info.plist's.
    /// nil outside a bundle, or when neither says.
    public func releaseVersion() -> String? {
        guard bundle != nil else { return nil }
        let v = version()
        return v == "?" ? nil : v
    }
}

/// The bundle the app was started from, as it was then (its path and inode). Another app at that path
/// now (an update's swap put the version before back) or none at all means this process runs an app
/// that was replaced: it must quit, or two Palavers would record.
public final class BundleWatch: @unchecked Sendable {
    public let path: String
    private let device: dev_t
    private let inode: ino_t

    /// nil for a development build (no bundle) or a bundle that cannot be looked at.
    public init?(bundle: URL?) {
        guard let bundle else { return nil }
        var st = stat()
        guard stat(bundle.path, &st) == 0 else { return nil }
        path = bundle.path
        device = st.st_dev
        inode = st.st_ino
    }

    /// The path is gone, or holds another folder than at the start.
    public func replaced() -> Bool {
        var st = stat()
        if stat(path, &st) != 0 { return errno == ENOENT || errno == ENOTDIR }
        return st.st_dev != device || st.st_ino != inode
    }
}

/// The single-instance lock: `app.lock` in Application Support, flock'd for as long as the app runs (the
/// kernel drops it when the process ends, however it ends). Taken before anything is bound (app.sock,
/// the notify socket, the window's port); a second app finds it held and refuses, whatever daemon.json
/// says. Close-on-exec: the workers never inherit it.
public final class InstanceLock: @unchecked Sendable {
    private var fd: Int32

    /// nil when another process (or another open of it in this one) holds it, or it cannot be opened.
    public init?(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        self.fd = fd
        let pid = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = pid.withCString { write(fd, $0, strlen($0)) }  // for a person looking; the lock is what counts
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
