import Foundation

/// Finds a bundled resource without SwiftPM's generated `Bundle.module`, which calls fatalError when the
/// resource bundle is missing (an app-start crash). nil when it is nowhere.
public enum ResourceLookup {
    public static func find(_ name: String, _ ext: String, main: Bundle? = .main, searchDirs: [URL],
                            bundleSuffix: String) -> URL? {
        if let url = main?.url(forResource: name, withExtension: ext) { return url }
        let fm = FileManager.default
        for dir in searchDirs {
            let bundles = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(bundleSuffix) }
            for bundle in bundles.sorted() {
                let root = dir.appendingPathComponent(bundle, isDirectory: true)
                for candidate in [root, root.appendingPathComponent("Resources", isDirectory: true),
                                  root.appendingPathComponent("Contents/Resources", isDirectory: true)] {
                    let file = candidate.appendingPathComponent("\(name).\(ext)")
                    if fm.fileExists(atPath: file.path) { return file }
                }
            }
        }
        return nil
    }
}
