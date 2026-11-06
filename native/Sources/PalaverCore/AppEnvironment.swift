// Where the app runs and what it starts with (cli.py's global options, install_layout.bundle,
// app_bundle's layout): the bundle or a development build, the Python its workers run, its version,
// the one-release fallback to the Python menu bar app, and the leftovers of an earlier run it
// sweeps. Pure enough to test without starting anything.
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
    /// The checkout (the folder with `palaver/__init__.py`) a development build lives in.
    public let checkout: URL?

    public static let hostName = "palaver-python"

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
        bundle = nil
        var dir = macos
        var found: URL?
        while dir.path != "/" && !dir.path.isEmpty {
            if fileExists(dir.appendingPathComponent("palaver/__init__.py").path) { found = dir; break }
            dir = dir.deletingLastPathComponent()
        }
        checkout = found
    }

    /// The Python the workers run: the bundle's host (`Contents/MacOS/palaver-python`); in a checkout its
    /// venv's python; `PALAVER_PYTHON` wins (a development override).
    public func python(environment: [String: String]) -> String {
        if let p = environment["PALAVER_PYTHON"], !p.isEmpty { return p }
        if let bundle { return bundle.appendingPathComponent("Contents/MacOS/\(Self.hostName)").path }
        if let checkout { return checkout.appendingPathComponent(".venv/bin/python").path }
        return "python3"
    }

    /// The version this is: the bundle's runtime.json (what the updater compares), else
    /// `__version__` of the checkout's palaver/__init__.py; "?" when neither says.
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
        if let checkout, let text = try? String(contentsOf: checkout.appendingPathComponent("palaver/__init__.py"), encoding: .utf8) {
            for line in text.split(separator: "\n") where line.hasPrefix("__version__") {
                let parts = line.split(separator: "\"")
                if parts.count >= 2 { return String(parts[1]) }
            }
        }
        return "?"
    }

    /// The runtime a release runs its Python on (`PalaverRuntimeID`): its python3 must be there.
    public func runtimePython(home: URL) -> URL? {
        guard let bundle,
              let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let rid = info["PalaverRuntimeID"] as? String, !rid.isEmpty else { return nil }
        return home.appendingPathComponent("Library/Application Support/palaver/runtime/\(rid)/bin/python3")
    }
}

/// The one-release fallback (spec "Rollout"): `PALAVER_LEGACY_APP=1`, or this file in Application
/// Support, starts the Python menu bar app (`palaver-python -m palaver menubar`) instead.
public enum LegacyApp {
    public static let markerName = "legacy-app"

    public static func wanted(environment: [String: String], support: URL,
                              fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        environment["PALAVER_LEGACY_APP"] == "1" || fileExists(support.appendingPathComponent(markerName).path)
    }

    /// `<python> -m palaver [options] menubar`, as the ObjC launcher started it.
    public static func argv(python: String, cliOptions: [String]) -> [String] {
        [python, "-m", "palaver"] + cliOptions + ["menubar"]
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
