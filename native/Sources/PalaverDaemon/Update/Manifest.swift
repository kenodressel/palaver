// The release manifest (release.py's parse_manifest, #60) as 0.6 and later read it: the release's version, its
// app archive (name, URL, size, sha256), the macOS it needs and its notes. Every name is checked as safe for a
// file name and every sha256 as well-formed before anything is downloaded.
//
// The manifest keeps schema 1 and its `runtime` block for the Python updaters of every release before 0.6
// (they refuse a manifest without one; tools/build_release.py names a placeholder there). This updater reads
// neither the runtime nor `models` (Palaver hosts no models): a manifest with or without them is the same here.
import Foundation

public struct ManifestError: Error, CustomStringConvertible, Equatable, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// One file of a release.
public struct ReleaseAsset: Equatable, Sendable {
    public var name: String
    public var url: String
    public var size: Int
    public var sha256: String
    public init(name: String, url: String, size: Int, sha256: String) {
        self.name = name; self.url = url; self.size = size; self.sha256 = sha256
    }
}

public struct ReleaseManifest: Equatable, Sendable {
    public static let schema = 1
    public static let latestURL = "https://github.com/kenodressel/palaver/releases/latest/download/manifest.json"

    public var version: String
    public var app: ReleaseAsset
    public var minimumMacos: String
    public var arch: String
    public var notes: String?

    public init(version: String, app: ReleaseAsset, minimumMacos: String = "15.0", arch: String = "arm64", notes: String? = nil) {
        self.version = version; self.app = app; self.minimumMacos = minimumMacos; self.arch = arch; self.notes = notes
    }

    /// The manifest, checked. Throws ManifestError saying what is wrong.
    public static func parse(_ data: Data) throws -> ReleaseManifest {
        let any: Any
        do { any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch {
            throw ManifestError("not JSON: \(error.localizedDescription)")
        }
        guard let obj = any as? [String: Any] else { throw ManifestError("not a JSON object") }
        guard let schema = integer(obj["schema"]), schema == Self.schema else {
            throw ManifestError("unknown schema \(obj["schema"].map { "\($0)" } ?? "None"): a newer installer is needed")
        }
        let version = try text(obj, "version", "manifest")
        guard ReleaseVersion.key(version) != nil else { throw ManifestError("bad version \(version)") }
        let notes = (obj["notes"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let minimum = (obj["minimum_macos"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "15.0"
        let arch = (obj["arch"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "arm64"
        return ReleaseManifest(version: version, app: try asset(obj["app"], "app"), minimumMacos: minimum, arch: arch, notes: notes)
    }

    static func asset(_ value: Any?, _ what: String) throws -> ReleaseAsset {
        guard let d = value as? [String: Any] else { throw ManifestError("\(what): missing") }
        guard let name = d["name"] as? String, safeName(name) else { throw ManifestError("\(what): bad file name \(d["name"].map { "\($0)" } ?? "None")") }
        guard let url = d["url"] as? String, url.hasPrefix("https://") || url.hasPrefix("file://") else {
            throw ManifestError("\(what): bad url \(d["url"].map { "\($0)" } ?? "None")")
        }
        guard let size = integer(d["size"]), size >= 0 else { throw ManifestError("\(what): bad size \(d["size"].map { "\($0)" } ?? "None")") }
        guard let sha = d["sha256"] as? String, sha.utf8.count == 64, sha.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            throw ManifestError("\(what): bad sha256")
        }
        return ReleaseAsset(name: name, url: url, size: size, sha256: sha)
    }

    /// `[A-Za-z0-9][A-Za-z0-9._-]*`: a name that is a plain file name, never a path.
    static func safeName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        func alnum(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) }
        guard let first = bytes.first, alnum(first) else { return false }
        return bytes.dropFirst().allSatisfy { alnum($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D }
    }

    /// A JSON integer (not a float, not a boolean).
    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) else { return nil }
        return n.intValue
    }

    private static func text(_ obj: [String: Any], _ key: String, _ what: String) throws -> String {
        guard let s = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            throw ManifestError("\(what): no \(key)")
        }
        return s
    }
}

/// Release versions as release.py compares them: numbers, then a < b < rc < the final release.
public enum ReleaseVersion {
    public struct Key: Comparable, Sendable {
        let numbers: [Int]
        let pre: Int
        let n: Int
        public static func < (a: Key, b: Key) -> Bool {
            if a.numbers != b.numbers { return a.numbers.lexicographicallyPrecedes(b.numbers) }
            if a.pre != b.pre { return a.pre < b.pre }
            return a.n < b.n
        }
    }

    /// `v?(\d+(\.\d+)*)((a|b|rc)\d+)?`, else nil.
    public static func key(_ version: String) -> Key? {
        var s = Substring(version.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.hasPrefix("v") { s = s.dropFirst() }
        var numbers: [Int] = []
        var digits = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c.isASCII, c.isNumber { digits.append(c) }
            else if c == ".", !digits.isEmpty { numbers.append(Int(digits) ?? 0); digits = "" }
            else { break }
            i = s.index(after: i)
        }
        guard !digits.isEmpty, let last = Int(digits) else { return nil }
        numbers.append(last)
        while numbers.count < 4 { numbers.append(0) }
        let rest = s[i...]
        if rest.isEmpty { return Key(numbers: numbers, pre: 3, n: 0) }
        for (tag, pre) in [("rc", 2), ("a", 0), ("b", 1)] where rest.hasPrefix(tag) {
            let n = rest.dropFirst(tag.count)
            guard !n.isEmpty, n.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(n) else { return nil }
            return Key(numbers: numbers, pre: pre, n: value)
        }
        return nil
    }

    private static let unknown = Key(numbers: [0], pre: 0, n: 0)

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        (key(candidate) ?? unknown) > (key(current) ?? unknown)
    }

    /// This Mac's macOS is `minimum` or later.
    public static func macosOK(minimum: String, macos: String) -> Bool {
        (key(macos) ?? unknown) >= (key(minimum) ?? unknown)
    }

    /// This Mac's macOS as "15.6.1".
    public static func macos() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

/// release.plan_update for 0.6 and later: always the app alone (no runtime, no hosted models).
public enum UpdatePlanner {
    /// nil when the manifest is not newer than `installed`. Throws for a release this Mac can't run.
    public static func plan(installed: String, manifest: ReleaseManifest, macos: String?) throws -> UpdatePlan? {
        guard ReleaseVersion.isNewer(manifest.version, than: installed) else { return nil }
        if let macos, !ReleaseVersion.macosOK(minimum: manifest.minimumMacos, macos: macos) {
            throw ManifestError("Palaver \(manifest.version) needs macOS \(manifest.minimumMacos) (this Mac has \(macos))")
        }
        return UpdatePlan(version: manifest.version, notes: manifest.notes, downloadBytes: manifest.app.size)
    }
}
