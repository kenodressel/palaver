// The old Python runtime goes (phase 4 batch 9): `~/Library/Application Support/palaver/runtime/`, about 600 MB
// from 0.3.x/0.5.x (plus the placeholder an older updater unpacked on the way to 0.6, `.previous` and unfinished
// `.<id>.*` unpackings). Housekeeping runs it at every start; it deletes only when all of these hold:
//   - this app is a release bundle without Python (no Contents/MacOS/palaver-python, no Contents/Resources/python);
//   - this version has started all the way and the swap that installed it committed: started-ok holds its
//     version, `previous-app` is gone (every swap.sh, 0.3's and 0.5's too, deletes it only on success) and
//     update.json records no failed swap. started-ok alone is not enough: a first tick after swap.sh's 120 s
//     window writes it while the swap is already putting the old app back, which needs its runtime;
//   - no `legacy-server` marker (or PALAVER_LEGACY_SERVER=1) asks for the Python fallback;
//   - no Claude Code or Claude Desktop config still names the runtime itself (the MCP entries' move runs first; an
//     entry naming a Palaver.app's `bin/python` needs no runtime: in 0.6 that is a shell shim starting
//     `bin/palaver mcp`);
//   - no process runs from inside the runtime folder or has its Python loaded (a Claude Desktop server started
//     from an old entry, say).
// The root must be a real folder (lstat) that resolves to exactly that path; deletion never follows a symlink out
// of it. Logged once, with the bytes freed. Going back to 0.5.x with install.sh downloads the runtime again.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

public enum RuntimeCleanup {
    public struct Facts: Sendable {
        /// The running app's bundle; nil from a checkout.
        public var bundle: URL?
        /// The bundle's release version (runtime.json); nil for a development build.
        public var bundleVersion: String?
        public var support: URL
        public var environment: [String: String]
        /// Claude's config files whose text must not name the runtime.
        public var claudeConfigs: [URL]
        /// The pids of processes that run from or have loaded a file under the folder.
        public var users: @Sendable (URL) -> [Int32]
        public init(bundle: URL?, bundleVersion: String?, support: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
                    claudeConfigs: [URL], users: @escaping @Sendable (URL) -> [Int32] = { RuntimeCleanup.processesUsing($0) }) {
            self.bundle = bundle; self.bundleVersion = bundleVersion; self.support = support; self.environment = environment
            self.claudeConfigs = claudeConfigs; self.users = users
        }
        public var root: URL { support.appendingPathComponent("runtime", isDirectory: true) }

        /// The running app's: Claude Code's and Claude Desktop's configs under the user's home.
        public static func app(bundle: URL?, bundleVersion: String?, support: URL,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> Facts {
            let stores = StorePaths.current(env: environment)
            return Facts(bundle: bundle, bundleVersion: bundleVersion, support: support, environment: environment,
                         claudeConfigs: [stores.claudeConfig, stores.claudeDesktopConfig])
        }
    }

