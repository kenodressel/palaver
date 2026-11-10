import Foundation
import PalaverCore

/// The one lookup for domain resources (the glossary's zipf.bin, ...): the app's `Contents/Resources`,
/// else the SwiftPM bundle `palaver-engine_PalaverDomain.bundle` next to the executable (development, tests),
/// else `PALAVER_RESOURCES` (DEBUG). Never `Bundle.module`: its accessor crashes when the bundle is missing.
public enum DomainResources {
    public static let bundleSuffix = "palaver-engine_PalaverDomain.bundle"

    /// The folders the SwiftPM bundle may sit in, worked out once.
    private static let searchDirs: [URL] = {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r) }
        if let exe = Bundle.main.executableURL { dirs.append(exe.deletingLastPathComponent()) }
        #if DEBUG
        // A test run's executable is SwiftPM's helper: the folders of the loaded bundles (the .xctest) count
        // too, the resource bundle sits beside them. Swift Testing loads the test bundle as an image.
        for b in Bundle.allBundles { dirs.append(b.bundleURL.deletingLastPathComponent()) }
        for i in 0..<_dyld_image_count() {
            guard let c = _dyld_get_image_name(i) else { continue }
            let path = String(cString: c)
            if let r = path.range(of: ".xctest/") {
                dirs.append(URL(fileURLWithPath: String(path[..<r.lowerBound]) + ".xctest").deletingLastPathComponent())
            }
        }
        #endif
        return dirs
    }()

    public static func url(_ name: String) -> URL? {
        let (base, ext) = split(name)
        // `.copy("Resources")` keeps the folder inside the SwiftPM bundle (Contents/Resources/Resources/<name>);
        // the app has the files flat in Contents/Resources.
        for prefix in ["", "Resources/"] {
            if let url = ResourceLookup.find(prefix + base, ext, searchDirs: searchDirs, bundleSuffix: bundleSuffix) { return url }
        }
        #if DEBUG
        if let root = ProcessInfo.processInfo.environment["PALAVER_RESOURCES"], !root.isEmpty {
            let file = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        #endif
        return nil
    }

    /// "zipf.bin" -> ("zipf", "bin"); ".keep" -> ("", "keep"); "LICENSE" -> ("LICENSE", "").
    static func split(_ name: String) -> (String, String) {
        guard let dot = name.lastIndex(of: ".") else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }
}
