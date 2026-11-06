import Foundation
import Testing
@testable import PalaverCore

@Suite struct ResourceLookupTests {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("res-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aMissingBundleGivesNilWithoutCrashing() throws {
        let dir = try temp()
        #expect(ResourceLookup.find("menubar", "png", main: nil, searchDirs: [dir], bundleSuffix: "_Palaver.bundle") == nil)
        #expect(ResourceLookup.find("menubar", "png", main: nil, searchDirs: [dir.appendingPathComponent("nope")], bundleSuffix: "_Palaver.bundle") == nil)
    }

    @Test func theSwiftPMResourceBundleIsFoundByPath() throws {
        let dir = try temp()
        let bundle = dir.appendingPathComponent("palaver-engine_Palaver.bundle/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data([1]).write(to: bundle.appendingPathComponent("menubar.png"))
        let found = ResourceLookup.find("menubar", "png", main: nil, searchDirs: [dir], bundleSuffix: "_Palaver.bundle")
        #expect(found?.lastPathComponent == "menubar.png")
    }
}
