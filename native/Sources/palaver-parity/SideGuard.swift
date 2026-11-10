// palaver-parity runs only on a parity side (tools/parity/corpus.py): it reads and writes the stores of
// XDG_CONFIG_HOME, the home of PALAVER_HOME and the recordings of config.toml's output_dir, so all three must be the
// side's own. Every check runs before the op does; tools/parity/ops.py makes the same checks on the Python side.
import Foundation

enum SideGuard {
    static let notASide = "palaver-parity runs only on a parity side"

    static var realHome: String? {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        return String(cString: dir)
    }

    /// `os.path.realpath(path)` (not strict): the components from left to right, each symlink replaced by its
    /// target (resolved the same way), `..` taking away the last component of what is resolved so far — the path
    /// the kernel would reach, never a lexical shortcut ("<side>/link/../x" with `link` outside is outside); a
    /// component that does not exist is kept as written.
    static func canonical(_ path: String, depth: Int = 0) -> String {
        let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        var resolved: [String] = []
        for part in absolute.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if part == "." { continue }
            if part == ".." { if !resolved.isEmpty { resolved.removeLast() }; continue }
            let candidate = "/" + (resolved + [part]).joined(separator: "/")
            var st = stat()
            if depth < 40, lstat(candidate, &st) == 0, st.st_mode & S_IFMT == S_IFLNK,
               let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                let joined = target.hasPrefix("/") ? target : "/" + (resolved + [target]).joined(separator: "/")
                resolved = canonical(joined, depth: depth + 1).split(separator: "/").map(String.init)
            } else {
                resolved.append(part)
            }
        }
        return "/" + resolved.joined(separator: "/")
    }

    private struct Identity: Equatable { let device: dev_t, inode: ino_t }

    private static func identity(_ path: String) -> Identity? {
        var st = stat()
        return stat(path, &st) == 0 ? Identity(device: st.st_dev, inode: st.st_ino) : nil
    }

    /// The same file: by device and inode when both exist (case and firmlink spellings can't slip by), else by
    /// canonical path.
    static func same(_ a: String, _ b: String) -> Bool {
        if let x = identity(canonical(a)), let y = identity(canonical(b)) { return x == y }
        return canonical(a) == canonical(b)
    }

    /// Whether `path` is `root` or inside it: the existing ancestors of its canonical path compared with `root` by
    /// device and inode. False when `root` does not exist.
    static func isInside(_ path: String, _ root: String) -> Bool {
        guard let want = identity(canonical(root)) else { return false }
        var url = URL(fileURLWithPath: canonical(path))
        while true {
            if identity(url.path) == want { return true }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return false }
            url = parent
        }
    }

    /// Why the environment alone rules a run out: XDG_CONFIG_HOME and PALAVER_HOME must be set and neither may be the
    /// user's real home or its .config. nil: go on.
    static func environmentProblem(_ env: [String: String]) -> String? {
        guard let home = realHome else { return "the user's home is unknown" }
        for key in ["XDG_CONFIG_HOME", "PALAVER_HOME"] {
            guard let value = env[key], !value.isEmpty else { return "\(key) is not set: \(notASide)" }
            if same(value, home) || same(value, home + "/.config") { return "\(key) is the real home or ~/.config: \(notASide)" }
        }
        return nil
    }

    /// Why `side` is no parity side for this environment: XDG_CONFIG_HOME must be its config/ and PALAVER_HOME its
    /// home/, its config/palaver/config.toml must exist, and it must not hold the real home. Nothing is read.
    static func sideProblem(_ side: String, _ env: [String: String]) -> String? {
        if !same(env["XDG_CONFIG_HOME"] ?? "", side + "/config") { return "XDG_CONFIG_HOME is not <side>/config: \(notASide)" }
        if !same(env["PALAVER_HOME"] ?? "", side + "/home") { return "PALAVER_HOME is not <side>/home: \(notASide)" }
        var isDir: ObjCBool = true
        guard FileManager.default.fileExists(atPath: side + "/config/palaver/config.toml", isDirectory: &isDir), !isDir.boolValue else {
            return "the side has no config/palaver/config.toml: \(notASide)"
        }
        if let home = realHome, isInside(home, side) { return "the side holds the real home: \(notASide)" }
        return nil
    }

    /// Why the loaded side must not run: its recordings (config.toml's output_dir) must be inside it.
    static func recordingsProblem(_ recordings: URL, side: String) -> String? {
        isInside(recordings.path, side) ? nil : "config.toml's output_dir is outside the side: \(notASide)"
    }
}