    /// Why the runtime stays now; nil: it may go. Only asked when the folder is there.
    public static func blocker(_ f: Facts) -> String? {
        guard let bundle = f.bundle, let version = f.bundleVersion else { return "not a release bundle" }
        let fm = FileManager.default
        if fm.fileExists(atPath: bundle.appendingPathComponent("Contents/MacOS/palaver-python").path)
            || fm.fileExists(atPath: bundle.appendingPathComponent("Contents/Resources/python").path) {
            return "this app still runs Python"
        }
        let ok = (try? String(contentsOf: f.support.appendingPathComponent("started-ok"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if ok != version { return "Palaver \(version) has not started all the way yet" }
        if fm.fileExists(atPath: f.support.appendingPathComponent("previous-app").path) {
            return "the update to Palaver \(version) is not finished (previous-app is still there)"
        }
        if let data = fm.contents(atPath: f.support.appendingPathComponent("update.json").path),
           let status = JSONValue.parse(data), status["state"]?.stringValue == "failed", status["from_swap"]?.truthy == true {
            return "update.json says the last update's swap failed"
        }
        if LegacyServer.wanted(environment: f.environment, support: f.support) { return "the legacy-server fallback is on" }
        let root = f.root.path, runtimeName = "Application Support/palaver/runtime"
        for config in f.claudeConfigs {
            guard let data = fm.contents(atPath: config.path) else { continue }
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
            if text.contains(root) || text.contains(runtimeName) {
                return "\(config.lastPathComponent) still starts Palaver's Python"
            }
        }
        let users = f.users(f.root)
        if !users.isEmpty { return "a process uses it (pid \(users.map(String.init).joined(separator: ", ")))" }
        return nil
    }

    /// Deletes the runtime folder when nothing blocks it. The bytes freed; nil when it stays (or is not there).
    @discardableResult
    public static func run(_ f: Facts, log: (String) -> Void) -> Int64? {
        var st = stat()
        guard lstat(f.root.path, &st) == 0 else { return nil }  // gone already: nothing to say
        if let why = blocker(f) {
            log("the old Python runtime stays for now: \(why)")
            return nil
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            log("the old Python runtime stays: \(f.root.path) is not a folder")
            return nil
        }
        // The root resolves to exactly <support>/runtime: no symlinked parent leads elsewhere.
        guard let real = realPath(f.root.path), let support = realPath(f.support.path), real == support + "/runtime" else {
            log("the old Python runtime stays: \(f.root.path) does not resolve to itself")
            return nil
        }
        var freed: Int64 = 0
        let ok = removeTree(real, freed: &freed)
        log(ok ? "deleted the old Python runtime: \(String(format: "%.1f", Double(freed) / 1e6)) MB free again"
               : "deleting the old Python runtime stopped part-way (\(String(format: "%.1f", Double(freed) / 1e6)) MB freed)")
        return freed
    }

    static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// Removes `path` and everything in it, by lstat: a symlink is removed as a link, never followed. The bytes of the
    /// regular files removed go into `freed`. false: something could not be removed.
    static func removeTree(_ path: String, freed: inout Int64) -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        let ok = removeContents(fd, freed: &freed)
        close(fd)
        return rmdir(path) == 0 && ok
    }

    private static func removeContents(_ dirfd: Int32, freed: inout Int64) -> Bool {
        let dupfd = dup(dirfd)
        guard dupfd >= 0, let dir = fdopendir(dupfd) else { return false }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        var ok = true
        for name in names {
            var st = stat()
            guard fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { ok = false; continue }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                let sub = openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard sub >= 0 else { ok = false; continue }
                if !removeContents(sub, freed: &freed) { ok = false }
                close(sub)
                if unlinkat(dirfd, name, AT_REMOVEDIR) != 0 { ok = false }
            } else {
                if unlinkat(dirfd, name, 0) == 0 {
                    if (st.st_mode & S_IFMT) == S_IFREG { freed += Int64(st.st_size) }
                } else {
                    ok = false
                }
            }
        }
        return ok
    }

    /// The processes whose program lies under `root`, or that have one of its Pythons or libpython mapped (lsof):
    /// a Python started from an old app's host runs from the bundle but loads the runtime.
    public static func processesUsing(_ root: URL) -> [Int32] {
        let prefix = (realPath(root.path) ?? root.path) + "/"
        var found = Set<Int32>()
        let count = proc_listallpids(nil, 0)
        if count > 0 {
            var pids = [Int32](repeating: 0, count: Int(count) * 2)
            let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            for pid in pids.prefix(Int(max(0, n))) where pid > 0 && pid != getpid() {
                if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer).hasPrefix(prefix) { found.insert(pid) }
            }
        }
        // The files a Python process maps from a runtime: bin/python3.x and lib/libpython3.x.dylib.
        var files: [String] = []
        let fm = FileManager.default
        for id in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            for sub in ["bin", "lib"] {
                let dir = root.appendingPathComponent(id).appendingPathComponent(sub)
                for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                where name.hasPrefix("python3") || (name.hasPrefix("libpython") && name.hasSuffix(".dylib")) {
                    let path = dir.appendingPathComponent(name).path
                    var st = stat()
                    if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { files.append(path) }
                }
            }
        }
        if !files.isEmpty {
            let p = Foundation.Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            p.arguments = ["-t", "-w", "--"] + files
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            if (try? p.run()) != nil {
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                for line in text.split(separator: "\n") { if let pid = Int32(line), pid != getpid() { found.insert(pid) } }
            }
        }
        return found.sorted()
    }
}
